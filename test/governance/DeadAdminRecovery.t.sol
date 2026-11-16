// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { PermanenceFixture } from "./PermanenceFixture.sol";

/// @notice Dead-admin recovery (GV-42): after `RECOVERY_SILENCE` with no admin activity anyone
///         opens a recovery; `RECOVERY_DELAY` later it makes one account the only admin, if a
///         guardian majority approved it, or, for the pre-registered recovery address, unless a
///         guardian majority objected. Any admin activity voids it.
contract DeadAdminRecoveryTest is PermanenceFixture {
    address internal newAdmin = makeAddr("newAdmin");
    address internal recovery = makeAddr("recoveryCouncil");

    function setUp() public {
        _deployGovernance();
    }

    function _open(address candidate) internal {
        vm.prank(outsider);
        manager.openRecovery(candidate);
    }

    function _setRecoveryAddress(address r) internal {
        _adminExecute(abi.encodeCall(WorksAccessManager.setRecoveryAddress, (address(0), r)));
    }

    function _isAdmin(address account) internal view returns (bool member) {
        (member,) = manager.hasRole(Roles.ADMIN, account);
    }

    function _hasAdminRecord(address account) internal view returns (bool) {
        (uint48 since,,,) = manager.getAccess(Roles.ADMIN, account);
        return since != 0;
    }

    // ------------------------------------------------------------------ opening

    function test_NobodyOpensARecoveryBeforeTheSilence() public {
        uint48 last = manager.lastAdminActivity();
        vm.warp(last + SILENCE - 1);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.AdminsNotSilent.selector, last));
        _open(newAdmin);
        vm.warp(last + SILENCE);
        _open(newAdmin);
    }

    function test_EveryKindOfAdminActivityResetsTheClock() public {
        // Scheduling, executing, cancelling and a heartbeat each count.
        bytes memory op = abi.encodeCall(IAccessManager.labelRole, (Roles.KEEPER, "k"));
        vm.warp(block.timestamp + 100 days);
        _schedule(coldAdmin, address(manager), op);
        assertEq(manager.lastAdminActivity(), block.timestamp, "schedule");
        vm.warp(block.timestamp + ADMIN_DELAY);
        vm.prank(coldAdmin);
        manager.execute(address(manager), op);
        assertEq(manager.lastAdminActivity(), block.timestamp, "execute");
        vm.warp(block.timestamp + 10 days);
        _schedule(coldAdmin, address(manager), op);
        vm.warp(block.timestamp + 10 days);
        vm.prank(adminSafe);
        manager.cancel(coldAdmin, address(manager), op);
        assertEq(manager.lastAdminActivity(), block.timestamp, "cancel");
        vm.warp(block.timestamp + 10 days);
        vm.prank(adminSafe);
        manager.heartbeat();
        assertEq(manager.lastAdminActivity(), block.timestamp, "heartbeat");
        // A guardian or an outsider is no admin.
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, guardianA, Roles.ADMIN
            )
        );
        vm.prank(guardianA);
        manager.heartbeat();
        vm.prank(guardianA);
        manager.suspend(Roles.PLATFORM, platform);
        assertEq(manager.lastAdminActivity(), block.timestamp - 10 days);
    }

    function test_ADirectCallConsumingAnAdminsOperationCounts() public {
        // The hot admin also holds the setter roles: calling a target after scheduling counts.
        bytes memory fee = abi.encodeCall(target.setFee, (7));
        bytes32 id = _schedule(adminSafe, address(target), fee);
        vm.warp(manager.getSchedule(id));
        vm.prank(adminSafe);
        target.setFee(7);
        assertEq(target.fee(), 7);
        assertEq(manager.lastAdminActivity(), block.timestamp);
    }

    /// @dev An admin acting only through immediate calls (`execute` of a zero-delay role, with
    ///      nothing scheduled) is active: each call moves the clock, so no recovery opens against
    ///      it. A non-admin's `execute` and a failed call move nothing. Fails without the
    ///      `execute` override: immediate calls never reach `_consumeScheduledOp`.
    function test_AnAdminsImmediateExecuteCountsAndKeepsRecoveryClosed() public {
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (Roles.KEEPER, adminSafe, 0)));
        uint48 granted = manager.lastAdminActivity();
        bytes memory keep = abi.encodeCall(target.keep, ());
        // A keeper that is no admin: its immediate call moves nothing.
        vm.warp(granted + SILENCE - 1 days);
        vm.prank(keeper);
        manager.execute(address(target), keep);
        assertEq(manager.lastAdminActivity(), granted, "a non-admin's execute");
        // A failed call (a delayed function with nothing scheduled) reverts with its update.
        vm.prank(adminSafe);
        vm.expectRevert();
        manager.execute(address(target), abi.encodeCall(target.setFee, (7)));
        assertEq(manager.lastAdminActivity(), granted, "a failed call");
        // The admin's own immediate call counts.
        vm.prank(adminSafe);
        manager.execute(address(target), keep);
        assertEq(manager.lastAdminActivity(), block.timestamp, "an admin's immediate execute");
        vm.warp(granted + SILENCE);
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.AdminsNotSilent.selector, manager.lastAdminActivity()
            )
        );
        _open(newAdmin);
    }

    function test_OpeningRefusesBadCandidatesADuplicateAndAHandedOverManager() public {
        vm.warp(block.timestamp + SILENCE);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.InvalidCandidate.selector, address(0))
        );
        _open(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.InvalidCandidate.selector, address(manager))
        );
        _open(address(manager));
        _open(newAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.RecoveryNotLive.selector, newAdmin)
        );
        _open(newAdmin);
    }

    // ------------------------------------------------------------------ the guardian path

    function test_AGuardianMajorityInstallsANewAdmin() public {
        vm.warp(block.timestamp + SILENCE);
        vm.expectEmit(address(manager));
        emit WorksAccessManager.RecoveryOpened(
            newAdmin, uint48(block.timestamp + RECOVERY), false, 3
        );
        _open(newAdmin);
        vm.prank(guardianA);
        manager.approveRecovery(newAdmin);
        vm.prank(guardianB);
        manager.approveRecovery(newAdmin);
        vm.warp(block.timestamp + RECOVERY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.RecoveryNotReady.selector, newAdmin, uint48(block.timestamp + 1)
            )
        );
        manager.completeRecovery(newAdmin);
        vm.warp(block.timestamp + 1);

        address[] memory former = manager.seatHolders(Roles.ADMIN);
        assertEq(former.length, 2);
        for (uint256 i; i < former.length; ++i) {
            vm.expectEmit(address(manager));
            emit IAccessManager.RoleRevoked(Roles.ADMIN, former[i]);
        }
        vm.expectEmit(address(manager));
        emit WorksAccessManager.RecoveryCompleted(newAdmin);
        vm.prank(outsider);
        manager.completeRecovery(newAdmin);

        assertFalse(_hasAdminRecord(adminSafe));
        assertFalse(_hasAdminRecord(coldAdmin));
        (bool member, uint32 delay) = manager.hasRole(Roles.ADMIN, newAdmin);
        assertTrue(member, "active at once");
        assertEq(delay, ADMIN_DELAY, "with the 30-day delay");
        assertEq(manager.seatHolders(Roles.ADMIN).length, 1);
        assertEq(manager.lastAdminActivity(), block.timestamp);

        // The new admin governs through the ordinary 30-day lane, guardians watching.
        bytes memory grant = abi.encodeCall(
            IAccessManager.grantRole, (Roles.ADMIN, makeAddr("second"), ADMIN_DELAY)
        );
        _scheduleAndExecute(newAdmin, address(manager), grant);
        assertEq(manager.seatHolders(Roles.ADMIN).length, 2);
    }

    function test_OneGuardianCannotApproveAlone() public {
        vm.warp(block.timestamp + SILENCE);
        _open(newAdmin);
        vm.prank(guardianA);
        manager.approveRecovery(newAdmin);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.AlreadyVoted.selector, guardianA));
        vm.prank(guardianA);
        manager.approveRecovery(newAdmin);
        vm.warp(block.timestamp + RECOVERY);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.RecoveryRefused.selector, newAdmin)
        );
        manager.completeRecovery(newAdmin);
    }

    function test_OnlyGuardiansSeatedWhenItOpenedVote() public {
        vm.warp(block.timestamp + SILENCE - 60 days);
        address late = makeAddr("lateGuardian");
        _addGuardian(late); // admin activity: the clock restarts here
        vm.warp(block.timestamp + SILENCE);
        address stranger = makeAddr("stranger");
        _open(newAdmin);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotAVoter.selector, outsider));
        vm.prank(outsider);
        manager.approveRecovery(newAdmin);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotAVoter.selector, stranger));
        vm.prank(stranger);
        manager.approveRecovery(newAdmin);
        vm.prank(late); // seated before it opened
        manager.approveRecovery(newAdmin);
        assertEq(manager.getRecovery(newAdmin).votes, 1);
        assertEq(manager.getRecovery(newAdmin).seats, 4);
    }

    // ------------------------------------------------------------------ admins alive

    function test_AnyAdminActionDuringTheDelayVoidsTheRecovery() public {
        vm.warp(block.timestamp + SILENCE);
        _open(newAdmin);
        vm.prank(guardianA);
        manager.approveRecovery(newAdmin);
        vm.prank(guardianB);
        manager.approveRecovery(newAdmin);
        vm.warp(block.timestamp + RECOVERY - 1);
        vm.prank(coldAdmin);
        manager.heartbeat();
        vm.warp(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.RecoveryNotLive.selector, newAdmin)
        );
        manager.completeRecovery(newAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.RecoveryNotLive.selector, newAdmin)
        );
        vm.prank(guardianC);
        manager.approveRecovery(newAdmin);
        // A new recovery needs a whole new silence.
        uint48 last = manager.lastAdminActivity();
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.AdminsNotSilent.selector, last));
        _open(newAdmin);
        vm.warp(last + SILENCE);
        _open(newAdmin);
        assertEq(manager.getRecovery(newAdmin).votes, 0, "earlier votes do not carry over");
    }

    function test_RecoveryIsNeverFasterThanCompromisingAnAdmin() public {
        // Even at the parameters' floors, a recovery needs 180 + 90 days of total admin silence,
        // against the 30 days of a compromised admin's own (guardian-vetoable) operations.
        _adminExecute(
            _setParameter(WorksAccessManager.Parameter.RECOVERY_SILENCE, SILENCE, 180 days)
        );
        _adminExecute(_setParameter(WorksAccessManager.Parameter.RECOVERY_DELAY, RECOVERY, 90 days));
        uint256 last = manager.lastAdminActivity();
        vm.warp(last + 180 days);
        _open(newAdmin);
        vm.prank(guardianA);
        manager.approveRecovery(newAdmin);
        vm.prank(guardianB);
        manager.approveRecovery(newAdmin);
        vm.warp(last + 270 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.RecoveryNotReady.selector, newAdmin, uint48(last + 270 days)
            )
        );
        manager.completeRecovery(newAdmin);
        vm.warp(last + 270 days);
        manager.completeRecovery(newAdmin);
    }

    // ------------------------------------------------------------------ the registered path

    function test_TheRecoveryAddressCompletesUnlessAMajorityObjects() public {
        _setRecoveryAddress(recovery);
        vm.warp(block.timestamp + SILENCE);
        _open(recovery);
        assertTrue(manager.getRecovery(recovery).registered);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.InvalidCandidate.selector, recovery)
        );
        vm.prank(guardianA);
        manager.approveRecovery(recovery);
        vm.prank(guardianA);
        manager.objectToRecovery(recovery); // one objection is not a majority
        vm.warp(block.timestamp + RECOVERY);
        manager.completeRecovery(recovery);
        assertTrue(_isAdmin(recovery));
    }

    function test_AGuardianMajorityStopsTheRecoveryAddress() public {
        _setRecoveryAddress(recovery);
        vm.warp(block.timestamp + SILENCE);
        _open(recovery);
        vm.prank(guardianA);
        manager.objectToRecovery(recovery);
        vm.prank(guardianC);
        manager.objectToRecovery(recovery);
        vm.warp(block.timestamp + RECOVERY);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.RecoveryRefused.selector, recovery)
        );
        manager.completeRecovery(recovery);
        // The guardians can still install someone else by majority.
        _open(newAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.InvalidCandidate.selector, newAdmin)
        );
        vm.prank(guardianA);
        manager.objectToRecovery(newAdmin);
    }

    function test_AdminsAndGuardiansBothDead_OnlyTheRecoveryAddressRecovers() public {
        // Nobody votes: the guardian path cannot complete, the registered one can.
        _setRecoveryAddress(recovery);
        vm.warp(block.timestamp + SILENCE);
        _open(newAdmin);
        _open(recovery);
        vm.warp(block.timestamp + RECOVERY);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.RecoveryRefused.selector, newAdmin)
        );
        manager.completeRecovery(newAdmin);
        manager.completeRecovery(recovery);
        assertTrue(_isAdmin(recovery));
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.RecoveryNotLive.selector, newAdmin)
        );
        manager.completeRecovery(newAdmin);
    }

    function test_Residual_AdminsAndGuardiansBothDeadWithNoRecoveryAddressNothingRecovers() public {
        vm.warp(block.timestamp + SILENCE);
        _open(newAdmin);
        vm.warp(block.timestamp + 10 * 365 days);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.RecoveryRefused.selector, newAdmin)
        );
        manager.completeRecovery(newAdmin);
    }

    function test_AdminsAliveGuardiansDead_TheAdminsReplaceTheGuardians() public {
        // No recovery is involved: nobody is left to cancel the admins' ordinary operations.
        _removeGuardianUnopposed(guardianA);
        _removeGuardianUnopposed(guardianB);
        _removeGuardianUnopposed(guardianC);
        assertEq(_guardianSeats(), 0);
        address fresh = makeAddr("freshGuardian");
        _addGuardian(fresh);
        (bool member,) = manager.hasRole(Roles.GUARDIAN, fresh);
        assertTrue(member);
    }

    /// @dev Review round 4: completing a recovery withdraws the former admins' pending successor
    ///      (`SuccessorProposed(0, 0)`), so it cannot accept before the new admin could withdraw
    ///      it in the slow lane, even with its probe already re-pointed. The new admin may
    ///      propose it again. Fails without the change: the successor accepts right after the
    ///      recovery and the manager is handed over.
    function test_ARecoveryWithdrawsTheFormerAdminsPendingSuccessor() public {
        address nextAdmin = makeAddr("nextAdmin");
        AccessManager next = new AccessManager(nextAdmin);
        _scheduleAndExecute(adminSafe, address(manager), _register(address(next)));
        address probe = manager.successionProbe();
        vm.prank(nextAdmin);
        next.execute(probe, abi.encodeCall(IAccessManaged.setAuthority, (address(manager))));
        vm.warp(block.timestamp + SILENCE);
        _open(newAdmin);
        vm.prank(guardianA);
        manager.approveRecovery(newAdmin);
        vm.prank(guardianB);
        manager.approveRecovery(newAdmin);
        vm.warp(block.timestamp + RECOVERY);
        vm.expectEmit(address(manager));
        emit WorksAccessManager.SuccessorProposed(address(0), address(0));
        vm.expectEmit(address(manager));
        emit WorksAccessManager.AdminActivity(newAdmin, uint48(block.timestamp));
        vm.expectEmit(address(manager));
        emit WorksAccessManager.RecoveryCompleted(newAdmin);
        manager.completeRecovery(newAdmin);
        assertEq(manager.pendingSuccessor(), address(0));
        assertEq(manager.successionProbe(), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.NotPendingSuccessor.selector, address(next))
        );
        vm.prank(nextAdmin);
        next.execute(address(manager), abi.encodeCall(WorksAccessManager.acceptSuccession, ()));
        assertEq(manager.successor(), address(0));
        assertTrue(_isAdmin(newAdmin));
        // The new admin decides: it may propose the same successor again, in the slow lane.
        _scheduleAndExecute(newAdmin, address(manager), _register(address(next)));
        assertEq(manager.pendingSuccessor(), address(next));
    }

    /// @dev Review round 4, the other order: a pending successor that accepts while a recovery
    ///      is open wins, and the recovery can no longer complete (`HandedOver`); a successor
    ///      the admins proposed in the slow lane, past every guardian's veto, stands until a
    ///      recovery completes. A recovery with no pending successor withdraws nothing.
    function test_ASuccessorAcceptingFirstEndsTheOpenRecovery() public {
        address nextAdmin = makeAddr("nextAdmin");
        AccessManager next = new AccessManager(nextAdmin);
        _scheduleAndExecute(adminSafe, address(manager), _register(address(next)));
        vm.warp(block.timestamp + SILENCE);
        _open(newAdmin);
        vm.prank(guardianA);
        manager.approveRecovery(newAdmin);
        vm.prank(guardianB);
        manager.approveRecovery(newAdmin);
        _accept(next, nextAdmin);
        assertEq(manager.successor(), address(next));
        vm.warp(block.timestamp + RECOVERY);
        vm.expectRevert(WorksAccessManager.HandedOver.selector);
        manager.completeRecovery(newAdmin);
    }

    /// @dev Review round 4: every move of the activity clock, which voids open recoveries, is in
    ///      the logs (`AdminActivity`): a heartbeat, a schedule, an execute, a cancel and a
    ///      completed recovery (above). A second activity at the same time moves nothing and
    ///      logs nothing. Fails without the change: no event.
    function test_EveryMoveOfTheActivityClockIsLogged() public {
        vm.warp(block.timestamp + 10 days);
        vm.expectEmit(address(manager));
        emit WorksAccessManager.AdminActivity(adminSafe, uint48(block.timestamp));
        vm.prank(adminSafe);
        manager.heartbeat();
        vm.recordLogs();
        vm.prank(coldAdmin);
        manager.heartbeat();
        assertEq(vm.getRecordedLogs().length, 0, "the clock already reads now");
        bytes memory op = abi.encodeCall(IAccessManager.labelRole, (Roles.KEEPER, "k"));
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(address(manager));
        emit WorksAccessManager.AdminActivity(coldAdmin, uint48(block.timestamp));
        _schedule(coldAdmin, address(manager), op);
        vm.warp(block.timestamp + ADMIN_DELAY);
        vm.expectEmit(address(manager));
        emit WorksAccessManager.AdminActivity(coldAdmin, uint48(block.timestamp));
        vm.prank(coldAdmin);
        manager.execute(address(manager), op);
        vm.warp(block.timestamp + 1 days);
        _schedule(coldAdmin, address(manager), op);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(address(manager));
        emit WorksAccessManager.AdminActivity(adminSafe, uint48(block.timestamp));
        vm.prank(adminSafe);
        manager.cancel(coldAdmin, address(manager), op);
        assertEq(manager.lastAdminActivity(), block.timestamp);
    }

    function test_NoRecoveryAfterAHandover() public {
        AccessManager next = new AccessManager(makeAddr("next"));
        _scheduleAndExecute(adminSafe, address(manager), _register(address(next)));
        _accept(next, makeAddr("next"));
        vm.warp(block.timestamp + SILENCE);
        vm.expectRevert(WorksAccessManager.HandedOver.selector);
        _open(newAdmin);
    }

    // ------------------------------------------------------------------ separation of roles

    /// @dev Review I-4: a guardian majority cannot make one of its own seats the sole admin
    ///      while it keeps its veto, by approval or as the registered recovery address.
    function test_ARecoveryCannotSeatAGuardianAsAdmin() public {
        vm.warp(block.timestamp + SILENCE);
        _open(guardianC);
        vm.prank(guardianA);
        manager.approveRecovery(guardianC);
        vm.prank(guardianB);
        manager.approveRecovery(guardianC);
        vm.warp(block.timestamp + RECOVERY);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.InvalidCandidate.selector, guardianC)
        );
        manager.completeRecovery(guardianC);
        assertTrue(_isAdmin(adminSafe), "nothing changed");
        // Once it leaves the guardian body (both roles), the same seat can be installed.
        vm.startPrank(guardianC);
        manager.renounceRole(Roles.GUARDIAN, guardianC);
        vm.expectRevert( // still a pauser: refused
            abi.encodeWithSelector(WorksAccessManager.InvalidCandidate.selector, guardianC)
        );
        manager.completeRecovery(guardianC);
        manager.renounceRole(Roles.PAUSER, guardianC);
        vm.stopPrank();
        manager.completeRecovery(guardianC);
        assertTrue(_isAdmin(guardianC));
        assertFalse(_hasAdminRecord(adminSafe));
    }
}
