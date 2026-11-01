// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { RevenuePayment } from "src/economics/RevenuePayment.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { Roles } from "src/governance/Roles.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { CURRENCY_DEFAULT, PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import {
    LockedTerms,
    Payment,
    PaymentMethod,
    PrimaryOutcome,
    PrimaryTerms,
    SaleKind
} from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import {
    ForwardingBidder,
    HolderReportingTarget,
    HostileActor,
    OutcomeReportingTarget,
    HugeIdTarget,
    MockMintTarget
} from "../../mocks/sales/AuctionMocks.sol";
import { MockPermit2 } from "../../mocks/sales/SaleMocks.sol";
import { AuctionBase } from "./AuctionBase.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { IEnglishAuctionFull } from "test/helpers/IEnglishAuctionFull.sol";

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
        assertFalse(auction.supportsInterface(0x00000001));
        // The opening-bid ceiling is a thousand currency floors (the specification's number).
        assertEq(auction.OPENING_BID_FLOORS(), 1_000);
    }

    /// @dev Each bound is inclusive: a window as long as the auction, and a 100% increment.
    function test_Constructor_AcceptsConfigAtTheBounds() public {
        address[] memory none = new address[](0);
        IEnglishAuction.AuctionConfig[2] memory edge = [
            IEnglishAuction.AuctionConfig(2 hours, 2 hours, SHARE),
            IEnglishAuction.AuctionConfig(DURATION, WINDOW, 100_000)
        ];
        for (uint256 i; i < edge.length; ++i) {
            EnglishAuction a = new EnglishAuction(
                address(manager),
                address(escrow),
                resolver,
                address(statements),
                address(0),
                bareLens,
                bareLens.codehash,
                edge[i],
                none
            );
            assertEq(
                IEnglishAuctionFull(address(a)).config().extensionWindow, edge[i].extensionWindow
            );
        }
    }

    /// @dev An ETH bid sends exactly the payment's amount: more is refused, not kept.
    function test_Bid_EthMustMatchTheAmountExactly() public {
        uint256 saleId = _start();
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        auction.bid{ value: 1 ether + 1 }(saleId, address(0), _direct(alice, 1 ether));
    }

    function test_Constructor_RejectsMissingDependencies() public {
        address[] memory none = new address[](0);
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new EnglishAuction(
            address(manager),
            eoa,
            resolver,
            address(statements),
            address(0),
            bareLens,
            bareLens.codehash,
            _config(),
            none
        );
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new EnglishAuction(
            address(manager),
            address(escrow),
            resolver,
            address(statements),
            eoa,
            bareLens,
            bareLens.codehash,
            _config(),
            none
        );
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new EnglishAuction(
            address(manager),
            address(escrow),
            resolver,
            eoa,
            address(0),
            bareLens,
            bareLens.codehash,
            _config(),
            none
        );
        address[] memory bad = new address[](1);
        bad[0] = address(escrow);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(escrow))
        );
        new EnglishAuction(
            address(manager),
            address(escrow),
            resolver,
            address(statements),
            address(0),
            bareLens,
            bareLens.codehash,
            _config(),
            bad
        );
    }

    /// Regression: MARKET-3 (docs/security/internal-review-2026-10.md)
    /// @dev MARKET-3: the auction takes the economics resolver (ERC-165 checked) and derives the
    ///      allowlist from it.
    function test_Constructor_RejectsAnUnfitResolver() public {
        address[] memory none = new address[](0);
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new EnglishAuction(
            address(manager),
            address(escrow),
            IEconomicsResolver(eoa),
            address(statements),
            address(0),
            bareLens,
            bareLens.codehash,
            _config(),
            none
        );
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(escrow))
        );
        new EnglishAuction(
            address(manager),
            address(escrow),
            IEconomicsResolver(address(escrow)),
            address(statements),
            address(0),
            bareLens,
            bareLens.codehash,
            _config(),
            none
        );
        resolver.setAllowlistOverride(eoa);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new EnglishAuction(
            address(manager),
            address(escrow),
            resolver,
            address(statements),
            address(0),
            bareLens,
            bareLens.codehash,
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
            vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
            new EnglishAuction(
                address(manager),
                address(escrow),
                resolver,
                address(statements),
                address(0),
                bareLens,
                bareLens.codehash,
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
        t.saleKind = SaleKind.UNIFORM_AUCTION;
        stream.setTerms(t);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector,
                SaleKind.ENGLISH_AUCTION,
                SaleKind.UNIFORM_AUCTION
            )
        );
        _start();
    }

    /// @dev A sale kind sorting below the auction's is refused like one sorting above it
    ///      (`UNIFORM_AUCTION` sorts above) (found by mutation testing).
    function test_Start_RevertsOnASaleKindSortingBelowTheAuctions() public {
        bytes32 low = bytes32(uint256(1));
        assertLt(uint256(low), uint256(SaleKind.ENGLISH_AUCTION));
        stream.setCheckKind(false);
        PrimaryTerms memory t = _terms(ETH);
        t.saleKind = low;
        stream.setTerms(t);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector, SaleKind.ENGLISH_AUCTION, low
            )
        );
        _start();
    }

    /// @dev A token that reports a token ID whose sale already exists (here one still in
    ///      custody, live) cannot start a second sale over it (found by mutation testing).
    function test_Start_RevertsWhenTheSaleAlreadyExists() public {
        HugeIdTarget t = new HugeIdTarget();
        vm.prank(successor);
        auction.setTarget(address(t), true);
        t.setId(7);
        uint256 saleId = auction.start(address(t), "");
        assertEq(t.ownerOf(7), address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.start(address(t), "");
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
                abi.encodeWithSelector(
                    ISaleAdapter.InvalidSaleTerms.selector, address(stream), next
                )
            );
            _start();
        }
    }

    /// Regression: CALLS-1 (docs/security/internal-review-2026-10.md)
    /// @dev A work paying the revenue escrow as its seller or fee recipient is refused at
    ///      start and at start-with-bid, while nothing is in custody, because the escrow refuses
    ///      to be paid as a wallet and the work could never settle.
    function test_Start_RefusesTheEscrowAsSellerOrFeeRecipient() public {
        for (uint256 i; i < 2; ++i) {
            PrimaryTerms memory t = _terms(ETH);
            if (i == 0) t.feeRecipient = address(escrow);
            else t.seller = address(escrow);
            stream.setTerms(t);
            uint256 next = stream.nextId() + 1;
            vm.expectRevert(
                abi.encodeWithSelector(
                    ISaleAdapter.InvalidSaleTerms.selector, address(stream), next
                )
            );
            _start();
            vm.deal(alice, 1 ether);
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ISaleAdapter.InvalidSaleTerms.selector, address(stream), next
                )
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
                ISaleAdapter.InvalidSaleTerms.selector,
                address(stream),
                uint256(type(uint32).max) + 1
            )
        );
        _start();
        stream.setMode(MockMintTarget.Mode.WRONG_CUSTODY);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(stream), 1)
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

    /// Regression: MARKET-2 (docs/security/internal-review-2026-10.md)
    /// @dev MARKET-2: deprecation freezes the auction: bids and settlement wait for the
    ///      currency, claims never do, and the first settle after re-admission reopens the
    ///      auction for the governed duration.
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
        vm.warp(block.timestamp + Roles.FUNDS);
        allowlist.admitAsset(address(usd), revision, USD_FLOOR);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(saleId, uint64(block.timestamp + DURATION));
        auction.settle(saleId);
        vm.startPrank(carol);
        auction.bid(saleId, address(0), _direct(carol, 30e18));
        vm.stopPrank();
        _end(saleId);
        auction.settle(saleId);
        assertEq(usd.balanceOf(seller), 22.5e18);
        assertEq(stream.ownerOf(1), carol);
    }

    /// @dev MARKET-2 reopens an auction only for a currency back inside its last window: one
    ///      back exactly a window before the end (re-admitted in the start's block, with a window
    ///      as long as the auction) settles at the end (found by mutation testing).
    function test_Settle_ACurrencyBackExactlyAWindowBeforeTheEndDoesNotReopen() public {
        vm.prank(setter);
        auction.setConfig(_config(), IEnglishAuction.AuctionConfig(DURATION, DURATION, SHARE));
        allowlist.deprecateAsset(address(usd));
        vm.warp(block.timestamp + Roles.FUNDS);
        (,, uint64 revision) = allowlist.assetConfig(address(usd));
        allowlist.admitAsset(address(usd), revision, USD_FLOOR);
        uint256 saleId = _startUsd();
        (, uint256 since,) = allowlist.statusClock(address(usd));
        assertEq(since + DURATION, auction.auction(saleId).endTime);
        _end(saleId);
        auction.settle(saleId);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(stream.ownerOf(1), museum, "unbid: the museum (D140)");
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
            abi.encodeWithSelector(IEnglishAuction.InvalidTarget.selector, address(stream))
        );
        stream.safeTransferFrom(alice, address(auction), id);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.InvalidTarget.selector, alice));
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

    /// Regression: L-1 (PoC F2, inverted) in the review of #21
    /// @dev A zero fee with no fee recipient starts.
    function test_Start_AZeroFeeWorkStarts() public {
        stream.setTerms(
            PrimaryTerms(SaleKind.ENGLISH_AUCTION, ETH, 0, "", seller, address(0), 0, artist)
        );
        uint256 saleId = auction.start(address(stream), "");
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.ACTIVE));
    }

    /// Regression: the review of #21
    /// @dev Token IDs at the packing limit: 2^32 - 1 is accepted and round-trips; 2^32 is refused.
    function test_Start_TokenIdPackingLimit() public {
        HugeIdTarget t = new HugeIdTarget();
        t.setAdmittedMinter(address(auction), true);
        vm.prank(successor);
        auction.setTarget(address(t), true);
        t.setId(type(uint32).max);
        uint256 saleId = auction.start(address(t), "");
        assertEq(auction.auction(saleId).tokenId, type(uint32).max);
        assertEq(saleId, auction.saleIdOf(address(t), type(uint32).max));
        t.setId(uint256(type(uint32).max) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.InvalidSaleTerms.selector, address(t), uint256(type(uint32).max) + 1
            )
        );
        auction.start(address(t), "");
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

    /// @dev A permit signature one byte longer or shorter is refused with `InvalidPayment`; a
    ///      short one never reaches the signature's last byte (found by mutation testing).
    function test_Bid_Erc20PermitNeedsA65ByteSignature() public {
        uint256 saleId = _startUsd();
        Payment memory p = _permitPayment(alicePk, 10e18, block.timestamp + 1 hours);
        (, bytes32 r, bytes32 s) = _split(p.signature);
        p.signature = bytes.concat(p.signature, hex"00");
        vm.prank(alice);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        auction.bid(saleId, address(0), p);
        p.signature = abi.encodePacked(r, s);
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
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        auction.bid(saleId, relayer, p);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        auction.bid(other, carol, p);
        auction.bid(saleId, carol, p);
        Payment memory replay = _permit2Payment(alicePk, saleId, carol, 11e18, 7);
        vm.expectRevert(MockPermit2.InvalidNonce.selector);
        auction.bid(saleId, carol, replay);
        vm.stopPrank();
    }

    function test_Bid_Permit2Disabled() public {
        IEnglishAuctionFull noPermit2 = _deploy(address(0));
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
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        auction.startWithBid(address(stream), hex"c0ffef", carol, p);
        vm.prank(relayer);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
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
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        auction.bid(saleId, alice, more);
        Payment memory later = _permit2Payment(alicePk, saleId, alice, 10e18, 9);
        later.deadline += 1;
        vm.prank(relayer);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        auction.bid(saleId, alice, later);
        vm.prank(relayer);
        auction.bid(saleId, address(0), p);
        assertEq(auction.auction(saleId).recipient, alice, "zero resolves to the payer");
    }

    /// Regression: the review of #57
    /// @dev An expired PERMIT or PERMIT2 payment reverts with `PaymentExpired`, as in the
    ///      fixed-price and Dutch adapters, even where an existing allowance would pay.
    function test_Bid_ExpiredPermitsRevertAlike() public {
        uint256 saleId = _startUsd();
        usd.mint(alice, 10e18);
        vm.prank(alice);
        usd.approve(address(auction), 10e18);
        uint256 deadline = block.timestamp - 1;
        Payment memory p = _permitPayment(alicePk, 10e18, deadline);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.PaymentExpired.selector, deadline));
        auction.bid(saleId, address(0), p);
        Payment memory p2 = _permit2Payment(bobPk, saleId, bob, 10e18, 1);
        vm.warp(p2.deadline + 1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.PaymentExpired.selector, p2.deadline));
        auction.bid(saleId, bob, p2);
        // A direct payment carries no deadline.
        vm.prank(alice);
        auction.bid(saleId, address(0), _direct(alice, 10e18));
        assertEq(auction.auction(saleId).bidder, alice);
    }

    /// @dev A permit is good through its deadline second (found by mutation testing).
    function test_Bid_APermitPaysAtItsDeadlineSecond() public {
        uint256 saleId = _startUsd();
        usd.mint(alice, 10e18);
        Payment memory p = _permitPayment(alicePk, 10e18, block.timestamp);
        vm.prank(alice);
        auction.bid(saleId, address(0), p);
        assertEq(auction.auction(saleId).bidder, alice);
    }

    /// Regression: the review of #21
    /// @dev Boundaries: a bid at exactly the end reverts; a bid one second before extends to
    ///      exactly now + window; a bid at end - window does not extend.
    function test_Bid_TimingBoundaries() public {
        uint256 saleId = _start();
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - WINDOW);
        _bidEth(saleId, alice, 1 ether);
        assertEq(auction.auction(saleId).endTime, end, "no extension at exactly the window");
        vm.warp(end - 1);
        _bidEth(saleId, bob, 2 ether);
        assertEq(auction.auction(saleId).endTime, end - 1 + WINDOW);
        vm.warp(end - 1 + WINDOW);
        vm.deal(carol, 3 ether);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ENDED
            )
        );
        auction.bid{ value: 3 ether }(saleId, address(0), _direct(carol, 3 ether));
    }

    /// Regression: mutant I5 in the review of #21
    /// @dev A floor raised after the first bid does not apply to later bids.
    function test_Bid_AFloorRaisedAfterTheFirstBidDoesNotApply() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _setFloor(ETH, 1 ether);
        _bidEth(saleId, bob, 1.05 ether);
        assertEq(auction.auction(saleId).bidder, bob);
        assertEq(auction.auction(saleId).incrementFloor, ETH_FLOOR);
    }

    /// Regression: L-4 in the review of #21
    /// @dev A bid for oneself stores no recipient; a bid for another stores it, and the
    ///      next self-bid clears it.
    function test_Bid_RecipientStoredOnlyWhenItDiffers() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        assertEq(auction.auction(saleId).recipient, alice, "resolved to the bidder");
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        auction.bid{ value: 2 ether }(saleId, carol, _direct(bob, 2 ether));
        assertEq(auction.auction(saleId).recipient, carol);
        _bidEth(saleId, alice, 3 ether);
        assertEq(auction.auction(saleId).recipient, alice);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
    }

    /// Regression: surviving mutant M8 in the review of #33
    /// @dev A recipient already stored is replaced when the next bid names a different third
    ///      party, and the token goes to the latest one.
    function test_Bid_RecipientChangesBetweenThirdParties() public {
        uint256 saleId = _start();
        address dave = makeAddr("dave");
        _bidFor(saleId, alice, carol, 1 ether);
        _bidFor(saleId, bob, dave, 2 ether);
        assertEq(auction.auction(saleId).recipient, dave);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(_tokenIdOf(saleId)), dave, "the winning bid's recipient");
    }

    /// Regression: L-4 in the review of #21
    /// @dev Bids above 96 bits (7.9e28 base units) are refused rather than truncated; the
    ///      largest one is accepted.
    function test_Bid_RefusesBidsAbove96Bits() public {
        uint256 largest = _start();
        _bidEth(largest, bob, type(uint96).max);
        assertEq(auction.auction(largest).bid, type(uint96).max);
        uint256 saleId = _start();
        uint256 amount = uint256(type(uint96).max) + 1;
        vm.deal(alice, amount);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, amount)
        );
        auction.bid{ value: amount }(saleId, address(0), _direct(alice, amount));
    }

    /// @dev Golden values computed off-chain with `cast keccak`: the full Permit2 type hashes the
    ///      auction's PERMIT2 bids are signed under (D16), built from `Typehashes`.
    function test_Permit2Witness_Golden() public pure {
        string memory stub =
            "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
        assertEq(keccak256(abi.encodePacked(stub, Typehashes.BID_WITNESS_TYPE)), BID_PERMIT_GOLDEN);
        assertEq(
            keccak256(abi.encodePacked(stub, Typehashes.START_BID_WITNESS_TYPE)),
            START_BID_PERMIT_GOLDEN
        );
        assertEq(
            Typehashes.BID_WITNESS,
            keccak256("Bid(uint256 saleId,address recipient,uint256 amount,uint256 deadline)")
        );
    }

    bytes32 internal constant BID_PERMIT_GOLDEN =
        0x0bfd3d1d308e98f9f0a38b17a9eaaad1118b7813eead91902f6714537c0eb034;
    bytes32 internal constant START_BID_PERMIT_GOLDEN =
        0xb44f39960bfdaf0c5fedccb2b3159844117a56c2d506bcf2c35776fe2c346acf;

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
        assertEq(stream.ownerOf(2), museum, "no-bid settlement with no fee side (D140)");
    }

    /// @dev A non-zero fee share still needs a fee recipient.
    function test_NonZeroFeeNeedsARecipient() public {
        PrimaryTerms memory t = _terms(ETH);
        t.feeRecipient = address(0);
        stream.setTerms(t);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(stream), 1)
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

    /// @dev D140 (ADR 0005): an unbid canonical work goes to the 6529 Network Museum, not to
    ///      its artist. This replaces the rc.1 behaviour, where it went to the artist.
    function test_Settle_NoBidsSendsTheTokenToTheMuseum() public {
        uint256 saleId = _start();
        _end(saleId);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.SaleSettled(
            saleId, address(stream), 1, address(0), museum, 1, ETH, 0, seller, 0, network, 0
        );
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), museum);
        assertEq(stream.balanceOf(artist), 0, "not the artist");
        assertEq(seller.balance + network.balance, 0);
        assertEq(auction.auction(saleId).recipient, museum);
        assertTrue(stream.primarySettled(1));
    }

    /// @dev D140: the museum is read from the economics resolver when the sale settles, so a
    ///      governed change made while the auction ran (or before a late settle) is honoured;
    ///      the artist's authority plays no part.
    function test_Settle_NoBidsFollowsTheMuseumAtSettlement() public {
        uint256 saleId = _start();
        address next = makeAddr("nextMuseum");
        resolver.setMuseumAccount(next);
        stream.setCreatorNow(makeAddr("recoveredAuthority"));
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), next);
        assertEq(auction.auction(saleId).recipient, next);
    }

    /// @dev D140: a canonical work no longer waits out an unresolved (restrained) artist: the
    ///      museum receives it at once. Under rc.1 this reverted until the override's outcome
    ///      (IDENTITY-1); ADR 0005 keeps that wait for federated works only.
    function test_Settle_NoBidsReachesTheMuseumWhileTheArtistIsUnresolved() public {
        uint256 saleId = _start();
        stream.setLockedCreator(1, address(0));
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), museum);
    }

    /// @dev Fail closed: a resolver that names no museum leaves an unbid canonical work in
    ///      custody; 6529 Stream refuses the move (the real resolver never names zero, so this
    ///      guards a broken one).
    function test_Settle_NoBidsRefusesAZeroMuseum() public {
        uint256 saleId = _start();
        resolver.setMuseumAccount(address(0));
        _end(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0))
        );
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), address(auction));
    }

    /// @dev A sold settlement never reads the museum: the read is only on the no-bid path.
    function test_Settle_ASoldSettlementDoesNotReadTheMuseum() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _end(saleId);
        vm.expectCall(address(resolver), abi.encodeCall(IEconomicsResolver.museum, ()), 0);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
    }

    /// @dev Owner decision 9 (ADR 0005): an unbid federated work stays with its artist, the
    ///      authority resolved at settlement (D13), so a recovery during the auction is honoured.
    function test_Settle_FederatedNoBidsFollowsTheArtistsCurrentAuthority() public {
        MockMintTarget fed = _federated();
        uint256 saleId = auction.start(address(fed), "");
        address recovered = makeAddr("recoveredAuthority");
        fed.setCreatorNow(recovered);
        _end(saleId);
        vm.expectCall(address(resolver), abi.encodeCall(IEconomicsResolver.museum, ()), 0);
        auction.settle(saleId);
        assertEq(fed.ownerOf(1), recovered);
        assertEq(auction.auction(saleId).recipient, recovered);
        assertEq(fed.balanceOf(museum), 0, "never the museum");
    }

    /// @dev Owner decision 9, enforced in code: only 6529 Stream, the token the auction was
    ///      deployed with, sends its unbid works to the museum. Another token governance lists
    ///      sends them to its artist, on the federated path, and never reads the museum.
    function test_Settle_AnotherListedTokensUnbidWorkGoesToItsArtist() public {
        MockMintTarget other = _listedToken(ETH);
        assertTrue(auction.isTarget(address(other)));
        uint256 saleId = auction.start(address(other), "");
        uint256 streamSale = _start();
        _end(streamSale);
        // 6529 Stream's own unbid work still goes to the museum.
        auction.settle(streamSale);
        assertEq(stream.ownerOf(1), museum);

        vm.expectCall(address(resolver), abi.encodeCall(IEconomicsResolver.museum, ()), 0);
        auction.settle(saleId);
        assertEq(other.ownerOf(1), artist, "its artist");
        assertEq(other.balanceOf(museum), 0, "never the museum");
        assertEq(auction.auction(saleId).recipient, artist);
        assertEq(
            other.settled(1),
            other.settlementHash(PrimaryOutcome.UNBID, address(0), ETH, 0),
            "reported UNBID"
        );
    }

    /// @dev rc.2 review, CALLS I-2 (fix F5): delivery is derived from `ownerOf`, never from the
    ///      holder a listed token's settlement hook reports. A token that reports its unbid work
    ///      as taken by the artist without moving it still has the work delivered to the artist,
    ///      out of the auction's custody, and no reported holder can strand it.
    function test_Settle_AReportedHolderIsNotTrustedWithoutTheTransfer() public {
        HolderReportingTarget other = new HolderReportingTarget();
        other.setAdmittedMinter(address(auction), true);
        other.setTerms(_terms(ETH));
        vm.prank(successor);
        auction.setTarget(address(other), true);
        other.setReportedHolder(artist);
        uint256 saleId = auction.start(address(other), "");
        _end(saleId);

        auction.settle(saleId);
        assertEq(other.ownerOf(1), artist, "delivered to its artist");
        assertEq(auction.auction(saleId).recipient, artist);
        assertEq(auction.pendingDelivery(saleId), address(0), "nothing left pending");

        // A report naming someone else changes nothing either: the work is still the auction's.
        other.setReportedHolder(makeAddr("stranger"));
        uint256 second = auction.start(address(other), "");
        _end(second);
        auction.settle(second);
        assertEq(other.ownerOf(2), artist, "still its artist");
        assertEq(auction.auction(second).recipient, artist);
    }

    /// @dev A listed `OutcomeReportingTarget`, on ETH terms.
    function _outcomeToken() internal returns (OutcomeReportingTarget t) {
        t = new OutcomeReportingTarget();
        t.setAdmittedMinter(address(auction), true);
        t.setTerms(_terms(ETH));
        vm.prank(successor);
        auction.setTarget(address(t), true);
    }

    /// @dev Owner decision 20: when the token already records the work's primary sale as
    ///      settled (6529 Stream after `rescueToMuseum`), `settle` closes the sale with refunds
    ///      only: the standing bid is credited back, nothing is reported, paid, minted or
    ///      delivered, and the auction is SETTLED (`RescuedSaleClosed`).
    function test_Settle_ATokenReportingTheWorkSettledClosesWithARefundOnly() public {
        OutcomeReportingTarget t = _outcomeToken();
        uint256 saleId = auction.start(address(t), "");
        _bidEth(saleId, alice, 1 ether);
        _end(saleId);
        t.setOutcome(1, PrimaryOutcome.UNBID);
        uint256 sellerBefore = seller.balance;
        vm.expectCall(address(t), abi.encodeWithSelector(IMintTarget.settlePrimary.selector), 0);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(alice, ETH, saleId, 1 ether);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(saleId);
        auction.settle(saleId);
        assertEq(t.ownerOf(1), address(auction), "nothing delivered");
        assertEq(seller.balance, sellerBefore, "nothing paid");
        assertEq(auction.claimable(alice, ETH), 1 ether, "the bid credited back");
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertEq(auction.auction(saleId).bidder, address(0));
    }

    /// @dev The guard is the token's recorded outcome and nothing else: NONE, a short answer,
    ///      a reverting view and a token with no such view (`MockMintTarget`) all settle as
    ///      usual, reporting the outcome once and paying the seller.
    function test_Settle_OnlyARecordedOutcomeClosesWithRefunds() public {
        OutcomeReportingTarget t = _outcomeToken();
        OutcomeReportingTarget.Answer[3] memory answers = [
            OutcomeReportingTarget.Answer.FULL,
            OutcomeReportingTarget.Answer.SHORT,
            OutcomeReportingTarget.Answer.REVERT
        ];
        // Each of the three sales is reported to the token once.
        vm.expectCall(address(t), abi.encodeWithSelector(IMintTarget.settlePrimary.selector), 3);
        for (uint256 i; i < answers.length; ++i) {
            t.setAnswer(answers[i]);
            uint256 saleId = auction.start(address(t), "");
            _bidEth(saleId, alice, 1 ether);
            _end(saleId);
            uint256 sellerBefore = seller.balance;
            vm.recordLogs();
            auction.settle(saleId);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j; j < logs.length; ++j) {
                assertTrue(logs[j].topics[0] != IEnglishAuction.RescuedSaleClosed.selector);
            }
            assertGt(seller.balance, sellerBefore, "the seller is paid");
            assertEq(t.ownerOf(i + 1), alice, "delivered");
        }
        // A token that answers nothing at all.
        uint256 streamSale = _start();
        _bidEth(streamSale, bob, 1 ether);
        _end(streamSale);
        auction.settle(streamSale);
        assertEq(stream.ownerOf(1), bob);
    }

    /// @dev Owner decision 10 with decision 9: another listed token's 30-day freeze exit takes
    ///      its no-bid branch too, so its work goes to its artist, with the bid credited back.
    function test_Settle_AnotherListedTokensFreezeExitGoesToItsArtist() public {
        MockMintTarget other = _listedToken(address(usd));
        uint256 saleId = auction.start(address(other), "");
        usd.mint(alice, 100e18);
        vm.startPrank(alice);
        usd.approve(address(auction), 100e18);
        auction.bid(saleId, address(0), _direct(alice, 100e18));
        vm.stopPrank();
        allowlist.deprecateAsset(address(usd));
        vm.warp(block.timestamp + 30 days);
        auction.settle(saleId);
        assertEq(other.ownerOf(1), artist, "its artist, not the museum");
        assertEq(auction.claimable(alice, address(usd)), 100e18, "the bid is credited back");
        assertEq(usd.balanceOf(seller) + usd.balanceOf(network), 0, "nothing is paid");
        assertEq(
            other.settled(1),
            other.settlementHash(PrimaryOutcome.FROZEN_OUT, address(0), address(usd), 0),
            "reported FROZEN_OUT, no buyer and no price"
        );
    }

    /// @dev L-5 applies to every token but 6529 Stream: another listed token's artist, as the
    ///      token reports it now, claims its unbid work's pending delivery.
    function test_ClaimDelivery_AnotherListedTokensArtistClaims() public {
        HostileActor artistWallet = new HostileActor();
        artistWallet.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        MockMintTarget other = _listedToken(ETH);
        PrimaryTerms memory t = _terms(ETH);
        t.creator = address(artistWallet);
        other.setTerms(t);
        uint256 saleId = auction.start(address(other), "");
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.pendingDelivery(saleId), address(artistWallet));
        address recovered = makeAddr("recoveredAuthority");
        other.setCreatorNow(recovered);
        vm.prank(museum);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, museum);
        vm.prank(recovered);
        auction.claimDelivery(saleId, recovered);
        assertEq(other.ownerOf(1), recovered);
    }

    /// @dev IDENTITY-1, kept for federated works: with no active artist the no-bid settle
    ///      reverts and moves nothing.
    function test_Settle_FederatedNoBidsRefusesAnUnresolvedArtist() public {
        MockMintTarget fed = _federated();
        uint256 saleId = auction.start(address(fed), "");
        fed.setLockedCreator(1, address(0));
        _end(saleId);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(0)));
        auction.settle(saleId);
        assertEq(fed.ownerOf(1), address(auction));
    }

    function test_Settle_Erc20() public {
        uint256 saleId = _startUsd();
        _bidUsd(saleId, alice, 100e18);
        _end(saleId);
        auction.settle(saleId);
        assertEq(usd.balanceOf(seller), 75e18);
        assertEq(usd.balanceOf(network), 25e18);
        assertEq(usd.balanceOf(address(auction)), 0);
        assertEq(
            stream.settled(1),
            stream.settlementHash(PrimaryOutcome.SOLD, alice, address(usd), 100e18),
            "reported SOLD in the locked ERC-20"
        );
    }

    /// @dev Owner decision 17: the buyer of record is the bidder who paid, not the recipient
    ///      the bid named, which receives the work.
    function test_Settle_ReportsThePayerAsTheBuyer() public {
        uint256 saleId = _start();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        auction.bid{ value: 1 ether }(saleId, carol, _direct(alice, 1 ether));
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), carol, "the recipient receives the work");
        assertEq(
            stream.settled(1),
            stream.settlementHash(PrimaryOutcome.SOLD, alice, ETH, 1 ether),
            "the payer is the buyer"
        );
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

    /// @dev Owner decision 17: 6529 Stream moves an unsold work to the museum itself, with no
    ///      receiver callback, so a museum contract that would reject a safe transfer still
    ///      receives it, and nothing is left pending.
    function test_Settle_NoBidMuseumThatWouldRejectStillReceivesTheWork() public {
        HostileActor museumSafe = new HostileActor();
        museumSafe.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        resolver.setMuseumAccount(address(museumSafe));
        uint256 saleId = _start();
        _end(saleId);
        vm.recordLogs();
        auction.settle(saleId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IEnglishAuction.DeliveryPending.selector, "no pending");
        }
        assertEq(stream.ownerOf(_tokenIdOf(saleId)), address(museumSafe));
        assertEq(auction.pendingDelivery(saleId), address(0));
        assertEq(auction.auction(saleId).recipient, address(museumSafe));
    }

    /// @dev Owner decision 9: a federated artist that rejects the token gets a pending claim.
    function test_Settle_FederatedNoBidArtistThatRejectsGetsAPendingClaim() public {
        HostileActor artistWallet = new HostileActor();
        artistWallet.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        MockMintTarget fed = _federated();
        PrimaryTerms memory t = _terms(ETH);
        t.creator = address(artistWallet);
        fed.setTerms(t);
        uint256 saleId = auction.start(address(fed), "");
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.pendingDelivery(saleId), address(artistWallet));
        artistWallet.execute(
            address(auction), 0, abi.encodeCall(auction.claimDelivery, (saleId, artist))
        );
        assertEq(fed.ownerOf(1), artist);
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

    /// @dev A settle that delivers (here a federated work to its artist) refuses a caller who
    ///      cannot forward the delivery gas, and moves nothing.
    function test_Settle_RevertsWhenTheCallerStarvesDelivery() public {
        MockMintTarget fed = _federated();
        uint256 saleId = auction.start(address(fed), "");
        _end(saleId);
        vm.expectRevert(IEnglishAuction.DeliveryInsufficientGas.selector);
        auction.settle{ gas: 250_000 }(saleId);
        assertEq(fed.ownerOf(1), address(auction));
    }

    /// Regression: MONEY-1 (docs/security/internal-review-2026-10.md); the review of #57
    /// @dev A settler that cannot forward the payout frame's gas in full is refused, so it
    ///      cannot force a payout onto the credit route.
    function test_Settle_AStarvedSettleRevertsInsteadOfCrediting() public {
        uint256 saleId = _endedUsdSale();
        (bool ok, bytes memory reason) =
            address(auction).call{ gas: 900_000 }(abi.encodeCall(auction.settle, (saleId)));
        assertFalse(ok, "refused");
        assertEq(bytes4(reason), RevenuePayment.PaymentInsufficientGas.selector, "for want of gas");
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ENDED));
        assertEq(auction.claimable(seller, address(usd)), 0, "nothing credited");
        auction.settle(saleId);
        assertEq(usd.balanceOf(seller), 75e18, "paid directly with enough gas");
    }

    /// Regression: MONEY-1 (docs/security/internal-review-2026-10.md); the review of #57
    /// @dev The least call gas a keeper must give an ERC-20 settlement (about 1.1M: the payout
    ///      frame must be forwardable in full) against the gas it uses, and the same for ETH.
    function test_Settle_SettlerGasLimitVersusGasUsed() public {
        uint256 saleId = _endedUsdSale();
        (uint256 limit, uint256 used) = _leastSettleGas(saleId);
        emit log_named_uint("ERC-20 settle: least call gas", limit);
        emit log_named_uint("ERC-20 settle: gas used", used);
        assertLe(limit, 1_200_000);
        assertLt(used, 300_000);
        stream.setTerms(_terms(ETH));
        uint256 ethSale = _start();
        _bidEth(ethSale, bob, 1 ether);
        vm.warp(auction.auction(ethSale).endTime);
        (limit, used) = _leastSettleGas(ethSale);
        emit log_named_uint("ETH settle: least call gas", limit);
        emit log_named_uint("ETH settle: gas used", used);
        assertLe(limit, 500_000);
    }

    function _endedUsdSale() internal returns (uint256 saleId) {
        saleId = _startUsd();
        _bidUsd(saleId, alice, 100e18);
        vm.warp(auction.auction(saleId).endTime);
    }

    function _leastSettleGas(uint256 saleId) internal returns (uint256 lo, uint256 used) {
        uint256 hi = 5_000_000;
        lo = 100_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(auction).call{ gas: mid }(abi.encodeCall(auction.settle, (saleId)));
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        lo = hi;
        uint256 before = gasleft();
        auction.settle(saleId);
        used = before - gasleft();
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

    /// @dev D140, the gap PLAN section 1.9 found, now closed by Stream (owner decision 17): an
    ///      unbid canonical work is never pending, so neither its artist (the recorded authority
    ///      or the current one) nor anyone else, the museum included, has anything to claim.
    function test_ClaimDelivery_NoBidsNothingToClaim() public {
        uint256 saleId = _start();
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), museum);
        address recovered = makeAddr("recoveredAuthority");
        stream.setCreatorNow(recovered);
        address[4] memory refused = [artist, recovered, alice, museum];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(refused[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId)
            );
            auction.claimDelivery(saleId, refused[i]);
        }
    }

    /// @dev ADR 0005: the museum named at settlement holds the work; a later governed change of
    ///      museum moves nothing, and nobody can claim it.
    function test_ClaimDelivery_TheMuseumNamedAtSettlementKeepsTheWork() public {
        address first = makeAddr("firstMuseum");
        resolver.setMuseumAccount(first);
        uint256 saleId = _start();
        _end(saleId);
        auction.settle(saleId);
        address next = makeAddr("nextMuseum");
        resolver.setMuseumAccount(next);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, next);
        assertEq(stream.ownerOf(1), first);
        assertEq(auction.auction(saleId).recipient, first);
    }

    /// @dev Owner decision 9: with no bids on a federated work only its artist may claim a
    ///      pending delivery, never the museum.
    function test_ClaimDelivery_FederatedNoBidsOnlyTheArtist() public {
        HostileActor artistWallet = new HostileActor();
        artistWallet.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        MockMintTarget fed = _federated();
        PrimaryTerms memory t = _terms(ETH);
        t.creator = address(artistWallet);
        fed.setTerms(t);
        uint256 saleId = auction.start(address(fed), "");
        _end(saleId);
        auction.settle(saleId);
        address[2] memory refused = [alice, museum];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(refused[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId)
            );
            auction.claimDelivery(saleId, refused[i]);
        }
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

    /// Regression: L-5 (PoC N2, inverted) in the review of #21
    /// @dev After a recovery, a federated artist's current authority claims a no-bid pending
    ///      delivery; an outsider still cannot. Since ADR 0005 (D140) this holds for federated
    ///      works only: a canonical work's no-bid delivery is the museum's.
    function test_ClaimDelivery_ANoBidClaimFollowsTheCurrentAuthority() public {
        HostileActor oldWallet = new HostileActor();
        oldWallet.configure(HostileActor.Behaviour.ACCEPT, HostileActor.Behaviour.REVERT);
        MockMintTarget fed = _federated();
        PrimaryTerms memory t = _terms(ETH);
        t.creator = address(oldWallet);
        fed.setTerms(t);
        uint256 saleId = auction.start(address(fed), "");
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.pendingDelivery(saleId), address(oldWallet));
        address recovered = makeAddr("recoveredAuthority");
        fed.setCreatorNow(recovered);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId));
        auction.claimDelivery(saleId, alice);
        vm.prank(recovered);
        auction.claimDelivery(saleId, recovered);
        assertEq(fed.ownerOf(1), recovered);
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

    /// Regression: MONEY-1 (docs/security/internal-review-2026-10.md); L5 in the review of #57
    /// @dev `claimFor` refuses ETH: an outbid bidder's ETH refund is claimed by the bidder, to the
    ///      address it chooses, and nobody can push it into a contract that cannot move it on.
    function test_ClaimFor_RefusesEth() public {
        uint256 saleId = _start();
        ForwardingBidder fb = new ForwardingBidder();
        vm.deal(address(this), 1 ether);
        fb.bid{ value: 1 ether }(auction, saleId);
        _bidEth(saleId, alice, 2 ether);
        vm.prank(makeAddr("griefer"));
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidAsset.selector, ETH));
        auction.claimFor(address(fb), ETH);
        address treasury = makeAddr("treasury");
        fb.claimTo(auction, treasury);
        assertEq(treasury.balance, 1 ether);
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

    // ------------------------------------------------------------------- 96-bit arithmetic

    /// @dev The auction's fee and increment formulas, exact at 96 bits: the fee rounds down
    ///      and the step rounds up, as `Math.mulDiv` does.
    function testFuzz_FeeMatchesMulDivFloor(uint96 price, uint32 share) public pure {
        share = uint32(bound(share, 0, 100_000));
        uint256 exact = uint256(price) * share / 100_000;
        assertEq(exact, Math.mulDiv(price, share, 100_000));
        assertLe(exact, price);
    }

    function testFuzz_StepMatchesMulDivCeil(uint96 high, uint24 share) public pure {
        share = uint24(bound(share, 0, 100_000));
        assertEq(
            (uint256(high) * share + 100_000 - 1) / 100_000,
            Math.mulDiv(high, share, 100_000, Math.Rounding.Ceil)
        );
    }

    function test_ArithmeticEdgeValues() public pure {
        uint96 m = type(uint96).max;
        assertEq(uint256(m) * 100_000 / 100_000, Math.mulDiv(m, 100_000, 100_000));
        assertEq(
            (uint256(m) * 100_000 + 99_999) / 100_000,
            Math.mulDiv(m, 100_000, 100_000, Math.Rounding.Ceil)
        );
        assertEq((uint256(1) * 1 + 99_999) / 100_000, 1);
        assertEq((uint256(0) * 5_000 + 99_999) / 100_000, 0);
    }
}

/// @dev A contract with code that was never admitted to the allowlist.
contract PermitTokenStub { }
