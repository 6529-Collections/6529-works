// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEntropyModule } from "../interfaces/IEntropyModule.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";
import {
    PRODUCT_STREAM,
    SHARE_DENOMINATOR,
    WorkTerms
} from "../interfaces/types/EconomicsTypes.sol";
import {
    ItemKind,
    PackageItem,
    SeedPolicy,
    StreamMintRequest
} from "../interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "../interfaces/types/SaleTypes.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { Utf8 } from "../libraries/Utf8.sol";

/// @title Stream
/// @notice 6529 Stream core: the one shared, network-curated ERC-721 holding every curated 1/1
///         (ADR 0001 sections 1, 4, 7 and 12; integrator decisions D1, D3, D4, D6 and D13).
/// @dev Holds ownership, the terms locked at mint, collections and serials, the edition link and
///      the marketplace metadata, and forwards `tokenURI` to the work's renderer. Records,
///      licenses, finalize and locators live in the bound `IWorkRecords` satellite.
///
///      Storage is shaped by the 300K auction-start budget. A mint writes the ERC-721 owner and
///      balance, one shared counter word, the collection's counter word and four work words:
///      the seller, serial, collection, kind, seed policy and flags; the royalty receiver, rate
///      and fee-terms index; the lead artist ID; the item hash. An ARTIST seed adds one word.
///      The fee recipient, fee share and currency a sale locks are stored once per distinct
///      combination and referenced by index, so `primaryTerms` returns a minted token's locked
///      terms (the auction reads them back at settlement) without a word per token.
///      `royaltyInfo` reads one word and makes no external call: it can run out of gas and
///      revert, but never return a zero royalty for lack of gas (RC1's Medium finding).
///
///      Trust: the package registry, artist registry, economics resolver and entropy module are
///      immutable. Sale adapters are trusted through the MINTER role; the records satellite and
///      6529 Editions through the one-shot `bind`.
contract Stream is ERC721, AccessManaged, IStream {
    /// @notice The longest accepted collection name, in bytes.
    uint256 public constant MAX_NAME_BYTES = 256;

    /// @notice A dependency lacks code or the required ERC-165 support, or is an EIP-7702
    ///         delegated account.
    error InvalidDependency(address dependency);
    /// @notice The collection name is empty, longer than `MAX_NAME_BYTES` or not UTF-8.
    error InvalidCollectionName();
    /// @notice The royalty rate exceeds 100,000.
    error InvalidRoyaltyRate(uint32 rate);

    /// @dev A token's four words.
    struct TokenData {
        address seller;
        uint32 serial;
        uint32 collectionId;
        ItemKind kind;
        SeedPolicy seedPolicy;
        bool primarySaleSettled;
        bool editionLinked;
        address royaltyReceiver;
        uint32 royaltyRate;
        uint32 feeTermsId;
        uint160 artistId;
        bytes32 itemHash;
    }

    /// @dev Fee terms and currency locked at mint, shared by every token minted under them.
    struct FeeTerms {
        address feeRecipient;
        uint32 feeShare;
        address currency;
    }

    /// @dev `exists` keeps the counter word nonzero, so each mint pays a warm rewrite.
    struct CollectionData {
        bool exists;
        uint32 minted;
        bytes32 metadataHash;
        string name;
    }

    struct Counts {
        uint64 minted;
        uint64 burned;
        uint32 collections;
    }

    /// @inheritdoc IStream
    address public immutable packageRegistry;
    /// @inheritdoc IStream
    address public immutable artistRegistry;
    /// @inheritdoc IStream
    address public immutable economics;
    /// @inheritdoc IStream
    address public immutable entropyModule;

    /// @inheritdoc IStream
    address public workRecords;
    /// @inheritdoc IStream
    address public editions;
    /// @inheritdoc IStream
    address public defaultRenderer;

    Counts private _counts;
    address private _owner;
    string private _contractURI;
    FeeTerms[] private _feeTerms;
    mapping(bytes32 key => uint32 id) private _feeTermsIds;
    mapping(uint256 collectionId => CollectionData) private _collections;
    mapping(uint256 tokenId => TokenData) private _tokens;
    mapping(uint256 tokenId => bytes32) private _seeds;

    /// @param authority_ The AccessManager governing this contract.
    /// @param packageRegistry_ The package registry `mint` consumes items from.
    /// @param artistRegistry_ The artist registry resolving each work's artist.
    /// @param economics_ The economics resolver whose terms works lock at mint.
    /// @param entropyModule_ The VRF entropy module, or zero if VRF works are not supported.
    /// @param renderer_ The initial default renderer.
    /// @param owner_ The initial marketplace owner.
    constructor(
        address authority_,
        address packageRegistry_,
        address artistRegistry_,
        address economics_,
        address entropyModule_,
        address renderer_,
        address owner_
    ) ERC721("6529 Stream", "STREAM") AccessManaged(authority_) {
        _requireInterface(packageRegistry_, type(IPackageRegistry).interfaceId);
        _requireInterface(artistRegistry_, type(IArtistRegistry).interfaceId);
        _requireInterface(economics_, type(IEconomicsResolver).interfaceId);
        if (entropyModule_ != address(0)) {
            _requireInterface(entropyModule_, type(IEntropyModule).interfaceId);
        }
        _requireInterface(renderer_, type(IRenderer).interfaceId);
        packageRegistry = packageRegistry_;
        artistRegistry = artistRegistry_;
        economics = economics_;
        entropyModule = entropyModule_;
        defaultRenderer = renderer_;
        _owner = owner_;
        emit DefaultRendererSet(address(0), renderer_);
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------------------------- minting

    /// @inheritdoc IMintTarget
    /// @dev MINTER role. The adapter mints into its own custody (`to == msg.sender`) and passes
    ///      `id = 0`, `amount = 1` and `data = abi.encode(StreamMintRequest)`. The registry checks
    ///      the approval, consents, move signature, single use and content uniqueness; this
    ///      contract checks the Stream rules and the delivered VRF seed, and assigns the next
    ///      token ID and collection serial.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        restricted
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        if (to != msg.sender || id != 0 || amount != 1) revert InvalidMintRequest();
        bytes32 kind = ISaleAdapter(msg.sender).saleKind();
        if (kind != SaleKind.ENGLISH_AUCTION) {
            revert SaleKindMismatch(SaleKind.ENGLISH_AUCTION, kind);
        }
        StreamMintRequest calldata req = _request(data);
        PackageItem calldata item = req.item;
        _checkItem(item);
        (bytes32 itemHash, uint256 artistId) = _consume(data);
        if (artistId == 0 || artistId > type(uint160).max) revert InvalidMintRequest();
        if (
            item.seedPolicy == SeedPolicy.VRF
                && !IEntropyModule(entropyModule).isDelivered(itemHash)
        ) revert SeedNotDelivered(itemHash);
        WorkTerms memory w;
        (terms, w) = _quote(item, artistId);
        tokenId = _store(req, itemHash, artistId, w, _feeTermsId(terms));
        _mint(to, tokenId);
    }

    /// @inheritdoc IMintTarget
    /// @dev For a minted token, the locked terms with the creator resolved now (the auction reads
    ///      them at settlement). For `id` 0, a preview from `data`; it resolves the lead artist
    ///      through `artistIdOf`, so it reverts while the lead artist has no identity.
    function primaryTerms(uint256 id, bytes calldata data)
        external
        view
        returns (PrimaryTerms memory terms)
    {
        if (id != 0) {
            TokenData storage t = _live(id);
            FeeTerms storage f = _feeTerms[t.feeTermsId - 1];
            terms.saleKind = SaleKind.ENGLISH_AUCTION;
            terms.currency = f.currency;
            terms.seller = t.seller;
            terms.feeRecipient = f.feeRecipient;
            terms.feeShare = f.feeShare;
            terms.creator = IArtistRegistry(artistRegistry).authorityOf(t.artistId);
            return terms;
        }
        StreamMintRequest calldata req = _request(data);
        _checkItem(req.item);
        uint256 artistId = IArtistRegistry(artistRegistry).artistIdOf(req.item.parties[0].account);
        if (artistId == 0) revert InvalidMintRequest();
        (terms,) = _quote(req.item, artistId);
    }

    /// @inheritdoc IMintTarget
    /// @dev MINTER role, only for the caller's own token: the auction custody path after an
    ///      upheld dispute (ADR 0001 section 12). The ID is never reused.
    function burn(uint256 id, uint256 amount) external restricted {
        address holder = _ownerOf(id);
        if (amount != 1) revert InvalidMintRequest();
        if (holder != msg.sender) revert ERC721IncorrectOwner(msg.sender, id, holder);
        ++_counts.burned;
        _burn(id);
    }

    // ----------------------------------------------------------------- collections and works

    /// @inheritdoc IStream
    function createCollection(string calldata name, bytes32 metadataHash)
        external
        restricted
        returns (uint256 collectionId)
    {
        bytes calldata raw = bytes(name);
        if (raw.length == 0 || raw.length > MAX_NAME_BYTES || !Utf8.isValid(raw)) {
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
        TokenData storage t = _live(tokenId);
        return WorkCore(
            t.itemHash,
            t.artistId,
            t.collectionId,
            t.serial,
            t.kind,
            t.seedPolicy,
            t.seller,
            t.royaltyReceiver,
            t.royaltyRate
        );
    }

    /// @inheritdoc IStream
    function artistOf(uint256 tokenId) external view returns (uint256) {
        return _live(tokenId).artistId;
    }

    /// @inheritdoc IStream
    function primarySaleSettled(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0) && _tokens[tokenId].primarySaleSettled;
    }

    /// @inheritdoc IStream
    function seedOf(uint256 tokenId) external view returns (SeedPolicy policy, bytes32 seed) {
        TokenData storage t = _live(tokenId);
        policy = t.seedPolicy;
        if (policy == SeedPolicy.ARTIST) seed = _seeds[tokenId];
        else if (policy == SeedPolicy.VRF) seed = IEntropyModule(entropyModule).seedOf(t.itemHash);
    }

    /// @inheritdoc IERC2981
    /// @dev One storage word and no external call. `rate <= 100,000` (checked when stored), so
    ///      `(p / D) * rate + (p % D) * rate / D` is exactly `floor(p * rate / D)` and cannot
    ///      overflow for any `salePrice` (RC1's overflow-free form).
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        TokenData storage t = _live(tokenId);
        receiver = t.royaltyReceiver;
        uint256 rate = t.royaltyRate;
        unchecked {
            // Exact: the remainder term restores what the first division drops.
            // forge-lint: disable-next-line(divide-before-multiply)
            royaltyAmount = (salePrice / SHARE_DENOMINATOR) * rate
                + ((salePrice % SHARE_DENOMINATOR) * rate) / SHARE_DENOMINATOR;
        }
    }

    // ------------------------------------------------------------------------------- rendering

    /// @inheritdoc IStream
    function setDefaultRenderer(address expected, address next) external restricted {
        if (defaultRenderer != expected) revert ExpectedValueMismatch();
        _requireInterface(next, type(IRenderer).interfaceId);
        defaultRenderer = next;
        emit DefaultRendererSet(expected, next);
        uint256 minted = _counts.minted;
        if (minted != 0) emit BatchMetadataUpdate(1, minted);
    }

    /// @inheritdoc IStream
    function rendererOf(uint256 tokenId) public view returns (address renderer) {
        _live(tokenId);
        address records = workRecords;
        if (records != address(0)) renderer = IWorkRecords(records).pinnedRenderer(tokenId);
        if (renderer == address(0)) renderer = defaultRenderer;
    }

    /// @notice The token's metadata, built by its pinned renderer once finalized, else by the
    ///         default renderer. Reverts with `UnknownWork` for a burned or unminted token.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return IRenderer(rendererOf(tokenId)).tokenURI(address(this), tokenId);
    }

    // ------------------------------------------------------------------------ satellite hooks

    /// @inheritdoc IStream
    function bind(address workRecords_, address editions_) external restricted {
        if (workRecords != address(0)) revert AlreadyBound();
        _requireContract(workRecords_);
        _requireContract(editions_);
        workRecords = workRecords_;
        editions = editions_;
        emit Bound(workRecords_, editions_);
    }

    /// @inheritdoc IStream
    /// @dev The receiver (the payees' split wallet) is fixed at mint (D19).
    function setRoyaltyRate(uint256 tokenId, uint32 rate) external {
        _onlyBound(workRecords);
        TokenData storage t = _live(tokenId);
        if (rate > SHARE_DENOMINATOR) revert InvalidRoyaltyRate(rate);
        emit RoyaltyRateChanged(tokenId, t.royaltyRate, rate);
        t.royaltyRate = rate;
    }

    /// @inheritdoc IStream
    function emitMetadataUpdate(uint256 fromTokenId, uint256 toTokenId) external {
        _onlyBound(workRecords);
        if (fromTokenId == toTokenId) emit MetadataUpdate(fromTokenId);
        else emit BatchMetadataUpdate(fromTokenId, toTokenId);
    }

    /// @inheritdoc IStream
    /// @dev Written once and never changed; the edition ID must equal the token ID.
    function linkEdition(uint256 tokenId, uint256 editionId) external {
        _onlyBound(editions);
        TokenData storage t = _live(tokenId);
        if (t.kind != ItemKind.EDITION_MASTER || t.editionLinked || editionId != tokenId) {
            revert EditionLinkInvalid(tokenId);
        }
        t.editionLinked = true;
        emit EditionLinked(tokenId, msg.sender, editionId);
        emit MetadataUpdate(tokenId);
    }

    /// @inheritdoc IStream
    function editionOf(uint256 tokenId)
        external
        view
        returns (address editionsContract, uint256 editionId)
    {
        if (_tokens[tokenId].editionLinked) return (editions, tokenId);
    }

    // --------------------------------------------------------------------- marketplace metadata

    /// @inheritdoc IStream
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @inheritdoc IStream
    function setContractURI(string calldata uri) external restricted {
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

    /// @dev Sets the primary-sale flag on a token's first transfer: tokens are minted into the
    ///      adapter's custody, so the first transfer that is neither a mint nor a burn is the
    ///      settlement (to the winner or, with no bids, to the artist).
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address from)
    {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) {
            TokenData storage t = _tokens[tokenId];
            if (!t.primarySaleSettled) t.primarySaleSettled = true;
        }
    }

    /// @dev Views `data` as `abi.encode(StreamMintRequest)` in place. Member offsets are
    ///      bounds-checked by the compiler on access.
    function _request(bytes calldata data) private pure returns (StreamMintRequest calldata req) {
        if (data.length < 160 || uint256(bytes32(data[:32])) != 32) revert InvalidMintRequest();
        assembly ("memory-safe") {
            req := add(data.offset, 32)
        }
    }

    /// @dev Forwards the request to `IPackageRegistry.consume` without re-encoding it: the tuple
    ///      after the leading offset word of `abi.encode(StreamMintRequest)` is exactly the ABI
    ///      encoding of `consume`'s four arguments, so the registry decodes the same values this
    ///      contract read through `_request`.
    function _consume(bytes calldata data) private returns (bytes32 itemHash, uint256 artistId) {
        (bool ok, bytes memory result) =
            packageRegistry.call(bytes.concat(IPackageRegistry.consume.selector, data[32:]));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        return abi.decode(result, (bytes32, uint256));
    }

    /// @dev Stream rules the registry does not know: auction-only with empty parameters, a lead
    ///      party, an existing collection, and a coherent seed policy.
    function _checkItem(PackageItem calldata item) private view {
        SeedPolicy policy = item.seedPolicy;
        if (
            item.sale.saleKind != SaleKind.ENGLISH_AUCTION || item.sale.params.length != 0
                || item.parties.length == 0 || !_collections[item.collectionId].exists
                || (policy == SeedPolicy.ARTIST) != (item.seed != 0)
                || (policy == SeedPolicy.VRF && entropyModule == address(0))
        ) revert InvalidMintRequest();
    }

    /// @dev The terms a work of `item` locks now, and the primary terms the adapter applies.
    function _quote(PackageItem calldata item, uint256 artistId)
        private
        view
        returns (PrimaryTerms memory terms, WorkTerms memory w)
    {
        IEconomicsResolver resolver = IEconomicsResolver(economics);
        w = resolver.newWorkTerms(PRODUCT_STREAM, item.payees);
        if (
            w.seller == address(0) || w.royaltyReceiver == address(0)
                || w.royaltyRate > SHARE_DENOMINATOR || w.feeShare > SHARE_DENOMINATOR
        ) revert InvalidMintRequest();
        terms.saleKind = SaleKind.ENGLISH_AUCTION;
        terms.currency = resolver.resolveCurrency(PRODUCT_STREAM, item.sale.currency);
        terms.seller = w.seller;
        terms.feeRecipient = w.feeRecipient;
        terms.feeShare = w.feeShare;
        terms.creator = IArtistRegistry(artistRegistry).authorityOf(artistId);
    }

    /// @dev The index (plus one) of the terms' fee recipient, fee share and currency,
    ///      registered on first use.
    function _feeTermsId(PrimaryTerms memory terms) private returns (uint32 id) {
        bytes32 key = keccak256(abi.encode(terms.feeRecipient, terms.feeShare, terms.currency));
        id = _feeTermsIds[key];
        if (id == 0) {
            _feeTerms.push(FeeTerms(terms.feeRecipient, terms.feeShare, terms.currency));
            // Fewer than 2^32 combinations can ever be registered (one per mint at most).
            // forge-lint: disable-next-line(unsafe-typecast)
            id = uint32(_feeTerms.length);
            _feeTermsIds[key] = id;
        }
    }

    /// @dev Assigns the next token ID and collection serial and writes the work words.
    function _store(
        StreamMintRequest calldata req,
        bytes32 itemHash,
        uint256 artistId,
        WorkTerms memory w,
        uint32 feeTermsId
    ) private returns (uint256 tokenId) {
        PackageItem calldata item = req.item;
        tokenId = ++_counts.minted;
        uint32 serial = ++_collections[item.collectionId].minted;
        TokenData storage t = _tokens[tokenId];
        t.seller = w.seller;
        t.serial = serial;
        // The collection exists, so its ID is at most the uint32 collection counter.
        // forge-lint: disable-next-line(unsafe-typecast)
        t.collectionId = uint32(item.collectionId);
        t.kind = item.kind;
        t.seedPolicy = item.seedPolicy;
        t.royaltyReceiver = w.royaltyReceiver;
        t.royaltyRate = w.royaltyRate;
        t.feeTermsId = feeTermsId;
        // `mint` reverted for an artist ID wider than 160 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        t.artistId = uint160(artistId);
        t.itemHash = itemHash;
        if (item.seedPolicy == SeedPolicy.ARTIST) _seeds[tokenId] = item.seed;
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

    function _onlyBound(address bound) private view {
        if (msg.sender != bound || bound == address(0)) revert NotBound(msg.sender);
    }

    /// @dev A live token: minted and not burned.
    function _live(uint256 tokenId) private view returns (TokenData storage) {
        if (_ownerOf(tokenId) == address(0)) revert UnknownWork(tokenId);
        return _tokens[tokenId];
    }

    /// @dev Installed dependencies are contracts, never EIP-7702 delegated accounts (D8).
    function _requireContract(address dependency) private view {
        if (dependency.code.length == 0 || DelegatedEOA.isDelegated(dependency)) {
            revert InvalidDependency(dependency);
        }
    }

    /// @dev `_requireContract` plus ERC-165 support for `interfaceId` (D8).
    function _requireInterface(address dependency, bytes4 interfaceId) private view {
        _requireContract(dependency);
        if (!ERC165Checker.supportsInterface(dependency, interfaceId)) {
            revert InvalidDependency(dependency);
        }
    }
}
