// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IRenderer
/// @notice Builds token metadata for 6529 Stream works and 6529 Editions editions (ADR 0001
///         section 8 "`tokenURI` size").
/// @dev A renderer is immutable: a change of rendering is a new renderer contract, which works
///      adopt as the default before finalize or by the errata path after. It reads the core and
///      seed from 6529 Stream, the record file ID, media, license and preferred locators from
///      `IWorkRecords` (an edition reads through its master), the record JSON and media bytes from
///      the content store, and dispute status from the statement log's `latestDisputeOutcome`; it
///      adds the collection, artist, license and edition traits. `tokenURI` stays small: it inlines
///      the media only when the work is on-chain complete and the primary file is at most
///      `inlineThreshold()` cost-weighted bytes; otherwise it gives the preferred locator plus a
///      small on-chain preview. Above 1 MiB the media is reachable only through the content
///      store's chunked reads. Reads are bounded and fail closed: a renderer never returns
///      plausible metadata for a token it cannot read. A work whose record is not open yet, not
///      completely uploaded (or not registered in the store at all) or not acceptable is not an
///      unreadable token: it gets core-only metadata from 6529 Stream with a `record_status`
///      field, and never a revert.
interface IRenderer is IERC165 {
    /// @notice The inline threshold is zero or above the renderer's `MAX_INLINE_BYTES`.
    error RendererThresholdInvalid(uint256 threshold);
    /// @notice A read of `target` failed: no code, a revert, out of its gas cap, or too much
    ///         return data. `selector` names the call.
    error RendererReadFailed(address target, bytes4 selector);
    /// @notice A string from 6529 Stream, a locator or the content store is not well-formed
    ///         UTF-8.
    error RendererInvalidUtf8();
    /// @notice The work's data breaks a rule: no primary file first, or an edition whose content
    ///         hash is not its master's. (A bad record is not an error: it renders core-only.)
    error RendererRecordInvalid(address token, uint256 tokenId);
    /// @notice `fullTokenURI` cannot serve the work in full: its record is not open, incomplete
    ///         or invalid, or the primary file is not on-chain complete, is incomplete, too large,
    ///         not attested `Base64`, or not stored as `Identity` or `Base64`.
    error RendererNotInlineable(address token, uint256 tokenId);

    /// @notice The compact metadata URI (`data:application/json;...`) for `tokenId` of
    ///         `token`, which is 6529 Stream or 6529 Editions.
    function tokenURI(address token, uint256 tokenId) external view returns (string memory);

    /// @notice The full metadata URI with the media inlined, for a work with a usable record that
    ///         is on-chain complete and whose primary file is at most 1 MiB (cost-weighted). Reverts
    ///         otherwise, including for a work that `tokenURI` shows as core-only.
    function fullTokenURI(address token, uint256 tokenId) external view returns (string memory);

    /// @notice The largest primary file `tokenURI` inlines, measured in cost-weighted stored bytes
    ///         (the renderer has to base64-encode an `Identity` file, which costs about eight times
    ///         what copying `Base64` text does, so an `Identity` byte counts eight times and a
    ///         `Base64` byte once), 256 KiB until the Sepolia matrix sets the final value.
    function inlineThreshold() external view returns (uint256);
}
