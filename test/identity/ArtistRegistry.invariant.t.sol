// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { IArtistRegistry, IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import {
    ArtistIdentity,
    ChangeKind,
    PendingChange,
    Standing
} from "src/interfaces/types/IdentityTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import {
    ArtistRegistryHandler,
    FederationActors,
    IdentityActors
} from "./ArtistRegistryHandler.sol";
import { IdentityFixture } from "./IdentityFixture.sol";
import {
    DisputeOutcomeLogMock,
    EditionsMastersMock,
    FederationRegistryStub,
    SplitFactoryWalletsMock
} from "../mocks/identity/IdentityWorksMocks.sol";
import { EveryoneEstablishedSource } from "../mocks/identity/PermanenceMocks.sol";
import { StreamMock } from "../mocks/stream/StreamMock.sol";

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
        StreamMock stream = new StreamMock();
        address editions = address(new EditionsMastersMock());
        stream.setEditions(editions);
        address federation = address(new FederationRegistryStub());
        vm.startPrank(admin);
        registry.bindSplitFactory(address(factory));
        registry.bindStatementLog(address(outcomes));
        registry.bindStream(address(stream));
        registry.bindFederationRegistry(federation);
        vm.stopPrank();
        address delegated = makeAddr("delegated7702");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(stream)));
        FederationActors memory f = FederationActors({
            federation: federation,
            tokens: [
                address(new FederationRegistryStub()), // a federated token
                address(new EditionsMastersMock()), // another
                address(stream),
                editions,
                address(registry),
                address(adapter),
                makeAddr("codeless"),
                delegated
            ],
            canonical: [false, false, true, true, true, true, false, false],
            installable: [true, true, true, true, true, true, false, false]
        });
        address[] memory named = new address[](4);
        (named[0], named[1], named[2], named[3]) =
        (vm.addr(artistKey), vm.addr(walletKey), vm.addr(newKey), vm.addr(thiefKey));
        IConsolidationSource hostile =
            IConsolidationSource(address(new EveryoneEstablishedSource(named)));
        handler = new ArtistRegistryHandler(
            IdentityActors({
                registry: registry,
                adapter: adapter,
                delegation: delegation,
                factory: factory,
                outcomes: outcomes,
                hostile: hostile,
                artistId: artistId,
                guardian: guardian,
                governor: governor,
                successorSetter: successorSetter,
                keys: [artistKey, walletKey, newKey, thiefKey],
                payouts: [artist, payout, makeAddr("estatePayout")]
            }),
            f
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
        bool lapsed =
            p.contestedAt != 0 && block.timestamp >= uint256(p.contestedAt) + p.contestTimeout;
        bool frozen = p.kind != ChangeKind.NONE && p.next.payout != identity.payout && !lapsed;
        assertEq(registry.payoutAddress(artistId), frozen ? address(0) : handler.ghostPayout());
    }

    /// Regression: IDENTITY-1 (docs/security/internal-review-2026-10.md)
    /// @dev IDENTITY-1: the active authority is zero exactly while a pending, unlapsed override
    ///      would move the authority, and the authority otherwise.
    function invariant_ActiveAuthorityIsRestrainedOnlyByAnAuthorityMovingOverride() public view {
        PendingChange memory p = registry.pendingChange(artistId);
        address current = handler.ghostAuthority();
        bool lapsed =
            p.contestedAt != 0 && block.timestamp >= uint256(p.contestedAt) + p.contestTimeout;
        bool restrained = p.kind > ChangeKind.STANDARD && p.next.authority != current && !lapsed;
        assertEq(registry.activeAuthorityOf(artistId), restrained ? address(0) : current);
    }

    /// @dev The `restrained` flag beside the authority (the state-growth diet) is exactly
    ///      whether the pending change is an override that moves the authority, lapsed or not:
    ///      set at every staging, cleared at every end of a change. `_artists` is at slot 3
    ///      (`forge inspect ArtistRegistry storageLayout`); the authority in the same word
    ///      guards the layout.
    function invariant_RestrainedFlagMatchesThePendingChange() public view {
        uint256 word =
            uint256(vm.load(address(registry), keccak256(abi.encode(artistId, uint256(3)))));
        address current = registry.authorityOf(artistId);
        assertEq(address(uint160(word)), current, "layout");
        PendingChange memory p = registry.pendingChange(artistId);
        bool moving = p.kind > ChangeKind.STANDARD && p.next.authority != current;
        assertEq((word >> 160) & 0xff != 0, moving);
    }

    /// @dev Dormancy counts only the artist's own activity and executions (never overrides,
    ///      vetoes or refreshes), and the nonce moves only with stagings and revocations.
    function invariant_ActivityAndNonceMatchTheModel() public view {
        (, uint64 lastActivity) = registry.artist(artistId);
        assertEq(lastActivity, handler.ghostLastActivity());
        assertEq(registry.changeNonce(artistId), handler.ghostNonce());
    }

    /// @dev Review C, F2: the consolidation source, however hostile (the handler swaps in one
    ///      that names every wallet), never acts for a live artist: no wallet-signed change is
    ///      staged while the artist had signed activity within the dormancy period, and a pending
    ///      wallet-signed change waits at least the override delay's floor (180 days).
    function invariant_ASourceNeverActsForALiveArtist() public view {
        assertEq(handler.walletStagedWhileLive(), 0);
        PendingChange memory p = registry.pendingChange(artistId);
        if (p.kind == ChangeKind.STANDARD && handler.ghostWalletStaged()) {
            assertGe(p.executableAt - p.stagedAt, 180 days);
        }
    }

    /// @dev A pending change is well formed, and its captured cancellers never change.
    function invariant_PendingChangeIsWellFormed() public view {
        PendingChange memory p = registry.pendingChange(artistId);
        if (p.kind == ChangeKind.NONE) return;
        // The delay and contest timeout locked at staging, whatever governance set since.
        assertEq(p.executableAt, p.stagedAt + handler.ghostStagedDelay());
        assertEq(p.contestTimeout, handler.ghostStagedTimeout());
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

    /// @dev The handler's hostile-source path works end to end: with a source that names every
    ///      wallet, the thief's key cannot stage for the live artist, then stages once the artist
    ///      is dormant, and its change waits the override delay.
    function test_HandlerReachesAWalletStagingUnderTheHostileSource() public {
        handler.toggleSource();
        handler.stageStandard(3, 3, 0); // live: refused with NotDormant, as predicted
        assertEq(handler.walletStagings(), 0);
        handler.warp(200 days);
        handler.warp(200 days);
        handler.stageStandard(3, 3, 0);
        assertEq(handler.walletStagings(), 1);
        PendingChange memory p = registry.pendingChange(artistId);
        assertEq(p.executableAt - p.stagedAt, 180 days);
        handler.toggleSource();
        assertFalse(handler.hostileInstalled());
    }

    /// Regression: IDENTITY-2 (docs/security/internal-review-2026-10.md)
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

    /// Regression: SIGS-3 (docs/security/internal-review-2026-10.md)
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

    /// @dev Every governed timer stays within its compiled floor and ceiling, the contest timeout
    ///      exceeds the override delay by the floors' 185 days, and the registry matches the
    ///      handler's model.
    function invariant_TimersStayWithinTheirBounds() public view {
        for (uint256 i; i < 5; ++i) {
            IArtistRegistry.Timer which = IArtistRegistry.Timer(i);
            (uint48 floor, uint48 ceiling) = registry.timerBounds(which);
            uint48 value = registry.timer(which);
            assertEq(value, handler.timerOf(i));
            assertGe(value, floor);
            assertLe(value, ceiling);
        }
        assertGe(
            registry.timer(IArtistRegistry.Timer.CONTEST_TIMEOUT),
            uint256(registry.timer(IArtistRegistry.Timer.OVERRIDE_DELAY)) + 185 days
        );
    }

    /// @dev The federation directory matches the model: canonical contracts are never listed,
    ///      LEFT is terminal, and each entry names this artist.
    function invariant_FederationDirectoryMatchesTheModel() public view {
        for (uint256 i; i < 8; ++i) {
            address token = handler.fedToken(i);
            (uint256 listedArtist, IArtistRegistry.FederationStatus status) =
                registry.federatedListing(token);
            assertEq(uint8(status), uint8(handler.ghostStatus(token)));
            if (handler.fedIsCanonical(i)) {
                assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.NONE));
            }
            if (handler.everLeft(token)) {
                assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.LEFT));
            }
            bool isListed = status != IArtistRegistry.FederationStatus.NONE;
            assertEq(listedArtist, isListed ? artistId : 0);
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
