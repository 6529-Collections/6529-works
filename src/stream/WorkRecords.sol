// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IContentStore } from "../interfaces/IContentStore.sol";
import { IEntropyModule } from "../interfaces/IEntropyModule.sol";
import { IRenderer } from "../interfaces/IRenderer.sol";
import { Locator, LocatorKind } from "../interfaces/types/ContentTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { License, PackageItem, Party, SeedPolicy } from "../interfaces/types/PackageTypes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { IStreamCore } from "./IStreamCore.sol";
import { IWorkRecords } from "./IWorkRecords.sol";

/// @title WorkRecords
/// @notice The records satellite of 6529 Stream: descriptive records, the state hash, finalize,
///         on-chain completeness, license and royalty amendments, renderer repins, locators and
///         preferred location (ADR 0001 sections 8 and 10; integrator decisions D1, D2, D9, D10,
///         D11, D19, D20 and D24).
/// @dev Nothing here is written at mint, so none of it costs the auction start. A work's records
///      open with `register`, checked against the item hash the core stored. License and royalty
///      changes are applied through the core's records hooks (this contract is bound there once),
///      and every metadata change asks the core to emit the ERC-4906 event marketplaces index.
///
///      Consents are EIP-712 signatures in this contract's domain by each party's current
///      authority in the artist registry, bound to the work's state hash: every applied change
///      bumps the version, so a consent can never apply twice or to a state its signer did not
///      see. A governed action carrying the consents is scheduled through AccessManager; its
///      deadline must cover the delay.
contract WorkRecords is AccessManaged, EIP712, IWorkRecords {
    uint256 private constant NONE = type(uint256).max;
    bytes32 private constant STATE_DOMAIN = keccak256("6529WORKS_WORK_STATE_V1");
    bytes32 private constant JSON_MIME = keccak256("application/json");

    /// @notice EIP-712 type of a license inside an amendment.
    bytes32 public constant LICENSE_TYPEHASH =
        keccak256("License(string spdxId,bytes32 textFileId)");
    /// @notice EIP-712 type of a relicensing consent.
    bytes32 public constant RELICENSE_TYPEHASH = keccak256(
        "Relicense(uint256 tokenId,License next,bytes32 stateHash,uint64 deadline)License(string spdxId,bytes32 textFileId)"
    );
    /// @notice EIP-712 type of a royalty-rate consent.
    bytes32 public constant ROYALTY_TYPEHASH =
        keccak256("RoyaltyChange(uint256 tokenId,uint32 rate,bytes32 stateHash,uint64 deadline)");
    /// @notice EIP-712 type of the lead artist's errata consent.
    bytes32 public constant REPIN_TYPEHASH = keccak256(
        "RendererRepin(uint256 tokenId,address renderer,bytes32 stateHash,uint64 deadline)"
    );

    /// @dev Word 0 holds the flags and the pin; the parties hash binds consents to the item.
    struct WorkData {
        address renderer;
        uint32 version;
        uint8 mediaCount;
        SeedPolicy seedPolicy;
        bool registered;
        bool finalized;
        bool onChainComplete;
        bytes32 record;
        bytes32 partiesHash;
        bytes32 seed;
    }

    /// @inheritdoc IWorkRecords
    address public immutable stream;
    /// @notice The artist registry resolving every party's current authority (the core's).
    address public immutable artistRegistry;
    /// @notice The content store holding records and media (immutable).
    address public immutable contentStore;
    /// @notice The optional VRF entropy module, or zero (immutable).
    address public immutable entropyModule;

    /// @inheritdoc IWorkRecords
    LocatorKind public preferredKind;

    mapping(uint256 tokenId => WorkData) private _works;
    mapping(uint256 tokenId => bytes32[]) private _media;
    mapping(uint256 collectionId => LocatorKind) private _collectionKinds;
    mapping(uint256 tokenId => mapping(bytes32 fileId => Locator[])) private _locators;
    mapping(uint256 tokenId => mapping(bytes32 fileId => uint256 indexPlusOne)) private _filePrefs;

    /// @param authority_ The AccessManager governing this contract.
    /// @param stream_ The core token, which must bind this contract with `bindRecords`.
    /// @param contentStore_ The content store.
    /// @param entropyModule_ The optional VRF module, or zero.
    constructor(address authority_, address stream_, address contentStore_, address entropyModule_)
        AccessManaged(authority_)
        EIP712("6529 Stream Records", "1")
    {
        _requireContract(stream_);
        _requireContract(contentStore_);
        if (entropyModule_ != address(0)) _requireContract(entropyModule_);
        stream = stream_;
        artistRegistry = IStreamCore(stream_).artistRegistry();
        contentStore = contentStore_;
        entropyModule = entropyModule_;
    }

    // ---------------------------------------------------------------------------- registration

    /// @inheritdoc IWorkRecords
    /// @dev Permissionless for a single-file work, whose media list the item's `contentId` fixes.
    ///      TODO(D2): once `PackageItem` commits the hash of the whole media list, check it here
    ///      and drop the interim rule that only the lead artist or PLATFORM may register a
    ///      multi-file list.
    function register(uint256 tokenId, PackageItem calldata item, bytes32[] calldata media_)
        external
    {
        IERC721(stream).ownerOf(tokenId);
        WorkData storage d = _works[tokenId];
        if (d.registered) revert AlreadyRegistered(tokenId);
        if (WorksHashing.itemHash(item) != IStreamCore(stream).itemHashOf(tokenId)) {
            revert ItemMismatch(tokenId);
        }
        if (media_.length > 1 && !_isArtist(tokenId, msg.sender)) {
            _checkCanCall(msg.sender, _msgData());
        }
        _checkMedia(item.contentId, media_);
        _checkRecordFile(item.metadataHash);
        d.registered = true;
        d.record = item.metadataHash;
        d.partiesHash = keccak256(abi.encode(item.parties));
        d.seedPolicy = item.seedPolicy;
        // At most `Limits.MAX_MEDIA_FILES` (32), checked in `_checkMedia`.
        // forge-lint: disable-next-line(unsafe-typecast)
        d.mediaCount = uint8(media_.length);
        if (item.seedPolicy == SeedPolicy.ARTIST) d.seed = item.seed;
        bytes32[] storage list = _media[tokenId];
        for (uint256 i; i < media_.length; ++i) {
            list.push(media_[i]);
        }
        emit WorkRegistered(tokenId, item.metadataHash, media_);
        IStreamCore(stream).refreshMetadata(tokenId, tokenId);
    }

    // --------------------------------------------------------------------------------- records

    /// @inheritdoc IWorkRecords
    function setRecord(uint256 tokenId, bytes32 record, bytes32 expectedStateHash) external {
        WorkData storage d = _registered(tokenId);
        if (d.finalized) revert WorkIsFinalized(tokenId);
        _onlyArtist(tokenId);
        if (record == d.record) return;
        _checkState(tokenId, expectedStateHash);
        _checkRecordFile(record);
        bytes32 previous = d.record;
        d.record = record;
        ++d.version;
        emit RecordSet(tokenId, previous, record, workStateHash(tokenId));
        IStreamCore(stream).refreshMetadata(tokenId, tokenId);
    }

    /// @inheritdoc IWorkRecords
    function finalize(uint256 tokenId, bytes32 expectedStateHash) external {
        WorkData storage d = _registered(tokenId);
        if (d.finalized) revert WorkIsFinalized(tokenId);
        _onlyArtist(tokenId);
        _checkState(tokenId, expectedStateHash);
        address renderer = IStreamCore(stream).defaultRenderer();
        d.renderer = renderer;
        d.finalized = true;
        ++d.version;
        emit WorkFinalized(tokenId, renderer, workStateHash(tokenId));
        IStreamCore(stream).refreshMetadata(tokenId, tokenId);
    }

    /// @inheritdoc IWorkRecords
    /// @dev Media is fixed by approval (D2), so completeness is permanent once reached.
    function syncOnChain(uint256 tokenId) external {
        WorkData storage d = _registered(tokenId);
        if (d.onChainComplete) return;
        bytes32[] storage list = _media[tokenId];
        for (uint256 i; i < list.length; ++i) {
            if (!IContentStore(contentStore).isComplete(list[i])) {
                revert NotOnChainComplete(tokenId);
            }
        }
        d.onChainComplete = true;
        emit WorkOnChainComplete(tokenId);
        IStreamCore(stream).refreshMetadata(tokenId, tokenId);
    }

    // ------------------------------------------------------------------------------ amendments

    /// @inheritdoc IWorkRecords
    /// @dev The core rejects any change away from CC0 (irrevocable). Whether `next` is more
    ///      permissive is not decidable on-chain; every party's consent plus the governed action
    ///      carry that judgement. An identical license is a no-op.
    function relicense(
        uint256 tokenId,
        Party[] calldata parties,
        License calldata next,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata signatures
    ) external restricted {
        WorkData storage d = _registered(tokenId);
        if (
            keccak256(abi.encode(next))
                == keccak256(abi.encode(IStreamCore(stream).licenseOf(tokenId)))
        ) {
            return;
        }
        bytes32 structHash =
            _relicenseHash(tokenId, next, _checkState(tokenId, expectedStateHash), deadline);
        _checkConsents(tokenId, d, parties, structHash, deadline, signatures);
        IStreamCore(stream).setLicense(tokenId, next);
        ++d.version;
        emit WorkAmended(tokenId, msg.sig, workStateHash(tokenId));
    }

    /// @inheritdoc IWorkRecords
    /// @dev An identical rate is a no-op.
    function setRoyaltyRate(
        uint256 tokenId,
        Party[] calldata parties,
        uint32 rate,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata signatures
    ) external restricted {
        WorkData storage d = _registered(tokenId);
        (, uint32 current) = IStreamCore(stream).royaltyOf(tokenId);
        if (rate == current) return;
        bytes32 structHash = keccak256(
            abi.encode(
                ROYALTY_TYPEHASH, tokenId, rate, _checkState(tokenId, expectedStateHash), deadline
            )
        );
        _checkConsents(tokenId, d, parties, structHash, deadline, signatures);
        IStreamCore(stream).setRoyaltyRate(tokenId, rate);
        ++d.version;
        emit WorkAmended(tokenId, msg.sig, workStateHash(tokenId));
    }

    /// @inheritdoc IWorkRecords
    function repinRenderer(
        uint256 tokenId,
        address renderer,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata signature
    ) external restricted {
        WorkData storage d = _registered(tokenId);
        if (!d.finalized) revert WorkNotFinalized(tokenId);
        if (
            DelegatedEOA.isDelegated(renderer)
                || !ERC165Checker.supportsInterface(renderer, type(IRenderer).interfaceId)
        ) revert InvalidRenderer(renderer);
        address previous = d.renderer;
        if (renderer == previous) return;
        bytes32 state = _checkState(tokenId, expectedStateHash);
        address artist = _artistOf(tokenId);
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(REPIN_TYPEHASH, tokenId, renderer, state, deadline))
        );
        // Deadlines are coarse (days); a validator's timestamp drift does not matter here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline || !SignatureVerifier.isValid(artist, digest, signature)) {
            revert InvalidConsent(tokenId, artist);
        }
        d.renderer = renderer;
        ++d.version;
        emit RendererRepinned(tokenId, previous, renderer);
        IStreamCore(stream).refreshMetadata(tokenId, tokenId);
    }

    // ---------------------------------------------------------------------------------- views

    /// @inheritdoc IWorkRecords
    function recordState(uint256 tokenId) external view returns (RecordState memory) {
        WorkData storage d = _registered(tokenId);
        return RecordState(
            d.record,
            d.renderer,
            d.version,
            d.mediaCount,
            d.seedPolicy,
            d.finalized,
            d.onChainComplete
        );
    }

    /// @inheritdoc IWorkRecords
    function media(uint256 tokenId) external view returns (bytes32[] memory) {
        _registered(tokenId);
        return _media[tokenId];
    }

    /// @inheritdoc IWorkRecords
    /// @dev Commits to the token, the version, the record file, the license, the royalty terms
    ///      and the effective renderer. Reverts for an unregistered work or a burned token.
    function workStateHash(uint256 tokenId) public view returns (bytes32) {
        WorkData storage d = _registered(tokenId);
        IStreamCore core = IStreamCore(stream);
        (address receiver, uint32 rate) = core.royaltyOf(tokenId);
        return keccak256(
            abi.encode(
                STATE_DOMAIN,
                tokenId,
                d.version,
                d.record,
                keccak256(abi.encode(core.licenseOf(tokenId))),
                receiver,
                rate,
                d.finalized ? d.renderer : core.defaultRenderer()
            )
        );
    }

    /// @inheritdoc IWorkRecords
    function pinnedRenderer(uint256 tokenId) external view returns (address) {
        return _works[tokenId].renderer;
    }

    /// @inheritdoc IWorkRecords
    /// @dev TODO(D4): read the VRF seed by item hash once the entropy module keys seeds by item.
    function seedOf(uint256 tokenId)
        external
        view
        returns (SeedPolicy policy, bytes32 seed, bool available)
    {
        WorkData storage d = _registered(tokenId);
        policy = d.seedPolicy;
        if (policy != SeedPolicy.VRF) return (policy, d.seed, true);
        IEntropyModule module = IEntropyModule(entropyModule);
        if (address(module) == address(0) || !module.isDelivered(stream, tokenId)) {
            return (policy, 0, false);
        }
        return (policy, module.seedOf(stream, tokenId), true);
    }

    // ---------------------------------------------------------------------------- locators

    /// @inheritdoc IWorkRecords
    function addLocator(uint256 tokenId, bytes32 fileId, Locator calldata locator) external {
        _registered(tokenId);
        if (!_isArtist(tokenId, msg.sender)) _checkCanCall(msg.sender, _msgData());
        _requireMedia(tokenId, fileId);
        _checkUri(locator);
        Locator[] storage list = _locators[tokenId][fileId];
        uint256 index = list.length;
        if (index >= Limits.MAX_LOCATORS_PER_FILE) revert InvalidLocator();
        list.push(locator);
        emit LocatorAdded(tokenId, fileId, index, locator);
        IStreamCore(stream).refreshMetadata(tokenId, tokenId);
    }

    /// @inheritdoc IWorkRecords
    function locators(uint256 tokenId, bytes32 fileId) external view returns (Locator[] memory) {
        return _locators[tokenId][fileId];
    }

    /// @inheritdoc IWorkRecords
    /// @dev Every locator of a file is a copy of that one file, so any choice among them is
    ///      hash-equal (ADR 0001 section 8).
    function preferredLocator(uint256 tokenId, bytes32 fileId)
        external
        view
        returns (Locator memory locator, uint256 index)
    {
        _registered(tokenId);
        _requireMedia(tokenId, fileId);
        Locator[] storage list = _locators[tokenId][fileId];
        index = _filePrefs[tokenId][fileId];
        bool found = index != 0;
        if (found) index -= 1;
        if (!found) {
            uint256 collectionId = IStreamCore(stream).work(tokenId).collectionId;
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
        _checkKind(kind);
        emit PreferredKindSet(preferredKind, kind);
        preferredKind = kind;
        _refreshAll();
    }

    /// @inheritdoc IWorkRecords
    function setCollectionPreferredKind(uint256 collectionId, LocatorKind kind)
        external
        restricted
    {
        _checkKind(kind);
        IStreamCore(stream).collection(collectionId); // reverts with `UnknownCollection`
        emit CollectionPreferredKindSet(collectionId, _collectionKinds[collectionId], kind);
        _collectionKinds[collectionId] = kind;
        _refreshAll();
    }

    /// @inheritdoc IWorkRecords
    function setFilePreference(uint256 tokenId, bytes32 fileId, uint256 index) external restricted {
        _registered(tokenId);
        _requireMedia(tokenId, fileId);
        if (index != NONE && index >= _locators[tokenId][fileId].length) {
            revert InvalidPreference();
        }
        emit FilePreferenceSet(tokenId, fileId, filePreference(tokenId, fileId), index);
        _filePrefs[tokenId][fileId] = index == NONE ? 0 : index + 1;
        IStreamCore(stream).refreshMetadata(tokenId, tokenId);
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

    function _relicenseHash(uint256 tokenId, License calldata next, bytes32 state, uint64 deadline)
        private
        pure
        returns (bytes32)
    {
        bytes32 license =
            keccak256(abi.encode(LICENSE_TYPEHASH, keccak256(bytes(next.spdxId)), next.textFileId));
        return keccak256(abi.encode(RELICENSE_TYPEHASH, tokenId, license, state, deadline));
    }

    function _registered(uint256 tokenId) private view returns (WorkData storage d) {
        d = _works[tokenId];
        if (!d.registered) revert UnknownWork(tokenId);
    }

    function _checkState(uint256 tokenId, bytes32 expected) private view returns (bytes32 state) {
        state = workStateHash(tokenId);
        if (state != expected) revert StateHashMismatch(expected, state);
    }

    /// @dev The lead artist's current authority; reverts with the core's `UnknownWork` for a
    ///      burned token.
    function _artistOf(uint256 tokenId) private view returns (address) {
        uint256 artistId = IStreamCore(stream).work(tokenId).artistId;
        return IArtistRegistry(artistRegistry).authorityOf(artistId);
    }

    function _isArtist(uint256 tokenId, address account) private view returns (bool) {
        return _artistOf(tokenId) == account;
    }

    function _onlyArtist(uint256 tokenId) private view {
        if (!_isArtist(tokenId, msg.sender)) revert NotWorkArtist(tokenId, msg.sender);
    }

    /// @dev Every party of the item consents, each by its current authority (D18 derivation:
    ///      `artistIdOf(account)`, else `uint160(account)`), in party order.
    function _checkConsents(
        uint256 tokenId,
        WorkData storage d,
        Party[] calldata parties,
        bytes32 structHash,
        uint64 deadline,
        bytes[] calldata signatures
    ) private view {
        if (keccak256(abi.encode(parties)) != d.partiesHash) {
            revert PartiesMismatch(tokenId);
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline || signatures.length != parties.length) {
            revert InvalidConsent(tokenId, address(0));
        }
        bytes32 digest = _hashTypedDataV4(structHash);
        IArtistRegistry registry = IArtistRegistry(artistRegistry);
        for (uint256 i; i < parties.length; ++i) {
            address account = parties[i].account;
            uint256 artistId = registry.artistIdOf(account);
            if (artistId == 0) artistId = uint256(uint160(account));
            if (!SignatureVerifier.isValid(registry.authorityOf(artistId), digest, signatures[i])) {
                revert InvalidConsent(tokenId, account);
            }
        }
    }

    /// @dev 1 to `MAX_MEDIA_FILES` distinct registered files, the primary (`contentId`) first.
    function _checkMedia(bytes32 contentId, bytes32[] calldata files) private view {
        uint256 n = files.length;
        if (n == 0 || n > Limits.MAX_MEDIA_FILES || files[0] != contentId) revert InvalidMedia();
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (files[i] == files[j]) revert InvalidMedia();
            }
            // Reverts with `ContentFileUnknown` unless the manifest is registered.
            IContentStore(contentStore).chunkHash(files[i], 0);
        }
    }

    /// @dev A record is a complete JSON file, so the renderer can always read it.
    function _checkRecordFile(bytes32 fileId) private view {
        IContentStore store = IContentStore(contentStore);
        if (
            keccak256(bytes(store.fileInfo(fileId).mimeType)) != JSON_MIME
                || !store.isComplete(fileId)
        ) revert InvalidRecord(fileId);
    }

    function _requireMedia(uint256 tokenId, bytes32 fileId) private view {
        bytes32[] storage list = _media[tokenId];
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == fileId) return;
        }
        revert FileNotInWork(tokenId, fileId);
    }

    /// @dev Locator URIs are printable ASCII without quotes, backslashes or angle brackets,
    ///      after the kind's scheme: `ar://` or `ipfs://` (D11: no HTTPS).
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

    function _checkKind(LocatorKind kind) private pure {
        if (kind == LocatorKind.HTTPS) revert InvalidPreference();
    }

    /// @dev ERC-4906 refresh of every token ever minted (burned IDs included, harmlessly).
    function _refreshAll() private {
        uint256 minted = IStreamCore(stream).totalMinted();
        if (minted != 0) IStreamCore(stream).refreshMetadata(1, minted);
    }

    function _requireContract(address dependency) private view {
        if (dependency.code.length == 0 || DelegatedEOA.isDelegated(dependency)) {
            revert InvalidDependency(dependency);
        }
    }
}
