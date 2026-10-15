// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Multicall } from "@openzeppelin/contracts/utils/Multicall.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import {
    GovernedTargetMock,
    SelectorCollisionMock,
    StockInstallHarness
} from "../mocks/GovernanceMocks.sol";

/// @notice ADR 0001 §13.2: the guardian Safes can cancel the admin's operations on the
///         AccessManager itself, and nobody can cancel their own replacement.
contract GuardianCancelTest is GovernanceFixture {
    uint32 internal constant META_DELAY = 30 days;

    function setUp() public {
        _deployGovernance();
    }

    // ------------------------------------------------------------------ helpers

    function _revoke(uint64 role, address account) internal pure returns (bytes memory) {
        return abi.encodeCall(IAccessManager.revokeRole, (role, account));
    }

    function _cancelAs(address canceller, address caller, address to, bytes memory data) internal {
        vm.prank(canceller);
        manager.cancel(caller, to, data);
    }

    function _expectUnauthorizedCancel(address canceller, address caller, bytes memory data)
        internal
    {
        _expectUnauthorizedCancelOn(canceller, caller, address(manager), data);
    }

    function _expectUnauthorizedCancelOn(
        address canceller,
        address caller,
        address to,
        bytes memory data
    ) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCancel.selector,
                canceller,
                caller,
                to,
                bytes4(data)
            )
        );
        vm.prank(canceller);
        manager.cancel(caller, to, data);
    }

    /// @dev One sample call for each of the manager's ten admin selectors, all hostile.
    function _hostileAdminCalls() internal returns (bytes[] memory calls) {
        AccessManager rogueAuthority = new AccessManager(attacker);
        calls = new bytes[](10);
        calls[0] = abi.encodeCall(IAccessManager.labelRole, (Roles.KEEPER, "pwned"));
        calls[1] = abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, attacker, 0));
        calls[2] = _revoke(Roles.GUARDIAN, guardianA);
        calls[3] = abi.encodeCall(IAccessManager.setRoleAdmin, (Roles.GUARDIAN, Roles.KEEPER));
        calls[4] = abi.encodeCall(IAccessManager.setRoleGuardian, (Roles.PAUSER, Roles.ADMIN));
        calls[5] = abi.encodeCall(IAccessManager.setGrantDelay, (Roles.FUNDS_SETTER, 0));
        calls[6] = abi.encodeCall(
            IAccessManager.setTargetFunctionRole,
            (
                address(target),
                _one(GovernedTargetMock.setRecipient.selector),
                Roles.PARAMETER_SETTER
            )
        );
        calls[7] = abi.encodeCall(IAccessManager.setTargetAdminDelay, (address(target), 0));
        calls[8] = abi.encodeCall(IAccessManager.setTargetClosed, (address(target), true));
        calls[9] = abi.encodeCall(
            IAccessManager.updateAuthority, (address(target), address(rogueAuthority))
        );
    }

    // ---------------------------------------------- the required scenario, step by step

    function test_GuardianCancelsCompromisedAdminRevokingGuardian() public {
        bytes memory data = _revoke(Roles.GUARDIAN, guardianA);
        bytes32 id = _schedule(adminSafe, address(manager), data);
        assertEq(manager.getSchedule(id), block.timestamp + META_DELAY, "30-day meta delay");

        vm.expectEmit(address(manager));
        emit IAccessManager.OperationCanceled(id, 1);
        _cancelAs(guardianB, adminSafe, address(manager), data);
        assertEq(manager.getSchedule(id), 0, "cancelled");

        vm.warp(block.timestamp + META_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id)
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), data);

        // Calling the function directly consumes a schedule too, and there is none.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id)
        );
        vm.prank(adminSafe);
        manager.revokeRole(Roles.GUARDIAN, guardianA);

        (bool isGuardian,) = manager.hasRole(Roles.GUARDIAN, guardianA);
        assertTrue(isGuardian, "guardian survives");
    }

    function test_AdminCannotExecuteBeforeTheDelay() public {
        bytes memory data = _revoke(Roles.GUARDIAN, guardianA);

        // No schedule at all: neither execute nor a direct call works.
        bytes32 id = manager.hashOperation(adminSafe, address(manager), data);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id)
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), data);

        // A schedule earlier than the 30-day delay is refused.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                adminSafe,
                address(manager),
                IAccessManager.revokeRole.selector
            )
        );
        vm.prank(adminSafe);
        manager.schedule(address(manager), data, uint48(block.timestamp + META_DELAY - 1));

        _schedule(adminSafe, address(manager), data);
        vm.warp(block.timestamp + META_DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        vm.prank(adminSafe);
        manager.execute(address(manager), data);

        // Unopposed, the operation executes once the full delay has passed.
        vm.warp(block.timestamp + 1);
        vm.expectEmit(address(manager));
        emit IAccessManager.RoleRevoked(Roles.GUARDIAN, guardianA);
        vm.prank(adminSafe);
        manager.execute(address(manager), data);
        (bool isGuardian,) = manager.hasRole(Roles.GUARDIAN, guardianA);
        assertFalse(isGuardian);
    }

    function test_GuardianCancelsEveryManagerAdminSelector() public {
        bytes[] memory calls = _hostileAdminCalls();
        for (uint256 i; i < calls.length; ++i) {
            // Unmapped: stock OpenZeppelin would leave only admins able to cancel these.
            assertEq(manager.getTargetFunctionRole(address(manager), bytes4(calls[i])), 0);
            bytes32 id = _schedule(adminSafe, address(manager), calls[i]);
            assertEq(manager.getSchedule(id), block.timestamp + META_DELAY, "30 days");
            _cancelAs(guardianB, adminSafe, address(manager), calls[i]);
            assertEq(manager.getSchedule(id), 0);
        }
        vm.warp(block.timestamp + META_DELAY);
        configurator.verify(_config()); // nothing changed
    }

    function test_EveryGuardianCancelsManagerOperations() public {
        bytes[] memory calls = _hostileAdminCalls();
        address[3] memory guardians = [guardianA, guardianB, guardianC];
        for (uint256 g; g < guardians.length; ++g) {
            for (uint256 i; i < calls.length; ++i) {
                if (i == 2 && guardians[g] == guardianA) continue; // its own revocation
                _schedule(coldAdmin, address(manager), calls[i]);
                _cancelAs(guardians[g], coldAdmin, address(manager), calls[i]);
            }
        }
    }

    function test_GuardianCancelsTargetClassOperations() public {
        bytes memory recipientCall =
            abi.encodeCall(GovernedTargetMock.setRecipient, (recipient0, attacker));
        bytes memory verifierCall =
            abi.encodeCall(GovernedTargetMock.setVerifier, (verifier0, attacker));
        bytes32 r = _schedule(adminSafe, address(target), recipientCall);
        bytes32 v = _schedule(adminSafe, address(target), verifierCall);
        assertEq(manager.getSchedule(r), block.timestamp + Roles.FUNDS);
        assertEq(manager.getSchedule(v), block.timestamp + Roles.SUCCESSOR);
        _cancelAs(guardianA, adminSafe, address(target), recipientCall);
        _cancelAs(guardianC, adminSafe, address(target), verifierCall);
        vm.warp(block.timestamp + Roles.SUCCESSOR);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, r)
        );
        vm.prank(adminSafe);
        manager.execute(address(target), recipientCall);
        assertEq(target.recipient(), recipient0);
    }

    function test_GuardianCancelsDirectSetAuthorityOnTarget() public {
        // OpenZeppelin lets an admin schedule `setAuthority` on a target directly, and locks
        // that selector's role mapping, so only WorksAccessManager's guardian rule stops it.
        AccessManager rogue = new AccessManager(attacker);
        bytes memory data = abi.encodeCall(IAccessManaged.setAuthority, (address(rogue)));
        bytes32 id = _schedule(adminSafe, address(target), data);
        assertEq(manager.getSchedule(id), block.timestamp + META_DELAY);
        _cancelAs(guardianA, adminSafe, address(target), data);
        vm.warp(block.timestamp + META_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id)
        );
        vm.prank(adminSafe);
        manager.execute(address(target), data);
        assertEq(target.authority(), address(manager));
    }

    function test_GuardianCancelsUnmappedTargetSelector() public {
        bytes memory data = abi.encodeCall(GovernedTargetMock.adminOnly, ());
        assertEq(
            manager.getTargetFunctionRole(address(target), GovernedTargetMock.adminOnly.selector),
            Roles.ADMIN
        );
        bytes32 id = _schedule(adminSafe, address(target), data);
        _cancelAs(guardianB, adminSafe, address(target), data);
        assertEq(manager.getSchedule(id), 0);
    }

    function test_OutsiderCannotCancel() public {
        bytes memory data = _revoke(Roles.GUARDIAN, guardianA);
        _schedule(adminSafe, address(manager), data);
        _expectUnauthorizedCancel(outsider, adminSafe, data);
        _expectUnauthorizedCancel(keeper, adminSafe, data);
    }

    function test_PauserOnlyAccountCannotCancel() public {
        // Cancelling is the GUARDIAN role's power, not PAUSER's.
        address pauserOnly = makeAddr("pauserOnly");
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (Roles.PAUSER, pauserOnly, 0)));
        vm.warp(block.timestamp + Roles.grantDelay(Roles.PAUSER));
        (bool isPauser,) = manager.hasRole(Roles.PAUSER, pauserOnly);
        assertTrue(isPauser);
        bytes memory data = abi.encodeCall(GovernedTargetMock.setFee, (1));
        _schedule(adminSafe, address(target), data);
        _expectUnauthorizedCancelOn(pauserOnly, adminSafe, address(target), data);
    }

    // ------------------------------------------------------------ anti-entrenchment

    function test_GuardianCannotCancelItsOwnReplacement() public {
        bytes memory revokeGuardian = _revoke(Roles.GUARDIAN, guardianA);
        bytes memory revokePauser = _revoke(Roles.PAUSER, guardianA);
        _schedule(adminSafe, address(manager), revokeGuardian);
        _schedule(adminSafe, address(manager), revokePauser);

        _expectUnauthorizedCancel(guardianA, adminSafe, revokeGuardian);
        _expectUnauthorizedCancel(guardianA, adminSafe, revokePauser);

        // The other guardians choose not to veto, so the replacement goes through.
        vm.warp(block.timestamp + META_DELAY);
        vm.startPrank(adminSafe);
        manager.execute(address(manager), revokeGuardian);
        manager.execute(address(manager), revokePauser);
        vm.stopPrank();
        (bool isGuardian,) = manager.hasRole(Roles.GUARDIAN, guardianA);
        (bool isPauser,) = manager.hasRole(Roles.PAUSER, guardianA);
        assertFalse(isGuardian);
        assertFalse(isPauser);
    }

    function test_GuardiansProtectEachOther() public {
        address[3] memory guardians = [guardianA, guardianB, guardianC];
        for (uint256 g; g < guardians.length; ++g) {
            bytes memory data = _revoke(Roles.GUARDIAN, guardians[g]);
            _schedule(adminSafe, address(manager), data);
            _cancelAs(guardians[(g + 1) % 3], adminSafe, address(manager), data);
        }
        vm.warp(block.timestamp + META_DELAY);
        configurator.verify(_config());
    }

    function test_GuardianCanCancelGrantOfAReplacement() public {
        // Blocking a newcomer is not entrenchment: it cannot stop its own revocation.
        bytes memory grant = abi.encodeCall(IAccessManager.grantRole, (Roles.GUARDIAN, outsider, 0));
        _schedule(adminSafe, address(manager), grant);
        _cancelAs(guardianA, adminSafe, address(manager), grant);
    }

    function test_SchedulerCanWithdrawARevocation() public {
        bytes memory data = _revoke(Roles.GUARDIAN, guardianA);
        bytes32 id = _schedule(adminSafe, address(manager), data);
        _cancelAs(adminSafe, adminSafe, address(manager), data);
        assertEq(manager.getSchedule(id), 0);
    }

    function test_SchedulerCanWithdrawItsOwnSelfRevocation() public {
        // Rule 2 exempts the scheduler: an admin may withdraw its own proposal to leave.
        bytes memory data = _revoke(Roles.ADMIN, adminSafe);
        bytes32 id = _schedule(adminSafe, address(manager), data);
        _cancelAs(adminSafe, adminSafe, address(manager), data);
        assertEq(manager.getSchedule(id), 0);
    }

    function test_RevocationWithTrailingCalldataIsStillProtected() public {
        bytes memory data = abi.encodePacked(_revoke(Roles.GUARDIAN, guardianA), bytes32(0));
        _schedule(adminSafe, address(manager), data);
        _expectUnauthorizedCancel(guardianA, adminSafe, data);
        _cancelAs(guardianB, adminSafe, address(manager), data);
    }

    function test_MalformedRevocationCanAlwaysBeCancelled() public {
        // A dirty address word cannot execute, and cancelling it never reverts.
        bytes memory data = abi.encodePacked(
            IAccessManager.revokeRole.selector,
            uint256(Roles.GUARDIAN),
            uint256(uint160(guardianA)) | (uint256(1) << 200)
        );
        bytes32 id = _schedule(adminSafe, address(manager), data);
        vm.warp(manager.getSchedule(id));
        vm.prank(adminSafe);
        (bool ok,) =
            address(manager).call(abi.encodeCall(IAccessManager.execute, (address(manager), data)));
        assertFalse(ok, "malformed revocation executed");
        _cancelAs(guardianA, adminSafe, address(manager), data);
        assertEq(manager.getSchedule(id), 0);
    }

    function test_TruncatedRevocationCanBeCancelledByAnyGuardian() public {
        // The role word is there, so the call schedules; the account word is not, so it
        // names nobody and no guardian is barred from cancelling it.
        bytes memory data =
            abi.encodePacked(IAccessManager.revokeRole.selector, uint256(Roles.GUARDIAN));
        bytes32 id = _schedule(adminSafe, address(manager), data);
        assertGt(manager.getSchedule(id), 0, "scheduled");
        _expectUnauthorizedCancel(attacker, adminSafe, data);
        _cancelAs(guardianA, adminSafe, address(manager), data);
        assertEq(manager.getSchedule(id), 0);
    }

    function test_Rule2OnlyProtectsRolesOnTheManager() public {
        // A target function with revokeRole's selector is not a role revocation: the account
        // named in it, a guardian, may cancel it like any other scheduled call.
        SelectorCollisionMock other = new SelectorCollisionMock(address(manager));
        bytes memory data =
            abi.encodeCall(SelectorCollisionMock.revokeRole, (Roles.GUARDIAN, guardianA));
        assertEq(bytes4(data), IAccessManager.revokeRole.selector);
        bytes32 id = _schedule(adminSafe, address(other), data);
        _cancelAs(guardianA, adminSafe, address(other), data);
        assertEq(manager.getSchedule(id), 0);
    }

    function test_DirtyRoleIdRevocationCannotBeScheduled() public {
        bytes memory data = abi.encodePacked(
            IAccessManager.revokeRole.selector,
            uint256(Roles.GUARDIAN) | (uint256(1) << 100),
            uint256(uint160(guardianA))
        );
        vm.expectRevert();
        vm.prank(adminSafe);
        manager.schedule(address(manager), data, 0);
    }

    function test_CompromisedAdminCannotCancelItsOwnRevocation() public {
        // The cold recovery admin removes a compromised hot admin.
        bytes memory data = _revoke(Roles.ADMIN, adminSafe);
        _schedule(coldAdmin, address(manager), data);

        // Stock OpenZeppelin lets any admin cancel any operation; not its own removal here.
        _expectUnauthorizedCancel(adminSafe, coldAdmin, data);

        vm.warp(block.timestamp + META_DELAY);
        vm.prank(coldAdmin);
        manager.execute(address(manager), data);
        (bool isAdmin,) = manager.hasRole(Roles.ADMIN, adminSafe);
        assertFalse(isAdmin);
    }

    // -------------------------------------------- Rule 3: only guardians veto removals

    function test_AdminCannotCancelAnotherAccountsRevocation() public {
        // The cold admin removes a guardian; the hot admin cannot veto it, a guardian can.
        bytes memory data = _revoke(Roles.GUARDIAN, guardianA);
        bytes32 id = _schedule(coldAdmin, address(manager), data);
        _expectUnauthorizedCancel(adminSafe, coldAdmin, data);
        _expectUnauthorizedCancel(guardianA, coldAdmin, data);
        vm.expectEmit(address(manager));
        emit IAccessManager.OperationCanceled(id, 1);
        _cancelAs(guardianB, coldAdmin, address(manager), data);
        assertEq(manager.getSchedule(id), 0);
    }

    function test_AdminCannotCancelAnotherAdminsRevocationOfAKey() public {
        bytes memory data = _revoke(Roles.PLATFORM, platform);
        _schedule(adminSafe, address(manager), data);
        _expectUnauthorizedCancel(coldAdmin, adminSafe, data);
        _expectUnauthorizedCancel(platform, adminSafe, data);
        _cancelAs(guardianC, adminSafe, address(manager), data);
    }

    function test_AdminStillCancelsAnotherAdminsOtherOperations() public {
        bytes[] memory calls = _hostileAdminCalls();
        for (uint256 i; i < calls.length; ++i) {
            if (bytes4(calls[i]) == IAccessManager.revokeRole.selector) continue;
            bytes32 id = _schedule(adminSafe, address(manager), calls[i]);
            _cancelAs(coldAdmin, adminSafe, address(manager), calls[i]);
            assertEq(manager.getSchedule(id), 0);
        }
        // ...and a revocation scheduled on another target is not a role revocation.
        SelectorCollisionMock other = new SelectorCollisionMock(address(manager));
        bytes memory data =
            abi.encodeCall(SelectorCollisionMock.revokeRole, (Roles.GUARDIAN, guardianA));
        _schedule(adminSafe, address(other), data);
        _cancelAs(coldAdmin, adminSafe, address(other), data);
    }

    function testFuzz_OnlyGuardiansCancelAnotherAccountsRevocation(
        uint64 role,
        uint8 victimPick,
        uint8 cancellerPick
    ) public {
        role = uint64(bound(role, 0, Roles.COUNT - 1));
        address[6] memory accounts = [guardianA, guardianB, guardianC, coldAdmin, keeper, platform];
        address victim = accounts[victimPick % 6];
        address canceller = accounts[cancellerPick % 6];
        bytes memory data = _revoke(role, victim);
        bytes32 id = _schedule(adminSafe, address(manager), data);
        bool guardian = canceller == guardianA || canceller == guardianB || canceller == guardianC;
        if (guardian && canceller != victim) {
            _cancelAs(canceller, adminSafe, address(manager), data);
            assertEq(manager.getSchedule(id), 0);
        } else {
            _expectUnauthorizedCancel(canceller, adminSafe, data);
        }
    }

    function testFuzz_NobodyCancelsTheirOwnRevocation(uint64 role, uint8 pick) public {
        role = uint64(bound(role, 0, Roles.COUNT - 1));
        address[5] memory victims = [guardianA, guardianB, guardianC, keeper, coldAdmin];
        address victim = victims[pick % 5];
        address other = victim == guardianA ? guardianB : guardianA;

        bytes memory data = _revoke(role, victim);
        _schedule(adminSafe, address(manager), data);
        _expectUnauthorizedCancel(victim, adminSafe, data);
        _cancelAs(other, adminSafe, address(manager), data);
    }

    // ------------------------------------------- wrappers cannot smuggle a revocation

    function test_MulticallWrappedRevocationNeverExecutes() public {
        bytes[] memory inner = new bytes[](2);
        inner[0] = _revoke(Roles.GUARDIAN, guardianA);
        inner[1] = _revoke(Roles.GUARDIAN, guardianB);
        bytes memory data = abi.encodeCall(Multicall.multicall, (inner));
        bytes32 id = _schedule(adminSafe, address(manager), data);
        assertEq(manager.getSchedule(id), block.timestamp + META_DELAY, "schedulable as ADMIN");
        vm.warp(block.timestamp + META_DELAY);
        // Inside execute, the manager is the caller and only `multicall` is authorised.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                address(manager),
                Roles.ADMIN
            )
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), data);
        (bool a,) = manager.hasRole(Roles.GUARDIAN, guardianA);
        (bool b,) = manager.hasRole(Roles.GUARDIAN, guardianB);
        assertTrue(a && b);
    }

    function test_NestedExecuteRevocationNeverExecutes() public {
        bytes memory data = abi.encodeCall(
            IAccessManager.execute, (address(manager), _revoke(Roles.GUARDIAN, guardianA))
        );
        bytes32 id = _schedule(adminSafe, address(manager), data);
        vm.warp(manager.getSchedule(id));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                address(manager),
                address(manager),
                IAccessManager.revokeRole.selector
            )
        );
        vm.prank(adminSafe);
        manager.execute(address(manager), data);
    }

    function test_ScheduledRenounceCannotRemoveGuardian() public {
        bytes memory data = abi.encodeCall(IAccessManager.renounceRole, (Roles.GUARDIAN, guardianA));
        bytes32 id = _schedule(adminSafe, address(manager), data);
        vm.warp(manager.getSchedule(id));
        vm.expectRevert(IAccessManager.AccessManagerBadConfirmation.selector);
        vm.prank(adminSafe);
        manager.execute(address(manager), data);
    }

    // --------------------------------------- why stock OpenZeppelin is not enough

    /// @dev The same configuration installed on a stock `AccessManager` through the library.
    function _stockManager() internal returns (AccessManager stock, GovernedTargetMock t) {
        StockInstallHarness harness = new StockInstallHarness();
        stock = new AccessManager(address(harness));
        t = new GovernedTargetMock(address(stock), recipient0, verifier0);
        GovernanceConfig.Config memory cfg = _config();
        cfg.targets[0].target = address(t);
        harness.install(stock, cfg);
    }

    function _expectStockUnauthorizedCancel(
        AccessManager stock,
        address canceller,
        address caller,
        address to,
        bytes memory data
    ) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCancel.selector,
                canceller,
                caller,
                to,
                bytes4(data)
            )
        );
        vm.prank(canceller);
        stock.cancel(caller, to, data);
    }

    function test_StockManagerLeavesGuardiansPowerlessOverManagerOperations() public {
        (AccessManager stock,) = _stockManager();
        bytes memory data = _revoke(Roles.GUARDIAN, guardianA);
        vm.prank(adminSafe);
        stock.schedule(address(stock), data, 0);
        _expectStockUnauthorizedCancel(stock, guardianB, adminSafe, address(stock), data);
    }

    function test_StockManagerCannotStopDirectSetAuthority() public {
        (AccessManager stock, GovernedTargetMock stockTarget) = _stockManager();
        AccessManager rogue = new AccessManager(attacker);
        bytes memory data = abi.encodeCall(IAccessManaged.setAuthority, (address(rogue)));
        vm.prank(adminSafe);
        stock.schedule(address(stockTarget), data, 0);
        _expectStockUnauthorizedCancel(stock, guardianA, adminSafe, address(stockTarget), data);
        // Thirty days later the compromised admin owns the target through the rogue manager.
        vm.warp(block.timestamp + META_DELAY);
        vm.prank(adminSafe);
        stock.execute(address(stockTarget), data);
        assertEq(stockTarget.authority(), address(rogue));
    }

    function test_StockManagerCannotStopUnmappedTargetSelector() public {
        (AccessManager stock, GovernedTargetMock stockTarget) = _stockManager();
        bytes memory data = abi.encodeCall(GovernedTargetMock.adminOnly, ());
        vm.prank(adminSafe);
        stock.schedule(address(stockTarget), data, 0);
        _expectStockUnauthorizedCancel(stock, guardianA, adminSafe, address(stockTarget), data);
        vm.warp(block.timestamp + META_DELAY);
        vm.prank(adminSafe);
        stock.execute(address(stockTarget), data);
        assertEq(stockTarget.adminCalls(), 1);
    }

    function test_StockManagerLetsAdminCancelItsOwnRevocation() public {
        (AccessManager stock,) = _stockManager();
        bytes memory data = _revoke(Roles.ADMIN, adminSafe);
        vm.prank(coldAdmin);
        (bytes32 id,) = stock.schedule(address(stock), data, 0);
        vm.prank(adminSafe); // succeeds on stock OpenZeppelin, hence Rule 2
        stock.cancel(coldAdmin, address(stock), data);
        assertEq(stock.getSchedule(id), 0);
    }

    // ------------------------------------------------------------- residual risk

    /// @dev Documented residual risk: colluding guardians can cancel each other's removal.
    ///      Per-account protection cannot distinguish that from defending a guardian against a
    ///      compromised admin. Mitigation is guardian independence, not code.
    function test_Residual_ColludingGuardiansCanShieldEachOther() public {
        bytes memory revokeA = _revoke(Roles.GUARDIAN, guardianA);
        bytes memory revokeB = _revoke(Roles.GUARDIAN, guardianB);
        _schedule(adminSafe, address(manager), revokeA);
        _schedule(adminSafe, address(manager), revokeB);
        _cancelAs(guardianB, adminSafe, address(manager), revokeA);
        _cancelAs(guardianA, adminSafe, address(manager), revokeB);
        (bool a,) = manager.hasRole(Roles.GUARDIAN, guardianA);
        (bool b,) = manager.hasRole(Roles.GUARDIAN, guardianB);
        assertTrue(a && b);
    }

    /// @dev Documented liveness assumption: safety needs two honest guardians online. With
    ///      only one online, a compromised admin removes it (it cannot veto its own removal)
    ///      and then nothing stops a target takeover.
    function test_Residual_LivenessNeedsTwoHonestGuardiansOnline() public {
        // guardianA and guardianC are offline; only guardianB watches.
        bytes memory rg = _revoke(Roles.GUARDIAN, guardianB);
        bytes memory rp = _revoke(Roles.PAUSER, guardianB);
        _schedule(adminSafe, address(manager), rg);
        _schedule(adminSafe, address(manager), rp);
        _expectUnauthorizedCancel(guardianB, adminSafe, rg);
        vm.warp(block.timestamp + META_DELAY);
        vm.startPrank(adminSafe);
        manager.execute(address(manager), rg);
        manager.execute(address(manager), rp);
        vm.stopPrank();
        AccessManager rogue = new AccessManager(attacker);
        _scheduleAndExecute(
            adminSafe,
            address(target),
            abi.encodeCall(IAccessManaged.setAuthority, (address(rogue)))
        );
        assertEq(target.authority(), address(rogue));
    }
}
