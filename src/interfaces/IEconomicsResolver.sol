// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { License } from "./types/PackageTypes.sol";
import { ISplitWallet } from "../economics/interfaces/ISplitWallet.sol";
import { ProductEconomics, WorkTerms } from "./types/EconomicsTypes.sol";

/// @title IEconomicsResolver
/// @notice The governed economics every product reads (ADR 0001 sections 5, 7 and 8): the
///         network fee and royalty rate for new works, the terms a work locks at mint, the
///         currency a sale starting now must lock, and each product's default license.
/// @dev Products are `PRODUCT_STREAM`, `PRODUCT_EDITIONS` and `PRODUCT_FEDERATED`. The currency
///      allowlist, per-currency increment floors and default currencies live in the economics
///      lane's `IAssetAllowlist`, which this resolver reads; split wallet addresses come from
///      its `ISplitFactory`. Changes apply to works and sales that start afterwards only: works
///      lock their terms at mint and sales lock their currency at start. Every setter is
///      governed, non-payable and compare-and-set on a revision counter that each change to the
///      same setting bumps (fee terms, royalty rate and license count separately), so a queued
///      operation never applies to a later state that merely looks the same.
interface IEconomicsResolver is IERC165 {
    /// @notice A product's economics changed; the changed setting's revision is now `revision`.
    event EconomicsSet(
        bytes32 indexed product, ProductEconomics previous, ProductEconomics next, uint64 revision
    );
    /// @notice A product's default license changed; its revision is now `revision`.
    event DefaultLicenseSet(
        bytes32 indexed product, License previous, License next, uint64 revision
    );

    /// @notice The currency is not active in the asset allowlist.
    error CurrencyNotAllowed(address currency);
    /// @notice The product has no economics configured.
    error UnknownProduct(bytes32 product);
    /// @notice Compare-and-set failed: the setting is at revision `actual`, not `expected`.
    error RevisionMismatch(uint64 expected, uint64 actual);
    /// @notice A fee share of 100,000 or more, a royalty rate above 100,000, or a zero fee
    ///         recipient for a non-zero fee share.
    error InvalidEconomics();
    /// @notice An empty, over-long or non-`[A-Za-z0-9.+-]` SPDX ID, or a zero text file ID.
    error InvalidLicense();
    /// @notice The asset allowlist or split factory has no code or is EIP-7702 delegated.
    error InvalidDependency(address dependency);
    /// @notice `recipient` cannot take the network fee: it is the resolver itself, its asset
    ///         allowlist or split factory, or a protocol contract that cannot accept a payment
    ///         (the revenue escrow, the claim router, a sale adapter or a mint target).
    error InvalidFeeRecipient(address recipient);

    /// @notice The terms a new work of `product` locks at mint, for the artist-portion payees of
    ///         its package item. Both wallets are predicted CREATE2 addresses; nothing is
    ///         deployed, so the auction start stays within its gas budget; a zero fee share omits
    ///         the fee payee. Reverts for a payee list the split factory would not accept.
    /// @dev The one derivation 6529 Stream, 6529 Editions and this resolver share, with `factory`
    ///      the economics lane's `ISplitFactory` and `D` = 100,000:
    ///      - `seller = factory.walletFor(payees, bytes32(0))`;
    ///      - if `feeShare == 0`, `royaltyReceiver = seller` (no wallet);
    ///      - otherwise `royaltyReceiver = factory.walletFor(list, bytes32(0))`, where `list` is the
    ///        two fixed payees `(seller, D - feeShare)` and `(feeRecipient, feeShare)` sorted
    ///        ascending by account, exactly `Splits.royaltyPayees(seller, feeRecipient, feeShare)`.
    ///      A contract that stores only `seller` and the fee terms re-derives the receiver this
    ///      way and gets the same address.
    function newWorkTerms(bytes32 product, ISplitWallet.Payee[] calldata payees)
        external
        view
        returns (WorkTerms memory);

    /// @notice The currency a sale of `product` starting now must lock: `requested` itself, or
    ///         the product's default for `CURRENCY_DEFAULT`. Reverts with `CurrencyNotAllowed`
    ///         unless the result is active.
    function resolveCurrency(bytes32 product, address requested) external view returns (address);

    /// @notice A product's economics.
    function economics(bytes32 product) external view returns (ProductEconomics memory);
    /// @notice A product's network fee recipient (`economics(product).feeRecipient`).
    function networkFeeRecipient(bytes32 product) external view returns (address);
    /// @notice A product's default license for new packages (CC0 at launch).
    function defaultLicense(bytes32 product) external view returns (License memory);
    /// @notice The revisions the setters compare: fee terms, royalty rate and license.
    function revisions(bytes32 product)
        external
        view
        returns (uint64 feeTerms, uint64 royaltyRate, uint64 license);
    /// @notice The economics lane's asset allowlist (immutable).
    function assetAllowlist() external view returns (address);
    /// @notice The economics lane's split factory (immutable).
    function splitFactory() external view returns (address);

    /// @notice Sets a product's network fee recipient and fee share for new works. FUNDS_SETTER
    ///         role (14 days). Reverts with {InvalidFeeRecipient} for a recipient that could
    ///         never be paid: a work locks its fee recipient at mint, so such a recipient would
    ///         make every sale of every work minted under it unsettleable.
    function setFeeTerms(
        bytes32 product,
        uint64 expectedRevision,
        address feeRecipient,
        uint32 feeShare
    ) external;
    /// @notice Sets a product's royalty rate for new works. PARAMETER_SETTER role (48 hours).
    function setRoyaltyRate(bytes32 product, uint64 expectedRevision, uint32 royaltyRate) external;
    /// @notice Sets a product's default license for new packages. PARAMETER_SETTER role
    ///         (48 hours).
    function setDefaultLicense(bytes32 product, uint64 expectedRevision, License calldata next)
        external;
}
