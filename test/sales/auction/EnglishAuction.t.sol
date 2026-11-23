// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { Outcome, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { AuctionFixture } from "./AuctionFixture.sol";
import { BidderContract, RefusingWallet } from "./AuctionMocks.sol";

/// @notice The English auction's start, bidding, settlement, delivery, claims and governance,
///         against the real `src/core/Stream6529.sol`.
contract EnglishAuctionTest is AuctionFixture {
    // ------------------------------------------------------------------------------ start

    function test_Start_MintsIntoCustodyAndOpensTheSale() public {
        uint256 expectedId = auction.saleIdOf(address(stream), 1);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.SaleStarted(
            expectedId,
            address(stream),
            1,
            SaleKind.ENGLISH_AUCTION,
            address(0),
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + DURATION)
        );
        uint256 saleId = _start(1);
        assertEq(saleId, expectedId);
        assertEq(stream.ownerOf(1), address(auction));
        assertEq(stream.workOf(1).itemHash, policy.factsOf(1).itemHash);
        assertEq(uint256(stream.workOf(1).outcome), uint256(Outcome.NONE));
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.token, address(stream));
        assertEq(a.tokenId, 1);
        assertEq(a.seller, seller);
        assertEq(a.feeShare, FEE_SHARE);
        assertEq(a.bidder, address(0));
        assertEq(a.endTime, block.timestamp + DURATION);
        assertEq(uint256(a.state), uint256(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(auction.minimumBid(saleId), 1);
    }

    function test_Start_IsPermissionless() public {
        vm.prank(alice);
        uint256 saleId = _start(1);
        assertEq(_tokenId(saleId), 1);
    }

    function test_Start_RefusedWhileStartsArePaused() public {
        auction.pause();
        vm.expectRevert(IEnglishAuction.SalePaused.selector);
        _start(1);
    }

    function test_Start_RefusedWithoutAPolicy() public {
        auction.setStreamPolicy(address(policy), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.TargetNotAllowed.selector, address(stream))
        );
        _start(1);
    }

    function test_Start_RefusedOnceTheAuctionIsNoLongerAMinter() public {
        stream.removeMinter(address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(stream), address(auction)
            )
        );
        _start(1);
    }

    function test_Start_TheSameItemCannotStartTwice() public {
        _start(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStream.ContentAlreadyMinted.selector, policy.factsOf(1).contentHash, 1
            )
        );
        _start(1);
    }

    function test_Start_RefusesTermsItCannotSellBy() public {
        address esc = address(escrow);
        address self = address(auction);
        bytes32[6] memory kinds = [
            SaleKind.UNIFORM_AUCTION,
            SaleKind.ENGLISH_AUCTION,
            SaleKind.ENGLISH_AUCTION,
            SaleKind.ENGLISH_AUCTION,
            SaleKind.ENGLISH_AUCTION,
            SaleKind.ENGLISH_AUCTION
        ];
        bytes[6] memory params = [bytes(""), bytes("x"), "", "", "", ""];
        address[6] memory sellers = [seller, seller, address(0), esc, self, seller];
        uint32[6] memory shares = [uint32(0), 0, 0, 0, 0, 100_001];
        for (uint256 i; i < 6; ++i) {
            policy.setTerms(kinds[i], params[i], sellers[i], shares[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IEnglishAuction.InvalidSaleTerms.selector, address(stream), 0
                )
            );
            _start(1);
        }
        assertEq(stream.totalMinted(), 0);
    }

    function test_Start_AFullNetworkShareIsAccepted() public {
        policy.setTerms(SaleKind.ENGLISH_AUCTION, "", seller, 100_000);
        uint256 saleId = _start(1);
        assertEq(auction.auction(saleId).feeShare, 100_000);
    }

    function test_StartWithBid_BidsForTheCaller() public {
        vm.prank(alice);
        uint256 saleId =
            auction.startWithBid{ value: 1 ether }(address(stream), abi.encode(1), address(0));
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.bidder, alice);
        assertEq(a.recipient, alice);
        assertEq(a.bid, 1 ether);
        assertEq(address(auction).balance, 1 ether);
    }

    function test_StartWithBid_ForARecipient() public {
        vm.prank(alice);
        uint256 saleId =
            auction.startWithBid{ value: 1 ether }(address(stream), abi.encode(1), carol);
        assertEq(auction.auction(saleId).recipient, carol);
        assertEq(auction.auction(saleId).bidder, alice);
    }

    function test_StartWithBid_MustReachTheOpeningBid() public {
        _setOpeningBid(2 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, 2 ether, 1 ether)
        );
        auction.startWithBid{ value: 1 ether }(address(stream), abi.encode(1), address(0));
    }

    // ---------------------------------------------------------------------------- bidding

    function test_Bid_FirstBidReachesTheOpeningBidReadWhenBidding() public {
        uint256 saleId = _start(1);
        _setOpeningBid(1 ether);
        assertEq(auction.minimumBid(saleId), 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, 1 ether, 0.5 ether)
        );
        auction.bid{ value: 0.5 ether }(saleId, address(0));
        _bid(alice, saleId, 1 ether);
        assertEq(auction.auction(saleId).bid, 1 ether);
    }

    function test_Bid_ZeroIsNeverABid() public {
        uint256 saleId = _start(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, 1, 0));
        auction.bid(saleId, address(0));
    }

    function testFuzz_Bid_IncrementRule(uint96 high, uint256 extra) public {
        high = uint96(bound(high, 1, 100 ether));
        uint256 saleId = _start(1);
        _bid(alice, saleId, high);
        uint256 step = (uint256(high) * SHARE + 99_999) / 100_000;
        uint256 required = high + (step > FLOOR ? step : FLOOR);
        assertEq(auction.minimumBid(saleId), required);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, required, required - 1)
        );
        auction.bid{ value: required - 1 }(saleId, address(0));
        extra = bound(extra, 0, 1 ether);
        _bid(bob, saleId, required + extra);
        assertEq(auction.auction(saleId).bidder, bob);
    }

    function test_Bid_AnOutbidBidIsCreditedNotPushed() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        uint256 before = alice.balance;
        vm.expectEmit(address(auction));
        emit IEnglishAuction.Credited(alice, address(0), saleId, 1 ether);
        _bid(bob, saleId, 2 ether);
        assertEq(alice.balance, before);
        assertEq(auction.claimable(alice), 1 ether);
        assertEq(address(auction).balance, 3 ether);
    }

    function test_Bid_InTheLastWindowExtendsTheEnd() public {
        uint256 saleId = _start(1);
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - 1);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.BidPlaced(saleId, alice, alice, 1 ether, uint64(end - 1 + WINDOW));
        _bid(alice, saleId, 1 ether);
        assertEq(auction.auction(saleId).endTime, end - 1 + WINDOW);
    }

    function test_Bid_BeforeTheWindowDoesNotExtend() public {
        uint256 saleId = _start(1);
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - WINDOW);
        _bid(alice, saleId, 1 ether);
        assertEq(auction.auction(saleId).endTime, end);
    }

    function test_Bid_RefusedAfterTheEnd() public {
        uint256 saleId = _start(1);
        _end(saleId);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ENDED
            )
        );
        auction.bid{ value: 1 ether }(saleId, address(0));
    }

    function test_Bid_UnknownSale() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.UnknownSale.selector, 7));
        auction.bid{ value: 1 ether }(7, address(0));
    }

    function test_Bid_TheAuctionIsNeverARecipient() public {
        uint256 saleId = _start(1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidRecipient.selector, address(auction))
        );
        auction.bid{ value: 1 ether }(saleId, address(auction));
    }

    function test_Bid_Above96BitsIsRefused() public {
        uint256 saleId = _start(1);
        uint256 huge = uint256(type(uint96).max) + 1;
        vm.deal(alice, huge);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, 1, huge));
        auction.bid{ value: huge }(saleId, address(0));
    }

    function test_Bid_ARebidForOneselfClearsTheRecipient() public {
        uint256 saleId = _start(1);
        vm.prank(alice);
        auction.bid{ value: 1 ether }(saleId, carol);
        assertEq(auction.auction(saleId).recipient, carol);
        _bid(bob, saleId, 2 ether);
        assertEq(auction.auction(saleId).recipient, bob);
    }

    // ------------------------------------------------------------------------- settlement

    function test_Settle_SoldPaysTheSellerAndTheNetworkAndDelivers() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        vm.expectEmit(address(stream));
        emit IStream.PrimarySale(1, Outcome.SOLD, alice, 1 ether);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.SaleSettled(
            saleId,
            address(stream),
            1,
            alice,
            alice,
            1,
            address(0),
            1 ether,
            seller,
            0.9 ether,
            feeRecipient,
            0.1 ether
        );
        auction.settle(saleId);
        assertEq(seller.balance, 0.9 ether);
        assertEq(feeRecipient.balance, 0.1 ether);
        assertEq(stream.ownerOf(1), alice);
        assertEq(uint256(stream.workOf(1).outcome), uint256(Outcome.SOLD));
        assertEq(address(auction).balance, 0);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.SETTLED));
    }

    function test_Settle_IsPermissionless() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        vm.prank(carol);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
    }

    function testFuzz_Settle_TheSellersPartRoundsDown(uint96 price, uint32 share) public {
        price = uint96(bound(price, 1, 1_000 ether));
        share = uint32(bound(share, 0, 100_000));
        policy.setTerms(SaleKind.ENGLISH_AUCTION, "", seller, share);
        uint256 saleId = _start(1);
        _bid(alice, saleId, price);
        _end(saleId);
        auction.settle(saleId);
        uint256 sellerPart = uint256(price) * (100_000 - share) / 100_000;
        assertEq(seller.balance, sellerPart);
        assertEq(feeRecipient.balance, price - sellerPart);
        assertEq(address(auction).balance, 0);
    }

    function test_Settle_TheFeeGoesToTheRecipientNamedAtSettlement() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        address later = makeAddr("laterRecipient");
        (uint64 feeRevision,,) = economics.revisions(keccak256("PRODUCT_STREAM"));
        economics.setFeeTerms(keccak256("PRODUCT_STREAM"), feeRevision, later, 5_000);
        _end(saleId);
        auction.settle(saleId);
        assertEq(later.balance, 0.1 ether, "share locked at start, recipient read now");
        assertEq(feeRecipient.balance, 0);
    }

    /// @dev The network lowers the product's share to zero while a sale runs. The resolver
    ///      refuses a zero recipient at any share, so a recipient stays named: the running sale
    ///      settles and pays the share it stored at its start to the recipient named now.
    function test_Settle_ARunningSaleSettlesAfterTheShareIsLoweredToZero() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        uint256 stored = auction.auction(saleId).feeShare;
        assertGt(stored, 0, "the sale stored a share");
        bytes32 product = keccak256("PRODUCT_STREAM");
        (uint64 feeRevision,,) = economics.revisions(product);
        vm.expectRevert(IEconomicsResolver.InvalidEconomics.selector);
        economics.setFeeTerms(product, feeRevision, address(0), 0);
        address later = makeAddr("laterRecipient");
        economics.setFeeTerms(product, feeRevision, later, 0);
        assertEq(economics.networkFeeRecipient(product), later, "a recipient is still named");

        _end(saleId);
        uint256 sellerPart = 1 ether * (100_000 - stored) / 100_000;
        _expectSoldToAlice(saleId, sellerPart, later);
        auction.settle(saleId);
        assertEq(later.balance, 1 ether - sellerPart, "the stored share, to the recipient now");
        assertEq(seller.balance, sellerPart);
        assertEq(stream.ownerOf(1), alice);
        assertEq(address(auction).balance, 0);
    }

    /// @dev Expects `SaleSettled` for 6529 Stream work 1 sold to alice for 1 ETH, `sellerPart`
    ///      to the seller and the rest to `recipient`.
    function _expectSoldToAlice(uint256 saleId, uint256 sellerPart, address recipient) internal {
        vm.expectEmit(address(auction));
        emit IEnglishAuction.SaleSettled(
            saleId,
            address(stream),
            1,
            alice,
            alice,
            1,
            address(0),
            1 ether,
            seller,
            sellerPart,
            recipient,
            1 ether - sellerPart
        );
    }

    function test_Settle_UnsoldStreamWorkGoesToTheMuseum() public {
        uint256 saleId = _start(1);
        _end(saleId);
        vm.expectEmit(address(stream));
        emit IStream.PrimarySale(1, Outcome.UNSOLD, address(0), 0);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), museum);
        assertEq(uint256(stream.workOf(1).outcome), uint256(Outcome.UNSOLD));
    }

    function test_Settle_TheMuseumIsReadAtSettlement() public {
        uint256 saleId = _start(1);
        address later = makeAddr("laterMuseum");
        economics.setMuseum(economics.museumRevision(), later);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), later);
    }

    function test_Settle_RefusedBeforeTheEndAndOnce() public {
        uint256 saleId = _start(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.settle(saleId);
        _end(saleId);
        auction.settle(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.SETTLED
            )
        );
        auction.settle(saleId);
    }

    function test_Settle_ASellerThatRefusesIsPaidThroughTheEscrow() public {
        address refusing = address(new RefusingWallet());
        policy.setTerms(SaleKind.ENGLISH_AUCTION, "", refusing, FEE_SHARE);
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(escrow.owed(refusing, address(0)), 0.9 ether);
        assertEq(stream.ownerOf(1), alice);
    }

    function test_Settle_ARecipientThatRefusesLeavesAPendingDelivery() public {
        BidderContract b = new BidderContract(IEnglishAuction(address(auction)));
        b.set(false, true, false);
        uint256 saleId = _start(1);
        b.bid{ value: 1 ether }(saleId, address(0));
        _end(saleId);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.DeliveryPending(saleId, address(b));
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), address(auction));
        assertEq(auction.pendingDelivery(saleId), address(b));
        assertEq(seller.balance, 0.9 ether, "payment does not wait on delivery");
        assertEq(uint256(stream.workOf(1).outcome), uint256(Outcome.SOLD));
        b.claimDelivery(saleId, carol);
        assertEq(stream.ownerOf(1), carol);
        assertEq(auction.pendingDelivery(saleId), address(0));
    }

    function test_Settle_ARecipientThatBurnsGasLeavesAPendingDelivery() public {
        BidderContract b = new BidderContract(IEnglishAuction(address(auction)));
        b.set(false, false, true);
        uint256 saleId = _start(1);
        b.bid{ value: 1 ether }(saleId, address(0));
        _end(saleId);
        auction.settle{ gas: 2_000_000 }(saleId);
        assertEq(auction.pendingDelivery(saleId), address(b));
        assertEq(seller.balance, 0.9 ether);
    }

    function test_ClaimDelivery_TheRecipientRedirectsOnlyAfterTheDelay() public {
        BidderContract r = new BidderContract(IEnglishAuction(address(auction)));
        r.set(false, true, false);
        uint256 saleId = _start(1);
        vm.prank(alice);
        auction.bid{ value: 1 ether }(saleId, address(r));
        _end(saleId);
        auction.settle(saleId);
        uint256 end = auction.auction(saleId).endTime;
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.InvalidRecipient.selector, carol));
        r.claimDelivery(saleId, carol);
        vm.warp(end + 14 days);
        r.claimDelivery(saleId, carol);
        assertEq(stream.ownerOf(1), carol);
    }

    function test_ClaimDelivery_TheBidderNamesAnyAddressAtOnce() public {
        BidderContract r = new BidderContract(IEnglishAuction(address(auction)));
        r.set(false, true, false);
        uint256 saleId = _start(1);
        vm.prank(alice);
        auction.bid{ value: 1 ether }(saleId, address(r));
        _end(saleId);
        auction.settle(saleId);
        vm.prank(alice);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.DeliveryClaimed(saleId, address(r), bob);
        auction.claimDelivery(saleId, bob);
        assertEq(stream.ownerOf(1), bob);
    }

    function test_ClaimDelivery_Refusals() public {
        BidderContract b = new BidderContract(IEnglishAuction(address(auction)));
        b.set(false, true, false);
        uint256 saleId = _start(1);
        b.bid{ value: 1 ether }(saleId, address(0));
        _end(saleId);
        auction.settle(saleId);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, carol);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidRecipient.selector, address(0))
        );
        b.claimDelivery(saleId, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidRecipient.selector, address(auction))
        );
        b.claimDelivery(saleId, address(auction));
        b.claimDelivery(saleId, carol);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        b.claimDelivery(saleId, carol);
    }

    function test_Settle_ARescuedWorkClosesWithRefunds() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        stream.removeMinter(address(auction));
        vm.warp(block.timestamp + stream.rescueDelay());
        stream.rescue(1, museum);
        _end(saleId);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(saleId);
        auction.settle(saleId);
        assertEq(auction.claimable(alice), 1 ether);
        assertEq(seller.balance, 0);
        assertEq(stream.ownerOf(1), museum);
        assertEq(uint256(stream.workOf(1).outcome), uint256(Outcome.RESCUED));
    }

    function test_Settle_ARemovedMinterStillSettlesWhatItStarted() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        stream.removeMinter(address(auction));
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
    }

    // ---------------------------------------------------------------------------- claims

    function test_Claim_SendsTheWholeCredit() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        _bid(bob, saleId, 2 ether);
        uint256 before = carol.balance;
        vm.prank(alice);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.Claimed(alice, address(0), carol, 1 ether);
        assertEq(auction.claim(carol), 1 ether);
        assertEq(carol.balance, before + 1 ether);
        assertEq(auction.claimable(alice), 0);
        assertEq(auction.expiresAt(alice), 0);
    }

    function test_Claim_Refusals() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NothingToClaim.selector, alice));
        auction.claim(alice);
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        _bid(bob, saleId, 2 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidRecipient.selector, address(0))
        );
        auction.claim(address(0));
    }

    function test_Claim_ARefusingReceiverKeepsTheCredit() public {
        BidderContract b = new BidderContract(IEnglishAuction(address(auction)));
        uint256 saleId = _start(1);
        b.bid{ value: 1 ether }(saleId, address(0));
        _bid(bob, saleId, 2 ether);
        b.set(true, false, false);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.ClaimFailed.selector, address(b)));
        b.claim(address(b));
        assertEq(auction.claimable(address(b)), 1 ether);
    }

    // ------------------------------------------------------------------------ governance

    function test_Pause_StopsStartsOnly() public {
        uint256 saleId = _start(1);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.Paused(address(this));
        auction.pause();
        assertTrue(auction.paused());
        vm.expectRevert(IEnglishAuction.SalePaused.selector);
        auction.pause();
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
        auction.unpause();
        assertFalse(auction.paused());
        vm.expectRevert(IEnglishAuction.NotPaused.selector);
        auction.unpause();
        _start(2);
    }

    function test_Governance_OnlyTheNetwork() public {
        vm.startPrank(alice);
        bytes4 unauthorized = IAccessManaged.AccessManagedUnauthorized.selector;
        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        auction.pause();
        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        auction.unpause();
        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        auction.setStreamPolicy(address(policy), address(0));
        IEnglishAuction.AuctionConfig memory c = auction.config();
        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        auction.setConfig(c, c);
        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        auction.pause(1, 0);
        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        auction.resume(1);
        vm.expectRevert(abi.encodeWithSelector(unauthorized, alice));
        auction.cancel(1, 0);
        vm.stopPrank();
    }

    function test_SetConfig_WithinBoundsAndCompareAndSet() public {
        IEnglishAuction.AuctionConfig memory c = auction.config();
        IEnglishAuction.AuctionConfig memory next =
            IEnglishAuction.AuctionConfig(2 days, 1 hours, 10_000, 6_000_000);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.ConfigSet(c, next);
        auction.setConfig(c, next);
        assertEq(auction.config().duration, 2 days);
        vm.expectRevert(IEnglishAuction.ExpectedValueMismatch.selector);
        auction.setConfig(c, next);
        IEnglishAuction.AuctionConfig[8] memory bad = [
            IEnglishAuction.AuctionConfig(1 hours - 1, 1 minutes, 1_000, 6_000_000),
            IEnglishAuction.AuctionConfig(7 days + 1, 1 minutes, 1_000, 6_000_000),
            IEnglishAuction.AuctionConfig(1 days, 1 minutes - 1, 1_000, 6_000_000),
            IEnglishAuction.AuctionConfig(2 days, 1 days + 1, 1_000, 6_000_000),
            IEnglishAuction.AuctionConfig(1 hours, 2 hours, 1_000, 6_000_000),
            IEnglishAuction.AuctionConfig(1 days, 1 hours, 999, 6_000_000),
            IEnglishAuction.AuctionConfig(1 days, 1 hours, 100_001, 6_000_000),
            IEnglishAuction.AuctionConfig(1 days, 1 hours, 1_000, 5_999_999)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
            auction.setConfig(next, bad[i]);
        }
        IEnglishAuction.AuctionConfig memory doubled =
            IEnglishAuction.AuctionConfig(2 days, 1 hours, 10_000, 12_000_001);
        vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
        auction.setConfig(next, doubled);
        doubled.refusalGas = 12_000_000;
        auction.setConfig(next, doubled);
        IEnglishAuction.AuctionConfig memory over =
            IEnglishAuction.AuctionConfig(2 days, 1 hours, 10_000, 15_000_001);
        vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
        auction.setConfig(doubled, over);
    }

    function test_SetStreamPolicy_CompareAndSetAndChecked() public {
        vm.expectRevert(IEnglishAuction.ExpectedValueMismatch.selector);
        auction.setStreamPolicy(address(1), address(0));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, alice));
        auction.setStreamPolicy(address(policy), alice);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.StreamPolicySet(address(policy), address(independentStream));
        auction.setStreamPolicy(address(policy), address(independentStream));
        assertEq(auction.streamPolicy(), address(independentStream));
        assertEq(auction.policyOf(address(stream)), address(independentStream));
    }

    function test_PolicyOf_StreamOrTheIndependentStreamModule() public view {
        assertEq(auction.policyOf(address(stream)), address(policy));
        assertEq(auction.policyOf(address(ind)), address(independentStream));
        assertEq(auction.policyOf(alice), address(independentStream));
    }

    function test_Constructor_ChecksItsDependencies() public {
        IEnglishAuction.AuctionConfig memory c = auction.config();
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, alice));
        new EnglishAuction(
            address(manager),
            alice,
            IDirectory(address(directory)),
            IEconomicsResolver(address(economics)),
            IRevenueEscrow(address(escrow)),
            IStatementLog(address(statements)),
            address(policy),
            c
        );
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(stream))
        );
        new EnglishAuction(
            address(manager),
            address(stream),
            IDirectory(address(stream)),
            IEconomicsResolver(address(economics)),
            IRevenueEscrow(address(escrow)),
            IStatementLog(address(statements)),
            address(policy),
            c
        );
        c.duration = 0;
        vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
        new EnglishAuction(
            address(manager),
            address(stream),
            IDirectory(address(directory)),
            IEconomicsResolver(address(economics)),
            IRevenueEscrow(address(escrow)),
            IStatementLog(address(statements)),
            address(policy),
            c
        );
    }

    // ----------------------------------------------------------------------------- views

    function test_Views_UnknownSalesRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.UnknownSale.selector, 5));
        auction.auction(5);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.UnknownSale.selector, 5));
        auction.minimumBid(5);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.UnknownSale.selector, 5));
        auction.auctionClock(5);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.UnknownSale.selector, 5));
        auction.refusableAt(5);
        assertEq(auction.pendingDelivery(5), address(0));
    }

    function test_Views_ClockMatchesTheAuction() public {
        uint256 saleId = _start(1);
        (IEnglishAuction.AuctionState s, uint64 end, uint64 pausedAt,) =
            auction.auctionClock(saleId);
        assertEq(uint256(s), uint256(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(end, auction.auction(saleId).endTime);
        assertEq(pausedAt, 0);
        assertEq(auction.economics().museum(), museum);
    }

    function test_OnERC721Received_RefusesEverySafeTransferIn() public {
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.InvalidTarget.selector, alice));
        vm.prank(alice);
        auction.onERC721Received(address(auction), address(0), 1, "");
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidTarget.selector, address(stream))
        );
        stream.safeTransferFrom(alice, address(auction), 1);
    }

    function test_SupportsInterface() public view {
        assertTrue(auction.supportsInterface(type(IERC165).interfaceId));
        assertTrue(auction.supportsInterface(type(IEnglishAuction).interfaceId));
        assertTrue(auction.supportsInterface(type(IERC721Receiver).interfaceId));
        assertFalse(auction.supportsInterface(type(IERC721).interfaceId));
        assertFalse(auction.supportsInterface(0xffffffff));
    }

    function test_Balance_EqualsStandingBidsPlusCredits() public {
        uint256[] memory sales = new uint256[](2);
        sales[0] = _start(1);
        sales[1] = _start(2);
        _bid(alice, sales[0], 1 ether);
        _bid(bob, sales[0], 2 ether);
        _bid(carol, sales[1], 3 ether);
        _bid(alice, sales[1], 4 ether);
        address[] memory who = new address[](3);
        (who[0], who[1], who[2]) = (alice, bob, carol);
        assertEq(address(auction).balance, _owed(sales, who));
        _end(sales[0]);
        auction.settle(sales[0]);
        assertEq(address(auction).balance, _owed(sales, who));
        vm.prank(carol);
        auction.claim(carol);
        assertEq(address(auction).balance, _owed(sales, who));
    }

    function test_Stream_ModulesSlotIsUntouched() public view {
        assertEq(IModules(address(stream)).moduleOf(Slots.TERMS), address(terms));
    }
}
