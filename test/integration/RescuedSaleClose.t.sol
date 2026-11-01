// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { PrimaryOutcome } from "src/interfaces/types/SaleTypes.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";

/// @notice The English auction closes the sale of a work governance rescued to the museum
///         (owner decision 20) on the real stack. A 1/1 that ended with a winning bid nobody
///         settled, rescued 90 days after its adapter's removal, is already settled in 6529
///         Stream: `settle` then credits the winner back, pays nobody, mints and delivers
///         nothing, and marks the auction SETTLED, so the winner's ETH and the master's edition
///         sale are never stranded. A sale that was not rescued settles as before.
contract RescuedSaleCloseTest is EditionAuctionStack {
    address internal artist;
    address internal winner = makeAddr("rescueWinner");
    address internal fan = makeAddr("rescueFan");

    function setUp() public override {
        super.setUp();
        artist = _actor("rescuedMasterArtist");
    }

    /// @dev Governance removes the English auction as a Stream minter (30 days), and 90 days
    ///      later rescues `tokenId` (30 days more).
    function _rescue(uint256 tokenId) internal {
        _govern(
            hotAdmin,
            address(stream),
            abi.encodeCall(stream.setAdmittedMinter, (address(auction), false))
        );
        vm.warp(block.timestamp + 60 days);
        _govern(hotAdmin, address(stream), abi.encodeCall(stream.rescueToMuseum, (tokenId)));
        assertEq(stream.ownerOf(tokenId), museum, "rescued");
    }

    /// @dev The whole path: a master's 1/1 ended with a winning bid nobody settled, its edition
    ///      sale has a bid, and governance rescued the work. Before the 1/1 settles, the edition
    ///      sale cannot settle. The 1/1's `settle` then closes it with a refund only; the winner
    ///      claims the full bid back; the seller and the network get nothing; the work stays in
    ///      the museum. The edition sale then settles, the edition can be created from the
    ///      rescued master (Stream records it settled, UNBID) and the edition bidder claims
    ///      their copy, as after any unbid 1/1. Before the fix the 1/1's `settle` reverted
    ///      `SaleAlreadySettled` for good, locking the bid and the edition sale.
    function test_RescuedWorkWithAWinningBidClosesWithARefundAndFreesTheEdition() public {
        (bytes32 root, Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) =
            _startMaster(artist, 0);
        uint256 bidId = _editionBid(saleId, fan, 40, 1);
        _ethBid(oneSaleId, winner, 1 ether);
        vm.warp(auction.auction(oneSaleId).endTime);
        _rescue(tokenId);
        (PrimaryOutcome outcome,,) = stream.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.UNBID));
        _assertEditionWaits(saleId);

        _closeWithRefund(oneSaleId, tokenId);

        // The edition sale is free: the edition is created from the rescued master (Stream
        // records it settled, UNBID), the sale settles, and the edition bidder's copy is minted.
        editions.createEdition(tokenId, w.item, root, _proofOf(_one(w), 0));
        _settleEditions(saleId);
        vm.prank(fan);
        (uint256 won,) = editionAuction.claimBid(saleId, bidId, fan);
        assertEq(won, 1);
        assertEq(editions.balanceOf(fan, tokenId), 1, "the edition copy");
    }

    /// @dev Stranded until the 1/1 closes: the edition sale waits on a SETTLED 1/1.
    function _assertEditionWaits(uint256 saleId) internal {
        IUniformEditionAuction.EndTimes memory e = ea.endTimes(saleId);
        if (block.timestamp < e.endTime) vm.warp(e.endTime);
        uint256[] memory order = _orderFor(saleId, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        editionAuction.settle(saleId, order);
    }

    /// @dev The 1/1's `settle` after the rescue: a refund of the winning bid, nothing reported,
    ///      paid or delivered, the auction SETTLED; the winner claims the full bid back.
    function _closeWithRefund(uint256 oneSaleId, uint256 tokenId) internal {
        address seller = auction.lockedTerms(oneSaleId).seller;
        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = networkFee.balance;
        vm.expectCall(address(stream), abi.encodeWithSelector(stream.settlePrimary.selector), 0);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(winner, CURRENCY_ETH, oneSaleId, 1 ether);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(oneSaleId);
        vm.recordLogs();
        auction.settle(oneSaleId);
        _assertNoSaleSettled(vm.getRecordedLogs());

        assertEq(
            uint8(auction.auction(oneSaleId).state), uint8(IEnglishAuction.AuctionState.SETTLED)
        );
        (IEnglishAuction.AuctionState clock,,) = auction.auctionClock(oneSaleId);
        assertEq(uint8(clock), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(auction.auction(oneSaleId).bidder, address(0), "no winner");
        assertEq(auction.pendingDelivery(oneSaleId), address(0), "nothing to deliver");
        assertEq(stream.ownerOf(tokenId), museum, "the work stays in the museum");
        assertEq(seller.balance, sellerBefore, "the seller is paid nothing");
        assertEq(networkFee.balance, feeBefore, "the network is paid nothing");
        assertEq(auction.claimable(winner, CURRENCY_ETH), 1 ether);
        uint256 winnerBefore = winner.balance;
        vm.prank(winner);
        auction.claim(CURRENCY_ETH, winner);
        assertEq(winner.balance - winnerBefore, 1 ether, "the winning bid, in full");
        // Settling again is refused, as for any settled sale.
        vm.expectRevert();
        auction.settle(oneSaleId);
    }

    /// @dev A rescue with no standing bid: the sale closes with nothing to credit.
    function test_RescuedWorkWithNoBidClosesWithNothingToCredit() public {
        (,, uint256 oneSaleId, uint256 tokenId,) = _startMaster(artist, 0);
        vm.warp(auction.auction(oneSaleId).endTime);
        _rescue(tokenId);
        vm.recordLogs();
        auction.settle(oneSaleId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNoSaleSettled(logs);
        assertEq(logs.length, 1, "only RescuedSaleClosed");
        assertEq(logs[0].topics[0], IEnglishAuction.RescuedSaleClosed.selector);
        assertEq(
            uint8(auction.auction(oneSaleId).state), uint8(IEnglishAuction.AuctionState.SETTLED)
        );
    }

    /// @dev Without a rescue the normal path is unchanged: Stream is asked for the outcome
    ///      (NONE), then told SOLD, the seller and the network are paid, the winner receives the
    ///      work, and `RescuedSaleClosed` is never emitted.
    function test_AWorkNotRescuedSettlesAsBefore() public {
        (,, uint256 oneSaleId, uint256 tokenId,) = _startMaster(artist, 0);
        _ethBid(oneSaleId, winner, 1 ether);
        vm.warp(auction.auction(oneSaleId).endTime);
        uint256 feeBefore = networkFee.balance;
        vm.expectCall(address(stream), abi.encodeCall(stream.primarySale, (tokenId)), 1);
        vm.expectCall(address(stream), abi.encodeWithSelector(stream.settlePrimary.selector), 1);
        vm.recordLogs();
        auction.settle(oneSaleId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool settled;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IEnglishAuction.RescuedSaleClosed.selector);
            if (logs[i].topics[0] == ISaleAdapter.SaleSettled.selector) settled = true;
        }
        assertTrue(settled, "SaleSettled");
        assertEq(stream.ownerOf(tokenId), winner);
        assertTrue(stream.primarySaleSettled(tokenId), "reported to Stream");
        assertEq(networkFee.balance - feeBefore, 0.25 ether, "25% to the network");
        assertEq(auction.claimable(winner, CURRENCY_ETH), 0, "nothing credited");
    }

    function _assertNoSaleSettled(Vm.Log[] memory logs) internal pure {
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ISaleAdapter.SaleSettled.selector, "no SaleSettled");
            assertTrue(logs[i].topics[0] != IStream.PrimarySaleSettled.selector, "no report");
        }
    }
}
