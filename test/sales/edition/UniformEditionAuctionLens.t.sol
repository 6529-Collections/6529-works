// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice The lens's views, read both directly and through the adapter's fallback (the same
///         answers), across every status: before opening, OPEN, SETTLING, SETTLED and VOID.
contract UniformEditionAuctionLensTest is EditionAuctionBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function test_Lens_AnswersThroughTheAdapterAndDirectly() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 130, 3);
        assertEq(
            keccak256(abi.encode(ua.auction(saleId))), keccak256(abi.encode(lens.auction(saleId)))
        );
        assertEq(
            keccak256(abi.encode(ua.clearing(saleId))), keccak256(abi.encode(lens.clearing(saleId)))
        );
        assertEq(ua.stepPrice(saleId, 130), lens.stepPrice(saleId, 130));
    }

    /// @dev `open` binds the edition to the adapter through `IEditions.bindMinter`, passing
    ///      the very item it received (the adapter re-frames `data` without decoding it).
    function test_Open_BindsTheEditionWithTheItemItReceived() public {
        PackageItem memory item = _item(ID, 42);
        vm.expectEmit(true, true, false, true, address(editions));
        emit IEditions.EditionMinterBound(ID, address(auction));
        auction.open(address(editions), ID, abi.encode(item));
        assertEq(editions.minterOf(ID), address(auction));
        assertEq(editions.boundItemHash(ID), WorksHashing.itemHash(item), "the item, intact");
        assertEq(editions.binds(), 1);
    }

    /// @dev An edition bound to another adapter refuses the open, with Editions' error, and
    ///      the sale is not recorded.
    function test_Open_RefusedForAnEditionAnotherAdapterSells() public {
        address other = makeAddr("otherAdapter");
        editions.admit(other, true);
        PackageItem memory item = _item(ID, 0);
        vm.prank(other);
        editions.bindMinter(ID, item);
        vm.expectRevert(abi.encodeWithSelector(IEditions.MinterMismatch.selector, ID, other));
        auction.open(address(editions), ID, abi.encode(item));
        uint256 saleId = auction.saleIdOf(address(editions), ID);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.UnknownAuction.selector, saleId)
        );
        ua.auction(saleId);
    }

    /// @dev A sale opened after its edition exists pays the economics the edition recorded,
    ///      not the resolver's current ones, so the edition always reports the split paid.
    function test_Lens_MasterTermsOfAnExistingEditionAreItsRecorded() public {
        address recordedSeller = makeAddr("recordedSeller");
        address recordedFee = makeAddr("recordedFee");
        editions.setExists(ID, true);
        editions.setLocked(ID, recordedSeller, recordedFee, 10_000);
        IUniformEditionAuctionLens.MasterTerms memory m =
            lens.masterTerms(address(editions), ID, abi.encode(_item(ID, 0)));
        assertEq(m.seller, recordedSeller);
        assertEq(m.feeRecipient, recordedFee);
        assertEq(m.feeShare, 10_000);
        // No fee recorded: none paid.
        editions.setLocked(ID, recordedSeller, recordedFee, 0);
        m = lens.masterTerms(address(editions), ID, abi.encode(_item(ID, 0)));
        assertEq(m.feeRecipient, address(0));
        assertEq(m.feeShare, 0);
    }

    /// @dev The cut step's departure log sorted in `O(n log n)`: 600 departures logged in
    ///      descending position order (the insertion sort's worst case, quadratic) keep
    ///      `settlementOrder`, `clearing`, `quote` and `bidOutcome` far inside a 50M `eth_call`
    ///      gas cap, and the order is by position.
    function test_Lens_SixHundredDeparturesInReverseOrderStayCheap() public {
        uint256 saleId = _open(900);
        address crowd = makeAddr("crowd");
        for (uint256 i; i < 1200; ++i) {
            _bid(saleId, crowd, 100, 1);
        }
        // Raise the later 600 in reverse: each leaves step 100 with a lower position.
        for (uint256 bidId = 1200; bidId > 600; --bidId) {
            _raise(saleId, bidId, 101);
        }
        assertEq(ua.departures(saleId, 100).length, 600);
        uint256 g = gasleft();
        uint256[] memory order = ua.settlementOrder(saleId);
        uint256 orderGas = g - gasleft();
        assertEq(order.length, 600);
        for (uint256 k; k < 600; ++k) {
            assertEq(order[k], 599 - k, "by position");
        }
        g = gasleft();
        IUniformEditionAuction.Clearing memory c = ua.clearing(saleId);
        uint256 clearingGas = g - gasleft();
        assertEq(c.step, 100);
        assertEq(c.count, 900);
        assertTrue(c.rationed);
        assertEq(c.cutoff, 300, "the 600 left are behind the cut");
        g = gasleft();
        ua.quote(saleId, 100, 1);
        uint256 quoteGas = g - gasleft();
        g = gasleft();
        ua.bidOutcome(saleId, 1);
        uint256 outcomeGas = g - gasleft();
        emit log_named_uint("settlementOrder gas", orderGas);
        emit log_named_uint("clearing gas", clearingGas);
        emit log_named_uint("quote gas", quoteGas);
        emit log_named_uint("bidOutcome gas", outcomeGas);
        assertLt(orderGas, 10_000_000);
        assertLt(clearingGas, 10_000_000);
        assertLt(quoteGas, 10_000_000);
        assertLt(outcomeGas, 10_000_000);
        // Settled with that order, in bounded calls.
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        uint256 balance = address(auction).balance;
        for (uint256 i; !auction.settle(saleId, ua.settlementOrder(saleId)); ++i) {
            require(i < 16, "settlement does not advance");
        }
        paidOut += balance - address(auction).balance;
        assertEq(ua.settlement(saleId).count, 900);
    }

    function test_Lens_MasterTerms() public {
        PackageItem memory item = _item(ID, 42);
        IUniformEditionAuctionLens.MasterTerms memory m =
            lens.masterTerms(address(editions), ID, abi.encode(item));
        assertEq(m.maxCount, 42);
        assertEq(m.seller, seller);
        assertEq(m.feeRecipient, networkFee);
        assertEq(m.feeShare, FEE_SHARE);
        assertEq(m.oneOfOneEnd, block.timestamp + 1 days);
        assertEq(uint8(m.oneOfOneState), uint8(IEnglishAuction.AuctionState.ACTIVE));
        // Another token is refused.
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(stream), ID)
        );
        lens.masterTerms(address(stream), ID, abi.encode(item));
    }

    function test_Lens_BeforeOpening() public view {
        uint256 saleId = auction.saleIdOf(address(editions), ID);
        // The ladder under the current configuration.
        assertEq(ua.stepPrice(saleId, 0), 1e14);
        assertEq(ua.stepPrice(saleId, 335), 953 ether);
        uint256[] memory prices = ua.ladder(saleId);
        assertEq(prices.length, 336);
        for (uint256 i = 1; i < prices.length; ++i) {
            assertGt(prices[i], prices[i - 1], "strictly increasing");
        }
        IUniformEditionAuction.Settlement memory s = ua.settlement(saleId);
        assertEq(s.count, 0);
        assertEq(ua.departures(saleId, 3).length, 0);
    }

    function test_Lens_RejectsUnknownSalesAndBadArguments() public {
        bytes memory unknown =
            abi.encodeWithSelector(IUniformEditionAuction.UnknownAuction.selector, 5);
        vm.expectRevert(unknown);
        ua.auction(5);
        vm.expectRevert(unknown);
        ua.endTimes(5);
        vm.expectRevert(unknown);
        ua.clearing(5);
        vm.expectRevert(unknown);
        ua.stepTotals(5);
        vm.expectRevert(unknown);
        ua.quote(5, 0, 1);
        vm.expectRevert(unknown);
        ua.lowestWinningStep(5, 1);
        vm.expectRevert(unknown);
        ua.settlementOrder(5);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.UnknownBid.selector, 5, 1));
        ua.bidOf(5, 1);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.UnknownBid.selector, 5, 1));
        ua.bidOutcome(5, 1);
        uint256 saleId = _open(0);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.InvalidStep.selector, 336));
        ua.stepPrice(saleId, 336);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.InvalidStep.selector, 336));
        ua.quote(saleId, 336, 1);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.InvalidQuantity.selector, 0));
        ua.quote(saleId, 3, 0);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.InvalidQuantity.selector, 0));
        ua.lowestWinningStep(saleId, 0);
    }

    function test_Lens_EmptyBook() public {
        uint256 saleId = _open(0);
        (uint256 low, uint256[] memory units) = ua.stepTotals(saleId);
        assertEq(low, 0);
        assertEq(units.length, 0);
        assertEq(ua.clearing(saleId).count, 0);
        assertEq(ua.settlementOrder(saleId).length, 0);
        // Any first bid wins: the lowest winning step is the base.
        (bool found, uint256 step) = ua.lowestWinningStep(saleId, 5);
        assertTrue(found);
        assertEq(step, 0);
        IUniformEditionAuction.Quote memory q = ua.quote(saleId, 10, 2);
        assertEq(q.unitsWon, 2);
        assertEq(q.result.count, 2);
        assertEq(q.unitsPushedOut, 0);
        assertEq(q.unitsPulledIn, 0);
    }

    function test_Lens_EndTimesAndStatus() public {
        uint256 saleId = _open(0);
        uint64 end = uint64(block.timestamp + 1 days);
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(e.oneOfOneEnd, end);
        assertEq(e.closeAt, end + 15 minutes);
        assertEq(e.softEnd, 0);
        assertEq(e.endTime, end + 15 minutes);
        assertEq(e.backstop, end + 15 minutes + 1 days);
        assertTrue(e.biddingOpen);
        assertFalse(e.withdrawalsOpen);
        vm.warp(end + 15 minutes);
        assertFalse(ua.endTimes(saleId).biddingOpen);
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.CLOSED)
        );
        // The 1/1 reopens after a currency freeze: the edition sale reopens with it.
        english.set(
            address(stream),
            ID,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        assertTrue(ua.endTimes(saleId).biddingOpen);
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.OPEN));
        _bid(saleId, alice, 0, 1);
    }

    function test_Lens_OutcomesQueueAndQuotesUnderACap() public {
        uint256 saleId = _open(5);
        _bid(saleId, alice, 100, 3); // position 0
        _bid(saleId, bob, 100, 3); // position 3: 2 of 3 win
        _bid(saleId, carol, 100, 2); // position 6: none win
        IUniformEditionAuction.BidOutcome memory o = ua.bidOutcome(saleId, 2);
        assertEq(o.unitsWon, 2);
        assertEq(o.unitsAhead, 3);
        assertEq(o.price, _price(saleId, 100));
        assertEq(o.refund, o.escrow - 2 * o.price);
        assertFalse(o.isFinal);
        o = ua.bidOutcome(saleId, 3);
        assertEq(o.unitsWon, 0);
        assertEq(o.price, 0);
        assertEq(o.unitsAhead, 6);
        // A bid one step up wins in full and pushes the queue's tail out.
        IUniformEditionAuction.Quote memory q = ua.quote(saleId, 101, 2);
        assertEq(q.unitsWon, 2);
        assertEq(q.unitsPushedOut, 2);
        assertEq(q.unitsPulledIn, 0);
        assertEq(q.escrow, 2 * _price(saleId, 101));
        assertEq(q.result.count, 5);
        assertTrue(q.result.rationed);
        assertEq(q.result.cutUnits, 3);
        // At the cut step a new bid joins the back: nothing left for it.
        q = ua.quote(saleId, 100, 1);
        assertEq(q.unitsWon, 0);
        (bool found, uint256 step) = ua.lowestWinningStep(saleId, 1);
        assertTrue(found);
        assertEq(step, 101);
    }

    function test_Lens_NoWinningStepWhenTheCapIsFilledAtTheTop() public {
        uint256 saleId = _open(2);
        _bid(saleId, alice, 335, 2);
        (bool found, uint256 step) = ua.lowestWinningStep(saleId, 1);
        assertFalse(found);
        assertEq(step, 0);
    }

    function test_Lens_SettlementOrderAcrossTheSweep() public {
        uint256 saleId = _open(5);
        _bid(saleId, alice, 10, 2); // 0
        _bid(saleId, bob, 10, 2); // 2
        _bid(saleId, carol, 10, 3); // 4
        _bid(saleId, makeAddr("dan"), 10, 3); // 7
        _raise(saleId, 2, 11); // departure 0 at position 2
        _raise(saleId, 1, 11); // departure 1 at position 0
        uint256[] memory order = ua.settlementOrder(saleId);
        assertEq(order.length, 2);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        uint256[] memory first = new uint256[](1);
        first[0] = order[0];
        uint256 balance = address(auction).balance;
        auction.settle(saleId, first);
        paidOut += balance - address(auction).balance;
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        // While settling: what is left of the order, the stored progress, the final outcomes.
        uint256[] memory rest = ua.settlementOrder(saleId);
        assertEq(rest.length, 1);
        assertEq(rest[0], order[1]);
        IUniformEditionAuction.Settlement memory s = ua.settlement(saleId);
        assertEq(s.departures, 2);
        assertEq(s.departuresSwept, 1);
        assertEq(s.cutoff, 3);
        assertEq(ua.clearing(saleId).cutoff, 5, "the live view gives the full sweep's cutoff");
        IUniformEditionAuction.BidOutcome memory o = ua.bidOutcome(saleId, 3);
        assertEq(o.unitsWon, 1);
        assertFalse(o.isFinal);
        auction.settle(saleId, rest);
        assertEq(ua.settlementOrder(saleId).length, 0);
        assertEq(ua.settlement(saleId).cutoff, 5);
        o = ua.bidOutcome(saleId, 3);
        assertTrue(o.isFinal);
        assertEq(o.unitsWon, 1);
        assertEq(_claimAll(saleId), 5);
        _assertConserved();
    }

    function test_Lens_VoidSale() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 10, 2);
        english.set(
            address(stream), ID, IEnglishAuction.AuctionState.CANCELLED, uint64(block.timestamp + 1)
        );
        auction.settle(saleId, new uint256[](0));
        assertEq(ua.clearing(saleId).count, 0);
        assertEq(ua.settlement(saleId).count, 0);
        assertEq(ua.settlementOrder(saleId).length, 0);
        assertFalse(ua.endTimes(saleId).biddingOpen);
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
    }

    function test_Lens_NetworkFeeAndStepTotals() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 130, 80);
        _bid(saleId, bob, 132, 1);
        IUniformEditionAuction.Clearing memory c = ua.clearing(saleId);
        assertEq(c.count, 81);
        assertEq(c.networkFee, c.revenue * FEE_SHARE / 100_000);
        (uint256 low, uint256[] memory units) = ua.stepTotals(saleId);
        assertEq(low, 130);
        assertEq(units.length, 3);
        assertEq(units[0], 80);
        assertEq(units[1], 0);
        assertEq(units[2], 1);
    }
}
