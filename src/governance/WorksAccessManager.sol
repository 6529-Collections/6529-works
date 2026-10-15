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
///         It also lets a guardian suspend a holder of a zero-delay operational role at once
///         (`suspend`, ADR 0002 addendum): a tightening action, one way for the guardian.
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
    /// @dev Suspended holders of `Roles.isSuspendable` roles. Cleared by any grant or revocation
    ///      of the same role to the same account, both ADMIN actions (30 days).
    mapping(uint64 roleId => mapping(address account => bool)) private _suspended;

    /// @notice `guardian` suspended `account`'s `roleId`: it no longer acts for that role.
    event RoleSuspended(uint64 indexed roleId, address indexed account, address indexed guardian);
    /// @notice A grant or revocation of `roleId` to `account` cleared its suspension.
    event RoleSuspensionLifted(uint64 indexed roleId, address indexed account);

    /// @notice `roleId` is not a zero-delay operational role (`Roles.isSuspendable`).
    error RoleNotSuspendable(uint64 roleId);
    /// @notice `account` has no record for `roleId`, or is already suspended.
    error NotSuspendable(uint64 roleId, address account);

    /// @param initialAdmin The one-shot configurator, which renounces the admin role once done.
    constructor(address initialAdmin) AccessManager(initialAdmin) { }

    /// @notice Suspends `account`'s `roleId` at once: it fails `hasRole`, and so `canCall` and
    ///         every check built on them, until an ADMIN grant or revocation of that role to
    ///         that account executes (30 days, guardian-vetoable). Guardians only.
    /// @dev `roleId` must be `Roles.isSuspendable` and `account` must hold or await it.
    function suspend(uint64 roleId, address account) external {
        address sender = _msgSender();
        (bool isGuardian,) = hasRole(Roles.GUARDIAN, sender);
        if (!isGuardian) revert AccessManagerUnauthorizedAccount(sender, Roles.GUARDIAN);
        if (!Roles.isSuspendable(roleId)) revert RoleNotSuspendable(roleId);
        (uint48 since,,,) = getAccess(roleId, account);
        if (since == 0 || _suspended[roleId][account]) revert NotSuspendable(roleId, account);
        _suspended[roleId][account] = true;
        emit RoleSuspended(roleId, account, sender);
    }

    /// @notice Whether `account`'s `roleId` is suspended.
    function isSuspended(uint64 roleId, address account) external view returns (bool) {
        return _suspended[roleId][account];
    }

    /// @inheritdoc AccessManager
    /// @dev A suspended holder is not a member.
    function hasRole(uint64 roleId, address account)
        public
        view
        override
        returns (bool isMember, uint32 executionDelay)
    {
        (isMember, executionDelay) = super.hasRole(roleId, account);
        if (isMember && Roles.isSuspendable(roleId) && _suspended[roleId][account]) {
            isMember = false;
        }
    }

    /// @inheritdoc AccessManager
    function _grantRole(uint64 roleId, address account, uint32 grantDelay, uint32 executionDelay)
        internal
        override
        returns (bool)
    {
        _lift(roleId, account);
        return super._grantRole(roleId, account, grantDelay, executionDelay);
    }

    /// @inheritdoc AccessManager
    function _revokeRole(uint64 roleId, address account) internal override returns (bool) {
        _lift(roleId, account);
        return super._revokeRole(roleId, account);
    }

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

    function _lift(uint64 roleId, address account) private {
        if (!_suspended[roleId][account]) return;
        delete _suspended[roleId][account];
        emit RoleSuspensionLifted(roleId, account);
    }

    /// @dev True when `data`, a `revokeRole` call, names `account`. Never reverts: shorter
    ///      data, or an address word with dirty upper bits, cannot execute as `revokeRole`, so
    ///      it falls through to the other rules.
    function _revokesRoleOf(bytes calldata data, address account) private pure returns (bool) {
        if (data.length < 0x44) return false;
        return uint256(bytes32(data[0x24:0x44])) == uint256(uint160(account));
    }
}
