// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MedusaClock } from "./MedusaClock.sol";
import { StreamMedusa } from "./StreamMedusa.sol";

/// @dev Runs the Stream and WorkRecords harness under Forge too, on every pull request.
contract StreamMedusaTest is Test {
    StreamMedusa internal harness;
    MedusaClock internal clock;

    function setUp() public {
        harness = new StreamMedusa();
        clock = new MedusaClock();
        targetContract(address(harness));
        targetContract(address(clock));
    }

    /// The harness's model agrees with Stream and WorkRecords over random call sequences.
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
        harness.mint(0, 0, 0, false); // token 1: adapter 0, content 0, artist 1
        harness.mint(1, 1, 0, true); // token 2: adapter 1, content 1, artist 2
        harness.mint(0, 0, 1, false); // content 0 again: refused, as the model predicts
        assertEq(harness.stream().totalMinted(), 2);

        harness.settle(1, 0, 1); // adapter 1 cannot settle adapter 0's work
        assertFalse(harness.stream().primarySaleSettled(1));
        harness.settle(0, 0, 1); // SOLD by the minting adapter
        assertTrue(harness.stream().primarySaleSettled(1));
        harness.settle(1, 1, 2); // UNBID: the work goes to the museum
        assertEq(harness.stream().ownerOf(2), address(harness.museum()));

        harness.mint(0, 2, 0, false); // token 3, content 2
        harness.burn(0, 2);
        harness.releaseContent(2, false, 0, true); // content 2 reserved for artist 1
        assertEq(harness.stream().releasedTo(harness.contentHashes(2)), 1);
        harness.mint(0, 2, 1, false); // token 4: the beneficiary mints content 2 again
        assertEq(harness.stream().totalMinted(), 4);
        harness.setAdmitted(1, false, true);
        assertFalse(harness.stream().isAdmittedMinter(address(harness.sellers(1))));

        harness.openRecord(0, false);
        harness.setRecord(0, 1, 0, false);
        assertEq(harness.records().record(1).recordFileId, harness.recordFiles(1));
        harness.renounce(0, 3, true, false, true);
        assertEq(harness.records().renouncedPowers(1), 3);
        harness.swapRenderer(true);
        harness.finalize(0, 0);
        assertTrue(harness.records().record(1).finalized);
        harness.swapRenderer(true);
        assertEq(harness.stream().rendererOf(1), address(harness.rendererB()));
        harness.renounce(0, 4, false, false, true);
        assertEq(harness.records().renouncedPowers(1), 7);

        harness.openRecord(1, false);
        harness.finalize(1, 2); // a stranger records the notice
        assertGt(harness.records().finalizeNoticeAt(2), 0);
        vm.warp(block.timestamp + 15 days);
        harness.finalize(1, 2);
        assertTrue(harness.records().record(2).finalized);
        _assertProperties();
    }

    function _assertProperties() internal view {
        assertTrue(harness.property_ModelPredictsEveryOutcome(), harness.lastMismatch());
        assertTrue(harness.property_SupplyIsMintedMinusBurned(), "supply");
        assertTrue(harness.property_IdsNeverReused(), "ids");
        assertTrue(harness.property_SettledOnlyByTheMintingAdapter(), "settled");
        assertTrue(harness.property_FinalizedRecordsNeverChange(), "finalized");
        assertTrue(harness.property_RenouncedMaskOnlyGrows(), "renounced");
        assertTrue(harness.property_NoContentMintsTwice(), "content");
    }
}
