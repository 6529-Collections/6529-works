// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "./Roles.sol";

/// @title GovernanceConfig
/// @notice Validates, installs and reads back the 6529 Works `AccessManager` configuration
///         (ADR 0001 §13). Delays, role admins and role guardians come from {Roles}; a config
///         only names holders and maps target selectors, so it cannot pick a wrong delay.
/// @dev `install` must run from the manager's sole admin with no execution delay, normally
///      {GovernanceConfigurator}. Grant and target-admin delays become effective after the
///      manager's `minSetback()` (5 days); until then every admin action still waits the
///      admin's 30-day execution delay. `verify` reads effective values, so CI readback runs
///      after that window.
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

    /// @notice Minimum number of distinct veto guardians (ADR 0001 §13.3).
    uint256 internal constant MIN_GUARDIANS = 2;
    /// @notice Admin delay of every target, the manager included (ADR 0001 §13.1).
    uint32 internal constant TARGET_ADMIN_DELAY = Roles.SUCCESSOR;

    /// @notice Fewer than {MIN_GUARDIANS} guardian grants.
    error TooFewGuardians(uint256 count);
    /// @notice A required role has no holder.
    error MissingHolder(uint64 role);
    /// @notice A grant names the zero address, the installer, or the implicit `META` role.
    error InvalidGrant(uint64 role, address account);
    /// @notice The same account appears twice for one role.
    error DuplicateGrant(uint64 role, address account);
    /// @notice A guardian also holds, or is pending for, a role that schedules operations.
    error GuardianIsProposer(address account, uint64 role);
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

    /// @notice The manager's own admin-restricted selectors, all mapped to `Roles.META`.
    function managerAdminSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IAccessManager.labelRole.selector;
        selectors[1] = IAccessManager.grantRole.selector;
        selectors[2] = IAccessManager.revokeRole.selector;
        selectors[3] = IAccessManager.setRoleAdmin.selector;
        selectors[4] = IAccessManager.setRoleGuardian.selector;
        selectors[5] = IAccessManager.setGrantDelay.selector;
        selectors[6] = IAccessManager.setTargetFunctionRole.selector;
        selectors[7] = IAccessManager.setTargetAdminDelay.selector;
        selectors[8] = IAccessManager.setTargetClosed.selector;
        selectors[9] = IAccessManager.updateAuthority.selector;
    }

    /// @notice Reverts unless `cfg` satisfies the guardian, holder and selector rules.
    function validate(IAccessManager manager, Config memory cfg) internal view {
        _validateGrants(cfg.grants);
        Target[] memory targets = cfg.targets;
        for (uint256 i; i < targets.length; ++i) {
            address target = targets[i].target;
            if (target == address(manager) || target.code.length == 0) {
                revert InvalidTarget(target);
            }
            for (uint256 j; j < i; ++j) {
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
        manager.setTargetFunctionRole(address(manager), managerAdminSelectors(), Roles.META);
        manager.setTargetAdminDelay(address(manager), TARGET_ADMIN_DELAY);

        for (uint256 i; i < cfg.targets.length; ++i) {
            Target memory target = cfg.targets[i];
            manager.setTargetAdminDelay(target.target, TARGET_ADMIN_DELAY);
            bytes4[] memory one = new bytes4[](1);
            for (uint256 j; j < target.functions.length; ++j) {
                one[0] = target.functions[j].selector;
                manager.setTargetFunctionRole(target.target, one, target.functions[j].role);
            }
        }

        for (uint256 i; i < cfg.grants.length; ++i) {
            Grant memory grant = cfg.grants[i];
            if (grant.account == address(this)) revert InvalidGrant(grant.role, grant.account);
            manager.grantRole(grant.role, grant.account, Roles.executionDelay(grant.role));
            if (grant.role == Roles.ADMIN) {
                manager.grantRole(Roles.META, grant.account, Roles.executionDelay(Roles.META));
            }
        }
    }

    /// @notice Reads `manager` back against `cfg` and reverts on the first difference.
    /// @dev Holders not named in `cfg` cannot be enumerated on-chain; an indexer checks them
    ///      from `RoleGranted` events.
    function verify(IAccessManager manager, Config memory cfg) internal view {
        validate(manager, cfg);
        for (uint64 role; role < Roles.COUNT; ++role) {
            if (
                manager.getRoleAdmin(role) != Roles.ADMIN
                    || manager.getRoleGuardian(role)
                        != (role == Roles.ADMIN ? Roles.ADMIN : Roles.GUARDIAN)
                    || manager.getRoleGrantDelay(role) != Roles.grantDelay(role)
            ) revert RoleMismatch(role);
        }
        _verifyTarget(manager, address(manager));
        bytes4[] memory own = managerAdminSelectors();
        for (uint256 i; i < own.length; ++i) {
            _verifyFunction(manager, address(manager), FunctionRole(own[i], Roles.META));
        }
        for (uint256 i; i < cfg.targets.length; ++i) {
            Target memory target = cfg.targets[i];
            _verifyTarget(manager, target.target);
            for (uint256 j; j < target.functions.length; ++j) {
                _verifyFunction(manager, target.target, target.functions[j]);
            }
        }
        for (uint256 i; i < cfg.grants.length; ++i) {
            Grant memory grant = cfg.grants[i];
            _verifyHolder(manager, grant.role, grant.account);
            if (grant.role == Roles.ADMIN) _verifyHolder(manager, Roles.META, grant.account);
            if (grant.role == Roles.GUARDIAN) {
                for (uint64 role; role < Roles.COUNT; ++role) {
                    if (Roles.isProposer(role) && _isOrWillBe(manager, role, grant.account)) {
                        revert GuardianIsProposer(grant.account, role);
                    }
                }
            }
            if (grant.role == Roles.PAUSER && _isOrWillBe(manager, Roles.UNPAUSER, grant.account)) {
                revert PauserIsUnpauser(grant.account);
            }
        }
    }

    function _validateGrants(Grant[] memory grants) private pure {
        uint256 guardians;
        uint256 required; // bit per required role seen: ADMIN, PAUSER, UNPAUSER
        for (uint256 i; i < grants.length; ++i) {
            Grant memory grant = grants[i];
            Roles.executionDelay(grant.role); // rejects unknown roles
            if (grant.account == address(0) || grant.role == Roles.META) {
                revert InvalidGrant(grant.role, grant.account);
            }
            for (uint256 j; j < i; ++j) {
                if (grants[j].account != grant.account) continue;
                if (grants[j].role == grant.role) revert DuplicateGrant(grant.role, grant.account);
                _checkPair(grants[j].role, grant.role, grant.account);
            }
            if (grant.role == Roles.GUARDIAN) ++guardians;
            required |= uint256(1) << grant.role;
        }
        if (guardians < MIN_GUARDIANS) revert TooFewGuardians(guardians);
        if (required & (uint256(1) << Roles.ADMIN) == 0) revert MissingHolder(Roles.ADMIN);
        if (required & (uint256(1) << Roles.PAUSER) == 0) revert MissingHolder(Roles.PAUSER);
        if (required & (uint256(1) << Roles.UNPAUSER) == 0) revert MissingHolder(Roles.UNPAUSER);
    }

    function _checkPair(uint64 a, uint64 b, address account) private pure {
        if (a == Roles.GUARDIAN && Roles.isProposer(b)) revert GuardianIsProposer(account, b);
        if (b == Roles.GUARDIAN && Roles.isProposer(a)) revert GuardianIsProposer(account, a);
        if (
            (a == Roles.PAUSER && b == Roles.UNPAUSER) || (a == Roles.UNPAUSER && b == Roles.PAUSER)
        ) {
            revert PauserIsUnpauser(account);
        }
    }

    function _validateFunctions(address target, FunctionRole[] memory functions) private pure {
        for (uint256 i; i < functions.length; ++i) {
            FunctionRole memory fn = functions[i];
            Roles.executionDelay(fn.role); // rejects unknown roles, PUBLIC included
            if (fn.role == Roles.ADMIN || fn.role == Roles.META || fn.role == Roles.CURATION_SIGNER)
            {
                revert InvalidFunctionRole(target, fn.selector, fn.role);
            }
            for (uint256 j; j < i; ++j) {
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

    function _verifyFunction(IAccessManager manager, address target, FunctionRole memory fn)
        private
        view
    {
        uint64 actual = manager.getTargetFunctionRole(target, fn.selector);
        if (actual != fn.role) revert FunctionRoleMismatch(target, fn.selector, actual);
    }

    function _verifyHolder(IAccessManager manager, uint64 role, address account) private view {
        (bool active, uint32 delay) = manager.hasRole(role, account);
        (,,, uint48 effect) = manager.getAccess(role, account);
        if (!active || delay != Roles.executionDelay(role) || effect != 0) {
            revert HolderMismatch(role, account);
        }
    }

    function _isOrWillBe(IAccessManager manager, uint64 role, address account)
        private
        view
        returns (bool)
    {
        (uint48 since,,,) = manager.getAccess(role, account);
        return since != 0;
    }
}
