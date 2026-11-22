// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAssetAllowlist } from "./interfaces/IAssetAllowlist.sol";

/// @title AssetAllowlist
/// @notice The governed payment settings of the network's sales, ETH only: the English auction's
///         opening bid and minimum increment, and each product's default currency (ETH). No other
///         asset can be admitted, and ETH can never be deprecated, so a sale's currency can never
///         be frozen.
/// @dev Governed through the AccessManager. Every setter compares a revision counter that every
///      change bumps, so a queued operation never applies to a later state that merely looks
///      the same. Nothing in the withdrawal paths reads this contract.
contract AssetAllowlist is IAssetAllowlist, AccessManaged {
    /// @notice ETH, which is always identified by the zero address.
    address public constant ETH = address(0);

    /// @dev `since` is when the status last changed; `inactiveTotal` sums the seconds of earlier,
    ///      closed deprecations; `openingBid` is the English auction's least first bid in the
    ///      asset. All share the status word, so an auction's start reads status and opening bid
    ///      from one slot.
    struct AssetConfig {
        Status status;
        uint64 revision;
        uint40 since;
        uint40 inactiveTotal;
        uint96 openingBid;
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
    function deprecateAsset(address asset) external restricted {
        if (asset == ETH) revert EthNotDeprecable();
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
    function setOpeningBid(address asset, uint64 expectedRevision, uint256 bid)
        external
        restricted
    {
        AssetConfig storage config = _activeConfig(asset);
        _checkRevision(expectedRevision, config.revision);
        // A storage bound only (the bid shares the status word), not a price cap (R19).
        if (bid > type(uint96).max) revert OpeningBidAboveCeiling(bid, type(uint96).max);
        uint256 previous = config.openingBid;
        // Safe: `bid` is at most `type(uint96).max` (checked above).
        // forge-lint: disable-next-line(unsafe-typecast)
        config.openingBid = uint96(bid);
        emit OpeningBidSet(asset, previous, bid, ++config.revision);
    }

    /// @inheritdoc IAssetAllowlist
    function openingBid(address asset) external view returns (uint256) {
        return _assets[asset].openingBid;
    }

    /// @inheritdoc IAssetAllowlist
    function activeOpeningBid(address asset) external view returns (uint256) {
        return _activeConfig(asset).openingBid;
    }

    /// @inheritdoc IAssetAllowlist
    function defaultCurrencyOpeningBid(bytes32 product)
        external
        view
        returns (address asset, uint256 bid)
    {
        Currency storage currency = _defaults[product];
        if (!currency.configured) revert CurrencyNotConfigured(product);
        asset = currency.asset;
        bid = _activeConfig(asset).openingBid;
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
