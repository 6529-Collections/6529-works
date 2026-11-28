// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Facts } from "src/interfaces/core/CoreTypes.sol";
import { MedusaClock } from "./MedusaClock.sol";
import { WorkFactsMedusa } from "./WorkFactsMedusa.sol";

/// @dev Runs the permanent record's Medusa harness under Forge too.
contract WorkFactsMedusaTest is Test {
    WorkFactsMedusa internal harness;
    MedusaClock internal clock;

    function setUp() public {
        vm.warp(1_800_000_000);
        harness = new WorkFactsMedusa();
        clock = new MedusaClock();
        targetContract(address(harness));
        targetContract(address(clock));
    }

    /// The harness's model agrees with WorkFacts, Stream and the store over random call
    /// sequences.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: deep.invariant.runs = 256
    /// forge-config: deep.invariant.depth = 128
    function invariant_MedusaPropertiesHold() public view {
        _assertProperties();
    }

    /// Each action changes state at least once, so a passing campaign is not a campaign of calls
    /// the contracts turned away.
    function test_HarnessActionsReachState() public {
        address stream = address(harness.stream());
        harness.mint(0, 0, 2, false); // work 1: content 0, MIT, record R0
        harness.mint(0, 1, 0, true); // content 0 again: refused
        harness.mint(1, 1, 0, true); // work 2: content 1 with a secondary file, CC0, record R1
        harness.mint(2, 2, 2, false); // work 3: roles wrong, never opens
        harness.open(0, 1); // another item: refused
        harness.open(0, 2); // other media: refused
        harness.open(0, 3); // no such token: refused
        harness.open(0, 0);
        harness.open(0, 0); // again: refused
        harness.open(1, 0);
        harness.open(2, 0); // roles wrong: refused
        assertTrue(harness.facts().factsOf(stream, 1).opened);

        harness.markOnChain(0); // the media is not stored yet: refused
        harness.upload(0);
        harness.markOnChain(0);
        assertTrue(harness.facts().factsOf(stream, 1).onChainComplete);

        harness.setRecord(0, 2, true); // the stranger, directly: refused
        harness.setRecord(0, 2, false); // R2 (two chunks): allowed before finalize
        harness.finalize(0); // R2 cannot be frozen: refused
        harness.setRecord(0, 0, false);
        harness.setLicense(1, 2); // work 2 is CC0: refused
        harness.setLicense(1, 7); // CC0 in another case: allowed
        harness.setLicense(0, 4); // invalid identifier: refused
        harness.setLicense(0, 6); // a text not yet complete: allowed before finalize
        harness.finalize(0); // the text is incomplete: refused
        harness.upload(6);
        harness.setRenderer(0); // the RENDERER slot is emptied
        harness.finalize(0); // no renderer: refused
        harness.setRenderer(2);
        harness.finalize(0);
        Facts memory f = harness.facts().factsOf(stream, 1);
        assertTrue(f.finalized);
        assertEq(f.renderer, address(harness.rendererB()));
        harness.setRecord(0, 1, false); // finalized: refused
        harness.setLicense(0, 5); // a text of 17 chunks: refused
        harness.repin(0, 3); // no code: refused
        harness.repin(0, 2);
        assertEq(harness.facts().rendererOf(stream, 1), address(harness.rendererC()));
        harness.lock(0, true, true);
        harness.repin(0, 0); // locked: refused
        harness.setLicense(0, 2); // locked: refused
        harness.lock(1, false, true); // work 2 is not finalized: refused
        harness.lock(1, true, false);
        assertTrue(harness.facts().factsOf(stream, 2).licenseLocked);
        _assertProperties();
    }

    function _assertProperties() internal view {
        assertTrue(harness.property_ModelPredictsEveryOutcome(), harness.lastMismatch());
        assertTrue(harness.property_MediaFixedAfterOpen(), "media");
        assertTrue(harness.property_RecordFixedAfterFinalize(), "record");
        assertTrue(harness.property_Cc0NeverLeft(), "cc0");
        assertTrue(harness.property_LocksOneWay(), "locks");
        assertTrue(harness.property_FinalizeNeedsARenderer(), "renderer");
    }
}
