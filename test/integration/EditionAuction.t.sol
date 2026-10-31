// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";

/// @notice The edition auction end to end on the real stack (D138-D141): a master's 1/1 and its
///         edition sale side by side, the 1/1 settling, the edition created, the edition sale
///         settled and every bid claimed on 6529 Stream Editions; the cap with FIFO and a hole;
///         the 1/1's anti-snipe moving the edition close; a dispute pause opening withdrawals and
///         an upheld dispute voiding the sale; editions selling without 1/1 bids; no edition bids.
contract EditionAuctionIntegrationTest is EditionAuctionStack {
    address internal artist;
    address internal collector = makeAddr("oneOfOneCollector");

    function setUp() public override {
        super.setUp();
        artist = _actor("masterArtist");
    }

    /// @dev PLAN appendix C, trace 2, on the real stack: 80 editions at 0.0511 ETH, 4.088 ETH
    ///      raised, 1.022 ETH to the network; every bid claimed, exactly 80 minted.
    function test_Flow_D138WorkedExample() public {
        (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(artist, 0);
        assertEq(saleId, editionAuction.saleIdOf(address(editions), tokenId));
        address[5] memory bidders = _traceTwoBids(saleId);
        _ethBid(oneSaleId, collector, 1 ether);
        IUniformEditionAuction.Clearing memory c = ea.clearing(saleId);
        assertEq(c.count, 80);
        assertEq(c.price, 0.0511 ether);
        assertEq(c.revenue, 4.088 ether);
        assertEq(c.networkFee, 1.022 ether);
        // The edition sale closes 15 minutes after the 1/1.
        assertEq(ea.endTimes(saleId).endTime, auction.auction(oneSaleId).endTime + 15 minutes);
        _settleOneOfOneAndCreate(oneSaleId, root, w);
        assertEq(stream.ownerOf(tokenId), collector);
        _settleAndCheckPayouts(saleId, _editionSeller(w));
        assertEq(_claimFive(saleId, tokenId, bidders), 80);
        assertEq(editions.edition(tokenId).minted, 80);
        assertEq(editions.edition(tokenId).minter, address(editionAuction));
        assertEq(editions.balanceOf(bidders[4], tokenId), 0);
        assertEq(bidders[4].balance, 200 * 0.01 ether, "the loser gets everything back");
        assertEq(address(editionAuction).balance, 0);
    }

    function _traceTwoBids(uint256 saleId) internal returns (address[5] memory bidders) {
        bidders = [makeAddr("b1"), makeAddr("b2"), makeAddr("b3"), makeAddr("b4"), makeAddr("b5")];
        uint16[5] memory steps = [uint16(192), 158, 144, 130, 96];
        uint32[5] memory quantities = [uint32(1), 9, 20, 50, 200];
        for (uint256 i; i < 5; ++i) {
            _editionBid(saleId, bidders[i], steps[i], quantities[i]);
        }
    }

    function _settleAndCheckPayouts(uint256 saleId, address seller) internal {
        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = networkFee.balance;
        _settleEditions(saleId);
        assertEq(seller.balance - sellerBefore, 4.088 ether - 1.022 ether);
        assertEq(networkFee.balance - feeBefore, 1.022 ether);
    }

    function _claimFive(uint256 saleId, uint256 tokenId, address[5] memory bidders)
        internal
        returns (uint256 minted)
    {
        for (uint256 i; i < 5; ++i) {
            vm.prank(bidders[i]);
            (uint256 won, uint256 refund) = editionAuction.claimBid(saleId, i + 1, bidders[i]);
            minted += won;
            assertEq(editions.balanceOf(bidders[i], tokenId), won);
            assertEq(bidders[i].balance, refund);
        }
    }

    /// @dev PLAN appendix C, trace 3: a cap of 60, B2 raised out of the cut step; the sweep
    ///      closes the hole and exactly 60 are minted.
    function test_Flow_CapFifoHole() public {
        (bytes32 root, Work memory w, uint256 oneSaleId,, uint256 saleId) = _startMaster(artist, 60);
        _editionBid(saleId, makeAddr("A"), 192, 1);
        _editionBid(saleId, makeAddr("B"), 158, 9);
        _editionBid(saleId, makeAddr("C"), 144, 5);
        _editionBid(saleId, makeAddr("B1"), 130, 20);
        uint256 b2 = _editionBid(saleId, makeAddr("B2"), 130, 15);
        _editionBid(saleId, makeAddr("B3"), 130, 10);
        _editionBid(saleId, makeAddr("B4"), 130, 20);
        uint256 topUp = 15 * (0.1 ether - 0.0511 ether);
        vm.deal(makeAddr("B2"), topUp);
        vm.prank(makeAddr("B2"));
        editionAuction.raise{ value: topUp }(saleId, b2, 144);
        assertEq(ea.clearing(saleId).cutoff, 45);
        _settleOneOfOneAndCreate(oneSaleId, root, w);
        _settleEditions(saleId);
        uint256 minted;
        for (uint256 bidId = 1; bidId <= 7; ++bidId) {
            (uint256 won,) = editionAuction.claimBidFor(saleId, bidId);
            minted += won;
        }
        assertEq(minted, 60);
        assertEq(editionAuction.claimable(makeAddr("B2"), address(0)), 0.7335 ether);
        assertEq(editionAuction.claimable(makeAddr("B4"), address(0)), 20 * 0.0511 ether);
    }

    /// @dev D140: the 1/1 keeps its anti-snipe and the edition close moves with it.
    function test_Flow_OneOfOneAntiSnipeMovesTheEditionClose() public {
        (,, uint256 oneSaleId,, uint256 saleId) = _startMaster(artist, 0);
        uint64 end = auction.auction(oneSaleId).endTime;
        // A 1/1 bid in its last window (15 minutes) extends it.
        vm.warp(end - 1);
        _ethBid(oneSaleId, collector, 1 ether);
        uint64 extended = auction.auction(oneSaleId).endTime;
        assertGt(extended, end);
        // Past the old edition close, an edition bid is accepted and the close follows the 1/1.
        vm.warp(end + 15 minutes);
        _editionBid(saleId, makeAddr("late"), 10, 1);
        assertEq(ea.endTimes(saleId).closeAt, extended + 15 minutes);
        // The edition's own soft close: a bid in its last 5 minutes extends it.
        vm.warp(extended + 15 minutes - 1);
        _editionBid(saleId, makeAddr("sniper"), 11, 1);
        assertEq(ea.endTimes(saleId).endTime, extended + 15 minutes - 1 + 5 minutes);
    }

    /// @dev Decision 12: a dispute pause opens withdrawals; an upheld dispute cancels the 1/1 and
    ///      voids the edition sale with full refunds.
    function test_Flow_DisputeWithdrawAndVoid() public {
        (,, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _startMaster(artist, 0);
        address stayer = makeAddr("stayer");
        address leaver = makeAddr("leaver");
        _editionBid(saleId, stayer, 50, 2);
        _editionBid(saleId, leaver, 60, 3);
        _ethBid(oneSaleId, collector, 1 ether);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(leaver);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.WithdrawalsClosed.selector, saleId)
        );
        editionAuction.withdrawBid(saleId, 2, leaver);
        vm.prank(guardian1);
        auction.pause(oneSaleId, keccak256("dispute"));
        assertTrue(ea.endTimes(saleId).withdrawalsOpen);
        vm.prank(leaver);
        editionAuction.withdrawBid(saleId, 2, leaver);
        assertEq(leaver.balance, 3 * ea.stepPrice(saleId, 60));
        // Bidding continues while paused.
        _editionBid(saleId, makeAddr("newcomer"), 55, 1);
        bytes32 outcome = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
        );
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (oneSaleId, outcome)));
        assertEq(
            uint8(auction.auction(oneSaleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        assertTrue(editionAuction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        vm.prank(stayer);
        (uint256 won, uint256 refund) = editionAuction.claimBid(saleId, 1, stayer);
        assertEq(won, 0);
        assertEq(refund, 2 * ea.stepPrice(saleId, 50));
        (won, refund) = editionAuction.claimBidFor(saleId, 3);
        assertEq(won, 0);
        assertEq(address(editionAuction).balance, refund, "only the credited refund remains");
    }

    /// @dev D141: editions sell whether or not the 1/1 drew bids.
    function test_Flow_EditionsSellWithoutOneOfOneBids() public {
        (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(artist, 0);
        _editionBid(saleId, makeAddr("fan"), 20, 4);
        _settleOneOfOneAndCreate(oneSaleId, root, w);
        assertEq(auction.auction(oneSaleId).bidder, address(0), "the 1/1 drew no bids");
        _settleEditions(saleId);
        vm.prank(makeAddr("fan"));
        (uint256 won,) = editionAuction.claimBid(saleId, 1, makeAddr("fan"));
        assertEq(won, 4);
        assertEq(editions.balanceOf(makeAddr("fan"), tokenId), 4);
    }

    /// @dev D141: no edition bids, no editions; nothing paid, no edition needed.
    function test_Flow_NoEditionBidsNoEditions() public {
        (,, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _startMaster(artist, 0);
        _ethBid(oneSaleId, collector, 1 ether);
        _settleAtEnd(oneSaleId);
        _settleEditions(saleId);
        assertEq(ea.settlement(saleId).count, 0);
        assertFalse(editions.exists(tokenId));
    }

    /// @dev An edition sale opens only for a master, with its stored item, from the 1/1's start.
    function test_Flow_OpenChecksTheMasterOnTheRealStack() public {
        Work memory w = _masterWork(artist, 0);
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        (, uint256 tokenId) = _start(root, works, 0);
        Work memory other = _masterWork(artist, 7);
        vm.expectRevert();
        editionAuction.open(address(editions), tokenId, abi.encode(other.item));
        editionAuction.open(address(editions), tokenId, abi.encode(w.item));
    }
}
