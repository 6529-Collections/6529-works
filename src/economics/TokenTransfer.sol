// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";

/// @title TokenTransfer
/// @notice Strict asset moves for every money path (ADR 0001 section 5). A token call counts only
///         when it returns exactly one word holding `true`, and both balances must then move by
///         exactly the amount. Fee-on-transfer, rebasing-rounding, no-return and false-returning
///         tokens therefore fail closed instead of corrupting accounting. ETH sends share one
///         primitive that copies no return data.
/// @dev Internal functions only, so nothing here is a linked library. Calls copy at most one word of
///      return data, so a return-data bomb costs the token, not the caller.
library TokenTransfer {
    /// @notice The token reverted, returned something other than `true`, or has no code.
    error TokenCallFailed(address asset, bytes4 selector);
    /// @notice A balance did not move by exactly the transferred amount.
    error TokenBalanceMismatch(address asset);
    /// @notice A token read failed or did not return exactly one word.
    error TokenReadFailed(address asset);
    /// @notice The caller cannot forward `gasLimit` to the token in full.
    error TokenInsufficientGas(uint256 gasLimit);

    /// @dev Requests all available gas (EIP-150 caps the forwarded amount).
    uint256 private constant _ALL_GAS = type(uint256).max;

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

    /// @notice The total supply of `asset`, read strictly.
    function totalSupply(address asset) internal view returns (uint256) {
        return _read(asset, abi.encodeCall(IERC20.totalSupply, ()));
    }

    /// @notice The allowance `owner` gave `spender` in `asset`, read strictly.
    function allowance(address asset, address owner, address spender)
        internal
        view
        returns (uint256)
    {
        return _read(asset, abi.encodeCall(IERC20.allowance, (owner, spender)));
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
        if (!_transfer(asset, to, amount, _ALL_GAS)) {
            revert TokenCallFailed(asset, IERC20.transfer.selector);
        }
    }

    /// @notice Transfers exactly `amount` of `asset` from this contract to `to`, giving the token
    ///         exactly `gasLimit` gas, so a refusal is the token's and never the caller's gas.
    /// @return moved False when the token reverted, or returned `false` and moved nothing; the
    ///         caller may then take another route. Reverts on any other misbehaviour, and when the
    ///         caller cannot forward `gasLimit` in full.
    function tryTransferExact(address asset, address to, uint256 amount, uint256 gasLimit)
        internal
        returns (bool moved)
    {
        return _transfer(asset, to, amount, gasLimit);
    }

    function _transfer(address asset, address to, uint256 amount, uint256 gasLimit)
        private
        returns (bool)
    {
        return _moveExact(
            asset,
            address(this),
            to,
            amount,
            IERC20.transfer.selector,
            abi.encodeCall(IERC20.transfer, (to, amount)),
            gasLimit
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
            _ALL_GAS
        );
    }

    /// @notice Approves `amount` of `asset` to `spender`, or reverts unless the token returns
    ///         exactly `true`.
    /// @dev The resulting allowance is not read back: a caller that needs it consumed exactly
    ///      checks the allowance after the pull (see `RevenuePayment.payERC20`). Too little makes
    ///      the pull fail; anything left over fails that check.
    function approve(address asset, address spender, uint256 amount) internal {
        if (
            _call(asset, abi.encodeCall(IERC20.approve, (spender, amount)), _ALL_GAS)
                != Outcome.True
        ) {
            revert TokenCallFailed(asset, IERC20.approve.selector);
        }
    }

    /// @dev Only a transfer with a bounded `gasLimit` tolerates a clean refusal; the strict paths
    ///      (all gas) revert on any failure.
    function _moveExact(
        address asset,
        address from,
        address to,
        uint256 amount,
        bytes4 selector,
        bytes memory data,
        uint256 gasLimit
    ) private returns (bool) {
        bool tolerateFailure = gasLimit != _ALL_GAS;
        uint256 fromBefore = balanceOf(asset, from);
        uint256 toBefore = balanceOf(asset, to);
        if (fromBefore < amount) revert TokenBalanceMismatch(asset);
        Outcome outcome = _call(asset, data, gasLimit);
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

    function _call(address asset, bytes memory data, uint256 gasLimit) private returns (Outcome) {
        if (gasLimit != _ALL_GAS && !BoundedCall.hasSufficientGas(gasleft(), gasLimit, 5_000)) {
            revert TokenInsufficientGas(gasLimit);
        }
        bool ok;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            ok := call(gasLimit, asset, 0, add(data, 0x20), mload(data), 0x00, 0x20)
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
