// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
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
contract ClaimRouter is IClaimRouter {
    /// @inheritdoc IClaimRouter
    /// @dev A worst-case plain item costs about 130,000 gas, so a full atomic batch stays under
    ///      7M, and continue mode needs at most `(MAX_CLAIMS + 1) * MIN_ITEM_GAS` (10.2M).
    uint256 public constant MAX_CLAIMS = 50;
    /// @inheritdoc IClaimRouter
    uint256 public constant MIN_ITEM_GAS = 200_000;
    /// @inheritdoc IClaimRouter
    /// @dev A worst-case signed item (a 200,000-gas ERC-1271 check, a 4 KiB signature in
    ///      calldata, a cold release) costs under 400,000 gas, so a full batch stays under the
    ///      cap in both modes; see `test/economics/GasCap.t.sol`.
    uint256 public constant MAX_SIGNED_CLAIMS = 20;
    /// @inheritdoc IClaimRouter
    uint256 public constant MIN_SIGNED_ITEM_GAS = 450_000;

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
            uint256 callGas = item.keepGoing ? gasleft() / (item.remaining + 1) : gasleft();
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
        if (!item.keepGoing) revert ClaimCallFailed(item.index, wallet, size, reason);
        emit ClaimFailed(wallet, item.asset, item.payee, item.index, size, reason);
    }
}
