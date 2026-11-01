// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IEntropyModule } from "../interfaces/IEntropyModule.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";
import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { Splits } from "../economics/Splits.sol";
import {
    PRODUCT_STREAM,
    ProductEconomics,
    WorkTerms
} from "../interfaces/types/EconomicsTypes.sol";
import {
    ItemKind,
    PackageItem,
    SeedPolicy,
    StreamMintRequest
} from "../interfaces/types/PackageTypes.sol";
import { PrimaryOutcome, PrimarySettlement, PrimaryTerms } from "../interfaces/types/SaleTypes.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { Utf8 } from "../libraries/Utf8.sol";
import { SpdxId } from "./SpdxId.sol";

/// @title Stream
/// @notice 6529 Stream core: the one shared, network-curated ERC-721 holding every curated 1/1
///         (ADR 0001 sections 1, 4, 7 and 12; integrator decisions D1, D3, D4, D6, D13 and
///         E1-E11).
/// @dev Holds ownership, the terms locked at mint, collections and serials, the edition link and
///      the marketplace metadata, and forwards `tokenURI` to the work's renderer. Records,
///      licenses, seeds, finalize and locators live in the bound `IWorkRecords` satellite.
///
///      Storage is shaped by the auction-start budget (ADR 0004): 350K Prague gas and at most 6
///      new slots, 7 with a bid, per steady-state start. A mint writes the ERC-721 owner and
///      balance, one shared counter word, the collection's counter word and two work words: the
///      seller, serial, collection, flags and terms ID; the item hash. The terms (the lead artist
///      ID, royalty rate, fee share, fee-recipient index and minting adapter's index) are one
///      word shared by every work with the same terms, written by the first of them (QUALITY-6),
///      so a start under existing terms writes one word fewer: 5 new slots, 6 with a bid. A first
///      start under new terms (an artist's first, and every artist's first after an economics
///      change or through a newly admitted adapter) writes the terms word: 6, 7 with a bid. On a
///      collision of the terms' 23-bit hashed position it writes one more, the overflow word and
///      its index; a curated artist can force that for another artist by grinding an address,
///      and with a bid that one first start can exceed 350K (an accepted limitation, ADR 0004).
///      Fee recipients are stored once each and referenced by index. The ERC-2981 receiver is
///      derived, not stored:
///      the seller itself when the fee share is zero, otherwise the split factory's salt-zero
///      wallet for the canonical payee list `(feeRecipient: feeShare, seller: rest)`. `royaltyInfo`
///      makes that one plain view call and no other: it can run out of gas and revert, but never
///      return a zero royalty for lack of gas (RC1's Medium finding).
///
///      Sale methods are pluggable (ADR 0005, owner decisions 14 and 15): an item names its 1/1
///      sale method by a `SaleKind` label, and only an admitted adapter reporting that label
///      mints it. Adapters are admitted one by one by a governed action (`setAdmittedMinter`,
///      SUCCESSOR_SETTER, the 30-day class); the English auction is admitted at genesis, and a
///      later sale method is a new adapter, with no new Stream. A removed adapter mints no more,
///      but still settles and cancels the sales it started.
///
///      Trust: the package registry, artist registry, economics resolver and entropy module
///      are the genesis contracts, replaceable one by one by governance (`setDependency`, the
///      30-day class, owner decision 16); the split factory is immutable. The records satellite
///      and 6529 Stream Editions are bound once each.
contract Stream is ERC721, AccessManaged, IStream {
    /// @notice The longest accepted collection name, in bytes.
    uint256 public constant MAX_NAME_BYTES = 256;
    /// @notice The gas `rendererOf` gives the records satellite's `pinnedRenderer`: several
    ///         times the cold reads it makes, so only a fault exhausts it.
    uint256 public constant RECORDS_GAS = 100_000;

    bytes32 private constant WORK_RECORDS = "WORK_RECORDS";
    bytes32 private constant EDITIONS = "EDITIONS";
    /// @dev The dependencies governance may replace (`setDependency`, owner decision 16).
    bytes32 private constant PACKAGE_REGISTRY = "PACKAGE_REGISTRY";
    bytes32 private constant ARTIST_REGISTRY = "ARTIST_REGISTRY";
    bytes32 private constant ECONOMICS = "ECONOMICS";
    bytes32 private constant ENTROPY_MODULE = "ENTROPY_MODULE";

    /// @dev `TokenData.flags`: an EDITION_MASTER, the seed policy (two bits), the primary sale
    ///      settled, the edition linked, and how the sale settled (owner decision 17): sold,
    ///      frozen out, or neither, unbid.
    uint8 private constant KIND_MASTER = 1;
    uint8 private constant SEED_SHIFT = 1;
    uint8 private constant SEED_MASK = 3;
    uint8 private constant SETTLED = 8;
    uint8 private constant LINKED = 16;
    uint8 private constant SALE_SOLD = 32;
    uint8 private constant SALE_FROZEN_OUT = 64;
    /// @dev Terms IDs below `OVERFLOW` are the hashed positions; from it, the overflow range.
    uint24 private constant HASHED = 0x7fffff;
    uint24 private constant OVERFLOW = 0x800000;

    /// @dev A token's two words (QUALITY-6). `flags` packs the kind (`KIND_MASTER`), the seed
    ///      policy (`SEED_SHIFT`), the settled primary sale and the edition link; `termsId` names
    ///      the token's `Terms` in `_terms`.
    struct TokenData {
        address seller;
        uint32 serial;
        uint32 collectionId;
        uint8 flags;
        uint24 termsId;
        bytes32 itemHash;
    }

    /// @dev What works share: the lead artist and the economics locked at mint, one word.
    ///      `feeRecipientId` and `minterId` index `_feeRecipients` and the admitted minters, both
    ///      from 1, and `artistId` is never zero, so a zero word is an empty position.
    struct Terms {
        uint160 artistId;
        uint32 royaltyRate;
        uint32 feeShare;
        uint16 feeRecipientId;
        uint16 minterId;
    }

    /// @dev `id` is assigned on first admission and kept, so a removed adapter still settles
    ///      the sales it started. Its sale kind is recorded then too (`_minterKinds`).
    struct Minter {
        bool admitted;
        uint16 id;
    }

    /// @dev `exists` keeps the counter word nonzero, so each mint pays a warm rewrite.
    struct CollectionData {
        bool exists;
        uint32 minted;
        bytes32 metadataHash;
        string name;
    }

    /// @dev `replaced` has bit `i` set once governance replaced dependency `i` (0 the package
    ///      registry, 1 the artist registry, 2 the economics resolver, 3 the entropy module):
    ///      every mint reads this word anyway, so a dependency still at its genesis value costs
    ///      a mint no extra slot.
    struct Counts {
        uint64 minted;
        uint64 burned;
        uint32 collections;
        uint16 minters;
        uint24 overflowTerms;
        uint8 replaced;
    }

    /// @notice The split factory that derives royalty receivers (the first economics
    ///         resolver's). Immutable: every royalty receiver ever derived stays valid.
    address public immutable splitFactory;
    /// @dev The genesis dependencies: what the getters return until `setDependency` replaces
    ///      one (owner decision 16).
    address private immutable _genesisPackageRegistry;
    address private immutable _genesisArtistRegistry;
    address private immutable _genesisEconomics;
    address private immutable _genesisEntropyModule;

    /// @inheritdoc IStream
    address public workRecords;
    /// @inheritdoc IStream
    address public editions;
    /// @inheritdoc IStream
    address public defaultRenderer;
    /// @dev The code hash `defaultRenderer` was installed with, checked again by `rendererOf`.
    bytes32 private _defaultRendererCodeHash;

    Counts private _counts;
    address private _owner;
    string private _contractURI;
    address[] private _feeRecipients;
    mapping(address recipient => uint16 id) private _feeRecipientIds;
    mapping(address adapter => Minter) private _minters;
    mapping(uint256 collectionId => CollectionData) private _collections;
    mapping(uint256 tokenId => TokenData) private _tokens;
    /// @dev Interned terms (QUALITY-6), at the position their hash names or in the overflow range.
    ///      `_terms` is an ordinary mapping: a "position" is a terms ID, a mapping key, not a
    ///      storage slot.
    mapping(uint24 termsId => Terms) private _terms;
    mapping(bytes32 termsHash => uint24 termsId) private _overflowIds;
    /// @dev Each admitted adapter's sale kind, by its ID: what `primaryTerms` reports for the
    ///      works it minted. Declared last, so the earlier slots keep their positions.
    mapping(uint16 minterId => bytes32 saleKind) private _minterKinds;
    /// @dev The dependencies governance replaced (owner decision 16), by the index of their
    ///      `Counts.replaced` bit; read only while that bit is set. Declared last, so the
    ///      earlier slots keep their positions.
    address[4] private _replaced;
    /// @dev A sold work's currency (the low 160 bits) and price (the high 96, saturated): one
    ///      word, written only for SOLD (owner decision 17). Declared last.
    mapping(uint256 tokenId => uint256 sale) private _sales;

    /// @param authority_ The AccessManager governing this contract.
    /// @param packageRegistry_ The package registry `mint` consumes items from.
    /// @param artistRegistry_ The artist registry resolving each work's artist.
    /// @param economics_ The economics resolver whose terms works lock at mint; its split
    ///        factory derives royalty receivers.
    /// @param entropyModule_ The VRF entropy module, or zero if VRF works are not supported.
    /// @param renderer_ The initial default renderer.
    /// @param rendererCodeHash The code hash `renderer_` must have.
    /// @param owner_ The initial marketplace owner.
    constructor(
        address authority_,
        address packageRegistry_,
        address artistRegistry_,
        address economics_,
        address entropyModule_,
        address renderer_,
        bytes32 rendererCodeHash,
        address owner_
    ) ERC721("6529 Stream", "STREAM") AccessManaged(authority_) {
        Dependency.check(packageRegistry_, type(IPackageRegistry).interfaceId);
        Dependency.check(artistRegistry_, type(IArtistRegistry).interfaceId);
        Dependency.check(economics_, type(IEconomicsResolver).interfaceId);
        if (entropyModule_ != address(0)) {
            Dependency.check(entropyModule_, type(IEntropyModule).interfaceId);
        }
        Dependency.checkPinned(renderer_, type(IRenderer).interfaceId, rendererCodeHash);
        address factory = IEconomicsResolver(economics_).splitFactory();
        Dependency.check(factory);
        _genesisPackageRegistry = packageRegistry_;
        _genesisArtistRegistry = artistRegistry_;
        _genesisEconomics = economics_;
        _genesisEntropyModule = entropyModule_;
        splitFactory = factory;
        defaultRenderer = renderer_;
        _defaultRendererCodeHash = rendererCodeHash;
        _owner = owner_;
        emit DefaultRendererSet(address(0), renderer_, rendererCodeHash);
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------------------------- minting

    /// @inheritdoc IMintTarget
    /// @dev Admitted minters only, and only for an item whose sale kind is the adapter's, as
    ///      recorded at its first admission (`SaleKindMismatch`): the kind `primaryTerms`
    ///      reports for the work, whatever the adapter's `saleKind()` answers later. The adapter
    ///      mints into its own custody (`to == msg.sender`) and passes `id = 0`, `amount = 1`
    ///      and `data = abi.encode(StreamMintRequest)`. The
    ///      registry checks the approval, consents, move signature, single use and content
    ///      uniqueness; this contract checks the Stream rules and the delivered VRF seed, and
    ///      assigns the next token ID and collection serial. The item's sale currency and
    ///      params are the adapter's to check (the English auction takes empty params).
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        Minter memory minter = _minters[msg.sender];
        if (!minter.admitted) revert NotAdmittedMinter(msg.sender);
        if (to != msg.sender || id != 0 || amount != 1) revert InvalidMintRequest();
        StreamMintRequest calldata req = _request(data);
        PackageItem calldata item = req.item;
        _checkItem(item);
        bytes32 kind = _minterKinds[minter.id];
        if (kind != item.sale.saleKind) revert SaleKindMismatch(item.sale.saleKind, kind);
        (bytes32 itemHash, uint256 artistId) = _consume(data);
        if (
            item.seedPolicy == SeedPolicy.VRF
                && !IEntropyModule(entropyModule()).isDelivered(itemHash)
        ) revert SeedNotDelivered(itemHash);
        WorkTerms memory w;
        (terms, w) = _quote(item, artistId);
        Terms memory shared = Terms(
            // `_consume` checked that `artistId` fits 160 bits.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint160(artistId),
            w.royaltyRate,
            w.feeShare,
            _feeRecipientId(w.feeRecipient),
            minter.id
        );
        tokenId = _store(req, itemHash, artistId, w.seller, _termsId(shared));
        _mint(to, tokenId);
    }

    /// @inheritdoc IMintTarget
    /// @dev For a minted token, only the sale kind (the minting adapter's), seller, fee terms
    ///      and the creator (the lead artist's active authority, resolved now: zero while a
    ///      recovery override is pending): the adapter reads them at settlement and owns the
    ///      currency. For `id` 0, a
    ///      preview from `data`; it resolves the lead artist through `artistIdOf`, so it reverts
    ///      while the lead artist has no identity.
    function primaryTerms(uint256 id, bytes calldata data)
        external
        view
        returns (PrimaryTerms memory terms)
    {
        if (id != 0) {
            (TokenData storage t, Terms memory shared) = _shared(id);
            terms.saleKind = _minterKinds[shared.minterId];
            terms.seller = t.seller;
            terms.feeRecipient = _feeRecipients[shared.feeRecipientId - 1];
            terms.feeShare = shared.feeShare;
            terms.creator = IArtistRegistry(artistRegistry()).activeAuthorityOf(shared.artistId);
            return terms;
        }
        StreamMintRequest calldata req = _request(data);
        _checkItem(req.item);
        uint256 artistId = IArtistRegistry(artistRegistry()).artistIdOf(req.item.parties[0].account);
        if (artistId == 0) revert InvalidLeadArtist();
        (terms,) = _quote(req.item, artistId);
    }

    /// @inheritdoc IMintTarget
    /// @dev Only the adapter that minted the token, while it still holds it in custody and
    ///      before the primary sale settled: the auction's cancel after an upheld dispute
    ///      (ADR 0001 section 12). Gated on the minting adapter's index, not on current
    ///      admission: like `settlePrimary`, it works after the adapter was removed, so a
    ///      running dispute can still finish, and another adapter holding the token can never
    ///      burn it. After a sale nothing is confiscated. The ID is never reused.
    function burn(uint256 id, uint256 amount) external {
        address holder = _ownerOf(id);
        if (amount != 1) revert InvalidMintRequest();
        if (holder != msg.sender) revert ERC721IncorrectOwner(msg.sender, id, holder);
        TokenData storage t = _tokens[id];
        if (_minters[msg.sender].id != _terms[t.termsId].minterId) {
            revert NotMintingAdapter(msg.sender);
        }
        if (t.flags & SETTLED != 0) revert SaleAlreadySettled(id);
        ++_counts.burned;
        _burn(id);
    }

    /// @inheritdoc IStream
    /// @dev PARAMETER_SETTER role, 48 hours: the upheld-dispute class of the auction's `cancel`,
    ///      so both are scheduled together and a guardian can veto either. Not part of `burn`:
    ///      Stream stores the item hash, not the content hash (D3), and storing it would cost
    ///      every start a word for a rare dispute path. The content hash is public in
    ///      `WorkMinted`, the registry's `ItemConsumed` and the package.
    function releaseContent(uint256 tokenId, bytes32 contentHash, uint256 beneficiary)
        external
        restricted
    {
        if (tokenId == 0 || tokenId > _counts.minted || _ownerOf(tokenId) != address(0)) {
            revert NotBurned(tokenId);
        }
        IPackageRegistry(packageRegistry())
            .releaseContent(contentHash, _tokens[tokenId].itemHash, beneficiary);
    }

    /// @inheritdoc IMintTarget
    function isAdmittedMinter(address adapter) external view returns (bool) {
        return _minters[adapter].admitted;
    }

    /// @inheritdoc IMintTarget
    /// @dev SUCCESSOR_SETTER role (the 30-day class). Admission checks code, ERC-165 for
    ///      `ISaleAdapter`, no EIP-7702 delegation and a nonzero sale kind, which the first
    ///      admission records with the adapter's index. Removal stops new mints only: the adapter
    ///      keeps its index, so it can still settle (`settlePrimary`) and cancel (`burn`)
    ///      the sales it started; a live sale is never stranded.
    function setAdmittedMinter(address adapter, bool admitted) external restricted {
        Minter storage minter = _minters[adapter];
        if (admitted) {
            Dependency.check(adapter, type(ISaleAdapter).interfaceId);
            if (minter.id == 0) {
                bytes32 kind = ISaleAdapter(adapter).saleKind();
                if (kind == 0) revert Dependency.InvalidDependency(adapter);
                uint16 id = ++_counts.minters;
                minter.id = id;
                _minterKinds[id] = kind;
            }
        }
        minter.admitted = admitted;
        emit AdmittedMinterSet(adapter, admitted);
    }

    /// @inheritdoc IMintTarget
    /// @dev Gated, like `burn`, on the minting adapter's index, not on current admission, so a
    ///      removed adapter still settles its sales. The outcome is two `TokenData.flags` bits
    ///      beside `SETTLED`, in the word the call reads anyway; only SOLD writes a new slot
    ///      (`_sales`). An unsold work moves from the adapter's custody (`ERC721IncorrectOwner`
    ///      if it no longer holds it) to the museum the economics resolver names now (a zero
    ///      museum reverts, `ERC721InvalidReceiver`), with no receiver callback: the museum is the governed account built to hold works, and no
    ///      call leaves Stream. This puts the museum rule (D140, owner decisions 9 and 10) on
    ///      chain for every 1/1 adapter: only a deliberately false SOLD escapes it, which the
    ///      admission review covers (ADR 0005). Stream resolves no creator here: an adapter of
    ///      Stream never delivers an unsold work.
    function settlePrimary(
        uint256 tokenId,
        PrimaryOutcome outcome,
        address buyer,
        address currency,
        uint256 price
    ) external returns (PrimarySettlement memory settlement) {
        (TokenData storage t, Terms memory shared) = _shared(tokenId);
        if (_minters[msg.sender].id != shared.minterId) revert NotMintingAdapter(msg.sender);
        uint8 flags = t.flags;
        if (flags & SETTLED != 0) revert SaleAlreadySettled(tokenId);
        flags |= SETTLED;
        if (outcome == PrimaryOutcome.SOLD) {
            if (buyer == address(0)) revert InvalidSaleOutcome();
            flags |= SALE_SOLD;
            uint256 stored = price < type(uint96).max ? price : type(uint96).max;
            _sales[tokenId] = uint256(uint160(currency)) | (stored << 160);
        } else {
            if (outcome == PrimaryOutcome.NONE || buyer != address(0) || price != 0) {
                revert InvalidSaleOutcome();
            }
            if (outcome == PrimaryOutcome.FROZEN_OUT) flags |= SALE_FROZEN_OUT;
        }
        t.flags = flags;
        emit PrimarySaleSettled(tokenId, outcome, buyer, currency, price);
        if (outcome != PrimaryOutcome.SOLD) {
            address museum = IEconomicsResolver(economics()).museum();
            if (museum == address(0)) revert ERC721InvalidReceiver(museum);
            address from = _update(museum, tokenId, address(0));
            if (from != msg.sender) revert ERC721IncorrectOwner(msg.sender, tokenId, from);
            settlement.holder = museum;
        }
        settlement.seller = t.seller;
        settlement.feeRecipient = _feeRecipients[shared.feeRecipientId - 1];
        settlement.feeShare = shared.feeShare;
    }

    // ----------------------------------------------------------------- collections and works

    /// @inheritdoc IStream
    /// @dev The name goes into every work's metadata, where a control character, `<`, `"` or
    ///      `\` is escaped to up to six bytes: refusing them keeps `tokenURI` within its gas
    ///      budget (the content README's budget proof).
    function createCollection(string calldata name, bytes32 metadataHash)
        external
        restricted
        returns (uint256 collectionId)
    {
        bytes calldata raw = bytes(name);
        if (raw.length == 0 || raw.length > MAX_NAME_BYTES || !Utf8.isValid(raw)) {
            revert InvalidCollectionName();
        }
        for (uint256 i; i < raw.length; ++i) {
            bytes1 b = raw[i];
            if (b < 0x20 || b == 0x7f || b == "<" || b == '"' || b == "\\") {
                revert InvalidCollectionName();
            }
        }
        collectionId = ++_counts.collections;
        CollectionData storage c = _collections[collectionId];
        c.exists = true;
        c.metadataHash = metadataHash;
        c.name = name;
        emit CollectionCreated(collectionId, name, metadataHash);
    }

    /// @inheritdoc IStream
    function collection(uint256 collectionId) external view returns (Collection memory) {
        CollectionData storage c = _collections[collectionId];
        if (!c.exists) revert UnknownCollection(collectionId);
        return Collection(c.name, c.metadataHash, c.minted);
    }

    /// @inheritdoc IStream
    function collectionCount() external view returns (uint256) {
        return _counts.collections;
    }

    /// @inheritdoc IStream
    function totalMinted() external view returns (uint256) {
        return _counts.minted;
    }

    /// @inheritdoc IStream
    function totalSupply() external view returns (uint256) {
        return _counts.minted - _counts.burned;
    }

    /// @inheritdoc IStream
    function work(uint256 tokenId) external view returns (WorkCore memory) {
        (TokenData storage t, Terms memory shared) = _shared(tokenId);
        uint8 flags = t.flags;
        return WorkCore(
            t.itemHash,
            shared.artistId,
            t.collectionId,
            t.serial,
            _kind(flags),
            _seedPolicy(flags),
            t.seller,
            _royaltyReceiver(t.seller, shared),
            shared.royaltyRate
        );
    }

    /// @inheritdoc IStream
    function coreOf(uint256 tokenId)
        external
        view
        returns (
            bytes32 itemHash,
            uint256 artistId,
            uint256 collectionId,
            ItemKind kind,
            SeedPolicy seedPolicy,
            uint32 royaltyRate
        )
    {
        (TokenData storage t, Terms memory shared) = _shared(tokenId);
        uint8 flags = t.flags;
        return (
            t.itemHash,
            shared.artistId,
            t.collectionId,
            _kind(flags),
            _seedPolicy(flags),
            shared.royaltyRate
        );
    }

    /// @inheritdoc IStream
    function artistOf(uint256 tokenId) external view returns (uint256) {
        (, Terms memory shared) = _shared(tokenId);
        return shared.artistId;
    }

    /// @inheritdoc IStream
    function primarySaleSettled(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0) && _tokens[tokenId].flags & SETTLED != 0;
    }

    /// @inheritdoc IStream
    /// @dev A settled token is never burned (`burn` refuses it), so its flags decide.
    function primarySale(uint256 tokenId)
        external
        view
        returns (PrimaryOutcome outcome, address currency, uint256 price)
    {
        uint8 flags = _tokens[tokenId].flags;
        if (flags & SETTLED == 0) return (PrimaryOutcome.NONE, address(0), 0);
        if (flags & SALE_SOLD == 0) {
            outcome =
                flags & SALE_FROZEN_OUT != 0 ? PrimaryOutcome.FROZEN_OUT : PrimaryOutcome.UNBID;
            return (outcome, address(0), 0);
        }
        uint256 sale = _sales[tokenId];
        return (PrimaryOutcome.SOLD, address(uint160(sale)), sale >> 160);
    }

    /// @inheritdoc IERC2981
    /// @dev `rate <= 100,000` (checked when stored), so `(p / D) * rate + (p % D) * rate / D` is
    ///      exactly `floor(p * rate / D)` and cannot overflow for any `salePrice` (RC1's
    ///      overflow-free form).
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        (TokenData storage t, Terms memory shared) = _shared(tokenId);
        receiver = _royaltyReceiver(t.seller, shared);
        uint256 rate = shared.royaltyRate;
        unchecked {
            // Exact: the remainder term restores what the first division drops.
            // forge-lint: disable-next-line(divide-before-multiply)
            royaltyAmount = (salePrice / Splits.DENOMINATOR) * rate
                + ((salePrice % Splits.DENOMINATOR) * rate) / Splits.DENOMINATOR;
        }
    }

    // ------------------------------------------------------------------------------- rendering

    /// @inheritdoc IStream
    function setDefaultRenderer(address expected, address next, bytes32 nextCodeHash)
        external
        restricted
    {
        if (defaultRenderer != expected) revert ExpectedValueMismatch();
        Dependency.checkPinned(next, type(IRenderer).interfaceId, nextCodeHash);
        defaultRenderer = next;
        _defaultRendererCodeHash = nextCodeHash;
        emit DefaultRendererSet(expected, next, nextCodeHash);
        uint256 minted = _counts.minted;
        if (minted != 0) emit BatchMetadataUpdate(1, minted);
        address bound = editions;
        if (bound != address(0)) IEditions(bound).notifyAllUpdated();
    }

    /// @inheritdoc IStream
    /// @dev The default renderer's code must still be the code it was installed with (DEPS-6):
    ///      a pin checked once could be outlived by code recreated at the same address. A work's
    ///      own pin is checked the same way by `IWorkRecords.pinnedRenderer` (WS-16).
    function rendererOf(uint256 tokenId) public view returns (address renderer) {
        _live(tokenId);
        address records = workRecords;
        if (records != address(0)) renderer = _pinnedRenderer(records, tokenId);
        if (renderer == address(0)) {
            renderer = defaultRenderer;
            Dependency.checkUnchanged(renderer, _defaultRendererCodeHash);
        }
    }

    /// @notice The token's metadata, built by its pinned renderer once finalized, else by the
    ///         default renderer. Reverts with `UnknownWork` for a burned or unminted token.
    /// @param tokenId A live token ID.
    /// @return The metadata URI the renderer builds (`IRenderer.tokenURI`).
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return IRenderer(rendererOf(tokenId)).tokenURI(address(this), tokenId);
    }

    // ---------------------------------------------------------------------------- dependencies

    /// @inheritdoc IStream
    function packageRegistry() public view returns (address) {
        return _dependency(0, _genesisPackageRegistry);
    }

    /// @inheritdoc IStream
    function artistRegistry() public view returns (address) {
        return _dependency(1, _genesisArtistRegistry);
    }

    /// @inheritdoc IStream
    function economics() public view returns (address) {
        return _dependency(2, _genesisEconomics);
    }

    /// @inheritdoc IStream
    function entropyModule() public view returns (address) {
        return _dependency(3, _genesisEntropyModule);
    }

    /// @inheritdoc IStream
    /// @dev SUCCESSOR_SETTER role (the 30-day class). The entropy module may be installed on a
    ///      Stream deployed without one, but never removed: a VRF work's record reads its seed
    ///      from it. A replacement is stored and its `Counts.replaced` bit set; putting the
    ///      genesis contract back is a replacement like any other.
    function setDependency(bytes32 kind, address expected, address next) external restricted {
        (uint8 index, bytes4 interfaceId, address current) = _dependencyOf(kind);
        if (current != expected) revert ExpectedValueMismatch();
        Dependency.check(next, interfaceId);
        _replaced[index] = next;
        _counts.replaced |= uint8(1) << index;
        emit DependencySet(kind, expected, next);
    }

    // ------------------------------------------------------------------------ satellite hooks

    /// @inheritdoc IStream
    /// @dev The target must serve this token (`stream() == address(this)`): the bind is
    ///      one-shot, so a satellite of another deployment could never be replaced.
    function bindWorkRecords(address target) external restricted {
        if (workRecords != address(0)) revert AlreadyBound(WORK_RECORDS);
        Dependency.check(target, type(IWorkRecords).interfaceId);
        if (IWorkRecords(target).stream() != address(this)) revert InvalidBinding(target);
        workRecords = target;
        emit Bound(WORK_RECORDS, target);
    }

    /// @inheritdoc IStream
    /// @dev The target must serve this token (`stream() == address(this)`), as for
    ///      `bindWorkRecords`.
    function bindEditions(address target) external restricted {
        if (editions != address(0)) revert AlreadyBound(EDITIONS);
        Dependency.check(target, type(IEditions).interfaceId);
        if (IEditions(target).stream() != address(this)) revert InvalidBinding(target);
        editions = target;
        emit Bound(EDITIONS, target);
    }

    /// @inheritdoc IStream
    /// @dev The payees (and so the receiver) are fixed at mint; only the rate changes (D19). The
    ///      token moves to the terms that differ from its own only by the rate, interned if new.
    function setRoyaltyRate(uint256 tokenId, uint32 rate) external {
        _onlyBound(workRecords);
        (TokenData storage t, Terms memory shared) = _shared(tokenId);
        if (rate > Splits.DENOMINATOR) revert InvalidRoyaltyRate(rate);
        emit RoyaltyRateChanged(tokenId, shared.royaltyRate, rate);
        shared.royaltyRate = rate;
        t.termsId = _termsId(shared);
    }

    /// @inheritdoc IStream
    function emitMetadataUpdate(uint256 fromTokenId, uint256 toTokenId) external {
        _onlyBound(workRecords);
        if (fromTokenId == toTokenId) emit MetadataUpdate(fromTokenId);
        else emit BatchMetadataUpdate(fromTokenId, toTokenId);
    }

    /// @inheritdoc IStream
    /// @dev Written once and never changed; the edition ID must equal the token ID, and the
    ///      master's primary sale must have settled (D14, checked here as well as in Editions).
    function linkEdition(uint256 tokenId, uint256 editionId) external {
        _onlyBound(editions);
        TokenData storage t = _live(tokenId);
        uint8 flags = t.flags;
        if (
            flags & KIND_MASTER == 0 || flags & SETTLED == 0 || flags & LINKED != 0
                || editionId != tokenId
        ) revert EditionLinkInvalid(tokenId);
        t.flags = flags | LINKED;
        emit EditionLinked(tokenId, msg.sender, editionId);
        emit MetadataUpdate(tokenId);
    }

    /// @inheritdoc IStream
    function editionOf(uint256 tokenId)
        external
        view
        returns (address editionsContract, uint256 editionId)
    {
        if (_tokens[tokenId].flags & LINKED != 0) return (editions, tokenId);
    }

    // --------------------------------------------------------------------- marketplace metadata

    /// @inheritdoc IStream
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @inheritdoc IStream
    function setContractURI(string calldata uri) external restricted {
        emit ContractURISet(_contractURI, uri);
        _contractURI = uri;
        emit ContractURIUpdated();
    }

    /// @inheritdoc IStream
    function owner() external view returns (address) {
        return _owner;
    }

    /// @inheritdoc IStream
    function setOwner(address expected, address next) external restricted {
        if (_owner != expected) revert ExpectedValueMismatch();
        _owner = next;
        emit OwnershipTransferred(expected, next);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, IERC165)
        returns (bool)
    {
        return interfaceId == bytes4(0x49064906) || interfaceId == type(IERC2981).interfaceId
            || interfaceId == type(IMintTarget).interfaceId
            || interfaceId == type(IStream).interfaceId || super.supportsInterface(interfaceId);
    }

    // -------------------------------------------------------------------------------- internal

    /// @dev Views `data` as `abi.encode(StreamMintRequest)` in place. Member offsets are
    ///      bounds-checked by the compiler on access.
    function _request(bytes calldata data) private pure returns (StreamMintRequest calldata req) {
        if (data.length < 160 || uint256(bytes32(data[:32])) != 32) revert InvalidMintRequest();
        assembly ("memory-safe") {
            req := add(data.offset, 32)
        }
    }

    /// @dev The work's pin in the records satellite, or zero for the default renderer. The
    ///      satellite gets exactly {RECORDS_GAS} (a caller with too little gas to forward it
    ///      reverts, so the answer never depends on the caller's gas) and at most one word is
    ///      copied back. Any fault falls back to the default renderer: a revert (a record not
    ///      yet open reverts with `RecordNotOpen` by design), running out of gas, or an answer
    ///      that is not one word holding an address with code. A fault in the satellite can then
    ///      never take every work's metadata down with it. The one revert passed on is
    ///      `DependencyCodeChanged`, a finalized work's pinned renderer whose code changed,
    ///      which fails closed (WS-16).
    function _pinnedRenderer(address records, uint256 tokenId)
        private
        view
        returns (address renderer)
    {
        if (!BoundedCall.hasSufficientGas(gasleft(), RECORDS_GAS, BoundedCall.CALL_RESERVE)) {
            revert BoundedCall.BoundedCallInsufficientGas(RECORDS_GAS);
        }
        bytes4 selector = IWorkRecords.pinnedRenderer.selector;
        bytes4 codeChanged = Dependency.DependencyCodeChanged.selector;
        uint256 gasLimit = RECORDS_GAS;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), tokenId)
            let ok := staticcall(gasLimit, records, ptr, 0x24, 0, 0x20)
            let size := returndatasize()
            switch ok
            case 1 {
                let word := mload(0)
                if and(eq(size, 0x20), iszero(shr(160, word))) { renderer := word }
            }
            default {
                if eq(size, 0x24) {
                    returndatacopy(ptr, 0, 0x24)
                    if eq(shr(224, mload(ptr)), shr(224, codeChanged)) { revert(ptr, 0x24) }
                }
            }
        }
        if (renderer != address(0) && renderer.code.length == 0) renderer = address(0);
    }

    /// @dev The `Counts.replaced` bit index, the ERC-165 interface and the current address of
    ///      the dependency `kind` names (`UnknownDependency` for any other).
    function _dependencyOf(bytes32 kind) private view returns (uint8, bytes4, address) {
        if (kind == PACKAGE_REGISTRY) {
            return (0, type(IPackageRegistry).interfaceId, packageRegistry());
        }
        if (kind == ARTIST_REGISTRY) {
            return (1, type(IArtistRegistry).interfaceId, artistRegistry());
        }
        if (kind == ECONOMICS) return (2, type(IEconomicsResolver).interfaceId, economics());
        if (kind == ENTROPY_MODULE) return (3, type(IEntropyModule).interfaceId, entropyModule());
        revert UnknownDependency(kind);
    }

    /// @dev Dependency `index`: its replacement once governance set one, else `genesis`.
    function _dependency(uint8 index, address genesis) private view returns (address) {
        return (_counts.replaced & (uint8(1) << index)) == 0 ? genesis : _replaced[index];
    }

    /// @dev Forwards the request to `IPackageRegistry.consume` without re-encoding it: the tuple
    ///      after the leading offset word of `abi.encode(StreamMintRequest)` is exactly the ABI
    ///      encoding of `consume`'s four arguments, so the registry decodes the same values this
    ///      contract read through `_request`.
    function _consume(bytes calldata data) private returns (bytes32 itemHash, uint256 artistId) {
        (bool ok, bytes memory result) =
            packageRegistry().call(bytes.concat(IPackageRegistry.consume.selector, data[32:]));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        if (result.length != 64) revert InvalidMintRequest();
        (itemHash, artistId) = abi.decode(result, (bytes32, uint256));
        // The registry never returns zero; an artist ID is an address-sized value (D1).
        if (artistId == 0 || artistId > type(uint160).max) revert InvalidMintRequest();
    }

    /// @dev Stream rules the registry does not know: a sale kind (whose adapter checks the
    ///      sale's currency and params), a lead party, an existing collection, a coherent seed
    ///      policy, and a license ID that follows
    ///      the `SpdxId` rule `WorkRecords` applies at relicense. `openRecord` stores the
    ///      approved record file and license as they are; the media commitments it checks (at
    ///      most 32 files, the primary first with the item's content hash) are not visible
    ///      here, so the curation signer's tooling must simulate `openRecord` before attesting
    ///      an item.
    function _checkItem(PackageItem calldata item) private view {
        if (item.sale.saleKind == 0) revert InvalidItemSale();
        if (item.parties.length == 0) revert InvalidLeadArtist();
        if (!_collections[item.collectionId].exists) revert UnknownCollection(item.collectionId);
        SeedPolicy policy = item.seedPolicy;
        if (
            (policy == SeedPolicy.ARTIST) != (item.seed != 0)
                || (policy == SeedPolicy.VRF && entropyModule() == address(0))
        ) revert InvalidSeedPolicy();
        if (!SpdxId.isValidCalldata(item.license.spdxId)) revert InvalidLicenseId();
    }

    /// @dev The terms a work of `item` locks now, and the primary terms the adapter applies:
    ///      the product's economics (one view read) and the seller wallet, the split factory's
    ///      salt-zero wallet for the item's payees (the factory validates the list). This is
    ///      `IEconomicsResolver.newWorkTerms` without its royalty-receiver derivation, which
    ///      Stream does lazily in `royaltyInfo` (`_royaltyReceiver`, the same address). The fee
    ///      terms must yield a valid royalty payee list: a fee share below 100,000 with a fee
    ///      recipient other than the seller, or no fee at all. `w.royaltyReceiver` is unset.
    function _quote(PackageItem calldata item, uint256 artistId)
        private
        view
        returns (PrimaryTerms memory terms, WorkTerms memory w)
    {
        ProductEconomics memory e = IEconomicsResolver(economics()).economics(PRODUCT_STREAM);
        address seller = ISplitFactory(splitFactory).walletFor(item.payees, bytes32(0));
        if (
            e.royaltyRate > Splits.DENOMINATOR || e.feeShare >= Splits.DENOMINATOR
                || (e.feeShare != 0 && (e.feeRecipient == address(0) || e.feeRecipient == seller))
        ) revert InvalidWorkTerms();
        w = WorkTerms(seller, e.feeRecipient, e.feeShare, address(0), e.royaltyRate);
        terms.saleKind = item.sale.saleKind;
        // The adapter resolves `CURRENCY_DEFAULT` and checks the allowlist when it locks the
        // currency (`PrimaryTerms`); an auction's price is zero, so the default is allowed. It
        // also checks the params (the English auction refuses any).
        terms.currency = item.sale.currency;
        terms.params = item.sale.params;
        terms.seller = w.seller;
        terms.feeRecipient = w.feeRecipient;
        terms.feeShare = w.feeShare;
        terms.creator = IArtistRegistry(artistRegistry()).activeAuthorityOf(artistId);
    }

    /// @dev Assigns the next token ID and collection serial and writes the two work words.
    function _store(
        StreamMintRequest calldata req,
        bytes32 itemHash,
        uint256 artistId,
        address seller,
        uint24 termsId
    ) private returns (uint256 tokenId) {
        PackageItem calldata item = req.item;
        tokenId = ++_counts.minted;
        uint32 serial = ++_collections[item.collectionId].minted;
        TokenData storage t = _tokens[tokenId];
        t.seller = seller;
        t.serial = serial;
        // The collection exists, so its ID is at most the uint32 collection counter.
        // forge-lint: disable-next-line(unsafe-typecast)
        t.collectionId = uint32(item.collectionId);
        t.flags = (item.kind == ItemKind.EDITION_MASTER ? KIND_MASTER : 0)
            | (uint8(item.seedPolicy) << SEED_SHIFT);
        t.termsId = termsId;
        t.itemHash = itemHash;
        emit WorkMinted(
            tokenId,
            item.collectionId,
            itemHash,
            serial,
            artistId,
            item.kind,
            req.packageRoot,
            item.contentHash,
            item.mediaHash,
            item.recordFileId
        );
    }

    /// @dev The index (from 1) of a fee recipient, registered on first use. A new network fee
    ///      recipient needs a governed economics change, so there are few; the checked counter
    ///      reverts past 65,535.
    function _feeRecipientId(address recipient) private returns (uint16 id) {
        id = _feeRecipientIds[recipient];
        if (id == 0) {
            _feeRecipients.push(recipient);
            id = uint16(_feeRecipients.length);
            if (id != _feeRecipients.length) revert TermsCapacityExceeded();
            _feeRecipientIds[recipient] = id;
        }
    }

    /// @dev The seller with no fee; otherwise the split factory's salt-zero wallet for
    ///      `Splits.royaltyPayees`, the canonical list the economics resolver derives the same
    ///      receiver from (fixed payees in address order).
    function _royaltyReceiver(address seller, Terms memory shared) private view returns (address) {
        uint32 feeShare = shared.feeShare;
        if (feeShare == 0) return seller;
        return ISplitFactory(splitFactory)
            .walletFor(
                Splits.royaltyPayees(seller, _feeRecipients[shared.feeRecipientId - 1], feeShare),
                bytes32(0)
            );
    }

    /// @dev The ID of `t`, interned on first use (QUALITY-6). `t` lives at the position its hash
    ///      names, below `OVERFLOW`; if other terms already hold that position, in the overflow
    ///      range, found again by the full hash. So works under existing terms write no terms
    ///      word, new terms write one (two in the rare overflow), and nothing loops.
    function _termsId(Terms memory t) private returns (uint24 id) {
        bytes32 key = _key(t);
        id = uint24(uint256(key)) & HASHED;
        Terms memory held = _terms[id];
        if (held.artistId == 0) {
            _terms[id] = t;
            return id;
        }
        if (_key(held) == key) return id;
        id = _overflowIds[key];
        if (id == 0) {
            // The overflow range holds 2^23 - 1 terms: the check reverts at the 2^23rd.
            uint24 n = ++_counts.overflowTerms;
            if (n > HASHED) revert TermsCapacityExceeded();
            id = OVERFLOW | n;
            _terms[id] = t;
            _overflowIds[key] = id;
        }
    }

    function _key(Terms memory t) private pure returns (bytes32) {
        return keccak256(abi.encode(t));
    }

    /// @dev A live token and the terms it shares.
    function _shared(uint256 tokenId)
        private
        view
        returns (TokenData storage t, Terms memory shared)
    {
        t = _live(tokenId);
        shared = _terms[t.termsId];
    }

    function _kind(uint8 flags) private pure returns (ItemKind) {
        return flags & KIND_MASTER != 0 ? ItemKind.EDITION_MASTER : ItemKind.ORIGINAL;
    }

    function _seedPolicy(uint8 flags) private pure returns (SeedPolicy) {
        return SeedPolicy((flags >> SEED_SHIFT) & SEED_MASK);
    }

    function _onlyBound(address bound) private view {
        if (msg.sender != bound || bound == address(0)) revert UnboundCaller(msg.sender);
    }

    /// @dev A live token: minted and not burned.
    function _live(uint256 tokenId) private view returns (TokenData storage) {
        if (_ownerOf(tokenId) == address(0)) revert UnknownWork(tokenId);
        return _tokens[tokenId];
    }
}
