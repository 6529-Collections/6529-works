// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FederatedEditionAuction } from "src/federated/FederatedEditionAuction.sol";
import { FederatedEditionAuctionLens } from "src/federated/FederatedEditionAuctionLens.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IFederatedEditions } from "src/interfaces/IFederatedEditions.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice A federated pair end to end on the real stack: the master's 1/1 on the English
///         auction, its edition on the federated edition auction, the network's locked share on
///         both, a delisting voiding the edition sale, and a master whose edition sale began
///         never restarting.
contract FederatedPairTest is FederationBase {
    FederatedEditionAuction internal fea;
    IUniformEditionAuctionLens internal fl;
    FederatedStream internal pairStream;
    FederatedEditions internal pairEditions;
    address internal collector = makeAddr("collector");

    function setUp() public override {
        super.setUp();
        FederatedEditionAuctionLens lens = new FederatedEditionAuctionLens(
            address(auction), address(escrow), address(artists), address(economics)
        );
        fea = new FederatedEditionAuction(
            address(manager),
            address(escrow),
            address(auction),
            address(lens),
            address(lens).codehash,
            DeployV1.editionAuctionDefaults(),
            DeployV1.editionAuctionLimits()
        );
        fl = IUniformEditionAuctionLens(address(fea));
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(fea), true))
        );
        (pairStream, pairEditions) = _pair(fedArtist);
    }

    function _openPair(uint32 maxCount)
        internal
        returns (Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId)
    {
        w = _fedMaster(fedArtist, maxCount);
        (oneSaleId, tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        saleId = fea.open(address(pairEditions), tokenId, abi.encode(w.item));
    }

    function _editionBidFed(uint256 saleId, address bidder, uint256 step, uint256 quantity)
        internal
        returns (uint256 bidId)
    {
        uint256 amount = quantity * fl.stepPrice(saleId, step);
        vm.deal(bidder, bidder.balance + amount);
        vm.prank(bidder);
        bidId = fea.bid{ value: amount }(saleId, step, quantity);
    }

    function test_Pair_EditionSalePaysTheLockedShareAndMintsWithinTheSeal() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _openPair(0);
        assertTrue(fl.isTarget(address(pairEditions)));
        assertEq(fl.auction(saleId).token, address(pairEditions));
        assertEq(fl.auction(saleId).master, address(pairStream));
        assertEq(fl.auction(saleId).feeShare, FED_SHARE);
        assertEq(fl.auction(saleId).feeRecipient, networkFee);
        address a = makeAddr("a");
        address b = makeAddr("b");
        _editionBidFed(saleId, a, 100, 3);
        _editionBidFed(saleId, b, 120, 2);
        _ethBid(oneSaleId, collector, 1 ether);
        _settleAtEnd(oneSaleId);
        pairEditions.createEdition(tokenId, w.item);
        vm.warp(fl.endTimes(saleId).endTime);
        address seller = splitFactory.walletFor(w.item.payees, 0);
        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = networkFee.balance;
        assertTrue(fea.settle(saleId, new uint256[](0)));
        IUniformEditionAuction.Settlement memory st = fl.settlement(saleId);
        uint256 revenue = st.count * st.price;
        assertGt(revenue, 0);
        assertEq(networkFee.balance - feeBefore, revenue * FED_SHARE / 100_000, "network share");
        assertEq(seller.balance - sellerBefore, revenue - revenue * FED_SHARE / 100_000);
        vm.prank(a);
        (uint256 wonA,) = fea.claimBid(saleId, 1, a);
        (uint256 wonB,) = fea.claimBidFor(saleId, 2);
        assertEq(pairEditions.balanceOf(a, tokenId), wonA);
        assertEq(pairEditions.balanceOf(b, tokenId), wonB);
        assertEq(wonA + wonB, st.count);
        assertTrue(pairEditions.edition(tokenId).supplySealed);
        assertEq(pairEditions.edition(tokenId).maxSupply, st.count);
        (address receiver, uint256 royalty) = pairEditions.royaltyInfo(tokenId, 1 ether);
        (address masterReceiver,) = pairStream.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, masterReceiver, "the master's 90/10 vault");
        assertEq(royalty, uint256(1 ether) * RATE / 100_000);
        assertEq(address(fea).balance, fl.claimable(b, address(0)), "only b's credited refund");
    }

    function test_Pair_ADelistingVoidsTheRunningEditionSaleWithRefunds() public {
        (,,, uint256 saleId) = _openPair(0);
        address a = makeAddr("a");
        _editionBidFed(saleId, a, 100, 3);
        uint256 paid = 3 * fl.stepPrice(saleId, 100);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(pairStream), address(pairEditions));
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(
                fedRegistry.setStatus, (tokens, IFederationRegistry.Status.DELISTED, "vote")
            )
        );
        assertFalse(fl.isTarget(address(pairEditions)));
        assertTrue(fea.settle(saleId, new uint256[](0)), "voided at once");
        vm.prank(a);
        (uint256 won, uint256 refund) = fea.claimBid(saleId, 1, a);
        assertEq(won, 0);
        assertEq(refund, paid, "every bid back in full");
    }

    function test_Pair_AMasterWhoseEditionSaleBeganNeverRestarts() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId,) = _openPair(0);
        _settleAtEnd(oneSaleId);
        assertEq(pairStream.ownerOf(tokenId), address(pairStream));
        vm.prank(fedArtist);
        pairStream.approveItem(_itemHash(w), RATE);
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.WorkNotRestartable.selector, 1));
        auction.start(address(pairStream), _mintData(w));
    }

    function test_Pair_TheEditionTakesTheFeeFromTheRegistryNotTheToken() public {
        (,,, uint256 saleId) = _openPair(0);
        IUniformEditionAuction.Auction memory v = fl.auction(saleId);
        assertEq(v.feeShare, fedRegistry.entry(address(pairEditions)).feeShare);
        assertEq(v.feeRecipient, economics.networkFeeRecipient(keccak256("PRODUCT_FEDERATED")));
    }

    function test_Pair_OnlyServedContractsOpen() public {
        Work memory w = _fedMaster(fedArtist, 0);
        (, uint256 tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.InvalidSaleTerms.selector, address(editions), tokenId
            )
        );
        fea.open(address(editions), tokenId, abi.encode(w.item));
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(1)));
        fea.setTarget(address(1), true);
    }

    function test_Pair_TheEditionsBindToOneAdapter() public {
        (Work memory w,, uint256 tokenId,) = _openPair(0);
        vm.prank(address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederatedEditions.MinterMismatch.selector, tokenId, address(fea)
            )
        );
        pairEditions.bindMinter(tokenId, w.item);
    }
}
