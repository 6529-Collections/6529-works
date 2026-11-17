// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { GovernanceConfig } from "./GovernanceConfig.sol";
import { Roles } from "./Roles.sol";
import { WorksAccessManager } from "./WorksAccessManager.sol";

/// @title GovernanceConfigurator
/// @notice One-shot installer that owns its manager: the constructor deploys
///         `WorksAccessManager(address(this))`, so the manager's code is the 6529 one and its
///         only installer is this contract. Deploy it, deploy every target with
///         `authority = worksManager()`, then call {configure}. The whole configuration,
///         including the genesis wiring calls (one-shot binds, admitted minters), lands in one
///         transaction; it proposes the network and renounces the installer record at the end.
///         The network then calls `acceptNetwork` on the manager.
/// @dev Only `deployer`, a constructor argument, may call {configure}, so a front-runner
///      cannot install its own holders. Taking it as an argument rather than `msg.sender`
///      lets the configurator be deployed through a CREATE2 factory, so its address, and its
///      manager's (`CREATE` nonce 1 of the configurator), can be predicted. Anyone can deploy
///      a configurator naming any deployer, but it only ever governs the new manager it
///      creates itself: it can never touch another manager, the real one included. No other
///      manager can be configured or verified through this contract.
contract GovernanceConfigurator {
    /// @notice The account allowed to call {configure}.
    address public immutable deployer;
    /// @notice The manager this configurator deployed and configures.
    WorksAccessManager public immutable worksManager;

    /// @notice A configuration epoch was installed on `manager`.
    /// @param manager The configured `WorksAccessManager`.
    /// @param configHash `keccak256(abi.encode(cfg))` of the installed configuration.
    /// @param manifestHash Hash of the signed JSON governance manifest for this epoch.
    /// @param wiringHash `keccak256(abi.encode(wiring))` of the genesis wiring calls.
    event GovernanceConfigured(
        address indexed manager,
        bytes32 indexed configHash,
        bytes32 indexed manifestHash,
        bytes32 wiringHash
    );

    /// @notice The caller is not the deployer.
    error NotDeployer(address caller);
    /// @notice The deployer argument is the zero address.
    error InvalidDeployer();
    /// @notice The configurator still holds its installer record on its manager.
    error ConfiguratorStillAdmin();

    /// @param deployer_ The only account that may call {configure}, normally the operator
    ///        broadcasting the genesis deployment.
    constructor(address deployer_) {
        if (deployer_ == address(0)) revert InvalidDeployer();
        deployer = deployer_;
        worksManager = new WorksAccessManager(address(this));
    }

    /// @notice Installs `cfg` on {worksManager}, executes the genesis `wiring` as the
    ///         zero-delay installer, proposes `cfg.network`, renounces this contract's installer
    ///         record and emits the epoch's hashes.
    /// @param cfg The network, the brake, the operational holders and the selector map; delays
    ///        come from {Roles}.
    /// @param manifestHash Hash of the signed governance manifest describing `cfg`.
    /// @param wiring Genesis calls on configured targets, at most
    ///        `GovernanceConfig.MAX_WIRING_CALLS`, each with a genesis selector
    ///        (`GovernanceConfig.isGenesisSelector`); any revert aborts the whole configuration.
    function configure(
        GovernanceConfig.Config calldata cfg,
        bytes32 manifestHash,
        GovernanceConfig.Call[] calldata wiring
    ) external {
        if (msg.sender != deployer) revert NotDeployer(msg.sender);
        GovernanceConfig.install(worksManager, cfg, wiring);
        worksManager.renounceRole(Roles.ADMIN, address(this));
        emit GovernanceConfigured(
            address(worksManager),
            keccak256(abi.encode(cfg)),
            manifestHash,
            keccak256(abi.encode(wiring))
        );
    }

    /// @notice Reverts unless {worksManager} matches `cfg`: this contract holds no installer
    ///         record, the network and brake are the configured ones (so the network has
    ///         accepted), and every role, holder and selector reads back as configured.
    /// @dev For CI readback by `eth_call` after the network accepted. Because this contract
    ///      deployed the manager and was its only installer, every other holder comes from a
    ///      configured grant or a later grant by the network, which an indexer sees as a
    ///      `RoleGranted` event.
    /// @param cfg The expected configuration, as passed to {configure}.
    function verify(GovernanceConfig.Config calldata cfg) external view {
        if (GovernanceConfig.hasRecord(worksManager, Roles.ADMIN, address(this))) {
            revert ConfiguratorStillAdmin();
        }
        GovernanceConfig.verify(worksManager, cfg);
    }
}
