// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice LIFECYCLE-1 regression, on the real stack: a dispute pause keeps the market it
///         interrupted. A bid withdrawn while paused stays as a reserve the next bid must reach,
///         and the resumed auction runs at least the governed duration, whether the pause lapses
///         or UNPAUSER resumes it, so the refunded bidders can return.
contract Lifecycle1RegressionTest is IntegrationBase {
    address internal artist;
    address internal alice = makeAddr("aliceBidder");
    address internal mallory = makeAddr("malloryBidder");

    function setUp() public override {
        super.setUp();
        artist = _actor("rightfulArtist");
    }

    function _startOne() internal returns (uint256 saleId, uint256 tokenId) {
        Work memory w = _work(artist, collectionId);
        bytes32 root = _publish(_one(w));
        (saleId, tokenId) = _start(root, _one(w), 0);
    }

    function _expectBidTooLow(uint256 saleId, address who, uint256 amount, uint256 required)
        internal
    {
        vm.deal(who, amount);
        vm.prank(who);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, required, amount)
        );
        auction.bid{ value: amount }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, who, amount, 0, 0, "")
        );
    }

    function test_LIFECYCLE1_WithdrawnBidStaysAsReserveThroughALapse() public {
        (uint256 saleId, uint256 tokenId) = _startOne();
        _ethBid(saleId, alice, 1 ether);
        _ethBid(saleId, mallory, 2 ether);
        vm.warp(auction.auction(saleId).endTime - 5 minutes);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        uint256 pausedAt = block.timestamp;
        vm.expectEmit(address(auction));
        emit IEnglishAuction.BidWithdrawn(saleId, mallory, 2 ether);
        vm.prank(mallory);
        auction.withdrawBid(saleId);
        assertEq(auction.minimumBid(saleId), 2 ether, "the withdrawn bid is the reserve");
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.bidder, address(0));
        assertEq(a.bid, 2 ether);

        // The pause lapses: the auction gets the full governed duration back.
        vm.warp(pausedAt + auction.MAX_PAUSE() + 1);
        a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(a.endTime, pausedAt + auction.MAX_PAUSE() + AUCTION_DURATION);
        _expectBidTooLow(saleId, mallory, 1, 2 ether);

        // Nobody meets the reserve: the work returns to the artist and nothing is paid.
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), artist);
        assertEq(auction.claimable(mallory, CURRENCY_ETH), 2 ether);
        assertEq(auction.claimable(alice, CURRENCY_ETH), 1 ether);
        assertEq(address(auction).balance, 3 ether, "the auction holds exactly the credits");
    }

    function test_LIFECYCLE1_RejectedDisputeResumesWithTheReserveAndTheDuration() public {
        (uint256 saleId, uint256 tokenId) = _startOne();
        _ethBid(saleId, makeAddr("earlyBidder"), 3 ether);
        address honest = makeAddr("honestHighBidder");
        _ethBid(saleId, honest, 5 ether);
        vm.warp(auction.auction(saleId).endTime - 10 minutes);
        vm.prank(guardian2);
        auction.pause(saleId, keccak256("genuine dispute"));
        vm.prank(honest);
        auction.withdrawBid(saleId);

        // UNPAUSER resumes after its 48 hours.
        bytes memory resume = abi.encodeCall(auction.resume, (saleId));
        _schedule(hotAdmin, address(auction), resume);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(saleId, uint64(block.timestamp + AUCTION_DURATION));
        vm.prank(hotAdmin);
        manager.execute(address(auction), resume);
        assertEq(auction.auction(saleId).endTime, block.timestamp + AUCTION_DURATION);
        assertEq(auction.minimumBid(saleId), 5 ether);
        _expectBidTooLow(saleId, makeAddr("sniper"), 1, 5 ether);

        // The honest bidder returns at the reserve and wins at the price it had reached.
        vm.prank(honest);
        auction.claim(CURRENCY_ETH, honest);
        _ethBid(saleId, honest, 5 ether);
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), honest);
    }

    function test_LIFECYCLE1_PauseWithoutAWithdrawalKeepsTheWindowRule() public {
        (uint256 saleId,) = _startOne();
        _ethBid(saleId, alice, 1 ether);
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - 5 minutes);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
        uint256 pausedAt = block.timestamp;
        vm.warp(pausedAt + auction.MAX_PAUSE() + 1);
        assertEq(
            auction.auction(saleId).endTime,
            pausedAt + auction.MAX_PAUSE() + EXTENSION_WINDOW,
            "a standing bid needs no more than the anti-snipe window"
        );
        assertEq(auction.minimumBid(saleId), 1 ether + 0.05 ether);
        // An unpaused auction never had a reserve: the opening bid applies.
        (uint256 fresh,) = _startOne();
        assertEq(auction.minimumBid(fresh), 1);
    }
}
