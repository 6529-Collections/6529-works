// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SpdxId } from "src/stream/SpdxId.sol";
import { Limits } from "src/interfaces/types/Limits.sol";

contract SpdxIdHarness {
    function memoryForm(string memory id) external pure returns (bool) {
        return SpdxId.isValid(id);
    }

    function calldataForm(string calldata id) external pure returns (bool) {
        return SpdxId.isValidCalldata(id);
    }
}

/// @notice The license-ID rule: 1 to 64 bytes of `[A-Za-z0-9.+-]`, the same in memory and in
///         calldata. test/symbolic/SpdxIdSymbolic.t.sol proves the byte mask for every input.
contract SpdxIdTest is Test {
    SpdxIdHarness internal h = new SpdxIdHarness();

    function _both(string memory id) internal view returns (bool) {
        bool m = h.memoryForm(id);
        assertEq(h.calldataForm(id), m, "memory and calldata forms disagree");
        return m;
    }

    function _reference(bytes memory id) internal pure returns (bool) {
        if (id.length == 0 || id.length > Limits.MAX_LICENSE_ID_BYTES) return false;
        for (uint256 i; i < id.length; ++i) {
            bytes1 c = id[i];
            bool ok = (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
                || c == "." || c == "+" || c == "-";
            if (!ok) return false;
        }
        return true;
    }

    function test_AcceptsRealIdentifiers() public view {
        assertTrue(_both("CC0-1.0"));
        assertTrue(_both("MIT"));
        assertTrue(_both("GPL-3.0+"));
        assertTrue(_both("LicenseRef-6529.Works"));
    }

    function test_LengthBounds() public view {
        assertFalse(_both(""), "empty");
        bytes memory id = new bytes(Limits.MAX_LICENSE_ID_BYTES);
        for (uint256 i; i < id.length; ++i) {
            id[i] = "a";
        }
        assertTrue(_both(string(id)), "the maximum length");
        assertFalse(_both(string(bytes.concat(id, "a"))), "one byte too long");
    }

    function test_EveryByteValue() public view {
        for (uint256 c; c < 256; ++c) {
            bytes memory id = abi.encodePacked("a", bytes1(uint8(c)), "z");
            assertEq(_both(string(id)), _reference(id), vm.toString(c));
        }
    }

    function testFuzz_MatchesTheReference(bytes memory id) public view {
        assertEq(_both(string(id)), _reference(id));
    }
}
