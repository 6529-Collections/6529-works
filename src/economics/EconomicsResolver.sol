// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import {
    CURRENCY_DEFAULT,
    PRODUCT_EDITIONS,
    PRODUCT_FEDERATED,
    PRODUCT_STREAM,
    ProductEconomics,
    WorkTerms
} from "../interfaces/types/EconomicsTypes.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { License } from "../interfaces/types/PackageTypes.sol";
import { IAssetAllowlist } from "./interfaces/IAssetAllowlist.sol";
import { ISplitFactory } from "./interfaces/ISplitFactory.sol";
import { ISplitWallet } from "./interfaces/ISplitWallet.sol";
import { Splits } from "./Splits.sol";

/// @title EconomicsResolver
/// @notice The network's governed economics for new works (ADR 0001 sections 2, 5, 7 and 8).
///         Launch defaults: 6529 Stream and 6529 Editions pay 75% to the artist portion and 25%
///         to the network; 6529 Stream Federated pays 90/10; the royalty rate is 6.529% (6,529
///         out of 100,000); the default license is CC0. Currencies come from the asset allowlist.
/// @dev Changes apply to new works only: a work locks its terms (seller wallet, fee terms,
///      royalty receiver and rate) at mint and a sale locks its currency at start, and nothing
///      here reaches back into either. Governed through AccessManager with `Roles`
///      (src/governance/Roles.sol): {setFeeTerms} maps to `Roles.FUNDS_SETTER` (14 days);
///      {setRoyaltyRate} and {setDefaultLicense} map to `Roles.PARAMETER_SETTER` (48 hours).
///      Each setter compares its own revision, bumped by every change to that setting.
contract EconomicsResolver is IEconomicsResolver, AccessManaged {
    /// @notice The launch network share of Stream and Editions primary sales and royalties.
    uint32 public constant DEFAULT_FEE_SHARE = 25_000;
    /// @notice The launch network share for 6529 Stream Federated.
    uint32 public constant FEDERATED_FEE_SHARE = 10_000;
    /// @notice The launch royalty rate: 6.529%.
    uint32 public constant DEFAULT_ROYALTY_RATE = 6_529;
    /// @notice The launch default license's SPDX ID; its key is `WorksHashing.CC0_LICENSE_KEY`.
    string public constant CC0 = "CC0-1.0";

    struct Product {
        ProductEconomics economics;
        uint64 feeRevision;
        uint64 royaltyRevision;
        uint64 licenseRevision;
        License license;
    }

    IAssetAllowlist private immutable _allowlist;
    ISplitFactory private immutable _factory;
    mapping(bytes32 product => Product) private _products;

    /// @param authority The AccessManager governing the setters.
    /// @param allowlist_ The economics lane's asset allowlist.
    /// @param factory_ The economics lane's split factory.
    /// @param feeRecipient The network fee recipient for every product at launch.
    /// @param cc0TextFileId The content store file ID of the CC0 1.0 legal text.
    constructor(
        address authority,
        IAssetAllowlist allowlist_,
        ISplitFactory factory_,
        address feeRecipient,
        bytes32 cc0TextFileId
    ) AccessManaged(authority) {
        _allowlist = IAssetAllowlist(_pinned(address(allowlist_)));
        _factory = ISplitFactory(_pinned(address(factory_)));
        License memory cc0 = License(CC0, cc0TextFileId);
        ProductEconomics memory standard =
            ProductEconomics(feeRecipient, DEFAULT_FEE_SHARE, DEFAULT_ROYALTY_RATE);
        _configure(PRODUCT_STREAM, standard, cc0);
        _configure(PRODUCT_EDITIONS, standard, cc0);
        standard.feeShare = FEDERATED_FEE_SHARE;
        _configure(PRODUCT_FEDERATED, standard, cc0);
    }

    /// @inheritdoc IEconomicsResolver
    function setFeeTerms(
        bytes32 product,
        uint64 expectedRevision,
        address feeRecipient,
        uint32 feeShare
    ) external restricted {
        Product storage p = _known(product);
        _check(expectedRevision, p.feeRevision);
        ProductEconomics memory previous = p.economics;
        ProductEconomics memory next =
            ProductEconomics(feeRecipient, feeShare, previous.royaltyRate);
        _validate(next);
        p.economics = next;
        emit EconomicsSet(product, previous, next, ++p.feeRevision);
    }

    /// @inheritdoc IEconomicsResolver
    function setRoyaltyRate(bytes32 product, uint64 expectedRevision, uint32 royaltyRate)
        external
        restricted
    {
        Product storage p = _known(product);
        _check(expectedRevision, p.royaltyRevision);
        ProductEconomics memory previous = p.economics;
        ProductEconomics memory next =
            ProductEconomics(previous.feeRecipient, previous.feeShare, royaltyRate);
        _validate(next);
        p.economics = next;
        emit EconomicsSet(product, previous, next, ++p.royaltyRevision);
    }

    /// @inheritdoc IEconomicsResolver
    function setDefaultLicense(bytes32 product, uint64 expectedRevision, License calldata next)
        external
        restricted
    {
        Product storage p = _known(product);
        _check(expectedRevision, p.licenseRevision);
        _validateLicense(next);
        License memory previous = p.license;
        p.license = next;
        emit DefaultLicenseSet(product, previous, next, ++p.licenseRevision);
    }

    /// @inheritdoc IEconomicsResolver
    /// @dev The royalty wallet's payee list is `Splits.royaltyPayees(seller, feeRecipient,
    ///      feeShare)`, salt zero: deploy it with exactly that list.
    function newWorkTerms(bytes32 product, ISplitWallet.Payee[] calldata payees)
        external
        view
        returns (WorkTerms memory)
    {
        ProductEconomics memory e = _known(product).economics;
        address seller = _factory.walletFor(payees, bytes32(0));
        address royaltyReceiver = e.feeShare == 0
            ? seller
            : _factory.walletFor(
                Splits.royaltyPayees(seller, e.feeRecipient, e.feeShare), bytes32(0)
            );
        return WorkTerms(seller, e.feeRecipient, e.feeShare, royaltyReceiver, e.royaltyRate);
    }

    /// @inheritdoc IEconomicsResolver
    function resolveCurrency(bytes32 product, address requested)
        external
        view
        returns (address currency)
    {
        _known(product);
        currency = requested;
        if (requested == CURRENCY_DEFAULT) {
            bool configured;
            (configured, currency,) = _allowlist.defaultCurrencyConfig(product);
            if (!configured) revert CurrencyNotAllowed(CURRENCY_DEFAULT);
        }
        if (!_allowlist.isActive(currency)) revert CurrencyNotAllowed(currency);
    }

    /// @inheritdoc IEconomicsResolver
    function economics(bytes32 product) external view returns (ProductEconomics memory) {
        return _known(product).economics;
    }

    /// @inheritdoc IEconomicsResolver
    function networkFeeRecipient(bytes32 product) external view returns (address) {
        return _known(product).economics.feeRecipient;
    }

    /// @inheritdoc IEconomicsResolver
    function defaultLicense(bytes32 product) external view returns (License memory) {
        return _known(product).license;
    }

    /// @inheritdoc IEconomicsResolver
    function revisions(bytes32 product) external view returns (uint64, uint64, uint64) {
        Product storage p = _known(product);
        return (p.feeRevision, p.royaltyRevision, p.licenseRevision);
    }

    /// @inheritdoc IEconomicsResolver
    function assetAllowlist() external view returns (address) {
        return address(_allowlist);
    }

    /// @inheritdoc IEconomicsResolver
    function splitFactory() external view returns (address) {
        return address(_factory);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEconomicsResolver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function _configure(bytes32 product, ProductEconomics memory e, License memory license)
        private
    {
        _validate(e);
        _validateLicense(license);
        Product storage p = _products[product];
        (p.economics, p.license) = (e, license);
        (p.feeRevision, p.royaltyRevision, p.licenseRevision) = (1, 1, 1);
        emit EconomicsSet(product, ProductEconomics(address(0), 0, 0), e, 1);
        emit DefaultLicenseSet(product, License("", bytes32(0)), license, 1);
    }

    function _known(bytes32 product) private view returns (Product storage p) {
        p = _products[product];
        if (p.feeRevision == 0) revert UnknownProduct(product);
    }

    function _check(uint64 expected, uint64 actual) private pure {
        if (expected != actual) revert RevisionMismatch(expected, actual);
    }

    function _validate(ProductEconomics memory e) private pure {
        if (
            e.feeShare >= Splits.DENOMINATOR || e.royaltyRate > Splits.DENOMINATOR
                || (e.feeShare != 0 && e.feeRecipient == address(0))
        ) revert InvalidEconomics();
    }

    function _validateLicense(License memory license) private pure {
        bytes memory id = bytes(license.spdxId);
        if (id.length == 0 || id.length > Limits.MAX_LICENSE_ID_BYTES || license.textFileId == 0) {
            revert InvalidLicense();
        }
        for (uint256 i; i < id.length; ++i) {
            bytes1 c = id[i];
            if (!((c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
                        || c == "." || c == "+" || c == "-")) revert InvalidLicense();
        }
    }

    function _pinned(address dependency) private view returns (address) {
        if (dependency.code.length == 0 || DelegatedEOA.isDelegated(dependency)) {
            revert InvalidDependency(dependency);
        }
        return dependency;
    }
}
