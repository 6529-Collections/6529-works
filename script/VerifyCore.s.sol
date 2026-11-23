// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { WorksAccessManager } from "src/governance/WorksAccessManager.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { DeployCore } from "./DeployCore.sol";
import { ScriptIO } from "./ScriptIO.sol";
import { VerifyCore } from "./VerifyCore.sol";

/// @title VerifyCoreScript
/// @notice Checks a plain-core deployment against the chain after the broadcast, read-only.
///         It loads a deployment record written by `script/DeployCore.s.sol`, runs every
///         `VerifyCore` readback against the same parameters and genesis file the deploy used
///         (the stored configuration included: the auctions' values, the ETH increment floor and
///         the VRF request parameters), asks the RPC for every `MinterAdded` log of the two
///         tokens since the deployment and requires exactly the two genesis minters, asks it
///         for the governance chain's entries in the statement log and requires exactly the
///         expected epoch-0 manifest,
///         then deploys the same build again, in the script's own memory, from the last block
///         before the deployment (the record's `forkBlock`) and compares the runtime code of
///         every contract with what is on chain. Any foreign code at a predicted address, any
///         different constructor argument and any missing wiring fails it.
/// @dev `forge script script/VerifyCore.s.sol --rpc-url <rpc>` with `DEPLOYMENT` (the record)
///      and the deploy's environment (`GENESIS_CONFIG`, `NETWORK_FEE_RECIPIENT`, `MUSEUM`,
///      `MARKETPLACE_OWNER`, `DEPLOY_NAMESPACE`, `AUCTION_DURATION`, `VRF_*`, `MANIFEST_PATH` or
///      `MANIFEST_DIGEST`, `MANIFEST_URI`). It sends no
///      transaction. A value the deploy was given and this run is not (a shortened
///      `AUCTION_DURATION`, a VRF setting) fails the readback: the stored configuration is
///      compared with this run's parameters. The RPC must serve the state of `forkBlock` (an
///      archive node, or a recent deployment) and `eth_getLogs` from `forkBlock` to the latest
///      block, asked `LOG_BLOCK_RANGE` blocks at a time (default 5,000). Off anvil the network must have accepted: the full governance readback
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
        uint256 forkBlock = vm.parseJsonUint(record, ".forkBlock");
        checkMinters(d, forkBlock);
        console2.log("no minter was ever added but the two genesis minters, from block:", forkBlock);
        checkManifest(d, manifestFromEnv(local), forkBlock);
        console2.log("the governance chain holds exactly the expected epoch-0 manifest");
        uint256 compared = checkCode(p, d, forkBlock);
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

    /// @notice Reverts unless the only minter each token has logged since `forkBlock` is its
    ///         genesis minter (`VerifyCore.verifyMinterLogs`). A minter given to a token's
    ///         constructor that is not a contract of the deployment shows here and nowhere else.
    function checkMinters(DeployCore.Deployment memory d, uint256 forkBlock) public {
        VerifyCore.verifyMinterLogs(
            d,
            mintersAdded(address(d.stream), forkBlock),
            mintersAdded(address(d.editions), forkBlock)
        );
    }

    /// @notice Reverts unless the governance chain in the statement log holds exactly the
    ///         expected epoch-0 manifest (`VerifyCore.verifyManifest`), with the chain's entries
    ///         read from the RPC since `forkBlock`.
    function checkManifest(
        DeployCore.Deployment memory d,
        DeployCore.Manifest memory expected,
        uint256 forkBlock
    ) public {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = IStatementLog.StatementAppended.selector;
        topics[1] = keccak256(abi.encode(address(d.manager), uint256(0)));
        Vm.EthGetLogs[] memory logs = logsSince(d.statementLog, topics, forkBlock);
        VerifyCore.ManifestEntry[] memory entries = new VerifyCore.ManifestEntry[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            entries[i] = VerifyCore.manifestEntry(logs[i].data);
        }
        VerifyCore.verifyManifest(d, expected, entries);
    }

    /// @notice Every minter `token` logged as added (`IModules.MinterAdded`) from `fromBlock` to
    ///         the current block, in order, read from the RPC with `eth_getLogs`.
    function mintersAdded(address token, uint256 fromBlock)
        public
        virtual
        returns (address[] memory added)
    {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = IModules.MinterAdded.selector;
        Vm.EthGetLogs[] memory logs = logsSince(token, topics, fromBlock);
        added = new address[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            added[i] = address(uint160(uint256(logs[i].topics[1])));
        }
    }

    /// @notice Every log of `emitter` with `topics` from `fromBlock` to the current block, in
    ///         order, read from the RPC with `eth_getLogs`, `LOG_BLOCK_RANGE` blocks at a time.
    function logsSince(address emitter, bytes32[] memory topics, uint256 fromBlock)
        public
        virtual
        returns (Vm.EthGetLogs[] memory all)
    {
        uint256 last = block.number;
        uint256 range = _envUint("LOG_BLOCK_RANGE", 5_000);
        if (range == 0) revert MissingParameter("LOG_BLOCK_RANGE");
        for (uint256 from = fromBlock; from <= last; from += range) {
            uint256 to = from + range - 1 < last ? from + range - 1 : last;
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(from, to, emitter, topics);
            Vm.EthGetLogs[] memory grown = new Vm.EthGetLogs[](all.length + logs.length);
            for (uint256 i; i < all.length; ++i) {
                grown[i] = all[i];
            }
            for (uint256 i; i < logs.length; ++i) {
                grown[all.length + i] = logs[i];
            }
            all = grown;
        }
    }

    /// @notice The deployment in `record` (name to address), with the manager and the CC0 file ID
    ///         read from the chain.
    function load(DeployCore.Params memory p, string memory record)
        public
        view
        returns (DeployCore.Deployment memory d)
    {
        d.coreFactory = vm.parseJsonAddress(record, ".CoreFactory");
        // A record with an entropy module is verified with the deploy's VRF settings, so the
        // module is in the list below and is read back like every other contract.
        if (vm.keyExistsJson(record, ".EntropyModule") && p.vrfCoordinator == address(0)) {
            revert MissingParameter("VRF_COORDINATOR");
        }
        string[] memory list = DeployCore.order(p);
        for (uint256 i; i < list.length; ++i) {
            DeployCore.assign(d, list[i], vm.parseJsonAddress(record, string.concat(".", list[i])));
        }
        d.manager = WorksAccessManager(d.configurator.worksManager());
        d.cc0TextFileId = d.workFacts.cc0TextFileId();
    }
}
