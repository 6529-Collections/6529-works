// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IArtistPayoutResolver
/// @notice Resolves an artist's current payout address (ADR 0001 section 11). Split wallets ask it
///         at release time, so a recovery or estate change also redirects balances that an
///         artist-resolved payee has already accrued.
/// @dev Local interface owned by the economics lane until the identity lane publishes the artist
///      registry; the integrator reconciles the two. Split wallets treat a zero result as
///      unresolved and refuse to release. A payout address must be an account that can pull or
///      sign: never a protocol contract such as the claim router, the escrow, a sale adapter or a
///      split wallet, which can neither pull nor move funds onward. The artist registry refuses
///      these at registration, staging and execution; a split wallet's predicted address is
///      refused only once the wallet is deployed, since before that it has no code.
interface IArtistPayoutResolver {
    /// @notice Returns the address that currently receives `artistId`'s payouts, or zero.
    function payoutAddress(uint256 artistId) external view returns (address);
}
