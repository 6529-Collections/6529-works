// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { IClaimRouter } from "./interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "./interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "./interfaces/ISplitWallet.sol";

/// @title ClaimRouter
/// @notice Permissionless, stateless batch claims across split wallets (ADR 0001 section 7). Plain
///         items call `release(asset, payee)`, which pays only a fixed payee's own account; signed
///         items call `releaseWithAuthorization`, which pays only where the payee signed.
/// @dev No storage, owner, approvals, `receive` or `fallback`, so it never holds funds and reentry
///      gains nothing; the wallets enforce entitlement, accounting and who may pull. Hostile
///      targets are contained: at most one word of return data is copied on success and at most
///      256 bytes of revert data on failure, and in continue mode each call gets only its share of
///      the gas left, but never less than its minimum.
///      Continue mode does not report a gas shortfall below {SHORTFALL_REVERT_CEILING} as an
///      item's failure. An item offered less than the ceiling that fails after spending all but
///      EIP-150's 1/64 reserve of its gas (in its own frame or in a call it made), or that fails
///      because an ERC-1271 check could not get its gas (`BoundedCallInsufficientGas`), reverts
///      the batch with {ClaimInsufficientGas}, so `eth_estimateGas` raises the limit. At the
///      estimate, every item is paid, fails with gas to spare, or failed despite at least the
///      ceiling and is skipped. The ceiling, about twice what a first signed release needs on
///      Sepolia's Glamsterdam, covers honest items under that schedule with room; it bounds what a
///      party to an item (a fixed co-payee, a signed recipient, a token) can force by burning gas:
///      once its item is offered the ceiling, it is skipped like any other failure. Below it, such
///      a party can still revert a batch; keepers simulate privately and split batches whose items
///      involve contract payees or unfamiliar tokens. The minimums are only the floor of each
///      item's share.
///
///      Glamsterdam (CALLS-3, observed on Sepolia): an item's share caps its regular gas only.
///      A release that creates storage or an account draws state gas from the transaction's
///      EIP-8037 reservoir, so an item's outcome can depend on the batch's gas limit, and the
///      caller pays for the state growth of every item it runs. A failed item pays nothing and
///      can be claimed again. Keepers should send at most 2^24 gas, which leaves no reservoir
///      (`BoundedCall`; docs/audit/known-limitations.md, LIM-GAS-2).
contract ClaimRouter is IClaimRouter {
    /// @inheritdoc IClaimRouter
    /// @dev In Prague gas a worst-case plain item costs about 130,000, so a full atomic batch
    ///      stays under 7M, and continue mode needs at least `(MAX_CLAIMS + 1) * MIN_ITEM_GAS`
    ///      (10.2M). Under Glamsterdam a first release also pays for its new slots and, to a
    ///      fresh payee, a new account (about 89,000 and 184,000 each on Sepolia), so a full batch
    ///      of first releases may not fit one transaction: it then reverts, never pays part of
    ///      the batch silently, and the caller splits it.
    uint256 public constant MAX_CLAIMS = 50;
    /// @inheritdoc IClaimRouter
    uint256 public constant MIN_ITEM_GAS = 200_000;
    /// @inheritdoc IClaimRouter
    /// @dev In Prague gas a worst-case signed item (a 200,000-gas ERC-1271 check, a 4 KiB
    ///      signature in calldata, a cold release) costs under 400,000, so a full batch stays
    ///      under the cap in both modes; see `test/economics/GasCap.t.sol`. The Glamsterdam note
    ///      on {MAX_CLAIMS} applies here too.
    uint256 public constant MAX_SIGNED_CLAIMS = 20;
    /// @inheritdoc IClaimRouter
    uint256 public constant MIN_SIGNED_ITEM_GAS = 450_000;
    /// @inheritdoc IClaimRouter
    /// @dev About twice a first signed release to a fresh recipient on Sepolia's Glamsterdam
    ///      (about 716,000: the release's new slots, the nonce word and the account).
    uint256 public constant SHORTFALL_REVERT_CEILING = 1_500_000;

    uint256 private constant _MAX_REASON_BYTES = 256;

    struct Item {
        address wallet;
        address asset;
        uint256 payee;
        uint256 index;
        uint256 remaining;
        uint256 minGas;
        bool keepGoing;
    }

    /// @inheritdoc IClaimRouter
    function claim(Claim[] calldata claims, bool continueOnFailure)
        external
        returns (uint256[] memory amounts)
    {
        uint256 count = claims.length;
        if (count > MAX_CLAIMS) revert TooManyClaims(count);
        amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            Claim calldata c = claims[i];
            amounts[i] = _call(
                Item(c.wallet, c.asset, c.payee, i, count - i, MIN_ITEM_GAS, continueOnFailure),
                abi.encodeCall(ISplitWallet.release, (c.asset, c.payee))
            );
        }
    }

    /// @inheritdoc IClaimRouter
    function claimSigned(SignedClaim[] calldata claims, bool continueOnFailure)
        external
        returns (uint256[] memory amounts)
    {
        uint256 count = claims.length;
        if (count > MAX_SIGNED_CLAIMS) revert TooManyClaims(count);
        amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            IReleaseVerifier.Authorization calldata a = claims[i].authorization;
            amounts[i] = _call(
                Item(
                    a.wallet, a.asset, a.payee, i, count - i, MIN_SIGNED_ITEM_GAS, continueOnFailure
                ),
                abi.encodeCall(ISplitWallet.releaseWithAuthorization, (a, claims[i].signature))
            );
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IClaimRouter).interfaceId
                || interfaceId == type(IERC165).interfaceId;
    }

    function _call(Item memory item, bytes memory input) private returns (uint256 amount) {
        address wallet = item.wallet;
        uint256 size;
        bytes memory reason;
        if (wallet.code.length == 0) {
            reason = abi.encodeWithSelector(ClaimTargetHasNoCode.selector, wallet);
        } else {
            // Continue mode splits the gas left between this call, the later items and the router,
            // recomputed per item so a failed item's share passes on.
            uint256 available = gasleft();
            uint256 callGas = item.keepGoing ? available / (item.remaining + 1) : available;
            if (item.keepGoing && callGas < item.minGas) {
                revert ClaimInsufficientGas(item.index, callGas);
            }
            bool ok;
            assembly ("memory-safe") {
                ok := call(callGas, wallet, 0, add(input, 0x20), mload(input), 0x00, 0x20)
                size := returndatasize()
                amount := mload(0x00)
            }
            if (ok && size == 32) return amount;
            uint256 spent = available - gasleft();
            amount = 0;
            if (ok) {
                reason = abi.encodeWithSelector(InvalidClaimReturnData.selector, size);
            } else {
                uint256 length = size > _MAX_REASON_BYTES ? _MAX_REASON_BYTES : size;
                reason = new bytes(length);
                assembly ("memory-safe") {
                    returndatacopy(add(reason, 0x20), 0, length)
                }
                // A failure below the ceiling that spent all but the 1/64 reserve of the item's
                // gas (the wallet's, or a payee's or token's under it), or an ERC-1271 check that
                // could not get its gas, may be a shortfall: revert so estimation raises the
                // limit, instead of reporting a failure the caller paid for.
                if (
                    item.keepGoing && callGas < SHORTFALL_REVERT_CEILING
                        && (spent > callGas - callGas / 64
                            // The first four bytes of the revert data: its error selector.
                            // forge-lint: disable-next-line(unsafe-typecast)
                            || bytes4(reason) == BoundedCall.BoundedCallInsufficientGas.selector)
                ) revert ClaimInsufficientGas(item.index, callGas);
            }
        }
        if (!item.keepGoing) revert ClaimCallFailed(item.index, wallet, size, reason);
        emit ClaimFailed(wallet, item.asset, item.payee, item.index, size, reason);
    }
}
