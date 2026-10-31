// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SaleKind
/// @notice Sale-kind labels carried by package sale terms and reported by each sale adapter
///         (ADR 0001 section 5 "Sale extensibility"). A kind is a `bytes32` label so a new
///         adapter needs no change to Core or to the package format.
/// @dev Constants only; nothing here is linked bytecode.
///      Adding a sale method (ADR 0005, owner decision 14) needs no new token contract: a new
///      adapter claims a fresh label, `keccak256("<NAME>")`, and reports it from
///      `ISaleAdapter.saleKind()`; packages approved afterwards name it in their terms; and
///      governance admits the adapter on each token it may mint (`IMintTarget.setAdmittedMinter`,
///      30-day class). A token mints only for an admitted adapter whose kind equals the terms'
///      kind, so no label is reserved to one adapter forever and no token hard-wires one minter.
///      Labels are never reused for a different method. FIXED_PRICE and DUTCH name rc.1's
///      adapters, which ADR 0005 removes; FIXED_PRICE stays reserved for a restored fixed-price
///      sale.
library SaleKind {
    /// @notice The English auction: 6529 Stream's only primary sale.
    bytes32 internal constant ENGLISH_AUCTION = keccak256("ENGLISH_AUCTION");
    /// @notice rc.1's fixed-price sale, removed by ADR 0005; reserved for a restored
    ///         fixed-price adapter.
    bytes32 internal constant FIXED_PRICE = keccak256("FIXED_PRICE");
    /// @notice rc.1's descending-price sale, removed by ADR 0005.
    bytes32 internal constant DUTCH = keccak256("DUTCH");
    /// @notice The uniform-price edition auction (`IUniformEditionAuction`, ADR 0005): one
    ///         auction per edition decides how many copies exist and their one price.
    bytes32 internal constant UNIFORM_AUCTION = keccak256("UNIFORM_AUCTION");
}

/// @notice How a buyer or bidder pays (ADR 0001 section 5 "Asset admission").
/// @dev DIRECT: ETH sent as `msg.value`, or an ERC-20 the payer approved beforehand.
///      PERMIT: an EIP-2612 permit (`signature` is the 65-byte `r || s || v`), then a pull.
///      PERMIT2: a Permit2 `permitWitnessTransferFrom` whose witness (see `Typehashes`) binds the
///      action, so a relayer can submit it for the payer (the signed payment intent).
enum PaymentMethod {
    DIRECT,
    PERMIT,
    PERMIT2
}

/// @notice One payment, pulled with an exact balance-delta check.
/// @dev `amount` is the exact amount of a bid; a sale method that charges a price only known
///      at execution defines it as the most the payer will pay. For DIRECT and PERMIT, `payer`
///      must be `msg.sender`; for PERMIT2 it is
///      the signer and may differ from `msg.sender`. ETH uses DIRECT with `msg.value == amount`.
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

/// @notice What a token contract tells a sale adapter about a primary sale.
/// @dev Returned by `IMintTarget.mint` and `IMintTarget.primaryTerms` (which, for a minted 6529
///      Stream token, sets only the sale kind, seller, fee and creator; 6529 Stream Editions'
///      `mint` sets only the sale kind). `currency` is the item's or edition's currency as
///      approved: for a 6529 Stream item `CURRENCY_ETH`, an allowlisted ERC-20 or
///      `CURRENCY_DEFAULT`, which the auction resolves (`IEconomicsResolver.resolveCurrency`) and
///      locks when the sale starts; for an edition, the sale method's own, opaque to the token
///      (the edition auction accepts only ETH). `price` is zero: an English auction has none,
///      and `EditionTerms` carries none (a priced sale method keeps its price in `params`).
///      `params` are the sale method's, as approved. `seller` receives the artist portion (a
///      split wallet's predicted CREATE2 address, which may not be deployed), `feeRecipient` the
///      network portion, `feeShare` out of `Splits.DENOMINATOR` (100,000). `creator` is the lead
///      artist's active authority, resolved through the artist registry when the terms are read.
///      It is zero while a recovery override is pending (`IArtistRegistry.activeAuthorityOf`).
///      Under ADR 0005 an unbid 6529 Stream work goes to the 6529 Network Museum
///      (`IEconomicsResolver.museum`); only a federated work's creator receives an unbid token.
struct PrimaryTerms {
    bytes32 saleKind;
    address currency;
    uint256 price;
    bytes params;
    address seller;
    address feeRecipient;
    uint32 feeShare;
    address creator;
}

/// @notice The terms a sale adapter locks for one sale, in the same shape in every adapter.
/// @dev `id` is the token ID (an edition ID for 6529 Stream Editions). `price` is zero for the
///      English auction; another sale method defines its own.
struct LockedTerms {
    address token;
    uint256 id;
    address currency;
    uint256 price;
    address seller;
    address feeRecipient;
    uint32 feeShare;
}
