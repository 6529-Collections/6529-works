// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";

/// @dev Under Forge only: a second invariant target that moves time forward, as Medusa's
///      `blockTimestampDelayMax` does between its calls. Each step is at most seven days, the
///      Medusa setting, so a 180-day rule needs many steps in a row under both fuzzers.
contract MedusaClock {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function skip(uint32 secondsAhead) external {
        uint256 step = uint256(secondsAhead) % 7 days;
        VM.warp(block.timestamp + step);
        VM.roll(block.number + 1 + step / 12);
    }

    /// A half-year jump, so the 180-day rules are reached in 64-call runs too.
    function skipHalfYear() external {
        VM.warp(block.timestamp + 181 days);
        VM.roll(block.number + 1);
    }
}
