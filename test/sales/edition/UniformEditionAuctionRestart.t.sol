// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice The shared edition auction and a 1/1 that is offered again (EA-17 in
///         `docs/spec/editions-and-sales.md`): a sale follows only the 1/1 sale it was opened in.
///         The English auction answers when a work was last offered again
///         (`IEnglishAuctionClock.auctionClock`); a time later than the sale's opening means the
///         1/1 sale it followed was settled unsold, so the sale reads its 1/1 as settled and
///         keeps the end it recorded. Here the 1/1's auction is a mock whose clock the test sets,
///         so every answer the rule can meet is reached; the real contracts run the same rule in
///         `test/integration/IndependentEditionRestart.t.sol`.
contract UniformEditionAuctionRestartTest is EditionAuctionBase {
    uint256 internal constant CLOSE_OFFSET = 15 minutes;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal saleId;
    uint64 internal firstEnd;

    function setUp() public override {
        super.setUp();
        saleId = _open(0);
        _bid(saleId, alice, 100, 2);
        _bid(saleId, bob, 50, 1);
        (, firstEnd) = english.clockOf(address(stream), ID);
    }

    /// @dev The 1/1 as its auction answers after a restart at `at`: ACTIVE with a new, later
    ///      end.
    function _restartOneOfOne(uint64 at) internal {
        english.set(address(stream), ID, IEnglishAuction.AuctionState.ACTIVE, at + 1 days);
        english.setRestartedAt(address(stream), ID, at);
    }

    /// @dev A 1/1 offered again after the sale opened reads SETTLED in the sale's views and at
    ///      settlement, with the end the sale recorded: bidding closes at that close, anyone
    ///      settles from it, the seller and the network are paid and every bid is claimed.
    function test_Restarted_TheSaleReadsItsOneOfOneAsSettledAndKeepsItsClose() public {
        vm.warp(firstEnd);
        _restartOneOfOne(uint64(block.timestamp));

        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(e.oneOfOneEnd, firstEnd, "the end it recorded");
        assertEq(e.closeAt, firstEnd + CLOSE_OFFSET);
        assertEq(e.endTime, firstEnd + CLOSE_OFFSET);
        assertTrue(e.biddingOpen, "open until its own close");
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.OPEN));
        (bool abandonable, uint256 abandonAt) = ua.abandonable(saleId);
        assertFalse(abandonable, "a sale that settles is not abandoned");
        assertEq(abandonAt, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        auction.settle(saleId, new uint256[](0));

        vm.warp(firstEnd + CLOSE_OFFSET);
        assertFalse(ua.endTimes(saleId).biddingOpen, "closed at its own close");
        uint256 balance = address(auction).balance;
        vm.expectEmit(true, false, false, false, address(auction));
        emit IUniformEditionAuction.AuctionSettled(saleId, 0, 0);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        paidOut += balance - address(auction).balance;
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        assertEq(ua.endTimes(saleId).oneOfOneEnd, firstEnd, "the stored end did not move");
        assertGt(_claimAll(saleId), 0, "copies are claimed");
        _assertConserved();
        assertEq(address(auction).balance, 0);
    }

    /// @dev A bid that lands inside the soft window reads the 1/1 live. With the 1/1 offered
    ///      again, the bid is taken, the soft close runs from the recorded close and the later
    ///      end of the restarted 1/1 is not recorded. After the end, a bid is refused.
    function test_Restarted_ABidNearTheCloseDoesNotRecordTheLaterEnd() public {
        vm.warp(firstEnd);
        _restartOneOfOne(uint64(block.timestamp));
        uint256 closeAt = firstEnd + CLOSE_OFFSET;
        uint256 softWindow = ua.auction(saleId).terms.softWindow;

        vm.warp(closeAt - 1);
        uint256 amount = _price(saleId, 100);
        vm.deal(alice, alice.balance + amount);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.BidPlaced(
            saleId, 3, alice, 100, 1, 0, uint64(closeAt - 1 + softWindow)
        );
        vm.prank(alice);
        auction.bid{ value: amount }(saleId, 100, 1);
        escrowIn += amount;

        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(e.oneOfOneEnd, firstEnd, "the restarted end is not recorded");
        assertEq(e.closeAt, closeAt);
        assertEq(e.endTime, closeAt - 1 + softWindow, "the soft close, from the recorded close");

        vm.warp(e.endTime);
        vm.deal(bob, bob.balance + amount);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.BiddingClosed.selector, saleId, e.endTime)
        );
        auction.bid{ value: amount }(saleId, 100, 1);

        uint256 balance = address(auction).balance;
        assertTrue(auction.settle(saleId, new uint256[](0)));
        paidOut += balance - address(auction).balance;
        _claimAll(saleId);
        _assertConserved();
    }

    /// @dev A restart in the block the sale opened in is not later than the opening: the sale
    ///      was opened in the restarted 1/1 sale and follows it, later end included.
    function test_Restarted_ARestartNotLaterThanTheOpeningIsFollowed() public {
        uint64 openedAt = ua.auction(saleId).openedAt;
        english.setRestartedAt(address(stream), ID, openedAt);
        english.set(address(stream), ID, IEnglishAuction.AuctionState.ACTIVE, firstEnd + 1 hours);

        vm.warp(firstEnd);
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(e.oneOfOneEnd, firstEnd + 1 hours, "it follows the 1/1 it was opened in");
        assertEq(e.closeAt, firstEnd + 1 hours + CLOSE_OFFSET);

        // Its settlement waits for that 1/1, as for any sale.
        vm.warp(e.closeAt);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        auction.settle(saleId, new uint256[](0));
        _settle(saleId);
        _claimAll(saleId);
        _assertConserved();
    }

    /// @dev A 1/1 offered again and then cancelled is still read as cancelled: the sale voids,
    ///      at once, and every bid is refunded in full.
    function test_Restarted_ACancelledOneOfOneStillVoidsTheSale() public {
        vm.warp(firstEnd);
        _restartOneOfOne(uint64(block.timestamp));
        vm.warp(block.timestamp + 1 hours);
        english.set(address(stream), ID, IEnglishAuction.AuctionState.CANCELLED, firstEnd + 1 days);

        assertEq(
            uint8(ua.endTimes(saleId).oneOfOneState), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionVoided(saleId);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertEq(_claimAll(saleId), 0, "nothing is minted");
        assertEq(refundsOut, escrowIn, "every bid is refunded in full");
        assertEq(address(auction).balance, 0);
        assertTrue(editions.editionOf(ID).supplySealed, "sealed at zero");
    }

    /// @dev A 1/1 auction that answers a restart time fitting no clock (past 64 bits) gives the
    ///      views no usable answer: they report no 1/1 state and the end the sale recorded.
    function test_Restarted_ARestartTimePastSixtyFourBitsIsNoAnswerForTheViews() public {
        english.setRawRestartedAt(uint256(type(uint64).max) + 1);
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.NONE));
        assertEq(e.oneOfOneEnd, firstEnd, "the sale's own recorded end");
        assertEq(e.closeAt, firstEnd + CLOSE_OFFSET);

        // The same answer with a time that fits is read as a restart.
        english.setRawRestartedAt(type(uint64).max);
        e = ua.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(e.closeAt, firstEnd + CLOSE_OFFSET);
    }

    /// @dev An English auction that answers the clock in three words, without the restart time,
    ///      gives no usable answer: no sale opens against it, and an open sale's views report no
    ///      1/1 state and the end the sale recorded.
    function test_AThreeWordClockAnswerIsNoUsableAnswer() public {
        english.set(
            address(stream),
            9,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        PackageItem memory item = _item(9, 0);
        english.setShortAnswer(true);
        vm.prank(opener);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.NoOneOfOneAuction.selector, address(stream), 9
            )
        );
        auction.open(address(editions), 9, _openData(item));

        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.NONE));
        assertEq(e.oneOfOneEnd, firstEnd, "the sale's own recorded end");

        // The same sale opens once the answer has all four words.
        english.setShortAnswer(false);
        vm.prank(opener);
        auction.open(address(editions), 9, _openData(item));
    }

    /// @dev A 1/1 never offered again (the answer zero) is followed as before: a later end
    ///      moves the close.
    function test_NotRestarted_ALaterEndStillMovesTheClose() public {
        english.set(address(stream), ID, IEnglishAuction.AuctionState.ACTIVE, firstEnd + 10 minutes);
        vm.warp(firstEnd);
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(e.closeAt, firstEnd + 10 minutes + CLOSE_OFFSET);
        _settle(saleId);
        _claimAll(saleId);
        _assertConserved();
    }
}
