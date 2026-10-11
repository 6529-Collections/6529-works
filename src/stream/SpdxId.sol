// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Limits } from "../interfaces/types/Limits.sol";

/// @title SpdxId
/// @notice The license-identifier rule 6529 Stream applies at mint and its records satellite at
///         deploy and relicense: 1 to `Limits.MAX_LICENSE_ID_BYTES` bytes of `[A-Za-z0-9.+-]`.
/// @dev The ID keeps its original case (`License`); only `WorksHashing.licenseKey` lowercases
///      it. Each byte is checked with one lookup in a 256-bit mask instead of a chain of range
///      comparisons, which keeps a 64-byte ID cheap on the auction-start path.
library SpdxId {
    /// @dev Bit `c` is set for every allowed byte `c`: `+`, `-`, `.`, `0-9`, `A-Z` and `a-z`.
    uint256 private constant ALLOWED = 0x07fffffe07fffffe03ff680000000000;

    /// @notice Whether `spdxId` (in memory) follows the rule.
    function isValid(string memory spdxId) internal pure returns (bool ok) {
        uint256 n = bytes(spdxId).length;
        if (n == 0 || n > Limits.MAX_LICENSE_ID_BYTES) return false;
        assembly ("memory-safe") {
            let p := add(spdxId, 0x20)
            let end := add(p, n)
            ok := 1
            for { } lt(p, end) { p := add(p, 1) } {
                ok := and(ok, shr(byte(0, mload(p)), ALLOWED))
            }
        }
    }

    /// @notice Whether `spdxId` (in calldata) follows the rule, without copying it to memory.
    function isValidCalldata(string calldata spdxId) internal pure returns (bool ok) {
        uint256 n = bytes(spdxId).length;
        if (n == 0 || n > Limits.MAX_LICENSE_ID_BYTES) return false;
        assembly ("memory-safe") {
            let p := spdxId.offset
            let end := add(p, n)
            ok := 1
            for { } lt(p, end) { p := add(p, 1) } {
                ok := and(ok, shr(byte(0, calldataload(p)), ALLOWED))
            }
        }
    }
}
