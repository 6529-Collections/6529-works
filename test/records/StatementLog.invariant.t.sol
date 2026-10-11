// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StatementLogFixture } from "./StatementLogFixture.sol";
import { StatementLogHandler, Actors } from "./StatementLogHandler.sol";

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
    ///      only under PLATFORM (DISPUTE_OUTCOME) and CURATOR (CURATION_EVIDENCE).
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
}
