// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { License, PackageItem } from "./types/PackageTypes.sol";
import { Locator, LocatorKind, MediaFile } from "./types/ContentTypes.sol";

/// @title IWorkRecords
/// @notice The 6529 Stream records satellite: each work's descriptive record, media, license,
///         finalize and renderer pin, and its locators and preferred location (ADR 0001
///         sections 8 and 10). 6529 Stream core holds the token; this holds what describes it.
/// @dev Records are files. A work's descriptive record is a UTF-8 JSON object in the content
///      store (RFC 8785 canonical; keys `name`, `description`, `artists`, `year`, `medium`,
///      `dimensions`, `attributes` as `[{trait_type, value}]`, `dependencies` as
///      `[{name, version}]`, and `files` mapping relative paths to media indexes); this contract
///      stores only its file ID. A record opens with the approved file and the approved media;
///      until finalize the artist may point the work at a new record file, but media never
///      changes.
///
///      "The artist" is the current authority of the work's lead artist ID. The state hash
///      commits to the token ID, the version, the record file ID, the license key and text, the
///      royalty rate and the effective renderer. The version bumps only on a real change (a new
///      record pointer, license, royalty rate or renderer pin); an identical re-publish is a
///      no-op, and permissionless actions (`syncOnChain`, `addLocator`) never change it. Every
///      finalize and signature binds the state hash, so nothing applies to a state its signer
///      did not see. Every visible change asks 6529 Stream to emit ERC-4906 and, for an edition
///      master, calls `IEditions.notifyMasterUpdated` (this satellite is bound in both).
///
///      Governed functions are non-payable; each names the `Roles` role its selector maps to.
interface IWorkRecords {
    /// @notice A work's record state.
    /// @param recordFileId The content-store file ID of the current descriptive record.
    /// @param mediaHash The approved media commitment (`PackageItem.mediaHash`).
    /// @param licenseKey The canonical key of the current license.
    /// @param renderer The pinned renderer once finalized, else zero.
    struct RecordInfo {
        bytes32 recordFileId;
        bytes32 mediaHash;
        bytes32 licenseKey;
        uint32 version;
        bool opened;
        bool finalized;
        bool onChainComplete;
        address renderer;
    }

    /// @notice A work's record was opened from its approved item and media.
    event RecordOpened(uint256 indexed tokenId, bytes32 recordFileId, bytes32 mediaHash);
    /// @notice The artist pointed a work at a new record file.
    event RecordSet(uint256 indexed tokenId, bytes32 recordFileId, bytes32 stateHash);
    /// @notice The artist finalized a work: the record is immutable and `renderer` is pinned.
    event WorkFinalized(uint256 indexed tokenId, address renderer, bytes32 stateHash);
    /// @notice Every media file of the work is stored on-chain; on-chain bytes are permanent.
    event WorkOnChainComplete(uint256 indexed tokenId);
    /// @notice A work's license changed, by every party's agreement plus a governed action.
    event LicenseChanged(uint256 indexed tokenId, License previous, License next);
    /// @notice The errata path replaced a finalized work's renderer pin (ADR 0001 section 10).
    event RendererRepinned(uint256 indexed tokenId, address previous, address next);
    /// @notice A locator was appended for one media file of a work.
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

    /// @notice The work has no open record.
    error RecordNotOpen(uint256 tokenId);
    /// @notice The work's record is already open.
    error RecordAlreadyOpen(uint256 tokenId);
    /// @notice The item or media does not match the work's committed item hash, the media
    ///         commitment, the content hash, the content store's declared SHA-256 or a limit.
    error InvalidRecordData(uint256 tokenId);
    /// @notice The record file is not registered in the content store.
    error UnknownRecordFile(bytes32 recordFileId);
    /// @notice The caller is not the work's artist.
    error NotWorkArtist(uint256 tokenId, address caller);
    /// @notice The work is finalized, so its record can no longer change.
    error WorkIsFinalized(uint256 tokenId);
    /// @notice The work's state hash is not the one the caller or signers expected.
    error StateHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice A party signature is missing, expired or does not verify.
    error InvalidConsent(uint256 tokenId, uint256 partyIndex);
    /// @notice A CC0 dedication is irrevocable, so the license cannot change.
    error LicenseIrrevocable(uint256 tokenId);
    /// @notice The file is not one of the work's media files.
    error FileNotInWork(uint256 tokenId, bytes32 fileId);
    /// @notice The locator kind is NONE or ONCHAIN, the URI is malformed, or the file already has
    ///         `Limits.MAX_LOCATORS_PER_FILE` locators.
    error InvalidLocator();
    /// @notice A media file still lacks chunks in the content store.
    error NotOnChainComplete(uint256 tokenId);

    /// @notice The 6529 Stream core this satellite serves (immutable).
    function stream() external view returns (address);

    // ----- records -----

    /// @notice Opens a work's record from its approved item and media. Permissionless (off the
    ///         auction-start path). Checks the item against Stream's stored item hash, `media`
    ///         against `item.mediaHash`, the first file's SHA-256 against `item.contentHash`, and
    ///         each file's declared SHA-256 against `IContentStore.sha256Of`; stores the record
    ///         file ID, the media file IDs and a non-CC0 license.
    function openRecord(uint256 tokenId, PackageItem calldata item, MediaFile[] calldata media)
        external;
    /// @notice The artist points the work at a new record file, registered in the content store,
    ///         until finalize. Re-publishing the current file is a no-op.
    function setRecord(uint256 tokenId, bytes32 recordFileId, bytes32 expectedStateHash) external;
    /// @notice The artist finalizes the work: the record becomes immutable and Stream's current
    ///         default renderer is pinned (ADR 0001 section 10).
    function finalize(uint256 tokenId, bytes32 expectedStateHash) external;
    /// @notice Marks the work on-chain complete once every media file is complete in the
    ///         content store. Permissionless and one-way; does not change the state hash.
    function syncOnChain(uint256 tokenId) external;

    /// @notice A work's record state.
    function record(uint256 tokenId) external view returns (RecordInfo memory);
    /// @notice A work's media, in approved order (primary first).
    function mediaOf(uint256 tokenId) external view returns (MediaFile[] memory);
    /// @notice A work's license: the stored one, or CC0 when none is stored.
    function licenseOf(uint256 tokenId) external view returns (License memory);
    /// @notice The hash every finalize and signature binds to.
    function workStateHash(uint256 tokenId) external view returns (bytes32);
    /// @notice The pinned renderer of a finalized work, or zero.
    function pinnedRenderer(uint256 tokenId) external view returns (address);

    // ----- amendments: agreement plus a governed action (ADR 0001 sections 7, 8 and 10) -----

    /// @notice Changes a work's license toward more permissive terms. PARAMETER_SETTER role plus
    ///         an EIP-712 `Typehashes.RELICENSE` signature from every party of `item`, in order,
    ///         each by its current authority. Reverts with `LicenseIrrevocable` when the current
    ///         license key is `WorksHashing.CC0_LICENSE_KEY`.
    function relicense(
        uint256 tokenId,
        License calldata next,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external;
    /// @notice Changes a work's royalty rate (payees never change). FUNDS_SETTER role plus a
    ///         `Typehashes.ROYALTY_RATE_CHANGE` signature from every party of `item`; calls
    ///         `IStream.setRoyaltyRate`.
    function setRoyaltyRate(
        uint256 tokenId,
        uint32 rate,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external;
    /// @notice The errata path: pins a new renderer on a finalized work. SUCCESSOR_SETTER role
    ///         (30-day delay) plus the artist's `Typehashes.RENDERER_REPIN` signature.
    function repinRenderer(
        uint256 tokenId,
        address renderer,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external;

    // ----- locators and preferred location (ADR 0001 section 8) -----

    /// @notice Appends an ARWEAVE or IPFS locator for one of the work's media files. Callable by
    ///         the artist or the PLATFORM role, also after finalize (delivery routing stays
    ///         operable). At most `Limits.MAX_URI_BYTES` per URI.
    function addLocator(uint256 tokenId, bytes32 fileId, Locator calldata locator) external;
    /// @notice A file's registered locators, in registration order.
    function locators(uint256 tokenId, bytes32 fileId) external view returns (Locator[] memory);
    /// @notice The locator `tokenURI` serves for a file. The most specific setting wins: the
    ///         file's preferred index, then the collection's preferred kind, then the global
    ///         preferred kind, then the first registered locator. A kind matches only if the file
    ///         has a locator of that kind (ONCHAIN only if the file is complete), and then its
    ///         first such locator is used. Reverts if the file has no locator at all.
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
    /// @notice Sets a file's preferred locator index (`type(uint256).max` clears it), which must
    ///         be registered. STORAGE_OPERATOR role.
    function setFilePreference(uint256 tokenId, bytes32 fileId, uint256 index) external;
    /// @notice The global preferred kind.
    function preferredKind() external view returns (LocatorKind);
    /// @notice A collection's preferred kind.
    function collectionPreferredKind(uint256 collectionId) external view returns (LocatorKind);
    /// @notice A file's preferred locator index, or `type(uint256).max`.
    function filePreference(uint256 tokenId, bytes32 fileId) external view returns (uint256);
}
