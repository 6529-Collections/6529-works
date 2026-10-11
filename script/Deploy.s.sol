// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { DeployV1 } from "./DeployV1.sol";

/// @title Deploy
/// @notice Deploys 6529 Works v1 and installs the genesis configuration in one run: every
///         contract (CREATE2, `DeployV1`), then `GovernanceConfigurator.configure` with the
///         holders and selector map from the genesis JSON and the genesis wiring.
/// @dev Never reads or prints a key: the operator signs with Foundry's own flags (`--account`,
///      `--ledger`, or `--unlocked` on anvil) and is the configurator's `deployer`. Parameters
///      come from environment variables (script/README.md). Off anvil, every placeholder is
///      refused. When broadcasting, the deployment is recorded under
///      `deployments/<chainId>/<timestamp>.json`.
contract Deploy is Script {
    /// @notice Placeholders used only on anvil (chain 31337), each recorded in the deployment.
    bytes32 internal constant PLACEHOLDER_CC0 = keccak256("placeholder: CC0 1.0 legal code file");
    bytes32 internal constant PLACEHOLDER_MANIFEST = keccak256("placeholder: epoch-0 manifest");
    address internal constant PLACEHOLDER_FEE_RECIPIENT = address(0xC001);

    error MissingParameter(string name);

    function run() external returns (DeployV1.Deployment memory d) {
        string memory path = vm.envOr("GENESIS_CONFIG", string("config/genesis.example.json"));
        string memory json = vm.readFile(path);
        bool local = block.chainid == DeployV1.LOCAL_CHAIN_ID;
        DeployV1.Params memory p = params(local);
        p.deployer = msg.sender;
        DeployV1.Manifest memory manifest = DeployV1.Manifest(
            _bytes32("MANIFEST_SHA256", PLACEHOLDER_MANIFEST, local),
            vm.envOr("MANIFEST_URI", local ? string("ar://placeholder-epoch-0") : string(""))
        );
        if (bytes(manifest.uri).length == 0) revert MissingParameter("MANIFEST_URI");
        uint256 startBlock = block.number;

        vm.startBroadcast();
        d = DeployV1.deploy(p);
        GovernanceConfig.Config memory cfg = DeployV1.config(d, json);
        GovernanceConfig.Call[] memory calls = DeployV1.wiring(d, json, manifest);
        DeployV1.install(d, cfg, manifest, calls);
        vm.stopBroadcast();

        console2.log("manager      ", address(d.manager));
        console2.log("configurator ", address(d.configurator));
        console2.log("targets      ", cfg.targets.length);
        console2.log("wiring calls ", calls.length);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _record(d, p, path, manifest, startBlock, keccak256(abi.encode(cfg)), calls, local);
        }
    }

    /// @notice Deployment parameters from the environment, with anvil defaults.
    function params(bool local) public view returns (DeployV1.Params memory p) {
        p.namespace = vm.envOr("DEPLOY_NAMESPACE", keccak256("6529-works/v1"));
        p.feeRecipient =
            vm.envOr("NETWORK_FEE_RECIPIENT", local ? PLACEHOLDER_FEE_RECIPIENT : address(0));
        if (p.feeRecipient == address(0)) revert MissingParameter("NETWORK_FEE_RECIPIENT");
        p.cc0TextFileId = _bytes32("CC0_TEXT_FILE_ID", PLACEHOLDER_CC0, local);
        p.ethIncrementFloor = vm.envOr("ETH_INCREMENT_FLOOR", uint256(0.001 ether));
        p.permit2 = vm.envOr("PERMIT2", DeployV1.CANONICAL_PERMIT2);
        p.auction = IEnglishAuction.AuctionConfig(
            uint32(vm.envOr("AUCTION_DURATION", uint256(24 hours))),
            uint32(vm.envOr("AUCTION_EXTENSION_WINDOW", uint256(15 minutes))),
            uint32(vm.envOr("AUCTION_INCREMENT_SHARE", uint256(5_000)))
        );
        p.vrfCoordinator = vm.envOr("VRF_COORDINATOR", address(0));
        if (p.vrfCoordinator != address(0)) {
            p.vrfCoordinatorCodeHash = p.vrfCoordinator.codehash;
            p.vrf = VrfEntropyModule.VrfConfig(
                vm.envUint("VRF_SUBSCRIPTION_ID"),
                vm.envBytes32("VRF_KEY_HASH"),
                uint32(vm.envOr("VRF_CALLBACK_GAS_LIMIT", uint256(200_000))),
                uint16(vm.envOr("VRF_CONFIRMATIONS", uint256(3))),
                vm.envOr("VRF_NATIVE_PAYMENT", false)
            );
            p.vrfRetryDelay = uint64(vm.envOr("VRF_RETRY_DELAY", uint256(3 days)));
        }
    }

    function _bytes32(string memory name, bytes32 placeholder, bool local)
        internal
        view
        returns (bytes32 value)
    {
        value = vm.envOr(name, local ? placeholder : bytes32(0));
        if (value == bytes32(0)) revert MissingParameter(name);
    }

    function _record(
        DeployV1.Deployment memory d,
        DeployV1.Params memory p,
        string memory genesis,
        DeployV1.Manifest memory manifest,
        uint256 startBlock,
        bytes32 configHash,
        GovernanceConfig.Call[] memory calls,
        bool local
    ) internal {
        string memory contracts = "contracts";
        string[22] memory names = DeployV1.names();
        string memory out;
        for (uint256 i; i < names.length; ++i) {
            address a = DeployV1.addressOf(d, names[i]);
            if (a == address(0)) continue;
            string memory entry = names[i];
            vm.serializeAddress(entry, "address", a);
            string memory e = vm.serializeBytes32(entry, "codehash", a.codehash);
            out = vm.serializeString(contracts, names[i], e);
        }
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "startBlock", startBlock);
        vm.serializeUint(root, "timestamp", block.timestamp);
        vm.serializeAddress(root, "deployer", p.deployer);
        vm.serializeBytes32(root, "namespace", p.namespace);
        vm.serializeString(root, "genesisConfig", genesis);
        vm.serializeBytes32(root, "manifestDigest", manifest.digest);
        vm.serializeString(root, "manifestUri", manifest.uri);
        vm.serializeBytes32(root, "configHash", configHash);
        vm.serializeBytes32(root, "wiringHash", keccak256(abi.encode(calls)));
        vm.serializeUint(root, "wiringCalls", calls.length);
        string[] memory pending = new string[](4);
        (pending[0], pending[1], pending[2], pending[3]) =
        ("Renderer", "Stream", "WorkRecords", "Editions");
        vm.serializeString(root, "pendingLanes", pending);
        string[] memory standIns = new string[](local ? 1 : 0);
        if (local) standIns[0] = "ArtistRegistry";
        vm.serializeString(root, "standIns", standIns);
        vm.serializeBool(root, "placeholders", local);
        string memory json = vm.serializeString(root, "contracts", out);

        string memory dir = string.concat("deployments/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        string memory file = string.concat(dir, "/", vm.toString(block.timestamp), ".json");
        vm.writeJson(json, file);
        console2.log("recorded     ", file);
    }
}
