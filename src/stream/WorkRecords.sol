// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IContentStore } from "../interfaces/IContentStore.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IEntropyModule } from "../interfaces/IEntropyModule.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IWorkDelivery } from "../interfaces/IWorkDelivery.sol";
import { IWorkPowers, WorkPowers } from "../interfaces/IWorkPowers.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { MediaFile } from "../interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "../interfaces/types/PackageTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { SSTORE2 } from "../libraries/SSTORE2.sol";
import { SpdxId } from "./SpdxId.sol";
import { WorkDelivery } from "./WorkDelivery.sol";

/// @title WorkRecords
/// @notice The permanent records satellite of 6529 Stream: descriptive records, media, licenses,
///         seeds, the state hash, finalize and the renderer pin, on-chain completeness and each
///         media file's store, amendments and the lead artist's renounceable powers (ADR 0001
///         sections 8, 9 and 10; ADR 0006). Delivery (locators, kinds, preferences) is a
///         replaceable contract behind `delivery`, which has no write path into any fact here.
/// @dev Nothing here is written at mint, so none of it costs the auction start: a work's record
///      opens with the permissionless `openRecord`, checked against the item hash the core
///      stored, and every per-token function reverts with `RecordNotOpen` until then.
///
///      Gas rule: a call whose outcome this contract interprets (the delivery contract, a chunk
///      check against an added store, a wallet's ERC-1271 check, an ERC-165 probe) goes
///      through `BoundedCall`'s forward-all reads, so running short of gas reverts with
///      `BoundedCallShortfall` and never reads as a refusal. Every other call (6529 Stream, the
///      artist registry, Editions, the entropy module, the content store) is a plain Solidity
///      call: it forwards all the gas EIP-150 allows and any failure, running short included,
///      reverts the transaction. No gas amount is compiled in.
///
///      Consents are EIP-712 signatures in this contract's domain (`Typehashes`), each by a
///      party's active authority and bound to the work's state hash; every applied change bumps
///      the version, so a consent can never apply twice or to a state its signers did not see.
contract WorkRecords is AccessManaged, EIP712, ERC165, IWorkRecords, IWorkPowers {
    uint256 private constant NONE = type(uint256).max;
    bytes32 private constant STATE_DOMAIN = keccak256("6529WORKS_WORK_STATE_V1");
    /// @dev `RecordData.flags` bits.
    uint8 private constant OPENED = 1;
    uint8 private constant FINALIZED = 2;
    uint8 private constant ON_CHAIN = 4;
    uint8 private constant CUSTOM_LICENSE = 8;
    /// @dev The one media role with meaning here (the rest are recorded, not interpreted).
    uint8 private constant PRIMARY = 0;
    /// @dev Seed policies with meaning here (`SeedPolicy`).
    uint8 private constant SEED_NONE = 0;
    uint8 private constant SEED_VRF = 2;
    /// @dev Locator kinds with meaning here (`LocatorKind`).
    uint256 private constant KIND_NONE = 0;
    uint256 private constant KIND_ONCHAIN = 3;
    /// @dev Store IDs, a role and a store per media file: four bits each (storage layout). A
    ///      safety bound, not a policy: 15 stores beside the content store.
    uint256 private constant MAX_STORES = 16;
    /// @dev The most bytes of a delivery answer copied: the canonical encoding of a location
    ///      with a URI of `Limits.MAX_URI_BYTES` (a bound against unbounded copying).
    uint256 private constant LOCATION_RETURN = 0xa0 + Limits.MAX_URI_BYTES;
    /// @dev The bytes a served locator URI may hold, as a bit set: printable ASCII `0x21` to
    ///      `0x7e` but `"` and `\`. No space (RFC 3986 has none; `%20` spells it), no control
    ///      byte, no byte from `0x80` (percent-encoding spells any other character), so a served
    ///      URI is UTF-8 by construction and needs no JSON escaping.
    uint256 private constant URI_BYTES = 0x7fffffffeffffffffffffffa00000000;
    /// @dev The chunk size of every content-store manifest, and the largest record file (one
    ///      chunk keeps the record checks O(1)).
    uint256 private constant CHUNK = SSTORE2.MAX_CHUNK_LENGTH;
    /// @dev The most chunks of any license text a work selects (relicensing, before or after
    ///      finalize, and renouncing RELICENSE; `finalize` checks the opened license, which
    ///      `openRecord` does not): a safety
    ///      bound against unbounded work, so the presence check at finalize is at most 16 chunk
    ///      reads (about 393 KB of text) in one transaction.
    uint256 private constant MAX_LICENSE_TEXT_CHUNKS = 16;
    /// @dev The high nibble of every byte of a `RecordData.files` word: the added store each file
    ///      is complete in.
    uint256 private constant ADDED_STORES =
        0xf0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0;

    /// @dev Word 0: the pin, version, media count, how many leading media files are complete in
    ///      the content store, flags, the content store's chunk cursor in the next file, and the
    ///      renounced powers (`WorkPowers` bits, only ever added). `files` holds a byte per media
    ///      file, file `i` at bits `8i`: its role in the low four bits, and in the high four the
    ///      added store it is complete in, or zero: the content store once the work is on-chain
    ///      complete or when `i < syncedFiles`, else not complete. Before on-chain completion
    ///      `syncedFiles` is the content walk's cursor (every file before it is complete: in the
    ///      content store, or in the added store its nibble names, which the walk passed over);
    ///      after it, every file is complete, and the cursor only serves upgrades.
    struct RecordData {
        address renderer;
        uint32 version;
        uint8 mediaCount;
        uint8 syncedFiles;
        uint8 flags;
        uint24 chunk;
        uint16 renounced;
        bytes32 recordFileId;
        bytes32 mediaHash;
        uint256 files;
    }

    /// @dev A `syncOnChain` cursor in memory: the file and chunk reached, the `files` word, the
    ///      media count, the chunks left in the call's budget, and whether the work was on-chain
    ///      complete when the call began.
    struct Sync {
        uint256 next;
        uint256 chunk;
        uint256 files;
        uint256 count;
        uint256 budget;
        bool done;
    }

    /// @dev A store beside the content store, pinned by code hash.
    struct StoreEntry {
        address source;
        bytes32 codeHash;
    }

    /// @inheritdoc IWorkRecords
    address public immutable stream;
    /// @notice The content store holding records, media and license texts: store 0 (immutable).
    address public immutable contentStore;
    /// @notice The text file of the default CC0 license (immutable).
    bytes32 public immutable cc0TextFileId;

    /// @inheritdoc IWorkRecords
    address public delivery;

    string private _cc0SpdxId;
    StoreEntry[] private _stores;
    mapping(uint256 tokenId => RecordData) private _records;
    mapping(uint256 tokenId => bytes32[32]) private _media;
    mapping(uint256 tokenId => License) private _licenses;
    mapping(uint256 tokenId => bytes32) private _seeds;
    /// @dev The code hash each renderer was first pinned with (finalize or the errata repin),
    ///      checked again by `pinnedRenderer`.
    mapping(address renderer => bytes32 codeHash) private _rendererCodeHashes;
    /// @dev The artist's added-store walk, beside the content store's cursor in word 0: the store
    ///      ID from bit 32, the file from bit 24 and the chunk in the low 24 bits.
    mapping(uint256 tokenId => uint256) private _storeCursors;

    /// @param authority_ The AccessManager governing this contract and its first delivery
    ///        contract.
    /// @param stream_ The core token, which must bind this contract.
    /// @param contentStore_ The content store.
    /// @param cc0 The default license, which must be CC0 (`CC0-1.0` in any case), with its text
    ///        registered in the content store.
    /// @dev Deploys the first delivery contract (`WorkDelivery`), so genesis needs no extra step.
    constructor(address authority_, address stream_, address contentStore_, License memory cc0)
        AccessManaged(authority_)
        EIP712(Typehashes.WORK_RECORDS_NAME, Typehashes.DOMAIN_VERSION)
    {
        Dependency.check(stream_, type(IStream).interfaceId);
        Dependency.check(contentStore_);
        if (
            !SpdxId.isValid(cc0.spdxId)
                || WorksHashing.licenseKey(cc0.spdxId) != WorksHashing.CC0_LICENSE_KEY
        ) {
            revert InvalidLicense();
        }
        stream = stream_;
        contentStore = contentStore_;
        // The rule every selected text meets, so a work on the default license can finalize.
        _requireLicenseText(cc0.textFileId, false);
        cc0TextFileId = cc0.textFileId;
        _cc0SpdxId = cc0.spdxId;
        address first = address(new WorkDelivery(authority_, address(this), stream_, address(0)));
        delivery = first;
        emit DeliverySet(address(0), first);
    }

    // --------------------------------------------------------------------------------- records

    /// @inheritdoc IWorkRecords
    /// @dev The approved record file and license are stored as they are, so neither can freeze a
    ///      minted work: `finalize` enforces both. One license rule is checked here: a CC0
    ///      license names the deployment's CC0 text, since CC0 can never be left or corrected.
    ///      Nothing else about a stored license is checked at open: not its identifier, nor
    ///      whether its text is registered, has a SHA-256 digest, has at most 16 chunks or is
    ///      complete. A text accepted here is checked when the work is finalized (all of that,
    ///      completeness included) or RELICENSE is renounced (all but completeness), and when
    ///      the license is replaced (`relicense`).
    function openRecord(uint256 tokenId, PackageItem calldata item, MediaFile[] calldata media)
        external
    {
        RecordData storage r = _records[tokenId];
        if (r.flags & OPENED != 0) revert RecordAlreadyOpen(tokenId);
        uint256 count = media.length;
        if (
            _itemHash(item) != _itemHashOf(tokenId) || count == 0 || count > Limits.MAX_MEDIA_FILES
                || keccak256(abi.encode(WorksHashing.MEDIA_DOMAIN, media)) != item.mediaHash
                || media[0].sha256Hash != item.contentHash
        ) revert InvalidRecordData(tokenId);
        uint256 files = 0;
        bytes32[32] storage list = _media[tokenId];
        for (uint256 i; i < count; ++i) {
            MediaFile calldata file = media[i];
            uint256 role = file.role;
            // Reverts with the store's `ContentFileUnknown` for an unregistered file, and with
            // `ContentDigestNotSha256` for a digest that is not SHA-256.
            bytes32 declared = IContentStore(contentStore).sha256Of(file.fileId);
            if (declared != file.sha256Hash || role > 15 || (role == PRIMARY) != (i == 0)) {
                revert InvalidRecordData(tokenId);
            }
            list[i] = file.fileId;
            files |= role << (8 * i);
        }
        uint8 flags = OPENED;
        bytes32 key = WorksHashing.licenseKey(item.license.spdxId);
        if (!_isDefaultLicense(item.license)) {
            if (key == WorksHashing.CC0_LICENSE_KEY && item.license.textFileId != cc0TextFileId) {
                revert InvalidLicense();
            }
            flags |= CUSTOM_LICENSE;
            _licenses[tokenId] = item.license;
        }
        // At most `Limits.MAX_MEDIA_FILES` (32), checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.mediaCount = uint8(count);
        r.flags = flags;
        r.recordFileId = item.recordFileId;
        r.mediaHash = item.mediaHash;
        r.files = files;
        // The seed is fixed for good at open: a VRF seed from the entropy module that was
        // current at the work's mint, by the item's content, so a governed replacement of the
        // module never changes it; the item's own seed for ARTIST and for any policy this
        // contract does not define (recorded, not interpreted).
        uint8 policy = item.seedPolicy;
        bytes32 seed;
        if (policy == SEED_VRF) {
            seed = IEntropyModule(IStream(stream).entropyModuleOf(tokenId))
                .seedOfContent(item.contentHash);
        } else if (policy != SEED_NONE) {
            seed = item.seed;
        }
        if (seed != 0) _seeds[tokenId] = seed;
        emit RecordOpened(tokenId, item, media, key, seed);
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    function setRecord(uint256 tokenId, bytes32 recordFileId, bytes32 expectedStateHash) external {
        RecordData storage r = _open(tokenId);
        if (r.flags & FINALIZED != 0) revert WorkIsFinalized(tokenId);
        _onlyArtist(tokenId);
        if (recordFileId == r.recordFileId) return;
        _checkState(tokenId, expectedStateHash);
        _checkRecordFile(recordFileId);
        r.recordFileId = recordFileId;
        ++r.version;
        emit RecordSet(tokenId, recordFileId, workStateHash(tokenId));
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    /// @dev The approved record file reaches here unchecked when the artist never replaced it,
    ///      so finalize applies the structural bounds itself. The license text must be complete
    ///      on-chain.
    function finalize(uint256 tokenId, bytes32 expectedStateHash) external {
        RecordData storage r = _open(tokenId);
        uint8 flags = r.flags;
        if (flags & FINALIZED != 0) revert WorkIsFinalized(tokenId);
        _onlyArtist(tokenId);
        _checkState(tokenId, expectedStateHash);
        // The default renderer, its code checked against Stream's pin (not finalized: no pin).
        address renderer = IStream(stream).rendererOf(tokenId);
        _checkRecordFile(r.recordFileId);
        _requireLicenseText(_frozenLicense(tokenId, flags), true);
        _pinCode(renderer, renderer.codehash);
        r.renderer = renderer;
        r.flags = flags | FINALIZED;
        ++r.version;
        emit WorkFinalized(tokenId, renderer, workStateHash(tokenId));
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    /// @dev Media is fixed by approval and verified bytes are permanent, so verified progress
    ///      only moves forward. Two walks that never touch each other: the content store's,
    ///      permissionless, whose cursor (`syncedFiles`, `chunk`) lives in the record's first
    ///      word; and the artist's walk over one added store at a time (`_storeCursors`), which
    ///      only the artist can move or restart. The content store's walk never calls an added
    ///      store, and passes over a file already complete in an added store whose bytes the
    ///      content store lacks, so nothing an added store does, and no order of files across
    ///      stores, can keep a file whose chunks are all in the content store from completing
    ///      there (review E, N-3). Once the work is on-chain complete, the content walk goes
    ///      round again over the files still complete only in an added store (upgrades); a call
    ///      that reaches the end with budget left wraps once, up to the file it started from, so
    ///      no file waits on a chunk missing from a later one. A call that verified no chunk in
    ///      that full pass reverts (`NotOnChainComplete`), leaving the cursor as it was.
    function syncOnChain(uint256 tokenId, uint256 storeId, uint256 maxChunks) external {
        RecordData storage r = _open(tokenId);
        uint256 synced = r.syncedFiles;
        uint256 count = r.mediaCount;
        uint8 flags = r.flags;
        uint256 files = r.files;
        // On-chain complete: only the content walk's upgrades remain, if any file is still
        // complete only in an added store.
        if (
            maxChunks == 0 || (flags & ON_CHAIN != 0 && (storeId != 0 || files & ADDED_STORES == 0))
        ) return;
        // Every file reached (only once on-chain complete): the walk restarts.
        if (synced == count) synced = 0;
        (address source, bool intact) = _storeOf(storeId);
        if (!intact) revert UnknownStore(storeId);
        // The chunk cursor is zero whenever every file was reached.
        Sync memory c = Sync(synced, r.chunk, files, count, maxChunks, flags & ON_CHAIN != 0);
        if (storeId != 0) {
            _onlyArtist(tokenId);
            // Resumes only on the same store and ahead of the content store's walk.
            uint256 cursor = _storeCursors[tokenId];
            uint256 file = (cursor >> 24) & 0xff;
            c.chunk = 0;
            if (cursor >> 32 == storeId && file >= synced) {
                (c.next, c.chunk) = (file, cursor & 0xffffff);
            }
        }
        uint256 start = c.next;
        _advance(tokenId, storeId, source, c);
        // An upgrade walk that reached the end with budget left goes round once more, up to
        // where it started, so a file before the cursor never waits on one after it.
        if (c.done && storeId == 0 && c.next == count && c.budget != 0 && start != 0) {
            (c.next, c.chunk, c.count) = (0, 0, start);
            _advance(tokenId, 0, source, c);
        }
        if (c.budget == maxChunks) revert NotOnChainComplete(tokenId);
        if (storeId == 0) {
            // At most `Limits.MAX_MEDIA_FILES` (32), and below a manifest's chunk count, which
            // the content store bounds far below 2^24.
            // forge-lint: disable-next-line(unsafe-typecast)
            r.syncedFiles = uint8(c.next);
            // forge-lint: disable-next-line(unsafe-typecast)
            r.chunk = uint24(c.chunk);
            synced = c.next;
        } else {
            _storeCursors[tokenId] = (storeId << 32) | (c.next << 24) | c.chunk;
        }
        r.files = c.files;
        emit OnChainSyncProgress(tokenId, c.next, c.chunk, storeId);
        // On-chain complete once every file is complete in some store; afterwards each call that
        // upgrades a file to the content store refreshes the metadata again.
        if (c.done) {
            if (c.files == files) return;
        } else {
            uint256 i = synced;
            while (i < count && (c.files >> (8 * i + 4)) & 0xf != 0) {
                ++i;
            }
            if (i != count) return;
            r.flags = flags | ON_CHAIN;
            emit WorkOnChainComplete(tokenId);
        }
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    function isOpen(uint256 tokenId) external view returns (bool) {
        return _records[tokenId].flags & OPENED != 0;
    }

    /// @inheritdoc IWorkRecords
    function record(uint256 tokenId) external view returns (RecordInfo memory) {
        RecordData storage r = _open(tokenId);
        uint8 flags = r.flags;
        return RecordInfo(
            r.recordFileId,
            r.mediaHash,
            WorksHashing.licenseKey(licenseOf(tokenId).spdxId),
            r.version,
            flags & FINALIZED != 0,
            flags & ON_CHAIN != 0,
            r.renderer
        );
    }

    /// @inheritdoc IWorkRecords
    /// @dev Each file's SHA-256 is read from the content store, which declared exactly the
    ///      committed value when the record opened (declarations never change).
    function mediaOf(uint256 tokenId) external view returns (MediaFile[] memory media) {
        RecordData storage r = _open(tokenId);
        media = new MediaFile[](r.mediaCount);
        uint256 files = r.files;
        bytes32[32] storage list = _media[tokenId];
        for (uint256 i; i < media.length; ++i) {
            bytes32 fileId = list[i];
            // Four bits.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 role = uint8((files >> (8 * i)) & 0xf);
            media[i] = MediaFile(fileId, IContentStore(contentStore).sha256Of(fileId), role);
        }
    }

    /// @inheritdoc IWorkRecords
    function mediaIndex(uint256 tokenId, bytes32 fileId) external view returns (uint256) {
        _open(tokenId);
        return _mediaIndex(tokenId, fileId);
    }

    /// @inheritdoc IWorkRecords
    function mediaStore(uint256 tokenId, uint256 index)
        external
        view
        returns (uint256 storeId, bool complete)
    {
        RecordData storage r = _open(tokenId);
        if (index >= r.mediaCount) revert FileNotInWork(tokenId, bytes32(index));
        storeId = (r.files >> (8 * index + 4)) & 0xf;
        complete = r.flags & ON_CHAIN != 0 || index < r.syncedFiles || storeId != 0;
    }

    /// @inheritdoc IWorkRecords
    function licenseOf(uint256 tokenId) public view returns (License memory) {
        if (_open(tokenId).flags & CUSTOM_LICENSE != 0) return _licenses[tokenId];
        return License(_cc0SpdxId, cc0TextFileId);
    }

    /// @inheritdoc IWorkRecords
    /// @dev `keccak256(abi.encode(domain, tokenId, version, recordFileId, licenseKey,
    ///      textFileId, royaltyRate, renderer))`, with the default renderer before finalize.
    function workStateHash(uint256 tokenId) public view returns (bytes32) {
        RecordData storage r = _open(tokenId);
        License memory license = licenseOf(tokenId);
        return keccak256(
            abi.encode(
                STATE_DOMAIN,
                tokenId,
                r.version,
                r.recordFileId,
                WorksHashing.licenseKey(license.spdxId),
                license.textFileId,
                _royaltyRateOf(tokenId),
                r.flags & FINALIZED != 0 ? r.renderer : IStream(stream).defaultRenderer()
            )
        );
    }

    /// @inheritdoc IWorkRecords
    /// @dev The code must still be the code the renderer was pinned with (DEPS-6).
    function pinnedRenderer(uint256 tokenId) external view returns (address renderer) {
        renderer = _open(tokenId).renderer;
        if (renderer != address(0)) {
            Dependency.checkUnchanged(renderer, _rendererCodeHashes[renderer]);
        }
    }

    /// @dev The artist registry resolving every party's active authority: 6529 Stream's, which
    ///      6529 Stream sets once at genesis and never replaces.
    function _artistRegistry() private view returns (address) {
        return IStream(stream).artistRegistry();
    }

    /// @inheritdoc IWorkRecords
    function seedOf(uint256 tokenId) external view returns (uint8 policy, bytes32 seed) {
        _open(tokenId);
        (,,,, policy,) = IStream(stream).coreOf(tokenId);
        seed = _seeds[tokenId];
    }

    // ------------------------------------------------------------------------------ amendments

    /// @inheritdoc IWorkRecords
    /// @dev Only CC0 irrevocability is enforced on-chain, on the canonical key, and a CC0
    ///      license always names the deployment's CC0 text. Whether `next` is more permissive is
    ///      a judgement the consents and the governed action carry. A license with the current
    ///      key and text is a no-op.
    function relicense(
        uint256 tokenId,
        License calldata next,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external restricted {
        RecordData storage r = _open(tokenId);
        _checkPower(r, tokenId, WorkPowers.RELICENSE);
        License memory previous = licenseOf(tokenId);
        bytes32 nextKey = _relicenseKey(tokenId, previous, next);
        if (nextKey == 0) return;
        _requireLicenseText(next.textFileId, r.flags & FINALIZED != 0);
        bytes32 structHash =
            _relicenseHash(tokenId, nextKey, next.textFileId, expectedStateHash, deadline);
        _checkConsents(tokenId, item, structHash, deadline, partySignatures);
        if (_isDefaultLicense(next)) {
            r.flags &= ~CUSTOM_LICENSE;
            delete _licenses[tokenId];
        } else {
            r.flags |= CUSTOM_LICENSE;
            _licenses[tokenId] = next;
        }
        ++r.version;
        emit LicenseChanged(tokenId, previous, next, workStateHash(tokenId));
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    /// @dev Lower-only (ADR 0006). The version bumps after the view calls that check state and
    ///      consents and before the state-changing ones; the core emits
    ///      `RoyaltyRateChanged`, a linked edition's rate follows its master's.
    function setRoyaltyRate(
        uint256 tokenId,
        uint32 rate,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external restricted {
        RecordData storage r = _open(tokenId);
        _checkPower(r, tokenId, WorkPowers.ROYALTY_RATE);
        uint32 previous = _royaltyRateOf(tokenId);
        if (rate == previous) return;
        if (rate > previous) revert RoyaltyRateNotLowered(tokenId, previous, rate);
        bytes32 structHash = keccak256(
            abi.encode(
                Typehashes.ROYALTY_RATE_CHANGE,
                tokenId,
                rate,
                _checkState(tokenId, expectedStateHash),
                deadline
            )
        );
        _checkConsents(tokenId, item, structHash, deadline, partySignatures);
        ++r.version;
        _applyRate(tokenId, previous, rate);
    }

    /// @inheritdoc IWorkRecords
    /// @dev Pinning the current renderer again is a no-op, unless the power is renounced.
    function repinRenderer(
        uint256 tokenId,
        address renderer,
        bytes32 rendererCodeHash,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external restricted {
        RecordData storage r = _open(tokenId);
        _checkPower(r, tokenId, WorkPowers.RENDERER_REPIN);
        if (r.flags & FINALIZED == 0) revert WorkNotFinalized(tokenId);
        address previous = r.renderer;
        if (renderer == previous) return;
        Dependency.checkPinned(renderer, type(IRenderer).interfaceId, rendererCodeHash);
        bytes32 structHash = keccak256(
            abi.encode(
                Typehashes.RENDERER_REPIN,
                tokenId,
                renderer,
                rendererCodeHash,
                _checkState(tokenId, expectedStateHash),
                deadline
            )
        );
        _checkArtistConsent(tokenId, structHash, deadline, artistSignature);
        _pinCode(renderer, rendererCodeHash);
        r.renderer = renderer;
        ++r.version;
        emit RendererRepinned(tokenId, previous, renderer, rendererCodeHash, workStateHash(tokenId));
        _refresh(tokenId);
    }

    // -------------------------------------------------------------------------------- powers

    /// @inheritdoc IWorkPowers
    /// @dev Authenticated as `repinRenderer` is: the lead artist's active authority (zero while
    ///      an authority-moving override is pending). Collaborators do not sign: each power
    ///      already needs the lead artist's signature. The version bump is the replay protection.
    function renounce(
        uint256 tokenId,
        uint16 powers,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external {
        RecordData storage r = _open(tokenId);
        if (powers & ~WorkPowers.ALL != 0) revert UnknownPower(powers);
        uint16 renounced = r.renounced;
        if (powers & ~renounced == 0) return;
        if (powers & WorkPowers.RENDERER_REPIN != 0 && r.flags & FINALIZED == 0) {
            revert WorkNotFinalized(tokenId);
        }
        // A license that can no longer change must be one the renderer can show, and one that
        // `finalize` can accept: only its missing chunks, which anyone may write, may remain.
        if (powers & WorkPowers.RELICENSE != 0) {
            _requireLicenseText(_frozenLicense(tokenId, r.flags), false);
        }
        bytes32 structHash = keccak256(
            abi.encode(
                Typehashes.RENOUNCE_POWERS,
                tokenId,
                powers,
                _checkState(tokenId, expectedStateHash),
                deadline
            )
        );
        _checkArtistConsent(tokenId, structHash, deadline, artistSignature);
        renounced |= powers;
        r.renounced = renounced;
        ++r.version;
        emit PowersRenounced(tokenId, powers, renounced, workStateHash(tokenId));
    }

    /// @inheritdoc IWorkPowers
    function renouncedPowers(uint256 tokenId) external view returns (uint16) {
        return _open(tokenId).renounced;
    }

    // ------------------------------------------------------------------------------ delivery

    /// @inheritdoc IWorkRecords
    function setDelivery(address expected, address next) external restricted {
        address current = delivery;
        if (current != expected) revert DeliveryMismatch();
        Dependency.check(next, type(IWorkDelivery).interfaceId);
        if (
            IWorkDelivery(next).records() != address(this)
                || IWorkDelivery(next).predecessor() != current
        ) revert Dependency.InvalidDependency(next);
        delivery = next;
        emit DeliverySet(current, next);
        _refreshAll();
    }

    /// @inheritdoc IWorkRecords
    /// @dev The delivery contract's answer is used only when it is the canonical encoding of an
    ///      allowed location (`_isLocation`); a refusal or anything else yields the work's own
    ///      answer from the on-chain flag. A shortfall reverts inside `BoundedCall`.
    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (IWorkDelivery.Location memory locator, uint256 index)
    {
        bool onChain = _open(tokenId).flags & ON_CHAIN != 0;
        _mediaIndex(tokenId, fileId);
        (bool ok, bytes memory data) = BoundedCall.tryReadAll(
            delivery,
            abi.encodeCall(IWorkDelivery.preferredLocator, (tokenId, fileId)),
            LOCATION_RETURN
        );
        if (ok && _isLocation(data, onChain)) {
            // The canonical encoding of the return values, checked: returned as it is.
            assembly ("memory-safe") {
                return(add(data, 0x20), mload(data))
            }
        }
        if (onChain) locator.kind = uint8(KIND_ONCHAIN);
        index = NONE;
    }

    /// @inheritdoc IWorkRecords
    function refreshMetadata(uint256 tokenId) external {
        _onlyDelivery();
        _open(tokenId);
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    function refreshAllMetadata() external {
        _onlyDelivery();
        _refreshAll();
    }

    // -------------------------------------------------------------------------------- stores

    /// @inheritdoc IWorkRecords
    function addStore(address source, bytes32 codeHash) external restricted {
        uint256 id = _stores.length + 1;
        if (id >= MAX_STORES) revert StoreLimitReached();
        Dependency.checkPinned(source, codeHash);
        _stores.push(StoreEntry(source, codeHash));
        emit StoreAdded(id, source, codeHash);
    }

    /// @inheritdoc IWorkRecords
    function store(uint256 storeId) external view returns (address source) {
        (source,) = _storeOf(storeId);
    }

    /// @notice ERC-165: `IWorkRecords`, which 6529 Stream and 6529 Stream Editions check when
    ///         binding, and `IWorkPowers`.
    /// @param interfaceId The interface ID to test.
    /// @return True for the `IWorkRecords`, `IWorkPowers` and `IERC165` interface IDs.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IWorkRecords).interfaceId
            || interfaceId == type(IWorkPowers).interfaceId || super.supportsInterface(interfaceId);
    }

    // -------------------------------------------------------------------------------- internal

    /// @dev The item hash of `item` (`WorksHashing.itemHashCalldata`).
    function _itemHash(PackageItem calldata item) private pure returns (bytes32) {
        return WorksHashing.itemHashCalldata(item);
    }

    /// @dev Records the code hash `renderer` is pinned with, the first time it is pinned. A
    ///      renderer already pinned with another code hash is refused.
    function _pinCode(address renderer, bytes32 codeHash) private {
        bytes32 pinned = _rendererCodeHashes[renderer];
        if (pinned == 0) _rendererCodeHashes[renderer] = codeHash;
        else if (pinned != codeHash) revert Dependency.DependencyCodeChanged(renderer);
    }

    /// @dev The canonical key of `next`, or zero when it is the current license (a no-op).
    ///      Reverts when leaving CC0, when a CC0 license would name any text but the
    ///      deployment's CC0 text, or for an invalid identifier.
    function _relicenseKey(uint256 tokenId, License memory previous, License calldata next)
        private
        view
        returns (bytes32 nextKey)
    {
        bytes32 previousKey = WorksHashing.licenseKey(previous.spdxId);
        nextKey = WorksHashing.licenseKey(next.spdxId);
        if (nextKey == previousKey && next.textFileId == previous.textFileId) return 0;
        bytes32 cc0 = WorksHashing.CC0_LICENSE_KEY;
        if (previousKey == cc0 && nextKey != cc0) revert LicenseIrrevocable(tokenId);
        if (
            (nextKey == cc0 && next.textFileId != cc0TextFileId)
                || !SpdxId.isValidCalldata(next.spdxId)
        ) revert InvalidLicense();
    }

    function _relicenseHash(
        uint256 tokenId,
        bytes32 licenseKey,
        bytes32 textFileId,
        bytes32 expectedStateHash,
        uint64 deadline
    ) private view returns (bytes32) {
        bytes32 state = _checkState(tokenId, expectedStateHash);
        return keccak256(
            abi.encode(Typehashes.RELICENSE, tokenId, licenseKey, textFileId, state, deadline)
        );
    }

    /// @dev Reverts with `PowerRenounced` once the lead artist renounced `power` for the work.
    function _checkPower(RecordData storage r, uint256 tokenId, uint16 power) private view {
        if (r.renounced & power != 0) revert PowerRenounced(tokenId, power);
    }

    function _open(uint256 tokenId) private view returns (RecordData storage r) {
        r = _records[tokenId];
        if (r.flags & OPENED == 0) revert RecordNotOpen(tokenId);
    }

    function _onlyDelivery() private view {
        if (msg.sender != delivery) revert NotDelivery();
    }

    function _checkState(uint256 tokenId, bytes32 expected) private view returns (bytes32 state) {
        state = workStateHash(tokenId);
        if (state != expected) revert StateHashMismatch(expected, state);
    }

    /// @dev The lead artist's active authority (zero while a recovery override is pending);
    ///      reverts with the core's `UnknownWork` for a burned token.
    function _artistOf(uint256 tokenId) private view returns (address) {
        return
            IArtistRegistry(_artistRegistry()).activeAuthorityOf(IStream(stream).artistOf(tokenId));
    }

    function _onlyArtist(uint256 tokenId) private view {
        if (_artistOf(tokenId) != msg.sender) revert NotWorkArtist(tokenId, msg.sender);
    }

    /// @dev The lead artist's active authority signed `structHash` before `deadline`
    ///      (`InvalidConsent(tokenId, 0)` otherwise): the errata repin and renunciation.
    function _checkArtistConsent(
        uint256 tokenId,
        bytes32 structHash,
        uint64 deadline,
        bytes calldata signature
    ) private view {
        SignatureVerifier.checkDeadline(deadline);
        if (!SignatureVerifier.isValid(_artistOf(tokenId), _hashTypedDataV4(structHash), signature))
        {
            revert InvalidConsent(tokenId, 0);
        }
    }

    /// @dev Every party of the work's item consents, in order, each by its active authority
    ///      (artist ID `artistIdOf(account)`, else `uint160(account)`). A wrong count reports the
    ///      party index `signatures.length`. Unanimity is the rule (ADR 0006); a party whose
    ///      authority is a contract wallet decides by that wallet's own rule (ERC-1271).
    function _checkConsents(
        uint256 tokenId,
        PackageItem calldata item,
        bytes32 structHash,
        uint64 deadline,
        bytes[] calldata signatures
    ) private view {
        if (_itemHash(item) != _itemHashOf(tokenId)) {
            revert InvalidRecordData(tokenId);
        }
        SignatureVerifier.checkDeadline(deadline);
        uint256 parties = item.parties.length;
        if (signatures.length != parties) revert InvalidConsent(tokenId, signatures.length);
        bytes32 digest = _hashTypedDataV4(structHash);
        IArtistRegistry registry = IArtistRegistry(_artistRegistry());
        for (uint256 i; i < parties; ++i) {
            address account = item.parties[i].account;
            uint256 artistId = registry.artistIdOf(account);
            if (artistId == 0) artistId = uint256(uint160(account));
            if (!SignatureVerifier.isValid(
                    registry.activeAuthorityOf(artistId), digest, signatures[i]
                )) {
                revert InvalidConsent(tokenId, i);
            }
        }
    }

    function _isDefaultLicense(License memory license) private view returns (bool) {
        return license.textFileId == cc0TextFileId
            && keccak256(bytes(license.spdxId)) == keccak256(bytes(_cc0SpdxId));
    }

    function _itemHashOf(uint256 tokenId) private view returns (bytes32 itemHash) {
        (itemHash,,,,,) = IStream(stream).coreOf(tokenId);
    }

    function _royaltyRateOf(uint256 tokenId) private view returns (uint32 rate) {
        (,,,,, rate) = IStream(stream).coreOf(tokenId);
    }

    /// @dev Applies a consented rate in the core and a linked edition, then reports it.
    function _applyRate(uint256 tokenId, uint32 previous, uint32 rate) private {
        IStream(stream).setRoyaltyRate(tokenId, rate);
        (address editions, uint256 editionId) = IStream(stream).editionOf(tokenId);
        if (editions != address(0)) IEditions(editions).setRoyaltyRate(editionId, rate);
        emit RoyaltyRateSet(tokenId, previous, rate, workStateHash(tokenId));
        _refresh(tokenId);
    }

    /// @dev A license's text must be a registered content-store file with a SHA-256 digest in at
    ///      most `MAX_LICENSE_TEXT_CHUNKS` chunks, and complete on-chain when `stored`. The
    ///      digest kind is `_fileInfo`'s encoding above its low byte, zero only for SHA-256. The
    ///      chunk count and digest kind are fixed by the file ID, so a text that passes here
    ///      can only lack chunks, which anyone may write.
    function _requireLicenseText(bytes32 textFileId, bool stored) private view {
        (,, uint256 chunks, uint256 encoding) = _fileInfo(textFileId, false);
        if (
            encoding >> 8 != 0 || chunks > MAX_LICENSE_TEXT_CHUNKS
                || (stored && !IContentStore(contentStore).isComplete(textFileId))
        ) revert InvalidLicense();
    }

    /// @dev The text file of the work's license, once a stored license's identifier passes the
    ///      rule the mint policy applies (`SpdxId`: 1 to 64 bytes of `[A-Za-z0-9.+-]`, so UTF-8),
    ///      which `openRecord` does not check: a license that freezes (finalize, renouncing
    ///      RELICENSE) is one the renderer can show.
    function _frozenLicense(uint256 tokenId, uint8 flags) private view returns (bytes32) {
        if (flags & CUSTOM_LICENSE == 0) return cc0TextFileId;
        License storage license = _licenses[tokenId];
        if (!SpdxId.isValid(license.spdxId)) revert InvalidLicense();
        return license.textFileId;
    }

    /// @dev The record file's structural bounds: registered, one chunk (at most `CHUNK`
    ///      bytes, so every check is O(1)), `Identity` with a SHA-256 digest, and complete. What a
    ///      renderer can show is the renderer's to decide: it refuses a record it cannot render
    ///      (core-only metadata with a record status). Only the store's `ContentFileUnknown`
    ///      reads as unregistered; any other failure propagates.
    function _checkRecordFile(bytes32 fileId) private view {
        (, uint256 length,, uint256 encoding) = _fileInfo(fileId, true);
        if (
            length > CHUNK || encoding != uint256(IContentStore.Encoding.Identity)
                || !IContentStore(contentStore).isComplete(fileId)
        ) revert UnknownRecordFile(fileId);
    }

    /// @dev A file's declared digest, stored length, chunk count and encoding, read in place
    ///      from the trusted store's `fileInfo` answer (one dynamic tuple: offset, digest, length,
    ///      chunkCount, encoding, the MIME type's offset, digestKind, then the MIME type). The
    ///      digest kind is returned in `encoding`'s second byte, so a digest that is not SHA-256
    ///      (kind 0) never matches an expected encoding. A store revert propagates, except
    ///      that for a record file (`isRecord`) the store's `ContentFileUnknown` reverts with
    ///      `UnknownRecordFile`.
    function _fileInfo(bytes32 fileId, bool isRecord)
        private
        view
        returns (bytes32 sha, uint256 length, uint256 chunks, uint256 encoding)
    {
        (bool ok, bytes memory info) =
            contentStore.staticcall(abi.encodeCall(IContentStore.fileInfo, (fileId)));
        // Only the selector is compared, so truncating to four bytes is intended.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (
            !ok && isRecord && info.length > 3
                && bytes4(info) == IContentStore.ContentFileUnknown.selector
        ) {
            revert UnknownRecordFile(fileId);
        }
        assembly ("memory-safe") {
            if or(iszero(ok), lt(mload(info), 0x100)) {
                revert(add(info, 0x20), mload(info))
            }
            sha := mload(add(info, 0x40))
            length := mload(add(info, 0x60))
            chunks := mload(add(info, 0x80))
            encoding := or(mload(add(info, 0xa0)), shl(8, mload(add(info, 0xe0))))
        }
    }

    function _mediaIndex(uint256 tokenId, bytes32 fileId) private view returns (uint256 i) {
        bytes32[32] storage list = _media[tokenId];
        uint256 count = _records[tokenId].mediaCount;
        for (; i < count; ++i) {
            if (list[i] == fileId) return i;
        }
        revert FileNotInWork(tokenId, fileId);
    }

    /// @dev Store `storeId` and whether its code is still the code it was added with (the
    ///      content store, 0, always is). Reverts with `UnknownStore` for an unused ID.
    function _storeOf(uint256 storeId) private view returns (address source, bool intact) {
        if (storeId == 0) return (contentStore, true);
        if (storeId > _stores.length) revert UnknownStore(storeId);
        StoreEntry storage e = _stores[storeId - 1];
        source = e.source;
        intact = source.codehash == e.codeHash;
    }

    /// @dev Moves the sync cursor `c` of work `tokenId` over at most `c.budget` chunks verified
    ///      against store `storeId`, recording each file that completes. An added store's walk
    ///      skips files already complete (those before the content walk's cursor, and those
    ///      complete in an added store). The content store's walk verifies every file not yet
    ///      complete there, one complete in an added store included (an upgrade), and passes
    ///      over such a file when the content store lacks a chunk of it, so it never waits on a
    ///      file another store already completed; once the work is on-chain complete it skips the
    ///      files complete in the content store.
    function _advance(uint256 tokenId, uint256 storeId, address source, Sync memory c) private {
        while (c.next < c.count && c.budget != 0) {
            uint256 shift = 8 * c.next + 4;
            uint256 added = (c.files >> shift) & 0xf;
            if (storeId != 0 ? added != 0 : c.done && added == 0) {
                ++c.next;
                c.chunk = 0;
                continue;
            }
            (uint256 reached, uint256 chunks) =
                _verify(source, _media[tokenId][c.next], c.chunk, c.budget);
            c.budget -= reached - c.chunk;
            c.chunk = reached;
            if (reached < chunks) {
                // Out of budget, or a chunk missing from a file complete nowhere: stop here.
                if (c.budget == 0 || storeId != 0 || added == 0) return;
                ++c.next;
                c.chunk = 0;
                continue;
            }
            c.files = (c.files & ~(uint256(0xf) << shift)) | (storeId << shift);
            emit MediaFileComplete(tokenId, c.next, storeId);
            ++c.next;
            c.chunk = 0;
        }
    }

    /// @dev Verifies at most `budget` chunks of `fileId` from `from` against `source` with the
    ///      content store's check, which presence-checks its own chunks (a ranged call) and
    ///      re-hashes and length-checks what an added store (`IChunkStore`) returns. An added
    ///      store is checked one chunk at a time, forward-all: a chunk it refuses (reverts, or
    ///      serves other bytes) is missing, so the progress before it stands; running short of
    ///      gas reverts with `BoundedCallShortfall` and never reads as missing.
    /// @return reached The first chunk not verified (missing, or past the budget).
    /// @return chunks The file's chunk count.
    function _verify(address source, bytes32 fileId, uint256 from, uint256 budget)
        private
        view
        returns (uint256 reached, uint256 chunks)
    {
        (,, chunks,) = _fileInfo(fileId, false);
        uint256 to = chunks - from > budget ? from + budget : chunks;
        if (source == contentStore) {
            return (IContentStore(contentStore).firstMissing(fileId, from, to, source), chunks);
        }
        for (reached = from; reached < to; ++reached) {
            (bool ok, bytes32 word) = BoundedCall.tryReadWordAll(
                contentStore,
                abi.encodeCall(IContentStore.firstMissing, (fileId, reached, reached + 1, source))
            );
            if (!ok || uint256(word) != reached + 1) break;
        }
    }

    /// @dev Whether `data` is the canonical encoding of `(Location, uint256)` that may be
    ///      served: a URI of at most `Limits.MAX_URI_BYTES` of `URI_BYTES`, empty exactly for
    ///      kinds NONE and ONCHAIN (whose index must be `NONE`), and ONCHAIN only when the work is
    ///      on-chain complete. The padding is not checked: readers take the URI by its length.
    function _isLocation(bytes memory data, bool onChain) private pure returns (bool) {
        if (data.length < 0xa0) return false;
        uint256 head;
        uint256 index;
        uint256 kind;
        uint256 inner;
        uint256 length;
        assembly ("memory-safe") {
            head := mload(add(data, 0x20))
            index := mload(add(data, 0x40))
            kind := mload(add(data, 0x60))
            inner := mload(add(data, 0x80))
            length := mload(add(data, 0xa0))
        }
        if (head != 0x40 || inner != 0x40 || kind > type(uint8).max) return false;
        if (length > Limits.MAX_URI_BYTES) return false;
        if (data.length != 0xa0 + ((length + 31) & ~uint256(31))) return false;
        bool bare = kind == KIND_NONE || kind == KIND_ONCHAIN;
        if (bare != (length == 0) || (bare && index != NONE)) return false;
        if (kind == KIND_ONCHAIN && !onChain) return false;
        bool ok = true;
        assembly ("memory-safe") {
            let p := add(data, 0xc0)
            for { let end := add(p, length) } lt(p, end) { p := add(p, 1) } {
                ok := and(ok, shr(byte(0, mload(p)), URI_BYTES))
            }
        }
        return ok;
    }

    /// @dev ERC-4906 through the core, and a linked edition master's edition through 6529
    ///      Stream Editions.
    function _refresh(uint256 tokenId) private {
        IStream(stream).emitMetadataUpdate(tokenId, tokenId);
        (address editions,) = IStream(stream).editionOf(tokenId);
        if (editions != address(0)) IEditions(editions).notifyMasterUpdated(tokenId);
    }

    /// @dev ERC-4906 for every token ever minted (burned IDs included, harmlessly) and every
    ///      edition.
    function _refreshAll() private {
        IStream core = IStream(stream);
        uint256 minted = core.totalMinted();
        if (minted != 0) core.emitMetadataUpdate(1, minted);
        address editions = core.editions();
        if (editions != address(0)) IEditions(editions).notifyAllUpdated();
    }
}
