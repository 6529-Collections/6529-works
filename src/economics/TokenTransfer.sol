// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";

/// @title TokenTransfer
/// @notice Strict asset moves for every money path (ADR 0001 section 5). A token call counts only
///         when it returns exactly one word holding `true`, and both balances must then move by
///         exactly the amount. Fee-on-transfer, rebasing-rounding, no-return and false-returning
///         tokens therefore fail closed instead of corrupting accounting. ETH sends share one
///         primitive that copies no return data. One exception accepts a token that returns
///         nothing: {transferExactAllowingNoReturn}, which split wallets release with (ECO-23).
/// @dev Internal functions only, so nothing here is a linked library. Calls copy at most one word
///      of return data, so a return-data bomb costs the token, not the caller.
library TokenTransfer {
    /// @notice The token reverted, returned something other than `true`, or has no code.
    error TokenCallFailed(address asset, bytes4 selector);
    /// @notice A balance did not move by exactly the transferred amount.
    error TokenBalanceMismatch(address asset);
    /// @notice A token read failed or did not return exactly one word.
    error TokenReadFailed(address asset);
    enum Outcome {
        Reverted,
        True,
        False,
        Empty,
        Malformed
    }

    /// @notice The `account` balance of `asset`, read strictly.
    function balanceOf(address asset, address account) internal view returns (uint256) {
        return _read(asset, abi.encodeCall(IERC20.balanceOf, (account)));
    }

    /// @notice The total supply of `asset`, read strictly.
    function totalSupply(address asset) internal view returns (uint256) {
        return _read(asset, abi.encodeCall(IERC20.totalSupply, ()));
    }

    /// @notice Sends `amount` wei to `to` with at most `gasLimit` gas, copying no return data.
    /// @return ok Whether the call succeeded.
    function sendETH(address to, uint256 amount, uint256 gasLimit) internal returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(gasLimit, to, amount, 0, 0, 0, 0)
        }
    }

    /// @notice Transfers exactly `amount` of `asset` from this contract to `to`, or reverts.
    function transferExact(address asset, address to, uint256 amount) internal {
        _moveExact(
            asset,
            address(this),
            to,
            amount,
            IERC20.transfer.selector,
            abi.encodeCall(IERC20.transfer, (to, amount))
        );
    }

    /// @notice Transfers exactly `amount` of `asset` from this contract to `to`, or reverts, like
    ///         {transferExact}, except that a call returning no data also counts: the exact
    ///         balance deltas on both sides, not the return value, prove the move. A `false`, any
    ///         return other than nothing or one word holding `true`, and any balance change other
    ///         than exactly `amount` on both sides still revert. An account without code never
    ///         gets this far: its `balanceOf` read, before the call, fails (`TokenReadFailed`).
    /// @dev For a holder that has no other way out of a token it did not choose, such as a split
    ///      wallet paid royalties by a marketplace. Never use it on a path that takes a sale
    ///      currency in.
    function transferExactAllowingNoReturn(address asset, address to, uint256 amount) internal {
        uint256 fromBefore = balanceOf(asset, address(this));
        uint256 toBefore = balanceOf(asset, to);
        if (fromBefore < amount) revert TokenBalanceMismatch(asset);
        Outcome outcome = _call(asset, abi.encodeCall(IERC20.transfer, (to, amount)));
        if (outcome != Outcome.True && outcome != Outcome.Empty) {
            revert TokenCallFailed(asset, IERC20.transfer.selector);
        }
        if (
            balanceOf(asset, address(this)) != fromBefore - amount
                || balanceOf(asset, to) != toBefore + amount
        ) revert TokenBalanceMismatch(asset);
    }

    /// @notice Pulls exactly `amount` of `asset` from `from` into this contract, or reverts.
    function pullExact(address asset, address from, uint256 amount) internal {
        _moveExact(
            asset,
            from,
            address(this),
            amount,
            IERC20.transferFrom.selector,
            abi.encodeCall(IERC20.transferFrom, (from, address(this), amount))
        );
    }

    /// @dev Calls the token with all gas and reverts unless it returns exactly `true` and both
    ///      balances move by exactly `amount`.
    function _moveExact(
        address asset,
        address from,
        address to,
        uint256 amount,
        bytes4 selector,
        bytes memory data
    ) private {
        uint256 fromBefore = balanceOf(asset, from);
        uint256 toBefore = balanceOf(asset, to);
        if (fromBefore < amount) revert TokenBalanceMismatch(asset);
        // Anything but one word holding `true`: a revert, a `false`, no return value, or a
        // malformed one.
        if (_call(asset, data) != Outcome.True) revert TokenCallFailed(asset, selector);
        if (
            balanceOf(asset, from) != fromBefore - amount
                || balanceOf(asset, to) != toBefore + amount
        ) revert TokenBalanceMismatch(asset);
    }

    /// @dev Forwards all the gas EIP-150 allows and copies at most one word of return data.
    function _call(address asset, bytes memory data) private returns (Outcome) {
        bool ok;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            ok := call(gas(), asset, 0, add(data, 0x20), mload(data), 0x00, 0x20)
            size := returndatasize()
            word := mload(0x00)
        }
        if (!ok) return Outcome.Reverted;
        if (size == 0) return Outcome.Empty;
        if (size != 32 || word > 1) return Outcome.Malformed;
        return word == 1 ? Outcome.True : Outcome.False;
    }

    function _read(address asset, bytes memory data) private view returns (uint256 word) {
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(gas(), asset, add(data, 0x20), mload(data), 0x00, 0x20)
            size := returndatasize()
            word := mload(0x00)
        }
        if (!ok || size != 32) revert TokenReadFailed(asset);
    }
}
