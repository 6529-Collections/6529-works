// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// The denominator of every share and rate, so 6.529% is exactly 6,529 (ADR 0001 section 7).
uint32 constant SHARE_DENOMINATOR = 100_000;

// The currency value meaning ETH.
address constant CURRENCY_ETH = address(0);

// The currency value meaning "the product's default currency when the sale starts" (ADR 0001
// section 5 "Payment currency is configuration, not code"). Valid only in package sale and
// edition terms; `IEconomicsResolver.resolveCurrency` resolves it, and it is never a sale's
// locked currency.
address constant CURRENCY_DEFAULT = address(type(uint160).max);

/// @notice One recipient of a split wallet (ADR 0001 sections 7 and 11).
/// @dev When `artistResolved` is true the wallet pays `IArtistRegistry.payoutOf` of `account`'s
///      artist ID at release time, so recovery and estates redirect balances already accrued
///      (ADR 0001 section 11 "Hardening"); otherwise it pays `account` itself. `share` is out of
///      `SHARE_DENOMINATOR`; a split's accounts are distinct, its shares sum to 100,000, and it
///      has at most `Limits.MAX_SPLIT_RECIPIENTS` recipients.
struct SplitRecipient {
    address account;
    uint32 share;
    bool artistResolved;
}

/// @notice The network's governed economics for one product (6529 Stream, 6529 Editions).
/// @dev `feeShare` is the network part of primary sales and of royalties (25,000 at launch);
///      `royaltyRate` is the ERC-2981 rate for new works (6,529 at launch). Both are out of
///      `SHARE_DENOMINATOR`.
struct ProductEconomics {
    address feeRecipient;
    uint32 feeShare;
    uint32 royaltyRate;
}

/// @notice The terms a new work locks at mint (ADR 0001 section 7 "locked at mint").
/// @dev `seller` is the artist-portion split wallet. `royaltyReceiver` is the split wallet that
///      pays royalties `SHARE_DENOMINATOR - feeShare` to `seller` and `feeShare` to
///      `feeRecipient`. Both wallets are deployed.
struct WorkTerms {
    address seller;
    address feeRecipient;
    uint32 feeShare;
    address royaltyReceiver;
    uint32 royaltyRate;
}

/// @notice Whether a currency may be used (ADR 0001 sections 5 and 7).
/// @dev ACTIVE currencies may start new sales. DEPRECATED currencies start no new sales but
///      everything already owed in them stays claimable and withdrawable.
enum CurrencyStatus {
    NONE,
    ACTIVE,
    DEPRECATED
}

/// @notice A currency's governed configuration.
/// @dev `incrementFloor` is the absolute minimum English-auction bid increment in that
///      currency's units (0.001 ETH for ETH); the increment is `max(5%, incrementFloor)`.
struct CurrencyConfig {
    CurrencyStatus status;
    uint256 incrementFloor;
}
