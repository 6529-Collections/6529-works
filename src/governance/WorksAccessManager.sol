// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Roles } from "./Roles.sol";

/// @title WorksAccessManager
/// @notice The OpenZeppelin 5.7.0 `AccessManager` that governs every 6529 Works contract, with
///         three cancellation rules (ADR 0001 §13.2, ADR 0002):
///         1. any `Roles.GUARDIAN` holder can cancel any scheduled operation;
///         2. nobody but its scheduler can cancel an operation that revokes one of the
///            canceller's own roles, so no guardian or admin can veto its own removal;
///         3. only a guardian, or its scheduler, can cancel a role revocation on this manager,
///            so no admin can veto another account's removal.
/// @dev Stock cancellation is selector-scoped: the scheduler, an admin, or the guardian of the
///      target function's role. That leaves guardians unable to cancel the admin's operations
///      on this manager (its admin selectors resolve to `ADMIN_ROLE`, whose guardian is locked
///      to `ADMIN`), a `setAuthority` scheduled directly on a target (its role mapping is
///      locked), and any target selector left unmapped. Rule 1 closes all three. Rules 2 and 3
///      cannot be expressed per selector, because they depend on arguments and on who
///      scheduled. Every other cancellation keeps the stock rules, so an admin still cancels
///      another admin's grants, remaps and authority moves. The inherited OpenZeppelin
///      `Multicall` self-delegatecall only batches calls into this contract; it is the one
///      sanctioned exemption to the no-delegatecall rule.
contract WorksAccessManager is AccessManager {
    /// @param initialAdmin The one-shot configurator, which renounces the admin role once done.
    constructor(address initialAdmin) AccessManager(initialAdmin) { }

    /// @inheritdoc AccessManager
    function _canCancel(address caller, address target, bytes calldata data)
        internal
        view
        override
        returns (bool)
    {
        address sender = _msgSender();
        bool othersRevocation = caller != sender && target == address(this) && data.length >= 4
            && bytes4(data[:4]) == IAccessManager.revokeRole.selector;
        if (othersRevocation && _revokesRoleOf(data, sender)) return false; // Rule 2
        (bool isGuardian,) = hasRole(Roles.GUARDIAN, sender);
        if (othersRevocation) return isGuardian; // Rule 3
        return isGuardian || super._canCancel(caller, target, data); // Rule 1
    }

    /// @dev True when `data`, a `revokeRole` call, names `account`. Never reverts: shorter
    ///      data, or an address word with dirty upper bits, cannot execute as `revokeRole`, so
    ///      it falls through to the other rules.
    function _revokesRoleOf(bytes calldata data, address account) private pure returns (bool) {
        if (data.length < 0x44) return false;
        return uint256(bytes32(data[0x24:0x44])) == uint256(uint160(account));
    }
}
