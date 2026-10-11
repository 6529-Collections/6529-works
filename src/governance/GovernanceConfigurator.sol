// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { GovernanceConfig } from "./GovernanceConfig.sol";
import { Roles } from "./Roles.sol";

/// @title GovernanceConfigurator
/// @notice One-shot installer: deploy it, deploy `WorksAccessManager(address(configurator))`,
///         then call {configure}. The whole configuration lands in one transaction and the
///         configurator renounces the admin role at the end, so no deployer key keeps power.
/// @dev Only the deployer may call {configure}, so a front-runner cannot install its own
///      holders on a manager that names this contract as initial admin.
contract GovernanceConfigurator {
    /// @notice The account allowed to call {configure}.
    address public immutable deployer;

    /// @notice A configuration epoch was installed on `manager`.
    /// @param manager The configured `AccessManager`.
    /// @param configHash `keccak256(abi.encode(cfg))` of the installed configuration.
    /// @param manifestHash Hash of the signed JSON governance manifest for this epoch.
    event GovernanceConfigured(
        address indexed manager, bytes32 indexed configHash, bytes32 indexed manifestHash
    );

    /// @notice The caller is not the deployer.
    error NotDeployer(address caller);
    /// @notice The configurator still holds the admin role on `manager`.
    error ConfiguratorStillAdmin(address manager);

    constructor() {
        deployer = msg.sender;
    }

    /// @notice Installs `cfg` on `manager`, renounces this contract's admin role and emits the
    ///         epoch's configuration and manifest hashes.
    /// @param manager A fresh manager whose only admin is this contract.
    /// @param cfg Holders and target selector mappings; delays come from {Roles}.
    /// @param manifestHash Hash of the signed governance manifest describing `cfg`.
    function configure(
        IAccessManager manager,
        GovernanceConfig.Config calldata cfg,
        bytes32 manifestHash
    ) external {
        if (msg.sender != deployer) {
            revert NotDeployer(msg.sender);
        }
        GovernanceConfig.install(manager, cfg);
        manager.renounceRole(Roles.ADMIN, address(this));
        emit GovernanceConfigured(address(manager), keccak256(abi.encode(cfg)), manifestHash);
    }

    /// @notice Reverts unless `manager` matches `cfg` and this contract holds no admin role.
    /// @dev For CI readback by `eth_call`, at least `minSetback()` after {configure}.
    function verify(IAccessManager manager, GovernanceConfig.Config calldata cfg) external view {
        (uint48 since,,,) = manager.getAccess(Roles.ADMIN, address(this));
        if (since != 0) revert ConfiguratorStillAdmin(address(manager));
        GovernanceConfig.verify(manager, cfg);
    }
}
