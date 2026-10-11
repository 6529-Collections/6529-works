// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BoundedCall } from "../libraries/BoundedCall.sol";
import { IRevenueEscrow } from "./interfaces/IRevenueEscrow.sol";
import { TokenTransfer } from "./TokenTransfer.sol";

/// @title RevenuePayment
/// @notice How sale adapters pay a wallet (ADR 0001 section 5, "wallet payments fall back to
///         escrow"): pay the wallet directly, and if the wallet or the token refuses, credit the
///         revenue escrow for that wallet instead. A refusal therefore cannot block a settlement,
///         and the funds still reach only that wallet.
/// @dev Internal functions only, compiled into each payer. Only a clean refusal routes to escrow:
///      an ETH call that fails, or a token transfer that reverts or returns `false` without moving
///      anything. Any other token misbehaviour (fees, rounding, no return value, a `true` with the
///      wrong balance change) reverts the whole payment, so nothing is left behind. The wallet or
///      token always gets its full gas allowance, so a caller cannot force the escrow route by
///      starving the call. A zero amount is a no-op, so a zero-price sale or a share that rounds
///      to zero never reaches the escrow.
library RevenuePayment {
    /// @notice Gas kept for the value transfer and a possible new account on top of the
    ///         wallet's gas limit.
    uint256 internal constant ETH_CALL_RESERVE = 40_000;

    /// @notice Gas given to a token's `transfer` on the direct route. A standard token needs far
    ///         less; a token that needs more is treated as refusing, and the payment is escrowed.
    uint256 internal constant ERC20_TRANSFER_GAS = 300_000;

    /// @notice The caller cannot forward `gasLimit` to the wallet in full.
    error PaymentInsufficientGas(uint256 gasLimit);
    /// @notice The escrow left an allowance behind after crediting `asset`.
    error EscrowAllowanceLeft(address asset);

    /// @notice Pays `amount` wei to `wallet`, forwarding exactly `gasLimit` gas, or credits the
    ///         escrow if the wallet refuses.
    /// @dev Reverts unless the wallet gets its full `gasLimit`, so a caller cannot force the
    ///      escrow route by starving the call.
    /// @return escrowed Whether the payment went to the escrow.
    function payETH(IRevenueEscrow escrow, address wallet, uint256 amount, uint256 gasLimit)
        internal
        returns (bool escrowed)
    {
        if (wallet == address(0) || wallet == address(escrow)) {
            revert IRevenueEscrow.InvalidWallet(wallet);
        }
        if (amount == 0) return false;
        if (!BoundedCall.hasSufficientGas(gasleft(), gasLimit, ETH_CALL_RESERVE)) {
            revert PaymentInsufficientGas(gasLimit);
        }
        if (TokenTransfer.sendETH(wallet, amount, gasLimit)) return false;
        escrow.depositETH{ value: amount }(wallet);
        return true;
    }

    /// @notice Transfers exactly `amount` of `asset` to `wallet`, giving the token
    ///         {ERC20_TRANSFER_GAS}, or credits the escrow if the token refuses the transfer.
    /// @return escrowed Whether the payment went to the escrow.
    function payERC20(IRevenueEscrow escrow, address wallet, address asset, uint256 amount)
        internal
        returns (bool escrowed)
    {
        if (wallet == address(0) || wallet == address(escrow)) {
            revert IRevenueEscrow.InvalidWallet(wallet);
        }
        if (amount == 0) return false;
        if (TokenTransfer.tryTransferExact(asset, wallet, amount, ERC20_TRANSFER_GAS)) {
            return false;
        }
        TokenTransfer.approve(asset, address(escrow), amount);
        escrow.depositERC20(wallet, asset, amount);
        // The escrow pulled exactly `amount`, so a standard token leaves no allowance. This is the
        // only check that catches a token whose `transferFrom` does not spend the allowance.
        if (TokenTransfer.allowance(asset, address(this), address(escrow)) != 0) {
            revert EscrowAllowanceLeft(asset);
        }
        return true;
    }
}
