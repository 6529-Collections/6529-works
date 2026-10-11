// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IMintTarget } from "./IMintTarget.sol";
import { ItemKind, SeedPolicy } from "./types/PackageTypes.sol";

/// @title IStream
/// @notice 6529 Stream core: the one shared, network-curated ERC-721 that holds every curated 1/1
///         (ADR 0001 sections 1, 4, 7 and 12). Descriptive records, finalize, licenses,
///         locators and renderer pins live in the `IWorkRecords` satellite.
/// @dev Token IDs are one chronological global sequence from 1, assigned when a work's sale
///      starts and never reused; a burn leaves a gap. Collections are groupings with
///      per-collection serials from 1; collection IDs and serials stay below 2^32. Tokens are
///      minted only through `IMintTarget.mint`, for an approved, unconsumed item whose lead
///      artist signed "move to Stream"; 6529 Stream is auction-only, so the item's sale kind and
///      the adapter's are both `SaleKind.ENGLISH_AUCTION`. A VRF item's seed must already be
///      delivered (`IEntropyModule.requestSeed` runs before the start).
///
///      Start-gas budget (300K for the whole start, decision D3): a mint stores two or three
///      words per token (the item hash; seller, serial, collection, kind and flags; royalty
///      receiver and rate) plus the lead artist ID, and nothing else. Everything else is in
///      `WorkMinted` and in the published package.
///
///      Satellites are bound once at genesis (`bind`) and never change. Governed functions are
///      non-payable; each names the `Roles` role its selector maps to.
interface IStream is IERC4906, IERC2981, IMintTarget {
    /// @notice A collection: a named grouping of works, possibly by several artists.
    /// @param name The display name.
    /// @param metadataHash The hash of the collection's metadata document, or zero.
    /// @param minted Works minted into it so far; also the last serial assigned.
    struct Collection {
        string name;
        bytes32 metadataHash;
        uint64 minted;
    }

    /// @notice What 6529 Stream stores for a work.
    /// @dev Nothing changes after mint except `royaltyRate` (by agreement, through
    ///      `IWorkRecords`). `artistId` is the lead artist. `seller` and `royaltyReceiver` are
    ///      predicted split-wallet addresses.
    struct WorkCore {
        bytes32 itemHash;
        uint256 artistId;
        uint256 collectionId;
        uint64 serial;
        ItemKind kind;
        SeedPolicy seedPolicy;
        address seller;
        address royaltyReceiver;
        uint32 royaltyRate;
    }

    /// @notice A curated work was minted. With the published package, this is the museum's
    ///         source record of the mint (ADR 0001 section 15).
    event WorkMinted(
        uint256 indexed tokenId,
        uint256 indexed collectionId,
        bytes32 indexed itemHash,
        uint64 serial,
        uint256 artistId,
        ItemKind kind,
        bytes32 packageRoot,
        bytes32 contentHash,
        bytes32 mediaHash,
        bytes32 recordFileId
    );
    /// @notice A work's royalty rate changed, by agreement of every party plus a governed action.
    event RoyaltyRateChanged(uint256 indexed tokenId, uint32 previous, uint32 next);
    /// @notice The renderer of works that are not finalized changed.
    event DefaultRendererSet(address previous, address next);
    /// @notice A collection was created.
    event CollectionCreated(uint256 indexed collectionId, string name, bytes32 metadataHash);
    /// @notice An edition master was linked to its 6529 Editions edition.
    event EditionLinked(uint256 indexed tokenId, address indexed editions, uint256 editionId);
    /// @notice The satellites were bound, once.
    event Bound(address workRecords, address editions);
    /// @notice The marketplace owner changed (the event marketplaces index for `owner()`).
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice ERC-7572: the contract-level metadata changed.
    event ContractURIUpdated();

    /// @notice No live token has this ID.
    error UnknownWork(uint256 tokenId);
    /// @notice No collection has this ID.
    error UnknownCollection(uint256 collectionId);
    /// @notice The caller is not the bound satellite this function serves.
    error NotBound(address caller);
    /// @notice The satellites are already bound.
    error AlreadyBound();
    /// @notice The mint request is malformed or breaks a Stream rule (sale kind, collection,
    ///         seed policy).
    error InvalidMintRequest();
    /// @notice The VRF seed of this item has not been delivered.
    error SeedNotDelivered(bytes32 itemHash);
    /// @notice The work is not an edition master, or its edition is already linked.
    error EditionLinkInvalid(uint256 tokenId);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();

    // ----- wiring -----

    /// @notice Binds the work-records satellite and 6529 Editions, once, at genesis. ADMIN role.
    function bind(address workRecords_, address editions_) external;
    /// @notice The bound `IWorkRecords` satellite.
    function workRecords() external view returns (address);
    /// @notice The bound 6529 Editions contract.
    function editions() external view returns (address);
    /// @notice The package registry consulted by `mint` (immutable).
    function packageRegistry() external view returns (address);
    /// @notice The artist registry that resolves each work's artist (immutable).
    function artistRegistry() external view returns (address);
    /// @notice The economics resolver whose `PRODUCT_STREAM` terms works lock at mint
    ///         (immutable).
    function economics() external view returns (address);
    /// @notice The VRF entropy module, or zero if VRF works are not supported (immutable).
    function entropyModule() external view returns (address);

    // ----- collections, supply and works -----

    /// @notice Creates a collection and returns its ID (sequential, from 1). PLATFORM role.
    function createCollection(string calldata name, bytes32 metadataHash)
        external
        returns (uint256 collectionId);
    /// @notice A collection. Reverts with `UnknownCollection`.
    function collection(uint256 collectionId) external view returns (Collection memory);
    /// @notice The number of collections created.
    function collectionCount() external view returns (uint256);
    /// @notice The number of tokens ever minted, which is also the highest token ID.
    function totalMinted() external view returns (uint256);
    /// @notice The number of live tokens (minted minus burned).
    function totalSupply() external view returns (uint256);
    /// @notice What Stream stores for a work. Reverts with `UnknownWork`.
    function work(uint256 tokenId) external view returns (WorkCore memory);
    /// @notice The lead artist ID of a live work, packed in its token slot; `isArtist` reads it.
    ///         Reverts with `UnknownWork`.
    function artistOf(uint256 tokenId) external view returns (uint256 artistId);
    /// @notice True after the token's first transfer out of the minting adapter's custody (the
    ///         auction settled, to a winner or to the artist); false before, and for burned or
    ///         unminted IDs. A packed flag set in the transfer hook; it gates edition creation.
    function primarySaleSettled(uint256 tokenId) external view returns (bool);
    /// @notice The work's seed: ARTIST seeds from the item, VRF seeds from the entropy module
    ///         (keyed by item hash, always delivered before mint), zero for NONE.
    function seedOf(uint256 tokenId) external view returns (SeedPolicy policy, bytes32 seed);

    // ----- rendering -----

    /// @notice The renderer of works that are not finalized.
    function defaultRenderer() external view returns (address);
    /// @notice Sets the default renderer. SUCCESSOR_SETTER role, compare-and-set. Finalized works
    ///         keep their pin.
    function setDefaultRenderer(address expected, address next) external;
    /// @notice The renderer serving a work: its pin in `IWorkRecords` once finalized, the default
    ///         before. `tokenURI` forwards to it.
    function rendererOf(uint256 tokenId) external view returns (address);

    // ----- hooks for the bound satellites -----

    /// @notice Sets a work's royalty rate (payees never change). Bound `IWorkRecords` only, after
    ///         it verified every party's consent and the governed action.
    function setRoyaltyRate(uint256 tokenId, uint32 rate) external;
    /// @notice Emits ERC-4906 for `[fromTokenId, toTokenId]` (one `MetadataUpdate` when equal).
    ///         Bound `IWorkRecords` only.
    function emitMetadataUpdate(uint256 fromTokenId, uint256 toTokenId) external;
    /// @notice The 6529 Editions edition an EDITION_MASTER work anchors, or zeros if none.
    function editionOf(uint256 tokenId)
        external
        view
        returns (address editionsContract, uint256 editionId);
    /// @notice Records the edition of an EDITION_MASTER work, once. Bound 6529 Editions only, from
    ///         `IEditions.createEdition`, which records the other direction in the same
    ///         transaction.
    function linkEdition(uint256 tokenId, uint256 editionId) external;

    // ----- marketplace metadata -----

    /// @notice ERC-7572 contract-level metadata URI.
    function contractURI() external view returns (string memory);
    /// @notice Sets the contract URI. PARAMETER_SETTER role.
    function setContractURI(string calldata uri) external;
    /// @notice The marketplace owner (held by 6529); it has no on-chain powers.
    function owner() external view returns (address);
    /// @notice Sets the marketplace owner, which marketplaces let configure creator earnings.
    ///         FUNDS_SETTER role, compare-and-set.
    function setOwner(address expected, address next) external;
}
