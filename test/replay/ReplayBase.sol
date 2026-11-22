// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";
import { ContentIndexer } from "./ContentIndexer.sol";
import { EditionsCoreIndexer } from "./EditionsCoreIndexer.sol";
import { EscrowIndexer, LedgerIndexer } from "./LedgerIndexer.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";
import { StatementLogIndexer } from "./StatementLogIndexer.sol";
import { CoreDirectoryIndexer, StreamCoreIndexer } from "./StreamCoreIndexer.sol";
import { WorkFactsIndexer } from "./WorkFactsIndexer.sol";

/// @notice The real deployed stack (`DeployCore.deploy` with the committed genesis policy,
///         `IntegrationBase`) with every log recorded from before the deployment, so each
///         constructor's events are replayed, and one reference indexer per permanent contract
///         fed from those logs alone: Stream, Editions, WorkFacts, Directory, SplitLedger,
///         RevenueEscrow, ContentStore and StatementLog. `_sync` applies the logs recorded since
///         the last call, in log order across contracts (the escrow ages credits under the
///         period the Directory's logs set), then compares every indexer with its live contract.
/// @dev A suite adds indexers for contracts it deploys itself (a federated pair) in
///      `_extraIndexers`, which runs before the first `_sync`, so those contracts are replayed
///      from their deployment too. The logs are given the current block timestamp: call `_sync`
///      after each step whose time a rebuilt value records (a minter's removal, an escrow
///      credit's clock).
abstract contract ReplayBase is IntegrationBase {
    string internal constant TOPICS_PATH = "test/fixtures/real/event-topics.json";

    StreamCoreIndexer internal streamIdx;
    CoreDirectoryIndexer internal directoryIdx;
    EditionsCoreIndexer internal editionsIdx;
    WorkFactsIndexer internal factsIdx;
    LedgerIndexer internal ledgerIdx;
    EscrowIndexer internal escrowIdx;
    ContentIndexer internal contentIdx;
    StatementLogIndexer internal statementsIdx;
    ReplayIndexer[] internal indexers;
    /// @dev When false, `_sync` applies logs without comparing (a suite that plants a fault).
    bool internal compareOnSync = true;

    function setUp() public virtual override {
        vm.recordLogs();
        super.setUp();
        streamIdx = new StreamCoreIndexer(address(stream));
        directoryIdx = new CoreDirectoryIndexer(address(directory));
        editionsIdx = new EditionsCoreIndexer(address(editions), true);
        factsIdx = new WorkFactsIndexer(address(facts));
        ledgerIdx = new LedgerIndexer(address(ledger));
        escrowIdx = new EscrowIndexer(address(escrow), directoryIdx);
        contentIdx = new ContentIndexer(address(store));
        statementsIdx = new StatementLogIndexer(address(statements));
        indexers.push(streamIdx);
        indexers.push(directoryIdx);
        indexers.push(editionsIdx);
        indexers.push(factsIdx);
        indexers.push(ledgerIdx);
        indexers.push(escrowIdx);
        indexers.push(contentIdx);
        indexers.push(statementsIdx);
        _extraIndexers();
        _sync();
    }

    /// @dev Deploys what a suite replays beyond the stack and pushes its indexers.
    function _extraIndexers() internal virtual { }

    /// @dev Applies the logs recorded since the last call, then compares every indexer.
    function _sync() internal {
        _apply(vm.getRecordedLogs());
        if (!compareOnSync) return;
        for (uint256 j; j < indexers.length; ++j) {
            indexers[j].assertMatches();
        }
    }

    function _apply(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            for (uint256 j; j < indexers.length; ++j) {
                indexers[j].applyLog(logs[i], block.timestamp);
            }
        }
    }

    /// @dev The logs recorded since the last call, with the first one emitted by `emitter`
    ///      whose topic0 is `topic0` removed (a dropped log), for the negative controls.
    function _dropOne(address emitter, bytes32 topic0)
        internal
        view
        returns (Vm.Log[] memory kept)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        kept = new Vm.Log[](logs.length);
        uint256 n;
        bool dropped;
        for (uint256 i; i < logs.length; ++i) {
            if (!dropped && logs[i].emitter == emitter && logs[i].topics[0] == topic0) {
                dropped = true;
                continue;
            }
            kept[n++] = logs[i];
        }
        require(dropped, "no such log to drop");
        assembly ("memory-safe") {
            mstore(kept, n)
        }
    }

    // ------------------------------------------------------------------ WorkRules calls

    /// @dev Every party of `w`'s item signs `structHash` in the rules module's domain, in order
    ///      (`IAccounts.requireSigned` proofs: the wallet, then its signature).
    function _consents(Work memory w, bytes32 structHash)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 digest = _typedDigest(address(rules), structHash);
        sigs = new bytes[](w.item.parties.length);
        for (uint256 i; i < sigs.length; ++i) {
            address party = w.item.parties[i].account;
            sigs[i] = abi.encodePacked(party, _sign(party, digest));
        }
    }

    /// @dev The network's royalty-rate change of `tokenId` to `rate`, with every party's consent.
    function _setRoyaltyRate(uint256 tokenId, Work memory w, uint24 rate) internal {
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        uint64 deadline = uint64(block.timestamp + 60 days);
        bytes32 structHash = keccak256(
            abi.encode(
                rules.ROYALTY_RATE_TYPEHASH(), address(stream), tokenId, rate, state, deadline
            )
        );
        _asNetwork(
            address(rules),
            abi.encodeCall(
                rules.setRoyaltyRate,
                (address(stream), tokenId, rate, w.item, state, deadline, _consents(w, structHash))
            )
        );
    }

    /// @dev The network's relicense of `tokenId` to `next`, with every party's consent.
    function _relicense(uint256 tokenId, Work memory w, License memory next) internal {
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        uint64 deadline = uint64(block.timestamp + 60 days);
        bytes32 structHash = keccak256(
            abi.encode(
                rules.RELICENSE_TYPEHASH(),
                address(stream),
                tokenId,
                WorksHashing.licenseKey(next.spdxId),
                next.textFileId,
                state,
                deadline
            )
        );
        _asNetwork(
            address(rules),
            abi.encodeCall(
                rules.relicense,
                (address(stream), tokenId, next, w.item, state, deadline, _consents(w, structHash))
            )
        );
    }

    /// @dev The lead artist renounces `powers` of `tokenId`, relayed by the network (the royalty
    ///      and license powers also need the network's role).
    function _renounce(uint256 tokenId, address lead, uint16 powers) internal {
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        uint64 deadline = uint64(block.timestamp + 60 days);
        bytes32 structHash = keccak256(
            abi.encode(
                rules.RENOUNCE_POWERS_TYPEHASH(), address(stream), tokenId, powers, state, deadline
            )
        );
        bytes memory proof =
            abi.encodePacked(lead, _sign(lead, _typedDigest(address(rules), structHash)));
        _asNetwork(
            address(rules),
            abi.encodeCall(
                rules.renounce, (address(stream), tokenId, powers, state, deadline, proof)
            )
        );
    }

    /// @dev Every event in `events` (a contract's compiled ABI, `ReplayEvents`) was replayed at
    ///      least once by `idx`, except `skipped`: events the contract declares but never emits,
    ///      each named in the suite. A skipped name that is not in the ABI fails too.
    function _assertEveryEventReplayed(
        string memory name,
        ReplayIndexer idx,
        string[] memory events,
        string[] memory skipped
    ) internal view {
        uint256 used;
        for (uint256 i; i < events.length; ++i) {
            bool skip;
            for (uint256 k; k < skipped.length; ++k) {
                if (keccak256(bytes(skipped[k])) == keccak256(bytes(events[i]))) {
                    skip = true;
                    ++used;
                }
            }
            if (skip) {
                assertEq(idx.seen(keccak256(bytes(events[i]))), 0, "a skipped event was emitted");
                continue;
            }
            assertGt(
                idx.seen(keccak256(bytes(events[i]))),
                0,
                string.concat(name, ": never replayed: ", events[i])
            );
        }
        assertEq(used, skipped.length, "a skipped event is not in the ABI");
    }

    /// @dev `events` equals the list `tools/make_vectors.py` wrote for `name` into the
    ///      committed topics file, and each topic0 there is the keccak of its signature.
    function _assertTopicsFile(string memory name, string[] memory events) internal view {
        string memory json = vm.readFile(TOPICS_PATH);
        string[] memory signatures =
            vm.parseJsonStringArray(json, string.concat(".", name, ".signatures"));
        bytes32[] memory topics =
            vm.parseJsonBytes32Array(json, string.concat(".", name, ".topics"));
        assertEq(signatures.length, topics.length, string.concat(name, ": topics file"));
        assertEq(signatures.length, events.length, string.concat(name, ": event count"));
        for (uint256 i; i < signatures.length; ++i) {
            assertEq(keccak256(bytes(signatures[i])), topics[i], "topics file: topic0");
            assertEq(signatures[i], events[i], string.concat(name, ": event list"));
        }
    }

    function _none() internal pure returns (string[] memory l) {
        l = new string[](0);
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
