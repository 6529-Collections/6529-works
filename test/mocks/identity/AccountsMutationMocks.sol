// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A contract that answers true to every `supportsInterface` probe, `0xffffffff`
///         included, so it does not implement ERC-165 and declares no interface.
contract YesToEveryInterface {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}
