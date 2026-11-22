// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Example: rebuild 6529 Stream's state from its logs alone.
//
// An indexer reads logs (eth_getLogs, filtered by the contract addresses in the deployment
// record) and folds them into state. The permanent token emits an event for every change, and
// the events carry enough to rebuild every getter (ADR 0010). This example records the logs of
// a few works on the deployed stack (one sold and delivered, then transferred again; one
// unsold and sent to the museum; the first one's record finalized in WorkFacts), rebuilds them
// with no view call, and only at the end compares the result with the views. The full event
// catalogue is docs/integrators/events-and-indexing.md.

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Vm } from "forge-std/Vm.sol";
import { Facts, MintFacts, Outcome, Work } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { IWorkRules } from "src/interfaces/core/IWorkRules.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { ExampleBase } from "./ExampleBase.sol";

contract ExampleIndexFromEvents is ExampleBase {
    /// What the indexer keeps for one work.
    struct Indexed {
        bool minted;
        uint256 artistId;
        bytes32 itemHash;
        bytes32 contentHash;
        address royaltyReceiver;
        uint24 royaltyRate;
        Outcome outcome;
        uint256 price; // logged only: no getter has it
        address owner;
        // From WorkFacts: the record.
        bool opened;
        bytes32 recordFileId;
        uint256 mediaCount;
        bool finalized;
        address renderer;
    }

    address internal collector = makeAddr("collector");

    mapping(uint256 => Indexed) internal works;
    mapping(bytes32 => uint256) internal tokenOfContent;
    uint256 internal supply;

    function test_RebuildStreamFromItsLogs() public {
        // The chain's side. Every log is recorded.
        vm.recordLogs();
        uint256 sold = _sell(_original(), collector, 1 ether); // sold for 1 ether, delivered
        (uint256 unsoldSale, uint256 unsold) = _start(_original());
        _settleAtEnd(unsoldSale); // no bid: the museum receives it
        address next = makeAddr("next owner");
        vm.prank(collector);
        stream.transferFrom(collector, next, sold);
        IWorkRules rules = IWorkRules(d.workRules);
        bytes32 state = rules.workStateHash(address(stream), sold);
        vm.prank(artist);
        rules.finalize(address(stream), sold, state);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The indexer's side: fold the logs, in order, by emitter and topic0.
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(stream)) _fold(logs[i]);
            if (logs[i].emitter == address(facts)) _foldFacts(logs[i]);
        }

        // The rebuilt state equals the views.
        uint256[2] memory live = [sold, unsold];
        for (uint256 j; j < live.length; ++j) {
            uint256 id = live[j];
            Work memory work = stream.workOf(id);
            assertEq(works[id].owner, stream.ownerOf(id));
            assertEq(works[id].artistId, work.artistId);
            assertEq(works[id].itemHash, work.itemHash);
            assertEq(works[id].royaltyReceiver, work.royaltyReceiver);
            assertEq(works[id].royaltyRate, work.royaltyRate);
            assertEq(uint8(works[id].outcome), uint8(work.outcome));
            assertEq(
                tokenOfContent[works[id].contentHash], stream.tokenOfContent(works[id].contentHash)
            );
            Facts memory f = facts.factsOf(address(stream), id);
            assertEq(works[id].opened, f.opened);
            assertEq(works[id].recordFileId, f.recordFileId);
            assertEq(works[id].mediaCount, f.media.length);
            assertEq(works[id].finalized, f.finalized);
            assertEq(works[id].renderer, f.renderer);
        }
        assertEq(works[sold].price, 1 ether, "the price comes from the log alone");
        assertEq(uint8(works[unsold].outcome), uint8(Outcome.UNSOLD));
        assertTrue(works[sold].finalized && !works[unsold].finalized);
        assertEq(supply, stream.totalSupply());
    }

    function _fold(Vm.Log memory log) internal {
        bytes32 t0 = log.topics[0];
        if (t0 == IStream.WorkMinted.selector) {
            // tokenId, collectionId, artistId indexed; minter, serial and the facts in data.
            uint256 id = uint256(log.topics[1]);
            (,, MintFacts memory f) = abi.decode(log.data, (address, uint32, MintFacts));
            works[id] = Indexed({
                minted: true,
                artistId: uint256(log.topics[3]),
                itemHash: f.itemHash,
                contentHash: f.contentHash,
                royaltyReceiver: f.royaltyReceiver,
                royaltyRate: f.royaltyRate,
                outcome: Outcome.NONE,
                price: 0,
                owner: works[id].owner, // the mint's Transfer comes first
                opened: false,
                recordFileId: bytes32(0),
                mediaCount: 0,
                finalized: false,
                renderer: address(0)
            });
            tokenOfContent[f.contentHash] = id; // the newest token of a content wins
        } else if (t0 == IERC721.Transfer.selector) {
            address from = address(uint160(uint256(log.topics[1])));
            address to = address(uint160(uint256(log.topics[2])));
            uint256 id = uint256(log.topics[3]);
            works[id].owner = to;
            if (from == address(0)) supply += 1;
            if (to == address(0)) supply -= 1; // a burn keeps tokenOfContent naming the token
        } else if (t0 == IStream.PrimarySale.selector) {
            (Outcome outcome, uint256 price) = abi.decode(log.data, (Outcome, uint256));
            works[uint256(log.topics[1])].outcome = outcome;
            works[uint256(log.topics[1])].price = price;
        } else if (t0 == IStream.RoyaltySet.selector) {
            (address receiver, uint24 rate) = abi.decode(log.data, (address, uint24));
            works[uint256(log.topics[1])].royaltyReceiver = receiver;
            works[uint256(log.topics[1])].royaltyRate = rate;
        }
    }

    /// @dev WorkFacts' events for Stream's works: the record opened (with the whole item and
    ///      media list), and finalized with the renderer it pins.
    function _foldFacts(Vm.Log memory log) internal {
        if (address(uint160(uint256(log.topics[1]))) != address(stream)) return;
        uint256 id = uint256(log.topics[2]);
        bytes32 t0 = log.topics[0];
        if (t0 == IWorkFacts.RecordOpened.selector) {
            (PackageItem memory item, MediaFile[] memory media) =
                abi.decode(log.data, (PackageItem, MediaFile[]));
            works[id].opened = true;
            works[id].recordFileId = item.recordFileId;
            works[id].mediaCount = media.length;
        } else if (t0 == IWorkFacts.RecordSet.selector) {
            works[id].recordFileId = abi.decode(log.data, (bytes32));
        } else if (t0 == IWorkFacts.Finalized.selector) {
            (address renderer,) = abi.decode(log.data, (address, bytes32));
            works[id].finalized = true;
            works[id].renderer = renderer;
        } else if (t0 == IWorkFacts.RendererRepinned.selector) {
            (address renderer,) = abi.decode(log.data, (address, bytes32));
            works[id].renderer = renderer;
        }
    }
}
