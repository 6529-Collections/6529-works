// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { DelegationManagementMock } from "test/mocks/identity/DelegationManagementMock.sol";
import { DeployGuards } from "./DeployGuards.sol";
import { DeployV1 } from "./DeployV1.sol";
import { ScriptIO } from "./ScriptIO.sol";

/// @title Deploy
/// @notice Deploys 6529 Works v1 and installs the genesis configuration in one run: every
///         contract (CREATE2, `DeployV1`), then `GovernanceConfigurator.configure` with the
///         holders and selector map from the genesis JSON and the genesis wiring.
/// @dev Never reads or prints a key: the operator signs with Foundry's own flags (`--account`,
///      `--ledger`, or `--unlocked` on anvil), names the same account with `--sender`, and is
///      the configurator's `deployer`. Parameters come from environment variables
///      (script/README.md). The whole run is simulated before anything is sent, so every check
///      below aborts the run with nothing broadcast. Off anvil:
///      - the RPC's chain ID must match (`ChainIdMismatch`);
///      - every placeholder is refused, and every required input must be given;
///      - the genesis file must name reachable holders and the committed policy
///        (`DeployGuards`);
///      - the CC0 text must hash to `DeployV1.CC0_LEGALCODE_SHA256`;
///      - Permit2 and the delegation contract must have code, and be canonical on mainnet;
///      - the entropy module is required unless declined with `NO_VRF=1`;
///      - nothing the genesis names may be left out.
///      On anvil, when the delegation contract has no code, a `DelegationManagementMock` is
///      deployed first. The record (`deployments/<chainId>/<timestamp>.json`) is written from
///      the simulation, before the transactions are confirmed, and says so; `Verify.s.sol`
///      confirms it against the chain.
contract Deploy is ScriptIO {
    /// @notice Placeholders used only on anvil (chain 31337), each recorded in the deployment.
    string internal constant PLACEHOLDER_CC0 =
        "6529 Works local dry run: placeholder for the CC0 1.0 Universal legal code.";
    bytes32 internal constant PLACEHOLDER_MANIFEST = keccak256("placeholder: epoch-0 manifest");
    string internal constant PLACEHOLDER_MANIFEST_URI = "ar://placeholder-epoch-0";
    address internal constant PLACEHOLDER_FEE_RECIPIENT = address(0xC001);
    address internal constant PLACEHOLDER_MARKET_OWNER = address(0xC002);
    /// @notice The committed example genesis: the policy every genesis file must match.
    string internal constant EXAMPLE_GENESIS = "config/genesis.example.json";

    error MissingParameter(string name);
    error ConflictingParameters(string a, string b);
    error NoCode(string name, address account);
    error NonCanonicalOnMainnet(string name, address account);
    /// @notice `--sender` was not given: the script's sender is Foundry's default, not the
    ///         signing account, so the configurator would name the wrong deployer.
    error SenderNotSet();
    /// @notice The canonical CC0 digest is not pinned yet (`DeployV1.CC0_LEGALCODE_SHA256`).
    error Cc0DigestNotPinned();
    error Cc0TextMismatch(bytes32 actual, bytes32 expected);
    /// @notice The configurator's CREATE2 address already has code: someone deployed the
    ///         operator's own initcode under this namespace first. Use a new DEPLOY_NAMESPACE
    ///         (and a private RPC on mainnet).
    error ConfiguratorAddressTaken(address configurator);

    /// @notice The last run's record, also written to `deployments/` when broadcasting.
    string public lastRecord;

    struct Run {
        string genesisPath;
        string json;
        DeployV1.Params p;
        DeployV1.Manifest manifest;
        string manifestPath;
        uint256 startBlock;
        bool local;
    }

    function run() external returns (DeployV1.Deployment memory d) {
        Run memory r = prepare();
        r.startBlock = block.number;

        vm.startBroadcast(msg.sender);
        if (r.local && r.p.delegation.code.length == 0) {
            r.p.delegation = address(new DelegationManagementMock());
        }
        d = DeployV1.deploy(r.p);
        vm.stopBroadcast();

        GovernanceConfig.Config memory cfg = DeployV1.config(d, r.json);
        GovernanceConfig.Call[] memory calls = DeployV1.wiring(d, r.json, r.manifest);
        checkDeployment(d, r, cfg);

        vm.startBroadcast(msg.sender);
        DeployV1.install(d, cfg, r.manifest, calls);
        vm.stopBroadcast();

        console2.log("manager      ", address(d.manager));
        console2.log("configurator ", address(d.configurator));
        console2.log("targets      ", cfg.targets.length);
        console2.log("wiring calls ", calls.length);
        lastRecord = record(d, r, cfg, calls);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            string memory dir = string.concat("deployments/", vm.toString(block.chainid));
            vm.createDir(dir, true);
            string memory file = string.concat(dir, "/", vm.toString(block.timestamp), ".json");
            vm.writeJson(lastRecord, file);
            console2.log("recorded     ", file, "(unconfirmed until Verify.s.sol passes)");
        }
    }

    /// @notice Everything checked before the first transaction: the chain, the sender, the
    ///         genesis file, the parameters and the manifest.
    function prepare() public returns (Run memory r) {
        r.local = block.chainid == DeployV1.LOCAL_CHAIN_ID;
        checkChain();
        if (msg.sender == DEFAULT_SENDER) revert SenderNotSet();
        r.genesisPath = _envString("GENESIS_CONFIG", r.local ? EXAMPLE_GENESIS : "");
        if (bytes(r.genesisPath).length == 0) revert MissingParameter("GENESIS_CONFIG");
        r.json = _read(r.genesisPath);
        if (!r.local) DeployGuards.checkHolders(r.json, _read(EXAMPLE_GENESIS));
        r.p = params(r.local);
        r.p.deployer = msg.sender;
        (r.manifest, r.manifestPath) = manifest(r.local);
        checkConfiguratorSlot(r.p);
    }

    /// @notice Off-anvil checks against the deployed contracts, before `configure`: nothing the
    ///         genesis names is left out, the policy is the committed one, and no holder is a
    ///         contract of the deployment.
    function checkDeployment(
        DeployV1.Deployment memory d,
        Run memory r,
        GovernanceConfig.Config memory cfg
    ) public view {
        if (r.local) return;
        DeployGuards.checkNothingDropped(d, r.json, r.p.vrfCoordinator == address(0));
        DeployGuards.checkPolicy(d, r.json, _read(EXAMPLE_GENESIS), r.manifest);
        DeployGuards.checkHoldersAgainst(d, r.p, cfg);
    }

    /// @notice The configurator's CREATE2 address must be free. If it is not, someone deployed
    ///         the operator's initcode first: harmless (that configurator only obeys the
    ///         operator), but this namespace can no longer be used.
    function checkConfiguratorSlot(DeployV1.Params memory p) public view {
        DeployV1.Deployment memory none;
        address configurator = vm.computeCreate2Address(
            DeployV1.salt(p, "GovernanceConfigurator"),
            keccak256(DeployV1.initcode(p, none, "GovernanceConfigurator")),
            DeployGuards.CREATE2_FACTORY
        );
        if (configurator.code.length != 0) revert ConfiguratorAddressTaken(configurator);
    }

    /// @notice Deployment parameters from the environment, with anvil defaults.
    function params(bool local) public view returns (DeployV1.Params memory p) {
        p.namespace = _envBytes32("DEPLOY_NAMESPACE", keccak256("6529-works/v1"));
        p.feeRecipient =
            _envAddress("NETWORK_FEE_RECIPIENT", local ? PLACEHOLDER_FEE_RECIPIENT : address(0));
        if (p.feeRecipient == address(0)) revert MissingParameter("NETWORK_FEE_RECIPIENT");
        p.marketOwner =
            _envAddress("MARKETPLACE_OWNER", local ? PLACEHOLDER_MARKET_OWNER : address(0));
        if (p.marketOwner == address(0)) revert MissingParameter("MARKETPLACE_OWNER");
        p.delegation = _dependency("DELEGATION_CONTRACT", DeployGuards.CANONICAL_DELEGATION, local);
        p.cc0Text = cc0Text(local);
        p.ethIncrementFloor = _envUint("ETH_INCREMENT_FLOOR", 0.001 ether);
        p.permit2 = _dependency("PERMIT2", DeployV1.CANONICAL_PERMIT2, local);
        p.auction = IEnglishAuction.AuctionConfig(
            SafeCast.toUint32(_envUint("AUCTION_DURATION", 24 hours)),
            SafeCast.toUint32(_envUint("AUCTION_EXTENSION_WINDOW", 15 minutes)),
            SafeCast.toUint32(_envUint("AUCTION_INCREMENT_SHARE", 5_000))
        );
        _vrf(p, local);
    }

    /// @dev An external contract the deployment pins: canonical on mainnet, with code off anvil.
    function _dependency(string memory name, address canonical, bool local)
        internal
        view
        returns (address account)
    {
        account = _envAddress(name, canonical);
        if (block.chainid == DeployGuards.MAINNET_CHAIN_ID && account != canonical) {
            revert NonCanonicalOnMainnet(name, account);
        }
        if (!local && account.code.length == 0) revert NoCode(name, account);
    }

    /// @dev The entropy module's parameters. Off anvil a VRF coordinator is required unless
    ///      `NO_VRF=1` declines the module explicitly (6529 Stream pins it immutably).
    function _vrf(DeployV1.Params memory p, bool local) internal view {
        p.vrfCoordinator = _envAddress("VRF_COORDINATOR", address(0));
        uint256 declined = _envUint("NO_VRF", 0);
        if (declined > 1) revert MissingParameter("NO_VRF (0 or 1)");
        if (p.vrfCoordinator == address(0)) {
            if (!local && declined == 0) {
                revert MissingParameter("VRF_COORDINATOR (or NO_VRF=1 to deploy without VRF)");
            }
            return;
        }
        if (declined == 1) revert ConflictingParameters("VRF_COORDINATOR", "NO_VRF");
        if (p.vrfCoordinator.code.length == 0) revert NoCode("VRF_COORDINATOR", p.vrfCoordinator);
        p.vrfCoordinatorCodeHash = p.vrfCoordinator.codehash;
        uint256 subscription = _envUint("VRF_SUBSCRIPTION_ID", 0);
        if (subscription == 0) revert MissingParameter("VRF_SUBSCRIPTION_ID");
        bytes32 keyHash = _envBytes32("VRF_KEY_HASH", bytes32(0));
        if (keyHash == bytes32(0)) revert MissingParameter("VRF_KEY_HASH");
        p.vrf = VrfEntropyModule.VrfConfig(
            subscription,
            keyHash,
            SafeCast.toUint32(_envUint("VRF_CALLBACK_GAS_LIMIT", 200_000)),
            SafeCast.toUint16(_envUint("VRF_CONFIRMATIONS", 3)),
            _envUint("VRF_NATIVE_PAYMENT", 0) == 1
        );
        p.vrfRetryDelay = SafeCast.toUint64(_envUint("VRF_RETRY_DELAY", 3 days));
    }

    /// @notice The CC0 legal code from `CC0_TEXT_PATH` (under ./config, the only readable
    ///         directory). Off anvil it is required, and must hash to the pinned canonical
    ///         digest; on anvil a placeholder stands in when no file is given.
    function cc0Text(bool local) public view returns (bytes memory text) {
        string memory path = _envString("CC0_TEXT_PATH", "");
        bytes32 pinned = cc0Digest();
        if (bytes(path).length == 0) {
            if (!local) revert MissingParameter("CC0_TEXT_PATH");
            return bytes(PLACEHOLDER_CC0);
        }
        if (!local && pinned == bytes32(0)) revert Cc0DigestNotPinned();
        text = _readBinary(path);
        if (pinned != bytes32(0) && sha256(text) != pinned) {
            revert Cc0TextMismatch(sha256(text), pinned);
        }
    }

    /// @notice The epoch-0 governance manifest: the SHA-256 of the file at `MANIFEST_PATH`
    ///         (under ./config) and its published `MANIFEST_URI`. Both are required off anvil.
    function manifest(bool local)
        public
        view
        returns (DeployV1.Manifest memory m, string memory path)
    {
        path = _envString("MANIFEST_PATH", "");
        if (bytes(path).length != 0) {
            m.digest = sha256(_readBinary(path));
        } else if (local) {
            m.digest = PLACEHOLDER_MANIFEST;
        } else {
            revert MissingParameter("MANIFEST_PATH");
        }
        m.uri = _envString("MANIFEST_URI", local ? PLACEHOLDER_MANIFEST_URI : "");
        if (bytes(m.uri).length == 0) revert MissingParameter("MANIFEST_URI");
    }

    // ------------------------------------------------------------------ the record

    /// @notice The deployment record: every address and code hash, and every constructor
    ///         parameter `Verify.s.sol` needs to recompute the CREATE2 addresses.
    function record(
        DeployV1.Deployment memory d,
        Run memory r,
        GovernanceConfig.Config memory cfg,
        GovernanceConfig.Call[] memory calls
    ) public returns (string memory) {
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "startBlock", r.startBlock);
        vm.serializeUint(root, "timestamp", block.timestamp);
        vm.serializeBool(root, "confirmed", false);
        vm.serializeString(
            root,
            "note",
            "Written from the simulation before the broadcast; Verify.s.sol confirms it on chain."
        );
        vm.serializeString(root, "genesisConfig", r.genesisPath);
        vm.serializeBytes32(root, "configHash", keccak256(abi.encode(cfg)));
        vm.serializeBytes32(root, "wiringHash", keccak256(abi.encode(calls)));
        vm.serializeUint(root, "wiringCalls", calls.length);
        vm.serializeBytes32(root, "manifestDigest", r.manifest.digest);
        vm.serializeString(root, "manifestUri", r.manifest.uri);
        vm.serializeString(root, "manifestPath", r.manifestPath);
        vm.serializeBytes32(root, "cc0TextFileId", d.cc0TextFileId);
        vm.serializeBytes32(root, "cc0TextSha256", sha256(r.p.cc0Text));
        vm.serializeString(root, "pendingLanes", _pending());
        vm.serializeString(root, "standIns", _standIns(r.local));
        vm.serializeBool(root, "placeholders", r.local);
        vm.serializeBool(
            root, "delegationMock", r.p.delegation != DeployGuards.CANONICAL_DELEGATION
        );
        vm.serializeString(root, "entropy", r.p.vrfCoordinator == address(0) ? "none" : "vrf");
        vm.serializeString(root, "params", _recordParams(r.p));
        return vm.serializeString(root, "contracts", _recordContracts(d));
    }

    function _recordParams(DeployV1.Params memory p) internal returns (string memory) {
        string memory o = "params";
        vm.serializeAddress(o, "factory", DeployGuards.CREATE2_FACTORY);
        vm.serializeAddress(o, "deployer", p.deployer);
        vm.serializeBytes32(o, "namespace", p.namespace);
        vm.serializeAddress(o, "networkFeeRecipient", p.feeRecipient);
        vm.serializeAddress(o, "marketOwner", p.marketOwner);
        vm.serializeAddress(o, "delegation", p.delegation);
        vm.serializeString(o, "ethIncrementFloor", vm.toString(p.ethIncrementFloor));
        vm.serializeAddress(o, "permit2", p.permit2);
        vm.serializeUint(o, "auctionDuration", p.auction.duration);
        vm.serializeUint(o, "auctionExtensionWindow", p.auction.extensionWindow);
        vm.serializeUint(o, "auctionIncrementShare", p.auction.incrementShare);
        vm.serializeAddress(o, "vrfCoordinator", p.vrfCoordinator);
        vm.serializeBytes32(o, "vrfCoordinatorCodeHash", p.vrfCoordinatorCodeHash);
        vm.serializeString(o, "vrfSubscriptionId", vm.toString(p.vrf.subscriptionId));
        vm.serializeBytes32(o, "vrfKeyHash", p.vrf.keyHash);
        vm.serializeUint(o, "vrfCallbackGasLimit", p.vrf.callbackGasLimit);
        vm.serializeUint(o, "vrfConfirmations", p.vrf.confirmations);
        vm.serializeBool(o, "vrfNativePayment", p.vrf.nativePayment);
        return vm.serializeUint(o, "vrfRetryDelay", p.vrfRetryDelay);
    }

    function _recordContracts(DeployV1.Deployment memory d) internal returns (string memory out) {
        string memory contracts = "contracts";
        string[] memory names = DeployV1.names();
        for (uint256 i; i < names.length; ++i) {
            address a = DeployV1.addressOf(d, names[i]);
            if (a == address(0)) continue;
            vm.serializeAddress(names[i], "address", a);
            out = vm.serializeString(
                contracts, names[i], vm.serializeBytes32(names[i], "codehash", a.codehash)
            );
        }
    }

    function _pending() internal pure returns (string[] memory pending) {
        pending = new string[](2);
        (pending[0], pending[1]) = ("Renderer", "Editions");
    }

    /// @dev Protocol contracts replaced by stand-ins: the renderer, on anvil only. (The
    ///      delegation mock is an external dependency, recorded as `delegationMock`.)
    function _standIns(bool local) internal pure returns (string[] memory list) {
        list = new string[](local ? 1 : 0);
        if (local) list[0] = "Renderer";
    }
}
