// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IClaimRouter } from "./interfaces/IClaimRouter.sol";
import { ISplitWallet } from "./interfaces/ISplitWallet.sol";

/// @title ClaimRouter
/// @notice Permissionless, stateless batch claims across split wallets (ADR 0001 section 7). Each
///         item calls `release(asset, payee)`, which pays only the payee's own payout address.
/// @dev No storage, owner, approvals, `receive` or `fallback`, so it never holds funds and reentry
///      gains nothing; the wallets enforce entitlement and accounting. Hostile targets are
///      contained: at most one word of return data is copied on success and at most 256 bytes of
///      revert data on failure, and in continue mode each call gets only its share of the gas left.
contract ClaimRouter is IClaimRouter {
    /// @inheritdoc IClaimRouter
    /// @dev A worst-case standard item costs about 130,000 gas, so a full atomic batch stays
    ///      under 7M, and continue mode needs at most `(MAX_CLAIMS + 1) * MIN_ITEM_GAS` (10.2M).
    uint256 public constant MAX_CLAIMS = 50;
    /// @inheritdoc IClaimRouter
    /// @dev Without a floor, a batch that never reverts lets gas estimation settle on a limit at
    ///      which every item runs out of gas and nothing is claimed.
    uint256 public constant MIN_ITEM_GAS = 200_000;

    uint256 private constant _MAX_REASON_BYTES = 256;

    /// @inheritdoc IClaimRouter
    function claim(Claim[] calldata claims, bool continueOnFailure)
        external
        returns (uint256[] memory amounts)
    {
        if (claims.length > MAX_CLAIMS) revert TooManyClaims(claims.length);
        amounts = new uint256[](claims.length);
        for (uint256 i; i < claims.length; ++i) {
            amounts[i] = _claim(claims[i], i, continueOnFailure, claims.length - i);
        }
    }

    function _claim(Claim calldata item, uint256 index, bool keepGoing, uint256 remaining)
        private
        returns (uint256 amount)
    {
        address wallet = item.wallet;
        uint256 size;
        bytes memory reason;
        if (wallet.code.length == 0) {
            reason = abi.encodeWithSelector(ClaimTargetHasNoCode.selector, wallet);
        } else {
            bytes memory input = abi.encodeCall(ISplitWallet.release, (item.asset, item.payee));
            // Continue mode splits the gas left between this call, the later items and the router,
            // recomputed per item so a failed item's share passes on. There is no fixed stipend.
            uint256 callGas = keepGoing ? gasleft() / (remaining + 1) : gasleft();
            if (keepGoing && callGas < MIN_ITEM_GAS) revert ClaimInsufficientGas(index, callGas);
            bool ok;
            assembly ("memory-safe") {
                ok := call(callGas, wallet, 0, add(input, 0x20), mload(input), 0x00, 0x20)
                size := returndatasize()
                amount := mload(0x00)
            }
            if (ok && size == 32) return amount;
            amount = 0;
            if (ok) {
                reason = abi.encodeWithSelector(InvalidClaimReturnData.selector, size);
            } else {
                uint256 length = size > _MAX_REASON_BYTES ? _MAX_REASON_BYTES : size;
                reason = new bytes(length);
                assembly ("memory-safe") {
                    returndatacopy(add(reason, 0x20), 0, length)
                }
            }
        }
        if (!keepGoing) revert ClaimCallFailed(index, wallet, size, reason);
        emit ClaimFailed(wallet, item.asset, item.payee, index, size, reason);
    }
}
