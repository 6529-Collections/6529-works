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
import { IMintPolicy } from "../interfaces/IMintPolicy.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IStreamViews } from "../interfaces/IStreamViews.sol";
import { IStreamExtension } from "../interfaces/IStreamExtension.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";
import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { Splits } from "../economics/Splits.sol";
import { PrimaryOutcome, PrimarySettlement, PrimaryTerms } from "../interfaces/types/SaleTypes.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { StreamViews } from "./StreamViews.sol";

/// @title Stream
/// @notice 6529 Stream core: the one shared, network-curated ERC-721 holding every curated 1/1
///         (ADR 0001 sections 1, 4, 7 and 12; integrator decisions D1, D3, D4, D6, D13 and
///         E1-E11).
/// @dev The permanent core. It holds ownership, the terms locked at mint, collections and serials,
///      the edition link and the marketplace metadata, the custody state machine (settle, burn,
///      rescue, museum routing) and the views other contracts authorize by. It takes no
///      instruction from replaceable code about existing tokens.
///
///      What to mint is decided by one replaceable mint policy (`IMintPolicy`, in v1 the package
///      registry, on the call a mint made to it anyway): `mint` hands it the adapter's request
///      unread, with Stream's current dependencies, and the policy checks consent, the item
///      rules, the economics and the entropy and answers with a record. Stream then checks its
///      own invariants on that record (the adapter's recorded sale kind, a nonzero item hash, lead
///      artist and seller, bounded economics, an existing collection, kind and seed policy within
///      their stored width), interns the terms and mints into the adapter's custody. The policy
///      has no write function into Stream. Informational views and collection-name rules are
///      served by a read-only extension reached through the fallback by STATICCALL.
///
///      Storage is shaped by the auction-start budget (ADR 0004): 350K Prague gas and at most 6
///      new slots, 7 with a bid, per steady-state start. A mint writes the ERC-721 owner and
///      balance, one shared counter word, the collection's counter word and two work words: the
///      seller, serial, collection, flags and terms ID; the item hash. The terms (the lead artist
///      ID, royalty rate, fee share, fee-recipient index and minting adapter's index) are one
///      word shared by every work with the same terms, written by the first of them (QUALITY-6),
///      so a start under existing terms writes one word fewer. On a collision of the terms'
///      23-bit hashed position a first start writes one more, the overflow word and its index (an
///      accepted limitation, ADR 0004). The ERC-2981 receiver is derived, not stored: the seller
///      itself when the fee share is zero, otherwise the split factory's salt-zero wallet for the
///      canonical payee list `(feeRecipient: feeShare, seller: rest)`.
///
///      Trust: the artist registry and the split factory are fixed at deployment. The mint
///      policy, the economics resolver, the entropy module and the view extension are
///      replaceable one by one by governance (`setDependency`, the 30-day class); a replacement
///      changes nothing about an existing work (its terms, its seed's module, its renderer pin).
///      The records satellite and 6529 Stream Editions are bound once each. No delegatecall.
contract Stream is ERC721, AccessManaged, IStream {
    /// @notice The shortest rescue delay there can ever be: a removed sale adapter always has at
    ///         least 90 days to settle its works before governance may move them to the museum
    ///         (`rescueToMuseum`, owner decision 20). The number is the guarantee; the delay in
    ///         force (`rescueDelay`) can only grow from it.
    uint256 public constant RESCUE_DELAY_FLOOR = 90 days;

    bytes32 private constant WORK_RECORDS = "WORK_RECORDS";
    bytes32 private constant EDITIONS = "EDITIONS";
    /// @dev The dependencies governance may replace (`setDependency`, owner decision 16), by
    ///      their `Counts.replaced` bit index: 0 the mint policy, 1 the economics resolver, 2 the
    ///      entropy module, 3 the view extension.
    bytes32 private constant PACKAGE_REGISTRY = "PACKAGE_REGISTRY";
    bytes32 private constant ECONOMICS = "ECONOMICS";
    bytes32 private constant ENTROPY_MODULE = "ENTROPY_MODULE";
    bytes32 private constant EXTENSION = "EXTENSION";

    /// @dev `TokenData.flags`: the item kind (bits 0-1) and seed policy (bits 2-3), stored as
    ///      the policy reported them (opaque to the core, up to 3 each); then the primary sale
    ///      settled, the edition linked, and how the sale settled (owner decision 17): sold,
    ///      frozen out, neither, unbid, or both, rescued (owner decision 28).
    uint8 private constant FIELD_MASK = 3;
    uint8 private constant SEED_SHIFT = 2;
    uint8 private constant KIND_EDITION_MASTER = 1;
    uint8 private constant SETTLED = 16;
    uint8 private constant LINKED = 32;
    uint8 private constant SALE_SOLD = 64;
    uint8 private constant SALE_FROZEN_OUT = 128;
    /// @dev Terms IDs below `OVERFLOW` are the hashed positions; from it, the overflow range.
    uint24 private constant HASHED = 0x7fffff;
    uint24 private constant OVERFLOW = 0x800000;
    /// @dev The most revert data `rendererOf` passes on from the records satellite (a safety
    ///      bound on copying, not a gas number; a longer revert is passed on empty).
    uint256 private constant PIN_REVERT_BYTES = 256;

    /// @dev A token's two words (QUALITY-6). `termsId` names the token's `Terms` in `_terms`.
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
    ///      from 1, and `artistId` is never zero, so a zero word is an empty position. Rates are
    ///      out of 100,000, so 24 bits hold them.
    struct Terms {
        uint160 artistId;
        uint24 royaltyRate;
        uint24 feeShare;
        uint24 feeRecipientId;
        uint24 minterId;
    }

    /// @dev `id` is assigned on first admission and kept, so a removed adapter still settles
    ///      the sales it started. Its sale kind is recorded then too: in full in `_minterKinds`
    ///      and as `kindKey` (`_kindKey`, 152 bits of its hash) in this word, which `mint` reads
    ///      anyway. `removedAt` is when governance removed the adapter, zero while admitted, and
    ///      `rescueDelay` the rescue delay in force then, locked for that removal's works.
    struct Minter {
        bool admitted;
        uint24 id;
        uint40 removedAt;
        uint32 rescueDelay;
        uint152 kindKey;
    }

    /// @dev `exists` keeps the counter word nonzero, so each mint pays a warm rewrite.
    struct CollectionData {
        bool exists;
        uint32 minted;
        bytes32 metadataHash;
        string name;
    }

    /// @dev `replaced` has bit `i` set once governance replaced dependency `i`: every mint reads
    ///      this word anyway, so a dependency still at its genesis value costs a mint no slot.
    struct Counts {
        uint64 minted;
        uint64 burned;
        uint32 collections;
        uint24 minters;
        uint24 overflowTerms;
        uint8 replaced;
        uint32 rescueDelay;
    }

    /// @notice The split factory that derives seller and royalty wallets (the first economics
    ///         resolver's). Immutable: every wallet ever derived stays valid.
    address public immutable splitFactory;
    /// @inheritdoc IStream
    address public immutable artistRegistry;
    /// @dev The genesis dependencies, what `_dependency` returns until `setDependency` replaces
    ///      one (owner decision 16).
    address private immutable _genesisPolicy;
    address private immutable _genesisEconomics;
    address private immutable _genesisEntropyModule;
    address private immutable _genesisExtension;

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
    mapping(address recipient => uint24 id) private _feeRecipientIds;
    mapping(address adapter => Minter) private _minters;
    mapping(uint256 collectionId => CollectionData) private _collections;
    mapping(uint256 tokenId => TokenData) private _tokens;
    /// @dev Interned terms (QUALITY-6), at the position their hash names or in the overflow range.
    mapping(uint24 termsId => Terms) private _terms;
    mapping(bytes32 termsHash => uint24 termsId) private _overflowIds;
    /// @dev Each admitted adapter's sale kind, by its ID.
    mapping(uint24 minterId => bytes32 saleKind) private _minterKinds;
    /// @dev The dependencies governance replaced, by `Counts.replaced` bit index; read only while
    ///      that bit is set.
    address[4] private _replaced;
    /// @dev Each entropy module governance replaced, oldest first, packed with the last token ID
    ///      minted while it was current (`lastTokenId << 160 | module`): a work's VRF seed is the
    ///      one its mint checked, so `entropyModuleOf` answers each work with that module.
    uint256[] private _entropyEras;
    /// @dev A sold work's currency (the low 160 bits) and price (the high 96, saturated): one
    ///      word, written only for SOLD (owner decision 17).
    mapping(uint256 tokenId => uint256 sale) private _sales;

    /// @param authority_ The AccessManager governing this contract.
    /// @param policy_ The mint policy (the package registry), which must use `artistRegistry_`.
    /// @param artistRegistry_ The artist registry, fixed for good.
    /// @param economics_ The economics resolver; its split factory derives every wallet.
    /// @param entropyModule_ The VRF entropy module, or zero if VRF works are not supported.
    /// @param renderer_ The initial default renderer.
    /// @param rendererCodeHash The code hash `renderer_` must have.
    /// @param owner_ The initial marketplace owner.
    constructor(
        address authority_,
        address policy_,
        address artistRegistry_,
        address economics_,
        address entropyModule_,
        address renderer_,
        bytes32 rendererCodeHash,
        address owner_
    ) ERC721("6529 Stream", "STREAM") AccessManaged(authority_) {
        Dependency.check(policy_, type(IMintPolicy).interfaceId);
        Dependency.check(artistRegistry_, type(IArtistRegistry).interfaceId);
        if (IMintPolicy(policy_).artistRegistry() != artistRegistry_) {
            revert InvalidBinding(policy_);
        }
        Dependency.check(economics_, type(IEconomicsResolver).interfaceId);
        if (entropyModule_ != address(0)) {
            Dependency.check(entropyModule_, type(IEntropyModule).interfaceId);
        }
        Dependency.checkPinned(renderer_, type(IRenderer).interfaceId, rendererCodeHash);
        address factory = IEconomicsResolver(economics_).splitFactory();
        Dependency.check(factory);
        _genesisPolicy = policy_;
        artistRegistry = artistRegistry_;
        _genesisEconomics = economics_;
        _genesisEntropyModule = entropyModule_;
        _genesisExtension = address(new StreamViews());
        splitFactory = factory;
        defaultRenderer = renderer_;
        _defaultRendererCodeHash = rendererCodeHash;
        _owner = owner_;
        emit DefaultRendererSet(address(0), renderer_, rendererCodeHash);
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @notice Serves every selector Stream does not implement from the read-only extension, by
    ///         STATICCALL: the extension can write nothing, and a native selector never reaches
    ///         it. Its answer, or its revert, is passed on as it is.
    fallback() external {
        address extension = _dependency(3, _genesisExtension);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := staticcall(gas(), extension, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    // ------------------------------------------------------------------------------- minting

    /// @inheritdoc IMintTarget
    /// @dev Admitted minters only. The adapter mints into its own custody (`to == msg.sender`)
    ///      and passes `id = 0`, `amount = 1` and the request `data`, which only the mint policy
    ///      reads (v1: `abi.encode(StreamMintRequest)`). The policy consumes the item and answers
    ///      with the work and its terms; this contract checks that the item's sale kind is the
    ///      adapter's, as recorded at its first admission (`SaleKindMismatch`), checks its own
    ///      invariants (`_checked`), and assigns the next token ID and collection serial.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        Minter memory minter = _minters[msg.sender];
        if (!minter.admitted) revert NotAdmittedMinter(msg.sender);
        if (to != msg.sender || id != 0 || amount != 1) revert InvalidMintRequest();
        (address policy, IMintPolicy.MintContext memory context) = _context(msg.sender);
        IMintPolicy.MintRecord memory r = _authorize(policy, context, data);
        if (minter.kindKey != _kindKey(r.saleKind)) {
            revert SaleKindMismatch(r.saleKind, _minterKinds[minter.id]);
        }
        tokenId = _store(r, _termsId(_checked(r, minter.id)));
        _mint(to, tokenId);
        terms = PrimaryTerms(
            r.saleKind, r.currency, 0, r.params, r.seller, r.feeRecipient, r.feeShare, r.creator
        );
    }

    /// @inheritdoc IMintTarget
    /// @dev For a minted token, only the sale kind (the minting adapter's), seller, fee terms
    ///      and the creator (the lead artist's active authority, resolved now: zero while a
    ///      recovery override is pending). For `id` 0, the mint policy's preview of `data`.
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
            terms.creator = IArtistRegistry(artistRegistry).activeAuthorityOf(shared.artistId);
            return terms;
        }
        (address policy, IMintPolicy.MintContext memory context) = _context(msg.sender);
        return IMintPolicy(policy).preview(context, data);
    }

    /// @inheritdoc IMintTarget
    /// @dev Only the adapter that minted the token, while it still holds it in custody and
    ///      before the primary sale settled: the auction's cancel after an upheld dispute
    ///      (ADR 0001 section 12). Gated on the minting adapter's index, not on current
    ///      admission. After a sale nothing is confiscated. The ID is never reused.
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
    /// @dev PARAMETER_SETTER role, 48 hours: the upheld-dispute class of the auction's `cancel`.
    ///      The release is recorded by the permanent token (`ContentReleased`) as well as by the
    ///      registry.
    function releaseContent(uint256 tokenId, bytes32 contentHash, uint256 beneficiary)
        external
        restricted
    {
        if (tokenId == 0 || tokenId > _counts.minted || _ownerOf(tokenId) != address(0)) {
            revert NotBurned(tokenId);
        }
        IPackageRegistry(packageRegistry())
            .releaseContent(contentHash, _tokens[tokenId].itemHash, beneficiary);
        emit ContentReleased(tokenId, contentHash, beneficiary);
    }

    /// @inheritdoc IMintTarget
    function isAdmittedMinter(address adapter) external view returns (bool) {
        return _minters[adapter].admitted;
    }

    /// @inheritdoc IMintTarget
    /// @dev SUCCESSOR_SETTER role (the 30-day class). Admission checks code, ERC-165 for
    ///      `ISaleAdapter`, no EIP-7702 delegation and a nonzero sale kind, which the first
    ///      admission records with the adapter's index. Removal stops new mints only: the adapter
    ///      keeps its index, so it can still settle and cancel the sales it started. Only real
    ///      transitions are accepted (owner decision 28, `AdmissionUnchanged`).
    function setAdmittedMinter(address adapter, bool admitted) external restricted {
        Minter storage minter = _minters[adapter];
        if (admitted == minter.admitted) revert AdmissionUnchanged(adapter, admitted);
        if (admitted) {
            Dependency.check(adapter, type(ISaleAdapter).interfaceId);
            if (minter.id == 0) {
                bytes32 kind = ISaleAdapter(adapter).saleKind();
                if (kind == 0) revert Dependency.InvalidDependency(adapter);
                uint24 id = ++_counts.minters;
                (minter.id, minter.kindKey) = (id, _kindKey(kind));
                _minterKinds[id] = kind;
            }
        }
        (minter.admitted, minter.removedAt) = (admitted, admitted ? 0 : uint40(block.timestamp));
        if (!admitted) minter.rescueDelay = uint32(rescueDelay());
        emit AdmittedMinterSet(adapter, minter.id, admitted, _minterKinds[minter.id]);
    }

    /// @inheritdoc IMintTarget
    /// @dev Gated, like `burn`, on the minting adapter's index, so a removed adapter still
    ///      settles its sales. The outcome is two `TokenData.flags` bits beside `SETTLED`; only
    ///      SOLD writes a new slot (`_sales`). An unsold work moves from the adapter's custody
    ///      to the museum the economics resolver names now, with no receiver callback.
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
            if (
                outcome == PrimaryOutcome.NONE || outcome == PrimaryOutcome.RESCUED
                    || buyer != address(0) || price != 0
            ) revert InvalidSaleOutcome();
            if (outcome == PrimaryOutcome.FROZEN_OUT) flags |= SALE_FROZEN_OUT;
        }
        t.flags = flags;
        emit PrimarySaleSettled(tokenId, outcome, buyer, currency, price);
        if (outcome != PrimaryOutcome.SOLD) {
            address from;
            (settlement.holder, from) = _toMuseum(tokenId);
            if (from != msg.sender) revert ERC721IncorrectOwner(msg.sender, tokenId, from);
        }
        settlement.seller = t.seller;
        settlement.feeRecipient = _feeRecipients[shared.feeRecipientId - 1];
        settlement.feeShare = shared.feeShare;
    }

    /// @inheritdoc IStream
    /// @dev SUCCESSOR_SETTER role (the 30-day class). A work is stranded only while its minting
    ///      adapter holds it unsettled after governance removed that adapter. RESCUED is both
    ///      outcome bits, a combination no adapter can report (owner decision 28).
    function rescueToMuseum(uint256 tokenId) external restricted {
        TokenData storage t = _live(tokenId);
        address adapter = _ownerOf(tokenId);
        Minter storage minter = _minters[adapter];
        uint256 removedAt = minter.removedAt;
        if (
            t.flags & SETTLED != 0 || minter.id != _terms[t.termsId].minterId || removedAt == 0
                || block.timestamp < removedAt + minter.rescueDelay
        ) revert WorkNotRescuable(tokenId);
        t.flags |= SETTLED | SALE_SOLD | SALE_FROZEN_OUT;
        emit PrimarySaleSettled(tokenId, PrimaryOutcome.RESCUED, address(0), address(0), 0);
        (address museum,) = _toMuseum(tokenId);
        emit WorkRescued(tokenId, adapter, museum);
    }

    /// @inheritdoc IStream
    function rescueDelay() public view returns (uint256) {
        uint256 delay = _counts.rescueDelay;
        return delay == 0 ? RESCUE_DELAY_FLOOR : delay;
    }

    /// @inheritdoc IStream
    /// @dev SUCCESSOR_SETTER role (the 30-day class). Lengthen only, and at most double at a
    ///      time (`InvalidRescueDelay`); a removal already made keeps the delay it locked.
    function setRescueDelay(uint256 next) external restricted {
        uint256 current = rescueDelay();
        if (next <= current || next > 2 * current || next > type(uint32).max) {
            revert InvalidRescueDelay(next);
        }
        // Checked above: `next` fits 32 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        _counts.rescueDelay = uint32(next);
        emit RescueDelaySet(current, next);
    }

    /// @dev Moves `tokenId` to the museum the economics resolver names now (a zero museum
    ///      reverts, `ERC721InvalidReceiver`), with no receiver callback; returns the museum and
    ///      the previous holder.
    function _toMuseum(uint256 tokenId) private returns (address museum, address from) {
        museum = IEconomicsResolver(economics()).museum();
        if (museum == address(0)) revert ERC721InvalidReceiver(museum);
        from = _update(museum, tokenId, address(0));
    }

    // ----------------------------------------------------------------- collections and works

    /// @inheritdoc IStream
    /// @dev The name goes into every work's metadata; which names the renderers can carry is the
    ///      view extension's rule (`IStreamExtension.isValidCollectionName`), not the core's.
    function createCollection(string calldata name, bytes32 metadataHash)
        external
        restricted
        returns (uint256 collectionId)
    {
        if (!IStreamExtension(_dependency(3, _genesisExtension)).isValidCollectionName(name)) {
            revert InvalidCollectionName();
        }
        collectionId = ++_counts.collections;
        CollectionData storage c = _collections[collectionId];
        c.exists = true;
        c.metadataHash = metadataHash;
        c.name = name;
        emit CollectionCreated(collectionId, name, metadataHash);
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
    function coreOf(uint256 tokenId)
        external
        view
        returns (
            bytes32 itemHash,
            uint256 artistId,
            uint256 collectionId,
            uint8 kind,
            uint8 seedPolicy,
            uint32 royaltyRate
        )
    {
        (TokenData storage t, Terms memory shared) = _shared(tokenId);
        uint8 flags = t.flags;
        return (
            t.itemHash,
            shared.artistId,
            t.collectionId,
            flags & FIELD_MASK,
            (flags >> SEED_SHIFT) & FIELD_MASK,
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
        if (flags & SALE_FROZEN_OUT != 0) {
            outcome = flags & SALE_SOLD != 0 ? PrimaryOutcome.RESCUED : PrimaryOutcome.FROZEN_OUT;
            return (outcome, address(0), 0);
        }
        if (flags & SALE_SOLD == 0) return (PrimaryOutcome.UNBID, address(0), 0);
        uint256 sale = _sales[tokenId];
        return (PrimaryOutcome.SOLD, address(uint160(sale)), sale >> 160);
    }

    /// @inheritdoc IERC2981
    /// @dev `rate <= 100,000` (checked when stored), so `(p / D) * rate + (p % D) * rate / D` is
    ///      exactly `floor(p * rate / D)` and cannot overflow for any `salePrice`.
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

    /// @inheritdoc IStream
    function extsload(bytes32 slot, uint256 n) external view returns (bytes32[] memory words) {
        words = new bytes32[](n);
        assembly ("memory-safe") {
            let out := add(words, 0x20)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                mstore(add(out, shl(5, i)), sload(add(slot, i)))
            }
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
    /// @dev The default renderer's code must still be the code it was installed with (DEPS-6).
    ///      A work's own pin is checked the same way by `IWorkRecords.pinnedRenderer` (WS-16).
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
        return _dependency(0, _genesisPolicy);
    }

    /// @inheritdoc IStream
    function economics() public view returns (address) {
        return _dependency(1, _genesisEconomics);
    }

    /// @inheritdoc IStream
    function entropyModule() public view returns (address) {
        return _dependency(2, _genesisEntropyModule);
    }

    /// @inheritdoc IStream
    /// @dev Bounded by the number of entropy replacements, each a 30-day governance action.
    function entropyModuleOf(uint256 tokenId) external view returns (address) {
        uint256 eras = _entropyEras.length;
        for (uint256 i; i < eras; ++i) {
            uint256 era = _entropyEras[i];
            if (tokenId <= era >> 160) return address(uint160(era));
        }
        return entropyModule();
    }

    /// @inheritdoc IStream
    /// @dev SUCCESSOR_SETTER role (the 30-day class). The entropy module may be installed on a
    ///      Stream deployed without one, but never removed; replacing it records the module it
    ///      replaces with the last token ID minted so far (`entropyModuleOf`). A replacement
    ///      policy must resolve parties through Stream's own artist registry. A replacement that
    ///      answers `authority()` with one word must name Stream's own AccessManager
    ///      (`InvalidBinding`); the read gets all the gas the call has, and a failure that left
    ///      a shortfall reverts (`BoundedCall.BoundedCallShortfall`), so the check cannot be
    ///      starved away.
    function setDependency(bytes32 kind, address expected, address next) external restricted {
        (uint8 index, bytes4 interfaceId, address current) = _dependencyOf(kind);
        if (current != expected) revert ExpectedValueMismatch();
        Dependency.check(next, interfaceId);
        if (index == 0 && IMintPolicy(next).artistRegistry() != artistRegistry) {
            revert InvalidBinding(next);
        }
        (bool ok, bytes32 word) =
            BoundedCall.tryReadWordAll(next, abi.encodeCall(this.authority, ()));
        if (ok && (uint256(word) >> 160 != 0 || address(uint160(uint256(word))) != authority())) {
            revert InvalidBinding(next);
        }
        if (index == 2) _entropyEras.push(uint256(_counts.minted) << 160 | uint160(current));
        _replaced[index] = next;
        _counts.replaced |= uint8(1) << index;
        emit DependencySet(kind, expected, next);
    }

    // ------------------------------------------------------------------------ satellite hooks

    /// @inheritdoc IStream
    /// @dev The target must serve this token (`stream() == address(this)`).
    function bindWorkRecords(address target) external restricted {
        if (workRecords != address(0)) revert AlreadyBound(WORK_RECORDS);
        Dependency.check(target, type(IWorkRecords).interfaceId);
        if (IWorkRecords(target).stream() != address(this)) revert InvalidBinding(target);
        workRecords = target;
        emit Bound(WORK_RECORDS, target);
    }

    /// @inheritdoc IStream
    /// @dev The target must serve this token (`stream() == address(this)`).
    function bindEditions(address target) external restricted {
        if (editions != address(0)) revert AlreadyBound(EDITIONS);
        Dependency.check(target, type(IEditions).interfaceId);
        if (IEditions(target).stream() != address(this)) revert InvalidBinding(target);
        editions = target;
        emit Bound(EDITIONS, target);
    }

    /// @inheritdoc IStream
    /// @dev The payees (and so the receiver) are fixed at mint; only the rate changes (D19), and
    ///      only downwards, enforced here whatever the satellite checks. The token moves to the
    ///      terms that differ from its own only by the rate, interned if new.
    function setRoyaltyRate(uint256 tokenId, uint32 rate) external {
        _onlyBound(workRecords);
        (TokenData storage t, Terms memory shared) = _shared(tokenId);
        if (rate > shared.royaltyRate) revert InvalidRoyaltyRate(rate);
        emit RoyaltyRateChanged(tokenId, shared.royaltyRate, rate);
        shared.royaltyRate = uint24(rate);
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
            flags & FIELD_MASK != KIND_EDITION_MASTER || flags & SETTLED == 0 || flags & LINKED != 0
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
    function setContractURI(string calldata uri) external restricted {
        emit ContractURISet(_contractURI, uri);
        _contractURI = uri;
        emit ContractURIUpdated();
    }

    /// @inheritdoc IStream
    function setOwner(address expected, address next) external restricted {
        if (_owner != expected) revert ExpectedValueMismatch();
        _owner = next;
        emit OwnershipTransferred(expected, next);
    }

    /// @inheritdoc IERC165
    /// @dev `IStream` is the whole native surface (one id); `IStreamViews` the views the
    ///      extension serves through the fallback (its own id).
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, IERC165)
        returns (bool)
    {
        return interfaceId == bytes4(0x49064906) || interfaceId == type(IERC2981).interfaceId
            || interfaceId == type(IMintTarget).interfaceId
            || interfaceId == type(IStream).interfaceId
            || interfaceId == type(IStreamViews).interfaceId || super.supportsInterface(interfaceId);
    }

    // -------------------------------------------------------------------------------- internal

    /// @dev The mint policy and what a mint tells it, from one read of `Counts.replaced`.
    function _context(address adapter)
        private
        view
        returns (address policy, IMintPolicy.MintContext memory c)
    {
        uint8 replaced = _counts.replaced;
        policy = replaced & 1 == 0 ? _genesisPolicy : _replaced[0];
        c.adapter = adapter;
        c.economics = replaced & 2 == 0 ? _genesisEconomics : _replaced[1];
        c.entropyModule = replaced & 4 == 0 ? _genesisEntropyModule : _replaced[2];
        c.splitFactory = splitFactory;
    }

    /// @dev Calls the policy and reads its answer in place: the flat `MintRecord` encoding (after
    ///      the tuple's offset word) is the record's memory layout, one word per field, with only
    ///      the offset of `params` to rebase. A policy revert is passed on. Every word must be a
    ///      clean value of its field's type and `params` must lie inside the answer
    ///      (`InvalidMintRequest`), so the record is never read out of type.
    function _authorize(address policy, IMintPolicy.MintContext memory context, bytes calldata data)
        private
        returns (IMintPolicy.MintRecord memory r)
    {
        bytes4 selector = IMintPolicy.authorize.selector;
        bytes4 malformed = InvalidMintRequest.selector;
        assembly ("memory-safe") {
            // `authorize(context, data)`, encoded in free memory: the selector, the context's four
            // words, the offset of `data` (0xa0), its length and its bytes, zero-padded.
            let input := mload(0x40)
            mstore(input, selector)
            mstore(add(input, 0x04), mload(context))
            mstore(add(input, 0x24), mload(add(context, 0x20)))
            mstore(add(input, 0x44), mload(add(context, 0x40)))
            mstore(add(input, 0x64), mload(add(context, 0x60)))
            mstore(add(input, 0x84), 0xa0)
            mstore(add(input, 0xa4), data.length)
            let padded := and(add(data.length, 0x1f), not(0x1f))
            mstore(add(input, add(0xa4, padded)), 0)
            calldatacopy(add(input, 0xc4), data.offset, data.length)
            let ok := call(gas(), policy, 0, input, add(0xc4, padded), 0, 0)
            let size := returndatasize()
            // The answer overwrites the input, which is no longer needed.
            r := input
            if iszero(ok) {
                returndatacopy(r, 0, size)
                revert(r, size)
            }
            // The offset word (0x20), 17 head words and the length word of `params`.
            let bad := lt(size, 0x260)
            if iszero(bad) {
                returndatacopy(0, 0, 0x20)
                bad := iszero(eq(mload(0), 0x20))
            }
            let tail := sub(size, 0x20)
            if iszero(bad) {
                returndatacopy(r, 0x20, tail)
                let off := mload(add(r, 0x200))
                bad := or(lt(off, 0x220), gt(add(off, 0x20), tail))
                if iszero(bad) {
                    bad := gt(add(add(off, 0x20), mload(add(r, off))), tail)
                }
                // kind and seed policy (uint8), royalty rate and fee share (uint32), currency,
                // seller, fee recipient and creator (160 bits).
                bad := or(bad, shr(8, or(mload(add(r, 0x60)), mload(add(r, 0x80)))))
                bad := or(bad, shr(32, or(mload(add(r, 0xa0)), mload(add(r, 0x1c0)))))
                bad := or(
                    bad,
                    shr(
                        160,
                        or(
                            or(mload(add(r, 0x160)), mload(add(r, 0x180))),
                            or(mload(add(r, 0x1a0)), mload(add(r, 0x1e0)))
                        )
                    )
                )
                mstore(add(r, 0x200), add(r, off))
            }
            if bad {
                mstore(0, malformed)
                revert(0, 4)
            }
            mstore(0x40, add(r, and(add(tail, 0x1f), not(0x1f))))
        }
    }

    /// @dev The core's invariants on the policy's record, whatever the policy: a nonzero item
    ///      hash, a nonzero lead artist ID that fits 160 bits, kind and seed policy within their
    ///      stored two bits (`InvalidMintRequest`); a nonzero seller, a royalty rate up to 100,000
    ///      and a fee share below it with a fee recipient other than the seller, or no fee
    ///      (`InvalidWorkTerms`). Returns the terms the work shares.
    function _checked(IMintPolicy.MintRecord memory r, uint24 minterId)
        private
        returns (Terms memory)
    {
        if (
            r.itemHash == 0 || r.artistId == 0 || r.artistId > type(uint160).max
                || r.kind > FIELD_MASK || r.seedPolicy > FIELD_MASK
        ) revert InvalidMintRequest();
        if (
            r.seller == address(0) || r.royaltyRate > Splits.DENOMINATOR
                || r.feeShare >= Splits.DENOMINATOR
                || (r.feeShare != 0 && (r.feeRecipient == address(0) || r.feeRecipient == r.seller))
        ) revert InvalidWorkTerms();
        return Terms(
            // Checked above: the artist ID fits 160 bits and both rates fit 24.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint160(r.artistId),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint24(r.royaltyRate),
            // forge-lint: disable-next-line(unsafe-typecast)
            uint24(r.feeShare),
            _feeRecipientId(r.feeRecipient),
            minterId
        );
    }

    /// @dev A sale kind as `Minter.kindKey` holds it: the low 152 bits of its keccak256.
    function _kindKey(bytes32 kind) private pure returns (uint152 key) {
        assembly ("memory-safe") {
            mstore(0, kind)
            key := and(keccak256(0, 0x20), 0xffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @dev The work's pin in the records satellite, or zero for the default renderer. The
    ///      satellite gets all the gas this call has (`BoundedCall.tryReadAll`; a shortfall
    ///      reverts with `BoundedCallShortfall`). Its answer is used only when it is one address
    ///      word (zero: no pin yet) or `RecordNotOpen` (a record not opened yet); any other revert
    ///      is passed on, and a malformed answer reverts with `RendererPinUnreadable`. A finalized work's pinned
    ///      renderer whose code changed reverts with `DependencyCodeChanged` from the satellite
    ///      (WS-16). Fail closed: no fault and no shortfall serves another renderer.
    function _pinnedRenderer(address records, uint256 tokenId)
        private
        view
        returns (address renderer)
    {
        (bool ok, bytes memory answer) = BoundedCall.tryReadAll(
            records, abi.encodeCall(IWorkRecords.pinnedRenderer, (tokenId)), PIN_REVERT_BYTES
        );
        if (ok) {
            uint256 word = uint256(bytes32(answer));
            if (answer.length != 32 || word >> 160 != 0) revert RendererPinUnreadable(tokenId);
            return address(uint160(word));
        }
        if (answer.length != 0x24 || bytes4(answer) != IWorkRecords.RecordNotOpen.selector) {
            assembly ("memory-safe") {
                revert(add(answer, 0x20), mload(answer))
            }
        }
    }

    /// @dev The `Counts.replaced` bit index, the ERC-165 interface and the current address of
    ///      the dependency `kind` names (`UnknownDependency` for any other).
    function _dependencyOf(bytes32 kind) private view returns (uint8, bytes4, address) {
        if (kind == PACKAGE_REGISTRY) return (0, type(IMintPolicy).interfaceId, packageRegistry());
        if (kind == ECONOMICS) return (1, type(IEconomicsResolver).interfaceId, economics());
        if (kind == ENTROPY_MODULE) return (2, type(IEntropyModule).interfaceId, entropyModule());
        if (kind == EXTENSION) {
            return (3, type(IStreamExtension).interfaceId, _dependency(3, _genesisExtension));
        }
        revert UnknownDependency(kind);
    }

    /// @dev Dependency `index`: its replacement once governance set one, else `genesis`.
    function _dependency(uint8 index, address genesis) private view returns (address) {
        return (_counts.replaced & (uint8(1) << index)) == 0 ? genesis : _replaced[index];
    }

    /// @dev Assigns the next token ID and collection serial, writes the two work words and emits
    ///      the mint record. The collection must exist (`UnknownCollection`).
    function _store(IMintPolicy.MintRecord memory r, uint24 termsId)
        private
        returns (uint256 tokenId)
    {
        CollectionData storage c = _collections[r.collectionId];
        if (!c.exists) revert UnknownCollection(r.collectionId);
        tokenId = ++_counts.minted;
        uint32 serial = ++c.minted;
        address seller = r.seller;
        TokenData storage t = _tokens[tokenId];
        t.seller = seller;
        t.serial = serial;
        // The collection exists, so its ID is at most the uint32 collection counter.
        // forge-lint: disable-next-line(unsafe-typecast)
        t.collectionId = uint32(r.collectionId);
        t.flags = r.kind | (r.seedPolicy << SEED_SHIFT);
        t.termsId = termsId;
        t.itemHash = r.itemHash;
        _emitMinted(r, tokenId, serial, seller, termsId);
    }

    /// @dev `WorkMinted`, written out by hand: twelve fields are more than the legacy code
    ///      generator can keep on the stack. The data words follow the event's declaration.
    function _emitMinted(
        IMintPolicy.MintRecord memory r,
        uint256 tokenId,
        uint32 serial,
        address seller,
        uint24 termsId
    ) private {
        bytes32 topic0 = WorkMinted.selector;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, mload(r)) // itemHash
            mstore(add(p, 0x20), serial)
            mstore(add(p, 0x40), mload(add(r, 0x60))) // kind
            mstore(add(p, 0x60), mload(add(r, 0xc0))) // packageRoot
            mstore(add(p, 0x80), mload(add(r, 0xe0))) // contentHash
            mstore(add(p, 0xa0), mload(add(r, 0x100))) // mediaHash
            mstore(add(p, 0xc0), mload(add(r, 0x120))) // recordFileId
            mstore(add(p, 0xe0), seller)
            mstore(add(p, 0x100), termsId)
            // topics: the signature, tokenId, collectionId, artistId
            log4(p, 0x120, topic0, tokenId, mload(add(r, 0x40)), mload(add(r, 0x20)))
        }
    }

    /// @dev The index (from 1) of a fee recipient, registered on first use.
    function _feeRecipientId(address recipient) private returns (uint24 id) {
        id = _feeRecipientIds[recipient];
        if (id == 0) {
            _feeRecipients.push(recipient);
            id = uint24(_feeRecipients.length);
            if (id != _feeRecipients.length) revert TermsCapacityExceeded();
            _feeRecipientIds[recipient] = id;
            emit FeeRecipientRegistered(id, recipient);
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

    /// @dev The ID of `t`, interned on first use (QUALITY-6), announced by `TermsInterned`.
    ///      `t` lives at the position its hash names, below `OVERFLOW`; if other terms already
    ///      hold that position, in the overflow range, found again by the full hash.
    function _termsId(Terms memory t) private returns (uint24 id) {
        bytes32 key = _key(t);
        id = uint24(uint256(key)) & HASHED;
        Terms memory held = _terms[id];
        if (held.artistId == 0) {
            _terms[id] = t;
            _interned(id, t);
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
            _interned(id, t);
        }
    }

    function _interned(uint24 id, Terms memory t) private {
        emit TermsInterned(id, t.royaltyRate, t.feeShare, t.feeRecipientId, t.minterId);
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

    function _onlyBound(address bound) private view {
        if (msg.sender != bound || bound == address(0)) revert UnboundCaller(msg.sender);
    }

    /// @dev A live token: minted and not burned.
    function _live(uint256 tokenId) private view returns (TokenData storage) {
        if (_ownerOf(tokenId) == address(0)) revert UnknownWork(tokenId);
        return _tokens[tokenId];
    }
}
