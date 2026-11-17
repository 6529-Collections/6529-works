// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { Splits } from "src/economics/Splits.sol";
import { FederationBase } from "../federated/FederationBase.sol";
import { ContentIndexer } from "./ContentIndexer.sol";
import { EditionsIndexer } from "./EditionsIndexer.sol";
import { DirectoryIndexer, FederationRegistryIndexer } from "./FederationIndexer.sol";
import { EscrowIndexer, LedgerIndexer } from "./LedgerIndexer.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";
import { StreamIndexer, WorkRecordsIndexer } from "./StreamIndexer.sol";

/// @notice The wired v1 stack (the deploy library with the committed genesis, `IntegrationBase`,
///         and the federation setup of `FederationBase`), with every log recorded from before
///         the deployment, and one reference indexer per permanent contract fed from those logs
///         alone. `_sync` applies the logs recorded since the last call, in log order across
///         contracts (a royalty re-rate's Stream event precedes `WorkRecords`' in the same
///         transaction), then compares every indexer with its live contract.
/// @dev The statement log's replay is `test/records/StatementLogHandler.sol` (INV-DSP-1 to
///      INV-DSP-3), not repeated here.
abstract contract ReplayBase is FederationBase {
    string internal constant TOPICS_PATH = "test/fixtures/real/event-topics.json";

    StreamIndexer internal streamIdx;
    WorkRecordsIndexer internal recordsIdx;
    EditionsIndexer internal editionsIdx;
    ContentIndexer internal contentIdx;
    LedgerIndexer internal ledgerIdx;
    EscrowIndexer internal escrowIdx;
    DirectoryIndexer internal directoryIdx;
    FederationRegistryIndexer internal fedIdx;
    ReplayIndexer[] internal indexers;

    function setUp() public virtual override {
        vm.recordLogs();
        super.setUp();
        streamIdx = new StreamIndexer(address(stream), address(splitFactory));
        recordsIdx = new WorkRecordsIndexer(address(records), streamIdx);
        editionsIdx = new EditionsIndexer(address(editions), address(stream), address(splitFactory));
        contentIdx = new ContentIndexer(address(store));
        ledgerIdx = new LedgerIndexer(address(splitFactory));
        escrowIdx = new EscrowIndexer(address(escrow), ledgerIdx);
        directoryIdx = new DirectoryIndexer(address(artists));
        fedIdx = new FederationRegistryIndexer(address(fedRegistry), directoryIdx);
        indexers.push(streamIdx);
        indexers.push(recordsIdx);
        indexers.push(editionsIdx);
        indexers.push(contentIdx);
        indexers.push(ledgerIdx);
        indexers.push(escrowIdx);
        indexers.push(directoryIdx);
        indexers.push(fedIdx);
        _sync();
    }

    /// @dev Applies the logs recorded since the last call, then compares every indexer. The
    ///      logs are given the current block timestamp: call it after each step whose time a
    ///      rebuilt value records (an escrow credit's clock).
    function _deployLoweredVault(address seller, address feeRecipient, uint32 share) internal {
        // A fee share is lowered only once the royalty vault at the lower share exists (R9).
        splitFactory.createWallet(Splits.royaltyPayees(seller, feeRecipient, share), bytes32(0));
    }

    function _sync() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            for (uint256 j; j < indexers.length; ++j) {
                indexers[j].applyLog(logs[i], block.timestamp);
            }
        }
        for (uint256 j; j < indexers.length; ++j) {
            indexers[j].assertMatches();
        }
    }

    /// @dev Every event declared in `name`'s compiled ABI (the committed list written by
    ///      `tools/make_vectors.py` from `out/`) was replayed at least once, except `skipped`:
    ///      events the contract declares but never emits, or that this lane does not replay,
    ///      each named in the suite. A new event without replay coverage fails here.
    function _assertEveryEventReplayed(
        string memory name,
        ReplayIndexer idx,
        string[] memory skipped
    ) internal view {
        string memory json = vm.readFile(TOPICS_PATH);
        string[] memory signatures =
            vm.parseJsonStringArray(json, string.concat(".", name, ".signatures"));
        bytes32[] memory topics =
            vm.parseJsonBytes32Array(json, string.concat(".", name, ".topics"));
        assertEq(signatures.length, topics.length, "topics file");
        assertGt(signatures.length, 0, "topics file lists no event");
        uint256 used;
        for (uint256 i; i < signatures.length; ++i) {
            assertEq(keccak256(bytes(signatures[i])), topics[i], "topics file: topic0");
            bool skip;
            for (uint256 k; k < skipped.length; ++k) {
                if (keccak256(bytes(skipped[k])) == keccak256(bytes(signatures[i]))) {
                    skip = true;
                    ++used;
                }
            }
            if (skip) continue;
            assertGt(
                idx.seen(topics[i]), 0, string.concat(name, ": never replayed: ", signatures[i])
            );
        }
        assertEq(used, skipped.length, "a skipped event is not in the ABI");
    }

    function _list(string memory a) internal pure returns (string[] memory l) {
        l = new string[](1);
        l[0] = a;
    }

    function _list(string memory a, string memory b) internal pure returns (string[] memory l) {
        l = new string[](2);
        (l[0], l[1]) = (a, b);
    }
}
