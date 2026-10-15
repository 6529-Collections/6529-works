// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IArtistRoleResolver
/// @notice The minimal question the statement log asks the artist registry: may `account` speak
///         as an artist of this subject? The artist registry implements it; the log depends
///         only on this interface.
/// @dev Must support ERC-165 for this interface, because the log checks that at install time
///      (ADR 0001 section 13, requirement 6). `token == address(0)` means `id` is a work ID that
///      has no token yet (for example an approved package item).
///
///      Trust. The log trusts this contract's answers completely: ARTIST authority is no stronger
///      than the resolver. The log pins a code hash at install, which binds bytecode, not
///      behaviour, so an implementation that forwards to a mutable backend is only as trustworthy
///      as whoever controls that backend. An implementation must therefore be immutable, or be
///      governed so that no answer is ever made true faster than the 30-day class (ADR 0001
///      section 13), with every change public. A guardian-vetoable withholding (an answer made
///      false, never redirected; ADR 0003 owner decision 6) is allowed.
interface IArtistRoleResolver is IERC165 {
    /// @notice Returns whether `account` is currently an artist (or authorised artist key) of
    ///         the subject `(token, id)`.
    /// @dev Should return false, not revert, for a subject it does not know. The log calls this
    ///      with `staticcall`, so it cannot change state.
    /// @param token The subject's token contract, or zero when `id` is a work ID with no token.
    /// @param id The token ID, or the work ID when `token` is zero.
    /// @param account The account that would speak as an artist.
    /// @return True if `account` may speak as an artist of the subject now.
    function isArtist(address token, uint256 id, address account) external view returns (bool);
}
