// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IndependentEditionAuctionTest } from "../sales/edition/IndependentEditionAuction.t.sol";

/// @notice What `IndependentEditionAuction` adds to the shared auction and the mutation campaign
///         found unpinned: `raise` (served and delisted), and the three states `settle` must not
///         void (a listed sale's scan, a clearing that has paid, a sale already void). Runs the
///         Independent Stream edition auction suite again with these cases added.
contract IndependentEditionAuctionMutationTest is IndependentEditionAuctionTest {
    function _raise(uint256 saleId, address bidder, uint256 bidId, uint256 newStep) internal {
        IUniformEditionAuction.Bid memory b = ua.bidOf(saleId, bidId);
        uint256 amount =
            uint256(b.quantity) * (ua.stepPrice(saleId, newStep) - ua.stepPrice(saleId, b.step));
        vm.deal(bidder, amount);
        vm.prank(bidder);
        auction.raise{ value: amount }(saleId, bidId, newStep);
    }

    function _status(uint256 saleId) internal view returns (uint8) {
        return uint8(ua.auction(saleId).status);
    }

    /// @dev The opening event names the master of the sale's own edition contract, the 1/1
    ///      contract whose sale it follows.
    function test_Open_TheEventNamesTheEditionContractsMaster() public {
        vm.recordLogs();
        uint256 saleId = _open();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IUniformEditionAuction.AuctionOpened.selector) continue;
            assertEq(logs[i].emitter, address(auction));
            assertEq(uint256(logs[i].topics[1]), saleId);
            // The master is the first word of the event's data.
            assertEq(address(uint160(uint256(bytes32(logs[i].data)))), address(master));
            ++found;
        }
        assertEq(found, 1, "one AuctionOpened");
    }

    /// @dev The Independent Stream lens reads its module from the directory and accepts no other.
    function test_SetIndependentStreamRegistry_TheLensRefusesAnyModule() public {
        address next = makeAddr("next");
        IUniformEditionAuctionLens lens = _lens();
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, next));
        lens.setIndependentStreamRegistry(address(gate), next);
    }

    function test_Raise_MovesTheBidUpForTheDifference() public {
        uint256 saleId = _open();
        uint256 bidId = _bid(saleId, alice, 10, 2);
        uint256 paid = 2 * (ua.stepPrice(saleId, 12) - ua.stepPrice(saleId, 10));
        // An uncapped sale has no queue position, and a raise this early leaves the end as it is.
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.BidRaised(
            saleId, bidId, alice, 10, 12, 0, paid, ua.endTimes(saleId).endTime
        );
        _raise(saleId, alice, bidId, 12);
        assertEq(ua.bidOf(saleId, bidId).step, 12);
        assertEq(address(auction).balance, 2 * ua.stepPrice(saleId, 12));
        assertEq(alice.balance, 0);
    }

    function test_Raise_RefusedOnceDelisted() public {
        uint256 saleId = _open();
        uint256 bidId = _bid(saleId, alice, 10, 1);
        gate.setActive(address(token), false);
        uint256 amount = ua.stepPrice(saleId, 12) - ua.stepPrice(saleId, 10);
        vm.deal(alice, amount);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.BiddingClosed.selector, saleId, 0)
        );
        auction.raise{ value: amount }(saleId, bidId, 12);
        assertEq(ua.bidOf(saleId, bidId).step, 10);
    }

    /// @dev A wide book's scan takes two calls: while the token stays listed the second call
    ///      clears and pays, it does not void.
    function test_Settle_AListedSalesScanFinishesOnALaterCall() public {
        uint256 saleId = _open();
        _bid(saleId, alice, 0, 1);
        _bid(saleId, bob, 335, 1);
        _close(saleId);
        assertFalse(auction.settle(saleId, new uint256[](0)));
        assertEq(_status(saleId), uint8(IUniformEditionAuction.AuctionStatus.SETTLING));
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(_status(saleId), uint8(IUniformEditionAuction.AuctionStatus.SETTLED));
        assertGt(fee.balance + seller.balance, 0, "paid");
    }

    /// @dev A sale voided while its scan was in progress stays void: a later settle call is
    ///      refused, it does not void the sale a second time.
    function test_Settle_ASaleVoidedDuringTheScanRefusesLaterCalls() public {
        uint256 saleId = _open();
        _bid(saleId, alice, 0, 1);
        _bid(saleId, bob, 335, 1);
        _close(saleId);
        assertFalse(auction.settle(saleId, new uint256[](0)));
        gate.setActive(address(token), false);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.VOID
            )
        );
        auction.settle(saleId, new uint256[](0));
    }

    /// @dev Once the clearing call has paid, the clearing stands: a capped sale whose departure
    ///      sweep is still in progress (SETTLING, the scan done) is not voided by a delisting; the
    ///      next settle call finishes the sweep and the winners claim.
    function test_Settle_AClearingThatPaidStandsThroughADelisting() public {
        PackageItem memory item = _item();
        item.edition = EditionTerms(25, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        master.setWork(ID, WorksHashing.itemHash(item), ItemKind.EDITION_MASTER);
        uint256 saleId = auction.open(address(token), ID, abi.encode(item));
        // 30 one-unit bids at step 10, 20 of them raised to step 11 in reverse order: demand 30
        // for 25 copies, and 20 departures at the cut step (more than the clearing call sweeps).
        for (uint256 i; i < 30; ++i) {
            _bid(saleId, alice, 10, 1);
        }
        for (uint256 bidId = 30; bidId > 10; --bidId) {
            _raise(saleId, alice, bidId, 11);
        }
        uint256[] memory order = ua.settlementOrder(saleId);
        assertEq(order.length, 20);
        _close(saleId);
        assertFalse(auction.settle(saleId, order), "cleared and paid, the sweep in progress");
        assertEq(_status(saleId), uint8(IUniformEditionAuction.AuctionStatus.SETTLING));
        uint256 paid = fee.balance + seller.balance;
        assertEq(paid, 25 * ua.stepPrice(saleId, 10));

        // Neither a delisting nor a cancelled 1/1 voids it now.
        gate.setActive(address(token), false);
        english.set(address(master), ID, IEnglishAuction.AuctionState.CANCELLED, 0);
        vm.prank(bob);
        assertTrue(auction.settle(saleId, order));
        assertEq(_status(saleId), uint8(IUniformEditionAuction.AuctionStatus.SETTLED));
        assertEq(fee.balance + seller.balance, paid);
        vm.prank(alice);
        (uint256 won,) = auction.claimBid(saleId, 30, alice);
        assertEq(won, 1);
        assertEq(token.balanceOf(alice, ID), 1);
    }
}
