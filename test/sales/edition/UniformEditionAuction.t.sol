// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionStorage } from "src/interfaces/IUniformEditionAuctionStorage.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { ItemKind, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { StepLadder } from "src/interfaces/types/StepLadder.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { MockFederationRegistry } from "../../mocks/sales/SaleMocks.sol";
import { EthRefusingHolder } from "../../mocks/sales/EditionAuctionMocks.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice Unit tests of `UniformEditionAuction` on mocks: every entry point's happy path,
///         negative paths and events, the coupling with the 1/1 (D140, D141), the soft close and
///         its backstop, the dispute window, void on cancel, zero bids, the cap with FIFO and
///         holes, raises, payouts and claims.
contract UniformEditionAuctionTest is EditionAuctionBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    // ================================================================== construction

    function test_Constructor_WiresAndCreatesLens() public view {
        assertEq(auction.editions(), address(editions));
        assertEq(auction.stream(), address(stream));
        assertEq(auction.englishAuction(), address(english));
        assertEq(auction.escrow(), address(escrow));
        assertEq(lens.adapter(), address(auction));
        assertTrue(auction.lens().code.length != 0);
        _assertConfig(auction.config(), defaultConfig());
        assertEq(auction.saleKind(), SaleKind.UNIFORM_AUCTION);
        assertEq(auction.PAYOUT_GAS(), 100_000);
    }

    function test_Constructor_RejectsBadDependencies() public {
        IUniformEditionAuction.AuctionConfig memory c = defaultConfig();
        address notContract = makeAddr("notContract");
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, notContract));
        new UniformEditionAuction(
            address(manager), notContract, address(editions), address(english), c
        );
        // Editions must answer IEditions.
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(english))
        );
        new UniformEditionAuction(
            address(manager), address(escrow), address(english), address(english), c
        );
        // The English auction must answer IEnglishAuction.
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(editions))
        );
        new UniformEditionAuction(
            address(manager), address(escrow), address(editions), address(editions), c
        );
        // The master read from Editions must answer IStream.
        editions.setStream(address(english));
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(english))
        );
        new UniformEditionAuction(
            address(manager), address(escrow), address(editions), address(english), c
        );
        editions.setStream(address(stream));
        // An invalid initial configuration.
        c.marginShare = 50_001;
        vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
        new UniformEditionAuction(
            address(manager), address(escrow), address(editions), address(english), c
        );
    }

    function test_SupportsInterface() public view {
        assertEq(type(IUniformEditionAuction).interfaceId, bytes4(0x69e7405b));
        assertTrue(auction.supportsInterface(type(IUniformEditionAuction).interfaceId));
        assertTrue(auction.supportsInterface(type(ISaleAdapter).interfaceId));
        assertTrue(auction.supportsInterface(type(IERC165).interfaceId));
        assertFalse(auction.supportsInterface(0xffffffff));
        assertFalse(auction.supportsInterface(type(IUniformEditionAuctionStorage).interfaceId));
    }

    /// @dev The adapter does not inherit the frozen interface (its views are the lens's), so the
    ///      compiler cannot check that its write functions match: this does, selector by
    ///      selector.
    function test_Selectors_MatchTheFrozenInterface() public view {
        assertEq(UniformEditionAuction.open.selector, IUniformEditionAuction.open.selector);
        assertEq(UniformEditionAuction.bid.selector, IUniformEditionAuction.bid.selector);
        assertEq(UniformEditionAuction.raise.selector, IUniformEditionAuction.raise.selector);
        assertEq(
            UniformEditionAuction.withdrawBid.selector, IUniformEditionAuction.withdrawBid.selector
        );
        assertEq(UniformEditionAuction.settle.selector, IUniformEditionAuction.settle.selector);
        assertEq(UniformEditionAuction.claimBid.selector, IUniformEditionAuction.claimBid.selector);
        assertEq(
            UniformEditionAuction.claimBidFor.selector, IUniformEditionAuction.claimBidFor.selector
        );
        assertEq(
            UniformEditionAuction.setConfig.selector, IUniformEditionAuction.setConfig.selector
        );
        assertEq(UniformEditionAuction.config.selector, IUniformEditionAuction.config.selector);
        assertEq(UniformEditionAuction.saleIdOf.selector, IUniformEditionAuction.saleIdOf.selector);
        assertEq(auction.englishAuction.selector, IUniformEditionAuction.englishAuction.selector);
        assertEq(auction.escrow.selector, IUniformEditionAuction.escrow.selector);
    }

    function test_Fallback_RefusesEthAndUnknownCalls() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(auction).call{ value: 1 }("");
        assertFalse(ok, "plain ETH refused");
        (ok,) = address(auction).call(abi.encodeWithSignature("nothingHere(uint256)", 1));
        assertFalse(ok, "unknown selector reverts in the lens");
        // A view through the fallback works and bubbles the lens's revert.
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.UnknownAuction.selector, 9));
        ua.auction(9);
    }

    /// @dev The adapter prices a bid from its own byte table of the mantissas. On a 512-step
    ///      ladder of each shape, the first two decades (every table entry the shape uses, and a
    ///      decade carry) and the top step cost exactly `StepLadder.price`, read from the
    ///      `IncorrectPayment` a zero-value bid reverts with.
    function test_StepPrices_MatchStepLadder() public {
        uint16[4] memory perDecade = [uint16(24), 48, 96, 192];
        uint96[4] memory base = [uint96(1e14), 1e14, 1e14, 1e17];
        for (uint256 n; n < 4; ++n) {
            IUniformEditionAuction.AuctionConfig memory c = defaultConfig();
            (c.basePrice, c.stepsPerDecade, c.stepCount) = (base[n], perDecade[n], 512);
            _setConfig(c);
            uint256 id = ID + 1 + n;
            english.set(
                address(stream),
                id,
                IEnglishAuction.AuctionState.ACTIVE,
                uint64(block.timestamp + 1 days)
            );
            uint256 saleId = _openId(id, 0);
            for (uint256 step; step < 512; step = step + 1 == 2 * perDecade[n] ? 511 : step + 1) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IUniformEditionAuction.IncorrectPayment.selector,
                        StepLadder.price(base[n], perDecade[n], step),
                        0
                    )
                );
                auction.bid(saleId, step, 1);
            }
        }
    }

    // ================================================================== governance

    function test_SetConfig_CompareAndSetAndLocksPerSale() public {
        uint256 saleId = _open(0);
        IUniformEditionAuction.AuctionConfig memory next = defaultConfig();
        next.marginShare = 30_000;
        next.closeOffset = 1 hours;
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.ConfigSet(defaultConfig(), next);
        auction.setConfig(defaultConfig(), next);
        _assertConfig(auction.config(), next);
        // The open sale keeps its locked parameters.
        _assertConfig(ua.auction(saleId).terms, defaultConfig());
        // A stale expectation reverts.
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setConfig(defaultConfig(), next);
        // A sale opened now locks the new ones.
        english.set(
            address(stream),
            8,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        uint256 second = _openId(8, 0);
        _assertConfig(ua.auction(second).terms, next);
    }

    function test_SetConfig_Bounds() public {
        IUniformEditionAuction.AuctionConfig memory c;
        c = defaultConfig();
        c.basePrice = 1e12 - 1;
        _expectInvalidConfig(c);
        c = defaultConfig();
        c.basePrice = 1e17 + 1;
        _expectInvalidConfig(c);
        c = defaultConfig();
        c.stepsPerDecade = 12;
        _expectInvalidConfig(c);
        c = defaultConfig();
        c.stepCount = 63;
        _expectInvalidConfig(c);
        c = defaultConfig();
        c.stepCount = 513;
        _expectInvalidConfig(c);
        // A top step below 10 ETH: 0.0001 ETH over 240 steps of 48 per decade tops at 9.53 ETH.
        c = defaultConfig();
        c.stepCount = 240;
        _expectInvalidConfig(c);
        c = defaultConfig();
        c.marginShare = 50_001;
        _expectInvalidConfig(c);
        c = defaultConfig();
        c.closeOffset = 1 days + 1;
        _expectInvalidConfig(c);
        c = defaultConfig();
        c.softWindow = 59;
        _expectInvalidConfig(c);
        c = defaultConfig();
        c.softWindow = 1 hours + 1;
        _expectInvalidConfig(c);
        c = defaultConfig();
        c.maxExtension = 1 hours - 1;
        _expectInvalidConfig(c);
        c = defaultConfig();
        c.maxExtension = 7 days + 1;
        _expectInvalidConfig(c);
        // The edges are accepted.
        c = IUniformEditionAuction.AuctionConfig(1e17, 24, 64, 50_000, 1 days, 1 hours, 7 days);
        _setConfig(c);
        c = IUniformEditionAuction.AuctionConfig(1e12, 192, 512, 0, 0, 1 minutes, 1 hours);
        // 1e12 over 512 steps of 192 per decade tops below 10 ETH: refused.
        _expectInvalidConfig(c);
        c.stepsPerDecade = 24;
        _setConfig(c);
        _assertConfig(auction.config(), c);
    }

    function test_Governance_IsRestricted() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setConfig(defaultConfig(), defaultConfig());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.unpause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setTarget(address(editions), false);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setFederationRegistry(address(0), address(0));
        vm.stopPrank();
    }

    function test_Pause_BlocksOpensOnly() public {
        uint256 saleId = _open(0);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Paused(address(this));
        auction.pause();
        assertTrue(auction.paused());
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        auction.pause();
        // Running sales bid, settle and claim.
        _bid(saleId, alice, 10, 2);
        PackageItem memory item = _item(8, 0);
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        auction.open(address(editions), 8, abi.encode(item));
        // GOV-5: not before 48 hours after the pause.
        uint256 allowedAt = block.timestamp + Roles.STANDARD;
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnpauseTooEarly.selector, allowedAt));
        auction.unpause();
        vm.warp(allowedAt);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Unpaused(address(this));
        auction.unpause();
        assertFalse(auction.paused());
        vm.expectRevert(ISaleAdapter.NotPaused.selector);
        auction.unpause();
    }

    function test_SetTarget_OnlyEditions() public {
        assertTrue(auction.isTarget(address(editions)));
        assertFalse(auction.isTarget(address(stream)));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(stream))
        );
        auction.setTarget(address(stream), true);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.TargetSet(address(editions), false);
        auction.setTarget(address(editions), false);
        assertFalse(auction.isTarget(address(editions)));
        PackageItem memory item = _item(ID, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(editions))
        );
        auction.open(address(editions), ID, abi.encode(item));
    }

    function test_SetFederationRegistry() public {
        MockFederationRegistry registry = new MockFederationRegistry();
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setFederationRegistry(address(1), address(registry));
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(editions))
        );
        auction.setFederationRegistry(address(0), address(editions));
        vm.expectEmit(address(auction));
        emit ISaleAdapter.FederationRegistrySet(address(0), address(registry));
        auction.setFederationRegistry(address(0), address(registry));
        assertEq(auction.federationRegistry(), address(registry));
        assertEq(auction.federationRegistryCodeHash(), address(registry).codehash);
        auction.setFederationRegistry(address(registry), address(0));
        assertEq(auction.federationRegistry(), address(0));
        assertEq(auction.federationRegistryCodeHash(), bytes32(0));
    }

    // ================================================================== open

    function test_Open_LocksTermsAndEmits() public {
        PackageItem memory item = _item(ID, 60);
        uint256 saleId = auction.saleIdOf(address(editions), ID);
        uint64 closeAt = uint64(block.timestamp + 1 days + 15 minutes);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.SaleStarted(
            saleId,
            address(editions),
            ID,
            SaleKind.UNIFORM_AUCTION,
            CURRENCY_ETH,
            1e14,
            uint64(block.timestamp),
            closeAt
        );
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionOpened(
            saleId, address(editions), ID, address(stream), 60, defaultConfig(), closeAt
        );
        vm.prank(opener);
        assertEq(auction.open(address(editions), ID, abi.encode(item)), saleId);
        IUniformEditionAuction.Auction memory a = ua.auction(saleId);
        assertEq(a.token, address(editions));
        assertEq(a.id, ID);
        assertEq(a.master, address(stream));
        assertEq(a.oneOfOneSaleId, english.saleIdOf(address(stream), ID));
        assertEq(uint8(a.status), uint8(IUniformEditionAuction.AuctionStatus.OPEN));
        assertEq(a.maxCount, 60);
        assertEq(a.seller, seller);
        assertEq(a.feeRecipient, networkFee);
        assertEq(a.feeShare, FEE_SHARE);
        assertEq(a.openedAt, block.timestamp);
        assertEq(a.bidCount, 0);
        assertEq(a.liveUnits, 0);
        assertEq(saleId, uint256(keccak256(abi.encode(address(editions), ID))));
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.AuctionExists.selector, saleId)
        );
        auction.open(address(editions), ID, abi.encode(item));
    }

    function test_Open_ChecksTokenAndId() public {
        PackageItem memory item = _item(ID, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(stream))
        );
        auction.open(address(stream), ID, abi.encode(item));
        uint256 big = uint256(1) << 32;
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), big)
        );
        auction.open(address(editions), big, abi.encode(item));
    }

    function test_Open_NeedsALiveOneOfOne() public {
        PackageItem memory item = _item(9, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.NoOneOfOneAuction.selector, address(stream), 9
            )
        );
        auction.open(address(editions), 9, abi.encode(item));
        english.set(
            address(stream), 9, IEnglishAuction.AuctionState.CANCELLED, uint64(block.timestamp)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.NoOneOfOneAuction.selector, address(stream), 9
            )
        );
        auction.open(address(editions), 9, abi.encode(item));
    }

    function test_Open_ChecksTheItem() public {
        PackageItem memory item = _item(ID, 0);
        bytes memory terms =
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), ID);
        // Another item than the stored one.
        PackageItem memory other = _item(ID, 0);
        other.contentHash = keccak256("another");
        vm.expectRevert(terms);
        auction.open(address(editions), ID, abi.encode(other));
        // Not an EDITION_MASTER.
        stream.setWork(ID, WorksHashing.itemHash(item), ItemKind.ORIGINAL);
        vm.expectRevert(terms);
        auction.open(address(editions), ID, abi.encode(item));
        // Another sale kind, a currency other than ETH, params.
        item = _item(ID, 0);
        item.edition.saleKind = SaleKind.FIXED_PRICE;
        stream.setWork(ID, WorksHashing.itemHash(item), ItemKind.EDITION_MASTER);
        vm.expectRevert(terms);
        auction.open(address(editions), ID, abi.encode(item));
        item = _item(ID, 0);
        item.edition.currency = address(0xE20);
        stream.setWork(ID, WorksHashing.itemHash(item), ItemKind.EDITION_MASTER);
        vm.expectRevert(terms);
        auction.open(address(editions), ID, abi.encode(item));
        item = _item(ID, 0);
        item.edition.params = hex"01";
        stream.setWork(ID, WorksHashing.itemHash(item), ItemKind.EDITION_MASTER);
        vm.expectRevert(terms);
        auction.open(address(editions), ID, abi.encode(item));
        // Malformed data.
        vm.expectRevert();
        auction.open(address(editions), ID, hex"1234");
    }

    function test_Open_ChecksThePayout() public {
        PackageItem memory item = _item(ID, 0);
        bytes memory data = abi.encode(item);
        bytes memory terms =
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), ID);
        economics.set(address(0), networkFee, FEE_SHARE);
        vm.expectRevert(terms);
        auction.open(address(editions), ID, data);
        economics.set(address(escrow), networkFee, FEE_SHARE);
        vm.expectRevert(terms);
        auction.open(address(editions), ID, data);
        economics.set(seller, address(0), FEE_SHARE);
        vm.expectRevert(terms);
        auction.open(address(editions), ID, data);
        economics.set(seller, address(escrow), FEE_SHARE);
        vm.expectRevert(terms);
        auction.open(address(editions), ID, data);
        economics.set(seller, networkFee, 100_001);
        vm.expectRevert(terms);
        auction.open(address(editions), ID, data);
        economics.setRefuse(true);
        vm.expectRevert(bytes("payees"));
        auction.open(address(editions), ID, data);
        economics.setRefuse(false);
        // A zero fee needs no recipient.
        economics.set(seller, address(0), 0);
        uint256 saleId = auction.open(address(editions), ID, data);
        IUniformEditionAuction.Auction memory a = ua.auction(saleId);
        assertEq(a.feeRecipient, address(0));
        assertEq(a.feeShare, 0);
    }

    function test_Open_InternsTheFeeRecipient() public {
        _open(0);
        english.set(
            address(stream),
            8,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        uint256 second = _openId(8, 0);
        assertEq(ua.auction(second).feeRecipient, networkFee);
        assertEq(
            auction.storageWord(IUniformEditionAuctionStorage.Space.FEE_RECIPIENT, 0, 1),
            uint160(networkFee)
        );
        assertEq(auction.storageWord(IUniformEditionAuctionStorage.Space.FEE_RECIPIENT, 0, 2), 0);
    }

    function test_Open_Timing() public {
        PackageItem memory item = _item(ID, 0);
        // Closed once the 1/1's end plus the offset has passed.
        uint256 closeAt = block.timestamp + 1 days + 15 minutes;
        vm.warp(closeAt);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.BiddingClosed.selector,
                auction.saleIdOf(address(editions), ID),
                uint64(closeAt)
            )
        );
        auction.open(address(editions), ID, abi.encode(item));
        // A 1/1 paused for a dispute keeps the edition sale openable.
        english.set(
            address(stream), ID, IEnglishAuction.AuctionState.PAUSED, uint64(closeAt - 15 minutes)
        );
        auction.open(address(editions), ID, abi.encode(item));
    }

    function test_Open_AfterTheOneOfOneSettled_BeforeTheClose() public {
        uint64 end = uint64(block.timestamp + 1 days);
        vm.warp(end + 1);
        english.set(address(stream), ID, IEnglishAuction.AuctionState.SETTLED, end);
        uint256 saleId = _open(0);
        _bid(saleId, alice, 0, 1);
    }

    // ================================================================== bid

    function test_Bid_EscrowsExactlyAndEmits() public {
        uint256 saleId = _open(0);
        uint256 amount = 3 * _price(saleId, 130);
        assertEq(_price(saleId, 130), 0.0511 ether);
        vm.deal(alice, amount);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.BidPlaced(
            saleId, 1, alice, 130, 3, 0, uint64(block.timestamp + 1 days + 15 minutes)
        );
        vm.prank(alice);
        assertEq(auction.bid{ value: amount }(saleId, 130, 3), 1);
        assertEq(address(auction).balance, amount);
        IUniformEditionAuction.Bid memory b = ua.bidOf(saleId, 1);
        assertEq(b.bidder, alice);
        assertEq(b.step, 130);
        assertEq(b.quantity, 3);
        assertEq(b.position, 0);
        IUniformEditionAuction.Auction memory a = ua.auction(saleId);
        assertEq(a.bidCount, 1);
        assertEq(a.liveUnits, 3);
        assertEq(a.lowStep, 130);
        assertEq(a.highStep, 130);
        // The minimum bid: one unit at the base step.
        assertEq(_bid(saleId, bob, 0, 1), 2);
        a = ua.auction(saleId);
        assertEq(a.lowStep, 0);
        assertEq(a.highStep, 130);
        _bid(saleId, carol, 335, 1);
        assertEq(ua.auction(saleId).highStep, 335);
    }

    function test_Bid_Rejects() public {
        uint256 saleId = _open(0);
        uint256 price = _price(saleId, 10);
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.IncorrectPayment.selector, 2 * price, price
            )
        );
        auction.bid{ value: price }(saleId, 10, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.IncorrectPayment.selector, price, price + 1
            )
        );
        auction.bid{ value: price + 1 }(saleId, 10, 1);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.InvalidStep.selector, 336));
        auction.bid{ value: price }(saleId, 336, 1);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.InvalidQuantity.selector, 0));
        auction.bid(saleId, 10, 0);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.UnknownAuction.selector, 5));
        auction.bid(5, 10, 1);
        vm.stopPrank();
    }

    function test_Bid_UnitsStayBelow2To32() public {
        uint256 saleId = _open(0);
        uint256 max = type(uint32).max;
        _bid(saleId, alice, 0, max - 1);
        uint256 amount = 2 * _price(saleId, 0);
        vm.deal(bob, amount);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.InvalidQuantity.selector, 2));
        auction.bid{ value: amount }(saleId, 0, 2);
        _bid(saleId, bob, 0, 1);
        assertEq(ua.auction(saleId).liveUnits, max);
    }

    /// @dev In a capped sale a bid's queue position counts every unit that ever entered its step,
    ///      withdrawn ones included, so the step's entered units also stay below 2^32: a bid
    ///      that would pass that limit is refused, though the sale's live units are low, and the
    ///      queue stays exact. The departure log's 32-bit fields therefore cannot overflow.
    function test_Bid_QueuePositionsStayBelow2To32() public {
        uint256 saleId = _open(10);
        uint256 max = type(uint32).max;
        _bid(saleId, alice, 5, max - 1);
        _withdrawDuringPause(saleId, 1);
        assertEq(ua.auction(saleId).liveUnits, 0);
        uint256 amount = 2 * _price(saleId, 5);
        vm.deal(bob, amount);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.InvalidQuantity.selector, 2));
        auction.bid{ value: amount }(saleId, 5, 2);
        // One unit still fits, at the last position; another step is unaffected.
        uint256 last = _bid(saleId, bob, 5, 1);
        assertEq(ua.bidOf(saleId, last).position, max - 1);
        _bid(saleId, carol, 6, 2);
        IUniformEditionAuction.Departure[] memory d = ua.departures(saleId, 5);
        assertEq(d.length, 1);
        assertEq(d[0].position, 0);
        assertEq(d[0].quantity, max - 1);
    }

    function test_Bid_ClosedAfterTheEnd() public {
        uint256 saleId = _open(0);
        uint64 closeAt = uint64(block.timestamp + 1 days + 15 minutes);
        vm.warp(closeAt - 1);
        _bid(saleId, alice, 1, 1);
        // That bid was in the window: the close moved to 5 minutes after it.
        uint64 endTime = uint64(closeAt - 1 + 5 minutes);
        assertEq(ua.endTimes(saleId).endTime, endTime);
        vm.warp(endTime);
        uint256 price = _price(saleId, 1);
        vm.deal(bob, price);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.BiddingClosed.selector, saleId, endTime)
        );
        auction.bid{ value: price }(saleId, 1, 1);
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.CLOSED)
        );
    }

    function test_SoftClose_ExtendsOnlyInTheWindow() public {
        uint256 saleId = _open(0);
        uint64 closeAt = uint64(block.timestamp + 1 days + 15 minutes);
        // Outside the window: no extension.
        vm.warp(closeAt - 5 minutes - 1);
        _bid(saleId, alice, 1, 1);
        assertEq(ua.endTimes(saleId).softEnd, 0);
        assertEq(ua.endTimes(saleId).endTime, closeAt);
        // At the window's edge: the close moves to 5 minutes after the bid.
        vm.warp(closeAt - 5 minutes + 1);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.BidPlaced(saleId, 2, bob, 2, 1, 0, closeAt + 1);
        _bid(saleId, bob, 2, 1);
        assertEq(ua.endTimes(saleId).softEnd, closeAt + 1);
        // A raise in the window extends too.
        vm.warp(closeAt);
        _raise(saleId, 1, 3);
        assertEq(ua.endTimes(saleId).endTime, closeAt + 5 minutes);
    }

    function test_SoftClose_Backstop() public {
        uint256 saleId = _open(0);
        uint256 closeAt = block.timestamp + 1 days + 15 minutes;
        uint256 backstop = closeAt + 1 days;
        // A dust bid every few minutes keeps the sale open, but never past the backstop.
        vm.warp(closeAt - 1);
        uint256 t = closeAt - 1;
        while (t + 4 minutes < backstop) {
            _bid(saleId, alice, 0, 1);
            t += 4 minutes;
            vm.warp(t);
        }
        _bid(saleId, alice, 0, 1);
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(e.backstop, backstop);
        assertEq(e.endTime, backstop, "capped at the backstop");
        vm.warp(backstop);
        uint256 price = _price(saleId, 0);
        vm.deal(bob, price);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.BiddingClosed.selector, saleId, uint64(backstop)
            )
        );
        auction.bid{ value: price }(saleId, 0, 1);
    }

    function test_Coupling_FollowsTheOneOfOneAntiSnipe() public {
        uint256 saleId = _open(0);
        uint64 end = uint64(block.timestamp + 1 days);
        // The 1/1 is extended by its anti-snipe: the edition close follows it.
        english.set(address(stream), ID, IEnglishAuction.AuctionState.ACTIVE, end + 10 minutes);
        vm.warp(end + 15 minutes);
        // Past the cached close, the bid reads the 1/1 live and is accepted.
        _bid(saleId, alice, 5, 1);
        assertEq(ua.endTimes(saleId).closeAt, end + 25 minutes);
        assertEq(ua.endTimes(saleId).oneOfOneEnd, end + 10 minutes);
        // The cached end was recorded.
        IUniformEditionAuctionStorage.SaleWord memory w = _saleWord(saleId);
        assertEq(w.oneOfOneEnd, end + 10 minutes);
        vm.warp(end + 25 minutes + 5 minutes);
        uint256 price = _price(saleId, 5);
        vm.deal(bob, price);
        vm.prank(bob);
        vm.expectRevert();
        auction.bid{ value: price }(saleId, 5, 1);
    }

    function test_Coupling_PausedOneOfOneAcceptsBidsWithoutExtending() public {
        uint256 saleId = _open(0);
        uint64 end = uint64(block.timestamp + 1 days);
        english.set(address(stream), ID, IEnglishAuction.AuctionState.PAUSED, end);
        vm.warp(end + 3 days);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.BidPlaced(saleId, 1, alice, 7, 2, 0, type(uint64).max);
        _bid(saleId, alice, 7, 2);
        _raise(saleId, 1, 9);
        assertEq(_saleWord(saleId).softEnd, 0, "a pause never extends");
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertTrue(e.biddingOpen);
        assertTrue(e.withdrawalsOpen);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.PAUSED));
        // Settlement waits for the 1/1.
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        auction.settle(saleId, new uint256[](0));
        // The 1/1 resumes for at least its duration; the edition close follows.
        uint64 resumed = uint64(block.timestamp + 1 days);
        english.set(address(stream), ID, IEnglishAuction.AuctionState.ACTIVE, resumed);
        assertEq(ua.endTimes(saleId).endTime, resumed + 15 minutes);
        _bid(saleId, bob, 7, 1);
    }

    /// @dev The cached 1/1 end is read again only within `softWindow` of the close: a bid placed
    ///      earlier after a cancel is accepted (and refunded in full when anyone voids the sale);
    ///      near the close, or once voided, no bid is.
    function test_Coupling_CancelledOneOfOneRefusesBidsNearTheClose() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 7, 2);
        uint64 end = uint64(block.timestamp + 1 days);
        english.set(address(stream), ID, IEnglishAuction.AuctionState.CANCELLED, end);
        // Far from the close: not read, accepted.
        _bid(saleId, carol, 7, 1);
        // Within the soft window of the cached close: read, refused.
        vm.warp(end + 10 minutes);
        uint256 price = _price(saleId, 7);
        vm.deal(bob, price);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.BiddingClosed.selector, saleId, uint64(end + 15 minutes)
            )
        );
        auction.bid{ value: price }(saleId, 7, 1);
        assertFalse(ua.endTimes(saleId).biddingOpen);
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.CLOSED)
        );
        // Voided: both bids come back in full.
        auction.settle(saleId, new uint256[](0));
        assertEq(_claimAll(saleId), 0);
        assertEq(alice.balance, 2 * price);
        assertEq(carol.balance, price);
        _assertConserved();
    }

    // ================================================================== raise

    function test_Raise_PaysTheDifferenceAndMoves() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 4);
        uint256 paid = 4 * (_price(saleId, 130) - _price(saleId, 100));
        vm.deal(alice, paid);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.BidRaised(
            saleId, 1, alice, 100, 130, 0, paid, uint64(block.timestamp + 1 days + 15 minutes)
        );
        vm.prank(alice);
        auction.raise{ value: paid }(saleId, 1, 130);
        assertEq(ua.bidOf(saleId, 1).step, 130);
        (uint256 low, uint256[] memory units) = ua.stepTotals(saleId);
        assertEq(low, 100);
        assertEq(units[0], 0);
        assertEq(units[30], 4);
        assertEq(ua.auction(saleId).highStep, 130);
    }

    function test_Raise_Rejects() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 4);
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.NotBidder.selector, bob));
        auction.raise(saleId, 1, 101);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.InvalidStep.selector, 100));
        auction.raise(saleId, 1, 100);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.InvalidStep.selector, 99));
        auction.raise(saleId, 1, 99);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.InvalidStep.selector, 336));
        auction.raise(saleId, 1, 336);
        uint256 paid = 4 * (_price(saleId, 101) - _price(saleId, 100));
        vm.deal(alice, paid + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.IncorrectPayment.selector, paid, paid + 1)
        );
        auction.raise{ value: paid + 1 }(saleId, 1, 101);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.UnknownBid.selector, saleId, 2)
        );
        auction.raise(saleId, 2, 101);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        vm.deal(alice, paid);
        vm.prank(alice);
        vm.expectRevert();
        auction.raise{ value: paid }(saleId, 1, 101);
    }

    function test_Raise_RejoinsAtTheBackInACappedSale() public {
        uint256 saleId = _open(10);
        _bid(saleId, alice, 50, 3); // position 0 at 50
        _bid(saleId, bob, 60, 2); // position 0 at 60
        _bid(saleId, carol, 50, 4); // position 3 at 50
        _raise(saleId, 1, 60); // alice leaves 50 (hole [0, 3)), joins 60 at position 2
        assertEq(ua.bidOf(saleId, 1).position, 2);
        IUniformEditionAuction.Departure[] memory d = ua.departures(saleId, 50);
        assertEq(d.length, 1);
        assertEq(d[0].position, 0);
        assertEq(d[0].quantity, 3);
        // A new bid at 50 enters after every unit that ever entered it.
        uint256 next = _bid(saleId, alice, 50, 1);
        assertEq(ua.bidOf(saleId, next).position, 7);
        // An uncapped sale keeps no positions or departures.
        english.set(
            address(stream),
            8,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        uint256 open = _openId(8, 0);
        uint256 b = _bid(open, alice, 50, 3);
        _bid(open, bob, 50, 3);
        uint256 amount = 3 * (_price(open, 60) - _price(open, 50));
        vm.deal(alice, amount);
        vm.prank(alice);
        auction.raise{ value: amount }(open, b, 60);
        assertEq(ua.departures(open, 50).length, 0);
        assertEq(ua.bidOf(open, 2).position, 0);
    }

    function test_Departures_LogPastTheHeadWord() public {
        uint256 saleId = _open(5);
        for (uint256 i; i < 9; ++i) {
            _bid(saleId, alice, 20, i + 1);
        }
        for (uint256 i; i < 9; ++i) {
            _raise(saleId, i + 1, 21);
        }
        IUniformEditionAuction.Departure[] memory d = ua.departures(saleId, 20);
        assertEq(d.length, 9);
        uint256 position;
        for (uint256 i; i < 9; ++i) {
            assertEq(d[i].position, position);
            assertEq(d[i].quantity, i + 1);
            position += i + 1;
        }
        // Departed units count toward the positions of later entries.
        uint256 last = _bid(saleId, bob, 20, 1);
        assertEq(ua.bidOf(saleId, last).position, 45);
    }

    // ================================================================== withdraw

    function test_WithdrawBid_OnlyWhileTheOneOfOneIsPaused() public {
        uint256 saleId = _open(10);
        _bid(saleId, alice, 40, 3);
        _bid(saleId, bob, 40, 2);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.WithdrawalsClosed.selector, saleId)
        );
        auction.withdrawBid(saleId, 1, alice);
        uint64 end = uint64(block.timestamp + 1 days);
        english.set(address(stream), ID, IEnglishAuction.AuctionState.PAUSED, end);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.NotBidder.selector, bob));
        auction.withdrawBid(saleId, 1, bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(0)));
        auction.withdrawBid(saleId, 1, address(0));
        address to = makeAddr("aliceCold");
        uint256 amount = 3 * _price(saleId, 40);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.BidWithdrawn(saleId, 1, alice, to, amount);
        vm.prank(alice);
        auction.withdrawBid(saleId, 1, to);
        assertEq(to.balance, amount);
        assertEq(ua.auction(saleId).liveUnits, 2);
        assertEq(ua.departures(saleId, 40).length, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.UnknownBid.selector, saleId, 1)
        );
        ua.bidOf(saleId, 1);
        // An address that refuses ETH keeps the bid.
        EthRefusingHolder refuser = new EthRefusingHolder();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.ClaimFailed.selector, address(refuser)));
        auction.withdrawBid(saleId, 2, address(refuser));
        // Every bid withdrawn: the book empties and the next bid resets its bounds.
        vm.prank(bob);
        auction.withdrawBid(saleId, 2, bob);
        assertEq(ua.auction(saleId).liveUnits, 0);
        assertEq(ua.clearing(saleId).count, 0);
        uint256 next = _bid(saleId, carol, 90, 1);
        assertEq(ua.bidOf(saleId, next).position, 0);
        IUniformEditionAuction.Auction memory a = ua.auction(saleId);
        assertEq(a.lowStep, 90);
        assertEq(a.highStep, 90);
    }

    // ================================================================== settle

    function test_Settle_NotReady() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 7, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        auction.settle(saleId, new uint256[](0));
        // Past the close, but the 1/1 has not settled.
        vm.warp(block.timestamp + 2 days);
        english.set(
            address(stream),
            ID,
            IEnglishAuction.AuctionState.ENDED,
            uint64(block.timestamp - 1 days)
        );
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        auction.settle(saleId, new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.UnknownAuction.selector, 3));
        auction.settle(3, new uint256[](0));
    }

    function test_Settle_PaysAndClaimsMintExactlyK() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 192, 1); // 1.00
        _bid(saleId, bob, 130, 50); // 0.0511
        // 151 x 0.01 = 1.51 is below 90% of 51 x 0.0511 = 2.6061: the price holds at 0.0511.
        _bid(saleId, carol, 96, 100); // 0.0100
        _closeOneOfOne(saleId);
        // Copies sold need the edition.
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.EditionNotCreated.selector, address(editions), ID
            )
        );
        auction.settle(saleId, new uint256[](0));
        editions.setExists(ID, true);
        uint256 revenue = 51 * 0.0511 ether;
        uint256 fee = revenue * FEE_SHARE / 100_000;
        // Every write first (the result, then SETTLED), the payout last.
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionCleared(
            saleId, 51, 130, 0.0511 ether, revenue, false, 50
        );
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionSettled(saleId, 51, 0);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.SaleSettled(
            saleId,
            address(editions),
            ID,
            address(0),
            address(0),
            51,
            CURRENCY_ETH,
            revenue,
            seller,
            revenue - fee,
            networkFee,
            fee
        );
        assertTrue(auction.settle(saleId, new uint256[](0)));
        paidOut += revenue;
        assertEq(seller.balance, revenue - fee);
        assertEq(networkFee.balance, fee);
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.SETTLED
            )
        );
        auction.settle(saleId, new uint256[](0));
        // Claims: the winners pay the clearing price, the loser gets everything back.
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.BidClaimed(saleId, 1, alice, alice, 1, 1 ether - 0.0511 ether);
        uint256 minted = _claimAll(saleId);
        assertEq(minted, 51);
        assertEq(editions.minted(ID), 51);
        assertEq(editions.balanceOf(alice, ID), 1);
        assertEq(editions.balanceOf(bob, ID), 50);
        assertEq(editions.balanceOf(carol, ID), 0);
        assertEq(carol.balance, 100 * 0.01 ether);
        _assertConserved();
        assertEq(address(auction).balance, 0);
    }

    function test_Settle_ZeroBidsMintsNothing() public {
        uint256 saleId = _open(0);
        _closeOneOfOne(saleId);
        // No edition is needed when nothing sold.
        vm.expectEmit(address(auction));
        emit ISaleAdapter.SaleSettled(
            saleId,
            address(editions),
            ID,
            address(0),
            address(0),
            0,
            CURRENCY_ETH,
            0,
            seller,
            0,
            networkFee,
            0
        );
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(ua.settlement(saleId).count, 0);
        assertEq(seller.balance, 0);
        assertEq(networkFee.balance, 0);
    }

    function test_Settle_VoidOnCancel() public {
        uint256 saleId = _open(5);
        _bid(saleId, alice, 100, 3);
        _bid(saleId, bob, 90, 4);
        // The 1/1 is cancelled after a dispute: anyone voids the sale at once.
        english.set(
            address(stream),
            ID,
            IEnglishAuction.AuctionState.CANCELLED,
            uint64(block.timestamp + 1 days)
        );
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionVoided(saleId);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        IUniformEditionAuction.BidOutcome memory o = ua.bidOutcome(saleId, 1);
        assertTrue(o.isFinal);
        assertEq(o.unitsWon, 0);
        assertEq(o.refund, o.escrow);
        assertEq(ua.clearing(saleId).count, 0);
        // No more bids; every bid is refunded in full and nothing is minted or paid.
        uint256 price = _price(saleId, 1);
        vm.deal(carol, price);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.VOID
            )
        );
        auction.bid{ value: price }(saleId, 1, 1);
        assertEq(_claimAll(saleId), 0);
        assertEq(alice.balance, 3 * _price(saleId, 100));
        assertEq(bob.balance, 4 * _price(saleId, 90));
        assertEq(seller.balance + networkFee.balance, 0);
        _assertConserved();
    }

    function test_Settle_RefusedPayoutsGoToTheEscrow() public {
        EthRefusingHolder refusing = new EthRefusingHolder();
        economics.set(address(refusing), networkFee, FEE_SHARE);
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 2);
        _settle(saleId);
        uint256 revenue = 2 * _price(saleId, 100);
        uint256 fee = revenue * FEE_SHARE / 100_000;
        assertEq(escrow.owed(address(refusing), address(0)), revenue - fee);
        assertEq(networkFee.balance, fee);
    }

    function test_Settle_CapWithFifoAndHoles_ChunkedSweep() public {
        // PLAN appendix C, trace 3: a cap of 60 on trace 2's book.
        uint256 saleId = _open(60);
        _bid(saleId, makeAddr("A"), 192, 1);
        _bid(saleId, makeAddr("B"), 158, 9);
        _bid(saleId, makeAddr("C"), 144, 5);
        _bid(saleId, makeAddr("B1"), 130, 20); // position 0
        uint256 b2 = _bid(saleId, makeAddr("B2"), 130, 15); // position 20, raised away below
        _bid(saleId, makeAddr("B3"), 130, 10); // position 35
        _bid(saleId, makeAddr("B4"), 130, 20); // position 45
        _bid(saleId, makeAddr("E"), 96, 200);
        _raise(saleId, b2, 144);
        IUniformEditionAuction.Clearing memory c = ua.clearing(saleId);
        assertEq(c.count, 60);
        assertEq(c.step, 130);
        assertTrue(c.rationed);
        assertEq(c.cutUnits, 30);
        assertEq(c.cutoff, 45, "the sweep passes B2's hole");
        uint256[] memory order = ua.settlementOrder(saleId);
        assertEq(order.length, 1);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        // First call: cleared and paid, the sweep not yet run (empty order).
        assertFalse(auction.settle(saleId, new uint256[](0)));
        paidOut += 60 * 0.0511 ether;
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        IUniformEditionAuction.Settlement memory s = ua.settlement(saleId);
        assertEq(s.departures, 1);
        assertEq(s.departuresSwept, 0);
        assertEq(s.cutoff, 30);
        // Claims wait for the sweep.
        vm.prank(makeAddr("B1"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.SETTLING
            )
        );
        auction.claimBid(saleId, 4, makeAddr("B1"));
        // An index past the log is refused.
        uint256[] memory bad = new uint256[](1);
        bad[0] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.InvalidSettlementOrder.selector, 0)
        );
        auction.settle(saleId, bad);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.DeparturesSwept(saleId, 1, 1, 45);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionSettled(saleId, 60, 45);
        assertTrue(auction.settle(saleId, order));
        assertEq(_claimAll(saleId), 60);
        assertEq(editions.balanceOf(makeAddr("B1"), ID), 20);
        assertEq(editions.balanceOf(makeAddr("B2"), ID), 15);
        assertEq(editions.balanceOf(makeAddr("B3"), ID), 10);
        assertEq(editions.balanceOf(makeAddr("B4"), ID), 0);
        // B2 won 15 at 0.0511 out of its 1.5 ETH escrow: 0.7335 ETH back.
        assertEq(makeAddr("B2").balance, 0.7335 ether);
        _assertConserved();
        assertEq(address(auction).balance, 0);
    }

    function test_Settle_RationedStepWithoutDeparturesSettlesAtOnce() public {
        uint256 saleId = _open(4);
        _bid(saleId, alice, 10, 2); // 0
        _bid(saleId, bob, 10, 2); // 2
        _bid(saleId, carol, 10, 2); // 4
        _bid(saleId, makeAddr("dan"), 10, 2); // 6
        _bid(saleId, makeAddr("eve"), 10, 2); // 8
        _raise(saleId, 3, 11); // departure 0: position 4
        _raise(saleId, 1, 11); // departure 1: position 0
        _raise(saleId, 2, 11); // departure 2: position 2; step 11 holds 6 units, cap 4
        IUniformEditionAuction.Clearing memory c = ua.clearing(saleId);
        assertEq(c.step, 11);
        assertTrue(c.rationed);
        assertEq(ua.settlementOrder(saleId).length, 0, "step 11 logged no departures");
        // Rationed at a step without departures settles at once.
        _settle(saleId);
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        assertEq(_claimAll(saleId), 4);
        _assertConserved();
    }

    function test_Settle_RejectsAnOutOfOrderSweep() public {
        uint256 saleId = _open(5);
        _bid(saleId, alice, 10, 2); // 0
        _bid(saleId, bob, 10, 2); // 2
        _bid(saleId, carol, 10, 3); // 4
        _bid(saleId, makeAddr("dan"), 10, 3); // 7
        _raise(saleId, 2, 11); // departure 0 at position 2
        _raise(saleId, 1, 11); // departure 1 at position 0; step 11 holds 4, step 10 holds 6
        IUniformEditionAuction.Clearing memory c = ua.clearing(saleId);
        assertEq(c.step, 10);
        assertTrue(c.rationed);
        uint256[] memory order = ua.settlementOrder(saleId);
        assertEq(order.length, 2);
        assertEq(order[0], 1);
        assertEq(order[1], 0);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        uint256[] memory wrong = new uint256[](2);
        (wrong[0], wrong[1]) = (0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.InvalidSettlementOrder.selector, 1)
        );
        auction.settle(saleId, wrong);
        uint256[] memory twice = new uint256[](2);
        (twice[0], twice[1]) = (1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.InvalidSettlementOrder.selector, 1)
        );
        auction.settle(saleId, twice);
        // In two chunks, with extra entries after the end ignored.
        uint256[] memory first = new uint256[](1);
        first[0] = 1;
        uint256 balance = address(auction).balance;
        assertFalse(auction.settle(saleId, first));
        paidOut += balance - address(auction).balance;
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.InvalidSettlementOrder.selector, 0)
        );
        auction.settle(saleId, first);
        uint256[] memory rest = new uint256[](2);
        (rest[0], rest[1]) = (0, 0);
        assertTrue(auction.settle(saleId, rest));
        // Cap 5: 4 at step 11, 1 at step 10 to the first live unit (carol at position 4).
        assertEq(_claimAll(saleId), 5);
        assertEq(editions.balanceOf(carol, ID), 1);
        assertEq(editions.balanceOf(makeAddr("dan"), ID), 0);
        _assertConserved();
    }

    // ================================================================== claims

    function test_Claims_RejectAndCredit() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 2);
        _bid(saleId, bob, 50, 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.OPEN
            )
        );
        auction.claimBid(saleId, 1, alice);
        _settle(saleId);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.NotBidder.selector, bob));
        auction.claimBid(saleId, 1, bob);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(0)));
        auction.claimBid(saleId, 2, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(auction))
        );
        auction.claimBid(saleId, 2, address(auction));
        EthRefusingHolder refuser = new EthRefusingHolder();
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.ClaimFailed.selector, address(refuser)));
        auction.claimBid(saleId, 2, address(refuser));
        vm.stopPrank();
        // Anyone pushes a claim: copies to the bidder, the refund credited.
        uint256 aliceRefund = 2 * (_price(saleId, 100) - _price(saleId, 100));
        assertEq(aliceRefund, 0);
        uint256 bobRefund = _price(saleId, 50);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(bob, CURRENCY_ETH, saleId, bobRefund);
        vm.prank(carol);
        (uint256 won, uint256 refund) = auction.claimBidFor(saleId, 2);
        assertEq(won, 0);
        assertEq(refund, bobRefund);
        assertEq(auction.claimable(bob, CURRENCY_ETH), bobRefund);
        assertEq(auction.claimable(bob, address(1)), 0);
        vm.prank(carol);
        (won, refund) = auction.claimBidFor(saleId, 1);
        assertEq(won, 2);
        assertEq(refund, 0);
        assertEq(editions.balanceOf(alice, ID), 2);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.UnknownBid.selector, saleId, 1)
        );
        auction.claimBidFor(saleId, 1);
        // Credits are claimed in ETH only.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.NothingToClaim.selector, bob, address(1))
        );
        auction.claim(address(1), bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(0)));
        auction.claim(CURRENCY_ETH, address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.ClaimFailed.selector, address(refuser)));
        auction.claim(CURRENCY_ETH, address(refuser));
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Claimed(bob, CURRENCY_ETH, bob, bobRefund);
        vm.prank(bob);
        assertEq(auction.claim(CURRENCY_ETH, bob), bobRefund);
        assertEq(bob.balance, bobRefund);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.NothingToClaim.selector, bob, CURRENCY_ETH)
        );
        auction.claim(CURRENCY_ETH, bob);
    }

    function test_Claims_RejectAWrongMint() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 2);
        _settle(saleId);
        editions.setReturnOffset(1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), ID)
        );
        auction.claimBid(saleId, 1, alice);
    }

    // ================================================================== storage words

    function test_StorageWord_DecodesAsTheLensDoes() public {
        uint256 saleId = _open(9);
        _bid(saleId, alice, 17, 3);
        IUniformEditionAuctionStorage.SaleWord memory w = _saleWord(saleId);
        assertEq(uint8(w.status), uint8(IUniformEditionAuction.AuctionStatus.OPEN));
        assertEq(w.termsId, 1);
        assertEq(w.maxCount, 9);
        assertEq(w.lowStep, 17);
        assertEq(w.highStep, 17);
        assertEq(w.liveUnits, 3);
        assertEq(w.bidCount, 1);
        assertEq(
            auction.storageWord(IUniformEditionAuctionStorage.Space.LIVE, saleId, 2),
            uint256(3) << 32
        );
        uint256 bidWord = auction.storageWord(IUniformEditionAuctionStorage.Space.BID, saleId, 1);
        assertEq(address(uint160(bidWord)), alice);
        uint256 terms = auction.storageWord(IUniformEditionAuctionStorage.Space.TERMS, 0, 1);
        assertEq(uint96(terms), 1e14);
        uint256 payout = auction.storageWord(IUniformEditionAuctionStorage.Space.PAYOUT, saleId, 0);
        assertEq(address(uint160(payout)), seller);
        assertEq(uint32(payout >> 208), ID);
        assertEq(auction.storageWord(IUniformEditionAuctionStorage.Space.RESULT, saleId, 0), 0);
        assertEq(
            auction.storageWord(IUniformEditionAuctionStorage.Space.DEPARTURE, saleId, 17 << 32), 0
        );
    }

    // ================================================================== helpers

    function _saleWord(uint256 saleId)
        internal
        view
        returns (IUniformEditionAuctionStorage.SaleWord memory a)
    {
        uint256 w = auction.storageWord(IUniformEditionAuctionStorage.Space.SALE, saleId, 0);
        a.status = IUniformEditionAuction.AuctionStatus(uint8(w));
        a.termsId = uint16(w >> 8);
        a.maxCount = uint32(w >> 24);
        a.oneOfOneEnd = uint32(w >> 56);
        a.softEnd = uint32(w >> 88);
        a.openedAt = uint32(w >> 120);
        a.lowStep = uint16(w >> 152);
        a.highStep = uint16(w >> 168);
        a.liveUnits = uint32(w >> 184);
        a.bidCount = uint32(w >> 216);
    }

    function _expectInvalidConfig(IUniformEditionAuction.AuctionConfig memory c) internal {
        IUniformEditionAuction.AuctionConfig memory current = auction.config();
        vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
        auction.setConfig(current, c);
    }

    function _assertConfig(
        IUniformEditionAuction.AuctionConfig memory a,
        IUniformEditionAuction.AuctionConfig memory b
    ) internal pure {
        assertEq(a.basePrice, b.basePrice, "basePrice");
        assertEq(a.stepsPerDecade, b.stepsPerDecade, "stepsPerDecade");
        assertEq(a.stepCount, b.stepCount, "stepCount");
        assertEq(a.marginShare, b.marginShare, "marginShare");
        assertEq(a.closeOffset, b.closeOffset, "closeOffset");
        assertEq(a.softWindow, b.softWindow, "softWindow");
        assertEq(a.maxExtension, b.maxExtension, "maxExtension");
    }
}
