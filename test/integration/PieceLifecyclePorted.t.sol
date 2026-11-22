// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { UniformClearingReference as Ref } from "../helpers/UniformClearingReference.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice A piece's whole life on the deployed plain-core stack, re-ported from the retired
///         `PieceLifecycle` (D138-D141, ADR 0005): an edition master's 1/1 English auction and
///         its uniform-price edition auction side by side. The 1/1's anti-snipe moves the
///         edition close; the edition auction's own soft close extends it; both settle;
///         winners claim their copies and refunds; the proceeds split between the network and
///         the seller; the edition pays its master's royalty. Also: an unbid 1/1 goes to the
///         museum while its editions still sell.
contract PieceLifecyclePortedTest is IntegrationBase {
    uint256 internal constant DENOMINATOR = 100_000;

    IUniformEditionAuction internal ea;
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
        ea = IUniformEditionAuction(address(editionAuction));
        artist = _actor("pieceArtist");
        for (uint256 i; i < 4; ++i) {
            bidders[i] = makeAddr(string.concat("pieceBidder", vm.toString(i)));
        }
        Work[] memory works = new Work[](2);
        for (uint256 i; i < 2; ++i) {
            // Uncapped (maxCount zero): the clearing alone decides the supply.
            works[i] = _asMaster(_work(artist, collectionId), 0);
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
        Work[] memory works = _package(root);
        (saleId, workId) = _start(root, works, index);
        vm.prank(keeper);
        editionSale = ea.open(
            address(editions), workId, abi.encode(works[index].item, root, _proofOf(works, index))
        );
        assertEq(editionSale, ea.saleIdOf(address(editions), workId));
    }

    function _editionBid(uint256 sale, address bidder, uint256 step, uint256 quantity)
        internal
        returns (uint256 bidId)
    {
        uint256 value = quantity * ea.stepPrice(sale, step);
        vm.deal(bidder, bidder.balance + value);
        vm.prank(bidder);
        bidId = ea.bid{ value: value }(sale, step, quantity);
    }

    function _close(uint256 sale) internal view returns (uint256) {
        return ea.endTimes(sale).endTime;
    }

    // ------------------------------------------------------------------ the flows

    /// @dev The full life of a piece. Four bidders bid 3 copies at step 12, 2 at step 10, 4 at
    ///      step 6 and 1 at step 0; a late bid adds 1 at step 12. The clearing (checked against
    ///      the per-unit reference) sells 10 copies at step 6's price: 11 at step 0's price would
    ///      raise less than 90% of the best revenue. The bid at step 0 loses and gets everything
    ///      back.
    function test_AOneOfOneAndItsEditionsSellSideBySide() public {
        (uint256 saleId, uint256 workId, uint256 sale) = _startPiece(0);
        uint256[5] memory ids;
        for (uint256 i; i < 4; ++i) {
            ids[i] = _editionBid(sale, bidders[i], sideSteps[i], sideQuantities[i]);
        }
        _ethBid(saleId, collector, 1 ether);

        // A 1/1 bid in its last minute: the anti-snipe moves its end, the edition close follows.
        vm.warp(auction.auction(saleId).endTime - 1 minutes);
        _ethBid(saleId, sniper, 2 ether);
        uint256 oneOfOneEnd = auction.auction(saleId).endTime;
        assertEq(oneOfOneEnd, block.timestamp + EXTENSION_WINDOW, "anti-snipe");
        assertEq(_close(sale), oneOfOneEnd + 15 minutes, "the edition close follows");

        // The 1/1 settles to the sniper; the edition auction is still open, and its own soft
        // close extends it.
        vm.warp(oneOfOneEnd);
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
        assertTrue(editions.editionOf(workId).supplySealed, "sealed at the count");
        assertEq(address(editionAuction).balance, 0, "nothing left in escrow");

        // The edition pays its master's royalty rate.
        (, uint256 masterRoyalty) = stream.royaltyInfo(workId, 1 ether);
        (address receiver, uint256 editionRoyalty) = editions.royaltyInfo(workId, 1 ether);
        assertTrue(receiver != address(0));
        assertGt(receiver.code.length, 0, "the edition's royalty vault is deployed at open");
        assertEq(editionRoyalty, masterRoyalty, "the master's rate");
    }

    /// @dev A bid in the edition auction's last window extends its close; settling before the
    ///      new close is refused. Returns the late bid's ID.
    function _softCloseExtends(uint256 sale) internal returns (uint256 late) {
        uint256 window = ea.auction(sale).terms.softWindow;
        vm.warp(_close(sale) - 1 minutes);
        late = _editionBid(sale, bidders[3], sideSteps[4], sideQuantities[4]);
        assertEq(_close(sale), block.timestamp + window, "the soft close extends the close");
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, sale)
        );
        ea.settle(sale, new uint256[](0));
    }

    /// @dev The clearing equals the per-unit reference; settlement pays the network its share
    ///      and the seller the rest.
    function _settleAndCheckPayouts(uint256 sale) internal returns (uint256 k, uint256 price) {
        (k, price) = _referenceOf(sale);
        assertEq(k, 10, "10 copies");
        assertEq(price, ea.stepPrice(sale, 6), "at step 6's price");
        IUniformEditionAuction.Clearing memory live = ea.clearing(sale);
        assertEq(live.count, k, "count");
        assertEq(live.price, price, "price");
        IUniformEditionAuction.Auction memory a = ea.auction(sale);
        uint256 fee = k * price * a.feeShare / DENOMINATOR;
        uint256 feeBefore = a.feeRecipient.balance;
        uint256 sellerBefore = a.seller.balance;
        vm.warp(_close(sale));
        assertTrue(ea.settle(sale, new uint256[](0)));
        assertEq(a.feeRecipient.balance - feeBefore, fee, "the network's share");
        assertEq(a.seller.balance - sellerBefore, k * price - fee, "the seller's share");
    }

    /// @dev D140, D141: nobody bids on the 1/1, which goes to the museum; its editions sell all
    ///      the same.
    function test_AnUnbidOneOfOneGoesToTheMuseumWhileItsEditionsSell() public {
        (uint256 saleId, uint256 workId, uint256 sale) = _startPiece(1);
        uint256 id = _editionBid(sale, bidders[0], 5, 2);
        _editionBid(sale, bidders[1], 3, 1);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(stream.ownerOf(workId), museum, "the museum holds the 1/1");
        assertEq(uint8(stream.workOf(workId).outcome), uint8(Outcome.UNSOLD));
        vm.warp(_close(sale));
        assertTrue(ea.settle(sale, new uint256[](0)));
        assertEq(ea.settlement(sale).count, 3, "both bids win: 3 copies");
        vm.prank(bidders[0]);
        (uint256 won,) = ea.claimBid(sale, id, bidders[0]);
        assertEq(won, 2);
        assertEq(editions.balanceOf(bidders[0], workId), 2);
    }

    // ------------------------------------------------------------------ internals

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
        (won, refund) = ea.claimBid(sale, bidId, b.bidder);
        assertEq(refund, paid - won * price, "refund = escrow - won x price");
        assertEq(b.bidder.balance - before, refund);
        assertEq(editions.balanceOf(b.bidder, id) - copies, won);
        assertEq(won, ea.stepPrice(sale, b.step) >= price ? b.quantity : 0);
    }

    /// @dev The per-unit reference clearing of the auction's live book.
    function _referenceOf(uint256 sale) internal view returns (uint256 k, uint256 price) {
        (uint256 low, uint256[] memory units) = ea.stepTotals(sale);
        uint256[] memory prices = new uint256[](units.length);
        for (uint256 s; s < units.length; ++s) {
            prices[s] = ea.stepPrice(sale, low + s);
        }
        (k, price,) = Ref.clear(units, prices, 0, ea.auction(sale).terms.marginShare);
    }
}
