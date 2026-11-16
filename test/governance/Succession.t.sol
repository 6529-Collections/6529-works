// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernedTargetMock } from "../mocks/governance/GovernanceMocks.sol";
import {
    AcceptOnlyAuthorityMock,
    BurningTargetMock,
    CanCallOnlyAuthorityMock,
    RefusingTargetMock,
    RevertingAuthorityMock
} from "../mocks/governance/SuccessionMocks.sol";
import { SuccessionProbe } from "src/governance/SuccessionProbe.sol";
import { PermanenceFixture } from "./PermanenceFixture.sol";

/// @notice The two-step succession and `migrate` (GV-43 to GV-45): `registerSuccessor` (slow
///         lane, bounded veto) only proposes; the manager keeps all its power until the proposed
///         successor re-points its probe to the manager and calls `acceptSuccession` itself;
///         `migrate` then re-points every managed target, the ones configured after genesis
///         included, in caller-chosen all-or-nothing pieces that anyone may run.
contract SuccessionTest is PermanenceFixture {
    AccessManager internal next;
    address internal nextAdmin = makeAddr("nextAdmin");
    GovernedTargetMock internal second;
    GovernedTargetMock internal third;

    function setUp() public {
        _deployGovernance();
        next = new AccessManager(nextAdmin);
        second = new GovernedTargetMock(address(manager), recipient0, verifier0);
        third = new GovernedTargetMock(address(manager), recipient0, verifier0);
    }

    /// @dev Configures targets after genesis the way the runbook does (a 30-day admin delay),
    ///      all in one 30-day round.
    function _onboard(address[] memory targets) internal {
        bytes32 id;
        for (uint256 i; i < targets.length; ++i) {
            id = _schedule(adminSafe, address(manager), _delayOf(targets[i]));
        }
        vm.warp(manager.getSchedule(id));
        vm.startPrank(adminSafe);
        for (uint256 i; i < targets.length; ++i) {
            manager.execute(address(manager), _delayOf(targets[i]));
        }
        vm.stopPrank();
    }

    function _delayOf(address t) internal pure returns (bytes memory) {
        return abi.encodeCall(IAccessManager.setTargetAdminDelay, (t, 30 days));
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        (l[0], l[1]) = (a, b);
    }

    function _handOver() internal {
        _propose(address(next));
        _accept(next, nextAdmin);
    }

    function _propose(address successor_) internal {
        _scheduleAndExecute(adminSafe, address(manager), _register(successor_));
    }

    /// @dev The manager still governs: an admin is a member and a guardian's pause works.
    function _assertStillInPower() internal {
        (bool member,) = manager.hasRole(Roles.ADMIN, adminSafe);
        assertTrue(member, "admins keep their power");
        vm.prank(guardianA);
        target.pause();
        assertTrue(target.paused(), "guardians keep their power");
    }

    // ------------------------------------------------------------------ the managed list

    function test_GenesisTargetsAndLaterTargetsAreManaged() public {
        address[] memory managed = manager.managedTargets();
        assertEq(managed.length, 1);
        assertEq(managed[0], address(target));
        configurator.verify(_config());

        bytes32 id = _schedule(adminSafe, address(manager), _delayOf(address(second)));
        vm.warp(manager.getSchedule(id));
        vm.expectEmit(address(manager));
        emit WorksAccessManager.TargetManaged(address(second));
        vm.prank(adminSafe);
        manager.execute(address(manager), _delayOf(address(second)));
        _onboard(_list(address(second), address(target)));
        // A selector mapping also enrols a target; nothing is listed twice; never the manager.
        bytes memory map = abi.encodeCall(
            IAccessManager.setTargetFunctionRole,
            (address(third), _one(GovernedTargetMock.setFee.selector), Roles.PARAMETER_SETTER)
        );
        _adminExecute(map);
        managed = manager.managedTargets();
        assertEq(managed.length, 3);
        assertEq(managed[1], address(second));
        assertEq(managed[2], address(third));
    }

    // ------------------------------------------------------------------ registration

    function test_RegistrationWaitsTheSlowDelayAndOnlyProposes() public {
        bytes memory register = _register(address(next));
        bytes32 id = _schedule(adminSafe, address(manager), register);
        assertEq(manager.getSchedule(id), block.timestamp + SLOW);
        vm.warp(block.timestamp + SLOW - 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        vm.prank(adminSafe);
        manager.registerSuccessor(address(next));
        vm.warp(block.timestamp + 1);
        // The probe is the manager's next CREATE.
        address probe = vm.computeCreateAddress(address(manager), vm.getNonce(address(manager)));
        vm.expectEmit(address(manager));
        emit WorksAccessManager.SuccessorProposed(address(next), probe);
        vm.prank(adminSafe);
        manager.registerSuccessor(address(next));
        assertEq(manager.pendingSuccessor(), address(next));
        assertEq(manager.successionProbe(), probe);
        assertEq(SuccessionProbe(probe).authority(), address(next), "governed by the successor");
        assertEq(manager.successor(), address(0), "nothing handed over yet");
        _assertStillInPower();
        vm.expectRevert(WorksAccessManager.NoSuccessor.selector);
        manager.migrate(0, type(uint256).max);
    }

    function test_AcceptanceEndsTheManagersPower() public {
        _propose(address(next));
        address probe = manager.successionProbe();
        vm.startPrank(nextAdmin);
        next.execute(probe, abi.encodeCall(IAccessManaged.setAuthority, (address(manager))));
        vm.expectEmit(address(manager));
        emit WorksAccessManager.SuccessorAccepted(address(next));
        next.execute(address(manager), abi.encodeCall(WorksAccessManager.acceptSuccession, ()));
        vm.stopPrank();
        assertEq(manager.successor(), address(next));
        assertEq(manager.pendingSuccessor(), address(0));
        assertEq(manager.successionProbe(), address(0));

        // No residual power: no role answers, no call is allowed, nothing can be scheduled.
        (bool member,) = manager.hasRole(Roles.ADMIN, adminSafe);
        assertFalse(member);
        (bool immediate, uint32 delay) =
            manager.canCall(guardianA, address(target), GovernedTargetMock.pause.selector);
        assertFalse(immediate);
        assertEq(delay, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardianA)
        );
        vm.prank(guardianA);
        target.pause();
        bytes memory grab =
            abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, attacker, 30 days));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                adminSafe,
                address(manager),
                IAccessManager.grantRole.selector
            )
        );
        vm.prank(adminSafe);
        manager.schedule(address(manager), grab, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, guardianA, Roles.GUARDIAN
            )
        );
        vm.prank(guardianA);
        manager.suspend(Roles.PLATFORM, platform);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, adminSafe, Roles.ADMIN
            )
        );
        vm.prank(adminSafe);
        manager.heartbeat();
        // Accepting twice is impossible: nothing is pending any more.
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.NotPendingSuccessor.selector, address(next))
        );
        vm.prank(address(next));
        manager.acceptSuccession();
    }

    // ------------------------------------------------------------------ proving it can act

    /// @dev Review M-1: an authority that answers `canCall` but cannot originate a call is
    ///      proposed, never takes over, and the admins replace it under the same slow lane.
    function test_ASuccessorThatCannotCallNeverTakesOver() public {
        CanCallOnlyAuthorityMock dead = new CanCallOnlyAuthorityMock();
        _propose(address(dead));
        assertEq(manager.pendingSuccessor(), address(dead));
        // Nobody can accept for it, and migrate has nothing to move to.
        address[4] memory others = [adminSafe, guardianA, outsider, address(manager)];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(WorksAccessManager.NotPendingSuccessor.selector, others[i])
            );
            vm.prank(others[i]);
            manager.acceptSuccession();
        }
        vm.expectRevert(WorksAccessManager.NoSuccessor.selector);
        manager.migrate(0, type(uint256).max);
        vm.warp(block.timestamp + 365 days);
        _assertStillInPower();
        assertEq(target.authority(), address(manager));

        // Replaced by a working successor through the slow lane; the dead one never accepts.
        _propose(address(next));
        assertEq(manager.pendingSuccessor(), address(next));
        _accept(next, nextAdmin);
        manager.migrate(0, type(uint256).max);
        assertEq(target.authority(), address(next));
    }

    /// @dev An admin's `execute` of `acceptSuccession` runs as the manager itself, not the
    ///      successor, so it cannot accept on the successor's behalf; acceptance is no
    ///      protected action, so it neither strikes nor dodges anything.
    function test_AnAdminCannotAcceptForTheSuccessor() public {
        _propose(address(next));
        bytes memory accept = abi.encodeCall(WorksAccessManager.acceptSuccession, ());
        bytes32 id = _schedule(adminSafe, address(manager), accept);
        vm.warp(manager.getSchedule(id));
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.NotPendingSuccessor.selector, address(manager)
            )
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), accept);
        assertEq(manager.actionOf(address(manager), accept), bytes32(0), "not a protected action");
    }

    /// @dev The successor must re-point its probe first: that is the `setAuthority` call it will
    ///      need on every permanent contract. One hard-wired call to the manager is not enough.
    function test_AcceptanceNeedsTheProbeRepointed() public {
        _propose(address(next));
        address probe = manager.successionProbe();
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.SuccessionUnproven.selector, probe)
        );
        vm.prank(nextAdmin);
        next.execute(address(manager), abi.encodeCall(WorksAccessManager.acceptSuccession, ()));

        AcceptOnlyAuthorityMock wired = new AcceptOnlyAuthorityMock();
        _propose(address(wired));
        probe = manager.successionProbe();
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.SuccessionUnproven.selector, probe)
        );
        wired.accept(address(manager));

        // Re-pointed elsewhere is not enough either: it must name the manager.
        _propose(address(next));
        probe = manager.successionProbe();
        address elsewhere = address(new AccessManager(makeAddr("elsewhere")));
        vm.prank(nextAdmin);
        next.execute(probe, abi.encodeCall(IAccessManaged.setAuthority, (elsewhere)));
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.SuccessionUnproven.selector, probe)
        );
        vm.prank(address(next));
        manager.acceptSuccession();
        assertEq(manager.successor(), address(0));
        // Nobody but the successor can re-point its probe.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, adminSafe)
        );
        vm.prank(adminSafe);
        SuccessionProbe(probe).setAuthority(address(manager));
    }

    /// @dev A replaced or withdrawn proposal cannot accept, even with its old probe re-pointed.
    function test_AReplacedOrWithdrawnProposalCannotAccept() public {
        AccessManager other = new AccessManager(nextAdmin);
        _propose(address(other));
        address oldProbe = manager.successionProbe();
        vm.prank(nextAdmin);
        other.execute(oldProbe, abi.encodeCall(IAccessManaged.setAuthority, (address(manager))));
        _propose(address(next)); // replaces `other`
        assertTrue(manager.successionProbe() != oldProbe, "a fresh probe");
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.NotPendingSuccessor.selector, address(other))
        );
        vm.prank(address(other));
        manager.acceptSuccession();

        bytes memory withdraw = _register(address(0));
        bytes32 id = _schedule(adminSafe, address(manager), withdraw);
        assertEq(manager.getSchedule(id), block.timestamp + SLOW, "the same slow lane");
        vm.warp(manager.getSchedule(id));
        vm.expectEmit(address(manager));
        emit WorksAccessManager.SuccessorProposed(address(0), address(0));
        vm.prank(adminSafe);
        manager.execute(address(manager), withdraw);
        assertEq(manager.pendingSuccessor(), address(0));
        assertEq(manager.successionProbe(), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.NotPendingSuccessor.selector, address(next))
        );
        vm.prank(address(next));
        manager.acceptSuccession();
        _assertStillInPower();
    }

    /// @dev While a proposal is pending the manager is fully in power: guardians still suspend
    ///      and cancel, and a dead-admin recovery still opens and completes.
    function test_WhilePendingRecoveryAndGuardiansStillWork() public {
        _propose(address(new CanCallOnlyAuthorityMock()));
        vm.prank(guardianA);
        manager.suspend(Roles.PLATFORM, platform);
        assertTrue(manager.isSuspended(Roles.PLATFORM, platform));
        bytes memory grant = abi.encodeCall(IAccessManager.grantRole, (Roles.CURATOR, outsider, 0));
        _schedule(adminSafe, address(manager), grant);
        _cancel(guardianB, adminSafe, grant);
        assertFalse(_scheduled(adminSafe, grant));
        vm.warp(block.timestamp + SILENCE);
        address candidate = makeAddr("candidate");
        manager.openRecovery(candidate);
        vm.prank(guardianA);
        manager.approveRecovery(candidate);
        vm.prank(guardianB);
        manager.approveRecovery(candidate);
        vm.warp(block.timestamp + RECOVERY);
        manager.completeRecovery(candidate);
        (bool member,) = manager.hasRole(Roles.ADMIN, candidate);
        assertTrue(member);
    }

    function test_ASuccessorMustHaveCodeAndAnswerCanCall() public {
        address[3] memory bad =
            [makeAddr("noCode"), address(manager), address(new RevertingAuthorityMock())];
        for (uint256 i; i < bad.length; ++i) {
            bytes memory register = _register(bad[i]);
            bytes32 id = _schedule(adminSafe, address(manager), register);
            vm.warp(manager.getSchedule(id));
            vm.expectRevert(
                abi.encodeWithSelector(WorksAccessManager.InvalidSuccessor.selector, bad[i])
            );
            vm.prank(adminSafe);
            manager.registerSuccessor(bad[i]);
        }
    }

    // ------------------------------------------------------------------ migrate

    function test_MigrateBeforeRegistrationReverts() public {
        vm.expectRevert(WorksAccessManager.NoSuccessor.selector);
        manager.migrate(0, type(uint256).max);
    }

    function test_OneTransactionMovesEveryManagedTarget() public {
        _onboard(_list(address(second), address(third)));
        _handOver();
        vm.prank(outsider);
        manager.migrate(0, type(uint256).max);
        assertEq(target.authority(), address(next));
        assertEq(second.authority(), address(next));
        assertEq(third.authority(), address(next));
        assertEq(manager.successor(), address(next));
    }

    function test_TheSuccessorAcceptsAndMigratesInOneMulticall() public {
        _onboard(_list(address(second), address(third)));
        _propose(address(next));
        address probe = manager.successionProbe();
        vm.startPrank(nextAdmin);
        next.execute(probe, abi.encodeCall(IAccessManaged.setAuthority, (address(manager))));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(WorksAccessManager.acceptSuccession, ());
        calls[1] = abi.encodeCall(WorksAccessManager.migrate, (0, type(uint256).max));
        next.execute(address(manager), abi.encodeCall(manager.multicall, (calls)));
        vm.stopPrank();
        assertEq(second.authority(), address(next));
        assertEq(target.authority(), address(next));
    }

    function test_PiecesAreIdempotentAndSkipTargetsThatLeftEarlier() public {
        _onboard(_list(address(second), address(third)));
        // `second` was moved on its own earlier (a 30-day updateAuthority).
        address elsewhere = address(new AccessManager(makeAddr("elsewhere")));
        _adminExecute(abi.encodeCall(IAccessManager.updateAuthority, (address(second), elsewhere)));
        _handOver();
        manager.migrate(0, 1);
        assertEq(target.authority(), address(next));
        assertEq(third.authority(), address(manager), "outside the piece");
        manager.migrate(0, 3); // idempotent for index 0, skips `second`
        assertEq(second.authority(), elsewhere);
        assertEq(third.authority(), address(next));
        manager.migrate(5, 9); // past the end: nothing
    }

    function test_ARefusingTargetBlocksOnlyThePiecesThatContainIt() public {
        RefusingTargetMock refusing = new RefusingTargetMock(address(manager));
        _onboard(_list(address(refusing), address(second)));
        _handOver();
        vm.expectRevert(RefusingTargetMock.Refused.selector);
        manager.migrate(0, 3);
        assertEq(target.authority(), address(manager), "all or nothing");
        manager.migrate(0, 1);
        manager.migrate(2, 3);
        assertEq(target.authority(), address(next));
        assertEq(second.authority(), address(next));
        assertEq(refusing.authority(), address(manager), "only the refusing target stays");
    }

    /// @dev The gas rule: `migrate` forwards all gas, so a target whose authority change costs
    ///      2x, 4x or 10x more still moves when the caller supplies the gas, and a caller short
    ///      of gas gets a revert, never a partial piece.
    function test_Stress_ATargetThatBurnsMoreGasStillMoves() public {
        uint256[3] memory factors = [uint256(2), 4, 10];
        address[] memory burners = new address[](3);
        for (uint256 i; i < 3; ++i) {
            burners[i] = address(new BurningTargetMock(address(manager), factors[i] * 3));
        }
        bytes32 id;
        for (uint256 i; i < 3; ++i) {
            id = _schedule(adminSafe, address(manager), _delayOf(burners[i]));
        }
        vm.warp(manager.getSchedule(id));
        vm.startPrank(adminSafe);
        for (uint256 i; i < 3; ++i) {
            manager.execute(address(manager), _delayOf(burners[i]));
        }
        vm.stopPrank();
        _handOver();
        // Too little gas for the 10x target: the whole piece reverts.
        (bool ok,) = address(manager).call{ gas: 200_000 }(abi.encodeCall(manager.migrate, (0, 4)));
        assertFalse(ok);
        assertEq(target.authority(), address(manager), "nothing moved");
        manager.migrate(0, 4);
        for (uint256 i; i < 3; ++i) {
            assertEq(IAccessManaged(burners[i]).authority(), address(next));
        }
    }
}
