// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAssetAllowlist
/// @notice The governed payment-currency allowlist (ADR 0001 section 5). Sale adapters read it when
///         a sale starts and lock the currency and its increment floor for that sale. Withdrawals
///         never read it: split wallets and the revenue escrow release any asset they hold. ETH is
///         `address(0)`.
/// @dev Every governed setter is compare-and-set on a revision counter. Each asset and each
///      product has its own counter, bumped by every change to it (admission, deprecation, floor
///      change; default change), so a queued operation runs only against the exact state it was
///      written for, even if the state later returns to the same values (no ABA).
interface IAssetAllowlist {
    /// @notice `None`: never admitted. `Active`: new sales may use it. `Deprecated`: new sales may
    ///         not use it; sales already started and every withdrawal are unaffected.
    enum Status {
        None,
        Active,
        Deprecated
    }

    /// @notice `asset` moved from status `previous` to `current`; its revision is now `revision`.
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
    /// @notice The default currency of `product` changed from `previous` to `current`; its
    ///         revision is now `revision` (1 for the product's first default).
    /// @param product The product identifier.
    /// @param previous The default currency before the change; `address(0)` when `revision` is 1.
    /// @param current The default currency after the change, an active asset.
    /// @param revision The product's revision after the change.
    event DefaultCurrencyChanged(
        bytes32 indexed product, address previous, address current, uint64 revision
    );

    /// @notice `asset` has no code, is an EIP-7702 delegated account, or reports a balance above
    ///         its total supply. Unreadable balances or supply revert with the token-read error.
    error AssetNotAdmissible(address asset);
    /// @notice Compare-and-set failed: the state is at revision `actual`, not `expected`.
    error RevisionMismatch(uint64 expected, uint64 actual);
    /// @notice The requested change does not apply to an asset in status `current`.
    error InvalidStatusTransition(address asset, Status current);
    /// @notice `asset` is not active.
    error AssetNotActive(address asset);
    /// @notice ETH, the native currency, is never deprecated: one guardian could otherwise
    ///         freeze every ETH sale and, after the 30-day freeze exit, end each one unsold
    ///         (MONEY-M1, G-2 in the rc.2 review).
    error EthNotDeprecable();
    /// @notice A deprecated `asset` may be re-admitted only from `allowedAt`, 14 days
    ///         (`Roles.FUNDS`) after its deprecation.
    error ReadmissionTooEarly(address asset, uint256 allowedAt);
    /// @notice An increment floor must be non-zero.
    error InvalidIncrementFloor();
    /// @notice The product identifier is zero.
    error InvalidProduct();
    /// @notice `product` has no default currency.
    error CurrencyNotConfigured(bytes32 product);

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
    /// @return floor The stored increment floor, in the asset's base units; kept while the asset
    ///        is deprecated, zero if it was never admitted.
    /// @return revision The asset's revision; zero if it was never admitted.
    function assetConfig(address asset)
        external
        view
        returns (Status status, uint256 floor, uint64 revision);

    /// @notice When `asset`'s status last changed (its latest admission or deprecation) and the
    ///         seconds it spent deprecated in earlier, closed deprecations, without reverting.
    /// @dev Sale adapters stop their clocks while their currency is deprecated (MARKET-1,
    ///      MARKET-2): the time deprecated so far is `inactiveTotal`, plus
    ///      `block.timestamp - since` while the asset is deprecated now.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @return status The asset's status.
    /// @return since The timestamp, in seconds, of the latest admission or deprecation; zero if
    ///        the asset was never admitted.
    /// @return inactiveTotal The seconds the asset spent deprecated before its latest admission.
    function statusClock(address asset)
        external
        view
        returns (Status status, uint256 since, uint256 inactiveTotal);

    /// @notice The default currency of `product`; reverts unless it is configured and active.
    /// @param product The product identifier.
    /// @return The product's default currency (ETH is `address(0)`).
    function defaultCurrency(bytes32 product) external view returns (address);

    /// @notice The stored default currency of `product` and its revision, without reverting.
    /// @param product The product identifier.
    /// @return configured Whether a default currency was ever set for the product.
    /// @return asset The stored default currency, active or not; meaningful only when
    ///        `configured`, since `address(0)` is also ETH.
    /// @return revision The product's revision; zero before its first default.
    function defaultCurrencyConfig(bytes32 product)
        external
        view
        returns (bool configured, address asset, uint64 revision);

    /// @notice Admits `asset`, or re-admits a deprecated one, with increment floor `floor`, if the
    ///         asset is at `expectedRevision` (0 for a never-admitted asset). Re-admission is the
    ///         only way back from deprecation, and is refused until 14 days after it
    ///         (`ReadmissionTooEarly`), even when scheduled before the deprecation.
    /// @param asset The asset to admit: ETH (`address(0)`) or a token contract that passes the
    ///        {AssetNotAdmissible} checks; must not be active already.
    /// @param expectedRevision The revision the asset must be at.
    /// @param floor The increment floor, in the asset's base units; must be non-zero.
    function admitAsset(address asset, uint64 expectedRevision, uint256 floor) external;

    /// @notice Stops new sales from using active `asset`. Immediate; bumps the asset's revision,
    ///         so every operation queued against the earlier state reverts. ETH is refused
    ///         (`EthNotDeprecable`): the native currency of every ETH sale, and the only currency
    ///         of the edition auctions, is never frozen.
    /// @param asset The asset to deprecate: an active token, never ETH.
    function deprecateAsset(address asset) external;

    /// @notice Sets the increment floor of active `asset` to `floor`, if the asset is at
    ///         `expectedRevision`.
    /// @param asset The asset whose floor to set; must be active.
    /// @param expectedRevision The revision the asset must be at.
    /// @param floor The new increment floor, in the asset's base units; must be non-zero.
    function setIncrementFloor(address asset, uint64 expectedRevision, uint256 floor) external;

    /// @notice Sets the default currency of `product` to active `asset`, if the product is at
    ///         `expectedRevision` (0 before its first default).
    /// @param product The product identifier; must be non-zero.
    /// @param expectedRevision The revision the product must be at.
    /// @param asset The new default currency; must be active.
    function setDefaultCurrency(bytes32 product, uint64 expectedRevision, address asset) external;
}
