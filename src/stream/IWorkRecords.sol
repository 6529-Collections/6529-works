// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Locator, LocatorKind } from "../interfaces/types/ContentTypes.sol";
import { License, PackageItem, Party, SeedPolicy } from "../interfaces/types/PackageTypes.sol";

/// @title IWorkRecords
/// @notice DRAFT, local to the stream lane: the records satellite of 6529 Stream (integrator
///         decisions D1, D2, D9, D10, D11, D19, D20 and D24), until the interfaces lane publishes
///         `IWorkRecords`. The integrator reconciles the two.
/// @dev A work's records open with `register`, which anyone may call with the token's approved
///      package item (checked against the item hash the core stored at mint) and its media list.
///      The descriptive record is a JSON file in the content store; the lead artist may point the
///      work at a new record file until finalize, which pins the default renderer. Media never
///      changes after approval. Locators are append-only copies of media files; the storage
///      operator only chooses among them. The version, and so the state hash, changes only on a
///      real change: a new record file, a license or royalty-rate change, finalize, or a renderer
///      repin. Permissionless actions (`register`, `syncOnChain`, `addLocator`) never change it.
interface IWorkRecords {
    /// @notice A registered work's record state.
    /// @param record The content-store file ID of the current JSON record.
    /// @param renderer The pinned renderer, zero before finalize.
    struct RecordState {
        bytes32 record;
        address renderer;
        uint32 version;
        uint8 mediaCount;
        SeedPolicy seedPolicy;
        bool finalized;
        bool onChainComplete;
    }

    /// @notice A work's records were opened from its approved item.
    event WorkRegistered(uint256 indexed tokenId, bytes32 record, bytes32[] media);
    /// @notice The lead artist pointed the work at a new record file.
    event RecordSet(uint256 indexed tokenId, bytes32 previous, bytes32 next, bytes32 stateHash);
    /// @notice The lead artist finalized the work and `renderer` was pinned.
    event WorkFinalized(uint256 indexed tokenId, address renderer, bytes32 stateHash);
    /// @notice Every media file is complete in the content store (permanent).
    event WorkOnChainComplete(uint256 indexed tokenId);
    /// @notice The errata path replaced a finalized work's renderer pin (ADR 0001 section 10).
    event RendererRepinned(uint256 indexed tokenId, address previous, address next);
    /// @notice A license or royalty-rate amendment took effect with every party's consent.
    event WorkAmended(uint256 indexed tokenId, bytes4 indexed action, bytes32 stateHash);
    /// @notice A locator was appended for a media file.
    event LocatorAdded(
        uint256 indexed tokenId, bytes32 indexed fileId, uint256 index, Locator locator
    );
    /// @notice The global preferred kind changed.
    event PreferredKindSet(LocatorKind previous, LocatorKind next);
    /// @notice A collection's preferred kind changed.
    event CollectionPreferredKindSet(
        uint256 indexed collectionId, LocatorKind previous, LocatorKind next
    );
    /// @notice A file's preferred locator index changed (`type(uint256).max` means none).
    event FilePreferenceSet(
        uint256 indexed tokenId, bytes32 indexed fileId, uint256 previous, uint256 next
    );

    /// @notice The token is not live in the core, or its records are not registered.
    error UnknownWork(uint256 tokenId);
    /// @notice The work's records are already registered.
    error AlreadyRegistered(uint256 tokenId);
    /// @notice The item does not hash to the token's stored item hash.
    error ItemMismatch(uint256 tokenId);
    /// @notice The media list is empty, too long, repeats a file, does not start with the
    ///         item's content ID, or names an unregistered file.
    error InvalidMedia();
    /// @notice The record file is not a complete `application/json` content-store file.
    error InvalidRecord(bytes32 fileId);
    /// @notice The caller is not the work's lead artist.
    error NotWorkArtist(uint256 tokenId, address caller);
    /// @notice The work is finalized, so its record can no longer change.
    error WorkIsFinalized(uint256 tokenId);
    /// @notice Only a finalized work has a renderer pin to replace.
    error WorkNotFinalized(uint256 tokenId);
    /// @notice The state hash is not the one the caller or signers expected.
    error StateHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice A media file still lacks chunks in the content store.
    error NotOnChainComplete(uint256 tokenId);
    /// @notice The parties do not hash to the registered parties.
    error PartiesMismatch(uint256 tokenId);
    /// @notice A consent is missing, expired, or not by the party's current authority.
    error InvalidConsent(uint256 tokenId, address party);
    /// @notice The renderer is not a contract supporting `IRenderer`.
    error InvalidRenderer(address renderer);
    /// @notice The file is not one of the work's media files.
    error FileNotInWork(uint256 tokenId, bytes32 fileId);
    /// @notice The locator kind is not ARWEAVE or IPFS, its URI is malformed, or the file
    ///         already has `Limits.MAX_LOCATORS_PER_FILE` locators.
    error InvalidLocator();
    /// @notice The preference names HTTPS, or an index with no locator.
    error InvalidPreference();
    /// @notice The file has no registered locator and is not on-chain complete.
    error NoLocator(uint256 tokenId, bytes32 fileId);
    /// @notice A dependency has no code or is an EIP-7702 delegated account.
    error InvalidDependency(address dependency);

    /// @notice The core token (immutable).
    function stream() external view returns (address);

    /// @notice Opens a work's records from its approved item: the record file it names, its
    ///         media list, its parties (for consents) and its seed.
    function register(uint256 tokenId, PackageItem calldata item, bytes32[] calldata media) external;

    /// @notice Points the work at a new JSON record file. The lead artist, before finalize. An
    ///         identical record is a no-op.
    function setRecord(uint256 tokenId, bytes32 record, bytes32 expectedStateHash) external;

    /// @notice The lead artist finalizes the work: the record is fixed and the core's default
    ///         renderer is pinned.
    function finalize(uint256 tokenId, bytes32 expectedStateHash) external;

    /// @notice Marks the work on-chain complete once every media file is complete. Permissionless,
    ///         one-way, and idempotent.
    function syncOnChain(uint256 tokenId) external;

    /// @notice Relicenses the work through the core. PARAMETER_SETTER role plus the consent of
    ///         every party listed in the item, each signing `Relicense` by its current authority.
    function relicense(
        uint256 tokenId,
        Party[] calldata parties,
        License calldata next,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata signatures
    ) external;

    /// @notice Changes the work's royalty rate through the core (the receiver is fixed).
    ///         FUNDS_SETTER role plus every party's `RoyaltyChange` consent.
    function setRoyaltyRate(
        uint256 tokenId,
        Party[] calldata parties,
        uint32 rate,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata signatures
    ) external;

    /// @notice The errata path: pins a new renderer on a finalized work. SUCCESSOR_SETTER role
    ///         (30-day delay) plus the lead artist's `RendererRepin` consent.
    function repinRenderer(
        uint256 tokenId,
        address renderer,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata signature
    ) external;

    /// @notice A registered work's record state.
    function recordState(uint256 tokenId) external view returns (RecordState memory);
    /// @notice A registered work's media file IDs, primary first.
    function media(uint256 tokenId) external view returns (bytes32[] memory);
    /// @notice The hash every finalize, record change and consent binds to.
    function workStateHash(uint256 tokenId) external view returns (bytes32);
    /// @notice The renderer pinned by finalize or the errata path, or zero.
    function pinnedRenderer(uint256 tokenId) external view returns (address);
    /// @notice The seed policy and seed; `available` is false while a VRF seed is outstanding.
    function seedOf(uint256 tokenId)
        external
        view
        returns (SeedPolicy policy, bytes32 seed, bool available);

    /// @notice Appends a locator for a media file. The lead artist or the PLATFORM role, also
    ///         after finalize. ARWEAVE (`ar://`) and IPFS (`ipfs://`) only.
    function addLocator(uint256 tokenId, bytes32 fileId, Locator calldata locator) external;
    /// @notice A file's locators, in registration order.
    function locators(uint256 tokenId, bytes32 fileId) external view returns (Locator[] memory);
    /// @notice The locator `tokenURI` serves for a file: the file override, then the collection
    ///         kind, then the global kind, then the first registered locator (D10). A kind
    ///         matches only if the file has a locator of that kind (ONCHAIN only if the file is
    ///         complete), and its first such locator is used. With no registered locator, a
    ///         complete file resolves to the implicit ONCHAIN locator.
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
    ///         STORAGE_OPERATOR role.
    function setFilePreference(uint256 tokenId, bytes32 fileId, uint256 index) external;
    /// @notice The global preferred kind.
    function preferredKind() external view returns (LocatorKind);
    /// @notice A collection's preferred kind.
    function collectionPreferredKind(uint256 collectionId) external view returns (LocatorKind);
    /// @notice A file's preferred locator index, or `type(uint256).max`.
    function filePreference(uint256 tokenId, bytes32 fileId) external view returns (uint256);
}
