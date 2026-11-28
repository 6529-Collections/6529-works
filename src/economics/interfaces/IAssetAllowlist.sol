// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @title IAssetAllowlist
/// @notice The governed payment settings of the network's sales, ETH only (ETH is `address(0)`):
///         the English auction's opening bid and increment floor, which it reads when a bid is
///         placed. No other asset can be admitted, and ETH is always active. Withdrawals never
///         read it.
/// @dev Every governed setter is compare-and-set on the asset's revision counter, bumped by
///      every change to it, so a queued operation runs only against the exact state it was
///      written for, even if the state later returns to the same values.
interface IAssetAllowlist {
    /// @notice `None`: not admitted (every asset but ETH). `Active`: sales use it (ETH).
    enum Status {
        None,
        Active
    }

    /// @notice `asset` moved from status `previous` to `current`; its revision is now `revision`.
    ///         Logged once, at deployment, when ETH is admitted.
    /// @param asset The asset whose status changed (ETH is `address(0)`).
    /// @param previous The status before the change.
    /// @param current The status after the change.
    /// @param revision The asset's revision after the change.
    event AssetStatusChanged(
        address indexed asset, Status previous, Status current, uint64 revision
    );
    /// @notice The absolute minimum bid increment for `asset` changed from `previous` to `current`;
    ///         its revision is now `revision`.
    /// @param asset The asset whose increment floor changed.
    /// @param previous The floor before the change, in the asset's base units (wei for ETH); zero
    ///        on the asset's first admission.
    /// @param current The floor after the change, in the asset's base units.
    /// @param revision The asset's revision after the change.
    event IncrementFloorChanged(
        address indexed asset, uint256 previous, uint256 current, uint64 revision
    );
    /// @notice The opening bid of `asset` (the least first bid of an English auction that
    ///         starts in it) changed from `previous` to `current`; its revision is now `revision`.
    /// @param asset The asset whose opening bid changed.
    /// @param previous The opening bid before the change, in the asset's base units.
    /// @param current The opening bid after the change, in the asset's base units.
    /// @param revision The asset's revision after the change.
    event OpeningBidSet(address indexed asset, uint256 previous, uint256 current, uint64 revision);

    /// @notice Compare-and-set failed: the state is at revision `actual`, not `expected`.
    error RevisionMismatch(uint64 expected, uint64 actual);
    /// @notice `asset` is not active.
    error AssetNotActive(address asset);
    /// @notice An increment floor must be non-zero.
    error InvalidIncrementFloor();
    /// @notice The opening bid does not fit its storage: it is above `type(uint96).max`.
    error OpeningBidAboveCeiling(uint256 bid, uint256 ceiling);

    /// @notice The status of `asset`.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @return The asset's status; `None` if it was never admitted.
    function status(address asset) external view returns (Status);

    /// @notice Returns whether new sales may use `asset`.
    /// @param asset The asset to check (ETH is `address(0)`).
    /// @return True if the asset's status is `Active`.
    function isActive(address asset) external view returns (bool);

    /// @notice The increment floor of an active `asset`; reverts unless it is active.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @return The minimum bid increment, in the asset's base units (wei for ETH).
    function incrementFloor(address asset) external view returns (uint256);

    /// @notice The status, stored increment floor and revision of `asset`, without reverting.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @return status The asset's status.
    /// @return floor The stored increment floor, in the asset's base units; zero if it was
    ///        never admitted.
    /// @return revision The asset's revision; zero if it was never admitted.
    function assetConfig(address asset)
        external
        view
        returns (Status status, uint256 floor, uint64 revision);

    /// @notice An asset's opening bid (zero when never set), whatever its status.
    /// @param asset The asset.
    /// @return The opening bid, in the asset's base units.
    function openingBid(address asset) external view returns (uint256);

    /// @notice The opening bid of an active asset, read with its status in one word: what an
    ///         English auction locks at start. Reverts with `AssetNotActive` otherwise.
    /// @param asset The asset.
    /// @return The opening bid, in the asset's base units.
    function activeOpeningBid(address asset) external view returns (uint256);

    /// @notice Sets the increment floor of active `asset` to `floor`, if the asset is at
    ///         `expectedRevision`.
    /// @param asset The asset whose floor to set; must be active.
    /// @param expectedRevision The revision the asset must be at.
    /// @param floor The new increment floor, in the asset's base units; must be non-zero.
    function setIncrementFloor(address asset, uint64 expectedRevision, uint256 floor) external;

    /// @notice Sets an active asset's opening bid, raising or lowering it (zero included) to any
    ///         value up to `type(uint96).max` (a storage bound, not a price cap), if the asset is
    ///         at `expectedRevision`. Applies to English auctions that start afterwards.
    ///         PARAMETER_SETTER role (the network, 24 hours).
    /// @param asset The asset; must be active.
    /// @param expectedRevision The revision the asset must be at.
    /// @param bid The new opening bid, in the asset's base units.
    function setOpeningBid(address asset, uint64 expectedRevision, uint256 bid) external;
}
