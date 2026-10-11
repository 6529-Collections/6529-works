// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { DelegationManagementMock } from "test/mocks/identity/DelegationManagementMock.sol";
import { DeployV1 } from "./DeployV1.sol";

/// @title Deploy
/// @notice Deploys 6529 Works v1 and installs the genesis configuration in one run: every
///         contract (CREATE2, `DeployV1`), then `GovernanceConfigurator.configure` with the
///         holders and selector map from the genesis JSON and the genesis wiring.
/// @dev Never reads or prints a key: the operator signs with Foundry's own flags (`--account`,
///      `--ledger`, or `--unlocked` on anvil) and is the configurator's `deployer`. Parameters
///      come from environment variables (script/README.md). Off anvil, every placeholder is
///      refused. On anvil, when the delegation contract has no code, a
///      `DelegationManagementMock` is deployed first. When broadcasting, the deployment is
///      recorded under `deployments/<chainId>/<timestamp>.json`.
contract Deploy is Script {
    /// @notice Placeholders used only on anvil (chain 31337), each recorded in the deployment.
    string internal constant PLACEHOLDER_CC0 =
        "6529 Works local dry run: placeholder for the CC0 1.0 Universal legal code.";
    bytes32 internal constant PLACEHOLDER_MANIFEST = keccak256("placeholder: epoch-0 manifest");
    address internal constant PLACEHOLDER_FEE_RECIPIENT = address(0xC001);
    address internal constant PLACEHOLDER_MARKET_OWNER = address(0xC002);
    /// @notice The 6529 delegation contract on Ethereum mainnet.
    address internal constant CANONICAL_DELEGATION = 0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d;
    uint256 internal constant MAINNET_CHAIN_ID = 1;
    /// @notice The committed example genesis; every holder in it is a placeholder.
    string internal constant EXAMPLE_GENESIS = "config/genesis.example.json";
    /// @notice Holder addresses at or below this are placeholders (the example's `0x…b0xx`) or
    ///         precompiles, never a Safe or a key.
    uint160 internal constant MAX_PLACEHOLDER = 0xFFFF;

    error MissingParameter(string name);
    error ExampleGenesisOffAnvil();
    error PlaceholderHolder(string role, address account);
    error NonCanonicalDelegationOnMainnet(address delegation);
    /// @notice `--sender` was not given: the script's sender is Foundry's default, not the
    ///         signing account, so the configurator would name the wrong deployer.
    error SenderNotSet();

    function run() external returns (DeployV1.Deployment memory d) {
        bool local = block.chainid == DeployV1.LOCAL_CHAIN_ID;
        string memory path = vm.envOr("GENESIS_CONFIG", local ? EXAMPLE_GENESIS : string(""));
        if (bytes(path).length == 0) revert MissingParameter("GENESIS_CONFIG");
        string memory json = vm.readFile(path);
        checkGenesis(path, json, local);
        DeployV1.Params memory p = params(local);
        if (msg.sender == DEFAULT_SENDER) revert SenderNotSet();
        p.deployer = msg.sender;
        DeployV1.Manifest memory manifest = DeployV1.Manifest(
            _bytes32("MANIFEST_SHA256", PLACEHOLDER_MANIFEST, local),
            vm.envOr("MANIFEST_URI", local ? string("ar://placeholder-epoch-0") : string(""))
        );
        if (bytes(manifest.uri).length == 0) revert MissingParameter("MANIFEST_URI");
        uint256 startBlock = block.number;

        vm.startBroadcast();
        if (local && p.delegation.code.length == 0) {
            p.delegation = address(new DelegationManagementMock());
        }
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

    /// @notice Off anvil, refuses the example genesis and any holder that is a placeholder:
    ///         the configurator renounces ADMIN in the same transaction, so a placeholder
    ///         admin would leave the system with no reachable governance.
    function checkGenesis(string memory path, string memory json, bool local) public view {
        if (local) return;
        if (keccak256(bytes(path)) == keccak256(bytes(EXAMPLE_GENESIS))) {
            revert ExampleGenesisOffAnvil();
        }
        for (uint256 i; vm.keyExistsJson(json, _holder(i, "")); ++i) {
            address account = vm.parseJsonAddress(json, _holder(i, ".account"));
            if (uint160(account) <= MAX_PLACEHOLDER) {
                revert PlaceholderHolder(vm.parseJsonString(json, _holder(i, ".role")), account);
            }
        }
    }

    function _holder(uint256 i, string memory field) private pure returns (string memory) {
        return string.concat(".holders[", vm.toString(i), "]", field);
    }

    /// @notice Deployment parameters from the environment, with anvil defaults.
    function params(bool local) public view returns (DeployV1.Params memory p) {
        p.namespace = vm.envOr("DEPLOY_NAMESPACE", keccak256("6529-works/v1"));
        p.feeRecipient =
            vm.envOr("NETWORK_FEE_RECIPIENT", local ? PLACEHOLDER_FEE_RECIPIENT : address(0));
        if (p.feeRecipient == address(0)) revert MissingParameter("NETWORK_FEE_RECIPIENT");
        p.marketOwner = vm.envOr("MARKETPLACE_OWNER", local ? PLACEHOLDER_MARKET_OWNER : address(0));
        if (p.marketOwner == address(0)) revert MissingParameter("MARKETPLACE_OWNER");
        p.delegation = vm.envOr("DELEGATION_CONTRACT", CANONICAL_DELEGATION);
        if (block.chainid == MAINNET_CHAIN_ID && p.delegation != CANONICAL_DELEGATION) {
            revert NonCanonicalDelegationOnMainnet(p.delegation);
        }
        if (!local && p.delegation.code.length == 0) {
            revert MissingParameter("DELEGATION_CONTRACT (no code at the address)");
        }
        p.cc0Text = _cc0Text(local);
        p.ethIncrementFloor = vm.envOr("ETH_INCREMENT_FLOOR", uint256(0.001 ether));
        p.permit2 = vm.envOr("PERMIT2", DeployV1.CANONICAL_PERMIT2);
        // The fixed-price and Dutch sales require a nonzero Permit2; off anvil it must be real.
        if (!local && p.permit2.code.length == 0) {
            revert MissingParameter("PERMIT2 (no code at the address)");
        }
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

    /// @dev The CC0 legal code from `CC0_TEXT_PATH` (under ./config, the only readable
    ///      directory), checked against `CC0_TEXT_SHA256` when set; a placeholder on anvil.
    function _cc0Text(bool local) internal view returns (bytes memory text) {
        string memory path = vm.envOr("CC0_TEXT_PATH", string(""));
        if (bytes(path).length == 0) {
            if (!local) revert MissingParameter("CC0_TEXT_PATH");
            return bytes(PLACEHOLDER_CC0);
        }
        text = bytes(vm.readFile(path));
        bytes32 expected = vm.envOr("CC0_TEXT_SHA256", bytes32(0));
        if (expected != bytes32(0) && sha256(text) != expected) {
            revert MissingParameter("CC0_TEXT_SHA256 (the file does not match)");
        }
    }

    /// @dev The renderer stand-in on anvil, and the delegation mock wherever the canonical
    ///      delegation contract is not used (anvil, Sepolia).
    function _standIns(DeployV1.Params memory p, bool local)
        internal
        pure
        returns (string[] memory list)
    {
        bool mock = p.delegation != CANONICAL_DELEGATION;
        list = new string[]((local ? 1 : 0) + (mock ? 1 : 0));
        if (local) list[0] = "Renderer";
        if (mock) list[list.length - 1] = "DelegationManagement";
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
        string[] memory names = DeployV1.names();
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
        vm.serializeAddress(root, "delegation", p.delegation);
        vm.serializeAddress(root, "marketOwner", p.marketOwner);
        vm.serializeAddress(root, "networkFeeRecipient", p.feeRecipient);
        vm.serializeBytes32(root, "namespace", p.namespace);
        vm.serializeString(root, "genesisConfig", genesis);
        vm.serializeBytes32(root, "manifestDigest", manifest.digest);
        vm.serializeBytes32(root, "cc0TextFileId", d.cc0TextFileId);
        vm.serializeString(root, "manifestUri", manifest.uri);
        vm.serializeBytes32(root, "configHash", configHash);
        vm.serializeBytes32(root, "wiringHash", keccak256(abi.encode(calls)));
        vm.serializeUint(root, "wiringCalls", calls.length);
        string[] memory pending = new string[](2);
        (pending[0], pending[1]) = ("Renderer", "Editions");
        vm.serializeString(root, "pendingLanes", pending);
        vm.serializeString(root, "standIns", _standIns(p, local));
        vm.serializeBool(root, "placeholders", local);
        string memory json = vm.serializeString(root, "contracts", out);

        string memory dir = string.concat("deployments/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        string memory file = string.concat(dir, "/", vm.toString(block.timestamp), ".json");
        vm.writeJson(json, file);
        console2.log("recorded     ", file);
    }
}
