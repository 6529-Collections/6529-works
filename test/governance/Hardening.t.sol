// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Errors } from "@openzeppelin/contracts/utils/Errors.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { BoundedParameter } from "src/governance/BoundedParameter.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import { GovernedTargetMock, PayableGovernedMock } from "../mocks/GovernanceMocks.sol";

/// @notice ADR 0001 §13 AccessManager hardening requirements 1, 3, 4, 5, 7 and 9, operation
///         expiry, and the rotated-admin procedure, on a configured `WorksAccessManager`.
contract HardeningTest is GovernanceFixture {
    function setUp() public {
        _deployGovernance();
    }

    function _proposerRoles() internal pure returns (uint64[6] memory) {
        return [
            Roles.ADMIN,
            Roles.META,
            Roles.UNPAUSER,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
    }

    // ------------------------------- §13.1 meta-governance never faster than slowest class

    function test_MetaGovernanceIsNeverFasterThanTheSlowestClass() public view {
        (bool isAdmin, uint32 adminDelay) = manager.hasRole(Roles.ADMIN, adminSafe);
        assertTrue(isAdmin);
        assertGe(adminDelay, Roles.SUCCESSOR, "admin execution delay");
        assertGe(manager.getTargetAdminDelay(address(manager)), Roles.SUCCESSOR);
        assertGe(manager.getTargetAdminDelay(address(target)), Roles.SUCCESSOR);
        for (uint64 role; role < Roles.COUNT; ++role) {
            assertGe(manager.getRoleGrantDelay(role), Roles.executionDelay(role), "grant >= class");
        }
    }

    function test_AdminCannotShortenGrantDelayWithoutWaiting() public {
        uint256 start = block.timestamp;
        _adminExecute(abi.encodeCall(IAccessManager.setGrantDelay, (Roles.FUNDS_SETTER, 0)));
        assertEq(block.timestamp, start + 30 days, "the setter itself waits 30 days");
        // The old 14-day delay keeps applying for 14 more days after execution.
        vm.warp(start + 30 days + 14 days - 1);
        assertEq(manager.getRoleGrantDelay(Roles.FUNDS_SETTER), Roles.FUNDS);
        vm.warp(start + 30 days + 14 days);
        assertEq(manager.getRoleGrantDelay(Roles.FUNDS_SETTER), 0);
    }

    function test_AdminCannotShortenTargetAdminDelayWithoutWaiting() public {
        uint256 start = block.timestamp;
        _adminExecute(abi.encodeCall(IAccessManager.setTargetAdminDelay, (address(target), 0)));
        vm.warp(start + 60 days - 1);
        assertEq(manager.getTargetAdminDelay(address(target)), 30 days);
        vm.warp(start + 60 days);
        assertEq(manager.getTargetAdminDelay(address(target)), 0);
    }

    function test_AdminCannotShortenItsOwnExecutionDelayWithoutWaiting() public {
        uint256 start = block.timestamp;
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, adminSafe, 0)));
        (, uint32 current, uint32 pending, uint48 effect) =
            manager.getAccess(Roles.ADMIN, adminSafe);
        assertEq(current, 30 days);
        assertEq(pending, 0);
        assertEq(effect, start + 60 days);
        vm.warp(start + 60 days);
        (, uint32 lowered) = manager.hasRole(Roles.ADMIN, adminSafe);
        assertEq(lowered, 0);
    }

    function test_FreshZeroDelayHolderWaitsScheduleAndGrantDelay() public {
        // OpenZeppelin lets an admin "reset" a delay by granting a fresh holder; that holder
        // still waits the 30-day admin delay plus the role's grant delay.
        uint256 start = block.timestamp;
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (Roles.FUNDS_SETTER, attacker, 0)));
        bytes memory data = abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, attacker));
        vm.warp(start + 30 days + 14 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker)
        );
        vm.prank(attacker);
        target.setRecipient(recipient0, attacker);
        vm.warp(start + 30 days + 14 days);
        vm.prank(attacker);
        manager.execute(address(target), data);
        assertEq(target.recipient(), attacker);
    }

    function test_RemappingAFundsSelectorToAFasterRoleTakesThirtyDays() public {
        bytes memory remap = abi.encodeCall(
            IAccessManager.setTargetFunctionRole,
            (
                address(target),
                _one(GovernedTargetMock.setRecipient.selector),
                Roles.PARAMETER_SETTER
            )
        );
        bytes32 id = _schedule(adminSafe, address(manager), remap);
        assertEq(manager.getSchedule(id), block.timestamp + 30 days);
        vm.warp(block.timestamp + 30 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        vm.prank(adminSafe);
        manager.execute(address(manager), remap);
    }

    function test_UnmappedSelectorFallsBackToAdminDelay() public {
        (bool immediate, uint32 delay) =
            manager.canCall(adminSafe, address(target), GovernedTargetMock.adminOnly.selector);
        assertFalse(immediate);
        assertEq(delay, 30 days);
        _scheduleAndExecute(
            adminSafe, address(target), abi.encodeCall(GovernedTargetMock.adminOnly, ())
        );
        assertEq(target.adminCalls(), 1);
    }

    // --------------------------------------------------------------- §13.3 guardian rules

    function test_GuardiansAreNeverProposers() public view {
        address[2] memory guardians = [guardianA, guardianB];
        uint64[6] memory proposers = _proposerRoles();
        for (uint256 g; g < 2; ++g) {
            (bool isGuardian, uint32 delay) = manager.hasRole(Roles.GUARDIAN, guardians[g]);
            assertTrue(isGuardian);
            assertEq(delay, 0);
            for (uint256 p; p < proposers.length; ++p) {
                (uint48 since,,,) = manager.getAccess(proposers[p], guardians[g]);
                assertEq(since, 0, "guardian holds a proposer role");
            }
            (bool immediate, uint32 setback) =
                manager.canCall(guardians[g], address(manager), IAccessManager.grantRole.selector);
            assertFalse(immediate);
            assertEq(setback, 0, "guardian could schedule a meta operation");
        }
    }

    function test_GuardianCannotSchedule() public {
        bytes memory data = abi.encodeCall(IAccessManager.grantRole, (Roles.KEEPER, guardianA, 0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                guardianA,
                address(manager),
                IAccessManager.grantRole.selector
            )
        );
        vm.prank(guardianA);
        manager.schedule(address(manager), data, 0);
    }

    function test_AtLeastTwoVetoGuardians() public view {
        (bool a,) = manager.hasRole(Roles.GUARDIAN, guardianA);
        (bool b,) = manager.hasRole(Roles.GUARDIAN, guardianB);
        assertTrue(a && b && guardianA != guardianB);
        for (uint64 role = 1; role < Roles.COUNT; ++role) {
            assertEq(manager.getRoleGuardian(role), Roles.GUARDIAN, "every role guarded");
        }
    }

    function test_PauseIsImmediateUnpauseIsSeparateDelayedAndVetoable() public {
        vm.expectEmit(address(target));
        emit GovernedTargetMock.PausedSet(true);
        vm.prank(guardianA);
        target.pause();

        // Pausers cannot unpause; unpausers cannot pause.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardianA)
        );
        vm.prank(guardianA);
        target.unpause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, adminSafe)
        );
        vm.prank(adminSafe);
        target.pause();

        // Unpause waits 48 hours, during which a guardian can cancel it.
        bytes memory data = abi.encodeCall(GovernedTargetMock.unpause, ());
        bytes32 id = _schedule(adminSafe, address(target), data);
        assertEq(manager.getSchedule(id), block.timestamp + 48 hours);
        vm.prank(guardianB);
        manager.cancel(adminSafe, address(target), data);

        _scheduleAndExecute(adminSafe, address(target), data);
        assertFalse(target.paused());
    }

    function test_GuardianVetoIsImmediate() public {
        vm.expectEmit(address(target));
        emit GovernedTargetMock.Vetoed(bytes32("dispute"));
        vm.prank(guardianB);
        target.veto("dispute");
        assertEq(target.vetoes(), 1);
    }

    // ------------------------------------------------------ §13.4 one selector, one class

    function test_EachGovernedSelectorHasExactlyOneClass() public view {
        GovernanceConfig.FunctionRole[] memory fns = _targetFunctions();
        for (uint256 i; i < fns.length; ++i) {
            uint64 role = manager.getTargetFunctionRole(address(target), fns[i].selector);
            assertEq(role, fns[i].role);
            if (!Roles.isProposer(role)) continue;
            (bool immediate, uint32 delay) =
                manager.canCall(adminSafe, address(target), fns[i].selector);
            assertFalse(immediate);
            assertEq(delay, Roles.executionDelay(role), "admin sees the class delay");
        }
    }

    function test_DirectionRulesLiveInTheTarget() public {
        // Raise-only: a scheduled decrease reverts in the target even after its delay.
        bytes memory lower = abi.encodeCall(GovernedTargetMock.raiseCallbackGas, (50_000));
        bytes32 id = _schedule(adminSafe, address(target), lower);
        vm.warp(manager.getSchedule(id));
        vm.expectRevert(
            abi.encodeWithSelector(BoundedParameter.ParameterNotRaised.selector, 100_000, 50_000)
        );
        vm.prank(adminSafe);
        manager.execute(address(target), lower);

        bytes memory raise = abi.encodeCall(GovernedTargetMock.raiseCallbackGas, (200_000));
        vm.warp(manager.getSchedule(_schedule(adminSafe, address(target), raise)));
        vm.expectEmit(address(target));
        emit GovernedTargetMock.CallbackGasUpdated(100_000, 200_000);
        vm.prank(adminSafe);
        manager.execute(address(target), raise);
        assertEq(target.callbackGas(), 200_000);
    }

    // -------------------------------------------------------- §13.5 compare-and-set

    function test_StaleCompareAndSetOperationReverts() public {
        address first = makeAddr("first");
        address second = makeAddr("second");
        bytes memory a = abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, first));
        bytes memory b = abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, second));
        _schedule(adminSafe, address(target), a);
        _schedule(adminSafe, address(target), b);
        vm.warp(block.timestamp + Roles.FUNDS);

        vm.expectEmit(address(target));
        emit GovernedTargetMock.RecipientUpdated(recipient0, first);
        vm.prank(adminSafe);
        manager.execute(address(target), a);

        vm.expectRevert(
            abi.encodeWithSelector(GovernedTargetMock.StaleValue.selector, recipient0, first)
        );
        vm.prank(adminSafe);
        manager.execute(address(target), b);
        assertEq(target.recipient(), first);
    }

    // ------------------------------------------------------- §13.7 non-payable

    function test_GovernedFunctionsRejectValueThroughExecute() public {
        bytes memory data = abi.encodeCall(GovernedTargetMock.setFee, (7));
        bytes32 id = _schedule(adminSafe, address(target), data);
        vm.warp(manager.getSchedule(id));
        vm.deal(adminSafe, 1 ether);
        vm.expectRevert(Errors.FailedCall.selector);
        vm.prank(adminSafe);
        manager.execute{ value: 1 ether }(address(target), data);

        vm.prank(adminSafe);
        manager.execute(address(target), data);
        assertEq(target.fee(), 7);
        assertEq(address(manager).balance, 0);
    }

    function test_EveryGovernedSelectorIsNonPayable() public {
        bytes[9] memory calls = [
            abi.encodeCall(GovernedTargetMock.pause, ()),
            abi.encodeCall(GovernedTargetMock.unpause, ()),
            abi.encodeCall(GovernedTargetMock.setFee, (1)),
            abi.encodeCall(GovernedTargetMock.raiseCallbackGas, (1)),
            abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, attacker)),
            abi.encodeCall(GovernedTargetMock.setVerifier, (verifier0, attacker)),
            abi.encodeCall(GovernedTargetMock.veto, (bytes32(0))),
            abi.encodeCall(GovernedTargetMock.keep, ()),
            abi.encodeCall(GovernedTargetMock.adminOnly, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            assertFalse(_acceptsValue(address(target), calls[i]), "governed function is payable");
        }
    }

    function test_NonPayableProbeFlagsAPayableGovernedFunction() public {
        PayableGovernedMock bad = new PayableGovernedMock(address(manager));
        assertTrue(_acceptsValue(address(bad), abi.encodeCall(PayableGovernedMock.deposit, (1))));
    }

    // ----------------------------------------------------------------------- expiry

    function test_ScheduledOperationExpiresAfterOneWeek() public {
        bytes memory data = abi.encodeCall(GovernedTargetMock.setFee, (9));
        bytes32 id = _schedule(adminSafe, address(target), data);
        uint48 ready = manager.getSchedule(id);
        vm.warp(ready + manager.expiration() - 1);
        assertEq(manager.getSchedule(id), ready, "still live");
        vm.warp(ready + manager.expiration());
        assertEq(manager.getSchedule(id), 0, "expired");
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerExpired.selector, id));
        vm.prank(adminSafe);
        manager.execute(address(target), data);

        // An expired operation can be scheduled again, with a new nonce and a full delay.
        vm.prank(adminSafe);
        (, uint32 nonce) = manager.schedule(address(target), data, 0);
        assertEq(nonce, 2);
    }

    function test_ExpiredMetaOperationCannotBeExecuted() public {
        bytes memory data = abi.encodeCall(IAccessManager.revokeRole, (Roles.GUARDIAN, guardianA));
        bytes32 id = _schedule(adminSafe, address(manager), data);
        vm.warp(manager.getSchedule(id) + manager.expiration());
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerExpired.selector, id));
        vm.prank(adminSafe);
        manager.execute(address(manager), data);
    }

    // ------------------------------------------------------- rotated-admin procedure

    /// @dev The procedure in src/governance/README.md: (1) the old admin schedules the new
    ///      admin's grants; (2) guardians or the old admin cancel every other pending operation
    ///      of the old admin; (3) grants execute and mature; (4) the old admin renounces, or the
    ///      new admin revokes it; (5) anything of the old admin's that slipped through is dead.
    function test_RotatedAdminPendingOperationsAreCancelled() public {
        address newAdmin = makeAddr("newAdmin");
        uint64[6] memory roles = _proposerRoles();

        // Pending operations of the old admin, one per kind.
        bytes memory pendingTarget =
            abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, attacker));
        bytes memory pendingMeta =
            abi.encodeCall(IAccessManager.grantRole, (Roles.KEEPER, attacker, 0));
        bytes memory slipped = abi.encodeCall(GovernedTargetMock.setFee, (666));
        _schedule(adminSafe, address(target), pendingTarget);
        _schedule(adminSafe, address(manager), pendingMeta);

        // (1) Grants for the new admin, each at its class delay.
        bytes[] memory grants = new bytes[](roles.length);
        for (uint256 i; i < roles.length; ++i) {
            grants[i] = abi.encodeCall(
                IAccessManager.grantRole, (roles[i], newAdmin, Roles.executionDelay(roles[i]))
            );
            _schedule(adminSafe, address(manager), grants[i]);
        }

        // (2) Guardians cancel the old admin's other pending operations.
        vm.prank(guardianA);
        manager.cancel(adminSafe, address(target), pendingTarget);
        vm.prank(guardianB);
        manager.cancel(adminSafe, address(manager), pendingMeta);

        // (3) Execute the grants after 30 days; they mature after their grant delays.
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(adminSafe);
        for (uint256 i; i < grants.length; ++i) {
            manager.execute(address(manager), grants[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days);
        for (uint256 i; i < roles.length; ++i) {
            (bool member, uint32 delay) = manager.hasRole(roles[i], newAdmin);
            assertTrue(member);
            assertEq(delay, Roles.executionDelay(roles[i]));
        }
        bytes32 slippedId = _schedule(adminSafe, address(target), slipped); // never cancelled
        vm.warp(manager.getSchedule(slippedId));

        // The new admin can also cancel anything the old admin still has pending.
        bytes memory another = abi.encodeCall(IAccessManager.setGrantDelay, (Roles.KEEPER, 0));
        _schedule(adminSafe, address(manager), another);
        vm.prank(newAdmin);
        manager.cancel(adminSafe, address(manager), another);

        // (4) The old admin renounces every role, immediately.
        vm.startPrank(adminSafe);
        for (uint256 i; i < roles.length; ++i) {
            manager.renounceRole(roles[i], adminSafe);
        }
        vm.stopPrank();

        // (5) Its uncancelled operation can no longer execute.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                adminSafe,
                address(target),
                GovernedTargetMock.setFee.selector
            )
        );
        vm.prank(adminSafe);
        manager.execute(address(target), slipped);
        assertEq(target.fee(), 0);
        assertEq(target.recipient(), recipient0);
        (bool keeperAttacker,) = manager.hasRole(Roles.KEEPER, attacker);
        assertFalse(keeperAttacker);
    }
}
