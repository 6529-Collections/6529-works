// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";
import { IAssetAllowlist } from "./interfaces/IAssetAllowlist.sol";
import { TokenTransfer } from "./TokenTransfer.sol";

/// @title AssetAllowlist
/// @notice The governed payment-currency allowlist (ADR 0001 section 5): which assets new sales may
///         settle in, each currency's absolute minimum bid increment, and each product's default
///         currency. Switching a product to USDC, or adding a 6529 token, is "admit the asset, then
///         change the default", with no contract change. Sales lock their currency and floor when
///         they start, so later changes only affect later sales.
/// @dev Governed through AccessManager, with the delay classes of ADR 0002 and the role IDs of
///      `Roles` (src/governance/Roles.sol): {admitAsset} and {setDefaultCurrency} map to
///      `Roles.FUNDS_SETTER` (`Roles.FUNDS`, 14 days), {setIncrementFloor} to
///      `Roles.PARAMETER_SETTER` (`Roles.STANDARD`, 48 hours), and {deprecateAsset}, which only
///      tightens, to `Roles.GUARDIAN` (`Roles.IMMEDIATE`). Direction rules and compare-and-set
///      live here because AccessManager only sees selectors. Nothing in the withdrawal paths reads
///      this contract, so admission can never block a withdrawal.
contract AssetAllowlist is IAssetAllowlist, AccessManaged {
    /// @notice ETH, which is always identified by the zero address.
    address public constant ETH = address(0);

    struct AssetConfig {
        Status status;
        uint256 incrementFloor;
    }

    struct Currency {
        bool configured;
        address asset;
    }

    mapping(address asset => AssetConfig) private _assets;
    mapping(bytes32 product => Currency) private _defaults;

    /// @param authority The AccessManager governing this contract.
    /// @param ethIncrementFloor The ETH increment floor in wei (ADR 0001: 0.001 ETH); ETH is admitted
    ///        at deployment because 6529 Stream launches with it.
    constructor(address authority, uint256 ethIncrementFloor) AccessManaged(authority) {
        _admit(ETH, ethIncrementFloor);
    }

    /// @inheritdoc IAssetAllowlist
    /// @dev Compare-and-set on status and floor: an admission queued before an emergency
    ///      deprecation, or before a floor change, reverts instead of silently re-activating.
    function admitAsset(address asset, Status expectedStatus, uint256 expectedFloor, uint256 floor)
        external
        restricted
    {
        AssetConfig storage config = _assets[asset];
        if (config.status != expectedStatus || config.incrementFloor != expectedFloor) {
            revert AdmissionMismatch(config.status, config.incrementFloor);
        }
        if (asset != ETH) {
            if (asset.code.length == 0 || DelegatedEOA.isDelegated(asset)) {
                revert AssetNotAdmissible(asset);
            }
            // A sanity probe, not proof of a standard token (governance vets that): both reads
            // must return exactly one word, and no balance may exceed the supply.
            if (TokenTransfer.balanceOf(asset, address(this)) > TokenTransfer.totalSupply(asset)) {
                revert AssetNotAdmissible(asset);
            }
        }
        _admit(asset, floor);
    }

    /// @inheritdoc IAssetAllowlist
    function deprecateAsset(address asset) external restricted {
        AssetConfig storage config = _assets[asset];
        if (config.status != Status.Active) revert InvalidStatusTransition(asset, config.status);
        config.status = Status.Deprecated;
        emit AssetStatusChanged(asset, Status.Active, Status.Deprecated);
    }

    /// @inheritdoc IAssetAllowlist
    function setIncrementFloor(address asset, uint256 expected, uint256 floor) external restricted {
        AssetConfig storage config = _activeConfig(asset);
        if (config.incrementFloor != expected) {
            revert IncrementFloorMismatch(expected, config.incrementFloor);
        }
        if (floor == 0) revert InvalidIncrementFloor();
        config.incrementFloor = floor;
        emit IncrementFloorChanged(asset, expected, floor);
    }

    /// @inheritdoc IAssetAllowlist
    function setDefaultCurrency(
        bytes32 product,
        bool expectedConfigured,
        address expected,
        address asset
    ) external restricted {
        if (product == bytes32(0)) revert InvalidProduct();
        Currency storage current = _defaults[product];
        if (current.configured != expectedConfigured || current.asset != expected) {
            revert DefaultCurrencyMismatch(current.configured, current.asset);
        }
        _activeConfig(asset);
        _defaults[product] = Currency(true, asset);
        emit DefaultCurrencyChanged(product, expectedConfigured, expected, asset);
    }

    /// @inheritdoc IAssetAllowlist
    function status(address asset) external view returns (Status) {
        return _assets[asset].status;
    }

    /// @inheritdoc IAssetAllowlist
    function isActive(address asset) external view returns (bool) {
        return _assets[asset].status == Status.Active;
    }

    /// @inheritdoc IAssetAllowlist
    function incrementFloor(address asset) external view returns (uint256) {
        return _activeConfig(asset).incrementFloor;
    }

    /// @inheritdoc IAssetAllowlist
    function assetConfig(address asset) external view returns (Status, uint256) {
        AssetConfig storage config = _assets[asset];
        return (config.status, config.incrementFloor);
    }

    /// @inheritdoc IAssetAllowlist
    function defaultCurrency(bytes32 product) external view returns (address) {
        Currency storage currency = _defaults[product];
        if (!currency.configured) revert CurrencyNotConfigured(product);
        _activeConfig(currency.asset);
        return currency.asset;
    }

    /// @inheritdoc IAssetAllowlist
    function defaultCurrencyConfig(bytes32 product) external view returns (bool, address) {
        Currency storage currency = _defaults[product];
        return (currency.configured, currency.asset);
    }

    function _admit(address asset, uint256 floor) private {
        AssetConfig storage config = _assets[asset];
        Status previous = config.status;
        if (previous == Status.Active) revert InvalidStatusTransition(asset, previous);
        if (floor == 0) revert InvalidIncrementFloor();
        uint256 previousFloor = config.incrementFloor;
        config.status = Status.Active;
        config.incrementFloor = floor;
        emit AssetStatusChanged(asset, previous, Status.Active);
        emit IncrementFloorChanged(asset, previousFloor, floor);
    }

    function _activeConfig(address asset) private view returns (AssetConfig storage config) {
        config = _assets[asset];
        if (config.status != Status.Active) revert AssetNotActive(asset);
    }
}
