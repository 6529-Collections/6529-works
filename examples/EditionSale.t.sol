// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Example: bid in an edition sale and claim the copies or the refund.
//
// An EDITION_MASTER work sells its 1/1 by English auction and, beside it, copies of its edition
// by a uniform-price auction that closes 15 minutes after the 1/1. Anyone opens the edition sale
// once the 1/1 has started (this also creates the edition in 6529 Stream Editions). Bidders name
// a price step and a quantity and pay the full escrow up front; bids are firm. At the close one
// price is found for every winner; each bid then claims its copies and gets back the rest.

import { IUniformEditionAuction as IEA } from "src/interfaces/IUniformEditionAuction.sol";
import { ExampleBase } from "./ExampleBase.sol";

contract ExampleEditionSale is ExampleBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    uint256 internal oneSaleId; // the 1/1's English auction
    uint256 internal tokenId; // the master's token ID, which is also the edition ID
    uint256 internal saleId; // the edition sale
    uint256 internal aliceBid;
    uint256 internal bobBid;

    function setUp() public override {
        super.setUp();
        // The master's 1/1 starts, and the keeper opens the edition sale in the same batch:
        // open(editions, tokenId, abi.encode(item, packageRoot, proof)).
        Package memory master = _master(100);
        (oneSaleId, tokenId) = _start(master);
        vm.prank(keeper);
        saleId = editionAuction.open(
            address(editions), tokenId, abi.encode(master.item, master.root, new bytes32[](0))
        );
    }

    function test_BidClaimCopiesAndRefunds() public {
        // The sale ID is derived, so a client can compute it before the sale opens.
        assertEq(saleId, editionAuction.saleIdOf(address(editions), tokenId));
        assertEq(editions.editionOf(tokenId).minted, 0, "the edition exists, with no copies yet");
        _bid();
        _closeAndSettle();
        _claim();
    }

    function _bid() internal {
        // 1. Bids name a step on a fixed price ladder; pay quantity x stepPrice exactly.
        uint256 escrow = 3 * editionAuction.stepPrice(saleId, 20);
        vm.deal(alice, escrow);
        vm.prank(alice);
        aliceBid = editionAuction.bid{ value: escrow }(saleId, 20, 3);

        // Before bidding, `quote` says what a new bid would win if the sale closed now.
        IEA.Quote memory q = editionAuction.quote(saleId, 2, 1);
        vm.deal(bob, q.escrow);
        vm.prank(bob);
        bobBid = editionAuction.bid{ value: q.escrow }(saleId, 2, 1);

        // 2. What to show now: the result if the sale closed now, and each bid's outcome.
        assertGt(editionAuction.clearing(saleId).count, 0);
        assertFalse(editionAuction.bidOutcome(saleId, aliceBid).isFinal);

        // 3. The close follows the 1/1: its end plus 15 minutes, later if late edition bids
        //    extend it. Show `endTimes(saleId).endTime`.
        IEA.EndTimes memory e = editionAuction.endTimes(saleId);
        assertEq(e.closeAt, e.oneOfOneEnd + 15 minutes);
    }

    function _closeAndSettle() internal {
        // 4. The keeper's steps: settle the 1/1 at its end (nobody bid on it here, so it goes
        //    to the museum), then, after the close, settle the edition sale, calling until it
        //    returns true. The order is the keeper's own remaining settlement order (empty when
        //    the cap does not ration the clearing step).
        _settleAtEnd(oneSaleId);
        vm.warp(editionAuction.endTimes(saleId).endTime + 1);
        vm.startPrank(keeper);
        while (!editionAuction.settle(saleId, editionAuction.settlementOrder(saleId))) { }
        vm.stopPrank();
    }

    function _claim() internal {
        IEA.Settlement memory s = editionAuction.settlement(saleId);

        // 5. Alice claims her own bid: her copies and her refund go to the address she names.
        //    Every winner pays the one clearing price.
        IEA.BidOutcome memory o = editionAuction.bidOutcome(saleId, aliceBid);
        assertTrue(o.isFinal);
        vm.prank(alice);
        (uint256 won, uint256 refund) = editionAuction.claimBid(saleId, aliceBid, alice);
        assertEq(won, o.unitsWon);
        assertEq(refund, o.escrow - won * s.price);
        assertEq(editions.balanceOf(alice, tokenId), won);

        // 6. Anyone may push a claim for a bidder: copies go to the bidder, the refund is
        //    credited to its `claimable` ETH, which it then claims.
        vm.prank(keeper);
        (uint256 bobWon, uint256 bobRefund) = editionAuction.claimBidFor(saleId, bobBid);
        assertEq(editions.balanceOf(bob, tokenId), bobWon);
        assertEq(editionAuction.claimable(bob, address(0)), bobRefund);
        if (bobRefund != 0) {
            vm.prank(bob);
            editionAuction.claim(address(0), bob);
        }
        assertEq(editions.editionOf(tokenId).minted, s.count, "every winning copy is minted");
    }
}
