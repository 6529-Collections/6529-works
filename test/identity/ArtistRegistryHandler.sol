// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { ConsolidationAdapter } from "src/identity/ConsolidationAdapter.sol";
import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
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
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { SignatureReverts } from "test/helpers/SignatureReverts.sol";

/// @notice The federation registry the handler acts as, and the addresses it tries to list:
///         `canonical[i]` marks the ones the artist registry must refuse as an entry or partner,
///         `installable[i]` the ones with code that is not an EIP-7702 delegation.
struct FederationActors {
    address federation;
    address[8] tokens;
    bool[8] canonical;
    bool[8] installable;
}

/// @notice The accounts the handler drives. `keys` are the artist key, an established
///         consolidated wallet, a fresh key and a thief; `payouts` are payout candidates.
struct IdentityActors {
    ArtistRegistry registry;
    ConsolidationAdapter adapter;
    DelegationManagementMock delegation;
    SplitFactoryWalletsMock factory;
    DisputeOutcomeLogMock outcomes;
    /// @dev A replacement source that names every wallet (review C, F2), swapped in and out.
    IConsolidationSource hostile;
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
///         overrides resolved by recorded votes or lapsing; governed timer changes; and time.
///         Ghosts of the identity, nonce and last activity change only with the calls that may
///         change them. It also acts as the bound federation registry (listings, status writes,
///         identity creations with good and forged consents) and as listed tokens (exits),
///         asserting that none of these touches the artist's identity, payout, standing or
///         pending change.
contract ArtistRegistryHandler is Test {
    bytes32 internal constant PROFILE = keccak256("profile/punk6529");

    ArtistRegistry internal immutable registry;
    ConsolidationAdapter internal immutable adapter;
    DelegationManagementMock internal immutable delegation;
    SplitFactoryWalletsMock internal immutable factory;
    DisputeOutcomeLogMock internal immutable outcomes;
    IConsolidationSource internal immutable hostile;
    address internal immutable successorSetter;
    uint256 internal immutable artistId;
    address internal immutable guardian;
    address internal immutable governor;
    uint256[4] internal keys;
    address[3] internal payouts;

    address public ghostPayout;
    address public ghostAuthority;
    /// @dev Every key that has been the artist's authority (SIGS-3: never again a new one).
    mapping(address account => bool) public ghostWasAuthority;
    uint64 public ghostLastActivity;
    uint256 public ghostNonce;
    bytes32 public ghostCancellers;
    uint256 public executed;
    uint256 public cleared;
    uint256 public contested;
    uint256 public resolved;
    uint256 public lapsed;
    mapping(bytes32 pair => bool) internal consolidated;
    /// @dev Whether the hostile source is installed, whether the pending change was signed by a
    ///      consolidated wallet, and the count of such stagings made while the artist was live
    ///      (the F2 invariant: always zero) or made at all (coverage).
    bool public hostileInstalled;
    bool public ghostWalletStaged;
    uint256 public walletStagedWhileLive;
    /// @dev Calls by a wallet other than the authority (stagings it signed, cancels, contests,
    ///      heartbeats, nonce revocations), and executions of changes such a wallet signed that
    ///      keep the authority, that moved the artist's last activity (review E, N-1: always
    ///      zero).
    uint256 public walletMovedActivity;
    uint256 public walletStagings;
    uint256 public sourceSwaps;

    /// @dev The governed timers, in `IArtistRegistry.Timer` order, and the delay and contest
    ///      timeout locked by the pending change.
    uint48[5] internal ghostTimers;
    uint48 public ghostStagedDelay;
    uint48 public ghostStagedTimeout;
    uint256 public timerChanges;

    address internal federation;
    address[8] internal fedTokens;
    bool[8] internal fedCanonical;
    bool[8] internal fedInstallable;
    mapping(address token => IArtistRegistry.FederationStatus) public ghostStatus;
    mapping(address token => bool) public everLeft;
    uint256 public listed;
    uint256 public statusWrites;
    uint256 public exits;
    uint256 public fedRegistrations;

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

    constructor(IdentityActors memory a, FederationActors memory f) {
        federation = f.federation;
        fedTokens = f.tokens;
        fedCanonical = f.canonical;
        fedInstallable = f.installable;
        for (uint256 i; i < 5; ++i) {
            ghostTimers[i] = a.registry.timer(IArtistRegistry.Timer(i));
        }
        registry = a.registry;
        adapter = a.adapter;
        delegation = a.delegation;
        factory = a.factory;
        outcomes = a.outcomes;
        hostile = a.hostile;
        successorSetter = a.successorSetter;
        artistId = a.artistId;
        guardian = a.guardian;
        governor = a.governor;
        keys = a.keys;
        payouts = a.payouts;
        (ArtistIdentity memory identity, uint64 last) = registry.artist(artistId);
        ghostPayout = identity.payout;
        ghostAuthority = identity.authority;
        ghostWasAuthority[identity.authority] = true;
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
        bytes memory err = _stageError(u.signer, next);
        uint64 before = _lastActivity();
        if (err.length != 0) vm.expectRevert(err);
        registry.stageChange(artistId, next, u.signer, deadline, u.signature, u.acceptance);
        if (err.length != 0) return;
        lastUsed = u;
        bool byWallet = u.signer != ghostAuthority;
        if (byWallet) {
            ++walletStagings;
            if (!_dormant()) ++walletStagedWhileLive;
            if (_lastActivity() != before) ++walletMovedActivity;
        } else {
            ghostLastActivity = uint64(block.timestamp);
        }
        _onStaged(ChangeKind.STANDARD, byWallet);
    }

    /// @dev A used payload never stages again: the nonce it signed is consumed.
    function replayLast() external {
        Used memory u = lastUsed;
        if (u.signer == address(0)) return;
        bytes memory err = _stageError(u.signer, u.next);
        if (err.length == 0) {
            // The nonce moved on, so the replayed signature no longer verifies, unless the
            // deadline passed first.
            err = block.timestamp > u.deadline
                ? SignatureReverts.expired(u.deadline)
                : SignatureReverts.invalid(u.signer);
        }
        vm.expectRevert(err);
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
        uint64 before = _lastActivity();
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
        if (caller != ghostAuthority && _lastActivity() != before) ++walletMovedActivity;
        if (p.kind == ChangeKind.NONE || !allowed || late) return;
        PendingChange memory q = registry.pendingChange(artistId);
        if (p.contestedAt != 0) {
            // A cancel of a contested override does nothing.
            assertEq(keccak256(abi.encode(q)), keccak256(abi.encode(p)));
            return;
        }
        // Only the artist's own key proves activity (review E, N-1).
        if (caller == p.previousAuthority) ghostLastActivity = uint64(block.timestamp);
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
        bool live =
            p.contestedAt != 0 && block.timestamp < uint256(p.contestedAt) + ghostStagedTimeout;
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
        _onExecuted(p);
    }

    /// @dev Lets anyone lapse a contest nobody resolved within its locked timeout.
    function expire() external {
        PendingChange memory p = registry.pendingChange(artistId);
        uint256 expiresAt = uint256(p.contestedAt) + ghostStagedTimeout;
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
        bytes memory err = _stageError(guardian, next);
        // Under the hostile source a dormant artist's guardian passes the signer check, and
        // its empty signature is then refused.
        _expect(err.length != 0 ? err : SignatureReverts.invalid(guardian));
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
        // Never faster than the delay locked at staging, whatever the timers are now.
        assertEq(p.executableAt, p.stagedAt + ghostStagedDelay);
        assertGe(block.timestamp, p.stagedAt + ghostStagedDelay);
        _onExecuted(p);
    }

    /// @dev An executed change: only a new authority's acceptance restarts the dormancy clock
    ///      (review E, N-1), so a wallet-signed change that keeps the authority never does.
    function _onExecuted(PendingChange memory p) private {
        bool moves = p.next.authority != p.previousAuthority;
        if (!moves && ghostWalletStaged && _lastActivity() != ghostLastActivity) {
            ++walletMovedActivity;
        }
        ghostPayout = p.next.payout;
        ghostAuthority = p.next.authority;
        ghostWasAuthority[p.next.authority] = true;
        if (moves) ghostLastActivity = uint64(block.timestamp);
        ++executed;
    }

    /// @dev The authority's alone (review C, F2): no consolidated wallet heartbeats.
    function heartbeat(uint256 callerSeed) external {
        address caller = _caller(callerSeed);
        bool ok = caller == ghostAuthority;
        uint64 before = _lastActivity();
        if (!ok) _expect(_notAuthorized(caller));
        vm.prank(caller);
        registry.heartbeat(artistId);
        if (!ok && _lastActivity() != before) ++walletMovedActivity;
        if (ok) ghostLastActivity = uint64(block.timestamp);
    }

    function revokeNonce(uint256 callerSeed) external {
        address caller = _caller(callerSeed);
        uint64 before = _lastActivity();
        if (caller != ghostAuthority) _expect(_notAuthorized(caller));
        vm.prank(caller);
        registry.revokeNonce(artistId);
        if (caller != ghostAuthority) {
            if (_lastActivity() != before) ++walletMovedActivity;
            return;
        }
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
        // The model is the delegation contract's; a hostile source records what it likes.
        if (hostileInstalled) return;
        Standing[] memory next = registry.standingOf(artistId);
        assertLe(next.length, 16);
        for (uint256 i; i < before.length; ++i) {
            if (_find(next, before[i].wallet) != type(uint256).max) continue;
            assertEq(adapter.effectiveAt(ghostAuthority, before[i].wallet), 0, "removed live");
            if (before[i].effectiveAt > block.timestamp) continue; // pending: it never had standing
            assertTrue(before[i].missingSince != 0, "removed while not missing");
            assertGe(
                block.timestamp, uint256(before[i].missingSince) + ghostTimers[4], "removed early"
            );
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

    /// @dev Governance swaps the consolidation source between the adapter and a source that
    ///      names every wallet as established since the epoch (review C, F2).
    function toggleSource() external {
        IConsolidationSource current = registry.consolidationSource();
        IConsolidationSource next =
            hostileInstalled ? IConsolidationSource(address(adapter)) : hostile;
        vm.prank(successorSetter);
        registry.setConsolidationSource(current, next, address(next).codehash);
        hostileInstalled = !hostileInstalled;
        ++sourceSwaps;
    }

    /// @dev Flags or unflags a payout candidate as a deployed split wallet.
    function flagSplitWallet(uint256 seed) external {
        address w = payouts[1 + seed % 2];
        factory.setWallet(w, !factory.isWallet(w));
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 hours, 200 days));
    }

    /// @dev Governance sets a timer, in or just outside its bounds; a pending change keeps what
    ///      it locked.
    function setTimer(uint256 whichSeed, uint256 valueSeed) external {
        PendingChange memory before = registry.pendingChange(artistId);
        IArtistRegistry.Timer which = IArtistRegistry.Timer(whichSeed % 5);
        (uint48 floor, uint48 ceiling) = registry.timerBounds(which);
        uint48 value = uint48(bound(valueSeed, floor - 1 days, ceiling + 1 days));
        uint48[5] memory t = ghostTimers;
        t[uint256(which)] = value;
        bool ok = value >= floor && value <= ceiling && t[3] >= uint256(t[1]) + 185 days;
        if (ok) {
            vm.expectEmit(address(registry));
            emit IArtistRegistry.TimerSet(which, value);
        } else {
            _expect(_sel(IArtistRegistry.InvalidTimers.selector));
        }
        vm.prank(successorSetter);
        registry.setTimer(which, value);
        assertEq(
            keccak256(abi.encode(registry.pendingChange(artistId))), keccak256(abi.encode(before))
        );
        if (!ok) return;
        ghostTimers = t;
        ++timerChanges;
    }

    /// @dev The federation registry lists an address; refused when listed, canonical (as entry
    ///      or partner) or not installable.
    function fedList(uint256 tokenSeed, uint256 partnerSeed, uint8 form, uint32 feeShare) external {
        bytes32 before = _identityState();
        uint256 i = tokenSeed % 8;
        address token = fedTokens[i];
        uint256 j = partnerSeed % 8;
        address partner = partnerSeed % 3 == 0 ? address(0) : fedTokens[j];
        // The adapter is canonical only while it is the installed source.
        if (hostileInstalled && (token == address(adapter) || partner == address(adapter))) return;
        bool ok = ghostStatus[token] == IArtistRegistry.FederationStatus.NONE && fedInstallable[i]
            && !fedCanonical[i] && (partner == address(0) || !fedCanonical[j]);
        // The consent of the active authority (none while a recovery override restrains it).
        address active = registry.activeAuthorityOf(artistId);
        uint64 deadline = uint64(block.timestamp);
        bytes memory consent =
            _sign(_keyOf(active), registry.listingDigest(artistId, token, deadline));
        if (active == address(0)) {
            ok = false;
            _expect(abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, active));
        } else if (ok) {
            vm.expectEmit(address(registry));
            emit IArtistRegistry.FederatedContractListed(
                artistId, token, token.codehash, form, partner, feeShare, payouts[2]
            );
        } else {
            _expect(
                abi.encodeWithSelector(IArtistRegistry.FederatedContractRefused.selector, token)
            );
        }
        vm.prank(federation);
        registry.listFederatedContract(
            artistId, token, form, partner, feeShare, payouts[2], deadline, consent
        );
        assertEq(_identityState(), before, "a listing touched the identity");
        if (!ok) return;
        ghostStatus[token] = IArtistRegistry.FederationStatus.ACTIVE;
        ++listed;
    }

    /// @dev The federation registry writes a status: only ACTIVE or DELISTED, never for an
    ///      unlisted or LEFT token.
    function fedStatus(uint256 tokenSeed, uint256 statusSeed) external {
        bytes32 before = _identityState();
        address token = fedTokens[tokenSeed % 8];
        IArtistRegistry.FederationStatus status = IArtistRegistry.FederationStatus(statusSeed % 4);
        IArtistRegistry.FederationStatus current = ghostStatus[token];
        bool ok =
            (current == IArtistRegistry.FederationStatus.ACTIVE
                    || current == IArtistRegistry.FederationStatus.DELISTED)
                && (status == IArtistRegistry.FederationStatus.ACTIVE
                    || status == IArtistRegistry.FederationStatus.DELISTED);
        if (ok) {
            vm.expectEmit(address(registry));
            emit IArtistRegistry.FederatedContractStatus(
                token, artistId, status, bytes32(statusSeed)
            );
        } else {
            _expect(
                abi.encodeWithSelector(
                    IArtistRegistry.FederatedStatusRefused.selector, token, current
                )
            );
        }
        vm.prank(federation);
        registry.setFederatedStatus(token, status, bytes32(statusSeed));
        assertEq(_identityState(), before, "a status write touched the identity");
        if (!ok) return;
        ghostStatus[token] = status;
        ++statusWrites;
    }

    /// @dev A token records its own exit: LEFT for good; a repeat does nothing; an unlisted
    ///      caller reverts.
    function fedExit(uint256 tokenSeed) external {
        bytes32 before = _identityState();
        address token = fedTokens[tokenSeed % 8];
        IArtistRegistry.FederationStatus current = ghostStatus[token];
        if (current == IArtistRegistry.FederationStatus.NONE) {
            _expect(
                abi.encodeWithSelector(
                    IArtistRegistry.FederatedStatusRefused.selector, token, current
                )
            );
        }
        IArtistRegistry.FederationStatus next = current == IArtistRegistry.FederationStatus.DELISTED
            ? IArtistRegistry.FederationStatus.LEFT_DELISTED
            : IArtistRegistry.FederationStatus.LEFT;
        bool exits_ = current == IArtistRegistry.FederationStatus.ACTIVE
            || current == IArtistRegistry.FederationStatus.DELISTED;
        if (exits_) {
            vm.expectEmit(address(registry));
            emit IArtistRegistry.FederatedContractStatus(token, artistId, next, bytes32(0));
        }
        vm.prank(token);
        registry.recordFederationExit();
        assertEq(_identityState(), before, "an exit touched the identity");
        if (!exits_) return;
        ghostStatus[token] = next;
        everLeft[token] = true;
        ++exits;
    }

    /// @dev The federation registry creates an identity: only for an account that signed its
    ///      consent; a consent signed by another key (here the thief's) is refused.
    function fedRegister(uint256 seed, bool forged) external {
        bytes32 before = _identityState();
        uint256 key = 0xF00D + fedRegistrations;
        address account = vm.addr(key);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = registry.registrationDigest(account, PROFILE, bytes32(seed), deadline);
        bytes memory signature = _sign(forged ? keys[3] : key, digest);
        if (forged) _expect(SignatureReverts.invalid(account));
        vm.prank(federation);
        registry.registerFederated(account, PROFILE, bytes32(seed), deadline, signature);
        assertEq(_identityState(), before, "a registration touched another identity");
        if (forged) return;
        assertEq(registry.authorityOf(uint160(account)), account);
        assertEq(registry.payoutAddress(uint160(account)), account);
        ++fedRegistrations;
    }

    function timerOf(uint256 i) external view returns (uint48) {
        return ghostTimers[i];
    }

    function fedToken(uint256 i) external view returns (address) {
        return fedTokens[i];
    }

    function fedIsCanonical(uint256 i) external view returns (bool) {
        return fedCanonical[i];
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
        _onStaged(u.kind, false);
    }

    /// @dev The registry's check order for `stageChange` up to the signature: a signer other
    ///      than the authority must never have been the artist's authority (RFX-ID-1), the artist
    ///      must be dormant (review C, F2; checked before the source), and the current source
    ///      must name the signer as established.
    function _stageError(address signer, ArtistIdentity memory next)
        private
        view
        returns (bytes memory)
    {
        if (registry.pendingChange(artistId).kind != ChangeKind.NONE) {
            return abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId);
        }
        if (signer != ghostAuthority) {
            if (ghostWasAuthority[signer]) return _notAuthorized(signer);
            if (!_dormant()) {
                return abi.encodeWithSelector(
                    IArtistRegistry.NotDormant.selector, artistId, ghostLastActivity
                );
            }
            bool established = hostileInstalled
                ? signer != ghostAuthority
                : adapter.isEstablished(ghostAuthority, signer);
            if (!established) return _notAuthorized(signer);
        }
        return _nextError(next);
    }

    function _lastActivity() private view returns (uint64 last) {
        (, last) = registry.artist(artistId);
    }

    function _dormant() private view returns (bool) {
        return block.timestamp >= uint256(ghostLastActivity) + ghostTimers[2];
    }

    /// @dev `_checkNext`: a valid payout, and a new authority that has never been the artist's
    ///      (SIGS-3; the handler drives one artist, so nothing else is mapped or reserved).
    function _nextError(ArtistIdentity memory next) private view returns (bytes memory) {
        if (factory.isWallet(next.payout)) return _sel(IArtistRegistry.InvalidIdentity.selector);
        if (next.authority != ghostAuthority && ghostWasAuthority[next.authority]) {
            return abi.encodeWithSelector(IArtistRegistry.AccountTaken.selector, next.authority);
        }
        return "";
    }

    /// @dev The registry's check order for `stageOverride`.
    function _overrideError(Accepted memory u) private view returns (bytes memory) {
        bytes memory err = _nextError(u.next);
        if (err.length != 0) return err;
        bool payoutOnly = u.next.authority == ghostAuthority && u.next.payout != ghostPayout;
        if (
            (u.kind != ChangeKind.CONTESTED || payoutOnly)
                && block.timestamp < uint256(ghostLastActivity) + ghostTimers[2]
        ) {
            return abi.encodeWithSelector(
                IArtistRegistry.NotDormant.selector, artistId, ghostLastActivity
            );
        }
        if (u.next.authority != ghostAuthority) {
            if (usedDigest[u.digest]) {
                return abi.encodeWithSelector(IArtistRegistry.AcceptanceUsed.selector, u.digest);
            }
            if (block.timestamp > u.deadline) return SignatureReverts.expired(u.deadline);
        }
        if (registry.pendingChange(artistId).kind > ChangeKind.STANDARD) {
            return abi.encodeWithSelector(IArtistRegistry.ChangePending.selector, artistId);
        }
        return "";
    }

    function _onStaged(ChangeKind kind, bool byWallet) private {
        PendingChange memory p = registry.pendingChange(artistId);
        assertEq(uint8(p.kind), uint8(kind));
        ghostWalletStaged = byWallet;
        // A wallet-signed change waits the override delay (review C, F2).
        ghostStagedDelay =
            kind == ChangeKind.STANDARD && !byWallet ? ghostTimers[0] : ghostTimers[1];
        ghostStagedTimeout = ghostTimers[3];
        assertEq(p.executableAt, p.stagedAt + ghostStagedDelay, "the delay is locked at staging");
        assertEq(p.contestTimeout, ghostStagedTimeout, "the contest timeout is locked at staging");
        ghostCancellers = keccak256(abi.encode(p.cancellers));
        ++ghostNonce;
    }

    /// @dev Everything about the artist that a federation action must leave unchanged.
    function _identityState() private view returns (bytes32) {
        (ArtistIdentity memory identity, uint64 last) = registry.artist(artistId);
        return keccak256(
            abi.encode(
                identity,
                last,
                registry.pendingChange(artistId),
                registry.standingOf(artistId),
                registry.changeNonce(artistId),
                registry.payoutAddress(artistId),
                registry.activeAuthorityOf(artistId)
            )
        );
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

    /// @dev The handler key of `account`, or the first key when it holds none.
    function _keyOf(address account) private view returns (uint256) {
        for (uint256 i; i < 4; ++i) {
            if (vm.addr(keys[i]) == account) return keys[i];
        }
        return keys[0];
    }

    function _sign(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
