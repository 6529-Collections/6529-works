// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import {
    ReturnDataMock,
    GasBurnerMock,
    GasReporterMock,
    ReturnBombMock
} from "../mocks/libraries/AdversarialTargets.sol";

contract BoundedCallHarness {
    function tryRead(address target, bytes calldata input, uint256 gasLimit, uint256 maxReturn)
        external
        view
        returns (bool, bytes memory)
    {
        return BoundedCall.tryRead(target, input, gasLimit, maxReturn, 0);
    }

    function read(
        address target,
        bytes calldata input,
        uint256 gasLimit,
        uint256 maxReturn,
        uint256 completionBuffer
    ) external view returns (bytes memory) {
        return BoundedCall.read(target, input, gasLimit, maxReturn, completionBuffer);
    }

    function readWord(address target, uint256 gasLimit) external view returns (bytes32) {
        return BoundedCall.readWord(target, "", gasLimit, 0);
    }

    function readString(address target, uint256 maxLength) external view returns (string memory) {
        return BoundedCall.readString(target, "", 100_000, maxLength, 0);
    }

    function decodeString(bytes calldata data, uint256 maxLength)
        external
        pure
        returns (bool, string memory)
    {
        return BoundedCall.decodeString(data, maxLength);
    }
}

contract BoundedCallTest is Test {
    uint256 internal constant LIMIT = 50_000;

    BoundedCallHarness internal harness;
    ReturnDataMock internal target;

    function setUp() public {
        harness = new BoundedCallHarness();
        target = new ReturnDataMock();
    }

    function _failed(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BoundedCall.BoundedCallFailed.selector, who);
    }

    function _malformed(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BoundedCall.BoundedCallMalformedReturn.selector, who);
    }

    // ---------------------------------------------------------------- gas rule

    function test_HasSufficientGasExactBoundary() public pure {
        uint256[6] memory limits = [uint256(0), 1, 62, 63, 64, 1_000_000];
        for (uint256 i; i < limits.length; ++i) {
            uint256 l = limits[i];
            uint256 required = l + (l + 62) / 63 + 777;
            assertTrue(BoundedCall.hasSufficientGas(required, l, 777));
            assertFalse(BoundedCall.hasSufficientGas(required - 1, l, 777));
        }
    }

    function testFuzz_HasSufficientGasNeverOverflows(uint256 available, uint256 l, uint256 buffer)
        public
        pure
    {
        BoundedCall.hasSufficientGas(available, l, buffer);
    }

    function testFuzz_HasSufficientGasMatchesFormula(uint256 available, uint256 l, uint256 buffer)
        public
        pure
    {
        l = bound(l, 0, type(uint128).max);
        buffer = bound(buffer, 0, type(uint128).max);
        uint256 required = l + (l + 62) / 63 + buffer;
        assertEq(BoundedCall.hasSufficientGas(available, l, buffer), available >= required);
    }

    function test_InsufficientGasReverts() public {
        target.configure(abi.encode(uint256(1)), false);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallInsufficientGas.selector, LIMIT)
        );
        harness.read{ gas: LIMIT }(address(target), "", LIMIT, 32, 0);
    }

    function test_CompletionBufferIsReserved() public {
        target.configure(abi.encode(uint256(1)), false);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallInsufficientGas.selector, LIMIT)
        );
        harness.read{ gas: 200_000 }(address(target), "", LIMIT, 32, 200_000);
    }

    /// @dev Whatever gas the caller supplies, the callee either receives its full limit
    ///      (minus only its own ~44-gas dispatch preamble) or the call reverts before being made.
    function testFuzz_CalleeAlwaysReceivesFullLimit(uint256 outerGas, uint256 l) public {
        GasReporterMock reporter = new GasReporterMock();
        l = bound(l, 1_000, 2_000_000);
        outerGas = bound(outerGas, 1_000, 2_200_000);
        (bool ok, bytes memory ret) = address(harness).call{ gas: outerGas }(
            abi.encodeCall(BoundedCallHarness.read, (address(reporter), "", l, 32, 0))
        );
        if (!ok) {
            // Only an up-front shortfall (or the harness frame itself running dry) may fail.
            if (ret.length != 0) {
                assertEq(bytes4(ret), BoundedCall.BoundedCallInsufficientGas.selector);
            }
            return;
        }
        uint256 seen = abi.decode(abi.decode(ret, (bytes)), (uint256));
        assertLe(seen, l);
        assertGe(seen, l - 100, "callee entry overhead only");
    }

    function test_CalleeReceivesFullLimitAtTheThreshold() public {
        GasReporterMock reporter = new GasReporterMock();
        // Walk down until the up-front check fails; just above it the limit is still intact.
        uint256 lowestOk;
        for (uint256 g = LIMIT + LIMIT / 63 + 6_000; g > LIMIT; g -= 1) {
            (bool ok, bytes memory ret) = address(harness).call{ gas: g }(
                abi.encodeCall(BoundedCallHarness.read, (address(reporter), "", LIMIT, 32, 0))
            );
            if (!ok) {
                assertEq(bytes4(ret), BoundedCall.BoundedCallInsufficientGas.selector);
                break;
            }
            lowestOk = g;
            uint256 seen = abi.decode(abi.decode(ret, (bytes)), (uint256));
            assertGe(seen, LIMIT - 100, "callee entry overhead only");
        }
        assertGt(lowestOk, 0);
    }

    // ---------------------------------------------------------------- failures

    function test_NoCodeTargetFails() public {
        address eoa = makeAddr("eoa");
        (bool ok, bytes memory ret) = harness.tryRead(eoa, "", LIMIT, 32);
        assertFalse(ok);
        assertEq(ret.length, 0);
        vm.expectRevert(_failed(eoa));
        harness.read(eoa, "", LIMIT, 32, 0);
    }

    function test_RevertingTargetFails() public {
        target.configure("boom", true);
        (bool ok, bytes memory ret) = harness.tryRead(address(target), "", LIMIT, 1024);
        assertFalse(ok);
        assertEq(ret.length, 0, "revert data is never copied");
        vm.expectRevert(_failed(address(target)));
        harness.read(address(target), "", LIMIT, 1024, 0);
    }

    function test_ReturnSizeBoundary() public {
        target.configure(new bytes(64), false);
        (bool ok, bytes memory ret) = harness.tryRead(address(target), "", LIMIT, 64);
        assertTrue(ok);
        assertEq(ret.length, 64);
        (ok, ret) = harness.tryRead(address(target), "", LIMIT, 63);
        assertFalse(ok);
        vm.expectRevert(_failed(address(target)));
        harness.read(address(target), "", LIMIT, 63, 0);
    }

    function test_ReturnsExactBytes() public {
        bytes memory payload = abi.encodePacked(keccak256("a"), keccak256("b"), hex"c0ffee");
        target.configure(payload, false);
        assertEq(harness.read(address(target), "", LIMIT, 1024, 0), payload);
    }

    function test_GasBombCostsAtMostTheLimit() public {
        GasBurnerMock burner = new GasBurnerMock();
        uint256 before = gasleft();
        (bool ok,) = harness.tryRead(address(burner), "", LIMIT, 32);
        uint256 used = before - gasleft();
        assertFalse(ok);
        assertGe(used, LIMIT);
        assertLe(used, LIMIT + 15_000);
    }

    function test_ReturnDataBombIsNeverCopied() public {
        ReturnBombMock bomb = new ReturnBombMock(32 * 1024, bytes32(uint256(1)));
        uint256 before = gasleft();
        vm.expectRevert(_failed(address(bomb)));
        harness.read(address(bomb), "", 1_000_000, 32, 0);
        uint256 used = before - gasleft();
        // The bomb pays for its own 32 KB; the caller copies nothing.
        assertLe(used, 40_000);
    }

    // ---------------------------------------------------------------- word reads

    function test_ReadWord() public {
        target.configure(abi.encode(bytes32("word")), false);
        assertEq(harness.readWord(address(target), LIMIT), bytes32("word"));
    }

    function test_ReadWordRejectsOtherSizes() public {
        target.configure(new bytes(31), false);
        vm.expectRevert(_malformed(address(target)));
        harness.readWord(address(target), LIMIT);

        target.configure("", false);
        vm.expectRevert(_malformed(address(target)));
        harness.readWord(address(target), LIMIT);

        target.configure(new bytes(33), false);
        vm.expectRevert(_failed(address(target)));
        harness.readWord(address(target), LIMIT);
    }

    // ---------------------------------------------------------------- string reads

    function test_ReadStringCanonical() public {
        string[5] memory values =
            [string(""), "a", "6529 Stream", string(new bytes(32)), string(new bytes(33))];
        for (uint256 i; i < values.length; ++i) {
            target.configure(abi.encode(values[i]), false);
            assertEq(harness.readString(address(target), 64), values[i]);
        }
    }

    function test_ReadStringLengthBoundary() public {
        target.configure(abi.encode(string(new bytes(40))), false);
        assertEq(bytes(harness.readString(address(target), 40)).length, 40);
        // 40 bytes pad to 64, which still fits a 33-byte maximum's return bound, so the
        // decoder (not the size bound) rejects it.
        vm.expectRevert(_malformed(address(target)));
        harness.readString(address(target), 33);
        // At a 32-byte maximum the return bound itself rejects it.
        vm.expectRevert(_failed(address(target)));
        harness.readString(address(target), 32);
    }

    function test_DecodeStringRejectsMalformedEncodings() public view {
        bytes memory good = abi.encode("hello");
        (bool ok, string memory value) = harness.decodeString(good, 64);
        assertTrue(ok);
        assertEq(value, "hello");

        bytes[9] memory bad = [
            bytes.concat(good, bytes32(0)), // trailing word
            abi.encodePacked(uint256(64), uint256(5), bytes32("hello")), // wrong offset
            abi.encodePacked(uint256(32), uint256(33), bytes32("hello")), // length overruns
            abi.encodePacked(uint256(32), uint256(5), bytes32("helloX")), // dirty padding
            abi.encodePacked(uint256(32), uint256(type(uint256).max)), // absurd length
            abi.encodePacked(uint256(32)), // truncated
            abi.encodePacked(uint256(0), uint256(5), bytes32("hello")), // offset below 32
            // The offset and the length are whole words: high bits make them wrong too.
            abi.encodePacked((uint256(1) << 128) | 32, uint256(5), bytes32("hello")),
            abi.encodePacked(uint256(32), (uint256(1) << 128) | 5, bytes32("hello"))
        ];
        for (uint256 i; i < bad.length; ++i) {
            (ok,) = harness.decodeString(bad[i], type(uint256).max);
            assertFalse(ok, vm.toString(i));
        }
        (ok,) = harness.decodeString(good, 4);
        assertFalse(ok, "over maxLength");
    }

    function testFuzz_DecodeStringRoundTrip(bytes memory raw) public view {
        (bool ok, string memory value) = harness.decodeString(abi.encode(string(raw)), raw.length);
        assertTrue(ok);
        assertEq(bytes(value), raw);
        if (raw.length > 0) {
            (ok,) = harness.decodeString(abi.encode(string(raw)), raw.length - 1);
            assertFalse(ok);
        }
    }
}
