// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ReplayBase } from "./ReplayBase.sol";
import { ReplayEvents } from "./ReplayEvents.sol";

/// @notice The replay suites' event lists (`ReplayEvents`) and the compiled ABIs agree: the
///         committed `test/fixtures/real/event-topics.json`, which `tools/make_vectors.py`
///         writes from Foundry's `out/`, must list for each permanent contract exactly the
///         events its suite requires to be replayed, each with the keccak of its signature.
contract LogReplayTopicsTest is ReplayBase {
    /// @notice Open: the committed topics file still names the contracts before the plain-core
    ///         restructuring (`WorkRecords`, `ArtistRegistry`, `FederationRegistry`, the old
    ///         Stream and Editions). When the tool and the fixture name the plain-core contracts
    ///         this fails, and `check_TopicsFileListsTheCompiledEvents` becomes a regular test.
    function test_Replay_TopicsFileListsTheCompiledEvents() public {
        _expectFailure(
            abi.encodeCall(this.check_TopicsFileListsTheCompiledEvents, ()),
            bytes4(0),
            "event-topics.json does not list the plain-core contracts' events: the CONTRACTS "
            "list of tools/make_vectors.py must name Stream, Editions, WorkFacts, Directory, "
            "FederatedStream, FederatedEditions, SplitLedger, RevenueEscrow, ContentStore and "
            "StatementLog, and the fixture be written again"
        );
    }

    function check_TopicsFileListsTheCompiledEvents() external view {
        _assertTopicsFile("Stream", ReplayEvents.stream());
        _assertTopicsFile("Editions", ReplayEvents.editions());
        _assertTopicsFile("WorkFacts", ReplayEvents.workFacts());
        _assertTopicsFile("Directory", ReplayEvents.directory());
        _assertTopicsFile("FederatedStream", ReplayEvents.federatedStream());
        _assertTopicsFile("FederatedEditions", ReplayEvents.federatedEditions());
        _assertTopicsFile("SplitLedger", ReplayEvents.splitLedger());
        _assertTopicsFile("RevenueEscrow", ReplayEvents.revenueEscrow());
        _assertTopicsFile("ContentStore", ReplayEvents.contentStore());
        _assertTopicsFile("StatementLog", ReplayEvents.statementLog());
    }

    /// @dev The lists are what the suites check: each signature's keccak is a distinct topic0.
    function test_Replay_EventListsHaveDistinctTopics() public pure {
        _distinct(ReplayEvents.stream());
        _distinct(ReplayEvents.editions());
        _distinct(ReplayEvents.workFacts());
        _distinct(ReplayEvents.directory());
        _distinct(ReplayEvents.federatedStream());
        _distinct(ReplayEvents.federatedEditions());
        _distinct(ReplayEvents.splitLedger());
        _distinct(ReplayEvents.revenueEscrow());
        _distinct(ReplayEvents.contentStore());
        _distinct(ReplayEvents.statementLog());
    }

    function _distinct(string[] memory events) internal pure {
        assertGt(events.length, 0, "empty list");
        for (uint256 i; i < events.length; ++i) {
            for (uint256 j = i + 1; j < events.length; ++j) {
                assertTrue(keccak256(bytes(events[i])) != keccak256(bytes(events[j])), "twice");
            }
        }
    }
}
