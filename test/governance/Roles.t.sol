// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Roles } from "src/governance/Roles.sol";

contract RolesHarness {
    function executionDelay(uint64 role) external pure returns (uint32) {
        return Roles.executionDelay(role);
    }

    function label(uint64 role) external pure returns (string memory) {
        return Roles.label(role);
    }

    function requireKnown(uint64 role) external pure {
        Roles.requireKnown(role);
    }
}

/// @notice The role and delay table every lane imports.
contract RolesTest is Test {
    RolesHarness internal harness = new RolesHarness();

    function test_FixedDelays() public pure {
        assertEq(Roles.DELAY_24H, 24 hours);
        assertEq(Roles.DELAY_3D, 3 days);
        assertEq(Roles.DELAY_7D, 7 days);
        assertEq(Roles.BRAKE_DELAY, 7 days);
    }

    function test_ReservedIdsMatchOpenZeppelin() public {
        AccessManager m = new AccessManager(address(this));
        assertEq(Roles.ADMIN, m.ADMIN_ROLE());
        assertEq(Roles.PUBLIC, m.PUBLIC_ROLE());
    }

    function test_NetworkRolesAndTheirClasses() public pure {
        assertEq(Roles.executionDelay(Roles.ADMIN), 7 days);
        assertEq(Roles.executionDelay(Roles.NETWORK), 0);
        assertEq(Roles.executionDelay(Roles.PARAMETER_SETTER), 24 hours);
        assertEq(Roles.executionDelay(Roles.FUNDS_SETTER), 3 days);
        assertEq(Roles.executionDelay(Roles.SUCCESSOR_SETTER), 7 days);
        uint256 network;
        for (uint64 role; role < Roles.COUNT; ++role) {
            if (Roles.isNetworkRole(role)) ++network;
        }
        assertEq(network, 5);
    }

    function test_OperationalRolesHaveNoDelay() public pure {
        uint64[7] memory operational = [
            Roles.PAUSER,
            Roles.CURATION_SIGNER,
            Roles.STORAGE_OPERATOR,
            Roles.MINTER,
            Roles.KEEPER,
            Roles.PLATFORM,
            Roles.CURATOR
        ];
        for (uint256 i; i < operational.length; ++i) {
            assertFalse(Roles.isNetworkRole(operational[i]));
            assertEq(Roles.executionDelay(operational[i]), 0);
        }
    }

    function test_LabelsAreDistinct() public pure {
        for (uint64 a = 1; a < Roles.COUNT; ++a) {
            if (!Roles.isKnown(a)) continue;
            for (uint64 b = a + 1; b < Roles.COUNT; ++b) {
                if (!Roles.isKnown(b)) continue;
                assertNotEq(keccak256(bytes(Roles.label(a))), keccak256(bytes(Roles.label(b))));
            }
        }
    }

    function test_AdminHasNoLabel() public {
        vm.expectRevert(abi.encodeWithSelector(Roles.UnknownRole.selector, Roles.ADMIN));
        harness.label(Roles.ADMIN);
    }

    /// @dev Every defined role has its own name, and IDs past the table have none.
    function test_LabelsNameEachRoleAndNothingPastTheTable() public {
        assertEq(harness.label(Roles.CURATOR), "CURATOR");
        assertEq(harness.label(Roles.SUCCESSOR_SETTER), "SUCCESSOR_SETTER");
        uint64[2] memory past = [Roles.COUNT, Roles.PUBLIC];
        for (uint256 i; i < past.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Roles.UnknownRole.selector, past[i]));
            harness.label(past[i]);
        }
    }

    /// @dev ID 3 was the separate unpause role; it is no longer defined.
    function test_TheFormerUnpauseIdIsUnknown() public {
        assertFalse(Roles.isKnown(3));
        vm.expectRevert(abi.encodeWithSelector(Roles.UnknownRole.selector, uint64(3)));
        harness.requireKnown(3);
        vm.expectRevert(abi.encodeWithSelector(Roles.UnknownRole.selector, uint64(3)));
        harness.executionDelay(3);
        vm.expectRevert(abi.encodeWithSelector(Roles.UnknownRole.selector, uint64(3)));
        harness.label(3);
    }

    function testFuzz_UnknownRoleReverts(uint64 role) public {
        vm.assume(role >= Roles.COUNT);
        vm.expectRevert(abi.encodeWithSelector(Roles.UnknownRole.selector, role));
        harness.requireKnown(role);
        vm.expectRevert(abi.encodeWithSelector(Roles.UnknownRole.selector, role));
        harness.executionDelay(role);
        assertFalse(Roles.isNetworkRole(role));
    }
}
