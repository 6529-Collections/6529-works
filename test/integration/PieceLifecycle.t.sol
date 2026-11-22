// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { UniformClearingReference as Ref } from "../helpers/UniformClearingReference.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";

/// @notice A piece's whole life on the deployed stack (D138-D141, ADR 0005): an edition
///         master's 1/1 English auction and its uniform-price edition auction side by side. The
///         1/1's anti-snipe moves the edition close; the edition auction's own soft close
///         extends it; both settle; winners claim their copies (minted by
///         `StreamEditions6529.mint`) and refunds; the proceeds split between the network and the
///         seller; the edition carries its master's royalty rate. Also: an unbid 1/1 goes to the
///         museum while its editions sell, and a cancelled 1/1 voids its edition sale with every
///         bid refunded in full.
contract PieceLifecycleTest is EditionAuctionStack {
    uint256 internal constant DENOMINATOR = 100_000;

    address internal artist;
    address internal keeper = makeAddr("pieceKeeper");
    address internal collector = makeAddr("pieceCollector");
    address internal sniper = makeAddr("pieceSniper");
    address[4] internal bidders;
    bytes32 internal root;

    uint256[5] internal sideSteps = [uint256(12), 10, 6, 0, 12];
    uint256[5] internal sideQuantities = [uint256(3), 2, 4, 1, 1];

    function setUp() public override {
        super.setUp();
        artist = _actor("pieceArtist");
        for (uint256 i; i < 4; ++i) {
            bidders[i] = makeAddr(string.concat("pieceBidder", vm.toString(i)));
        }
        Work[] memory works = new Work[](3);
        for (uint256 i; i < 3; ++i) {
            works[i] = _masterWork(artist, 0);
        }
        root = _publish(works);
        _keep(root, works);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Starts master `index`'s 1/1 and, as the keeper does in the same batch, opens its
    ///      edition auction (which creates the edition).
    function _startPiece(uint256 index)
        internal
        returns (uint256 saleId, uint256 workId, uint256 editionSale)
    {
        (saleId, workId) = _start(root, _package(root), index);
        vm.prank(keeper);
        editionSale =
            editionAuction.open(address(editions), workId, _openData(root, _package(root), index));
        assertEq(editionSale, ea.saleIdOf(address(editions), workId));
        assertEq(editions.editionOf(workId).minter, address(editionAuction), "created at open");
    }

    function _close(uint256 sale) internal view returns (uint256) {
        return ea.endTimes(sale).endTime;
    }

    // ------------------------------------------------------------------ the flows

    /// @dev The full life of a piece. Four bidders bid 3 copies at step 12, 2 at step 10, 4 at
    ///      step 6 and 1 at step 0; a late bid adds 1 at step 12. The clearing (checked against
    ///      the per-unit reference) sells 10 copies at step 6's price: 11 at step 0's price
    ///      would raise less than 90% of the best revenue. The bid at step 0 loses and gets
    ///      everything back.
    function test_Piece_AOneOfOneAndItsEditionsSellSideBySide() public {
        (uint256 saleId, uint256 workId, uint256 sale) = _startPiece(0);
        uint256[5] memory ids;
        for (uint256 i; i < 4; ++i) {
            ids[i] = _editionBid(sale, bidders[i], sideSteps[i], sideQuantities[i]);
        }
        _ethBid(saleId, collector, 1 ether);
        _antiSnipeMovesTheEditionClose(saleId, sale);

        // The 1/1 settles to the sniper; the edition auction is still open, and its own soft
        // close extends it.
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(stream.ownerOf(workId), sniper);
        ids[4] = _softCloseExtends(sale);

        (uint256 k, uint256 price) = _settleAndCheckPayouts(sale);
        uint256 minted;
        for (uint256 i; i < 5; ++i) {
            minted += _claimAndCheck(sale, ids[i], price);
        }
        assertEq(minted, k, "exactly k copies");
        assertEq(editions.editionOf(workId).minted, k, "the edition's supply is k");
        assertEq(editions.editionOf(workId).maxSupply, k, "sealed at k");
        assertTrue(editions.editionOf(workId).supplySealed);
        assertEq(address(editionAuction).balance, 0, "nothing left in escrow");

        // The edition carries its master's royalty rate, paid to the edition royalty wallet.
        (, uint256 masterRoyalty) = stream.royaltyInfo(workId, 1 ether);
        (address receiver, uint256 editionRoyalty) = editions.royaltyInfo(workId, 1 ether);
        assertEq(receiver, _editionRoyalty(_package(root)[0]), "the edition royalty wallet");
        assertTrue(receiver.code.length != 0, "deployed at open");
        assertGt(editionRoyalty, 0);
        assertEq(editionRoyalty, masterRoyalty, "the master's rate");
        assertEq(editions.editionOf(workId).royaltyRate, stream.workOf(workId).royaltyRate);
    }

    /// @dev A 1/1 bid in its last minute: the 1/1's anti-snipe moves its end, and the edition
    ///      close follows it, 15 minutes later.
    function _antiSnipeMovesTheEditionClose(uint256 saleId, uint256 sale) internal {
        uint256 before = _close(sale);
        assertEq(before, auction.auction(saleId).endTime + 15 minutes, "15 minutes after");
        vm.warp(auction.auction(saleId).endTime - 1 minutes);
        _ethBid(saleId, sniper, 2 ether);
        uint256 oneOfOneEnd = auction.auction(saleId).endTime;
        assertEq(oneOfOneEnd, block.timestamp + EXTENSION_WINDOW, "anti-snipe");
        assertEq(_close(sale), oneOfOneEnd + 15 minutes, "the edition close follows");
        assertGt(_close(sale), before);
    }

    /// @dev A bid in the edition auction's last window extends its close; settling before the
    ///      new close is refused. Returns the late bid's ID.
    function _softCloseExtends(uint256 sale) internal returns (uint256 late) {
        uint256 window = ea.auction(sale).terms.softWindow;
        assertEq(window, 5 minutes);
        vm.warp(_close(sale) - 1 minutes);
        late = _editionBid(sale, bidders[3], sideSteps[4], sideQuantities[4]);
        assertEq(_close(sale), block.timestamp + window, "the soft close extends the close");
        vm.warp(block.timestamp + window - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, sale)
        );
        editionAuction.settle(sale, new uint256[](0));
    }

    /// @dev The clearing equals the per-unit reference; settlement pays the network its share
    ///      and the seller the rest.
    function _settleAndCheckPayouts(uint256 sale) internal returns (uint256 k, uint256 price) {
        (k, price) = _referenceOf(sale, 0);
        assertEq(k, 10, "10 copies");
        assertEq(price, ea.stepPrice(sale, 6), "at step 6's price");
        IUniformEditionAuction.Clearing memory live = ea.clearing(sale);
        assertEq(live.count, k, "count");
        assertEq(live.price, price, "price");
        IUniformEditionAuction.Auction memory a = ea.auction(sale);
        assertEq(a.seller, _editionSeller(_package(root)[0]), "the edition seller wallet");
        assertEq(a.feeRecipient, networkFee, "the network fee vault");
        assertGt(a.feeShare, 0);
        uint256 revenue = k * price;
        uint256 fee = revenue - revenue * (DENOMINATOR - a.feeShare) / DENOMINATOR;
        uint256 feeBefore = networkFee.balance;
        uint256 sellerBefore = a.seller.balance;
        vm.warp(_close(sale));
        assertTrue(editionAuction.settle(sale, new uint256[](0)));
        assertEq(networkFee.balance - feeBefore, fee, "the network's share");
        assertEq(a.seller.balance - sellerBefore, revenue - fee, "the seller's share");
    }

    /// @dev The bidder claims bid `bidId`: it wins all its units at or above the clearing price,
    ///      none below, and gets back its escrow less the copies at the one price.
    function _claimAndCheck(uint256 sale, uint256 bidId, uint256 price)
        internal
        returns (uint256 won)
    {
        IUniformEditionAuction.Bid memory b = ea.bidOf(sale, bidId);
        uint256 paid = uint256(b.quantity) * ea.stepPrice(sale, b.step);
        uint256 before = b.bidder.balance;
        uint256 id = ea.auction(sale).id;
        uint256 copies = editions.balanceOf(b.bidder, id);
        uint256 refund;
        vm.prank(b.bidder);
        (won, refund) = editionAuction.claimBid(sale, bidId, b.bidder);
        assertEq(refund, paid - won * price, "refund = escrow - won x price");
        assertEq(b.bidder.balance - before, refund);
        assertEq(editions.balanceOf(b.bidder, id) - copies, won);
        assertEq(won, ea.stepPrice(sale, b.step) >= price ? b.quantity : 0);
    }

    /// @dev D140, D141: nobody bids on the 1/1, which goes to the museum; its editions sell all
    ///      the same.
    function test_Piece_AnUnbidOneOfOneGoesToTheMuseumWhileItsEditionsSell() public {
        (uint256 saleId, uint256 workId, uint256 sale) = _startPiece(1);
        uint256 id = _editionBid(sale, bidders[0], 5, 2);
        _editionBid(sale, bidders[1], 3, 1);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(stream.ownerOf(workId), museum, "the museum holds the 1/1");
        assertEq(uint8(stream.workOf(workId).outcome), uint8(Outcome.UNSOLD));
        uint256 sellerBefore = ea.auction(sale).seller.balance;
        vm.warp(_close(sale));
        assertTrue(editionAuction.settle(sale, new uint256[](0)));
        assertEq(ea.settlement(sale).count, 3, "both bids win: 3 copies");
        assertGt(ea.auction(sale).seller.balance, sellerBefore, "the seller is paid");
        vm.prank(bidders[0]);
        (uint256 won,) = editionAuction.claimBid(sale, id, bidders[0]);
        assertEq(won, 2);
        assertEq(editions.balanceOf(bidders[0], workId), 2);
        (won,) = editionAuction.claimBidFor(sale, 2);
        assertEq(won, 1);
        assertEq(editions.editionOf(workId).minted, 3);
    }

    /// @dev R21: an upheld dispute cancels the 1/1 (its token burned) and voids the edition
    ///      sale: anyone's settle call voids it at once, the edition is sealed at zero, and every
    ///      bid, placed before or during the pause, comes back in full; nothing is paid.
    function test_Piece_ACancelledOneOfOneVoidsTheEditionSale() public {
        (uint256 saleId, uint256 workId, uint256 sale) = _startPiece(2);
        _editionBid(sale, bidders[0], 50, 2);
        _editionBid(sale, bidders[1], 60, 3);
        _ethBid(saleId, collector, 1 ether);
        vm.warp(block.timestamp + 2 hours);
        _pauseOneOfOne(saleId);
        // Bidding continues while the 1/1 is paused.
        _editionBid(sale, bidders[2], 55, 1);
        bytes32 outcome = _platformStatement(
            address(stream), workId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
        );
        _asNetwork(address(auction), abi.encodeCall(auction.cancel, (saleId, outcome)));
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        // Anyone's settle call voids the sale at once.
        uint256 feeBefore = networkFee.balance;
        uint256 sellerBefore = ea.auction(sale).seller.balance;
        vm.prank(makeAddr("anyone"));
        assertTrue(editionAuction.settle(sale, new uint256[](0)));
        assertEq(uint8(ea.auction(sale).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertTrue(editions.editionOf(workId).supplySealed, "sealed");
        assertEq(editions.editionOf(workId).maxSupply, 0, "at zero");
        uint256[3] memory steps = [uint256(50), 60, 55];
        uint256[3] memory quantities = [uint256(2), 3, 1];
        for (uint256 i; i < 3; ++i) {
            uint256 before = bidders[i].balance;
            vm.prank(bidders[i]);
            (uint256 won, uint256 refund) = editionAuction.claimBid(sale, i + 1, bidders[i]);
            assertEq(won, 0);
            assertEq(refund, quantities[i] * ea.stepPrice(sale, steps[i]), "in full");
            assertEq(bidders[i].balance - before, refund);
        }
        assertEq(networkFee.balance, feeBefore, "no fee");
        assertEq(ea.auction(sale).seller.balance, sellerBefore, "no seller payment");
        assertEq(address(editionAuction).balance, 0);
        assertEq(editions.editionOf(workId).minted, 0);
    }

    // ------------------------------------------------------------------ internals

    /// @dev The per-unit reference clearing of the auction's live book (`stepTotals`).
    function _referenceOf(uint256 sale, uint32 cap)
        internal
        view
        returns (uint256 k, uint256 price)
    {
        (uint256 low, uint256[] memory units) = ea.stepTotals(sale);
        uint256[] memory prices = new uint256[](units.length);
        for (uint256 s; s < units.length; ++s) {
            prices[s] = ea.stepPrice(sale, low + s);
        }
        (k, price,) = Ref.clear(units, prices, cap, ea.auction(sale).terms.marginShare);
    }
}
