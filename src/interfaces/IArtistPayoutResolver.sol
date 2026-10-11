// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IArtistPayoutResolver
/// @notice Resolves an artist's current payout address (ADR 0001 section 11). Split wallets ask it
///         at release time, so a recovery or estate change also redirects balances that an
///         artist-resolved payee has already accrued.
/// @dev An exact mirror of the economics lane's `src/economics/interfaces/IArtistPayoutResolver`
///      (PR #11, not yet merged); the two are deduplicated when it merges. Split wallets treat a
///      zero result as unresolved and refuse to release.
interface IArtistPayoutResolver {
    /// @notice Returns the address that currently receives `artistId`'s payouts, or zero.
    function payoutAddress(uint256 artistId) external view returns (address);
}
