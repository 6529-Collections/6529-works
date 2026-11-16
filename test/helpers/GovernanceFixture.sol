// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Roles } from "src/governance/Roles.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { GovernedTargetMock } from "../mocks/governance/GovernanceMocks.sol";

/// @notice Deploys and configures a `WorksAccessManager` the way a deploy script must: one
///         network, one brake, operational keys. Offers schedule and execute helpers. Other
///         lanes can inherit it to put their own targets under governance in tests.
abstract contract GovernanceFixture is Test {
    bytes32 internal constant MANIFEST = keccak256("6529 Works governance manifest, test epoch");

    /// @dev The network: the one holder of every network role.
    address internal adminSafe = makeAddr("networkSafe");
    /// @dev The brake.
    address internal brakeSafe = makeAddr("brakeSafe");
    /// @dev Holders of the operational `PAUSER` key.
    address internal guardianA = makeAddr("pauserA");
    address internal guardianB = makeAddr("pauserB");
    address internal guardianC = makeAddr("pauserC");
    address internal curationSigner = makeAddr("curationSigner");
    address internal curationSigner2 = makeAddr("curationSigner2");
    address internal storageOperator = makeAddr("storageOperator");
    address internal keeper = makeAddr("keeper");
    address internal platform = makeAddr("platform");
    address internal curator = makeAddr("curator");
    address internal outsider = makeAddr("outsider");
    address internal attacker = makeAddr("attacker");
    address internal recipient0 = makeAddr("recipient0");
    address internal verifier0 = makeAddr("verifier0");

    GovernanceConfigurator internal configurator;
    WorksAccessManager internal manager;
    GovernedTargetMock internal target;

    /// @dev Deploys the configurator (which deploys the manager) and the sample target.
    function _deployUnconfigured() internal {
        configurator = new GovernanceConfigurator(address(this));
        manager = configurator.worksManager();
        target = new GovernedTargetMock(address(manager), recipient0, verifier0);
    }

    /// @dev Deploys, configures with the default layout, and has the network accept.
    function _deployGovernance() internal {
        _deployUnconfigured();
        configurator.configure(_config(), MANIFEST, _noWiring());
        _accept();
    }

    /// @dev The proposed network takes over.
    function _accept() internal {
        vm.prank(adminSafe);
        manager.acceptNetwork();
    }

    /// @dev An empty genesis wiring list.
    function _noWiring() internal pure returns (GovernanceConfig.Call[] memory) {
        return new GovernanceConfig.Call[](0);
    }

    /// @dev Kept for callers written for the earlier manager; nothing waits on it now.
    function _settle() internal {
        vm.warp(block.timestamp + manager.minSetback());
    }

    /// @dev The default operational keys: three pausers, two curation signers, and one key per
    ///      other operational role, the statement-log curator included.
    function _grants() internal view virtual returns (GovernanceConfig.Grant[] memory g) {
        g = new GovernanceConfig.Grant[](9);
        g[0] = GovernanceConfig.Grant(Roles.PAUSER, guardianA);
        g[1] = GovernanceConfig.Grant(Roles.PAUSER, guardianB);
        g[2] = GovernanceConfig.Grant(Roles.PAUSER, guardianC);
        g[3] = GovernanceConfig.Grant(Roles.CURATION_SIGNER, curationSigner);
        g[4] = GovernanceConfig.Grant(Roles.CURATION_SIGNER, curationSigner2);
        g[5] = GovernanceConfig.Grant(Roles.STORAGE_OPERATOR, storageOperator);
        g[6] = GovernanceConfig.Grant(Roles.KEEPER, keeper);
        g[7] = GovernanceConfig.Grant(Roles.PLATFORM, platform);
        g[8] = GovernanceConfig.Grant(Roles.CURATOR, curator);
    }

    /// @dev The sample target's selector-to-class mapping. `adminOnly` stays unmapped.
    function _targetFunctions() internal pure returns (GovernanceConfig.FunctionRole[] memory f) {
        f = new GovernanceConfig.FunctionRole[](9);
        f[0] = GovernanceConfig.FunctionRole(GovernedTargetMock.pause.selector, Roles.PAUSER);
        f[1] = GovernanceConfig.FunctionRole(
            GovernedTargetMock.unpause.selector, Roles.PARAMETER_SETTER
        );
        f[2] = GovernanceConfig.FunctionRole(
            GovernedTargetMock.setFee.selector, Roles.PARAMETER_SETTER
        );
        f[3] = GovernanceConfig.FunctionRole(
            GovernedTargetMock.raiseCallbackGas.selector, Roles.PARAMETER_SETTER
        );
        f[4] = GovernanceConfig.FunctionRole(
            GovernedTargetMock.setRecipient.selector, Roles.FUNDS_SETTER
        );
        f[5] = GovernanceConfig.FunctionRole(
            GovernedTargetMock.setVerifier.selector, Roles.SUCCESSOR_SETTER
        );
        f[6] = GovernanceConfig.FunctionRole(GovernedTargetMock.veto.selector, Roles.NETWORK);
        f[7] = GovernanceConfig.FunctionRole(GovernedTargetMock.keep.selector, Roles.KEEPER);
        f[8] = GovernanceConfig.FunctionRole(GovernedTargetMock.curate.selector, Roles.CURATOR);
    }

    function _config() internal view returns (GovernanceConfig.Config memory cfg) {
        cfg.network = adminSafe;
        cfg.brake = brakeSafe;
        cfg.grants = _grants();
        cfg.targets = new GovernanceConfig.Target[](1);
        cfg.targets[0] = GovernanceConfig.Target(address(target), _targetFunctions());
    }

    /// @dev Schedules `data` on `to` as `caller` at the earliest allowed time.
    function _schedule(address caller, address to, bytes memory data)
        internal
        returns (bytes32 id)
    {
        vm.prank(caller);
        (id,) = manager.schedule(to, data, 0);
    }

    /// @dev Schedules, waits exactly the caller's delay, and executes.
    function _scheduleAndExecute(address caller, address to, bytes memory data) internal {
        bytes32 id = _schedule(caller, to, data);
        vm.warp(manager.getSchedule(id));
        vm.prank(caller);
        manager.execute(to, data);
    }

    /// @dev The network's operation on the manager itself (7 days).
    function _adminExecute(bytes memory data) internal {
        _scheduleAndExecute(adminSafe, address(manager), data);
    }

    function _one(bytes4 selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    /// @dev True when a call carrying value gets past the callee's callvalue check: a
    ///      non-payable function reverts with empty data before decoding or `restricted`
    ///      runs, while a payable one reaches `restricted` and reverts with
    ///      `AccessManagedUnauthorized` for an outsider.
    function _acceptsValue(address to, bytes memory data) internal returns (bool) {
        vm.deal(outsider, 1);
        vm.prank(outsider);
        (bool ok, bytes memory reason) = to.call{ value: 1 }(data);
        assertFalse(ok, "outsider call succeeded");
        if (reason.length == 0) return false;
        assertEq(
            reason,
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        return true;
    }
}
