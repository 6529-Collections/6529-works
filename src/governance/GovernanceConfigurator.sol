// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { GovernanceConfig } from "./GovernanceConfig.sol";
import { Roles } from "./Roles.sol";
import { WorksAccessManager } from "./WorksAccessManager.sol";

/// @title GovernanceConfigurator
/// @notice One-shot installer that owns its manager: the constructor deploys
///         `WorksAccessManager(address(this))`, so the manager's code is the hardened one and
///         its only initial admin is this contract. Deploy it, deploy every target with
///         `authority = worksManager()`, then call {configure}. The whole configuration,
///         including the genesis wiring calls (one-shot binds, admitted minters), lands in one
///         transaction and this contract renounces the admin role at the end.
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
    /// @notice The configurator still holds the admin role on its manager.
    error ConfiguratorStillAdmin();

    /// @param deployer_ The only account that may call {configure}, normally the operator
    ///        broadcasting the genesis deployment.
    constructor(address deployer_) {
        if (deployer_ == address(0)) revert InvalidDeployer();
        deployer = deployer_;
        worksManager = new WorksAccessManager(address(this));
    }

    /// @notice Installs `cfg` on {worksManager}, executes the genesis `wiring` as zero-delay
    ///         admin, renounces this contract's admin role and emits the epoch's hashes.
    /// @param cfg Holders and target selector mappings; delays come from {Roles}.
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
