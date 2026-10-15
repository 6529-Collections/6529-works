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
///      Start-gas budget: 350K Prague gas, and at most 6 new storage slots (7 with a bid), per
///      steady-state start transaction (ADR 0003, ADR 0004; the first start in an empty
///      collection or custody may cost more, and its measured value is recorded). A
///      mint stores per token two words: the seller with the serial, collection, kind, seed
///      policy, flags and a terms ID; the item hash. The terms (lead artist ID, royalty rate, fee
///      share, a small fee-recipient index and the minting adapter's index) are one word shared
///      by every work under the same terms, so only a first start under new terms writes it
///      (one word more when its 23-bit hashed position collides with other terms'). The royalty
///      receiver is derived, not stored: the split factory's `walletFor` over
///      `(seller, feeRecipient, feeShare)`. ARTIST seeds are stored by
///      `IWorkRecords` when the record opens. Everything else is in `WorkMinted` and in the
///      published package.
///
///      An upheld dispute burns the token from auction custody (`IMintTarget.burn`, by the
///      adapter that minted it, before the primary sale settled). The governed `releaseContent`
///      then passes the burned work's stored item hash, and the rightful artist the dispute
///      outcome names, to `IPackageRegistry.releaseContent`: the content hash is reserved for
///      that artist's items and the burned item is tombstoned.
///
///      Satellites are bound once each (`bindWorkRecords`, `bindEditions`): ERC-165 checked, not
///      EIP-7702 delegated accounts, serving this Stream (`stream() == address(this)`), never
///      changed. Governed functions are non-payable; each
///      names the `Roles` role its selector maps to.
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
    ///      `IWorkRecords`). `artistId` is the lead artist. `seller` is a predicted split-wallet
    ///      address; `royaltyReceiver` is derived from it and the stored fee terms.
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
    /// @notice The renderer of works that are not finalized changed; `codeHash` is pinned.
    event DefaultRendererSet(address previous, address next, bytes32 codeHash);
    /// @notice A collection was created.
    event CollectionCreated(uint256 indexed collectionId, string name, bytes32 metadataHash);
    /// @notice An edition master was linked to its 6529 Editions edition.
    event EditionLinked(uint256 indexed tokenId, address indexed editions, uint256 editionId);
    /// @notice A satellite was bound under `name` (WORK_RECORDS or EDITIONS), once.
    event Bound(bytes32 indexed name, address target);
    /// @notice The minting adapter marked a token's primary sale settled.
    event PrimarySaleSettled(uint256 indexed tokenId);
    /// @notice The marketplace owner changed (the event marketplaces index for `owner()`).
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice ERC-7572: the contract-level metadata changed.
    event ContractURIUpdated();
    /// @notice The contract URI changed from `previous` to `next` (emitted beside ERC-7572's
    ///         parameterless `ContractURIUpdated`).
    event ContractURISet(string previous, string next);

    /// @notice No live token has this ID.
    error UnknownWork(uint256 tokenId);
    /// @notice No collection has this ID.
    error UnknownCollection(uint256 collectionId);
    /// @notice The caller is not the bound contract (or minting adapter) this function serves.
    error UnboundCaller(address caller);
    /// @notice `name` is already bound.
    error AlreadyBound(bytes32 name);
    /// @notice The target lacks code or the expected ERC-165 support, is an EIP-7702 delegated
    ///         account, or (a satellite) serves another Stream; or the default renderer's code is
    ///         no longer the code hash it was installed with.
    error InvalidBinding(address target);
    /// @notice The mint request is malformed or breaks a Stream rule (sale kind, collection,
    ///         seed policy, license ID, fee terms).
    error InvalidMintRequest();
    /// @notice The collection name is empty, too long, not UTF-8, or holds a control character,
    ///         `<`, `"` or `\`.
    error InvalidCollectionName();
    /// @notice The royalty rate exceeds 100,000.
    error InvalidRoyaltyRate(uint32 rate);
    /// @notice The token is not burned.
    error NotBurned(uint256 tokenId);
    /// @notice The token's primary sale settled, so it can no longer be burned.
    error SaleAlreadySettled(uint256 tokenId);
    /// @notice The VRF seed of this item has not been delivered.
    error SeedNotDelivered(bytes32 itemHash);
    /// @notice The work is not an edition master, its primary sale has not settled, its edition
    ///         is already linked, or the edition ID is not the token ID.
    error EditionLinkInvalid(uint256 tokenId);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();

    // ----- wiring -----

    /// @notice Binds the work-records satellite, once (ERC-165 for `IWorkRecords`, and
    ///         `IWorkRecords(target).stream()` must be this contract). ADMIN role.
    function bindWorkRecords(address target) external;
    /// @notice Binds 6529 Editions, once (ERC-165 for `IEditions`, and `IEditions(target).stream()`
    ///         must be this contract). ADMIN role.
    function bindEditions(address target) external;
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

    /// @notice Creates a collection and returns its ID (sequential, from 1). PLATFORM role. The
    ///         name is 1 to 256 bytes of UTF-8 without control characters (below 0x20, and
    ///         0x7F), `<`, `"` or `\`.
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
    /// @notice What Stream stores for a work, with the derived royalty receiver. Reverts with
    ///         `UnknownWork`.
    function work(uint256 tokenId) external view returns (WorkCore memory);
    /// @notice The stored core fields only, without deriving the royalty receiver: the cheap read
    ///         `IWorkRecords` uses. Reverts with `UnknownWork`.
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
        );
    /// @notice After an upheld-dispute burn, passes the burned work's stored item hash,
    ///         `contentHash` and the rightful artist `beneficiary` the dispute outcome names to
    ///         `IPackageRegistry.releaseContent`, which checks the pair and reserves the content
    ///         for that artist, who must be registered. PARAMETER_SETTER role (48 hours); reverts
    ///         with `NotBurned` for a live or unminted token.
    function releaseContent(uint256 tokenId, bytes32 contentHash, uint256 beneficiary) external;
    /// @notice The lead artist ID of a live work, packed in its token slot; `isArtist` reads it.
    ///         Reverts with `UnknownWork`.
    function artistOf(uint256 tokenId) external view returns (uint256 artistId);
    /// @notice True once the minting adapter marked the token's primary sale settled
    ///         (`IMintTarget.markPrimarySettled`: to a
    ///         winner, a pending claim, or the artist); false before, and for burned or unminted
    ///         IDs. A packed flag; it gates edition creation.
    function primarySaleSettled(uint256 tokenId) external view returns (bool);

    // ----- rendering -----

    /// @notice The renderer of works that are not finalized.
    function defaultRenderer() external view returns (address);
    /// @notice Sets the default renderer: ERC-165 checked for `IRenderer`, code hash
    ///         `nextCodeHash`, not an EIP-7702 delegated account. SUCCESSOR_SETTER role,
    ///         compare-and-set. Finalized works keep their pin; 6529 Editions is notified
    ///         (`IEditions.notifyAllUpdated`).
    function setDefaultRenderer(address expected, address next, bytes32 nextCodeHash) external;
    /// @notice The renderer serving a work: its pin in `IWorkRecords` once finalized, the default
    ///         before. `tokenURI` forwards to it (and 6529 Editions' `uri`). Fails closed: reverts
    ///         with `InvalidBinding` when the default renderer's code is no longer the code hash
    ///         `setDefaultRenderer` (or the constructor) pinned, and with
    ///         `IWorkRecords.InvalidRenderer` when a finalized work's pinned renderer changed
    ///         code; it never falls back to another renderer. A new default renderer, or the
    ///         errata repin for a finalized work, restores the metadata.
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
    /// @notice Records the edition of an EDITION_MASTER work, once, after the master's primary
    ///         sale settled (D14, checked here as well as in Editions); the edition ID equals the
    ///         token ID. Bound 6529 Editions only, from `IEditions.createEdition`, which records
    ///         the other direction in the same transaction.
    function linkEdition(uint256 tokenId, uint256 editionId) external;

    // ----- marketplace metadata -----

    /// @notice ERC-7572 contract-level metadata URI.
    function contractURI() external view returns (string memory);
    /// @notice Sets the contract URI (`ContractURISet`, `ContractURIUpdated`). PARAMETER_SETTER
    ///         role.
    function setContractURI(string calldata uri) external;
    /// @notice The marketplace owner (held by 6529); it has no on-chain powers.
    function owner() external view returns (address);
    /// @notice Sets the marketplace owner, which marketplaces let configure creator earnings.
    ///         FUNDS_SETTER role, compare-and-set.
    function setOwner(address expected, address next) external;
}
