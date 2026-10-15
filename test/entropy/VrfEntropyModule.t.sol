// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { BoundedParameter } from "src/governance/BoundedParameter.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { StateGrowth } from "test/helpers/StateGrowth.sol";
import { EntropyBase } from "./EntropyBase.sol";
import {
    EntropyPackageRegistryMock,
    MockVrfCoordinator,
    ReentrantVrfCoordinator
} from "test/mocks/entropy/EntropyMocks.sol";
import { Dependency } from "src/libraries/Dependency.sol";

/// @dev Different bytecode, same storage and functions as the mock (DEPS-6).
contract AlteredVrfCoordinator is MockVrfCoordinator {
    function altered() external pure returns (bool) {
        return true;
    }
}

/// @notice Requests, the package gate, fulfilment, repeats and reads of the VRF entropy module.
contract VrfEntropyModuleTest is EntropyBase {
    event SeedLinked(bytes32 indexed itemHash, bytes32 indexed contentHash);
    event SeedRequested(bytes32 indexed itemHash, uint256 requestId);
    event SeedDelivered(bytes32 indexed contentHash, uint256 requestId, bytes32 seed);
    event RandomWordsRequested(
        uint256 indexed requestId,
        address indexed consumer,
        bytes32 keyHash,
        uint256 subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords,
        bytes extraArgs
    );
    event ConfigSet(VrfEntropyModule.VrfConfig previous, VrfEntropyModule.VrfConfig next);
    event CoordinatorSet(address previous, address next, bytes32 codeHash);

    function _fulfillAs(address caller, uint256 requestId, uint256 word) internal {
        vm.prank(caller);
        module.rawFulfillRandomWords(requestId, _oneWord(word));
    }

    // ------------------------------------------------------------------ constructor

    function test_Constructor_StoresConfiguration() public view {
        assertEq(module.authority(), address(manager));
        assertEq(module.coordinator(), address(coordinator));
        assertEq(address(module.packageRegistry()), address(registry));
        assertEq(module.retryDelay(), RETRY_DELAY);
        VrfEntropyModule.VrfConfig memory c = module.config();
        assertEq(c.subscriptionId, SUBSCRIPTION);
        assertEq(c.keyHash, KEY_HASH);
        assertEq(c.callbackGasLimit, GAS_LIMIT);
        assertEq(c.confirmations, CONFIRMATIONS);
        assertFalse(c.nativePayment);
    }

    function test_Constructor_EmitsInitialState() public {
        vm.expectEmit(false, false, false, true);
        emit CoordinatorSet(address(0), address(coordinator), address(coordinator).codehash);
        vm.expectEmit(false, false, false, true);
        emit ConfigSet(VrfEntropyModule.VrfConfig(0, 0, 0, 0, false), _config());
        _deploy(coordinator);
    }

    function test_Constructor_RejectsBadRetryDelay() public {
        VrfEntropyModule.VrfConfig memory c = _config();
        uint64 low = module.MIN_RETRY_DELAY() - 1;
        uint64 high = module.MAX_RETRY_DELAY() + 1;
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.InvalidRetryDelay.selector, low));
        _newModule(address(coordinator), c, low, address(registry));
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.InvalidRetryDelay.selector, high));
        _newModule(address(coordinator), c, high, address(registry));
        _newModule(address(coordinator), c, module.MIN_RETRY_DELAY(), address(registry));
        _newModule(address(coordinator), c, module.MAX_RETRY_DELAY(), address(registry));
    }

    /// @dev The minimum is three days, not the one day a coordinator timeout would suggest:
    ///      VRF v2.5 never expires a request on-chain.
    function test_Constructor_TheMinimumRetryDelayIsThreeDays() public view {
        assertEq(module.MIN_RETRY_DELAY(), 3 days);
    }

    function test_Constructor_RejectsAnInvalidCoordinator() public {
        address delegated = makeAddr("delegated EOA");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(coordinator)));
        address[3] memory bad = [address(0), stranger, delegated];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, bad[i]));
            _newModule(bad[i], _config(), RETRY_DELAY, address(registry));
        }
    }

    function test_Constructor_PinsTheCoordinatorCodeHash() public {
        bytes32 wrong = keccak256("some other coordinator");
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(coordinator))
        );
        new VrfEntropyModule(
            address(manager),
            address(coordinator),
            wrong,
            _config(),
            RETRY_DELAY,
            IPackageRegistry(address(registry)),
            address(registry).codehash
        );
    }

    /// @dev The registry is an install: code that is not a delegation, ERC-165 for
    ///      `IPackageRegistry`, and the pinned code hash.
    function test_Constructor_RejectsARegistryWithoutErc165Support() public {
        address[5] memory bad = [
            address(0), // no code
            stranger, // an EOA
            address(coordinator), // a contract that does not implement ERC-165
            address(module), // ERC-165, but another interface
            address(manager) // a contract with a different ABI
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, bad[i]));
            _newModule(address(coordinator), _config(), RETRY_DELAY, bad[i]);
        }
    }

    function test_Constructor_PinsTheRegistryCodeHash() public {
        bytes32 wrong = keccak256("some other registry");
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(registry))
        );
        new VrfEntropyModule(
            address(manager),
            address(coordinator),
            address(coordinator).codehash,
            _config(),
            RETRY_DELAY,
            IPackageRegistry(address(registry)),
            wrong
        );
    }

    /// @dev Review regression (PoC 3): an EIP-7702 delegated EOA whose delegate answers ERC-165 for
    ///      `IPackageRegistry` used to pass the install check.
    function test_Constructor_RejectsADelegatedRegistry() public {
        EntropyPackageRegistryMock impl = new EntropyPackageRegistryMock();
        (address eoa, uint256 pk) = makeAddrAndKey("eoa-registry");
        vm.signAndAttachDelegation(address(impl), pk);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        _newModule(address(coordinator), _config(), RETRY_DELAY, eoa);

        // And by raw designator code.
        address designated = makeAddr("designated registry");
        vm.etch(designated, abi.encodePacked(hex"ef0100", address(impl)));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, designated));
        _newModule(address(coordinator), _config(), RETRY_DELAY, designated);
    }

    function test_Constructor_RejectsInvalidConfig() public {
        address reg = address(registry);
        VrfEntropyModule.VrfConfig memory c = _config();
        c.subscriptionId = 0;
        vm.expectRevert(IEntropyModule.InvalidConfig.selector);
        _newModule(address(coordinator), c, RETRY_DELAY, reg);

        c = _config();
        c.keyHash = 0;
        vm.expectRevert(IEntropyModule.InvalidConfig.selector);
        _newModule(address(coordinator), c, RETRY_DELAY, reg);

        c = _config();
        c.callbackGasLimit = module.MIN_CALLBACK_GAS() - 1;
        vm.expectRevert(IEntropyModule.InvalidConfig.selector);
        _newModule(address(coordinator), c, RETRY_DELAY, reg);

        c = _config();
        c.callbackGasLimit = module.MAX_CALLBACK_GAS() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                BoundedParameter.ParameterAboveCeiling.selector,
                module.MAX_CALLBACK_GAS() + 1,
                module.MAX_CALLBACK_GAS()
            )
        );
        _newModule(address(coordinator), c, RETRY_DELAY, reg);

        c = _config();
        c.callbackGasLimit = 0;
        vm.expectRevert(BoundedParameter.ParameterZero.selector);
        _newModule(address(coordinator), c, RETRY_DELAY, reg);

        c = _config();
        c.confirmations = module.MIN_CONFIRMATIONS() - 1;
        vm.expectRevert(IEntropyModule.InvalidConfig.selector);
        _newModule(address(coordinator), c, RETRY_DELAY, reg);

        c = _config();
        c.confirmations = module.MAX_CONFIRMATIONS() + 1;
        vm.expectRevert(IEntropyModule.InvalidConfig.selector);
        _newModule(address(coordinator), c, RETRY_DELAY, reg);
    }

    function test_ExtraArgsTagIsTheV25Tag() public pure {
        assertEq(bytes4(keccak256("VRF ExtraArgsV1")), bytes4(0x92fd1338));
    }

    // ------------------------------------------------------------------ ERC-165 (decision D8)

    function test_SupportsInterface() public view {
        assertTrue(module.supportsInterface(type(IERC165).interfaceId));
        assertTrue(module.supportsInterface(type(IEntropyModule).interfaceId));
        assertFalse(module.supportsInterface(0xffffffff));
        assertFalse(module.supportsInterface(0x12345678));
        assertFalse(module.supportsInterface(type(IPackageRegistry).interfaceId));
    }

    /// @dev The interface ID is the XOR of the selectors an installer expects.
    function test_InterfaceIdIsTheXorOfTheEntropySelectors() public pure {
        bytes4 expected = IEntropyModule.requestSeed.selector ^ IEntropyModule.isDelivered.selector
            ^ IEntropyModule.seedOf.selector ^ IEntropyModule.requestOf.selector
            ^ IEntropyModule.retryDelay.selector ^ IEntropyModule.coordinator.selector
            ^ IEntropyModule.setCoordinator.selector;
        assertEq(type(IEntropyModule).interfaceId, expected);
    }

    // ------------------------------------------------------------------ first request

    function test_Request_AnyoneMayRequestAnApprovedItemAndTheCoordinatorSeesTheParameters()
        public
    {
        vm.expectEmit(true, true, false, true, address(coordinator));
        emit RandomWordsRequested(
            1,
            address(module),
            KEY_HASH,
            SUBSCRIPTION,
            CONFIRMATIONS,
            GAS_LIMIT,
            1,
            abi.encodeWithSelector(bytes4(0x92fd1338), false)
        );
        vm.expectEmit(true, false, false, true, address(module));
        emit SeedRequested(items[0], 1);
        uint256 id = _request(0);

        assertEq(id, 1);
        (uint256 requestId, uint64 requestedAt) = module.requestOf(items[0]);
        assertEq(requestId, 1);
        assertEq(requestedAt, block.timestamp);
        assertFalse(module.isDelivered(items[0]));
    }

    function test_Request_NoRoleIsNeeded() public {
        address[4] memory callers = [stranger, setter, successor, admin];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            module.requestSeed(_item(i), root, proofs[i]);
            (uint256 requestId,) = module.requestOf(items[i]);
            assertEq(requestId, i + 1);
        }
    }

    function test_Request_NativePaymentFlowsIntoTheExtraArgs() public {
        VrfEntropyModule.VrfConfig memory next = _config();
        next.nativePayment = true;
        vm.prank(setter);
        module.setConfig(_config(), next);
        vm.expectEmit(true, true, false, true, address(coordinator));
        emit RandomWordsRequested(
            1,
            address(module),
            KEY_HASH,
            SUBSCRIPTION,
            CONFIRMATIONS,
            GAS_LIMIT,
            1,
            abi.encodeWithSelector(bytes4(0x92fd1338), true)
        );
        _request(0);
    }

    function test_Request_AOneItemPackageNeedsNoProof() public {
        vm.prank(stranger);
        module.requestSeed(_solo(), soloRoot, new bytes32[](0));
        (uint256 requestId,) = module.requestOf(_hash(_solo()));
        assertEq(requestId, 1);
    }

    function test_Request_IsNonPayable() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(module).call{ value: 1 }(
            abi.encodeCall(module.requestSeed, (_item(0), root, proofs[0]))
        );
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ the package gate

    function test_Gate_RejectsAnUnknownOrRevokedPackage() public {
        bytes32 unknown = keccak256("unknown package");
        vm.expectRevert(_notRequestable(items[0]));
        module.requestSeed(_item(0), unknown, proofs[0]);

        registry.setStatus(root, IPackageRegistry.PackageStatus.REVOKED);
        vm.expectRevert(_notRequestable(items[0]));
        module.requestSeed(_item(0), root, proofs[0]);
        (uint256 requestId,) = module.requestOf(items[0]);
        assertEq(requestId, 0);
    }

    function test_Gate_RejectsAnItemThatIsNotInThePackage() public {
        PackageItem memory outsider = _makeItem(999, SeedPolicy.VRF);
        // An item that is not in the package, with a real proof of another item.
        vm.expectRevert(_notRequestable(_hash(outsider)));
        module.requestSeed(outsider, root, proofs[0]);
        // A real item with the proof of another item.
        vm.expectRevert(_notRequestable(items[0]));
        module.requestSeed(_item(0), root, proofs[1]);
        // A real item with no proof.
        vm.expectRevert(_notRequestable(items[0]));
        module.requestSeed(_item(0), root, new bytes32[](0));
        // An item of one approved package under the root of another.
        vm.expectRevert(_notRequestable(items[0]));
        module.requestSeed(_item(0), soloRoot, new bytes32[](0));
    }

    /// @dev The module hashes the whole item itself, so changing any field of an approved item
    ///      makes a different item that is not in the package.
    function test_Gate_ATamperedItemIsADifferentItem() public {
        PackageItem memory item = _item(0);
        item.mediaHash = keccak256("tampered media");
        vm.expectRevert(_notRequestable(_hash(item)));
        module.requestSeed(item, root, proofs[0]);

        item = _item(0);
        item.recordFileId = keccak256("tampered record");
        vm.expectRevert(_notRequestable(_hash(item)));
        module.requestSeed(item, root, proofs[0]);

        item = _item(0);
        item.parties[0].account = stranger;
        vm.expectRevert(_notRequestable(_hash(item)));
        module.requestSeed(item, root, proofs[0]);

        item = _item(0);
        item.sale.params = hex"01";
        vm.expectRevert(_notRequestable(_hash(item)));
        module.requestSeed(item, root, proofs[0]);
    }

    function test_Gate_RejectsAnItemWhoseSeedPolicyIsNotVrf() public {
        SeedPolicy[2] memory policies = [SeedPolicy.NONE, SeedPolicy.ARTIST];
        for (uint256 i; i < policies.length; ++i) {
            PackageItem memory item = _plain(policies[i]);
            // In an approved package, with a valid (empty) proof, it is still refused.
            vm.expectRevert(_notRequestable(_hash(item)));
            module.requestSeed(item, plainRoot(policies[i]), new bytes32[](0));
            (uint256 requestId,) = module.requestOf(_hash(item));
            assertEq(requestId, 0);
        }
    }

    /// @dev Flipping an approved item's policy to VRF changes its hash: a seed cannot be drawn for
    ///      an item the network approved with another policy.
    function test_Gate_ThePolicyCannotBeFlippedToVrf() public {
        PackageItem memory item = _plain(SeedPolicy.ARTIST);
        item.seedPolicy = SeedPolicy.VRF;
        item.seed = bytes32(0);
        vm.expectRevert(_notRequestable(_hash(item)));
        module.requestSeed(item, plainRoot(SeedPolicy.ARTIST), new bytes32[](0));
    }

    function test_Gate_RejectsAConsumedItem() public {
        // The registry reports the item's content hash as consumed by the item itself...
        registry.setConsumedBy(_item(2).contentHash, items[2]);
        vm.expectRevert(_notRequestable(items[2]));
        module.requestSeed(_item(2), root, proofs[2]);
        // ...or as claimed by another item, so this one can never mint either.
        registry.setConsumedBy(_item(1).contentHash, keccak256("another item"));
        vm.expectRevert(_notRequestable(items[1]));
        module.requestSeed(_item(1), root, proofs[1]);
        // Other items of the package are unaffected.
        _request(3);
    }

    function test_Gate_RejectsAnOverlongProof() public {
        bytes32[] memory proof = new bytes32[](33);
        vm.expectRevert(_notRequestable(items[0]));
        module.requestSeed(_item(0), root, proof);
        proof = new bytes32[](32); // the longest accepted; rejected here only as not in the package
        vm.expectRevert(_notRequestable(items[0]));
        module.requestSeed(_item(0), root, proof);
    }

    /// @dev The Merkle loop is bounded: a proof past the cap is refused before any hashing, so
    ///      the work of a refused call does not grow with the length of the proof.
    function test_Gate_AnOverlongProofIsRefusedBeforeItIsHashed() public {
        PackageItem memory item = _item(0);
        bytes32[] memory proof = new bytes32[](5_000);
        uint256 before = gasleft();
        vm.expectRevert(_notRequestable(items[0]));
        module.requestSeed(item, root, proof);
        uint256 used = before - gasleft();
        emit log_named_uint("gas of a refused 5,000-hash proof", used);
        assertLt(used, 1_000_000);
    }

    function test_Gate_RevocationStopsARepeatButNotTheReads() public {
        uint256 id = _request(0);
        coordinator.fulfill(id, 5);
        _request(1);
        registry.setStatus(root, IPackageRegistry.PackageStatus.REVOKED);

        vm.warp(block.timestamp + RETRY_DELAY);
        vm.expectRevert(_notRequestable(items[1]));
        module.requestSeed(_item(1), root, proofs[1]);
        // A delivered seed stays readable.
        assertEq(module.seedOf(items[0]), bytes32(uint256(5)));
        // Reinstating the package (not possible in the real registry, but the gate is stateless)
        // reopens the repeat.
        registry.setStatus(root, IPackageRegistry.PackageStatus.APPROVED);
        _request(1);
    }

    function test_Gate_ARequestMadeBeforeRevocationStillDelivers() public {
        uint256 id = _request(0);
        registry.setStatus(root, IPackageRegistry.PackageStatus.REVOKED);
        coordinator.fulfill(id, 9);
        assertEq(module.seedOf(items[0]), bytes32(uint256(9)));
    }

    function test_Gate_ConsumptionAfterDeliveryBlocksNothingRead() public {
        uint256 id = _request(0);
        coordinator.fulfill(id, 9);
        registry.setConsumedBy(_item(0).contentHash, items[0]); // the auction's start consumed it
        assertTrue(module.isDelivered(items[0]));
        assertEq(module.seedOf(items[0]), bytes32(uint256(9)));
    }

    // ------------------------------------------------------------------ coordinator edge cases

    function test_Request_CoordinatorFailureLeavesNoState() public {
        coordinator.setDisabled(true);
        vm.expectRevert(MockVrfCoordinator.RequestsDisabled.selector);
        module.requestSeed(_item(0), root, proofs[0]);
        (uint256 requestId, uint64 requestedAt) = module.requestOf(items[0]);
        assertEq(requestId, 0);
        assertEq(requestedAt, 0);
        coordinator.setDisabled(false);
        assertEq(_request(0), 1);
    }

    function test_Request_RejectsAZeroRequestId() public {
        coordinator.force(0, true);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.InvalidRequestId.selector, 0));
        module.requestSeed(_item(0), root, proofs[0]);
    }

    function test_Request_RejectsADuplicateRequestId() public {
        coordinator.force(42, false);
        _request(0);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.InvalidRequestId.selector, 42));
        module.requestSeed(_item(1), root, proofs[1]);
        (uint256 requestId,) = module.requestOf(items[0]);
        assertEq(requestId, 42);
        (requestId,) = module.requestOf(items[1]);
        assertEq(requestId, 0);
    }

    function test_Request_ReentrancyFromTheCoordinatorFindsNothingToUse() public {
        ReentrantVrfCoordinator evil = new ReentrantVrfCoordinator(module);
        _swap(address(evil));
        evil.aim(_item(0), root, proofs[0]);

        uint256 id = _request(0);
        assertEq(id, evil.ISSUED_ID());
        // The repeat saw the pending request, and the fulfilment saw an ID not yet recorded.
        assertFalse(evil.repeatSucceeded());
        assertEq(
            evil.repeatError(),
            abi.encodeWithSelector(
                IEntropyModule.RequestPending.selector,
                items[0],
                uint64(block.timestamp + RETRY_DELAY)
            )
        );
        assertFalse(evil.fulfilSucceeded());
        assertEq(
            evil.fulfilError(),
            abi.encodeWithSelector(IEntropyModule.UnknownRequest.selector, evil.ISSUED_ID())
        );
        assertFalse(module.isDelivered(items[0]));
    }

    // ------------------------------------------------------------------ fulfilment

    function test_Fulfill_StoresTheSeedAndEmits() public {
        uint256 id = _request(0);
        vm.expectEmit(true, false, false, true, address(module));
        emit SeedDelivered(_item(0).contentHash, id, bytes32(uint256(123)));
        coordinator.fulfill(id, 123);

        assertTrue(module.isDelivered(items[0]));
        assertEq(module.seedOf(items[0]), bytes32(uint256(123)));
        (uint256 requestId,) = module.requestOf(items[0]);
        assertEq(requestId, 0, "delivered: no request is outstanding");
    }

    function test_Fulfill_OnlyTheCoordinatorMay() public {
        uint256 id = _request(0);
        address[4] memory callers = [stranger, setter, admin, address(module)];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IEntropyModule.OnlyCoordinatorCanFulfill.selector,
                    callers[i],
                    address(coordinator)
                )
            );
            _fulfillAs(callers[i], id, 5);
        }
        assertFalse(module.isDelivered(items[0]));
    }

    /// @dev A repeat adds a request; it never invalidates the earlier one. The earlier request's
    ///      delivery, even late, is accepted if it comes first, and it fixes the seed.
    function test_Fulfill_AnEarlierRequestStillDeliversAfterARepeat() public {
        uint256 first = _request(0);
        vm.warp(block.timestamp + RETRY_DELAY);
        uint256 second = _request(0);
        assertTrue(second != first);
        // The item's current request is the repeat; the first still delivers.
        (uint256 current,) = module.requestOf(items[0]);
        assertEq(current, second);

        coordinator.fulfill(first, 1111);
        assertTrue(module.isDelivered(items[0]));
        assertEq(module.seedOf(items[0]), bytes32(uint256(1111)));
    }

    /// @dev Review regression (PoC 1, inverted): a delivery still pending at `retryDelay` cannot
    ///      be discarded by a repeat. It lands, and it is final.
    function test_Fulfill_ARepeatCannotDiscardAPendingDelivery() public {
        uint256 first = _request(0);
        uint256 disliked = 0xBAD;
        vm.warp(block.timestamp + RETRY_DELAY);
        // The observer sees `disliked` pending and front-runs it with a repeat.
        uint256 second = _request(0);

        // The pending delivery lands anyway, accepted by the module and the coordinator.
        assertTrue(coordinator.tryFulfill(first, disliked));
        assertEq(module.seedOf(items[0]), bytes32(disliked));
        // The repeat's own delivery arrives later and changes nothing.
        assertTrue(coordinator.tryFulfill(second, 0x600D));
        assertEq(module.seedOf(items[0]), bytes32(disliked));
    }

    /// @dev Whichever delivery comes first wins, whichever request it belongs to.
    function test_Fulfill_TheFirstDeliveryWinsInEitherOrder() public {
        uint256 first = _request(0);
        vm.warp(block.timestamp + RETRY_DELAY);
        uint256 second = _request(0);
        coordinator.fulfill(second, 2222);
        coordinator.fulfill(first, 1111);
        assertEq(module.seedOf(items[0]), bytes32(uint256(2222)));
    }

    /// @dev A later delivery for an item whose seed is fixed is a silent no-op: no revert (so the
    ///      oracle's fulfilment succeeds), no event, no change.
    function test_Fulfill_ADoubleFulfilIsANoOp() public {
        uint256 id = _request(0);
        coordinator.fulfill(id, 10);
        vm.recordLogs();
        coordinator.fulfill(id, 20);
        assertEq(_countModuleLogs(IEntropyModule.SeedDelivered.selector), 0);
        assertEq(module.seedOf(items[0]), bytes32(uint256(10)));
    }

    function test_Fulfill_AnUnissuedRequestIdReverts() public {
        _request(0);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.UnknownRequest.selector, 999));
        _fulfillAs(address(coordinator), 999, 1);
        // Zero must not match the empty record of an unknown request.
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.UnknownRequest.selector, 0));
        _fulfillAs(address(coordinator), 0, 1);
    }

    function test_Fulfill_ExactlyOneWordIsRequired() public {
        uint256 id = _request(0);
        uint256[] memory none = new uint256[](0);
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.InvalidRandomWords.selector, id));
        coordinator.deliver(address(module), id, none);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.InvalidRandomWords.selector, id));
        coordinator.deliver(address(module), id, two);
        assertFalse(module.isDelivered(items[0]));
    }

    function test_Fulfill_AZeroWordIsAValidSeed() public {
        uint256 id = _request(0);
        coordinator.fulfill(id, 0);
        assertTrue(module.isDelivered(items[0]));
        assertEq(module.seedOf(items[0]), bytes32(0));
    }

    function test_Fulfill_ItemsAreIndependent() public {
        uint256 a = _request(0);
        uint256 b = _request(1);
        coordinator.fulfill(b, 222);
        assertFalse(module.isDelivered(items[0]));
        assertEq(module.seedOf(items[1]), bytes32(uint256(222)));
        coordinator.fulfill(a, 111);
        assertEq(module.seedOf(items[0]), bytes32(uint256(111)));
        assertEq(module.seedOf(items[1]), bytes32(uint256(222)));
    }

    function test_Fulfill_ALateDeliverySucceedsAtTheCoordinator() public {
        uint256 id = _request(0);
        assertTrue(coordinator.tryFulfill(id, 5));
        assertTrue(coordinator.tryFulfill(id, 6));
        assertEq(module.seedOf(items[0]), bytes32(uint256(5)));
    }

    /// @dev A malformed delivery still reverts (the coordinator absorbs it) and fixes nothing.
    function test_Fulfill_AMalformedDeliveryRevertsAndTheItemStaysUndelivered() public {
        uint256 id = _request(0);
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.InvalidRandomWords.selector, id));
        coordinator.deliver(address(module), id, two);
        assertFalse(module.isDelivered(items[0]));
        coordinator.fulfill(id, 5);
        assertEq(module.seedOf(items[0]), bytes32(uint256(5)));
    }

    // ------------------------------------------------------------------ the pinned coordinator

    /// Regression: DEPS-6 (docs/security/internal-review-2026-10.md)
    /// @dev DEPS-6: the coordinator's code hash is checked at every use, not only at install. If
    ///      the code at the pinned address no longer has the pinned hash, requests and deliveries
    ///      stop until governance installs a coordinator again.
    function test_Pin_ACoordinatorWhoseCodeChangedIsRefused() public {
        uint256 id = _request(0);
        bytes32 pinned = address(coordinator).codehash;
        vm.etch(address(coordinator), address(new AlteredVrfCoordinator()).code);
        bytes32 actual = address(coordinator).codehash;
        assertTrue(actual != pinned);
        bytes memory mismatch =
            abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, address(coordinator));

        vm.expectRevert(mismatch);
        _request(1);
        vm.expectRevert(mismatch);
        coordinator.deliver(address(module), id, _oneWord(7));
        assertFalse(module.isDelivered(items[0]));

        // A swap pins the code that is there now (here, the altered code at a new address).
        AlteredVrfCoordinator next = new AlteredVrfCoordinator();
        _swap(address(next));
        vm.prank(stranger);
        uint256 again = module.requestSeed(_item(1), root, proofs[1]);
        next.fulfill(again, 8);
        assertEq(module.seedOf(items[1]), bytes32(uint256(8)));
    }

    // ------------------------------------------------------------------ one draw per content

    /// @dev Another item carrying item 0's content (its own one-item package): a revision of the
    ///      same work, with a different record file and so a different item hash.
    function _revision() internal returns (PackageItem memory item, bytes32 revisionRoot) {
        item = _makeItem(300, SeedPolicy.VRF);
        item.contentHash = _item(0).contentHash;
        revisionRoot = WorksHashing.leaf(_hash(item));
        registry.setStatus(revisionRoot, IPackageRegistry.PackageStatus.APPROVED);
    }

    function test_Content_TheFirstRequestLinksTheItem() public {
        vm.expectEmit(true, true, false, false, address(module));
        emit SeedLinked(items[0], _item(0).contentHash);
        vm.expectEmit(true, false, false, true, address(module));
        emit SeedRequested(items[0], 1);
        assertEq(_request(0), 1);
    }

    function test_Content_ASecondItemJoinsTheDeliveredDrawWithoutARequest() public {
        coordinator.fulfill(_request(0), 42);
        (PackageItem memory item, bytes32 revisionRoot) = _revision();
        bytes32 revision = _hash(item);
        uint256 nextId = coordinator.nextId();
        vm.recordLogs();
        vm.prank(stranger);
        assertEq(module.requestSeed(item, revisionRoot, new bytes32[](0)), 0);
        assertEq(_countModuleLogs(IEntropyModule.SeedLinked.selector), 1);
        assertEq(coordinator.nextId(), nextId, "the coordinator was not asked");
        assertTrue(module.isDelivered(revision));
        assertEq(module.seedOf(revision), bytes32(uint256(42)));
        // Linked once: a repeat reverts as for the first item.
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.SeedAlreadyDelivered.selector, revision)
        );
        module.requestSeed(item, revisionRoot, new bytes32[](0));
    }

    function test_Content_ASecondItemJoinsAPendingDrawAndSharesItsClock() public {
        uint256 first = _request(0);
        (PackageItem memory item, bytes32 revisionRoot) = _revision();
        bytes32 revision = _hash(item);
        assertEq(module.requestSeed(item, revisionRoot, new bytes32[](0)), 0, "joined");
        (uint256 requestId, uint64 requestedAt) = module.requestOf(revision);
        assertEq(requestId, first);
        assertEq(requestedAt, block.timestamp);
        uint64 retryAt = uint64(block.timestamp + RETRY_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.RequestPending.selector, revision, retryAt)
        );
        module.requestSeed(item, revisionRoot, new bytes32[](0));
        // Overdue, either item repeats the content's request; any delivery seeds both.
        vm.warp(retryAt);
        uint256 second = module.requestSeed(item, revisionRoot, new bytes32[](0));
        assertTrue(second != 0 && second != first);
        coordinator.fulfill(first, 9);
        assertEq(module.seedOf(items[0]), bytes32(uint256(9)));
        assertEq(module.seedOf(revision), bytes32(uint256(9)));
        coordinator.fulfill(second, 10);
        assertEq(module.seedOf(revision), bytes32(uint256(9)), "the first delivery wins");
    }

    /// @dev An item that never called `requestSeed` reads as undelivered, even when its content's
    ///      seed exists: Stream then refuses to mint it until it links.
    function test_Content_AnUnlinkedItemReadsAsUndelivered() public {
        coordinator.fulfill(_request(0), 42);
        (PackageItem memory item,) = _revision();
        bytes32 revision = _hash(item);
        assertFalse(module.isDelivered(revision));
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.SeedNotDelivered.selector, revision));
        module.seedOf(revision);
        (uint256 requestId, uint64 requestedAt) = module.requestOf(revision);
        assertEq(requestId, 0);
        assertEq(requestedAt, 0);
    }

    function test_Gate_RejectsAnItemWithoutAContentHash() public {
        PackageItem memory item = _makeItem(301, SeedPolicy.VRF);
        item.contentHash = 0;
        bytes32 itemRoot = WorksHashing.leaf(_hash(item));
        registry.setStatus(itemRoot, IPackageRegistry.PackageStatus.APPROVED);
        vm.expectRevert(_notRequestable(_hash(item)));
        module.requestSeed(item, itemRoot, new bytes32[](0));
    }

    function test_SeedOf_RevertsBeforeDelivery() public {
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.SeedNotDelivered.selector, items[0]));
        module.seedOf(items[0]);
        _request(0);
        vm.expectRevert(abi.encodeWithSelector(IEntropyModule.SeedNotDelivered.selector, items[0]));
        module.seedOf(items[0]);
    }

    function test_NoRequestAfterDelivery() public {
        uint256 id = _request(0);
        coordinator.fulfill(id, 7);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(
            abi.encodeWithSelector(IEntropyModule.SeedAlreadyDelivered.selector, items[0])
        );
        module.requestSeed(_item(0), root, proofs[0]);
        assertEq(module.seedOf(items[0]), bytes32(uint256(7)));
    }

    // ------------------------------------------------------------------ repeat

    function test_Repeat_BeforeTheTimeoutReverts() public {
        _request(0);
        uint256 requestedAt = block.timestamp;
        uint64 retryAt = uint64(requestedAt + RETRY_DELAY);
        uint256[3] memory waits = [uint256(0), 1, RETRY_DELAY - 1];
        for (uint256 w; w < waits.length; ++w) {
            vm.warp(requestedAt + waits[w]);
            vm.expectRevert(
                abi.encodeWithSelector(IEntropyModule.RequestPending.selector, items[0], retryAt)
            );
            module.requestSeed(_item(0), root, proofs[0]);
        }
        // Nothing changed: the first request is still the current one.
        (uint256 requestId, uint64 stamp) = module.requestOf(items[0]);
        assertEq(requestId, 1);
        assertEq(stamp, requestedAt);
    }

    function test_Repeat_AfterTheTimeoutIsOpenToAnyone() public {
        uint256 first = _request(0);
        (, uint64 firstAt) = module.requestOf(items[0]);
        vm.warp(firstAt + RETRY_DELAY);

        vm.expectEmit(true, false, false, true, address(module));
        emit SeedRequested(items[0], first + 1);
        vm.prank(admin);
        uint256 second = module.requestSeed(_item(0), root, proofs[0]);

        assertEq(second, first + 1);
        (uint256 requestId, uint64 requestedAt) = module.requestOf(items[0]);
        assertEq(requestId, second);
        assertEq(requestedAt, block.timestamp);
        // The delay restarts from the new request.
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntropyModule.RequestPending.selector,
                items[0],
                uint64(block.timestamp + RETRY_DELAY)
            )
        );
        module.requestSeed(_item(0), root, proofs[0]);
    }

    function test_Repeat_UsesTheCurrentConfiguration() public {
        _request(0);
        VrfEntropyModule.VrfConfig memory next = _config();
        next.subscriptionId = 0xBEEF;
        next.callbackGasLimit = 300_000;
        vm.prank(setter);
        module.setConfig(_config(), next);
        vm.warp(block.timestamp + RETRY_DELAY);
        vm.expectEmit(true, true, false, true, address(coordinator));
        emit RandomWordsRequested(
            2,
            address(module),
            KEY_HASH,
            0xBEEF,
            CONFIRMATIONS,
            300_000,
            1,
            abi.encodeWithSelector(bytes4(0x92fd1338), false)
        );
        _request(0);
    }

    /// @dev Every outstanding request may deliver; the first delivery fixes the seed and the rest
    ///      change nothing.
    function test_Repeat_EveryOutstandingRequestMayDeliverAndTheFirstWins() public {
        uint256[4] memory ids;
        ids[0] = _request(0);
        for (uint256 i = 1; i < ids.length; ++i) {
            vm.warp(block.timestamp + RETRY_DELAY);
            ids[i] = _request(0);
        }
        coordinator.fulfill(ids[1], 4444); // an earlier-than-latest request, delivered first
        for (uint256 i; i < ids.length; ++i) {
            coordinator.fulfill(ids[i], 9000 + i);
        }
        assertEq(module.seedOf(items[0]), bytes32(uint256(4444)));
    }

    /// @dev Review regression (PoC 2, inverted): after A to B to A, request IDs of different
    ///      coordinators that share a number stay apart. A's ID 1 is still item 0's request, not
    ///      item 1's, even though B issued ID 1 for item 1.
    function test_Repeat_RequestIdsDoNotMixAcrossCoordinators() public {
        MockVrfCoordinator b = new MockVrfCoordinator();
        uint256 idA = _request(0); // A issues 1 for item 0
        assertEq(idA, 1);
        _swap(address(b));
        uint256 idB = _request(1); // B issues 1 for item 1
        assertEq(idB, 1);
        _swap(address(coordinator)); // back to A

        coordinator.fulfill(idA, 0xA);
        assertEq(module.seedOf(items[0]), bytes32(uint256(0xA)));
        assertFalse(module.isDelivered(items[1]));
        // B no longer delivers, and its ID 1 did not become A's.
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntropyModule.OnlyCoordinatorCanFulfill.selector, address(b), address(coordinator)
            )
        );
        b.fulfill(idB, 0xB);
    }

    /// @dev Nit: while a repeat is being made, the coordinator delivers the EARLIER request. The
    ///      seed is then fixed when the call returns, so the new request is recorded but not
    ///      announced as the item's current request, and its own delivery is a no-op.
    function test_Repeat_AnEarlierRequestDeliveredDuringTheRepeatIsNotOverwritten() public {
        ReentrantVrfCoordinator evil = new ReentrantVrfCoordinator(module);
        _swap(address(evil));
        evil.aim(_item(0), root, proofs[0]);
        uint256 first = _request(0);
        assertEq(first, evil.ISSUED_ID());

        evil.armEarlierDelivery(first, 0xE);
        vm.warp(block.timestamp + RETRY_DELAY);
        vm.recordLogs();
        uint256 second = _request(0);
        assertEq(second, first + 1);

        assertTrue(evil.earlierSucceeded());
        assertEq(module.seedOf(items[0]), bytes32(uint256(0xE)));
        assertEq(_countModuleLogs(IEntropyModule.SeedRequested.selector), 0);
        (uint256 current,) = module.requestOf(items[0]);
        assertEq(current, 0, "delivered during the repeat: the word holds the seed");
        // The repeat's own delivery arrives later: a no-op, not a revert.
        evil.deliver(second, 0xF);
        assertEq(module.seedOf(items[0]), bytes32(uint256(0xE)));
    }

    function test_Repeat_OfOneItemLeavesOthersUntouched() public {
        uint256 other = _request(1);
        _request(0);
        vm.warp(block.timestamp + RETRY_DELAY);
        _request(0);
        coordinator.fulfill(other, 99);
        assertEq(module.seedOf(items[1]), bytes32(uint256(99)));
    }

    // ------------------------------------------------------------------ gas

    /// @dev The coordinator forwards exactly the configured limit; the callback must fit with a
    ///      wide margin even with every slot and account cold, at the smallest limit allowed.
    /// @dev Glamsterdam (EIP-8037 and EIP-8038), as ADR 0004 models it on Sepolia's measured
    ///      receipts: about 89,000 more per new storage slot than Prague, and a write to a
    ///      nonzero slot at 10,000 instead of Prague's 2,900.
    uint256 internal constant GLAMSTERDAM_NEW_SLOT_EXTRA = 89_000;
    uint256 internal constant GLAMSTERDAM_WRITE_EXTRA = 10_000 - 2900;

    /// Regression: CALLS-2, DEPS-2 (docs/security/internal-review-2026-10.md)
    /// @dev DEPS-2 (CALLS-2): the floor must hold under Glamsterdam, with the callback using at
    ///      most half of it. The callback rewrites two nonzero words (the seed over the request
    ///      ID, and the delivered flag) and creates no slot, measured with every slot cold.
    function test_Callback_UsesUnderHalfTheFloorUnderGlamsterdam() public {
        VrfEntropyModule.VrfConfig memory c = _config();
        c.callbackGasLimit = module.MIN_CALLBACK_GAS();
        VrfEntropyModule lean = _newModule(address(coordinator), c, RETRY_DELAY, address(registry));
        vm.prank(stranger);
        uint256 id = lean.requestSeed(_item(0), root, proofs[0]);
        uint256 snapshot = vm.snapshotState();
        vm.cool(address(lean));
        uint256 prague = coordinator.fulfill(id, type(uint256).max);
        vm.revertToState(snapshot);

        module = lean; // `_moduleSlots` counts the slots of `module`
        bytes memory deliver = abi.encodeCall(coordinator.fulfill, (id, type(uint256).max));
        uint256 newSlots = _moduleSlots(address(this), address(coordinator), deliver);
        uint256 glamsterdam =
            prague + newSlots * GLAMSTERDAM_NEW_SLOT_EXTRA + 2 * GLAMSTERDAM_WRITE_EXTRA;
        emit log_named_uint("callback, Prague gas (cold)", prague);
        emit log_named_uint("callback, Glamsterdam estimate", glamsterdam);
        assertEq(newSlots, 0);
        assertLe(2 * glamsterdam, lean.MIN_CALLBACK_GAS(), "the floor has a 2x margin");
    }

    function test_Callback_GasStaysUnderTheConfiguredLimit() public {
        VrfEntropyModule.VrfConfig memory c = _config();
        c.callbackGasLimit = module.MIN_CALLBACK_GAS();
        VrfEntropyModule lean = _newModule(address(coordinator), c, RETRY_DELAY, address(registry));
        vm.prank(stranger);
        uint256 id = lean.requestSeed(_item(0), root, proofs[0]);

        vm.cool(address(lean));
        uint256 gasUsed = coordinator.fulfill(id, type(uint256).max);

        emit log_named_uint("callback gas (cold)", gasUsed);
        assertTrue(lean.isDelivered(items[0]));
        assertLt(gasUsed, uint256(c.callbackGasLimit) / 2);
    }

    /// @dev The storage slots of `module` that one call creates (ADR 0004's state growth).
    function _moduleSlots(address caller, address target, bytes memory data)
        internal
        returns (uint256 n)
    {
        uint256 preCall = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.prank(caller);
        (bool ok,) = target.call(data);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertTrue(ok, "the measured call reverted");
        StateGrowth.Growth memory g = StateGrowth.count(accesses, preCall, caller, target);
        for (uint256 i; i < g.slots; ++i) {
            if (g.newSlots[i].account == address(module)) ++n;
        }
    }

    /// @dev Glamsterdam prices a new storage slot at about 111,000 gas, more than the callback
    ///      floor, so the callback creates none: the seed overwrites the word that held the
    ///      request ID. The slots are paid by the permissionless request instead.
    function test_Callback_CreatesNoStorageSlot() public {
        uint256 id = _request(0);
        bytes memory deliver = abi.encodeCall(coordinator.fulfill, (id, 5));
        assertEq(_moduleSlots(address(this), address(coordinator), deliver), 0);
        coordinator.fulfill(id, 5);
        assertEq(module.seedOf(items[0]), bytes32(uint256(5)));
        (uint256 requestId, uint64 requestedAt) = module.requestOf(items[0]);
        assertEq(requestId, 0, "no request is outstanding once the seed is delivered");
        assertEq(requestedAt, block.timestamp);
    }

    /// @dev A first request for a content creates four slots: the item's link, the draw's two
    ///      words and the request ID's record. An item joining a delivered draw creates one.
    function test_Request_NewStorageSlots() public {
        bytes memory first = abi.encodeCall(module.requestSeed, (_item(0), root, proofs[0]));
        assertEq(_moduleSlots(stranger, address(module), first), 4, "a fresh content");
        (uint256 id,) = module.requestOf(items[0]);
        coordinator.fulfill(id, 5);
        (PackageItem memory item, bytes32 revisionRoot) = _revision();
        bytes memory join =
            abi.encodeCall(module.requestSeed, (item, revisionRoot, new bytes32[](0)));
        assertEq(_moduleSlots(stranger, address(module), join), 1, "a joining item: its link");
    }

    /// @dev Reported for the budgets. `requestSeed` is off the auction's start path (decision D4),
    ///      so it has no 300K target; it counts everything in the transaction: the registry reads,
    ///      the two-hash proof, four new storage slots in the module and one in the mock (the
    ///      real coordinator costs more).
    function test_Request_GasOverhead() public {
        vm.startPrank(stranger);
        uint256 before = gasleft();
        module.requestSeed(_item(0), root, proofs[0]);
        uint256 used = before - gasleft();
        vm.stopPrank();
        emit log_named_uint("requestSeed gas (module + mock coordinator)", used);
        assertLt(used, 200_000);
    }
}
