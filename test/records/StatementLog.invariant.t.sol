// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StatementLogFixture } from "./StatementLogFixture.sol";
import { StatementLogHandler, Actors } from "./StatementLogHandler.sol";
import { HandlerReach } from "../helpers/HandlerReach.sol";

/// @notice Stateful invariants for the statement log (ADR 0001 section 12). A handler appends
///         through every path, revokes and replays nonces and attempts unauthorised writes, while
///         rebuilding each subject's chain from the emitted events. Run with the foundry.toml
///         campaign (256 runs x depth 128, `fail_on_revert`).
contract StatementLogInvariantTest is StatementLogFixture {
    StatementLogHandler internal handler;

    function setUp() public override {
        super.setUp();
        resolver.grantEverywhere(artist);
        nft.setOwner(2, tokenOwner);
        editions.setBalance(7, tokenOwner, 1);
        // The AccessManager would pass both role checks; it must still never be a signer.
        resolver.grantEverywhere(address(manager));
        editions.setBalance(7, address(manager), 1);

        handler = new StatementLogHandler(
            stmtLog,
            Actors({
                nft: address(nft),
                editions: address(editions),
                resolver: address(resolver),
                artist: artist,
                tokenOwner: tokenOwner,
                curator: curator,
                platform: platform,
                admin: admin,
                manager: address(manager),
                governor: governor,
                stranger: stranger,
                artistKey: artistKey,
                ownerKey: ownerKey,
                curatorKey: curatorKey
            })
        );
        targetContract(address(handler));
    }

    /// @dev Stored count and head equal the ones rebuilt from events, for every subject touched.
    function invariant_CountAndHeadMatchEmittedEvents() public view {
        for (uint256 i; i < handler.keysLength(); ++i) {
            bytes32 key = handler.keys(i);
            (uint64 count, bytes32 head) =
                stmtLog.chainOf(handler.subjectToken(key), handler.subjectId(key));
            assertEq(count, handler.ghostCount(key), "count differs from events");
            assertEq(
                head, handler.ghostHead(key), "head differs from the chain rebuilt from events"
            );
        }
    }

    /// @dev A subject's latest-dispute pointer equals the last DISPUTE_OUTCOME entry rebuilt from
    ///      events, and stays zero for subjects with none.
    function invariant_LatestDisputeOutcomeMatchesEvents() public view {
        for (uint256 i; i < handler.keysLength(); ++i) {
            bytes32 key = handler.keys(i);
            assertEq(
                stmtLog.latestDisputeOutcome(handler.subjectToken(key), handler.subjectId(key)),
                handler.ghostDispute(key)
            );
        }
    }

    /// @dev Every event was well formed, gapless and recomputable; no replayed or unauthorised
    ///      append ever succeeded (including by the admin, curator, platform or the log itself).
    function invariant_NoMalformedEventsReplaysOrUnauthorisedWrites() public view {
        assertEq(handler.violations(), 0);
    }

    /// @dev ARTIST events are signed by the artist (or the artist's wallet) and OWNER events by
    ///      the owner, never by an admin, curator, platform or stranger; the reserved kinds appear
    ///      only under PLATFORM (DISPUTE_OUTCOME) and CURATOR (CURATION_EVIDENCE); and the
    ///      AccessManager signs only GOVERNANCE_MANIFEST entries, as PLATFORM, about itself.
    function invariant_RolesAreSpokenOnlyByTheirHoldersAndReservedKindsStayReserved() public view {
        assertEq(handler.roleViolations(), 0);
    }

    /// @dev Every ARTIST entry carries the resolver that was active when it was written, across
    ///      resolver swaps; no other role carries one.
    function invariant_ArtistEntriesBindTheActiveResolver() public view {
        assertEq(handler.resolverViolations(), 0);
    }

    /// @dev A relayed entry is followed by exactly one nonce event naming its entry, signer and
    ///      nonce; a direct entry by none.
    function invariant_RelayedEntriesCarryTheirNonce() public view {
        assertEq(handler.relayViolations(), 0);
    }

    /// @dev A used or revoked nonce stays spent.
    function invariant_SpentNoncesStaySpent() public view {
        for (uint256 i; i < handler.authorizationsLength(); ++i) {
            (address signer, uint256 nonce) = handler.authorizationAt(i);
            assertTrue(stmtLog.nonceUsed(signer, nonce));
        }
        for (uint256 i; i < handler.revokedLength(); ++i) {
            assertTrue(stmtLog.nonceUsed(handler.revokedBy(i), handler.revokedNonce(i)));
        }
    }

    /// @notice Handler self-test: every append path, the resolver swap, the nonce revocation and
    ///         the governance manifest write the log; every replay, tampered or expired relay,
    ///         unauthorised writer, reserved-kind misuse and governance misuse reaches the log
    ///         and is refused there. Then every invariant holds.
    function test_HandlerPathsReachState() public {
        uint8 w = HandlerReach.WRITES;
        uint8 r = HandlerReach.REFUSED;
        HandlerReach.Expect[] memory e = new HandlerReach.Expect[](15);
        e[0] = HandlerReach.Expect(StatementLogHandler.appendArtist.selector, w);
        e[1] = HandlerReach.Expect(StatementLogHandler.appendOwner.selector, w);
        e[2] = HandlerReach.Expect(StatementLogHandler.appendCurator.selector, w);
        e[3] = HandlerReach.Expect(StatementLogHandler.appendPlatform.selector, w);
        e[4] = HandlerReach.Expect(StatementLogHandler.appendRelayed.selector, w);
        e[5] = HandlerReach.Expect(StatementLogHandler.appendRelayedByWallet.selector, w);
        e[6] = HandlerReach.Expect(StatementLogHandler.swapResolver.selector, w);
        e[7] = HandlerReach.Expect(StatementLogHandler.revokeNonce.selector, w);
        e[8] = HandlerReach.Expect(StatementLogHandler.replay.selector, r);
        e[9] = HandlerReach.Expect(StatementLogHandler.tamperedRelay.selector, r);
        e[10] = HandlerReach.Expect(StatementLogHandler.expiredRelay.selector, r);
        e[11] = HandlerReach.Expect(StatementLogHandler.unauthorized.selector, r);
        e[12] = HandlerReach.Expect(StatementLogHandler.reservedKindMisuse.selector, r);
        e[13] = HandlerReach.Expect(
            StatementLogHandler.appendGovernanceManifest.selector, w | HandlerReach.CLOCK
        );
        e[14] = HandlerReach.Expect(StatementLogHandler.governanceMisuse.selector, r);
        address[] memory sut = new address[](1);
        sut[0] = address(stmtLog);
        HandlerReach.check(e, HandlerReach.drive(address(handler), e, sut, 24, 1));
        assertGt(handler.resolverSwaps(), 0);
        assertGt(handler.refusedAttempts(), 0);
        invariant_CountAndHeadMatchEmittedEvents();
        invariant_LatestDisputeOutcomeMatchesEvents();
        invariant_NoMalformedEventsReplaysOrUnauthorisedWrites();
        invariant_RolesAreSpokenOnlyByTheirHoldersAndReservedKindsStayReserved();
        invariant_ArtistEntriesBindTheActiveResolver();
        invariant_RelayedEntriesCarryTheirNonce();
        invariant_SpentNoncesStaySpent();
    }
}
