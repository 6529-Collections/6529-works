// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IContentStore } from "src/interfaces/IContentStore.sol";
import { WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { MockRenderer } from "../mocks/core/CoreMocks.sol";
import { ReplayBase } from "./ReplayBase.sol";
import { ReplayEvents } from "./ReplayEvents.sol";

/// @notice Log replay of `WorkFacts` on the deployed stack: every record, rebuilt from the
///         contract's logs alone, equals `factsOf` after each step of a history that emits each
///         of its events through the real modules (records opened by anyone, a work found
///         complete on-chain, the artist's record change, the network's relicense with every
///         party's consent, the license and repin powers renounced, the artist's finalize, a
///         finalize by anyone after the notice, and the network's repin).
contract LogReplayWorkFactsTest is ReplayBase {
    address internal artist;
    address internal buyer = makeAddr("factsBuyer");
    bytes32 internal root;
    bytes32 internal ccByText;
    bytes32 internal mitText;

    function setUp() public override {
        super.setUp();
        artist = _actor("factsArtist");
        ccByText = _storeText("Creative Commons Attribution 4.0 (replay fixture)", "text/plain");
        mitText = _storeText("MIT License (replay fixture)", "text/plain");
        bytes memory media = _bytes(store.CHUNK_SIZE() + 50, 7);
        Work[] memory works = new Work[](2);
        works[0] = _storedWork(
            artist, media, IContentStore.Encoding.Identity, sha256(media), "Facts replay 0"
        );
        works[0].item.license = License("CC-BY-4.0", ccByText);
        works[1] = _work(artist, collectionId);
        root = _publish(works);
        _keep(root, works);
        _sync();
    }

    function test_WorkFacts_EveryEventReplaysToTheSameState() public {
        Work[] memory works = _package(root);
        uint256 a = _sell(root, works, 0, buyer, 1 ether);
        uint256 b = _sell(root, works, 1, buyer, 1 ether);
        // Anyone opens the records; the uploaded work is found complete on-chain.
        _open(a, works[0]);
        _open(b, works[1]);
        facts.markOnChainComplete(address(stream), a);
        _sync();

        // The artist changes the record; the network relicenses with every party's consent; the
        // artist renounces the license power.
        bytes32 next = _record("Facts replay 0, second record");
        bytes32 state = rules.workStateHash(address(stream), a);
        vm.prank(artist);
        rules.setRecord(address(stream), a, next, state);
        _sync();
        _relicense(a, works[0], License("MIT", mitText));
        _sync();
        _renounce(a, artist, WorkPowers.RELICENSE);
        _sync();

        // Finalized by the artist, repinned by the network, the repin power renounced.
        state = rules.workStateHash(address(stream), a);
        vm.prank(artist);
        rules.finalize(address(stream), a, state);
        _sync();
        MockRenderer errata = new MockRenderer();
        state = rules.workStateHash(address(stream), a);
        _asNetwork(
            address(rules),
            abi.encodeCall(rules.repinRenderer, (address(stream), a, address(errata), state))
        );
        _sync();
        _renounce(a, artist, WorkPowers.RENDERER_REPIN);
        _sync();

        // Anyone finalizes the other work once the notice has run.
        vm.prank(buyer);
        rules.finalize(address(stream), b, bytes32(0));
        skip(FINALIZE_NOTICE);
        vm.prank(buyer);
        rules.finalize(address(stream), b, bytes32(0));
        _sync();

        assertTrue(facts.factsOf(address(stream), a).licenseLocked);
        assertTrue(facts.factsOf(address(stream), a).repinLocked);
        assertEq(facts.factsOf(address(stream), a).renderer, address(errata));
        assertTrue(facts.factsOf(address(stream), b).finalized);
        _assertEveryEventReplayed("WorkFacts", factsIdx, ReplayEvents.workFacts(), _none());
    }

    // ------------------------------------------------------------------ negative controls

    /// @dev Slot 0 holds the records: a record file no `RecordSet` logged.
    function test_WorkFacts_ReplayFailsOnStateNoLogExplains() public {
        Work[] memory works = _package(root);
        uint256 a = _sell(root, works, 0, buyer, 1 ether);
        _open(a, works[0]);
        _sync();
        bytes32 slot = keccak256(abi.encode(a, keccak256(abi.encode(address(stream), uint256(0)))));
        vm.store(address(facts), slot, keccak256("a record no log names"));
        vm.expectRevert();
        factsIdx.assertMatches();
    }

    /// @dev A record change whose `RecordSet` log is dropped: the rebuilt record is stale.
    function test_WorkFacts_ReplayFailsOnADroppedLog() public {
        Work[] memory works = _package(root);
        uint256 a = _sell(root, works, 0, buyer, 1 ether);
        _open(a, works[0]);
        _sync();
        bytes32 next = _record("Facts replay 0, dropped record");
        bytes32 state = rules.workStateHash(address(stream), a);
        vm.prank(artist);
        rules.setRecord(address(stream), a, next, state);
        _apply(_dropOne(address(facts), IWorkFacts.RecordSet.selector));
        vm.expectRevert();
        factsIdx.assertMatches();
    }
}
