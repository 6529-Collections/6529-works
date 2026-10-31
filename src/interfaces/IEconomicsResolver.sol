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
///      allowlist, per-currency increment floors and default currencies live in the
///      `IAssetAllowlist`, which this resolver reads; split wallet addresses come from
///      its `ISplitFactory`. Changes apply to works and sales that start afterwards only: works
///      lock their terms at mint and sales lock their currency at start. Every setter is
///      governed, non-payable and compare-and-set on a revision counter that each change to the
///      same setting bumps (fee terms, royalty rate and license count separately), so a queued
///      operation never applies to a later state that merely looks the same.
interface IEconomicsResolver is IERC165 {
    /// @notice A product's economics changed; the changed setting's revision is now `revision`.
    /// @param product The product identifier.
    /// @param previous The economics before the change; all zero at deployment.
    /// @param next The economics after the change.
    /// @param revision The fee-terms or royalty-rate revision after the change; 1 at deployment,
    ///        when one event sets both.
    event EconomicsSet(
        bytes32 indexed product, ProductEconomics previous, ProductEconomics next, uint64 revision
    );
    /// @notice A product's default license changed; its revision is now `revision`.
    /// @param product The product identifier.
    /// @param previous The license before the change; empty at deployment.
    /// @param next The license after the change.
    /// @param revision The product's license revision after the change; 1 at deployment.
    event DefaultLicenseSet(
        bytes32 indexed product, License previous, License next, uint64 revision
    );
    /// @notice The 6529 Network Museum's address changed; its revision is now `revision`
    ///         (ADR 0005).
    /// @param previous The museum before the change; zero at deployment.
    /// @param next The museum after the change.
    /// @param revision The museum revision after the change; 1 at deployment.
    event MuseumSet(address previous, address next, uint64 revision);

    /// @notice The currency is not active in the asset allowlist.
    error CurrencyNotAllowed(address currency);
    /// @notice The product has no economics configured.
    error UnknownProduct(bytes32 product);
    /// @notice Compare-and-set failed: the setting is at revision `actual`, not `expected`.
    error RevisionMismatch(uint64 expected, uint64 actual);
    /// @notice A fee share of 100,000 or more, a royalty rate above 100,000, or a zero fee
    ///         recipient for a non-zero fee share.
    error InvalidEconomics();
    /// @notice An empty, over-long or non-`[A-Za-z0-9.+-]` SPDX ID, a zero text file ID, or a
    ///         CC0 license (by key) whose text is not the CC0 text the resolver was deployed with.
    error InvalidLicense();
    /// @notice `recipient` cannot take the network fee: it is the resolver itself, its asset
    ///         allowlist, split factory or release verifier, or a protocol contract that cannot
    ///         accept a payment (the revenue escrow, the claim router, a sale adapter, a mint
    ///         target, the artist or package registry, or the work records).
    error InvalidFeeRecipient(address recipient);
    /// @notice `museum` cannot hold the network's works: zero, or a protocol contract that
    ///         cannot take an ERC-721 for the network (the resolver itself, a sale adapter, a
    ///         token contract, a registry, the revenue escrow or the claim router).
    error InvalidMuseum(address museum);

    /// @notice The terms a new work of `product` locks at mint, for the artist-portion payees of
    ///         its package item. Both wallets are predicted CREATE2 addresses; nothing is
    ///         deployed, so the auction start stays within its gas budget; a zero fee share omits
    ///         the fee payee. Reverts for a payee list the split factory would not accept.
    /// @dev The one derivation 6529 Stream, 6529 Stream Editions and this resolver share, with
    ///      `factory` the `ISplitFactory` and `D` = 100,000:
    ///      - `seller = factory.walletFor(payees, bytes32(0))`;
    ///      - if `feeShare == 0`, `royaltyReceiver = seller` (no wallet);
    ///      - otherwise `royaltyReceiver = factory.walletFor(list, bytes32(0))`, where `list` is
    ///        the two fixed payees `(seller, D - feeShare)` and `(feeRecipient, feeShare)` sorted
    ///        ascending by account, exactly `Splits.royaltyPayees(seller, feeRecipient, feeShare)`.
    ///      A contract that stores only `seller` and the fee terms re-derives the receiver this
    ///      way and gets the same address.
    /// @param product The product identifier; reverts with {UnknownProduct} if not configured.
    /// @param payees The canonical artist-portion payee list of the work's package item.
    /// @return The seller wallet, fee terms, royalty receiver and royalty rate the work locks.
    function newWorkTerms(bytes32 product, ISplitWallet.Payee[] calldata payees)
        external
        view
        returns (WorkTerms memory);

    /// @notice The currency a sale of `product` starting now must lock: `requested` itself, or
    ///         the product's default for `CURRENCY_DEFAULT`. Reverts with `CurrencyNotAllowed`
    ///         unless the result is active.
    /// @param product The product identifier; reverts with {UnknownProduct} if not configured.
    /// @param requested The currency the sale names (ETH is `address(0)`), or `CURRENCY_DEFAULT`.
    /// @return The active currency the sale locks; never `CURRENCY_DEFAULT`.
    function resolveCurrency(bytes32 product, address requested) external view returns (address);

    /// @notice A product's economics.
    /// @param product The product identifier; reverts with {UnknownProduct} if not configured.
    /// @return The fee recipient, fee share and royalty rate new works lock, both rates out of
    ///        100,000.
    function economics(bytes32 product) external view returns (ProductEconomics memory);
    /// @notice A product's network fee recipient (`economics(product).feeRecipient`).
    /// @param product The product identifier; reverts with {UnknownProduct} if not configured.
    /// @return The fee recipient; zero only while the fee share is zero.
    function networkFeeRecipient(bytes32 product) external view returns (address);
    /// @notice A product's default license for new packages (CC0 at launch).
    /// @param product The product identifier; reverts with {UnknownProduct} if not configured.
    /// @return The license's SPDX ID and the content store file ID of its text.
    function defaultLicense(bytes32 product) external view returns (License memory);
    /// @notice The revisions the setters compare: fee terms, royalty rate and license.
    /// @param product The product identifier; reverts with {UnknownProduct} if not configured.
    /// @return feeTerms The revision {setFeeTerms} compares.
    /// @return royaltyRate The revision {setRoyaltyRate} compares.
    /// @return license The revision {setDefaultLicense} compares.
    function revisions(bytes32 product)
        external
        view
        returns (uint64 feeTerms, uint64 royaltyRate, uint64 license);
    /// @notice The asset allowlist (immutable).
    /// @return The `IAssetAllowlist` this resolver reads currencies from.
    function assetAllowlist() external view returns (address);
    /// @notice The split factory (immutable).
    /// @return The `ISplitFactory` this resolver predicts wallet addresses with.
    function splitFactory() external view returns (address);
    /// @notice The 6529 Network Museum (ADR 0005; 6529chain D140): the network-held account
    ///         that receives a 6529 Stream work whose 1/1 auction drew no bids, or that ended
    ///         unsold after its currency stayed deprecated for 30 days. The English auction reads
    ///         it at settlement; a federated work goes to its artist instead. Set at deployment
    ///         (revision 1) and never zero.
    /// @return The museum's address.
    function museum() external view returns (address);
    /// @notice The revision `setMuseum` compares.
    /// @return The museum revision: 1 at deployment, bumped by every change.
    function museumRevision() external view returns (uint64);

    /// @notice Sets a product's network fee recipient and fee share for new works. FUNDS_SETTER
    ///         role (14 days). Reverts with {InvalidFeeRecipient} for a recipient that could
    ///         never be paid: a work locks its fee recipient at mint, so such a recipient would
    ///         make every sale of every work minted under it unsettleable.
    /// @param product The product identifier; reverts with {UnknownProduct} if not configured.
    /// @param expectedRevision The fee-terms revision the product must be at.
    /// @param feeRecipient The new network fee recipient; non-zero unless `feeShare` is zero.
    /// @param feeShare The network share of primary sales and royalties, out of 100,000; below
    ///        100,000, and zero omits the fee payee.
    function setFeeTerms(
        bytes32 product,
        uint64 expectedRevision,
        address feeRecipient,
        uint32 feeShare
    ) external;
    /// @notice Sets a product's royalty rate for new works. PARAMETER_SETTER role (48 hours).
    /// @param product The product identifier; reverts with {UnknownProduct} if not configured.
    /// @param expectedRevision The royalty-rate revision the product must be at.
    /// @param royaltyRate The ERC-2981 royalty rate, out of 100,000; at most 100,000.
    function setRoyaltyRate(bytes32 product, uint64 expectedRevision, uint32 royaltyRate) external;
    /// @notice Sets a product's default license for new packages. PARAMETER_SETTER role
    ///         (48 hours). A CC0 license must name the deployment's CC0 text, as
    ///         `IWorkRecords.openRecord` requires.
    /// @param product The product identifier; reverts with {UnknownProduct} if not configured.
    /// @param expectedRevision The license revision the product must be at.
    /// @param next The new license: a non-empty SPDX ID of `[A-Za-z0-9.+-]` characters, at most
    ///        `Limits.MAX_LICENSE_ID_BYTES` bytes, and a non-zero text file ID.
    function setDefaultLicense(bytes32 product, uint64 expectedRevision, License calldata next)
        external;
    /// @notice Sets the 6529 Network Museum for settlements from now on. FUNDS_SETTER role
    ///         (14 days, the network-level recipients class), compare-and-set on the museum
    ///         revision. Reverts with {InvalidMuseum} for an address that could never hold the
    ///         network's works; the runbook also requires an existing account that accepts
    ///         ERC-721 tokens (a Safe). A work already delivered or pending for the previous
    ///         museum stays with it.
    /// @param expectedRevision The museum revision the resolver must be at.
    /// @param next The new museum: nonzero, and not a protocol contract.
    function setMuseum(uint64 expectedRevision, address next) external;
}
