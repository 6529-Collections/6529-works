// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { RefusingMintTarget } from "../../mocks/sales/AuctionMocks.sol";
import { AuctionBase } from "./AuctionBase.sol";

/// @notice A listed token that breaks `IMintTarget.settlePrimary`'s promise that a sale can always
///         settle, by refusing the report or naming a wallet the escrow refuses, holds a standing
///         bid only until 60 days after the sale's end (RFX-SAL-3). Before then the settlement
///         reverts and anyone may retry; from then on a refused report closes the sale with the
///         bid credited back (`RescuedSaleClosed`), and an unpayable ETH payout is credited to
///         its wallet so the sale completes. 6529 Stream's own `settlePrimary` never refuses a
///         sold work and returns the wallets the auction checked at start.
contract AuctionLateSettlementTest is AuctionBase {
    uint256 internal constant EXIT = 60 days;
    uint256 internal constant PRICE = 1 ether;
    uint256 internal constant FEE_PAID = PRICE * FEE / 100_000;

    RefusingMintTarget internal token;

    function setUp() public override {
        super.setUp();
        token = new RefusingMintTarget();
        token.setAdmittedMinter(address(auction), true);
        token.setTerms(_terms(ETH));
        vm.prank(successor);
        auction.setTarget(address(token), true);
    }

    /// @dev An ETH sale of the refusing token with `alice`'s winning bid, at its end.
    function _endedSale() internal returns (uint256 saleId, uint256 endTime) {
        saleId = auction.start(address(token), "");
        _bidEth(saleId, alice, PRICE);
        endTime = auction.auction(saleId).endTime;
        vm.warp(endTime);
    }

    function _assertClosedWithARefund(uint256 saleId, uint256 sellerBefore) internal view {
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(auction.claimable(alice, ETH), PRICE, "the bid is credited back");
        assertEq(auction.auction(saleId).bidder, address(0));
        assertEq(token.ownerOf(1), address(auction), "the work stays in custody");
        assertEq(seller.balance, sellerBefore, "nothing paid");
        assertEq(auction.pendingDelivery(saleId), address(0), "nothing pending");
    }

    /// Regression: RFX-SAL-3
    /// @dev A token that reverts holds the sale until the exit: before it the settlement
    ///      reverts with the token's reason; from it the sale closes with the bid credited back
    ///      and nothing reported, paid or delivered. The bidder then claims its ETH.
    function test_Settle_ARefusingTokenClosesWithARefundAtTheExit() public {
        (uint256 saleId, uint256 endTime) = _endedSale();
        token.setRefusal(RefusingMintTarget.Refusal.REVERT);
        vm.expectRevert(bytes("refused"));
        auction.settle(saleId);
        vm.warp(endTime + EXIT - 1);
        vm.expectRevert(bytes("refused"));
        auction.settle(saleId);

        vm.warp(endTime + EXIT);
        uint256 sellerBefore = seller.balance;
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(alice, ETH, saleId, PRICE);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(saleId);
        vm.prank(makeAddr("keeper"));
        auction.settle(saleId);
        _assertClosedWithARefund(saleId, sellerBefore);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        auction.claim(ETH, alice);
        assertEq(alice.balance, aliceBefore + PRICE, "the bidder has its ETH back");
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.SETTLED
            )
        );
        auction.settle(saleId);
    }

    /// Regression: RFX-SAL-3
    /// @dev A token that burns all the gas it is given gets exactly 1,000,000 at the exit, and
    ///      the sale closes with a refund instead of the settlement running out of gas.
    function test_Settle_AGasBurningTokenClosesWithARefundAtTheExit() public {
        (uint256 saleId, uint256 endTime) = _endedSale();
        token.setRefusal(RefusingMintTarget.Refusal.BURN_GAS);
        vm.warp(endTime + EXIT);
        uint256 sellerBefore = seller.balance;
        uint256 before = gasleft();
        auction.settle{ gas: 2_000_000 }(saleId);
        assertLt(before - gasleft(), 1_200_000, "the token's frame is bounded");
        _assertClosedWithARefund(saleId, sellerBefore);
    }

    /// Regression: RFX-SAL-3
    /// @dev At the exit a caller that cannot forward the token's frame in full is refused, so it
    ///      cannot make a working token fail and close the sale without its sale.
    function test_Settle_ACallerCannotStarveTheReportAtTheExit() public {
        (uint256 saleId, uint256 endTime) = _endedSale();
        vm.warp(endTime + EXIT);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallInsufficientGas.selector, 1_000_000)
        );
        auction.settle{ gas: 900_000 }(saleId);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.ENDED));

        // With the gas, a working token's sale settles as any other: sold, paid and delivered.
        uint256 sellerBefore = seller.balance;
        auction.settle(saleId);
        assertEq(token.ownerOf(1), alice, "delivered to the winner");
        assertEq(seller.balance, sellerBefore + PRICE - FEE_PAID, "the seller is paid");
        assertEq(auction.claimable(alice, ETH), 0, "nothing refunded");
    }

    /// Regression: RFX-SAL-3
    /// @dev A token that names the zero address as the seller holds the sale until the exit
    ///      (the escrow refuses the wallet); from then on the payout is credited to that wallet,
    ///      and the sale completes: the winner receives the work and the fee is paid.
    function test_Settle_AnUnpayableSellerIsCreditedAtTheExit() public {
        (uint256 saleId, uint256 endTime) = _endedSale();
        PrimaryTerms memory t = _terms(ETH);
        t.seller = address(0);
        token.setTerms(t);
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(0)));
        auction.settle(saleId);

        vm.warp(endTime + EXIT);
        uint256 networkBefore = network.balance;
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(address(0), ETH, saleId, PRICE - FEE_PAID);
        auction.settle(saleId);
        assertEq(token.ownerOf(1), alice, "the winner receives the work");
        assertEq(network.balance, networkBefore + FEE_PAID, "the fee is paid");
        assertEq(auction.claimable(address(0), ETH), PRICE - FEE_PAID);
        assertEq(auction.claimable(alice, ETH), 0, "the winner paid");
    }

    /// Regression: RFX-SAL-3
    /// @dev The same for a fee recipient that is the escrow.
    function test_Settle_AnEscrowFeeRecipientIsCreditedAtTheExit() public {
        (uint256 saleId, uint256 endTime) = _endedSale();
        PrimaryTerms memory t = _terms(ETH);
        t.feeRecipient = address(escrow);
        token.setTerms(t);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(escrow))
        );
        auction.settle(saleId);

        vm.warp(endTime + EXIT);
        uint256 sellerBefore = seller.balance;
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(address(escrow), ETH, saleId, FEE_PAID);
        auction.settle(saleId);
        assertEq(token.ownerOf(1), alice);
        assertEq(seller.balance, sellerBefore + PRICE - FEE_PAID, "the seller is paid");
        assertEq(auction.claimable(address(escrow), ETH), FEE_PAID);
    }

    /// Regression: RFX-SAL-3
    /// @dev A sale with no bid is never closed this way: its token's refusal reverts at any
    ///      time, so a passing fault (6529 Stream's museum not yet set, say) cannot strand the
    ///      work, and anyone retries.
    function test_Settle_ANoBidSaleAlwaysWaitsForItsToken() public {
        uint256 saleId = auction.start(address(token), "");
        uint256 endTime = auction.auction(saleId).endTime;
        token.setRefusal(RefusingMintTarget.Refusal.REVERT);
        vm.warp(endTime + 365 days);
        vm.expectRevert(bytes("refused"));
        auction.settle(saleId);
        token.setRefusal(RefusingMintTarget.Refusal.NONE);
        vm.expectCall(address(token), abi.encodeWithSelector(IMintTarget.settlePrimary.selector));
        auction.settle(saleId);
        assertEq(token.ownerOf(1), artist, "the unsold work goes to its artist");
    }
}
