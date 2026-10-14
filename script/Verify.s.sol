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
///            no stand-ins. On mainnet, the recorded VRF coordinator, Permit2 and delegation
///            contract are the canonical ones with their pinned code (no delegation mock).
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
///            immediate path into `openSale`, `closeSale` and `addLocator`. Off anvil, the
///            entropy module is its VRF subscription's only consumer, and on mainnet the
///            subscription's owner is the hot admin Safe.
///         7. The `GovernanceConfigured` event carries the configuration, manifest and wiring
///            hashes recomputed from the JSON.
///         8. No pending grant-delay or target-admin-delay change other than genesis setting
///            the configured value (OpenZeppelin has no getter for these, ADR 0002).
///         9. Every `RoleGranted` since genesis is a configured holder (or the configurator's
///            own initial ADMIN, renounced).
///         10. No operation scheduled on the manager since genesis is still pending, unless
///            `ALLOW_PENDING_OPERATIONS=1` (then each is logged).
///
///         After a governance change (an admin recovery, a key rotation), set
///         `GOVERNANCE_CONFIG` to a copy of the genesis file with the current holders (epoch
///         mode). Checks 5, 6 and 9 then use it; checks 7 and 8 keep the genesis file; every
///         genesis holder it drops must hold no record for that role any more.
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
    /// @notice On mainnet, a recorded dependency is not the canonical contract.
    error NonCanonicalOnMainnet(string name, address account);
    /// @notice On mainnet, a canonical dependency's code (or its recorded hash) is not the pinned
    ///         code.
    error NonCanonicalCode(string name, address account, bytes32 codehash);
    /// @notice The VRF subscription's consumers are not exactly the entropy module (`count`
    ///         consumers).
    error SubscriptionConsumers(uint256 subscriptionId, uint256 count);
    /// @notice On mainnet, the VRF subscription's owner is not the hot admin Safe.
    error SubscriptionOwner(address owner);
    /// @notice On mainnet, the coordinator does not report the subscription.
    error SubscriptionUnreadable(address coordinator, uint256 subscriptionId);
    /// @notice Epoch mode: a genesis holder the current configuration drops still has a record
    ///         for the role.
    error HolderNotRemoved(uint64 role, address account);
    /// @notice An operation scheduled on the manager since genesis is still pending (neither
    ///         executed, cancelled nor expired). Review it, then set `ALLOW_PENDING_OPERATIONS=1`.
    error PendingOperation(
        bytes32 operationId, address caller, address target, bytes4 selector, uint48 readyAt
    );

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

    /// @notice Every check above against `record`; returns the counts verified. With
    ///         `GOVERNANCE_CONFIG` set (epoch mode), the current-state checks use that file, a
    ///         copy of the genesis file with the holders of a later epoch, while the genesis
    ///         event checks keep the recorded genesis file.
    function verify(string memory record)
        public
        view
        returns (uint256 targets, uint256 calls, uint256 holders)
    {
        bool local = _checkRecordChain(record);
        if (block.chainid == DeployGuards.MAINNET_CHAIN_ID) _checkCanonical(record);
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
        GovernanceConfig.Config memory cfg = DeployV1.config(d, _currentConfig(genesis));
        GovernanceConfig.Call[] memory wired = DeployV1.wiring(d, genesis, manifest);
        if (!local) _checkGuards(record, d, _currentConfig(genesis), cfg, manifest);
        VerifyV1.check(d, cfg, wired);
        if (!local) _checkSubscription(d, cfg, block.chainid == DeployGuards.MAINNET_CHAIN_ID);
        _checkHistory(d, genesis, cfg, wired, manifest, record);
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

    /// @dev On mainnet, every dependency the record names is the canonical contract with its
    ///      pinned code: the VRF coordinator (when the module was deployed), Permit2 and the 6529
    ///      delegation contract, which is no mock.
    function _checkCanonical(string memory record) internal view {
        DeployV1.Params memory p = paramsOf(record);
        if (keccak256(bytes(vm.parseJsonString(record, ".entropy"))) != keccak256("none")) {
            address coordinator = p.vrfCoordinator;
            if (coordinator != DeployGuards.CANONICAL_VRF_COORDINATOR) {
                revert NonCanonicalOnMainnet("VRF_COORDINATOR", coordinator);
            }
            bytes32 pin = DeployGuards.CANONICAL_VRF_COORDINATOR_CODEHASH;
            if (coordinator.codehash != pin) {
                revert NonCanonicalCode("VRF_COORDINATOR", coordinator, coordinator.codehash);
            }
            if (p.vrfCoordinatorCodeHash != pin) {
                revert NonCanonicalCode("VRF_COORDINATOR", coordinator, p.vrfCoordinatorCodeHash);
            }
        }
        if (p.permit2 != DeployV1.CANONICAL_PERMIT2) {
            revert NonCanonicalOnMainnet("PERMIT2", p.permit2);
        }
        if (p.permit2.code.length == 0) revert NonCanonicalCode("PERMIT2", p.permit2, bytes32(0));
        if (p.delegation != DeployGuards.CANONICAL_DELEGATION) {
            revert NonCanonicalOnMainnet("DELEGATION_CONTRACT", p.delegation);
        }
        if (
            p.delegation.codehash != DeployGuards.CANONICAL_DELEGATION_CODEHASH
                || vm.parseJsonBool(record, ".delegationMock")
        ) revert NonCanonicalCode("DELEGATION_CONTRACT", p.delegation, p.delegation.codehash);
    }

    /// @dev The live entropy module's VRF subscription, read from its current coordinator when
    ///      the coordinator reports it (`getSubscription`, Chainlink v2.5): the module is the only
    ///      consumer. On `mainnet` the owner must be the hot admin Safe, the configured holder of
    ///      both ADMIN and PARAMETER_SETTER (which moves the module between subscriptions), and a
    ///      coordinator that does not report the subscription fails.
    function _checkSubscription(
        DeployV1.Deployment memory d,
        GovernanceConfig.Config memory cfg,
        bool mainnet
    ) internal view {
        if (address(d.entropyModule) == address(0)) return;
        address coordinator = d.entropyModule.coordinator();
        uint256 id = d.entropyModule.config().subscriptionId;
        (bool ok, bytes memory ret) =
            coordinator.staticcall(abi.encodeWithSignature("getSubscription(uint256)", id));
        if (!ok || ret.length < 192) {
            if (mainnet) revert SubscriptionUnreadable(coordinator, id);
            return;
        }
        (,,, address owner, address[] memory consumers) =
            abi.decode(ret, (uint96, uint96, uint64, address, address[]));
        if (consumers.length != 1 || consumers[0] != address(d.entropyModule)) {
            revert SubscriptionConsumers(id, consumers.length);
        }
        if (
            mainnet
                && !(_holds(cfg, Roles.ADMIN, owner) && _holds(cfg, Roles.PARAMETER_SETTER, owner))
        ) revert SubscriptionOwner(owner);
    }

    function _holds(GovernanceConfig.Config memory cfg, uint64 role, address account)
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < cfg.grants.length; ++i) {
            if (cfg.grants[i].role == role && cfg.grants[i].account == account) return true;
        }
        return false;
    }

    /// @dev Checks 7 to 10, from the manager's and the configurator's events since genesis.
    ///      `genesis` is the genesis file, `cfg` the current configuration (the genesis one
    ///      outside epoch mode).
    function _checkHistory(
        DeployV1.Deployment memory d,
        string memory genesis,
        GovernanceConfig.Config memory cfg,
        GovernanceConfig.Call[] memory wired,
        DeployV1.Manifest memory manifest,
        string memory record
    ) internal view {
        GovernanceConfig.Config memory initial = DeployV1.config(d, genesis);
        uint256 fromBlock = vm.parseJsonUint(record, ".startBlock");
        _checkConfigured(d, initial, wired, manifest, fromBlock);
        _checkPendingDelays(d, fromBlock);
        _checkGrants(d, initial, cfg, fromBlock);
        _checkRemoved(d, initial, cfg);
        _checkPendingOperations(d, fromBlock);
    }

    /// @dev The file at `GOVERNANCE_CONFIG` (epoch mode), or the genesis file.
    function _currentConfig(string memory genesis) internal view returns (string memory) {
        string memory path = _env("GOVERNANCE_CONFIG");
        return bytes(path).length == 0 ? genesis : _read(path);
    }

    /// @dev Epoch mode: every genesis holder the current configuration drops holds no record
    ///      for that role any more (revoked or renounced).
    function _checkRemoved(
        DeployV1.Deployment memory d,
        GovernanceConfig.Config memory initial,
        GovernanceConfig.Config memory cfg
    ) internal view {
        for (uint256 i; i < initial.grants.length; ++i) {
            GovernanceConfig.Grant memory g = initial.grants[i];
            if (_holds(cfg, g.role, g.account)) continue;
            if (GovernanceConfig.hasRecord(d.manager, g.role, g.account)) {
                revert HolderNotRemoved(g.role, g.account);
            }
        }
    }

    /// @dev Every operation scheduled on the manager since genesis that can still execute
    ///      (`getSchedule` nonzero for its latest nonce). Fails on the first, unless
    ///      `ALLOW_PENDING_OPERATIONS=1`, which logs each one instead.
    function _checkPendingOperations(DeployV1.Deployment memory d, uint256 fromBlock)
        internal
        view
    {
        bool allowed = _envUint("ALLOW_PENDING_OPERATIONS", 0) == 1;
        Vm.EthGetLogs[] memory logs = _logs(
            fromBlock,
            address(d.manager),
            keccak256("OperationScheduled(bytes32,uint32,uint48,address,address,bytes)")
        );
        for (uint256 i; i < logs.length; ++i) {
            bytes32 id = logs[i].topics[1];
            uint48 readyAt = d.manager.getSchedule(id);
            if (readyAt != 0 && d.manager.getNonce(id) == uint32(uint256(logs[i].topics[2]))) {
                _pending(id, readyAt, logs[i].data, allowed);
            }
        }
    }

    function _pending(bytes32 id, uint48 readyAt, bytes memory logData, bool allowed)
        internal
        pure
    {
        (, address caller, address target, bytes memory data) =
            abi.decode(logData, (uint48, address, address, bytes));
        // Casting to bytes4 is safe: it keeps the selector, the first four bytes.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = data.length < 4 ? bytes4(0) : bytes4(data);
        if (!allowed) revert PendingOperation(id, caller, target, selector, readyAt);
        console2.log("pending operation", vm.toString(id));
        console2.log("  caller, target", caller, target);
        console2.log("  selector, ready at", vm.toString(selector), uint256(readyAt));
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

    /// @dev Every `RoleGranted` since genesis is a holder of the genesis or the current
    ///      configuration, the configurator's own initial ADMIN, or (epoch mode only) an account
    ///      that no longer holds the role, such as an intermediate holder since replaced.
    function _checkGrants(
        DeployV1.Deployment memory d,
        GovernanceConfig.Config memory initial,
        GovernanceConfig.Config memory cfg,
        uint256 fromBlock
    ) internal view {
        Vm.EthGetLogs[] memory logs = _logs(
            fromBlock,
            address(d.manager),
            keccak256("RoleGranted(uint64,address,uint32,uint48,bool)")
        );
        bool epoch = keccak256(abi.encode(initial)) != keccak256(abi.encode(cfg));
        for (uint256 i; i < logs.length; ++i) {
            uint64 role = uint64(uint256(logs[i].topics[1]));
            address account = address(uint160(uint256(logs[i].topics[2])));
            bool expected = (role == Roles.ADMIN && account == address(d.configurator))
                || _holds(initial, role, account) || _holds(cfg, role, account)
                || (epoch && !GovernanceConfig.hasRecord(d.manager, role, account));
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
