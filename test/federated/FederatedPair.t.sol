// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC1155Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { FederatedEditionAuction } from "src/federated/FederatedEditionAuction.sol";
import { FederatedEditionAuctionLens } from "src/federated/FederatedEditionAuctionLens.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IEnglishAuctionRefusal } from "src/interfaces/IEnglishAuctionRefusal.sol";
import { IFederatedEditions } from "src/interfaces/IFederatedEditions.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import {
    PrimaryOutcome,
    PrimarySettlement,
    PrimaryTerms,
    SaleKind
} from "src/interfaces/types/SaleTypes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { SettleOnRefund, StarvedSeal } from "../mocks/federated/FederatedMocks.sol";
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
    FederatedEditionAuctionLens internal flens;
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
        flens = lens;
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

    /// @dev The supply check counts what was already minted: once some copies of a sealed
    ///      edition exist, the bound adapter cannot mint one more than the rest.
    function test_Pair_MintBeyondTheRemainingSealedSupplyIsRefused() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _openPair(0);
        address a = makeAddr("a");
        _editionBidFed(saleId, a, 100, 3);
        _ethBid(oneSaleId, collector, 1 ether);
        _settleAtEnd(oneSaleId);
        pairEditions.createEdition(tokenId, w.item);
        vm.warp(fl.endTimes(saleId).endTime);
        assertTrue(fea.settle(saleId, new uint256[](0)));
        uint256 count = fl.settlement(saleId).count;
        vm.prank(a);
        (uint256 won,) = fea.claimBid(saleId, 1, a);
        assertGt(won, 0);
        assertEq(pairEditions.edition(tokenId).maxSupply, count);
        bytes memory data = abi.encode(address(0), uint256(1 ether));
        uint256 rest = count - won;
        vm.prank(address(fea));
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedEditions.EditionUnavailable.selector, tokenId)
        );
        pairEditions.mint(collector, tokenId, rest + 1, data);
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

    /// @dev D-1: an unsold master with no bound edition sale gets no edition from anyone, so the
    ///      artist's restart stays possible. Fails without the change: an outsider's
    ///      `createEdition` binds the master and the restart reverts `WorkNotRestartable`.
    function test_Pair_AnUnsoldUnboundMasterGetsNoEditionAndRestarts() public {
        Work memory w = _fedMaster(fedArtist, 0);
        (uint256 oneSaleId, uint256 tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        _settleAtEnd(oneSaleId);
        vm.prank(makeAddr("outsider"));
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedEditions.NotEditionMaster.selector, tokenId)
        );
        pairEditions.createEdition(tokenId, w.item);
        assertFalse(pairEditions.isBound(tokenId));
        vm.prank(fedArtist);
        pairStream.approveItem(_itemHash(w), RATE);
        uint256 again = auction.start(address(pairStream), _mintData(w));
        assertEq(auction.auction(again).tokenId, tokenId + 1, "restarted");
    }

    /// @dev R16 keeps working: with an edition sale bound, the edition is created after an
    ///      unsold master settles (here through `createEdition` itself, as `abandon` calls it).
    function test_Pair_ABoundSaleStillGetsItsEditionAfterAnUnsoldMaster() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId,) = _openPair(0);
        _settleAtEnd(oneSaleId);
        pairEditions.createEdition(tokenId, w.item);
        assertTrue(pairEditions.exists(tokenId));
    }

    /// @dev D-2: suspending only the 1/1 template also stops new edition sales of its pair.
    ///      Fails without the change: `canMint` ignored the partner's template and `open`
    ///      returned a sale ID.
    function test_Pair_ASuspended1of1TemplateOpensNoEditionSale() public {
        Work memory w = _fedMaster(fedArtist, 0);
        (, uint256 tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        assertTrue(fedRegistry.canMint(address(pairEditions), address(fea)));
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.suspendTemplate, (streamHash))
        );
        assertFalse(fedRegistry.canMint(address(pairEditions), address(fea)));
        vm.expectRevert();
        fea.open(address(pairEditions), tokenId, abi.encode(w.item));
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

    // ------------------------------------------------------------------ the editions half

    /// @dev An open pair whose master settled and whose edition exists, bound to `fea`.
    function _createdEdition() internal returns (uint256 tokenId, uint256 saleId) {
        Work memory w;
        uint256 oneSaleId;
        (w, oneSaleId, tokenId, saleId) = _openPair(0);
        _settleAtEnd(oneSaleId);
        pairEditions.createEdition(tokenId, w.item);
    }

    function test_Editions_NameAndSymbolAreTheConfiguredOnes() public view {
        assertEq(pairEditions.name(), "Artist Editions");
        assertEq(pairEditions.symbol(), "ARTE");
    }

    /// @dev FED-33: an adapter binds an unopened master only if it runs the sale kind the item
    ///      names; the English auction (admitted for 1/1s) cannot take a UNIFORM_AUCTION edition.
    function test_BindMinter_RefusesAnAdapterOfAnotherSaleKind() public {
        Work memory w = _fedMaster(fedArtist, 0);
        (, uint256 tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        assertTrue(pairEditions.isAdmittedMinter(address(auction)));
        vm.prank(address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedEditions.NotEditionMaster.selector, tokenId)
        );
        pairEditions.bindMinter(tokenId, w.item);
        assertFalse(pairEditions.isBound(tokenId));
    }

    function test_Mint_RefusesAZeroAmountAMalformedRequestAndAnotherCurrency() public {
        (uint256 tokenId,) = _createdEdition();
        bytes memory eth = abi.encode(address(0), 1 ether);
        vm.startPrank(address(fea));
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        pairEditions.mint(collector, tokenId, 0, eth);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        pairEditions.mint(collector, tokenId, 1, abi.encode(address(0)));
        address other = makeAddr("otherCurrency");
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedEditions.CurrencyMismatch.selector, address(0), other)
        );
        pairEditions.mint(collector, tokenId, 1, abi.encode(other, 1 ether));
        vm.stopPrank();
        assertEq(pairEditions.edition(tokenId).minted, 0);
    }

    /// @dev FED-34: the terms in force for the adapter, with the partner as creator; nothing to
    ///      settle per token.
    function test_PrimaryTerms_TheLockedVaultTheShareInForceAndThePartnerAsCreator() public {
        (uint256 tokenId,) = _createdEdition();
        IEditions.Edition memory e = pairEditions.edition(tokenId);
        PrimaryTerms memory p = pairEditions.primaryTerms(tokenId, "");
        assertEq(p.saleKind, SaleKind.UNIFORM_AUCTION);
        assertEq(p.seller, e.seller);
        assertEq(p.feeRecipient, e.feeRecipient);
        assertEq(p.feeShare, e.feeShare);
        assertEq(p.feeShare, FED_SHARE);
        assertEq(p.creator, address(pairStream));
        vm.expectRevert(abi.encodeWithSelector(IFederatedEditions.UnknownEdition.selector, 999));
        pairEditions.primaryTerms(999, "");
        PrimarySettlement memory s =
            pairEditions.settlePrimary(tokenId, PrimaryOutcome.SOLD, collector, collector, 1);
        assertEq(s.seller, address(0));
        assertEq(s.feeRecipient, address(0));
        assertEq(s.feeShare, 0);
        assertEq(s.holder, address(0));
    }

    /// @dev Only the bound adapter burns, a nonzero amount, from its own balance.
    function test_Burn_OnlyTheBoundAdapterFromItsOwnBalance() public {
        (uint256 tokenId,) = _createdEdition();
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFederatedEditions.MinterMismatch.selector, tokenId, address(fea)
            )
        );
        pairEditions.burn(tokenId, 1);
        vm.startPrank(address(fea));
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        pairEditions.burn(tokenId, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, address(fea), 0, 1, tokenId
            )
        );
        pairEditions.burn(tokenId, 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ the federated adapter

    /// @dev FED-57: a served sale takes a raise as the shared base does.
    function test_Pair_AServedSaleTakesARaise() public {
        (,,, uint256 saleId) = _openPair(0);
        address a = makeAddr("a");
        uint256 bidId = _editionBidFed(saleId, a, 100, 2);
        uint256 diff = 2 * (fl.stepPrice(saleId, 110) - fl.stepPrice(saleId, 100));
        vm.deal(a, diff);
        // An uncapped sale (position zero); the raise is early, so the end does not move.
        vm.expectEmit(address(fea));
        emit IUniformEditionAuction.BidRaised(
            saleId, bidId, a, 100, 110, 0, diff, fl.endTimes(saleId).endTime
        );
        vm.prank(a);
        fea.raise{ value: diff }(saleId, bidId, 110);
        assertEq(fl.auction(saleId).highStep, 110);
    }

    /// @dev FED-58: after a delisting the lens's views show the 1/1 as the English auction has
    ///      it (still ACTIVE, the sale's view still open), while a bid is refused and settlement
    ///      voids the sale as if the 1/1 were cancelled.
    function test_Pair_ADelistedSalesViewsShowItsOneOfOneAsItIs() public {
        // The vote is scheduled first, so it lands while the 1/1 is still running.
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
        _editionBidFed(saleId, makeAddr("a"), 100, 1);
        vm.prank(hotAdmin);
        manager.execute(address(fedRegistry), delist);
        assertFalse(fl.isTarget(address(pairEditions)));
        IUniformEditionAuction.EndTimes memory e = fl.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertTrue(e.biddingOpen, "the view reads the 1/1 as it is");
        uint256 amount = fl.stepPrice(saleId, 100);
        address b = makeAddr("b");
        vm.deal(b, amount);
        vm.prank(b);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.BiddingClosed.selector, saleId, 0)
        );
        fea.bid{ value: amount }(saleId, 100, 1);
        assertTrue(fea.settle(saleId, new uint256[](0)));
        assertEq(uint8(fl.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
    }

    /// @dev The settle re-check of a delisted mid-scan sale keeps the shared guard: entered from
    ///      a refund paid by another call of the adapter, it reverts and voids nothing.
    function test_Settle_AMidScanVoidReenteredFromARefundIsRefused() public {
        (,,, uint256 saleA) = _openPair(0);
        (Work memory w, uint256 oneB, uint256 tokenB, uint256 saleB) = _openPair(0);
        address a = makeAddr("a");
        uint256 bidA = _editionBidFed(saleA, a, 100, 1);
        _editionBidFed(saleB, makeAddr("low"), 0, 40);
        _editionBidFed(saleB, makeAddr("high"), 300, 1);
        _settleAtEnd(oneB);
        pairEditions.createEdition(tokenB, w.item);
        vm.warp(fl.endTimes(saleB).endTime);
        assertFalse(fea.settle(saleB, new uint256[](0)), "the scan continues");
        _delistPair();
        assertTrue(fea.settle(saleA, new uint256[](0)), "A voided");
        SettleOnRefund hostile = new SettleOnRefund(fea, saleB);
        vm.prank(a);
        (, uint256 refund) = fea.claimBid(saleA, bidA, address(hostile));
        assertEq(address(hostile).balance, refund);
        assertEq(
            hostile.revertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(
            uint8(fl.auction(saleB).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        assertTrue(fea.settle(saleB, new uint256[](0)));
        assertEq(uint8(fl.auction(saleB).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
    }

    /// @dev FED-56: the abandoned sale's best-effort seal is never read as a refusal when the
    ///      editions contract ran out of gas: the abandonment reverts `BoundedCallShortfall`. The
    ///      editions' code is replaced, after the sale opened, by one whose `sealSupply` consumes
    ///      all the gas it is given, as an honest callee that ran short does.
    function test_Abandon_ASealThatRunsOutOfGasIsAShortfall() public {
        Work memory w = _fedMaster(fedArtist, 0);
        (uint256 oneSaleId, uint256 tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        uint256 saleId = fea.open(address(pairEditions), tokenId, abi.encode(w.item));
        vm.mockCallRevert(
            address(pairStream), abi.encodeWithSelector(IMintTarget.settlePrimary.selector), "x"
        );
        vm.warp(auction.auction(oneSaleId).endTime + 2 days);
        IEnglishAuctionRefusal(address(auction)).settleOrRefund(oneSaleId);
        vm.clearMockedCalls();
        (, uint256 abandonAt) = fl.abandonable(saleId);
        vm.warp(abandonAt);
        vm.etch(address(pairEditions), address(new StarvedSeal(address(pairStream))).code);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, pairEditions)
        );
        fea.abandon{ gas: 5_000_000 }(saleId, abi.encode(w.item));
        assertEq(
            uint8(fl.auction(saleId).status),
            uint8(IUniformEditionAuction.AuctionStatus.CLOSED),
            "not voided"
        );
    }

    /// @dev R16 through the federated lens: a settled master whose edition was never created
    ///      is abandonable, and `abandon` creates the edition; once it exists the sale is no
    ///      longer abandonable.
    function test_Abandon_ASettledMasterGetsItsEditionCreated() public {
        (Work memory w, uint256 oneSaleId, uint256 tokenId, uint256 saleId) = _openPair(0);
        _settleAtEnd(oneSaleId);
        (, uint256 abandonAt) = fl.abandonable(saleId);
        assertGt(abandonAt, 0);
        vm.warp(abandonAt);
        (bool ok,) = fl.abandonable(saleId);
        assertTrue(ok);
        fea.abandon(saleId, abi.encode(w.item));
        assertTrue(pairEditions.exists(tokenId), "created");
        (ok, abandonAt) = fl.abandonable(saleId);
        assertFalse(ok);
        assertEq(abandonAt, 0);
    }

    /// @dev The lens's fixed answers and its fee check, through the adapter and directly.
    function test_Lens_FixedAnswersAndTheFeeCheckOfAnUnservedToken() public {
        assertEq(fl.editions(), address(0));
        assertEq(fl.stream(), address(0));
        assertEq(fl.federationRegistry(), address(fedRegistry));
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(7)));
        fl.setFederationRegistry(address(fedRegistry), address(7));
        (address recipient, uint256 share) = flens.feeTerms(address(pairEditions), address(escrow));
        assertEq(recipient, networkFee);
        assertEq(share, FED_SHARE);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), 0)
        );
        flens.feeTerms(address(editions), address(escrow));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(pairEditions), 0)
        );
        flens.feeTerms(address(pairEditions), networkFee);
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
