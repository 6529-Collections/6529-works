// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { VrfEntropyModule } from "src/entropy/VrfEntropyModule.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEntropyModule } from "src/interfaces/IEntropyModule.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { CURRENCY_DEFAULT } from "src/interfaces/types/EconomicsTypes.sol";
import {
    ItemKind,
    License,
    PackageItem,
    Party,
    PartyRole,
    SaleTerms,
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { MockPackageRegistry, MockVrfCoordinator } from "test/mocks/EntropyMocks.sol";

/// @dev Builds package items without storing them: an item holds arrays of structs, which the
///      legacy code generator cannot copy from memory to storage, so tests rebuild an item from
///      its salt whenever they need it.
abstract contract EntropyItems {
    /// @dev Salts of the one-item packages' items (the four-item package uses 0 to 3).
    uint256 internal constant SOLO_SALT = 100;
    uint256 internal constant PLAIN_SALT = 200;

    /// @dev A one-party item with the given seed policy; `salt` makes its hash unique. The seed is
    ///      nonzero only under ARTIST, as `PackageItem` requires.
    function _makeItem(uint256 salt, SeedPolicy policy)
        internal
        pure
        returns (PackageItem memory item)
    {
        address artist = address(uint160(uint256(keccak256(abi.encode("artist", salt)))));
        item.kind = ItemKind.ORIGINAL;
        item.collectionId = 1;
        item.contentHash = keccak256(abi.encode("content", salt));
        item.mediaHash = keccak256(abi.encode("media", salt));
        item.recordFileId = keccak256(abi.encode("record", salt));
        item.parties = new Party[](1);
        item.parties[0] = Party(artist, PartyRole.ARTIST);
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(0, artist, 100_000);
        item.license = License("CC0-1.0", keccak256("cc0 text"));
        item.seedPolicy = policy;
        if (policy == SeedPolicy.ARTIST) item.seed = keccak256(abi.encode("seed", salt));
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_DEFAULT, "");
    }

    function _hash(PackageItem memory item) internal pure returns (bytes32) {
        return WorksHashing.itemHash(item);
    }
}

/// @dev Fixtures shared by the entropy tests: the module under a stock OpenZeppelin
///      `AccessManager` with the two roles its governed selectors map to, a mock coordinator, and
///      a mock package registry that approves these packages:
///      - a four-item VRF package (items 0 to 3, real Merkle proofs);
///      - a one-item VRF package (`soloRoot`, its root is its leaf, an empty proof);
///      - one-item packages whose item has seed policy NONE or ARTIST (`plainRoot(policy)`).
abstract contract EntropyBase is Test, EntropyItems {
    uint64 internal constant RETRY_DELAY = 3 days;
    uint256 internal constant SUBSCRIPTION = 0xA11CE;
    bytes32 internal constant KEY_HASH = keccak256("gas-lane");
    uint32 internal constant GAS_LIMIT = 200_000;
    uint16 internal constant CONFIRMATIONS = 3;

    address internal admin = makeAddr("admin");
    address internal setter = makeAddr("setter");
    address internal successor = makeAddr("successor");
    address internal stranger = makeAddr("stranger");
    address internal other = makeAddr("other");

    AccessManager internal manager;
    MockVrfCoordinator internal coordinator;
    MockPackageRegistry internal registry;
    VrfEntropyModule internal module;

    /// @dev The four-item package: the root, the item hashes and each item's Merkle proof.
    bytes32 internal root;
    bytes32[4] internal items;
    bytes32[][4] internal proofs;
    bytes32 internal soloRoot;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        manager = new AccessManager(admin);
        coordinator = new MockVrfCoordinator();
        registry = new MockPackageRegistry();
        module = _deploy(coordinator);

        // The deploy configuration maps `setConfig` to the 48-hour class and `setCoordinator` to
        // the 30-day class. `requestSeed` has no role: the package is the gate. The unit tests
        // grant every role with no delay.
        vm.startPrank(admin);
        manager.grantRole(Roles.PARAMETER_SETTER, setter, 0);
        manager.grantRole(Roles.SUCCESSOR_SETTER, successor, 0);
        manager.setTargetFunctionRole(
            address(module), _selector(module.setConfig.selector), Roles.PARAMETER_SETTER
        );
        manager.setTargetFunctionRole(
            address(module), _selector(module.setCoordinator.selector), Roles.SUCCESSOR_SETTER
        );
        vm.stopPrank();

        // A four-leaf tree: root = pair(pair(l0, l1), pair(l2, l3)).
        bytes32[4] memory leaves;
        for (uint256 i; i < 4; ++i) {
            items[i] = _hash(_item(i));
            leaves[i] = WorksHashing.leaf(items[i]);
        }
        bytes32 left = _pair(leaves[0], leaves[1]);
        bytes32 right = _pair(leaves[2], leaves[3]);
        root = _pair(left, right);
        proofs[0] = _proof(leaves[1], right);
        proofs[1] = _proof(leaves[0], right);
        proofs[2] = _proof(leaves[3], left);
        proofs[3] = _proof(leaves[2], left);
        registry.setStatus(root, IPackageRegistry.PackageStatus.APPROVED);

        soloRoot = WorksHashing.leaf(_hash(_solo()));
        registry.setStatus(soloRoot, IPackageRegistry.PackageStatus.APPROVED);
        registry.setStatus(plainRoot(SeedPolicy.NONE), IPackageRegistry.PackageStatus.APPROVED);
        registry.setStatus(plainRoot(SeedPolicy.ARTIST), IPackageRegistry.PackageStatus.APPROVED);
    }

    function _deploy(MockVrfCoordinator coordinator_) internal returns (VrfEntropyModule) {
        return _newModule(address(coordinator_), _config(), RETRY_DELAY, address(registry));
    }

    /// @dev A module whose pinned code hashes are those of the deployed coordinator and registry
    ///      (an account without code has hash zero or the empty-code hash, which the module
    ///      rejects before it compares).
    function _newModule(
        address coordinator_,
        VrfEntropyModule.VrfConfig memory config_,
        uint64 retryDelay_,
        address registry_
    ) internal returns (VrfEntropyModule) {
        return new VrfEntropyModule(
            address(manager),
            coordinator_,
            coordinator_.codehash,
            config_,
            retryDelay_,
            IPackageRegistry(registry_),
            registry_.codehash
        );
    }

    /// @dev The successor swaps the module's coordinator, pinning the new one's code hash.
    function _swap(address next) internal {
        address current = module.coordinator();
        bytes32 codeHash = next.codehash;
        vm.prank(successor);
        module.setCoordinator(current, next, codeHash);
    }

    /// @dev Item `i` (0 to 3) of the four-item package: a VRF item.
    function _item(uint256 i) internal pure returns (PackageItem memory) {
        return _makeItem(i, SeedPolicy.VRF);
    }

    /// @dev The VRF item of the one-item package.
    function _solo() internal pure returns (PackageItem memory) {
        return _makeItem(SOLO_SALT, SeedPolicy.VRF);
    }

    /// @dev The item (policy NONE or ARTIST) of a one-item package.
    function _plain(SeedPolicy policy) internal pure returns (PackageItem memory) {
        return _makeItem(PLAIN_SALT + uint256(policy), policy);
    }

    /// @dev The root of the one-item package of `_plain(policy)`: its leaf.
    function plainRoot(SeedPolicy policy) internal pure returns (bytes32) {
        return WorksHashing.leaf(_hash(_plain(policy)));
    }

    /// @dev The revert data of every failure of the spam gate.
    function _notRequestable(bytes32 itemHash) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IEntropyModule.NotRequestable.selector, itemHash);
    }

    function _proof(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](2);
        out[0] = a;
        out[1] = b;
    }

    /// @dev OpenZeppelin's commutative node hash.
    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _config() internal pure returns (VrfEntropyModule.VrfConfig memory) {
        return VrfEntropyModule.VrfConfig({
            subscriptionId: SUBSCRIPTION,
            keyHash: KEY_HASH,
            callbackGasLimit: GAS_LIMIT,
            confirmations: CONFIRMATIONS,
            nativePayment: false
        });
    }

    function _selector(bytes4 s) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](1);
        out[0] = s;
    }

    /// @dev Requests the seed of item `i` of the four-item package, as `stranger`.
    function _request(uint256 i) internal returns (uint256 requestId) {
        vm.prank(stranger);
        requestId = module.requestSeed(_item(i), root, proofs[i]);
    }

    /// @dev How many of the recorded logs were emitted by the module with `topic0`. Clears them.
    function _countModuleLogs(bytes32 topic0) internal view returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(module) && logs[i].topics[0] == topic0) ++count;
        }
    }

    function _oneWord(uint256 word) internal pure returns (uint256[] memory words) {
        words = new uint256[](1);
        words[0] = word;
    }
}
