// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Example: watch a 1/1 sale and bid on it in ETH.
//
// What a bidding front end needs: the minimum bid, the end time and how a late bid extends
// it, what happens to an outbid bid (it becomes a credit, never pushed back), and how to
// claim that credit.

import { Vm } from "forge-std/Vm.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { IntegrationBase } from "test/integration/IntegrationBase.sol";

contract ExampleBidInEth is IntegrationBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal saleId;

    function setUp() public override {
        super.setUp();
        Work[] memory works = _one(_work(_actor("artist"), collectionId));
        (saleId,) = _start(_publish(works), works, 0);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    /// A DIRECT ETH payment: the payer is the caller and `msg.value` equals the amount.
    function _bid(address bidder, uint256 amount) internal {
        Payment memory pay = Payment(PaymentMethod.DIRECT, bidder, amount, 0, 0, "");
        vm.prank(bidder);
        // recipient zero: the token goes to the payer if this bid wins.
        auction.bid{ value: amount }(saleId, address(0), pay);
    }

    function test_BidOutbidAndClaimTheCredit() public {
        // 1. The state of the sale. `auction(saleId)` is answered by the auction's lens through
        //    the auction's address: call the auction, never the lens itself.
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(a.currency, address(0), "ETH");

        // 2. The first bid must reach the opening bid; read minimumBid right before sending.
        uint256 first = auction.minimumBid(saleId);
        assertEq(first, auction.openingBid(address(0)));
        _bid(alice, first);

        // 3. The next bid must beat the high bid by the increment: 5% at launch, and at least
        //    the currency's increment floor (0.001 ETH here).
        uint256 next = auction.minimumBid(saleId);
        assertGt(next, first);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, next, next - 1));
        _bid(bob, next - 1);

        // 4. A bid in the last 15 minutes moves the end to 15 minutes after the bid
        //    (anti-snipe). BidPlaced carries the new end, so an indexer needs no extra read.
        uint64 end = auction.auction(saleId).endTime;
        vm.warp(end - 60);
        vm.recordLogs();
        _bid(bob, next);
        uint64 newEnd = auction.auction(saleId).endTime;
        assertEq(newEnd, block.timestamp + auction.config().extensionWindow);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // 5. Alice was outbid: her bid is credited to her, in the same transaction, just
        //    before Bob's BidPlaced. Nothing is sent to her yet.
        assertEq(logs[0].topics[0], ISaleAdapter.Credited.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), alice);
        assertEq(logs[1].topics[0], IEnglishAuction.BidPlaced.selector);
        assertEq(auction.claimable(alice, address(0)), first);

        // 6. Alice claims the credit to any address she names (ETH is currency zero).
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 amount = auction.claim(address(0), alice);
        assertEq(amount, first);
        assertEq(alice.balance - before, first);
        assertEq(auction.claimable(alice, address(0)), 0);

        // 7. A bid at or after the end reverts; the sale is ENDED (derived from the clock, no
        //    transaction ends it) and waits for anyone's `settle`.
        vm.warp(newEnd);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ENDED));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ENDED
            )
        );
        _bid(alice, 5 ether);
    }

    // A credit left unclaimed for 180 days can be sent to the network fee recipient by anyone
    // (`expireCredit`); `creditExpiresAt` on the auction tells when. Claim credits promptly.
}
