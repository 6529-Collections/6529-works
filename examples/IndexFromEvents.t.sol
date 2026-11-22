// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Example: rebuild 6529 Stream's state from its logs alone.
//
// An indexer reads logs (eth_getLogs, filtered by the contract addresses in the deployment
// record) and folds them into state. The permanent token emits an event for every change, and
// the events carry enough to rebuild every getter (ADR 0010). This example records the logs of
// a few works (minted, sold, delivered, one burned, one transferred again, a royalty changed),
// rebuilds them with no view call, and only at the end compares the result with the views.
// The full event catalogue is docs/integrators/events-and-indexing.md.

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Vm } from "forge-std/Vm.sol";
import { MintFacts, Outcome, Work } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { CoreFixture } from "test/mocks/core/CoreFixture.sol";

contract ExampleIndexFromEvents is CoreFixture {
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
    }

    mapping(uint256 => Indexed) internal works;
    mapping(bytes32 => uint256) internal tokenOfContent;
    uint256 internal supply;

    function test_RebuildStreamFromItsLogs() public {
        // The chain's side. Every log is recorded.
        vm.recordLogs();
        uint256 sold = _sell(1, collector); // minted, sold for 1 ether, delivered
        uint256 burned = _mint(2); // minted into custody, then burned (a cancelled sale)
        sale.burn(address(stream), burned);
        uint256 again = _mint(2); // the burned token's content minted again
        address next = makeAddr("next owner");
        vm.prank(collector);
        stream.transferFrom(collector, next, sold);
        terms.setRoyalty(address(stream), again, address(0xBEEF), 5000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The indexer's side: fold the logs, in order, by emitter and topic0.
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(stream)) _fold(logs[i]);
        }

        // The rebuilt state equals the views.
        uint256[2] memory live = [sold, again];
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
        }
        assertEq(works[sold].price, 1 ether, "the price comes from the log alone");
        assertEq(works[burned].owner, address(0), "burned");
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
                owner: works[id].owner // the mint's Transfer comes first
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
}
