// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TokenTransfer
/// @notice Strict ERC-20 moves for every money path (ADR 0001 section 5). A token call counts only
///         when it returns exactly one word holding `true`, and both balances must then move by
///         exactly the amount. Fee-on-transfer, rebasing-rounding, no-return and false-returning
///         tokens therefore fail closed instead of corrupting accounting.
/// @dev Internal functions only, so nothing here is a linked library. Calls copy at most one word of
///      return data, so a return-data bomb costs the token, not the caller.
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
        Malformed
    }

    /// @notice The `account` balance of `asset`, read strictly.
    function balanceOf(address asset, address account) internal view returns (uint256) {
        return _read(asset, abi.encodeCall(IERC20.balanceOf, (account)));
    }

    /// @notice The allowance `owner` gave `spender` in `asset`, read strictly.
    function allowance(address asset, address owner, address spender)
        internal
        view
        returns (uint256)
    {
        return _read(asset, abi.encodeCall(IERC20.allowance, (owner, spender)));
    }

    /// @notice Transfers exactly `amount` of `asset` from this contract to `to`, or reverts.
    function transferExact(address asset, address to, uint256 amount) internal {
        if (!tryTransferExact(asset, to, amount)) {
            revert TokenCallFailed(asset, IERC20.transfer.selector);
        }
    }

    /// @notice Transfers exactly `amount` of `asset` from this contract to `to`.
    /// @return moved False when the token reverted, or returned `false` and moved nothing; the
    ///         caller may then take another route. Reverts on any other misbehaviour.
    function tryTransferExact(address asset, address to, uint256 amount)
        internal
        returns (bool moved)
    {
        return _moveExact(
            asset,
            address(this),
            to,
            amount,
            IERC20.transfer.selector,
            abi.encodeCall(IERC20.transfer, (to, amount)),
            true
        );
    }

    /// @notice Pulls exactly `amount` of `asset` from `from` into this contract, or reverts.
    function pullExact(address asset, address from, uint256 amount) internal {
        _moveExact(
            asset,
            from,
            address(this),
            amount,
            IERC20.transferFrom.selector,
            abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)),
            false
        );
    }

    /// @notice Approves exactly `amount` of `asset` to `spender`, or reverts.
    function approveExact(address asset, address spender, uint256 amount) internal {
        if (
            _call(asset, abi.encodeCall(IERC20.approve, (spender, amount))) != Outcome.True
                || allowance(asset, address(this), spender) != amount
        ) revert TokenCallFailed(asset, IERC20.approve.selector);
    }

    function _moveExact(
        address asset,
        address from,
        address to,
        uint256 amount,
        bytes4 selector,
        bytes memory data,
        bool tolerateFailure
    ) private returns (bool) {
        uint256 fromBefore = balanceOf(asset, from);
        uint256 toBefore = balanceOf(asset, to);
        if (fromBefore < amount) revert TokenBalanceMismatch(asset);
        Outcome outcome = _call(asset, data);
        if (outcome == Outcome.Reverted && tolerateFailure) return false;
        if (outcome == Outcome.Malformed || outcome == Outcome.Reverted) {
            revert TokenCallFailed(asset, selector);
        }
        uint256 fromAfter = balanceOf(asset, from);
        uint256 toAfter = balanceOf(asset, to);
        if (outcome == Outcome.False) {
            if (!tolerateFailure) revert TokenCallFailed(asset, selector);
            if (fromAfter != fromBefore || toAfter != toBefore) revert TokenBalanceMismatch(asset);
            return false;
        }
        if (fromAfter != fromBefore - amount || toAfter != toBefore + amount) {
            revert TokenBalanceMismatch(asset);
        }
        return true;
    }

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
