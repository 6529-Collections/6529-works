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

        handler = new StatementLogHandler(
            stmtLog,
            Actors({
                nft: address(nft),
                editions: address(editions),
                artist: artist,
                tokenOwner: tokenOwner,
                curator: curator,
                platform: platform,
                admin: admin,
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

    /// @dev Entries exist only as events: the counts add up to the number of events emitted.
    function invariant_EntryTotalEqualsEventTotal() public view {
        uint256 total;
        for (uint256 i; i < handler.keysLength(); ++i) {
            (uint64 count,) = stmtLog.chainOf(
                handler.subjectToken(handler.keys(i)), handler.subjectId(handler.keys(i))
            );
            total += count;
        }
        assertEq(total, handler.totalEvents());
    }

    /// @dev Every event was well formed, gapless and recomputable; no replayed or unauthorised
    ///      append ever succeeded (including by the admin, curator, platform or the log itself).
    function invariant_NoMalformedEventsReplaysOrUnauthorisedWrites() public view {
        assertEq(handler.violations(), 0);
    }

    /// @dev ARTIST events are signed by the artist and OWNER events by the owner, never by an
    ///      admin, curator, platform or stranger.
    function invariant_RolesAreSpokenOnlyByTheirHolders() public view {
        assertEq(handler.roleViolations(), 0);
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

    function invariant_LogHoldsNoValue() public view {
        assertEq(address(stmtLog).balance, 0);
    }
}
