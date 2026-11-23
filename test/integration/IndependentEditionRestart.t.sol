// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IndependentEditionAuction } from "src/independent/IndependentEditionAuction.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { Edition, Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { PRODUCT_INDEPENDENT } from "src/interfaces/types/EconomicsTypes.sol";
import { SettleAndRestart } from "test/mocks/sales/RestartMocks.sol";
import { IndependentIntegrationBase } from "./IndependentIntegrationBase.sol";

/// @notice An Independent Stream edition sale and a 1/1 that is offered again, on the real
///         deployed stack (IND-56 in `docs/spec/independent-stream.md`, EA-17 in
///         `docs/spec/editions-and-sales.md`). An edition sale follows only the 1/1 sale it was
///         opened in: once that 1/1 is settled unsold and offered again (`restart`), the edition
///         sale keeps the end it recorded, closes, settles and pays by its own rule, and its
///         bidders claim, whatever the work's later sales do. A sale opened after a restart
///         follows the restarted 1/1, in whichever order the two happen inside one block.
contract IndependentEditionRestartTest is IndependentIntegrationBase {
    uint256 internal constant CLOSE_OFFSET = 15 minutes;

    address internal artist;
    address internal anyone = makeAddr("anyone");
    address internal alice = makeAddr("editionAlice");
    address internal bob = makeAddr("editionBob");
    address internal collector = makeAddr("laterCollector");
    IndependentStream6529 internal fStream;
    IndependentStreamEditions6529 internal fEditions;
    IndependentEditionAuction internal indAuction;
    SettleAndRestart internal restarter = new SettleAndRestart();
    /// @dev The adapter's views, answered by its lens through its fallback.
    IUniformEditionAuction internal ea;

    /// @dev The master item, encoded as the edition sale's open data.
    bytes internal itemData;
    /// @dev The master's seller wallet.
    address internal seller;
    uint256 internal oneSaleId;
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        artist = _actor("restartArtist");
        (fStream, fEditions) = _listPair(artist);
        indAuction = IndependentEditionAuction(payable(deployment.independentEditionAuction));
        ea = IUniformEditionAuction(address(indAuction));
        Work memory master = _asMaster(_fedWork(artist), 0);
        itemData = abi.encode(master.item);
        seller = ledger.walletFor(master.item.payees, bytes32(0));
        _approveInd(address(fStream), artist, master, IND_RATE);
        (oneSaleId, tokenId) = _fedStart(address(fStream), master);
    }

    // ------------------------------------------------------------------ the sale it followed

    /// @dev The 1/1 ends unsold with an edition sale open and holding bids; it is settled and
    ///      offered again inside the edition sale's last fifteen minutes. The edition sale reads
    ///      its 1/1 as settled and keeps its close: it takes bids until then, settles at it,
    ///      pays the seller and the network, and its bidders claim. The restarted 1/1 runs on
    ///      and sells on its own.
    function test_Restart_AnEditionSaleKeepsItsCloseWhenItsOneOfOneIsOfferedAgain() public {
        uint256 saleId = _openEdition();
        uint256 aliceEscrow = _bid(saleId, alice, 100, 2);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        uint256 closeAt = firstEnd + CLOSE_OFFSET;
        assertEq(ea.endTimes(saleId).closeAt, closeAt, "fifteen minutes after the 1/1");

        _settleUnsoldAndRestart(firstEnd);
        IEnglishAuction.Auction memory one = auction.auction(oneSaleId);
        assertEq(uint8(one.state), uint8(IEnglishAuction.AuctionState.ACTIVE), "offered again");
        assertGt(one.endTime, closeAt, "with a later end");
        assertEq(_restartedAt(), block.timestamp, "the auction answers when");

        // The edition sale's own views: its 1/1 is settled, its close has not moved.
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(e.oneOfOneEnd, firstEnd, "the end it recorded");
        assertEq(e.closeAt, closeAt, "the close has not moved");
        assertEq(e.endTime, closeAt);
        assertTrue(e.biddingOpen, "open until its own close");

        // A bid before the close is taken as usual; settlement waits for the close.
        vm.warp(firstEnd + 5 minutes);
        uint256 bobEscrow = _bid(saleId, bob, 50, 3);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        indAuction.settle(saleId, new uint256[](0));

        // At the close: no more bids, and anyone settles, with the 1/1 still running.
        vm.warp(closeAt);
        uint256 price = ea.stepPrice(saleId, 100);
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.BiddingClosed.selector, saleId, uint64(closeAt)
            )
        );
        indAuction.bid{ value: price }(saleId, 100, 1);
        vm.deal(alice, 0);

        IUniformEditionAuction.Clearing memory c = _settleAndCheckThePayout(saleId);
        assertEq(
            uint8(auction.auction(oneSaleId).state),
            uint8(IEnglishAuction.AuctionState.ACTIVE),
            "the restarted 1/1 is still running"
        );

        // Every bidder claims: copies at the clearing price and the rest back.
        uint256 refunds = _claim(saleId, 1, alice) + _claim(saleId, 2, bob);
        assertEq(refunds, aliceEscrow + bobEscrow - c.revenue, "refunds are the rest");
        assertEq(fEditions.balanceOf(alice, tokenId) + fEditions.balanceOf(bob, tokenId), c.count);
        assertEq(address(indAuction).balance, 0, "the edition auction holds nothing");
        Edition memory ed = fEditions.editionOf(tokenId);
        assertTrue(ed.supplySealed, "sealed at the count");
        assertEq(ed.maxSupply, c.count);

        // The restarted 1/1 sells on its own.
        _ethBid(oneSaleId, collector, 1 ether);
        _settleAtEnd(oneSaleId);
        assertEq(fStream.ownerOf(tokenId), collector);
        assertEq(uint8(fStream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
    }

    /// @dev The 1/1 is offered again every time it ends unsold, and nobody touches the edition
    ///      sale in between. The edition sale still reads the close of the sale it followed:
    ///      anyone settles it during any later 1/1 sale, and its bidder claims.
    function test_Restart_RepeatedRestartsNeverMoveTheEditionSalesClose() public {
        uint256 saleId = _openEdition();
        uint256 escrow = _bid(saleId, alice, 100, 2);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;

        uint256 end = firstEnd;
        for (uint256 i; i < 3; ++i) {
            _settleUnsoldAndRestart(end);
            end = auction.auction(oneSaleId).endTime;
        }
        assertGt(block.timestamp, firstEnd + CLOSE_OFFSET, "long after the first close");
        assertEq(
            uint8(auction.auction(oneSaleId).state), uint8(IEnglishAuction.AuctionState.ACTIVE)
        );

        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(e.endTime, firstEnd + CLOSE_OFFSET, "the close of the sale it followed");
        assertFalse(e.biddingOpen, "closed");
        (bool abandonable,) = ea.abandonable(saleId);
        assertFalse(abandonable, "it settles; it is not abandoned");

        vm.prank(anyone);
        assertTrue(indAuction.settle(saleId, new uint256[](0)));
        IUniformEditionAuction.Clearing memory c = ea.clearing(saleId);
        assertEq(c.count, 2);
        assertEq(_claim(saleId, 1, alice), escrow - c.revenue);
        assertEq(fEditions.balanceOf(alice, tokenId), 2);
        assertEq(address(indAuction).balance, 0);
    }

    // ------------------------------------------------------------------ a sale opened later

    /// @dev An edition sale opened after the 1/1 was offered again, here in the same block as
    ///      the restart, follows that restarted 1/1: its close is fifteen minutes after the new
    ///      end, it waits for that 1/1 to settle, and a second restart no longer moves it.
    function test_Restart_ASaleOpenedAfterARestartFollowsTheRestartedOneOfOne() public {
        _settleUnsoldAndRestart(auction.auction(oneSaleId).endTime);
        uint256 secondEnd = auction.auction(oneSaleId).endTime;
        uint256 saleId = _openEdition();
        assertEq(ea.auction(saleId).openedAt, block.timestamp, "opened in the restart's block");
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(e.closeAt, secondEnd + CLOSE_OFFSET, "it follows the restarted 1/1");
        uint256 escrow = _bid(saleId, alice, 100, 1);

        // Past the close with the 1/1 ended and not settled: the sale waits for it.
        vm.warp(secondEnd + CLOSE_OFFSET);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        indAuction.settle(saleId, new uint256[](0));

        // The 1/1 ends unsold again and is offered a third time: this sale keeps its close.
        auction.settle(oneSaleId);
        vm.prank(anyone);
        auction.restart(oneSaleId);
        e = ea.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(e.endTime, secondEnd + CLOSE_OFFSET);
        assertTrue(indAuction.settle(saleId, new uint256[](0)));
        assertEq(_claim(saleId, 1, alice), escrow - ea.clearing(saleId).revenue);
        assertEq(fEditions.balanceOf(alice, tokenId), 1);
    }

    /// @dev The other order inside one block: the 1/1 has ended unsold and is settled, an edition
    ///      sale is opened in its last fifteen minutes, and the 1/1 is offered again in the same
    ///      block, after the open. The sale was opened in the 1/1 sale that ended: it keeps that
    ///      close, takes a bid until then, settles and pays.
    function test_Restart_ASaleOpenedBeforeARestartInTheSameBlockKeepsItsClose() public {
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        vm.warp(firstEnd + 1 minutes);
        auction.settle(oneSaleId);
        uint256 saleId = _openEdition();
        vm.prank(anyone);
        auction.restart(oneSaleId);
        assertEq(ea.auction(saleId).openedAt, block.timestamp, "opened in the restart's block");
        assertEq(_restartedAt(), block.timestamp);

        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(e.oneOfOneEnd, firstEnd, "the end of the 1/1 sale it was opened in");
        assertEq(e.closeAt, firstEnd + CLOSE_OFFSET);
        assertTrue(e.biddingOpen);

        uint256 escrow = _bid(saleId, alice, 100, 2);
        vm.warp(e.closeAt + ea.auction(saleId).terms.softWindow);
        IUniformEditionAuction.Clearing memory c = _settleAndCheckThePayout(saleId);
        assertEq(c.count, 2);
        assertEq(_claim(saleId, 1, alice), escrow - c.revenue);
        assertEq(fEditions.balanceOf(alice, tokenId), 2);
        assertEq(address(indAuction).balance, 0);
    }

    // ------------------------------------------------------------------ steps

    function _openEdition() internal returns (uint256 saleId) {
        saleId = indAuction.open(address(fEditions), tokenId, itemData);
    }

    /// @dev At `end`, with no bid on the 1/1: anyone settles it (it stays in custody) and offers
    ///      it again, both in one transaction, so nothing can read the 1/1 in between.
    function _settleUnsoldAndRestart(uint256 end) internal {
        vm.warp(end);
        vm.prank(anyone);
        restarter.run(IEnglishAuction(address(auction)), oneSaleId);
        assertEq(fStream.ownerOf(tokenId), address(auction), "unsold, in custody");
    }

    function _restartedAt() internal view returns (uint64 restartedAt) {
        (,,, restartedAt) = auction.auctionClock(oneSaleId);
    }

    /// @dev Anyone settles the closed edition sale in one call: it clears as its lens computed,
    ///      and pays the network its share and the seller the rest.
    function _settleAndCheckThePayout(uint256 saleId)
        internal
        returns (IUniformEditionAuction.Clearing memory c)
    {
        c = ea.clearing(saleId);
        assertGt(c.count, 0, "the book clears");
        address fee = economics.networkFeeRecipient(PRODUCT_INDEPENDENT);
        (uint256 sellerBefore, uint256 feeBefore) = (seller.balance, fee.balance);
        vm.expectEmit(address(indAuction));
        emit IUniformEditionAuction.AuctionCleared(
            saleId, c.count, c.step, c.price, c.revenue, c.rationed, c.cutUnits
        );
        vm.expectEmit(address(indAuction));
        emit IUniformEditionAuction.AuctionSettled(saleId, c.count, 0);
        vm.prank(anyone);
        assertTrue(indAuction.settle(saleId, new uint256[](0)), "settled in one call");
        assertEq(
            uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        assertEq(fee.balance - feeBefore, c.networkFee, "the network's share");
        assertEq(seller.balance - sellerBefore, c.revenue - c.networkFee, "the seller's part");
    }

    function _bid(uint256 saleId, address bidder, uint256 step, uint256 quantity)
        internal
        returns (uint256 amount)
    {
        amount = quantity * ea.stepPrice(saleId, step);
        vm.deal(bidder, amount);
        vm.prank(bidder);
        indAuction.bid{ value: amount }(saleId, step, quantity);
    }

    /// @dev `bidder` claims its bid to itself; returns the refund, checked against its balance.
    function _claim(uint256 saleId, uint256 bidId, address bidder)
        internal
        returns (uint256 refund)
    {
        uint256 before = bidder.balance;
        vm.prank(bidder);
        (, refund) = indAuction.claimBid(saleId, bidId, bidder);
        assertEq(bidder.balance - before, refund, "the refund is paid");
    }
}
