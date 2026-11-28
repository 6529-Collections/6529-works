// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { DeployCore } from "script/DeployCore.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { MockVrfCoordinator } from "../mocks/entropy/EntropyMocks.sol";
import { CoreIntegrationBase } from "../integration/CoreIntegrationBase.sol";

/// @notice The whole stack deployed by `DeployCore.deploy` with its real constructors (and the
///         entropy module, so the genesis wiring is the longest it can be), not configured yet:
///         the genesis transaction itself is the subject.
abstract contract GenesisFreshBase is CoreIntegrationBase {
    function setUp() public virtual override {
        vm.warp(1_800_000_000);
        delegation = new DelegationManagementMock();
        coordinator = new MockVrfCoordinator();
        params = _params();
        deployment = DeployCore.deploy(params, address(this));
        manager = deployment.manager;
        configurator = deployment.configurator;
        manifest = DeployCore.Manifest(keccak256("fresh genesis manifest"), "ar://fresh-genesis");
        genesisJson = _withHolders(vm.readFile(GENESIS));
    }

    function _withVrf() internal pure override returns (bool) {
        return true;
    }

    /// @dev The committed genesis wiring for this deployment.
    function _wiring() internal view returns (GovernanceConfig.Call[] memory) {
        return DeployCore.wiring(deployment, genesisJson, manifest);
    }

    function _configureData(GovernanceConfig.Call[] memory calls)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            GovernanceConfigurator.configure, (_genesisConfig(), manifest.digest, calls)
        );
    }

    /// @dev The deployer sends `data` to the configurator; returns the whole transaction's gas
    ///      (EIP-7623: the larger of the standard cost and the calldata floor).
    function _sendAsDeployer(bytes memory data) internal returns (bool ok, uint256 total) {
        uint256 tokens;
        for (uint256 i; i < data.length; ++i) {
            tokens += data[i] == 0 ? 1 : 4;
        }
        vm.prank(deployer);
        uint256 before = gasleft();
        (ok,) = address(configurator).call(data);
        uint256 execution = before - gasleft();
        uint256 standard = 21_000 + 4 * tokens + execution;
        uint256 floor = 21_000 + 10 * tokens;
        total = standard > floor ? standard : floor;
    }

    function _accept() internal {
        vm.prank(network);
        WorksAccessManager(address(manager)).acceptNetwork();
    }
}
