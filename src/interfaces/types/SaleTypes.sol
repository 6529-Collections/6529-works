// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SaleKind
/// @notice Sale-kind labels carried by package sale terms and reported by each sale adapter
///         (ADR 0001 section 5 "Sale extensibility"). A kind is a `bytes32` label so a new
///         adapter needs no change to Core or to the package format.
/// @dev Constants only; nothing here is linked bytecode.
library SaleKind {
    /// @notice The English auction: 6529 Stream's only primary sale.
    bytes32 internal constant ENGLISH_AUCTION = keccak256("ENGLISH_AUCTION");
    /// @notice Fixed price with optional allowlist phases (6529 Editions).
    bytes32 internal constant FIXED_PRICE = keccak256("FIXED_PRICE");
    /// @notice Descending price (6529 Editions).
    bytes32 internal constant DUTCH = keccak256("DUTCH");
}

/// @notice How a buyer or bidder pays (ADR 0001 section 5 "Asset admission").
/// @dev DIRECT: ETH sent as `msg.value`, or an ERC-20 the payer approved beforehand.
///      PERMIT: an EIP-2612 permit (`signature` is the 65-byte `r || s || v`), then a pull.
///      PERMIT2: a Permit2 `permitWitnessTransferFrom`, whose witness binds the exact action, so
///      a relayer can submit it for the payer (the signed payment intent).
enum PaymentMethod {
    DIRECT,
    PERMIT,
    PERMIT2
}

/// @notice One payment. Adapters pull exactly `amount` and check the exact balance delta.
/// @dev For DIRECT and PERMIT, `payer` must be `msg.sender`; for PERMIT2 it is the signer and
///      may differ from `msg.sender`. ETH payments use DIRECT with `msg.value == amount`.
///      `deadline` and `signature` are the permit's; `nonce` is the Permit2 nonce (zero
///      otherwise). The payer is the bidder or buyer of record: refunds and credits go to it.
struct Payment {
    PaymentMethod method;
    address payer;
    uint256 amount;
    uint256 deadline;
    uint256 nonce;
    bytes signature;
}

/// @notice What a token contract tells a sale adapter about one primary sale.
/// @dev Returned by `IMintTarget.mint` and previewed by `IMintTarget.primaryTerms`. Adapters
///      lock these values when a sale starts (ADR 0001 section 5 "Each sale locks its currency
///      when it starts"). `currency` is already resolved: `CURRENCY_ETH` or an active allowlisted
///      ERC-20, never `CURRENCY_DEFAULT`. `price` is the unit price for FIXED_PRICE, the starting
///      price for DUTCH and zero for ENGLISH_AUCTION (whose opening bid is governed). `seller`
///      receives the artist portion (the work's split wallet, a predicted CREATE2 address
///      that may not be deployed yet), `feeRecipient` the network
///      portion, `feeShare` out of `SHARE_DENOMINATOR`. `creator` is the lead artist's current
///      authority: it receives an auction token that drew no bids and may schedule edition
///      sales. `revealPending` is true while a VRF seed is outstanding; no bid or purchase is
///      accepted until it is delivered.
struct PrimaryTerms {
    bytes32 saleKind;
    address currency;
    uint256 price;
    bytes params;
    address seller;
    address feeRecipient;
    uint32 feeShare;
    address creator;
    bool revealPending;
}

/// @notice The `params` of a DUTCH sale: `abi.encode(DutchParams)` (ADR 0001 section 5).
/// @dev The price starts at the edition `price` and falls to `restingPrice` over `duration`
///      seconds, linearly when `stepSeconds` is zero, otherwise in equal drops every
///      `stepSeconds`; it then rests. `restingPrice` is at most the starting price.
struct DutchParams {
    uint256 restingPrice;
    uint64 duration;
    uint64 stepSeconds;
}
