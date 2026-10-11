// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import {
    PRODUCT_STREAM,
    SHARE_DENOMINATOR,
    WorkTerms
} from "../interfaces/types/EconomicsTypes.sol";
import {
    ItemKind,
    License,
    PackageItem,
    SeedPolicy,
    StreamMintRequest
} from "../interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "../interfaces/types/SaleTypes.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { Utf8 } from "../libraries/Utf8.sol";
import { IStreamCore } from "./IStreamCore.sol";
import { IWorkRecords } from "./IWorkRecords.sol";

/// @title Stream
/// @notice 6529 Stream: the one shared, network-curated ERC-721 holding every curated 1/1
///         (ADR 0001 sections 1, 4, 7 and 12; integrator decisions D1, D3 and D6).
/// @dev The core token. It holds ownership, the royalty terms `royaltyInfo` reads, collections
///      and serials, the license, the edition link, the marketplace owner and contract URI, and
///      forwards `tokenURI` to the work's renderer. Descriptive records, the state hash,
///      finalize, amendments and locators live in the bound `WorkRecords` satellite, which
///      changes license and royalty rate here through two hooks and asks this contract to emit
///      the ERC-4906 events marketplaces index.
///
///      Storage is shaped by the 300K auction-start budget: a mint writes the ERC-721 owner and
///      balance, one shared counter word, the collection's counter word and three work words,
///      and puts everything else in `WorkMinted` (D26). Word 0 packs the lead artist ID, serial,
///      collection ID, license index and kind; word 1 the royalty receiver and rate, which is all
///      `royaltyInfo` reads (no external call, so it can run out of gas and revert but never
///      return a zero royalty for lack of gas: RC1's Medium finding); word 2 the item hash.
///      Distinct licenses are stored once and referenced by index, so a work pays for its
///      license only if nobody used it before.
///
///      Trust: the package registry, artist registry and economics resolver are immutable and
///      trusted. Sale adapters are trusted through the MINTER role; the records satellite and
///      the 6529 Editions contract through one-shot bindings made at genesis.
contract Stream is ERC721, AccessManaged, IStreamCore {
    /// @notice The longest accepted collection name, in bytes.
    uint256 public constant MAX_NAME_BYTES = 256;
    /// @notice The longest accepted SPDX identifier, in bytes.
    uint256 public constant MAX_SPDX_BYTES = 64;

    /// @dev The canonical key (D20) of CC0: keccak256 of the lowercase SPDX identifier.
    bytes32 private constant CC0_KEY = keccak256("cc0-1.0");

    /// @dev `keccak256(abi.encode(license))` of license 1, the product default at deployment,
    ///      which most works use: matching it costs no storage read at mint.
    bytes32 private immutable _defaultLicenseKey;

    /// @dev Words 0, 1 and 2 of a token. `licenseId` indexes `_licenses` plus one.
    struct TokenData {
        uint160 artistId;
        uint32 serial;
        uint32 collectionId;
        uint24 licenseId;
        ItemKind kind;
        address royaltyReceiver;
        uint32 royaltyRate;
        bool editionLinked;
        bytes32 itemHash;
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

    /// @inheritdoc IStreamCore
    address public immutable packageRegistry;
    /// @inheritdoc IStreamCore
    address public immutable artistRegistry;
    /// @inheritdoc IStreamCore
    address public immutable economics;

    /// @inheritdoc IStreamCore
    address public records;
    /// @inheritdoc IStreamCore
    address public editions;
    /// @inheritdoc IStreamCore
    address public defaultRenderer;

    Counts private _counts;
    address private _owner;
    string private _contractURI;
    License[] private _licenses;
    mapping(bytes32 licenseHash => uint24 id) private _licenseIds;
    mapping(uint256 collectionId => CollectionData) private _collections;
    mapping(uint256 tokenId => TokenData) private _tokens;

    /// @param authority_ The AccessManager governing this contract.
    /// @param packageRegistry_ The package registry `mint` consumes items from.
    /// @param artistRegistry_ The artist registry resolving each work's artist.
    /// @param economics_ The economics resolver whose terms works lock at mint.
    /// @param renderer_ The initial default renderer.
    /// @param owner_ The initial marketplace owner.
    /// @param defaultLicense_ The product's default license (CC0 at launch), registered as
    ///        license 1.
    constructor(
        address authority_,
        address packageRegistry_,
        address artistRegistry_,
        address economics_,
        address renderer_,
        address owner_,
        License memory defaultLicense_
    ) ERC721("6529 Stream", "STREAM") AccessManaged(authority_) {
        _requireContract(packageRegistry_);
        _requireContract(artistRegistry_);
        _requireContract(economics_);
        _requireContract(renderer_);
        packageRegistry = packageRegistry_;
        artistRegistry = artistRegistry_;
        economics = economics_;
        defaultRenderer = renderer_;
        _owner = owner_;
        uint256 spdx = bytes(defaultLicense_.spdxId).length;
        if (spdx == 0 || spdx > MAX_SPDX_BYTES) revert InvalidLicense();
        bytes32 key = keccak256(abi.encode(defaultLicense_));
        _defaultLicenseKey = key;
        _licenses.push(defaultLicense_);
        _licenseIds[key] = 1;
        emit DefaultRendererSet(address(0), renderer_);
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------------------------- minting

    /// @inheritdoc IMintTarget
    /// @dev MINTER role. The adapter mints into its own custody (`to == msg.sender`), reports
    ///      `SaleKind.ENGLISH_AUCTION`, and passes `id = 0`, `amount = 1` and
    ///      `data = abi.encode(StreamMintRequest)`. The registry checks the approval, consents,
    ///      move signature, single use and content uniqueness; this contract checks the Stream
    ///      rules and assigns the next token ID and collection serial.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        restricted
        returns (uint256 tokenId, PrimaryTerms memory terms)
    {
        if (to != msg.sender || id != 0 || amount != 1) revert InvalidMintRequest();
        if (ISaleAdapter(msg.sender).saleKind() != SaleKind.ENGLISH_AUCTION) {
            revert InvalidMintRequest();
        }
        StreamMintRequest calldata req = _request(data);
        _checkItem(req.item);
        (bytes32 itemHash, uint256 artistId) = _consume(data);
        if (artistId == 0 || artistId > type(uint160).max) revert InvalidMintRequest();
        WorkTerms memory w;
        (terms, w) = _quote(req.item, artistId);
        tokenId = _store(req.item, itemHash, artistId, w);
        _mint(to, tokenId);
    }

    /// @inheritdoc IMintTarget
    /// @dev Resolves the lead artist through `artistIdOf`, so it reverts while the lead artist
    ///      has no identity (no sale can start then either).
    function primaryTerms(uint256 id, bytes calldata data)
        external
        view
        returns (PrimaryTerms memory terms)
    {
        if (id != 0) revert InvalidMintRequest();
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

    // ------------------------------------------------------------------- collections, supply

    /// @inheritdoc IStreamCore
    function createCollection(string calldata name, bytes32 metadataHash)
        external
        restricted
        returns (uint256 collectionId)
    {
        bytes calldata raw = bytes(name);
        if (raw.length == 0 || raw.length > MAX_NAME_BYTES || !Utf8.isValid(raw)) {
            revert InvalidCollection();
        }
        collectionId = ++_counts.collections;
        CollectionData storage c = _collections[collectionId];
        c.exists = true;
        c.metadataHash = metadataHash;
        c.name = name;
        emit CollectionCreated(collectionId, name, metadataHash);
    }

    /// @inheritdoc IStreamCore
    function collection(uint256 collectionId) external view returns (Collection memory) {
        CollectionData storage c = _collections[collectionId];
        if (!c.exists) revert UnknownCollection(collectionId);
        return Collection(c.name, c.metadataHash, c.minted);
    }

    /// @inheritdoc IStreamCore
    function collectionCount() external view returns (uint256) {
        return _counts.collections;
    }

    /// @inheritdoc IStreamCore
    function totalMinted() external view returns (uint256) {
        return _counts.minted;
    }

    /// @inheritdoc IStreamCore
    function totalSupply() external view returns (uint256) {
        return _counts.minted - _counts.burned;
    }

    // ---------------------------------------------------------------------------------- works

    /// @inheritdoc IStreamCore
    function work(uint256 tokenId) external view returns (TokenInfo memory) {
        TokenData storage t = _live(tokenId);
        return TokenInfo(t.itemHash, t.artistId, t.collectionId, t.serial, t.kind, t.editionLinked);
    }

    /// @inheritdoc IStreamCore
    /// @dev Kept after a burn, so statements and indexers can still join a burned token to its
    ///      item (D23). Zero for an ID never minted.
    function itemHashOf(uint256 tokenId) external view returns (bytes32) {
        return _tokens[tokenId].itemHash;
    }

    /// @inheritdoc IStreamCore
    function licenseOf(uint256 tokenId) external view returns (License memory) {
        return _licenses[_live(tokenId).licenseId - 1];
    }

    /// @inheritdoc IStreamCore
    function royaltyOf(uint256 tokenId) external view returns (address receiver, uint32 rate) {
        TokenData storage t = _live(tokenId);
        return (t.royaltyReceiver, t.royaltyRate);
    }

    /// @inheritdoc IERC2981
    /// @dev Two storage reads and no external call. `rate <= 100,000` (checked when stored), so
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

    // ------------------------------------------------------------------------- records hooks

    /// @inheritdoc IStreamCore
    /// @dev Only the bound records satellite, after it has collected every party's consent and
    ///      the governed action. A CC0 dedication is irrevocable, checked here as well.
    function setLicense(uint256 tokenId, License calldata next) external {
        _onlyRecords();
        TokenData storage t = _live(tokenId);
        License memory previous = _licenses[t.licenseId - 1];
        if (licenseKey(previous.spdxId) == CC0_KEY) revert LicenseIrrevocable(tokenId);
        _checkLicense(next);
        t.licenseId = _licenseId(next);
        emit LicenseChanged(tokenId, previous, next);
        emit MetadataUpdate(tokenId);
    }

    /// @inheritdoc IStreamCore
    /// @dev Only the bound records satellite. The receiver (the payees' split wallet) is fixed
    ///      at mint; only the rate changes (D19).
    function setRoyaltyRate(uint256 tokenId, uint32 rate) external {
        _onlyRecords();
        TokenData storage t = _live(tokenId);
        if (rate > SHARE_DENOMINATOR) revert InvalidRoyalty();
        emit RoyaltyChanged(tokenId, t.royaltyReceiver, t.royaltyRate, rate);
        t.royaltyRate = rate;
    }

    /// @inheritdoc IStreamCore
    function refreshMetadata(uint256 fromTokenId, uint256 toTokenId) external {
        _onlyRecords();
        if (fromTokenId == toTokenId) emit MetadataUpdate(fromTokenId);
        else emit BatchMetadataUpdate(fromTokenId, toTokenId);
    }

    // ------------------------------------------------------------------------------- rendering

    /// @inheritdoc IStreamCore
    function setDefaultRenderer(address expected, address next) external restricted {
        if (defaultRenderer != expected) revert ExpectedValueMismatch();
        _requireContract(next);
        defaultRenderer = next;
        emit DefaultRendererSet(expected, next);
        uint256 minted = _counts.minted;
        if (minted != 0) emit BatchMetadataUpdate(1, minted);
    }

    /// @inheritdoc IStreamCore
    function rendererOf(uint256 tokenId) public view returns (address renderer) {
        _live(tokenId);
        address bound = records;
        if (bound != address(0)) renderer = IWorkRecords(bound).pinnedRenderer(tokenId);
        if (renderer == address(0)) renderer = defaultRenderer;
    }

    /// @notice The token's metadata, built by its pinned renderer once finalized, else by the
    ///         default renderer. Reverts for a burned or unminted token.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return IRenderer(rendererOf(tokenId)).tokenURI(address(this), tokenId);
    }

    // -------------------------------------------------------------------------------- bindings

    /// @inheritdoc IStreamCore
    function bindRecords(address records_) external restricted {
        if (records != address(0)) revert AlreadyBound(records);
        _requireContract(records_);
        records = records_;
        emit RecordsBound(records_);
    }

    /// @inheritdoc IStreamCore
    function bindEditions(address editions_) external restricted {
        if (editions != address(0)) revert AlreadyBound(editions);
        _requireContract(editions_);
        editions = editions_;
        emit EditionsBound(editions_);
    }

    /// @inheritdoc IStreamCore
    /// @dev The link is written once and never changes; the edition ID must equal the token ID.
    function linkEdition(uint256 tokenId, uint256 editionId) external {
        if (msg.sender != editions || msg.sender == address(0)) {
            revert UnboundCaller(msg.sender);
        }
        TokenData storage t = _live(tokenId);
        if (t.kind != ItemKind.EDITION_MASTER || t.editionLinked || editionId != tokenId) {
            revert EditionLinkInvalid(tokenId);
        }
        t.editionLinked = true;
        emit EditionLinked(tokenId, msg.sender, editionId);
        emit MetadataUpdate(tokenId);
    }

    /// @inheritdoc IStreamCore
    function editionOf(uint256 tokenId)
        external
        view
        returns (address editionsContract, uint256 editionId)
    {
        if (_tokens[tokenId].editionLinked) return (editions, tokenId);
    }

    // --------------------------------------------------------------------- marketplace metadata

    /// @inheritdoc IStreamCore
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @inheritdoc IStreamCore
    function setContractURI(string calldata uri) external restricted {
        _contractURI = uri;
        emit ContractURIUpdated();
    }

    /// @inheritdoc IStreamCore
    function owner() external view returns (address) {
        return _owner;
    }

    /// @inheritdoc IStreamCore
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
            || interfaceId == type(IStreamCore).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice The canonical key of an SPDX identifier (D20): keccak256 of its ASCII-lowercase
    ///         form, so `CC0-1.0` and `cc0-1.0` are one license for irrevocability.
    function licenseKey(string memory spdxId) public pure returns (bytes32) {
        bytes memory lower = bytes(spdxId);
        lower = bytes.concat(lower); // copy: never modify the caller's string
        for (uint256 i; i < lower.length; ++i) {
            bytes1 c = lower[i];
            if (c >= "A" && c <= "Z") lower[i] = bytes1(uint8(c) + 32);
        }
        return keccak256(lower);
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
        (itemHash, artistId,) = abi.decode(result, (bytes32, uint256, bytes32));
    }

    /// @dev Stream rules the registry does not know: auction-only with empty parameters, an
    ///      existing collection, a coherent seed, a usable license and a lead party.
    function _checkItem(PackageItem calldata item) private view {
        if (
            item.sale.saleKind != SaleKind.ENGLISH_AUCTION || item.sale.params.length != 0
                || item.parties.length == 0 || !_collections[item.collectionId].exists
                || (item.seedPolicy == SeedPolicy.ARTIST) != (item.seed != 0)
        ) revert InvalidMintRequest();
        _checkLicense(item.license);
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
        terms.revealPending = item.seedPolicy == SeedPolicy.VRF;
    }

    /// @dev Assigns the next token ID and collection serial and writes the three work words.
    function _store(
        PackageItem calldata item,
        bytes32 itemHash,
        uint256 artistId,
        WorkTerms memory w
    ) private returns (uint256 tokenId) {
        tokenId = ++_counts.minted;
        uint32 serial = ++_collections[item.collectionId].minted;
        TokenData storage t = _tokens[tokenId];
        // `mint` reverted above for an artist ID wider than 160 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        t.artistId = uint160(artistId);
        t.serial = serial;
        // The collection exists, so its ID is at most the uint32 collection counter.
        t.collectionId = uint32(item.collectionId);
        t.licenseId = _licenseId(item.license);
        t.kind = item.kind;
        t.royaltyReceiver = w.royaltyReceiver;
        t.royaltyRate = w.royaltyRate;
        t.itemHash = itemHash;
        emit WorkMinted(
            tokenId,
            item.collectionId,
            itemHash,
            serial,
            artistId,
            item.kind,
            item.contentId,
            w.seller,
            w.royaltyReceiver,
            w.royaltyRate
        );
    }

    /// @dev The index (plus one) of `license`, registering it on first use.
    function _licenseId(License calldata license) private returns (uint24 id) {
        bytes32 key = keccak256(abi.encode(license));
        if (key == _defaultLicenseKey) return 1;
        id = _licenseIds[key];
        if (id == 0) {
            _licenses.push(license);
            // Reverts (checked conversion) past 16,777,215 distinct licenses.
            id = uint24(_licenses.length);
            if (id != _licenses.length) revert InvalidLicense();
            _licenseIds[key] = id;
        }
    }

    function _checkLicense(License calldata license) private pure {
        uint256 length = bytes(license.spdxId).length;
        if (length == 0 || length > MAX_SPDX_BYTES) revert InvalidLicense();
    }

    function _onlyRecords() private view {
        if (msg.sender != records || msg.sender == address(0)) revert UnboundCaller(msg.sender);
    }

    /// @dev A live token: minted and not burned.
    function _live(uint256 tokenId) private view returns (TokenData storage) {
        if (_ownerOf(tokenId) == address(0)) revert UnknownWork(tokenId);
        return _tokens[tokenId];
    }

    /// @dev Installed dependencies are contracts, never EIP-7702 delegated accounts.
    function _requireContract(address dependency) private view {
        if (dependency.code.length == 0 || DelegatedEOA.isDelegated(dependency)) {
            revert InvalidDependency(dependency);
        }
    }
}
