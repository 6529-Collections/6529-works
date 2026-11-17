// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { ArtistIdentity } from "src/interfaces/types/IdentityTypes.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import { IdentityFixture } from "./IdentityFixture.sol";

/// @notice Drives one account through consolidations made and revoked in either direction, root
///         moves, freezes and time, keeping a model of who belongs to it.
contract AccountsHandler is Test {
    uint256 internal constant POOL = 5;
    address internal constant ALL = 0x8888888888888888888888888888888888888888;

    ArtistRegistry internal immutable registry;
    DelegationManagementMock internal immutable delegation;
    address internal immutable network;
    uint256 public immutable artistId;

    uint256[POOL] public keys;
    /// @dev `direction[i][j]`: key i holds a live consolidation registration of key j.
    bool[POOL][POOL] internal direction;
    uint256 public rootIndex;
    uint256 public frozenUntil;
    uint256 public moves;

    constructor(
        ArtistRegistry registry_,
        DelegationManagementMock delegation_,
        address network_,
        uint256 artistId_,
        uint256[POOL] memory keys_
    ) {
        (registry, delegation, network, artistId, keys) =
        (registry_, delegation_, network_, artistId_, keys_);
    }

    function consolidate(uint256 i, uint256 j) external {
        (i, j) = (i % POOL, j % POOL);
        if (i == j || direction[i][j]) return;
        vm.prank(vm.addr(keys[i]));
        delegation.registerDelegationAddress(ALL, vm.addr(keys[j]), type(uint64).max, 999, true, 0);
        direction[i][j] = true;
    }

    function revoke(uint256 i, uint256 j) external {
        (i, j) = (i % POOL, j % POOL);
        if (!direction[i][j]) return;
        vm.prank(vm.addr(keys[i]));
        delegation.revokeDelegationAddress(ALL, vm.addr(keys[j]), 999);
        direction[i][j] = false;
    }

    function freeze() external {
        if (frozenUntil > block.timestamp) return;
        vm.prank(network);
        registry.freeze(artistId);
        frozenUntil = block.timestamp + 14 days;
    }

    function unfreeze() external {
        vm.prank(network);
        registry.unfreeze(artistId);
        frozenUntil = 0;
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + by % 20 days);
    }

    /// @dev The account moves its root to one of its wallets, signed by any wallet of it.
    function moveRoot(uint256 to, uint256 signer) external {
        (to, signer) = (to % POOL, signer % POOL);
        if (!isWalletInModel(to) || !isWalletInModel(signer) || to == rootIndex) return;
        address next = vm.addr(keys[to]);
        if (registry.artistIdOf(next) != 0 && registry.artistIdOf(next) != artistId) return;
        ArtistIdentity memory id = ArtistIdentity(next, next, bytes32(0), bytes32(0));
        uint64 deadline = uint64(block.timestamp);
        bytes32 digest =
            registry.changeDigest(artistId, id, registry.changeNonce(artistId), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[signer], digest);
        registry.stageChange(
            artistId, id, deadline, abi.encodePacked(vm.addr(keys[signer]), r, s, v)
        );
        // Not frozen at staging (both keys are wallets in the model), so not frozen 2 days on.
        vm.warp(block.timestamp + 2 days);
        bool stillWallet = direction[rootIndex][to] && direction[to][rootIndex];
        registry.executeChange(artistId);
        if (stillWallet) {
            rootIndex = to;
            ++moves;
        }
    }

    /// @notice Whether key `i` acts for the account in the model.
    function isWalletInModel(uint256 i) public view returns (bool) {
        if (frozenUntil > block.timestamp) return false;
        return i == rootIndex || (direction[rootIndex][i] && direction[i][rootIndex]);
    }
}

/// @notice Invariant: `requireSigned` passes exactly for the wallets that belong to the account
///         now (its root, or a wallet in a live two-way consolidation with the root), and never
///         for a wallet outside it or while it is frozen.
contract AccountsInvariantTest is IdentityFixture {
    AccountsHandler internal handler;
    uint256[5] internal pool = [uint256(0xA1), 0xB2, 0xB3, 0xB4, 0xB5];

    function setUp() public override {
        super.setUp();
        // The fixture consolidated the root (0xA1) with 0xB2; start the model from a clean pair.
        _revoke(artist, wallet);
        _revoke(wallet, artist);
        handler = new AccountsHandler(registry, delegation, network, artistId, pool);
        vm.prank(admin);
        manager.grantRole(NETWORK, address(handler), 0);
        targetContract(address(handler));
    }

    function invariant_RequireSignedPassesExactlyForTheAccountsWallets() public view {
        bytes32 digest = keccak256(abi.encode("probe", block.timestamp));
        for (uint256 i; i < pool.length; ++i) {
            bool passes = _passes(pool[i], digest);
            assertEq(passes, handler.isWalletInModel(i), vm.toString(i));
        }
        assertFalse(_passes(outsiderKey, digest), "an outsider never passes");
    }

    /// @notice `PackageRegistry._useMove` takes a fast path when the proof's wallet is
    ///         `activeAuthorityOf` (it then checks the signature against it), and otherwise calls
    ///         `requireSigned` with the same proof. The two agree when every wallet the fast path
    ///         accepts also passes `requireSigned`, as the same wallet: the active authority is
    ///         always a wallet of the account, and zero whenever no wallet may act.
    function invariant_TheMoveFastPathAgreesWithRequireSigned() public view {
        bytes32 digest = keccak256(abi.encode("move", block.timestamp));
        address active = registry.activeAuthorityOf(artistId);
        for (uint256 i; i < pool.length; ++i) {
            if (vm.addr(pool[i]) != active) continue;
            assertTrue(_passes(pool[i], digest), "the fast path's wallet passes requireSigned");
        }
        if (active != address(0)) assertTrue(registry.isWallet(artistId, active));
        if (registry.frozenUntil(artistId) > block.timestamp) assertEq(active, address(0));
    }

    function _passes(uint256 key, bytes32 digest) internal view returns (bool) {
        try registry.requireSigned(artistId, digest, _proof(key, digest)) returns (address w) {
            return w == vm.addr(key);
        } catch {
            return false;
        }
    }
}
