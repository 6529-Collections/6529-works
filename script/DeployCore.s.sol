// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { console2 } from "forge-std/console2.sol";
import { Vm, VmSafe } from "forge-std/Vm.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { DelegationManagementMock } from "test/mocks/identity/DelegationManagementMock.sol";
import { DeployCore } from "./DeployCore.sol";
import { DeployGuards } from "./DeployGuards.sol";
import { ScriptIO } from "./ScriptIO.sol";
import { VerifyCore } from "./VerifyCore.sol";

/// @title DeployCoreScript
/// @notice Broadcasts the plain-core stack (`DeployCore`) on anvil or Sepolia, installs the
///         genesis policy and reads the deployment back (`VerifyCore`). It refuses every other
///         chain: this restructuring deploys to Sepolia only. The readback here runs in forge's
///         simulation, before anything is sent; the check that counts is
///         `script/VerifyCore.s.sol` against the chain after the broadcast (runtime code of
///         every contract and the whole wiring).
/// @dev `forge script script/DeployCore.s.sol --rpc-url <rpc> --sender <deployer> --broadcast`.
///      Environment: `GENESIS_CONFIG` (default on anvil: `config/genesis.core.example.json`),
///      `DEPLOY_NAMESPACE`, `NETWORK_FEE_RECIPIENT`, `MUSEUM`, `MARKETPLACE_OWNER`,
///      `MANIFEST_PATH` (a file under `config/`, hashed with SHA-256) or `MANIFEST_DIGEST`,
///      `MANIFEST_URI`, `AUCTION_DURATION` (seconds; a testnet round only), `ACCEPT_NETWORK`
///      (1 on anvil to accept as the network). Off anvil the genesis file's network must be a
///      deployed Safe and its holders real keys (`DeployGuards.checkHolders`), and no brake is
///      installed.
///      Off anvil it also checks, before `configure`, that the genesis policy is the committed
///      one (`DeployGuards.checkPolicy`) and that no holder is a contract of the deployment
///      (`DeployGuards.checkHoldersAgainst`). VRF: `VRF_COORDINATOR` (zero or unset: no entropy
///      module), `VRF_SUBSCRIPTION_ID`, `VRF_KEY_HASH`, `VRF_CALLBACK_GAS_LIMIT`,
///      `VRF_CONFIRMATIONS`, `VRF_NATIVE_PAYMENT`, `VRF_RETRY_DELAY`.
contract DeployCoreScript is ScriptIO {
    error ChainNotAllowed(uint256 chainId);

    function run() external returns (DeployCore.Deployment memory d) {
        bool local = block.chainid == DeployCore.LOCAL_CHAIN_ID;
        if (!local && block.chainid != DeployGuards.SEPOLIA_CHAIN_ID) {
            revert ChainNotAllowed(block.chainid);
        }
        checkChain();
        // The last block before the deployment: `script/VerifyCore.s.sol` deploys the same build
        // again from this block's state and compares the runtime code of every contract.
        uint256 forkBlock = block.number;
        string memory path = _envString("GENESIS_CONFIG", local ? CORE_GENESIS : "");
        if (bytes(path).length == 0) revert MissingParameter("GENESIS_CONFIG");
        string memory json = _read(path);
        if (!local) {
            (address[] memory singletons, bytes32[] memory codehashes) = safeSingletons();
            DeployGuards.checkHolders(
                json, _read(CORE_GENESIS), singletons, codehashes, safeProxies()
            );
            DeployGuards.checkNoBrake(json);
        }
        DeployCore.Params memory p = params(local);
        DeployCore.Manifest memory manifest = manifestFromEnv(local);

        vm.recordLogs();
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
        VerifyCore.verify(p, d, cfg, json, accepted);
        checkLogs(d, cfg, manifest, calls);

        log(p, d);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) record(p, d, forkBlock);
    }

    /// @notice Reverts unless, among every log recorded in this run, the only minter each token
    ///         added is its genesis minter (`VerifyCore.verifyMinterLogs`), the configurator
    ///         logged the hashes of `cfg`, the manifest and `calls`
    ///         (`VerifyCore.verifyConfigured`), and the manager's logs leave exactly the holders
    ///         and the selector map of `cfg` (`VerifyCore.governanceDifferences`).
    function checkLogs(
        DeployCore.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        DeployCore.Manifest memory manifest,
        GovernanceConfig.Call[] memory calls
    ) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        VerifyCore.verifyMinterLogs(
            d,
            VerifyCore.mintersAdded(logs, address(d.stream)),
            VerifyCore.mintersAdded(logs, address(d.editions))
        );
        VerifyCore.verifyConfigured(
            d, cfg, manifest, calls, VerifyCore.entries(logs, address(d.configurator))
        );
        VerifyCore.requireNoDifference(
            VerifyCore.governanceDifferences(cfg, VerifyCore.entries(logs, address(d.manager)))
        );
    }

    /// @notice Prints every address as `<name>: <address>` (the Sepolia manifest writer reads
    ///         these lines), the manager and the CC0 file ID.
    function log(DeployCore.Params memory p, DeployCore.Deployment memory d) internal pure {
        console2.log(string.concat("CoreFactory: ", vm.toString(d.coreFactory)));
        console2.log(string.concat("WorksAccessManager: ", vm.toString(address(d.manager))));
        string[] memory list = DeployCore.order(p);
        for (uint256 i; i < list.length; ++i) {
            console2.log(
                string.concat(list[i], ": ", vm.toString(DeployCore.addressOf(d, list[i])))
            );
        }
        console2.log(string.concat("cc0TextFileId: ", vm.toString(d.cc0TextFileId)));
    }

    /// @notice Writes every deployed address to `deployments/<chain>/core-<time>.json`, with
    ///         what `script/VerifyCore.s.sol` needs to deploy the same build again: the deployer,
    ///         the delegation contract and the last block before the deployment (`forkBlock`).
    function record(DeployCore.Params memory p, DeployCore.Deployment memory d, uint256 forkBlock)
        internal
    {
        string memory o = "core";
        string[] memory list = DeployCore.order(p);
        vm.serializeAddress(o, "CoreFactory", d.coreFactory);
        vm.serializeAddress(o, "deployer", p.deployer);
        vm.serializeAddress(o, "delegation", p.delegation);
        string memory out = vm.serializeUint(o, "forkBlock", forkBlock);
        for (uint256 i; i < list.length; ++i) {
            out = vm.serializeAddress(o, list[i], DeployCore.addressOf(d, list[i]));
        }
        string memory dir = string.concat("deployments/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        string memory file = string.concat(dir, "/core-", vm.toString(block.timestamp), ".json");
        vm.writeJson(out, file);
        console2.log("recorded ", file);
    }
}
