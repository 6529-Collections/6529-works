// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Roles } from "../governance/Roles.sol";
import { Dependency } from "../libraries/Dependency.sol";
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
///      live here because AccessManager only sees selectors. Every setter compares a revision
///      counter that every change bumps, so a queued operation never applies to a later state
///      that merely looks the same. Nothing in the withdrawal paths reads this contract, so
///      admission can never block a withdrawal.
contract AssetAllowlist is IAssetAllowlist, AccessManaged {
    /// @notice ETH, which is always identified by the zero address.
    address public constant ETH = address(0);

    /// @dev `since` is when the status last changed; `inactiveTotal` sums the seconds of earlier,
    ///      closed deprecations. Both share the status word, so recording them costs no new slot.
    struct AssetConfig {
        Status status;
        uint64 revision;
        uint40 since;
        uint40 inactiveTotal;
        uint256 incrementFloor;
    }

    struct Currency {
        bool configured;
        address asset;
        uint64 revision;
    }

    mapping(address asset => AssetConfig) private _assets;
    mapping(bytes32 product => Currency) private _defaults;

    /// @param authority The AccessManager governing this contract.
    /// @param ethIncrementFloor The ETH increment floor in wei (ADR 0001: 0.001 ETH); ETH is
    ///        admitted at deployment because 6529 Stream launches with it, at revision 1.
    constructor(address authority, uint256 ethIncrementFloor) AccessManaged(authority) {
        _admit(ETH, ethIncrementFloor);
    }

    /// @inheritdoc IAssetAllowlist
    /// @dev Compare-and-set on the asset's revision. Any admission, deprecation or floor change
    ///      after the operation was written bumps the revision, so the operation reverts; this
    ///      includes an emergency deprecation that returns the asset to the status and floor the
    ///      operation saw.
    function admitAsset(address asset, uint64 expectedRevision, uint256 floor) external restricted {
        AssetConfig storage config = _assets[asset];
        _checkRevision(expectedRevision, config.revision);
        // As GOV-5 for unpauses: AccessManager counts the 14-day delay from scheduling, so a
        // re-admission scheduled ahead could undo a deprecation in its own block. The delay is
        // counted from the deprecation instead.
        if (config.status == Status.Deprecated) {
            uint256 allowedAt = uint256(config.since) + Roles.FUNDS;
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < allowedAt) revert ReadmissionTooEarly(asset, allowedAt);
        }
        if (asset != ETH) {
            // The install predicate every dependency gets, under the allowlist's own error.
            if (!Dependency.isInstallable(asset)) revert AssetNotAdmissible(asset);
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
        config.since = uint40(block.timestamp);
        emit AssetStatusChanged(asset, Status.Active, Status.Deprecated, ++config.revision);
    }

    /// @inheritdoc IAssetAllowlist
    function setIncrementFloor(address asset, uint64 expectedRevision, uint256 floor)
        external
        restricted
    {
        AssetConfig storage config = _activeConfig(asset);
        _checkRevision(expectedRevision, config.revision);
        if (floor == 0) revert InvalidIncrementFloor();
        uint256 previous = config.incrementFloor;
        config.incrementFloor = floor;
        emit IncrementFloorChanged(asset, previous, floor, ++config.revision);
    }

    /// @inheritdoc IAssetAllowlist
    function setDefaultCurrency(bytes32 product, uint64 expectedRevision, address asset)
        external
        restricted
    {
        if (product == bytes32(0)) revert InvalidProduct();
        Currency storage current = _defaults[product];
        _checkRevision(expectedRevision, current.revision);
        _activeConfig(asset);
        address previous = current.asset;
        current.configured = true;
        current.asset = asset;
        emit DefaultCurrencyChanged(product, previous, asset, ++current.revision);
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
    function assetConfig(address asset) external view returns (Status, uint256, uint64) {
        AssetConfig storage config = _assets[asset];
        return (config.status, config.incrementFloor, config.revision);
    }

    /// @inheritdoc IAssetAllowlist
    function statusClock(address asset) external view returns (Status, uint256, uint256) {
        AssetConfig storage config = _assets[asset];
        return (config.status, config.since, config.inactiveTotal);
    }

    /// @inheritdoc IAssetAllowlist
    function defaultCurrency(bytes32 product) external view returns (address) {
        Currency storage currency = _defaults[product];
        if (!currency.configured) revert CurrencyNotConfigured(product);
        _activeConfig(currency.asset);
        return currency.asset;
    }

    /// @inheritdoc IAssetAllowlist
    function defaultCurrencyConfig(bytes32 product) external view returns (bool, address, uint64) {
        Currency storage currency = _defaults[product];
        return (currency.configured, currency.asset, currency.revision);
    }

    /// @dev Activates `asset` with `floor` as one change (one revision bump, two events).
    function _admit(address asset, uint256 floor) private {
        AssetConfig storage config = _assets[asset];
        Status previous = config.status;
        if (previous == Status.Active) revert InvalidStatusTransition(asset, previous);
        if (floor == 0) revert InvalidIncrementFloor();
        uint256 previousFloor = config.incrementFloor;
        if (previous == Status.Deprecated) {
            config.inactiveTotal += uint40(block.timestamp - config.since);
        }
        config.status = Status.Active;
        config.since = uint40(block.timestamp);
        config.incrementFloor = floor;
        uint64 revision = ++config.revision;
        emit AssetStatusChanged(asset, previous, Status.Active, revision);
        emit IncrementFloorChanged(asset, previousFloor, floor, revision);
    }

    function _checkRevision(uint64 expected, uint64 actual) private pure {
        if (expected != actual) revert RevisionMismatch(expected, actual);
    }

    function _activeConfig(address asset) private view returns (AssetConfig storage config) {
        config = _assets[asset];
        if (config.status != Status.Active) revert AssetNotActive(asset);
    }
}
