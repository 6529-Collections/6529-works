// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { SSTORE2 } from "src/libraries/SSTORE2.sol";

/// @dev The deployer whose address the pointers depend on.
contract SSTORE2Harness {
    function write(bytes calldata data) external returns (address) {
        return SSTORE2.write(data);
    }

    function writeMeasured(bytes calldata data) external returns (address pointer, uint256 used) {
        bytes memory copy = data;
        uint256 start = gasleft();
        pointer = SSTORE2.write(copy);
        used = start - gasleft();
    }

    function read(address pointer) external view returns (bytes memory) {
        return SSTORE2.read(pointer);
    }

    function readRange(address pointer, uint256 start, uint256 end)
        external
        view
        returns (bytes memory)
    {
        return SSTORE2.read(pointer, start, end);
    }

    function readVerified(address pointer, bytes32 expectedHash)
        external
        view
        returns (bytes memory)
    {
        return SSTORE2.readVerified(pointer, expectedHash);
    }

    function size(address pointer) external view returns (uint256) {
        return SSTORE2.size(pointer);
    }

    function pointerOf(address deployer, bytes calldata data) external pure returns (address) {
        return SSTORE2.pointerOf(deployer, data);
    }
}

contract SSTORE2Test is Test {
    uint256 internal constant MAX = SSTORE2.MAX_CHUNK_LENGTH;

    SSTORE2Harness internal store;

    function setUp() public {
        store = new SSTORE2Harness();
    }

    function _data(uint256 length, uint256 seed) internal pure returns (bytes memory data) {
        data = new bytes(length);
        for (uint256 i; i < length; ++i) {
            data[i] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i / 32))) >> (8 * (i % 32))));
        }
    }

    // ---------------------------------------------------------------- write and read

    function test_RoundTripAtSizeBoundaries() public {
        uint256[8] memory lengths = [uint256(0), 1, 31, 32, 33, 1000, MAX - 1, MAX];
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory data = _data(lengths[i], i);
            address pointer = store.write(data);
            assertEq(pointer, store.pointerOf(address(store), data), "predicted pointer");
            assertEq(pointer.code, bytes.concat(hex"00", data), "STOP-prefixed code");
            assertEq(store.size(pointer), data.length);
            assertEq(store.read(pointer), data);
            assertEq(store.readVerified(pointer, keccak256(data)), data);
        }
    }

    function test_ChunkLimitMatchesEIP170() public pure {
        assertEq(MAX + 1, 24_576);
    }

    function test_OversizedChunkReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SSTORE2.SSTORE2ChunkTooLarge.selector, MAX + 1));
        store.write(new bytes(MAX + 1));
    }

    function test_RewriteIsIdempotentAndCheap() public {
        bytes memory data = _data(MAX, 7);
        (address first, uint256 firstGas) = store.writeMeasured(data);
        (address second, uint256 secondGas) = store.writeMeasured(data);
        assertEq(first, second);
        assertEq(store.read(second), data);
        console2.log("write 24,575 bytes: first / repeat gas", firstGas, secondGas);
        assertLt(secondGas, 60_000, "a repeat write deploys nothing");
        assertGt(firstGas, 200 * MAX, "the first write pays the code deposit");
    }

    function test_PointersDependOnDeployerAndBytes() public {
        SSTORE2Harness other = new SSTORE2Harness();
        bytes memory data = bytes("6529 Stream content");
        address a = store.write(data);
        address b = other.write(data);
        assertTrue(a != b);
        assertEq(store.read(b), data, "any contract can read any pointer");
        assertTrue(store.write(bytes("6529 Stream content!")) != a);
    }

    function test_PointerCannotExecute() public {
        address pointer =
            store.write(abi.encodeWithSignature("transfer(address,uint256)", address(1), 1));
        (bool ok, bytes memory ret) = pointer.call(abi.encodeWithSignature("anything()"));
        assertTrue(ok);
        assertEq(ret.length, 0);
        assertEq(store.read(pointer).length, 68, "state unchanged");
    }

    function test_WriteFailsCleanlyWhenTheDepositRunsOutOfGas() public {
        bytes memory data = _data(MAX, 1);
        vm.expectRevert(SSTORE2.SSTORE2WriteFailed.selector);
        store.write{ gas: 2_000_000 }(data);
        // Nothing was deployed, so a properly funded write still succeeds.
        assertEq(store.read(store.write(data)), data);
    }

    // ---------------------------------------------------------------- ranges

    function test_RangeReads() public {
        bytes memory data = _data(100, 3);
        address pointer = store.write(data);
        assertEq(store.readRange(pointer, 0, 100), data);
        assertEq(store.readRange(pointer, 0, 0), "");
        assertEq(store.readRange(pointer, 100, 100), "");
        assertEq(store.readRange(pointer, 99, 100), abi.encodePacked(data[99]));
        assertEq(store.readRange(pointer, 10, 42), _slice(data, 10, 42));
    }

    function test_RangeOutOfBoundsReverts() public {
        address pointer = store.write(_data(100, 3));
        vm.expectRevert(abi.encodeWithSelector(SSTORE2.SSTORE2OutOfBounds.selector, 0, 101, 100));
        store.readRange(pointer, 0, 101);
        vm.expectRevert(abi.encodeWithSelector(SSTORE2.SSTORE2OutOfBounds.selector, 50, 49, 100));
        store.readRange(pointer, 50, 49);
        vm.expectRevert(abi.encodeWithSelector(SSTORE2.SSTORE2OutOfBounds.selector, 101, 101, 100));
        store.readRange(pointer, 101, 101);
    }

    // ---------------------------------------------------------------- verification

    function test_ReadVerifiedRejectsWrongHash() public {
        bytes memory data = _data(64, 5);
        address pointer = store.write(data);
        vm.expectRevert(abi.encodeWithSelector(SSTORE2.SSTORE2HashMismatch.selector, pointer));
        store.readVerified(pointer, keccak256("something else"));
    }

    function test_InvalidPointersRevert() public {
        address eoa = makeAddr("eoa");
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(store)));
        address[4] memory pointers = [eoa, address(store), delegated, address(1)];
        for (uint256 i; i < pointers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(SSTORE2.SSTORE2InvalidPointer.selector, pointers[i])
            );
            store.read(pointers[i]);
        }
    }

    /// @dev Any STOP-prefixed contract reads as data; only a hash check binds the bytes.
    function test_ForeignStopPrefixedCodeNeedsVerification() public {
        address impostor = makeAddr("impostor");
        vm.etch(impostor, bytes.concat(hex"00", "forged"));
        assertEq(store.read(impostor), "forged");
        vm.expectRevert(abi.encodeWithSelector(SSTORE2.SSTORE2HashMismatch.selector, impostor));
        store.readVerified(impostor, keccak256("genuine"));
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_RoundTripAndRanges(bytes memory data, uint256 a, uint256 b) public {
        vm.assume(data.length <= 2048);
        address pointer = store.write(data);
        assertEq(pointer, store.pointerOf(address(store), data));
        assertEq(store.read(pointer), data);
        a = bound(a, 0, data.length);
        b = bound(b, a, data.length);
        assertEq(store.readRange(pointer, a, b), _slice(data, a, b));
        assertEq(store.write(data), pointer, "idempotent");
    }

    function _slice(bytes memory data, uint256 start, uint256 end)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[start + i];
        }
    }
}
