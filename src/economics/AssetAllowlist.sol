// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IAssetAllowlist } from "./interfaces/IAssetAllowlist.sol";

/// @title AssetAllowlist
/// @notice The governed payment settings of the network's sales, ETH only: the English auction's
///         opening bid and minimum increment. No other asset can be admitted and ETH is always
///         active, so a sale's currency can never be frozen.
/// @dev Governed through the AccessManager. Every setter compares a revision counter that every
///      change bumps, so a queued operation never applies to a later state that merely looks
///      the same. Nothing in the withdrawal paths reads this contract.
contract AssetAllowlist is IAssetAllowlist, AccessManaged {
    /// @notice ETH, which is always identified by the zero address.
    address public constant ETH = address(0);

    /// @dev `openingBid` is the English auction's least first bid in the asset. It shares the
    ///      status word, so an auction's start reads status and opening bid from one slot.
    struct AssetConfig {
        Status status;
        uint64 revision;
        uint96 openingBid;
        uint256 incrementFloor;
    }

    mapping(address asset => AssetConfig) private _assets;

    /// @param authority The AccessManager governing this contract.
    /// @param ethIncrementFloor The ETH increment floor in wei (0.001 ETH at launch); ETH is
    ///        admitted at deployment because 6529 Stream launches with it, at revision 1.
    constructor(address authority, uint256 ethIncrementFloor) AccessManaged(authority) {
        if (ethIncrementFloor == 0) revert InvalidIncrementFloor();
        AssetConfig storage config = _assets[ETH];
        config.status = Status.Active;
        config.incrementFloor = ethIncrementFloor;
        config.revision = 1;
        emit AssetStatusChanged(ETH, Status.None, Status.Active, 1);
        emit IncrementFloorChanged(ETH, 0, ethIncrementFloor, 1);
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
    function setOpeningBid(address asset, uint64 expectedRevision, uint256 bid)
        external
        restricted
    {
        AssetConfig storage config = _activeConfig(asset);
        _checkRevision(expectedRevision, config.revision);
        // A storage bound only (the bid shares the status word), not a price cap.
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

    function _checkRevision(uint64 expected, uint64 actual) private pure {
        if (expected != actual) revert RevisionMismatch(expected, actual);
    }

    function _activeConfig(address asset) private view returns (AssetConfig storage config) {
        config = _assets[asset];
        if (config.status != Status.Active) revert AssetNotActive(asset);
    }
}
