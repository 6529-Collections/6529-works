// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Deploy } from "script/Deploy.s.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { DeployHarness, VerifyHarness } from "../deploy/ScriptHarness.sol";
import { Forks, IVrfSubscriptions } from "./WorksForkBase.sol";

/// @notice The full deploy script simulated against a Sepolia fork with sepolia-r2's inputs: its
///         holders (the real Safes behind the admins and guardians, its signer and operator
///         keys) on the committed policy, its network fee recipient and marketplace owner, the
///         official 6529 delegation contract, the canonical Permit2, the real VRF v2.5
///         coordinator with r2's gas lane (and a new subscription, as the runbook creates for
///         each deployment), and r2's epoch-0 manifest, under a fresh namespace. Every off-anvil
///         guard must pass against the live accounts, and `Verify.s.sol` must confirm the
///         simulated deployment five days later. Nothing is broadcast: the run happens in the
///         fork.
///
///         The genesis is `config/genesis.example.json` with r2's holders, as a new rehearsal's
///         would be. r2's own file predates later policy changes (the governed selectors
///         `Stream.releaseContent` and `EntropyModule.lowerCallbackGasLimit`, and the `manager`
///         section), so the committed-policy guard refuses it as it stands; its holders alone
///         are checked against the live Safes.
/// @dev Opt-in: skipped unless `FORK_SEPOLIA_RPC` is set (`FORK_SEPOLIA_RPC_BLOCK` pins the
///      block). See `test/fork/README.md`.
contract DeploySimulationSepoliaForkTest is Test {
    string internal constant R2_RECORD = "deployments/11155111/1791750816.json";
    string internal constant R2_GENESIS = "config/sepolia-r2/genesis.json";
    string internal constant R2_MANIFEST = "config/sepolia-r2/manifest-epoch0.json";
    string internal constant EXAMPLE = "config/genesis.example.json";
    /// @dev Served by the harnesses, not written to disk.
    string internal constant GENESIS = "config/genesis.fork-simulation.json";
    uint256 internal constant SEPOLIA = 11_155_111;

    DeployHarness internal deployer;
    VerifyHarness internal verifier;
    string internal r2;
    bool internal forked;
    address internal subscriptionOwner = makeAddr("forkSimulationSubscriptionOwner");
    uint256 internal subscriptionId;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        Forks.select(vm, rpc, vm.envOr("FORK_SEPOLIA_RPC_BLOCK", uint256(0)));
        require(block.chainid == SEPOLIA, "the RPC serves another chain");
        forked = true;
        deployer = new DeployHarness();
        verifier = new VerifyHarness();
        r2 = vm.readFile(R2_RECORD);
        bytes memory genesis = bytes(_committedPolicyWithR2Holders());
        deployer.setFile(GENESIS, genesis);
        verifier.setFile(GENESIS, genesis);
        _env("GENESIS_CONFIG", GENESIS);
        _env("DEPLOY_NAMESPACE", vm.toString(keccak256("6529-works/sepolia/fork-simulation")));
        _env("NETWORK_FEE_RECIPIENT", vm.toString(_r2Address("networkFeeRecipient")));
        _env("MARKETPLACE_OWNER", vm.toString(_r2Address("marketOwner")));
        _env("VRF_COORDINATOR", vm.toString(_r2Address("vrfCoordinator")));
        _env("VRF_SUBSCRIPTION_ID", vm.toString(_newSubscription()));
        _env("VRF_KEY_HASH", vm.toString(vm.parseJsonBytes32(r2, ".params.vrfKeyHash")));
        _env("VRF_CALLBACK_GAS_LIMIT", vm.toString(_r2Uint("vrfCallbackGasLimit")));
        _env("VRF_CONFIRMATIONS", vm.toString(_r2Uint("vrfConfirmations")));
        _env("VRF_NATIVE_PAYMENT", vm.parseJsonBool(r2, ".params.vrfNativePayment") ? "1" : "0");
        _env("MANIFEST_PATH", R2_MANIFEST);
        _env("MANIFEST_URI", vm.parseJsonString(r2, ".manifestUri"));
    }

    /// @dev The committed example with each placeholder holder replaced by r2's holder of the
    ///      same role, in order (hot then cold admin, the three guardians, the two curation
    ///      signers, the storage operator, the platform and the curator).
    function _committedPolicyWithR2Holders() internal view returns (string memory json) {
        json = vm.readFile(EXAMPLE);
        string memory holders = vm.readFile(R2_GENESIS);
        uint16[10] memory placeholders =
            [0xb001, 0xb002, 0xb011, 0xb012, 0xb013, 0xb021, 0xb022, 0xb031, 0xb051, 0xb061];
        string[10] memory roles = [
            "ADMIN",
            "ADMIN",
            "GUARDIAN",
            "GUARDIAN",
            "GUARDIAN",
            "CURATION_SIGNER",
            "CURATION_SIGNER",
            "STORAGE_OPERATOR",
            "PLATFORM",
            "CURATOR"
        ];
        for (uint256 i; i < placeholders.length; ++i) {
            uint256 nth;
            for (uint256 j; j < i; ++j) {
                if (keccak256(bytes(roles[j])) == keccak256(bytes(roles[i]))) ++nth;
            }
            string memory from = vm.toLowercase(vm.toString(address(uint160(placeholders[i]))));
            json = vm.replace(json, from, vm.toString(_holder(holders, roles[i], nth)));
        }
    }

    /// @dev The `nth` holder of `role` in a genesis file.
    function _holder(string memory json, string memory role, uint256 nth)
        internal
        view
        returns (address)
    {
        for (uint256 j; vm.keyExistsJson(json, _at(j, "")); ++j) {
            if (
                keccak256(bytes(vm.parseJsonString(json, _at(j, ".role"))))
                    != keccak256(bytes(role))
            ) {
                continue;
            }
            if (nth == 0) return vm.parseJsonAddress(json, _at(j, ".account"));
            --nth;
        }
        revert(string.concat("no such holder in r2's genesis: ", role));
    }

    function _at(uint256 j, string memory field) internal pure returns (string memory) {
        return string.concat(".holders[", vm.toString(j), "]", field);
    }

    /// @dev As the runbook does before a deployment: a new subscription on the coordinator,
    ///      funded in native ETH, whose only consumer will be the new entropy module.
    function _newSubscription() internal returns (uint256 id) {
        IVrfSubscriptions coordinator = IVrfSubscriptions(_r2Address("vrfCoordinator"));
        vm.deal(subscriptionOwner, 10 ether);
        vm.startPrank(subscriptionOwner);
        id = coordinator.createSubscription();
        coordinator.fundSubscriptionWithNative{ value: 1 ether }(id);
        vm.stopPrank();
        subscriptionId = id;
    }

    function _env(string memory name, string memory value) internal {
        deployer.setEnv(name, value);
    }

    function _r2Address(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(r2, string.concat(".params.", key));
    }

    function _r2Uint(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(r2, string.concat(".params.", key));
    }

    modifier onFork() {
        if (!forked) vm.skip(true, "FORK_SEPOLIA_RPC is not set");
        _;
    }

    /// @dev `prepare` runs every check made before the first transaction against the live
    ///      chain: the RPC's chain ID, the genesis holders (deployed Safes with thresholds and
    ///      disjoint signers), an existing fee recipient, dependencies with code, the pinned CC0
    ///      text and the manifest.
    function test_TheGuardsPassWithTheR2SafesAndDependencies() public onFork {
        Deploy.Run memory r = deployer.prepare();
        assertFalse(r.local);
        assertEq(r.p.delegation, DeployGuards.SEPOLIA_DELEGATION, "the official delegation");
        assertEq(r.p.delegation.codehash, DeployGuards.CANONICAL_DELEGATION_CODEHASH);
        assertEq(r.p.permit2, DeployV1.CANONICAL_PERMIT2);
        assertEq(r.p.vrfCoordinator, _r2Address("vrfCoordinator"));
        assertEq(
            r.p.vrfCoordinatorCodeHash,
            vm.parseJsonBytes32(r2, ".params.vrfCoordinatorCodeHash"),
            "the coordinator r2 pinned"
        );
        assertEq(sha256(r.p.cc0Text), DeployV1.CC0_LEGALCODE_SHA256);
        assertEq(r.manifest.digest, vm.parseJsonBytes32(r2, ".manifestDigest"), "r2's manifest");
    }

    /// @dev r2's own genesis file still passes every holder guard against the live Safes.
    function test_TheR2HoldersPassTheHolderGuards() public onFork {
        (address[] memory singletons, bytes32[] memory codehashes) =
            DeployGuards.canonicalSafeSingletons();
        DeployGuards.checkHolders(
            vm.readFile(R2_GENESIS), vm.readFile(EXAMPLE), singletons, codehashes
        );
    }

    /// @dev The whole run, simulated: deploy, the deployment guards (nothing dropped, the
    ///      committed policy, no holder a deployment contract), `configure` with r2's genesis,
    ///      and the record; then Verify against the fork, after the manager's 5-day setback.
    function test_TheFullRunDeploysConfiguresAndVerifies() public onFork {
        vm.recordLogs();
        DeployV1.Deployment memory d = deployer.run();
        verifier.addLogs(vm.getRecordedLogs());
        // The runbook's next step: the new module becomes its subscription's only consumer.
        vm.prank(subscriptionOwner);
        IVrfSubscriptions(_r2Address("vrfCoordinator"))
            .addConsumer(subscriptionId, address(d.entropyModule));
        string memory record = deployer.lastRecord();
        assertFalse(vm.parseJsonBool(record, ".placeholders"));
        assertFalse(vm.parseJsonBool(record, ".delegationMock"), "the canonical delegation code");
        assertEq(vm.parseJsonString(record, ".entropy"), "vrf");
        assertEq(vm.parseJsonStringArray(record, ".standIns").length, 0);

        vm.warp(block.timestamp + 5 days);
        (uint256 targets, uint256 calls, uint256 holders) = verifier.verify(record);
        assertEq(targets, 15, "every governed contract, the entropy module included");
        assertEq(calls, 19, "every wiring call");
        assertEq(holders, 17, "every genesis holder");
        assertEq(
            vm.parseJsonAddress(record, ".params.networkFeeRecipient"),
            _r2Address("networkFeeRecipient")
        );
    }
}
