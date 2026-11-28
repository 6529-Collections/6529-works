// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice A contract that answers true to every `supportsInterface` probe, `0xffffffff`
///         included, so it does not implement ERC-165 and declares no interface.
contract YesToEveryInterface {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @notice An editions-like contract that answers `stream` with whatever bytes the test sets
///         (and has no `workOf`).
contract RawStreamAnswer {
    bytes internal _answer;

    function setAnswer(bytes calldata answer) external {
        _answer = answer;
    }

    function stream() external view returns (bytes memory) {
        bytes memory a = _answer;
        assembly ("memory-safe") {
            return(add(a, 0x20), mload(a))
        }
    }
}
