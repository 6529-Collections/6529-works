// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Example: rebuild one work's life from its logs alone.
//
// An indexer reads logs (eth_getLogs, filtered by the contract addresses in the deployment
// record) and folds them into state. This example records every log of a whole sale, then
// rebuilds the work from the logs with no view call, and only at the end compares the result
// with the contracts' views. The full event catalogue is docs/integrators/events-and-indexing.md.

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Vm } from "forge-std/Vm.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { IntegrationBase } from "test/integration/IntegrationBase.sol";

contract ExampleIndexFromEvents is IntegrationBase {
    /// What the indexer keeps for one work.
    struct Indexed {
        uint256 tokenId;
        uint256 artistId;
        bytes32 itemHash;
        address seller; // the seller split wallet
        bool recordOpened;
        uint256 saleId;
        uint64 endTime; // the latest end: SaleStarted, then each BidPlaced
        uint256 bids;
        address highBidder;
        uint256 highBid;
        uint256 credited; // outbid refunds credited, not yet claimed
        bool settled;
        uint256 price;
        uint256 fee;
        address owner;
    }

    function test_RebuildAWorkFromItsLogs() public {
        // The chain's side: a sale with two bidders, settled. Every log is recorded.
        vm.recordLogs();
        Work[] memory works = _one(_work(_actor("artist"), collectionId));
        (uint256 saleId, uint256 tokenId) = _start(_publish(works), works, 0);
        records.openRecord(tokenId, works[0].item, works[0].media);
        _ethBid(saleId, makeAddr("first"), 1 ether);
        _ethBid(saleId, makeAddr("second"), 2 ether);
        _settleAtEnd(saleId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The indexer's side: fold the logs, in order, by emitter and topic0.
        Indexed memory x;
        for (uint256 i; i < logs.length; ++i) {
            _fold(x, logs[i]);
        }

        // Only now compare with the views.
        assertEq(x.tokenId, tokenId);
        assertEq(x.saleId, saleId);
        assertEq(x.owner, stream.ownerOf(tokenId));
        assertEq(x.itemHash, stream.consumedItemOf(works[0].item.contentHash));
        assertEq(x.seller, stream.primaryTerms(tokenId, "").seller);
        assertTrue(x.recordOpened && records.isOpen(tokenId));
        assertEq(x.bids, 2);
        assertEq(x.highBidder, makeAddr("second"));
        assertEq(x.price, 2 ether);
        assertEq(x.credited, auction.claimable(makeAddr("first"), address(0)));
        assertTrue(x.settled);
        assertEq(x.endTime, auction.auction(saleId).endTime);
    }

    function _fold(Indexed memory x, Vm.Log memory log) internal view {
        bytes32 topic = log.topics[0];
        if (log.emitter == address(stream)) {
            if (topic == IStream.WorkMinted.selector) {
                x.tokenId = uint256(log.topics[1]);
                x.artistId = uint256(log.topics[3]);
                // Non-indexed fields, in declaration order.
                (x.itemHash,,,,,,, x.seller,) = abi.decode(
                    log.data,
                    (bytes32, uint64, uint8, bytes32, bytes32, bytes32, bytes32, address, uint24)
                );
            } else if (topic == IERC721.Transfer.selector && uint256(log.topics[3]) == x.tokenId) {
                x.owner = address(uint160(uint256(log.topics[2])));
            }
        } else if (log.emitter == address(records)) {
            if (topic == IWorkRecords.RecordOpened.selector) x.recordOpened = true;
        } else if (log.emitter == address(auction)) {
            if (topic == ISaleAdapter.SaleStarted.selector && uint256(log.topics[3]) == x.tokenId) {
                x.saleId = uint256(log.topics[1]);
                (,,,, x.endTime) = abi.decode(log.data, (bytes32, address, uint256, uint64, uint64));
            } else if (
                topic == IEnglishAuction.BidPlaced.selector && uint256(log.topics[1]) == x.saleId
            ) {
                ++x.bids;
                x.highBidder = address(uint160(uint256(log.topics[2])));
                (, x.highBid, x.endTime) = abi.decode(log.data, (address, uint256, uint64));
            } else if (
                topic == ISaleAdapter.Credited.selector && uint256(log.topics[3]) == x.saleId
            ) {
                x.credited += abi.decode(log.data, (uint256));
            } else if (
                topic == ISaleAdapter.SaleSettled.selector && uint256(log.topics[1]) == x.saleId
            ) {
                x.settled = true;
                (,,,, x.price,,,, x.fee) = abi.decode(
                    log.data,
                    (
                        address,
                        address,
                        uint256,
                        address,
                        uint256,
                        address,
                        uint256,
                        address,
                        uint256
                    )
                );
            }
        }
    }
}
