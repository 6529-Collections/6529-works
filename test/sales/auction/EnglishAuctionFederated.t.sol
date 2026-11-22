// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { AuctionFixture } from "./AuctionFixture.sol";
import { BidderContract } from "./AuctionMocks.sol";

/// @notice Federated tokens: the federation module as their policy, unsold works waiting in
///         custody and offered again, delisting, and the refused-settlement exit.
contract EnglishAuctionFederatedTest is AuctionFixture {
    function test_Federated_StartsThroughTheFederationModule() public {
        uint256 saleId = _startFed(1);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.token, address(fed));
        assertEq(a.seller, fedSeller);
        assertEq(a.feeShare, FED_FEE_SHARE);
        assertEq(fed.ownerOf(1), address(auction));
    }

    function test_Federated_AnUnlistedTokenCannotStart() public {
        federation.setMinter(address(fed), address(auction), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(fed), address(auction)
            )
        );
        _startFed(1);
    }

    function test_Federated_SoldPaysTheFederatedFeeRecipient() public {
        address fedFee = makeAddr("fedFee");
        (uint64 rev,,) = economics.revisions(PRODUCT_FEDERATED);
        economics.setFeeTerms(PRODUCT_FEDERATED, rev, fedFee, 5_000);
        uint256 saleId = _startFed(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(fedFee.balance, 0.05 ether);
        assertEq(fedSeller.balance, 0.95 ether);
        assertEq(fed.ownerOf(1), alice);
        assertEq(uint256(fed.workOf(1).outcome), uint256(Outcome.SOLD));
    }

    function test_Federated_AnUnsoldWorkStaysInCustodyWithNoOutcome() public {
        uint256 saleId = _startFed(1);
        _end(saleId);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.SaleSettled(
            saleId,
            address(fed),
            1,
            address(0),
            address(auction),
            1,
            address(0),
            0,
            fedSeller,
            0,
            address(0),
            0
        );
        auction.settle(saleId);
        assertEq(fed.ownerOf(1), address(auction));
        assertEq(uint256(fed.workOf(1).outcome), uint256(Outcome.NONE));
        assertEq(auction.pendingDelivery(saleId), address(0), "the artist cannot take it");
    }

    function test_Restart_OffersAnUnsoldWorkAgainAndSellsIt() public {
        uint256 saleId = _startFed(1);
        _end(saleId);
        auction.settle(saleId);
        vm.warp(block.timestamp + 5 days);
        vm.prank(carol);
        auction.restart(saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint256(a.state), uint256(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(a.endTime, block.timestamp + DURATION);
        assertEq(a.seller, fedSeller);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(fed.ownerOf(1), alice);
        assertEq(uint256(fed.workOf(1).outcome), uint256(Outcome.SOLD));
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
        // A live federated sale does not restart.
        uint256 saleId = _startFed(1);
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
        federation.setMinter(address(fed), address(auction), false);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.TargetNotAllowed.selector, address(fed))
        );
        auction.restart(saleId);
    }

    function test_Restart_RefusedForASoldWorkPendingDelivery() public {
        BidderContract b = new BidderContract(IEnglishAuction(address(auction)));
        b.set(false, true, false);
        uint256 saleId = _startFed(1);
        b.bid{ value: 1 ether }(saleId, address(0));
        _end(saleId);
        auction.settle(saleId);
        // Sold, and still in custody waiting for its winner's claim: never offered again.
        assertEq(fed.ownerOf(1), address(auction));
        assertEq(uint256(fed.workOf(1).outcome), uint256(Outcome.SOLD));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.SETTLED
            )
        );
        auction.restart(saleId);
        b.claimDelivery(saleId, carol);
        assertEq(fed.ownerOf(1), carol);
    }

    function test_Delisted_RefusesBidsAndEndsUnsoldWithARefund() public {
        uint256 saleId = _startFed(1);
        _bid(alice, saleId, 1 ether);
        federation.setMinter(address(fed), address(auction), false);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.TargetNotAllowed.selector, address(fed))
        );
        auction.bid{ value: 2 ether }(saleId, address(0));
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.claimable(alice), 1 ether);
        assertEq(fed.ownerOf(1), address(auction));
        assertEq(fedSeller.balance, 0);
    }

    function test_SettleOrRefund_OnlyFederatedAndOnlyAfterTheDelay() public {
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
        uint256 saleId = _startFed(1);
        _end(saleId);
        uint256 at = auction.refusableAt(saleId);
        assertEq(at, block.timestamp + 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuctionRefusal.RefusalTooEarly.selector, saleId, at)
        );
        auction.settleOrRefund(saleId);
    }

    function test_SettleOrRefund_SettlesWhenTheTokenCooperates() public {
        uint256 saleId = _startFed(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        vm.warp(block.timestamp + 2 days);
        auction.settleOrRefund(saleId);
        assertEq(fed.ownerOf(1), alice);
        assertEq(fedSeller.balance, 0.95 ether);
    }

    function test_SettleOrRefund_ClosesWithARefundWhenTheTokenRefuses() public {
        uint256 saleId = _startFed(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        vm.warp(block.timestamp + 2 days);
        // The gate no longer counts the auction as a federated minter: the token refuses to
        // record the sale, so the whole settlement fails.
        federation.forget(address(auction));
        vm.expectEmit(address(auction));
        emit IEnglishAuctionRefusal.SettlementRefused(saleId);
        auction.settleOrRefund(saleId);
        assertEq(auction.claimable(alice), 1 ether);
        assertEq(fed.ownerOf(1), address(auction));
        assertEq(uint256(fed.workOf(1).outcome), uint256(Outcome.NONE));
        assertEq(fedSeller.balance, 0);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.SETTLED));
        // Once the token cooperates again the work is offered again.
        federation.setMinter(address(fed), address(auction), true);
        auction.restart(saleId);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.ACTIVE));
    }

    function test_SettleOrRefund_AShortfallIsNeverARefusal() public {
        uint256 saleId = _startFed(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        vm.warp(block.timestamp + 2 days);
        federation.forget(address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallInsufficientGas.selector, REFUSAL_GAS)
        );
        auction.settleOrRefund{ gas: 2_500_000 }(saleId);
        assertEq(auction.claimable(alice), 0);
    }
}
