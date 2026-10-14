// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { GovernanceConfigurator } from "src/governance/GovernanceConfigurator.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { DeployGuards } from "./DeployGuards.sol";
import { DeployV1 } from "./DeployV1.sol";
import { ScriptIO } from "./ScriptIO.sol";
import { VerifyV1 } from "./VerifyV1.sol";

/// @title Verify
/// @notice Confirms a recorded deployment against the chain. Run it against the chain the
///         deployment is on, at least `minSetback()` (5 days) after genesis:
///
///         DEPLOYMENT=deployments/<chainId>/<timestamp>.json \
///           forge script script/Verify.s.sol --rpc-url <rpc>
///
///         The record is only an index: every check recomputes from the chain and the
///         committed inputs, failing on the first difference.
///         1. The RPC is on the recorded chain; off anvil, the record has no placeholders and
///            no stand-ins.
///         2. Every recorded address is where CREATE2 puts that contract given the recorded
///            constructor parameters and CREATE2 deployer (`DeployV1.predict`, which reads
///            each pinned code hash from the chain), and every recorded code hash is on chain.
///         3. The default license (`VerifyV1.checkCc0`): WorkRecords and every product's
///            default name the recorded CC0 file, complete, hashing to the recorded digest;
///            off anvil that digest must be the pinned canonical one.
///         4. The manifest file (`MANIFEST_PATH`, by default the recorded path) hashes to the
///            recorded manifest digest; required off anvil.
///         5. Off anvil, the genesis file still matches the committed policy and names nothing
///            the deployment lacks, and its holders pass the deploy's holder guards against the
///            chain as it is now: Safes, signer separation, no deployment contract
///            (`DeployGuards.checkHolders`, `checkHoldersAgainst`).
///         6. `VerifyV1.check`: every role, holder, delay and selector, no role left with the
///            configurator, every target's authority, every wired getter, and PLATFORM's
///            immediate path into `openSale`, `closeSale` and `addLocator`.
///         7. The `GovernanceConfigured` event carries the configuration, manifest and wiring
///            hashes recomputed from the JSON.
///         8. No pending grant-delay or target-admin-delay change other than genesis setting
///            the configured value (OpenZeppelin has no getter for these, ADR 0002).
///         9. Every `RoleGranted` since genesis is a configured holder (or the configurator's
///            own initial ADMIN, renounced).
contract Verify is ScriptIO {
    error MissingParameter(string name);
    error WrongChain(uint256 recorded, uint256 actual);
    error PlaceholdersOffAnvil();
    error StandInsOffAnvil(string name);
    error Cc0NotCanonical(bytes32 recorded, bytes32 pinned);
    error MissingGovernanceConfigured();
    error HashMismatch(string what, bytes32 expected, bytes32 actual);
    error PendingGrantDelayChange(uint64 role, uint32 delay, uint48 effect);
    error PendingTargetAdminDelayChange(address target, uint32 delay, uint48 effect);
    error UnexpectedGrant(uint64 role, address account);
    error CodeHashMismatch(string name, address account);

    string internal constant EXAMPLE_GENESIS = "config/genesis.example.json";

    function run() external {
        checkChain();
        string memory path = _env("DEPLOYMENT");
        if (bytes(path).length == 0) revert MissingParameter("DEPLOYMENT");
        (uint256 targets, uint256 calls, uint256 holders) = verify(_read(path));
        console2.log("verified: targets", targets);
        console2.log("verified: wiring calls", calls);
        console2.log("verified: holders", holders);
    }

    /// @notice Every check above against `record`; returns the counts verified.
    function verify(string memory record)
        public
        view
        returns (uint256 targets, uint256 calls, uint256 holders)
    {
        bool local = _checkRecordChain(record);
        DeployV1.Deployment memory d = load(record);
        VerifyV1.checkAddresses(
            DeployV1.predict(
                paramsOf(record), d.cc0TextFileId, vm.parseJsonAddress(record, ".params.factory")
            ),
            d
        );
        _checkCodeHashes(record);
        _checkCc0(d, record, local);
        DeployV1.Manifest memory manifest = _checkManifest(record, local);

        string memory genesis = _read(vm.parseJsonString(record, ".genesisConfig"));
        GovernanceConfig.Config memory cfg = DeployV1.config(d, genesis);
        GovernanceConfig.Call[] memory wired = DeployV1.wiring(d, genesis, manifest);
        if (!local) _checkGuards(record, d, genesis, cfg, manifest);
        VerifyV1.check(d, cfg, wired);
        uint256 fromBlock = vm.parseJsonUint(record, ".startBlock");
        _checkConfigured(d, cfg, wired, manifest, fromBlock);
        _checkPendingDelays(d, fromBlock);
        _checkGrants(d, cfg, fromBlock);
        return (cfg.targets.length, wired.length, cfg.grants.length);
    }

    /// @notice The recorded deployment's addresses and CC0 file ID.
    function load(string memory record) public view returns (DeployV1.Deployment memory d) {
        d.cc0TextFileId = vm.parseJsonBytes32(record, ".cc0TextFileId");
        string[] memory names = DeployV1.names();
        for (uint256 i; i < names.length; ++i) {
            string memory key = string.concat(".contracts.", names[i], ".address");
            if (vm.keyExistsJson(record, key)) {
                DeployV1.assign(d, names[i], vm.parseJsonAddress(record, key));
            }
        }
    }

    /// @notice The recorded constructor parameters (all but the CC0 text, whose file ID and
    ///         digest are recorded instead).
    function paramsOf(string memory record) public pure returns (DeployV1.Params memory p) {
        p.deployer = _address(record, "deployer");
        p.namespace = vm.parseJsonBytes32(record, ".params.namespace");
        p.feeRecipient = _address(record, "networkFeeRecipient");
        p.marketOwner = _address(record, "marketOwner");
        p.delegation = _address(record, "delegation");
        p.ethIncrementFloor = vm.parseUint(vm.parseJsonString(record, ".params.ethIncrementFloor"));
        p.permit2 = _address(record, "permit2");
        p.auction = IEnglishAuction.AuctionConfig(
            SafeCast.toUint32(_uint(record, "auctionDuration")),
            SafeCast.toUint32(_uint(record, "auctionExtensionWindow")),
            SafeCast.toUint32(_uint(record, "auctionIncrementShare"))
        );
        p.vrfCoordinator = _address(record, "vrfCoordinator");
        p.vrfCoordinatorCodeHash = vm.parseJsonBytes32(record, ".params.vrfCoordinatorCodeHash");
        p.vrf = VrfEntropyModule.VrfConfig(
            vm.parseUint(vm.parseJsonString(record, ".params.vrfSubscriptionId")),
            vm.parseJsonBytes32(record, ".params.vrfKeyHash"),
            SafeCast.toUint32(_uint(record, "vrfCallbackGasLimit")),
            SafeCast.toUint16(_uint(record, "vrfConfirmations")),
            vm.parseJsonBool(record, ".params.vrfNativePayment")
        );
        p.vrfRetryDelay = SafeCast.toUint64(_uint(record, "vrfRetryDelay"));
    }

    function _address(string memory record, string memory key) private pure returns (address) {
        return vm.parseJsonAddress(record, string.concat(".params.", key));
    }

    function _uint(string memory record, string memory key) private pure returns (uint256) {
        return vm.parseJsonUint(record, string.concat(".params.", key));
    }

    /// @dev Check 5: the deploy's off-anvil guards, repeated against the chain as it is now.
    function _checkGuards(
        string memory record,
        DeployV1.Deployment memory d,
        string memory genesis,
        GovernanceConfig.Config memory cfg,
        DeployV1.Manifest memory manifest
    ) internal view {
        string memory example = _read(EXAMPLE_GENESIS);
        DeployGuards.checkNothingDropped(
            d,
            genesis,
            keccak256(bytes(vm.parseJsonString(record, ".entropy"))) == keccak256("none")
        );
        DeployGuards.checkPolicy(d, genesis, example, manifest);
        DeployGuards.checkHolders(genesis, example);
        DeployGuards.checkHoldersAgainst(d, paramsOf(record), cfg);
    }

    /// @dev The record is for this chain; off anvil it carries no placeholder or stand-in.
    function _checkRecordChain(string memory record) internal view returns (bool local) {
        uint256 recorded = vm.parseJsonUint(record, ".chainId");
        if (recorded != block.chainid) revert WrongChain(recorded, block.chainid);
        local = block.chainid == DeployV1.LOCAL_CHAIN_ID;
        if (local) return true;
        if (vm.parseJsonBool(record, ".placeholders")) revert PlaceholdersOffAnvil();
        string[] memory standIns = vm.parseJsonStringArray(record, ".standIns");
        if (standIns.length != 0) revert StandInsOffAnvil(standIns[0]);
    }

    function _checkCc0(DeployV1.Deployment memory d, string memory record, bool local)
        internal
        view
    {
        bytes32 digest = vm.parseJsonBytes32(record, ".cc0TextSha256");
        bytes32 pinned = cc0Digest();
        if (!local && (pinned == bytes32(0) || digest != pinned)) {
            revert Cc0NotCanonical(digest, pinned);
        }
        VerifyV1.checkCc0(d, digest);
    }

    /// @dev The manifest file hashes to the recorded digest; off anvil it is required.
    function _checkManifest(string memory record, bool local)
        internal
        view
        returns (DeployV1.Manifest memory manifest)
    {
        manifest = DeployV1.Manifest(
            vm.parseJsonBytes32(record, ".manifestDigest"),
            vm.parseJsonString(record, ".manifestUri")
        );
        string memory path =
            _envString("MANIFEST_PATH", vm.parseJsonString(record, ".manifestPath"));
        if (bytes(path).length == 0) {
            if (!local) revert MissingParameter("MANIFEST_PATH");
            return manifest;
        }
        _same("manifest file", manifest.digest, sha256(_readBinary(path)));
    }

    /// @dev Logs of `emitter` with first topic `topic` from `fromBlock` on.
    function _logs(uint256 fromBlock, address emitter, bytes32 topic)
        internal
        view
        virtual
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
        string[] memory names = DeployV1.names();
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
