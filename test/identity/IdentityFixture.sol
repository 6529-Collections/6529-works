// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { PackageRegistryStub } from "../mocks/identity/IdentityWorksMocks.sol";

/// @notice Shared setup for the identity tests: an AccessManager whose one network role holds
///         every restricted selector of the registry with no delay (the delay classes are the
///         governance lane's), the delegation-contract mock, the consolidation adapter and the
///         registry with its package registry bound (genesis wiring), plus one registered artist
///         whose root `artist` is consolidated (both ways, all collections) with `wallet`.
abstract contract IdentityFixture is Test {
    /// @dev The network's role in these tests.
    uint64 internal constant NETWORK = 1;

    uint256 internal constant START = 1_750_000_000;
    uint256 internal constant FAR = type(uint64).max;
    address internal constant ALL = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;

    AccessManager internal manager;
    DelegationManagementMock internal delegation;
    ConsolidationAdapter internal adapter;
    ArtistRegistry internal registry;
    address internal packageRegistry;

    address internal admin = makeAddr("admin");
    address internal network = makeAddr("network");
    address internal stranger = makeAddr("stranger");

    uint256 internal artistKey = 0xA1;
    uint256 internal walletKey = 0xB2;
    uint256 internal wallet2Key = 0xB3;
    uint256 internal newKey = 0xC3;
    uint256 internal outsiderKey = 0xD4;
    address internal artist;
    address internal wallet;
    address internal wallet2;
    address internal newRoot;
    address internal outsider;
    address internal payout = makeAddr("payout");
    uint256 internal artistId;

    bytes32 internal constant PROFILE = keccak256("profile/punk6529");
    bytes32 internal constant PROFILE_DOC = keccak256("profile document v1");
    bytes32 internal constant EVIDENCE = keccak256("evidence");

    function setUp() public virtual {
        artist = vm.addr(artistKey);
        wallet = vm.addr(walletKey);
        wallet2 = vm.addr(wallet2Key);
        newRoot = vm.addr(newKey);
        outsider = vm.addr(outsiderKey);
        vm.warp(START);

        manager = new AccessManager(admin);
        delegation = new DelegationManagementMock();
        adapter = new ConsolidationAdapter(IDelegationManagement(address(delegation)));
        registry = new ArtistRegistry(address(manager), adapter, address(adapter).codehash);
        packageRegistry = address(new PackageRegistryStub());
        _configureRoles(address(registry));
        vm.prank(admin);
        registry.bindPackageRegistry(packageRegistry);

        _consolidate(artist, wallet);
        artistId = _register(artist);
    }

    function _configureRoles(address target) internal {
        bytes4[] memory s = new bytes4[](11);
        s[0] = ArtistRegistry.stageReplacement.selector;
        s[1] = ArtistRegistry.cancelReplacement.selector;
        s[2] = ArtistRegistry.resolveContested.selector;
        s[3] = ArtistRegistry.freeze.selector;
        s[4] = ArtistRegistry.unfreeze.selector;
        s[5] = ArtistRegistry.setFederationDelisted.selector;
        s[6] = ArtistRegistry.lowerFederatedFeeShare.selector;
        s[7] = ArtistRegistry.setConsolidationSource.selector;
        s[8] = ArtistRegistry.setPackageRegistry.selector;
        s[9] = ArtistRegistry.setFederationRegistry.selector;
        s[10] = ArtistRegistry.cancelOwnChange.selector;
        vm.startPrank(admin);
        manager.setTargetFunctionRole(target, s, NETWORK);
        manager.grantRole(NETWORK, network, 0);
        vm.stopPrank();
    }

    function _register(address account) internal returns (uint256 id) {
        vm.prank(packageRegistry);
        id = registry.register(account, PROFILE, PROFILE_DOC);
    }

    /// @dev Registers a consolidation of `a` and `b` in both directions, for all collections.
    function _consolidate(address a, address b) internal {
        _delegate(a, b, FAR);
        _delegate(b, a, FAR);
    }

    function _delegate(address from, address to, uint256 expiry) internal {
        vm.prank(from);
        delegation.registerDelegationAddress(ALL, to, expiry, CONSOLIDATION, true, 0);
    }

    function _revoke(address from, address to) internal {
        vm.prank(from);
        delegation.revokeDelegationAddress(ALL, to, CONSOLIDATION);
    }

    function _identity(address root_, address payout_)
        internal
        pure
        returns (ArtistIdentity memory)
    {
        return ArtistIdentity(root_, payout_, PROFILE, keccak256("profile document v2"));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The proof `requireSigned` takes: the signing wallet, then its signature.
    function _proof(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        return abi.encodePacked(vm.addr(key), _sign(key, digest));
    }

    function _changeCall(uint256 signerKey, ArtistIdentity memory next)
        internal
        view
        returns (bytes memory)
    {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest =
            registry.changeDigest(artistId, next, registry.changeNonce(artistId), deadline);
        return abi.encodeCall(
            ArtistRegistry.stageChange, (artistId, next, deadline, _proof(signerKey, digest))
        );
    }

    /// @dev Stages the account's own change signed by `signerKey`, relayed by a stranger.
    function _stage(uint256 signerKey, ArtistIdentity memory next) internal {
        (bool ok, bytes memory data) = _relay(_changeCall(signerKey, next));
        _ok(ok, data);
    }

    function _relay(bytes memory data) internal returns (bool ok, bytes memory result) {
        vm.prank(stranger);
        (ok, result) = address(registry).call(data);
    }

    function _replacementCall(ArtistIdentity memory next, uint256 acceptKey)
        internal
        view
        returns (bytes memory)
    {
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes memory acceptance =
            _sign(acceptKey, registry.replacementDigest(artistId, next, EVIDENCE, deadline));
        return abi.encodeCall(
            ArtistRegistry.stageReplacement, (artistId, next, EVIDENCE, deadline, acceptance)
        );
    }

    /// @dev Stages a network replacement to `next`, accepted by `acceptKey`.
    function _stageReplacement(ArtistIdentity memory next, uint256 acceptKey) internal {
        bytes memory data = _replacementCall(next, acceptKey);
        vm.prank(network);
        (bool ok, bytes memory result) = address(registry).call(data);
        _ok(ok, result);
    }

    /// @dev Bubbles a failed low-level call's revert data.
    function _ok(bool ok, bytes memory data) internal pure {
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
    }
}
