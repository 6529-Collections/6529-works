// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";

/// @notice Selects a fork of the chain at `rpc`: at `pinned` when nonzero, otherwise a few blocks
///         behind the head, which every node behind a load-balanced public endpoint already
///         serves (the head itself may not have reached the node that answers the next read).
library Forks {
    uint256 internal constant BEHIND_HEAD = 8;

    function select(Vm vm, string memory rpc, uint256 pinned) internal {
        if (pinned != 0) {
            vm.createSelectFork(rpc, pinned);
            return;
        }
        vm.createSelectFork(rpc);
        vm.rollFork(block.number - BEHIND_HEAD);
    }
}
