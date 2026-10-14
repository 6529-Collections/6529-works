// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Roles } from "src/governance/Roles.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Governance recovery on the real genesis deployment (ADR 0002 decision 5, owner
///         decision 2): the cold recovery admin completes a recovery even when the hot admin and
///         one guardian (of three) act against it together.
contract GovernanceRecoveryTest is IntegrationBase {
    uint32 internal constant META_DELAY = 30 days;

    function _revoke(uint64 role, address account) internal pure returns (bytes memory) {
        return abi.encodeCall(IAccessManager.revokeRole, (role, account));
    }

    function _has(uint64 role, address account) internal view returns (bool member) {
        (member,) = manager.hasRole(role, account);
    }

    function _hotAdminRoles() internal pure returns (uint64[5] memory) {
        return [
            Roles.ADMIN,
            Roles.UNPAUSER,
            Roles.PARAMETER_SETTER,
            Roles.FUNDS_SETTER,
            Roles.SUCCESSOR_SETTER
        ];
    }

    function _expectUnauthorizedCancel(address canceller, address caller, bytes memory data)
        internal
    {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCancel.selector,
                canceller,
                caller,
                address(manager),
                bytes4(data)
            )
        );
        vm.prank(canceller);
        manager.cancel(caller, address(manager), data);
    }

    // ------------------------------------------------- GOV-1: recovery completes

    /// @dev Round one removes the guardian (only another guardian may cancel its revocation,
    ///      and the honest ones do not); round two removes the hot admin (nobody left may cancel
    ///      it). Then the cold admin appoints the replacement: revocations first, grants after.
    function test_GOV1_ColdAdminRemovesAHotAdminAndAGuardianActingTogether() public {
        vm.warp(block.timestamp + manager.minSetback());
        uint64[5] memory hotRoles = _hotAdminRoles();
        bytes[5] memory removeHot;
        for (uint256 i; i < 5; ++i) {
            removeHot[i] = _revoke(hotRoles[i], hotAdmin);
        }
        bytes memory removeGuardian = _revoke(Roles.GUARDIAN, guardian1);
        bytes memory removePauser = _revoke(Roles.PAUSER, guardian1);

        // Round one.
        for (uint256 i; i < 5; ++i) {
            _schedule(coldAdmin, address(manager), removeHot[i]);
        }
        _schedule(coldAdmin, address(manager), removeGuardian);
        _schedule(coldAdmin, address(manager), removePauser);
        // A guardian may still cancel any operation, the hot admin's revocations included.
        for (uint256 i; i < 5; ++i) {
            vm.prank(guardian1);
            manager.cancel(coldAdmin, address(manager), removeHot[i]);
        }
        // Neither may cancel the revocation of the guardian: guardian 1 by Rule 2, the hot
        // admin by Rule 3 (only guardians cancel another account's revocation).
        _expectUnauthorizedCancel(guardian1, coldAdmin, removeGuardian);
        _expectUnauthorizedCancel(guardian1, coldAdmin, removePauser);
        _expectUnauthorizedCancel(hotAdmin, coldAdmin, removeGuardian);
        _expectUnauthorizedCancel(hotAdmin, coldAdmin, removePauser);
        vm.warp(block.timestamp + META_DELAY);
        vm.startPrank(coldAdmin);
        manager.execute(address(manager), removeGuardian);
        manager.execute(address(manager), removePauser);
        vm.stopPrank();
        assertFalse(_has(Roles.GUARDIAN, guardian1), "guardian 1 removed");
        assertFalse(_has(Roles.PAUSER, guardian1), "guardian 1 pauser removed");

        // Round two: the hot admin's revocations.
        for (uint256 i; i < 5; ++i) {
            _schedule(coldAdmin, address(manager), removeHot[i]);
            _expectUnauthorizedCancel(hotAdmin, coldAdmin, removeHot[i]);
            _expectUnauthorizedCancel(guardian1, coldAdmin, removeHot[i]);
        }
        vm.warp(block.timestamp + META_DELAY);
        vm.startPrank(coldAdmin);
        for (uint256 i; i < 5; ++i) {
            manager.execute(address(manager), removeHot[i]);
        }
        vm.stopPrank();
        for (uint256 i; i < 5; ++i) {
            (uint48 since,,,) = manager.getAccess(hotRoles[i], hotAdmin);
            assertEq(since, 0, "the hot admin keeps a role");
        }

        // Only then the replacement: nobody left can cancel the cold admin's grants.
        address newHot = makeAddr("newHotAdminSafe");
        bytes memory grantUnpauser =
            abi.encodeCall(IAccessManager.grantRole, (Roles.UNPAUSER, newHot, Roles.STANDARD));
        _schedule(coldAdmin, address(manager), grantUnpauser);
        _expectUnauthorizedCancel(hotAdmin, coldAdmin, grantUnpauser);
        vm.warp(block.timestamp + META_DELAY);
        vm.prank(coldAdmin);
        manager.execute(address(manager), grantUnpauser);
        vm.warp(block.timestamp + Roles.grantDelay(Roles.UNPAUSER));
        assertTrue(_has(Roles.UNPAUSER, newHot), "the new hot admin unpauses");
        assertTrue(_has(Roles.ADMIN, coldAdmin), "the cold admin stays");
    }

    /// @dev The guardian veto is unchanged: any other guardian cancels a hostile admin's
    ///      revocation of a guardian, and admins keep the stock power to cancel each other's
    ///      operations other than revocations.
    function test_GOV1_TheGuardianVetoIsUnchanged() public {
        vm.warp(block.timestamp + manager.minSetback());
        bytes memory removeGuardian2 = _revoke(Roles.GUARDIAN, guardian2);
        bytes32 id = _schedule(hotAdmin, address(manager), removeGuardian2);
        _expectUnauthorizedCancel(guardian2, hotAdmin, removeGuardian2);
        vm.prank(guardian3);
        manager.cancel(hotAdmin, address(manager), removeGuardian2);
        assertEq(manager.getSchedule(id), 0, "vetoed");

        // A scheduler still withdraws its own revocation.
        bytes memory removeCold = _revoke(Roles.ADMIN, coldAdmin);
        id = _schedule(hotAdmin, address(manager), removeCold);
        vm.prank(hotAdmin);
        manager.cancel(hotAdmin, address(manager), removeCold);
        assertEq(manager.getSchedule(id), 0, "withdrawn");

        // With every guardian offline, the cold admin still cancels the hot admin's grants.
        bytes memory grab =
            abi.encodeCall(IAccessManager.grantRole, (Roles.ADMIN, makeAddr("intruder"), 0));
        id = _schedule(hotAdmin, address(manager), grab);
        vm.prank(coldAdmin);
        manager.cancel(hotAdmin, address(manager), grab);
        assertEq(manager.getSchedule(id), 0, "admin cancels a grant");
    }
}
