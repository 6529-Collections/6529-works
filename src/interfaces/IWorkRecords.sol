// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IWorkDelivery } from "./IWorkDelivery.sol";
import { MediaFile } from "./types/ContentTypes.sol";
import { License, PackageItem } from "./types/PackageTypes.sol";

/// @title IWorkRecords
/// @notice The 6529 Stream records satellite: each work's descriptive record, media, license,
///         seed, state hash, finalize and renderer pin, amendments, on-chain completeness and
///         the store holding each media file (ADR 0001 sections 8 and 10). 6529 Stream core
///         holds the token; this holds the facts that describe it. Delivery (locators, kinds,
///         preferences) lives in a replaceable contract behind `delivery()`, which can never
///         change a fact here.
/// @dev Permanent: 6529 Stream and 6529 Stream Editions bind this contract once, so this
///      interface and its ERC-165 ID are frozen at launch.
///
///      Records are files. A work's descriptive record is a UTF-8 JSON object in the content
///      store (RFC 8785 canonical; keys `name`, `description`, `artists`, `year`, `medium`,
///      `dimensions`, `attributes` as `[{trait_type, value}]`, `dependencies` as
///      `[{name, version}]`, and `files` mapping relative paths to media indexes); this contract
///      stores only its file ID. A record opens with the approved file and the approved media,
///      stored as they are, so an approved record file can never keep a minted work from
///      opening. Structural bounds, enforced by `setRecord` and `finalize`, each O(1): the
///      record file is registered in the content store, complete, `Identity` with a SHA-256
///      digest, and one chunk (`IContentStore.CHUNK_SIZE`, 24,575 bytes), a structural bound that
///      keeps every check O(1). No renderer budget is held here: the pinned renderer decides what
///      it can show (it validates the JSON and its size, and renders core-only metadata with a
///      record status for a record it refuses), and what it inlines of a preview.
///
///      "The artist" is any wallet of the work's lead artist account (`IAccounts.isWallet` on
///      6529 Stream's artist registry): the root or a wallet consolidated with it. The state hash
///      commits to the token ID, the version, the record file ID, the license key and text, the
///      royalty rate and the effective renderer. The version bumps only on a real change (a new
///      record pointer, license, royalty rate or renderer pin, finalize, or a renunciation
///      through `IWorkPowers.renounce`); an identical re-publish is a no-op, and permissionless
///      or delivery actions (`syncOnChain`, everything in the delivery contract) never change it.
///      Every finalize and signature binds the state hash (compare-and-set), so nothing applies
///      to a state its signer did not see. Every visible change asks 6529 Stream to emit
///      ERC-4906 and, for an edition master, calls `IEditions.notifyMasterUpdated`.
///
///      Item kinds, seed policies and party roles are open `uint8`s in the shared package types
///      (`PackageItem`, `MediaFile`), so an item a future mint policy defines with a new value
///      still opens. Media roles are open too, but only 0 to 15: a file's role is stored in four
///      bits (a storage-layout bound fixed for good), so an item with a media role above 15 can
///      never open (`InvalidRecordData`), and a mint policy must refuse one.
///
///      Logs only: every fact here can be rebuilt from this contract's events, with 6529
///      Stream's (rate, default renderer) for the state hash.
///
///      Governed functions are non-payable; each names the role its selector maps to.
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

    /// @notice A work's record was opened from its approved item and media. Carries every fact
    ///         the open fixes, so the record can be rebuilt from logs: the record file, media
    ///         commitment, initial license, seed policy, parties and payees with their shares
    ///         are fields of `item`, whose `WorksHashing.itemHash` is the item hash 6529 Stream
    ///         stored at mint.
    /// @param tokenId The work's token ID.
    /// @param item The work's approved package item.
    /// @param media The approved media list, primary first (`item.mediaHash` commits to it).
    /// @param licenseKey The initial license's canonical key.
    /// @param seed The seed fixed at open: the entropy module's for VRF, zero for NONE, and the
    ///        item's own for ARTIST and for any policy value this contract does not define.
    event RecordOpened(
        uint256 indexed tokenId,
        PackageItem item,
        MediaFile[] media,
        bytes32 licenseKey,
        bytes32 seed
    );
    /// @notice The artist pointed a work at a new record file.
    /// @param tokenId The work's token ID.
    /// @param recordFileId The new record file.
    /// @param stateHash The work's state hash after the change.
    event RecordSet(uint256 indexed tokenId, bytes32 recordFileId, bytes32 stateHash);
    /// @notice A work was finalized (by the artist, or by anyone 14 days after a recorded
    ///         notice): the record is immutable and `renderer` is pinned.
    /// @param tokenId The work's token ID.
    /// @param renderer The pinned renderer: 6529 Stream's default renderer at finalize, pinned
    ///        with the code hash 6529 Stream installed it with.
    /// @param stateHash The work's state hash after finalize.
    event WorkFinalized(uint256 indexed tokenId, address renderer, bytes32 stateHash);
    /// @notice Every media file of the work is complete in some store (the content store or an
    ///         added store, per file: `MediaFileComplete`); one-way.
    /// @param tokenId The work's token ID.
    event WorkOnChainComplete(uint256 indexed tokenId);
    /// @notice Media file `index` of the work is complete in store `storeId`: every chunk was
    ///         verified there. A file complete in an added store may later complete in the
    ///         content store (0), which then is its store for good (an upgrade, never undone);
    ///         the latest event for a file names its store.
    /// @param tokenId The work's token ID.
    /// @param index The media index.
    /// @param storeId The store (0 is the content store).
    event MediaFileComplete(uint256 indexed tokenId, uint256 index, uint256 storeId);
    /// @notice `syncOnChain` progress of the walk over store `storeId`. For the content store
    ///         (0): before the work is on-chain complete, the first `files` media files are
    ///         complete (in the content store, or in the added store their latest
    ///         `MediaFileComplete` names, which the walk passed over) and the next is verified up
    ///         to chunk `chunk`; afterwards, where the upgrade walk stands. For an added store:
    ///         the artist's walk stands at chunk `chunk` of file `files`. Progress is bookkeeping, not a fact: facts are `MediaFileComplete`
    ///         and `WorkOnChainComplete`.
    /// @param tokenId The work's token ID.
    /// @param files The content walk's file (every file before it complete, until on-chain
    ///        completion), or the added walk's file.
    /// @param chunk The next chunk to verify in file `files` (zero when none is in progress).
    /// @param storeId The store this call verified against.
    event OnChainSyncProgress(
        uint256 indexed tokenId, uint256 files, uint256 chunk, uint256 storeId
    );
    /// @notice A work's license changed, by every party's agreement plus a governed action.
    /// @param tokenId The work's token ID.
    /// @param previous The license before the change.
    /// @param next The license after the change.
    /// @param stateHash The work's state hash after the change.
    event LicenseChanged(
        uint256 indexed tokenId, License previous, License next, bytes32 stateHash
    );
    /// @notice A work's royalty rate changed, up or down, by every party's agreement plus the
    ///         network's action (applied in 6529 Stream and, for a linked master, its edition).
    /// @param tokenId The work's token ID.
    /// @param previous The rate before the change, out of 100,000.
    /// @param next The rate after the change, out of 100,000.
    /// @param stateHash The work's state hash after the change.
    event RoyaltyRateSet(uint256 indexed tokenId, uint32 previous, uint32 next, bytes32 stateHash);
    /// @notice The network replaced a finalized work's renderer pin (the errata repin, C8).
    /// @param tokenId The work's token ID.
    /// @param previous The renderer pinned before the change.
    /// @param next The renderer pinned after the change.
    /// @param codeHash The code hash `next` is pinned with.
    /// @param stateHash The work's state hash after the change.
    event RendererRepinned(
        uint256 indexed tokenId, address previous, address next, bytes32 codeHash, bytes32 stateHash
    );
    /// @notice The delivery contract changed (`setDelivery`).
    /// @param previous The delivery contract before the change.
    /// @param next The delivery contract after the change.
    event DeliverySet(address indexed previous, address indexed next);
    /// @notice A store joined the set `syncOnChain` may verify media against, for good.
    /// @param storeId The store's ID, from 1 (0 is the content store).
    /// @param store The store contract.
    /// @param codeHash The code hash it is pinned with, checked at each use.
    event StoreAdded(uint256 indexed storeId, address store, bytes32 codeHash);
    /// @notice The network marked an added store dead (`retireStore`, C21): nothing more is
    ///         counted through it. Files already complete in it keep their record.
    /// @param storeId The store's ID.
    event StoreRetired(uint256 indexed storeId);
    /// @notice Someone other than the artist asked to finalize a work whose primary sale settled
    ///         (C9): from `dueAt` anyone may finalize it as it then stands.
    /// @param tokenId The work's token ID.
    /// @param dueAt When the work may be finalized by anyone (the notice plus 14 days).
    event FinalizeNoticeRecorded(uint256 indexed tokenId, uint256 dueAt);

    /// @notice The work has no open record.
    error RecordNotOpen(uint256 tokenId);
    /// @notice The work's record is already open.
    error RecordAlreadyOpen(uint256 tokenId);
    /// @notice The item or media does not match the work's committed item hash, the media
    ///         commitment, the content hash, the content store's declared SHA-256 or a limit.
    error InvalidRecordData(uint256 tokenId);
    /// @notice The record file is not registered in the content store, or breaks a record bound.
    error UnknownRecordFile(bytes32 recordFileId);
    /// @notice The caller is not a wallet of the work's lead artist account (for `finalize`:
    ///         and the work's primary sale has not settled).
    error NotWorkArtist(uint256 tokenId, address caller);
    /// @notice A finalize by anyone but the artist comes before `dueAt` (14 days after the
    ///         recorded notice).
    error FinalizeNotDue(uint256 tokenId, uint256 dueAt);
    /// @notice The work is finalized, so its record can no longer change.
    error WorkIsFinalized(uint256 tokenId);
    /// @notice The work's state hash is not the one the caller or signers expected.
    error StateHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice The number of signatures is not the number of parties (`partyIndex` is the number
    ///         of signatures given). A signature that does not verify reverts with the artist
    ///         registry's reason (`IAccounts.requireSigned`); an expired consent with
    ///         `SignatureVerifier.SignatureExpired`.
    error InvalidConsent(uint256 tokenId, uint256 partyIndex);
    /// @notice A CC0 dedication is irrevocable, so the license key cannot change.
    error LicenseIrrevocable(uint256 tokenId);
    /// @notice The file is not one of the work's media files.
    error FileNotInWork(uint256 tokenId, bytes32 fileId);
    /// @notice `syncOnChain` could verify no chunk: the next one is missing from the store.
    error NotOnChainComplete(uint256 tokenId);
    /// @notice The license ID is invalid, the deployment's default license is not CC0, a license
    ///         text file declares no SHA-256, a CC0 license names a text other than the
    ///         deployment's CC0 text, or a license text that must be permanent is not complete
    ///         or has more than 16 chunks.
    error InvalidLicense();
    /// @notice The work is not finalized (an errata repin, and renouncing it, need one).
    error WorkNotFinalized(uint256 tokenId);
    /// @notice No store has this ID, its code changed since it was added, or it was retired.
    error UnknownStore(uint256 storeId);
    /// @notice Every store ID is taken (at most 15 stores beside the content store).
    error StoreLimitReached();
    /// @notice Only the current delivery contract may call this.
    error NotDelivery();
    /// @notice The current delivery contract is not the one the governed call expected.
    error DeliveryMismatch();

    /// @notice The 6529 Stream core this satellite serves (immutable).
    /// @return The 6529 Stream contract.
    function stream() external view returns (address);

    // ----- records -----

    /// @notice Opens a work's record from its approved item and media. Permissionless (off the
    ///         auction-start path). Checks the item against Stream's stored item hash, `media`
    ///         against `item.mediaHash`, the first file's SHA-256 against `item.contentHash`,
    ///         each file's declared SHA-256 against the content store, 1 to
    ///         `Limits.MAX_MEDIA_FILES` files with the PRIMARY (role 0) first and alone, roles
    ///         below 16. A PREVIEW has no bound here beyond the store's own (a file of at most
    ///         `MAX_CHUNKS` chunks, read chunk by chunk): the renderer decides what it inlines.
    ///         Stores the record file ID, the media, the seed and a non-CC0 license as approved
    ///         (a CC0 license must name the deployment's CC0 text, `InvalidLicense`), and emits
    ///         `RecordOpened` with every fact it fixed. It does not check a stored license's
    ///         identifier or text (registered, SHA-256 digest, at most 16 chunks, complete):
    ///         `finalize` checks all of that, and renouncing RELICENSE all but completeness.
    ///         A text accepted here can therefore be refused there until `relicense` replaces
    ///         it, or, for a text that is only unregistered or incomplete, until its chunks are
    ///         written.
    /// @dev The curation signer's tooling MUST simulate `openRecord` before attesting an item: a
    ///      mis-committed item mints and can never open.
    /// @param tokenId A live 6529 Stream token whose record is not open yet.
    /// @param item The work's approved package item.
    /// @param media The work's media files in approved order, primary first.
    function openRecord(uint256 tokenId, PackageItem calldata item, MediaFile[] calldata media)
        external;
    /// @notice The artist points the work at a new record file, which must meet the structural
    ///         bounds, until finalize. Re-publishing the current file is a no-op.
    /// @param tokenId A work with an open record, not finalized.
    /// @param recordFileId The new record file (`UnknownRecordFile` unless it meets the bounds).
    /// @param expectedStateHash The work's current state hash (`StateHashMismatch` otherwise).
    function setRecord(uint256 tokenId, bytes32 recordFileId, bytes32 expectedStateHash) external;
    /// @notice Finalizes the work: the record becomes immutable and Stream's current default
    ///         renderer is pinned with its code hash (ADR 0001 section 10). The artist finalizes
    ///         at any time (C9). Anyone else may once 6529 Stream reports the primary sale
    ///         settled (`NotWorkArtist` before): the first such call records a notice
    ///         (`FinalizeNoticeRecorded`) and changes nothing else; from 14 days after the notice
    ///         (`FinalizeNotDue` before), a call finalizes the record as it then stands. The record
    ///         file must meet the structural bounds (one chunk; see the contract notes), the
    ///         license text (the deployment's CC0 text for a work with no stored license) must
    ///         be registered, with a SHA-256 digest, in at most 16 chunks and complete on-chain,
    ///         and a stored license's ID must pass the mint rule (`SpdxId`); `openRecord` checks
    ///         none of this for a stored license (`InvalidLicense`). Renouncing RELICENSE
    ///         checks the same ID and text except completeness.
    /// @param tokenId A work with an open record, not finalized.
    /// @param expectedStateHash The work's current state hash (`StateHashMismatch` otherwise).
    function finalize(uint256 tokenId, bytes32 expectedStateHash) external;
    /// @notice Marks media on-chain, in pieces of the caller's choosing; never changes the state
    ///         hash. Each call verifies at most `maxChunks` chunks, in media order, through
    ///         `IContentStore.firstMissing` against store `storeId`. Two independent walks:
    ///         - The content store (0): anyone; a cursor from where the last such call stopped;
    ///           each chunk must be stored at its required length. It verifies every file not
    ///           yet complete there, one complete in an added store included, which then becomes
    ///           complete in the content store (an upgrade); it passes over a file already
    ///           complete in an added store when the content store lacks a chunk of it, so no
    ///           order of files across stores holds back the others. Once the work is on-chain
    ///           complete the walk goes round again over the files still complete only in an
    ///           added store; a call that reaches the end with budget left wraps once, up to the
    ///           file it started from. No added store is called on this walk.
    ///         - An added store that is not retired: a wallet of the work's artist account or the
    ///           storage operator (the role mapped to this selector), until the work is
    ///           on-chain complete; one walk at a time, resumed on the same store and restarted at
    ///           the content walk's cursor when a caller names another; it skips files already
    ///           complete in any store. Each chunk is checked alone: the bytes the store
    ///           serves for the manifest's chunk hash must hash to it and have the required length,
    ///           and a chunk the store refuses (reverts, or serves other bytes) is missing.
    ///         A file's completion is recorded per store (`MediaFileComplete`, `mediaStore`):
    ///         never undone, and only ever moved to the content store. When every file is complete
    ///         in some store, the work is on-chain complete for good (`WorkOnChainComplete`).
    ///         Reverts with `NotOnChainComplete` when no chunk could be verified, and with
    ///         `BoundedCall.BoundedCallShortfall` when an added store's check runs short of gas; a
    ///         call that verified some keeps its progress. A call with nothing left to do on its
    ///         walk is a no-op.
    /// @param tokenId A work with an open record.
    /// @param storeId A store ID (`UnknownStore` otherwise).
    /// @param maxChunks The most chunks to verify in this call; zero is a no-op.
    function syncOnChain(uint256 tokenId, uint256 storeId, uint256 maxChunks) external;

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
    /// @notice The index of `fileId` in a work's media list.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files (`FileNotInWork` otherwise).
    /// @return index The file's index, from 0.
    function mediaIndex(uint256 tokenId, bytes32 fileId) external view returns (uint256 index);
    /// @notice The store media file `index` is complete in, and whether it is complete. A file
    ///         complete in the content store stays there for good; one complete in an added
    ///         store stays complete, and moves only to the content store (`syncOnChain`).
    /// @param tokenId A work with an open record.
    /// @param index A media index (`FileNotInWork` with a zero file ID otherwise).
    /// @return storeId The file's store (0 is the content store); zero for a file not complete.
    /// @return complete Whether the file is complete in some store.
    function mediaStore(uint256 tokenId, uint256 index)
        external
        view
        returns (uint256 storeId, bool complete);
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
    ///         hash it was first pinned with, so 6529 Stream's `tokenURI` fails closed.
    /// @param tokenId A work with an open record.
    /// @return The pinned renderer, or zero before finalize.
    function pinnedRenderer(uint256 tokenId) external view returns (address);
    /// @notice The work's seed and seed policy, both fixed at `openRecord`.
    /// @param tokenId A live work with an open record.
    /// @return policy The work's seed policy.
    /// @return seed The seed, or zero under NONE.
    function seedOf(uint256 tokenId) external view returns (uint8 policy, bytes32 seed);
    /// @notice When a finalize notice was recorded for the work (C9), or zero.
    /// @param tokenId Any token ID.
    /// @return The notice time, in seconds since the epoch.
    function finalizeNoticeAt(uint256 tokenId) external view returns (uint48);

    // ----- amendments: agreement plus a governed action (ADR 0001 sections 7, 8 and 10) -----

    /// @notice Changes a work's license. FUNDS_SETTER role (the network, 3 days) plus an EIP-712
    ///         `Typehashes.RELICENSE` signature from every party of `item`, in order, each by
    ///         a wallet of its account. Leaving CC0 reverts (`LicenseIrrevocable`); a CC0 license
    ///         names the deployment's CC0 text; the new text must be registered with a SHA-256
    ///         digest in at most 16 chunks, before finalize too (`InvalidLicense`), and complete
    ///         for a finalized work (a no-op, the current key and text, is not checked). Reverts with `PowerRenounced` once relicensing is renounced.
    /// @param tokenId A live work with an open record.
    /// @param next The new license.
    /// @param item The work's approved package item, whose parties consent.
    /// @param expectedStateHash The work's current state hash, which every signature binds.
    /// @param deadline The consents' deadline, inclusive; it must cover the governance delay.
    /// @param partySignatures One proof per party of `item`, in party order: the signing wallet
    ///        followed by its signature (`abi.encodePacked(wallet, signature)`).
    function relicense(
        uint256 tokenId,
        License calldata next,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external;
    /// @notice Raises or lowers a work's royalty rate (payees never change; R10). FUNDS_SETTER
    ///         role (the network, 3 days) plus a `Typehashes.ROYALTY_RATE_CHANGE` signature from
    ///         every party of `item`, each by a wallet of its account. Above 100,000 reverts in
    ///         6529 Stream (`IStream.InvalidRoyaltyRate`), the current rate is a no-op, and every
    ///         call reverts once the power is renounced. Applies in 6529 Stream and a linked
    ///         edition, then emits `RoyaltyRateSet`.
    /// @param tokenId A live work with an open record.
    /// @param rate The new royalty rate, out of 100,000.
    /// @param item The work's approved package item, whose parties consent.
    /// @param expectedStateHash The work's current state hash, which every signature binds.
    /// @param deadline The consents' deadline, inclusive; it must cover the governance delay.
    /// @param partySignatures One proof per party of `item`, in party order: the signing wallet
    ///        followed by its signature (`abi.encodePacked(wallet, signature)`).
    function setRoyaltyRate(
        uint256 tokenId,
        uint32 rate,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external;
    /// @notice The errata path: pins a new renderer (`IRenderer` by ERC-165, code hash
    ///         `rendererCodeHash`, not an EIP-7702 delegated account) on a finalized work.
    ///         SUCCESSOR_SETTER role (the network, 7 days), with no artist signature (C8).
    ///         Reverts with `PowerRenounced` for good once the lead artist renounced
    ///         `WorkPowers.RENDERER_REPIN`.
    /// @param tokenId A finalized work (`WorkNotFinalized` otherwise).
    /// @param renderer The new renderer.
    /// @param rendererCodeHash The code hash `renderer` must have, which it is pinned with.
    /// @param expectedStateHash The work's current state hash (`StateHashMismatch` otherwise).
    function repinRenderer(
        uint256 tokenId,
        address renderer,
        bytes32 rendererCodeHash,
        bytes32 expectedStateHash
    ) external;

    // ----- delivery: a replaceable contract that never changes a fact -----

    /// @notice The current delivery contract (locators, kinds and preferences).
    /// @return The delivery contract.
    function delivery() external view returns (address);
    /// @notice Replaces the delivery contract, compare-and-set. SUCCESSOR_SETTER role (the network
    ///         at 7 days). `next` must declare `IWorkDelivery` by ERC-165,
    ///         serve this contract (`records()`) and name the current contract as its
    ///         `predecessor()`, whose locators it is obliged to keep serving (`IWorkDelivery`).
    ///         Refreshes every token's metadata.
    /// @param expected The current delivery contract (`DeliveryMismatch` otherwise).
    /// @param next The new delivery contract (`Dependency.InvalidDependency` if refused).
    function setDelivery(address expected, address next) external;
    /// @notice The locator `tokenURI` serves for a file: the delivery contract's answer, checked.
    ///         Fail-soft: when the delivery contract refuses (reverts, or has no code) or answers
    ///         anything but a canonical `(IWorkDelivery.Location, uint256)` with a URI of at
    ///         most `Limits.MAX_URI_BYTES` bytes of printable ASCII (`0x21` to `0x7e`, but `"` and
    ///         `\`; no space or control byte, nothing from `0x80`: percent-encoding spells the
    ///         rest), a non-empty URI for every kind but NONE and ONCHAIN, an empty one for those
    ///         two, and ONCHAIN only for an on-chain complete work, the answer is the work's own:
    ///         the implicit ONCHAIN copy of an on-chain complete work, else the empty locator
    ///         (kind NONE). Index `type(uint256).max`
    ///         stands for both. A delivery call that runs short of gas reverts with
    ///         `BoundedCall.BoundedCallShortfall`, never falls back. Kinds are `uint8` labels
    ///         (`LocatorKind` names 0 to 3); any other kind is passed through.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files (`FileNotInWork` otherwise).
    /// @return locator The chosen locator.
    /// @return index Its index in the delivery contract's list for the file, or
    ///         `type(uint256).max`.
    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (IWorkDelivery.Location memory locator, uint256 index);
    /// @notice ERC-4906 for one work through 6529 Stream (and its edition, for a master). Only
    ///         the delivery contract (`NotDelivery`).
    /// @param tokenId A work with an open record.
    function refreshMetadata(uint256 tokenId) external;
    /// @notice ERC-4906 for every token and edition. Only the delivery contract (`NotDelivery`).
    function refreshAllMetadata() external;

    // ----- stores -----

    /// @notice Adds a store `syncOnChain` may verify media against, walked by a work's artist or
    ///         the storage operator. SUCCESSOR_SETTER role (the network, 7 days). Append-only: an
    ///         ID is never reused, a store is never removed (only retired, `retireStore`), and no
    ///         existing file's completeness ever changes. The store must implement `IChunkStore`; its code hash is pinned and
    ///         checked at each use. The pin fixes the store's code, not what it reads: a store
    ///         may stop serving, and a file complete in it stays recorded as complete there
    ///         (`MediaFileComplete` names the store), so the duty to keep serving bytes once
    ///         served (`IChunkStore`) is a review condition for adding a store, not enforced
    ///         here. Readers should prefer the content store's copy (`IContentStore.isComplete`).
    /// @param source The store contract (`Dependency.InvalidDependency` if it has no code, is an
    ///        EIP-7702 delegated account or does not have `codeHash`).
    /// @param codeHash The store's code hash.
    function addStore(address source, bytes32 codeHash) external;
    /// @notice Marks an added store dead (C21): nothing more is counted through it
    ///         (`syncOnChain` refuses it with `UnknownStore`). Works already counted keep their
    ///         record. PARAMETER_SETTER role (the network, 24 hours). One-way.
    /// @param storeId An added store's ID (`UnknownStore` for 0 or an unused ID).
    function retireStore(uint256 storeId) external;
    /// @notice Whether the network retired store `storeId` (`retireStore`); false for 0.
    /// @param storeId A store ID (`UnknownStore` for an unused nonzero ID).
    /// @return Whether the store is retired.
    function storeRetired(uint256 storeId) external view returns (bool);
    /// @notice The store with `storeId`: the content store for 0.
    /// @param storeId A store ID (`UnknownStore` otherwise).
    /// @return The store contract.
    function store(uint256 storeId) external view returns (address);
}
