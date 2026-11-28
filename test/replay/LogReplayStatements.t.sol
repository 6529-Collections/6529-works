// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IStatementLog, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { HASH_SHA256, HashRef } from "src/interfaces/types/HashRef.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { ReplayBase } from "./ReplayBase.sol";
import { ReplayEvents } from "./ReplayEvents.sol";

/// @notice Log replay of the statement log on the deployed stack, from its deployment on (the
///         resolver its constructor installs and the governance manifest the wiring appends):
///         a history that emits every event it can emit (curation evidence, a platform's
///         dispute outcome, an owner's and an artist's statements, a relayed signed statement,
///         a revoked nonce, the artist resolver removed and installed again) rebuilds every
///         subject's chain, each dispute outcome, every nonce and the resolver from its logs
///         alone; every entry hash and head is recomputed from the logged fields.
contract LogReplayStatementsTest is ReplayBase {
    address internal artist;
    address internal collector;
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("statementArtist");
        collector = _actor("statementCollector");
        Work[] memory works = new Work[](1);
        works[0] = _work(artist, collectionId);
        root = _publish(works);
        _keep(root, works);
        _sync();
    }

    function _statement(uint256 id, bytes32 kind, string memory uri, bytes32 supersedes)
        internal
        view
        returns (Statement memory)
    {
        return Statement(
            address(stream),
            id,
            kind,
            keccak256("6529-stream/replay-statement/1"),
            HashRef(HASH_SHA256, keccak256(bytes(uri))),
            uri,
            bytes32(0),
            supersedes
        );
    }

    function test_StatementLog_EveryEventReplaysToTheSameState() public {
        statementsIdx.probe(collector);
        uint256 id = _sell(root, _package(root), 0, collector, 1 ether);
        _sync();

        // The owner's statement, then the artist's on the same subject: one chain of two.
        vm.prank(collector);
        bytes32 first = statements.append(
            Role.OWNER, _statement(id, StatementKinds.CUSTODY_ATTESTATION, "ar://o", 0)
        );
        vm.prank(artist);
        statements.append(
            Role.ARTIST, _statement(id, StatementKinds.ARTIST_STATEMENT, "ar://a", first)
        );
        _sync();

        // A platform's dispute outcome about the work.
        _platformStatement(address(stream), id, StatementKinds.DISPUTE_OUTCOME, "ar://outcome");
        _sync();

        // A signed statement relayed by anyone, and a revoked nonce in the same word.
        Statement memory s = _statement(id, StatementKinds.EXHIBITION, "ar://relayed", 0);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = statements.authorizationDigest(Role.OWNER, s, collector, 3, deadline);
        statements.appendSigned(Role.OWNER, s, collector, 3, deadline, _sign(collector, digest));
        vm.prank(collector);
        statements.revokeNonce(2);
        _sync();

        // The artist resolver removed, then installed again.
        address resolver = statements.artistResolver();
        _asNetwork(
            address(statements),
            abi.encodeCall(statements.setArtistResolver, (resolver, address(0), bytes32(0)))
        );
        _sync();
        _asNetwork(
            address(statements),
            abi.encodeCall(statements.setArtistResolver, (address(0), resolver, resolver.codehash))
        );
        _sync();

        (uint64 count,) = statements.chainOf(address(stream), id);
        assertEq(count, 4);
        _assertEveryEventReplayed(
            "StatementLog",
            statementsIdx,
            ReplayEvents.statementLog(),
            _list("EIP712DomainChanged()")
        );
    }

    // ------------------------------------------------------------------ negative controls

    /// @dev Slot 7 holds the nonce bitmaps: a nonce spent with no log.
    function test_StatementLog_ReplayFailsOnStateNoLogExplains() public {
        statementsIdx.probe(collector);
        statementsIdx.assertMatches();
        vm.store(
            address(statements),
            keccak256(abi.encode(uint256(0), keccak256(abi.encode(collector, uint256(7))))),
            bytes32(uint256(1 << 5))
        );
        vm.expectRevert(bytes("nonceUsed (probed): true != false"));
        statementsIdx.assertMatches();
    }

    /// @dev Of two statements on one subject, the first's log is dropped: the second's index
    ///      and head no longer follow from the logs the indexer holds.
    function test_StatementLog_ReplayFailsOnADroppedLog() public {
        uint256 id = _sell(root, _package(root), 0, collector, 1 ether);
        _sync();
        vm.startPrank(collector);
        statements.append(Role.OWNER, _statement(id, StatementKinds.EXHIBITION, "ar://1", 0));
        statements.append(Role.OWNER, _statement(id, StatementKinds.EXHIBITION, "ar://2", 0));
        vm.stopPrank();
        vm.expectRevert(bytes("indexer: entry index: 1 != 0"));
        this.applyExternally(
            _dropOne(address(statements), IStatementLog.StatementAppended.selector)
        );
    }

    function applyExternally(Vm.Log[] memory logs) external {
        _apply(logs);
    }
}
