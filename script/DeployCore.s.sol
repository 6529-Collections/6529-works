// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { DelegationManagementMock } from "test/mocks/identity/DelegationManagementMock.sol";
import { DeployCore } from "./DeployCore.sol";
import { DeployGuards } from "./DeployGuards.sol";
import { ScriptIO } from "./ScriptIO.sol";
import { VerifyCore } from "./VerifyCore.sol";

/// @title DeployCoreScript
/// @notice Broadcasts the plain-core stack (`DeployCore`) on anvil or Sepolia, installs the
///         genesis policy and reads the permanent contracts back (`VerifyCore`). It refuses
///         every other chain: this restructuring deploys to Sepolia only.
/// @dev `forge script script/DeployCore.s.sol --rpc-url <rpc> --sender <deployer> --broadcast`.
///      Environment: `GENESIS_CONFIG` (default on anvil: `config/genesis.core.example.json`),
///      `DEPLOY_NAMESPACE`, `NETWORK_FEE_RECIPIENT`, `MUSEUM`, `MARKETPLACE_OWNER`,
///      `MANIFEST_DIGEST`, `MANIFEST_URI`, `ACCEPT_NETWORK` (1 on anvil to accept as the
///      network). Off anvil the genesis file's network must be a deployed Safe and its holders
///      real keys (`DeployGuards.checkHolders`), and no brake is installed.
///      Off anvil it also checks, before `configure`, that the genesis policy is the committed
///      one (`DeployGuards.checkPolicy`) and that no holder is a contract of the deployment
///      (`DeployGuards.checkHoldersAgainst`). VRF: `VRF_COORDINATOR` (zero or unset: no entropy
///      module), `VRF_SUBSCRIPTION_ID`, `VRF_KEY_HASH`, `VRF_CALLBACK_GAS_LIMIT`,
///      `VRF_CONFIRMATIONS`, `VRF_NATIVE_PAYMENT`, `VRF_RETRY_DELAY`.
contract DeployCoreScript is ScriptIO {
    string internal constant CORE_GENESIS = "config/genesis.core.example.json";
    string internal constant CC0_FIXTURE = "test/fixtures/cc0-legalcode.txt";

    error ChainNotAllowed(uint256 chainId);
    error MissingParameter(string name);
    error Cc0TextMismatch(bytes32 actual);

    function run() external returns (DeployCore.Deployment memory d) {
        bool local = block.chainid == DeployCore.LOCAL_CHAIN_ID;
        if (!local && block.chainid != DeployGuards.SEPOLIA_CHAIN_ID) {
            revert ChainNotAllowed(block.chainid);
        }
        checkChain();
        string memory path = _envString("GENESIS_CONFIG", local ? CORE_GENESIS : "");
        if (bytes(path).length == 0) revert MissingParameter("GENESIS_CONFIG");
        string memory json = _read(path);
        if (!local) {
            (address[] memory singletons, bytes32[] memory codehashes) = safeSingletons();
            DeployGuards.checkHolders(json, _read(CORE_GENESIS), singletons, codehashes);
            DeployGuards.checkNoBrake(json);
        }
        DeployCore.Params memory p = params(local);
        DeployCore.Manifest memory manifest = DeployCore.Manifest(
            _envBytes32("MANIFEST_DIGEST", local ? keccak256("local manifest") : bytes32(0)),
            _envString("MANIFEST_URI", local ? "ar://local-manifest" : "")
        );
        if (manifest.digest == 0) revert MissingParameter("MANIFEST_DIGEST");

        vm.startBroadcast(msg.sender);
        if (p.delegation.code.length == 0 && local) {
            p.delegation = address(new DelegationManagementMock());
        }
        d = DeployCore.deploy(p, DeployGuards.CREATE2_FACTORY);
        vm.stopBroadcast();

        GovernanceConfig.Config memory cfg = DeployCore.config(d, json);
        GovernanceConfig.Call[] memory calls = DeployCore.wiring(d, json, manifest);
        if (!local) {
            DeployGuards.checkPolicy(d, json, _read(CORE_GENESIS), manifest);
            DeployGuards.checkHoldersAgainst(d, p, cfg);
        }
        vm.startBroadcast(msg.sender);
        DeployCore.install(d, cfg, manifest, calls);
        vm.stopBroadcast();
        bool accepted = _envUint("ACCEPT_NETWORK", 0) == 1;
        if (accepted) {
            vm.broadcast(cfg.network);
            d.manager.acceptNetwork();
        }
        VerifyCore.verify(p, d, cfg, accepted);

        console2.log("manager  ", address(d.manager));
        console2.log("Stream   ", address(d.stream));
        console2.log("Editions ", address(d.editions));
        console2.log("Directory", address(d.directory));
        console2.log("WorkFacts", address(d.workFacts));
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) record(p, d);
    }

    /// @notice Writes every deployed address to `deployments/<chain>/core-<time>.json`.
    function record(DeployCore.Params memory p, DeployCore.Deployment memory d) internal {
        string memory o = "core";
        string[] memory list = DeployCore.order(p);
        string memory out;
        for (uint256 i; i < list.length; ++i) {
            out = vm.serializeAddress(o, list[i], DeployCore.addressOf(d, list[i]));
        }
        string memory dir = string.concat("deployments/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        string memory file = string.concat(dir, "/core-", vm.toString(block.timestamp), ".json");
        vm.writeJson(out, file);
        console2.log("recorded ", file);
    }

    /// @notice The deployment parameters from the environment; placeholders only on anvil.
    function params(bool local) public view returns (DeployCore.Params memory p) {
        p.deployer = msg.sender;
        p.namespace =
            _envBytes32("DEPLOY_NAMESPACE", local ? keccak256("6529-works/core") : bytes32(0));
        if (p.namespace == 0) revert MissingParameter("DEPLOY_NAMESPACE");
        p.feeRecipient = _envAddress("NETWORK_FEE_RECIPIENT", local ? address(0xC001) : address(0));
        p.museum = _envAddress("MUSEUM", local ? address(0xC003) : address(0));
        p.marketOwner = _envAddress("MARKETPLACE_OWNER", local ? address(0xC002) : address(0));
        if (p.feeRecipient == address(0)) revert MissingParameter("NETWORK_FEE_RECIPIENT");
        if (p.museum == address(0)) revert MissingParameter("MUSEUM");
        if (p.marketOwner == address(0)) revert MissingParameter("MARKETPLACE_OWNER");
        p.delegation = block.chainid == DeployGuards.SEPOLIA_CHAIN_ID
            ? DeployGuards.SEPOLIA_DELEGATION
            : _envAddress("DELEGATION_CONTRACT", address(0));
        p.cc0Text = _readBinary(CC0_FIXTURE);
        if (sha256(p.cc0Text) != cc0Digest()) revert Cc0TextMismatch(sha256(p.cc0Text));
        p.ethIncrementFloor = 0.001 ether;
        p.auctionConfig = DeployCore.auctionConfig();
        p.editionAuctionConfig = DeployCore.editionAuctionConfig();
        p.vrfCoordinator = _envAddress("VRF_COORDINATOR", address(0));
        if (p.vrfCoordinator != address(0)) {
            p.vrfCoordinatorCodeHash = p.vrfCoordinator.codehash;
            uint256 subscription = _envUint("VRF_SUBSCRIPTION_ID", 0);
            bytes32 keyHash = _envBytes32("VRF_KEY_HASH", bytes32(0));
            if (subscription == 0) revert MissingParameter("VRF_SUBSCRIPTION_ID");
            if (keyHash == 0) revert MissingParameter("VRF_KEY_HASH");
            p.vrf = VrfEntropyModule.VrfConfig(
                subscription,
                keyHash,
                SafeCast.toUint32(_envUint("VRF_CALLBACK_GAS_LIMIT", 200_000)),
                SafeCast.toUint16(_envUint("VRF_CONFIRMATIONS", 3)),
                _envUint("VRF_NATIVE_PAYMENT", 0) == 1
            );
            p.vrfRetryDelay = SafeCast.toUint64(_envUint("VRF_RETRY_DELAY", 3 days));
        }
    }
}
