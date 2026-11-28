// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Accounts } from "src/identity/Accounts.sol";
import { ConsolidationAdapter, IDelegationManagement } from "src/identity/ConsolidationAdapter.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import {
    DisputeOutcomeLogMock,
    PackageRegistryStub,
    SplitFactoryWalletsMock
} from "../mocks/identity/IdentityStreamMocks.sol";

/// @notice A directory whose module slots the test sets: `Accounts` asks it for the Independent
///         Stream module (the only `registerIndependent` caller).
contract DirectoryStub {
    mapping(bytes32 slot => address) public moduleOf;

    function setModule(bytes32 slot, address module) external {
        moduleOf[slot] = module;
    }
}

/// @notice Shared setup for the identity tests: an AccessManager whose one network role holds
///         every restricted selector of `Accounts` with no delay, the delegation-contract mock,
///         the consolidation adapter, and the accounts module deployed with its wiring (a
///         directory stub, stand-in Stream and Editions addresses, a split factory whose vaults
///         the test sets, a statement log whose outcomes the test sets, a package registry), plus
///         one registered artist whose root `artist` is consolidated (both ways, all
///         collections) with `wallet`.
abstract contract AccountsFixture is Test {
    /// @dev The network's role in these tests.
    uint64 internal constant NETWORK = 1;

    uint256 internal constant START = 1_750_000_000;
    uint256 internal constant FAR = type(uint64).max;
    address internal constant ALL = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CONSOLIDATION = 999;
    /// @dev `Slots.ACCOUNTS`: the fixture's module is the one in force.
    bytes32 internal constant ACCOUNTS_SLOT = "ACCOUNTS";

    AccessManager internal manager;
    DelegationManagementMock internal delegation;
    ConsolidationAdapter internal adapter;
    Accounts internal registry;
    DirectoryStub internal directory;
    SplitFactoryWalletsMock internal factory;
    DisputeOutcomeLogMock internal outcomes;
    address internal packageRegistry;
    address internal streamAddr = makeAddr("stream");
    address internal editionsAddr = makeAddr("editions");

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
        directory = new DirectoryStub();
        factory = new SplitFactoryWalletsMock();
        packageRegistry = address(new PackageRegistryStub());
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        outcomes = new DisputeOutcomeLogMock(predicted);
        registry = _deploy(address(outcomes));
        assertEq(address(registry), predicted, "predicted accounts address");
        directory.setModule(ACCOUNTS_SLOT, address(registry));
        _configureRoles(address(registry));

        _consolidate(artist, wallet);
        artistId = _register(artist);
    }

    /// @dev An accounts module with this fixture's wiring and the given statement log.
    function _deploy(address statementLog) internal returns (Accounts) {
        return new Accounts(
            address(manager),
            adapter,
            address(adapter).codehash,
            Accounts.Wiring(
                address(directory),
                streamAddr,
                editionsAddr,
                address(factory),
                statementLog,
                packageRegistry,
                address(0)
            ),
            new address[](0)
        );
    }

    function _configureRoles(address target) internal {
        bytes4[] memory s = new bytes4[](8);
        s[0] = Accounts.stageReplacement.selector;
        s[1] = Accounts.cancelReplacement.selector;
        s[2] = Accounts.resolveContested.selector;
        s[3] = Accounts.freeze.selector;
        s[4] = Accounts.unfreeze.selector;
        s[5] = Accounts.setConsolidationSource.selector;
        s[6] = Accounts.setPackageRegistry.selector;
        s[7] = Accounts.cancelOwnChange.selector;
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
            Accounts.stageChange, (artistId, next, deadline, _proof(signerKey, digest))
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
            Accounts.stageReplacement, (artistId, next, EVIDENCE, deadline, acceptance)
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
