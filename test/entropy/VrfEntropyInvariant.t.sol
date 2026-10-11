// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { MockPackageRegistry, MockVrfCoordinator } from "test/mocks/EntropyMocks.sol";
import { EntropyBase, EntropyItems } from "./EntropyBase.sol";

/// @dev Drives the module with arbitrary requests, deliveries, revocations and consumptions, and
///      tracks what must hold: the handler predicts the outcome of every call, and `violations`
///      counts each prediction the module got wrong (so a delivery that reverts or changes a fixed seed, a
///      request that got past the package gate or the policy check, or a wrongly refused request
///      shows). Indexes 0 to 3 are the VRF items of the four-item package; 4 and 5 are items of
///      one-item packages whose seed policy is NONE and ARTIST, which must never be accepted.
contract EntropyHandler is Test, EntropyItems {
    uint256 internal constant VRF_ITEMS = 4;
    uint256 internal constant ITEMS = 6;

    VrfEntropyModule internal immutable module;
    MockVrfCoordinator internal immutable coordinator;
    MockPackageRegistry internal immutable registry;
    bytes32 internal immutable root;
    bytes32 internal immutable noneRoot;
    bytes32 internal immutable artistRoot;
    uint64 internal immutable retryDelay;
    bytes32[][4] internal proofs;

    mapping(uint256 index => uint256[]) internal issued;
    mapping(uint256 index => uint256) public currentId;
    mapping(uint256 index => bool) public delivered;
    mapping(uint256 index => bytes32) public deliveredSeed;
    mapping(uint256 index => uint256) public deliveries;
    uint256 public violations;
    uint256 public accepted;

    /// @param roots_ The four-item package's root, then the roots of the NONE and ARTIST packages.
    constructor(
        VrfEntropyModule module_,
        MockVrfCoordinator coordinator_,
        MockPackageRegistry registry_,
        bytes32[3] memory roots_
    ) {
        module = module_;
        coordinator = coordinator_;
        registry = registry_;
        (root, noneRoot, artistRoot) = (roots_[0], roots_[1], roots_[2]);
        retryDelay = module_.retryDelay();
    }

    function setProof(uint256 i, bytes32[] calldata proof) external {
        proofs[i] = proof;
    }

    function itemOf(uint256 i) public pure returns (PackageItem memory) {
        if (i < VRF_ITEMS) return _makeItem(i, SeedPolicy.VRF);
        SeedPolicy policy = i == VRF_ITEMS ? SeedPolicy.NONE : SeedPolicy.ARTIST;
        return _makeItem(PLAIN_SALT + uint256(policy), policy);
    }

    function itemHash(uint256 i) public pure returns (bytes32) {
        return _hash(itemOf(i));
    }

    /// @dev Whether the rules say a request for item `i` is accepted now.
    function _requestAllowed(uint256 i) internal view returns (bool) {
        (, uint64 requestedAt) = module.requestOf(itemHash(i));
        return i < VRF_ITEMS && !delivered[i]
            && registry.statusOf(root) == IPackageRegistry.PackageStatus.APPROVED
            && registry.consumedBy(itemOf(i).contentHash) == 0
            && (requestedAt == 0 || block.timestamp >= requestedAt + retryDelay);
    }

    function _rootOf(uint256 i) internal view returns (bytes32) {
        return i < VRF_ITEMS ? root : (i == VRF_ITEMS ? noneRoot : artistRoot);
    }

    function _proofOf(uint256 i) internal view returns (bytes32[] memory) {
        return i < VRF_ITEMS ? proofs[i] : new bytes32[](0);
    }

    function request(uint256 itemSeed, uint256 callerSeed, uint256 wait) external {
        uint256 i = itemSeed % ITEMS;
        vm.warp(block.timestamp + (wait % 36 hours));
        bool allowed = _requestAllowed(i);

        vm.prank(address(uint160(callerSeed)));
        try module.requestSeed(itemOf(i), _rootOf(i), _proofOf(i)) returns (uint256 id) {
            if (!allowed) ++violations;
            ++accepted;
            issued[i].push(id);
            currentId[i] = id;
        } catch {
            if (allowed) ++violations;
        }
    }

    /// @dev A delivery for any request ever issued for the item, current or earlier. The first
    ///      one fixes the seed; later ones are no-ops. None may revert.
    function fulfill(uint256 itemSeed, uint256 pick, uint256 word) external {
        uint256 i = itemSeed % ITEMS;
        uint256 count = issued[i].length;
        if (count == 0) return;
        uint256 id = issued[i][pick % count];

        try coordinator.fulfill(id, word) {
            if (!delivered[i]) {
                delivered[i] = true;
                deliveredSeed[i] = bytes32(word);
                ++deliveries[i];
            }
        } catch {
            ++violations;
        }
    }

    /// @dev The guardian revokes the package, or it is approved again (the gate is stateless).
    function setApproved(bool approved) external {
        registry.setStatus(
            root,
            approved
                ? IPackageRegistry.PackageStatus.APPROVED
                : IPackageRegistry.PackageStatus.REVOKED
        );
    }

    /// @dev An item is consumed by a start, or not.
    function setConsumed(uint256 itemSeed, bool value) external {
        PackageItem memory item = itemOf(itemSeed % ITEMS);
        registry.setConsumedBy(item.contentHash, value ? _hash(item) : bytes32(0));
    }

    function itemCount() external pure returns (uint256) {
        return ITEMS;
    }
}

/// @notice Stateful invariants of the entropy module.
contract VrfEntropyInvariantTest is EntropyBase {
    EntropyHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new EntropyHandler(
            module,
            coordinator,
            registry,
            [root, plainRoot(SeedPolicy.NONE), plainRoot(SeedPolicy.ARTIST)]
        );
        for (uint256 i; i < 4; ++i) {
            handler.setProof(i, proofs[i]);
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = EntropyHandler.request.selector;
        selectors[1] = EntropyHandler.fulfill.selector;
        selectors[2] = EntropyHandler.setApproved.selector;
        selectors[3] = EntropyHandler.setConsumed.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @dev Every request, repeat and delivery had the outcome the rules predict: a request only
    ///      for an approved, unconsumed VRF item of an approved package, a repeat only after the
    ///      delay, and a delivery for any request ever issued, which never reverts.
    function invariant_EveryCallHadThePredictedOutcome() public view {
        assertEq(handler.violations(), 0);
    }

    /// @dev One seed per item: at most one delivery ever succeeded, and the module agrees about
    ///      which items are delivered and what their seeds are, forever.
    function invariant_AtMostOneSeedPerItemAndItNeverChanges() public view {
        for (uint256 i; i < handler.itemCount(); ++i) {
            bytes32 hash = handler.itemHash(i);
            assertLe(handler.deliveries(i), 1);
            assertEq(module.isDelivered(hash), handler.delivered(i));
            if (handler.delivered(i)) {
                assertEq(module.seedOf(hash), handler.deliveredSeed(i));
            }
        }
    }

    /// @dev The module's current request of an item is the last one it issued; an item whose
    ///      seed policy is not VRF never has one.
    function invariant_TheCurrentRequestIsTheLastIssued() public view {
        for (uint256 i; i < handler.itemCount(); ++i) {
            (uint256 requestId,) = module.requestOf(handler.itemHash(i));
            assertEq(requestId, handler.currentId(i));
            if (i >= 4) assertEq(requestId, 0);
        }
    }
}
