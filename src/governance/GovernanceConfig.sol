// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAssetAllowlist } from "../economics/interfaces/IAssetAllowlist.sol";
import { FederationRegistry } from "../federated/FederationRegistry.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IStatementLog } from "../interfaces/IStatementLog.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { Roles } from "./Roles.sol";
import { WorksAccessManager } from "./WorksAccessManager.sol";

/// @title GovernanceConfig
/// @notice Validates, installs and reads back the 6529 Works `AccessManager` configuration.
///         A config names the network, the optional brake, the operational key holders and
///         the selector map; delays come from {Roles}, so a config cannot pick a wrong delay.
/// @dev `install` must run from the manager's installer (its constructor admin), which holds
///      every network role with no delay until it renounces: in production,
///      {GovernanceConfigurator} on the manager it deploys itself. It proposes the network with
///      `transferNetwork`; the network takes over when it calls `acceptNetwork`.
///
///      Genesis wiring: `install` also executes the genesis calls ({isGenesisSelector}: the
///      package registry's Stream bind and entropy module, sale targets, default currencies, the
///      ETH opening bid, the federation module's adapters, template versions and entropy module,
///      the epoch-0 manifest) as the zero-delay installer, before any selector is mapped. Every
///      wired selector therefore still resolves to `ADMIN`; without this phase those calls would
///      wait the network's 7-day class.
library GovernanceConfig {
    /// @notice One holder of one operational role. It acts with no delay.
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
        /// @dev The network: proposed at install, in charge once it accepts.
        address network;
        /// @dev The brake, or zero for none.
        address brake;
        Grant[] grants;
        Target[] targets;
    }

    /// @notice One genesis wiring call, executed by the installer as zero-delay `ADMIN`.
    struct Call {
        address target;
        bytes data;
    }

    /// @notice Maximum genesis wiring calls. The whole configuration is one transaction under
    ///         the EIP-7825 cap of 2^24 gas (`GenesisConfig.t.sol` gates it at 60%).
    uint256 internal constant MAX_WIRING_CALLS = 64;
    /// @notice {genesisInterface}'s answer for a selector any configured target may receive:
    ///         `0xffffffff`, which ERC-165 reserves as no interface.
    bytes4 internal constant ANY_TARGET = 0xffffffff;

    /// @notice The config names no network.
    error MissingNetwork();
    /// @notice A grant names a network role, an unknown role, the zero address or the
    ///         installer itself.
    error InvalidGrant(uint64 role, address account);
    /// @notice The same account appears twice for one role.
    error DuplicateGrant(uint64 role, address account);
    /// @notice A target is the manager, has no code, repeats, or is governed by another
    ///         authority.
    error InvalidTarget(address target);
    /// @notice A selector appears twice on one target (one selector, one class).
    error DuplicateSelector(address target, bytes4 selector);
    /// @notice A selector maps to a role that must not call governed functions.
    error InvalidFunctionRole(address target, bytes4 selector, uint64 role);
    /// @notice Readback: a role's admin, guardian or grant delay differs from the install.
    error RoleMismatch(uint64 role);
    /// @notice Readback: a holder is missing, not yet active, or has a delay or a pending one.
    error HolderMismatch(uint64 role, address account);
    /// @notice Readback: a target is closed.
    error TargetMismatch(address target);
    /// @notice Readback: a selector maps to a different role.
    error FunctionRoleMismatch(address target, bytes4 selector, uint64 actual);
    /// @notice Readback: the manager's network or brake differs from the config.
    error NetworkMismatch(address network, address brake);
    /// @notice More than {MAX_WIRING_CALLS} wiring calls.
    error TooManyWiringCalls(uint256 count);
    /// @notice A wiring call targets an address outside the configured targets (the manager
    ///         included) or carries no selector.
    error InvalidWiringCall(address target, bytes4 selector);
    /// @notice A wiring call's selector is not a genesis selector ({isGenesisSelector}), or its
    ///         target does not declare the interface the selector is admitted for
    ///         ({genesisInterface}).
    error WiringSelectorNotAllowed(address target, bytes4 selector);
    /// @notice Wiring call `index` reverted without a reason.
    error WiringCallFailed(uint256 index);

    /// @notice Reverts unless `cfg` names a network and satisfies the holder and selector
    ///         rules.
    function validate(IAccessManager manager, Config memory cfg) internal view {
        if (cfg.network == address(0)) revert MissingNetwork();
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

    /// @notice Whether `selector` may be wired at genesis: the package registry's one-shot
    ///         Stream bind and first entropy module, an edition auction's sale target, a
    ///         product's first default currency and the ETH opening bid, the federation
    ///         module's first configuration (its admitted sale contracts, its first template
    ///         versions and its entropy module: ADR 0008), or the epoch-0 governance manifest.
    ///         Modules and minters of the core are constructor arguments, so none is wired
    ///         here. Everything else waits its delay class after genesis.
    function isGenesisSelector(bytes4 selector) internal pure returns (bool) {
        return genesisInterface(selector) != 0;
    }

    /// @notice The ERC-165 interface a target must declare to receive genesis call `selector`,
    ///         so a selector admitted for one contract never reaches another contract's function
    ///         of the same selector. `ANY_TARGET` for selectors only one contract declares (the
    ///         asset allowlist's and the statement log's, which implement no ERC-165); zero for
    ///         any other selector.
    function genesisInterface(bytes4 selector) internal pure returns (bytes4) {
        if (selector == ISaleAdapter.setTarget.selector) return type(ISaleAdapter).interfaceId;
        if (
            selector == FederationRegistry.setAdapter.selector
                || selector == FederationRegistry.approveTemplate.selector
                || selector == FederationRegistry.setEntropyModule.selector
        ) return type(IFederationRegistry).interfaceId;
        if (
            selector == IPackageRegistry.bindStream.selector
                || selector == IPackageRegistry.setEntropyModule.selector
        ) return type(IPackageRegistry).interfaceId;
        if (
            selector == IAssetAllowlist.setDefaultCurrency.selector
                || selector == IAssetAllowlist.setOpeningBid.selector
                || selector == IStatementLog.appendGovernanceManifest.selector
        ) return ANY_TARGET;
        return 0;
    }

    /// @notice Reverts unless there are at most {MAX_WIRING_CALLS} wiring calls, each on a
    ///         configured target with a genesis selector that target declares the interface for
    ///         ({genesisInterface}; the probe forwards all gas, and a shortfall reverts).
    function validateWiring(Config memory cfg, Call[] memory wiring) internal view {
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
            bytes4 iface = genesisInterface(selector);
            if (
                iface == 0 || (iface != ANY_TARGET && !BoundedCall.supportsInterface(target, iface))
            ) revert WiringSelectorNotAllowed(target, selector);
        }
    }

    /// @notice Applies `cfg` to a freshly deployed manager whose installer is the caller:
    ///         labels the roles, makes the network (no delay) the admin of every operational
    ///         role, executes `wiring` before mapping any selector, maps the selectors, grants
    ///         the operational keys with no delay, sets the brake and proposes the network.
    /// @dev The caller still holds its installer record afterwards and must renounce it. A
    ///      reverting wiring call reverts the whole installation with the callee's error.
    function install(WorksAccessManager manager, Config memory cfg, Call[] memory wiring) internal {
        validate(manager, cfg);
        validateWiring(cfg, wiring);
        for (uint64 role = 1; role < Roles.COUNT; ++role) {
            if (!Roles.isKnown(role)) continue;
            manager.labelRole(role, Roles.label(role));
            if (!Roles.isNetworkRole(role)) manager.setRoleAdmin(role, Roles.NETWORK);
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
            manager.grantRole(grant.role, grant.account, 0);
        }
        if (cfg.brake != address(0)) manager.setBrake(cfg.brake);
        manager.transferNetwork(cfg.network);
    }

    /// @notice Reads `manager` back against `cfg` and reverts on the first difference. Run it
    ///         after the network accepted.
    /// @dev Holders not named in `cfg` cannot be enumerated on-chain; an indexer checks them
    ///      from `RoleGranted` events.
    function verify(WorksAccessManager manager, Config memory cfg) internal view {
        validate(manager, cfg);
        if (manager.network() != cfg.network || manager.brake() != cfg.brake) {
            revert NetworkMismatch(manager.network(), manager.brake());
        }
        for (uint64 role = 0; role < Roles.COUNT; ++role) {
            if (!Roles.isKnown(role)) continue;
            uint64 admin = Roles.isNetworkRole(role) ? Roles.ADMIN : Roles.NETWORK;
            if (
                manager.getRoleAdmin(role) != admin || manager.getRoleGuardian(role) != Roles.ADMIN
                    || manager.getRoleGrantDelay(role) != 0
            ) revert RoleMismatch(role);
        }
        for (uint256 i = 0; i < cfg.targets.length; ++i) {
            Target memory target = cfg.targets[i];
            if (manager.isTargetClosed(target.target)) revert TargetMismatch(target.target);
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
            (bool active, uint32 delay) = manager.hasRole(grant.role, grant.account);
            (, uint32 current, uint32 pending, uint48 effect) =
                manager.getAccess(grant.role, grant.account);
            if (!active || delay != 0 || current != 0 || pending != 0 || effect != 0) {
                revert HolderMismatch(grant.role, grant.account);
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
        for (uint256 i = 0; i < grants.length; ++i) {
            Grant memory grant = grants[i];
            if (
                !Roles.isKnown(grant.role) || Roles.isNetworkRole(grant.role)
                    || grant.account == address(0)
            ) revert InvalidGrant(grant.role, grant.account);
            for (uint256 j = 0; j < i; ++j) {
                if (grants[j].account == grant.account && grants[j].role == grant.role) {
                    revert DuplicateGrant(grant.role, grant.account);
                }
            }
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
}
