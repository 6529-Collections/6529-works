// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice An Independent Stream module that is down: every call to it reverts.
contract RevertingGate {
    error GateDown();

    fallback() external {
        revert GateDown();
    }
}
