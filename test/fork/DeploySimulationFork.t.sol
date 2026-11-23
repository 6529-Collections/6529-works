// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DeployCoreScript } from "script/DeployCore.s.sol";
import { DeployCore } from "script/DeployCore.sol";
import { DeployGuards } from "script/DeployGuards.sol";
import { VerifyCore } from "script/VerifyCore.sol";
import { GovernanceConfig } from "src/governance/GovernanceConfig.sol";
import { Forks, IVrfSubscriptions } from "./WorksForkBase.sol";

/// @notice `DeployCoreScript` with its environment variables and files set by the test.
contract DeployCoreHarness is DeployCoreScript {
    mapping(string name => string) internal _envs;
    mapping(string path => string) internal _files;

    function setEnv(string memory name, string memory value) external {
        _envs[name] = value;
    }

    function setFile(string memory path, string memory content) external {
        _files[path] = content;
    }

    function _env(string memory name) internal view override returns (string memory) {
        return _envs[name];
    }

    function _read(string memory path) internal view override returns (string memory) {
        return bytes(_files[path]).length != 0 ? _files[path] : vm.readFile(path);
    }
}

/// @notice The plain-core deploy script (`script/DeployCore.s.sol`) simulated on a Sepolia fork
///         with sepolia-r5's public inputs: its network (a live 2-of-3 Safe 1.4.1) and holder
///         keys on the committed policy (`config/genesis.core.example.json`), its fee recipient,
///         marketplace owner and museum, the official 6529 delegation contract, the real VRF
///         v2.5 coordinator with r5's gas lane (and a new subscription, as the runbook creates
///         for each deployment) and r5's epoch-0 manifest, under a fresh namespace. Every
///         off-anvil guard must pass against the live accounts (the RPC's chain ID, the network
///         a bare canonical Safe, the holders, the committed policy, no holder a deployment
///         contract), the readback must pass, and once the Safe accepts the whole governance
///         configuration must read back. Nothing is broadcast: the run happens in the fork.
/// @dev Opt-in: skipped unless `FORK_SEPOLIA_RPC` is set (`FORK_SEPOLIA_RPC_BLOCK` pins the
///      block). The genesis is served by the harness, not written to disk.
contract DeploySimulationSepoliaForkTest is Test {
    string internal constant EXAMPLE = "config/genesis.core.example.json";
    string internal constant R5_ACCOUNTS = "config/sepolia-r5/accounts.json";
    string internal constant R5_RECORD = "deployments/11155111/1795338612.json";
    string internal constant GENESIS = "config/genesis.fork-simulation.json";
    uint256 internal constant SEPOLIA = 11_155_111;
    /// @dev r5's deployment inputs (`config/sepolia-r5/deploy.env`).
    address internal constant R5_NETWORK = 0x54a769fe591c3F47CF83d30b69e576497CE34454;
    address internal constant R5_MUSEUM = 0xB37A2a265044Ca0cB07839950D208D62B3944D25;
    address internal constant VRF_COORDINATOR = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
    bytes32 internal constant KEY_HASH =
        0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;

    DeployCoreHarness internal script;
    address internal subscriptionOwner = makeAddr("forkSimulationSubscriptionOwner");
    uint256 internal subscriptionId;
    string internal genesis;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "FORK_SEPOLIA_RPC is not set");
            return;
        }
        Forks.select(vm, rpc, vm.envOr("FORK_SEPOLIA_RPC_BLOCK", uint256(0)));
        require(block.chainid == SEPOLIA, "the RPC serves another chain");
        script = new DeployCoreHarness();
        genesis = _committedPolicyWithR5Holders();
        script.setFile(GENESIS, genesis);
        string memory r5 = vm.readFile(R5_RECORD);
        _env("GENESIS_CONFIG", GENESIS);
        _env("DEPLOY_NAMESPACE", vm.toString(keccak256("6529-works/sepolia/fork-simulation")));
        _env("NETWORK_FEE_RECIPIENT", vm.toString(R5_NETWORK));
        _env("MARKETPLACE_OWNER", vm.toString(R5_NETWORK));
        _env("MUSEUM", vm.toString(R5_MUSEUM));
        _env("VRF_COORDINATOR", vm.toString(VRF_COORDINATOR));
        _env("VRF_SUBSCRIPTION_ID", vm.toString(_newSubscription()));
        _env("VRF_KEY_HASH", vm.toString(KEY_HASH));
        _env("VRF_NATIVE_PAYMENT", "1");
        _env("MANIFEST_DIGEST", vm.toString(vm.parseJsonBytes32(r5, ".manifestDigest")));
        _env("MANIFEST_URI", vm.parseJsonString(r5, ".manifestUri"));
    }

    /// @dev The committed example with its placeholder network replaced by r5's network Safe
    ///      and each placeholder holder by r5's holder in the same position (three pausers, two
    ///      curation signers, the storage operator, the platform, the curator).
    function _committedPolicyWithR5Holders() internal view returns (string memory json) {
        json = vm.readFile(EXAMPLE);
        string memory accounts = vm.readFile(R5_ACCOUNTS);
        assertEq(vm.parseJsonAddress(accounts, ".network"), R5_NETWORK, "r5's network");
        json = vm.replace(
            json, vm.toLowercase(vm.toString(address(uint160(0xb001)))), vm.toString(R5_NETWORK)
        );
        uint16[8] memory placeholders =
            [0xb011, 0xb012, 0xb013, 0xb021, 0xb022, 0xb031, 0xb051, 0xb061];
        string[8] memory roles = [
            "PAUSER",
            "PAUSER",
            "PAUSER",
            "CURATION_SIGNER",
            "CURATION_SIGNER",
            "STORAGE_OPERATOR",
            "PLATFORM",
            "CURATOR"
        ];
        for (uint256 i; i < placeholders.length; ++i) {
            string memory entry = string.concat(".holders[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(accounts, string.concat(entry, ".role")), roles[i]);
            string memory from = vm.toLowercase(vm.toString(address(uint160(placeholders[i]))));
            json = vm.replace(
                json,
                from,
                vm.toString(vm.parseJsonAddress(accounts, string.concat(entry, ".account")))
            );
        }
    }

    /// @dev As the runbook does before a deployment: a new subscription on the coordinator,
    ///      funded in native ETH, whose only consumer will be the new entropy module.
    function _newSubscription() internal returns (uint256 id) {
        IVrfSubscriptions coordinator = IVrfSubscriptions(VRF_COORDINATOR);
        vm.deal(subscriptionOwner, 10 ether);
        vm.startPrank(subscriptionOwner);
        id = coordinator.createSubscription();
        coordinator.fundSubscriptionWithNative{ value: 1 ether }(id);
        vm.stopPrank();
        subscriptionId = id;
    }

    function _env(string memory name, string memory value) internal {
        script.setEnv(name, value);
    }

    /// @notice The parameters the script reads off anvil: the official delegation contract,
    ///         the coordinator with its live code hash, the pinned CC0 text.
    function test_DeploySimulation_TheScriptReadsTheSepoliaInputs() public view {
        DeployCore.Params memory p = script.params(false);
        assertEq(p.delegation, DeployGuards.SEPOLIA_DELEGATION, "the official delegation");
        assertEq(p.delegation.codehash, DeployGuards.CANONICAL_DELEGATION_CODEHASH);
        assertEq(p.vrfCoordinator, VRF_COORDINATOR);
        assertEq(p.vrfCoordinatorCodeHash, VRF_COORDINATOR.codehash);
        assertEq(p.vrf.subscriptionId, subscriptionId);
        assertEq(sha256(p.cc0Text), DeployCore.CC0_LEGALCODE_SHA256);
        assertEq(p.feeRecipient, R5_NETWORK);
        assertEq(p.museum, R5_MUSEUM);
    }

    /// @notice The holder guards pass against r5's live Safe and keys on the committed policy,
    ///         and the committed example itself is refused off anvil.
    function test_DeploySimulation_TheR5AccountsPassTheHolderGuards() public {
        (address[] memory singletons, bytes32[] memory codehashes) =
            DeployGuards.canonicalSafeSingletons();
        DeployGuards.checkHolders(genesis, vm.readFile(EXAMPLE), singletons, codehashes);
        DeployGuards.checkNoBrake(genesis);
        assertEq(vm.parseJsonAddress(genesis, ".network"), R5_NETWORK);
        string memory example = vm.readFile(EXAMPLE);
        vm.expectRevert(DeployGuards.ExampleGenesisOffAnvil.selector);
        this.checkHoldersExternal(example, example, singletons, codehashes);
    }

    function checkHoldersExternal(
        string memory json,
        string memory example,
        address[] memory singletons,
        bytes32[] memory codehashes
    ) external view {
        DeployGuards.checkHolders(json, example, singletons, codehashes);
    }

    /// @notice The whole run, simulated: the guards, `deploy`, the policy and deployment-holder
    ///         guards, `install` and the readback. Then the runbook's next steps: the new module
    ///         becomes its subscription's only consumer (the subscription guard passes) and
    ///         r5's Safe accepts the network, after which the whole governance configuration
    ///         reads back.
    function test_DeploySimulation_TheFullRunDeploysInstallsAndVerifies() public {
        DeployCore.Deployment memory d = script.run();
        DeployCore.Params memory p = script.params(false);
        assertEq(d.manager.pendingNetwork(), R5_NETWORK, "genesis proposes r5's Safe");
        assertEq(d.manager.network(), address(0));
        assertTrue(d.entropyModule != address(0), "the entropy module is deployed");
        assertEq(address(d.configurator.worksManager()), address(d.manager));

        vm.prank(subscriptionOwner);
        IVrfSubscriptions(VRF_COORDINATOR).addConsumer(subscriptionId, d.entropyModule);
        GovernanceConfig.Config memory cfg = DeployCore.config(d, genesis);
        DeployGuards.checkSubscription(d, cfg, false);

        vm.prank(R5_NETWORK);
        d.manager.acceptNetwork();
        assertEq(d.manager.network(), R5_NETWORK);
        VerifyCore.verify(p, d, cfg, true);
    }
}
