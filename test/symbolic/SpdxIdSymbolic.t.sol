// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SpdxId } from "src/stream/SpdxId.sol";

/// @notice Halmos proofs of the license-ID rule (docs/testing/README.md, "Symbolic").
/// @dev `SpdxId` tests each byte with a chain of comparisons and stops at the first refused byte,
///      so every allowed byte splits a path about seven ways and the paths multiply with the
///      length. The proofs are therefore bounded: every content of every length from 0 to 4,
///      and, at the length limit, any one byte at each of the 64 positions of a 64-byte
///      identifier (the others `a`), plus 64 bytes accepted and 65 refused. Both the memory form
///      and the calldata form are checked against a branch-free reference of the byte ranges.
contract SpdxIdSymbolicTest is Test {
    /// @dev 1 when `b` is in `[A-Za-z0-9.+-]`, else 0, without branching.
    function _allowed(uint256 b) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := or(
                or(
                    and(iszero(lt(b, 0x41)), iszero(gt(b, 0x5a))),
                    and(iszero(lt(b, 0x61)), iszero(gt(b, 0x7a)))
                ),
                or(
                    and(iszero(lt(b, 0x30)), iszero(gt(b, 0x39))),
                    or(eq(b, 0x2e), or(eq(b, 0x2b), eq(b, 0x2d)))
                )
            )
        }
    }

    function calldataForm(string calldata id) external pure returns (bool) {
        return SpdxId.isValidCalldata(id);
    }

    /// @notice Both forms equal the rule for every identifier of 0 to 4 bytes.
    /// @dev Bounds: every content; lengths 0 to 4.
    function check_spdxId_matchesTheRuleUpToFourBytes(bytes4 w) public view {
        for (uint256 n; n <= 4; ++n) {
            bytes memory id = new bytes(n);
            uint256 ok = n >= 1 ? 1 : 0;
            for (uint256 i; i < n; ++i) {
                id[i] = w[i];
                ok &= _allowed(uint8(w[i]));
            }
            assert(SpdxId.isValid(string(id)) == (ok == 1));
            assert(this.calldataForm(string(id)) == (ok == 1));
        }
    }

    /// @notice At the length limit every position is checked: a 64-byte identifier with any
    ///         byte `b` at any one position (the others `a`) is valid exactly when `b` is allowed;
    ///         64 allowed bytes are valid and 65 are not.
    /// @dev Bounds: every byte `b`; each of the 64 positions; lengths 64 and 65.
    function check_spdxId_everyPositionAtTheLengthLimit(bytes1 b) public view {
        bool ok = _allowed(uint8(b)) == 1;
        for (uint256 k; k < 64; ++k) {
            bytes memory id = bytes(_as(64));
            id[k] = b;
            assert(SpdxId.isValid(string(id)) == ok);
            assert(this.calldataForm(string(id)) == ok);
        }
        assert(SpdxId.isValid(_as(64)) && this.calldataForm(_as(64)));
        assert(!SpdxId.isValid(_as(65)) && !this.calldataForm(_as(65)));
    }

    /// @dev `n` bytes of `a`.
    function _as(uint256 n) internal pure returns (string memory) {
        bytes memory id = new bytes(n);
        for (uint256 i; i < n; ++i) {
            id[i] = "a";
        }
        return string(id);
    }
}
