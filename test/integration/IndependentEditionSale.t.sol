// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { IndependentEditionAuction } from "src/independent/IndependentEditionAuction.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { Edition, Outcome, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { PRODUCT_INDEPENDENT } from "src/interfaces/types/EconomicsTypes.sol";
import { IndependentIntegrationBase } from "./IndependentIntegrationBase.sol";

/// @notice An Independent Stream edition sale end to end on the real deployed stack (IND-53,
///         IND-54, IND-57 in `docs/spec/independent-stream.md`): an artist's pair deployed through
///         the genesis template deployers and listed; a master work approved, minted through the
///         English auction and its record opened and finalized; its edition created at the open of
///         the Independent Stream edition auction; five bids, four winning and one losing; the
///         1/1 sold; the edition cleared at one price, the copies claimed and the loser refunded;
///         the money split 90/10 between the artist's side and the network, released from the
///         split wallet to the artist and the collaborator and forwarded from the fee vault, with
///         every wei paid in accounted for.
contract IndependentEditionSaleTest is IndependentIntegrationBase {
    /// @dev The collaborator's share of the seller's side, of 100,000.
    uint32 internal constant COLLAB_SHARE = 30_000;
    uint256 internal constant ONE_OF_ONE_PRICE = 1 ether;

    address internal artist;
    address internal collab;
    address internal collector = makeAddr("independentCollector");
    IndependentStream6529 internal fStream;
    IndependentStreamEditions6529 internal fEditions;
    IndependentEditionAuction internal indAuction;
    /// @dev The adapter's views, answered by its lens through its fallback.
    IUniformEditionAuction internal ea;

    address[5] internal bidders;
    uint256[5] internal escrowed;
    /// @dev Everything the bidders and the collector paid in.
    uint256 internal paidIn;

    uint256 internal oneSaleId;
    uint256 internal tokenId;
    uint256 internal saleId;
    address internal seller;
    address internal fee;
    uint256 internal escrowBefore;
    uint256 internal feeBefore;
    uint256 internal feeSafeBefore;

    function setUp() public override {
        super.setUp();
        artist = _actor("independentEditionArtist");
        collab = _actor("independentEditionCollaborator");
        (fStream, fEditions) = _listPair(artist);
        indAuction = IndependentEditionAuction(payable(deployment.independentEditionAuction));
        ea = IUniformEditionAuction(address(indAuction));
        bidders = [
            makeAddr("indB1"),
            makeAddr("indB2"),
            makeAddr("indB3"),
            makeAddr("indB4"),
            makeAddr("indB5")
        ];
    }

    /// @dev The whole flow. The book is the edition auction's worked example (80 copies at
    ///      0.0511 ETH, 4.088 ETH raised; a bid of 200 below the clearing step loses), here on an
    ///      artist's own pair at the Independent Stream share: 0.4088 ETH to the network and
    ///      3.6792 ETH to the seller's split wallet, which also holds 0.9 ETH of the 1 ETH paid
    ///      for the 1/1; the wallet pays 30% to the collaborator and 70% to the artist.
    function test_IndependentEditionSale_BidsClearCopiesAreClaimedAndEveryWeiIsAccounted() public {
        // The master: approved by the artist, consented by the collaborator, minted at the start
        // of its 1/1 sale, its record opened by anyone and finalized by the artist.
        Work memory w = _withIndCollaborator(_asMaster(_fedWork(artist), 0), collab, COLLAB_SHARE);
        _startMasterSale(w);
        facts.open(address(fStream), tokenId, w.item, w.media);
        bytes32 state = rules.workStateHash(address(fStream), tokenId);
        vm.prank(artist);
        rules.finalize(address(fStream), tokenId, state);
        assertTrue(facts.factsOf(address(fStream), tokenId).finalized, "the record is finalized");

        // The edition is created when its sale opens, with the listing's share locked.
        seller = ledger.walletFor(w.item.payees, bytes32(0));
        fee = economics.networkFeeRecipient(PRODUCT_INDEPENDENT);
        saleId = indAuction.open(address(fEditions), tokenId, abi.encode(w.item));
        _checkOpened();

        escrowBefore = address(escrow).balance;
        feeBefore = fee.balance;
        feeSafeBefore = feeSafe.balance;

        // Five bids, then the 1/1 is bid on and sold.
        _bidAndSellTheOneOfOne();

        // The edition clears at one price and pays the two sides.
        IUniformEditionAuction.Clearing memory c = ea.clearing(saleId);
        assertEq(c.count, 80, "copies sold");
        assertEq(c.price, 0.0511 ether, "the clearing price");
        assertEq(c.revenue, 4.088 ether, "raised");
        assertEq(c.networkFee, 0.4088 ether, "10% of the revenue");
        _settleEdition();
        assertEq(
            uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        assertEq(seller.balance, 0.9 ether + 3.6792 ether, "the edition: 90% to the seller");
        assertEq(fee.balance - feeBefore, 0.1 ether + 0.4088 ether, "the edition: 10%");
        assertEq(c.revenue, 3.6792 ether + 0.4088 ether, "the two sides are the revenue");

        // Every bid is claimed: the winners take copies and the rest of their escrow, the loser
        // everything it paid.
        assertEq(_claimAll(c.price), paidIn - ONE_OF_ONE_PRICE - c.revenue, "refunds are the rest");
        assertEq(fEditions.balanceOf(bidders[4], tokenId), 0, "the loser has no copy");
        assertEq(bidders[4].balance, 200 * 0.01 ether, "the loser gets everything back");
        Edition memory e = fEditions.editionOf(tokenId);
        assertEq(e.minted, 80, "exactly the copies sold");
        assertEq(e.maxSupply, 80, "sealed at the count");
        assertTrue(e.supplySealed, "sealed");

        // The seller's wallet pays its payees through the ledger; the fee vault forwards.
        _releaseAndForward(w.item.payees);
        _checkConservation();
    }

    /// @dev The network empties the INDEPENDENT_STREAM slot while an edition sale is open. The
    ///      sale voids: the bid is refunded in full, once; nothing is paid out, nothing is minted
    ///      and nothing is sealed, because with no module the editions contract lets no sale
    ///      contract seal.
    function test_IndependentEditionSale_AnEmptiedSlotVoidsWithRefundsAndSealsNothing() public {
        Work memory w = _withIndCollaborator(_asMaster(_fedWork(artist), 0), collab, COLLAB_SHARE);
        _startMasterSale(w);
        seller = ledger.walletFor(w.item.payees, bytes32(0));
        fee = economics.networkFeeRecipient(PRODUCT_INDEPENDENT);
        saleId = indAuction.open(address(fEditions), tokenId, abi.encode(w.item));
        uint256 amount = _bid(bidders[0], 100, 3);
        (uint256 sellerBefore, uint256 feeAtOpen) = (seller.balance, fee.balance);
        _asNetwork(
            address(directory), abi.encodeCall(directory.removeModule, (Slots.INDEPENDENT_STREAM))
        );

        assertEq(fEditions.minterRemovedAt(address(indAuction)), block.timestamp);
        vm.prank(address(indAuction));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEditions.NotEditionMinter.selector, tokenId, address(indAuction)
            )
        );
        fEditions.seal(tokenId, 0);

        assertTrue(indAuction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertEq(address(indAuction).balance, amount, "the escrow waits for its claim");
        vm.prank(bidders[0]);
        (uint256 won, uint256 refund) = indAuction.claimBid(saleId, 1, bidders[0]);
        assertEq(won, 0);
        assertEq(refund, amount);
        assertEq(bidders[0].balance, amount, "refunded in full");
        assertEq(address(indAuction).balance, 0, "nothing left behind");
        vm.prank(bidders[0]);
        vm.expectRevert();
        indAuction.claimBid(saleId, 1, bidders[0]);
        assertEq(seller.balance, sellerBefore, "nothing paid to the seller");
        assertEq(fee.balance, feeAtOpen, "nothing paid to the network");
        Edition memory e = fEditions.editionOf(tokenId);
        assertEq(e.minted, 0);
        assertFalse(e.supplySealed, "nothing new is sealed with no module");
    }

    // ------------------------------------------------------------------ steps

    /// @dev Approves `w` at `IND_RATE` and starts its 1/1 with the collaborator's consent.
    function _startMasterSale(Work memory w) internal {
        _approveInd(address(fStream), artist, w, IND_RATE);
        bytes[] memory consents = new bytes[](1);
        consents[0] = _fedConsent(collab, address(fStream), w, IND_RATE);
        oneSaleId = auction.start(address(fStream), _fedRequest(w, consents));
        tokenId = fStream.totalMinted();
        assertEq(fStream.ownerOf(tokenId), address(auction), "in the auction's custody");
    }

    /// @dev The sale and the edition as the open leaves them.
    function _checkOpened() internal view {
        assertEq(saleId, ea.saleIdOf(address(fEditions), tokenId), "sale ID");
        assertEq(fee, networkFee, "the Independent Stream fee recipient is the fee vault");
        IUniformEditionAuction.Auction memory a = ea.auction(saleId);
        assertEq(a.token, address(fEditions));
        assertEq(a.master, address(fStream), "the master is the partner contract");
        assertEq(a.seller, seller, "the seller is the master's split wallet");
        assertEq(a.feeRecipient, fee);
        assertEq(a.feeShare, IND_SHARE, "the listing's share: 10%");
        assertTrue(seller.code.length != 0, "the seller's wallet is deployed");
        Edition memory e = fEditions.editionOf(tokenId);
        assertEq(e.minter, address(indAuction), "the edition belongs to this sale contract");
        assertEq(e.minted, 0);
        assertFalse(e.supplySealed);
        address vault = ledger.walletFor(Splits.royaltyPayees(seller, fee, IND_SHARE), bytes32(0));
        (address receiver, uint256 royalty) = fEditions.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, vault, "royalties to the vault at the listing's share");
        assertTrue(vault.code.length != 0, "the royalty vault is deployed");
        assertEq(royalty, 0.05 ether, "the master's royalty rate");
    }

    /// @dev The five edition bids, then one bid on the 1/1, settled at its end: 90% of its price
    ///      to the seller's wallet and 10% to the network.
    function _bidAndSellTheOneOfOne() internal {
        uint16[5] memory steps = [uint16(192), 158, 144, 130, 96];
        uint32[5] memory quantities = [uint32(1), 9, 20, 50, 200];
        paidIn = ONE_OF_ONE_PRICE;
        for (uint256 i; i < 5; ++i) {
            escrowed[i] = _bid(bidders[i], steps[i], quantities[i]);
            paidIn += escrowed[i];
        }
        assertEq(address(indAuction).balance, paidIn - ONE_OF_ONE_PRICE, "the bids are held");
        _ethBid(oneSaleId, collector, ONE_OF_ONE_PRICE);
        _settleAtEnd(oneSaleId);
        assertEq(fStream.ownerOf(tokenId), collector, "the 1/1 is delivered");
        assertEq(uint8(fStream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
        assertEq(seller.balance, 0.9 ether, "the 1/1: 90% to the seller's wallet");
        assertEq(fee.balance - feeBefore, 0.1 ether, "the 1/1: 10% to the network");
    }

    /// @dev `bidder` bids `quantity` at `step` with exactly its escrow; returns the escrow.
    function _bid(address bidder, uint256 step, uint256 quantity)
        internal
        returns (uint256 amount)
    {
        amount = quantity * ea.stepPrice(saleId, step);
        vm.deal(bidder, amount);
        vm.prank(bidder);
        indAuction.bid{ value: amount }(saleId, step, quantity);
        assertEq(bidder.balance, 0, "the whole escrow is paid in");
    }

    /// @dev Warps to the edition close and settles with the lens's order until done.
    function _settleEdition() internal {
        uint256 end = ea.endTimes(saleId).endTime;
        if (block.timestamp < end) vm.warp(end);
        IUniformEditionAuctionLens l = IUniformEditionAuctionLens(address(indAuction));
        for (
            uint256 i;
            !indAuction.settle(saleId, l.settlementOrderFor(saleId, address(this)));
            ++i
        ) {
            require(i < 64, "settlement does not advance");
        }
    }

    /// @dev Each bidder claims its own bid: copies minted to it and its refund sent to it, each
    ///      refund the bid's escrow less the copies won at the clearing `price`.
    function _claimAll(uint256 price) internal returns (uint256 refunds) {
        uint256 minted;
        for (uint256 i; i < 5; ++i) {
            vm.prank(bidders[i]);
            (uint256 won, uint256 refund) = indAuction.claimBid(saleId, i + 1, bidders[i]);
            assertEq(fEditions.balanceOf(bidders[i], tokenId), won, "copies minted to the bidder");
            assertEq(refund, escrowed[i] - won * price, "the refund is the escrow less the price");
            assertEq(bidders[i].balance, refund, "the refund is paid");
            minted += won;
            refunds += refund;
        }
        assertEq(minted, 80, "the winners hold every copy sold");
    }

    /// @dev The collaborator (a fixed payee, index 0) and the artist (index 1) are paid by the
    ///      ledger from the seller's wallet; the fee vault forwards what it took to the network's
    ///      destination.
    function _releaseAndForward(ISplitWallet.Payee[] memory payees) internal {
        uint256 held = 0.9 ether + 3.6792 ether;
        assertEq(ledger.release(payees, bytes32(0), address(0), 0), held * 30 / 100, "30%");
        vm.prank(artist);
        assertEq(ledger.release(payees, bytes32(0), address(0), 1), held * 70 / 100, "70%");
        assertEq(collab.balance, 1.37376 ether, "the collaborator's share");
        assertEq(artist.balance, 3.20544 ether, "the artist's share");

        assertEq(feeVault.destination(), feeSafe);
        feeVault.forward(address(0), 0.1 ether + 0.4088 ether);
        assertEq(feeSafe.balance - feeSafeBefore, 0.5088 ether, "the network's 10% of both sales");
    }

    /// @dev What the bidders and the collector paid is what the artist, the collaborator, the
    ///      network and the refunded bidders hold; nothing is left in between.
    function _checkConservation() internal view {
        uint256 paidOut = artist.balance + collab.balance + (feeSafe.balance - feeSafeBefore);
        for (uint256 i; i < 5; ++i) {
            paidOut += bidders[i].balance;
        }
        assertEq(paidOut, paidIn, "every wei paid in is paid out");
        assertEq(collector.balance, 0, "the collector paid its bid");
        assertEq(address(indAuction).balance, 0, "the edition auction holds nothing");
        assertEq(address(auction).balance, 0, "the English auction holds nothing");
        assertEq(seller.balance, 0, "the seller's wallet holds nothing");
        assertEq(fee.balance, feeBefore, "the fee vault holds nothing of this sale");
        assertEq(address(escrow).balance, escrowBefore, "nothing went to the escrow");
    }
}
