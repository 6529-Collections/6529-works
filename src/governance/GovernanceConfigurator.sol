// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { GovernanceConfig } from "./GovernanceConfig.sol";
import { Roles } from "./Roles.sol";
import { WorksAccessManager } from "./WorksAccessManager.sol";

/// @title GovernanceConfigurator
/// @notice One-shot installer that owns its manager: the constructor deploys
///         `WorksAccessManager(address(this))`, so the manager's code is the hardened one and
///         its only initial admin is this contract. Deploy it, deploy every target with
///         `authority = worksManager()`, then call {configure}. The whole configuration lands
///         in one transaction and this contract renounces the admin role at the end.
/// @dev Only the deployer may call {configure}, so a front-runner cannot install its own
///      holders. No other manager can be configured or verified through this contract.
contract GovernanceConfigurator {
    /// @notice The account allowed to call {configure}.
    address public immutable deployer;
    /// @notice The manager this configurator deployed and configures.
    WorksAccessManager public immutable worksManager;

    /// @notice A configuration epoch was installed on `manager`.
    /// @param manager The configured `WorksAccessManager`.
    /// @param configHash `keccak256(abi.encode(cfg))` of the installed configuration.
    /// @param manifestHash Hash of the signed JSON governance manifest for this epoch.
    event GovernanceConfigured(
        address indexed manager, bytes32 indexed configHash, bytes32 indexed manifestHash
    );

    /// @notice The caller is not the deployer.
    error NotDeployer(address caller);
    /// @notice The configurator still holds the admin role on its manager.
    error ConfiguratorStillAdmin();

    constructor() {
        deployer = msg.sender;
        worksManager = new WorksAccessManager(address(this));
    }

    /// @notice Installs `cfg` on {worksManager}, renounces this contract's admin role and
    ///         emits the epoch's configuration and manifest hashes.
    /// @param cfg Holders and target selector mappings; delays come from {Roles}.
    /// @param manifestHash Hash of the signed governance manifest describing `cfg`.
    function configure(GovernanceConfig.Config calldata cfg, bytes32 manifestHash) external {
        if (msg.sender != deployer) revert NotDeployer(msg.sender);
        GovernanceConfig.install(worksManager, cfg);
        worksManager.renounceRole(Roles.ADMIN, address(this));
        emit GovernanceConfigured(address(worksManager), keccak256(abi.encode(cfg)), manifestHash);
    }

    /// @notice Reverts unless {worksManager} matches `cfg`: this contract holds no admin role,
    ///         every configured admin carries the full 30-day delay with nothing pending, and
    ///         every other role, holder and selector reads back as configured.
    /// @dev For CI readback by `eth_call`, at least `minSetback()` after {configure}. Because
    ///      this contract deployed the manager and was its only initial admin, any other admin
    ///      can only come from a configured grant or a later 30-day, guardian-vetoable grant,
    ///      which an indexer sees as a `RoleGranted` event.
    function verify(GovernanceConfig.Config calldata cfg) external view {
        if (GovernanceConfig.hasRecord(worksManager, Roles.ADMIN, address(this))) {
            revert ConfiguratorStillAdmin();
        }
        GovernanceConfig.verify(worksManager, cfg);
    }
}
