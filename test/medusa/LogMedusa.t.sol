// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LogMedusa } from "./LogMedusa.sol";
import { MedusaClock } from "./MedusaClock.sol";

/// @dev Runs the StatementLog and Editions harness under Forge too, on every pull request.
contract LogMedusaTest is Test {
    LogMedusa internal harness;
    MedusaClock internal clock;

    function setUp() public {
        harness = new LogMedusa();
        clock = new MedusaClock();
        targetContract(address(harness));
        targetContract(address(clock));
    }

    /// The harness's model agrees with StatementLog and Editions over random call sequences.
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
        address deed = address(harness.deed());
        harness.append(1, 0, 0, 0, 0); // the artist, about deed #1
        harness.append(2, 1, 1, 0, 1); // the owner, about deed #2, by file ID
        harness.appendRole(true, 3, 0, 1, 2); // the platform's dispute outcome on deed #1
        harness.appendRole(false, 2, 3, 2, 0); // the curator's evidence on work 7
        (uint64 count,) = harness.log().chainOf(deed, 1);
        assertEq(count, 2);
        (bytes32 dispute,) = harness.log().disputeOutcomeOf(deed, 1);
        assertTrue(dispute != 0);

        harness.appendSigned(1, 0, 2, 0, 0, 0); // relayed artist statement, nonce 0
        assertTrue(harness.log().nonceUsed(address(harness.artist()), 0));
        harness.revokeNonce(1, 3);
        assertTrue(harness.log().nonceUsed(address(harness.owner()), 256));
        harness.appendManifest(true, false, 0);
        (count,) = harness.log().chainOf(address(harness.gate()), 0);
        assertEq(count, 1);
        harness.moveDeed(0, true);
        harness.append(2, 6, 0, 0, 0); // the new owner speaks
        (count,) = harness.log().chainOf(deed, 1);
        assertEq(count, 3);

        harness.createEdition(0);
        harness.mint(0, 0, 3, true);
        assertEq(harness.editions().edition(1).minted, 3);
        harness.mint(1, 0, 1, true); // another adapter of the kind: refused
        harness.seal(0, 0, 0); // sealed at the three minted
        assertTrue(harness.editions().edition(1).supplySealed);
        harness.seal(0, 0, 1); // a second seal: refused, as the model predicts
        harness.mint(0, 0, 1, true); // past the seal: refused
        harness.setAdmitted(0, false, true);
        assertFalse(harness.editions().isAdmittedMinter(address(harness.adapters(0))));
        harness.createEdition(1);
        harness.mint(1, 1, 2, false);
        harness.burnCopies(1, 1, 1);
        assertEq(harness.editions().balanceOf(address(harness.adapters(1)), 2), 1);
        _assertProperties();
    }

    function _assertProperties() internal view {
        assertTrue(harness.property_ModelPredictsEveryOutcome(), harness.lastMismatch());
        assertTrue(harness.property_CountAndHeadMatchTheModel(), "count and head");
        assertTrue(harness.property_RolesWriteOnlyTheirKinds(), "roles");
        assertTrue(harness.property_SpentNoncesStaySpent(), "nonces");
        assertTrue(harness.property_EditionSupplyAccounting(), "edition supply");
        assertTrue(harness.property_SealedSupplyHolds(), "sealed supply");
    }
}
