// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { License, PackageItem, SeedPolicy } from "./types/PackageTypes.sol";
import { Locator, LocatorKind, MediaFile } from "./types/ContentTypes.sol";

/// @title IWorkRecords
/// @notice The 6529 Stream records satellite: each work's descriptive record, media, license,
///         finalize and renderer pin, and its locators and preferred location (ADR 0001
///         sections 8 and 10). 6529 Stream core holds the token; this holds what describes it.
/// @dev Records are files. A work's descriptive record is a UTF-8 JSON object in the content
///      store (RFC 8785 canonical; keys `name`, `description`, `artists`, `year`, `medium`,
///      `dimensions`, `attributes` as `[{trait_type, value}]`, `dependencies` as
///      `[{name, version}]`, and `files` mapping relative paths to media indexes); this contract
///      stores only its file ID. A record opens with the approved file and the approved media,
///      stored as they are, so an approved record file can never keep a minted work from
///      opening. Structural bounds, enforced by `setRecord` and `finalize`, each O(1): the
///      record file is registered in the content store, complete, and a single `Identity`
///      chunk of at most `Limits.MAX_RECORD_BYTES` bytes. The JSON itself (at most
///      `Limits.MAX_ARTISTS` artists, a numeric `year`, the key set) is validated by the
///      renderer, which renders core-only metadata with a record status for an invalid or
///      out-of-bounds record. Until finalize the artist may point the work at a new record
///      file, but media never changes.
///
///      "The artist" is the active authority of the work's lead artist ID. The state hash
///      commits to the token ID, the version, the record file ID, the license key and text, the
///      royalty rate and the effective renderer. The version bumps only on a real change (a new
///      record pointer, license, royalty rate or renderer pin); an identical re-publish is a
///      no-op, and delivery actions (`syncOnChain`, `addLocator`) never change it. Every
///      finalize and signature binds the state hash, so nothing applies to a state its signer
///      did not see. Every visible change asks 6529 Stream to emit ERC-4906 and, for an edition
///      master, calls `IEditions.notifyMasterUpdated` (this satellite is bound in both).
///
///      A record must be opened first: every per-token view and mutator reverts with
///      `RecordNotOpen` until `openRecord` has run (`isOpen` tells), and the renderer falls back
///      to core-only metadata from 6529 Stream until then. Changes to the global or a collection
///      preferred kind call `IEditions.notifyAllUpdated`.
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
        bool finalized;
        bool onChainComplete;
        address renderer;
    }

    /// @notice A work's record was opened from its approved item and media.
    /// @param tokenId The work's token ID.
    /// @param recordFileId The approved record file (`PackageItem.recordFileId`).
    /// @param mediaHash The approved media commitment (`PackageItem.mediaHash`).
    event RecordOpened(uint256 indexed tokenId, bytes32 recordFileId, bytes32 mediaHash);
    /// @notice The artist pointed a work at a new record file.
    /// @param tokenId The work's token ID.
    /// @param recordFileId The new record file.
    /// @param stateHash The work's state hash after the change.
    event RecordSet(uint256 indexed tokenId, bytes32 recordFileId, bytes32 stateHash);
    /// @notice The artist finalized a work: the record is immutable and `renderer` is pinned.
    /// @param tokenId The work's token ID.
    /// @param renderer The pinned renderer: 6529 Stream's default renderer at finalize.
    /// @param stateHash The work's state hash after finalize.
    event WorkFinalized(uint256 indexed tokenId, address renderer, bytes32 stateHash);
    /// @notice Every media file of the work is stored on-chain; on-chain bytes are permanent.
    /// @param tokenId The work's token ID.
    event WorkOnChainComplete(uint256 indexed tokenId);
    /// @notice `syncOnChain` found the work's first `files` media files complete and stopped at
    ///         its chunk budget; the next call resumes there.
    /// @param tokenId The work's token ID.
    /// @param files The number of leading media files found complete so far.
    event OnChainSyncProgress(uint256 indexed tokenId, uint256 files);
    /// @notice A work's license changed, by every party's agreement plus a governed action.
    /// @param tokenId The work's token ID.
    /// @param previous The license before the change.
    /// @param next The license after the change.
    event LicenseChanged(uint256 indexed tokenId, License previous, License next);
    /// @notice A work's royalty rate changed, by every party's agreement plus a governed action
    ///         (applied in 6529 Stream and, for a linked master, its edition). `stateHash` is the
    ///         work's new state hash.
    /// @param tokenId The work's token ID.
    /// @param previous The rate before the change, out of 100,000.
    /// @param next The rate after the change, out of 100,000.
    /// @param stateHash The work's state hash after the change.
    event RoyaltyRateSet(uint256 indexed tokenId, uint32 previous, uint32 next, bytes32 stateHash);
    /// @notice The errata path replaced a finalized work's renderer pin (ADR 0001 section 10);
    ///         `codeHash` is the pinned code hash of `next`.
    /// @param tokenId The work's token ID.
    /// @param previous The renderer pinned before the change.
    /// @param next The renderer pinned after the change.
    /// @param codeHash The code hash the artist signed for `next`.
    event RendererRepinned(
        uint256 indexed tokenId, address previous, address next, bytes32 codeHash
    );
    /// @notice A locator was appended for one media file of a work.
    /// @param tokenId The work's token ID.
    /// @param fileId The media file the locator names a copy of.
    /// @param index The locator's registration index among the file's locators, from 0.
    /// @param locator The locator added.
    event LocatorAdded(
        uint256 indexed tokenId, bytes32 indexed fileId, uint256 index, Locator locator
    );
    /// @notice The global preferred locator kind was set (emitted even when it is unchanged).
    /// @param previous The kind before the call.
    /// @param next The kind after the call (NONE when cleared).
    event PreferredKindSet(LocatorKind previous, LocatorKind next);
    /// @notice A collection's preferred locator kind was set (emitted even when it is unchanged).
    /// @param collectionId The 6529 Stream collection ID.
    /// @param previous The kind before the call.
    /// @param next The kind after the call (NONE when cleared).
    event CollectionPreferredKindSet(
        uint256 indexed collectionId, LocatorKind previous, LocatorKind next
    );
    /// @notice A file's preferred locator index was set (emitted even when it is unchanged;
    ///         `type(uint256).max` means none).
    /// @param tokenId The work's token ID.
    /// @param fileId The media file.
    /// @param previous The index before the call.
    /// @param next The index after the call.
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
    /// @notice The record file is not registered in the content store, or breaks a record bound.
    error UnknownRecordFile(bytes32 recordFileId);
    /// @notice The caller is not the work's artist.
    error NotWorkArtist(uint256 tokenId, address caller);
    /// @notice The work is finalized, so its record can no longer change.
    error WorkIsFinalized(uint256 tokenId);
    /// @notice The work's state hash is not the one the caller or signers expected.
    error StateHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice A party's signature does not verify, or (`partyIndex` equal to the number of
    ///         signatures given) the number of signatures is not the number of parties. An
    ///         expired consent reverts with `SignatureVerifier.SignatureExpired`.
    error InvalidConsent(uint256 tokenId, uint256 partyIndex);
    /// @notice A CC0 dedication is irrevocable, so the license key cannot change (only a CC0
    ///         text file can be corrected).
    error LicenseIrrevocable(uint256 tokenId);
    /// @notice The file is not one of the work's media files.
    error FileNotInWork(uint256 tokenId, bytes32 fileId);
    /// @notice The locator kind is NONE or ONCHAIN, the URI is not a content address of its kind
    ///         (see `Locator`) or is already registered for the file, or the caller's quota for
    ///         the file (the artist's or the platform's half of `Limits.MAX_LOCATORS_PER_FILE`)
    ///         is used up.
    error InvalidLocator();
    /// @notice A media file still lacks chunks in the content store.
    error NotOnChainComplete(uint256 tokenId);
    /// @notice The license ID is empty, too long or outside `[A-Za-z0-9.+-]`, the deployment's
    ///         default license is not CC0, a license text file declares no SHA-256, a CC0 license
    ///         (at `openRecord` or a relicense) names a text other than the deployment's CC0
    ///         text, or a license text that must be permanent (at finalize, or relicensing a
    ///         finalized work) is not complete on-chain.
    error InvalidLicense();
    /// @notice The work is not finalized (an errata repin needs a finalized work).
    error WorkNotFinalized(uint256 tokenId);

    /// @notice The 6529 Stream core this satellite serves (immutable).
    /// @return The 6529 Stream contract.
    function stream() external view returns (address);

    // ----- records -----

    /// @notice Opens a work's record from its approved item and media. Permissionless (off the
    ///         auction-start path). Checks the item against Stream's stored item hash, `media`
    ///         against `item.mediaHash`, the first file's SHA-256 against `item.contentHash`,
    ///         each file's declared SHA-256 against `IContentStore.sha256Of`, and the size of
    ///         each PREVIEW file stored as `Identity` or `Base64` against
    ///         `Limits.MAX_PREVIEW_BYTES` (an `Identity` file counting four times, so `tokenURI`
    ///         keeps its 8M budget); stores the record
    ///         file ID, the media file IDs, an ARTIST seed and a non-CC0 license as approved.
    ///         Neither the record file's bounds nor the license text are checked here, so
    ///         neither can freeze a minted work: `setRecord` corrects a record before finalize,
    ///         and `finalize` enforces both. The exception is CC0, which can never be left or
    ///         corrected: a license whose key is CC0 must name the deployment's CC0 text
    ///         (`InvalidLicense`).
    /// @dev The media commitments are not visible at mint, so a mis-committed item mints and can
    ///      never open: the curation signer's tooling MUST simulate `openRecord` for an item
    ///      before attesting it. The license ID is checked at mint by 6529 Stream.
    /// @param tokenId A live 6529 Stream token whose record is not open yet.
    /// @param item The work's approved package item, which must hash to the item hash 6529
    ///        Stream stored.
    /// @param media The work's media files in approved order, primary first (1 to
    ///        `Limits.MAX_MEDIA_FILES`).
    function openRecord(uint256 tokenId, PackageItem calldata item, MediaFile[] calldata media)
        external;
    /// @notice The artist points the work at a new record file, which must meet the structural
    ///         bounds, until finalize. Re-publishing the current file is a no-op.
    /// @param tokenId A work with an open record, not finalized.
    /// @param recordFileId The new record file: registered, complete, `Identity` and at most
    ///        `Limits.MAX_RECORD_BYTES` (`UnknownRecordFile` otherwise).
    /// @param expectedStateHash The work's current state hash (`StateHashMismatch` otherwise).
    function setRecord(uint256 tokenId, bytes32 recordFileId, bytes32 expectedStateHash) external;
    /// @notice The artist finalizes the work: the record becomes immutable and Stream's current
    ///         default renderer is pinned (ADR 0001 section 10). The record file must meet the
    ///         structural bounds, completeness included, and the license text must be complete
    ///         on-chain, so a finalized work's record and license text are permanent and
    ///         readable.
    /// @param tokenId A work with an open record, not finalized.
    /// @param expectedStateHash The work's current state hash (`StateHashMismatch` otherwise).
    function finalize(uint256 tokenId, bytes32 expectedStateHash) external;
    /// @notice Marks the work on-chain complete once every media file is complete in the
    ///         content store. Permissionless and one-way; does not change the state hash.
    ///         Resumable: a call checks whole files, in media order, up to a budget of 512
    ///         chunks (a file of up to 512 always fits), keeps its place and emits
    ///         `OnChainSyncProgress` when the budget stops it, so a work of any size completes
    ///         over calls that each fit the EIP-7825 cap. Reverts with `NotOnChainComplete` at
    ///         the first file it finds incomplete (earlier calls' progress stays).
    /// @param tokenId A work with an open record.
    function syncOnChain(uint256 tokenId) external;

    /// @notice Whether a work's record is open. Never reverts.
    /// @param tokenId Any token ID.
    /// @return True once `openRecord` has run for the work.
    function isOpen(uint256 tokenId) external view returns (bool);
    /// @notice A work's record state.
    /// @param tokenId A work with an open record.
    /// @return The record file, media commitment, license key, version, flags and renderer pin.
    function record(uint256 tokenId) external view returns (RecordInfo memory);
    /// @notice A work's media, in approved order (primary first).
    /// @param tokenId A work with an open record.
    /// @return Each file's ID, declared SHA-256 and role.
    function mediaOf(uint256 tokenId) external view returns (MediaFile[] memory);
    /// @notice A work's license: the stored one, or CC0 when none is stored.
    /// @param tokenId A work with an open record.
    /// @return The license's SPDX ID and text file ID.
    function licenseOf(uint256 tokenId) external view returns (License memory);
    /// @notice The hash every finalize and signature binds to.
    /// @param tokenId A live work with an open record.
    /// @return The work's current state hash.
    function workStateHash(uint256 tokenId) external view returns (bytes32);
    /// @notice The pinned renderer of a finalized work, or zero. Reverts with
    ///         `Dependency.DependencyCodeChanged` when the renderer's code is no longer the code
    ///         hash it was first pinned with
    ///         (finalize pins the default renderer as Stream checked it; the errata repin pins
    ///         the hash the artist signed), so 6529 Stream's `tokenURI` fails closed until the
    ///         errata repin installs a renderer again.
    /// @param tokenId A work with an open record.
    /// @return The pinned renderer, or zero before finalize.
    function pinnedRenderer(uint256 tokenId) external view returns (address);
    /// @notice The work's seed: ARTIST seeds stored at `openRecord`, VRF seeds from the entropy
    ///         module by item hash, zero for NONE.
    /// @param tokenId A live work with an open record.
    /// @return policy The work's seed policy.
    /// @return seed The seed, or zero under NONE.
    function seedOf(uint256 tokenId) external view returns (SeedPolicy policy, bytes32 seed);

    // ----- amendments: agreement plus a governed action (ADR 0001 sections 7, 8 and 10) -----

    /// @notice Changes a work's license toward more permissive terms. PARAMETER_SETTER role plus
    ///         an EIP-712 `Typehashes.RELICENSE` signature from every party of `item`, in order,
    ///         each by its active authority. Reverts with `LicenseIrrevocable` when the current
    ///         license key is `WorksHashing.CC0_LICENSE_KEY` and `next`'s is not. A CC0 license
    ///         names the deployment's CC0 text (`InvalidLicense` otherwise), as `openRecord`
    ///         requires too, so a CC0 work's license never changes. The new license's text file
    ///         must be registered in the
    ///         content store, and complete on-chain for a finalized work. Only CC0
    ///         irrevocability is enforced on-chain; whether `next` is more permissive rests with
    ///         the consents and the governed action.
    /// @param tokenId A live work with an open record.
    /// @param next The new license: an SPDX ID and its text file in the content store.
    /// @param item The work's approved package item, whose parties consent
    ///        (`InvalidRecordData` unless it hashes to the item hash 6529 Stream stored).
    /// @param expectedStateHash The work's current state hash, which every signature binds.
    /// @param deadline The consents' deadline, inclusive, in seconds since the epoch; it must
    ///        cover the AccessManager delay.
    /// @param partySignatures One signature per party of `item`, in party order.
    function relicense(
        uint256 tokenId,
        License calldata next,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external;
    /// @notice Changes a work's royalty rate (payees never change). FUNDS_SETTER role plus a
    ///         `Typehashes.ROYALTY_RATE_CHANGE` signature from every party of `item`. Bumps the
    ///         version before its external calls, calls `IStream.setRoyaltyRate` and, for an
    ///         edition master, `IEditions.setRoyaltyRate` on the linked edition, then emits
    ///         `RoyaltyRateSet` and ERC-4906. An unchanged rate is a no-op.
    /// @param tokenId A live work with an open record.
    /// @param rate The new royalty rate, out of 100,000 (6529 Stream refuses more).
    /// @param item The work's approved package item, whose parties consent
    ///        (`InvalidRecordData` unless it hashes to the item hash 6529 Stream stored).
    /// @param expectedStateHash The work's current state hash, which every signature binds.
    /// @param deadline The consents' deadline, inclusive, in seconds since the epoch; it must
    ///        cover the AccessManager delay.
    /// @param partySignatures One signature per party of `item`, in party order.
    function setRoyaltyRate(
        uint256 tokenId,
        uint32 rate,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external;
    /// @notice The errata path: pins a new renderer (ERC-165 checked for `IRenderer`, code hash
    ///         `rendererCodeHash`, not an EIP-7702 delegated account) on a finalized work.
    ///         SUCCESSOR_SETTER role (30-day delay) plus the artist's `Typehashes.RENDERER_REPIN`
    ///         signature, which binds the code hash.
    /// @param tokenId A finalized work (`WorkNotFinalized` otherwise).
    /// @param renderer The new renderer.
    /// @param rendererCodeHash The code hash `renderer` must have, which it is pinned with.
    /// @param expectedStateHash The work's current state hash, which the signature binds.
    /// @param deadline The signature's deadline, inclusive, in seconds since the epoch; it must
    ///        cover the AccessManager delay.
    /// @param artistSignature The signature of the active authority of the work's lead artist.
    function repinRenderer(
        uint256 tokenId,
        address renderer,
        bytes32 rendererCodeHash,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external;

    // ----- locators and preferred location (ADR 0001 section 8) -----

    /// @notice Appends an ARWEAVE or IPFS locator for one of the work's media files. Callable by
    ///         the artist until finalize, and by the PLATFORM role also after it (delivery routing
    ///         stays operable). The URI must be a content address with nothing after it: `ar://`
    ///         and a 43-character transaction ID, or `ipfs://` and a CIDv1 of the fixed profile
    ///         (see `Locator`). Each file takes at most half of `Limits.MAX_LOCATORS_PER_FILE` (8)
    ///         from the artist and half from the platform, so neither can exhaust the other's, and
    ///         a URI already registered for the file is refused (`InvalidLocator`). After finalize
    ///         only the PLATFORM role adds locators (the artist's call is then unauthorized):
    ///         "Final" fixes the content, and since the content a locator names is not verified
    ///         on-chain, a finalized work's copies are the platform's to register and the storage
    ///         operator's to choose. The platform may then use the file's whole
    ///         `Limits.MAX_LOCATORS_PER_FILE`, the artist's unused slots included.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files (`FileNotInWork` otherwise).
    /// @param locator The ARWEAVE or IPFS locator of a copy of that file.
    function addLocator(uint256 tokenId, bytes32 fileId, Locator calldata locator) external;
    /// @notice A file's registered locators, in registration order.
    /// @param tokenId A work with an open record.
    /// @param fileId Any file ID; one that is not in the work has none.
    /// @return The file's locators.
    function locators(uint256 tokenId, bytes32 fileId) external view returns (Locator[] memory);
    /// @notice The locator `tokenURI` serves for a file. The most specific setting wins: the
    ///         file's preferred index, then the collection's preferred kind, then the global
    ///         preferred kind, then the first registered locator, then the implicit ONCHAIN copy.
    ///         A kind matches only if the file has a locator of that kind, and then its first
    ///         such locator is used; ONCHAIN matches only a work `syncOnChain` marked on-chain
    ///         complete (the stored flag, never a content-store scan). Returns an empty locator
    ///         (kind NONE) when nothing matches.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files (`FileNotInWork` otherwise).
    /// @return locator The chosen locator.
    /// @return index Its registration index, or `type(uint256).max` for the implicit ONCHAIN one
    ///         and for none.
    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (Locator memory locator, uint256 index);
    /// @notice Sets the global preferred kind (NONE clears it). STORAGE_OPERATOR role.
    /// @param kind The new global preferred kind.
    function setPreferredKind(LocatorKind kind) external;
    /// @notice Sets a collection's preferred kind (NONE clears it). STORAGE_OPERATOR role.
    /// @param collectionId An existing 6529 Stream collection (`IStream.UnknownCollection`
    ///        otherwise).
    /// @param kind The collection's new preferred kind.
    function setCollectionPreferredKind(uint256 collectionId, LocatorKind kind) external;
    /// @notice Sets a file's preferred locator index (`type(uint256).max` clears it), which must
    ///         be registered. STORAGE_OPERATOR role.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files (`FileNotInWork` otherwise).
    /// @param index An index into the file's locators (`InvalidLocator` otherwise), or
    ///        `type(uint256).max`.
    function setFilePreference(uint256 tokenId, bytes32 fileId, uint256 index) external;
    /// @notice The global preferred kind.
    /// @return The kind, or NONE when unset.
    function preferredKind() external view returns (LocatorKind);
    /// @notice A collection's preferred kind.
    /// @param collectionId Any collection ID.
    /// @return The kind, or NONE when unset.
    function collectionPreferredKind(uint256 collectionId) external view returns (LocatorKind);
    /// @notice A file's preferred locator index, or `type(uint256).max`.
    /// @param tokenId A work with an open record.
    /// @param fileId Any file ID.
    /// @return The index into the file's locators, or `type(uint256).max` when unset.
    function filePreference(uint256 tokenId, bytes32 fileId) external view returns (uint256);
}
