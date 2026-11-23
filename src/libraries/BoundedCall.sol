// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title BoundedCall
/// @notice External calls whose failure can be told apart from the caller running short of gas.
///         Two families.
///
///         FORWARD-ALL, the gas rule for permanent contracts (no gas number anywhere):
///         - `tryReadAll(target, input, maxReturn) -> (bool ok, bytes data)`: STATICCALL.
///         - `tryCallAll(target, value, input, maxReturn) -> (bool ok, bytes data)`: CALL.
///         - `tryReadWordAll(target, input) -> (bool ok, bytes32 word)`: STATICCALL whose answer
///           must be exactly one 32-byte word.
///         - `supportsERC165(account)` and `supportsInterface(account, id)`: ERC-165 detection
///           with the answers of OpenZeppelin's `ERC165Checker`; `supportsInterfaceUnchecked`
///           is one probe without the ERC-165 precheck.
///         Each forwards all the gas EIP-150 allows (all but 1/64) and copies at most
///         `maxReturn` bytes of return data (32 for the word and ERC-165 forms). Outcomes:
///         1. Answer: the call succeeded and returned at most `maxReturn` bytes; `ok` is true
///            and `data` holds them. A frame that succeeded ran to completion, so it was not
///            starved: what it returned is its answer, and the caller judges its shape.
///         2. Refusal: `ok` is false. The call failed (reverted, ran out of gas, hit an invalid
///            opcode) and left the caller more than 1/8 of the gas it held just before the
///            call, or it succeeded with more than `maxReturn` bytes. After a failure `data`
///            holds the revert data when it fits `maxReturn`; otherwise it is empty.
///         3. Shortfall: the call failed and left the caller at most 1/8 of the gas it held just
///            before the call. The function reverts with {BoundedCallShortfall}, so a shortfall
///            never reads as a refusal, an empty answer or a default.
///
///         Why 1/8 ({SHORTFALL_DIVISOR}). A callee that runs out of gas consumes all it was
///         forwarded, which leaves the caller the 1/64 that EIP-150 retained, less a few gas.
///         Through nested frames that each forward all they may (a proxy, its implementation, a
///         wallet's own ERC-1271 owner), each frame keeps 1/64 of what it held, so an
///         out-of-gas k frames below the caller leaves it at most `1 - (63/64)^k` of what it
///         held: 11.8% at k = 8. Work a frame does after its child failed only lowers that. So
///         an honest out-of-gas up to eight frames deep reads as a shortfall whatever gas the
///         transaction carries: no sender can pick a gas limit that turns a callee's
///         out-of-gas into a refusal. The converse gives a callee nothing: one that burns gas
///         and then reverts just above the threshold has refused, as it could by reverting at
///         once, and one that burns everything makes the transaction revert, as it always can.
///         Residuals, accepted: (a) a refusal that itself consumes more than about 7/8 of the
///         gas forwarded reads as a shortfall, so the caller retries with more gas, and any
///         callee whose work is bounded refuses readably once given enough; (b) a callee that
///         catches its own out-of-gas and then returns successfully has answered, by its own
///         code's choice. The divisor is a ratio, not a gas amount: no repricing changes what
///         it decides.
///
///         FIXED-GAS (`tryRead`, `read`, `readWord`, `readString`, `hasSufficientGas`): a
///         `staticcall` that caps both the gas it forwards and the return data it copies. Kept
///         for replaceable contracts that bound a hostile target's cost (the consolidation
///         adapter, sale adapters); permanent contracts, and the renderer that finalized works
///         pin, use the forward-all family (ADR 0007's gas rule). Both families copy at most
///         `maxReturn` bytes: the gas rule removes the gas cap, never the return-data bound.
/// @dev Fixed-gas family: before calling, the caller must hold
///      `gasLimit + ceil(gasLimit / 63) + reserve`, so the callee always receives its full
///      `gasLimit` under EIP-150 and a failure is never caused by the caller's own gas supply.
///      A shortfall reverts instead of being reported as a failed call. Return data is never
///      copied unless it fits `maxReturn`.
///
///      Glamsterdam (LIM-GAS-2): {hasSufficientGas} also guards the protocol's fixed-gas CALLs
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
    /// @notice A forward-all call that fails and leaves the caller at most this fraction (1/8)
    ///         of the gas it held just before the call is a shortfall. A ratio, not a gas
    ///         amount; the library notes say why 1/8.
    uint256 internal constant SHORTFALL_DIVISOR = 8;

    /// @notice Gas kept for the CALL itself on top of EIP-150 retention. The target account is
    ///         already warm (its code size was read first), so the CALL costs about 100 gas.
    uint256 internal constant CALL_RESERVE = 1_000;

    /// @notice The caller holds too little gas to forward `gasLimit` and complete afterwards.
    error BoundedCallInsufficientGas(uint256 gasLimit);
    /// @notice The target has no code, reverted, ran out of gas or returned too much data.
    error BoundedCallFailed(address target);
    /// @notice The target returned data that is not the canonical encoding expected.
    error BoundedCallMalformedReturn(address target);
    /// @notice A forward-all call to `target` failed and left at most 1/8 of the gas held before
    ///         it: the transaction ran short of gas, and a higher gas limit is needed. It never
    ///         means that `target` refused.
    error BoundedCallShortfall(address target);

    // ------------------------------------------------------------------ forward-all family

    /// @notice STATICCALLs `target` with `input`, forwarding all the gas EIP-150 allows.
    /// @dev Reverts with {BoundedCallShortfall} on a shortfall (library notes). A target without
    ///      code succeeds with no data, as the EVM does; callers check the answer's shape.
    /// @param target The contract to read.
    /// @param input The calldata.
    /// @param maxReturn The most return data, in bytes, that is copied.
    /// @return ok True for an answer of at most `maxReturn` bytes; false for a refusal.
    /// @return data The answer when `ok`; after a failure, the revert data if it fits
    ///         `maxReturn`; otherwise empty.
    function tryReadAll(address target, bytes memory input, uint256 maxReturn)
        internal
        view
        returns (bool ok, bytes memory data)
    {
        uint256 before;
        uint256 size;
        assembly ("memory-safe") {
            before := gas()
            ok := staticcall(gas(), target, add(input, 0x20), mload(input), 0, 0)
            size := returndatasize()
        }
        return _outcome(target, ok, size, before, maxReturn);
    }

    /// @notice CALLs `target` with `value` and `input`, forwarding all the gas EIP-150 allows.
    /// @dev The outcomes of {tryReadAll}. A CALL whose `value` exceeds this contract's balance
    ///      fails at once with its gas unspent: a refusal, never a shortfall.
    /// @param target The contract or account to call.
    /// @param value The wei to send.
    /// @param input The calldata.
    /// @param maxReturn The most return data, in bytes, that is copied.
    /// @return ok True for an answer of at most `maxReturn` bytes; false for a refusal.
    /// @return data As for {tryReadAll}.
    function tryCallAll(address target, uint256 value, bytes memory input, uint256 maxReturn)
        internal
        returns (bool ok, bytes memory data)
    {
        uint256 before;
        uint256 size;
        assembly ("memory-safe") {
            before := gas()
            ok := call(gas(), target, value, add(input, 0x20), mload(input), 0, 0)
            size := returndatasize()
        }
        return _outcome(target, ok, size, before, maxReturn);
    }

    /// @notice STATICCALLs `target` with `input`, forwarding all the gas EIP-150 allows, for an
    ///         answer of exactly one 32-byte word. Copies at most 32 bytes.
    /// @dev Reverts with {BoundedCallShortfall} on a shortfall. Any other failure, and a
    ///      successful answer of any other length, is a refusal.
    /// @param target The contract to read.
    /// @param input The calldata.
    /// @return ok True when the call succeeded with exactly 32 bytes.
    /// @return word The answer when `ok`; zero otherwise.
    function tryReadWordAll(address target, bytes memory input)
        internal
        view
        returns (bool ok, bytes32 word)
    {
        uint256 before;
        bool success;
        assembly ("memory-safe") {
            before := gas()
            success := staticcall(gas(), target, add(input, 0x20), mload(input), 0, 0x20)
            ok := and(success, eq(returndatasize(), 0x20))
            if ok { word := mload(0) }
        }
        if (!success) _checkShortfall(target, before);
    }

    /// @notice ERC-165 detection: whether `account` answers true for `IERC165` and false for
    ///         `0xffffffff`. The answers of OpenZeppelin `ERC165Checker.supportsERC165`, except
    ///         that a shortfall reverts with {BoundedCallShortfall}.
    /// @dev `supportsInterface(account, type(IERC165).interfaceId)`: one probe more than needed,
    ///      which keeps a single probe loop in every contract.
    /// @param account The address to probe.
    /// @return Whether `account` implements ERC-165.
    function supportsERC165(address account) internal view returns (bool) {
        return _erc165(account, 0x01ffc9a7, 3);
    }

    /// @notice Whether `account` implements ERC-165 and declares `interfaceId`. The answers of
    ///         OpenZeppelin `ERC165Checker.supportsInterface`, except that a shortfall reverts
    ///         with {BoundedCallShortfall}: running short never reads as "not supported".
    /// @param account The address to probe.
    /// @param interfaceId The ERC-165 interface ID.
    /// @return Whether `account` declares `interfaceId`.
    function supportsInterface(address account, bytes4 interfaceId) internal view returns (bool) {
        return _erc165(account, interfaceId, 3);
    }

    /// @notice One `supportsInterface(interfaceId)` probe without the ERC-165 precheck: true
    ///         when the call succeeds with at least 32 bytes whose first word is non-zero (as
    ///         OpenZeppelin `ERC165Checker.supportsERC165InterfaceUnchecked`). A shortfall
    ///         reverts with {BoundedCallShortfall}.
    /// @param account The address to probe.
    /// @param interfaceId The ERC-165 interface ID.
    /// @return Whether `account` answered that it supports `interfaceId`.
    function supportsInterfaceUnchecked(address account, bytes4 interfaceId)
        internal
        view
        returns (bool)
    {
        return _erc165(account, interfaceId, 1);
    }

    /// @dev Runs the first `count` ERC-165 probes and returns whether each passed, stopping at
    ///      the first that does not: probe 0 asks for `interfaceId` and must answer true; probe 1
    ///      asks for `IERC165` and must answer true; probe 2 asks for `0xffffffff` and must
    ///      succeed without answering true. "Answers true": succeeds with at least 32 bytes
    ///      whose first word is non-zero. The order of the probes never changes the result. One
    ///      call site, built in scratch space, copying at most 32 bytes; a failed probe that
    ///      leaves at most 1/8 of the gas held before it reverts with {BoundedCallShortfall}
    ///      (selector `0x5b20679f`, encoded here to keep the loop small; the error's argument is
    ///      `account` as Solidity passed it, which every caller derives from a typed address).
    function _erc165(address account, bytes4 interfaceId, uint256 count)
        private
        view
        returns (bool passed)
    {
        assembly ("memory-safe") {
            let selector := shl(224, 0x01ffc9a7)
            passed := 1
            for { let i := 0 } and(passed, lt(i, count)) { i := add(i, 1) } {
                // Probe 1 asks for the selector itself, probe 2 for 0xffffffff (the selector
                // xor 0xfe003658).
                let id := interfaceId
                if i { id := xor(selector, mul(sub(i, 1), shl(224, 0xfe003658))) }
                mstore(0x00, selector)
                mstore(0x04, id)
                let before := gas()
                let ok := staticcall(gas(), account, 0x00, 0x24, 0x00, 0x20)
                if iszero(or(ok, gt(gas(), div(before, SHORTFALL_DIVISOR)))) {
                    mstore(0x00, shl(224, 0x5b20679f))
                    mstore(0x04, account)
                    revert(0x00, 0x24)
                }
                passed := and(ok, and(gt(returndatasize(), 0x1f), iszero(iszero(mload(0x00)))))
                if eq(i, 2) { passed := and(ok, iszero(passed)) }
            }
        }
    }

    /// @dev Classifies a finished forward-all call and copies its return data when it fits.
    function _outcome(address target, bool ok, uint256 size, uint256 before, uint256 maxReturn)
        private
        view
        returns (bool, bytes memory data)
    {
        if (!ok) _checkShortfall(target, before);
        if (size > maxReturn) return (false, data);
        data = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(data, 0x20), 0, size)
        }
        return (ok, data);
    }

    /// @dev Reverts with {BoundedCallShortfall} when a failed call left at most 1/8 of `before`,
    ///      the gas held just before the call.
    function _checkShortfall(address target, uint256 before) private view {
        if (gasleft() <= before / SHORTFALL_DIVISOR) revert BoundedCallShortfall(target);
    }

    // ------------------------------------------------------------------ fixed-gas family

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
