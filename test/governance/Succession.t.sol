// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernedTargetMock } from "../mocks/governance/GovernanceMocks.sol";
import {
    BurningTargetMock,
    RefusingTargetMock,
    RevertingAuthorityMock
} from "../mocks/governance/SuccessionMocks.sol";
import { PermanenceFixture } from "./PermanenceFixture.sol";

/// @notice The pre-registered successor and `migrate` (GV-43 to GV-45): `registerSuccessor`
///         (slow lane, bounded veto) ends the manager's power; `migrate` re-points every
///         managed target, the ones configured after genesis included, in caller-chosen
///         all-or-nothing pieces that anyone may run.
contract SuccessionTest is PermanenceFixture {
    AccessManager internal next;
    GovernedTargetMock internal second;
    GovernedTargetMock internal third;

    function setUp() public {
        _deployGovernance();
        next = new AccessManager(makeAddr("nextAdmin"));
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
        _scheduleAndExecute(adminSafe, address(manager), _register(address(next)));
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

    function test_RegistrationWaitsTheSlowDelayAndEndsTheManagersPower() public {
        bytes memory register = _register(address(next));
        bytes32 id = _schedule(adminSafe, address(manager), register);
        assertEq(manager.getSchedule(id), block.timestamp + SLOW);
        vm.warp(block.timestamp + SLOW - 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        vm.prank(adminSafe);
        manager.registerSuccessor(address(next));
        vm.warp(block.timestamp + 1);
        vm.expectEmit(address(manager));
        emit WorksAccessManager.SuccessorRegistered(address(next));
        vm.prank(adminSafe);
        manager.registerSuccessor(address(next));
        assertEq(manager.successor(), address(next));

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

    function test_RegisteringAndMigratingInOneMulticall() public {
        _onboard(_list(address(second), address(third)));
        bytes memory register = _register(address(next));
        bytes32 id = _schedule(adminSafe, address(manager), register);
        vm.warp(manager.getSchedule(id));
        bytes[] memory calls = new bytes[](2);
        calls[0] = register;
        calls[1] = abi.encodeCall(WorksAccessManager.migrate, (0, type(uint256).max));
        vm.prank(adminSafe);
        manager.multicall(calls);
        assertEq(second.authority(), address(next));
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
