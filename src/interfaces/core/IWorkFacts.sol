// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MediaFile } from "../types/ContentTypes.sol";
import { License, PackageItem } from "../types/PackageTypes.sol";
import { Facts } from "./CoreTypes.sol";

/// @title IWorkFacts
/// @notice The permanent record of each work, for 6529 Stream and every federated token, keyed
///         by token contract and token ID: media, descriptive record, license and, once
///         finalized, the pinned renderer. Unowned and ungoverned.
/// @dev Who may change a record, and when, is the business of each token's RECORDS module
///      (`IModuleSlots(token).moduleOf("RECORDS")`). What holds whatever that module does:
///      - a record opens only with the exact item the token was minted from, and its media are
///        the files that item committed to; media never change;
///      - after finalize the descriptive record never changes;
///      - a CC0 license is never left; a locked license never changes;
///      - a finalized work's renderer changes only by `repin`, and never once that is locked;
///      - "on-chain complete" is checked against the content store, by anyone.
interface IWorkFacts {
    /// @notice A record was opened.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param item The item the token was minted from.
    /// @param media Its media files.
    event RecordOpened(
        address indexed token, uint256 indexed tokenId, PackageItem item, MediaFile[] media
    );
    /// @notice The descriptive record was replaced (before finalize).
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param recordFileId The new record file.
    event RecordSet(address indexed token, uint256 indexed tokenId, bytes32 recordFileId);
    /// @notice The license was replaced.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param license The license now.
    event LicenseSet(address indexed token, uint256 indexed tokenId, License license);
    /// @notice The work was finalized and its renderer pinned.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param renderer The pinned renderer.
    /// @param codeHash Its code hash.
    event Finalized(
        address indexed token, uint256 indexed tokenId, address renderer, bytes32 codeHash
    );
    /// @notice A finalized work's renderer was replaced.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param renderer The renderer now.
    /// @param codeHash Its code hash.
    event RendererRepinned(
        address indexed token, uint256 indexed tokenId, address renderer, bytes32 codeHash
    );
    /// @notice The work's locks after a `lock` call.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param license True if the license is locked.
    /// @param repin True if the renderer pin is locked.
    event Locked(address indexed token, uint256 indexed tokenId, bool license, bool repin);
    /// @notice Every media file of the work is complete in the content store.
    /// @param token The token contract.
    /// @param tokenId The token.
    event OnChainComplete(address indexed token, uint256 indexed tokenId);

    /// @notice The caller is not the token's RECORDS module.
    error NotRecordsModule(address token, address caller);
    /// @notice The record is already open.
    error RecordAlreadyOpen(address token, uint256 tokenId);
    /// @notice The record is not open.
    error RecordNotOpen(address token, uint256 tokenId);
    /// @notice The item or media do not match the token, or the record file is not one complete
    ///         chunk, or the license ID cannot be shown.
    error InvalidRecord(address token, uint256 tokenId);
    /// @notice The license would leave CC0, a CC0 license names another text, the ID is invalid,
    ///         or the text is not a registered SHA-256 file of at most 16 chunks (complete, where
    ///         required).
    error InvalidLicense();
    /// @notice The license is locked.
    error LicenseIsLocked(address token, uint256 tokenId);
    /// @notice The work is finalized.
    error WorkIsFinalized(address token, uint256 tokenId);
    /// @notice The work is not finalized.
    error WorkNotFinalized(address token, uint256 tokenId);
    /// @notice The renderer pin is locked.
    error RepinIsLocked(address token, uint256 tokenId);
    /// @notice The renderer has no code, or its code is no longer the code that was pinned.
    error RendererCodeChanged(address renderer);
    /// @notice A media file is not complete in the content store.
    error NotOnChainComplete(address token, uint256 tokenId);

    /// @notice The content store.
    /// @return The store.
    function contentStore() external view returns (address);

    /// @notice The text file every CC0 license names.
    /// @return The file ID.
    function cc0TextFileId() external view returns (bytes32);

    /// @notice Opens a work's record from the item it was minted from. Anyone: the item is
    ///         checked against `IStream(token).itemHashOf(tokenId)`, the media against the item's
    ///         media hash and content hash and the content store's declared SHA-256.
    /// @param token The token contract.
    /// @param tokenId A live token.
    /// @param item The item.
    /// @param media The media files, primary first.
    function open(
        address token,
        uint256 tokenId,
        PackageItem calldata item,
        MediaFile[] calldata media
    ) external;

    /// @notice Records that every media file is complete in the content store
    ///         (`IContentStore.isComplete`, one read per file). Anyone.
    /// @param token The token contract.
    /// @param tokenId A token with an open record.
    function markOnChainComplete(address token, uint256 tokenId) external;

    /// @notice Replaces the descriptive record. The RECORDS module only; never after finalize.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param recordFileId The new record file.
    function setRecord(address token, uint256 tokenId, bytes32 recordFileId) external;

    /// @notice Replaces the license. The RECORDS module only; never once locked, never away from
    ///         CC0.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param next The new license.
    function setLicense(address token, uint256 tokenId, License calldata next) external;

    /// @notice Freezes the record and pins the token's current RENDERER module, once. The
    ///         RECORDS module only. The record file must be one complete chunk and the license
    ///         text complete.
    /// @param token The token contract.
    /// @param tokenId The token.
    function finalize(address token, uint256 tokenId) external;

    /// @notice Replaces a finalized work's renderer. The RECORDS module only; never once locked.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param renderer The new renderer (with code).
    function repin(address token, uint256 tokenId, address renderer) external;

    /// @notice Locks the license, the renderer pin, or both, for good. The RECORDS module only.
    ///         The pin locks only after finalize.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param license True to lock the license.
    /// @param repin_ True to lock the pin.
    function lock(address token, uint256 tokenId, bool license, bool repin_) external;

    /// @notice A work's record (empty if not opened).
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @return The record.
    function factsOf(address token, uint256 tokenId) external view returns (Facts memory);

    /// @notice The renderer pinned for a finalized work, or zero. Reverts with
    ///         `RendererCodeChanged` if its code is no longer the code that was pinned.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @return renderer The pinned renderer.
    function rendererOf(address token, uint256 tokenId) external view returns (address renderer);
}
