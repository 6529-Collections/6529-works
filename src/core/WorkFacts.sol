// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IContentStore } from "../interfaces/IContentStore.sol";
import { Facts, Media, Slots } from "../interfaces/core/CoreTypes.sol";
import { IModuleSlots } from "../interfaces/core/IModules.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { IWorkFacts } from "../interfaces/core/IWorkFacts.sol";
import { MediaFile } from "../interfaces/types/ContentTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { License, PackageItem } from "../interfaces/types/PackageTypes.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { SpdxId } from "../stream/SpdxId.sol";

/// @title WorkFacts
/// @notice The permanent record of each work, for 6529 Stream and for
///         every federated token: its media files, its descriptive record, its license and, once
///         finalized, its pinned renderer. Who may change a record, and when, is the business of
///         each token's replaceable RECORDS module; what can never change is enforced here.
/// @dev lane 3 completes this (tests, NatSpec, review; the store reads follow the escrow and
///      content fixes branch once it lands). What this contract guarantees whatever the module does:
///      - a record opens only with the exact item the token was minted from, and its media are
///        the files that item committed to; media never change;
///      - after finalize the descriptive record never changes;
///      - a CC0 license is never left; a locked license never changes;
///      - a finalized work's renderer changes only by a repin, and never once that is locked;
///      - "on-chain complete" is checked against the content store, by anyone.
contract WorkFacts is IWorkFacts {
    /// @notice The most chunks of a license text: a bound on the work one call does.
    uint256 public constant MAX_LICENSE_TEXT_CHUNKS = 16;

    /// @inheritdoc IWorkFacts
    address public immutable contentStore;
    /// @inheritdoc IWorkFacts
    bytes32 public immutable cc0TextFileId;

    mapping(address token => mapping(uint256 tokenId => Facts)) private _facts;

    /// @param contentStore_ The content store.
    /// @param cc0TextFileId_ The text file every CC0 license names.
    constructor(address contentStore_, bytes32 cc0TextFileId_) {
        contentStore = contentStore_;
        cc0TextFileId = cc0TextFileId_;
    }

    // ---------------------------------------------------------------------- anyone, verified

    /// @inheritdoc IWorkFacts
    function open(
        address token,
        uint256 tokenId,
        PackageItem calldata item,
        MediaFile[] calldata media
    ) external {
        Facts storage f = _facts[token][tokenId];
        if (f.opened) revert RecordAlreadyOpen(token, tokenId);
        uint256 count = media.length;
        if (
            WorksHashing.itemHashCalldata(item) != IStream(token).itemHashOf(tokenId) || count == 0
                || count > Limits.MAX_MEDIA_FILES
                || keccak256(abi.encode(WorksHashing.MEDIA_DOMAIN, media)) != item.mediaHash
                || media[0].sha256Hash != item.contentHash
        ) revert InvalidRecord(token, tokenId);
        for (uint256 i; i < count; ++i) {
            MediaFile calldata file = media[i];
            // Reverts for a file the store does not know or whose digest is not SHA-256.
            if (
                IContentStore(contentStore).sha256Of(file.fileId) != file.sha256Hash
                    || (file.role == 0) != (i == 0)
            ) {
                revert InvalidRecord(token, tokenId);
            }
            f.media.push(Media(file.fileId, file.role));
        }
        _checkCc0(item.license);
        f.opened = true;
        f.recordFileId = item.recordFileId;
        f.licenseId = item.license.spdxId;
        f.licenseTextFileId = item.license.textFileId;
        emit RecordOpened(token, tokenId, item, media);
        IStream(token).emitMetadataUpdate(tokenId, tokenId);
    }

    /// @inheritdoc IWorkFacts
    function markOnChainComplete(address token, uint256 tokenId) external {
        Facts storage f = _opened(token, tokenId);
        uint256 count = f.media.length;
        for (uint256 i; i < count; ++i) {
            if (!IContentStore(contentStore).isComplete(f.media[i].fileId)) {
                revert NotOnChainComplete(token, tokenId);
            }
        }
        if (f.onChainComplete) return;
        f.onChainComplete = true;
        emit OnChainComplete(token, tokenId);
        IStream(token).emitMetadataUpdate(tokenId, tokenId);
    }

    // ------------------------------------------------------------------- the RECORDS module

    /// @inheritdoc IWorkFacts
    function setRecord(address token, uint256 tokenId, bytes32 recordFileId) external {
        Facts storage f = _module(token, tokenId);
        if (f.finalized) revert WorkIsFinalized(token, tokenId);
        f.recordFileId = recordFileId;
        emit RecordSet(token, tokenId, recordFileId);
    }

    /// @inheritdoc IWorkFacts
    function setLicense(address token, uint256 tokenId, License calldata next) external {
        Facts storage f = _module(token, tokenId);
        if (f.licenseLocked) revert LicenseIsLocked(token, tokenId);
        bytes32 cc0 = WorksHashing.CC0_LICENSE_KEY;
        if (
            (WorksHashing.licenseKey(f.licenseId) == cc0
                    && WorksHashing.licenseKey(next.spdxId) != cc0)
                || !SpdxId.isValidCalldata(next.spdxId)
        ) revert InvalidLicense();
        _checkCc0(next);
        _checkLicenseText(next.textFileId, f.finalized);
        f.licenseId = next.spdxId;
        f.licenseTextFileId = next.textFileId;
        emit LicenseSet(token, tokenId, next);
    }

    /// @inheritdoc IWorkFacts
    function finalize(address token, uint256 tokenId) external {
        Facts storage f = _module(token, tokenId);
        if (f.finalized) revert WorkIsFinalized(token, tokenId);
        // The record is one complete chunk; the license is one the renderer can show.
        IContentStore.FileInfo memory info = IContentStore(contentStore).fileInfo(f.recordFileId);
        if (
            info.chunkCount != 1 || info.digestKind != 0 || info.encoding != 0
                || !IContentStore(contentStore).isComplete(f.recordFileId)
                || !SpdxId.isValid(f.licenseId)
        ) revert InvalidRecord(token, tokenId);
        _checkLicenseText(f.licenseTextFileId, true);
        address renderer = IModuleSlots(token).moduleOf(Slots.RENDERER);
        f.finalized = true;
        _pin(f, renderer);
        emit Finalized(token, tokenId, renderer, f.rendererCodeHash);
    }

    /// @inheritdoc IWorkFacts
    function repin(address token, uint256 tokenId, address renderer) external {
        Facts storage f = _module(token, tokenId);
        if (!f.finalized) revert WorkNotFinalized(token, tokenId);
        if (f.repinLocked) revert RepinIsLocked(token, tokenId);
        _pin(f, renderer);
        emit RendererRepinned(token, tokenId, renderer, f.rendererCodeHash);
    }

    /// @inheritdoc IWorkFacts
    function lock(address token, uint256 tokenId, bool license, bool repin_) external {
        Facts storage f = _module(token, tokenId);
        if (license) {
            if (!SpdxId.isValid(f.licenseId)) revert InvalidLicense();
            _checkLicenseText(f.licenseTextFileId, false);
            f.licenseLocked = true;
        }
        if (repin_) {
            if (!f.finalized) revert WorkNotFinalized(token, tokenId);
            f.repinLocked = true;
        }
        emit Locked(token, tokenId, f.licenseLocked, f.repinLocked);
    }

    // --------------------------------------------------------------------------------- views

    /// @inheritdoc IWorkFacts
    function factsOf(address token, uint256 tokenId) external view returns (Facts memory) {
        return _facts[token][tokenId];
    }

    /// @inheritdoc IWorkFacts
    function rendererOf(address token, uint256 tokenId) external view returns (address renderer) {
        Facts storage f = _facts[token][tokenId];
        renderer = f.renderer;
        if (renderer != address(0) && renderer.codehash != f.rendererCodeHash) {
            revert RendererCodeChanged(renderer);
        }
    }

    // ------------------------------------------------------------------------------ internal

    function _opened(address token, uint256 tokenId) private view returns (Facts storage f) {
        f = _facts[token][tokenId];
        if (!f.opened) revert RecordNotOpen(token, tokenId);
    }

    function _module(address token, uint256 tokenId) private view returns (Facts storage) {
        if (msg.sender != IModuleSlots(token).moduleOf(Slots.RECORDS)) {
            revert NotRecordsModule(token, msg.sender);
        }
        return _opened(token, tokenId);
    }

    function _pin(Facts storage f, address renderer) private {
        if (renderer.code.length == 0) revert RendererCodeChanged(renderer);
        f.renderer = renderer;
        f.rendererCodeHash = renderer.codehash;
    }

    /// @dev A CC0 license always names the deployment's CC0 text.
    function _checkCc0(License calldata license) private view {
        if (
            WorksHashing.licenseKey(license.spdxId) == WorksHashing.CC0_LICENSE_KEY
                && license.textFileId != cc0TextFileId
        ) revert InvalidLicense();
    }

    /// @dev A license text is a registered SHA-256 file of at most 16 chunks, complete if `stored`.
    function _checkLicenseText(bytes32 textFileId, bool stored) private view {
        IContentStore.FileInfo memory info = IContentStore(contentStore).fileInfo(textFileId);
        if (
            info.digestKind != 0 || info.chunkCount > MAX_LICENSE_TEXT_CHUNKS
                || (stored && !IContentStore(contentStore).isComplete(textFileId))
        ) revert InvalidLicense();
    }
}
