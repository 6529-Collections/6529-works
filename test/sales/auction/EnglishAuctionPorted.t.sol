// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { AuctionFixture } from "./AuctionFixture.sol";
import { ReentrantRecipient } from "../../mocks/economics/EconomicsMocks.sol";

/// @notice Re-ported from the retired auction's suites: the guard `expireCredit` holds while it
///         pays the network (found by mutation testing), and `settleOrRefund` refused while the
///         escrow holds its guard (`escrow.locked()`), including a caller inside an escrow flush.
contract EnglishAuctionPortedTest is AuctionFixture {
    /// @dev Credits `amount` to alice: she bids it and carol outbids her.
    function _creditAlice(uint256 n, uint256 amount) internal {
        uint256 saleId = _start(n);
        _bid(alice, saleId, amount);
        _bid(carol, saleId, auction.minimumBid(saleId));
    }

    /// @dev An Independent Stream sale with alice's standing bid, ended and past the refusal delay.
    function _refusableSale() internal returns (uint256 saleId) {
        saleId = _startInd(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        vm.warp(auction.refusableAt(saleId));
    }

    // ------------------------------------------------------------------ expireCredit

    /// @dev `expireCredit` holds the reentrancy guard while it pays the network's recipient: a
    ///      recipient calling back into the auction (here to expire the same credit again) is
    ///      refused on the guard, and the credit is paid once.
    function test_ExpireCredit_AReentrantRecipientIsBlocked() public {
        _creditAlice(1, 1 ether);
        ReentrantRecipient recipient = new ReentrantRecipient();
        recipient.configure(address(auction), abi.encodeCall(IEnglishAuction.expireCredit, (alice)));
        vm.mockCall(
            address(economics),
            abi.encodeCall(IEconomicsResolver.networkFeeRecipient, (PRODUCT_STREAM)),
            abi.encode(address(recipient))
        );
        vm.warp(block.timestamp + directory.unclaimedPeriod());
        assertEq(auction.expireCredit(alice), 1 ether);
        assertTrue(recipient.entered(), "the recipient called back");
        assertFalse(recipient.lastOk(), "the reentry was refused");
        assertEq(
            recipient.lastResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "on the guard"
        );
        assertEq(address(recipient).balance, 1 ether, "paid once");
        assertEq(auction.claimable(alice), 0);
    }

    /// @dev The same reentry into `claim` by a recipient that holds a credit of its own: refused
    ///      on the guard, the recipient's credit untouched.
    function test_ExpireCredit_AReentrantClaimIsBlocked() public {
        ReentrantRecipient recipient = new ReentrantRecipient();
        _creditAlice(1, 1 ether);
        // The recipient also holds a credit: it bids and is outbid.
        uint256 saleId = _start(2);
        vm.deal(address(recipient), 2 ether);
        vm.prank(address(recipient));
        auction.bid{ value: 2 ether }(saleId, address(0));
        _bid(carol, saleId, auction.minimumBid(saleId));
        recipient.configure(
            address(auction), abi.encodeCall(IEnglishAuction.claim, (address(recipient)))
        );
        vm.mockCall(
            address(economics),
            abi.encodeCall(IEconomicsResolver.networkFeeRecipient, (PRODUCT_STREAM)),
            abi.encode(address(recipient))
        );
        vm.warp(block.timestamp + directory.unclaimedPeriod());
        assertEq(auction.expireCredit(alice), 1 ether);
        assertFalse(recipient.lastOk());
        assertEq(
            recipient.lastResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(auction.claimable(address(recipient)), 2 ether, "its own credit untouched");
    }

    // ------------------------------------------------------------------ settleOrRefund

    /// @dev While the escrow reports its guard held, `settleOrRefund` is refused on the guard
    ///      error before any attempt: nothing settles, nothing is credited back.
    function test_SettleOrRefund_RefusedWhileTheEscrowIsLocked() public {
        uint256 saleId = _refusableSale();
        independentStream.forget(address(auction)); // an attempt now would fail and refund
        vm.mockCall(address(escrow), abi.encodeCall(IRevenueEscrow.locked, ()), abi.encode(true));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        auction.settleOrRefund(saleId);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.ENDED));
        assertEq(auction.claimable(alice), 0, "no refund");
        assertEq(auction.auction(saleId).bidder, alice, "the bid still stands");

        vm.clearMockedCalls();
        vm.expectEmit(address(auction));
        emit IEnglishAuctionRefusal.SettlementRefused(saleId);
        auction.settleOrRefund(saleId);
        assertEq(auction.claimable(alice), 1 ether, "refunded once the escrow is free");
    }

    /// @dev The real case the check exists for: a wallet the escrow pays during a flush (the
    ///      escrow's guard held) calls `settleOrRefund`; it is refused, and the sale is untouched.
    function test_SettleOrRefund_RefusedFromInsideAnEscrowFlush() public {
        uint256 saleId = _refusableSale();
        independentStream.forget(address(auction));
        ReentrantRecipient inside = new ReentrantRecipient();
        inside.configure(
            address(auction), abi.encodeCall(IEnglishAuctionRefusal.settleOrRefund, (saleId))
        );
        vm.deal(address(this), 1);
        escrow.depositETH{ value: 1 }(address(inside));
        escrow.flush(address(inside), address(0));
        assertTrue(inside.entered());
        assertFalse(inside.lastOk(), "refused inside the flush");
        assertEq(
            inside.lastResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.ENDED));
        assertEq(auction.claimable(alice), 0);
    }

    /// @dev The escrow is asked with a plain call: if the read fails, `settleOrRefund` reverts
    ///      with the escrow's reason instead of taking the failure for "free".
    function test_SettleOrRefund_AFailingLockReadReverts() public {
        uint256 saleId = _refusableSale();
        vm.mockCallRevert(
            address(escrow), abi.encodeCall(IRevenueEscrow.locked, ()), bytes("escrow down")
        );
        vm.expectRevert(bytes("escrow down"));
        auction.settleOrRefund(saleId);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.ENDED));
    }
}
