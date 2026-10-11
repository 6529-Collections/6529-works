// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev A stand-in for a contract the package registry binds (6529 Stream or 6529 Editions): it
///      reports ERC-165 support for one interface ID and does nothing else. Tests prank it.
contract MockBoundCaller is IERC165 {
    bytes4 public immutable interfaceIdSupported;

    constructor(bytes4 interfaceId_) {
        interfaceIdSupported = interfaceId_;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == interfaceIdSupported;
    }
}
