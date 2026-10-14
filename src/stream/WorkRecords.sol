// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IContentStore } from "../interfaces/IContentStore.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IEntropyModule } from "../interfaces/IEntropyModule.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "../interfaces/types/ContentTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { ItemKind, License, PackageItem, SeedPolicy } from "../interfaces/types/PackageTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { SpdxId } from "./SpdxId.sol";

/// @title WorkRecords
/// @notice The records satellite of 6529 Stream: descriptive records, media, licenses, seeds,
///         the state hash, finalize, on-chain completeness, amendments, renderer repins,
///         locators and preferred location (ADR 0001 sections 8, 9 and 10; integrator decisions
///         D1, D2, D9, D10, D11, D19, D20, D24, E5, E6, E9 and E11).
/// @dev Nothing here is written at mint, so none of it costs the auction start: a work's record
///      opens with the permissionless `openRecord`, checked against the item hash the core
///      stored, and every per-token function reverts with `RecordNotOpen` until then. The
///      descriptive record is a content-store file; only its ID is stored. Media is stored as
///      one word per file (its file ID) plus one word of packed roles; each file's SHA-256 is the
///      content store's declaration, checked equal to the committed one at open. A license is
///      stored only when it is not the deployment's default CC0 license, and an ARTIST seed only
///      for ARTIST works.
///
///      Consents are EIP-712 signatures in this contract's domain (`Typehashes`), each by a
///      party's current authority and bound to the work's state hash. Every applied change bumps
///      the version, so a consent can never apply twice or to a state its signers did not see;
///      a governed action carrying consents is scheduled through AccessManager, so its deadline
///      must cover the delay. Royalty-rate changes are applied in the core (and a linked edition)
///      through their bound hooks, and every visible change asks the core to emit ERC-4906 and
///      tells 6529 Editions.
contract WorkRecords is AccessManaged, EIP712, ERC165, IWorkRecords {
    uint256 private constant NONE = type(uint256).max;
    bytes32 private constant STATE_DOMAIN = keccak256("6529WORKS_WORK_STATE_V1");
    /// @dev Locators per file the artist may add, and separately the platform (16 in all).
    uint256 private constant LOCATOR_QUOTA = Limits.MAX_LOCATORS_PER_FILE / 2;
    /// @dev The characters of an Arweave transaction ID (base64url: `A-Z a-z 0-9 - _`) and of a
    ///      base32 CID (`a-z 2-7`), as bit sets over ASCII.
    uint256 private constant TXID_CHARS = 0x07fffffe87fffffe03ff200000000000;
    uint256 private constant CID_CHARS = 0x07fffffe0000000000fc000000000000;
    /// @dev Chunks one `syncOnChain` call checks at most, in whole files. A chunk costs about
    ///      8,100 gas from cold storage, so a call stays near half of the EIP-7825 cap; one file
    ///      (at most `IContentStore.MAX_CHUNKS`, 512) always fits.
    uint256 private constant SYNC_CHUNKS = 1_024;

    /// @dev Word 0: the pin, version, media count, flags and how many leading media files
    ///      `syncOnChain` has found complete. `roles` packs each file's role in eight bits, file
    ///      `i` at bits `8i`.
    struct RecordData {
        address renderer;
        uint32 version;
        uint8 mediaCount;
        bool opened;
        bool finalized;
        bool onChainComplete;
        bool customLicense;
        uint8 syncedFiles;
        bytes32 recordFileId;
        bytes32 mediaHash;
        uint256 roles;
    }

    /// @dev How many of a file's locators the artist and the platform each added, and which
    ///      the artist added after finalize (bit `i` for locator `i`): those are held, served
    ///      only when the storage operator selects them.
    struct LocatorCounts {
        uint8 artist;
        uint8 platform;
        uint16 held;
    }

    /// @inheritdoc IWorkRecords
    address public immutable stream;
    /// @notice The artist registry resolving every party's current authority (the core's).
    address public immutable artistRegistry;
    /// @notice The VRF entropy module (the core's), or zero.
    address public immutable entropyModule;
    /// @notice The content store holding records, media and license texts (immutable).
    address public immutable contentStore;
    /// @notice The text file of the default CC0 license (immutable).
    bytes32 public immutable cc0TextFileId;

    /// @inheritdoc IWorkRecords
    LocatorKind public preferredKind;

    string private _cc0SpdxId;
    mapping(uint256 tokenId => RecordData) private _records;
    mapping(uint256 tokenId => bytes32[32]) private _media;
    mapping(uint256 tokenId => License) private _licenses;
    mapping(uint256 tokenId => bytes32) private _seeds;
    mapping(uint256 collectionId => LocatorKind) private _collectionKinds;
    mapping(uint256 tokenId => mapping(bytes32 fileId => Locator[])) private _locators;
    mapping(uint256 tokenId => mapping(bytes32 fileId => uint256 indexPlusOne)) private _filePrefs;
    mapping(uint256 tokenId => mapping(bytes32 fileId => LocatorCounts)) private _locatorCounts;
    mapping(uint256 tokenId => mapping(bytes32 fileId => mapping(bytes32 uriHash => bool))) private
        _locatorUris;

    /// @param authority_ The AccessManager governing this contract.
    /// @param stream_ The core token, which must bind this contract.
    /// @param contentStore_ The content store.
    /// @param cc0 The default license, which must be CC0 (`CC0-1.0` in any case), with its text
    ///        registered in the content store.
    constructor(address authority_, address stream_, address contentStore_, License memory cc0)
        AccessManaged(authority_)
        EIP712(Typehashes.WORK_RECORDS_NAME, Typehashes.DOMAIN_VERSION)
    {
        _requireContract(stream_);
        if (!ERC165Checker.supportsInterface(stream_, type(IStream).interfaceId)) {
            revert InvalidDependency(stream_);
        }
        _requireContract(contentStore_);
        if (
            !SpdxId.isValid(cc0.spdxId)
                || WorksHashing.licenseKey(cc0.spdxId) != WorksHashing.CC0_LICENSE_KEY
                || IContentStore(contentStore_).sha256Of(cc0.textFileId) == 0
        ) {
            revert InvalidLicense();
        }
        stream = stream_;
        artistRegistry = IStream(stream_).artistRegistry();
        entropyModule = IStream(stream_).entropyModule();
        contentStore = contentStore_;
        cc0TextFileId = cc0.textFileId;
        _cc0SpdxId = cc0.spdxId;
    }

    // --------------------------------------------------------------------------------- records

    /// @inheritdoc IWorkRecords
    /// @dev The approved record file and license are stored as they are, without the
    ///      structural record-file gate or a license-text check, so neither can freeze a
    ///      minted work: an invalid record renders core-only metadata until the artist sets a
    ///      valid one, and `finalize` enforces both. Trust obligation: the media commitments
    ///      checked here (1 to 32 files, the PRIMARY first and alone, its SHA-256 equal to
    ///      `item.contentHash`, every declaration matching the content store, every PREVIEW
    ///      file within `Limits.MAX_PREVIEW_BYTES`) are not checked at mint, so a
    ///      mis-committed item mints and can never open. The curation signer's tooling MUST
    ///      simulate `openRecord` for an item before attesting it.
    function openRecord(uint256 tokenId, PackageItem calldata item, MediaFile[] calldata media)
        external
    {
        RecordData storage r = _records[tokenId];
        if (r.opened) revert RecordAlreadyOpen(tokenId);
        uint256 files = media.length;
        if (
            WorksHashing.itemHashCalldata(item) != _itemHashOf(tokenId) || files == 0
                || files > Limits.MAX_MEDIA_FILES || WorksHashing.mediaHash(media) != item.mediaHash
                || media[0].sha256Hash != item.contentHash
        ) revert InvalidRecordData(tokenId);
        uint256 roles = 0;
        bytes32[32] storage list = _media[tokenId];
        IContentStore store = IContentStore(contentStore);
        for (uint256 i; i < files; ++i) {
            MediaFile calldata file = media[i];
            // Reverts with the store's `ContentFileUnknown` for an unregistered file.
            bytes32 declared = file.role == FileRole.PREVIEW
                ? _previewSha(tokenId, file.fileId)
                : store.sha256Of(file.fileId);
            if (declared != file.sha256Hash || (file.role == FileRole.PRIMARY) != (i == 0)) {
                revert InvalidRecordData(tokenId);
            }
            list[i] = file.fileId;
            roles |= uint256(file.role) << (8 * i);
        }
        r.opened = true;
        // At most `Limits.MAX_MEDIA_FILES` (32), checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.mediaCount = uint8(files);
        r.recordFileId = item.recordFileId;
        r.mediaHash = item.mediaHash;
        r.roles = roles;
        if (!_isDefaultLicense(item.license)) {
            r.customLicense = true;
            _licenses[tokenId] = item.license;
        }
        if (item.seedPolicy == SeedPolicy.ARTIST) _seeds[tokenId] = item.seed;
        emit RecordOpened(tokenId, item.recordFileId, item.mediaHash);
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    function setRecord(uint256 tokenId, bytes32 recordFileId, bytes32 expectedStateHash) external {
        RecordData storage r = _open(tokenId);
        if (r.finalized) revert WorkIsFinalized(tokenId);
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
    ///      on-chain, so a finalized work's license text is permanent (ADR 0001 section 8).
    function finalize(uint256 tokenId, bytes32 expectedStateHash) external {
        RecordData storage r = _open(tokenId);
        if (r.finalized) revert WorkIsFinalized(tokenId);
        _onlyArtist(tokenId);
        _checkState(tokenId, expectedStateHash);
        _checkRecordFile(r.recordFileId);
        _requireLicenseText(r.customLicense ? _licenses[tokenId].textFileId : cc0TextFileId, true);
        address renderer = IStream(stream).defaultRenderer();
        r.renderer = renderer;
        r.finalized = true;
        ++r.version;
        emit WorkFinalized(tokenId, renderer, workStateHash(tokenId));
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    /// @dev Media is fixed by approval (D2) and on-chain bytes are permanent, so a file found
    ///      complete stays complete: each call resumes at the first file not yet found complete,
    ///      checks whole files while their chunks fit `SYNC_CHUNKS`, and keeps its place. A
    ///      repeat after completion is a no-op.
    function syncOnChain(uint256 tokenId) external {
        RecordData storage r = _open(tokenId);
        if (r.onChainComplete) return;
        uint256 files = r.mediaCount;
        uint256 next = r.syncedFiles;
        uint256 budget = SYNC_CHUNKS;
        bytes32[32] storage list = _media[tokenId];
        for (; next < files; ++next) {
            bytes32 fileId = list[next];
            (,, uint256 chunks,) = _fileInfo(fileId);
            if (chunks > budget) break;
            if (!IContentStore(contentStore).isComplete(fileId)) {
                revert NotOnChainComplete(tokenId);
            }
            budget -= chunks;
        }
        // At most `Limits.MAX_MEDIA_FILES` (32).
        // forge-lint: disable-next-line(unsafe-typecast)
        r.syncedFiles = uint8(next);
        if (next < files) {
            emit OnChainSyncProgress(tokenId, next);
            return;
        }
        r.onChainComplete = true;
        emit WorkOnChainComplete(tokenId);
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    function isOpen(uint256 tokenId) external view returns (bool) {
        return _records[tokenId].opened;
    }

    /// @inheritdoc IWorkRecords
    function record(uint256 tokenId) external view returns (RecordInfo memory) {
        RecordData storage r = _open(tokenId);
        return RecordInfo(
            r.recordFileId,
            r.mediaHash,
            WorksHashing.licenseKey(licenseOf(tokenId).spdxId),
            r.version,
            r.finalized,
            r.onChainComplete,
            r.renderer
        );
    }

    /// @inheritdoc IWorkRecords
    /// @dev Each file's SHA-256 is read from the content store, which declared exactly the
    ///      committed value when the record opened (declarations never change).
    function mediaOf(uint256 tokenId) external view returns (MediaFile[] memory media) {
        RecordData storage r = _open(tokenId);
        media = new MediaFile[](r.mediaCount);
        bytes32[32] storage list = _media[tokenId];
        IContentStore store = IContentStore(contentStore);
        for (uint256 i; i < media.length; ++i) {
            bytes32 fileId = list[i];
            media[i] =
                MediaFile(fileId, store.sha256Of(fileId), FileRole(uint8(r.roles >> (8 * i))));
        }
    }

    /// @inheritdoc IWorkRecords
    function licenseOf(uint256 tokenId) public view returns (License memory) {
        if (_open(tokenId).customLicense) return _licenses[tokenId];
        return License(_cc0SpdxId, cc0TextFileId);
    }

    /// @inheritdoc IWorkRecords
    /// @dev `keccak256(abi.encode(domain, tokenId, version, recordFileId, licenseKey,
    ///      textFileId, royaltyRate, renderer))`, with the default renderer before finalize.
    function workStateHash(uint256 tokenId) public view returns (bytes32) {
        RecordData storage r = _open(tokenId);
        IStream core = IStream(stream);
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
                r.finalized ? r.renderer : core.defaultRenderer()
            )
        );
    }

    /// @inheritdoc IWorkRecords
    function pinnedRenderer(uint256 tokenId) external view returns (address) {
        return _open(tokenId).renderer;
    }

    /// @inheritdoc IWorkRecords
    function seedOf(uint256 tokenId) external view returns (SeedPolicy policy, bytes32 seed) {
        _open(tokenId);
        bytes32 itemHash;
        (itemHash,,,, policy,) = _core(tokenId);
        if (policy == SeedPolicy.ARTIST) {
            seed = _seeds[tokenId];
        } else if (policy == SeedPolicy.VRF) {
            seed = IEntropyModule(entropyModule).seedOf(itemHash);
        }
    }

    // ------------------------------------------------------------------------------ amendments

    /// @inheritdoc IWorkRecords
    /// @dev Only CC0 irrevocability is enforced on-chain, on the canonical key: a CC0 work may
    ///      only correct its text file, and only to the deployment's CC0 text (`cc0TextFileId`,
    ///      pinned by digest at deployment), which any relicense to CC0 names. Whether `next`
    ///      is more permissive than the current license is a judgement the artist's and every
    ///      party's consent plus the governed action carry; the contract does not order
    ///      licenses. A license with the current key and text is a no-op. The new text must be
    ///      registered, and complete on-chain once the work is finalized.
    function relicense(
        uint256 tokenId,
        License calldata next,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external restricted {
        RecordData storage r = _open(tokenId);
        License memory previous = licenseOf(tokenId);
        bytes32 nextKey = _relicenseKey(tokenId, previous, next);
        if (nextKey == 0) return;
        _requireLicenseText(next.textFileId, r.finalized);
        bytes32 structHash =
            _relicenseHash(tokenId, nextKey, next.textFileId, expectedStateHash, deadline);
        _checkConsents(tokenId, item, structHash, deadline, partySignatures);
        r.customLicense = !_isDefaultLicense(next);
        if (r.customLicense) _licenses[tokenId] = next;
        else delete _licenses[tokenId];
        ++r.version;
        emit LicenseChanged(tokenId, previous, next);
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    /// @dev An unchanged rate is a no-op. The version bumps before the external calls; the core
    ///      emits `RoyaltyRateChanged`, a linked edition's rate follows its master's, and this
    ///      contract emits `RoyaltyRateSet` and refreshes the metadata.
    function setRoyaltyRate(
        uint256 tokenId,
        uint32 rate,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external restricted {
        RecordData storage r = _open(tokenId);
        (,,,,, uint32 previous) = _core(tokenId);
        if (rate == previous) return;
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
    /// @dev Pinning the current renderer again is a no-op.
    function repinRenderer(
        uint256 tokenId,
        address renderer,
        bytes32 rendererCodeHash,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external restricted {
        RecordData storage r = _open(tokenId);
        if (!r.finalized) revert WorkNotFinalized(tokenId);
        address previous = r.renderer;
        if (renderer == previous) return;
        if (
            renderer.code.length == 0 || DelegatedEOA.isDelegated(renderer)
                || renderer.codehash != rendererCodeHash
                || !ERC165Checker.supportsInterface(renderer, type(IRenderer).interfaceId)
        ) revert InvalidRenderer(renderer);
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    Typehashes.RENDERER_REPIN,
                    tokenId,
                    renderer,
                    rendererCodeHash,
                    _checkState(tokenId, expectedStateHash),
                    deadline
                )
            )
        );
        // Deadlines are coarse (days); a validator's timestamp drift does not matter here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert InvalidConsent(tokenId, 0);
        if (!SignatureVerifier.isValid(_artistOf(tokenId), digest, artistSignature)) {
            revert InvalidConsent(tokenId, 0);
        }
        r.renderer = renderer;
        ++r.version;
        emit RendererRepinned(tokenId, previous, renderer, rendererCodeHash);
        _refresh(tokenId);
    }

    // ---------------------------------------------------------------------------- locators

    /// @inheritdoc IWorkRecords
    /// @dev The artist and the platform each have a quota of `MAX_LOCATORS_PER_FILE / 2` (8)
    ///      locators per file, so neither can exhaust the other's. A URI already registered for
    ///      the file is refused, compared as exact bytes; the set is shared, so whichever side
    ///      adds a URI first holds it (it is listed either way). A locator the artist adds after
    ///      finalize is held: listed, but served only when the storage operator selects it.
    function addLocator(uint256 tokenId, bytes32 fileId, Locator calldata locator) external {
        bool finalized = _open(tokenId).finalized;
        bool byArtist = _isArtist(tokenId, msg.sender);
        if (!byArtist) _checkCanCall(msg.sender, _msgData());
        _requireMedia(tokenId, fileId);
        _checkUri(locator);
        LocatorCounts storage counts = _locatorCounts[tokenId][fileId];
        mapping(bytes32 => bool) storage seen = _locatorUris[tokenId][fileId];
        bytes32 uriHash = keccak256(bytes(locator.uri));
        if ((byArtist ? counts.artist : counts.platform) >= LOCATOR_QUOTA || seen[uriHash]) {
            revert InvalidLocator();
        }
        seen[uriHash] = true;
        Locator[] storage list = _locators[tokenId][fileId];
        uint256 index = list.length;
        if (!byArtist) {
            ++counts.platform;
        } else {
            ++counts.artist;
            // At most 16 locators per file (the two quotas), so the bit fits in 16 bits.
            // forge-lint: disable-next-line(unsafe-typecast, incorrect-shift)
            if (finalized) counts.held |= uint16(1 << index);
        }
        list.push(locator);
        emit LocatorAdded(tokenId, fileId, index, locator);
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    function locators(uint256 tokenId, bytes32 fileId) external view returns (Locator[] memory) {
        _open(tokenId);
        return _locators[tokenId][fileId];
    }

    /// @inheritdoc IWorkRecords
    /// @dev Every locator is registered as a copy of that one file (ADR 0001 section 8); it is
    ///      not verified on-chain, so the storage operator chooses only among the copies
    ///      registered for the file. ONCHAIN matches on the work's stored
    ///      `onChainComplete` flag (`syncOnChain`), never on a content-store completeness scan,
    ///      which costs a read per chunk. A held locator (the artist's, added after finalize)
    ///      is skipped by the kinds and the fallback, so only the file preference serves it.
    ///      With no other locator, a synced work's file resolves to the implicit ONCHAIN copy;
    ///      otherwise the result is the empty locator (kind NONE, index `type(uint256).max`).
    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (Locator memory locator, uint256 index)
    {
        bool onChain = _open(tokenId).onChainComplete;
        _requireMedia(tokenId, fileId);
        Locator[] storage list = _locators[tokenId][fileId];
        uint256 held = _locatorCounts[tokenId][fileId].held;
        index = _filePrefs[tokenId][fileId];
        bool found = index != 0;
        if (found) index -= 1;
        if (!found) {
            (,, uint256 collectionId,,,) = _core(tokenId);
            (found, index) = _firstOfKind(list, held, onChain, _collectionKinds[collectionId]);
        }
        if (!found) (found, index) = _firstOfKind(list, held, onChain, preferredKind);
        for (uint256 i; !found && i < list.length; ++i) {
            if ((held >> i) & 1 == 0) (found, index) = (true, i);
        }
        if (!found && onChain) (found, index) = (true, NONE);
        if (!found) return (Locator(LocatorKind.NONE, ""), NONE);
        locator = index == NONE ? Locator(LocatorKind.ONCHAIN, "") : list[index];
    }

    /// @inheritdoc IWorkRecords
    function setPreferredKind(LocatorKind kind) external restricted {
        emit PreferredKindSet(preferredKind, kind);
        preferredKind = kind;
        _refreshAll();
    }

    /// @inheritdoc IWorkRecords
    function setCollectionPreferredKind(uint256 collectionId, LocatorKind kind)
        external
        restricted
    {
        // Collection IDs run from 1 to the count and are never removed.
        if (collectionId == 0 || collectionId > IStream(stream).collectionCount()) {
            revert IStream.UnknownCollection(collectionId);
        }
        emit CollectionPreferredKindSet(collectionId, _collectionKinds[collectionId], kind);
        _collectionKinds[collectionId] = kind;
        _refreshAll();
    }

    /// @inheritdoc IWorkRecords
    function setFilePreference(uint256 tokenId, bytes32 fileId, uint256 index) external restricted {
        _open(tokenId);
        _requireMedia(tokenId, fileId);
        if (index != NONE && index >= _locators[tokenId][fileId].length) revert InvalidLocator();
        emit FilePreferenceSet(tokenId, fileId, filePreference(tokenId, fileId), index);
        _filePrefs[tokenId][fileId] = index == NONE ? 0 : index + 1;
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    function collectionPreferredKind(uint256 collectionId) external view returns (LocatorKind) {
        return _collectionKinds[collectionId];
    }

    /// @inheritdoc IWorkRecords
    function filePreference(uint256 tokenId, bytes32 fileId) public view returns (uint256) {
        _open(tokenId);
        uint256 stored = _filePrefs[tokenId][fileId];
        return stored == 0 ? NONE : stored - 1;
    }

    /// @notice ERC-165: `IWorkRecords`, which 6529 Stream and 6529 Editions check when binding.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IWorkRecords).interfaceId || super.supportsInterface(interfaceId);
    }

    // -------------------------------------------------------------------------------- internal

    /// @dev The canonical key of `next`, or zero when it is the current license (a no-op).
    ///      Reverts when leaving CC0 (CC0 to CC0 with another text file is a correction), when
    ///      a CC0 license would name any text but the deployment's CC0 text, or for an invalid
    ///      identifier.
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

    function _open(uint256 tokenId) private view returns (RecordData storage r) {
        r = _records[tokenId];
        if (!r.opened) revert RecordNotOpen(tokenId);
    }

    function _checkState(uint256 tokenId, bytes32 expected) private view returns (bytes32 state) {
        state = workStateHash(tokenId);
        if (state != expected) revert StateHashMismatch(expected, state);
    }

    /// @dev The lead artist's current authority; reverts with the core's `UnknownWork` for a
    ///      burned token.
    function _artistOf(uint256 tokenId) private view returns (address) {
        return IArtistRegistry(artistRegistry).authorityOf(IStream(stream).artistOf(tokenId));
    }

    function _isArtist(uint256 tokenId, address account) private view returns (bool) {
        return _artistOf(tokenId) == account;
    }

    function _onlyArtist(uint256 tokenId) private view {
        if (!_isArtist(tokenId, msg.sender)) revert NotWorkArtist(tokenId, msg.sender);
    }

    /// @dev Every party of the work's item consents, in order, each by its current authority
    ///      (artist ID `artistIdOf(account)`, else `uint160(account)`). A wrong count or a passed
    ///      deadline reports the party index `signatures.length`.
    function _checkConsents(
        uint256 tokenId,
        PackageItem calldata item,
        bytes32 structHash,
        uint64 deadline,
        bytes[] calldata signatures
    ) private view {
        if (WorksHashing.itemHashCalldata(item) != _itemHashOf(tokenId)) {
            revert InvalidRecordData(tokenId);
        }
        uint256 parties = item.parties.length;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline || signatures.length != parties) {
            revert InvalidConsent(tokenId, signatures.length);
        }
        bytes32 digest = _hashTypedDataV4(structHash);
        IArtistRegistry registry = IArtistRegistry(artistRegistry);
        for (uint256 i; i < parties; ++i) {
            address account = item.parties[i].account;
            uint256 artistId = registry.artistIdOf(account);
            if (artistId == 0) artistId = uint256(uint160(account));
            if (!SignatureVerifier.isValid(registry.authorityOf(artistId), digest, signatures[i])) {
                revert InvalidConsent(tokenId, i);
            }
        }
    }

    function _isDefaultLicense(License memory license) private view returns (bool) {
        return license.textFileId == cc0TextFileId
            && keccak256(bytes(license.spdxId)) == keccak256(bytes(_cc0SpdxId));
    }

    /// @dev The core's per-work facts (`IStream.coreOf`); reverts with `UnknownWork` for a
    ///      burned or unminted token.
    function _core(uint256 tokenId)
        private
        view
        returns (
            bytes32 itemHash,
            uint256 artistId,
            uint256 collectionId,
            ItemKind kind,
            SeedPolicy policy,
            uint32 rate
        )
    {
        (itemHash, artistId, collectionId, kind, policy, rate) = IStream(stream).coreOf(tokenId);
    }

    /// @dev The work's linked edition (`IStream.editionOf`), or zero.
    function _edition(uint256 tokenId) private view returns (address editions, uint256 editionId) {
        (editions, editionId) = IStream(stream).editionOf(tokenId);
    }

    function _itemHashOf(uint256 tokenId) private view returns (bytes32 itemHash) {
        (itemHash,,,,,) = _core(tokenId);
    }

    function _royaltyRateOf(uint256 tokenId) private view returns (uint32 rate) {
        (,,,,, rate) = _core(tokenId);
    }

    /// @dev A license's text must be a registered content-store file, and complete on-chain
    ///      when `stored`. An unknown file reverts with the store's `ContentFileUnknown`; a
    ///      registered one has a nonzero SHA-256.
    function _requireLicenseText(bytes32 textFileId, bool stored) private view {
        IContentStore store = IContentStore(contentStore);
        if (stored ? !store.isComplete(textFileId) : store.sha256Of(textFileId) == 0) {
            revert InvalidLicense();
        }
    }

    /// @dev Applies a consented rate in the core and a linked edition, then reports it.
    function _applyRate(uint256 tokenId, uint32 previous, uint32 rate) private {
        IStream(stream).setRoyaltyRate(tokenId, rate);
        (address editions, uint256 editionId) = _edition(tokenId);
        if (editions != address(0)) IEditions(editions).setRoyaltyRate(editionId, rate);
        emit RoyaltyRateSet(tokenId, previous, rate, workStateHash(tokenId));
        _refresh(tokenId);
    }

    /// @dev The record file's structural bounds: registered, at most `Limits.MAX_RECORD_BYTES`
    ///      (at most one chunk, so the store's layout rule makes it exactly one), `Identity`
    ///      encoding, and complete (that one chunk stored). Each check is O(1). The JSON itself
    ///      is not parsed here: the renderer validates it and falls back to core-only metadata
    ///      for an invalid record. Only the store's `ContentFileUnknown` reads as unregistered;
    ///      any other store failure propagates.
    function _checkRecordFile(bytes32 fileId) private view {
        (bool ok, bytes memory info) =
            contentStore.staticcall(abi.encodeCall(IContentStore.fileInfo, (fileId)));
        if (!ok) {
            // Only the selector is compared, so truncating to four bytes is intended.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (info.length >= 4 && bytes4(info) == IContentStore.ContentFileUnknown.selector) {
                revert UnknownRecordFile(fileId);
            }
            assembly ("memory-safe") {
                revert(add(info, 0x20), mload(info))
            }
        }
        // `FileInfo` comes back as one dynamic tuple: offset, sha256Hash, length, chunkCount,
        // encoding, then the MIME type. The trusted store's fields are read in place.
        uint256 length;
        uint256 encoding;
        if (info.length < 0xc0) revert UnknownRecordFile(fileId);
        assembly ("memory-safe") {
            length := mload(add(info, 0x60))
            encoding := mload(add(info, 0xa0))
        }
        if (
            length > Limits.MAX_RECORD_BYTES || encoding != uint256(IContentStore.Encoding.Identity)
                || !IContentStore(contentStore).isComplete(fileId)
        ) revert UnknownRecordFile(fileId);
    }

    /// @dev The declared SHA-256 of a PREVIEW file of work `tokenId`, which must be within
    ///      `Limits.MAX_PREVIEW_BYTES`, an `Identity` file counting four times.
    function _previewSha(uint256 tokenId, bytes32 fileId) private view returns (bytes32 sha) {
        uint256 length;
        uint256 encoding;
        (sha, length,, encoding) = _fileInfo(fileId);
        if (encoding == uint256(IContentStore.Encoding.Identity)) length *= 4;
        if (length > Limits.MAX_PREVIEW_BYTES) revert InvalidRecordData(tokenId);
    }

    /// @dev A media file's declared SHA-256, stored length, chunk count and encoding, read in
    ///      place from the trusted store's `fileInfo` answer as in `_checkRecordFile`. A store
    ///      revert (`ContentFileUnknown` for an unregistered file) propagates.
    function _fileInfo(bytes32 fileId)
        private
        view
        returns (bytes32 sha, uint256 length, uint256 chunks, uint256 encoding)
    {
        (bool ok, bytes memory info) =
            contentStore.staticcall(abi.encodeCall(IContentStore.fileInfo, (fileId)));
        assembly ("memory-safe") {
            if or(iszero(ok), lt(mload(info), 0xc0)) { revert(add(info, 0x20), mload(info)) }
            sha := mload(add(info, 0x40))
            length := mload(add(info, 0x60))
            chunks := mload(add(info, 0x80))
            encoding := mload(add(info, 0xa0))
        }
    }

    function _requireMedia(uint256 tokenId, bytes32 fileId) private view {
        bytes32[32] storage list = _media[tokenId];
        uint256 files = _records[tokenId].mediaCount;
        for (uint256 i; i < files; ++i) {
            if (list[i] == fileId) return;
        }
        revert FileNotInWork(tokenId, fileId);
    }

    /// @dev A locator URI is a content address, so what it names cannot change (D11, ADR 0003
    ///      "Locator kinds"), with nothing after it (no path, query or fragment):
    ///      - ARWEAVE: `ar://` and a 43-character transaction ID in base64url. An ArNS name,
    ///        which its owner can repoint, is never 43 characters long.
    ///      - IPFS: `ipfs://` and a CIDv1 of the fixed profile (ADR 0001 section 8): base32
    ///        (`b`), sha2-256, a raw leaf or a dag-pb root (`bafkrei` or `bafybei`), 59
    ///        characters in all.
    function _checkUri(Locator calldata locator) private pure {
        bytes calldata uri = bytes(locator.uri);
        uint256 chars = 0;
        uint256 start = 0;
        if (locator.kind == LocatorKind.ARWEAVE) {
            if (uri.length == 48 && bytes5(uri[:5]) == "ar://") (chars, start) = (TXID_CHARS, 5);
        } else if (locator.kind == LocatorKind.IPFS && uri.length == 66) {
            bytes14 head = bytes14(uri[:14]);
            if (head == "ipfs://bafkrei" || head == "ipfs://bafybei") {
                (chars, start) = (CID_CHARS, 14);
            }
        }
        if (chars == 0) revert InvalidLocator();
        for (uint256 i = start; i < uri.length; ++i) {
            if ((chars >> uint8(uri[i])) & 1 == 0) revert InvalidLocator();
        }
    }

    /// @dev The first locator of `kind` that is not held, or the implicit ONCHAIN one (`NONE`)
    ///      when the work is on-chain complete. NONE as a kind never matches.
    function _firstOfKind(Locator[] storage list, uint256 held, bool onChain, LocatorKind kind)
        private
        view
        returns (bool, uint256)
    {
        if (kind == LocatorKind.NONE) return (false, 0);
        if (kind == LocatorKind.ONCHAIN) return (onChain, NONE);
        for (uint256 i; i < list.length; ++i) {
            if ((held >> i) & 1 == 0 && list[i].kind == kind) return (true, i);
        }
        return (false, 0);
    }

    /// @dev ERC-4906 through the core, and a linked edition master's edition through 6529
    ///      Editions.
    function _refresh(uint256 tokenId) private {
        IStream(stream).emitMetadataUpdate(tokenId, tokenId);
        (address editions,) = _edition(tokenId);
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

    function _requireContract(address dependency) private view {
        if (dependency.code.length == 0 || DelegatedEOA.isDelegated(dependency)) {
            revert InvalidDependency(dependency);
        }
    }
}
