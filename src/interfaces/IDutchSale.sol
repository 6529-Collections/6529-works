// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISaleAdapter } from "./ISaleAdapter.sol";
import { Payment } from "./types/SaleTypes.sol";

/// @title IDutchSale
/// @notice The shared descending-price adapter (ADR 0001 sections 5 and 6), for 6529 Editions and
///         future federated contracts.
/// @dev The schedule comes from the token's terms: the starting price is `PrimaryTerms.price`
///      and the curve is `abi.decode(PrimaryTerms.params, (DutchParams))`; the sale only fixes the
///      start time. Each purchase pays the current price, at most `maxUnitPrice` per copy; for
///      ETH any excess over the charge is credited to the payer. There is no rebate when the
///      price later falls. `saleKind()` is `SaleKind.DUTCH`.
interface IDutchSale is ISaleAdapter {
    /// @notice A sale's locked terms and schedule.
    struct DutchSale {
        address token;
        uint256 id;
        address currency;
        uint256 startPrice;
        uint256 restingPrice;
        uint64 startTime;
        uint64 duration;
        uint64 stepSeconds;
        address seller;
        address feeRecipient;
        uint32 feeShare;
        address creator;
        bool closed;
    }

    /// @notice A sale was closed before its supply ran out.
    event SaleClosed(uint256 indexed saleId);

    /// @notice The sale has not started or is closed.
    error SaleNotOpen(uint256 saleId);
    /// @notice The current unit price is above the buyer's limit.
    error PriceAboveLimit(uint256 price, uint256 maxUnitPrice);
    /// @notice The caller is neither the token's creator nor the PLATFORM role.
    error NotSaleManager(address caller);

    /// @notice Opens a Dutch sale of token `id` starting at `startTime` (not in the past).
    ///         Callable by the lead artist (the terms' `creator`) or the PLATFORM role.
    function openSale(address token, uint256 id, uint64 startTime) external returns (uint256 saleId);

    /// @notice Closes a sale. Callable by the creator or the PLATFORM role.
    function closeSale(uint256 saleId) external;

    /// @notice Buys `quantity` copies for `recipient` (the payer when zero) at the current price.
    function purchase(
        uint256 saleId,
        address recipient,
        uint256 quantity,
        uint256 maxUnitPrice,
        Payment calldata payment
    ) external payable;

    /// @notice The unit price now.
    function currentPrice(uint256 saleId) external view returns (uint256);
    /// @notice A sale's locked terms and schedule.
    function sale(uint256 saleId) external view returns (DutchSale memory);
}
