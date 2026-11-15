// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
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

    function test_NoRecoveryAfterAHandover() public {
        address next = address(new AccessManager(makeAddr("next")));
        bytes memory register = _register(next);
        _scheduleAndExecute(adminSafe, address(manager), register);
        vm.warp(block.timestamp + SILENCE);
        vm.expectRevert(WorksAccessManager.HandedOver.selector);
        _open(newAdmin);
    }
}
