// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Limits } from "../interfaces/types/Limits.sol";

/// @title SpdxId
/// @notice The license-identifier rule shared by 6529 Stream's mint check and its records
///         satellite, so an item whose license `WorkRecords` would refuse can never mint.
library SpdxId {
    /// @notice Whether `spdxId` is 1 to `Limits.MAX_LICENSE_ID_BYTES` bytes of `[A-Za-z0-9.+-]`.
    /// @dev The ID keeps its original case (`License`); only `WorksHashing.licenseKey`
    ///      lowercases it.
    function isValid(string memory spdxId) internal pure returns (bool) {
        bytes memory id = bytes(spdxId);
        if (id.length == 0 || id.length > Limits.MAX_LICENSE_ID_BYTES) return false;
        for (uint256 i; i < id.length; ++i) {
            bytes1 c = id[i];
            if (!((c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
                        || c == "." || c == "+" || c == "-")) return false;
        }
        return true;
    }
}
