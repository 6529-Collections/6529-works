// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { IndependentEditionAuctionTest } from "./IndependentEditionAuction.t.sol";

/// @notice Rules of `docs/spec/independent-stream.md` for the Independent Stream edition auction:
///         the fee share a sale stores at open (IND-54), bids and raises on a sale that is no
///         longer served (IND-55), and `abandon` (IND-56). Runs the Independent Stream edition
///         auction suite again on the same fixture.
contract IndependentEditionAuctionRulesTest is IndependentEditionAuctionTest {
    function _lens() internal view returns (IUniformEditionAuctionLens) {
        return IUniformEditionAuctionLens(auction.lens());
    }

    function _setOneOfOne(IEnglishAuction.AuctionState state) internal {
        (, uint64 end) = english.clockOf(address(master), ID);
        english.set(address(master), ID, state, end);
    }

    function _expectNotAbandonable(uint256 saleId) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        auction.abandon(saleId);
    }

    // ------------------------------------------------------------------ the fee share (IND-54)

    /// The sale stores the Independent Stream module's share for the token when it opens. A later
    /// change of the module's answer, or of the economics resolver's share, does not move it: the
    /// settlement pays the network at the stored share (IND-54).
    function test_Open_TheStoredShareIsNotMovedByLaterAnswers() public {
        uint32 atOpen = 4000;
        gate.setFeeShare(address(token), atOpen);
        uint256 saleId = _open();
        gate.setFeeShare(address(token), 0);
        economics.set(seller, fee, 50_000);
        assertEq(ua.auction(saleId).feeShare, atOpen, "stored at open");

        _bid(saleId, alice, 100, 2);
        _close(saleId);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        uint256 revenue = 2 * ua.stepPrice(saleId, 100);
        uint256 networkFee = revenue - revenue * (100_000 - atOpen) / 100_000;
        assertGt(networkFee, 0);
        assertEq(fee.balance, networkFee, "the network's part at the stored share");
        assertEq(seller.balance, revenue - networkFee, "the seller's part");
    }

    // ------------------------------------------------------------------ not served (IND-55)

    /// Once the module stops serving the sale's contract, a raise of a standing bid is refused as
    /// a new bid is (`BiddingClosed` with end zero), whatever the time (IND-55).
    function test_Delisted_ARaiseIsRefused() public {
        uint256 saleId = _open();
        uint256 bidId = _bid(saleId, alice, 100, 1);
        gate.setActive(address(token), false);
        uint256 more = ua.stepPrice(saleId, 110) - ua.stepPrice(saleId, 100);
        vm.deal(alice, more);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.BiddingClosed.selector, saleId, 0)
        );
        auction.raise{ value: more }(saleId, bidId, 110);
        assertEq(alice.balance, more, "nothing was taken");
    }

    /// Once the module stops serving the sale's contract, the sale's own views report its 1/1 as
    /// cancelled and bidding as closed, although the 1/1's auction still answers that it is
    /// active.
    function test_Delisted_TheSalesViewsReportTheOneOfOneCancelled() public {
        uint256 saleId = _open();
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertTrue(e.biddingOpen);

        gate.setActive(address(token), false);
        (IEnglishAuction.AuctionState state,) = english.clockOf(address(master), ID);
        assertEq(uint8(state), uint8(IEnglishAuction.AuctionState.ACTIVE), "the 1/1 itself");
        e = ua.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.CANCELLED));
        assertFalse(e.biddingOpen);
    }

    // ------------------------------------------------------------------ abandon (IND-56)

    /// `abandon` is refused while the sale's 1/1 is live. Once the 1/1 is cancelled it is refused
    /// until the compiled wait after the edition's close has passed, and accepted from then, by
    /// anyone: the sale is void, the edition is sealed at zero and the bid is refunded in full
    /// (IND-56).
    function test_Abandon_AfterTheOneOfOneIsCancelledAndTheWaitItSealsAtZero() public {
        uint256 saleId = _open();
        _bid(saleId, alice, 100, 1);
        uint256 paid = ua.stepPrice(saleId, 100);
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, 0, "a live 1/1: no time at which it can be abandoned");
        _expectNotAbandonable(saleId);

        _setOneOfOne(IEnglishAuction.AuctionState.CANCELLED);
        (ok, at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, uint256(ua.endTimes(saleId).closeAt) + _lens().ABANDON_DELAY());
        vm.warp(at - 1);
        _expectNotAbandonable(saleId);
        vm.warp(at);
        (ok,) = ua.abandonable(saleId);
        assertTrue(ok);

        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionVoided(saleId);
        vm.expectEmit(address(token));
        emit IEditions.EditionSupplySealed(ID, 0);
        vm.prank(makeAddr("anyone"));
        auction.abandon(saleId);
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertTrue(token.editionOf(ID).supplySealed);
        assertEq(token.editionOf(ID).maxSupply, 0, "sealed at zero");
        assertEq(token.editionOf(ID).minted, 0);
        vm.prank(alice);
        (uint256 won, uint256 refund) = auction.claimBid(saleId, 1, alice);
        assertEq(won, 0);
        assertEq(refund, paid);
        assertEq(alice.balance, paid, "refunded in full");
        assertEq(fee.balance + seller.balance, 0, "nothing paid");
        _expectNotAbandonable(saleId);
    }

    /// A sale whose 1/1 settled is never abandoned, however long after its close: it settles as
    /// usual (IND-56).
    function test_Abandon_ASaleWhoseOneOfOneSettledIsRefused() public {
        uint256 saleId = _open();
        _bid(saleId, alice, 100, 1);
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        vm.warp(uint256(ua.endTimes(saleId).closeAt) + _lens().ABANDON_DELAY());
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, 0);
        _expectNotAbandonable(saleId);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        assertEq(token.editionOf(ID).maxSupply, 1, "sealed at the one copy sold");
    }
}
