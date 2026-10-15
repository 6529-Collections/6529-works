// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IArtistPayoutResolver
/// @notice Resolves an artist's current payout address (ADR 0001 section 11). Split wallets ask it
///         at release time, so a recovery or estate change also redirects balances that an
///         artist-resolved payee has already accrued.
/// @dev Implemented by the artist registry (`IArtistRegistry.payoutAddress`). Split wallets treat a
///      zero result as unresolved and refuse to release. A payout address must be an account that
///      can pull or sign: never a protocol contract such as the claim router, the escrow, a sale
///      adapter or a split wallet, which can neither pull nor move funds onward. The artist
///      registry refuses these at registration, staging and execution; a split wallet's predicted
///      address is refused only once the wallet is deployed, since before that it has no code.
interface IArtistPayoutResolver {
    /// @notice Returns the address that currently receives `artistId`'s payouts, or zero.
    /// @param artistId The artist's ID in the artist registry.
    /// @return The current payout address; zero for an unknown artist, and while a pending
    ///        change would move the payout.
    function payoutAddress(uint256 artistId) external view returns (address);
}
