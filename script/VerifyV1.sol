// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AuthorityUtils } from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Roles } from "src/governance/Roles.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IDutchSale } from "src/interfaces/IDutchSale.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { DeployV1 } from "./DeployV1.sol";

/// @title VerifyV1
/// @notice Reads a deployed system back against its genesis configuration and wiring. Static
///         checks only, so the integration tests can run them; `script/Verify.s.sol` adds the
///         event checks that need an RPC (hashes, pending delay reductions, role grants).
library VerifyV1 {
    error ConfiguratorHoldsRole(uint64 role);
    error WrongAuthority(address target, address authority);
    error WiringNotApplied(address target, bytes4 selector);
    error UnknownWiringSelector(bytes4 selector);
    error PlatformPathClosed(address target, bytes4 selector);
    error PlatformHolderMissing();

    /// @notice Reverts on the first difference between the deployment and `cfg` / `calls`.
    /// @dev Run at least `minSetback()` after genesis, when grant and target-admin delays are
    ///      effective (`GovernanceConfigurator.verify`).
    function check(
        DeployV1.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        GovernanceConfig.Call[] memory calls
    ) internal view {
        // Roles, delays, holders and selectors; the configurator renounced ADMIN.
        d.configurator.verify(cfg);
        for (uint64 role; role < Roles.COUNT; ++role) {
            if (GovernanceConfig.hasRecord(d.manager, role, address(d.configurator))) {
                revert ConfiguratorHoldsRole(role);
            }
        }
        // Every configured target answers to this manager.
        for (uint256 i; i < cfg.targets.length; ++i) {
            address authority = IAccessManaged(cfg.targets[i].target).authority();
            if (authority != address(d.manager)) {
                revert WrongAuthority(cfg.targets[i].target, authority);
            }
        }
        // Every wiring call left its mark.
        for (uint256 i; i < calls.length; ++i) {
            checkWired(d, calls[i]);
        }
        checkPlatformPath(d, cfg);
    }

    /// @notice Reverts unless the wired getter reflects `call`.
    function checkWired(DeployV1.Deployment memory d, GovernanceConfig.Call memory call)
        internal
        view
    {
        bytes memory data = call.data;
        // Casting to bytes4 is safe: it keeps the selector, the first four bytes.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = bytes4(data);
        address target = call.target;
        bool ok;
        if (selector == IStatementLog.appendGovernanceManifest.selector) {
            (uint64 count,) = IStatementLog(target).chainOf(address(d.manager), 0);
            ok = count != 0;
        } else {
            address arg;
            bool flag;
            assembly ("memory-safe") {
                arg := mload(add(data, 36))
                flag := mload(add(data, 68))
            }
            if (selector == IStream.bindWorkRecords.selector) {
                ok = _getter(target, "workRecords()") == arg;
            } else if (selector == IStream.bindEditions.selector) {
                ok = _getter(target, "editions()") == arg;
            } else if (selector == IPackageRegistry.bindStream.selector) {
                ok = _getter(target, "stream()") == arg;
            } else if (selector == IArtistRegistry.bindPackageRegistry.selector) {
                ok = _getter(target, "packageRegistry()") == arg;
            } else if (selector == IArtistRegistry.bindSplitFactory.selector) {
                ok = _getter(target, "splitFactory()") == arg;
            } else if (selector == IArtistRegistry.bindFederationRegistry.selector) {
                ok = _getter(target, "federationRegistry()") == arg;
            } else if (selector == IMintTarget.setAdmittedMinter.selector) {
                ok = IMintTarget(target).isAdmittedMinter(arg) == flag;
            } else if (selector == ISaleAdapter.setTarget.selector) {
                ok = ISaleAdapter(target).isTarget(arg) == flag;
            } else {
                revert UnknownWiringSelector(selector);
            }
        }
        if (!ok) revert WiringNotApplied(target, selector);
    }

    /// @notice PLATFORM reaches `openSale`, `closeSale` and `addLocator` through each
    ///         implementation's own `canCall` check (the creator or artist path needs no role):
    ///         the configured PLATFORM holder must get an immediate answer, as the
    ///         implementation asks it.
    function checkPlatformPath(DeployV1.Deployment memory d, GovernanceConfig.Config memory cfg)
        internal
        view
    {
        address platform;
        for (uint256 i; i < cfg.grants.length; ++i) {
            if (cfg.grants[i].role == Roles.PLATFORM) platform = cfg.grants[i].account;
        }
        if (platform == address(0)) revert PlatformHolderMissing();
        _platformCan(d, platform, address(d.fixedPriceSale), IFixedPriceSale.openSale.selector);
        _platformCan(d, platform, address(d.fixedPriceSale), IFixedPriceSale.closeSale.selector);
        _platformCan(d, platform, address(d.dutchSale), IDutchSale.openSale.selector);
        _platformCan(d, platform, address(d.dutchSale), IDutchSale.closeSale.selector);
        _platformCan(d, platform, d.workRecords, IWorkRecords.addLocator.selector);
    }

    function _platformCan(
        DeployV1.Deployment memory d,
        address platform,
        address target,
        bytes4 selector
    ) private view {
        if (target == address(0)) return; // pending lane
        (bool immediate,) =
            AuthorityUtils.canCallWithDelay(address(d.manager), platform, target, selector);
        if (!immediate) revert PlatformPathClosed(target, selector);
    }

    function _getter(address target, string memory signature) private view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }
}
