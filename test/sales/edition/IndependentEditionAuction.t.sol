// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { StreamDirectory6529 } from "src/core/StreamDirectory6529.sol";
import { EditionsBase } from "src/core/EditionsBase.sol";
import { IndependentEditionAuction } from "src/independent/IndependentEditionAuction.sol";
import { IndependentEditionAuctionLens } from "src/independent/IndependentEditionAuctionLens.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Edition, Outcome, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionTerms,
    ItemKind,
    License,
    PackageItem,
    Party,
    PartyRole,
    SaleTerms,
    SeedPolicy
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import {
    MockEditionRenderer,
    MockMasterStream,
    MockOneOfOneAuction,
    MockRevenueEscrow,
    MockWorkTermsResolver,
    ReentrantBidder
} from "./EditionAuctionMocks.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";

/// @notice An Independent Stream module for the test: which sale contracts may mint which token,
///         which tokens are listed, and each token's fee share.
contract MockGate {
    mapping(address token => mapping(address minter => bool)) public canMint;
    mapping(address token => bool) public isActive;
    mapping(address token => uint32) public feeShareOf;
    mapping(address minter => uint256) public minterRemovedAt;
    mapping(address token => address) public partnerOf;

    /// @dev `IIndependentStreamRegistry.entry`, of which only the partner is set here.
    function entry(address token)
        external
        view
        returns (uint8, address, uint256, uint32, bytes32, uint32, uint8)
    {
        return (0, partnerOf[token], 0, 0, 0, 0, 0);
    }

    function setPartner(address token, address partner) external {
        partnerOf[token] = partner;
    }

    function set(address token, address minter, bool ok) external {
        canMint[token][minter] = ok;
    }

    function setActive(address token, bool ok) external {
        isActive[token] = ok;
    }

    function setFeeShare(address token, uint32 share) external {
        feeShareOf[token] = share;
    }

    function remove(address minter, uint256 when) external {
        minterRemovedAt[minter] = when;
    }
}

/// @notice An Independent Stream Editions token as lane 5 builds it, reduced to its hooks:
///         `EditionsBase` whose minters are the directory's INDEPENDENT_STREAM module's answer.
contract GatedEditions is EditionsBase {
    StreamDirectory6529 public immutable directory;
    address public immutable network;

    constructor(address stream_, StreamDirectory6529 directory_) EditionsBase(stream_, msg.sender) {
        directory = directory_;
        network = msg.sender;
    }

    function _moduleOf(bytes32 slot) internal view override returns (address) {
        return slot == Slots.TERMS ? directory.moduleOf(Slots.INDEPENDENT_TERMS) : address(0);
    }

    function _isMinter(address account) internal view override returns (bool) {
        return
            MockGate(directory.moduleOf(Slots.INDEPENDENT_STREAM)).canMint(address(this), account);
    }

    function _wasMinter(address) internal pure override returns (bool) {
        return true;
    }

    function _minterRemovedAt(address account) internal view override returns (uint256) {
        return MockGate(directory.moduleOf(Slots.INDEPENDENT_STREAM)).minterRemovedAt(account);
    }

    function _checkAdmin() internal view override {
        require(msg.sender == network, "admin");
    }

    function _checkNetwork() internal view override {
        require(msg.sender == network, "network");
    }
}

/// @notice The Independent Stream edition auction on an Independent Stream Editions token built on
///         `EditionsBase`: the edition is created at open, the fee share is the Independent Stream
///         module's for the token, a delisted token's sale voids with full refunds and its
///         edition is sealed at zero, and the winners of a listed one claim.
contract IndependentEditionAuctionTest is Test {
    uint256 internal constant ID = 3;
    uint32 internal constant SHARE = 10_000;

    AccessManager internal manager;
    MockGate internal gate;
    StreamDirectory6529 internal directory;
    MockMasterStream internal master;
    GatedEditions internal token;
    MockOneOfOneAuction internal english;
    MockWorkTermsResolver internal economics;
    MockRevenueEscrow internal escrow;
    IndependentEditionAuction internal auction;
    IUniformEditionAuction internal ua;

    address internal seller = makeAddr("seller");
    address internal fee = makeAddr("independentFee");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new AccessManager(address(this));
        gate = new MockGate();
        directory = new StreamDirectory6529(
            address(manager), address(0xACC), address(gate), address(0x7E), address(0)
        );
        master = new MockMasterStream();
        master.setRenderer(address(new MockEditionRenderer()));
        token = new GatedEditions(address(master), directory);
        english = new MockOneOfOneAuction();
        economics = new MockWorkTermsResolver();
        economics.set(seller, fee, SHARE);
        escrow = new MockRevenueEscrow();
        address l = address(
            new IndependentEditionAuctionLens(
                address(english), address(escrow), address(directory), address(economics)
            )
        );
        auction = new IndependentEditionAuction(
            address(manager),
            address(escrow),
            address(directory),
            address(english),
            l,
            l.codehash,
            IUniformEditionAuction.AuctionConfig(1e14, 48, 336, 10_000, 5 minutes, 1 days),
            IUniformEditionAuction.Limits(100_000)
        );
        ua = IUniformEditionAuction(address(auction));
        gate.set(address(token), address(auction), true);
        gate.setActive(address(token), true);
        gate.setActive(address(master), true); // its master contract is served too
        gate.setPartner(address(master), address(token)); // and names it as its editions
        gate.setFeeShare(address(token), SHARE);
        english.set(
            address(master),
            ID,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
    }

    function _item() internal returns (PackageItem memory item) {
        item.kind = uint8(ItemKind.EDITION_MASTER);
        item.collectionId = 1;
        item.contentHash = keccak256("Independent Stream content");
        item.parties = new Party[](1);
        item.parties[0] = Party(makeAddr("artist"), uint8(PartyRole.ARTIST));
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(1, address(0), 100_000);
        item.license = License("CC0-1.0", keccak256("cc0"));
        item.seedPolicy = uint8(SeedPolicy.NONE);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        item.edition = EditionTerms(0, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        master.setWork(ID, WorksHashing.itemHash(item), ItemKind.EDITION_MASTER);
    }

    function _open() internal returns (uint256) {
        return auction.open(address(token), ID, abi.encode(_item()));
    }

    function _bid(uint256 saleId, address bidder, uint256 step, uint256 quantity)
        internal
        returns (uint256)
    {
        uint256 amount = quantity * ua.stepPrice(saleId, step);
        vm.deal(bidder, amount);
        vm.prank(bidder);
        return auction.bid{ value: amount }(saleId, step, quantity);
    }

    function _close(uint256 saleId) internal {
        (, uint64 end) = english.clockOf(address(master), ID);
        english.set(address(master), ID, IEnglishAuction.AuctionState.SETTLED, end);
        vm.warp(ua.endTimes(saleId).endTime);
    }

    function test_Open_CreatesTheEditionWithTheIndependentStreamModulesShare() public {
        gate.setFeeShare(address(token), 4000);
        uint256 saleId = _open();
        Edition memory e = token.editionOf(ID);
        assertEq(e.minter, address(auction));
        assertEq(e.royaltyRate, 6529, "the master's rate");
        IUniformEditionAuction.Auction memory a = ua.auction(saleId);
        assertEq(a.feeShare, 4000, "the Independent Stream module's share, not the resolver's");
        assertEq(a.seller, seller);
        assertEq(a.feeRecipient, fee);
        assertEq(a.master, address(master));
        assertEq(ua.independentStreamRegistry(), address(gate));
    }

    function test_Open_RefusedUnlessTheModuleLetsThisAuctionMint() public {
        gate.set(address(token), address(auction), false);
        bytes memory data = abi.encode(_item());
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(token), ID)
        );
        auction.open(address(token), ID, data);
        // With no Independent Stream module installed, nothing opens.
        gate.set(address(token), address(auction), true);
        directory.removeModule(Slots.INDEPENDENT_STREAM);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(token), ID)
        );
        auction.open(address(token), ID, data);
    }

    /// @dev One editions contract per master (IND-78): a contract the module lets this auction
    ///      mint opens no sale unless its master's entry names it as the master's editions
    ///      contract. A master that names another contract, or none, refuses it.
    function test_Open_RefusedUnlessTheMasterNamesThisEditionsContract() public {
        bytes memory data = abi.encode(_item());
        bytes memory refused =
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(token), ID);
        gate.setPartner(address(master), makeAddr("anotherEditionsContract"));
        assertTrue(gate.canMint(address(token), address(auction)), "the module lets it mint");
        vm.expectRevert(refused);
        auction.open(address(token), ID, data);
        gate.setPartner(address(master), address(0));
        vm.expectRevert(refused);
        auction.open(address(token), ID, data);
        gate.setPartner(address(master), address(token));
        assertEq(auction.open(address(token), ID, data), ua.saleIdOf(address(token), ID));
    }

    function test_SetTarget_Refused() public {
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(1)));
        auction.setTarget(address(1), true);
    }

    function test_Sale_SettlesPaysAndTheWinnersClaim() public {
        uint256 saleId = _open();
        _bid(saleId, alice, 100, 2);
        _close(saleId);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        uint256 revenue = 2 * ua.stepPrice(saleId, 100);
        uint256 networkFee = revenue - revenue * (100_000 - SHARE) / 100_000;
        assertEq(fee.balance, networkFee);
        assertEq(seller.balance, revenue - networkFee);
        vm.prank(alice);
        (uint256 won,) = auction.claimBid(saleId, 1, alice);
        assertEq(won, 2);
        assertEq(token.balanceOf(alice, ID), 2);
        assertEq(token.editionOf(ID).maxSupply, 2, "sealed at the count");
        // A winner still claims after the module stops letting the auction mint: it sealed.
        gate.set(address(token), address(auction), false);
        assertEq(token.balanceOf(alice, ID), 2);
    }

    function test_Delisted_BidsRefusedAndTheSaleVoidsWithAZeroSeal() public {
        uint256 saleId = _open();
        _bid(saleId, alice, 100, 1);
        gate.setActive(address(token), false);
        uint256 amount = ua.stepPrice(saleId, 10);
        vm.deal(bob, amount);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.BiddingClosed.selector, saleId, 0)
        );
        auction.bid{ value: amount }(saleId, 10, 1);
        assertTrue(auction.settle(saleId, new uint256[](0)), "a delisted 1/1 reads cancelled");
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertTrue(token.editionOf(ID).supplySealed);
        assertEq(token.editionOf(ID).maxSupply, 0);
        vm.prank(alice);
        (, uint256 refund) = auction.claimBid(saleId, 1, alice);
        assertEq(refund, ua.stepPrice(saleId, 100));
    }

    /// @dev An adopted sale whose master's sale already ended runs on its own and does not read
    ///      the 1/1's clock. Delisted while it is open, it still voids with full refunds: nothing
    ///      is paid and no copy is minted.
    function test_Delisted_AnAdoptedSaleThatRunsOnItsOwnVoids() public {
        (IndependentEditionAuction next, uint256 saleId) = _adoptedOnItsOwn();
        IUniformEditionAuction un = IUniformEditionAuction(address(next));
        uint256 amount = un.stepPrice(saleId, 100);
        vm.deal(alice, amount);
        vm.prank(alice);
        uint256 bidId = next.bid{ value: amount }(saleId, 100, 1);
        gate.setActive(address(token), false);
        vm.warp(un.endTimes(saleId).endTime);
        assertTrue(next.settle(saleId, new uint256[](0)));
        assertEq(uint8(un.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertEq(fee.balance + seller.balance, 0, "nothing paid");
        assertEq(token.editionOf(ID).minted, 0);
        vm.prank(alice);
        (uint256 won, uint256 refund) = next.claimBid(saleId, bidId, alice);
        assertEq(won, 0);
        assertEq(refund, amount);
        // The refund is paid once: the whole escrow left the auction, and the bid is gone.
        assertEq(alice.balance, amount, "refunded in full");
        assertEq(address(next).balance, 0, "nothing left behind");
        vm.prank(alice);
        vm.expectRevert();
        next.claimBid(saleId, bidId, alice);
    }

    /// @dev The same sale, still listed, settles and pays as before.
    function test_Adopted_ASaleThatRunsOnItsOwnSettlesWhileListed() public {
        (IndependentEditionAuction next, uint256 saleId) = _adoptedOnItsOwn();
        IUniformEditionAuction un = IUniformEditionAuction(address(next));
        uint256 amount = un.stepPrice(saleId, 100);
        vm.deal(alice, amount);
        vm.prank(alice);
        next.bid{ value: amount }(saleId, 100, 1);
        vm.warp(un.endTimes(saleId).endTime);
        assertTrue(next.settle(saleId, new uint256[](0)));
        assertEq(
            uint8(un.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        assertEq(fee.balance + seller.balance, amount, "the clearing is paid");
    }

    /// @dev The first auction opens the edition and is removed; after the rebind wait the network
    ///      moves the edition to a second auction, which adopts it once the master's sale has an
    ///      outcome, so the adopted sale runs on its own.
    function _adoptedOnItsOwn() internal returns (IndependentEditionAuction next, uint256 saleId) {
        _open();
        address l = address(
            new IndependentEditionAuctionLens(
                address(english), address(escrow), address(directory), address(economics)
            )
        );
        next = new IndependentEditionAuction(
            address(manager),
            address(escrow),
            address(directory),
            address(english),
            l,
            l.codehash,
            IUniformEditionAuction.AuctionConfig(1e14, 48, 336, 10_000, 5 minutes, 1 days),
            IUniformEditionAuction.Limits(100_000)
        );
        gate.set(address(token), address(next), true);
        gate.set(address(token), address(auction), false);
        gate.remove(address(auction), block.timestamp);
        vm.warp(block.timestamp + token.rebindDelay());
        token.rebind(ID, address(next));
        master.setOutcome(ID, Outcome.SOLD);
        saleId = next.adopt(address(token), ID, abi.encode(_item()));
    }

    /// @dev Delisted while a wide book's scan is in progress (nothing paid yet): the next settle
    ///      call voids the sale.
    function test_Delisted_DuringTheScanVoids() public {
        uint256 saleId = _open();
        _bid(saleId, alice, 0, 1);
        _bid(saleId, bob, 335, 1);
        _close(saleId);
        assertFalse(auction.settle(saleId, new uint256[](0)));
        gate.setActive(address(token), false);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertEq(fee.balance + seller.balance, 0, "nothing paid");
    }

    /// @dev The 1/1 is cancelled while a wide book's scan is in progress (nothing paid yet): the
    ///      next settle call voids the sale, as the first call would have. Every bid comes back
    ///      in full, nothing is paid, and the edition is sealed at zero (IND-56).
    function test_Cancelled_DuringTheScanVoidsWithFullRefunds() public {
        uint256 saleId = _open();
        uint256 first = _bid(saleId, alice, 0, 1);
        uint256 second = _bid(saleId, bob, 335, 1);
        (uint256 paidAlice, uint256 paidBob) = (ua.stepPrice(saleId, 0), ua.stepPrice(saleId, 335));
        _close(saleId);
        assertFalse(auction.settle(saleId, new uint256[](0)));
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        _setOneOfOne(IEnglishAuction.AuctionState.CANCELLED);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionVoided(saleId);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertEq(fee.balance + seller.balance, 0, "nothing paid");
        Edition memory e = token.editionOf(ID);
        assertTrue(e.supplySealed && e.maxSupply == 0, "sealed at zero");
        vm.prank(alice);
        (uint256 won, uint256 refund) = auction.claimBid(saleId, first, alice);
        assertEq(won, 0);
        assertEq(refund, paidAlice, "refunded in full");
        vm.prank(bob);
        (won, refund) = auction.claimBid(saleId, second, bob);
        assertEq(won, 0);
        assertEq(refund, paidBob, "refunded in full");
        assertEq(address(auction).balance, 0, "nothing left behind");
        assertEq(token.balanceOf(alice, ID) + token.balanceOf(bob, ID), 0, "no copy");
    }

    /// @dev A 1/1 that was only offered again while the scan is in progress (running, paused or
    ///      ended again, never cancelled) does not void the sale: the next call finishes the
    ///      scan and pays.
    function test_Restarted_DuringTheScanTheSettlementGoesOn() public {
        IEnglishAuction.AuctionState[3] memory states = [
            IEnglishAuction.AuctionState.ACTIVE,
            IEnglishAuction.AuctionState.PAUSED,
            IEnglishAuction.AuctionState.ENDED
        ];
        uint256 saleId = _open();
        _bid(saleId, alice, 0, 1);
        _bid(saleId, bob, 335, 1);
        _close(saleId);
        assertFalse(auction.settle(saleId, new uint256[](0)));
        english.setRestartedAt(address(master), ID, uint64(block.timestamp));
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < states.length; ++i) {
            english.set(address(master), ID, states[i], uint64(block.timestamp + 1 days));
            assertTrue(auction.settle(saleId, new uint256[](0)), "the scan finishes");
            assertEq(
                uint8(ua.auction(saleId).status),
                uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
            );
            assertGt(fee.balance + seller.balance, 0, "paid");
            vm.revertToState(snapshot);
        }
    }

    /// @dev An adopted sale that runs on its own never reads the 1/1: with its scan in progress
    ///      and the English auction reporting the 1/1 cancelled and then refusing to answer, the
    ///      next call still finishes the scan and pays; only a delisting voids it.
    function test_Adopted_AScanInProgressDoesNotReadTheOneOfOne() public {
        (IndependentEditionAuction next, uint256 saleId) = _adoptedOnItsOwn();
        IUniformEditionAuction un = IUniformEditionAuction(address(next));
        uint256[2] memory steps = [uint256(0), 335];
        for (uint256 i; i < 2; ++i) {
            uint256 amount = un.stepPrice(saleId, steps[i]);
            vm.deal(alice, amount);
            vm.prank(alice);
            next.bid{ value: amount }(saleId, steps[i], 1);
        }
        vm.warp(un.endTimes(saleId).endTime);
        assertFalse(next.settle(saleId, new uint256[](0)), "the scan needs another call");
        uint256 snapshot = vm.snapshotState();

        _setOneOfOne(IEnglishAuction.AuctionState.CANCELLED);
        english.setRefuseClock(true);
        assertTrue(next.settle(saleId, new uint256[](0)));
        assertEq(
            uint8(un.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        assertGt(fee.balance + seller.balance, 0, "paid");

        vm.revertToState(snapshot);
        gate.setActive(address(token), false);
        assertTrue(next.settle(saleId, new uint256[](0)));
        assertEq(uint8(un.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertEq(fee.balance + seller.balance, 0, "nothing paid");
    }

    /// @dev The void of a delisted sale whose scan is in progress is not reachable from inside
    ///      another call of the auction: a bidder refunded from a second sale re-enters `settle`
    ///      of the scanning one and is refused by the reentrancy guard, and the sale voids by a
    ///      call of its own afterwards.
    function test_Delisted_TheVoidDuringTheScanIsNotReentrant() public {
        uint256 scanning = _open();
        _bid(scanning, alice, 0, 1);
        _bid(scanning, bob, 335, 1);

        // A second sale of the same token, with one bid of a wallet that re-enters when paid.
        uint256 second = ID + 1;
        PackageItem memory item = _item();
        item.contentHash = keccak256("a second Independent Stream content");
        master.setWork(second, WorksHashing.itemHash(item), ItemKind.EDITION_MASTER);
        english.set(
            address(master),
            second,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        uint256 other = auction.open(address(token), second, abi.encode(item));
        ReentrantBidder hostile = new ReentrantBidder(ua);
        uint256 hostileBid = _bid(other, address(hostile), 10, 1);
        uint256 paid = ua.stepPrice(other, 10);

        _close(scanning);
        assertFalse(auction.settle(scanning, new uint256[](0)), "the scan is in progress");
        gate.setActive(address(token), false);
        assertTrue(auction.settle(other, new uint256[](0)), "the second sale voids");

        // The refund's receive re-enters `settle` of the scanning sale.
        hostile.setTarget(scanning, 0, 1);
        vm.prank(address(hostile));
        auction.claimBid(other, hostileBid, address(hostile));
        assertTrue(hostile.attempted());
        assertEq(
            bytes4(hostile.lastRevert()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(address(hostile).balance, paid, "refunded in full");
        assertEq(
            uint8(ua.auction(scanning).status),
            uint8(IUniformEditionAuction.AuctionStatus.SETTLING),
            "not voided from inside the refund"
        );

        assertTrue(auction.settle(scanning, new uint256[](0)));
        assertEq(
            uint8(ua.auction(scanning).status), uint8(IUniformEditionAuction.AuctionStatus.VOID)
        );
    }

    // ===================================================== rules of the specification

    function _lens() internal view returns (IUniformEditionAuctionLens) {
        return IUniformEditionAuctionLens(auction.lens());
    }

    function _setOneOfOne(IEnglishAuction.AuctionState state) internal {
        (, uint64 end) = english.clockOf(address(master), ID);
        english.set(address(master), ID, state, end);
    }

    function _expectNotAbandonable(uint256 saleId) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        auction.abandon(saleId);
    }

    // ------------------------------------------------------------------ the fee share (IND-54)

    /// The sale stores the Independent Stream module's share for the token when it opens. A later
    /// change of the module's answer, or of the economics resolver's share, does not move it: the
    /// settlement pays the network at the stored share (IND-54).
    function test_Open_TheStoredShareIsNotMovedByLaterAnswers() public {
        uint32 atOpen = 4000;
        gate.setFeeShare(address(token), atOpen);
        uint256 saleId = _open();
        gate.setFeeShare(address(token), 0);
        economics.set(seller, fee, 50_000);
        assertEq(ua.auction(saleId).feeShare, atOpen, "stored at open");

        _bid(saleId, alice, 100, 2);
        _close(saleId);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        uint256 revenue = 2 * ua.stepPrice(saleId, 100);
        uint256 networkFee = revenue - revenue * (100_000 - atOpen) / 100_000;
        assertGt(networkFee, 0);
        assertEq(fee.balance, networkFee, "the network's part at the stored share");
        assertEq(seller.balance, revenue - networkFee, "the seller's part");
    }

    // ------------------------------------------------------------------ not served (IND-55)

    /// Once the module stops serving the sale's contract, a raise of a standing bid is refused as
    /// a new bid is (`BiddingClosed` with end zero), whatever the time (IND-55).
    function test_Delisted_ARaiseIsRefused() public {
        uint256 saleId = _open();
        uint256 bidId = _bid(saleId, alice, 100, 1);
        gate.setActive(address(token), false);
        uint256 more = ua.stepPrice(saleId, 110) - ua.stepPrice(saleId, 100);
        vm.deal(alice, more);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.BiddingClosed.selector, saleId, 0)
        );
        auction.raise{ value: more }(saleId, bidId, 110);
        assertEq(alice.balance, more, "nothing was taken");
    }

    /// Once the module stops serving the sale's contract, the sale's own views report its 1/1 as
    /// cancelled and bidding as closed, although the 1/1's auction still answers that it is
    /// active.
    function test_Delisted_TheSalesViewsReportTheOneOfOneCancelled() public {
        uint256 saleId = _open();
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertTrue(e.biddingOpen);

        gate.setActive(address(token), false);
        (IEnglishAuction.AuctionState state,) = english.clockOf(address(master), ID);
        assertEq(uint8(state), uint8(IEnglishAuction.AuctionState.ACTIVE), "the 1/1 itself");
        e = ua.endTimes(saleId);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.CANCELLED));
        assertFalse(e.biddingOpen);
    }

    // ------------------------------------------------------------------ abandon

    /// `abandon` is refused while the sale's 1/1 is live. Once the 1/1 is cancelled it is refused
    /// until the compiled wait after the edition's close has passed, and accepted from then, by
    /// anyone: the sale is void, the edition is sealed at zero and the bid is refunded in full.
    function test_Abandon_AfterTheOneOfOneIsCancelledAndTheWaitItSealsAtZero() public {
        uint256 saleId = _open();
        _bid(saleId, alice, 100, 1);
        uint256 paid = ua.stepPrice(saleId, 100);
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, 0, "a live 1/1: no time at which it can be abandoned");
        _expectNotAbandonable(saleId);

        _setOneOfOne(IEnglishAuction.AuctionState.CANCELLED);
        (ok, at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, uint256(ua.endTimes(saleId).closeAt) + _lens().ABANDON_DELAY());
        vm.warp(at - 1);
        _expectNotAbandonable(saleId);
        vm.warp(at);
        (ok,) = ua.abandonable(saleId);
        assertTrue(ok);

        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionVoided(saleId);
        vm.expectEmit(address(token));
        emit IEditions.EditionSupplySealed(ID, 0);
        vm.prank(makeAddr("anyone"));
        auction.abandon(saleId);
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertTrue(token.editionOf(ID).supplySealed);
        assertEq(token.editionOf(ID).maxSupply, 0, "sealed at zero");
        assertEq(token.editionOf(ID).minted, 0);
        vm.prank(alice);
        (uint256 won, uint256 refund) = auction.claimBid(saleId, 1, alice);
        assertEq(won, 0);
        assertEq(refund, paid);
        assertEq(alice.balance, paid, "refunded in full");
        assertEq(fee.balance + seller.balance, 0, "nothing paid");
        _expectNotAbandonable(saleId);
    }

    /// As built, a sale whose 1/1 settled is never abandoned, however long after its close: it
    /// settles as usual.
    function test_Abandon_ASaleWhoseOneOfOneSettledIsRefused() public {
        uint256 saleId = _open();
        _bid(saleId, alice, 100, 1);
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        vm.warp(uint256(ua.endTimes(saleId).closeAt) + _lens().ABANDON_DELAY());
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, 0);
        _expectNotAbandonable(saleId);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        assertEq(token.editionOf(ID).maxSupply, 1, "sealed at the one copy sold");
    }
}
