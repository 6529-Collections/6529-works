// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Multicall } from "@openzeppelin/contracts/utils/Multicall.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { PermanenceFixture } from "./PermanenceFixture.sol";

/// @notice The bounded veto (GV-37): a guardian's first cancellation of a guardian's removal or
///         of a successor registration works as before and strikes the action; a re-proposal
///         waits the escalated delay and only a majority of the guardian seats counted when it
///         was scheduled, never fewer than two guardians, can stop it.
contract BoundedVetoTest is PermanenceFixture {
    address internal successorA;
    address internal successorB;

    function setUp() public {
        _deployGovernance();
        successorA = address(new AccessManager(makeAddr("successor admin A")));
        successorB = address(new AccessManager(makeAddr("successor admin B")));
    }

    // ------------------------------------------------------------------ the first cancellation

    function test_AGuardiansFirstCancellationWorksAsBeforeAndStrikesTheAction() public {
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        bytes32 id = _schedule(adminSafe, address(manager), removeA);
        assertEq(manager.getSchedule(id), block.timestamp + ADMIN_DELAY, "normal lane");
        bytes32 action = manager.actionOf(address(manager), removeA);
        assertFalse(manager.isStruck(action));

        vm.expectEmit(address(manager));
        emit WorksAccessManager.ActionStruck(action, id);
        _cancel(guardianB, adminSafe, removeA);
        assertEq(manager.getSchedule(id), 0, "a single guardian cancels the first proposal");
        assertTrue(manager.isStruck(action));
    }

    function test_OnlyAGuardiansCancellationStrikes() public {
        // The scheduler withdrawing its own proposal is no strike.
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        _strike(adminSafe, removeA, adminSafe);
        assertFalse(manager.isStruck(manager.actionOf(address(manager), removeA)));

        // Another admin may cancel a successor registration (stock rule), but that is no
        // strike: two admins cannot push a successor past the single-guardian veto.
        bytes memory register = _register(successorA);
        _strike(adminSafe, register, coldAdmin);
        assertFalse(manager.isStruck(manager.actionOf(address(manager), register)));
        bytes32 id = _schedule(adminSafe, address(manager), register);
        assertEq(manager.getSchedule(id), block.timestamp + SLOW, "still the slow lane");
        assertEq(manager.getEscalation(id).nonce, 0, "not escalated");
    }

    // ------------------------------------------------------------------ the escalated lane

    function test_AReProposalEntersTheEscalatedLane() public {
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        _strike(adminSafe, removeA, guardianB);
        bytes32 action = manager.actionOf(address(manager), removeA);
        bytes32 id = _id(adminSafe, removeA);

        vm.expectEmit(address(manager));
        emit WorksAccessManager.OperationEscalated(id, 2, action, 3);
        _schedule(adminSafe, address(manager), removeA);
        assertEq(manager.getSchedule(id), block.timestamp + ESCALATED);
        WorksAccessManager.Escalation memory e = manager.getEscalation(id);
        assertEq(e.nonce, 2);
        assertEq(e.seats, 3);
        assertEq(e.votes, 0);
    }

    function test_TheSameActionWhoeverProposesItAndWithTrailingBytes() public {
        _strike(adminSafe, _revoke(Roles.GUARDIAN, guardianA), guardianB);
        // Another admin, the PAUSER half of the same removal, and trailing bytes: all escalated.
        bytes memory byCold = _revoke(Roles.GUARDIAN, guardianA);
        bytes memory pauser = _revoke(Roles.PAUSER, guardianA);
        bytes memory trailing = abi.encodePacked(byCold, bytes32("trailing"));
        bytes32 a = _schedule(coldAdmin, address(manager), byCold);
        bytes32 b = _schedule(adminSafe, address(manager), pauser);
        bytes32 c = _schedule(adminSafe, address(manager), trailing);
        assertEq(manager.getSchedule(a), block.timestamp + ESCALATED);
        assertEq(manager.getSchedule(b), block.timestamp + ESCALATED);
        assertEq(manager.getSchedule(c), block.timestamp + ESCALATED);
        // Another guardian's removal is another action: the normal lane.
        bytes32 d = _schedule(adminSafe, address(manager), _revoke(Roles.GUARDIAN, guardianC));
        assertEq(manager.getSchedule(d), block.timestamp + ADMIN_DELAY);
    }

    function test_DirtyArgumentsAreNotProtectedAndCannotStrikeTheCleanAction() public {
        bytes memory clean = _revoke(Roles.GUARDIAN, guardianA);
        bytes memory dirty = abi.encodeWithSelector(
            IAccessManager.revokeRole.selector,
            Roles.GUARDIAN,
            uint256(uint160(guardianA)) | (uint256(1) << 200)
        );
        assertEq(manager.actionOf(address(manager), dirty), bytes32(0));
        _strike(adminSafe, dirty, guardianB);
        assertFalse(manager.isStruck(manager.actionOf(address(manager), clean)));
        // Other roles and other targets are not protected either.
        assertEq(manager.actionOf(address(manager), _revoke(Roles.ADMIN, coldAdmin)), bytes32(0));
        assertEq(manager.actionOf(address(target), clean), bytes32(0));
    }

    function test_ASingleGuardianCannotStopAnEscalatedOperation() public {
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        _strike(adminSafe, removeA, guardianB);
        bytes32 id = _schedule(adminSafe, address(manager), removeA);
        uint48 ready = manager.getSchedule(id);
        bytes32 ballot = keccak256(abi.encode(id, uint32(2)));

        vm.expectEmit(address(manager));
        emit WorksAccessManager.GuardianVoted(ballot, guardianB, 1, 3);
        _cancel(guardianB, adminSafe, removeA);
        assertEq(manager.getSchedule(id), ready, "one vote does not stop it");
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.AlreadyVoted.selector, guardianB));
        _cancel(guardianB, adminSafe, removeA);
    }

    function test_AMajorityOfTheSeatsStopsIt() public {
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        _strike(adminSafe, removeA, guardianB);
        bytes32 id = _schedule(adminSafe, address(manager), removeA);
        _cancel(guardianB, adminSafe, removeA);
        vm.expectEmit(address(manager));
        emit IAccessManager.OperationCanceled(id, 2);
        _cancel(guardianC, adminSafe, removeA);
        assertEq(manager.getSchedule(id), 0);
        // It stays struck: the next proposal is escalated again.
        _schedule(adminSafe, address(manager), removeA);
        assertEq(manager.getSchedule(id), block.timestamp + ESCALATED);
        assertEq(manager.getEscalation(id).nonce, 3);
    }

    function test_NoAdminOrOutsiderCanStopItButTheSchedulerMayWithdraw() public {
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        _strike(adminSafe, removeA, guardianB);
        bytes32 id = _schedule(adminSafe, address(manager), removeA);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotAVoter.selector, coldAdmin));
        _cancel(coldAdmin, adminSafe, removeA);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotAVoter.selector, outsider));
        _cancel(outsider, adminSafe, removeA);
        _cancel(adminSafe, adminSafe, removeA);
        assertEq(manager.getSchedule(id), 0, "the scheduler withdraws");
    }

    function test_ItExecutesAfterTheEscalatedDelayAndTheStrikeEndsWithTheRemoval() public {
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        bytes memory pauserA = _revoke(Roles.PAUSER, guardianA);
        _strike(adminSafe, removeA, guardianB);
        bytes32 id = _schedule(adminSafe, address(manager), removeA);
        _schedule(adminSafe, address(manager), pauserA);
        vm.warp(block.timestamp + ESCALATED - 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        vm.prank(adminSafe);
        manager.execute(address(manager), removeA);
        vm.warp(block.timestamp + 1);
        vm.startPrank(adminSafe);
        manager.execute(address(manager), removeA);
        bytes32 action = manager.actionOf(address(manager), removeA);
        assertTrue(manager.isStruck(action), "PAUSER still held");
        manager.execute(address(manager), pauserA);
        vm.stopPrank();
        assertFalse(manager.isStruck(action), "removal complete");
        (bool member,) = manager.hasRole(Roles.GUARDIAN, guardianA);
        assertFalse(member);
    }

    // ------------------------------------------------------------------ who votes

    function test_TheNamedGuardianVotesWithItsSeat() public {
        // A compromised admin and a dishonest guardian C against honest A and B: the honest
        // majority (A, B) stops the removal of A.
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        _strike(attackerAdmin(), removeA, guardianB);
        bytes32 id = _schedule(adminSafe, address(manager), removeA);
        _cancel(guardianA, adminSafe, removeA);
        _cancel(guardianB, adminSafe, removeA);
        assertEq(manager.getSchedule(id), 0, "honest majority of three");
    }

    function test_Residual_TwoColludingGuardiansOfThreeAreAMajority() public {
        // With three seats two guardians are a majority, so they still shield each other.
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        _strike(adminSafe, removeA, guardianB);
        bytes32 id = _schedule(adminSafe, address(manager), removeA);
        _cancel(guardianA, adminSafe, removeA);
        _cancel(guardianB, adminSafe, removeA);
        assertEq(manager.getSchedule(id), 0);
    }

    function test_TwoColludingGuardiansOfFiveCannotShieldEachOther() public {
        address guardianD = makeAddr("guardianD");
        address guardianE = makeAddr("guardianE");
        _addGuardian(guardianD);
        _addGuardian(guardianE);
        assertEq(_guardianSeats(), 5);

        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        bytes memory pauserA = _revoke(Roles.PAUSER, guardianA);
        _strike(adminSafe, removeA, guardianB); // B shields A once
        bytes32 id = _schedule(adminSafe, address(manager), removeA);
        _schedule(adminSafe, address(manager), pauserA);
        _cancel(guardianA, adminSafe, removeA);
        _cancel(guardianB, adminSafe, removeA);
        _cancel(guardianA, adminSafe, pauserA);
        _cancel(guardianB, adminSafe, pauserA);
        assertEq(manager.getEscalation(id).votes, 2);
        assertTrue(_scheduled(adminSafe, removeA), "two of five is no majority");
        vm.warp(block.timestamp + ESCALATED);
        vm.startPrank(adminSafe);
        manager.execute(address(manager), removeA);
        manager.execute(address(manager), pauserA);
        vm.stopPrank();
        assertFalse(GovernanceRecord.has(manager, Roles.GUARDIAN, guardianA));

        // B alone cannot cancel its own removal (Rule 2) and has no partner left.
        bytes memory removeB = _revoke(Roles.GUARDIAN, guardianB);
        bytes32 idB = _schedule(adminSafe, address(manager), removeB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCancel.selector,
                guardianB,
                adminSafe,
                address(manager),
                IAccessManager.revokeRole.selector
            )
        );
        _cancel(guardianB, adminSafe, removeB);
        vm.warp(manager.getSchedule(idB));
        vm.prank(adminSafe);
        manager.execute(address(manager), removeB);
        assertFalse(GovernanceRecord.has(manager, Roles.GUARDIAN, guardianB));
    }

    function test_WithTwoSeatsBothGuardiansMustVote() public {
        _removeGuardianUnopposed(guardianC);
        assertEq(_guardianSeats(), 2);
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        _strike(adminSafe, removeA, guardianB);
        bytes32 id = _schedule(adminSafe, address(manager), removeA);
        _cancel(guardianA, adminSafe, removeA);
        assertTrue(_scheduled(adminSafe, removeA), "one of two");
        _cancel(guardianB, adminSafe, removeA);
        assertEq(manager.getSchedule(id), 0, "two of two");

        // If B does not vote, A's own vote cannot stop it: the removal executes.
        _schedule(adminSafe, address(manager), removeA);
        _cancel(guardianA, adminSafe, removeA);
        vm.warp(block.timestamp + ESCALATED);
        vm.prank(adminSafe);
        manager.execute(address(manager), removeA);
        assertFalse(GovernanceRecord.has(manager, Roles.GUARDIAN, guardianA));
    }

    function test_ASoleGuardianNeverStopsAnEscalatedOperation() public {
        bytes memory register = _register(successorA);
        _strike(adminSafe, register, guardianA);
        _removeGuardianUnopposed(guardianB);
        _removeGuardianUnopposed(guardianC);
        assertEq(_guardianSeats(), 1);
        bytes32 id = _schedule(adminSafe, address(manager), register);
        assertEq(manager.getEscalation(id).seats, 1);
        _cancel(guardianA, adminSafe, register);
        assertTrue(_scheduled(adminSafe, register), "a decision needs two guardians");
        vm.warp(manager.getSchedule(id));
        vm.prank(adminSafe);
        manager.registerSuccessor(successorA);
        assertEq(manager.pendingSuccessor(), successorA);
    }

    function test_SeatChangesMidFlightDoNotMoveTheCount() public {
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        _strike(adminSafe, removeA, guardianB);
        bytes32 id = _schedule(adminSafe, address(manager), removeA);
        assertEq(manager.getEscalation(id).seats, 3);

        _cancel(guardianC, adminSafe, removeA); // C votes, then leaves
        vm.prank(guardianC);
        manager.renounceRole(Roles.GUARDIAN, guardianC);
        address guardianD = makeAddr("guardianD");
        _addGuardian(guardianD); // seated after the snapshot: no vote
        assertTrue(_scheduled(adminSafe, removeA));
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotAVoter.selector, guardianD));
        _cancel(guardianD, adminSafe, removeA);

        // C's vote stays counted against the three seats of the snapshot.
        _cancel(guardianB, adminSafe, removeA);
        assertEq(manager.getSchedule(id), 0);
    }

    // ------------------------------------------------------------------ the successor

    function test_ASuccessorRegistrationHasTheBoundedVetoToo() public {
        bytes memory register = _register(successorA);
        bytes32 id = _schedule(adminSafe, address(manager), register);
        assertEq(manager.getSchedule(id), block.timestamp + SLOW, "slow lane");
        _cancel(guardianC, adminSafe, register);
        assertTrue(manager.isStruck(manager.actionOf(address(manager), register)));

        _schedule(adminSafe, address(manager), register);
        assertEq(manager.getSchedule(id), block.timestamp + ESCALATED, "escalated lane");
        _cancel(guardianC, adminSafe, register);
        assertTrue(_scheduled(adminSafe, register), "one guardian no longer stops it");

        // Another successor is another action: the slow lane, and one guardian stops it.
        bytes memory other = _register(successorB);
        bytes32 otherId = _schedule(adminSafe, address(manager), other);
        assertEq(manager.getSchedule(otherId), block.timestamp + SLOW);
        _cancel(guardianC, adminSafe, other);
        assertEq(manager.getSchedule(otherId), 0);

        vm.warp(manager.getSchedule(id));
        vm.prank(adminSafe);
        manager.registerSuccessor(successorA);
        assertEq(manager.pendingSuccessor(), successorA);
        // The action executed: its strike is spent, so a later proposal of it (after a
        // withdrawal) starts in the slow lane again.
        assertFalse(manager.isStruck(manager.actionOf(address(manager), register)));
    }

    /// @dev Withdrawing a pending successor, `registerSuccessor(0)`, is keyed on zero: a
    ///      guardian's strike on a withdrawal escalates only later withdrawals, never a
    ///      proposal of a real successor, and a strike on one successor never reaches another.
    function test_AWithdrawalIsItsOwnActionAndCannotShieldAProposal() public {
        _scheduleAndExecute(adminSafe, address(manager), _register(successorA));
        bytes memory withdraw = _register(address(0));
        bytes32 withdrawKey = manager.actionOf(address(manager), withdraw);
        assertTrue(withdrawKey != bytes32(0));
        assertTrue(withdrawKey != manager.actionOf(address(manager), _register(successorA)));
        _strike(adminSafe, withdraw, guardianA);
        assertTrue(manager.isStruck(withdrawKey));
        // Replacing A by B is B's action: the slow lane, unaffected by the withdrawal's strike.
        bytes memory registerB = _register(successorB);
        bytes32 idB = _schedule(adminSafe, address(manager), registerB);
        assertEq(manager.getSchedule(idB), block.timestamp + SLOW);
        // The withdrawal itself is escalated now, and stopped only by a majority.
        bytes32 idW = _schedule(adminSafe, address(manager), withdraw);
        assertEq(manager.getSchedule(idW), block.timestamp + ESCALATED);
        _cancel(guardianA, adminSafe, withdraw);
        assertTrue(_scheduled(adminSafe, withdraw));
        _cancel(guardianB, adminSafe, withdraw);
        assertFalse(_scheduled(adminSafe, withdraw));
        assertEq(manager.pendingSuccessor(), successorA, "still pending");
    }

    function test_AWrappedRegistrationNeverExecutes() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = _register(successorA);
        bytes memory wrapped = abi.encodeCall(Multicall.multicall, (calls));
        bytes32 id = _schedule(adminSafe, address(manager), wrapped);
        assertEq(manager.getSchedule(id), block.timestamp + ADMIN_DELAY, "no slow lane");
        vm.warp(manager.getSchedule(id));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                address(manager),
                Roles.ADMIN
            )
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), wrapped);
        assertEq(manager.pendingSuccessor(), address(0));
    }

    function attackerAdmin() internal view returns (address) {
        return coldAdmin; // stands for a compromised admin seat
    }
}

/// @dev Whether an account has any record for a role.
library GovernanceRecord {
    function has(WorksAccessManager manager, uint64 role, address account)
        internal
        view
        returns (bool)
    {
        (uint48 since,,,) = manager.getAccess(role, account);
        return since != 0;
    }
}
