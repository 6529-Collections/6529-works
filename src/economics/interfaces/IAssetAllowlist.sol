// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAssetAllowlist
/// @notice The governed payment-currency allowlist (ADR 0001 section 5). Sale adapters read it when a
///         sale starts and lock the currency and its increment floor for that sale. Withdrawals
///         never read it: split wallets and the revenue escrow release any asset they hold.
///         ETH is `address(0)`.
interface IAssetAllowlist {
    /// @notice `None`: never admitted. `Active`: new sales may use it. `Deprecated`: new sales may
    ///         not use it; sales already started and every withdrawal are unaffected.
    enum Status {
        None,
        Active,
        Deprecated
    }

    /// @notice `asset` moved from status `previous` to `current`.
    event AssetStatusChanged(address indexed asset, Status previous, Status current);
    /// @notice The absolute minimum bid increment for `asset` changed from `previous` to `current`.
    event IncrementFloorChanged(address indexed asset, uint256 previous, uint256 current);
    /// @notice The default currency of `product` changed from `previous` to `current`;
    ///         `wasConfigured` is false for the product's first default.
    event DefaultCurrencyChanged(
        bytes32 indexed product, bool wasConfigured, address previous, address current
    );

    /// @notice `asset` has no code, is an EIP-7702 delegated account, or reports a balance above
    ///         its total supply. Unreadable balances or supply revert with the token-read error.
    error AssetNotAdmissible(address asset);
    /// @notice The requested change does not apply to an asset in status `current`.
    error InvalidStatusTransition(address asset, Status current);
    /// @notice `asset` is not active.
    error AssetNotActive(address asset);
    /// @notice An increment floor must be non-zero.
    error InvalidIncrementFloor();
    /// @notice Compare-and-set failed: the floor is `actual`, not `expected`.
    error IncrementFloorMismatch(uint256 expected, uint256 actual);
    /// @notice Compare-and-set failed: the default currency is not the expected one.
    error DefaultCurrencyMismatch(bool actualConfigured, address actual);
    /// @notice The product identifier is zero.
    error InvalidProduct();
    /// @notice `product` has no default currency.
    error CurrencyNotConfigured(bytes32 product);

    /// @notice The status of `asset`.
    function status(address asset) external view returns (Status);

    /// @notice Returns whether new sales may use `asset`.
    function isActive(address asset) external view returns (bool);

    /// @notice The increment floor of an active `asset`; reverts unless it is active.
    function incrementFloor(address asset) external view returns (uint256);

    /// @notice The status and stored increment floor of `asset`, without reverting.
    function assetConfig(address asset) external view returns (Status, uint256 floor);

    /// @notice The default currency of `product`; reverts unless it is configured and active.
    function defaultCurrency(bytes32 product) external view returns (address);

    /// @notice The stored default currency of `product`, without reverting.
    function defaultCurrencyConfig(bytes32 product)
        external
        view
        returns (bool configured, address asset);

    /// @notice Admits `asset`, or re-admits a deprecated one, with increment floor `floor`.
    function admitAsset(address asset, uint256 floor) external;

    /// @notice Stops new sales from using active `asset`.
    function deprecateAsset(address asset) external;

    /// @notice Sets the increment floor of active `asset` from `expected` to `floor`.
    function setIncrementFloor(address asset, uint256 expected, uint256 floor) external;

    /// @notice Sets the default currency of `product` to active `asset`, if the current setting
    ///         is `(expectedConfigured, expected)`.
    function setDefaultCurrency(
        bytes32 product,
        bool expectedConfigured,
        address expected,
        address asset
    ) external;
}
