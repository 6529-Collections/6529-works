// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "./Roles.sol";

/// @title GovernanceConfig
/// @notice Validates, installs and reads back the 6529 Works `AccessManager` configuration
///         (ADR 0001 §13). Delays, role admins and role guardians come from {Roles}; a config
///         only names holders and maps target selectors, so it cannot pick a wrong delay.
/// @dev `install` must run from the manager's sole admin with no execution delay: in
///      production, {GovernanceConfigurator} on the manager it deploys itself. Grant and
///      target-admin delays become effective after the manager's `minSetback()` (5 days);
///      `verify` reads effective values, so CI readback runs after that window. OpenZeppelin
///      exposes no getter for a pending grant-delay or target-admin-delay change, so `verify`
///      cannot see one; deployment CI scans `RoleGrantDelayChanged` and
///      `TargetAdminDelayUpdated` events for future effect times instead.
library GovernanceConfig {
    /// @notice One holder of one role. Its execution delay is always `Roles.executionDelay`.
    struct Grant {
        uint64 role;
        address account;
    }

    /// @notice One governed selector on a target and the single class role it maps to.
    struct FunctionRole {
        bytes4 selector;
        uint64 role;
    }

    /// @notice One `AccessManaged` target and its governed selectors.
    struct Target {
        address target;
        FunctionRole[] functions;
    }

    /// @notice A full configuration epoch.
    struct Config {
        Grant[] grants;
        Target[] targets;
    }

    /// @notice Minimum number of distinct veto guardians (ADR 0001 §13.3). Deployments use
    ///         at least three, because safety needs two honest guardians online at all times.
    uint256 internal constant MIN_GUARDIANS = 2;
    /// @notice Admin delay of every target, the manager included (ADR 0001 §13.1).
    uint32 internal constant TARGET_ADMIN_DELAY = Roles.SUCCESSOR;

    /// @notice Fewer than {MIN_GUARDIANS} guardian grants.
    error TooFewGuardians(uint256 count);
    /// @notice A required role has no holder.
    error MissingHolder(uint64 role);
    /// @notice A grant names the zero address or the installer itself.
    error InvalidGrant(uint64 role, address account);
    /// @notice The same account appears twice for one role.
    error DuplicateGrant(uint64 role, address account);
    /// @notice A guardian also holds, or is pending for, a role other than `PAUSER`.
    error GuardianHoldsRole(address account, uint64 role);
    /// @notice One account holds both pause and unpause.
    error PauserIsUnpauser(address account);
    /// @notice A target is the manager, has no code, repeats, or is governed by another
    ///         authority.
    error InvalidTarget(address target);
    /// @notice A selector appears twice on one target (one selector, one class).
    error DuplicateSelector(address target, bytes4 selector);
    /// @notice A selector maps to a role that must not call governed functions.
    error InvalidFunctionRole(address target, bytes4 selector, uint64 role);
    /// @notice Readback: a role's admin, guardian or grant delay differs from {Roles}.
    error RoleMismatch(uint64 role);
    /// @notice Readback: a holder is missing, not yet active, or has a different or pending
    ///         execution delay.
    error HolderMismatch(uint64 role, address account);
    /// @notice Readback: a target's authority, closed flag or admin delay differs.
    error TargetMismatch(address target);
    /// @notice Readback: a selector maps to a different role.
    error FunctionRoleMismatch(address target, bytes4 selector, uint64 actual);

    /// @notice Reverts unless `cfg` satisfies the guardian, holder and selector rules.
    function validate(IAccessManager manager, Config memory cfg) internal view {
        _validateGrants(cfg.grants);
        Target[] memory targets = cfg.targets;
        for (uint256 i = 0; i < targets.length; ++i) {
            address target = targets[i].target;
            if (target == address(manager) || target.code.length == 0) {
                revert InvalidTarget(target);
            }
            for (uint256 j = 0; j < i; ++j) {
                if (targets[j].target == target) revert InvalidTarget(target);
            }
            try IAccessManaged(target).authority() returns (address authority) {
                if (authority != address(manager)) revert InvalidTarget(target);
            } catch {
                revert InvalidTarget(target);
            }
            _validateFunctions(target, targets[i].functions);
        }
    }

    /// @notice Applies `cfg` to a freshly deployed manager whose sole admin is the caller.
    /// @dev The caller still holds `ADMIN` afterwards and must renounce it.
    function install(IAccessManager manager, Config memory cfg) internal {
        validate(manager, cfg);
        for (uint64 role = 1; role < Roles.COUNT; ++role) {
            manager.labelRole(role, Roles.label(role));
            manager.setRoleGuardian(role, Roles.GUARDIAN);
            manager.setGrantDelay(role, Roles.grantDelay(role));
        }
        manager.setGrantDelay(Roles.ADMIN, Roles.grantDelay(Roles.ADMIN));
        manager.setTargetAdminDelay(address(manager), TARGET_ADMIN_DELAY);

        for (uint256 i = 0; i < cfg.targets.length; ++i) {
            Target memory target = cfg.targets[i];
            manager.setTargetAdminDelay(target.target, TARGET_ADMIN_DELAY);
            bytes4[] memory one = new bytes4[](1);
            for (uint256 j = 0; j < target.functions.length; ++j) {
                one[0] = target.functions[j].selector;
                manager.setTargetFunctionRole(target.target, one, target.functions[j].role);
            }
        }

        for (uint256 i = 0; i < cfg.grants.length; ++i) {
            Grant memory grant = cfg.grants[i];
            if (grant.account == address(this)) revert InvalidGrant(grant.role, grant.account);
            manager.grantRole(grant.role, grant.account, Roles.executionDelay(grant.role));
        }
    }

    /// @notice Reads `manager` back against `cfg` and reverts on the first difference.
    /// @dev Holders not named in `cfg` cannot be enumerated on-chain; an indexer checks them
    ///      from `RoleGranted` events. Pending grant-delay and target-admin-delay reductions
    ///      are invisible here (see the library notes).
    function verify(IAccessManager manager, Config memory cfg) internal view {
        validate(manager, cfg);
        for (uint64 role = 0; role < Roles.COUNT; ++role) {
            if (
                manager.getRoleAdmin(role) != Roles.ADMIN
                    || manager.getRoleGuardian(role)
                        != (role == Roles.ADMIN ? Roles.ADMIN : Roles.GUARDIAN)
                    || manager.getRoleGrantDelay(role) != Roles.grantDelay(role)
            ) revert RoleMismatch(role);
        }
        _verifyTarget(manager, address(manager));
        for (uint256 i = 0; i < cfg.targets.length; ++i) {
            Target memory target = cfg.targets[i];
            _verifyTarget(manager, target.target);
            for (uint256 j = 0; j < target.functions.length; ++j) {
                FunctionRole memory fn = target.functions[j];
                uint64 actual = manager.getTargetFunctionRole(target.target, fn.selector);
                if (actual != fn.role) {
                    revert FunctionRoleMismatch(target.target, fn.selector, actual);
                }
            }
        }
        for (uint256 i = 0; i < cfg.grants.length; ++i) {
            Grant memory grant = cfg.grants[i];
            _verifyHolder(manager, grant.role, grant.account);
            if (grant.role == Roles.GUARDIAN) {
                for (uint64 role = 0; role < Roles.COUNT; ++role) {
                    if (
                        role != Roles.GUARDIAN && role != Roles.PAUSER
                            && hasRecord(manager, role, grant.account)
                    ) revert GuardianHoldsRole(grant.account, role);
                }
            }
            if (grant.role == Roles.PAUSER && hasRecord(manager, Roles.UNPAUSER, grant.account)) {
                revert PauserIsUnpauser(grant.account);
            }
        }
    }

    /// @notice Whether `account` has any access record for `role`: a member, a member not yet
    ///         active, or one with a pending execution-delay change.
    function hasRecord(IAccessManager manager, uint64 role, address account)
        internal
        view
        returns (bool)
    {
        (uint48 since, uint32 current, uint32 pending, uint48 effect) =
            manager.getAccess(role, account);
        return since != 0 || current != 0 || pending != 0 || effect != 0;
    }

    function _validateGrants(Grant[] memory grants) private pure {
        uint256 guardians = 0;
        uint256 seen = 0; // one bit per role with at least one holder
        for (uint256 i = 0; i < grants.length; ++i) {
            Grant memory grant = grants[i];
            Roles.requireKnown(grant.role);
            if (grant.account == address(0)) revert InvalidGrant(grant.role, grant.account);
            for (uint256 j = 0; j < i; ++j) {
                if (grants[j].account != grant.account) continue;
                if (grants[j].role == grant.role) revert DuplicateGrant(grant.role, grant.account);
                _checkPair(grants[j].role, grant.role, grant.account);
            }
            if (grant.role == Roles.GUARDIAN) ++guardians;
            seen |= uint256(1) << grant.role;
        }
        if (guardians < MIN_GUARDIANS) revert TooFewGuardians(guardians);
        if (seen & (uint256(1) << Roles.ADMIN) == 0) revert MissingHolder(Roles.ADMIN);
        if (seen & (uint256(1) << Roles.PAUSER) == 0) revert MissingHolder(Roles.PAUSER);
        if (seen & (uint256(1) << Roles.UNPAUSER) == 0) revert MissingHolder(Roles.UNPAUSER);
    }

    /// @dev Veto stays separate from action: a guardian holds `GUARDIAN` and `PAUSER` only.
    function _checkPair(uint64 a, uint64 b, address account) private pure {
        if (a == Roles.GUARDIAN && b != Roles.PAUSER) revert GuardianHoldsRole(account, b);
        if (b == Roles.GUARDIAN && a != Roles.PAUSER) revert GuardianHoldsRole(account, a);
        if (
            (a == Roles.PAUSER && b == Roles.UNPAUSER) || (a == Roles.UNPAUSER && b == Roles.PAUSER)
        ) {
            revert PauserIsUnpauser(account);
        }
    }

    function _validateFunctions(address target, FunctionRole[] memory functions) private pure {
        for (uint256 i = 0; i < functions.length; ++i) {
            FunctionRole memory fn = functions[i];
            Roles.requireKnown(fn.role); // rejects PUBLIC too
            if (fn.role == Roles.ADMIN || fn.role == Roles.CURATION_SIGNER) {
                revert InvalidFunctionRole(target, fn.selector, fn.role);
            }
            for (uint256 j = 0; j < i; ++j) {
                if (functions[j].selector == fn.selector) {
                    revert DuplicateSelector(target, fn.selector);
                }
            }
        }
    }

    function _verifyTarget(IAccessManager manager, address target) private view {
        if (
            manager.isTargetClosed(target)
                || manager.getTargetAdminDelay(target) != TARGET_ADMIN_DELAY
        ) revert TargetMismatch(target);
    }

    function _verifyHolder(IAccessManager manager, uint64 role, address account) private view {
        (bool active, uint32 delay) = manager.hasRole(role, account);
        (uint48 since, uint32 current, uint32 pending, uint48 effect) =
            manager.getAccess(role, account);
        uint32 expected = Roles.executionDelay(role);
        if (
            !active || since == 0 || delay != expected || current != expected || pending != 0
                || effect != 0
        ) revert HolderMismatch(role, account);
    }
}
