// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Roles } from "src/governance/Roles.sol";

contract RolesHarness {
    function executionDelay(uint64 role) external pure returns (uint32) {
        return Roles.executionDelay(role);
    }

    function grantDelay(uint64 role) external pure returns (uint32) {
        return Roles.grantDelay(role);
    }

    function label(uint64 role) external pure returns (string memory) {
        return Roles.label(role);
    }

    function requireKnown(uint64 role) external pure {
        Roles.requireKnown(role);
    }
}

/// @notice The role and delay-class table every lane imports (ADR 0001 §13).
contract RolesTest is Test {
    RolesHarness internal harness = new RolesHarness();

    function test_DelayClasses() public pure {
        assertEq(Roles.IMMEDIATE, 0);
        assertEq(Roles.STANDARD, 48 hours);
        assertEq(Roles.FUNDS, 14 days);
        assertEq(Roles.SUCCESSOR, 30 days);
    }

    function test_ReservedIdsMatchOpenZeppelin() public {
        AccessManager manager = new AccessManager(address(this));
        assertEq(Roles.ADMIN, manager.ADMIN_ROLE());
        assertEq(Roles.PUBLIC, manager.PUBLIC_ROLE());
        assertLt(Roles.COUNT, Roles.PUBLIC);
    }

    function test_ExecutionDelayTable() public pure {
        assertEq(Roles.executionDelay(Roles.ADMIN), 30 days);
        assertEq(Roles.executionDelay(Roles.GUARDIAN), 0);
        assertEq(Roles.executionDelay(Roles.PAUSER), 0);
        assertEq(Roles.executionDelay(Roles.UNPAUSER), 48 hours);
        assertEq(Roles.executionDelay(Roles.CURATION_SIGNER), 0);
        assertEq(Roles.executionDelay(Roles.STORAGE_OPERATOR), 0);
        assertEq(Roles.executionDelay(Roles.MINTER), 0);
        assertEq(Roles.executionDelay(Roles.KEEPER), 0);
        assertEq(Roles.executionDelay(Roles.PLATFORM), 0);
        assertEq(Roles.executionDelay(Roles.PARAMETER_SETTER), 48 hours);
        assertEq(Roles.executionDelay(Roles.FUNDS_SETTER), 14 days);
        assertEq(Roles.executionDelay(Roles.SUCCESSOR_SETTER), 30 days);
        assertEq(Roles.executionDelay(Roles.SYSTEM), 0);
        assertEq(Roles.executionDelay(Roles.CURATOR), 0);
    }

    function test_GrantDelayTable() public pure {
        assertEq(Roles.grantDelay(Roles.ADMIN), 30 days);
        assertEq(Roles.grantDelay(Roles.GUARDIAN), 30 days);
        assertEq(Roles.grantDelay(Roles.PAUSER), 48 hours);
        assertEq(Roles.grantDelay(Roles.UNPAUSER), 48 hours);
        assertEq(Roles.grantDelay(Roles.CURATION_SIGNER), 30 days);
        assertEq(Roles.grantDelay(Roles.STORAGE_OPERATOR), 48 hours);
        assertEq(Roles.grantDelay(Roles.MINTER), 30 days);
        assertEq(Roles.grantDelay(Roles.KEEPER), 48 hours);
        assertEq(Roles.grantDelay(Roles.PLATFORM), 48 hours);
        assertEq(Roles.grantDelay(Roles.PARAMETER_SETTER), 48 hours);
        assertEq(Roles.grantDelay(Roles.FUNDS_SETTER), 14 days);
        assertEq(Roles.grantDelay(Roles.SUCCESSOR_SETTER), 30 days);
        assertEq(Roles.grantDelay(Roles.SYSTEM), 30 days);
        assertEq(Roles.grantDelay(Roles.CURATOR), 48 hours);
    }

    /// ADR 0001 §13.1: each class role's grant delay is at least its class delay, and
    /// meta-governance (ADMIN) is at least as slow as the slowest class.
    function test_GrantDelayNeverShorterThanExecutionDelay() public pure {
        for (uint64 role; role < Roles.COUNT; ++role) {
            assertGe(Roles.grantDelay(role), Roles.executionDelay(role));
            assertLe(Roles.executionDelay(role), Roles.executionDelay(Roles.ADMIN));
        }
        assertEq(Roles.executionDelay(Roles.ADMIN), Roles.SUCCESSOR);
    }

    function test_DelayedRolesAreTheAdminSafeClasses() public pure {
        uint256 delayed;
        for (uint64 role; role < Roles.COUNT; ++role) {
            if (Roles.executionDelay(role) != Roles.IMMEDIATE) ++delayed;
        }
        assertEq(delayed, 5, "ADMIN, UNPAUSER and the three setters");
        assertEq(Roles.executionDelay(Roles.GUARDIAN), Roles.IMMEDIATE);
        assertEq(Roles.executionDelay(Roles.PAUSER), Roles.IMMEDIATE);
    }

    function test_CodeLevelGrantsTakeThirtyDays() public pure {
        // Owner decisions: a new sale adapter, curation signer or protocol contract is
        // successor-level, though each then acts immediately.
        uint64[3] memory roles = [Roles.MINTER, Roles.CURATION_SIGNER, Roles.SYSTEM];
        for (uint256 i; i < roles.length; ++i) {
            assertEq(Roles.grantDelay(roles[i]), Roles.SUCCESSOR);
            assertEq(Roles.executionDelay(roles[i]), Roles.IMMEDIATE);
        }
        assertEq(Roles.COUNT, 14);
        assertEq(Roles.SYSTEM, 12);
        assertEq(Roles.CURATOR, 13);
    }

    function test_LabelsAreDistinct() public pure {
        for (uint64 a = 1; a < Roles.COUNT; ++a) {
            assertGt(bytes(Roles.label(a)).length, 0);
            for (uint64 b = a + 1; b < Roles.COUNT; ++b) {
                assertNotEq(keccak256(bytes(Roles.label(a))), keccak256(bytes(Roles.label(b))));
            }
        }
    }

    function test_AdminHasNoLabel() public {
        vm.expectRevert(abi.encodeWithSelector(Roles.UnknownRole.selector, Roles.ADMIN));
        harness.label(Roles.ADMIN);
    }

    function testFuzz_UnknownRoleReverts(uint64 role) public {
        role = uint64(bound(role, Roles.COUNT, type(uint64).max));
        bytes memory err = abi.encodeWithSelector(Roles.UnknownRole.selector, role);
        vm.expectRevert(err);
        harness.executionDelay(role);
        vm.expectRevert(err);
        harness.grantDelay(role);
        vm.expectRevert(err);
        harness.label(role);
        vm.expectRevert(err);
        harness.requireKnown(role);
    }
}
