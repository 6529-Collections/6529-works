// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { PRODUCT_INDEPENDENT } from "src/interfaces/types/EconomicsTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { AuctionFixture } from "./AuctionFixture.sol";
import { BidderContract } from "./AuctionMocks.sol";

/// @notice Independent Stream tokens: the Independent Stream module as their policy, unsold works
///         waiting in custody and offered again, delisting, and the refused-settlement exit.
contract EnglishAuctionIndependentTest is AuctionFixture {
    function test_Independent_StartsThroughTheIndependentStreamModule() public {
        uint256 saleId = _startInd(1);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.token, address(ind));
        assertEq(a.seller, indSeller);
        assertEq(a.feeShare, IND_FEE_SHARE);
        assertEq(ind.ownerOf(1), address(auction));
    }

    function test_Independent_AnUnlistedTokenCannotStart() public {
        independentStream.setMinter(address(ind), address(auction), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(ind), address(auction)
            )
        );
        _startInd(1);
    }

    function test_Independent_SoldPaysTheIndependentFeeRecipient() public {
        address indFee = makeAddr("indFee");
        (uint64 rev,,) = economics.revisions(PRODUCT_INDEPENDENT);
        economics.setFeeTerms(PRODUCT_INDEPENDENT, rev, indFee, 5_000);
        uint256 saleId = _startInd(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(indFee.balance, 0.05 ether);
        assertEq(indSeller.balance, 0.95 ether);
        assertEq(ind.ownerOf(1), alice);
        assertEq(uint256(ind.workOf(1).outcome), uint256(Outcome.SOLD));
    }

    function test_Independent_AnUnsoldWorkStaysInCustodyWithNoOutcome() public {
        uint256 saleId = _startInd(1);
        _end(saleId);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.SaleSettled(
            saleId,
            address(ind),
            1,
            address(0),
            address(auction),
            1,
            address(0),
            0,
            indSeller,
            0,
            address(0),
            0
        );
        auction.settle(saleId);
        assertEq(ind.ownerOf(1), address(auction));
        assertEq(uint256(ind.workOf(1).outcome), uint256(Outcome.NONE));
        assertEq(auction.pendingDelivery(saleId), address(0), "the artist cannot take it");
    }

    function test_Restart_OffersAnUnsoldWorkAgainAndSellsIt() public {
        uint256 saleId = _startInd(1);
        _end(saleId);
        auction.settle(saleId);
        vm.warp(block.timestamp + 5 days);
        vm.prank(carol);
        auction.restart(saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint256(a.state), uint256(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(a.endTime, block.timestamp + DURATION);
        assertEq(a.seller, indSeller);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(ind.ownerOf(1), alice);
        assertEq(uint256(ind.workOf(1).outcome), uint256(Outcome.SOLD));
    }

    /// @dev The clock answers when a work was last offered again: zero for a sale never
    ///      restarted, the restart's time after each restart. A sale that followed the earlier
    ///      sale reads it to learn that sale is over.
    function test_Restart_TheClockAnswersWhenTheWorkWasOfferedAgain() public {
        uint256 saleId = _startInd(1);
        (,,, uint64 restartedAt) = auction.auctionClock(saleId);
        assertEq(restartedAt, 0, "never offered again");
        _end(saleId);
        auction.settle(saleId);
        (,,, restartedAt) = auction.auctionClock(saleId);
        assertEq(restartedAt, 0, "settling records nothing");

        vm.warp(block.timestamp + 10 minutes);
        uint64 first = uint64(block.timestamp);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.SaleStarted(
            saleId,
            address(ind),
            1,
            SaleKind.ENGLISH_AUCTION,
            address(0),
            allowlist.openingBid(address(0)),
            first,
            first + DURATION
        );
        vm.prank(carol);
        auction.restart(saleId);
        IEnglishAuction.AuctionState state;
        uint64 end;
        (state, end,, restartedAt) = auction.auctionClock(saleId);
        assertEq(uint256(state), uint256(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(end, first + DURATION);
        assertEq(restartedAt, first, "the restart's time");

        _end(saleId);
        auction.settle(saleId);
        vm.warp(block.timestamp + 3 days);
        auction.restart(saleId);
        (,,, restartedAt) = auction.auctionClock(saleId);
        assertEq(restartedAt, block.timestamp, "the latest restart's time");

        // A 6529 Stream sale is never offered again, so its clock always answers zero.
        uint256 streamSale = _start(1);
        _end(streamSale);
        auction.settle(streamSale);
        (state,,, restartedAt) = auction.auctionClock(streamSale);
        assertEq(uint256(state), uint256(IEnglishAuction.AuctionState.SETTLED));
        assertEq(restartedAt, 0);
    }

    function test_Restart_Refusals() public {
        // A 6529 Stream sale never restarts.
        uint256 streamSale = _start(1);
        _end(streamSale);
        auction.settle(streamSale);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                streamSale,
                IEnglishAuction.AuctionState.SETTLED
            )
        );
        auction.restart(streamSale);
        // A live Independent Stream sale does not restart.
        uint256 saleId = _startInd(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.restart(saleId);
        _end(saleId);
        auction.settle(saleId);
        // Paused starts, and a delisted token.
        auction.pause();
        vm.expectRevert(IEnglishAuction.SalePaused.selector);
        auction.restart(saleId);
        auction.unpause();
        independentStream.setMinter(address(ind), address(auction), false);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.TargetNotAllowed.selector, address(ind))
        );
        auction.restart(saleId);
    }

    function test_Restart_RefusedForASoldWorkPendingDelivery() public {
        BidderContract b = new BidderContract(IEnglishAuction(address(auction)));
        b.set(false, true, false);
        uint256 saleId = _startInd(1);
        b.bid{ value: 1 ether }(saleId, address(0));
        _end(saleId);
        auction.settle(saleId);
        // Sold, and still in custody waiting for its winner's claim: never offered again.
        assertEq(ind.ownerOf(1), address(auction));
        assertEq(uint256(ind.workOf(1).outcome), uint256(Outcome.SOLD));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.SETTLED
            )
        );
        auction.restart(saleId);
        b.claimDelivery(saleId, carol);
        assertEq(ind.ownerOf(1), carol);
    }

    function test_Delisted_RefusesBidsAndEndsUnsoldWithARefund() public {
        uint256 saleId = _startInd(1);
        _bid(alice, saleId, 1 ether);
        independentStream.setMinter(address(ind), address(auction), false);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.TargetNotAllowed.selector, address(ind))
        );
        auction.bid{ value: 2 ether }(saleId, address(0));
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.claimable(alice), 1 ether);
        assertEq(ind.ownerOf(1), address(auction));
        assertEq(indSeller.balance, 0);
    }

    function test_SettleOrRefund_OnlyIndependentAndOnlyAfterTheDelay() public {
        uint256 streamSale = _start(1);
        _end(streamSale);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuctionRefusal.SaleNotRefusable.selector, streamSale)
        );
        auction.settleOrRefund(streamSale);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuctionRefusal.SaleNotRefusable.selector, streamSale)
        );
        auction.refusableAt(streamSale);
        uint256 saleId = _startInd(1);
        _end(saleId);
        uint256 at = auction.refusableAt(saleId);
        assertEq(at, block.timestamp + 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuctionRefusal.RefusalTooEarly.selector, saleId, at)
        );
        auction.settleOrRefund(saleId);
    }

    function test_SettleOrRefund_SettlesWhenTheTokenCooperates() public {
        uint256 saleId = _startInd(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        vm.warp(block.timestamp + 2 days);
        auction.settleOrRefund(saleId);
        assertEq(ind.ownerOf(1), alice);
        assertEq(indSeller.balance, 0.95 ether);
    }

    function test_SettleOrRefund_ClosesWithARefundWhenTheTokenRefuses() public {
        uint256 saleId = _startInd(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        vm.warp(block.timestamp + 2 days);
        // The gate no longer counts the auction as an Independent Stream minter: the token refuses
        // to record the sale, so the whole settlement fails.
        independentStream.forget(address(auction));
        vm.expectEmit(address(auction));
        emit IEnglishAuctionRefusal.SettlementRefused(saleId);
        auction.settleOrRefund(saleId);
        assertEq(auction.claimable(alice), 1 ether);
        assertEq(ind.ownerOf(1), address(auction));
        assertEq(uint256(ind.workOf(1).outcome), uint256(Outcome.NONE));
        assertEq(indSeller.balance, 0);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.SETTLED));
        // Once the token cooperates again the work is offered again.
        independentStream.setMinter(address(ind), address(auction), true);
        auction.restart(saleId);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.ACTIVE));
    }

    function test_SettleOrRefund_AShortfallIsNeverARefusal() public {
        uint256 saleId = _startInd(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        vm.warp(block.timestamp + 2 days);
        independentStream.forget(address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallInsufficientGas.selector, REFUSAL_GAS)
        );
        auction.settleOrRefund{ gas: 2_500_000 }(saleId);
        assertEq(auction.claimable(alice), 0);
    }
}
