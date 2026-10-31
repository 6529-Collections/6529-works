// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { UniformClearingReference as Ref } from "../helpers/UniformClearingReference.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice A piece's whole life on the real stack (D138-D141, ADR 0005): an edition master's
///         1/1 English auction and its uniform-price edition auction side by side. The 1/1's
///         anti-snipe moves the edition close; the edition auction's own soft close extends it;
///         both settle; winners claim their copies and refunds; the proceeds split between the
///         network and the seller; the edition pays its master's royalty. Also: an unbid 1/1
///         goes to the museum while its editions still sell; no edition bid mints nothing; and a
///         cancelled 1/1 voids its edition auction with full refunds.
contract PieceLifecycleTest is IntegrationBase {
    uint256 internal constant DENOMINATOR = 100_000;

    address internal artist;
    address internal keeper = makeAddr("pieceKeeper");
    address internal collector = makeAddr("pieceCollector");
    address internal sniper = makeAddr("pieceSniper");
    address[4] internal bidders;
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("pieceArtist");
        for (uint256 i; i < 4; ++i) {
            bidders[i] = makeAddr(string.concat("pieceBidder", vm.toString(i)));
        }
        Work[] memory works = new Work[](4);
        uint32[4] memory caps = [uint32(0), 0, 0, 3];
        for (uint256 i; i < 4; ++i) {
            works[i] = _work(artist, collectionId);
            works[i].item.kind = ItemKind.EDITION_MASTER;
            works[i].item.edition =
                EditionTerms(caps[i], CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        }
        root = _publish(works);
        _keep(root, works);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Starts master `index`'s 1/1 and, as the keeper does in the same batch, opens its
    ///      edition auction.
    function _startPiece(uint256 index) internal returns (uint256 saleId, uint256 workId) {
        (saleId, workId) = _start(root, _package(root), index);
        vm.prank(keeper);
        assertEq(editionAuction.open(workId, _package(root)[index].item), workId);
    }

    function _editionBid(uint256 workId, address bidder, uint256 step, uint256 quantity)
        internal
        returns (uint256 bidId)
    {
        uint256 cost = quantity * editionAuction.stepPrice(workId, step);
        vm.deal(bidder, bidder.balance + cost);
        vm.prank(bidder);
        bidId = editionAuction.bid{ value: cost }(workId, step, quantity);
    }

    function _createEdition(uint256 workId, uint256 index) internal {
        Work[] memory works = _package(root);
        editions.createEdition(workId, works[index].item, root, _proofOf(works, index));
    }

    function _close(uint256 workId) internal view returns (uint256) {
        return editionAuction.auctionOf(workId).endTime;
    }

    function _offset(uint256 workId) internal view returns (uint256) {
        return editionAuction.configOf(editionAuction.auctionOf(workId).termsId).closeOffset;
    }

    // ------------------------------------------------------------------ the flows

    /// @dev The full life of a piece. Four bidders bid 3 copies at step 12, 2 at step 10, 4 at
    ///      step 6 and 1 at step 0; a late bid adds 1 at step 12. The clearing (checked against
    ///      the per-unit reference) sells 10 copies at step 6's price: 11 at step 0's price
    ///      would raise less than 90% of the best revenue. The bid at step 0 loses and gets
    ///      everything back.
    function test_AOneOfOneAndItsEditionsSellSideBySide() public {
        (uint256 saleId, uint256 workId) = _startPiece(0);
        uint256[4] memory steps = [uint256(12), 10, 6, 0];
        uint256[4] memory quantities = [uint256(3), 2, 4, 1];
        uint256[4] memory ids;
        for (uint256 i; i < 4; ++i) {
            ids[i] = _editionBid(workId, bidders[i], steps[i], quantities[i]);
        }
        _ethBid(saleId, collector, 1 ether);

        // The 1/1's anti-snipe moves its end, and the edition close follows it.
        vm.warp(auction.auction(saleId).endTime - 1 minutes);
        _ethBid(saleId, sniper, 2 ether);
        uint256 oneOfOneEnd = auction.auction(saleId).endTime;
        assertEq(oneOfOneEnd, block.timestamp + auction.config().extensionWindow, "anti-snipe");
        assertEq(_close(workId), oneOfOneEnd + _offset(workId), "the edition close follows");

        // The 1/1 settles to the sniper and anyone creates the edition; the edition auction is
        // still open.
        vm.warp(oneOfOneEnd);
        auction.settle(saleId);
        assertEq(stream.ownerOf(workId), sniper);
        _createEdition(workId, 0);

        // The edition auction's own soft close: a bid in its last window extends it.
        uint256 window =
            editionAuction.configOf(editionAuction.auctionOf(workId).termsId).softCloseWindow;
        vm.warp(_close(workId) - 1 minutes);
        uint256 late = _editionBid(workId, bidders[3], 12, 1);
        assertEq(_close(workId), block.timestamp + window, "the soft close extends the close");
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.AuctionNotClosed.selector, workId, _close(workId)
            )
        );
        editionAuction.settle(workId, new uint256[](0));

        // The clearing equals the per-unit reference.
        (uint256 k, uint256 price) = _referenceOf(workId, 0);
        assertEq(k, 10, "10 copies");
        assertEq(price, editionAuction.stepPrice(workId, 6), "at step 6's price");
        IUniformEditionAuction.Clearing memory live = editionAuction.clearing(workId);
        assertEq(live.count, k, "count");
        assertEq(live.price, price, "price");

        // Settlement pays the network its share and the seller the rest.
        IUniformEditionAuction.Auction memory ea = editionAuction.auctionOf(workId);
        uint256 revenue = k * price;
        uint256 fee = revenue * ea.feeShare / DENOMINATOR;
        uint256 feeBefore = ea.feeRecipient.balance;
        uint256 sellerBefore = ea.seller.balance;
        vm.warp(_close(workId));
        assertTrue(editionAuction.settle(workId, new uint256[](0)));
        assertEq(ea.feeRecipient.balance - feeBefore, fee, "the network's share");
        assertEq(ea.seller.balance - sellerBefore, revenue - fee, "the seller's share");

        // Every bid claims: winners get their copies at the one price, everyone the rest back.
        uint256 minted;
        for (uint256 i; i < 4; ++i) {
            minted += _claimAndCheck(ids[i], bidders[i], steps[i], quantities[i], workId, price);
        }
        minted += _claimAndCheck(late, bidders[3], 12, 1, workId, price);
        assertEq(minted, k, "exactly k copies");
        assertEq(editions.edition(workId).minted, k, "the edition's supply is k");
        assertEq(address(editionAuction).balance, 0, "nothing left in escrow");

        // The edition pays its master's royalty rate.
        (, uint256 masterRoyalty) = stream.royaltyInfo(workId, 1 ether);
        (address receiver, uint256 editionRoyalty) = editions.royaltyInfo(workId, 1 ether);
        assertTrue(receiver != address(0));
        assertEq(editionRoyalty, masterRoyalty, "the master's rate");
    }

    /// @dev D140, D141: nobody bids on the 1/1, which goes to the 6529 Network Museum; its
    ///      editions sell all the same.
    function test_AnUnbidOneOfOneGoesToTheMuseumWhileItsEditionsSell() public {
        (uint256 saleId, uint256 workId) = _startPiece(1);
        uint256 id = _editionBid(workId, bidders[0], 5, 2);
        _editionBid(workId, bidders[1], 3, 1);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(stream.ownerOf(workId), economics.museum(), "the museum holds the 1/1");
        _createEdition(workId, 1);
        vm.warp(_close(workId));
        assertTrue(editionAuction.settle(workId, new uint256[](0)));
        IUniformEditionAuction.Clearing memory c = editionAuction.clearing(workId);
        assertEq(c.count, 3, "both bids win: 3 copies");
        vm.prank(bidders[0]);
        (uint256 won,) = editionAuction.claimBid(id, bidders[0]);
        assertEq(won, 2);
        assertEq(editions.balanceOf(bidders[0], workId), 2);
    }

    /// @dev D141: no edition bid means no editions. The edition auction settles with a count of
    ///      zero, pays nothing and mints nothing, without the edition ever being created.
    function test_NoEditionBidsMintNothing() public {
        (uint256 saleId, uint256 workId) = _startPiece(2);
        _ethBid(saleId, collector, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        IUniformEditionAuction.Auction memory ea = editionAuction.auctionOf(workId);
        uint256 feeBefore = ea.feeRecipient.balance;
        vm.warp(_close(workId));
        assertTrue(editionAuction.settle(workId, new uint256[](0)));
        assertEq(editionAuction.clearing(workId).count, 0);
        assertEq(ea.feeRecipient.balance, feeBefore, "nothing paid");
        assertFalse(editions.exists(workId), "no edition was needed");
        assertEq(
            uint8(editionAuction.auctionOf(workId).state),
            uint8(IUniformEditionAuction.AuctionState.SETTLED)
        );
    }

    /// @dev D141, owner decision 12: edition bidding continues while the 1/1 is paused for a
    ///      dispute and bidders may withdraw; an upheld dispute cancels the 1/1, which voids the
    ///      edition auction: every bid is refunded in full and nothing is minted or paid.
    function test_ACancelledOneOfOneVoidsItsEditionAuction() public {
        (uint256 saleId, uint256 workId) = _startPiece(3);
        uint256 kept = _editionBid(workId, bidders[0], 4, 2);
        uint256 leaving = _editionBid(workId, bidders[1], 4, 1);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("piece dispute"));
        assertEq(_close(workId), type(uint64).max, "the close is undetermined while paused");
        uint256 during = _editionBid(workId, bidders[2], 7, 1);
        uint256 escrow = editionAuction.stepPrice(workId, 4);
        uint256 before = bidders[1].balance;
        vm.prank(bidders[1]);
        editionAuction.withdraw(leaving, bidders[1]);
        assertEq(bidders[1].balance - before, escrow, "a withdrawal refunds in full");

        bytes32 outcome = _platformStatement(
            address(stream), workId, StatementKinds.DISPUTE_OUTCOME, "ar://piece-outcome"
        );
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (saleId, outcome)));
        editionAuction.settle(workId, new uint256[](0));
        assertEq(
            uint8(editionAuction.auctionOf(workId).state),
            uint8(IUniformEditionAuction.AuctionState.VOID)
        );
        uint256[2] memory ids = [kept, during];
        address[2] memory who = [bidders[0], bidders[2]];
        uint256[2] memory paid = [2 * escrow, editionAuction.stepPrice(workId, 7)];
        for (uint256 i; i < 2; ++i) {
            uint256 b = who[i].balance;
            vm.prank(who[i]);
            (uint256 won, uint256 refund) = editionAuction.claimBid(ids[i], who[i]);
            assertEq(won, 0);
            assertEq(refund, paid[i]);
            assertEq(who[i].balance - b, paid[i]);
        }
        assertEq(address(editionAuction).balance, 0);
    }

    // ------------------------------------------------------------------ internals

    function _claimAndCheck(
        uint256 bidId,
        address bidder,
        uint256 step,
        uint256 quantity,
        uint256 workId,
        uint256 price
    ) internal returns (uint256 won) {
        uint256 paid = quantity * editionAuction.stepPrice(workId, step);
        uint256 before = bidder.balance;
        uint256 copies = editions.balanceOf(bidder, workId);
        uint256 refund;
        vm.prank(bidder);
        (won, refund) = editionAuction.claimBid(bidId, bidder);
        assertEq(refund, paid - won * price, "refund = escrow - won x price");
        assertEq(bidder.balance - before, refund);
        assertEq(editions.balanceOf(bidder, workId) - copies, won);
        assertEq(won, editionAuction.stepPrice(workId, step) >= price ? quantity : 0);
    }

    /// @dev The per-unit reference clearing of the auction's live book, read step by step.
    function _referenceOf(uint256 workId, uint32 cap)
        internal
        view
        returns (uint256 k, uint256 price)
    {
        IUniformEditionAuction.Auction memory a = editionAuction.auctionOf(workId);
        uint256 n = uint256(a.highStep) - a.lowStep + 1;
        uint256[] memory units = new uint256[](n);
        uint256[] memory prices = new uint256[](n);
        for (uint256 s; s < n; ++s) {
            units[s] = editionAuction.unitsAt(workId, a.lowStep + s);
            prices[s] = editionAuction.stepPrice(workId, a.lowStep + s);
        }
        uint256 margin = editionAuction.configOf(a.termsId).marginBps;
        (k, price,) = Ref.clear(units, prices, cap, margin);
    }
}
