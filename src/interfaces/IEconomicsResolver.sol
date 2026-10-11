// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { License } from "./types/PackageTypes.sol";
import { CurrencyConfig, ProductEconomics, WorkTerms } from "./types/EconomicsTypes.sol";

/// @title IEconomicsResolver
/// @notice The governed economics every product reads (ADR 0001 sections 5, 7 and 8): the
///         primary split and royalty rate for new works, the currency allowlist with per-currency
///         increment floors, each product's default currency, and each product's default
///         license.
/// @dev A product is identified by its token contract address (6529 Stream, 6529 Editions).
///      Changes apply to works and sales that start afterwards only: works lock their terms at
///      mint and sales lock their currency at start. Every setter is governed, non-payable and
///      compare-and-set, and emits the old and new values.
interface IEconomicsResolver {
    /// @notice A product's economics changed.
    event EconomicsSet(address indexed product, ProductEconomics previous, ProductEconomics next);
    /// @notice A currency's configuration changed.
    event CurrencySet(address indexed currency, CurrencyConfig previous, CurrencyConfig next);
    /// @notice A product's default currency changed.
    event DefaultCurrencySet(address indexed product, address previous, address next);
    /// @notice A product's default license changed.
    event DefaultLicenseSet(address indexed product, License previous, License next);

    /// @notice The currency is not ACTIVE.
    error CurrencyNotAllowed(address currency);
    /// @notice The product has no economics configured.
    error UnknownProduct(address product);
    /// @notice A split wallet the terms need is not deployed.
    error SplitNotDeployed(bytes32 splitId);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();

    /// @notice The terms a new work of `product` locks at mint, for the artist-portion split
    ///         `artistSplitId`. Reverts if a wallet is not deployed.
    function newWorkTerms(address product, bytes32 artistSplitId)
        external
        view
        returns (WorkTerms memory);

    /// @notice The currency a sale of `product` starting now must lock: `requested` itself, or
    ///         the product's default for `CURRENCY_DEFAULT`. Reverts with `CurrencyNotAllowed`
    ///         unless the result is ACTIVE.
    function resolveCurrency(address product, address requested) external view returns (address);

    /// @notice A product's economics.
    function economics(address product) external view returns (ProductEconomics memory);
    /// @notice A currency's configuration.
    function currency(address token) external view returns (CurrencyConfig memory);
    /// @notice A product's default currency.
    function defaultCurrency(address product) external view returns (address);
    /// @notice A product's default license for new packages (CC0 at launch).
    function defaultLicense(address product) external view returns (License memory);
    /// @notice The split factory whose wallets the terms name (immutable).
    function splitFactory() external view returns (address);

    /// @notice Sets a product's economics. FUNDS_SETTER role.
    function setEconomics(
        address product,
        ProductEconomics calldata expected,
        ProductEconomics calldata next
    ) external;
    /// @notice Admits, changes or deprecates a currency. PARAMETER_SETTER role.
    ///         Only standard ERC-20s are admitted: a value-returning transfer, no fee, no rebase.
    function setCurrency(
        address token,
        CurrencyConfig calldata expected,
        CurrencyConfig calldata next
    ) external;
    /// @notice Sets a product's default currency, which must be ACTIVE.
    ///         PARAMETER_SETTER role.
    function setDefaultCurrency(address product, address expected, address next) external;
    /// @notice Sets a product's default license. PARAMETER_SETTER role.
    function setDefaultLicense(address product, License calldata expected, License calldata next)
        external;
}
