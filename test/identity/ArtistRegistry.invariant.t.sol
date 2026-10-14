// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import {
    ArtistIdentity,
    ChangeKind,
    PendingChange,
    Standing
} from "src/interfaces/types/IdentityTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { ArtistRegistryHandler, IdentityActors } from "./ArtistRegistryHandler.sol";
import { IdentityFixture } from "./IdentityFixture.sol";
import {
    DisputeOutcomeLogMock,
    SplitFactoryWalletsMock
} from "../mocks/identity/IdentityWorksMocks.sol";

/// @notice Stateful invariants for the artist registry (ADR 0001 section 11). The handler stages,
///         overrides, cancels, vetoes, replays, executes, refreshes standing and moves time and
///         consolidations, asserting every call's predicted outcome (a wrong prediction reverts the
///         handler, which `fail_on_revert` reports). Run with the foundry.toml campaign (256 runs x
///         depth 128).
contract ArtistRegistryInvariantTest is IdentityFixture {
    ArtistRegistryHandler internal handler;

    function setUp() public override {
        super.setUp();
        SplitFactoryWalletsMock factory = new SplitFactoryWalletsMock();
        DisputeOutcomeLogMock outcomes = new DisputeOutcomeLogMock(address(registry));
        vm.startPrank(admin);
        registry.bindSplitFactory(address(factory));
        registry.bindStatementLog(address(outcomes));
        vm.stopPrank();
        handler = new ArtistRegistryHandler(
            IdentityActors({
                registry: registry,
                adapter: adapter,
                delegation: delegation,
                factory: factory,
                outcomes: outcomes,
                artistId: artistId,
                guardian: guardian,
                governor: governor,
                successorSetter: successorSetter,
                keys: [artistKey, walletKey, newKey, thiefKey],
                payouts: [artist, payout, makeAddr("estatePayout")]
            })
        );
        targetContract(address(handler));
    }

    /// @dev The payout and the authority change only through executed changes: they always equal
    ///      the ghosts, which only a successful `executeChange` updates. The payout resolves to
    ///      zero exactly while a pending change would move it.
    function invariant_PayoutChangesOnlyThroughExecutedChanges() public view {
        (ArtistIdentity memory identity,) = registry.artist(artistId);
        assertEq(identity.payout, handler.ghostPayout());
        assertEq(registry.authorityOf(artistId), handler.ghostAuthority());
        PendingChange memory p = registry.pendingChange(artistId);
        bool lapsed = p.contestedAt != 0 && block.timestamp >= uint256(p.contestedAt) + 365 days;
        bool frozen = p.kind != ChangeKind.NONE && p.next.payout != identity.payout && !lapsed;
        assertEq(registry.payoutAddress(artistId), frozen ? address(0) : handler.ghostPayout());
    }

    /// @dev IDENTITY-1: the active authority is zero exactly while a pending, unlapsed override
    ///      would move the authority, and the authority otherwise.
    function invariant_ActiveAuthorityIsRestrainedOnlyByAnAuthorityMovingOverride() public view {
        PendingChange memory p = registry.pendingChange(artistId);
        address current = handler.ghostAuthority();
        bool lapsed = p.contestedAt != 0 && block.timestamp >= uint256(p.contestedAt) + 365 days;
        bool restrained = p.kind > ChangeKind.STANDARD && p.next.authority != current && !lapsed;
        assertEq(registry.activeAuthorityOf(artistId), restrained ? address(0) : current);
    }

    /// @dev Dormancy counts only the artist's own activity and executions (never overrides,
    ///      vetoes or refreshes), and the nonce moves only with stagings and revocations.
    function invariant_ActivityAndNonceMatchTheModel() public view {
        (, uint64 lastActivity) = registry.artist(artistId);
        assertEq(lastActivity, handler.ghostLastActivity());
        assertEq(registry.changeNonce(artistId), handler.ghostNonce());
    }

    /// @dev A pending change is well formed, and its captured cancellers never change.
    function invariant_PendingChangeIsWellFormed() public view {
        PendingChange memory p = registry.pendingChange(artistId);
        if (p.kind == ChangeKind.NONE) return;
        uint64 delay = p.kind == ChangeKind.STANDARD ? 7 days : 180 days;
        assertEq(p.executableAt, p.stagedAt + delay);
        assertEq(p.previousAuthority, registry.authorityOf(artistId));
        assertEq(p.evidenceHash == bytes32(0), p.kind == ChangeKind.STANDARD);
        assertLe(p.cancellers.length, Limits.MAX_CANCELLERS);
        assertEq(keccak256(abi.encode(p.cancellers)), handler.ghostCancellers());
        assertTrue(p.next.authority != address(0) && p.next.payout != address(0));
        if (p.contestedAt == 0) {
            assertEq(p.priorOutcome, bytes32(0));
            return;
        }
        assertTrue(p.kind > ChangeKind.STANDARD, "only overrides are contested");
        assertTrue(p.contestedAt >= p.stagedAt && p.contestedAt < p.executableAt, "in the notice");
    }

    /// @dev The handler's contest paths work end to end: a fixed walk contests an override,
    ///      records a vote and voids it, then contests another and lets it lapse. (The random
    ///      campaign reaches each path too, though not every run reaches all of them.)
    function test_HandlerReachesContestResolveAndLapse() public {
        handler.stageOverride(0, 2, 0); // CONTESTED, to the fresh key
        handler.cancel(1); // the artist's recorded wallet contests
        handler.recordOutcome(1);
        handler.resolve(false, 1); // a fresh vote voids it
        handler.stageOverride(3, 2, 0); // another CONTESTED override, new evidence
        handler.cancel(1);
        handler.warp(200 days);
        handler.warp(200 days);
        handler.expire(); // lapsed after a year
        assertEq(handler.contested(), 2);
        assertEq(handler.resolved(), 1);
        assertEq(handler.lapsed(), 1);
    }

    /// @dev IDENTITY-2: exactly the next authority of a pending change that moves the authority
    ///      is reserved for the artist; every other key is unreserved.
    function invariant_OnlyThePendingNextAuthorityIsReserved() public view {
        PendingChange memory p = registry.pendingChange(artistId);
        address current = registry.authorityOf(artistId);
        address[4] memory keys =
            [vm.addr(artistKey), vm.addr(walletKey), vm.addr(newKey), vm.addr(thiefKey)];
        for (uint256 i; i < keys.length; ++i) {
            bool reserved =
                p.kind != ChangeKind.NONE && p.next.authority == keys[i] && keys[i] != current;
            assertEq(registry.reservedFor(keys[i]), reserved ? artistId : 0);
        }
    }

    /// @dev SIGS-3: exactly the keys that have been the artist's authority resolve to it, and the
    ///      handler's model (which refuses a return to any of them) matches.
    function invariant_PastAuthoritiesResolveToTheArtist() public view {
        address[4] memory keys =
            [vm.addr(artistKey), vm.addr(walletKey), vm.addr(newKey), vm.addr(thiefKey)];
        for (uint256 i; i < keys.length; ++i) {
            bool was = handler.ghostWasAuthority(keys[i]);
            assertEq(registry.artistIdOf(keys[i]), was ? artistId : 0);
        }
    }

    /// @dev The authority resolves to the artist, and the standing snapshot stays bounded and
    ///      free of duplicates.
    function invariant_AuthorityAndStandingAreConsistent() public view {
        assertEq(registry.artistIdOf(registry.authorityOf(artistId)), artistId);
        Standing[] memory s = registry.standingOf(artistId);
        assertLe(s.length, Limits.MAX_CANCELLERS);
        for (uint256 i; i < s.length; ++i) {
            for (uint256 j = i + 1; j < s.length; ++j) {
                assertTrue(s[i].wallet != s[j].wallet);
            }
        }
    }
}
