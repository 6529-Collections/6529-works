// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { BoundedCall } from "../libraries/BoundedCall.sol";
import { IRevenueEscrow } from "./interfaces/IRevenueEscrow.sol";
import { TokenTransfer } from "./TokenTransfer.sol";

/// @title RevenuePayment
/// @notice How sale adapters pay a wallet (ADR 0001 section 5, "wallet payments fall back to
///         escrow"): pay the wallet directly in ETH, and if the wallet refuses, credit the
///         revenue escrow for that wallet instead. A refusal therefore cannot block a settlement,
///         and the funds still reach only that wallet.
/// @dev Internal functions only, compiled into each payer. Only an ETH call that fails routes to
///      escrow. The wallet always gets its full gas allowance, so a caller cannot force the
///      escrow route by starving the call. A zero amount is a no-op, so a zero-price sale or a
///      share that rounds to zero never reaches the escrow.
///
///      Glamsterdam (LIM-GAS-2; the EIP-8037 draft, not yet reproduced on Sepolia): the allowance
///      caps the wallet's regular gas, not the state gas it spends creating storage or accounts,
///      which comes from the transaction's EIP-8037 reservoir. A state-writing wallet can
///      therefore be paid or escrowed depending on the caller's gas limit, and the caller can
///      pay for a hostile callee's state growth; either way the funds reach only that wallet.
///      Keepers should send at most 2^24 gas (`BoundedCall`; docs/audit/known-limitations.md,
///      LIM-GAS-2).
library RevenuePayment {
    /// @notice Gas kept for the value transfer and a possible new account on top of the
    ///         wallet's gas limit.
    uint256 internal constant ETH_CALL_RESERVE = 40_000;

    /// @notice The caller cannot forward `gasLimit` to the wallet in full.
    error PaymentInsufficientGas(uint256 gasLimit);

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
}
