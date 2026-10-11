// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRevenueEscrow
/// @notice The fallback for payments a sale could not push (ADR 0001 sections 5 and 7).
/// @dev Adapters credit a recipient here when pushing to it fails (a reverting wallet, an
///      address a token blocks), so no recipient can block a sale. `flush` retries the push and
///      is permissionless; an account may also withdraw its own credit to another address, which
///      is the only way funds leave other than to the account itself. Credits are by exact
///      balance delta; the escrow always holds at least `totalOwed` of each currency.
interface IRevenueEscrow {
    /// @notice `from` credited `amount` of `currency` to `account`.
    event Credited(
        address indexed account, address indexed currency, address indexed from, uint256 amount
    );
    /// @notice `amount` owed to `account` was paid to `to`.
    event Paid(
        address indexed account, address indexed currency, address indexed to, uint256 amount
    );

    /// @notice `msg.value` or the received amount does not equal `amount`.
    error CreditMismatch(uint256 expected, uint256 received);
    /// @notice Nothing is owed to `account` in `currency`.
    error NothingOwed(address account, address currency);

    /// @notice Credits `amount` of `currency` to `account`: ETH as `msg.value`, an ERC-20 pulled
    ///         from the caller.
    function credit(address account, address currency, uint256 amount) external payable;
    /// @notice Pushes everything owed to `account` in `currency` to `account`. Permissionless.
    function flush(address account, address currency) external returns (uint256 amount);
    /// @notice Pays the caller's own credit in `currency` to `to`.
    function withdraw(address currency, address to) external returns (uint256 amount);
    /// @notice What is owed to `account` in `currency`.
    function owed(address account, address currency) external view returns (uint256);
    /// @notice What is owed to everyone in `currency`.
    function totalOwed(address currency) external view returns (uint256);
}
