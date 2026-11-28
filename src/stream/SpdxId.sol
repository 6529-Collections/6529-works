// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { Limits } from "../interfaces/types/Limits.sol";

/// @title SpdxId
/// @notice The license-identifier rule: 1 to `Limits.MAX_LICENSE_ID_BYTES` bytes of
///         `[A-Za-z0-9.+-]`. The mint policy applies it to an item's license, and
///         `StreamWorkFacts6529` applies it whenever a license is replaced, locked or frozen by
///         finalize, so every license a finalized work shows is one a renderer can print.
/// @dev The identifier keeps its original case (`License`); only `WorksHashing.licenseKey`
///      lowercases it. Plain code: one comparison chain per byte, no assembly.
library SpdxId {
    /// @notice Whether `spdxId` (in memory) follows the rule.
    /// @param spdxId The identifier.
    /// @return True if it follows the rule.
    function isValid(string memory spdxId) internal pure returns (bool) {
        bytes memory id = bytes(spdxId);
        uint256 n = id.length;
        if (n == 0 || n > Limits.MAX_LICENSE_ID_BYTES) return false;
        for (uint256 i; i < n; ++i) {
            if (!_allowed(id[i])) return false;
        }
        return true;
    }

    /// @notice Whether `spdxId` (in calldata) follows the rule, without copying it to memory.
    /// @param spdxId The identifier.
    /// @return True if it follows the rule.
    function isValidCalldata(string calldata spdxId) internal pure returns (bool) {
        bytes calldata id = bytes(spdxId);
        uint256 n = id.length;
        if (n == 0 || n > Limits.MAX_LICENSE_ID_BYTES) return false;
        for (uint256 i; i < n; ++i) {
            if (!_allowed(id[i])) return false;
        }
        return true;
    }

    /// @dev Whether `c` is one of `A-Z`, `a-z`, `0-9`, `.`, `+` or `-`.
    function _allowed(bytes1 c) private pure returns (bool) {
        return (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
            || c == "." || c == "+" || c == "-";
    }
}
