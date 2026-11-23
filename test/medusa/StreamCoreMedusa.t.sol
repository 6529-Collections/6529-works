// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Outcome, Slots } from "src/interfaces/core/CoreTypes.sol";
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
        harness.mint(0, 0, 2, false, 0); // token 1, sale 0
        harness.mint(1, 0, 3, false, 0); // content 0 again: refused, as predicted
        harness.mint(1, 1, 4, true, 0); // token 2, straight to a collector
        for (uint8 shape = 1; shape <= 7; ++shape) {
            harness.mint(2, 4, 9, false, shape); // invalid facts or no second collection
        }
        assertEq(harness.stream().totalMinted(), 2);
        harness.createCollection(false); // a stranger: refused
        harness.createCollection(true);
        harness.mint(2, 4, 9, false, 7); // collection 2 now exists
        assertEq(harness.stream().workOf(3).collectionId, 2);
        harness.record(0, 1, true); // sale 1 does not hold token 1: refused
        harness.record(0, 0, true);
        assertEq(uint8(harness.stream().workOf(1).outcome), uint8(Outcome.SOLD));
        harness.deliver(0, 0);
        harness.transfer(0, 0, 1);
        assertEq(harness.stream().ownerOf(1), address(harness.collectors(1)));
        harness.setRoyalty(0, 1, 700, false);
        harness.lockRate(0, false);
        harness.setRoyalty(0, 1, 800, false); // refused: locked
        harness.setRoyalty(0, 1, 700, true); // refused: module B is not installed
        harness.refresh(1, 3, false);
        harness.mint(2, 2, 5, false, 0); // token 4, sale 2
        harness.burn(3, 2);
        assertEq(harness.stream().totalBurned(), 1);
        harness.mint(0, 3, 6, false, 0); // token 5, sale 0
        harness.setDelays(0, 0, false); // a stranger: refused
        harness.setDelays(0, 0, true);
        harness.removeMinter(0, true);
        harness.rescue(4, false); // a stranger: refused
        harness.rescue(4, true);
        assertEq(harness.stream().ownerOf(5), harness.MUSEUM());
        harness.addMinter(0, true);
        assertTrue(harness.stream().isMinter(address(harness.sales(0))));

        harness.setDelays(0, 3 days, true);
        harness.proposeTerms(true, true, true); // no code: refused
        harness.proposeTerms(true, false, true);
        harness.activateTerms(); // not ready: refused
        vm.warp(block.timestamp + 3 days);
        harness.activateTerms();
        assertEq(harness.stream().moduleOf(Slots.TERMS), address(harness.termsB()));
        harness.setRoyalty(1, 2, 900, true); // token 2 through module B
        assertEq(harness.stream().workOf(2).royaltyRate, 900);
        harness.removeTerms(true);
        harness.lockRate(1, true); // refused: the slot is empty
        _assertProperties();
    }

    function _assertProperties() internal view {
        assertTrue(harness.property_ModelPredictsEveryOutcome(), harness.lastMismatch());
        assertTrue(harness.property_OnlyTheNetworkGoverns(), "governed");
        assertTrue(harness.property_SupplyIsMintedMinusBurned(), "supply");
        assertTrue(harness.property_OneLiveTokenPerContent(), "content");
        assertTrue(harness.property_OutcomesAndOwnersMatchTheModel(), "outcomes and owners");
        assertTrue(harness.property_FactsNeverChange(), "facts");
        assertTrue(harness.property_RoyaltiesMatchTheModel(), "royalties");
        assertTrue(harness.property_ModulesAndMintersMatchTheModel(), "modules and minters");
    }
}
