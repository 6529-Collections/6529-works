// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IRevenueEscrow } from "./interfaces/IRevenueEscrow.sol";
import { TokenTransfer } from "./TokenTransfer.sol";

/// @title RevenueEscrow
/// @notice The escrow fallback for wallet payments (ADR 0001 sections 5 and 7). When a payer cannot
///         deliver to a wallet (for example a token blocks the wallet, as USDC can), it credits the
///         escrow instead, so the sale still settles. Anyone may flush a credit, and a credit only
///         ever goes to the wallet captured when it was made.
/// @dev Unowned and ungoverned. Crediting is permissionless and does not consult the asset
///      allowlist: the credit is backed by funds that arrived by exact balance delta, and credits
///      are isolated per asset, so a hostile token can only affect its own credits. There is
///      deliberately no recovery or redirection route, so no consent rules are needed; a credit
///      that a token blocks stays owed to its wallet until the token allows the transfer.
contract RevenueEscrow is IRevenueEscrow, ReentrancyGuardTransient {
    /// @inheritdoc IRevenueEscrow
    mapping(address wallet => mapping(address asset => uint256)) public owed;
    /// @inheritdoc IRevenueEscrow
    mapping(address asset => uint256) public totalOwed;

    /// @inheritdoc IRevenueEscrow
    function depositETH(address wallet) external payable nonReentrant {
        _credit(wallet, address(0), msg.value);
    }

    /// @inheritdoc IRevenueEscrow
    function depositERC20(address wallet, address asset, uint256 amount) external nonReentrant {
        if (asset == address(0)) revert InvalidAsset(asset);
        _checkCredit(wallet, amount);
        TokenTransfer.pullExact(asset, msg.sender, amount);
        _credit(wallet, asset, amount);
    }

    /// @inheritdoc IRevenueEscrow
    function flush(address wallet, address asset) external nonReentrant returns (uint256 amount) {
        amount = owed[wallet][asset];
        if (amount == 0) revert NothingOwed(wallet, asset);
        owed[wallet][asset] = 0;
        totalOwed[asset] -= amount;
        emit Flushed(wallet, asset, msg.sender, amount);
        if (asset == address(0)) {
            if (!TokenTransfer.sendETH(wallet, amount, gasleft())) {
                revert ETHTransferFailed(wallet, amount);
            }
        } else {
            TokenTransfer.transferExact(asset, wallet, amount);
        }
    }

    function _credit(address wallet, address asset, uint256 amount) private {
        _checkCredit(wallet, amount);
        uint256 balance = owed[wallet][asset] + amount;
        owed[wallet][asset] = balance;
        totalOwed[asset] += amount;
        emit Credited(wallet, asset, msg.sender, amount, balance);
    }

    function _checkCredit(address wallet, uint256 amount) private view {
        if (wallet == address(0) || wallet == address(this)) revert InvalidWallet(wallet);
        if (amount == 0) revert ZeroAmount();
    }
}
