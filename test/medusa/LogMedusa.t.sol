// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LogMedusa } from "./LogMedusa.sol";
import { MedusaClock } from "./MedusaClock.sol";

/// @dev Runs the StatementLog, Stream and Editions harness under Forge too, on every pull
///      request.
contract LogMedusaTest is Test {
    LogMedusa internal harness;
    MedusaClock internal clock;

    function setUp() public {
        vm.warp(1_800_000_000);
        harness = new LogMedusa();
        clock = new MedusaClock();
        targetContract(address(harness));
        targetContract(address(clock));
    }

    /// The harness's model agrees with StatementLog, Stream and Editions over random call
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
        harness.appendRole(true, 3, 0, 1, 2); // a dispute outcome about work 1 before its mint
        (uint64 count,) = harness.log().chainOf(stream, 1);
        assertEq(count, 0);
        harness.mintWork();
        harness.mintWork();
        harness.append(1, 0, 0, 0, 0); // the artist, about work 1
        harness.append(2, 1, 1, 0, 1); // the owner, about work 2, by file ID
        harness.append(2, 7, 1, 0, 1); // the stranger is not the owner: refused
        harness.appendRole(false, 2, 4, 2, 0); // the curator's evidence on work 1's item
        harness.appendRole(true, 3, 4, 1, 2); // the platform's outcome about work 1's item
        (bytes32 itemOutcome,) =
            harness.log().disputeOutcomeOf(address(0), uint256(harness.itemOf(1)));
        assertTrue(itemOutcome != 0);
        assertEq(harness.log().latestDisputeOutcome(stream, 1), itemOutcome); // through the item
        harness.appendRole(true, 3, 0, 1, 2); // and now one about work 1 itself
        (bytes32 own,) = harness.log().disputeOutcomeOf(stream, 1);
        assertEq(harness.log().latestDisputeOutcome(stream, 1), own);
        (count,) = harness.log().chainOf(stream, 1);
        assertEq(count, 2);

        harness.appendSigned(1, 0, 2, 0, 0, 0); // relayed artist statement, nonce 0
        assertTrue(harness.log().nonceUsed(address(harness.artist()), 0));
        harness.revokeNonce(1, 3);
        assertTrue(harness.log().nonceUsed(address(harness.owner()), 256));
        harness.appendManifest(true, false, 0);
        (count,) = harness.log().chainOf(address(harness.gate()), 0);
        assertEq(count, 1);
        harness.moveWork(0);
        harness.append(2, 7, 0, 0, 0); // the new holder speaks
        (count,) = harness.log().chainOf(stream, 1);
        assertEq(count, 3);

        harness.createEdition(0, 0, true); // invalid royalty: refused
        harness.createEdition(0, 0, false);
        harness.mint(0, 0, 3, true);
        assertEq(harness.editions().editionOf(1).minted, 3);
        harness.mint(1, 0, 1, true); // not the edition's minter: refused
        harness.append(2, 6, 3, 0, 0); // the buyer holds copies of edition 1
        harness.appendRole(true, 3, 3, 1, 0); // an outcome about an edition: refused
        harness.seal(0, 0, 0); // sealed at the three minted
        assertTrue(harness.editions().editionOf(1).supplySealed);
        harness.seal(0, 0, 1); // a second seal: refused, as the model predicts
        harness.mint(0, 0, 1, true); // past the seal: refused
        harness.burnCopies(true, 0, 1);
        assertEq(harness.editions().balanceOf(address(harness.buyer()), 1), 2);

        harness.createEdition(1, 1, false);
        harness.setDelays(0, 0, true);
        harness.setMinter(1, false, true); // remove edition sale 1
        harness.mint(1, 1, 1, true); // removed and unsealed: refused
        harness.rebind(1, 2, false); // a stranger: refused
        harness.rebind(1, 2, true);
        assertEq(harness.editions().editionOf(2).minter, address(harness.edSales(2)));
        harness.mint(2, 1, 2, false);
        harness.setMinter(1, true, true);
        assertTrue(harness.editions().isMinter(address(harness.edSales(1))));

        harness.burnWork(1);
        harness.appendRole(true, 3, 1, 1, 0); // an outcome about the burned work: refused
        harness.mintWork(); // work 3
        harness.createEdition(0, 1, false); // edition 2 exists and its master is burned: refused
        _assertProperties();
    }

    function _assertProperties() internal view {
        assertTrue(harness.property_ModelPredictsEveryOutcome(), harness.lastMismatch());
        assertTrue(harness.property_CountAndHeadMatchTheModel(), "count and head");
        assertTrue(harness.property_DisputeOutcomesFollowTheWork(), "dispute outcomes");
        assertTrue(harness.property_RolesWriteOnlyTheirKinds(), "roles");
        assertTrue(harness.property_SpentNoncesStaySpent(), "nonces");
        assertTrue(harness.property_EditionSupplyAccounting(), "edition supply");
        assertTrue(harness.property_SealedSupplyHolds(), "sealed supply");
    }
}
