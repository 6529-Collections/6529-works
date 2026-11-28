// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IndependentEditionAuction } from "src/independent/IndependentEditionAuction.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { Edition, Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { PRODUCT_INDEPENDENT, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionAuctionStack } from "./EditionAuctionStack.sol";
import { IndependentIntegrationBase } from "./IndependentIntegrationBase.sol";
import { ContractWallet, SaleFlowBase } from "./SaleFlowBase.sol";

/// @notice Where a rescued work is when its sale is settled: with the rescue's recipient; in the
///         auction because the network named the auction itself as the recipient (the token
///         never moved); or in the auction because the recipient sent it back.
enum Custody {
    ELSEWHERE,
    RESCUED_TO_THE_AUCTION,
    SENT_BACK
}

/// @notice A 6529 Stream sale whose work the network rescued, on the deployed stack (AUC-36,
///         AUC-56, EA-22 and LIM-SAL-14). The sale closes with refunds whether the work is with
///         the rescue's recipient or in the auction's custody again: the standing bid is credited
///         once, nothing is recorded or paid, a work in custody goes to the museum, and an
///         edition sale that followed the 1/1 is void with every bid refunded in full.
contract RescuedSaleStreamTest is EditionAuctionStack {
    address internal artist;
    address internal bidder = makeAddr("rescueBidder");
    address internal fan = makeAddr("rescueFan");
    address internal safe = makeAddr("rescueRecipient");

    /// @dev The wallets the 1/1 and the edition sale would pay.
    address internal oneSeller;
    address internal editionSeller;
    uint256 internal oneSaleId;
    uint256 internal tokenId;
    uint256 internal editionSaleId;
    uint256 internal editionBidId;
    uint256 internal editionEscrow;

    function setUp() public override {
        super.setUp();
        artist = _actor("rescueArtist");
    }

    // ------------------------------------------------------------------ steps

    /// @dev Starts a 1/1 (with a bid of `oneBid` unless zero) and, when `linked`, opens its
    ///      edition sale and bids two copies on it.
    function _startSale(uint256 oneBid, bool linked) internal {
        Work memory w;
        if (linked) {
            (, w, oneSaleId, tokenId, editionSaleId) = _startMaster(artist, 0);
            editionSeller = _editionSeller(w);
            editionEscrow = 2 * ea.stepPrice(editionSaleId, 40);
            editionBidId = _editionBid(editionSaleId, fan, 40, 2);
        } else {
            w = _work(artist, collectionId);
            Work[] memory works = _one(w);
            (oneSaleId, tokenId) = _start(_publish(works), works, 0);
        }
        oneSeller = economics.newWorkTerms(PRODUCT_STREAM, w.item.payees).seller;
        if (oneBid != 0) _ethBid(oneSaleId, bidder, oneBid);
    }

    /// @dev The network removes the auction as a minter, waits `rescueDelay` and rescues the
    ///      work, leaving it where `custody` says.
    function _rescue(Custody custody) internal {
        _asNetwork(address(stream), abi.encodeCall(stream.removeMinter, (address(auction))));
        vm.warp(block.timestamp + stream.rescueDelay());
        address to = custody == Custody.RESCUED_TO_THE_AUCTION ? address(auction) : safe;
        _asNetwork(address(stream), abi.encodeCall(stream.rescue, (tokenId, to)));
        if (custody == Custody.SENT_BACK) {
            vm.prank(safe);
            stream.transferFrom(safe, address(auction), tokenId);
        }
        assertEq(
            stream.ownerOf(tokenId), custody == Custody.ELSEWHERE ? safe : address(auction), "held"
        );
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.RESCUED));
    }

    /// @dev Anyone settles the rescued 1/1: it closes for good with the bid credited once and
    ///      claimed, nothing recorded or paid, and a work in custody sent to the museum.
    function _closeTheOneOfOne(Custody custody, uint256 oneBid) internal {
        address seller = oneSeller;
        (uint256 sellerBefore, uint256 feeBefore) = (seller.balance, networkFee.balance);
        assertEq(uint8(auction.auction(oneSaleId).state), uint8(IEnglishAuction.AuctionState.ENDED));
        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(oneSaleId);
        auction.settle(oneSaleId);

        assertEq(
            uint8(auction.auction(oneSaleId).state),
            uint8(IEnglishAuction.AuctionState.CANCELLED),
            "closed for good"
        );
        assertEq(
            stream.ownerOf(tokenId),
            custody == Custody.ELSEWHERE ? safe : museum,
            "the work is with the rescue's recipient, or in the museum"
        );
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.RESCUED));
        assertEq(auction.claimable(bidder), oneBid, "the standing bid, credited once");
        assertEq(address(auction).balance, oneBid, "the auction holds the credit only");
        assertEq(seller.balance, sellerBefore, "the seller is paid nothing");
        assertEq(networkFee.balance, feeBefore, "the network is paid nothing");

        bytes memory closed = abi.encodeWithSelector(
            IEnglishAuction.InvalidAuctionState.selector,
            oneSaleId,
            IEnglishAuction.AuctionState.CANCELLED
        );
        vm.expectRevert(closed);
        auction.settle(oneSaleId);
        vm.expectRevert(closed);
        auction.settleOrRefund(oneSaleId);
        if (oneBid != 0) {
            vm.prank(bidder);
            auction.claim(bidder);
            assertEq(bidder.balance, oneBid, "the bidder has its bid back");
        }
        assertEq(auction.claimable(bidder), 0);
        assertEq(address(auction).balance, 0, "nothing is left and nothing was paid twice");
    }

    /// @dev The edition sale that followed the rescued 1/1 is void: anyone settles it, the fan
    ///      claims its whole payment and no copy, and the edition is sealed at zero.
    function _theEditionSaleIsVoid() internal {
        address seller = editionSeller;
        (uint256 sellerBefore, uint256 feeBefore) = (seller.balance, networkFee.balance);
        vm.expectEmit(address(editionAuction));
        emit IUniformEditionAuction.AuctionVoided(editionSaleId);
        assertTrue(editionAuction.settle(editionSaleId, new uint256[](0)));
        assertEq(
            uint8(ea.auction(editionSaleId).status),
            uint8(IUniformEditionAuction.AuctionStatus.VOID)
        );
        vm.prank(fan);
        (uint256 won, uint256 refund) = editionAuction.claimBid(editionSaleId, editionBidId, fan);
        assertEq(won, 0, "no copy of a rescued master is sold");
        assertEq(refund, editionEscrow, "refunded in full");
        assertEq(fan.balance, editionEscrow);
        assertEq(editions.balanceOf(fan, tokenId), 0);
        assertEq(address(editionAuction).balance, 0, "the edition auction holds nothing");
        assertEq(seller.balance, sellerBefore, "the seller is paid nothing");
        assertEq(networkFee.balance, feeBefore, "the network is paid nothing");
        Edition memory e = editions.editionOf(tokenId);
        assertTrue(e.supplySealed && e.maxSupply == 0 && e.minted == 0, "sealed at zero");
        vm.prank(fan);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.UnknownBid.selector, editionSaleId, editionBidId
            )
        );
        editionAuction.claimBid(editionSaleId, editionBidId, fan);
    }

    function _run(Custody custody, uint256 oneBid, bool linked) internal {
        _startSale(oneBid, linked);
        _rescue(custody);
        if (linked) {
            // Until the 1/1 is closed the edition sale waits for it.
            vm.expectRevert(
                abi.encodeWithSelector(
                    IUniformEditionAuction.SettlementNotReady.selector, editionSaleId
                )
            );
            editionAuction.settle(editionSaleId, new uint256[](0));
        }
        _closeTheOneOfOne(custody, oneBid);
        if (linked) _theEditionSaleIsVoid();
    }

    // ------------------------------------------------------------------ the 1/1 alone

    function test_RescuedSale_WorkWithItsRecipient_TheBidIsRefunded() public {
        _run(Custody.ELSEWHERE, 1 ether, false);
    }

    function test_RescuedSale_RescuedToTheAuctionItself_TheBidIsRefundedAndTheWorkGoesToTheMuseum()
        public
    {
        _run(Custody.RESCUED_TO_THE_AUCTION, 1 ether, false);
    }

    function test_RescuedSale_SentBackToTheAuction_TheBidIsRefundedAndTheWorkGoesToTheMuseum()
        public
    {
        _run(Custody.SENT_BACK, 1 ether, false);
    }

    function test_RescuedSale_BackInCustodyWithNoBid_ClosesAndTheWorkGoesToTheMuseum() public {
        _run(Custody.RESCUED_TO_THE_AUCTION, 0, false);
    }

    // ------------------------------------------------------------------ with an edition sale

    function test_RescuedSale_WorkWithItsRecipient_TheEditionSaleIsVoid() public {
        _run(Custody.ELSEWHERE, 1 ether, true);
    }

    function test_RescuedSale_WorkWithItsRecipientAndNoBid_TheEditionSaleIsVoid() public {
        _run(Custody.ELSEWHERE, 0, true);
    }

    function test_RescuedSale_RescuedToTheAuctionItself_TheEditionSaleIsVoid() public {
        _run(Custody.RESCUED_TO_THE_AUCTION, 1 ether, true);
    }

    function test_RescuedSale_RescuedToTheAuctionItselfAndNoBid_TheEditionSaleIsVoid() public {
        _run(Custody.RESCUED_TO_THE_AUCTION, 0, true);
    }

    function test_RescuedSale_SentBackToTheAuction_TheEditionSaleIsVoid() public {
        _run(Custody.SENT_BACK, 1 ether, true);
    }

    // ------------------------------------------------------------------ around the close

    /// @dev Adding the auction as a minter again after the rescue changes nothing: the recorded
    ///      outcome, not the minter list, says the work was rescued.
    function test_RescuedSale_ClosesTheSameAfterTheAuctionIsAddedAgain() public {
        _startSale(1 ether, false);
        _rescue(Custody.RESCUED_TO_THE_AUCTION);
        _asNetwork(address(stream), abi.encodeCall(stream.addMinter, (address(auction))));
        vm.warp(block.timestamp + stream.moduleDelay());
        assertTrue(stream.isMinter(address(auction)));
        _closeTheOneOfOne(Custody.RESCUED_TO_THE_AUCTION, 1 ether);
    }

    /// @dev No edition sale opens for a master whose 1/1 sale closed after a rescue.
    function test_RescuedSale_NoEditionSaleOpensAfterTheClose() public {
        Work memory w;
        (w, oneSaleId, tokenId) = _startUnopened(artist, 0);
        _rescue(Custody.ELSEWHERE);
        auction.settle(oneSaleId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.NoOneOfOneAuction.selector, address(stream), tokenId
            )
        );
        editionAuction.open(address(editions), tokenId, _openData(w));
    }
}

/// @notice The same for an Independent Stream work and its pair's edition sale. The sale closes
///         by `settle` at its end, with no wait for the refusal exit, and the closed sale is
///         never offered again.
contract RescuedSaleIndependentTest is IndependentIntegrationBase {
    address internal artist;
    address internal bidder = makeAddr("indRescueBidder");
    address internal fan = makeAddr("indRescueFan");
    address internal safe = makeAddr("indRescueRecipient");
    IndependentStream6529 internal fStream;
    IndependentStreamEditions6529 internal fEditions;
    IndependentEditionAuction internal indAuction;
    IUniformEditionAuction internal ea;

    bytes internal itemData;
    address internal seller;
    uint256 internal oneSaleId;
    uint256 internal tokenId;
    /// @dev Close the rescued sale with `settleOrRefund`, from the refusal delay, instead of
    ///      with `settle` at the end.
    bool internal closeByRefusalExit;

    function setUp() public override {
        super.setUp();
        artist = _actor("indRescueArtist");
        (fStream, fEditions) = _listPair(artist);
        indAuction = IndependentEditionAuction(payable(deployment.independentEditionAuction));
        ea = IUniformEditionAuction(address(indAuction));
        Work memory master = _asMaster(_fedWork(artist), 0);
        itemData = abi.encode(master.item);
        seller = ledger.walletFor(master.item.payees, bytes32(0));
        _approveInd(address(fStream), artist, master, IND_RATE);
        (oneSaleId, tokenId) = _fedStart(address(fStream), master);
    }

    /// @dev The network removes the auction as a sale contract and, with the token's rescue wait
    ///      set to zero, rescues the work while its sale is still running.
    function _rescue(Custody custody) internal {
        _asNetwork(
            address(independentStream),
            abi.encodeCall(
                independentStream.setAdapter,
                (address(auction), IIndependentStreamRegistry.Form.ERC721, false)
            )
        );
        vm.prank(network);
        fStream.setRescueDelay(0);
        address to = custody == Custody.RESCUED_TO_THE_AUCTION ? address(auction) : safe;
        vm.prank(network);
        fStream.rescue(tokenId, to);
        if (custody == Custody.SENT_BACK) {
            vm.prank(safe);
            fStream.transferFrom(safe, address(auction), tokenId);
        }
        assertEq(uint8(fStream.workOf(tokenId).outcome), uint8(Outcome.RESCUED));
    }

    function _run(Custody custody, uint256 oneBid, bool linked) internal {
        uint256 saleId;
        uint256 escrowed;
        if (linked) {
            saleId = indAuction.open(address(fEditions), tokenId, itemData);
            escrowed = 2 * ea.stepPrice(saleId, 40);
            vm.deal(fan, escrowed);
            vm.prank(fan);
            indAuction.bid{ value: escrowed }(saleId, 40, 2);
        }
        if (oneBid != 0) _ethBid(oneSaleId, bidder, oneBid);
        _rescue(custody);
        address fee = economics.networkFeeRecipient(PRODUCT_INDEPENDENT);
        (uint256 sellerBefore, uint256 feeBefore) = (seller.balance, fee.balance);
        _closeTheOneOfOne(custody, oneBid);
        if (linked) _theEditionSaleIsVoid(saleId, escrowed);
        assertEq(seller.balance, sellerBefore, "the seller is paid nothing");
        assertEq(fee.balance, feeBefore, "the network is paid nothing");
    }

    /// @dev At the end, two days before the refusal exit opens, `settle` closes the rescued
    ///      sale for good: the bid is credited once and claimed, a work in custody goes to the
    ///      museum, and the work is never offered again.
    function _closeTheOneOfOne(Custody custody, uint256 oneBid) internal {
        vm.warp(auction.auction(oneSaleId).endTime);
        if (closeByRefusalExit) vm.warp(block.timestamp + auction.REFUSAL_DELAY());
        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(oneSaleId);
        if (closeByRefusalExit) auction.settleOrRefund(oneSaleId);
        else auction.settle(oneSaleId);
        assertEq(
            uint8(auction.auction(oneSaleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        assertEq(fStream.ownerOf(tokenId), custody == Custody.ELSEWHERE ? safe : museum);
        assertEq(auction.claimable(bidder), oneBid, "the standing bid, credited once");
        assertEq(address(auction).balance, oneBid);
        if (oneBid != 0) {
            vm.prank(bidder);
            auction.claim(bidder);
            assertEq(bidder.balance, oneBid);
        }
        assertEq(address(auction).balance, 0, "nothing is left and nothing was paid twice");

        bytes memory closed = abi.encodeWithSelector(
            IEnglishAuction.InvalidAuctionState.selector,
            oneSaleId,
            IEnglishAuction.AuctionState.CANCELLED
        );
        vm.warp(block.timestamp + auction.REFUSAL_DELAY());
        vm.expectRevert(closed);
        auction.settle(oneSaleId);
        vm.expectRevert(closed);
        auction.settleOrRefund(oneSaleId);
        vm.expectRevert(closed);
        auction.restart(oneSaleId);
    }

    /// @dev The edition sale that followed the rescued 1/1 is void, with its one bid refunded
    ///      in full and the edition sealed at zero.
    function _theEditionSaleIsVoid(uint256 saleId, uint256 escrowed) internal {
        vm.expectEmit(address(indAuction));
        emit IUniformEditionAuction.AuctionVoided(saleId);
        assertTrue(indAuction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ea.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        vm.prank(fan);
        (uint256 won, uint256 refund) = indAuction.claimBid(saleId, 1, fan);
        assertEq(won, 0, "no copy of a rescued master is sold");
        assertEq(refund, escrowed, "refunded in full");
        assertEq(fan.balance, escrowed);
        assertEq(address(indAuction).balance, 0);
        Edition memory e = fEditions.editionOf(tokenId);
        assertTrue(e.supplySealed && e.maxSupply == 0 && e.minted == 0, "sealed at zero");
    }

    function test_RescuedIndependentSale_WorkWithItsRecipient_TheBidIsRefunded() public {
        _run(Custody.ELSEWHERE, 1 ether, false);
    }

    function test_RescuedIndependentSale_RescuedToTheAuctionItself_ClosesAtTheEnd() public {
        _run(Custody.RESCUED_TO_THE_AUCTION, 1 ether, false);
    }

    function test_RescuedIndependentSale_SentBackWithNoBid_ClosesAndGoesToTheMuseum() public {
        _run(Custody.SENT_BACK, 0, false);
    }

    function test_RescuedIndependentSale_WorkWithItsRecipient_TheEditionSaleIsVoid() public {
        _run(Custody.ELSEWHERE, 1 ether, true);
    }

    function test_RescuedIndependentSale_RescuedToTheAuctionItself_TheEditionSaleIsVoid() public {
        _run(Custody.RESCUED_TO_THE_AUCTION, 1 ether, true);
    }

    function test_RescuedIndependentSale_SentBackWithNoBid_TheEditionSaleIsVoid() public {
        _run(Custody.SENT_BACK, 0, true);
    }

    /// @dev The refusal exit as the first closing call: its attempt is `settle` itself, which
    ///      succeeds for a rescued sale, so the sale ends cancelled (not settled after a refused
    ///      settlement), the bid is credited once and the edition sale is void.
    function test_RescuedIndependentSale_ClosedBySettleOrRefund_TheEditionSaleIsVoid() public {
        closeByRefusalExit = true;
        _run(Custody.RESCUED_TO_THE_AUCTION, 1 ether, true);
    }

    function test_RescuedIndependentSale_ClosedBySettleOrRefund_WorkWithItsRecipient() public {
        closeByRefusalExit = true;
        _run(Custody.ELSEWHERE, 1 ether, true);
    }
}

/// @notice What a rescue can reach (AUC-35, AUC-57, LIM-SAL-14): only a token that a removed
///         minter holds with no outcome recorded. The English auction records the outcome of
///         every work before the work leaves it, so no work it sold, sent to the museum or keeps
///         for a pending delivery can be rescued, whatever the network does to its minter list.
contract RescueReachTest is SaleFlowBase {
    address internal artist;
    ContractWallet internal wallet;

    function setUp() public override {
        super.setUp();
        artist = _actor("reachArtist");
        wallet = new ContractWallet();
        // The network's waits at zero: the least a rescue ever needs.
        _asNetwork(address(stream), abi.encodeCall(stream.setModuleDelay, (0)));
        _asNetwork(address(stream), abi.encodeCall(stream.setRescueDelay, (0)));
    }

    function _startOne() internal returns (uint256 saleId, uint256 tokenId) {
        Work[] memory works = _one(_work(artist, collectionId));
        (saleId, tokenId) = _start(_publish(works), works, 0);
    }

    /// @dev The network makes `holder` a removed minter, then tries to rescue `tokenId` from it.
    function _expectOutOfReach(address holder, uint256 tokenId) internal {
        if (stream.minterOf(holder).activeFrom == 0) {
            _asNetwork(address(stream), abi.encodeCall(stream.addMinter, (holder)));
        }
        if (stream.minterOf(holder).removedAt == 0) {
            _asNetwork(address(stream), abi.encodeCall(stream.removeMinter, (holder)));
        }
        assertGt(stream.minterOf(holder).removedAt, 0, "a removed minter");
        assertEq(stream.ownerOf(tokenId), holder);
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(IStream.NotRescuable.selector, tokenId));
        stream.rescue(tokenId, makeAddr("anywhere"));
        assertEq(stream.ownerOf(tokenId), holder, "not moved");
    }

    /// @dev A sold work: SOLD is recorded before the delivery, so the buyer's contract wallet,
    ///      made a removed minter, is rescued from nothing.
    function test_Rescue_NeverReachesAWorkTheAuctionSold() public {
        (uint256 saleId, uint256 tokenId) = _startOne();
        address buyer = makeAddr("reachBuyer");
        _ethBid(saleId, buyer, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        vm.recordLogs();
        auction.settle(saleId);
        _assertRecordedBeforeItLeft(tokenId);
        vm.prank(buyer);
        stream.transferFrom(buyer, address(wallet), tokenId);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
        _expectOutOfReach(address(wallet), tokenId);
    }

    /// @dev An unsold work: UNSOLD is recorded before the transfer to the museum.
    function test_Rescue_NeverReachesAWorkTheAuctionSentToTheMuseum() public {
        (uint256 saleId, uint256 tokenId) = _startOne();
        vm.warp(auction.auction(saleId).endTime);
        vm.recordLogs();
        auction.settle(saleId);
        _assertRecordedBeforeItLeft(tokenId);
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.UNSOLD));
        _expectOutOfReach(museum, tokenId);
    }

    /// @dev A sold work whose delivery is pending stays in the auction with SOLD recorded: the
    ///      removed auction is rescued from nothing, and the winner still claims its work.
    function test_Rescue_NeverReachesAWorkWaitingForItsDelivery() public {
        (uint256 saleId, uint256 tokenId) = _startOne();
        _walletBid(wallet, saleId, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        assertEq(auction.pendingDelivery(saleId), address(wallet), "the wallet refused the token");
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));
        _expectOutOfReach(address(auction), tokenId);
        address to = makeAddr("reachCollector");
        wallet.exec(address(auction), 0, abi.encodeCall(auction.claimDelivery, (saleId, to)));
        assertEq(stream.ownerOf(tokenId), to);
    }

    /// @dev In the logs of a settlement, the token's `PrimarySale` comes before the `Transfer`
    ///      that takes the work out of the auction.
    function _assertRecordedBeforeItLeft(uint256 tokenId) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 recordedAt = type(uint256).max;
        uint256 leftAt = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stream)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == IStream.PrimarySale.selector && uint256(logs[i].topics[1]) == tokenId) {
                recordedAt = i;
            }
            if (
                topic == IERC721.Transfer.selector
                    && address(uint160(uint256(logs[i].topics[1]))) == address(auction)
                    && uint256(logs[i].topics[3]) == tokenId
            ) leftAt = i;
        }
        assertLt(recordedAt, leftAt, "the outcome is recorded before the work leaves");
        assertLt(leftAt, type(uint256).max, "the work left the auction");
    }
}
