// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @dev Answers every receiver hook with the exact bytes the test sets.
contract RawAnswerReceiver1155 {
    bytes internal _answer;

    function setAnswer(bytes calldata answer) external {
        _answer = answer;
    }

    fallback() external {
        bytes memory answer = _answer;
        assembly ("memory-safe") {
            return(add(answer, 0x20), mload(answer))
        }
    }
}
