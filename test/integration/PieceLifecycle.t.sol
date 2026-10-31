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

    /// @dev The edition auction through its full interface (its views are answered by its lens).
    function _ea() internal view returns (IUniformEditionAuction) {
        return IUniformEditionAuction(address(editionAuction));
    }

    /// @dev Starts master `index`'s 1/1 and, as the keeper does in the same batch, opens its
    ///      edition auction.
    function _startPiece(uint256 index)
        internal
        returns (uint256 saleId, uint256 workId, uint256 editionSale)
    {
        (saleId, workId) = _start(root, _package(root), index);
        vm.prank(keeper);
        editionSale =
            _ea().open(address(editions), workId, abi.encode(_package(root)[index].item));
        assertEq(editionSale, _ea().saleIdOf(address(editions), workId));
    }

    function _editionBid(uint256 sale, address bidder, uint256 step, uint256 quantity)
        internal
        returns (uint256 bidId)
    {
        uint256 cost = quantity * _ea().stepPrice(sale, step);
        vm.deal(bidder, bidder.balance + cost);
        vm.prank(bidder);
        bidId = _ea().bid{ value: cost }(sale, step, quantity);
    }

    function _createEdition(uint256 workId, uint256 index) internal {
        Work[] memory works = _package(root);
        editions.createEdition(workId, works[index].item, root, _proofOf(works, index));
    }

    function _close(uint256 sale) internal view returns (uint256) {
        return _ea().endTimes(sale).endTime;
    }

    function _offset(uint256 sale) internal view returns (uint256) {
        return _ea().auction(sale).terms.closeOffset;
    }

    // ------------------------------------------------------------------ the flows

    /// @dev The full life of a piece. Four bidders bid 3 copies at step 12, 2 at step 10, 4 at
    ///      step 6 and 1 at step 0; a late bid adds 1 at step 12. The clearing (checked against
    ///      the per-unit reference) sells 10 copies at step 6's price: 11 at step 0's price
    ///      would raise less than 90% of the best revenue. The bid at step 0 loses and gets
    ///      everything back.
    function test_AOneOfOneAndItsEditionsSellSideBySide() public {
        (uint256 saleId, uint256 workId, uint256 sale) = _startPiece(0);
        uint256[5] memory ids = _sideBySideBids(sale);
        _ethBid(saleId, collector, 1 ether);
        _antiSnipeMovesTheEditionClose(saleId, sale);

        // The 1/1 settles to the sniper and anyone creates the edition; the edition auction is
        // still open, and its own soft close extends it.
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(stream.ownerOf(workId), sniper);
        _createEdition(workId, 0);
        ids[4] = _softCloseExtends(sale);

        (uint256 k, uint256 price) = _settleAndCheckPayouts(sale);
        _claimEveryBid(sale, ids, k, price);
        assertEq(editions.edition(workId).minted, k, "the edition's supply is k");
        assertEq(address(editionAuction).balance, 0, "nothing left in escrow");

        // The edition pays its master's royalty rate.
        (, uint256 masterRoyalty) = stream.royaltyInfo(workId, 1 ether);
        (address receiver, uint256 editionRoyalty) = editions.royaltyInfo(workId, 1 ether);
        assertTrue(receiver != address(0));
        assertEq(editionRoyalty, masterRoyalty, "the master's rate");
    }

    uint256[5] internal sideSteps = [uint256(12), 10, 6, 0, 12];
    uint256[5] internal sideQuantities = [uint256(3), 2, 4, 1, 1];

    function _sideBySideBids(uint256 sale) internal returns (uint256[5] memory ids) {
        for (uint256 i; i < 4; ++i) {
            ids[i] = _editionBid(sale, bidders[i], sideSteps[i], sideQuantities[i]);
        }
    }

    /// @dev A 1/1 bid in its last minute: the 1/1's anti-snipe moves its end, and the edition
    ///      close follows it.
    function _antiSnipeMovesTheEditionClose(uint256 saleId, uint256 sale) internal {
        vm.warp(auction.auction(saleId).endTime - 1 minutes);
        _ethBid(saleId, sniper, 2 ether);
        uint256 oneOfOneEnd = auction.auction(saleId).endTime;
        assertEq(oneOfOneEnd, block.timestamp + auction.config().extensionWindow, "anti-snipe");
        assertEq(_close(sale), oneOfOneEnd + _offset(sale), "the edition close follows");
    }

    /// @dev A bid in the edition auction's last window extends its close; settling before the
    ///      new close is refused. Returns the late bid's ID.
    function _softCloseExtends(uint256 sale) internal returns (uint256 late) {
        uint256 window = _ea().auction(sale).terms.softWindow;
        vm.warp(_close(sale) - 1 minutes);
        late = _editionBid(sale, bidders[3], sideSteps[4], sideQuantities[4]);
        assertEq(_close(sale), block.timestamp + window, "the soft close extends the close");
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, sale)
        );
        _ea().settle(sale, new uint256[](0));
    }

    /// @dev The clearing equals the per-unit reference; settlement pays the network its share
    ///      and the seller the rest.
    function _settleAndCheckPayouts(uint256 sale) internal returns (uint256 k, uint256 price) {
        (k, price) = _referenceOf(sale, 0);
        assertEq(k, 10, "10 copies");
        assertEq(price, _ea().stepPrice(sale, 6), "at step 6's price");
        IUniformEditionAuction.Clearing memory live = _ea().clearing(sale);
        assertEq(live.count, k, "count");
        assertEq(live.price, price, "price");
        IUniformEditionAuction.Auction memory a = _ea().auction(sale);
        uint256 fee = k * price * a.feeShare / DENOMINATOR;
        uint256 feeBefore = a.feeRecipient.balance;
        uint256 sellerBefore = a.seller.balance;
        vm.warp(_close(sale));
        assertTrue(_ea().settle(sale, new uint256[](0)));
        assertEq(a.feeRecipient.balance - feeBefore, fee, "the network's share");
        assertEq(a.seller.balance - sellerBefore, k * price - fee, "the seller's share");
    }

    /// @dev Every bid claims: winners get their copies at the one price, everyone the rest back.
    function _claimEveryBid(uint256 sale, uint256[5] memory ids, uint256 k, uint256 price)
        internal
    {
        uint256 minted;
        for (uint256 i; i < 5; ++i) {
            minted += _claimAndCheck(sale, ids[i], price);
        }
        assertEq(minted, k, "exactly k copies");
    }

    /// @dev D140, D141: nobody bids on the 1/1, which goes to the 6529 Network Museum; its
    ///      editions sell all the same.
    function test_AnUnbidOneOfOneGoesToTheMuseumWhileItsEditionsSell() public {
        (uint256 saleId, uint256 workId, uint256 sale) = _startPiece(1);
        uint256 id = _editionBid(sale, bidders[0], 5, 2);
        _editionBid(sale, bidders[1], 3, 1);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(stream.ownerOf(workId), economics.museum(), "the museum holds the 1/1");
        _createEdition(workId, 1);
        vm.warp(_close(sale));
        assertTrue(_ea().settle(sale, new uint256[](0)));
        assertEq(_ea().settlement(sale).count, 3, "both bids win: 3 copies");
        vm.prank(bidders[0]);
        (uint256 won,) = _ea().claimBid(sale, id, bidders[0]);
        assertEq(won, 2);
        assertEq(editions.balanceOf(bidders[0], workId), 2);
    }

    /// @dev D141: no edition bid means no editions. The edition auction settles with a count of
    ///      zero, pays nothing and mints nothing, without the edition ever being created.
    function test_NoEditionBidsMintNothing() public {
        (uint256 saleId, uint256 workId, uint256 sale) = _startPiece(2);
        _ethBid(saleId, collector, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        IUniformEditionAuction.Auction memory ea = _ea().auction(sale);
        uint256 feeBefore = ea.feeRecipient.balance;
        vm.warp(_close(sale));
        assertTrue(_ea().settle(sale, new uint256[](0)));
        assertEq(_ea().settlement(sale).count, 0);
        assertEq(ea.feeRecipient.balance, feeBefore, "nothing paid");
        assertFalse(editions.exists(workId), "no edition was needed");
        assertEq(
            uint8(_ea().auction(sale).status),
            uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
    }

    /// @dev D141, owner decision 12: edition bidding continues while the 1/1 is paused for a
    ///      dispute and bidders may withdraw; an upheld dispute cancels the 1/1, which voids the
    ///      edition auction: every bid is refunded in full and nothing is minted or paid.
    function test_ACancelledOneOfOneVoidsItsEditionAuction() public {
        (uint256 saleId, uint256 workId, uint256 sale) = _startPiece(3);
        uint256 kept = _editionBid(sale, bidders[0], 4, 2);
        uint256 leaving = _editionBid(sale, bidders[1], 4, 1);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("piece dispute"));
        IUniformEditionAuction.EndTimes memory e = _ea().endTimes(sale);
        assertTrue(e.biddingOpen && e.withdrawalsOpen, "bidding and withdrawals open in a pause");
        vm.warp(e.endTime + 1 days);
        assertTrue(_ea().endTimes(sale).biddingOpen, "whatever the time");
        uint256 during = _editionBid(sale, bidders[2], 7, 1);
        uint256 escrow = _ea().stepPrice(sale, 4);
        uint256 before = bidders[1].balance;
        vm.prank(bidders[1]);
        _ea().withdrawBid(sale, leaving, bidders[1]);
        assertEq(bidders[1].balance - before, escrow, "a withdrawal refunds in full");

        bytes32 outcome = _platformStatement(
            address(stream), workId, StatementKinds.DISPUTE_OUTCOME, "ar://piece-outcome"
        );
        _govern(hotAdmin, address(auction), abi.encodeCall(auction.cancel, (saleId, outcome)));
        assertFalse(_ea().endTimes(sale).biddingOpen, "a cancelled 1/1 takes no bids");
        assertTrue(_ea().settle(sale, new uint256[](0)));
        assertEq(
            uint8(_ea().auction(sale).status),
            uint8(IUniformEditionAuction.AuctionStatus.VOID)
        );
        _refundInFull(sale, kept, bidders[0], 2 * escrow);
        _refundInFull(sale, during, bidders[2], _ea().stepPrice(sale, 7));
        assertEq(address(editionAuction).balance, 0);
        assertFalse(editions.exists(workId), "a void sale needs no edition");
    }

    // ------------------------------------------------------------------ internals

    /// @dev A void sale's claim: no copies, the whole escrow back.
    function _refundInFull(uint256 sale, uint256 bidId, address bidder, uint256 paid) internal {
        uint256 before = bidder.balance;
        vm.prank(bidder);
        (uint256 won, uint256 refund) = _ea().claimBid(sale, bidId, bidder);
        assertEq(won, 0);
        assertEq(refund, paid);
        assertEq(bidder.balance - before, paid);
    }

    /// @dev The bidder claims bid `bidId`: it wins all its units at or above the clearing price,
    ///      none below, and gets back its escrow less the copies at the one price.
    function _claimAndCheck(uint256 sale, uint256 bidId, uint256 price)
        internal
        returns (uint256 won)
    {
        IUniformEditionAuction.Bid memory b = _ea().bidOf(sale, bidId);
        uint256 paid = uint256(b.quantity) * _ea().stepPrice(sale, b.step);
        uint256 before = b.bidder.balance;
        uint256 copies = editions.balanceOf(b.bidder, _ea().auction(sale).id);
        uint256 refund;
        vm.prank(b.bidder);
        (won, refund) = _ea().claimBid(sale, bidId, b.bidder);
        assertEq(refund, paid - won * price, "refund = escrow - won x price");
        assertEq(b.bidder.balance - before, refund);
        assertEq(editions.balanceOf(b.bidder, _ea().auction(sale).id) - copies, won);
        assertEq(won, _ea().stepPrice(sale, b.step) >= price ? b.quantity : 0);
    }

    /// @dev The per-unit reference clearing of the auction's live book (`stepTotals`).
    function _referenceOf(uint256 sale, uint32 cap) internal view returns (uint256 k, uint256 price) {
        (uint256 low, uint256[] memory units) = _ea().stepTotals(sale);
        uint256[] memory prices = new uint256[](units.length);
        for (uint256 s; s < units.length; ++s) {
            prices[s] = _ea().stepPrice(sale, low + s);
        }
        (k, price,) = Ref.clear(units, prices, cap, _ea().auction(sale).terms.marginShare);
    }
}
