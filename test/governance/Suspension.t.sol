// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Multicall } from "@openzeppelin/contracts/utils/Multicall.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";
import { GovernedTargetMock } from "../mocks/governance/GovernanceMocks.sol";

/// @notice GOV-2: a guardian suspends a holder of a zero-delay operational role at once; only
///         an ADMIN grant or revocation (30 days, guardian-vetoable) clears it.
contract SuspensionTest is GovernanceFixture {
    uint32 internal constant META_DELAY = 30 days;

    function setUp() public {
        _deployGovernance();
    }

    function _suspend(address guardian, uint64 role, address account) internal {
        vm.prank(guardian);
        manager.suspend(role, account);
    }

    function _member(uint64 role, address account) internal view returns (bool member) {
        (member,) = manager.hasRole(role, account);
    }

    function test_SuspendableRolesAreTheZeroDelayOperationalKeys() public view {
        for (uint64 role; role < Roles.COUNT; ++role) {
            bool expected =
                role == Roles.PLATFORM || role == Roles.CURATOR || role == Roles.STORAGE_OPERATOR;
            assertEq(Roles.isSuspendable(role), expected, vm.toString(role));
            if (expected) assertEq(Roles.executionDelay(role), 0, "zero-delay roles only");
        }
        assertFalse(Roles.isSuspendable(Roles.ADMIN));
        // The curation verifier's `disableSigner` is the signer's kill switch.
        assertFalse(Roles.isSuspendable(Roles.CURATION_SIGNER));
        assertFalse(Roles.isSuspendable(Roles.KEEPER));
        assertFalse(Roles.isSuspendable(Roles.PUBLIC));
    }

    function test_AGuardianSuspendsAKeyInTheSameBlock() public {
        vm.prank(curator);
        target.curate();
        vm.expectEmit(address(manager));
        emit WorksAccessManager.RoleSuspended(Roles.CURATOR, curator, guardianB);
        _suspend(guardianB, Roles.CURATOR, curator);
        assertTrue(manager.isSuspended(Roles.CURATOR, curator));
        assertFalse(_member(Roles.CURATOR, curator));
        (bool immediate, uint32 delay) =
            manager.canCall(curator, address(target), GovernedTargetMock.curate.selector);
        assertFalse(immediate);
        assertEq(delay, 0);
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, curator)
        );
        target.curate();
        // Its record stays until an admin revokes it, and other roles are unaffected.
        assertTrue(GovernanceConfig.hasRecord(manager, Roles.CURATOR, curator));
        assertTrue(_member(Roles.KEEPER, keeper));
        vm.prank(keeper);
        target.keep();
    }

    function test_OnlyGuardiansSuspend() public {
        address[6] memory others = [adminSafe, coldAdmin, platform, curator, keeper, outsider];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessManager.AccessManagerUnauthorizedAccount.selector,
                    others[i],
                    Roles.GUARDIAN
                )
            );
            manager.suspend(Roles.PLATFORM, platform);
        }
        // A pauser that is not a guardian cannot either.
        address pauserOnly = makeAddr("pauserOnly");
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (Roles.PAUSER, pauserOnly, 0)));
        vm.warp(block.timestamp + Roles.grantDelay(Roles.PAUSER));
        vm.prank(pauserOnly);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, pauserOnly, Roles.GUARDIAN
            )
        );
        manager.suspend(Roles.PLATFORM, platform);
    }

    function testFuzz_OnlyOperationalRolesCanBeSuspended(uint64 role) public {
        role = uint64(bound(role, 0, Roles.COUNT));
        vm.assume(!Roles.isSuspendable(role));
        vm.prank(guardianA);
        vm.expectRevert(
            abi.encodeWithSelector(WorksAccessManager.RoleNotSuspendable.selector, role)
        );
        manager.suspend(role, adminSafe);
    }

    function test_NonMembersAndTheSuspendedCannotBeSuspendedAgain() public {
        vm.prank(guardianA);
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.NotSuspendable.selector, Roles.PLATFORM, outsider
            )
        );
        manager.suspend(Roles.PLATFORM, outsider);
        _suspend(guardianA, Roles.PLATFORM, platform);
        vm.prank(guardianB);
        vm.expectRevert(
            abi.encodeWithSelector(
                WorksAccessManager.NotSuspendable.selector, Roles.PLATFORM, platform
            )
        );
        manager.suspend(Roles.PLATFORM, platform);
    }

    function test_APendingGrantCanBeSuspended() public {
        address newCurator = makeAddr("newCurator");
        _adminExecute(abi.encodeCall(IAccessManager.grantRole, (Roles.CURATOR, newCurator, 0)));
        assertFalse(_member(Roles.CURATOR, newCurator), "waits its grant delay");
        _suspend(guardianC, Roles.CURATOR, newCurator);
        vm.warp(block.timestamp + Roles.grantDelay(Roles.CURATOR));
        assertFalse(_member(Roles.CURATOR, newCurator), "never becomes active");
    }

    function test_SuspensionThroughExecuteIsRefused() public {
        // Unmapped on the manager, `suspend` resolves to ADMIN; inside `execute` the manager
        // is the sender, which is no guardian.
        bytes memory data = abi.encodeCall(WorksAccessManager.suspend, (Roles.PLATFORM, platform));
        _schedule(adminSafe, address(manager), data);
        vm.warp(block.timestamp + META_DELAY);
        vm.prank(adminSafe);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                address(manager),
                Roles.GUARDIAN
            )
        );
        manager.execute(address(manager), data);
        assertFalse(manager.isSuspended(Roles.PLATFORM, platform));
    }

    function test_AGuardianBatchesSuspensionsInMulticall() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(WorksAccessManager.suspend, (Roles.PLATFORM, platform));
        calls[1] = abi.encodeCall(WorksAccessManager.suspend, (Roles.CURATOR, curator));
        vm.prank(guardianA);
        Multicall(address(manager)).multicall(calls);
        assertTrue(manager.isSuspended(Roles.PLATFORM, platform));
        assertTrue(manager.isSuspended(Roles.CURATOR, curator));
    }

    // ------------------------------------------------------------------ lifting it

    function test_OnlyAnAdminGrantLiftsItAndAGuardianCanVetoThat() public {
        _suspend(guardianA, Roles.CURATOR, curator);
        bytes memory lift = abi.encodeCall(IAccessManager.grantRole, (Roles.CURATOR, curator, 0));
        bytes32 id = _schedule(adminSafe, address(manager), lift);
        assertEq(manager.getSchedule(id), block.timestamp + META_DELAY, "30-day class");
        vm.prank(guardianB);
        manager.cancel(adminSafe, address(manager), lift);
        id = _schedule(adminSafe, address(manager), lift);
        vm.warp(manager.getSchedule(id));
        vm.expectEmit(address(manager));
        emit WorksAccessManager.RoleSuspensionLifted(Roles.CURATOR, curator);
        vm.prank(adminSafe);
        manager.execute(address(manager), lift);
        assertFalse(manager.isSuspended(Roles.CURATOR, curator));
        assertTrue(_member(Roles.CURATOR, curator), "an existing member: no grant delay");
        vm.prank(curator);
        target.curate();
    }

    /// @dev Leaving a role that was never suspended lifts nothing, so it announces nothing.
    function test_ARenunciationWithoutASuspensionLiftsNothing() public {
        vm.recordLogs();
        vm.prank(platform);
        manager.renounceRole(Roles.PLATFORM, platform);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != WorksAccessManager.RoleSuspensionLifted.selector,
                "a lift was announced"
            );
        }
        assertFalse(GovernanceConfig.hasRecord(manager, Roles.PLATFORM, platform));
    }

    function test_ARevocationClearsItAndTheKeyCanRenounce() public {
        _suspend(guardianA, Roles.STORAGE_OPERATOR, storageOperator);
        bytes memory revoke =
            abi.encodeCall(IAccessManager.revokeRole, (Roles.STORAGE_OPERATOR, storageOperator));
        _schedule(adminSafe, address(manager), revoke);
        vm.warp(block.timestamp + META_DELAY);
        vm.expectEmit(address(manager));
        emit WorksAccessManager.RoleSuspensionLifted(Roles.STORAGE_OPERATOR, storageOperator);
        vm.prank(adminSafe);
        manager.execute(address(manager), revoke);
        assertFalse(manager.isSuspended(Roles.STORAGE_OPERATOR, storageOperator));
        assertFalse(GovernanceConfig.hasRecord(manager, Roles.STORAGE_OPERATOR, storageOperator));

        // A suspended key may renounce; it leaves the role entirely.
        _suspend(guardianA, Roles.PLATFORM, platform);
        vm.prank(platform);
        manager.renounceRole(Roles.PLATFORM, platform);
        assertFalse(manager.isSuspended(Roles.PLATFORM, platform));
        assertFalse(GovernanceConfig.hasRecord(manager, Roles.PLATFORM, platform));
    }

    function test_ReadbackRejectsASuspendedHolder() public {
        configurator.verify(_config());
        _suspend(guardianA, Roles.PLATFORM, platform);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceConfig.HolderMismatch.selector, Roles.PLATFORM, platform
            )
        );
        configurator.verify(_config());
    }

    function test_GuardiansAndAdminsAreNeverSuspendedByRole() public view {
        // The membership checks the cancel rules and the admin functions rely on are stock.
        assertTrue(_member(Roles.GUARDIAN, guardianA));
        assertTrue(_member(Roles.ADMIN, adminSafe));
        assertTrue(_member(Roles.PAUSER, guardianA));
    }
}
