// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { ContractSeat } from "../mocks/governance/SuccessionMocks.sol";
import { PermanenceFixture } from "./PermanenceFixture.sol";

/// @notice A governance seat need not be a plain key (GV-46): the manager authorises
///         `msg.sender` only, so a contract account (a smart wallet with any signature scheme)
///         can hold `ADMIN` or `GUARDIAN`, schedule, execute, cancel, vote and prove liveness,
///         and can rotate its own key without its roles changing.
contract ContractSeatTest is PermanenceFixture {
    bytes32 internal constant ADMIN_KEY = keccak256("admin seat key, any scheme");
    bytes32 internal constant GUARDIAN_KEY = keccak256("guardian seat key, any scheme");
    ContractSeat internal adminSeat;
    ContractSeat internal guardianSeat;

    function setUp() public {
        adminSeat = new ContractSeat(keccak256(abi.encode(ADMIN_KEY)));
        guardianSeat = new ContractSeat(keccak256(abi.encode(GUARDIAN_KEY)));
        _deployGovernance();
    }

    /// @dev The default layout with the cold admin and guardian C replaced by contract seats.
    function _grants() internal view override returns (GovernanceConfig.Grant[] memory g) {
        g = super._grants();
        for (uint256 i; i < g.length; ++i) {
            if (g[i].account == coldAdmin) g[i].account = address(adminSeat);
            if (g[i].account == guardianC) g[i].account = address(guardianSeat);
        }
    }

    function _asAdmin(bytes memory call) internal returns (bytes memory) {
        return adminSeat.exec(ADMIN_KEY, address(manager), call);
    }

    function _asGuardian(bytes memory call) internal returns (bytes memory) {
        return guardianSeat.exec(GUARDIAN_KEY, address(manager), call);
    }

    function test_AContractAdminSeatSchedulesExecutesAndProvesLiveness() public {
        bytes memory grant =
            abi.encodeCall(IAccessManager.grantRole, (Roles.CURATOR, makeAddr("newCurator"), 0));
        _asAdmin(abi.encodeCall(IAccessManager.schedule, (address(manager), grant, 0)));
        vm.warp(block.timestamp + ADMIN_DELAY);
        _asAdmin(abi.encodeCall(IAccessManager.execute, (address(manager), grant)));
        (uint48 since,,,) = manager.getAccess(Roles.CURATOR, makeAddr("newCurator"));
        assertGt(since, 0);
        vm.warp(block.timestamp + 100 days);
        _asAdmin(abi.encodeCall(WorksAccessManager.heartbeat, ()));
        assertEq(manager.lastAdminActivity(), block.timestamp);
    }

    function test_AContractGuardianSeatCancelsAndVotes() public {
        bytes memory removeA = _revoke(Roles.GUARDIAN, guardianA);
        _schedule(adminSafe, address(manager), removeA);
        _asGuardian(abi.encodeCall(IAccessManager.cancel, (adminSafe, address(manager), removeA)));
        assertFalse(_scheduled(adminSafe, removeA), "Rule 1, and a strike");
        bytes32 id = _schedule(adminSafe, address(manager), removeA);
        _asGuardian(abi.encodeCall(IAccessManager.cancel, (adminSafe, address(manager), removeA)));
        assertEq(manager.getEscalation(id).votes, 1, "a vote in the escalated lane");
        _cancel(guardianB, adminSafe, removeA);
        assertFalse(_scheduled(adminSafe, removeA));
    }

    function test_ASeatRotatesItsKeyAndKeepsItsRoles() public {
        bytes32 nextKey = keccak256("a post-quantum key");
        guardianSeat.rotate(GUARDIAN_KEY, keccak256(abi.encode(nextKey)));
        vm.expectRevert(ContractSeat.WrongKey.selector);
        guardianSeat.exec(GUARDIAN_KEY, address(manager), "");
        guardianSeat.exec(
            nextKey,
            address(manager),
            abi.encodeCall(WorksAccessManager.suspend, (Roles.PLATFORM, platform))
        );
        assertTrue(manager.isSuspended(Roles.PLATFORM, platform));
        (bool member,) = manager.hasRole(Roles.GUARDIAN, address(guardianSeat));
        assertTrue(member);
    }
}
