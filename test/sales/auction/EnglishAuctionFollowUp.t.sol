// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { RevenuePayment } from "src/economics/RevenuePayment.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod, PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { MockFederationRegistry, MockMintTarget } from "../../mocks/auction/AuctionMocks.sol";
import { AuctionBase } from "./AuctionBase.sol";

/// @dev A bidding contract that forwards its refunds with `claim(currency, to)` and accepts ETH
///      for other reasons, but has no way to move ETH out.
contract ForwardingBidder {
    function bid(IEnglishAuction auction, uint256 saleId) external payable {
        auction.bid{ value: msg.value }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, address(this), msg.value, 0, 0, "")
        );
    }

    function claimTo(IEnglishAuction auction, address treasury) external {
        auction.claim(address(0), treasury);
    }

    receive() external payable { }
}

/// @notice Follow-ups from the review of the auction fixes: the exact 96-bit arithmetic, the
///         federated recipient checked at start (L6), the reopening floor (L7), `claimFor`
///         refusing ETH (L5), the payout frame's gas floor (MONEY-1), and the settler's gas.
contract EnglishAuctionFollowUpTest is AuctionBase {
    // ------------------------------------------------- exact 96-bit arithmetic

    function testFuzz_FeeMatchesMulDivFloor(uint96 price, uint32 share) public pure {
        share = uint32(bound(share, 0, 100_000));
        uint256 exact = uint256(price) * share / 100_000;
        assertEq(exact, Math.mulDiv(price, share, 100_000));
        assertLe(exact, price);
    }

    function testFuzz_StepMatchesMulDivCeil(uint96 high, uint24 share) public pure {
        share = uint24(bound(share, 0, 100_000));
        assertEq(
            (uint256(high) * share + 100_000 - 1) / 100_000,
            Math.mulDiv(high, share, 100_000, Math.Rounding.Ceil)
        );
    }

    function test_ArithmeticEdgeValues() public pure {
        uint96 m = type(uint96).max;
        assertEq(uint256(m) * 100_000 / 100_000, Math.mulDiv(m, 100_000, 100_000));
        assertEq(
            (uint256(m) * 100_000 + 99_999) / 100_000,
            Math.mulDiv(m, 100_000, 100_000, Math.Rounding.Ceil)
        );
        assertEq((uint256(1) * 1 + 99_999) / 100_000, 1);
        assertEq((uint256(0) * 5_000 + 99_999) / 100_000, 0);
    }

    // ------------------------------------------------- MARKET-3 follow-up (L6)

    function _federated(PrimaryTerms memory terms) internal returns (MockMintTarget federated) {
        MockFederationRegistry registry = new MockFederationRegistry();
        federated = new MockMintTarget();
        federated.setAdmittedMinter(address(auction), true);
        federated.setTerms(terms);
        vm.prank(successor);
        auction.setFederationRegistry(address(0), address(registry));
        registry.register(
            address(federated),
            IFederationRegistry.Entry(
                IFederationRegistry.Form.ERC721,
                address(0),
                uint160(artist),
                1,
                address(federated).codehash,
                10_000,
                IFederationRegistry.Status.ACTIVE
            )
        );
    }

    /// @dev A federated sale's fee goes to the network's federated recipient, so that recipient,
    ///      not the token's own, is checked at start: a zero one is refused while nothing is in
    ///      custody, in ETH and in ERC-20.
    function test_L6_FederatedStartNeedsANetworkRecipient() public {
        resolver.set(PRODUCT_FEDERATED, address(0), 0);
        address[2] memory currencies = [ETH, address(usd)];
        for (uint256 i; i < 2; ++i) {
            MockMintTarget federated = _federated(_terms(currencies[i]));
            vm.expectRevert(
                abi.encodeWithSelector(EnglishAuction.InvalidTerms.selector, address(federated), 1)
            );
            auction.start(address(federated), "");
            address installed = auction.federationRegistry();
            vm.prank(successor);
            auction.setFederationRegistry(installed, address(0));
        }
    }

    /// @dev The token's own fee recipient is never paid for a federated sale, so it is not
    ///      checked: zero, or even the escrow, starts and settles to the network's recipient.
    function test_L6_AFederatedTokensOwnRecipientIsIgnored() public {
        PrimaryTerms memory terms = _terms(ETH);
        terms.feeRecipient = address(escrow);
        MockMintTarget federated = _federated(terms);
        uint256 saleId = auction.start(address(federated), "");
        _bidEth(saleId, alice, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(federatedNetwork.balance, 0.1 ether);
        assertEq(escrow.owed(address(escrow), ETH), 0);
    }

    // ------------------------------------------------- LIFECYCLE-1 follow-up (L7)

    /// @dev The reopening is the governed duration or the sale's locked window, whichever is
    ///      longer, with or without a withdrawal: a later, shorter duration cannot give a
    ///      halted sale less than its anti-snipe window.
    function test_L7_ReopeningIsNeverShorterThanTheLockedWindow() public {
        IEnglishAuction.AuctionConfig memory c = auction.config();
        IEnglishAuction.AuctionConfig memory wide =
            IEnglishAuction.AuctionConfig(7 days, 1 days, SHARE);
        vm.prank(setter);
        auction.setConfig(c, wide);
        uint256 withdrawn = _start();
        uint256 standing = _start();
        _bidEth(withdrawn, alice, 1 ether);
        _bidEth(standing, bob, 1 ether);
        vm.warp(block.timestamp + 7 days - 10 minutes);
        _pause(withdrawn);
        _pause(standing);
        uint256 pausedAt = block.timestamp;
        vm.prank(alice);
        auction.withdrawBid(withdrawn);
        vm.prank(setter);
        auction.setConfig(wide, IEnglishAuction.AuctionConfig(1 hours, 1 minutes, SHARE));
        vm.warp(pausedAt + auction.MAX_PAUSE() + 1);
        uint256 resumedAt = pausedAt + auction.MAX_PAUSE();
        assertEq(auction.auction(withdrawn).endTime, resumedAt + 1 days, "withdrawn: the window");
        assertEq(auction.auction(standing).endTime, resumedAt + 1 days, "standing: the window");
    }

    // ------------------------------------------------- MONEY-1 follow-up (L5)

    /// @dev `claimFor` refuses ETH: an outbid bidder's ETH refund is claimed by the bidder, to the
    ///      address it chooses, and nobody can push it into a contract that cannot move it on.
    function test_L5_ClaimForRefusesEth() public {
        uint256 saleId = _start();
        ForwardingBidder fb = new ForwardingBidder();
        vm.deal(address(this), 1 ether);
        fb.bid{ value: 1 ether }(auction, saleId);
        _bidEth(saleId, alice, 2 ether);
        vm.prank(makeAddr("griefer"));
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidAsset.selector, ETH));
        auction.claimFor(address(fb), ETH);
        address treasury = makeAddr("treasury");
        fb.claimTo(auction, treasury);
        assertEq(treasury.balance, 1 ether);
    }

    // ------------------------------------------------- expired permits, as in every adapter

    /// @dev An expired PERMIT or PERMIT2 payment reverts with `PaymentExpired`, as in the
    ///      fixed-price and Dutch adapters, even where an existing allowance would pay.
    function test_ExpiredPermitsRevertAlike() public {
        uint256 saleId = _startUsd();
        usd.mint(alice, 10e18);
        vm.prank(alice);
        usd.approve(address(auction), 10e18);
        uint256 deadline = block.timestamp - 1;
        Payment memory p = _permitPayment(alicePk, 10e18, deadline);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.PaymentExpired.selector, deadline));
        auction.bid(saleId, address(0), p);
        Payment memory p2 = _permit2Payment(bobPk, saleId, bob, 10e18, 1);
        vm.warp(p2.deadline + 1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.PaymentExpired.selector, p2.deadline));
        auction.bid(saleId, bob, p2);
        // A direct payment carries no deadline.
        vm.prank(alice);
        auction.bid(saleId, address(0), _direct(alice, 10e18));
        assertEq(auction.auction(saleId).bidder, alice);
    }

    // ------------------------------------------------- MONEY-1: the payout frame's gas

    function _endedUsdSale() internal returns (uint256 saleId) {
        saleId = _startUsd();
        _bidUsd(saleId, alice, 100e18);
        vm.warp(auction.auction(saleId).endTime);
    }

    /// @dev A settler that cannot forward the payout frame's gas in full is refused, so it
    ///      cannot force a payout onto the credit route.
    function test_MONEY1_AStarvedSettleRevertsInsteadOfCrediting() public {
        uint256 saleId = _endedUsdSale();
        (bool ok, bytes memory reason) =
            address(auction).call{ gas: 900_000 }(abi.encodeCall(auction.settle, (saleId)));
        assertFalse(ok, "refused");
        assertEq(bytes4(reason), RevenuePayment.PaymentInsufficientGas.selector, "for want of gas");
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ENDED));
        assertEq(auction.claimable(seller, address(usd)), 0, "nothing credited");
        auction.settle(saleId);
        assertEq(usd.balanceOf(seller), 75e18, "paid directly with enough gas");
    }

    /// @dev The least call gas a keeper must give an ERC-20 settlement (about 1.1M: the payout
    ///      frame must be forwardable in full) against the gas it uses, and the same for ETH.
    function test_MONEY1_SettlerGasLimitVersusGasUsed() public {
        uint256 saleId = _endedUsdSale();
        (uint256 limit, uint256 used) = _leastSettleGas(saleId);
        emit log_named_uint("ERC-20 settle: least call gas", limit);
        emit log_named_uint("ERC-20 settle: gas used", used);
        assertLe(limit, 1_200_000);
        assertLt(used, 300_000);
        stream.setTerms(_terms(ETH));
        uint256 ethSale = _start();
        _bidEth(ethSale, bob, 1 ether);
        vm.warp(auction.auction(ethSale).endTime);
        (limit, used) = _leastSettleGas(ethSale);
        emit log_named_uint("ETH settle: least call gas", limit);
        emit log_named_uint("ETH settle: gas used", used);
        assertLe(limit, 500_000);
    }

    function _leastSettleGas(uint256 saleId) internal returns (uint256 lo, uint256 used) {
        uint256 hi = 5_000_000;
        lo = 100_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(auction).call{ gas: mid }(abi.encodeCall(auction.settle, (saleId)));
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        lo = hi;
        uint256 before = gasleft();
        auction.settle(saleId);
        used = before - gasleft();
    }

    receive() external payable { }
}
