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
/// @notice The permanent record of each work, for 6529 Stream and for every federated token: its
///         media files, its descriptive record, its license and, once finalized, its pinned
///         renderer. Who may change a record, and when, is the business of each token's
///         replaceable RECORDS module; what can never change is enforced here.
/// @dev Unowned and ungoverned: no function here is restricted to the network, and no setting
///      exists. What this contract guarantees, whatever any module does:
///      - a record opens only with the exact item the token was minted from, and its media are
///        the files that item committed to; the media never change;
///      - after finalize the descriptive record never changes;
///      - a CC0 license is never left, and always names the deployment's CC0 text;
///      - a license whose identifier is not a valid SPDX identifier (an empty one included) can
///        never be finalized or locked;
///      - a locked license never changes;
///      - a finalized work's renderer changes only by a repin, and never once that is locked;
///      - `finalized`, `licenseLocked`, `repinLocked` and `onChainComplete` never go back to
///        false;
///      - "on-chain complete" is checked against the content store, by anyone.
///      Every call to the token contract or its RECORDS module is made before this contract
///      reads the state it checks, so a token that calls back into this contract cannot change
///      what a call has already checked.
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
    /// @dev The license is stored as the item states it: only the CC0 rule is checked here (a
    ///      CC0 license names the deployment's CC0 text), because CC0 can never be left or
    ///      corrected. Everything else about the license is checked when it is finalized,
    ///      locked or replaced.
    function open(
        address token,
        uint256 tokenId,
        PackageItem calldata item,
        MediaFile[] calldata media
    ) external {
        // The token is asked first; an answer it gives by calling back cannot open twice.
        bytes32 itemHash = IStream(token).itemHashOf(tokenId);
        Facts storage f = _facts[token][tokenId];
        if (f.opened) revert RecordAlreadyOpen(token, tokenId);
        uint256 count = media.length;
        if (
            WorksHashing.itemHashCalldata(item) != itemHash || count == 0
                || count > Limits.MAX_MEDIA_FILES
                || keccak256(abi.encode(WorksHashing.MEDIA_DOMAIN, media)) != item.mediaHash
                || media[0].sha256Hash != item.contentHash
        ) revert InvalidRecord(token, tokenId);
        _checkCc0(item.license);
        f.opened = true;
        f.recordFileId = item.recordFileId;
        f.licenseId = item.license.spdxId;
        f.licenseTextFileId = item.license.textFileId;
        for (uint256 i; i < count; ++i) {
            MediaFile calldata file = media[i];
            // The store reverts for a file it does not know or whose digest is not SHA-256.
            if (
                IContentStore(contentStore).sha256Of(file.fileId) != file.sha256Hash
                    || (file.role == 0) != (i == 0)
            ) {
                revert InvalidRecord(token, tokenId);
            }
            f.media.push(Media(file.fileId, file.role));
        }
        emit RecordOpened(token, tokenId, item, media);
        IStream(token).emitMetadataUpdate(tokenId, tokenId);
    }

    /// @inheritdoc IWorkFacts
    function markOnChainComplete(address token, uint256 tokenId) external {
        Facts storage f = _opened(token, tokenId);
        if (f.onChainComplete) return;
        uint256 count = f.media.length;
        for (uint256 i; i < count; ++i) {
            if (!IContentStore(contentStore).isComplete(f.media[i].fileId)) {
                revert NotOnChainComplete(token, tokenId);
            }
        }
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
    /// @dev A CC0 license may be replaced only by CC0 (any case of `CC0-1.0`) with the
    ///      deployment's CC0 text. The new identifier must be valid, and the new text a
    ///      registered SHA-256 file of at most `MAX_LICENSE_TEXT_CHUNKS` chunks, complete once
    ///      the work is finalized.
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
    /// @dev The record file must be a registered, complete, one-chunk file stored as it is
    ///      (no encoding) with a SHA-256 digest. The license identifier must be valid: a license
    ///      with an empty identifier, CC0 text or not, never finalizes. The license text must be
    ///      complete. The renderer pinned is the token's RENDERER module at this moment, read by
    ///      this contract, so no module chooses it.
    function finalize(address token, uint256 tokenId) external {
        Facts storage f = _module(token, tokenId);
        address renderer = IModuleSlots(token).moduleOf(Slots.RENDERER);
        if (f.finalized) revert WorkIsFinalized(token, tokenId);
        IContentStore.FileInfo memory info = IContentStore(contentStore).fileInfo(f.recordFileId);
        if (
            info.chunkCount != 1 || info.digestKind != 0 || info.encoding != 0
                || !IContentStore(contentStore).isComplete(f.recordFileId)
                || !SpdxId.isValid(f.licenseId)
        ) revert InvalidRecord(token, tokenId);
        _checkLicenseText(f.licenseTextFileId, true);
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
    /// @dev Locking the license needs a valid identifier and a registered SHA-256 text of at
    ///      most `MAX_LICENSE_TEXT_CHUNKS` chunks, so a license that can never change again is
    ///      one `finalize` can accept (only missing chunks, which anyone may write, may remain).
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

    /// @dev The open record of a work.
    function _opened(address token, uint256 tokenId) private view returns (Facts storage f) {
        f = _facts[token][tokenId];
        if (!f.opened) revert RecordNotOpen(token, tokenId);
    }

    /// @dev The open record of a work, when the caller is the token's RECORDS module. The token
    ///      is asked before the record is read.
    function _module(address token, uint256 tokenId) private view returns (Facts storage) {
        if (msg.sender != IModuleSlots(token).moduleOf(Slots.RECORDS)) {
            revert NotRecordsModule(token, msg.sender);
        }
        return _opened(token, tokenId);
    }

    /// @dev Pins `renderer` and its current code hash. A renderer without code is refused.
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

    /// @dev A license text is a registered SHA-256 file of at most `MAX_LICENSE_TEXT_CHUNKS`
    ///      chunks, and complete when `stored`. The store reverts for an unknown file.
    function _checkLicenseText(bytes32 textFileId, bool stored) private view {
        IContentStore.FileInfo memory info = IContentStore(contentStore).fileInfo(textFileId);
        if (
            info.digestKind != 0 || info.chunkCount > MAX_LICENSE_TEXT_CHUNKS
                || (stored && !IContentStore(contentStore).isComplete(textFileId))
        ) revert InvalidLicense();
    }
}
