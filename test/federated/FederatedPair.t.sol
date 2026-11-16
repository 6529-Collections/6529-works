// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FederatedEditionAuction } from "src/federated/FederatedEditionAuction.sol";
import { FederatedEditionAuctionLens } from "src/federated/FederatedEditionAuctionLens.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { IFederatedEditions } from "src/interfaces/IFederatedEditions.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice An editions copy that reports no network fee when an adapter binds it: different code,
///         so governance must approve its hash, as an audit would a faulty version.
contract FeeDodgingEditions is FederatedEditions {
    constructor(Config memory c) FederatedEditions(c) { }

    function bindMinter(uint256 editionId, PackageItem calldata item)
        public
        override
        returns (WorkTerms memory w)
    {
        w = super.bindMinter(editionId, item);
        (w.feeRecipient, w.feeShare) = (w.seller, 0);
    }
}

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
        // FED-36: the edition renders through its master's renderer.
        assertTrue(_contains(pairEditions.uri(tokenId), "data:application/json"));
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

    /// @dev FED-54: the fee locked at open is the registry's, whatever the token answers.
    function test_Pair_ATokenThatReportsNoFeeStillPaysTheRegistryShare() public {
        FederatedStream s = _deployStream(fedArtist);
        FeeDodgingEditions dodge = FeeDodgingEditions(
            _copy(
                type(FeeDodgingEditions).creationCode,
                abi.encode(_editionsConfig(fedArtist, address(s)))
            )
        );
        _approveTemplate(
            fedRegistry,
            type(FeeDodgingEditions).creationCode,
            address(dodge).codehash,
            98,
            IFederationRegistry.Form.ERC1155
        );
        vm.prank(fedArtist);
        s.linkEditions(address(dodge));
        _join(address(dodge), fedArtist);
        _join(address(s), fedArtist);
        Work memory w = _fedMaster(fedArtist, 0);
        (uint256 oneSaleId, uint256 tokenId) = _startFed(s, fedArtist, w, RATE);
        uint256 saleId = fea.open(address(dodge), tokenId, abi.encode(w.item));
        assertEq(fl.auction(saleId).feeShare, FED_SHARE, "the registry's share");
        assertEq(fl.auction(saleId).feeRecipient, networkFee);
        _editionBidFed(saleId, makeAddr("a"), 100, 2);
        _settleAtEnd(oneSaleId);
        dodge.createEdition(tokenId, w.item);
        vm.warp(fl.endTimes(saleId).endTime);
        uint256 before = networkFee.balance;
        fea.settle(saleId, new uint256[](0));
        IUniformEditionAuction.Settlement memory st = fl.settlement(saleId);
        assertEq(networkFee.balance - before, st.count * st.price * FED_SHARE / 100_000);
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

    // ------------------------------------------------------------------ the pair as one (F3)

    /// @dev The 1/1 half joins only once its editions are listed ACTIVE under the same artist,
    ///      and listed editions mint nothing while their 1/1 contract is unlisted.
    function test_Pair_The1of1JoinsOnlyAfterItsEditions() public {
        FederatedStream s = _deployStream(fedArtist);
        FederatedEditions ed = _deployEditions(fedArtist, address(s));
        vm.prank(fedArtist);
        s.linkEditions(address(ed));
        _join(
            address(s),
            fedArtist,
            abi.encodeWithSelector(IFederationRegistry.NotListable.selector, address(s))
        );
        _join(address(ed), fedArtist);
        assertFalse(fedRegistry.canMint(address(ed), address(fea)), "not before its 1/1 half");
        _join(address(s), fedArtist);
        assertTrue(fedRegistry.canMint(address(ed), address(fea)));
    }

    /// @dev Review G (G4): a restart re-offers an edition master only while its editions are
    ///      listed ACTIVE, as a first mint does.
    function test_Pair_AMasterRestartsOnlyWhileItsEditionsAreListed() public {
        Work memory w = _fedMaster(fedArtist, 0);
        (uint256 oneSaleId,) = _startFed(pairStream, fedArtist, w, RATE);
        _settleAtEnd(oneSaleId);
        _setListing(address(pairEditions), IFederationRegistry.Status.DELISTED);
        vm.prank(fedArtist);
        pairStream.approveItem(_itemHash(w), RATE);
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.WorkNotRestartable.selector, 1));
        auction.start(address(pairStream), _mintData(w));
    }

    /// @dev Editions joined beside a 1/1 half that never joins, or that is delisted, mint
    ///      nothing through the network.
    function test_Pair_EditionsWithoutAListed1of1MintNothing() public {
        FederatedStream s = _deployStream(fedArtist);
        FederatedEditions ed = _deployEditions(fedArtist, address(s));
        vm.prank(fedArtist);
        s.linkEditions(address(ed));
        _join(address(ed), fedArtist);
        assertFalse(ed.isAdmittedMinter(address(fea)), "1/1 never joined");
        _setListing(address(pairStream), IFederationRegistry.Status.DELISTED);
        assertFalse(pairEditions.isAdmittedMinter(address(fea)), "1/1 delisted");
    }

    /// @dev Pass 3: the edition sale's fee recipient is locked at open; a governance change of
    ///      the federated recipient before settlement does not redirect it.
    function test_Pair_TheEditionFeeRecipientIsTheOneCurrentAtSettlement() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _openPair(0);
        _editionBidFed(saleId, makeAddr("a"), 100, 3);
        address next = makeAddr("nextFeeRecipient");
        (uint64 revision,,) = economics.revisions(PRODUCT_FEDERATED);
        _govern(
            hotAdmin,
            address(economics),
            abi.encodeCall(economics.setFeeTerms, (PRODUCT_FEDERATED, revision, next, FED_SHARE))
        );
        assertEq(economics.networkFeeRecipient(PRODUCT_FEDERATED), next);
        assertEq(fl.auction(saleId).feeRecipient, next, "R18: read at settlement");
        auction.settle(oneSaleId);
        pairEditions.createEdition(tokenId, w.item);
        uint256 before = networkFee.balance;
        assertTrue(fea.settle(saleId, new uint256[](0)));
        IUniformEditionAuction.Settlement memory st = fl.settlement(saleId);
        uint256 revenue = st.count * st.price;
        assertEq(next.balance, revenue - revenue * (100_000 - FED_SHARE) / 100_000);
        assertEq(networkFee.balance, before);
    }

    /// @dev Pass 3: the lens deploys a sale's wallets only through the canonical split ledger;
    ///      a token naming any other ledger opens nothing.
    function test_Pair_ATokenNamingAnotherLedgerOpensNoSale() public {
        Work memory w = _fedMaster(fedArtist, 0);
        (, uint256 tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        (address ar,, uint256 id, uint32 share, address recipient, address partner) =
            pairEditions.federationTerms();
        vm.mockCall(
            address(pairEditions),
            abi.encodeWithSelector(IFederatedToken.federationTerms.selector),
            abi.encode(ar, makeAddr("otherLedger"), id, share, recipient, partner)
        );
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(pairEditions), 0)
        );
        fea.open(address(pairEditions), tokenId, abi.encode(w.item));
    }

    function _delistPair() internal {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(pairStream), address(pairEditions));
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(
                fedRegistry.setStatus, (tokens, IFederationRegistry.Status.DELISTED, "vote")
            )
        );
    }

    /// @dev A delisted pair's edition sale takes no bid and no raise, however far from the close:
    ///      the federated adapter checks the registry on every bid, not only near the close.
    function test_Pair_ADelistedSaleTakesNoBidOrRaiseLongBeforeTheClose() public {
        // The vote is scheduled first, so it lands while the sale is young.
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(pairStream), address(pairEditions));
        bytes memory delist = abi.encodeCall(
            fedRegistry.setStatus, (tokens, IFederationRegistry.Status.DELISTED, "vote")
        );
        (, uint32 delay) = manager.canCall(hotAdmin, address(fedRegistry), bytes4(delist));
        vm.prank(hotAdmin);
        manager.schedule(address(fedRegistry), delist, 0);
        vm.warp(block.timestamp + delay);
        (,,, uint256 saleId) = _openPair(0);
        address a = makeAddr("a");
        _editionBidFed(saleId, a, 100, 3);
        uint256 closeAt = fl.endTimes(saleId).closeAt;
        vm.prank(hotAdmin);
        manager.execute(address(fedRegistry), delist);
        assertFalse(fl.isTarget(address(pairEditions)));
        assertLt(
            block.timestamp + DeployV1.editionAuctionDefaults().softWindow,
            closeAt,
            "well before the soft window"
        );
        uint256 amount = fl.stepPrice(saleId, 100);
        uint256 diff = 3 * (fl.stepPrice(saleId, 101) - amount);
        vm.deal(a, amount + diff);
        vm.prank(a);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.BiddingClosed.selector, saleId, 0)
        );
        fea.bid{ value: amount }(saleId, 100, 1);
        vm.prank(a);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.BiddingClosed.selector, saleId, 0)
        );
        fea.raise{ value: diff }(saleId, 1, 101);
    }

    /// @dev A delisting between the settle calls of a wide book, while the scan has paid
    ///      nothing, voids the sale with full refunds: no seal, no payout.
    function test_Pair_ADelistingMidScanVoidsBeforeAnyPayout() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _openPair(0);
        address low = makeAddr("low");
        address high = makeAddr("high");
        _editionBidFed(saleId, low, 0, 40);
        _editionBidFed(saleId, high, 300, 1);
        uint256 paidLow = 40 * fl.stepPrice(saleId, 0);
        uint256 paidHigh = fl.stepPrice(saleId, 300);
        _settleAtEnd(oneSaleId);
        pairEditions.createEdition(tokenId, w.item);
        vm.warp(fl.endTimes(saleId).endTime);
        assertFalse(fea.settle(saleId, new uint256[](0)), "the scan continues");
        assertEq(
            uint8(fl.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        _delistPair();
        uint256 held = address(fea).balance;
        assertTrue(fea.settle(saleId, new uint256[](0)), "voided");
        assertEq(uint8(fl.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertEq(address(fea).balance, held, "nothing paid");
        assertFalse(pairEditions.edition(tokenId).supplySealed, "nothing sealed");
        vm.prank(low);
        (uint256 wonLow, uint256 refundLow) = fea.claimBid(saleId, 1, low);
        vm.prank(high);
        (uint256 wonHigh, uint256 refundHigh) = fea.claimBid(saleId, 2, high);
        assertEq(wonLow + wonHigh, 0);
        assertEq(refundLow, paidLow);
        assertEq(refundHigh, paidHigh);
    }
}
