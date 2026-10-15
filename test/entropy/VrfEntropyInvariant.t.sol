// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import {
    EntropyPackageRegistryMock,
    MockVrfCoordinator
} from "test/mocks/entropy/EntropyMocks.sol";
import { EntropyBase, EntropyItems } from "./EntropyBase.sol";

/// @dev Drives the module with arbitrary requests, deliveries, revocations and consumptions, and
///      tracks what must hold: the handler predicts the outcome of every call, and `violations`
///      counts each prediction the module got wrong (so a delivery that reverts or changes a
///      fixed seed, a request that got past the package gate or the policy check, or a wrongly
///      refused request shows). Indexes 0 to 3 are the VRF items of the four-item package; 4 and
///      5 are items of one-item packages whose seed policy is NONE and ARTIST, which must never
///      be accepted; 6 and 7 are VRF items of their own one-item packages that carry the content
///      of items 0 and 1 (revisions of the same works), so they share those items' draws.
contract EntropyHandler is Test, EntropyItems {
    uint256 internal constant VRF_ITEMS = 4;
    uint256 internal constant ITEMS = 8;
    uint256 internal constant TWIN_SALT = 300;

    VrfEntropyModule internal immutable module;
    MockVrfCoordinator internal immutable coordinator;
    EntropyPackageRegistryMock internal immutable registry;
    bytes32 internal immutable root;
    bytes32 internal immutable noneRoot;
    bytes32 internal immutable artistRoot;
    uint64 internal immutable retryDelay;
    bytes32[][4] internal proofs;

    /// @dev The model is per content (the draw) and per item (its link to the draw).
    mapping(uint256 index => bool) public linked;
    mapping(uint256 content => uint256[]) internal issued;
    mapping(uint256 content => uint256) internal _currentId;
    mapping(uint256 content => uint64) internal _requestedAt;
    mapping(uint256 content => bool) internal _delivered;
    mapping(uint256 content => bytes32) internal _seed;
    mapping(uint256 content => uint256) internal _deliveries;
    uint256 public violations;
    uint256 public accepted;

    /// @param roots_ The four-item package's root, then the roots of the NONE and ARTIST packages.
    constructor(
        VrfEntropyModule module_,
        MockVrfCoordinator coordinator_,
        EntropyPackageRegistryMock registry_,
        bytes32[3] memory roots_
    ) {
        module = module_;
        coordinator = coordinator_;
        registry = registry_;
        (root, noneRoot, artistRoot) = (roots_[0], roots_[1], roots_[2]);
        retryDelay = module_.retryDelay();
        for (uint256 i = 6; i < ITEMS; ++i) {
            registry_.setStatus(_twinRoot(i), IPackageRegistry.PackageStatus.APPROVED);
        }
    }

    function setProof(uint256 i, bytes32[] calldata proof) external {
        proofs[i] = proof;
    }

    function itemOf(uint256 i) public pure returns (PackageItem memory item) {
        if (i < VRF_ITEMS) return _makeItem(i, SeedPolicy.VRF);
        if (i >= 6) {
            item = _makeItem(TWIN_SALT + i, SeedPolicy.VRF);
            item.contentHash = _makeItem(i - 6, SeedPolicy.VRF).contentHash;
            return item;
        }
        SeedPolicy policy = i == VRF_ITEMS ? SeedPolicy.NONE : SeedPolicy.ARTIST;
        return _makeItem(PLAIN_SALT + uint256(policy), policy);
    }

    function itemHash(uint256 i) public pure returns (bytes32) {
        return _hash(itemOf(i));
    }

    /// @notice The content (draw) item `i` reads: the revisions read their originals' draws.
    function contentOf(uint256 i) public pure returns (uint256) {
        return i >= 6 ? i - 6 : i;
    }

    function delivered(uint256 i) external view returns (bool) {
        return linked[i] && _delivered[contentOf(i)];
    }

    function deliveredSeed(uint256 i) external view returns (bytes32) {
        return _seed[contentOf(i)];
    }

    function deliveries(uint256 i) external view returns (uint256) {
        return _deliveries[contentOf(i)];
    }

    /// @notice The request `requestOf(item)` must report: the content's latest, until delivered.
    function currentId(uint256 i) external view returns (uint256) {
        uint256 c = contentOf(i);
        return linked[i] && !_delivered[c] ? _currentId[c] : 0;
    }

    function _vrf(uint256 i) internal pure returns (bool) {
        return i < VRF_ITEMS || i >= 6;
    }

    /// @dev Whether the gate admits item `i` now: VRF, approved root, unconsumed content.
    function _gateOpen(uint256 i) internal view returns (bool) {
        return _vrf(i) && registry.statusOf(_rootOf(i)) == IPackageRegistry.PackageStatus.APPROVED
            && registry.consumedBy(itemOf(i).contentHash) == 0;
    }

    function _pending(uint256 c) internal view returns (bool) {
        return _requestedAt[c] != 0 && block.timestamp < _requestedAt[c] + retryDelay;
    }

    function _twinRoot(uint256 i) internal pure returns (bytes32) {
        return WorksHashing.leaf(_hash(itemOf(i)));
    }

    function _rootOf(uint256 i) internal view returns (bytes32) {
        if (i >= 6) return _twinRoot(i);
        return i < VRF_ITEMS ? root : (i == VRF_ITEMS ? noneRoot : artistRoot);
    }

    function _proofOf(uint256 i) internal view returns (bytes32[] memory) {
        return i < VRF_ITEMS ? proofs[i] : new bytes32[](0);
    }

    /// @dev A request: refused by the gate; for an item not yet linked, a join that returns zero
    ///      when the content's draw is delivered or pending; for a linked item, refused then; and
    ///      otherwise a new request for the content.
    function request(uint256 itemSeed, uint256 callerSeed, uint256 wait) external {
        uint256 i = itemSeed % ITEMS;
        uint256 c = contentOf(i);
        vm.warp(block.timestamp + (wait % 36 hours));
        bool open = _gateOpen(i);
        bool joins = open && !linked[i] && (_delivered[c] || _pending(c));
        bool requests = open && !_delivered[c] && !_pending(c);

        vm.prank(address(uint160(callerSeed)));
        try module.requestSeed(itemOf(i), _rootOf(i), _proofOf(i)) returns (uint256 id) {
            if (!(joins || requests) || (joins && id != 0) || (requests && id == 0)) {
                ++violations;
            }
            ++accepted;
            linked[i] = true;
            if (id != 0) {
                issued[c].push(id);
                _currentId[c] = id;
                _requestedAt[c] = uint64(block.timestamp);
            }
        } catch {
            if (joins || requests) ++violations;
        }
    }

    /// @dev A delivery for any request ever issued for the item's content, current or earlier.
    ///      The first one fixes the seed; later ones are no-ops. None may revert.
    function fulfill(uint256 itemSeed, uint256 pick, uint256 word) external {
        uint256 c = contentOf(itemSeed % ITEMS);
        uint256 count = issued[c].length;
        if (count == 0) return;
        uint256 id = issued[c][pick % count];

        try coordinator.fulfill(id, word) {
            if (!_delivered[c]) {
                _delivered[c] = true;
                _seed[c] = bytes32(word);
                ++_deliveries[c];
            }
        } catch {
            ++violations;
        }
    }

    /// @dev The guardian revokes the packages, or they are approved again (the gate is
    ///      stateless).
    function setApproved(bool approved) external {
        IPackageRegistry.PackageStatus status = approved
            ? IPackageRegistry.PackageStatus.APPROVED
            : IPackageRegistry.PackageStatus.REVOKED;
        registry.setStatus(root, status);
        for (uint256 i = 6; i < ITEMS; ++i) {
            registry.setStatus(_twinRoot(i), status);
        }
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

    /// @dev One seed per content: at most one delivery ever succeeded for a content, and the
    ///      module agrees about which items are delivered and what their seeds are, forever.
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

    /// @dev The module's current request of an item is the last one its content's draw issued
    ///      until the seed is delivered, then zero; an item never linked, or whose seed policy is
    ///      not VRF, never has one.
    function invariant_TheCurrentRequestIsTheLastIssued() public view {
        for (uint256 i; i < handler.itemCount(); ++i) {
            (uint256 requestId,) = module.requestOf(handler.itemHash(i));
            assertEq(requestId, handler.currentId(i));
            if (i == 4 || i == 5) assertEq(requestId, 0);
        }
    }

    /// @dev One draw per content: items that share a content hash (items 0 and 1 and their
    ///      revisions 6 and 7) read equal seeds once both are linked and the draw delivered.
    function invariant_ItemsThatShareContentReadOneSeed() public view {
        for (uint256 i = 6; i < handler.itemCount(); ++i) {
            bytes32 revision = handler.itemHash(i);
            bytes32 original = handler.itemHash(i - 6);
            if (module.isDelivered(revision) && module.isDelivered(original)) {
                assertEq(module.seedOf(revision), module.seedOf(original));
            }
        }
    }
}
