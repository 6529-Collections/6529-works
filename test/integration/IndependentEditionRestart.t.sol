// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Roles } from "src/governance/Roles.sol";
import { IndependentEditionAuction } from "src/independent/IndependentEditionAuction.sol";
import { IndependentEditionAuctionLens } from "src/independent/IndependentEditionAuctionLens.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { Edition, Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { PRODUCT_INDEPENDENT } from "src/interfaces/types/EconomicsTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { SettleAndRestart } from "test/mocks/sales/RestartMocks.sol";
import { IndependentIntegrationBase } from "./IndependentIntegrationBase.sol";

/// @notice An Independent Stream edition sale and a 1/1 that is offered again, on the real
///         deployed stack (IND-56 in `docs/spec/independent-stream.md`, EA-17 in
///         `docs/spec/editions-and-sales.md`, AUC-53 in `docs/spec/stream-and-auctions.md`). A
///         work is offered again only from fifteen minutes after its last sale's end, the time an
///         edition sale stays open after its 1/1: an edition sale that followed the ended 1/1
///         has reached its close by then. From the restart it reads its 1/1 as settled and keeps
///         the end it recorded, so it settles and pays by its own rule and its bidders claim,
///         whatever the work's later sales do. A sale opened after a restart follows the
///         restarted 1/1.
contract IndependentEditionRestartTest is IndependentIntegrationBase {
    uint256 internal constant CLOSE_OFFSET = 15 minutes;
    bytes32 internal constant DISPUTE_REF = keccak256("restart suite: a dispute");

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

    // ------------------------------------------------------------------ when a restart is taken

    /// @dev The restart wait is the edition auctions' close offset, and it is counted from the
    ///      ended sale's end: settling and offering again in one transaction at the end is
    ///      refused, as is every call up to the last second, with the time it is first accepted.
    function test_Restart_RefusedUntilTheEditionCloseOffsetAfterTheEnd() public {
        assertEq(auction.RESTART_DELAY(), CLOSE_OFFSET);
        assertEq(IUniformEditionAuctionLens(address(indAuction)).CLOSE_OFFSET(), CLOSE_OFFSET);
        uint256 saleId = _openEdition();
        _bid(saleId, alice, 100, 2);
        uint256 end = auction.auction(oneSaleId).endTime;

        vm.warp(end);
        vm.expectRevert(_tooEarly(end));
        vm.prank(anyone);
        restarter.run(IEnglishAuction(address(auction)), oneSaleId);

        auction.settle(oneSaleId);
        vm.warp(end + CLOSE_OFFSET - 1);
        vm.expectRevert(_tooEarly(end));
        vm.prank(anyone);
        auction.restart(oneSaleId);
        assertTrue(ea.endTimes(saleId).biddingOpen, "the edition sale's last second");

        vm.warp(end + CLOSE_OFFSET);
        assertFalse(ea.endTimes(saleId).biddingOpen, "the edition sale has closed");
        vm.prank(anyone);
        auction.restart(oneSaleId);
        assertEq(_restartedAt(), block.timestamp, "the auction answers when");
    }

    // ------------------------------------------------------------------ the sale it followed

    /// @dev The 1/1 ends unsold with an edition sale open and holding bids. The edition sale
    ///      takes a bid in its last fifteen minutes and closes; the 1/1 is offered again at
    ///      that moment. The edition sale reads its 1/1 as settled and keeps its close: anyone
    ///      settles it with the restarted 1/1 running, the seller and the network are paid and
    ///      the bidders claim. The restarted 1/1 sells on its own.
    function test_Restart_AnEditionSaleKeepsItsCloseWhenItsOneOfOneIsOfferedAgain() public {
        uint256 saleId = _openEdition();
        uint256 escrow = _bid(saleId, alice, 100, 2);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        uint256 closeAt = firstEnd + CLOSE_OFFSET;
        assertEq(ea.endTimes(saleId).closeAt, closeAt, "fifteen minutes after the 1/1");

        vm.warp(firstEnd);
        auction.settle(oneSaleId);
        vm.warp(firstEnd + 5 minutes);
        escrow += _bid(saleId, bob, 50, 3);
        uint256 endTime = ea.endTimes(saleId).endTime;
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        indAuction.settle(saleId, new uint256[](0));

        _restartAt(closeAt);
        IEnglishAuction.Auction memory one = auction.auction(oneSaleId);
        assertEq(uint8(one.state), uint8(IEnglishAuction.AuctionState.ACTIVE), "offered again");
        assertGt(one.endTime, closeAt, "with a later end");

        // The edition sale's own views: its 1/1 is settled, its clocks have not moved.
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(e.oneOfOneEnd, firstEnd, "the end it recorded");
        assertEq(e.closeAt, closeAt, "the close has not moved");
        assertEq(e.endTime, endTime, "nor its end");

        // At its end: no more bids, and anyone settles, with the 1/1 running again.
        vm.warp(endTime);
        _expectBiddingClosed(saleId, endTime);
        IUniformEditionAuction.Clearing memory c = _settleAndCheckThePayout(saleId);
        assertEq(
            uint8(auction.auction(oneSaleId).state),
            uint8(IEnglishAuction.AuctionState.ACTIVE),
            "the restarted 1/1 is still running"
        );

        // Every bidder claims: copies at the clearing price and the rest back.
        assertEq(_claim(saleId, 1, alice) + _claim(saleId, 2, bob), escrow - c.revenue);
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

    /// @dev The 1/1 is offered again every time it may be, and nobody touches the edition sale
    ///      in between. The edition sale still reads the close of the sale it followed: anyone
    ///      settles it during any later 1/1 sale, and its bidder claims.
    function test_Restart_RepeatedRestartsNeverMoveTheEditionSalesClose() public {
        uint256 saleId = _openEdition();
        uint256 escrow = _bid(saleId, alice, 100, 2);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;

        uint256 end = firstEnd;
        for (uint256 i; i < 3; ++i) {
            vm.warp(end);
            auction.settle(oneSaleId);
            _restartAt(end + CLOSE_OFFSET);
            end = auction.auction(oneSaleId).endTime;
        }
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

    /// @dev An edition settlement that takes more than one call (a book wider than one scan)
    ///      is started at the close, the 1/1 is offered again, and the later call finishes it:
    ///      a settlement under way does not read the 1/1 again.
    function test_Restart_ASettlementInSeveralCallsSpansARestart() public {
        uint256 saleId = _openEdition();
        uint256 escrow = _bid(saleId, alice, 0, 5);
        escrow += _bid(saleId, bob, 330, 1);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        vm.warp(firstEnd);
        auction.settle(oneSaleId);

        vm.warp(firstEnd + CLOSE_OFFSET);
        assertFalse(indAuction.settle(saleId, new uint256[](0)), "the scan needs another call");
        assertEq(
            uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        _restartAt(block.timestamp);
        vm.warp(block.timestamp + 1 hours);
        assertTrue(indAuction.settle(saleId, new uint256[](0)), "finished after the restart");

        IUniformEditionAuction.Clearing memory c = ea.clearing(saleId);
        assertGt(c.count, 0);
        assertEq(_claim(saleId, 1, alice) + _claim(saleId, 2, bob), escrow - c.revenue);
        assertEq(address(indAuction).balance, 0);
    }

    // ------------------------------------------------------------------ a 1/1 end that moved

    /// @dev A dispute pause that the network ends (`resume`) moves the 1/1's end later, and
    ///      nobody bids on the edition sale afterwards, so the sale still holds the earlier
    ///      end. The edition sale's close is fifteen minutes after the real end all the same.
    function test_Restart_AfterAResumedPauseTheEditionSaleKeepsItsLastFifteenMinutes() public {
        uint256 saleId = _openEdition();
        _bid(saleId, alice, 100, 2);
        uint256 recorded = auction.auction(oneSaleId).endTime;
        _pause();
        vm.warp(block.timestamp + 1 days);
        _asNetwork(address(auction), abi.encodeCall(auction.resume, (oneSaleId)));
        _checkTheLastFifteenMinutes(saleId, recorded);
    }

    /// @dev The same when the pause runs out on its own after three days.
    function test_Restart_AfterAPauseRanOutTheEditionSaleKeepsItsLastFifteenMinutes() public {
        uint256 saleId = _openEdition();
        _bid(saleId, alice, 100, 2);
        uint256 recorded = auction.auction(oneSaleId).endTime;
        _pause();
        vm.warp(block.timestamp + 3 days + 1);
        _checkTheLastFifteenMinutes(saleId, recorded);
    }

    /// @dev The same for a 1/1 that had a bid, withdrawn during the pause: it ends unsold at
    ///      its later end.
    function test_Restart_AfterABidWithdrawnInAPauseTheEditionSaleKeepsItsLastFifteenMinutes()
        public
    {
        uint256 saleId = _openEdition();
        _bid(saleId, alice, 100, 2);
        uint256 recorded = auction.auction(oneSaleId).endTime;
        _ethBid(oneSaleId, collector, 1 ether);
        _pause();
        vm.prank(collector);
        auction.withdrawBid(oneSaleId);
        vm.warp(block.timestamp + 3 days + 1);
        _checkTheLastFifteenMinutes(saleId, recorded);
    }

    /// @dev With the 1/1's real end later than `recorded`, the end the edition sale holds: the
    ///      1/1 ends unsold and is settled; until fifteen minutes after its real end the work
    ///      is not offered again, the edition sale is open and does not settle; then the work
    ///      is offered again and the edition sale, closed, settles and its bidder claims.
    function _checkTheLastFifteenMinutes(uint256 saleId, uint256 recorded) internal {
        uint256 realEnd = auction.auction(oneSaleId).endTime;
        assertGt(realEnd, recorded + CLOSE_OFFSET, "the 1/1's end moved later");
        assertEq(ea.endTimes(saleId).closeAt, realEnd + CLOSE_OFFSET, "the close follows it");

        vm.warp(realEnd);
        vm.expectRevert(_tooEarly(realEnd));
        vm.prank(anyone);
        restarter.run(IEnglishAuction(address(auction)), oneSaleId);
        auction.settle(oneSaleId);
        assertEq(fStream.ownerOf(tokenId), address(auction), "unsold, in custody");

        vm.warp(realEnd + CLOSE_OFFSET - 1);
        vm.expectRevert(_tooEarly(realEnd));
        auction.restart(oneSaleId);
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        assertTrue(e.biddingOpen, "open through its last fifteen minutes");
        assertEq(e.closeAt, realEnd + CLOSE_OFFSET);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        indAuction.settle(saleId, new uint256[](0));

        _restartAt(realEnd + CLOSE_OFFSET);
        e = ea.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertFalse(e.biddingOpen, "closed, as it was a moment before the restart");
        assertTrue(indAuction.settle(saleId, new uint256[](0)));
        uint256 owed = 2 * ea.stepPrice(saleId, 100) - ea.clearing(saleId).revenue;
        uint256 before = alice.balance;
        vm.prank(alice);
        (uint256 won, uint256 refund) = indAuction.claimBid(saleId, 1, alice);
        assertEq(won, 2);
        assertEq(refund, owed, "the escrow less the copies at the clearing price");
        assertEq(alice.balance - before, owed, "the refund is paid");
        assertEq(address(indAuction).balance, 0);
    }

    /// @dev A bid in those last fifteen minutes is taken, runs the soft close and records the
    ///      real end, so after the restart the sale shows the close it really had.
    function test_Restart_ALateBidAfterAPauseIsTakenAndRecordsTheRealEnd() public {
        uint256 saleId = _openEdition();
        uint256 escrow = _bid(saleId, alice, 100, 2);
        _pause();
        vm.warp(block.timestamp + 3 days + 1);
        uint256 realEnd = auction.auction(oneSaleId).endTime;
        vm.warp(realEnd);
        auction.settle(oneSaleId);
        vm.warp(realEnd + CLOSE_OFFSET - 1);
        escrow += _bid(saleId, bob, 120, 1);
        uint256 endTime = ea.endTimes(saleId).endTime;
        assertGt(endTime, realEnd + CLOSE_OFFSET, "the soft close runs");

        _restartAt(realEnd + CLOSE_OFFSET);
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        assertEq(e.closeAt, realEnd + CLOSE_OFFSET, "the real close");
        assertEq(e.endTime, endTime, "the soft end stands");
        assertTrue(e.biddingOpen, "open until its soft end");
        vm.warp(endTime);
        IUniformEditionAuction.Clearing memory c = _settleAndCheckThePayout(saleId);
        assertEq(_claim(saleId, 1, alice) + _claim(saleId, 2, bob), escrow - c.revenue);
    }

    /// @dev The end of a pause that ran out is computed from the auction's settings until a call
    ///      writes it. The edition sale records that end with a bid; the network then lowers
    ///      the auction's duration, so the end written at settlement is earlier. The work may be
    ///      offered again fifteen minutes after the written end, while the edition sale is
    ///      still open on the end it recorded: it keeps that close, takes a bid, settles and
    ///      pays (LIM-EA-22).
    function test_Restart_AnEditionSaleThatRecordedALongerEndKeepsIt() public {
        uint256 saleId = _openEdition();
        uint256 escrow = _bid(saleId, alice, 100, 2);
        _pause();
        vm.warp(block.timestamp + 3 days + 1);
        uint256 longer = auction.auction(oneSaleId).endTime;
        escrow += _bid(saleId, bob, 100, 1);
        assertEq(ea.endTimes(saleId).oneOfOneEnd, longer, "recorded with the bid");

        IEnglishAuction.AuctionConfig memory current = auction.config();
        IEnglishAuction.AuctionConfig memory next = auction.config();
        next.duration = 1 hours;
        _asNetwork(address(auction), abi.encodeCall(auction.setConfig, (current, next)));
        uint256 written = auction.auction(oneSaleId).endTime;
        assertLt(written, longer, "the end is earlier under the new setting");

        // The first moment the work may be offered again is before the close the sale recorded.
        uint256 restartAt = written + CLOSE_OFFSET;
        if (block.timestamp > restartAt) restartAt = block.timestamp;
        assertLt(restartAt, longer + CLOSE_OFFSET, "a restart while the edition sale is open");
        vm.warp(restartAt);
        auction.settle(oneSaleId);
        _restartAt(restartAt);
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(e.closeAt, longer + CLOSE_OFFSET, "the close it recorded");
        assertLt(block.timestamp, e.endTime, "before its end");
        assertTrue(e.biddingOpen, "open until the close it recorded");
        escrow += _bid(saleId, bob, 100, 1);
        e = ea.endTimes(saleId);
        assertEq(e.closeAt, longer + CLOSE_OFFSET, "the bid does not move the close");
        vm.warp(e.endTime);
        IUniformEditionAuction.Clearing memory c = _settleAndCheckThePayout(saleId);
        uint256 refunds = _claim(saleId, 1, alice) + _claim(saleId, 2, bob);
        assertEq(refunds + _claim(saleId, 3, bob), escrow - c.revenue);
    }

    // ------------------------------------------------------------------ a refused settlement

    /// @dev A 1/1 with a bid whose settlement its token refuses is closed after two days with
    ///      the bid credited back, and may be offered again at once (two days are past the
    ///      wait). The edition sale that followed it settles on the close it recorded.
    function test_Restart_AfterARefusedSettlementWithABid() public {
        uint256 saleId = _openEdition();
        uint256 escrow = _bid(saleId, alice, 100, 2);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        _ethBid(oneSaleId, collector, 1 ether);
        firstEnd = auction.auction(oneSaleId).endTime;
        vm.mockCallRevert(
            address(fStream), abi.encodeWithSelector(IStream.recordPrimarySale.selector), "refused"
        );
        vm.warp(firstEnd + auction.REFUSAL_DELAY());
        vm.expectEmit(address(auction));
        emit IEnglishAuctionRefusal.SettlementRefused(oneSaleId);
        auction.settleOrRefund(oneSaleId);
        vm.clearMockedCalls();
        assertEq(auction.claimable(collector), 1 ether, "the bid is credited back");
        assertEq(fStream.ownerOf(tokenId), address(auction), "the work stays in custody");

        _restartAt(block.timestamp);
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(e.closeAt, firstEnd + CLOSE_OFFSET);
        assertTrue(indAuction.settle(saleId, new uint256[](0)));
        assertEq(_claim(saleId, 1, alice), escrow - ea.clearing(saleId).revenue);
        assertEq(fEditions.balanceOf(alice, tokenId), 2);
    }

    // ------------------------------------------------------------------ cancel and delisting

    /// @dev The restarted 1/1 is cancelled after an upheld dispute before anyone settled the
    ///      edition sale: the sale voids and every bid is refunded in full.
    function test_Restart_ACancelAfterTheRestartVoidsAnUnsettledEditionSale() public {
        uint256 saleId = _openEdition();
        uint256 escrow = _bid(saleId, alice, 100, 2);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        vm.warp(firstEnd);
        auction.settle(oneSaleId);
        _restartAt(firstEnd + CLOSE_OFFSET);

        _pause();
        bytes32 outcome = _platformStatement(
            address(fStream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ipfs://outcome"
        );
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionCancelled(oneSaleId, outcome);
        _asNetwork(address(auction), abi.encodeCall(auction.cancel, (oneSaleId, outcome)));

        assertEq(
            uint8(ea.endTimes(saleId).oneOfOneState), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        _voidsAndRefunds(saleId, escrow);
        assertTrue(fEditions.editionOf(tokenId).supplySealed, "sealed at zero");
    }

    /// @dev The contract is delisted after the restart, before anyone settled the edition
    ///      sale: the sale voids and every bid is refunded in full (IND-55).
    function test_Restart_ADelistingAfterTheRestartVoidsAnUnsettledEditionSale() public {
        uint256 saleId = _openEdition();
        uint256 escrow = _bid(saleId, alice, 100, 2);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        vm.warp(firstEnd);
        auction.settle(oneSaleId);
        _restartAt(firstEnd + CLOSE_OFFSET);

        _asNetwork(
            address(independentStream),
            abi.encodeCall(
                independentStream.setStatus,
                (
                    _asArray(address(fStream)),
                    IIndependentStreamRegistry.Status.DELISTED,
                    bytes32("delisted")
                )
            )
        );
        _voidsAndRefunds(saleId, escrow);
    }

    // ------------------------------------------------------------------ between settle calls

    /// @dev Two bids far enough apart that the settlement scan takes more than one call; the
    ///      1/1 ends unsold and the first settle call starts the scan. Nothing is paid yet.
    function _startAScanInSeveralCalls() internal returns (uint256 saleId, uint256 escrow) {
        saleId = _openEdition();
        escrow = _bid(saleId, alice, 0, 5);
        escrow += _bid(saleId, bob, 330, 1);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        vm.warp(firstEnd);
        auction.settle(oneSaleId);
        vm.warp(firstEnd + CLOSE_OFFSET);
        assertFalse(indAuction.settle(saleId, new uint256[](0)), "the scan needs another call");
        assertEq(
            uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        assertFalse(fEditions.editionOf(tokenId).supplySealed, "not cleared yet");
    }

    /// @dev The sale is void: both bids come back in full, no copy is minted, the seller and the
    ///      network are paid nothing, and the edition is sealed at zero.
    function _voidsWithBothBidsRefunded(uint256 saleId, uint256 escrow) internal {
        address fee = economics.networkFeeRecipient(PRODUCT_INDEPENDENT);
        (uint256 sellerBefore, uint256 feeBefore) = (seller.balance, fee.balance);
        vm.expectEmit(address(indAuction));
        emit IUniformEditionAuction.AuctionVoided(saleId);
        vm.prank(anyone);
        assertTrue(indAuction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertEq(_claim(saleId, 1, alice) + _claim(saleId, 2, bob), escrow, "refunded in full");
        assertEq(fEditions.balanceOf(alice, tokenId) + fEditions.balanceOf(bob, tokenId), 0);
        assertEq(address(indAuction).balance, 0, "nothing left behind");
        assertEq(seller.balance, sellerBefore, "the seller is paid nothing");
        assertEq(fee.balance, feeBefore, "the network is paid nothing");
        Edition memory e = fEditions.editionOf(tokenId);
        assertTrue(e.supplySealed && e.maxSupply == 0 && e.minted == 0, "sealed at zero");
    }

    /// @dev The restarted 1/1 is cancelled after an upheld dispute while the edition sale's
    ///      scan is in progress, with nothing paid: the next settle call voids the sale, as the
    ///      first call would have, instead of clearing it (IND-56, EA-19).
    function test_Restart_ACancelBetweenUnpaidSettleCallsVoidsWithFullRefunds() public {
        (uint256 saleId, uint256 escrow) = _startAScanInSeveralCalls();
        _restartAt(block.timestamp);
        _pause();
        bytes32 outcome = _platformStatement(
            address(fStream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ipfs://outcome"
        );
        _asNetwork(address(auction), abi.encodeCall(auction.cancel, (oneSaleId, outcome)));
        assertEq(
            uint8(ea.endTimes(saleId).oneOfOneState), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        _voidsWithBothBidsRefunded(saleId, escrow);
    }

    /// @dev The work is offered again and the network rescues it during that later sale, while
    ///      the edition sale opened in the first sale has its scan in progress. Closing the
    ///      rescued 1/1 credits its bid back and leaves it cancelled; the edition sale then
    ///      voids with both bids refunded and nobody paid (EA-22).
    function test_Restart_ARescueOfTheRestartedOneOfOneVoidsAnUnpaidEditionSale() public {
        (uint256 saleId, uint256 escrow) = _startAScanInSeveralCalls();
        _restartAt(block.timestamp);
        _ethBid(oneSaleId, collector, 1 ether);
        _rescueTheRestartedOneOfOne();
        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(oneSaleId);
        auction.settle(oneSaleId);
        assertEq(auction.claimable(collector), 1 ether, "the 1/1 bid, credited back");
        vm.prank(collector);
        auction.claim(collector);
        assertEq(collector.balance, 1 ether);
        assertEq(address(auction).balance, 0);
        assertEq(
            uint8(ea.endTimes(saleId).oneOfOneState), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        _voidsWithBothBidsRefunded(saleId, escrow);
    }

    /// @dev An edition sale that settled and paid before the later sale's work was rescued
    ///      stands: its winner claims the copies.
    function test_Restart_ARescueAfterTheClearingPaidLeavesItStanding() public {
        uint256 saleId = _openEdition();
        uint256 escrow = _bid(saleId, alice, 100, 2);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        vm.warp(firstEnd);
        auction.settle(oneSaleId);
        vm.warp(firstEnd + CLOSE_OFFSET);
        IUniformEditionAuction.Clearing memory c = _settleAndCheckThePayout(saleId);
        uint256 sellerAfter = seller.balance;
        _restartAt(block.timestamp);
        _rescueTheRestartedOneOfOne();
        auction.settle(oneSaleId);
        assertTrue(indAuction.settle(saleId, new uint256[](0)), "still settled");
        assertEq(seller.balance, sellerAfter, "nothing taken back, nothing paid again");
        assertEq(_claim(saleId, 1, alice), escrow - c.revenue, "the difference only");
        assertEq(fEditions.balanceOf(alice, tokenId), 2, "the copies it won");
        assertEq(address(indAuction).balance, 0);
    }

    /// @dev The network removes the English auction as a sale contract and, with the token's
    ///      rescue wait at zero, rescues the work; the sale is then at its end.
    function _rescueTheRestartedOneOfOne() internal {
        _asNetwork(
            address(independentStream),
            abi.encodeCall(
                independentStream.setAdapter,
                (address(auction), IIndependentStreamRegistry.Form.ERC721, false)
            )
        );
        vm.prank(network);
        fStream.setRescueDelay(0);
        vm.prank(network);
        fStream.rescue(tokenId, makeAddr("rescueRecipient"));
        vm.warp(auction.auction(oneSaleId).endTime);
    }

    /// @dev The contract is delisted in the same window, after a restart: the sale voids too.
    function test_Restart_ADelistingBetweenUnpaidSettleCallsVoidsWithFullRefunds() public {
        (uint256 saleId, uint256 escrow) = _startAScanInSeveralCalls();
        _restartAt(block.timestamp);
        _asNetwork(
            address(independentStream),
            abi.encodeCall(
                independentStream.setStatus,
                (
                    _asArray(address(fStream)),
                    IIndependentStreamRegistry.Status.DELISTED,
                    bytes32("delisted")
                )
            )
        );
        _voidsWithBothBidsRefunded(saleId, escrow);
    }

    /// @dev A restart alone, and a restarted 1/1 under a dispute pause that is not decided, do
    ///      not void the sale: the scan keeps its progress and the next call clears and pays.
    function test_Restart_APausedRestartBetweenSettleCallsKeepsTheScan() public {
        (uint256 saleId, uint256 escrow) = _startAScanInSeveralCalls();
        _restartAt(block.timestamp);
        _pause();
        assertEq(
            uint8(auction.auction(oneSaleId).state), uint8(IEnglishAuction.AuctionState.PAUSED)
        );
        address fee = economics.networkFeeRecipient(PRODUCT_INDEPENDENT);
        (uint256 sellerBefore, uint256 feeBefore) = (seller.balance, fee.balance);
        assertTrue(indAuction.settle(saleId, new uint256[](0)), "finished during the pause");
        IUniformEditionAuction.Clearing memory c = ea.clearing(saleId);
        assertGt(c.count, 0);
        assertEq(fee.balance - feeBefore, c.networkFee, "the network's share");
        assertEq(seller.balance - sellerBefore, c.revenue - c.networkFee, "the seller's part");
        assertEq(_claim(saleId, 1, alice) + _claim(saleId, 2, bob), escrow - c.revenue);
        assertEq(address(indAuction).balance, 0);
    }

    /// @dev A clearing that already paid stands: the sale settles and pays, its 1/1 is then
    ///      offered again and cancelled, and the winners still claim their copies and only the
    ///      difference back; a later settle call changes nothing.
    function test_Restart_ACancelAfterTheClearingPaidLeavesItStanding() public {
        uint256 saleId = _openEdition();
        uint256 escrow = _bid(saleId, alice, 100, 2);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        vm.warp(firstEnd);
        auction.settle(oneSaleId);
        vm.warp(firstEnd + CLOSE_OFFSET);
        IUniformEditionAuction.Clearing memory c = _settleAndCheckThePayout(saleId);
        (uint256 sellerAfter, uint256 held) = (seller.balance, address(indAuction).balance);

        _restartAt(block.timestamp);
        _pause();
        bytes32 outcome = _platformStatement(
            address(fStream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ipfs://outcome"
        );
        _asNetwork(address(auction), abi.encodeCall(auction.cancel, (oneSaleId, outcome)));

        assertTrue(indAuction.settle(saleId, new uint256[](0)), "still settled");
        assertEq(
            uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        assertEq(seller.balance, sellerAfter, "nothing taken back, nothing paid again");
        assertEq(address(indAuction).balance, held);
        assertEq(_claim(saleId, 1, alice), escrow - c.revenue, "the difference only");
        assertEq(fEditions.balanceOf(alice, tokenId), 2, "the copies it won");
        assertEq(address(indAuction).balance, 0);
    }

    // ------------------------------------------------------------------ a sale opened later

    /// @dev An edition sale opened after the 1/1 was offered again, here in the same block as
    ///      the restart, follows that restarted 1/1: its close is fifteen minutes after the new
    ///      end, it waits for that 1/1 to settle, and a second restart does not move it.
    function test_Restart_ASaleOpenedAfterARestartFollowsTheRestartedOneOfOne() public {
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        vm.warp(firstEnd);
        auction.settle(oneSaleId);
        _restartAt(firstEnd + CLOSE_OFFSET);
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
        _restartAt(block.timestamp);
        e = ea.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(e.endTime, secondEnd + CLOSE_OFFSET);
        assertTrue(indAuction.settle(saleId, new uint256[](0)));
        assertEq(_claim(saleId, 1, alice), escrow - ea.clearing(saleId).revenue);
        assertEq(fEditions.balanceOf(alice, tokenId), 1);
    }

    /// @dev An edition sale opened in the ended 1/1's last fifteen minutes cannot share a block
    ///      with the restart: the open is refused from the moment the restart is accepted.
    function test_Restart_NoSaleOpensAgainstTheEndedOneOfOneOnceItMayBeOfferedAgain() public {
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        vm.warp(firstEnd);
        auction.settle(oneSaleId);
        vm.warp(firstEnd + CLOSE_OFFSET);
        uint256 saleId = ea.saleIdOf(address(fEditions), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.BiddingClosed.selector,
                saleId,
                uint64(firstEnd + CLOSE_OFFSET)
            )
        );
        indAuction.open(address(fEditions), tokenId, itemData);

        // One second earlier the open is accepted and the restart is not.
        vm.warp(firstEnd + CLOSE_OFFSET - 1);
        assertEq(_openEdition(), saleId);
        vm.expectRevert(_tooEarly(firstEnd));
        auction.restart(oneSaleId);
    }

    // ------------------------------------------------------------------ an adopted sale

    /// @dev The network removes the edition auction and moves the unsold edition to another,
    ///      which adopts it while the work, unsold and offered again, has a running 1/1 sale.
    ///      The adopted sale follows that 1/1; when it too ends unsold and the work is offered a
    ///      third time, the adopted sale keeps its close, settles and its bidder claims.
    function test_Restart_AnAdoptedSaleFollowsTheOneOfOneItWasAdoptedIn() public {
        _openEdition();
        IndependentEditionAuction second = _secondEditionAuction();
        IUniformEditionAuction sv = IUniformEditionAuction(address(second));
        _asNetwork(
            address(independentStream),
            abi.encodeCall(
                independentStream.setAdapter,
                (address(indAuction), IIndependentStreamRegistry.Form.ERC1155, false)
            )
        );
        vm.warp(block.timestamp + fEditions.rebindDelay());
        auction.settle(oneSaleId);
        vm.prank(network);
        fEditions.rebind(tokenId, address(second));
        _restartAt(block.timestamp);
        uint256 secondEnd = auction.auction(oneSaleId).endTime;

        vm.prank(network);
        uint256 saleId = second.adopt(address(fEditions), tokenId, itemData);
        IUniformEditionAuction.EndTimes memory e = sv.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(e.closeAt, secondEnd + CLOSE_OFFSET, "it follows the 1/1 running at its adoption");
        uint256 amount = 2 * sv.stepPrice(saleId, 100);
        vm.deal(alice, amount);
        vm.prank(alice);
        second.bid{ value: amount }(saleId, 100, 2);

        vm.warp(secondEnd);
        auction.settle(oneSaleId);
        _restartAt(secondEnd + CLOSE_OFFSET);
        e = sv.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(e.closeAt, secondEnd + CLOSE_OFFSET, "the close has not moved");
        assertTrue(second.settle(saleId, new uint256[](0)));
        vm.prank(alice);
        (uint256 won,) = second.claimBid(saleId, 1, alice);
        assertEq(won, 2);
        assertEq(fEditions.balanceOf(alice, tokenId), 2);
        assertEq(address(second).balance, 0);
    }

    /// @dev Another Independent Stream edition auction with the genesis one's settings, wired
    ///      as the network would: `adopt` mapped to the NETWORK role, and admitted by the
    ///      Independent Stream module for editions contracts.
    function _secondEditionAuction() internal returns (IndependentEditionAuction second) {
        address l = address(
            new IndependentEditionAuctionLens(
                address(auction), address(escrow), address(directory), address(economics)
            )
        );
        second = new IndependentEditionAuction(
            address(manager),
            address(escrow),
            address(directory),
            address(auction),
            l,
            l.codehash,
            ea.config(),
            ea.limits()
        );
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = second.adopt.selector;
        _asNetwork(
            address(manager),
            abi.encodeCall(
                manager.setTargetFunctionRole, (address(second), selectors, Roles.NETWORK)
            )
        );
        _asNetwork(
            address(independentStream),
            abi.encodeCall(
                independentStream.setAdapter,
                (address(second), IIndependentStreamRegistry.Form.ERC1155, true)
            )
        );
    }

    // ------------------------------------------------------------------ steps

    function _openEdition() internal returns (uint256 saleId) {
        saleId = indAuction.open(address(fEditions), tokenId, itemData);
    }

    /// @dev Anyone offers the settled, unsold 1/1 again at `at`.
    function _restartAt(uint256 at) internal {
        vm.warp(at);
        vm.prank(anyone);
        auction.restart(oneSaleId);
        assertEq(fStream.ownerOf(tokenId), address(auction), "in custody");
    }

    function _tooEarly(uint256 end) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            IEnglishAuction.RestartTooEarly.selector, oneSaleId, end + CLOSE_OFFSET
        );
    }

    /// @dev A pauser pauses the 1/1 for a dispute, one hour from now.
    function _pause() internal {
        vm.warp(block.timestamp + 1 hours);
        _govern(
            pauser1,
            address(auction),
            abi.encodeWithSignature("pause(uint256,bytes32)", oneSaleId, DISPUTE_REF)
        );
    }

    function _restartedAt() internal view returns (uint64 restartedAt) {
        (,,, restartedAt) = auction.auctionClock(oneSaleId);
    }

    function _expectBiddingClosed(uint256 saleId, uint256 endTime) internal {
        uint256 price = ea.stepPrice(saleId, 100);
        vm.deal(anyone, price);
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.BiddingClosed.selector, saleId, uint64(endTime)
            )
        );
        indAuction.bid{ value: price }(saleId, 100, 1);
        vm.deal(anyone, 0);
    }

    /// @dev Anyone settles the edition sale: it voids, and alice's bid (the only one) comes
    ///      back in full with no copy.
    function _voidsAndRefunds(uint256 saleId, uint256 escrow) internal {
        vm.expectEmit(address(indAuction));
        emit IUniformEditionAuction.AuctionVoided(saleId);
        vm.prank(anyone);
        assertTrue(indAuction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertEq(_claim(saleId, 1, alice), escrow, "refunded in full");
        assertEq(fEditions.balanceOf(alice, tokenId), 0, "no copy");
        assertEq(address(indAuction).balance, 0);
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
        vm.deal(bidder, bidder.balance + amount);
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
