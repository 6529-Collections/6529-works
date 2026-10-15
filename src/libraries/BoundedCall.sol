// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BoundedCall
/// @notice A `staticcall` that caps both the gas it forwards and the return data it copies.
/// @dev Before calling, the caller must hold `gasLimit + ceil(gasLimit / 63) + reserve`, so
///      the callee always receives its full `gasLimit` under EIP-150 and a failure is never
///      caused by the caller's own gas supply. A shortfall reverts instead of being reported
///      as a failed call. Return data is never copied unless it fits `maxReturn`.
///
///      Glamsterdam (CALLS-3): {hasSufficientGas} also guards the protocol's fixed-gas CALLs
///      (payouts, token transfers, deliveries), and there it guarantees regular gas only. Under
///      the EIP-8037 draft a transaction whose gas limit exceeds 2^24 carries a state-gas
///      reservoir that passes through a fixed-gas call, so the allowance does not cap the state
///      gas a callee spends creating storage or accounts, and whether a state-writing callee
///      succeeds can depend on the caller's gas limit. This follows the draft; it has not been
///      reproduced on Sepolia, which has only shown that transactions above the cap are
///      accepted. Keepers should send at most 16,777,216 (2^24) gas, which leaves no reservoir.
///      {tryRead}'s STATICCALL creates no state and is unaffected. See
///      docs/audit/known-limitations.md, LIM-GAS-2.
library BoundedCall {
    /// @notice Gas kept for the CALL itself on top of EIP-150 retention. The target account is
    ///         already warm (its code size was read first), so the CALL costs about 100 gas.
    uint256 internal constant CALL_RESERVE = 1_000;

    /// @notice The caller holds too little gas to forward `gasLimit` and complete afterwards.
    error BoundedCallInsufficientGas(uint256 gasLimit);
    /// @notice The target has no code, reverted, ran out of gas or returned too much data.
    error BoundedCallFailed(address target);
    /// @notice The target returned data that is not the canonical encoding expected.
    error BoundedCallMalformedReturn(address target);

    /// @notice Returns whether `available` gas covers forwarding `gasLimit` in full and then
    ///         `completionBuffer` more: `gasLimit + ceil(gasLimit / 63) + completionBuffer`.
    ///         Regular gas only: see the library's note on Glamsterdam.
    /// @dev Subtraction-form comparisons cannot overflow for any input.
    function hasSufficientGas(uint256 available, uint256 gasLimit, uint256 completionBuffer)
        internal
        pure
        returns (bool)
    {
        if (available < gasLimit) return false;
        uint256 afterLimit = available - gasLimit;
        uint256 retention = gasLimit / 63 + (gasLimit % 63 == 0 ? 0 : 1);
        if (afterLimit < retention) return false;
        return afterLimit - retention >= completionBuffer;
    }

    /// @notice Calls `target` with `input`, forwarding exactly `gasLimit` gas.
    /// @param completionBuffer Gas the caller needs after the call returns.
    /// @return ok False when the target has no code, fails, or returns more than `maxReturn`.
    /// @return result The return data when `ok`; empty otherwise.
    function tryRead(
        address target,
        bytes memory input,
        uint256 gasLimit,
        uint256 maxReturn,
        uint256 completionBuffer
    ) internal view returns (bool ok, bytes memory result) {
        if (target.code.length == 0) return (false, result);
        // completionBuffer + CALL_RESERVE overflows only for absurd buffers, which then revert.
        if (!hasSufficientGas(gasleft(), gasLimit, completionBuffer + CALL_RESERVE)) {
            revert BoundedCallInsufficientGas(gasLimit);
        }
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(input, 0x20), mload(input), 0, 0)
            size := returndatasize()
        }
        if (!ok || size > maxReturn) return (false, result);
        result = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(result, 0x20), 0, size)
        }
    }

    /// @notice Like {tryRead}, but reverts with {BoundedCallFailed} instead of returning false.
    function read(
        address target,
        bytes memory input,
        uint256 gasLimit,
        uint256 maxReturn,
        uint256 completionBuffer
    ) internal view returns (bytes memory result) {
        bool ok;
        (ok, result) = tryRead(target, input, gasLimit, maxReturn, completionBuffer);
        if (!ok) revert BoundedCallFailed(target);
    }

    /// @notice Reads exactly one 32-byte word.
    function readWord(
        address target,
        bytes memory input,
        uint256 gasLimit,
        uint256 completionBuffer
    ) internal view returns (bytes32 word) {
        bytes memory result = read(target, input, gasLimit, 32, completionBuffer);
        if (result.length != 32) revert BoundedCallMalformedReturn(target);
        assembly ("memory-safe") {
            word := mload(add(result, 0x20))
        }
    }

    /// @notice Reads a canonically ABI-encoded `string` of at most `maxLength` bytes.
    function readString(
        address target,
        bytes memory input,
        uint256 gasLimit,
        uint256 maxLength,
        uint256 completionBuffer
    ) internal view returns (string memory value) {
        bytes memory result = read(
            target, input, gasLimit, 64 + _roundUp(maxLength), completionBuffer
        );
        bool ok;
        (ok, value) = decodeString(result, maxLength);
        if (!ok) revert BoundedCallMalformedReturn(target);
    }

    /// @notice Decodes `data` as exactly one canonical ABI `string`: offset 32, a length of at
    ///         most `maxLength`, no trailing bytes and zero padding.
    function decodeString(bytes memory data, uint256 maxLength)
        internal
        pure
        returns (bool ok, string memory value)
    {
        if (data.length < 64) return (false, value);
        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            offset := mload(add(data, 0x20))
            length := mload(add(data, 0x40))
        }
        // `length > data.length` is a cheap early-out, not the payload check. It makes an absurd
        // length (for example near 2**256) return `false` instead of overflowing in `_roundUp`
        // when the caller's `maxLength` is huge. The exact check `data.length - 64 == padded`
        // below is what binds the length to the payload and rejects trailing bytes.
        if (offset != 32 || length > maxLength || length > data.length) return (false, value);
        uint256 padded = _roundUp(length);
        if (data.length - 64 != padded) return (false, value);
        if (padded != length) {
            uint256 lastWord;
            assembly ("memory-safe") {
                lastWord := mload(add(data, add(0x40, padded)))
            }
            if (lastWord << ((length % 32) * 8) != 0) return (false, value);
        }
        return (true, abi.decode(data, (string)));
    }

    function _roundUp(uint256 length) private pure returns (uint256) {
        return (length + 31) & ~uint256(31);
    }
}
