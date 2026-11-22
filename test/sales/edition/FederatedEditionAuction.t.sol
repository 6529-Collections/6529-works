// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Directory } from "src/core/Directory.sol";
import { EditionsBase } from "src/core/EditionsBase.sol";
import { FederatedEditionAuction } from "src/federated/FederatedEditionAuction.sol";
import { FederatedEditionAuctionLens } from "src/federated/FederatedEditionAuctionLens.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Edition, Slots } from "src/interfaces/core/CoreTypes.sol";
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
    MockWorkTermsResolver
} from "./EditionAuctionMocks.sol";

/// @notice A federation module for the test: which sale contracts may mint which token, which
///         tokens are listed, and each token's fee share.
contract MockGate {
    mapping(address token => mapping(address minter => bool)) public canMint;
    mapping(address token => bool) public isActive;
    mapping(address token => uint32) public feeShareOf;
    mapping(address minter => uint256) public minterRemovedAt;

    function set(address token, address minter, bool ok) external {
        canMint[token][minter] = ok;
    }

    function setActive(address token, bool ok) external {
        isActive[token] = ok;
    }

    function setFeeShare(address token, uint32 share) external {
        feeShareOf[token] = share;
    }
}

/// @notice A federated editions token as lane 5 builds it, reduced to its hooks: `EditionsBase`
///         whose minters are the directory's FEDERATION module's answer.
contract GatedEditions is EditionsBase {
    Directory public immutable directory;
    address public immutable network;

    constructor(address stream_, Directory directory_) EditionsBase(stream_, msg.sender) {
        directory = directory_;
        network = msg.sender;
    }

    function _moduleOf(bytes32 slot) internal view override returns (address) {
        return slot == Slots.TERMS ? directory.moduleOf(Slots.FEDERATED_TERMS) : address(0);
    }

    function _isMinter(address account) internal view override returns (bool) {
        return MockGate(directory.moduleOf(Slots.FEDERATION)).canMint(address(this), account);
    }

    function _minterRemovedAt(address account) internal view override returns (uint256) {
        return MockGate(directory.moduleOf(Slots.FEDERATION)).minterRemovedAt(account);
    }

    function _checkAdmin() internal view override {
        require(msg.sender == network, "admin");
    }

    function _checkNetwork() internal view override {
        require(msg.sender == network, "network");
    }
}

/// @notice The federated edition auction on a federated editions token built on
///         `EditionsBase`: the edition is created at open, the fee share is the federation
///         module's for the token, a delisted token's sale voids with full refunds and its
///         edition is sealed at zero, and the winners of a listed one claim.
contract FederatedEditionAuctionTest is Test {
    uint256 internal constant ID = 3;
    uint32 internal constant SHARE = 10_000;

    AccessManager internal manager;
    MockGate internal gate;
    Directory internal directory;
    MockMasterStream internal master;
    GatedEditions internal token;
    MockOneOfOneAuction internal english;
    MockWorkTermsResolver internal economics;
    MockRevenueEscrow internal escrow;
    FederatedEditionAuction internal auction;
    IUniformEditionAuction internal ua;

    address internal seller = makeAddr("seller");
    address internal fee = makeAddr("federatedFee");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new AccessManager(address(this));
        gate = new MockGate();
        directory = new Directory(
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
            new FederatedEditionAuctionLens(
                address(english), address(escrow), address(directory), address(economics)
            )
        );
        auction = new FederatedEditionAuction(
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
        item.contentHash = keccak256("federated content");
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

    function test_Open_CreatesTheEditionWithTheFederationModulesShare() public {
        gate.setFeeShare(address(token), 4000);
        uint256 saleId = _open();
        Edition memory e = token.editionOf(ID);
        assertEq(e.minter, address(auction));
        assertEq(e.royaltyRate, 6529, "the master's rate");
        IUniformEditionAuction.Auction memory a = ua.auction(saleId);
        assertEq(a.feeShare, 4000, "the federation module's share, not the resolver's");
        assertEq(a.seller, seller);
        assertEq(a.feeRecipient, fee);
        assertEq(a.master, address(master));
        assertEq(ua.federationRegistry(), address(gate));
    }

    function test_Open_RefusedUnlessTheModuleLetsThisAuctionMint() public {
        gate.set(address(token), address(auction), false);
        bytes memory data = abi.encode(_item());
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(token), ID)
        );
        auction.open(address(token), ID, data);
        // With no federation module installed, nothing opens.
        gate.set(address(token), address(auction), true);
        directory.removeModule(Slots.FEDERATION);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(token), ID)
        );
        auction.open(address(token), ID, data);
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
}
