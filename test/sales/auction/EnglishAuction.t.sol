// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { Roles } from "src/governance/Roles.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { CURRENCY_DEFAULT, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import {
    LockedTerms,
    Payment,
    PaymentMethod,
    PrimaryTerms,
    SaleKind
} from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { HostileActor, MockMintTarget } from "../../mocks/auction/AuctionMocks.sol";
import { AuctionBase } from "./AuctionBase.sol";

/// @dev Unit tests for starting, bidding, settling, delivery claims and credits.
contract EnglishAuctionTest is AuctionBase {
    // ------------------------------------------------------------------------- deployment

    function test_Constructor_WiresDependenciesAndGenesisTarget() public view {
        assertEq(auction.escrow(), address(escrow));
        assertEq(address(auction.allowlist()), address(allowlist));
        assertEq(address(auction.economicsResolver()), address(resolver));
        assertEq(auction.statementLog(), address(statements));
        assertEq(auction.permit2(), address(permit2));
        assertTrue(auction.isTarget(address(stream)));
        assertEq(auction.saleKind(), SaleKind.ENGLISH_AUCTION);
        IEnglishAuction.AuctionConfig memory c = auction.config();
        assertEq(c.duration, DURATION);
        assertEq(c.extensionWindow, WINDOW);
        assertEq(c.incrementShare, SHARE);
        assertTrue(auction.supportsInterface(type(IEnglishAuction).interfaceId));
        assertTrue(auction.supportsInterface(type(ISaleAdapter).interfaceId));
        assertTrue(auction.supportsInterface(type(IERC165).interfaceId));
        assertTrue(auction.supportsInterface(type(IERC721Receiver).interfaceId));
        assertFalse(auction.supportsInterface(0xffffffff));
    }

    function test_Constructor_RejectsMissingDependencies() public {
        address[] memory none = new address[](0);
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.InvalidDependency.selector, eoa));
        new EnglishAuction(
            address(manager), eoa, resolver, address(statements), address(0), _config(), none
        );
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.InvalidDependency.selector, eoa));
        new EnglishAuction(
            address(manager), address(escrow), resolver, address(statements), eoa, _config(), none
        );
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.InvalidDependency.selector, eoa));
        new EnglishAuction(
            address(manager), address(escrow), resolver, eoa, address(0), _config(), none
        );
        address[] memory bad = new address[](1);
        bad[0] = address(escrow);
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.InvalidTarget.selector, address(escrow))
        );
        new EnglishAuction(
            address(manager),
            address(escrow),
            resolver,
            address(statements),
            address(0),
            _config(),
            bad
        );
    }

    /// @dev MARKET-3: the auction takes the economics resolver (ERC-165 checked) and derives the
    ///      allowlist from it.
    function test_Constructor_RejectsAnUnfitResolver() public {
        address[] memory none = new address[](0);
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.InvalidDependency.selector, eoa));
        new EnglishAuction(
            address(manager),
            address(escrow),
            IEconomicsResolver(eoa),
            address(statements),
            address(0),
            _config(),
            none
        );
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.InvalidDependency.selector, address(escrow))
        );
        new EnglishAuction(
            address(manager),
            address(escrow),
            IEconomicsResolver(address(escrow)),
            address(statements),
            address(0),
            _config(),
            none
        );
        resolver.setAllowlistOverride(eoa);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.InvalidDependency.selector, eoa));
        new EnglishAuction(
            address(manager),
            address(escrow),
            resolver,
            address(statements),
            address(0),
            _config(),
            none
        );
    }

    function test_Constructor_RejectsConfigOutOfBounds() public {
        address[] memory none = new address[](0);
        IEnglishAuction.AuctionConfig[5] memory bad = [
            IEnglishAuction.AuctionConfig(59 minutes, WINDOW, SHARE),
            IEnglishAuction.AuctionConfig(7 days + 1, WINDOW, SHARE),
            IEnglishAuction.AuctionConfig(DURATION, 59, SHARE),
            IEnglishAuction.AuctionConfig(DURATION, WINDOW, 999),
            IEnglishAuction.AuctionConfig(2 hours, 3 hours, SHARE)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(EnglishAuction.InvalidConfig.selector);
            new EnglishAuction(
                address(manager),
                address(escrow),
                resolver,
                address(statements),
                address(0),
                bad[i],
                none
            );
        }
    }

    // ------------------------------------------------------------------------------ start

    function test_Start_MintsIntoCustodyAndOpens() public {
        uint256 expected = _saleIdOf(1);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.SaleStarted(
            expected,
            address(stream),
            1,
            SaleKind.ENGLISH_AUCTION,
            ETH,
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + DURATION)
        );
        vm.prank(carol);
        uint256 saleId = _start();
        assertEq(saleId, expected, "derived from the token and its ID");
        assertEq(stream.ownerOf(1), address(auction));
        assertEq(auction.saleIdOf(address(stream), 1), saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.token, address(stream));
        assertEq(a.tokenId, 1);
        assertEq(a.currency, ETH);
        assertEq(a.incrementFloor, 0, "locked by the first bid");
        assertEq(a.bidder, address(0));
        assertEq(a.bid, 0);
        assertEq(a.endTime, block.timestamp + DURATION);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(auction.minimumBid(saleId), 1);
    }

    function test_Start_PlainMintAlsoWorks() public {
        stream.setSafeMint(false);
        uint256 saleId = _start();
        assertEq(stream.ownerOf(_tokenIdOf(saleId)), address(auction));
    }

    function test_Start_RevertsForUnadmittedTarget() public {
        MockMintTarget other = new MockMintTarget();
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(other))
        );
        auction.start(address(other), "");
    }

    function test_Start_RevertsOnSaleKindMismatch() public {
        stream.setCheckKind(false);
        PrimaryTerms memory t = _terms(ETH);
        t.saleKind = SaleKind.FIXED_PRICE;
        stream.setTerms(t);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector,
                SaleKind.ENGLISH_AUCTION,
                SaleKind.FIXED_PRICE
            )
        );
        _start();
    }

    function test_Start_RevertsOnInactiveCurrency() public {
        address unknown = address(new PermitTokenStub());
        stream.setTerms(_terms(unknown));
        vm.expectRevert(abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, unknown));
        _start();
    }

    function test_Start_RevertsOnUnusableTerms() public {
        for (uint256 i; i < 6; ++i) {
            PrimaryTerms memory t = _terms(ETH);
            if (i == 0) t.seller = address(0);
            if (i == 1) t.feeRecipient = address(0);
            if (i == 2) t.creator = address(0);
            if (i == 3) t.feeShare = 100_001;
            if (i == 4) t.price = 1;
            if (i == 5) t.params = hex"01";
            stream.setTerms(t);
            uint256 next = stream.nextId() + 1;
            vm.expectRevert(
                abi.encodeWithSelector(EnglishAuction.InvalidTerms.selector, address(stream), next)
            );
            _start();
        }
    }

    /// @dev CALLS-1: a work paying the revenue escrow as its seller or fee recipient is refused at
    ///      start and at start-with-bid, while nothing is in custody, because the escrow refuses
    ///      to be paid as a wallet and the work could never settle.
    function test_CALLS1_StartRefusesTheEscrowAsSellerOrFeeRecipient() public {
        for (uint256 i; i < 2; ++i) {
            PrimaryTerms memory t = _terms(ETH);
            if (i == 0) t.feeRecipient = address(escrow);
            else t.seller = address(escrow);
            stream.setTerms(t);
            uint256 next = stream.nextId() + 1;
            vm.expectRevert(
                abi.encodeWithSelector(EnglishAuction.InvalidTerms.selector, address(stream), next)
            );
            _start();
            vm.deal(alice, 1 ether);
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(EnglishAuction.InvalidTerms.selector, address(stream), next)
            );
            auction.startWithBid{ value: 1 ether }(
                address(stream), "", address(0), _direct(alice, 1 ether)
            );
        }
        // Valid wallets start and settle as usual.
        stream.setTerms(_terms(ETH));
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(_tokenIdOf(saleId)), alice);
    }

    function test_Start_RevertsOnBadMintResult() public {
        stream.setMode(MockMintTarget.Mode.ZERO_ID);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        _start();
        stream.setMode(MockMintTarget.Mode.HUGE_ID);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnglishAuction.InvalidTerms.selector, address(stream), uint256(type(uint32).max) + 1
            )
        );
        _start();
        stream.setMode(MockMintTarget.Mode.WRONG_CUSTODY);
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.InvalidTerms.selector, address(stream), 1)
        );
        _start();
    }

    function test_Start_LocksEveryParameter() public {
        vm.prank(setter);
        auction.setOpeningBid(ETH, 0, 0.01 ether);
        uint256 started = block.timestamp;
        uint256 saleId = _start();
        vm.startPrank(setter);
        auction.setConfig(_config(), IEnglishAuction.AuctionConfig(2 days, 1 hours, 50_000));
        auction.setOpeningBid(ETH, 0.01 ether, 0.02 ether);
        vm.stopPrank();
        assertEq(auction.minimumBid(saleId), 0.01 ether, "opening bid locked");
        _bidEth(saleId, alice, 1 ether);
        _setFloor(ETH, 1 ether);
        assertEq(auction.minimumBid(saleId), _minimumAfter(1 ether, ETH_FLOOR), "share, floor");
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.endTime - started, DURATION, "duration locked");
        vm.warp(a.endTime - WINDOW);
        _bidEth(saleId, bob, 2 ether);
        assertEq(auction.auction(saleId).endTime, block.timestamp + WINDOW, "window locked");
    }

    /// @dev E2: the increment floor is read when the first bid arrives and locked from then on.
    function test_IncrementFloorLocksAtTheFirstBid() public {
        uint256 saleId = _start();
        _setFloor(ETH, 0.5 ether);
        _bidEth(saleId, alice, 1 ether);
        assertEq(auction.auction(saleId).incrementFloor, 0.5 ether);
        assertEq(auction.minimumBid(saleId), 1.5 ether);
        _setFloor(ETH, 0.1 ether);
        assertEq(auction.minimumBid(saleId), 1.5 ether, "locked");
        vm.prank(guardian);
        auction.pause(saleId, bytes32(0));
        vm.prank(alice);
        auction.withdrawBid(saleId);
        assertEq(auction.auction(saleId).incrementFloor, 0.5 ether, "kept after a withdrawal");
    }

    function test_Start_Erc20LocksCurrency() public {
        uint256 saleId = _startUsd();
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.currency, address(usd));
        _bidUsd(saleId, alice, 10e18);
        assertEq(auction.auction(saleId).incrementFloor, USD_FLOOR);
        _bidUsd(saleId, bob, 20e18);
        assertEq(auction.claimable(alice, address(usd)), 10e18);
    }

    /// @dev Deprecating the locked currency stops bidding (an emergency tightening), but never
    ///      settlement, refunds or claims.
    /// @dev MARKET-2: deprecation freezes the auction: bids and the settlement of a standing bid
    ///      wait for the currency, claims never do, and the first settle after re-admission
    ///      reopens the auction for at least the anti-snipe window.
    function test_DeprecatedCurrencyFreezesTheAuction() public {
        uint256 saleId = _startUsd();
        _bidUsd(saleId, alice, 10e18);
        _bidUsd(saleId, bob, 20e18);
        allowlist.deprecateAsset(address(usd));
        usd.mint(carol, 30e18);
        vm.startPrank(carol);
        usd.approve(address(auction), 30e18);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usd))
        );
        auction.bid(saleId, address(0), _direct(carol, 30e18));
        vm.stopPrank();
        vm.prank(alice);
        auction.claim(address(usd), alice);
        assertEq(usd.balanceOf(alice), 10e18);
        _end(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, address(usd))
        );
        auction.settle(saleId);
        (,, uint64 revision) = allowlist.assetConfig(address(usd));
        allowlist.admitAsset(address(usd), revision, USD_FLOOR);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(saleId, uint64(block.timestamp + WINDOW));
        auction.settle(saleId);
        vm.startPrank(carol);
        auction.bid(saleId, address(0), _direct(carol, 30e18));
        vm.stopPrank();
        _end(saleId);
        auction.settle(saleId);
        assertEq(usd.balanceOf(seller), 22.5e18);
        assertEq(stream.ownerOf(1), carol);
    }

    /// @dev Terms naming `CURRENCY_DEFAULT` lock the product's default once, at start.
    function test_Start_ResolvesTheDefaultCurrencyOnce() public {
        _setDefault(PRODUCT_STREAM, address(usd));
        stream.setTerms(_terms(CURRENCY_DEFAULT));
        uint256 saleId = _start();
        assertEq(auction.auction(saleId).currency, address(usd));
        _setDefault(PRODUCT_STREAM, ETH);
        assertEq(auction.auction(saleId).currency, address(usd), "running sale unaffected");
        _bidUsd(saleId, alice, 5e18);
        assertEq(auction.auction(_start()).currency, ETH, "new sales use the new default");
    }

    function test_Start_DefaultCurrencyMustBeConfigured() public {
        stream.setTerms(_terms(CURRENCY_DEFAULT));
        vm.expectRevert(
            abi.encodeWithSelector(IAssetAllowlist.CurrencyNotConfigured.selector, PRODUCT_STREAM)
        );
        _start();
    }

    function test_LockedTerms_ReadBackFromTheToken() public {
        uint256 saleId = _start();
        LockedTerms memory lt = auction.lockedTerms(saleId);
        assertEq(lt.token, address(stream));
        assertEq(lt.id, 1);
        assertEq(lt.currency, ETH);
        assertEq(lt.price, 0);
        assertEq(lt.seller, seller);
        assertEq(lt.feeRecipient, network);
        assertEq(lt.feeShare, FEE);
        assertEq(stream.primaryTerms(1, "").creator, artist);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, 7));
        auction.lockedTerms(7);
    }

    function test_OnERC721Received_RejectsUnexpectedTransfers() public {
        stream.setAdmittedMinter(address(this), true);
        stream.setTerms(_terms(ETH));
        stream.setCheckKind(false);
        (uint256 id,) = stream.mint(alice, 0, 1, "");
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.InvalidTarget.selector, address(stream))
        );
        stream.safeTransferFrom(alice, address(auction), id);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.InvalidTarget.selector, alice));
        vm.prank(alice);
        auction.onERC721Received(address(auction), address(0), 1, "");
    }

    /// @dev D4: a VRF item's seed is checked by the token's `mint`; whatever the token refuses,
    ///      the start refuses too, and nothing enters custody.
    function test_Start_RevertsWhenTheTokenRefusesTheMint() public {
        stream.setAdmittedMinter(address(auction), false);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(auction))
        );
        _start();
        assertEq(stream.balanceOf(address(auction)), 0);
    }

    // ------------------------------------------------------------------------------ bids

    function test_Bid_FirstBidThenIncrements() public {
        uint256 saleId = _start();
        vm.expectEmit(address(auction));
        emit IEnglishAuction.BidPlaced(saleId, alice, alice, 1, uint64(block.timestamp + DURATION));
        _bidEth(saleId, alice, 1);
        assertEq(auction.minimumBid(saleId), 1 + ETH_FLOOR, "the floor dominates small bids");
        _bidEth(saleId, bob, 1 + ETH_FLOOR);
        _bidEth(saleId, alice, 1 ether);
        assertEq(auction.minimumBid(saleId), 1.05 ether, "5% dominates large bids");
    }

    function testFuzz_Bid_IncrementIsMaxOfShareAndFloor(uint256 high) public {
        high = bound(high, 1, 1e28);
        uint256 saleId = _start();
        _bidEth(saleId, alice, high);
        uint256 required = _minimumAfter(high, ETH_FLOOR);
        assertEq(auction.minimumBid(saleId), required);
        vm.deal(bob, required);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, required, required - 1)
        );
        auction.bid{ value: required - 1 }(saleId, address(0), _direct(bob, required - 1));
        _bidEth(saleId, bob, required);
        assertEq(auction.claimable(alice, ETH), high);
    }

    function test_Bid_OutbidBidderIsCreditedAndClaims() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(alice, ETH, saleId, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        assertEq(auction.claimable(alice, ETH), 1 ether);
        assertEq(address(auction).balance, 3 ether);
        address dest = makeAddr("dest");
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Claimed(alice, ETH, dest, 1 ether);
        vm.prank(alice);
        assertEq(auction.claim(ETH, dest), 1 ether);
        assertEq(dest.balance, 1 ether);
        assertEq(auction.claimable(alice, ETH), 0);
        assertEq(address(auction).balance, 2 ether);
    }

    function test_Bid_SelfOutbidCreditsThePreviousBid() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, alice, 2 ether);
        assertEq(auction.claimable(alice, ETH), 1 ether);
        assertEq(auction.auction(saleId).bidder, alice);
    }

    function test_Bid_ForAnotherRecipient() public {
        uint256 saleId = _start();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        auction.bid{ value: 1 ether }(saleId, carol, _direct(alice, 1 ether));
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.bidder, alice);
        assertEq(a.recipient, carol);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(auction))
        );
        auction.bid(saleId, address(auction), _direct(alice, 0));
    }

    function test_Bid_AntiSnipeExtends() public {
        uint256 saleId = _start();
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - WINDOW - 1);
        _bidEth(saleId, alice, 1 ether);
        assertEq(auction.auction(saleId).endTime, end, "outside the window");
        vm.warp(end - 1);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.BidPlaced(saleId, bob, bob, 2 ether, uint64(block.timestamp + WINDOW));
        _bidEth(saleId, bob, 2 ether);
        assertEq(auction.auction(saleId).endTime, block.timestamp + WINDOW);
        vm.warp(block.timestamp + WINDOW);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ENDED));
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ENDED
            )
        );
        auction.bid{ value: 3 ether }(saleId, address(0), _direct(alice, 3 ether));
    }

    function test_Bid_EthPaymentMustMatch() public {
        uint256 saleId = _start();
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        auction.bid{ value: 1 ether }(saleId, address(0), _direct(alice, 2 ether));
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        auction.bid{ value: 1 ether }(saleId, address(0), _direct(bob, 1 ether));
        Payment memory p = _direct(alice, 1 ether);
        p.method = PaymentMethod.PERMIT;
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        auction.bid{ value: 1 ether }(saleId, address(0), p);
        vm.stopPrank();
    }

    function test_Bid_Erc20Direct() public {
        uint256 saleId = _startUsd();
        _bidUsd(saleId, alice, 10e18);
        assertEq(usd.balanceOf(address(auction)), 10e18);
        _bidUsd(saleId, bob, 20e18);
        assertEq(auction.claimable(alice, address(usd)), 10e18);
        vm.prank(alice);
        auction.claim(address(usd), alice);
        assertEq(usd.balanceOf(alice), 10e18);
        assertEq(usd.balanceOf(address(auction)), 20e18);
    }

    function test_Bid_Erc20RejectsEthAndForeignPayers() public {
        uint256 saleId = _startUsd();
        usd.mint(alice, 10e18);
        vm.deal(alice, 1);
        vm.startPrank(alice);
        usd.approve(address(auction), type(uint256).max);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        auction.bid{ value: 1 }(saleId, address(0), _direct(alice, 10e18));
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        auction.bid(saleId, address(0), _direct(bob, 10e18));
        vm.stopPrank();
    }

    function test_Bid_Erc20WithEip2612Permit() public {
        uint256 saleId = _startUsd();
        usd.mint(alice, 10e18);
        Payment memory p = _permitPayment(alicePk, 10e18, block.timestamp + 1 hours);
        vm.prank(alice);
        auction.bid(saleId, address(0), p);
        assertEq(usd.balanceOf(address(auction)), 10e18);
        assertEq(usd.allowance(alice, address(auction)), 0);
    }

    function test_Bid_Erc20FrontRunPermitStillBids() public {
        uint256 saleId = _startUsd();
        usd.mint(alice, 10e18);
        Payment memory p = _permitPayment(alicePk, 10e18, block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = _split(p.signature);
        usd.permit(alice, address(auction), 10e18, p.deadline, v, r, s);
        vm.prank(alice);
        auction.bid(saleId, address(0), p);
        assertEq(auction.auction(saleId).bid, 10e18);
    }

    function test_Bid_Erc20PermitNeedsA65ByteSignature() public {
        uint256 saleId = _startUsd();
        Payment memory p = _permitPayment(alicePk, 10e18, block.timestamp + 1 hours);
        p.signature = bytes.concat(p.signature, hex"00");
        vm.prank(alice);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        auction.bid(saleId, address(0), p);
    }

    function test_Bid_Permit2RelayedPaymentIntent() public {
        uint256 saleId = _startUsd();
        usd.mint(alice, 10e18);
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        Payment memory p = _permit2Payment(alicePk, saleId, carol, 10e18, 7);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.BidPlaced(saleId, alice, carol, 10e18, auction.auction(saleId).endTime);
        vm.prank(relayer);
        auction.bid(saleId, carol, p);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.bidder, alice, "the payer is the bidder of record");
        assertEq(a.recipient, carol);
        assertEq(usd.balanceOf(address(auction)), 10e18);

        _bidUsd(saleId, bob, 20e18);
        assertEq(auction.claimable(alice, address(usd)), 10e18, "refunds go to the payer");
    }

    function test_Bid_Permit2WitnessBindsTheSaleAndRecipient() public {
        uint256 saleId = _startUsd();
        uint256 other = _startUsd();
        usd.mint(alice, 10e18);
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        Payment memory p = _permit2Payment(alicePk, saleId, carol, 10e18, 7);
        vm.startPrank(relayer);
        vm.expectRevert(bytes("InvalidSigner"));
        auction.bid(saleId, relayer, p);
        vm.expectRevert(bytes("InvalidSigner"));
        auction.bid(other, carol, p);
        auction.bid(saleId, carol, p);
        Payment memory replay = _permit2Payment(alicePk, saleId, carol, 11e18, 7);
        vm.expectRevert(bytes("InvalidNonce"));
        auction.bid(saleId, carol, replay);
        vm.stopPrank();
    }

    function test_Bid_Permit2Disabled() public {
        EnglishAuction noPermit2 = _deploy(address(0));
        stream.setTerms(_terms(address(usd)));
        uint256 saleId = noPermit2.start(address(stream), "");
        Payment memory p = _permit2Payment(alicePk, saleId, alice, 10e18, 1);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        noPermit2.bid(saleId, alice, p);
    }

    function test_StartWithBid_Eth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 saleId = auction.startWithBid{ value: 1 ether }(
            address(stream), "", carol, _direct(alice, 1 ether)
        );
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.bidder, alice);
        assertEq(a.recipient, carol);
        assertEq(a.bid, 1 ether);
        assertEq(address(auction).balance, 1 ether);
    }

    function test_StartWithBid_Erc20Permit() public {
        stream.setTerms(_terms(address(usd)));
        usd.mint(alice, 5e18);
        Payment memory p = _permitPayment(alicePk, 5e18, block.timestamp + 1 hours);
        vm.prank(alice);
        uint256 saleId = auction.startWithBid(address(stream), "", address(0), p);
        assertEq(auction.auction(saleId).bid, 5e18);
    }

    /// @dev A relayed start-with-bid signs the token, the mint data hash, the recipient, the
    ///      amount and the deadline (`Typehashes.START_BID_WITNESS`), as no sale ID exists yet.
    function test_StartWithBid_Permit2RelayedIntent() public {
        stream.setTerms(_terms(address(usd)));
        usd.mint(alice, 5e18);
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        bytes memory mintData = hex"c0ffee";
        Payment memory p = _startBidPayment(alicePk, mintData, carol, 5e18, 3);
        vm.prank(relayer);
        vm.expectRevert(bytes("InvalidSigner"));
        auction.startWithBid(address(stream), hex"c0ffef", carol, p);
        vm.prank(relayer);
        vm.expectRevert(bytes("InvalidSigner"));
        auction.startWithBid(address(stream), mintData, relayer, p);
        vm.prank(relayer);
        uint256 saleId = auction.startWithBid(address(stream), mintData, carol, p);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.bidder, alice);
        assertEq(a.recipient, carol);
        assertEq(usd.balanceOf(address(auction)), 5e18);
    }

    /// @dev The bid witness binds the amount and the deadline as well as the sale and recipient.
    function test_Bid_Permit2WitnessBindsAmountAndDeadline() public {
        uint256 saleId = _startUsd();
        usd.mint(alice, 20e18);
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        Payment memory p = _permit2Payment(alicePk, saleId, alice, 10e18, 9);
        Payment memory more = _permit2Payment(alicePk, saleId, alice, 10e18, 9);
        more.amount = 11e18;
        vm.prank(relayer);
        vm.expectRevert(bytes("InvalidSigner"));
        auction.bid(saleId, alice, more);
        Payment memory later = _permit2Payment(alicePk, saleId, alice, 10e18, 9);
        later.deadline += 1;
        vm.prank(relayer);
        vm.expectRevert(bytes("InvalidSigner"));
        auction.bid(saleId, alice, later);
        vm.prank(relayer);
        auction.bid(saleId, address(0), p);
        assertEq(auction.auction(saleId).recipient, alice, "zero resolves to the payer");
    }

    // ------------------------------------------------------------------------- settlement

    function test_Settle_PaysTheSplitAndDelivers() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        _end(saleId);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.SaleSettled(
            saleId,
            address(stream),
            1,
            bob,
            bob,
            1,
            ETH,
            2 ether,
            seller,
            1.5 ether,
            network,
            0.5 ether
        );
        vm.prank(carol);
        auction.settle(saleId);
        assertEq(seller.balance, 1.5 ether, "paid to the undeployed split wallet address");
        assertEq(network.balance, 0.5 ether);
        assertEq(stream.ownerOf(1), bob);
        assertEq(address(auction).balance, 1 ether, "alice's credit remains");
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(auction.pendingDelivery(saleId), address(0));
        assertTrue(stream.primarySettled(1), "E11: marked at settlement");
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.SETTLED
            )
        );
        auction.settle(saleId);
    }

    function testFuzz_Settle_SplitsExactly(uint256 price, uint32 feeShare) public {
        price = bound(price, 1, type(uint96).max);
        feeShare = uint32(bound(feeShare, 0, 100_000));
        PrimaryTerms memory t = _terms(ETH);
        t.feeShare = feeShare;
        stream.setTerms(t);
        uint256 saleId = _start();
        _bidEth(saleId, alice, price);
        _end(saleId);
        auction.settle(saleId);
        uint256 fee = price * feeShare / 100_000;
        assertEq(network.balance, fee);
        assertEq(seller.balance, price - fee);
        assertEq(address(auction).balance, 0);
    }

    /// @dev A zero-fee configuration may name no fee recipient: the start is accepted and the
    ///      seller receives the whole price, with nothing paid on the fee side.
    function test_ZeroFeeWithoutARecipient() public {
        PrimaryTerms memory t = _terms(ETH);
        t.feeShare = 0;
        t.feeRecipient = address(0);
        stream.setTerms(t);
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _end(saleId);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.SaleSettled(
            saleId,
            address(stream),
            1,
            alice,
            alice,
            1,
            ETH,
            1 ether,
            seller,
            1 ether,
            address(0),
            0
        );
        auction.settle(saleId);
        assertEq(seller.balance, 1 ether);
        assertEq(address(auction).balance, 0);
        assertEq(escrow.owed(address(0), ETH), 0);

        uint256 quiet = _start();
        _end(quiet);
        auction.settle(quiet);
        assertEq(stream.ownerOf(2), artist, "no-bid settlement with no fee side");
    }

    /// @dev A non-zero fee share still needs a fee recipient.
    function test_NonZeroFeeNeedsARecipient() public {
        PrimaryTerms memory t = _terms(ETH);
        t.feeRecipient = address(0);
        stream.setTerms(t);
        vm.expectRevert(
            abi.encodeWithSelector(EnglishAuction.InvalidTerms.selector, address(stream), 1)
        );
        _start();
    }

    function test_Settle_RevertsBeforeTheEnd() public {
        uint256 saleId = _start();
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.settle(saleId);
    }

    function test_Settle_NoBidsSendsTheTokenToTheArtist() public {
        uint256 saleId = _start();
        _end(saleId);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.SaleSettled(
            saleId, address(stream), 1, address(0), artist, 1, ETH, 0, seller, 0, network, 0
        );
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), artist);
        assertEq(seller.balance + network.balance, 0);
        assertEq(auction.auction(saleId).recipient, artist);
        assertTrue(stream.primarySettled(1));
    }

    /// @dev D13: with no bids the token goes to the artist's authority resolved at settlement,
    ///      so a recovery during the auction is honoured.
    function test_Settle_NoBidsFollowsTheArtistsCurrentAuthority() public {
        uint256 saleId = _start();
        address recovered = makeAddr("recoveredAuthority");
        stream.setCreatorNow(recovered);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), recovered);
        assertEq(auction.auction(saleId).recipient, recovered);
    }

    function test_Settle_NoBidsRefusesAnUnresolvedArtist() public {
        uint256 saleId = _start();
        stream.setLockedCreator(1, address(0));
        _end(saleId);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(0)));
        auction.settle(saleId);
    }

    function test_Settle_Erc20() public {
        uint256 saleId = _startUsd();
        _bidUsd(saleId, alice, 100e18);
        _end(saleId);
        auction.settle(saleId);
        assertEq(usd.balanceOf(seller), 75e18);
        assertEq(usd.balanceOf(network), 25e18);
        assertEq(usd.balanceOf(address(auction)), 0);
    }

    function test_Settle_RefusingWalletIsEscrowed() public {
        HostileActor wallet = new HostileActor();
        wallet.configure(HostileActor.Behaviour.REVERT, HostileActor.Behaviour.ACCEPT);
        PrimaryTerms memory t = _terms(ETH);
        t.seller = address(wallet);
        stream.setTerms(t);
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(escrow.owed(address(wallet), ETH), 0.75 ether);
        assertEq(network.balance, 0.25 ether);
        assertEq(stream.ownerOf(1), alice);
        wallet.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.ACCEPT);
        escrow.flush(address(wallet), ETH);
        assertEq(address(wallet).balance, 0.75 ether);
    }

    function test_Settle_FailedDeliveryLeavesAPendingClaim() public {
        HostileActor winner = new HostileActor();
        HostileActor.Behaviour[4] memory modes = [
            HostileActor.Behaviour.REVERT,
            HostileActor.Behaviour.BURN_GAS,
            HostileActor.Behaviour.WRONG_MAGIC,
            HostileActor.Behaviour.HAND_BACK
        ];
        for (uint256 i; i < modes.length; ++i) {
            winner.configure(HostileActor.Behaviour.ACCEPT, modes[i]);
            uint256 saleId = _start();
            vm.deal(alice, 1 ether);
            vm.prank(alice);
            auction.bid{ value: 1 ether }(saleId, address(winner), _direct(alice, 1 ether));
            _end(saleId);
            vm.expectEmit(address(auction));
            emit IEnglishAuction.DeliveryPending(saleId, address(winner));
            auction.settle(saleId);
            assertEq(stream.ownerOf(_tokenIdOf(saleId)), address(auction));
            assertEq(auction.pendingDelivery(saleId), address(winner));
            assertTrue(stream.primarySettled(_tokenIdOf(saleId)), "not held up by the claim");
            assertEq(seller.balance, 0.75 ether * (i + 1), "settlement still pays");

            vm.expectRevert(
                abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId)
            );
            vm.prank(bob);
            auction.claimDelivery(saleId, bob);
            vm.expectEmit(address(auction));
            emit IEnglishAuction.DeliveryClaimed(saleId, address(winner), carol);
            winner.execute(
                address(auction), 0, abi.encodeCall(auction.claimDelivery, (saleId, carol))
            );
            assertEq(stream.ownerOf(_tokenIdOf(saleId)), carol);
            assertEq(auction.pendingDelivery(saleId), address(0));
            vm.expectRevert(
                abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId)
            );
            winner.execute(
                address(auction), 0, abi.encodeCall(auction.claimDelivery, (saleId, carol))
            );
        }
    }

    function test_Settle_NoBidArtistThatRejectsGetsAPendingClaim() public {
        HostileActor artistWallet = new HostileActor();
        artistWallet.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        PrimaryTerms memory t = _terms(ETH);
        t.creator = address(artistWallet);
        stream.setTerms(t);
        uint256 saleId = _start();
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.pendingDelivery(saleId), address(artistWallet));
        artistWallet.execute(
            address(auction), 0, abi.encodeCall(auction.claimDelivery, (saleId, artist))
        );
        assertEq(stream.ownerOf(_tokenIdOf(saleId)), artist);
    }

    function test_Settle_TokenThatBlocksTransfersLeavesAPendingClaim() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _end(saleId);
        stream.setMode(MockMintTarget.Mode.REJECT_TRANSFERS);
        auction.settle(saleId);
        assertEq(auction.pendingDelivery(saleId), alice);
        vm.prank(alice);
        vm.expectRevert(bytes("transfers paused"));
        auction.claimDelivery(saleId, alice);
        stream.setMode(MockMintTarget.Mode.NORMAL);
        vm.prank(alice);
        auction.claimDelivery(saleId, alice);
        assertEq(stream.ownerOf(_tokenIdOf(saleId)), alice);
    }

    function test_Settle_RevertsWhenTheCallerStarvesDelivery() public {
        uint256 saleId = _start();
        _end(saleId);
        vm.expectRevert(EnglishAuction.DeliveryInsufficientGas.selector);
        auction.settle{ gas: 250_000 }(saleId);
        assertEq(stream.ownerOf(_tokenIdOf(saleId)), address(auction));
    }

    /// @dev A recipient contract that can neither receive the token nor make the claim does not
    ///      strand it: the winning bidder claims it to any address. Nobody else can.
    function test_ClaimDelivery_TheWinnerCanRedirect() public {
        HostileActor recipient = new HostileActor();
        recipient.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        uint256 saleId = _start();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        auction.bid{ value: 1 ether }(saleId, address(recipient), _direct(alice, 1 ether));
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.pendingDelivery(saleId), address(recipient));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, bob);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.DeliveryClaimed(saleId, address(recipient), carol);
        vm.prank(alice);
        auction.claimDelivery(saleId, carol);
        assertEq(stream.ownerOf(1), carol);
        assertEq(auction.pendingDelivery(saleId), address(0));
    }

    /// @dev With no bids only the artist may claim a pending delivery.
    function test_ClaimDelivery_NoBidsOnlyTheArtist() public {
        HostileActor artistWallet = new HostileActor();
        artistWallet.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        PrimaryTerms memory t = _terms(ETH);
        t.creator = address(artistWallet);
        stream.setTerms(t);
        uint256 saleId = _start();
        _end(saleId);
        auction.settle(saleId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, alice);
    }

    function test_ClaimDelivery_RejectsBadDestinations() public {
        HostileActor winner = new HostileActor();
        winner.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        uint256 saleId = _start();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        auction.bid{ value: 1 ether }(saleId, address(winner), _direct(alice, 1 ether));
        _end(saleId);
        auction.settle(saleId);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(0)));
        winner.execute(
            address(auction), 0, abi.encodeCall(auction.claimDelivery, (saleId, address(0)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(auction))
        );
        winner.execute(
            address(auction), 0, abi.encodeCall(auction.claimDelivery, (saleId, address(auction)))
        );
    }

    // ---------------------------------------------------------------------------- credits

    function test_Claim_RevertsWithNothingOrNoDestination() public {
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NothingToClaim.selector, alice, ETH));
        vm.prank(alice);
        auction.claim(ETH, alice);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(0)));
        vm.prank(alice);
        auction.claim(ETH, address(0));
    }

    function test_Claim_ToARefusingAddressKeepsTheCredit() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        HostileActor refusing = new HostileActor();
        refusing.configure(HostileActor.Behaviour.REVERT, HostileActor.Behaviour.ACCEPT);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.ClaimFailed.selector, address(refusing))
        );
        auction.claim(ETH, address(refusing));
        assertEq(auction.claimable(alice, ETH), 1 ether);
    }

    // ------------------------------------------------------------------------------ views

    function test_Views_UnknownSale() public {
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, 7));
        auction.auction(7);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, 7));
        auction.minimumBid(7);
        assertEq(auction.saleIdOf(address(stream), 7), uint256(keccak256(abi.encode(stream, 7))));
        assertEq(auction.pendingDelivery(7), address(0));
    }

    // --------------------------------------------------------------------- emergency pause

    /// @dev The emergency pause stops only new starts; every live auction carries on.
    function test_EmergencyPause_StopsOnlyNewStarts() public {
        uint256 live = _start();
        _bidEth(live, alice, 1 ether);
        uint256 quiet = _start();
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Paused(pauser);
        vm.prank(pauser);
        auction.pause();
        assertTrue(auction.paused());

        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        _start();
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        auction.startWithBid{ value: 1 ether }(
            address(stream), "", address(0), _direct(carol, 1 ether)
        );

        _bidEth(live, bob, 2 ether);
        vm.prank(alice);
        auction.claim(ETH, alice);
        _pause(quiet);
        // GOV-5: the start pause ends no earlier than 48 hours after it began.
        vm.prank(unpauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.UnpauseTooEarly.selector, block.timestamp + Roles.STANDARD
            )
        );
        auction.unpause();
        _end(live);
        auction.settle(live);
        assertEq(stream.ownerOf(_tokenIdOf(live)), bob);
        assertEq(seller.balance, 1.5 ether);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(unpauser);
        auction.resume(quiet);

        vm.expectEmit(address(auction));
        emit ISaleAdapter.Unpaused(unpauser);
        vm.prank(unpauser);
        auction.unpause();
        assertFalse(auction.paused());
        _start();
    }

    function test_EmergencyPause_RolesAndStateChecks() public {
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian)
        );
        auction.pause();
        vm.prank(unpauser);
        vm.expectRevert(ISaleAdapter.NotPaused.selector);
        auction.unpause();
        vm.prank(pauser);
        auction.pause();
        vm.prank(pauser);
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        auction.pause();
        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, pauser)
        );
        auction.unpause();
    }

    function test_GovernedFunctionsRejectEthAndOutsiders() public {
        bytes[7] memory calls = [
            abi.encodeWithSelector(DISPUTE_PAUSE, 1, bytes32(0)),
            abi.encodeWithSelector(START_PAUSE),
            abi.encodeWithSelector(START_UNPAUSE),
            abi.encodeCall(auction.resume, (1)),
            abi.encodeCall(auction.cancel, (1, bytes32(0))),
            abi.encodeCall(auction.setOpeningBid, (ETH, 0, 1)),
            abi.encodeCall(auction.setTarget, (alice, true))
        ];
        vm.deal(alice, 7);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory reason) = address(auction).call{ value: 1 }(calls[i]);
            assertFalse(ok);
            assertEq(reason.length, 0, "non-payable");
            vm.prank(alice);
            (ok, reason) = address(auction).call(calls[i]);
            assertFalse(ok);
            assertEq(
                reason,
                abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
            );
        }
    }

    function _split(bytes memory sig) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
    }
}

/// @dev A contract with code that was never admitted to the allowlist.
contract PermitTokenStub { }
