// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// The integrator examples live in examples/ (examples/README.md). Importing them here compiles
// them with the test suite, so `forge test` runs the examples and they cannot drift from the
// contracts. Run only the examples with:
//     forge test --match-path "examples/*"
import { ExampleIndexFromEvents } from "../examples/IndexFromEvents.t.sol";
import { ExampleReadAWork } from "../examples/ReadAWork.t.sol";
