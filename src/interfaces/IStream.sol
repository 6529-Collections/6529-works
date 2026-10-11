// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IMintTarget } from "./IMintTarget.sol";
import { ItemKind, License, SeedPolicy } from "./types/PackageTypes.sol";
import { Locator, LocatorKind, Work } from "./types/ContentTypes.sol";

/// @title IStream
/// @notice 6529 Stream: the one shared, network-curated ERC-721 that holds every curated 1/1
///         (ADR 0001 sections 1, 4, 7, 8, 10 and 12).
/// @dev Token IDs are one chronological global sequence starting at 1, assigned when a work's
///      sale starts and never reused; a burn leaves a gap. Collections are groupings inside the
///      contract with per-collection serials starting at 1. Tokens are minted only through
///      `IMintTarget.mint` from an admitted adapter, and only for an approved, unconsumed package
///      item whose lead artist signed "move to Stream"; 6529 Stream is auction-only, so the item's
///      sale kind and the adapter's must both be `SaleKind.ENGLISH_AUCTION`.
///
///      "The artist" of a work below is the current authority, in the artist registry, of the
///      work's lead artist ID. Every change to a work's state increments its `version`, and
///      `workStateHash` commits to the token ID, the version, the record hash, the license, the
///      royalty terms and the effective renderer, so an artist signature or a finalize bound to a
///      state hash can never apply to a state the artist did not see.
///
///      Governed functions are non-payable and restricted by AccessManager. Each names the
///      `Roles` role (and so the delay class) its selector is meant to map to; the governance
///      configuration is authoritative.
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

    /// @notice A work's on-chain state.
    /// @dev `contentId`, `kind`, `collectionId`, `serial`, `artistId`, `split`, `seedPolicy`,
    ///      `packageRoot` and `itemHash` never change after mint. `metadataHash` is the hash of the
    ///      current work record (initially the approved one). `recordPublished` is true once a
    ///      record with that hash is stored. `renderer` is zero until finalize pins it.
    struct WorkInfo {
        bytes32 packageRoot;
        bytes32 itemHash;
        bytes32 contentId;
        bytes32 metadataHash;
        bytes32 split;
        uint256 collectionId;
        uint64 serial;
        uint64 artistId;
        ItemKind kind;
        SeedPolicy seedPolicy;
        bool recordPublished;
        bool finalized;
        bool onChainComplete;
        uint32 version;
        address renderer;
    }

    /// @notice A curated work was minted from an approved package item.
    event WorkMinted(
        uint256 indexed tokenId,
        uint256 indexed collectionId,
        bytes32 indexed itemHash,
        uint64 serial,
        uint64 artistId,
        ItemKind kind,
        bytes32 packageRoot,
        bytes32 contentId,
        bytes32 contentHash,
        bytes32 metadataHash
    );
    /// @notice A work record was stored, either the approved one or an artist's edit.
    event WorkRecordSet(uint256 indexed tokenId, bytes32 metadataHash, bytes32 stateHash);
    /// @notice The artist finalized a work: its record is immutable and `renderer` is pinned.
    event WorkFinalized(uint256 indexed tokenId, address renderer, bytes32 stateHash);
    /// @notice Every media file of the work is stored on-chain; on-chain bytes are permanent.
    event WorkOnChainComplete(uint256 indexed tokenId);
    /// @notice The errata path replaced a finalized work's renderer pin (ADR 0001 section 10).
    event RendererRepinned(uint256 indexed tokenId, address previous, address next);
    /// @notice The renderer used by works that are not finalized changed.
    event DefaultRendererSet(address previous, address next);
    /// @notice A work's license changed, by artist agreement plus a governed action.
    event LicenseChanged(uint256 indexed tokenId, License previous, License next);
    /// @notice A work's royalty terms changed, by artist agreement plus a governed action.
    event RoyaltyChanged(
        uint256 indexed tokenId,
        address previousReceiver,
        uint32 previousRate,
        address nextReceiver,
        uint32 nextRate
    );
    /// @notice A locator was appended for one file of a work.
    event LocatorAdded(
        uint256 indexed tokenId, bytes32 indexed fileId, uint256 index, Locator locator
    );
    /// @notice The global preferred locator kind changed.
    event PreferredKindSet(LocatorKind previous, LocatorKind next);
    /// @notice A collection's preferred locator kind changed.
    event CollectionPreferredKindSet(
        uint256 indexed collectionId, LocatorKind previous, LocatorKind next
    );
    /// @notice A file's preferred locator index changed (`type(uint256).max` means none).
    event FilePreferenceSet(
        uint256 indexed tokenId, bytes32 indexed fileId, uint256 previous, uint256 next
    );
    /// @notice A collection was created.
    event CollectionCreated(uint256 indexed collectionId, string name, bytes32 metadataHash);
    /// @notice An edition master was linked to its 6529 Editions edition.
    event EditionLinked(uint256 indexed tokenId, address indexed editions, uint256 editionId);
    /// @notice The 6529 Editions contract allowed to link editions changed.
    event EditionsSet(address previous, address next);
    /// @notice The marketplace owner changed (the event marketplaces index for `owner()`).
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice ERC-7572: the contract-level metadata changed.
    event ContractURIUpdated();

    /// @notice No live token has this ID.
    error UnknownWork(uint256 tokenId);
    /// @notice No collection has this ID.
    error UnknownCollection(uint256 collectionId);
    /// @notice The caller is not the work's artist.
    error NotWorkArtist(uint256 tokenId, address caller);
    /// @notice The work is finalized, so its record can no longer change.
    error WorkIsFinalized(uint256 tokenId);
    /// @notice The work's state hash is not the one the caller or signer expected.
    error StateHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();
    /// @notice The record does not hash to the committed hash and the caller is not the artist.
    error RecordHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice The record breaks a media rule (first file PRIMARY and equal to the content ID,
    ///         one PRIMARY, every file registered in the content store) or a `Work` limit.
    error InvalidWorkRecord();
    /// @notice The file is neither the work's content nor in its published media list.
    error FileNotInWork(uint256 tokenId, bytes32 fileId);
    /// @notice The locator kind is NONE or ONCHAIN, or the URI is empty or malformed.
    error InvalidLocator();
    /// @notice A file still lacks chunks in the content store.
    error NotOnChainComplete(uint256 tokenId);
    /// @notice Only the configured 6529 Editions contract may link editions.
    error NotEditions(address caller);
    /// @notice The work is not an edition master, or its edition is already linked.
    error EditionLinkInvalid(uint256 tokenId);
    /// @notice The mint request is malformed or the item breaks a Stream rule (sale kind,
    ///         collection, seed policy).
    error InvalidMintRequest();
    /// @notice A CC0 dedication is irrevocable, so the license cannot change.
    error LicenseIrrevocable(uint256 tokenId);
    /// @notice The artist co-signature is expired or does not verify.
    error InvalidArtistSignature(uint256 tokenId);

    // ----- wiring -----

    /// @notice The package registry consulted by `mint` (immutable).
    function packageRegistry() external view returns (address);
    /// @notice The artist registry that resolves each work's artist (immutable).
    function artistRegistry() external view returns (address);
    /// @notice The economics resolver whose terms works lock at mint (immutable).
    function economics() external view returns (address);
    /// @notice The content store holding media, license texts and dependencies (immutable).
    function contentStore() external view returns (address);
    /// @notice The optional VRF entropy module, or zero if VRF works are not supported
    ///         (immutable).
    function entropyModule() external view returns (address);
    /// @notice The 6529 Editions contract allowed to link editions, or zero before it is set.
    function editions() external view returns (address);
    /// @notice Sets the 6529 Editions contract. SUCCESSOR_SETTER role, compare-and-set.
    function setEditions(address expected, address next) external;

    // ----- collections and supply -----

    /// @notice Creates a collection and returns its ID (sequential, from 1). PLATFORM role.
    function createCollection(string calldata name, bytes32 metadataHash)
        external
        returns (uint256 collectionId);
    /// @notice A collection. Reverts with `UnknownCollection` for an unknown ID.
    function collection(uint256 collectionId) external view returns (Collection memory);
    /// @notice The number of collections created.
    function collectionCount() external view returns (uint256);
    /// @notice The number of tokens ever minted, which is also the highest token ID.
    function totalMinted() external view returns (uint256);
    /// @notice The number of live tokens (minted minus burned).
    function totalSupply() external view returns (uint256);

    // ----- works -----

    /// @notice A work's on-chain state. Reverts with `UnknownWork` for a burned or unminted ID.
    function work(uint256 tokenId) external view returns (WorkInfo memory);
    /// @notice A work's current record. Reverts if no record has been published yet.
    function workRecord(uint256 tokenId) external view returns (Work memory);
    /// @notice The hash every finalize and artist co-signature binds to.
    function workStateHash(uint256 tokenId) external view returns (bytes32);
    /// @notice The work's license.
    function licenseOf(uint256 tokenId) external view returns (License memory);
    /// @notice The work's seed policy and seed. `available` is false while a VRF seed is
    ///         outstanding, and true otherwise (an ARTIST seed, or NONE with a zero seed).
    function seedOf(uint256 tokenId)
        external
        view
        returns (SeedPolicy policy, bytes32 seed, bool available);
    /// @notice The royalty terms locked at mint (or changed since by agreement): receiver and
    ///         rate out of 100,000. `royaltyInfo` reads the same storage and makes no external
    ///         call.
    function royaltyOf(uint256 tokenId) external view returns (address receiver, uint32 rate);

    /// @notice Stores a work record. The artist may store any valid record until finalize;
    ///         anyone may store the record whose hash is the committed `metadataHash` (publishing
    ///         the approved record). Emits `WorkRecordSet` and `MetadataUpdate`.
    /// @param tokenId The work.
    /// @param record The record; `media[0]` must be the PRIMARY file equal to the content ID,
    ///        every file must be registered in the content store, and the record must respect
    ///        the `Work` limits.
    /// @param expectedStateHash The current `workStateHash`.
    function setWorkRecord(uint256 tokenId, Work calldata record, bytes32 expectedStateHash)
        external;

    /// @notice The artist finalizes the work: the record becomes immutable and the current
    ///         default renderer is pinned (ADR 0001 section 10). Requires a published record.
    /// @param tokenId The work.
    /// @param expectedStateHash The current `workStateHash`, which commits to the renderer.
    function finalize(uint256 tokenId, bytes32 expectedStateHash) external;

    /// @notice Marks the work on-chain complete once every media file is complete in the
    ///         content store. Permissionless and one-way; reverts with `NotOnChainComplete`
    ///         otherwise. Emits `WorkOnChainComplete` and `MetadataUpdate`.
    function syncOnChain(uint256 tokenId) external;

    // ----- amendments: artist agreement plus a governed action (ADR 0001 sections 7, 8, 10) --

    /// @notice Changes a work's license toward more permissive terms. PARAMETER_SETTER role
    ///         plus the artist's EIP-712 co-signature over
    ///         `WorkAmendment(uint256 tokenId,bytes4 action,bytes32 payloadHash,bytes32 stateHash,
    ///         uint64 deadline)` with `action` this selector and `payloadHash`
    ///         `keccak256(abi.encode(next))`. Reverts with `LicenseIrrevocable` for a CC0 work.
    function relicense(
        uint256 tokenId,
        License calldata next,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external;

    /// @notice Changes a work's royalty terms. FUNDS_SETTER role plus the artist's
    ///         `WorkAmendment` co-signature with `payloadHash`
    ///         `keccak256(abi.encode(receiver, rate))`.
    function setRoyalty(
        uint256 tokenId,
        address receiver,
        uint32 rate,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external;

    /// @notice The errata path: pins a new renderer on a finalized work. SUCCESSOR_SETTER role
    ///         (30-day delay) plus the artist's `WorkAmendment` co-signature with `payloadHash`
    ///         `keccak256(abi.encode(renderer))`. Emits `RendererRepinned`.
    function repinRenderer(
        uint256 tokenId,
        address renderer,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external;

    // ----- rendering -----

    /// @notice The renderer of works that are not finalized.
    function defaultRenderer() external view returns (address);
    /// @notice Sets the default renderer. SUCCESSOR_SETTER role, compare-and-set. Finalized
    ///         works keep their pin.
    function setDefaultRenderer(address expected, address next) external;
    /// @notice The renderer serving a work: its pin once finalized, the default before.
    function rendererOf(uint256 tokenId) external view returns (address);

    // ----- locators and preferred location (ADR 0001 section 8) -----

    /// @notice Appends a locator for one of the work's files: the content ID or a file in the
    ///         published media list. Callable by the artist or the PLATFORM role, also after
    ///         finalize (delivery routing stays operable). At most
    ///         `Limits.MAX_LOCATORS_PER_FILE` per file and `Limits.MAX_URI_BYTES` per URI.
    function addLocator(uint256 tokenId, bytes32 fileId, Locator calldata locator) external;
    /// @notice A file's registered locators, in registration order.
    function locators(uint256 tokenId, bytes32 fileId) external view returns (Locator[] memory);
    /// @notice The locator `tokenURI` serves for a file: the first match of the global preferred
    ///         kind, then the collection's preferred kind, then the file's preferred index, then
    ///         the first registered locator. A kind matches only if the file has a locator of
    ///         that kind (ONCHAIN only if the file is complete), and then its first such locator
    ///         is used. Reverts if the file has no locator at all.
    /// @return locator The chosen locator.
    /// @return index Its registration index, or `type(uint256).max` for the implicit ONCHAIN one.
    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (Locator memory locator, uint256 index);
    /// @notice Sets the global preferred kind (NONE clears it). STORAGE_OPERATOR role.
    function setPreferredKind(LocatorKind kind) external;
    /// @notice Sets a collection's preferred kind (NONE clears it). STORAGE_OPERATOR role.
    function setCollectionPreferredKind(uint256 collectionId, LocatorKind kind) external;
    /// @notice Sets a file's preferred locator index (`type(uint256).max` clears it).
    ///         STORAGE_OPERATOR role. The index must be registered.
    function setFilePreference(uint256 tokenId, bytes32 fileId, uint256 index) external;
    /// @notice The global preferred kind.
    function preferredKind() external view returns (LocatorKind);
    /// @notice A collection's preferred kind.
    function collectionPreferredKind(uint256 collectionId) external view returns (LocatorKind);
    /// @notice A file's preferred locator index, or `type(uint256).max`.
    function filePreference(uint256 tokenId, bytes32 fileId) external view returns (uint256);

    // ----- edition link (ADR 0001 section 6) -----

    /// @notice The 6529 Editions edition an EDITION_MASTER work anchors, or zeros if none.
    function editionOf(uint256 tokenId)
        external
        view
        returns (address editionsContract, uint256 editionId);
    /// @notice Records the edition of an EDITION_MASTER work, once. Callable only by `editions()`
    ///         from `IEditions.createEdition`, which records the other direction in the same
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
