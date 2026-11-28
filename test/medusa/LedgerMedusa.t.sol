// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LedgerMedusa } from "./LedgerMedusa.sol";
import { MedusaClock } from "./MedusaClock.sol";

/// @dev Runs the money harness under Forge too, so a change that breaks the harness or a rule it
///      models fails `forge test` on every pull request, not only the scheduled Medusa campaign.
contract LedgerMedusaTest is Test {
    LedgerMedusa internal harness;
    MedusaClock internal clock;

    function setUp() public {
        harness = new LedgerMedusa{ value: 1e27 }();
        clock = new MedusaClock();
        targetContract(address(harness));
        targetContract(address(clock));
    }

    /// The harness's model agrees with the money contracts over random call sequences.
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
        address w0 = harness.wallets(0);
        address w1 = harness.wallets(1);
        harness.pay(0, true, 1e18 - 1);
        harness.pay(0, false, 1e18 - 1);
        harness.pay(1, true, 3e18 - 1);
        harness.createWallet(false);
        harness.createWallet(true);
        assertTrue(harness.ledger().isWallet(w1));
        assertTrue(harness.ledger().isWallet(harness.wallets(2)));

        // alice is caller 0; the royalty wallet's non-network payee pays the network too.
        uint8 alice = uint8(1 - harness.networkIndex());
        harness.release(0, true, alice, 4);
        assertEq(harness.ledger().totalReleased(w0, address(0)), 1e18);
        harness.releaseTo(1, true, 0, _owner(1, 0), 5);
        harness.releaseTo(1, true, 2, 2, 3); // keyA releases the artist share to keyB
        harness.releaseSigned(1, true, 1, _owner(1, 1), 1, 0, 5); // payee 1 signs, to sinkB
        (, address second,) = _payee(1, 1);
        assertTrue(harness.ledger().nonceUsed(second, 0));
        harness.revokeNonce(0, 3);
        assertTrue(harness.ledger().nonceUsed(address(harness.alice()), 256));

        harness.pay(0, false, 5e18 - 1);
        harness.mark(0, false, alice);
        (uint256 target,) = harness.ledger().markOf(w0, address(harness.token()), alice);
        assertGt(target, 0);
        vm.warp(block.timestamp + 181 days);
        harness.forfeit(0, false, alice);
        (target,) = harness.ledger().markOf(w0, address(harness.token()), alice);
        assertEq(target, 0);

        // A period of zero: a new mark matures at once; the escrow's credits age at once.
        harness.pay(0, false, 5e18 - 1);
        harness.setPeriod(0, false); // a stranger: refused
        harness.setPeriod(0, true);
        assertEq(harness.directory().unclaimedPeriod(), 0);
        harness.mark(0, false, alice);
        harness.forfeit(0, false, alice);
        (target,) = harness.ledger().markOf(w0, address(harness.token()), alice);
        assertEq(target, 0);
        harness.deposit(0, true, 1e18 - 1); // W0's credit, expirable at once
        harness.expire(0, true);
        assertEq(harness.escrow().owed(w0, address(0)), 0);
        harness.setPeriod(3, true); // back to 180 days

        harness.setPayout(1);
        harness.toggleRefuse(false);
        assertTrue(harness.alice().refuseETH());
        harness.toggleRefuse(false);

        harness.deposit(3, true, 1e18 - 1); // alice's credit
        harness.deposit(1, false, 2e18 - 1); // W1's credit
        harness.deposit(4, true, 1e18 - 1); // the fee vault's credit
        harness.flush(1, false);
        assertEq(harness.escrow().owed(w1, address(harness.token())), 0);
        harness.consent(5); // sinkB
        harness.recover(3, 5, true, true);
        assertEq(harness.escrow().owed(address(harness.sinkB()), address(0)), 1e18);
        harness.recover(4, 4, true, true); // the network moves its own credit to bob
        harness.deposit(2, true, 1e18 - 1);
        vm.warp(block.timestamp + 181 days);
        harness.expire(2, true);
        assertEq(harness.escrow().owed(address(harness.vault()), address(0)), 1e18);
        harness.donate(7e17 - 1);
        harness.sweep(false, 0, true);
        assertEq(harness.token().balanceOf(address(harness.sinkB())), 7e17);

        harness.pay(0, true, 1e18 - 1);
        harness.releaseToDestination(true, uint8(harness.networkIndex()));
        harness.forward(true, 0);
        harness.setDestination(true, false, 1);
        assertEq(harness.vault().destination(), address(harness.sinkB()));
        _assertProperties();
    }

    /// The caller index of payee `i` of wallet `w`'s account (alice 0, bob 1).
    function _owner(uint256 w, uint256 i) internal view returns (uint8) {
        (, address account,) = _payee(w, i);
        return account == address(harness.alice()) ? 0 : 1;
    }

    function _payee(uint256 w, uint256 i) internal view returns (uint256, address, uint32) {
        w;
        address a = address(harness.alice());
        address b = address(harness.bob());
        address first = a < b ? a : b;
        address second = a < b ? b : a;
        return (0, i == 0 ? first : second, 30_000);
    }

    function _assertProperties() internal view {
        assertTrue(harness.property_ModelPredictsEveryOutcome(), harness.lastMismatch());
        assertTrue(harness.property_WalletsConserveValue(), "wallets conserve value");
        assertTrue(harness.property_ReleasedWithinEntitlement(), "released within entitlement");
        assertTrue(harness.property_DustIsBounded(), "dust bounded");
        assertTrue(harness.property_EscrowIsSolvent(), "escrow solvent");
        assertTrue(harness.property_NoUnauthorizedRelease(), "unauthorized");
        assertTrue(harness.property_NetworkShareIsPaidOrDue(), "network share");
    }
}
