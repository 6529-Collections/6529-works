// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Example: bid in an edition sale and claim the copies or the refund.
//
// An EDITION_MASTER work sells its 1/1 by English auction and, beside it, copies of its edition
// by a uniform-price auction that closes 15 minutes after the 1/1. Bidders name a price step
// and a quantity and pay the full escrow up front; bids are firm. At the close one price is
// found for every winner; each bid then claims its copies and gets back the rest.

import { IUniformEditionAuction as IEA } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { EditionAuctionStack } from "test/integration/EditionAuctionStack.sol";

contract ExampleEditionSale is EditionAuctionStack {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    bytes32 internal root; // the package root; the master item is kept under it
    uint256 internal oneSaleId; // the 1/1's English auction
    uint256 internal tokenId; // the master's token ID, which is also the edition ID
    uint256 internal saleId; // the edition sale
    uint256 internal aliceBid;
    uint256 internal bobBid;

    function setUp() public override {
        super.setUp();
        // The master's 1/1 starts and the keeper opens the edition sale in the same batch:
        // open(editions, tokenId, abi.encode(item, packageRoot, proof)).
        Work memory master;
        (root, master, oneSaleId, tokenId, saleId) = _startMaster(_actor("artist"), 0);
        _keep(root, _one(master));
    }

    function test_BidClaimCopiesAndRefunds() public {
        // The sale ID is derived, so a client can compute it before the sale opens.
        assertEq(saleId, ea.saleIdOf(address(editions), tokenId));
        _bid();
        _closeAndSettle();
        _claim();
    }

    function _bid() internal {
        // 1. Bids name a step on a fixed price ladder; pay quantity x stepPrice exactly.
        uint256 escrow = 3 * ea.stepPrice(saleId, 20);
        vm.deal(alice, escrow);
        vm.prank(alice);
        aliceBid = ea.bid{ value: escrow }(saleId, 20, 3);

        // Before bidding, `quote` says what a new bid would win if the sale closed now.
        IEA.Quote memory q = ea.quote(saleId, 2, 1);
        vm.deal(bob, q.escrow);
        vm.prank(bob);
        bobBid = ea.bid{ value: q.escrow }(saleId, 2, 1);

        // 2. What to show now: the result if the sale closed now, and each bid's outcome.
        assertGt(ea.clearing(saleId).count, 0);
        assertFalse(ea.bidOutcome(saleId, aliceBid).isFinal);

        // 3. The close follows the 1/1: its end plus 15 minutes, later if late edition bids
        //    extend it. Show `endTimes(saleId).endTime`.
        IEA.EndTimes memory e = ea.endTimes(saleId);
        assertEq(e.closeAt, e.oneOfOneEnd + 15 minutes);
    }

    function _closeAndSettle() internal {
        // 4. The keeper's steps: settle the 1/1 at its end (nobody bid on it here, so it goes
        //    to the museum), create the edition (needed before a sale with winners settles),
        //    then, after the close, settle the edition sale, calling until it returns true,
        //    each time with the keeper's own remaining settlement order.
        vm.warp(auction.auction(oneSaleId).endTime);
        auction.settle(oneSaleId);
        editions.createEdition(tokenId, _package(root)[0].item);
        vm.warp(ea.endTimes(saleId).endTime);
        IUniformEditionAuctionLens lens = IUniformEditionAuctionLens(address(editionAuction));
        vm.startPrank(keeper);
        while (!ea.settle(saleId, lens.settlementOrderFor(saleId, keeper))) { }
        vm.stopPrank();
    }

    function _claim() internal {
        IEA.Settlement memory s = ea.settlement(saleId);

        // 5. Alice claims her own bid: her copies and her refund go to the address she names.
        //    Every winner pays the one clearing price.
        IEA.BidOutcome memory o = ea.bidOutcome(saleId, aliceBid);
        assertTrue(o.isFinal);
        vm.prank(alice);
        (uint256 won, uint256 refund) = ea.claimBid(saleId, aliceBid, alice);
        assertEq(won, o.unitsWon);
        assertEq(refund, o.escrow - won * s.price);
        assertEq(editions.balanceOf(alice, tokenId), won);

        // 6. Anyone may push a claim for a bidder: copies go to the bidder, the refund is
        //    credited to its `claimable` ETH, which it then claims.
        vm.prank(keeper);
        (uint256 bobWon, uint256 bobRefund) = ea.claimBidFor(saleId, bobBid);
        assertEq(editions.balanceOf(bob, tokenId), bobWon);
        assertEq(ea.claimable(bob, address(0)), bobRefund);
        if (bobRefund != 0) {
            vm.prank(bob);
            ea.claim(address(0), bob);
        }
        assertEq(editions.edition(tokenId).minted, s.count, "every winning copy is minted");
    }
}
