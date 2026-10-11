// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Roles } from "src/governance/Roles.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, ChangeKind } from "src/interfaces/types/IdentityTypes.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { PackageRegistryStub } from "../mocks/identity/IdentityWorksMocks.sol";

/// @notice Shared setup for the identity tests: an AccessManager with the registry's selectors
///         mapped to the governance lane's role IDs, the delegation-contract mock, the
///         consolidation adapter and the registry with its package registry bound by the admin
///         (genesis wiring), plus one registered artist whose wallet has been consolidated (both
///         directions, all collections) for 60 days.
abstract contract IdentityFixture is Test {
    uint64 internal constant GUARDIAN = Roles.GUARDIAN;
    uint64 internal constant PARAMETER_SETTER = Roles.PARAMETER_SETTER;
    uint64 internal constant SUCCESSOR_SETTER = Roles.SUCCESSOR_SETTER;

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
    address internal guardian = makeAddr("guardian");
    address internal governor = makeAddr("governor");
    address internal successorSetter = makeAddr("successorSetter");
    address internal stranger = makeAddr("stranger");

    uint256 internal artistKey = 0xA1;
    uint256 internal walletKey = 0xB2;
    uint256 internal wallet2Key = 0xB3;
    uint256 internal newKey = 0xC3;
    uint256 internal thiefKey = 0xD4;
    address internal artist;
    address internal wallet;
    address internal wallet2;
    address internal newAuthority;
    address internal thief;
    address internal payout = makeAddr("payout");
    uint256 internal artistId;

    bytes32 internal constant PROFILE = keccak256("profile/punk6529");
    bytes32 internal constant PROFILE_DOC = keccak256("profile document v1");

    function setUp() public virtual {
        artist = vm.addr(artistKey);
        wallet = vm.addr(walletKey);
        wallet2 = vm.addr(wallet2Key);
        newAuthority = vm.addr(newKey);
        thief = vm.addr(thiefKey);
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
        vm.warp(START + 60 days);
        artistId = _register(artist);
    }

    function _configureRoles(address target) internal {
        vm.startPrank(admin);
        _map(target, ArtistRegistry.vetoChange.selector, GUARDIAN);
        _map(target, ArtistRegistry.stageOverride.selector, PARAMETER_SETTER);
        _map(target, ArtistRegistry.setConsolidationSource.selector, SUCCESSOR_SETTER);
        _map(target, ArtistRegistry.resolveContested.selector, SUCCESSOR_SETTER);
        // The bind* selectors stay on the AccessManager default (ADMIN): genesis wiring.
        manager.grantRole(GUARDIAN, guardian, 0);
        manager.grantRole(PARAMETER_SETTER, governor, 0);
        manager.grantRole(SUCCESSOR_SETTER, successorSetter, 0);
        vm.stopPrank();
    }

    function _map(address target, bytes4 selector, uint64 role) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
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

    function _identity(address authority_, address payout_)
        internal
        pure
        returns (ArtistIdentity memory)
    {
        return ArtistIdentity(authority_, payout_, PROFILE, keccak256("profile document v2"));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _digest(ArtistIdentity memory next, uint64 deadline) internal view returns (bytes32) {
        return registry.changeDigest(artistId, next, registry.changeNonce(artistId), deadline);
    }

    bytes internal armedRevert;

    /// @dev Makes the next {_stage} expect `err`, armed after its own view calls.
    function _armRevert(bytes memory err) internal {
        armedRevert = err;
    }

    /// @dev Stages `next` signed by `signerKey`; a new authority countersigns with `acceptKey`.
    function _stage(uint256 signerKey, ArtistIdentity memory next, uint256 acceptKey) internal {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = _digest(next, deadline);
        bytes memory acceptance = acceptKey == 0 ? bytes("") : _sign(acceptKey, digest);
        if (armedRevert.length != 0) {
            vm.expectRevert(armedRevert);
            delete armedRevert;
        }
        registry.stageChange(
            artistId, next, vm.addr(signerKey), deadline, _sign(signerKey, digest), acceptance
        );
    }

    /// @dev Stages an override as the governor; a new authority accepts with `acceptKey` (zero
    ///      for none).
    function _stageOverride(ChangeKind kind, ArtistIdentity memory next, uint256 acceptKey)
        internal
    {
        bytes32 evidence = keccak256("evidence");
        bytes memory acceptance;
        uint64 deadline = uint64(block.timestamp + 3 days);
        if (acceptKey != 0) {
            acceptance =
                _sign(acceptKey, registry.overrideDigest(artistId, kind, next, evidence, deadline));
        }
        if (armedRevert.length != 0) {
            vm.expectRevert(armedRevert);
            delete armedRevert;
        }
        vm.prank(governor);
        registry.stageOverride(artistId, kind, next, evidence, deadline, acceptance);
    }

    function _cancellers() internal view returns (address[] memory) {
        return registry.pendingChange(artistId).cancellers;
    }

    function _source() internal view returns (IConsolidationSource) {
        return registry.consolidationSource();
    }

    /// @dev The registry's ID-derivation rule, as documented in `IArtistRegistry`.
    function _idOf(address account) internal view returns (uint256 id) {
        id = registry.artistIdOf(account);
        if (id == 0) id = uint256(uint160(account));
    }
}
