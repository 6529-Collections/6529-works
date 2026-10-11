// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitFactory } from "./ISplitFactory.sol";

/// @title IRevenueEscrow
/// @notice Holds payments a payer could not deliver to a wallet (ADR 0001 sections 5 and 7), keyed
///         by `(wallet, asset)`. Anyone may flush a credit to its wallet. Governance may move a
///         credit only to an equivalent replacement wallet (same factory, identical payees).
interface IRevenueEscrow {
    /// @notice `payer` credited `amount` of `asset` to `wallet`, which is now owed `owed`.
    event Credited(
        address indexed wallet,
        address indexed asset,
        address indexed payer,
        uint256 amount,
        uint256 owed
    );
    /// @notice `caller` flushed `amount` of `asset` to `wallet`.
    event Flushed(
        address indexed wallet, address indexed asset, address indexed caller, uint256 amount
    );
    /// @notice `amount` of `asset` owed to `wallet` moved to the equivalent `replacement`, which is
    ///         now owed `owed`.
    event Recovered(
        address indexed wallet,
        address indexed replacement,
        address indexed asset,
        uint256 amount,
        uint256 owed
    );

    /// @notice The factory has no code or is an EIP-7702 delegated account.
    error InvalidFactory(address factory);
    /// @notice `wallet` is zero or the escrow itself.
    error InvalidWallet(address wallet);
    /// @notice An ERC-20 deposit named `address(0)`, which is ETH.
    error InvalidAsset(address asset);
    /// @notice Deposits must be non-zero.
    error ZeroAmount();
    /// @notice `wallet` is owed nothing in `asset`.
    error NothingOwed(address wallet, address asset);
    /// @notice Sending `amount` wei to `wallet` failed; the credit is kept.
    error ETHTransferFailed(address wallet, uint256 amount);
    /// @notice `wallet` and `replacement` are not two distinct factory wallets with identical
    ///         payee configurations.
    error NotEquivalentWallet(address wallet, address replacement);

    /// @notice The split factory whose wallet configurations {recover} compares.
    function factory() external view returns (ISplitFactory);

    /// @notice The amount of `asset` owed to `wallet`.
    function owed(address wallet, address asset) external view returns (uint256);

    /// @notice The amount of `asset` owed to all wallets.
    function totalOwed(address asset) external view returns (uint256);

    /// @notice Credits `msg.value` to `wallet`.
    function depositETH(address wallet) external payable;

    /// @notice Pulls exactly `amount` of `asset` from the caller and credits it to `wallet`.
    /// @dev The caller approves the escrow first. Reverts unless both balances move by exactly
    ///      `amount` and the token returns `true`.
    function depositERC20(address wallet, address asset, uint256 amount) external;

    /// @notice Pays everything owed to `wallet` in `asset` to `wallet`. Anyone may call.
    /// @return amount The amount paid.
    function flush(address wallet, address asset) external returns (uint256 amount);

    /// @notice Moves everything owed to `wallet` in `asset` to `replacement`, a distinct wallet of
    ///         the same factory with an identical payee configuration (another salt).
    /// @dev Governed: `Roles.FUNDS_SETTER` (`Roles.FUNDS`, 14 days). It rescues credits for a
    ///      wallet a token has blocked; the blocked wallet's own balance stays where it is. This
    ///      deviates from the consent wording of ADR 0001 section 7; consent is trivially
    ///      satisfied because the payees are identical (recorded in ADR 0003). Both wallets must be
    ///      deployed. A credit the replacement already holds is added to, never overwritten.
    function recover(address wallet, address replacement, address asset) external;
}
