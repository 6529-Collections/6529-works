// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IContentStore } from "../interfaces/IContentStore.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "../interfaces/types/ContentTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { License, PackageItem } from "../interfaces/types/PackageTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";

/// @title WorkRecords
/// @notice The records satellite of 6529 Stream: descriptive records, media, licenses, the state
///         hash, finalize, on-chain completeness, amendments, renderer repins, locators and
///         preferred location (ADR 0001 sections 8 and 10; integrator decisions D1, D2, D9, D10,
///         D11, D19, D20 and D24).
/// @dev Nothing here is written at mint, so none of it costs the auction start: a work's record
///      opens with the permissionless `openRecord`, checked against the item hash the core
///      stored. The descriptive record is a content-store file; only its ID is stored. Media is
///      stored as one word per file (its file ID) plus one word of packed roles; each file's
///      SHA-256 is the content store's declaration, checked equal to the committed one at open.
///      A license is stored only when it is not the deployment's default CC0 license.
///
///      Consents are EIP-712 signatures in this contract's domain (`Typehashes`), each by a
///      party's current authority and bound to the work's state hash. Every applied change bumps
///      the version, so a consent can never apply twice or to a state its signers did not see;
///      a governed action carrying consents is scheduled through AccessManager, so its deadline
///      must cover the delay. Royalty-rate changes are applied in the core through its bound
///      hook, and every visible change asks the core to emit ERC-4906 and, for a linked edition
///      master, tells 6529 Editions.
contract WorkRecords is AccessManaged, EIP712, IWorkRecords {
    uint256 private constant NONE = type(uint256).max;
    bytes32 private constant STATE_DOMAIN = keccak256("6529WORKS_WORK_STATE_V1");

    /// @notice A dependency lacks code or the required ERC-165 support, or is an EIP-7702
    ///         delegated account.
    error InvalidDependency(address dependency);
    /// @notice The license identifier is empty or longer than `Limits.MAX_LICENSE_ID_BYTES`, or
    ///         the deployment's default license is not CC0.
    error InvalidLicense();
    /// @notice Only a finalized work has a renderer pin to replace.
    error WorkNotFinalized(uint256 tokenId);
    /// @notice The renderer is not a contract supporting `IRenderer`.
    error InvalidRenderer(address renderer);
    /// @notice The file has no registered locator and is not on-chain complete.
    error NoLocator(uint256 tokenId, bytes32 fileId);

    /// @dev Word 0: the pin, version, media count and flags. `roles` packs each file's role in
    ///      eight bits, file `i` at bits `8i`.
    struct RecordData {
        address renderer;
        uint32 version;
        uint8 mediaCount;
        bool opened;
        bool finalized;
        bool onChainComplete;
        bool customLicense;
        bytes32 recordFileId;
        bytes32 mediaHash;
        uint256 roles;
    }

    /// @inheritdoc IWorkRecords
    address public immutable stream;
    /// @notice The artist registry resolving every party's current authority (the core's).
    address public immutable artistRegistry;
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
    mapping(uint256 collectionId => LocatorKind) private _collectionKinds;
    mapping(uint256 tokenId => mapping(bytes32 fileId => Locator[])) private _locators;
    mapping(uint256 tokenId => mapping(bytes32 fileId => uint256 indexPlusOne)) private _filePrefs;

    /// @param authority_ The AccessManager governing this contract.
    /// @param stream_ The core token, which must bind this contract.
    /// @param contentStore_ The content store.
    /// @param cc0 The default license, which must be CC0 (`WorksHashing.CC0_LICENSE_KEY`).
    constructor(address authority_, address stream_, address contentStore_, License memory cc0)
        AccessManaged(authority_)
        EIP712(Typehashes.WORK_RECORDS_NAME, Typehashes.DOMAIN_VERSION)
    {
        _requireContract(stream_);
        if (!ERC165Checker.supportsInterface(stream_, type(IStream).interfaceId)) {
            revert InvalidDependency(stream_);
        }
        _requireContract(contentStore_);
        if (WorksHashing.licenseKey(cc0.spdxId) != WorksHashing.CC0_LICENSE_KEY) {
            revert InvalidLicense();
        }
        stream = stream_;
        artistRegistry = IStream(stream_).artistRegistry();
        contentStore = contentStore_;
        cc0TextFileId = cc0.textFileId;
        _cc0SpdxId = cc0.spdxId;
    }

    // --------------------------------------------------------------------------------- records

    /// @inheritdoc IWorkRecords
    function openRecord(uint256 tokenId, PackageItem calldata item, MediaFile[] calldata media)
        external
    {
        RecordData storage r = _records[tokenId];
        if (r.opened) revert RecordAlreadyOpen(tokenId);
        uint256 files = media.length;
        uint256 spdx = bytes(item.license.spdxId).length;
        if (
            WorksHashing.itemHashCalldata(item) != IStream(stream).work(tokenId).itemHash
                || files == 0 || files > Limits.MAX_MEDIA_FILES
                || WorksHashing.mediaHash(media) != item.mediaHash
                || media[0].sha256Hash != item.contentHash || spdx == 0
                || spdx > Limits.MAX_LICENSE_ID_BYTES
        ) revert InvalidRecordData(tokenId);
        _requireRecordFile(item.recordFileId);
        uint256 roles;
        bytes32[32] storage list = _media[tokenId];
        for (uint256 i; i < files; ++i) {
            MediaFile calldata file = media[i];
            (bool known, bytes32 declared) = _sha256Of(file.fileId);
            if (
                !known || declared != file.sha256Hash || (file.role == FileRole.PRIMARY) != (i == 0)
            ) revert InvalidRecordData(tokenId);
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
        _requireRecordFile(recordFileId);
        r.recordFileId = recordFileId;
        ++r.version;
        emit RecordSet(tokenId, recordFileId, workStateHash(tokenId));
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    function finalize(uint256 tokenId, bytes32 expectedStateHash) external {
        RecordData storage r = _open(tokenId);
        if (r.finalized) revert WorkIsFinalized(tokenId);
        _onlyArtist(tokenId);
        _checkState(tokenId, expectedStateHash);
        address renderer = IStream(stream).defaultRenderer();
        r.renderer = renderer;
        r.finalized = true;
        ++r.version;
        emit WorkFinalized(tokenId, renderer, workStateHash(tokenId));
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    /// @dev Media is fixed by approval (D2), so completeness is permanent; a repeat is a no-op.
    function syncOnChain(uint256 tokenId) external {
        RecordData storage r = _open(tokenId);
        if (r.onChainComplete) return;
        bytes32[32] storage list = _media[tokenId];
        for (uint256 i; i < r.mediaCount; ++i) {
            if (!IContentStore(contentStore).isComplete(list[i])) {
                revert NotOnChainComplete(tokenId);
            }
        }
        r.onChainComplete = true;
        emit WorkOnChainComplete(tokenId);
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    function record(uint256 tokenId) external view returns (RecordInfo memory) {
        RecordData storage r = _open(tokenId);
        return RecordInfo(
            r.recordFileId,
            r.mediaHash,
            WorksHashing.licenseKey(licenseOf(tokenId).spdxId),
            r.version,
            true,
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
        for (uint256 i; i < media.length; ++i) {
            bytes32 fileId = list[i];
            (, bytes32 sha) = _sha256Of(fileId);
            media[i] = MediaFile(fileId, sha, FileRole(uint8(r.roles >> (8 * i))));
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
                core.work(tokenId).royaltyRate,
                r.finalized ? r.renderer : core.defaultRenderer()
            )
        );
    }

    /// @inheritdoc IWorkRecords
    function pinnedRenderer(uint256 tokenId) external view returns (address) {
        return _records[tokenId].renderer;
    }

    // ------------------------------------------------------------------------------ amendments

    /// @inheritdoc IWorkRecords
    /// @dev Whether `next` is more permissive is not decidable on-chain; every party's consent
    ///      and the governed action carry that judgement, and CC0 can never be left. A license
    ///      with the current key and text is a no-op.
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
    /// @dev An unchanged rate is a no-op. The core emits `RoyaltyRateChanged`.
    function setRoyaltyRate(
        uint256 tokenId,
        uint32 rate,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external restricted {
        RecordData storage r = _open(tokenId);
        if (rate == IStream(stream).work(tokenId).royaltyRate) return;
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
        IStream(stream).setRoyaltyRate(tokenId, rate);
        ++r.version;
    }

    /// @inheritdoc IWorkRecords
    /// @dev Pinning the current renderer again is a no-op.
    function repinRenderer(
        uint256 tokenId,
        address renderer,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external restricted {
        RecordData storage r = _open(tokenId);
        if (!r.finalized) revert WorkNotFinalized(tokenId);
        address previous = r.renderer;
        if (renderer == previous) return;
        if (
            DelegatedEOA.isDelegated(renderer)
                || !ERC165Checker.supportsInterface(renderer, type(IRenderer).interfaceId)
        ) revert InvalidRenderer(renderer);
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    Typehashes.RENDERER_REPIN,
                    tokenId,
                    renderer,
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
        emit RendererRepinned(tokenId, previous, renderer);
        _refresh(tokenId);
    }

    // ---------------------------------------------------------------------------- locators

    /// @inheritdoc IWorkRecords
    function addLocator(uint256 tokenId, bytes32 fileId, Locator calldata locator) external {
        _open(tokenId);
        if (!_isArtist(tokenId, msg.sender)) _checkCanCall(msg.sender, _msgData());
        _requireMedia(tokenId, fileId);
        _checkUri(locator);
        Locator[] storage list = _locators[tokenId][fileId];
        uint256 index = list.length;
        if (index >= Limits.MAX_LOCATORS_PER_FILE) revert InvalidLocator();
        list.push(locator);
        emit LocatorAdded(tokenId, fileId, index, locator);
        _refresh(tokenId);
    }

    /// @inheritdoc IWorkRecords
    function locators(uint256 tokenId, bytes32 fileId) external view returns (Locator[] memory) {
        return _locators[tokenId][fileId];
    }

    /// @inheritdoc IWorkRecords
    /// @dev Every locator of a file is a copy of that one file, so any choice among them is
    ///      hash-equal (ADR 0001 section 8). With no registered locator, a complete file resolves
    ///      to the implicit ONCHAIN copy; otherwise this reverts with `NoLocator`.
    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (Locator memory locator, uint256 index)
    {
        _open(tokenId);
        _requireMedia(tokenId, fileId);
        Locator[] storage list = _locators[tokenId][fileId];
        index = _filePrefs[tokenId][fileId];
        bool found = index != 0;
        if (found) index -= 1;
        if (!found) {
            uint256 collectionId = IStream(stream).work(tokenId).collectionId;
            (found, index) = _firstOfKind(list, fileId, _collectionKinds[collectionId]);
        }
        if (!found) (found, index) = _firstOfKind(list, fileId, preferredKind);
        if (!found && list.length != 0) (found, index) = (true, 0);
        if (!found && IContentStore(contentStore).isComplete(fileId)) {
            (found, index) = (true, NONE);
        }
        if (!found) revert NoLocator(tokenId, fileId);
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
        IStream(stream).collection(collectionId); // reverts with `UnknownCollection`
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
        uint256 stored = _filePrefs[tokenId][fileId];
        return stored == 0 ? NONE : stored - 1;
    }

    // -------------------------------------------------------------------------------- internal

    /// @dev The canonical key of `next`, or zero when it is the current license (a no-op).
    ///      Reverts when leaving CC0 or for an invalid identifier.
    function _relicenseKey(uint256 tokenId, License memory previous, License calldata next)
        private
        pure
        returns (bytes32 nextKey)
    {
        bytes32 previousKey = WorksHashing.licenseKey(previous.spdxId);
        nextKey = WorksHashing.licenseKey(next.spdxId);
        if (nextKey == previousKey && next.textFileId == previous.textFileId) return 0;
        if (previousKey == WorksHashing.CC0_LICENSE_KEY) revert LicenseIrrevocable(tokenId);
        uint256 spdx = bytes(next.spdxId).length;
        if (spdx == 0 || spdx > Limits.MAX_LICENSE_ID_BYTES) revert InvalidLicense();
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
        if (WorksHashing.itemHashCalldata(item) != IStream(stream).work(tokenId).itemHash) {
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

    /// @dev The content store's declared SHA-256 of `fileId`, or `known = false` for an
    ///      unregistered file (the store reverts).
    function _sha256Of(bytes32 fileId) private view returns (bool known, bytes32 sha) {
        try IContentStore(contentStore).sha256Of(fileId) returns (bytes32 declared) {
            return (true, declared);
        } catch {
            return (false, 0);
        }
    }

    function _requireRecordFile(bytes32 fileId) private view {
        (bool known,) = _sha256Of(fileId);
        if (!known) revert UnknownRecordFile(fileId);
    }

    function _requireMedia(uint256 tokenId, bytes32 fileId) private view {
        bytes32[32] storage list = _media[tokenId];
        uint256 files = _records[tokenId].mediaCount;
        for (uint256 i; i < files; ++i) {
            if (list[i] == fileId) return;
        }
        revert FileNotInWork(tokenId, fileId);
    }

    /// @dev Locator URIs are printable ASCII without quotes, backslashes or angle brackets,
    ///      after the kind's scheme: `ar://` or `ipfs://` (D11).
    function _checkUri(Locator calldata locator) private pure {
        bytes calldata uri = bytes(locator.uri);
        uint256 start;
        if (locator.kind == LocatorKind.ARWEAVE) start = _scheme(uri, "ar://");
        else if (locator.kind == LocatorKind.IPFS) start = _scheme(uri, "ipfs://");
        if (start == 0 || uri.length == start || uri.length > Limits.MAX_URI_BYTES) {
            revert InvalidLocator();
        }
        for (uint256 i = start; i < uri.length; ++i) {
            bytes1 c = uri[i];
            if (c < 0x21 || c > 0x7e || c == '"' || c == "\\" || c == "<" || c == ">") {
                revert InvalidLocator();
            }
        }
    }

    /// @dev The scheme's length if `uri` starts with it, else zero.
    function _scheme(bytes calldata uri, bytes memory scheme) private pure returns (uint256) {
        uint256 n = scheme.length;
        if (uri.length < n || keccak256(uri[:n]) != keccak256(scheme)) return 0;
        return n;
    }

    /// @dev The first locator of `kind`, or the implicit ONCHAIN one (`NONE`) when the file is
    ///      complete. NONE as a kind never matches.
    function _firstOfKind(Locator[] storage list, bytes32 fileId, LocatorKind kind)
        private
        view
        returns (bool, uint256)
    {
        if (kind == LocatorKind.NONE) return (false, 0);
        if (kind == LocatorKind.ONCHAIN) {
            return (IContentStore(contentStore).isComplete(fileId), NONE);
        }
        for (uint256 i; i < list.length; ++i) {
            if (list[i].kind == kind) return (true, i);
        }
        return (false, 0);
    }

    /// @dev ERC-4906 through the core, and a linked edition master's edition through 6529
    ///      Editions.
    function _refresh(uint256 tokenId) private {
        IStream core = IStream(stream);
        core.emitMetadataUpdate(tokenId, tokenId);
        (address editions,) = core.editionOf(tokenId);
        if (editions != address(0)) IEditions(editions).notifyMasterUpdated(tokenId);
    }

    /// @dev ERC-4906 for every token ever minted (burned IDs included, harmlessly).
    function _refreshAll() private {
        uint256 minted = IStream(stream).totalMinted();
        if (minted != 0) IStream(stream).emitMetadataUpdate(1, minted);
    }

    function _requireContract(address dependency) private view {
        if (dependency.code.length == 0 || DelegatedEOA.isDelegated(dependency)) {
            revert InvalidDependency(dependency);
        }
    }
}
