// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Base64Validator } from "src/content/Base64Validator.sol";

/// @notice Halmos proofs for `Base64Validator.isAlphabet` (docs/testing/README.md, "Symbolic").
/// @dev The validator classifies 32 bytes at once with carry-free word arithmetic; the
///      reference here tests one byte at a time against the RFC 4648 section 4 alphabet. Both
///      are branch-free, so each proof is a single path that covers every value of the
///      symbolic words: the word proofs are unbounded over content. Lengths are enumerated
///      (0 to 64), so the length dimension is exhaustive for buffers of up to two words.
contract Base64ValidatorSymbolicTest is Test {
    /// @dev 1 when `b` is in `[A-Za-z0-9+/]`, else 0. Assembly keeps it branch-free.
    function _inAlphabet(uint256 b) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := or(
                or(
                    and(iszero(lt(b, 0x41)), iszero(gt(b, 0x5a))),
                    and(iszero(lt(b, 0x61)), iszero(gt(b, 0x7a)))
                ),
                or(and(iszero(lt(b, 0x30)), iszero(gt(b, 0x39))), or(eq(b, 0x2b), eq(b, 0x2f)))
            )
        }
    }

    /// @dev 1 when the first `length` bytes of `data` are all in the alphabet. Branch-free in
    ///      the content; `length` is concrete in every caller.
    function _reference(bytes memory data, uint256 length) internal pure returns (bool) {
        uint256 all = 1;
        for (uint256 i; i < length; ++i) {
            all &= _inAlphabet(uint8(data[i]));
        }
        return all == 1;
    }

    /// @notice Every 32-byte word: the word-at-a-time check equals the bytewise alphabet test.
    ///         Unbounded over the 2**256 words.
    function check_isAlphabet_fullWord(bytes32 w) public pure {
        bytes memory data = abi.encodePacked(w);
        assert(Base64Validator.isAlphabet(data, 32) == _reference(data, 32));
    }

    /// @notice Every prefix of every two-word buffer: the result equals the bytewise test of
    ///         the prefix, and the buffer is unchanged afterwards (the tail fill is restored).
    ///         Unbounded over content; lengths 0 to 64 enumerated.
    function check_isAlphabet_everyPrefixOfTwoWords(bytes32 w0, bytes32 w1) public pure {
        for (uint256 length; length <= 64; ++length) {
            bytes memory data = abi.encodePacked(w0, w1);
            assert(Base64Validator.isAlphabet(data, length) == _reference(data, length));
            bytes32 a;
            bytes32 b;
            assembly ("memory-safe") {
                a := mload(add(data, 0x20))
                b := mload(add(data, 0x40))
            }
            assert(a == w0 && b == w1);
        }
    }

    /// @notice A buffer that is not padded to a whole word (as `abi.encodePacked` of odd
    ///         lengths leaves it) keeps the memory right after it intact: the tail fill writes
    ///         past the buffer and must put the word back. Unbounded over content and over
    ///         the neighbouring word; lengths 1 to 31 enumerated.
    function check_isAlphabet_restoresTheNeighbouringWord(bytes32 w, bytes32 neighbour)
        public
        pure
    {
        for (uint256 length = 1; length < 32; ++length) {
            bytes memory data = new bytes(length);
            bytes32 after_;
            assembly ("memory-safe") {
                // Put `w` over the content, then shrink the allocation so the next object
                // starts right after the last content byte, as encodePacked would leave it.
                mstore(add(data, 0x20), w)
                let end := add(add(data, 0x20), length)
                mstore(end, neighbour)
                mstore(0x40, add(end, 0x20))
            }
            bool result = Base64Validator.isAlphabet(data, length);
            assembly ("memory-safe") {
                after_ := mload(add(add(data, 0x20), length))
            }
            assert(after_ == neighbour);
            assert(result == _reference(data, length));
        }
    }
}
