// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAssetAllowlist } from "../economics/interfaces/IAssetAllowlist.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IStatementLog } from "../interfaces/IStatementLog.sol";
import { IStream } from "../interfaces/IStream.sol";
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
///
///      Genesis wiring: `install` also executes the genesis calls ({isGenesisSelector}: one-shot
///      binds, admitted minters, sale targets, the epoch-0 manifest) as the zero-delay
///      installer, after the roles and target admin delays are set and before any selector is
///      mapped. Every wired selector therefore still resolves to `ADMIN`; without this phase
///      those calls would wait the admins' 30-day delay.
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

    /// @notice One genesis wiring call, executed by the installer as zero-delay `ADMIN`.
    struct Call {
        address target;
        bytes data;
    }

    /// @notice Minimum number of distinct veto guardians (ADR 0001 §13.3). Deployments use
    ///         at least three, because safety needs two honest guardians online at all times.
    uint256 internal constant MIN_GUARDIANS = 2;
    /// @notice Admin delay of every target, the manager included (ADR 0001 §13.1).
    uint32 internal constant TARGET_ADMIN_DELAY = Roles.SUCCESSOR;
    /// @notice Maximum genesis wiring calls. The whole configuration is one transaction under
    ///         the EIP-7825 cap of 2^24 gas: the example genesis configuration plus this many
    ///         ERC-165-checking calls on cold accounts measures about 6.6M gas, 39% of the cap,
    ///         including worst-case calldata (`GenesisConfig.t.sol` gates it at 60%).
    uint256 internal constant MAX_WIRING_CALLS = 64;

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
    /// @notice More than {MAX_WIRING_CALLS} wiring calls.
    error TooManyWiringCalls(uint256 count);
    /// @notice A wiring call targets an address outside the configured targets (the manager
    ///         included) or carries no selector.
    error InvalidWiringCall(address target, bytes4 selector);
    /// @notice A wiring call's selector is not a genesis selector ({isGenesisSelector}).
    error WiringSelectorNotAllowed(address target, bytes4 selector);
    /// @notice Wiring call `index` reverted without a reason.
    error WiringCallFailed(uint256 index);

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

    /// @notice Whether `selector` may be wired at genesis: a one-shot bind (including the
    ///         v1.1 federation bind), an admitted-minter grant, a sale target, a product's
    ///         first default currency (an auction cannot start without one), or the epoch-0
    ///         governance manifest. Everything else waits its delay class after genesis.
    function isGenesisSelector(bytes4 selector) internal pure returns (bool) {
        return selector == IStream.bindWorkRecords.selector
            || selector == IStream.bindEditions.selector
            || selector == IPackageRegistry.bindStream.selector
            || selector == IArtistRegistry.bindPackageRegistry.selector
            || selector == IArtistRegistry.bindSplitFactory.selector
            || selector == IArtistRegistry.bindFederationRegistry.selector
            || selector == IArtistRegistry.bindStatementLog.selector
            || selector == IMintTarget.setAdmittedMinter.selector
            || selector == ISaleAdapter.setTarget.selector
            || selector == IAssetAllowlist.setDefaultCurrency.selector
            || selector == IStatementLog.appendGovernanceManifest.selector;
    }

    /// @notice Reverts unless there are at most {MAX_WIRING_CALLS} wiring calls, each on a
    ///         configured target with a genesis selector.
    function validateWiring(Config memory cfg, Call[] memory wiring) internal pure {
        if (wiring.length > MAX_WIRING_CALLS) revert TooManyWiringCalls(wiring.length);
        for (uint256 i = 0; i < wiring.length; ++i) {
            address target = wiring[i].target;
            bytes memory data = wiring[i].data;
            // Casting to bytes4 is safe: it keeps the selector, the first four bytes.
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes4 selector = data.length < 4 ? bytes4(0) : bytes4(data);
            if (data.length < 4 || !_isTarget(cfg, target)) {
                revert InvalidWiringCall(target, selector);
            }
            if (!isGenesisSelector(selector)) revert WiringSelectorNotAllowed(target, selector);
        }
    }

    /// @notice Applies `cfg` to a freshly deployed manager whose sole admin is the caller, and
    ///         executes `wiring` as that zero-delay admin before mapping any selector.
    /// @dev The caller still holds `ADMIN` afterwards and must renounce it. A reverting wiring
    ///      call reverts the whole installation with the callee's error.
    function install(IAccessManager manager, Config memory cfg, Call[] memory wiring) internal {
        validate(manager, cfg);
        validateWiring(cfg, wiring);
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
        }

        for (uint256 i = 0; i < wiring.length; ++i) {
            (bool ok, bytes memory reason) = wiring[i].target.call(wiring[i].data);
            if (!ok) {
                if (reason.length == 0) revert WiringCallFailed(i);
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }

        for (uint256 i = 0; i < cfg.targets.length; ++i) {
            Target memory target = cfg.targets[i];
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

    function _isTarget(Config memory cfg, address account) private pure returns (bool) {
        for (uint256 i = 0; i < cfg.targets.length; ++i) {
            if (cfg.targets[i].target == account) return true;
        }
        return false;
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
