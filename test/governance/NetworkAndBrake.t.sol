// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Errors } from "@openzeppelin/contracts/utils/Errors.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import { GovernedTargetMock, PayableGovernedMock } from "../mocks/governance/GovernanceMocks.sol";

/// @notice One authority (the network), one brake, three fixed delays (governance spec,
///         GV-1 to GV-9), on a configured `WorksAccessManager`.
contract NetworkAndBrakeTest is GovernanceFixture {
    function setUp() public {
        _deployGovernance();
    }

    function _id(address caller, address to, bytes memory data) internal view returns (bytes32) {
        return manager.hashOperation(caller, to, data);
    }

    function _networkRoles() internal pure returns (uint64[5] memory) {
        return [
            Roles.ADMIN,
            Roles.NETWORK,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
    }

    // ------------------------------------------------------------------ the classes

    /// @dev GV-2. Fails against the earlier manager, whose classes were 48 hours, 14 days and
    ///      30 days.
    function test_EachClassRunsAtItsDelayAndNotBefore() public {
        bytes[5] memory calls = [
            abi.encodeCall(GovernedTargetMock.setFee, (7)),
            abi.encodeCall(GovernedTargetMock.raiseCallbackGas, (200_000)),
            abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, outsider)),
            abi.encodeCall(GovernedTargetMock.setVerifier, (verifier0, outsider)),
            abi.encodeCall(GovernedTargetMock.adminOnly, ())
        ];
        uint32[5] memory delays = [uint32(24 hours), 24 hours, 3 days, 7 days, 7 days];
        for (uint256 i; i < calls.length; ++i) {
            (bool immediate, uint32 delay) =
                manager.canCall(adminSafe, address(target), bytes4(calls[i]));
            assertFalse(immediate);
            assertEq(delay, delays[i], "class delay");
            bytes32 id = _schedule(adminSafe, address(target), calls[i]);
            assertEq(manager.getSchedule(id), block.timestamp + delays[i]);
            vm.warp(block.timestamp + delays[i] - 1);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id)
            );
            vm.prank(adminSafe);
            manager.execute(address(target), calls[i]);
            vm.warp(block.timestamp + 1);
            vm.prank(adminSafe);
            manager.execute(address(target), calls[i]);
        }
        assertEq(target.fee(), 7);
        assertEq(target.callbackGas(), 200_000);
        assertEq(target.recipient(), outsider);
        assertEq(target.verifier(), outsider);
        assertEq(target.adminCalls(), 1);
    }

    /// @dev Integrator ruling 13: unpausing is the network's, with no delay.
    function test_TheNetworkUnpausesAtOnce() public {
        vm.prank(guardianA);
        target.pause();
        (bool immediate, uint32 delay) =
            manager.canCall(adminSafe, address(target), GovernedTargetMock.unpause.selector);
        assertTrue(immediate);
        assertEq(delay, 0);
        vm.prank(guardianA);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardianA)
        );
        target.unpause();
        vm.prank(adminSafe);
        target.unpause();
        assertFalse(target.paused());
    }

    /// @dev GV-2: the manager's own administration is the 7-day class.
    function test_ManagerAdministrationIsTheSevenDayClass() public {
        bytes[3] memory calls = [
            abi.encodeCall(WorksAccessManager.setBrake, (outsider)),
            abi.encodeCall(WorksAccessManager.transferNetwork, (outsider)),
            abi.encodeCall(IAccessManager.setTargetClosed, (address(target), true))
        ];
        for (uint256 i; i < calls.length; ++i) {
            bytes32 id = _schedule(adminSafe, address(manager), calls[i]);
            assertEq(manager.getSchedule(id), block.timestamp + 7 days);
        }
    }

    /// @dev GV-2: the network acts through `NETWORK` at once; nobody else can.
    function test_TheNetworkActsAtOnceThroughTheNetworkRole() public {
        vm.prank(adminSafe);
        target.veto(bytes32("x"));
        assertEq(target.vetoes(), 1);
        address[4] memory others = [guardianA, brakeSafe, platform, outsider];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, others[i])
            );
            vm.prank(others[i]);
            target.veto(bytes32("x"));
        }
    }

    /// @dev GV-3: operational keys act at once and are granted and revoked by the network at
    ///      once (integrator ruling 14); nobody else grants one.
    function test_OperationalKeysAreGrantedAndRevokedAtOnce() public {
        address key = makeAddr("newPauser");
        vm.prank(outsider);
        vm.expectRevert();
        manager.grantRole(Roles.PAUSER, key, 0);
        vm.prank(adminSafe);
        manager.grantRole(Roles.PAUSER, key, 0);
        vm.prank(key);
        target.pause();
        assertTrue(target.paused());

        vm.prank(adminSafe);
        manager.revokeRole(Roles.PAUSER, key);
        (bool still,) = manager.hasRole(Roles.PAUSER, key);
        assertFalse(still);
        // A key can drop its own role at once.
        vm.prank(guardianB);
        manager.renounceRole(Roles.PAUSER, guardianB);
        (still,) = manager.hasRole(Roles.PAUSER, guardianB);
        assertFalse(still);
    }

    /// @dev Every grant that makes an account a member counts once; a second grant to a member
    ///      does not, and a grant after a revocation does, even within the same second (the
    ///      curation verifier's signer epoch relies on it).
    function test_GrantCountMovesOnEveryNewMembership() public {
        address key = makeAddr("countedKey");
        assertEq(manager.grantCount(Roles.CURATOR, key), 0);
        vm.startPrank(adminSafe);
        manager.grantRole(Roles.CURATOR, key, 0);
        assertEq(manager.grantCount(Roles.CURATOR, key), 1);
        manager.grantRole(Roles.CURATOR, key, 0);
        assertEq(manager.grantCount(Roles.CURATOR, key), 1, "already a member");
        manager.revokeRole(Roles.CURATOR, key);
        manager.grantRole(Roles.CURATOR, key, 0);
        vm.stopPrank();
        assertEq(manager.grantCount(Roles.CURATOR, key), 2, "a new membership");
    }

    /// @dev An unmapped selector falls back to `ADMIN`, the 7-day class.
    function test_UnmappedSelectorFallsBackToTheSevenDayClass() public view {
        (bool immediate, uint32 delay) =
            manager.canCall(adminSafe, address(target), GovernedTargetMock.adminOnly.selector);
        assertFalse(immediate);
        assertEq(delay, 7 days);
        (bool member,) = manager.hasRole(Roles.ADMIN, outsider);
        assertFalse(member);
    }

    // ------------------------------------------------------------------ one network

    /// @dev GV-1. Fails against the earlier manager, where an admin could grant any role.
    function test_NobodyCanBeGrantedANetworkRole() public {
        uint64[5] memory roles = _networkRoles();
        for (uint256 i; i < roles.length; ++i) {
            bytes memory data = abi.encodeCall(
                IAccessManager.grantRole, (roles[i], outsider, Roles.executionDelay(roles[i]))
            );
            bytes32 id = _schedule(adminSafe, address(manager), data);
            vm.warp(manager.getSchedule(id));
            vm.expectRevert(
                abi.encodeWithSelector(
                    WorksAccessManager.NetworkRoleNotGrantable.selector, roles[i]
                )
            );
            vm.prank(adminSafe);
            manager.execute(address(manager), data);
            (bool member,) = manager.hasRole(roles[i], outsider);
            assertFalse(member);
        }
    }

    function testFuzz_OnlyTheNetworkHoldsTheNetworkRoles(address account, uint8 pick) public view {
        uint64 role = _networkRoles()[pick % 5];
        (bool member, uint32 delay) = manager.hasRole(role, account);
        assertEq(member, account == adminSafe);
        if (member) assertEq(delay, Roles.executionDelay(role));
    }

    /// @dev Before anyone accepts, nobody holds the network roles, the zero address included.
    function test_NoNetworkBeforeAcceptance() public {
        _deployUnconfigured();
        configurator.configure(_config(), MANIFEST, _noWiring());
        uint64[5] memory roles = _networkRoles();
        for (uint256 i; i < roles.length; ++i) {
            (bool zero,) = manager.hasRole(roles[i], address(0));
            (bool pending,) = manager.hasRole(roles[i], adminSafe);
            assertFalse(zero);
            assertFalse(pending);
        }
    }

    /// @dev GV-4. Fails against the earlier manager, which had no single network to hand over.
    function test_TransferNetworkTakesEffectOnlyOnAccept() public {
        address next = makeAddr("tdhExecutor");
        bytes memory stale = abi.encodeCall(GovernedTargetMock.setFee, (666));
        _schedule(adminSafe, address(target), stale); // pending under the old network

        bytes memory transfer = abi.encodeCall(WorksAccessManager.transferNetwork, (next));
        bytes32 id = _schedule(adminSafe, address(manager), transfer);
        vm.warp(manager.getSchedule(id));
        vm.expectEmit(address(manager));
        emit WorksAccessManager.NetworkTransferStarted(adminSafe, next);
        vm.prank(adminSafe);
        manager.execute(address(manager), transfer);
        assertEq(manager.pendingNetwork(), next);
        assertEq(manager.network(), adminSafe, "nothing changes before acceptance");
        (bool nextHolds,) = manager.hasRole(Roles.ADMIN, next);
        assertFalse(nextHolds);

        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.NotPendingNetwork.selector, outsider)
        );
        vm.prank(outsider);
        manager.acceptNetwork();

        vm.expectEmit(address(manager));
        emit WorksAccessManager.NetworkTransferred(adminSafe, next);
        vm.prank(next);
        manager.acceptNetwork();
        assertEq(manager.network(), next);
        assertEq(manager.pendingNetwork(), address(0));

        uint64[5] memory roles = _networkRoles();
        for (uint256 i; i < roles.length; ++i) {
            (bool old,) = manager.hasRole(roles[i], adminSafe);
            (bool now_, uint32 delay) = manager.hasRole(roles[i], next);
            assertFalse(old, "the old network holds nothing");
            assertTrue(now_);
            assertEq(delay, Roles.executionDelay(roles[i]));
        }
        // The old network's scheduled operation can no longer run, and it cannot act at once.
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                adminSafe,
                address(target),
                GovernedTargetMock.setFee.selector
            )
        );
        vm.prank(adminSafe);
        manager.execute(address(target), stale);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, adminSafe)
        );
        vm.prank(adminSafe);
        target.veto(bytes32("x"));
        // The new network may cancel it.
        vm.prank(next);
        manager.cancel(adminSafe, address(target), stale);
        // A second accept does nothing.
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotPendingNetwork.selector, next));
        vm.prank(next);
        manager.acceptNetwork();
    }

    function test_TransferCanBeWithdrawnOrReplaced() public {
        address first = makeAddr("first");
        address second = makeAddr("second");
        _adminExecute(abi.encodeCall(WorksAccessManager.transferNetwork, (first)));
        _adminExecute(abi.encodeCall(WorksAccessManager.transferNetwork, (second)));
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.NotPendingNetwork.selector, first)
        );
        vm.prank(first);
        manager.acceptNetwork();
        _adminExecute(abi.encodeCall(WorksAccessManager.transferNetwork, (address(0))));
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.NotPendingNetwork.selector, second)
        );
        vm.prank(second);
        manager.acceptNetwork();
        assertEq(manager.network(), adminSafe);
    }

    function test_OnlyTheNetworkCanStartATransfer() public {
        address[3] memory others = [brakeSafe, guardianA, outsider];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManager.AccessManagerUnauthorizedAccount.selector, others[i], Roles.ADMIN
                )
            );
            vm.prank(others[i]);
            manager.transferNetwork(others[i]);
        }
        // Not even the network at once: it must schedule and wait 7 days.
        bytes memory data = abi.encodeCall(WorksAccessManager.transferNetwork, (outsider));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerNotScheduled.selector,
                _id(adminSafe, address(manager), data)
            )
        );
        vm.prank(adminSafe);
        manager.transferNetwork(outsider);
    }

    // ------------------------------------------------------------------ the brake

    /// @dev GV-6. Fails against the earlier manager, which had no brake.
    function test_TheBrakeDelaysAnOperationOnce() public {
        bytes memory data = abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, outsider));
        bytes32 id = _schedule(adminSafe, address(target), data);
        uint48 ready = manager.getSchedule(id);

        vm.expectEmit(address(manager));
        emit WorksAccessManager.OperationBraked(id, ready + 7 days);
        vm.prank(brakeSafe);
        manager.brakeOnce(id);
        assertEq(manager.notBefore(id), ready + 7 days);

        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.AlreadyBraked.selector, id));
        vm.prank(brakeSafe);
        manager.brakeOnce(id);

        vm.warp(ready);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.BrakeNotElapsed.selector, id, ready + 7 days)
        );
        vm.prank(adminSafe);
        manager.execute(address(target), data);
        vm.warp(ready + 7 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.BrakeNotElapsed.selector, id, ready + 7 days)
        );
        vm.prank(adminSafe);
        manager.execute(address(target), data);

        vm.warp(ready + 7 days);
        vm.prank(adminSafe);
        manager.execute(address(target), data);
        assertEq(target.recipient(), outsider);
        assertEq(manager.notBefore(id), 0, "the mark clears when the operation runs");
    }

    /// @dev A direct call on the target that consumes the schedule is held the same way.
    function test_TheBrakeAlsoHoldsADirectDelayedCall() public {
        bytes memory data = abi.encodeCall(GovernedTargetMock.setFee, (5));
        bytes32 id = _schedule(adminSafe, address(target), data);
        vm.prank(brakeSafe);
        manager.brakeOnce(id);
        vm.warp(manager.getSchedule(id));
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.BrakeNotElapsed.selector, id, manager.notBefore(id)
            )
        );
        vm.prank(adminSafe);
        target.setFee(5);
        vm.warp(manager.notBefore(id));
        vm.prank(adminSafe);
        target.setFee(5);
        assertEq(target.fee(), 5);
    }

    /// @dev GV-6: cancelling and scheduling again does not clear the mark, and the brake
    ///      cannot delay the operation a second time.
    function test_CancelAndRescheduleDoesNotEscapeTheBrake() public {
        bytes memory data = abi.encodeCall(GovernedTargetMock.setFee, (9));
        bytes32 id = _schedule(adminSafe, address(target), data);
        uint48 until = manager.getSchedule(id) + 7 days;
        vm.prank(brakeSafe);
        manager.brakeOnce(id);

        vm.prank(adminSafe);
        manager.cancel(adminSafe, address(target), data);
        _schedule(adminSafe, address(target), data);
        assertEq(manager.notBefore(id), until, "the mark survives");
        vm.warp(manager.getSchedule(id));
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.BrakeNotElapsed.selector, id, until)
        );
        vm.prank(adminSafe);
        manager.execute(address(target), data);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.AlreadyBraked.selector, id));
        vm.prank(brakeSafe);
        manager.brakeOnce(id);

        vm.warp(until);
        vm.prank(adminSafe);
        manager.execute(address(target), data);
        assertEq(target.fee(), 9);
        // Once it ran, the same call scheduled later is a new action the brake may delay.
        _schedule(adminSafe, address(target), data);
        vm.prank(brakeSafe);
        manager.brakeOnce(id);
    }

    function test_OnlyTheBrakeCanBrake() public {
        bytes32 id =
            _schedule(adminSafe, address(target), abi.encodeCall(GovernedTargetMock.setFee, (1)));
        address[4] memory others = [adminSafe, guardianA, platform, outsider];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotBrake.selector, others[i]));
            vm.prank(others[i]);
            manager.brakeOnce(id);
        }
        // With no brake set, nobody can brake.
        _adminExecute(abi.encodeCall(WorksAccessManager.setBrake, (address(0))));
        assertEq(manager.brake(), address(0));
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotBrake.selector, brakeSafe));
        vm.prank(brakeSafe);
        manager.brakeOnce(id);
    }

    /// @dev An action with no delay is never scheduled, so it cannot be braked.
    function test_AnActionWithNoDelayCannotBeBraked() public {
        bytes memory veto = abi.encodeCall(GovernedTargetMock.veto, (bytes32("x")));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                adminSafe,
                address(target),
                GovernedTargetMock.veto.selector
            )
        );
        vm.prank(adminSafe);
        manager.schedule(address(target), veto, 0);
        bytes32 id = _id(adminSafe, address(target), veto);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotBrakeable.selector, id));
        vm.prank(brakeSafe);
        manager.brakeOnce(id);
        vm.prank(adminSafe);
        target.veto(bytes32("x")); // still runs at once
    }

    function test_ACancelledExecutedOrExpiredOperationCannotBeBraked() public {
        bytes memory data = abi.encodeCall(GovernedTargetMock.setFee, (3));
        bytes32 id = _schedule(adminSafe, address(target), data);
        vm.prank(adminSafe);
        manager.cancel(adminSafe, address(target), data);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotBrakeable.selector, id));
        vm.prank(brakeSafe);
        manager.brakeOnce(id);

        _scheduleAndExecute(adminSafe, address(target), data);
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotBrakeable.selector, id));
        vm.prank(brakeSafe);
        manager.brakeOnce(id);

        _schedule(adminSafe, address(target), data);
        vm.warp(manager.getSchedule(id) + manager.expiration());
        vm.expectRevert(abi.encodeWithSelector(WorksAccessManager.NotBrakeable.selector, id));
        vm.prank(brakeSafe);
        manager.brakeOnce(id);
    }

    /// @dev GV-7: a braked operation keeps a week in which it can run. Fails against a stock
    ///      one-week expiry, which would expire it the moment the brake lets it run.
    function test_ABrakedOperationDoesNotExpireBeforeItCanRun() public {
        assertEq(manager.expiration(), 14 days);
        bytes memory data = abi.encodeCall(GovernedTargetMock.setFee, (4));
        bytes32 id = _schedule(adminSafe, address(target), data);
        uint48 ready = manager.getSchedule(id);
        vm.prank(brakeSafe);
        manager.brakeOnce(id);
        vm.warp(ready + 14 days - 1);
        vm.prank(adminSafe);
        manager.execute(address(target), data);
        assertEq(target.fee(), 4);

        id = _schedule(adminSafe, address(target), data);
        ready = manager.getSchedule(id);
        vm.warp(ready + 14 days);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerExpired.selector, id));
        vm.prank(adminSafe);
        manager.execute(address(target), data);
    }

    /// @dev GV-7 at the edges of the window. The mark is always the ready time plus 7 days and
    ///      expiry the ready time plus 14, so a braked operation keeps exactly a week to run
    ///      whenever the brake acts: just before ready, or just before expiry (when the mark has
    ///      already passed, so that brake delays nothing). It never outlives its expiry.
    function test_ABrakeNearTheEndOfTheWindowKeepsTheWeekAndTheExpiry() public {
        bytes memory data = abi.encodeCall(GovernedTargetMock.setFee, (6));
        bytes32 id = _schedule(adminSafe, address(target), data);
        uint48 ready = manager.getSchedule(id);
        vm.warp(ready - 1);
        vm.prank(brakeSafe);
        manager.brakeOnce(id);
        assertEq(manager.notBefore(id), ready + 7 days);
        vm.warp(ready + 14 days - 1);
        vm.prank(adminSafe);
        manager.execute(address(target), data);
        assertEq(target.fee(), 6);

        data = abi.encodeCall(GovernedTargetMock.setFee, (8));
        id = _schedule(adminSafe, address(target), data);
        ready = manager.getSchedule(id);
        vm.warp(ready + 14 days - 1);
        vm.prank(brakeSafe);
        manager.brakeOnce(id);
        assertEq(manager.notBefore(id), ready + 7 days, "the mark is already past");
        vm.prank(adminSafe);
        manager.execute(address(target), data);
        assertEq(target.fee(), 8);

        id = _schedule(adminSafe, address(target), data);
        ready = manager.getSchedule(id);
        vm.prank(brakeSafe);
        manager.brakeOnce(id);
        vm.warp(ready + 14 days);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerExpired.selector, id));
        vm.prank(adminSafe);
        manager.execute(address(target), data);
    }

    /// @dev The brake can delay the network's own administration too, its own removal
    ///      included, once.
    function test_TheBrakeCanDelayItsOwnRemovalOnce() public {
        bytes memory data = abi.encodeCall(WorksAccessManager.setBrake, (address(0)));
        bytes32 id = _schedule(adminSafe, address(manager), data);
        vm.prank(brakeSafe);
        manager.brakeOnce(id);
        vm.warp(manager.notBefore(id));
        vm.expectEmit(address(manager));
        emit WorksAccessManager.BrakeSet(brakeSafe, address(0));
        vm.prank(adminSafe);
        manager.execute(address(manager), data);
        assertEq(manager.brake(), address(0));
    }

    /// @dev The brake cannot cancel; the scheduler and the network can.
    function test_CancellationIsTheSchedulerOrTheNetwork() public {
        bytes memory data = abi.encodeCall(GovernedTargetMock.setFee, (2));
        _schedule(adminSafe, address(target), data);
        address[3] memory others = [brakeSafe, guardianA, outsider];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManager.AccessManagerUnauthorizedCancel.selector,
                    others[i],
                    adminSafe,
                    address(target),
                    GovernedTargetMock.setFee.selector
                )
            );
            vm.prank(others[i]);
            manager.cancel(adminSafe, address(target), data);
        }
        vm.prank(adminSafe);
        manager.cancel(adminSafe, address(target), data);
    }

    // ------------------------------------------------------------------ the manager itself

    function test_TheManagerCannotBeRemappedOrClosed() public {
        bytes[2] memory calls = [
            abi.encodeCall(
                IAccessManager.setTargetFunctionRole,
                (address(manager), _one(WorksAccessManager.transferNetwork.selector), Roles.PAUSER)
            ),
            abi.encodeCall(IAccessManager.setTargetClosed, (address(manager), true))
        ];
        for (uint256 i; i < calls.length; ++i) {
            bytes32 id = _schedule(adminSafe, address(manager), calls[i]);
            vm.warp(manager.getSchedule(id));
            vm.expectRevert(WorksAccessManager.ManagerSelfConfiguration.selector);
            vm.prank(adminSafe);
            manager.execute(address(manager), calls[i]);
        }
    }

    /// @dev Replacing the manager needs no special code: the stock `updateAuthority`, per
    ///      managed contract, at the 7-day class.
    function test_AContractMovesToAnotherManagerAtSevenDays() public {
        address next = address(new AccessManager(outsider));
        bytes memory data = abi.encodeCall(IAccessManager.updateAuthority, (address(target), next));
        bytes32 id = _schedule(adminSafe, address(manager), data);
        assertEq(manager.getSchedule(id), block.timestamp + 7 days);
        vm.warp(manager.getSchedule(id));
        vm.prank(adminSafe);
        manager.execute(address(manager), data);
        assertEq(target.authority(), next);
    }

    /// @dev A target added after genesis: the network maps its selectors at 7 days, then
    ///      readback passes with the new config.
    function test_OnboardATargetAfterGenesis() public {
        GovernedTargetMock late = new GovernedTargetMock(address(manager), recipient0, verifier0);
        GovernanceConfig.FunctionRole[] memory fns = _targetFunctions();
        bytes[] memory ops = new bytes[](fns.length);
        for (uint256 i; i < fns.length; ++i) {
            ops[i] = abi.encodeCall(
                IAccessManager.setTargetFunctionRole,
                (address(late), _one(fns[i].selector), fns[i].role)
            );
            _schedule(adminSafe, address(manager), ops[i]);
        }
        vm.warp(block.timestamp + 7 days);
        vm.prank(adminSafe);
        manager.multicall(ops); // each call consumes its own schedule

        GovernanceConfig.Config memory cfg = _config();
        GovernanceConfig.Target[] memory targets = new GovernanceConfig.Target[](2);
        targets[0] = cfg.targets[0];
        targets[1] = GovernanceConfig.Target(address(late), fns);
        cfg.targets = targets;
        configurator.verify(cfg);
    }

    // ------------------------------------------------------------------ value and staleness

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
        bytes[10] memory calls = [
            abi.encodeCall(GovernedTargetMock.pause, ()),
            abi.encodeCall(GovernedTargetMock.unpause, ()),
            abi.encodeCall(GovernedTargetMock.setFee, (1)),
            abi.encodeCall(GovernedTargetMock.raiseCallbackGas, (1)),
            abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, attacker)),
            abi.encodeCall(GovernedTargetMock.setVerifier, (verifier0, attacker)),
            abi.encodeCall(GovernedTargetMock.veto, (bytes32(0))),
            abi.encodeCall(GovernedTargetMock.keep, ()),
            abi.encodeCall(GovernedTargetMock.curate, ()),
            abi.encodeCall(GovernedTargetMock.adminOnly, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            assertFalse(_acceptsValue(address(target), calls[i]), "governed function is payable");
        }
        PayableGovernedMock bad = new PayableGovernedMock(address(manager));
        assertTrue(_acceptsValue(address(bad), abi.encodeCall(PayableGovernedMock.deposit, (1))));
    }

    function test_StaleCompareAndSetOperationReverts() public {
        address first = makeAddr("first");
        address second = makeAddr("second");
        bytes memory a = abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, first));
        bytes memory b = abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, second));
        _schedule(adminSafe, address(target), a);
        _schedule(adminSafe, address(target), b);
        vm.warp(block.timestamp + Roles.DELAY_3D);
        vm.prank(adminSafe);
        manager.execute(address(target), a);
        vm.expectRevert(
            abi.encodeWithSelector(GovernedTargetMock.StaleValue.selector, recipient0, first)
        );
        vm.prank(adminSafe);
        manager.execute(address(target), b);
        assertEq(target.recipient(), first);
    }
}
