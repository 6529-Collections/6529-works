// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "../economics/interfaces/ISplitWallet.sol";
import { IWorkDelivery } from "./IWorkDelivery.sol";
import { EditionTerms, License, SaleTerms } from "./types/PackageTypes.sol";

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
///      "The artist" is the active authority of the work's lead artist ID. The state hash
///      commits to the token ID, the version, the record file ID, the license key and text, the
///      royalty rate and the effective renderer. The version bumps only on a real change (a new
///      record pointer, license, royalty rate or renderer pin, finalize, or a renunciation
///      through `IWorkPowers.renounce`); an identical re-publish is a no-op, and permissionless
///      or delivery actions (`syncOnChain`, everything in the delivery contract) never change it.
///      Every finalize and signature binds the state hash (compare-and-set), so nothing applies
///      to a state its signer did not see. Every visible change asks 6529 Stream to emit
///      ERC-4906 and, for an edition master, calls `IEditions.notifyMasterUpdated`.
///
///      Item kinds, seed policies, party roles and media roles are read as `uint8`, so an item a
///      future mint policy defines with a new value still opens; the ABI of `WorkItem` and
///      `WorkMedia` is the ABI of `PackageItem` and `MediaFile` (enums encode as `uint8`), and
///      the item hash is `WorksHashing.itemHash` of the same bytes.
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

    /// @notice A party of an item (`Party`, with its role read as `uint8`).
    struct WorkParty {
        address account;
        uint8 role;
    }

    /// @notice A package item (`PackageItem`, with `kind`, `seedPolicy` and party roles read as
    ///         `uint8`); same ABI encoding and item hash.
    struct WorkItem {
        uint8 kind;
        uint256 collectionId;
        bytes32 contentHash;
        bytes32 mediaHash;
        bytes32 recordFileId;
        WorkParty[] parties;
        ISplitWallet.Payee[] payees;
        License license;
        uint8 seedPolicy;
        bytes32 seed;
        SaleTerms sale;
        EditionTerms edition;
    }

    /// @notice A media file (`MediaFile`, with its role read as `uint8`: 0 PRIMARY, 1 PREVIEW,
    ///         2 AUXILIARY, and any other value up to 15 recorded for future readers).
    struct WorkMedia {
        bytes32 fileId;
        bytes32 sha256Hash;
        uint8 role;
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
        uint256 indexed tokenId, WorkItem item, WorkMedia[] media, bytes32 licenseKey, bytes32 seed
    );
    /// @notice The artist pointed a work at a new record file.
    /// @param tokenId The work's token ID.
    /// @param recordFileId The new record file.
    /// @param stateHash The work's state hash after the change.
    event RecordSet(uint256 indexed tokenId, bytes32 recordFileId, bytes32 stateHash);
    /// @notice The artist finalized a work: the record is immutable and `renderer` is pinned.
    /// @param tokenId The work's token ID.
    /// @param renderer The pinned renderer: 6529 Stream's default renderer at finalize, pinned
    ///        with the code hash 6529 Stream installed it with.
    /// @param stateHash The work's state hash after finalize.
    event WorkFinalized(uint256 indexed tokenId, address renderer, bytes32 stateHash);
    /// @notice Every media file of the work is stored on-chain; one-way.
    /// @param tokenId The work's token ID.
    event WorkOnChainComplete(uint256 indexed tokenId);
    /// @notice `syncOnChain` progress: the first `files` media files are complete, and the next
    ///         one is verified up to chunk `chunk`. Every file this call touched is held by
    ///         store `storeId`, so a file's store is that of the event in which `files` first
    ///         passed its index.
    /// @param tokenId The work's token ID.
    /// @param files The number of leading media files complete so far.
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
    /// @notice A work's royalty rate was lowered, by every party's agreement plus a governed
    ///         action (applied in 6529 Stream and, for a linked master, its edition).
    /// @param tokenId The work's token ID.
    /// @param previous The rate before the change, out of 100,000.
    /// @param next The rate after the change, out of 100,000.
    /// @param stateHash The work's state hash after the change.
    event RoyaltyRateSet(uint256 indexed tokenId, uint32 previous, uint32 next, bytes32 stateHash);
    /// @notice The errata path replaced a finalized work's renderer pin (ADR 0001 section 10).
    /// @param tokenId The work's token ID.
    /// @param previous The renderer pinned before the change.
    /// @param next The renderer pinned after the change.
    /// @param codeHash The code hash the artist signed for `next`.
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
    /// @notice A CC0 dedication is irrevocable, so the license key cannot change.
    error LicenseIrrevocable(uint256 tokenId);
    /// @notice The file is not one of the work's media files.
    error FileNotInWork(uint256 tokenId, bytes32 fileId);
    /// @notice `syncOnChain` could verify no chunk: the next one is missing from the store.
    error NotOnChainComplete(uint256 tokenId);
    /// @notice The license ID is invalid, the deployment's default license is not CC0, a license
    ///         text file declares no SHA-256, a CC0 license names a text other than the
    ///         deployment's CC0 text, or a license text that must be permanent is not complete.
    error InvalidLicense();
    /// @notice The work is not finalized (an errata repin, and renouncing it, need one).
    error WorkNotFinalized(uint256 tokenId);
    /// @notice No store has this ID, or its code changed since it was added.
    error UnknownStore(uint256 storeId);
    /// @notice The work's file in progress is held by store `storeId`, which still serves its
    ///         next chunk; only a store missing that chunk can be switched away from.
    error StoreInUse();
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
    ///         `RecordOpened` with every fact it fixed.
    /// @dev The curation signer's tooling MUST simulate `openRecord` before attesting an item: a
    ///      mis-committed item mints and can never open.
    /// @param tokenId A live 6529 Stream token whose record is not open yet.
    /// @param item The work's approved package item.
    /// @param media The work's media files in approved order, primary first.
    function openRecord(uint256 tokenId, WorkItem calldata item, WorkMedia[] calldata media)
        external;
    /// @notice The artist points the work at a new record file, which must meet the structural
    ///         bounds, until finalize. Re-publishing the current file is a no-op.
    /// @param tokenId A work with an open record, not finalized.
    /// @param recordFileId The new record file (`UnknownRecordFile` unless it meets the bounds).
    /// @param expectedStateHash The work's current state hash (`StateHashMismatch` otherwise).
    function setRecord(uint256 tokenId, bytes32 recordFileId, bytes32 expectedStateHash) external;
    /// @notice The artist finalizes the work: the record becomes immutable and Stream's current
    ///         default renderer is pinned with its code hash (ADR 0001 section 10). The record
    ///         file must meet the structural bounds (one chunk; see the contract notes) and the
    ///         license text must be complete on-chain.
    /// @param tokenId A work with an open record, not finalized.
    /// @param expectedStateHash The work's current state hash (`StateHashMismatch` otherwise).
    function finalize(uint256 tokenId, bytes32 expectedStateHash) external;
    /// @notice Marks media on-chain, in pieces of the caller's choosing. Permissionless; never
    ///         changes the state hash. Each call verifies at most `maxChunks` chunks, in media
    ///         order, from where the last call stopped (a chunk cursor), against store
    ///         `storeId`, through `IContentStore.firstMissing`: for the content store (0) that
    ///         the chunk is stored at its required length; for any other store (`IChunkStore`)
    ///         that the bytes it serves for the manifest's chunk hash hash to it and have the
    ///         required length (a store that reverts makes the call revert). A file's store is
    ///         fixed when its last chunk verifies and never changes; a file in progress stays with
    ///         its store unless that store is missing its next chunk or refuses to say
    ///         (`StoreInUse`). When the last file
    ///         completes, the work is on-chain complete for good. Reverts with
    ///         `NotOnChainComplete` when no chunk could be verified; a call that verified some
    ///         keeps its progress. A complete work is a no-op.
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
    function mediaOf(uint256 tokenId) external view returns (WorkMedia[] memory);
    /// @notice The index of `fileId` in a work's media list.
    /// @param tokenId A work with an open record.
    /// @param fileId One of the work's media files (`FileNotInWork` otherwise).
    /// @return index The file's index, from 0.
    function mediaIndex(uint256 tokenId, bytes32 fileId) external view returns (uint256 index);
    /// @notice The store of media file `index` and whether that file is complete; a complete
    ///         file's store never changes.
    /// @param tokenId A work with an open record.
    /// @param index A media index (`FileNotInWork` with a zero file ID otherwise).
    /// @return storeId The file's store (0 is the content store); for a file not yet complete,
    ///         the store its verification has used so far.
    /// @return complete Whether the file is complete.
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

    // ----- amendments: agreement plus a governed action (ADR 0001 sections 7, 8 and 10) -----

    /// @notice Changes a work's license. PARAMETER_SETTER role plus an EIP-712
    ///         `Typehashes.RELICENSE` signature from every party of `item`, in order, each by
    ///         its active authority. Leaving CC0 reverts (`LicenseIrrevocable`); a CC0 license
    ///         names the deployment's CC0 text; the new text must be registered, and complete
    ///         for a finalized work. Reverts with `PowerRenounced` once relicensing is renounced.
    /// @param tokenId A live work with an open record.
    /// @param next The new license.
    /// @param item The work's approved package item, whose parties consent.
    /// @param expectedStateHash The work's current state hash, which every signature binds.
    /// @param deadline The consents' deadline, inclusive; it must cover the governance delay.
    /// @param partySignatures One signature per party of `item`, in party order.
    function relicense(
        uint256 tokenId,
        License calldata next,
        WorkItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external;
    /// @notice Lowers a work's royalty rate (payees never change). FUNDS_SETTER role plus a
    ///         `Typehashes.ROYALTY_RATE_CHANGE` signature from every party of `item`. A higher
    ///         rate reverts (`RoyaltyRateNotLowered`), the current rate is a no-op, and every
    ///         call reverts once the power is renounced. Applies in 6529 Stream and a linked
    ///         edition, then emits `RoyaltyRateSet`.
    /// @param tokenId A live work with an open record.
    /// @param rate The new royalty rate, out of 100,000.
    /// @param item The work's approved package item, whose parties consent.
    /// @param expectedStateHash The work's current state hash, which every signature binds.
    /// @param deadline The consents' deadline, inclusive; it must cover the governance delay.
    /// @param partySignatures One signature per party of `item`, in party order.
    function setRoyaltyRate(
        uint256 tokenId,
        uint32 rate,
        WorkItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external;
    /// @notice The errata path: pins a new renderer (`IRenderer` by ERC-165, code hash
    ///         `rendererCodeHash`, not an EIP-7702 delegated account) on a finalized work.
    ///         SUCCESSOR_SETTER role plus the artist's `Typehashes.RENDERER_REPIN` signature.
    ///         Reverts with `PowerRenounced` for good once the lead artist renounced
    ///         `WorkPowers.RENDERER_REPIN`.
    /// @param tokenId A finalized work (`WorkNotFinalized` otherwise).
    /// @param renderer The new renderer.
    /// @param rendererCodeHash The code hash `renderer` must have, which it is pinned with.
    /// @param expectedStateHash The work's current state hash, which the signature binds.
    /// @param deadline The signature's deadline, inclusive; it must cover the governance delay.
    /// @param artistSignature The signature of the active authority of the work's lead artist.
    function repinRenderer(
        uint256 tokenId,
        address renderer,
        bytes32 rendererCodeHash,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external;

    // ----- delivery: a replaceable contract that never changes a fact -----

    /// @notice The current delivery contract (locators, kinds and preferences).
    /// @return The delivery contract.
    function delivery() external view returns (address);
    /// @notice Replaces the delivery contract, compare-and-set. SUCCESSOR_SETTER role (the slow
    ///         class; any guardian may cancel). `next` must declare `IWorkDelivery` by ERC-165,
    ///         serve this contract (`records()`) and name the current contract as its
    ///         `predecessor()`, whose locators it is obliged to keep serving (`IWorkDelivery`).
    ///         Refreshes every token's metadata.
    /// @param expected The current delivery contract (`DeliveryMismatch` otherwise).
    /// @param next The new delivery contract (`Dependency.InvalidDependency` if refused).
    function setDelivery(address expected, address next) external;
    /// @notice The locator `tokenURI` serves for a file: the delivery contract's answer, checked.
    ///         Fail-soft: when the delivery contract refuses (reverts, or has no code) or answers
    ///         anything but a canonical `(IWorkDelivery.Location, uint256)` with a URI of at
    ///         most `Limits.MAX_URI_BYTES` bytes, a non-empty URI for every kind but NONE and
    ///         ONCHAIN, an empty one for those two, and ONCHAIN only for an on-chain complete
    ///         work, the answer is the work's own: the implicit ONCHAIN copy of an on-chain
    ///         complete work, else the empty locator (kind NONE). Index `type(uint256).max`
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

    /// @notice Adds a store `syncOnChain` may verify media against. SUCCESSOR_SETTER role (the
    ///         slow class; any guardian may cancel). Append-only: an ID is never reused, a store
    ///         never removed, and no existing file's store or completeness ever changes. The
    ///         store must implement `IChunkStore`; its code hash is pinned and checked at each
    ///         use.
    /// @param source The store contract (`Dependency.InvalidDependency` if it has no code, is an
    ///        EIP-7702 delegated account or does not have `codeHash`).
    /// @param codeHash The store's code hash.
    function addStore(address source, bytes32 codeHash) external;
    /// @notice The store with `storeId`: the content store for 0.
    /// @param storeId A store ID (`UnknownStore` otherwise).
    /// @return The store contract.
    function store(uint256 storeId) external view returns (address);
}
