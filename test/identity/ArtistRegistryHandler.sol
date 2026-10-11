// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { ConsolidationAdapter } from "src/identity/ConsolidationAdapter.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, ChangeKind, PendingChange } from "src/interfaces/types/IdentityTypes.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";

/// @notice The accounts the handler drives. `keys` are the artist key, an established
///         consolidated wallet, a fresh key and a thief; `payouts` are payout candidates.
struct IdentityActors {
    ArtistRegistry registry;
    ConsolidationAdapter adapter;
    DelegationManagementMock delegation;
    uint256 artistId;
    address guardian;
    address governor;
    uint256[4] keys;
    address[3] payouts;
}

/// @notice Drives one artist identity through every path and asserts each outcome: before every
///         call it predicts, from the registry's current state, whether the call succeeds or which
///         error it reverts with, then makes the call and checks it. Covered: signed STANDARD
///         changes by the authority, a consolidated wallet and a thief; two-sided overrides;
///         cancels by every kind of caller; guardian vetoes and redirect attempts; replays of used
///         payloads and acceptances; heartbeats; nonce burns; standing refreshes; consolidation
///         revocations and renewals; and time. Ghosts of the identity, nonce and last activity
///         change only with the calls that may change them.
contract ArtistRegistryHandler is Test {
    bytes32 internal constant PROFILE = keccak256("profile/punk6529");

    ArtistRegistry internal immutable registry;
    ConsolidationAdapter internal immutable adapter;
    DelegationManagementMock internal immutable delegation;
    uint256 internal immutable artistId;
    address internal immutable guardian;
    address internal immutable governor;
    uint256[4] internal keys;
    address[3] internal payouts;

    address public ghostPayout;
    address public ghostAuthority;
    uint64 public ghostLastActivity;
    uint256 public ghostNonce;
    bytes32 public ghostCancellers;
    uint256 public executed;
    bool internal walletConsolidated = true;

    struct Used {
        ArtistIdentity next;
        address signer;
        uint64 deadline;
        bytes signature;
        bytes acceptance;
    }

    struct Accepted {
        ChangeKind kind;
        ArtistIdentity next;
        bytes32 evidence;
        bytes32 digest;
        uint64 deadline;
        bytes acceptance;
    }

    Used internal lastUsed;
    Accepted internal lastAcceptance;
    /// @dev Override acceptance digests the registry has consumed.
    mapping(bytes32 => bool) public usedDigest;

    constructor(IdentityActors memory a) {
        registry = a.registry;
        adapter = a.adapter;
        delegation = a.delegation;
        artistId = a.artistId;
        guardian = a.guardian;
        governor = a.governor;
        keys = a.keys;
        payouts = a.payouts;
        (ArtistIdentity memory identity, uint64 last) = registry.artist(artistId);
        ghostPayout = identity.payout;
        ghostAuthority = identity.authority;
        ghostLastActivity = last;
    }

    // ----------------------------------------------------------------- actions

    function stageStandard(uint256 signerSeed, uint256 authoritySeed, uint256 payoutSeed) external {
        uint256 signerKey = keys[signerSeed % 4];
        uint256 nextKey = keys[authoritySeed % 4];
        ArtistIdentity memory next =
            ArtistIdentity(vm.addr(nextKey), payouts[payoutSeed % 3], PROFILE, bytes32(payoutSeed));
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 digest = registry.changeDigest(artistId, next, ghostNonce, deadline);
        Used memory u = Used(next, vm.addr(signerKey), deadline, _sign(signerKey, digest), "");
        u.acceptance = _sign(nextKey, digest);
        bytes memory err = _stageError(u.signer);
        if (err.length != 0) vm.expectRevert(err);
        registry.stageChange(artistId, next, u.signer, deadline, u.signature, u.acceptance);
        if (err.length != 0) return;
        lastUsed = u;
        ghostLastActivity = uint64(block.timestamp);
        _onStaged(ChangeKind.STANDARD);
    }

    /// @dev A used payload never stages again: the nonce it signed is consumed.
    function replayLast() external {
        Used memory u = lastUsed;
        if (u.signer == address(0)) return;
        bytes memory err = _stageError(u.signer);
        vm.expectRevert(err.length != 0 ? err : _sel(IArtistRegistry.InvalidSignature.selector));
        registry.stageChange(artistId, u.next, u.signer, u.deadline, u.signature, u.acceptance);
    }

    function stageOverride(uint256 kindSeed, uint256 authoritySeed, uint256 payoutSeed) external {
        Accepted memory u;
        u.kind = ChangeKind(2 + kindSeed % 3);
        uint256 nextKey = keys[authoritySeed % 4];
        u.next = ArtistIdentity(vm.addr(nextKey), payouts[payoutSeed % 3], PROFILE, bytes32(0));
        u.evidence = keccak256(abi.encode(kindSeed));
        u.deadline = uint64(block.timestamp + 3 days);
        u.digest = registry.overrideDigest(artistId, u.kind, u.next, u.evidence, u.deadline);
        u.acceptance = _sign(nextKey, u.digest);
        if (_tryOverride(u)) lastAcceptance = u;
    }

    /// @dev A used acceptance never stages again (its digest is consumed), unless the override no
    ///      longer changes the authority and so needs none.
    function replayAcceptance() external {
        Accepted memory u = lastAcceptance;
        if (u.next.authority != address(0)) _tryOverride(u);
    }

    function cancel(uint256 callerSeed) external {
        address caller = _caller(callerSeed);
        PendingChange memory p = registry.pendingChange(artistId);
        bool allowed = p.kind == ChangeKind.STANDARD && caller == p.previousAuthority;
        for (uint256 i; i < p.cancellers.length; ++i) {
            allowed = allowed || p.cancellers[i] == caller;
        }
        if (p.kind == ChangeKind.NONE) _expect(_noPending());
        else if (!allowed) _expect(_notAuthorized(caller));
        vm.prank(caller);
        registry.cancelChange(artistId);
        if (p.kind != ChangeKind.NONE && allowed) ghostLastActivity = uint64(block.timestamp);
    }

    function veto() external {
        if (registry.pendingChange(artistId).kind == ChangeKind.NONE) _expect(_noPending());
        vm.prank(guardian);
        registry.vetoChange(artistId);
    }

    /// @dev The guardian is veto-only: every write path refuses it.
    function guardianRedirect(uint256 payoutSeed) external {
        ArtistIdentity memory next =
            ArtistIdentity(guardian, payouts[payoutSeed % 3], PROFILE, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian)
        );
        vm.prank(guardian);
        registry.stageOverride(artistId, ChangeKind.CONTESTED, next, keccak256("e"), 0, "");
        _expect(_stageError(guardian));
        registry.stageChange(artistId, next, guardian, type(uint64).max, "", "");
    }

    function execute() external {
        PendingChange memory p = registry.pendingChange(artistId);
        if (p.kind == ChangeKind.NONE) {
            _expect(_noPending());
        } else if (block.timestamp < p.executableAt) {
            _expect(
                abi.encodeWithSelector(
                    IArtistRegistry.ChangeNotDue.selector, artistId, p.executableAt
                )
            );
        }
        registry.executeChange(artistId);
        if (p.kind == ChangeKind.NONE || block.timestamp < p.executableAt) return;
        uint64 delay = p.kind == ChangeKind.STANDARD ? 7 days : 180 days;
        assertEq(p.executableAt, p.stagedAt + delay);
        assertGe(block.timestamp, p.stagedAt + delay);
        ghostPayout = p.next.payout;
        ghostAuthority = p.next.authority;
        ghostLastActivity = uint64(block.timestamp);
        ++executed;
    }

    function heartbeat(uint256 callerSeed) external {
        address caller = _caller(callerSeed);
        bool ok = caller == ghostAuthority || adapter.isEstablished(ghostAuthority, caller);
        if (!ok) _expect(_notAuthorized(caller));
        vm.prank(caller);
        registry.heartbeat(artistId);
        if (ok) ghostLastActivity = uint64(block.timestamp);
    }

    function revokeNonce(uint256 callerSeed) external {
        address caller = _caller(callerSeed);
        if (caller != ghostAuthority) _expect(_notAuthorized(caller));
        vm.prank(caller);
        registry.revokeNonce(artistId);
        if (caller != ghostAuthority) return;
        ++ghostNonce;
        ghostLastActivity = uint64(block.timestamp);
    }

    function refreshStanding() external {
        registry.refreshStanding(artistId);
    }

    /// @dev Revokes or renews the consolidation of the original artist key and its wallet, as a
    ///      thief holding the artist key (or the artist) could.
    function toggleWalletConsolidation() external {
        address artist = vm.addr(keys[0]);
        address wallet = vm.addr(keys[1]);
        address all = delegation.ALL_COLLECTIONS();
        if (walletConsolidated) {
            vm.prank(artist);
            delegation.revokeDelegationAddress(all, wallet, 999);
        } else {
            vm.prank(artist);
            delegation.registerDelegationAddress(all, wallet, type(uint64).max, 999, true, 0);
            vm.prank(wallet);
            delegation.registerDelegationAddress(all, artist, type(uint64).max, 999, true, 0);
        }
        walletConsolidated = !walletConsolidated;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 hours, 200 days));
    }

    // ----------------------------------------------------------------- model

    /// @dev Predicts and checks one override staging; returns whether it succeeded.
    function _tryOverride(Accepted memory u) private returns (bool ok) {
        bytes memory err = _overrideError(u);
        bool consumes = u.next.authority != ghostAuthority;
        if (err.length != 0) vm.expectRevert(err);
        vm.prank(governor);
        registry.stageOverride(artistId, u.kind, u.next, u.evidence, u.deadline, u.acceptance);
        ok = err.length == 0;
        if (!ok) return ok;
        if (consumes) usedDigest[u.digest] = true;
        _onStaged(u.kind);
    }

    /// @dev The registry's check order for `stageChange` up to the signature.
    function _stageError(address signer) private view returns (bytes memory) {
        if (registry.pendingChange(artistId).kind != ChangeKind.NONE) {
            return abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId);
        }
        if (signer != ghostAuthority && !adapter.isEstablished(ghostAuthority, signer)) {
            return _notAuthorized(signer);
        }
        return "";
    }

    /// @dev The registry's check order for `stageOverride` (identities here are always valid).
    function _overrideError(Accepted memory u) private view returns (bytes memory) {
        if (u.kind != ChangeKind.CONTESTED && block.timestamp < ghostLastActivity + 365 days) {
            return abi.encodeWithSelector(
                IArtistRegistry.NotDormant.selector, artistId, ghostLastActivity
            );
        }
        if (
            u.next.authority != ghostAuthority
                && (block.timestamp > u.deadline || usedDigest[u.digest])
        ) return _sel(IArtistRegistry.InvalidSignature.selector);
        if (registry.pendingChange(artistId).kind > ChangeKind.STANDARD) {
            return abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId);
        }
        return "";
    }

    function _onStaged(ChangeKind kind) private {
        PendingChange memory p = registry.pendingChange(artistId);
        assertEq(uint8(p.kind), uint8(kind));
        ghostCancellers = keccak256(abi.encode(p.cancellers));
        ++ghostNonce;
    }

    function _expect(bytes memory err) private {
        vm.expectRevert(err);
    }

    function _noPending() private view returns (bytes memory) {
        return abi.encodeWithSelector(IArtistRegistry.NoPendingChange.selector, artistId);
    }

    function _notAuthorized(address account) private view returns (bytes memory) {
        return abi.encodeWithSelector(IArtistRegistry.NotAuthorized.selector, artistId, account);
    }

    function _sel(bytes4 selector) private pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }

    function _caller(uint256 seed) private view returns (address) {
        uint256 i = seed % 5;
        return i == 4 ? guardian : vm.addr(keys[i]);
    }

    function _sign(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
