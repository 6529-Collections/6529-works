// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IWorkRecords
/// @notice DRAFT, local to the stream lane: the records satellite of 6529 Stream (integrator
///         decision D1), until the interfaces lane publishes `IWorkRecords`.
interface IWorkRecords {
    /// @notice The renderer pinned by finalize or the errata path, or zero before finalize.
    function pinnedRenderer(uint256 tokenId) external view returns (address);
}
