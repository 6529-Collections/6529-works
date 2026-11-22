// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DeployCore } from "script/DeployCore.sol";
import { VerifyCore } from "script/VerifyCore.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";

/// @notice The whole plain-core stack for the end-to-end suites, deployed and configured by the
///         deploy library (`script/DeployCore.sol`), the same code the deploy script broadcasts,
///         with the governance policy of `config/genesis.core.example.json`. The network is one
///         key that accepts in `setUp`.
/// @dev Replaces `IntegrationBase` at integration: the integration suites move onto it once
///      every lane's module exists (`DeployCore.deploy` creates modules from their build
///      artifacts). Until then nothing inherits it.
abstract contract CoreIntegrationBase is Test {
    /// @dev Every start row, as a whole transaction in Prague gas, is at most this (ADR 0010).
    uint256 internal constant START_BUDGET = 370_000;
    /// @dev New storage slots a start may write, with or without a bid (ADR 0010).
    uint256 internal constant START_MAX_SLOTS = 8;
    /// @dev EIP-7825: no transaction may carry more than 2^24 gas.
    uint256 internal constant TX_GAS_CAP = 1 << 24;

    string internal constant GENESIS = "config/genesis.core.example.json";
    string internal constant CC0_FIXTURE = "test/fixtures/cc0-legalcode.txt";

    DeployCore.Deployment internal deployment;
    address internal network = makeAddr("network");
    address internal deployer = makeAddr("deployer");
    address internal marketOwner = makeAddr("marketOwner");
    address internal museum = makeAddr("museum");
    address internal feeRecipient = makeAddr("feeRecipient");
    DelegationManagementMock internal delegation;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        delegation = new DelegationManagementMock();
        DeployCore.Params memory p = _params();
        deployment = DeployCore.deploy(p, address(this));
        DeployCore.Manifest memory manifest =
            DeployCore.Manifest(keccak256("integration manifest"), "ar://integration");
        string memory json = vm.readFile(GENESIS);
        GovernanceConfig.Config memory cfg = DeployCore.config(deployment, json);
        cfg.network = network;
        GovernanceConfig.Call[] memory calls = DeployCore.wiring(deployment, json, manifest);
        vm.prank(deployer);
        DeployCore.install(deployment, cfg, manifest, calls);
        vm.prank(network);
        deployment.manager.acceptNetwork();
        VerifyCore.verify(p, deployment, cfg, true);
    }

    /// @dev The deployment's parameters. Suites override pieces (the auction configuration).
    function _params() internal view virtual returns (DeployCore.Params memory p) {
        p.deployer = deployer;
        p.namespace = keccak256("6529-works/core-integration");
        p.feeRecipient = feeRecipient;
        p.museum = museum;
        p.marketOwner = marketOwner;
        p.delegation = address(delegation);
        p.cc0Text = vm.readFileBinary(CC0_FIXTURE);
        p.ethIncrementFloor = 0.001 ether;
        // INTEGRATION: the English auction's and the edition auctions' genesis configuration,
        // encoded as lanes 4 and 2 finish their constructors.
    }

    /// @dev The manager, typed.
    function _manager() internal view returns (WorksAccessManager) {
        return deployment.manager;
    }
}
