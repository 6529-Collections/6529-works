// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { console2 } from "forge-std/console2.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { DeployCore } from "./DeployCore.sol";
import { ScriptIO } from "./ScriptIO.sol";
import { VerifyCore } from "./VerifyCore.sol";

/// @title VerifyCoreScript
/// @notice Reads a plain-core deployment back from the chain, read-only: every address of a
///         deployment record written by `script/DeployCore.s.sol`, checked by `VerifyCore`
///         against the same parameters and genesis file the deploy used (code at every address,
///         the permanent contracts' wiring, genesis modules and minters, the four settings at
///         their launch values and, once the network has accepted, the whole governance
///         configuration).
/// @dev `forge script script/VerifyCore.s.sol --rpc-url <rpc>` with `DEPLOYMENT` (the record)
///      and the deploy's environment (`GENESIS_CONFIG`, `NETWORK_FEE_RECIPIENT`, `MUSEUM`,
///      `MARKETPLACE_OWNER`, `DEPLOY_NAMESPACE`, `VRF_*`). It sends no transaction. The settings
///      are the network's to change at once: this check is for the state right after genesis.
contract VerifyCoreScript is ScriptIO {
    function run() external returns (bool networkAccepted) {
        bool local = block.chainid == DeployCore.LOCAL_CHAIN_ID;
        checkChain();
        DeployCore.Params memory p = params(local);
        string memory record = _read(_envString("DEPLOYMENT", ""));
        DeployCore.Deployment memory d = load(p, record);
        string memory path = _envString("GENESIS_CONFIG", local ? CORE_GENESIS : "");
        if (bytes(path).length == 0) revert MissingParameter("GENESIS_CONFIG");
        GovernanceConfig.Config memory cfg = DeployCore.config(d, _read(path));
        networkAccepted = d.manager.network() == cfg.network;
        VerifyCore.verify(p, d, cfg, networkAccepted);
        console2.log("every contract has code and reads back:", DeployCore.order(p).length);
        console2.log("network accepted and the governance configuration matches:", networkAccepted);
        console2.log(
            "Stream moduleDelay, rescueDelay (s):", d.stream.moduleDelay(), d.stream.rescueDelay()
        );
        console2.log("Editions rebindDelay (s):", d.editions.rebindDelay());
        console2.log("Directory unclaimedPeriod (s):", d.directory.unclaimedPeriod());
    }

    /// @notice The deployment in `record` (name to address), with the manager and the CC0 file ID
    ///         read from the chain.
    function load(DeployCore.Params memory p, string memory record)
        public
        view
        returns (DeployCore.Deployment memory d)
    {
        string[] memory list = DeployCore.order(p);
        for (uint256 i; i < list.length; ++i) {
            DeployCore.assign(d, list[i], vm.parseJsonAddress(record, string.concat(".", list[i])));
        }
        d.manager = WorksAccessManager(d.configurator.worksManager());
        d.cc0TextFileId = d.workFacts.cc0TextFileId();
    }
}
