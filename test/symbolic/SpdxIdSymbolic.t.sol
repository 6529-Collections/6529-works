// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SpdxId } from "src/stream/SpdxId.sol";

/// @notice Halmos proof of the license-ID rule (docs/testing/README.md, "Symbolic").
/// @dev `SpdxId` checks each byte with one lookup in a 256-bit mask. The reference tests the
///      byte ranges directly. Both are branch-free in the content, so the proof covers every
///      content of every length from 0 to 65 (one past the maximum): unbounded over the rule's
///      whole input space, for the memory form and the calldata form.
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

    function check_spdxId_matchesTheRuleForEveryInput(bytes32 w0, bytes32 w1, bytes32 w2)
        public
        view
    {
        bytes memory all = abi.encodePacked(w0, w1, w2);
        for (uint256 n; n <= 65; ++n) {
            bytes memory id = new bytes(n);
            uint256 ok = (n >= 1 && n <= 64) ? 1 : 0;
            for (uint256 i; i < n; ++i) {
                id[i] = all[i];
                ok &= _allowed(uint8(all[i]));
            }
            assert(SpdxId.isValid(string(id)) == (ok == 1));
            assert(this.calldataForm(string(id)) == (ok == 1));
        }
    }
}
