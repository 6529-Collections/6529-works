// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IReleaseVerifier } from "./IReleaseVerifier.sol";
import { ISplitFactory } from "./ISplitFactory.sol";
import { ISplitWallet } from "./ISplitWallet.sol";

/// @title ISplitLedger
/// @notice The one permanent split contract (ADR 0001 section 7): it predicts and deploys every
///         split wallet ({ISplitFactory}), keeps every wallet's accounting and executes its
///         releases ({ISplitWallet}), and verifies signed releases ({IReleaseVerifier}). A wallet
///         is a minimal vault that only the ledger can command, so withdrawing depends on no
///         deployment beyond the vault's 66 bytes of code, once per wallet.
interface ISplitLedger is ISplitFactory, ISplitWallet, IReleaseVerifier {
    /// @notice Executes a payee's signed release from `authorization.wallet`. Anyone may submit
    ///         it; it works for fixed and artist-resolved payees alike.
    /// @param payees The payee list of `authorization.wallet`.
    /// @param salt The salt of `authorization.wallet`.
    /// @param authorization The signed release; its `account` must be the payee's current payout
    ///        address.
    /// @param signature The signature of `authorization.account` over
    ///        {IReleaseVerifier.releaseDigest}: 65 or 64 (ERC-2098) bytes for an EOA, or an
    ///        ERC-1271 signature for a contract account.
    /// @return amount The amount released.
    function releaseWithAuthorization(
        Payee[] calldata payees,
        bytes32 salt,
        Authorization calldata authorization,
        bytes calldata signature
    ) external returns (uint256 amount);
}
