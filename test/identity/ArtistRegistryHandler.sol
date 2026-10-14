// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { ConsolidationAdapter } from "src/identity/ConsolidationAdapter.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import {
    ArtistIdentity,
    ChangeKind,
    PendingChange,
    Standing
} from "src/interfaces/types/IdentityTypes.sol";
import { DelegationManagementMock } from "../mocks/identity/DelegationManagementMock.sol";
import {
    DisputeOutcomeLogMock,
    SplitFactoryWalletsMock
} from "../mocks/identity/IdentityWorksMocks.sol";

/// @notice The accounts the handler drives. `keys` are the artist key, an established
///         consolidated wallet, a fresh key and a thief; `payouts` are payout candidates.
struct IdentityActors {
    ArtistRegistry registry;
    ConsolidationAdapter adapter;
    DelegationManagementMock delegation;
    SplitFactoryWalletsMock factory;
    DisputeOutcomeLogMock outcomes;
    uint256 artistId;
    address guardian;
    address governor;
    address successorSetter;
    uint256[4] keys;
    address[3] payouts;
}

/// @notice Drives one artist identity through every path and asserts each outcome: before every
///         call it predicts, from the registry's current state, whether the call succeeds or which
///         error it reverts with, then makes the call and checks it. Covered: signed STANDARD
///         changes by the authority, a consolidated wallet and a thief; two-sided overrides;
///         cancels by every kind of caller; guardian vetoes and redirect attempts; replays of used
///         payloads and acceptances; heartbeats; nonce burns; standing refreshes, checked against
///         a standing model; consolidations made and revoked between any two keys; payouts that
///         become split wallets, so stale changes are cleared at execution; contested
///         overrides resolved by recorded votes or lapsing after a year; and time. Ghosts of
///         the identity, nonce and last activity change only with the calls that may change them.
contract ArtistRegistryHandler is Test {
    bytes32 internal constant PROFILE = keccak256("profile/punk6529");

    ArtistRegistry internal immutable registry;
    ConsolidationAdapter internal immutable adapter;
    DelegationManagementMock internal immutable delegation;
    SplitFactoryWalletsMock internal immutable factory;
    DisputeOutcomeLogMock internal immutable outcomes;
    address internal immutable successorSetter;
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
    uint256 public cleared;
    uint256 public contested;
    uint256 public resolved;
    uint256 public lapsed;
    mapping(bytes32 pair => bool) internal consolidated;

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
        factory = a.factory;
        outcomes = a.outcomes;
        successorSetter = a.successorSetter;
        artistId = a.artistId;
        guardian = a.guardian;
        governor = a.governor;
        keys = a.keys;
        payouts = a.payouts;
        (ArtistIdentity memory identity, uint64 last) = registry.artist(artistId);
        ghostPayout = identity.payout;
        ghostAuthority = identity.authority;
        ghostLastActivity = last;
        consolidated[_pair(vm.addr(keys[0]), vm.addr(keys[1]))] = true;
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
        bytes memory err = _stageError(u.signer, next.payout);
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
        bytes memory err = _stageError(u.signer, u.next.payout);
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
        bool overrideOpen = allowed && p.kind > ChangeKind.STANDARD && p.contestedAt == 0;
        bool late = overrideOpen && block.timestamp >= p.executableAt;
        if (p.kind == ChangeKind.NONE) {
            _expect(_noPending());
        } else if (!allowed) {
            _expect(_notAuthorized(caller));
        } else if (late) {
            _expect(
                abi.encodeWithSelector(
                    IArtistRegistry.ContestWindowClosed.selector, artistId, p.executableAt
                )
            );
        }
        bool contests = overrideOpen && !late;
        if (contests) {
            vm.expectEmit(address(registry));
            emit IArtistRegistry.ChangeContested(artistId, caller);
        }
        vm.prank(caller);
        registry.cancelChange(artistId);
        if (p.kind == ChangeKind.NONE || !allowed || late) return;
        PendingChange memory q = registry.pendingChange(artistId);
        if (p.contestedAt != 0) {
            // A cancel of a contested override does nothing.
            assertEq(keccak256(abi.encode(q)), keccak256(abi.encode(p)));
            return;
        }
        ghostLastActivity = uint64(block.timestamp);
        if (!contests) return;
        assertEq(q.contestedAt, block.timestamp);
        assertEq(q.priorOutcome, outcomes.latestDisputeOutcome(address(registry), artistId));
        ++contested;
    }

    /// @dev Records (or clears) the vote outcome the statement log reports for the artist.
    function recordOutcome(uint256 seed) external {
        outcomes.setOutcome(address(registry), artistId, seed % 4 == 0 ? bytes32(0) : _ref(seed));
    }

    /// @dev Applies a vote to a contested override, citing the recorded outcome or a wrong one.
    function resolve(bool uphold, uint256 seed) external {
        PendingChange memory p = registry.pendingChange(artistId);
        bytes32 recorded = outcomes.latestDisputeOutcome(address(registry), artistId);
        bytes32 ref = seed % 3 == 0 ? _ref(seed) : recorded;
        bool live = p.contestedAt != 0 && block.timestamp < uint256(p.contestedAt) + 365 days;
        bool ok;
        if (!live) {
            _expect(abi.encodeWithSelector(IArtistRegistry.NotContested.selector, artistId));
        } else if (ref == bytes32(0) || ref != recorded) {
            _expect(
                abi.encodeWithSelector(IArtistRegistry.OutcomeNotRecorded.selector, artistId, ref)
            );
        } else if (ref == p.priorOutcome) {
            _expect(
                abi.encodeWithSelector(
                    IArtistRegistry.OutcomePredatesContest.selector, artistId, ref
                )
            );
        } else if (uphold && block.timestamp < p.executableAt) {
            _expect(
                abi.encodeWithSelector(
                    IArtistRegistry.ChangeNotDue.selector, artistId, p.executableAt
                )
            );
        } else {
            ok = true;
        }
        vm.prank(successorSetter);
        registry.resolveContested(artistId, uphold, ref);
        if (!ok) return;
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        ++resolved;
        if (!uphold || factory.isWallet(p.next.payout)) return;
        ghostPayout = p.next.payout;
        ghostAuthority = p.next.authority;
        ghostLastActivity = uint64(block.timestamp);
        ++executed;
    }

    /// @dev Lets anyone lapse a contest nobody resolved within a year.
    function expire() external {
        PendingChange memory p = registry.pendingChange(artistId);
        uint256 expiresAt = uint256(p.contestedAt) + 365 days;
        if (p.contestedAt == 0) {
            _expect(abi.encodeWithSelector(IArtistRegistry.NotContested.selector, artistId));
        } else if (block.timestamp < expiresAt) {
            _expect(
                abi.encodeWithSelector(
                    IArtistRegistry.ContestNotExpired.selector, artistId, uint64(expiresAt)
                )
            );
        }
        registry.expireContest(artistId);
        if (p.contestedAt == 0 || block.timestamp < expiresAt) return;
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        ++lapsed;
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
        _expect(_stageError(guardian, next.payout));
        registry.stageChange(artistId, next, guardian, type(uint64).max, "", "");
    }

    function execute() external {
        PendingChange memory p = registry.pendingChange(artistId);
        if (p.kind == ChangeKind.NONE) {
            _expect(_noPending());
        } else if (p.contestedAt != 0) {
            _expect(abi.encodeWithSelector(IArtistRegistry.OverrideContested.selector, artistId));
            registry.executeChange(artistId);
            return;
        } else if (block.timestamp < p.executableAt) {
            _expect(
                abi.encodeWithSelector(
                    IArtistRegistry.ChangeNotDue.selector, artistId, p.executableAt
                )
            );
        }
        bool due = p.kind != ChangeKind.NONE && block.timestamp >= p.executableAt;
        bool stale = due && factory.isWallet(p.next.payout);
        if (stale) {
            vm.expectEmit(address(registry));
            emit IArtistRegistry.ChangeCancelled(artistId, address(registry), false);
        }
        registry.executeChange(artistId);
        if (!due) return;
        assertEq(uint8(registry.pendingChange(artistId).kind), uint8(ChangeKind.NONE));
        if (stale) {
            ++cleared;
            return;
        }
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

    /// @dev Checks a refresh against the standing model: removals only after the grace, or at
    ///      once for a pending entry no longer consolidated (IDENTITY-3), every entry's missing
    ///      flag matches the live consolidation and only an established entry goes missing, new
    ///      entries are live with the source's `effectiveAt`, and every consolidated key is
    ///      recorded unless the snapshot is full.
    function refreshStanding() external {
        Standing[] memory before = registry.standingOf(artistId);
        registry.refreshStanding(artistId);
        Standing[] memory next = registry.standingOf(artistId);
        assertLe(next.length, 16);
        for (uint256 i; i < before.length; ++i) {
            if (_find(next, before[i].wallet) != type(uint256).max) continue;
            assertEq(adapter.effectiveAt(ghostAuthority, before[i].wallet), 0, "removed live");
            if (before[i].effectiveAt > block.timestamp) continue; // pending: it never had standing
            assertTrue(before[i].missingSince != 0, "removed while not missing");
            assertGe(block.timestamp, uint256(before[i].missingSince) + 30 days, "removed early");
        }
        for (uint256 i; i < next.length; ++i) {
            uint64 due = adapter.effectiveAt(ghostAuthority, next[i].wallet);
            assertEq(next[i].missingSince == 0, due != 0, "missing flag");
            if (next[i].missingSince != 0) {
                assertLe(
                    next[i].effectiveAt, block.timestamp, "only established entries go missing"
                );
            }
            if (_find(before, next[i].wallet) == type(uint256).max) {
                assertEq(next[i].effectiveAt, due, "recorded effectiveAt");
            }
        }
        if (next.length == 16) return;
        for (uint256 k; k < 4; ++k) {
            address w = vm.addr(keys[k]);
            if (adapter.effectiveAt(ghostAuthority, w) != 0) {
                assertTrue(_find(next, w) != type(uint256).max, "consolidated but not recorded");
            }
        }
    }

    /// @dev Makes or revokes a two-way consolidation between two keys, as their holders (or a key
    ///      thief) could.
    function toggleConsolidation(uint256 seedA, uint256 seedB) external {
        address x = vm.addr(keys[seedA % 4]);
        address y = vm.addr(keys[seedB % 4]);
        if (x == y) return;
        bytes32 pair = _pair(x, y);
        address all = delegation.ALL_COLLECTIONS();
        if (consolidated[pair]) {
            vm.prank(x);
            delegation.revokeDelegationAddress(all, y, 999);
        } else {
            vm.prank(x);
            delegation.registerDelegationAddress(all, y, type(uint64).max, 999, true, 0);
            vm.prank(y);
            delegation.registerDelegationAddress(all, x, type(uint64).max, 999, true, 0);
        }
        consolidated[pair] = !consolidated[pair];
    }

    /// @dev Flags or unflags a payout candidate as a deployed split wallet.
    function flagSplitWallet(uint256 seed) external {
        address w = payouts[1 + seed % 2];
        factory.setWallet(w, !factory.isWallet(w));
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
    function _stageError(address signer, address payout) private view returns (bytes memory) {
        if (registry.pendingChange(artistId).kind != ChangeKind.NONE) {
            return abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId);
        }
        if (signer != ghostAuthority && !adapter.isEstablished(ghostAuthority, signer)) {
            return _notAuthorized(signer);
        }
        if (factory.isWallet(payout)) return _sel(IArtistRegistry.InvalidIdentity.selector);
        return "";
    }

    /// @dev The registry's check order for `stageOverride`.
    function _overrideError(Accepted memory u) private view returns (bytes memory) {
        if (factory.isWallet(u.next.payout)) return _sel(IArtistRegistry.InvalidIdentity.selector);
        if (u.kind != ChangeKind.CONTESTED && block.timestamp < ghostLastActivity + 365 days) {
            return abi.encodeWithSelector(
                IArtistRegistry.NotDormant.selector, artistId, ghostLastActivity
            );
        }
        if (u.next.authority != ghostAuthority) {
            if (usedDigest[u.digest]) {
                return abi.encodeWithSelector(IArtistRegistry.AcceptanceUsed.selector, u.digest);
            }
            if (block.timestamp > u.deadline) {
                return _sel(IArtistRegistry.InvalidSignature.selector);
            }
        }
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

    function _find(Standing[] memory list, address w) private pure returns (uint256) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i].wallet == w) return i;
        }
        return type(uint256).max;
    }

    function _ref(uint256 seed) private pure returns (bytes32) {
        return keccak256(abi.encode("outcome", seed));
    }

    function _pair(address x, address y) private pure returns (bytes32) {
        return x < y ? keccak256(abi.encode(x, y)) : keccak256(abi.encode(y, x));
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
