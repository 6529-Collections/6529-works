// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { Roles } from "src/governance/Roles.sol";
import { DeployV1 } from "./DeployV1.sol";
import { VerifyV1 } from "./VerifyV1.sol";

/// @title Verify
/// @notice Reads a recorded deployment back against its genesis configuration. Run it against
///         the chain the deployment is on, at least `minSetback()` (5 days) after genesis:
///
///         DEPLOYMENT=deployments/<chainId>/<timestamp>.json \
///           forge script script/Verify.s.sol --rpc-url <rpc>
///
///         Checks, failing on the first difference:
///         1. `VerifyV1.check`: every role, holder, delay and selector (`configurator.verify`),
///            no role left with the configurator, every target's authority, every wired getter
///            (`workRecords()`, `editions()`, `stream()`, `packageRegistry()`,
///            `splitFactory()`, `isAdmittedMinter`, the adapters' targets, the epoch-0
///            manifest), and PLATFORM's immediate path into `openSale`, `closeSale` and
///            `addLocator`;
///         2. the `GovernanceConfigured` event: the configuration hash and `wiringHash`
///            recomputed from the JSON, and the manifest hash;
///         3. no pending grant-delay or target-admin-delay change other than genesis setting
///            the configured value (OpenZeppelin has no getter for these, ADR 0002);
///         4. every `RoleGranted` since genesis is a configured holder (or the configurator's
///            own initial ADMIN, renounced);
///         5. every recorded code hash matches the chain.
contract Verify is Script {
    error MissingGovernanceConfigured();
    error HashMismatch(string what, bytes32 expected, bytes32 actual);
    error PendingGrantDelayChange(uint64 role, uint32 delay, uint48 effect);
    error PendingTargetAdminDelayChange(address target, uint32 delay, uint48 effect);
    error UnexpectedGrant(uint64 role, address account);
    error CodeHashMismatch(string name, address account);

    function run() external view {
        string memory record = vm.readFile(vm.envString("DEPLOYMENT"));
        DeployV1.Deployment memory d = load(record);
        string memory genesis = vm.readFile(vm.parseJsonString(record, ".genesisConfig"));
        DeployV1.Manifest memory manifest = DeployV1.Manifest(
            vm.parseJsonBytes32(record, ".manifestDigest"),
            vm.parseJsonString(record, ".manifestUri")
        );
        GovernanceConfig.Config memory cfg = DeployV1.config(d, genesis);
        GovernanceConfig.Call[] memory calls = DeployV1.wiring(d, genesis, manifest);
        uint256 fromBlock = vm.parseJsonUint(record, ".startBlock");

        VerifyV1.check(d, cfg, calls);
        _checkConfigured(d, cfg, calls, manifest, fromBlock);
        _checkPendingDelays(d, fromBlock);
        _checkGrants(d, cfg, fromBlock);
        _checkCodeHashes(record);

        console2.log("verified: targets", cfg.targets.length);
        console2.log("verified: wiring calls", calls.length);
        console2.log("verified: holders", cfg.grants.length);
    }

    /// @notice The recorded deployment's addresses.
    function load(string memory record) public view returns (DeployV1.Deployment memory d) {
        string[22] memory names = DeployV1.names();
        for (uint256 i; i < names.length; ++i) {
            string memory key = string.concat(".contracts.", names[i], ".address");
            if (vm.keyExistsJson(record, key)) {
                DeployV1.assign(d, names[i], vm.parseJsonAddress(record, key));
            }
        }
    }

    function _logs(uint256 fromBlock, address emitter, bytes32 topic)
        internal
        view
        returns (Vm.EthGetLogs[] memory)
    {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = topic;
        return vm.eth_getLogs(fromBlock, vm.getBlockNumber(), emitter, topics);
    }

    function _checkConfigured(
        DeployV1.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        GovernanceConfig.Call[] memory calls,
        DeployV1.Manifest memory manifest,
        uint256 fromBlock
    ) internal view {
        Vm.EthGetLogs[] memory logs = _logs(
            fromBlock, address(d.configurator), GovernanceConfigurator.GovernanceConfigured.selector
        );
        if (logs.length != 1) revert MissingGovernanceConfigured();
        Vm.EthGetLogs memory log = logs[0];
        _same("configHash", keccak256(abi.encode(cfg)), log.topics[2]);
        _same("manifestHash", manifest.digest, log.topics[3]);
        _same("wiringHash", keccak256(abi.encode(calls)), abi.decode(log.data, (bytes32)));
    }

    function _checkPendingDelays(DeployV1.Deployment memory d, uint256 fromBlock) internal view {
        address m = address(d.manager);
        Vm.EthGetLogs[] memory grants =
            _logs(fromBlock, m, keccak256("RoleGrantDelayChanged(uint64,uint32,uint48)"));
        for (uint256 i; i < grants.length; ++i) {
            uint64 role = uint64(uint256(grants[i].topics[1]));
            (uint32 delay, uint48 effect) = abi.decode(grants[i].data, (uint32, uint48));
            // Only "is the change still pending" matters here; seconds of skew are irrelevant.
            // forge-lint: disable-next-line(block-timestamp)
            if (effect > block.timestamp && delay != Roles.grantDelay(role)) {
                revert PendingGrantDelayChange(role, delay, effect);
            }
        }
        Vm.EthGetLogs[] memory targets =
            _logs(fromBlock, m, keccak256("TargetAdminDelayUpdated(address,uint32,uint48)"));
        for (uint256 i; i < targets.length; ++i) {
            address target = address(uint160(uint256(targets[i].topics[1])));
            (uint32 delay, uint48 effect) = abi.decode(targets[i].data, (uint32, uint48));
            // forge-lint: disable-next-line(block-timestamp)
            if (effect > block.timestamp && delay != GovernanceConfig.TARGET_ADMIN_DELAY) {
                revert PendingTargetAdminDelayChange(target, delay, effect);
            }
        }
    }

    function _checkGrants(
        DeployV1.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        uint256 fromBlock
    ) internal view {
        Vm.EthGetLogs[] memory logs = _logs(
            fromBlock,
            address(d.manager),
            keccak256("RoleGranted(uint64,address,uint32,uint48,bool)")
        );
        for (uint256 i; i < logs.length; ++i) {
            uint64 role = uint64(uint256(logs[i].topics[1]));
            address account = address(uint160(uint256(logs[i].topics[2])));
            bool expected = role == Roles.ADMIN && account == address(d.configurator);
            for (uint256 j; j < cfg.grants.length && !expected; ++j) {
                expected = cfg.grants[j].role == role && cfg.grants[j].account == account;
            }
            if (!expected) revert UnexpectedGrant(role, account);
        }
    }

    function _checkCodeHashes(string memory record) internal view {
        string[22] memory names = DeployV1.names();
        for (uint256 i; i < names.length; ++i) {
            string memory base = string.concat(".contracts.", names[i]);
            if (!vm.keyExistsJson(record, string.concat(base, ".address"))) continue;
            address a = vm.parseJsonAddress(record, string.concat(base, ".address"));
            if (a.codehash != vm.parseJsonBytes32(record, string.concat(base, ".codehash"))) {
                revert CodeHashMismatch(names[i], a);
            }
        }
    }

    function _same(string memory what, bytes32 expected, bytes32 actual) internal pure {
        if (expected != actual) revert HashMismatch(what, expected, actual);
    }
}
