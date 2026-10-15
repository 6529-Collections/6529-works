// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Vm } from "forge-std/Vm.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { WorksForkBase } from "./WorksForkBase.sol";

/// @dev The subscription calls of the Chainlink VRF v2.5 coordinator (`SubscriptionAPI`).
interface IVrfSubscriptions {
    function createSubscription() external returns (uint256 subId);
    function fundSubscriptionWithNative(uint256 subId) external payable;
    function addConsumer(uint256 subId, address consumer) external;
    function getSubscription(uint256 subId)
        external
        view
        returns (
            uint96 balance,
            uint96 nativeBalance,
            uint64 reqCount,
            address owner,
            address[] memory consumers
        );
}

/// @notice The entropy module against the real Chainlink VRF v2.5 coordinator on a Sepolia
///         fork: a funded subscription with the module as its consumer, a seed request that the
///         coordinator accepts and logs with sepolia-r2's gas lane and limits, then a simulated
///         fulfilment (the coordinator's own fulfilment needs the oracle's VRF proof) delivered
///         within the configured callback gas, after which the VRF work starts and renders its
///         seed.
contract VrfSepoliaForkTest is WorksForkBase {
    /// @dev The VRF v2.5 coordinator on Sepolia, and the code hash sepolia-r2 pinned.
    address internal constant VRF_COORDINATOR = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
    bytes32 internal constant R2_COORDINATOR_CODEHASH =
        0x5e22d4163e7c1b059a946f0600759a4d38eb3e04592d0e359def022cec36bdbc;
    /// @dev sepolia-r2's gas lane, callback gas limit and confirmations (its deployment record).
    bytes32 internal constant KEY_HASH =
        0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
    uint32 internal constant CALLBACK_GAS = 200_000;
    uint16 internal constant CONFIRMATIONS = 3;

    address internal subscriptionOwner = makeAddr("forkVrfSubscriptionOwner");
    uint256 internal subscriptionId;
    address internal artist;
    bytes32 internal root;

    function _rpcVar() internal pure override returns (string memory) {
        return "FORK_SEPOLIA_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return SEPOLIA;
    }

    /// @dev A new subscription, funded in native ETH, before the deployment pins its ID.
    function _realCoordinator() internal override returns (address) {
        vm.deal(subscriptionOwner, 10 ether);
        vm.startPrank(subscriptionOwner);
        subscriptionId = IVrfSubscriptions(VRF_COORDINATOR).createSubscription();
        IVrfSubscriptions(VRF_COORDINATOR).fundSubscriptionWithNative{ value: 1 ether }(
            subscriptionId
        );
        vm.stopPrank();
        return VRF_COORDINATOR;
    }

    function _params() internal view override returns (DeployV1.Params memory p) {
        p = super._params();
        p.vrf =
            VrfEntropyModule.VrfConfig(subscriptionId, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, true);
    }

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        vm.prank(subscriptionOwner);
        IVrfSubscriptions(VRF_COORDINATOR).addConsumer(subscriptionId, address(entropy));
        artist = _actor("forkVrfArtist");
        Work memory w = _work(artist, collectionId);
        w.item.seedPolicy = SeedPolicy.VRF;
        root = _publish(_one(w));
        _keep(root, _one(w));
    }

    function test_TheCoordinatorIsTheOneR2Pinned() public onFork {
        assertEq(entropy.coordinator(), VRF_COORDINATOR);
        assertEq(VRF_COORDINATOR.codehash, R2_COORDINATOR_CODEHASH, "the coordinator's code");
    }

    /// @dev The request reaches the coordinator, which records it against the subscription and
    ///      logs it for the oracle with the module's gas lane and limits; a fulfilment delivered
    ///      within the callback gas then lets the auction start, and the seed renders.
    function test_RequestReachesTheCoordinatorAndAFulfilmentStartsTheWork() public onFork {
        Work[] memory works = _package(root);
        bytes32 itemHash = WorksHashing.itemHash(works[0].item);
        vm.recordLogs();
        uint256 requestId = entropy.requestSeed(works[0].item, root, _proofOf(works, 0));
        _assertRequestLogged(vm.getRecordedLogs(), requestId);
        (,,, address owner, address[] memory consumers) =
            IVrfSubscriptions(VRF_COORDINATOR).getSubscription(subscriptionId);
        assertEq(owner, subscriptionOwner);
        assertEq(consumers.length, 1);
        assertEq(consumers[0], address(entropy), "the module is the subscription's consumer");
        (uint256 pending,) = entropy.requestOf(itemHash);
        assertEq(pending, requestId);

        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256("simulated VRF output"));
        vm.prank(VRF_COORDINATOR);
        entropy.rawFulfillRandomWords{ gas: CALLBACK_GAS }(requestId, words);
        assertEq(entropy.seedOf(itemHash), bytes32(words[0]));

        (, uint256 tokenId) = _start(root, works, 0);
        string memory trait = string.concat(
            '{"trait_type":"Seed","value":"', Strings.toHexString(words[0], 32), '"}'
        );
        assertTrue(_contains(stream.tokenURI(tokenId), trait), "the seed renders");
    }

    function test_OnlyTheCoordinatorFulfils() public onFork {
        Work[] memory works = _package(root);
        uint256 requestId = entropy.requestSeed(works[0].item, root, _proofOf(works, 0));
        uint256[] memory words = new uint256[](1);
        vm.expectRevert(
            abi.encodeWithSelector(
                VrfEntropyModule.OnlyCoordinatorCanFulfill.selector, address(this), VRF_COORDINATOR
            )
        );
        entropy.rawFulfillRandomWords(requestId, words);
    }

    /// @dev `RandomWordsRequested(bytes32 indexed keyHash, uint256 requestId, uint256 preSeed,
    ///      uint256 indexed subId, uint16 minimumRequestConfirmations, uint32 callbackGasLimit,
    ///      uint32 numWords, bytes extraArgs, address indexed sender)`, from the coordinator.
    function _assertRequestLogged(Vm.Log[] memory logs, uint256 requestId) internal view {
        bytes32 topic = keccak256(
            "RandomWordsRequested(bytes32,uint256,uint256,uint256,uint16,uint32,uint32,bytes,address)"
        );
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != VRF_COORDINATOR || logs[i].topics[0] != topic) continue;
            assertEq(logs[i].topics[1], KEY_HASH, "the gas lane");
            assertEq(uint256(logs[i].topics[2]), subscriptionId, "the subscription");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(entropy), "the consumer");
            (
                uint256 id,,
                uint16 confirmations,
                uint32 gasLimit,
                uint32 numWords,
                bytes memory extra
            ) = abi.decode(logs[i].data, (uint256, uint256, uint16, uint32, uint32, bytes));
            assertEq(id, requestId);
            assertEq(confirmations, CONFIRMATIONS);
            assertEq(gasLimit, CALLBACK_GAS);
            assertEq(numWords, 1);
            assertEq(extra, abi.encodeWithSelector(bytes4(0x92fd1338), true), "native payment");
            return;
        }
        revert("the coordinator logged no request");
    }
}
