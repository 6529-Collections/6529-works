// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Roles } from "src/governance/Roles.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernanceFixture } from "../helpers/GovernanceFixture.sol";

/// @notice Helpers for the bounded veto, dead-admin recovery, succession and seat tests.
abstract contract PermanenceFixture is GovernanceFixture {
    uint32 internal constant ADMIN_DELAY = 30 days;
    uint32 internal constant SLOW = 60 days;
    uint32 internal constant ESCALATED = 120 days;
    uint32 internal constant SILENCE = 365 days;
    uint32 internal constant RECOVERY = 180 days;

    function _revoke(uint64 role, address account) internal pure returns (bytes memory) {
        return abi.encodeCall(IAccessManager.revokeRole, (role, account));
    }

    function _register(address next) internal pure returns (bytes memory) {
        return abi.encodeCall(WorksAccessManager.registerSuccessor, (next));
    }

    /// @dev `nextAdmin`, a zero-delay admin of the OpenZeppelin successor `next`, proves the
    ///      pending successor can act: it re-points the probe to the manager, then accepts.
    function _accept(AccessManager next, address nextAdmin) internal {
        address probe = manager.successionProbe();
        vm.startPrank(nextAdmin);
        next.execute(probe, abi.encodeCall(IAccessManaged.setAuthority, (address(manager))));
        next.execute(address(manager), abi.encodeCall(WorksAccessManager.acceptSuccession, ()));
        vm.stopPrank();
    }

    function _setParameter(WorksAccessManager.Parameter which, uint32 expected, uint32 value)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(WorksAccessManager.setParameter, (which, expected, value));
    }

    function _id(address caller, bytes memory data) internal view returns (bytes32) {
        return manager.hashOperation(caller, address(manager), data);
    }

    function _cancel(address by, address caller, bytes memory data) internal {
        vm.prank(by);
        manager.cancel(caller, address(manager), data);
    }

    /// @dev `adminSafe` grants `account` GUARDIAN and PAUSER (30 days), which become active after
    ///      the 30-day grant delay.
    function _addGuardian(address account) internal {
        bytes memory a = abi.encodeCall(IAccessManager.grantRole, (Roles.GUARDIAN, account, 0));
        bytes memory b = abi.encodeCall(IAccessManager.grantRole, (Roles.PAUSER, account, 0));
        _schedule(adminSafe, address(manager), a);
        bytes32 id = _schedule(adminSafe, address(manager), b);
        vm.warp(manager.getSchedule(id));
        vm.startPrank(adminSafe);
        manager.execute(address(manager), a);
        manager.execute(address(manager), b);
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days);
    }

    /// @dev Removes `account`'s guardian roles in the normal lane, with nobody cancelling.
    function _removeGuardianUnopposed(address account) internal {
        bytes memory a = _revoke(Roles.GUARDIAN, account);
        bytes memory b = _revoke(Roles.PAUSER, account);
        _schedule(adminSafe, address(manager), a);
        bytes32 id = _schedule(adminSafe, address(manager), b);
        vm.warp(manager.getSchedule(id));
        vm.startPrank(adminSafe);
        manager.execute(address(manager), a);
        manager.execute(address(manager), b);
        vm.stopPrank();
    }

    /// @dev `scheduler` proposes `data` and `canceller` cancels it in the normal lane.
    function _strike(address scheduler, bytes memory data, address canceller) internal {
        _schedule(scheduler, address(manager), data);
        _cancel(canceller, scheduler, data);
    }

    function _guardianSeats() internal view returns (uint256) {
        return manager.seatHolders(Roles.GUARDIAN).length;
    }

    function _scheduled(address caller, bytes memory data) internal view returns (bool) {
        return manager.getSchedule(_id(caller, data)) != 0;
    }
}
