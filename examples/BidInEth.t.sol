// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

// Example: watch a 1/1 sale and bid on it in ETH.
//
// What a bidding front end needs: the minimum bid, the end time and how a late bid extends it,
// what happens to an outbid bid (it becomes a credit, never pushed back), and how to claim that
// credit. Sales are in ETH only.

import { Vm } from "forge-std/Vm.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { ExampleBase } from "./ExampleBase.sol";

contract ExampleBidInEth is ExampleBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal saleId;

    function setUp() public override {
        super.setUp();
        (saleId,) = _start(_original());
    }

    function test_BidOutbidAndClaimTheCredit() public {
        // 1. The state of the sale.
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(a.bidder, address(0), "no bid yet");

        // 2. The first bid must reach the opening bid (0.05 ETH at genesis, a network setting
        //    in the asset allowlist); read minimumBid right before sending.
        uint256 first = auction.minimumBid(saleId);
        assertEq(first, AssetAllowlist(d.assetAllowlist).openingBid(address(0)));
        _bid(saleId, alice, first);

        // 3. The next bid must beat the high bid by the increment: 5% at genesis, and at least
        //    the increment floor (0.001 ETH here).
        uint256 next = auction.minimumBid(saleId);
        assertGt(next, first);
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, next, next - 1));
        auction.bid{ value: next - 1 }(saleId, address(0));

        // 4. A bid in the last 15 minutes moves the end to 15 minutes after the bid
        //    (anti-snipe). BidPlaced carries the new end, so an indexer needs no extra read.
        uint64 end = auction.auction(saleId).endTime;
        vm.warp(end - 60);
        vm.recordLogs();
        _bid(saleId, bob, next);
        uint64 newEnd = auction.auction(saleId).endTime;
        assertEq(newEnd, block.timestamp + auction.config().extensionWindow);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IEnglishAuction.BidPlaced.selector) continue;
            (address recipient, uint256 amount, uint64 endTime) =
                abi.decode(logs[i].data, (address, uint256, uint64));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), bob);
            assertEq(recipient, bob, "a zero recipient means the bidder");
            assertEq(amount, next);
            assertEq(endTime, newEnd);
            seen = true;
        }
        assertTrue(seen);

        // 5. Alice was outbid: her bid is now a credit in the auction (Credited), never pushed
        //    back. She claims it to any address. A credit left unclaimed for the network's
        //    unclaimed period (Directory.unclaimedPeriod) may be sent to the network by anyone;
        //    `expiresAt` says when the oldest part can go.
        assertEq(auction.claimable(alice), first);
        assertEq(auction.expiresAt(alice), block.timestamp + directory.unclaimedPeriod());
        uint256 before = alice.balance;
        vm.prank(alice);
        auction.claim(alice);
        assertEq(alice.balance - before, first);
        assertEq(auction.claimable(alice), 0);
    }
}
