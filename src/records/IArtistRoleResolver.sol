// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IArtistRoleResolver
/// @notice The minimal question the statement log asks the artist registry: may `account` speak
///         as an artist of this subject? The registry implements this later; the log only
///         depends on this interface.
/// @dev Must support ERC-165 for this interface, because the log checks that at install time
///      (ADR 0001 section 13, requirement 6). `token == address(0)` means `id` is a work ID that
///      has no token yet (for example an approved package item).
interface IArtistRoleResolver is IERC165 {
    /// @notice Returns whether `account` is currently an artist (or authorised artist key) of
    ///         the subject `(token, id)`.
    /// @dev Should return false, not revert, for a subject it does not know. The log calls this
    ///      with `staticcall`, so it cannot change state.
    function isArtist(address token, uint256 id, address account) external view returns (bool);
}
