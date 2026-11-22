// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { MedusaClock } from "./MedusaClock.sol";
import { StreamCoreMedusa } from "./StreamCoreMedusa.sol";

/// @dev Runs the permanent ERC-721's Medusa harness under Forge too.
contract StreamCoreMedusaTest is Test {
    StreamCoreMedusa internal harness;
    MedusaClock internal clock;

    function setUp() public {
        vm.warp(1_800_000_000);
        harness = new StreamCoreMedusa();
        clock = new MedusaClock();
        targetContract(address(harness));
        targetContract(address(clock));
    }

    /// The harness's model agrees with the contract over random call sequences.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: deep.invariant.runs = 256
    /// forge-config: deep.invariant.depth = 128
    function invariant_MedusaPropertiesHold() public view {
        _assertProperties();
    }

    /// Each action changes state at least once (a token seed `s` picks token `1 + s % minted`),
    /// so a passing campaign is not a campaign of calls the contract turned away.
    function test_HarnessActionsReachState() public {
        harness.mint(0, 0, 2, false); // token 1, sale 0
        harness.mint(1, 0, 3, false); // content 0 again: refused, as predicted
        harness.mint(1, 1, 4, true); // token 2, straight to a collector
        assertEq(harness.stream().totalMinted(), 2);
        harness.record(0, 1, true); // sale 1 does not hold token 1: refused
        harness.record(0, 0, true);
        assertEq(uint8(harness.stream().workOf(1).outcome), uint8(Outcome.SOLD));
        harness.deliver(0, 0);
        harness.transfer(0, 0, 1);
        assertEq(harness.stream().ownerOf(1), address(harness.collectors(1)));
        harness.setRoyalty(0, address(0xFEE), 700);
        harness.lockRate(0);
        harness.setRoyalty(0, address(0xFEE), 800); // refused: locked
        harness.mint(2, 2, 5, false); // token 3, sale 2
        harness.burn(2, 2);
        assertEq(harness.stream().totalBurned(), 1);
        harness.mint(0, 3, 6, false); // token 4, sale 0
        harness.setDelays(0, 0);
        harness.removeMinter(0);
        harness.rescue(3);
        assertEq(harness.stream().ownerOf(4), harness.MUSEUM());
        harness.addMinter(0);
        assertTrue(harness.stream().isMinter(address(harness.sales(0))));
        _assertProperties();
    }

    function _assertProperties() internal view {
        assertTrue(harness.property_ModelPredictsEveryOutcome(), harness.lastMismatch());
        assertTrue(harness.property_SupplyIsMintedMinusBurned(), "supply");
        assertTrue(harness.property_OneLiveTokenPerContent(), "content");
        assertTrue(harness.property_OutcomesAndOwnersMatchTheModel(), "outcomes and owners");
        assertTrue(harness.property_FactsNeverChange(), "facts");
        assertTrue(harness.property_LockedRateHolds(), "locked rate");
    }
}
