// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { License } from "./types/PackageTypes.sol";
import { Payee, ProductEconomics, WorkTerms } from "./types/EconomicsTypes.sol";

/// @title IEconomicsResolver
/// @notice The governed economics every product reads (ADR 0001 sections 5, 7 and 8): the
///         network fee and royalty rate for new works, the terms a work locks at mint, the
///         currency a sale starting now must lock, and each product's default license.
/// @dev Products are `PRODUCT_STREAM`, `PRODUCT_EDITIONS` and `PRODUCT_FEDERATED`. The currency
///      allowlist, per-currency increment floors and default currencies live in the economics
///      lane's `IAssetAllowlist`, which this resolver reads; split wallet addresses come from
///      its `ISplitFactory`. Changes apply to works and sales that start afterwards only: works
///      lock their terms at mint and sales lock their currency at start. Every setter is
///      governed, non-payable and compare-and-set, and emits the old and new values.
interface IEconomicsResolver is IERC165 {
    /// @notice A product's economics changed.
    event EconomicsSet(bytes32 indexed product, ProductEconomics previous, ProductEconomics next);
    /// @notice A product's default license changed.
    event DefaultLicenseSet(bytes32 indexed product, License previous, License next);

    /// @notice The currency is not active in the asset allowlist.
    error CurrencyNotAllowed(address currency);
    /// @notice The product has no economics configured.
    error UnknownProduct(bytes32 product);
    /// @notice A compare-and-set setter's expected current value is stale.
    error ExpectedValueMismatch();

    /// @notice The terms a new work of `product` locks at mint, for the artist-portion payees of
    ///         its package item. Both wallets are predicted CREATE2 addresses; nothing is
    ///         deployed, so the auction start stays within its gas budget; a zero fee share omits
    ///         the fee payee. Reverts for a payee list the split factory would not accept.
    function newWorkTerms(bytes32 product, Payee[] calldata payees)
        external
        view
        returns (WorkTerms memory);

    /// @notice The currency a sale of `product` starting now must lock: `requested` itself, or
    ///         the product's default for `CURRENCY_DEFAULT`. Reverts with `CurrencyNotAllowed`
    ///         unless the result is active.
    function resolveCurrency(bytes32 product, address requested) external view returns (address);

    /// @notice A product's economics.
    function economics(bytes32 product) external view returns (ProductEconomics memory);
    /// @notice A product's default license for new packages (CC0 at launch).
    function defaultLicense(bytes32 product) external view returns (License memory);
    /// @notice The economics lane's asset allowlist (immutable).
    function assetAllowlist() external view returns (address);
    /// @notice The economics lane's split factory (immutable).
    function splitFactory() external view returns (address);

    /// @notice Sets a product's economics. FUNDS_SETTER role.
    function setEconomics(
        bytes32 product,
        ProductEconomics calldata expected,
        ProductEconomics calldata next
    ) external;
    /// @notice Sets a product's default license. PARAMETER_SETTER role.
    function setDefaultLicense(bytes32 product, License calldata expected, License calldata next)
        external;
}
