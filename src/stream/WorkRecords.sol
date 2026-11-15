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
import {
    IChunkSource,
    IContentStoreRange,
    IRecordLimits,
    IWorkRecords
} from "../interfaces/IWorkRecords.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { License } from "../interfaces/types/PackageTypes.sol";
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
///      Gas rule: a call whose outcome this contract interprets (the delivery contract, a store
///      adapter, a renderer's bounds, a wallet's ERC-1271 check, an ERC-165 probe) goes through
///      `BoundedCall`'s forward-all reads, so running short of gas reverts with
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
    /// @dev Media roles with meaning here (the rest are recorded, not interpreted).
    uint8 private constant PRIMARY = 0;
    uint8 private constant PREVIEW = 1;
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
    /// @dev The chunk size of every content-store manifest, and the largest record file (one
    ///      chunk keeps the record checks O(1)).
    uint256 private constant CHUNK = SSTORE2.MAX_CHUNK_LENGTH;

    /// @dev Word 0: the pin, version, media count, how many leading media files are complete,
    ///      flags, the chunk cursor in the next file, and the renounced powers (`WorkPowers`
    ///      bits, only ever added). `files` holds a byte per media file, file `i` at bits `8i`:
    ///      its role in the low four bits, its store in the high four.
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

    /// @dev A `syncOnChain` cursor in memory: complete files, the chunk in the next file, the
    ///      `files` word, the media count and the chunks left in the call's budget.
    struct Sync {
        uint256 next;
        uint256 chunk;
        uint256 files;
        uint256 count;
        uint256 budget;
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
                || IContentStore(contentStore_).sha256Of(cc0.textFileId) == 0
        ) {
            revert InvalidLicense();
        }
        stream = stream_;
        contentStore = contentStore_;
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
    function openRecord(uint256 tokenId, WorkItem calldata item, WorkMedia[] calldata media)
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
        uint256 previewBound = NONE;
        bytes32[32] storage list = _media[tokenId];
        for (uint256 i; i < count; ++i) {
            WorkMedia calldata file = media[i];
            uint256 role = file.role;
            bytes32 declared;
            if (role == PREVIEW) {
                if (previewBound == NONE) {
                    (, previewBound) = _limits(IStream(stream).defaultRenderer());
                }
                declared = _previewSha(tokenId, file.fileId, previewBound);
            } else {
                // Reverts with the store's `ContentFileUnknown` for an unregistered file.
                declared = IContentStore(contentStore).sha256Of(file.fileId);
            }
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
        _checkRecordFile(recordFileId, IStream(stream).defaultRenderer());
        r.recordFileId = recordFileId;
        ++r.version;
        emit RecordSet(tokenId, recordFileId, workStateHash(tokenId));
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    /// @dev The approved record file reaches here unchecked when the artist never replaced it,
    ///      so finalize applies the structural bounds itself, with the record bound of the
    ///      renderer it pins. The license text must be complete on-chain.
    function finalize(uint256 tokenId, bytes32 expectedStateHash) external {
        RecordData storage r = _open(tokenId);
        uint8 flags = r.flags;
        if (flags & FINALIZED != 0) revert WorkIsFinalized(tokenId);
        _onlyArtist(tokenId);
        _checkState(tokenId, expectedStateHash);
        // The default renderer, its code checked against Stream's pin (not finalized: no pin).
        address renderer = IStream(stream).rendererOf(tokenId);
        _checkRecordFile(r.recordFileId, renderer);
        _requireLicenseText(
            flags & CUSTOM_LICENSE != 0 ? _licenses[tokenId].textFileId : cc0TextFileId, true
        );
        _pinCode(renderer, renderer.codehash);
        r.renderer = renderer;
        r.flags = flags | FINALIZED;
        ++r.version;
        emit WorkFinalized(tokenId, renderer, workStateHash(tokenId));
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    /// @dev Media is fixed by approval and verified bytes are permanent, so verified progress
    ///      only moves forward: the cursor (`syncedFiles`, `chunk`) lives in the record's first
    ///      word and each file's store in its byte of `files`, so no slot is added. The store of
    ///      a file in progress may change only when it lacks the file's next chunk, so no caller
    ///      can undo another's progress; a file's store is final once the file completes.
    function syncOnChain(uint256 tokenId, uint256 storeId, uint256 maxChunks) external {
        RecordData storage r = _open(tokenId);
        if (r.flags & ON_CHAIN != 0 || maxChunks == 0) return;
        (address source, bool intact) = _storeOf(storeId);
        if (!intact) revert UnknownStore(storeId);
        Sync memory c = Sync(r.syncedFiles, 0, r.files, r.mediaCount, maxChunks);
        c.chunk = _startChunk(tokenId, r, storeId, c.next);
        _advance(tokenId, storeId, source, c);
        if (c.budget == maxChunks) revert NotOnChainComplete(tokenId);
        // At most `Limits.MAX_MEDIA_FILES` (32), and below a manifest's chunk count, which the
        // content store bounds far below 2^24.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.syncedFiles = uint8(c.next);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.chunk = uint24(c.chunk);
        r.files = c.files;
        emit OnChainSyncProgress(tokenId, c.next, c.chunk, storeId);
        if (c.next == c.count) {
            r.flags |= ON_CHAIN;
            emit WorkOnChainComplete(tokenId);
            _refresh(tokenId);
        }
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
    function mediaOf(uint256 tokenId) external view returns (WorkMedia[] memory media) {
        RecordData storage r = _open(tokenId);
        media = new WorkMedia[](r.mediaCount);
        uint256 files = r.files;
        bytes32[32] storage list = _media[tokenId];
        for (uint256 i; i < media.length; ++i) {
            bytes32 fileId = list[i];
            // Four bits.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 role = uint8((files >> (8 * i)) & 0xf);
            media[i] = WorkMedia(fileId, IContentStore(contentStore).sha256Of(fileId), role);
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
        complete = index < r.syncedFiles;
    }

    /// @inheritdoc IWorkRecords
    function syncCursor(uint256 tokenId) external view returns (uint256 files, uint256 chunk) {
        RecordData storage r = _open(tokenId);
        return (r.syncedFiles, r.chunk);
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

    /// @inheritdoc IWorkRecords
    function rendererCodeHash(address renderer) external view returns (bytes32) {
        return _rendererCodeHashes[renderer];
    }

    /// @dev The artist registry resolving every party's active authority: 6529 Stream's, read
    ///      on every use, so a governed replacement there applies at once.
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
        WorkItem calldata item,
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
    /// @dev Lower-only (ADR 0006). The version bumps before the external calls; the core emits
    ///      `RoyaltyRateChanged`, a linked edition's rate follows its master's.
    function setRoyaltyRate(
        uint256 tokenId,
        uint32 rate,
        WorkItem calldata item,
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
        bytes32 rendererCodeHash_,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external restricted {
        RecordData storage r = _open(tokenId);
        _checkPower(r, tokenId, WorkPowers.RENDERER_REPIN);
        if (r.flags & FINALIZED == 0) revert WorkNotFinalized(tokenId);
        address previous = r.renderer;
        if (renderer == previous) return;
        Dependency.checkPinned(renderer, type(IRenderer).interfaceId, rendererCodeHash_);
        bytes32 structHash = keccak256(
            abi.encode(
                Typehashes.RENDERER_REPIN,
                tokenId,
                renderer,
                rendererCodeHash_,
                _checkState(tokenId, expectedStateHash),
                deadline
            )
        );
        _checkArtistConsent(tokenId, structHash, deadline, artistSignature);
        _pinCode(renderer, rendererCodeHash_);
        r.renderer = renderer;
        ++r.version;
        emit RendererRepinned(
            tokenId, previous, renderer, rendererCodeHash_, workStateHash(tokenId)
        );
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
        if (current != expected) revert DeliveryMismatch(expected, current);
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

    /// @inheritdoc IWorkRecords
    function storeCount() external view returns (uint256) {
        return _stores.length + 1;
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

    /// @dev The item hash of `item`: `WorksHashing.itemHash` of the same ABI bytes.
    function _itemHash(WorkItem calldata item) private pure returns (bytes32) {
        return keccak256(abi.encode(WorksHashing.PACKAGE_ITEM_DOMAIN, item));
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
        if (msg.sender != delivery) revert NotDelivery(msg.sender);
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
        WorkItem calldata item,
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

    /// @dev A license's text must be a registered content-store file, and complete on-chain
    ///      when `stored`.
    function _requireLicenseText(bytes32 textFileId, bool stored) private view {
        IContentStore cs = IContentStore(contentStore);
        if (stored ? !cs.isComplete(textFileId) : cs.sha256Of(textFileId) == 0) {
            revert InvalidLicense();
        }
    }

    /// @dev A renderer's record and preview bounds (`IRecordLimits`), or the compiled ones when
    ///      it does not answer exactly two words; the record bound never exceeds one chunk.
    function _limits(address renderer)
        private
        view
        returns (uint256 maxRecord, uint256 maxPreview)
    {
        (bool ok, bytes memory data) = BoundedCall.tryReadAll(
            renderer, abi.encodeCall(IRecordLimits.recordLimits, ()), 64
        );
        if (!ok || data.length != 64) return (Limits.MAX_RECORD_BYTES, Limits.MAX_PREVIEW_BYTES);
        (maxRecord, maxPreview) = abi.decode(data, (uint256, uint256));
        if (maxRecord > CHUNK) maxRecord = CHUNK;
    }

    /// @dev The record file's structural bounds: registered, at most `renderer`'s record bound
    ///      (at most one chunk), `Identity`, and complete. Each check is O(1). Only the store's
    ///      `ContentFileUnknown` reads as unregistered; any other failure propagates.
    function _checkRecordFile(bytes32 fileId, address renderer) private view {
        (, uint256 length,, uint256 encoding) = _fileInfo(fileId, true);
        (uint256 maxRecord,) = _limits(renderer);
        if (
            length > maxRecord || encoding != uint256(IContentStore.Encoding.Identity)
                || !IContentStore(contentStore).isComplete(fileId)
        ) revert UnknownRecordFile(fileId);
    }

    /// @dev The declared SHA-256 of a PREVIEW file of work `tokenId`. One the renderer can
    ///      inline (`Identity` or `Base64`) must be within `bound`, an `Identity` file counting
    ///      four times; a gzip one is served by locator only.
    function _previewSha(uint256 tokenId, bytes32 fileId, uint256 bound)
        private
        view
        returns (bytes32 sha)
    {
        uint256 length;
        uint256 encoding;
        (sha, length,, encoding) = _fileInfo(fileId, false);
        if (encoding == uint256(IContentStore.Encoding.Identity)) length *= 4;
        else if (encoding != uint256(IContentStore.Encoding.Base64)) length = 0;
        if (length > bound) revert InvalidRecordData(tokenId);
    }

    /// @dev A file's declared SHA-256, stored length, chunk count and encoding, read in place
    ///      from the trusted store's `fileInfo` answer (one dynamic tuple: offset, sha256Hash,
    ///      length, chunkCount, encoding, then the MIME type). A store revert propagates, except
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
            if or(iszero(ok), lt(mload(info), 0xc0)) { revert(add(info, 0x20), mload(info)) }
            sha := mload(add(info, 0x40))
            length := mload(add(info, 0x60))
            chunks := mload(add(info, 0x80))
            encoding := mload(add(info, 0xa0))
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
    ///      against store `storeId`, setting each touched file's store in `c.files`.
    function _advance(uint256 tokenId, uint256 storeId, address source, Sync memory c)
        private
        view
    {
        while (c.next < c.count && c.budget != 0) {
            uint256 shift = 8 * c.next + 4;
            c.files = (c.files & ~(uint256(0xf) << shift)) | (storeId << shift);
            (uint256 reached, uint256 chunks) =
                _verify(storeId, source, _media[tokenId][c.next], c.chunk, c.budget);
            c.budget -= reached - c.chunk;
            c.chunk = reached;
            if (reached < chunks) return;
            ++c.next;
            c.chunk = 0;
        }
    }

    /// @dev Where the file in progress resumes: its cursor when it stays with its store or has
    ///      none yet, else chunk 0 once its store proves to lack the next chunk (`StoreInUse`
    ///      while it still holds it). A store whose code changed holds nothing.
    function _startChunk(uint256 tokenId, RecordData storage r, uint256 storeId, uint256 next)
        private
        view
        returns (uint256 chunk)
    {
        chunk = r.chunk;
        uint256 held = (r.files >> (8 * next + 4)) & 0xf;
        if (held == storeId || chunk == 0) return chunk;
        (address heldSource, bool heldIntact) = _storeOf(held);
        if (heldIntact) {
            (uint256 reached,) = _verify(held, heldSource, _media[tokenId][next], chunk, 1);
            if (reached != chunk) revert StoreInUse(tokenId, held);
        }
        return 0;
    }

    /// @dev Verifies at most `budget` chunks of `fileId` from `from` against store `storeId`.
    ///      The content store answers by its ranged presence check (its chunks are CREATE2 code
    ///      named by their hash). Any other store must return, for the manifest's chunk hash,
    ///      ABI-encoded bytes with that keccak256 and the length the layout rule requires; a
    ///      refusal or any other answer is a missing chunk, and running short of gas reverts.
    /// @return reached The first chunk not verified (missing, or past the budget).
    /// @return chunks The file's chunk count.
    function _verify(uint256 storeId, address source, bytes32 fileId, uint256 from, uint256 budget)
        private
        view
        returns (uint256 reached, uint256 chunks)
    {
        uint256 length;
        (, length, chunks,) = _fileInfo(fileId, false);
        uint256 to = chunks - from > budget ? from + budget : chunks;
        if (storeId == 0) {
            return (IContentStoreRange(source).firstMissing(fileId, from, to), chunks);
        }
        for (reached = from; reached < to; ++reached) {
            bytes32 hash = IContentStore(contentStore).chunkHash(fileId, reached);
            (bool ok, bytes memory data) = BoundedCall.tryReadAll(
                source, abi.encodeCall(IChunkSource.readChunk, (hash)), 0x40 + CHUNK + 1
            );
            uint256 expected = reached + 1 < chunks ? CHUNK : length - (chunks - 1) * CHUNK;
            assembly ("memory-safe") {
                // An answer `(offset 0x20, length, bytes)`, whose bytes hash to the chunk hash.
                // Padding is not inspected: the hash binds the bytes.
                ok := and(ok, gt(mload(data), 0x3f))
                if ok {
                    ok := and(
                        and(eq(mload(add(data, 0x20)), 0x20), eq(mload(add(data, 0x40)), expected)),
                        and(
                            iszero(lt(mload(data), add(0x40, expected))),
                            eq(keccak256(add(data, 0x60), expected), hash)
                        )
                    )
                }
            }
            if (!ok) return (reached, chunks);
        }
    }

    /// @dev Whether `data` is the canonical encoding of `(Location, uint256)` that may be
    ///      served: a URI of at most `Limits.MAX_URI_BYTES` with zero padding, empty exactly for
    ///      kinds NONE and ONCHAIN (whose index must be `NONE`), and ONCHAIN only when the work
    ///      is on-chain complete.
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
        return kind != KIND_ONCHAIN || onChain;
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
