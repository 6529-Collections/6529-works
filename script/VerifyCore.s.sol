// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { console2 } from "forge-std/console2.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { DeployCore } from "./DeployCore.sol";
import { ScriptIO } from "./ScriptIO.sol";
import { VerifyCore } from "./VerifyCore.sol";

/// @title VerifyCoreScript
/// @notice Checks a plain-core deployment against the chain after the broadcast, read-only.
///         It loads a deployment record written by `script/DeployCore.s.sol`, runs every
///         `VerifyCore` readback against the same parameters and genesis file the deploy used,
///         then deploys the same build again, in the script's own memory, from the last block
///         before the deployment (the record's `forkBlock`) and compares the runtime code of
///         every contract with what is on chain. Any foreign code at a predicted address, any
///         different constructor argument and any missing wiring fails it.
/// @dev `forge script script/VerifyCore.s.sol --rpc-url <rpc>` with `DEPLOYMENT` (the record)
///      and the deploy's environment (`GENESIS_CONFIG`, `NETWORK_FEE_RECIPIENT`, `MUSEUM`,
///      `MARKETPLACE_OWNER`, `DEPLOY_NAMESPACE`, `AUCTION_DURATION`, `VRF_*`). It sends no
///      transaction. The RPC must serve the state of `forkBlock` (an archive node, or a recent
///      deployment). Off anvil the network must have accepted: the full governance readback
///      is part of the check. The settings are the network's to change at once: this check is
///      for the state right after genesis.
contract VerifyCoreScript is ScriptIO {
    /// @notice Off anvil, the network has not accepted yet, so the governance readback cannot run.
    error NetworkNotAccepted(address pending);

    function run() external returns (bool networkAccepted) {
        bool local = block.chainid == DeployCore.LOCAL_CHAIN_ID;
        checkChain();
        string memory record = _read(_envString("DEPLOYMENT", ""));
        DeployCore.Params memory p = params(local);
        p.deployer = vm.parseJsonAddress(record, ".deployer");
        p.delegation = vm.parseJsonAddress(record, ".delegation");
        DeployCore.Deployment memory d = load(p, record);
        string memory path = _envString("GENESIS_CONFIG", local ? CORE_GENESIS : "");
        if (bytes(path).length == 0) revert MissingParameter("GENESIS_CONFIG");
        string memory json = _read(path);
        GovernanceConfig.Config memory cfg = DeployCore.config(d, json);
        networkAccepted = d.manager.network() == cfg.network;
        if (!local && !networkAccepted) revert NetworkNotAccepted(d.manager.pendingNetwork());
        VerifyCore.verify(p, d, cfg, json, networkAccepted);
        console2.log("every contract has code and reads back:", DeployCore.order(p).length);
        console2.log("network accepted and the governance configuration matches:", networkAccepted);
        console2.log(
            "Stream moduleDelay, rescueDelay (s):", d.stream.moduleDelay(), d.stream.rescueDelay()
        );
        console2.log("Editions rebindDelay (s):", d.editions.rebindDelay());
        console2.log("Directory unclaimedPeriod (s):", d.directory.unclaimedPeriod());
        uint256 compared = checkCode(p, d, vm.parseJsonUint(record, ".forkBlock"));
        console2.log("runtime code equal to the build's, contracts:", compared);
    }

    /// @notice Deploys the same build with the same parameters from the state of `forkBlock`
    ///         and compares every contract's address and runtime code with the chain's.
    ///         External contracts the constructors read (the delegation contract, the VRF
    ///         coordinator) are copied into that state if they did not exist yet then.
    /// @return The number of contracts compared.
    function checkCode(
        DeployCore.Params memory p,
        DeployCore.Deployment memory d,
        uint256 forkBlock
    ) public returns (uint256) {
        bytes32[] memory actual = VerifyCore.codeHashes(p, d);
        bytes memory delegationCode = p.delegation.code;
        bytes memory coordinatorCode = p.vrfCoordinator.code;
        vm.rollFork(forkBlock);
        if (p.delegation.code.length == 0) vm.etch(p.delegation, delegationCode);
        if (p.vrfCoordinator != address(0) && p.vrfCoordinator.code.length == 0) {
            vm.etch(p.vrfCoordinator, coordinatorCode);
        }
        vm.startPrank(p.deployer);
        DeployCore.Deployment memory ref = DeployCore.deploy(p, DeployCore.CREATE2_FACTORY);
        vm.stopPrank();
        ref.manager = WorksAccessManager(ref.configurator.worksManager());
        VerifyCore.checkCode(p, d, actual, ref, VerifyCore.codeHashes(p, ref));
        return actual.length;
    }

    /// @notice The deployment in `record` (name to address), with the manager and the CC0 file ID
    ///         read from the chain.
    function load(DeployCore.Params memory p, string memory record)
        public
        view
        returns (DeployCore.Deployment memory d)
    {
        d.coreFactory = vm.parseJsonAddress(record, ".CoreFactory");
        string[] memory list = DeployCore.order(p);
        for (uint256 i; i < list.length; ++i) {
            DeployCore.assign(d, list[i], vm.parseJsonAddress(record, string.concat(".", list[i])));
        }
        d.manager = WorksAccessManager(d.configurator.worksManager());
        d.cc0TextFileId = d.workFacts.cc0TextFileId();
    }
}
