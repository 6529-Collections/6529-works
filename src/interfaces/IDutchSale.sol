// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISaleAdapter } from "./ISaleAdapter.sol";
import { LockedTerms, Payment } from "./types/SaleTypes.sol";

/// @title IDutchSale
/// @notice The shared descending-price adapter (ADR 0001 sections 5 and 6), for 6529 Editions and
///         future federated contracts.
/// @dev The schedule comes from the token's terms: the starting price is `PrimaryTerms.price`
///      and the curve is `abi.decode(PrimaryTerms.params, (DutchParams))`; the sale only fixes the
///      start time. At most one sale per `(token, id)` is open at a time. Each purchase charges
///      exactly the current price times the quantity, which must not exceed `maxUnitPrice` per
///      copy; `payment.amount` is the most the payer will pay, ERC-20s are pulled for the exact
///      charge only, and ETH overpayment is credited back. There is no rebate when the price
///      later falls. `saleKind()` is `SaleKind.DUTCH`; PERMIT2 purchases use
///      `Typehashes.DUTCH_PURCHASE_WITNESS`.
interface IDutchSale is ISaleAdapter {
    /// @notice A sale's schedule.
    struct Schedule {
        uint256 restingPrice;
        uint64 startTime;
        uint64 duration;
        uint64 stepSeconds;
    }

    /// @notice A sale was closed: it sells no more, and a new sale of its token may open.
    /// @param saleId The closed sale.
    event SaleClosed(uint256 indexed saleId);

    /// @notice The sale has not started or is closed.
    error SaleNotOpen(uint256 saleId);
    /// @notice The current unit price is above the buyer's limit.
    error PriceAboveLimit(uint256 price, uint256 maxUnitPrice);
    /// @notice The start time is in the past, or the token's curve is invalid.
    error InvalidSchedule();

    /// @notice Opens a Dutch sale of token `id` starting at `startTime` (not in the past).
    ///         Callable by the creator or the PLATFORM role; PLATFORM only for a listed edition
    ///         of FIXED size (an OPEN edition's one-time window is the artist's, MARKET-6).
    /// @param token A token contract this adapter serves (`isTarget`), with DUTCH terms.
    /// @param id The token ID to sell (an edition ID for 6529 Editions).
    /// @param startTime When purchases open and the price starts to fall, in seconds since the
    ///        epoch.
    /// @return saleId The new sale's ID (sale IDs start at 1).
    function openSale(address token, uint256 id, uint64 startTime) external returns (uint256 saleId);
    /// @notice Closes a sale. Callable by the creator; by the PLATFORM role for a sale it opened,
    ///         or for any sale while the creator resolves to zero (a pending recovery override,
    ///         MARKET-6).
    /// @param saleId The open sale to close.
    function closeSale(uint256 saleId) external;
    /// @notice Buys `quantity` copies for `recipient` (the payer when zero) at the current price.
    /// @param saleId The sale to buy from.
    /// @param recipient Who receives the copies; zero for the payer.
    /// @param quantity The number of copies, at least one.
    /// @param maxUnitPrice The highest unit price the buyer accepts, in the currency's base units
    ///        (wei for ETH); a higher current price reverts with `PriceAboveLimit`.
    /// @param payment How the payer pays; `amount` is the most it will pay, and for ETH the
    ///        amount above the charge is credited to the payer.
    function purchase(
        uint256 saleId,
        address recipient,
        uint256 quantity,
        uint256 maxUnitPrice,
        Payment calldata payment
    ) external payable;

    /// @notice The unit price now.
    /// @param saleId An existing sale.
    /// @return The unit price in the sale's currency's base units, on the curve moved by
    ///        `scheduleDelay(saleId)`.
    function currentPrice(uint256 saleId) external view returns (uint256);
    /// @notice A sale's locked terms (`price` is the starting price), schedule and closed flag.
    /// @param saleId An existing sale.
    /// @return terms The terms locked when the sale opened.
    /// @return schedule The curve as configured at open, without `scheduleDelay`.
    /// @return closed Whether the sale was closed.
    function sale(uint256 saleId)
        external
        view
        returns (LockedTerms memory terms, Schedule memory schedule, bool closed);
    /// @notice The open sale of `(token, id)`, or zero.
    /// @param token The token contract.
    /// @param id The token ID.
    /// @return saleId The open sale's ID; zero when no sale of `(token, id)` is open.
    function openSaleOf(address token, uint256 id) external view returns (uint256 saleId);
    /// @notice Seconds the sale's start and price curve have moved since it opened: the
    ///         adapter's pauses and its currency's deprecations since then, running ones
    ///         included (MARKET-1). Overlapping halts count twice. Reverts for an unknown sale.
    /// @param saleId An existing sale.
    /// @return The delay in seconds.
    function scheduleDelay(uint256 saleId) external view returns (uint256);
}
