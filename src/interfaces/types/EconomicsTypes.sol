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

// Product identifiers (ADR 0001 section 2). They scope default currencies, economics and
// content uniqueness.
bytes32 constant PRODUCT_STREAM = keccak256("PRODUCT_STREAM");
bytes32 constant PRODUCT_EDITIONS = keccak256("PRODUCT_EDITIONS");
bytes32 constant PRODUCT_FEDERATED = keccak256("PRODUCT_FEDERATED");

/// @notice One share holder of a split wallet: an exact mirror of the economics lane's
///         `ISplitWallet.Payee` (ADR 0001 sections 7 and 11), to be deduplicated when that
///         interface moves here.
/// @dev Exactly one of `artistId` and `account` is nonzero. A fixed payee names its `account`;
///      an artist-resolved payee names its `artistId` and is paid at
///      `IArtistRegistry.payoutAddress(artistId)` when funds are released, so recovery and
///      estates redirect balances already accrued. `share` is out of `SHARE_DENOMINATOR` and the
///      shares of a list sum to 100,000. A payee list is canonical when it is sorted strictly by
///      `(artistId, account)`: fixed payees first by address, then artist-resolved payees by
///      artist ID. The split wallet's address is a CREATE2 address committing to the canonical
///      list, known before the wallet is deployed.
struct Payee {
    uint256 artistId;
    address account;
    uint32 share;
}

/// @notice The network's governed economics for one product.
/// @dev `feeShare` is the network part of primary sales and of royalties (25,000 at launch);
///      `royaltyRate` is the ERC-2981 rate for new works (6,529 at launch). Both are out of
///      `SHARE_DENOMINATOR`.
struct ProductEconomics {
    address feeRecipient;
    uint32 feeShare;
    uint32 royaltyRate;
}

/// @notice The terms a new work locks at mint (ADR 0001 section 7 "locked at mint").
/// @dev `seller` is the split wallet of the item's payees (the artist portion). `royaltyReceiver`
///      is the split wallet paying `SHARE_DENOMINATOR - feeShare` to `seller` and `feeShare` to
///      `feeRecipient`. Both are predicted CREATE2 addresses: they may not be deployed yet, which
///      is safe because ETH and ERC-20 transfers to them are held until anyone deploys the
///      wallet, and a sale start never pays the roughly 1.6M gas a deployment costs.
struct WorkTerms {
    address seller;
    address feeRecipient;
    uint32 feeShare;
    address royaltyReceiver;
    uint32 royaltyRate;
}
