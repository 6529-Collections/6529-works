// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev A payout wallet that burns every unit of gas it is given.
contract GasBurnerWallet {
    receive() external payable {
        while (true) { }
    }
}
