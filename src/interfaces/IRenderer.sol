// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRenderer
/// @notice Builds token metadata for 6529 Stream works and 6529 Editions editions (ADR 0001
///         section 8 "`tokenURI` size").
/// @dev A renderer is immutable: a change of rendering is a new renderer contract, which works
///      adopt as the default before finalize or by the errata path after. It reads the work
///      record, license, locators and seed from 6529 Stream (an edition reads through its
///      master), the bytes from the content store, and dispute status from the statement log's
///      `latestDisputeOutcome`,
///      and adds the collection, artist, license and edition traits. `tokenURI` stays small: it
///      inlines the media only when the work is on-chain complete and the primary file is at
///      most `inlineThreshold()` bytes; otherwise it gives the preferred locator plus, up to
///      1 MB, a small on-chain preview. Above 1 MB the media is reachable only through the
///      content store's chunked reads. Reads are bounded and fail closed: a renderer never
///      returns plausible metadata for a token it cannot read.
interface IRenderer {
    /// @notice The compact metadata URI (`data:application/json;...`) for `tokenId` of
    ///         `token`, which is 6529 Stream or 6529 Editions.
    function tokenURI(address token, uint256 tokenId) external view returns (string memory);

    /// @notice The full metadata URI with the media inlined, for an on-chain complete work whose
    ///         primary file is at most 1 MB. Reverts otherwise.
    function fullTokenURI(address token, uint256 tokenId) external view returns (string memory);

    /// @notice The largest primary file, in stored bytes, that `tokenURI` inlines (256 KiB
    ///         until the Sepolia matrix sets the final value).
    function inlineThreshold() external view returns (uint256);
}
