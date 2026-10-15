// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISaleAdapter } from "./ISaleAdapter.sol";

/// @title IMintSale
/// @notice The errors only the adapters that mint at purchase raise: 6529 Editions' fixed-price
///         and Dutch sales (`MintSaleBase`). The English auction, which mints at start, never
///         raises them, so they are not on `ISaleAdapter`.
/// @dev Errors only. It declares no function, so its ERC-165 interface ID is zero and no adapter
///      reports it; `IFixedPriceSale` and `IDutchSale` extend it.
interface IMintSale is ISaleAdapter {
    /// @notice A sale of this token is already open.
    error SaleAlreadyOpen(address token, uint256 id);
    /// @notice The caller is neither the token's creator nor the PLATFORM role.
    error NotSaleManager(address caller);
    /// @notice A required address is zero.
    error InvalidAddress();
    /// @notice A priced sale must name its currency; `CURRENCY_DEFAULT` is for gifts only.
    error PricedDefaultCurrency(address token, uint256 id);
    /// @notice The resolver returned another currency than the one the token named.
    error CurrencyMismatch(address named, address resolved);
    /// @notice The locked currency is no longer active on the asset allowlist (the auction
    ///         reports `IAssetAllowlist.AssetNotActive` instead).
    error CurrencyNotActive(address currency);
    /// @notice A purchase must buy at least one copy.
    error InvalidQuantity();
    /// @notice The sale is already closed.
    error SaleAlreadyClosed(uint256 saleId);
    /// @notice PLATFORM opened, without the artist's approval, a sale only the artist may
    ///         configure: an edition with a one-time window (OPEN), or a token that is not a
    ///         listed 6529 Editions edition.
    error ArtistApprovalRequired(address token, uint256 id);
}
