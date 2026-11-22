// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { Directory } from "src/core/Directory.sol";
import { Editions } from "src/core/Editions.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
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
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { UniformEditionAuctionLens } from "src/sales/UniformEditionAuctionLens.sol";
import {
    MockEditionRenderer,
    MockMasterStream,
    MockOneOfOneAuction,
    MockRevenueEscrow,
    MockWorkTermsResolver
} from "./EditionAuctionMocks.sol";

/// @notice The edition auction on the real 6529 Stream Editions (`src/core/Editions.sol`) and
///         the real `Directory`, with mocks for the rest: a harness the unit, vector, hostile
///         and invariant suites share. The 1/1 English auction, the master token (which also
///         answers the package registry's approval check) and the economics resolver are mocks
///         whose state the test sets; the adapter, its lens, the clearing library and the
///         edition contract are the real ones. This contract is the AccessManager's admin, so it
///         may call every restricted setter at once.
/// @dev Helpers keep ghost accounting of every wei the auction takes in and pays out, so a suite
///      can check conservation at any point: `escrowIn - refundsOut - paidOut ==
///      address(auction).balance - credits`.
abstract contract EditionAuctionBase is Test {
    /// @dev Edition ID (the master's token ID) every test sells unless it opens another.
    uint256 internal constant ID = 7;
    uint32 internal constant FEE_SHARE = 25_000;
    /// @dev The package root every test opens with.
    bytes32 internal constant ROOT = keccak256("package root");

    AccessManager internal manager;
    MockRevenueEscrow internal escrow;
    MockWorkTermsResolver internal economics;
    MockMasterStream internal stream;
    Editions internal editions;
    Directory internal directory;
    MockOneOfOneAuction internal english;
    UniformEditionAuction internal auction;
    /// @dev The adapter through its frozen interface (the views reach the lens).
    IUniformEditionAuction internal ua;
    /// @dev The lens's own views, at the adapter's address: the lens reads its caller, so it is
    ///      always called through the adapter's fallback.
    IUniformEditionAuctionLens internal lens;
    /// @dev The deployed lens itself.
    address internal lensAddress;

    address internal seller = makeAddr("sellerWallet");
    address internal networkFee = makeAddr("networkFeeSafe");
    address internal opener = makeAddr("opener");
    address internal lead = makeAddr("leadArtist");

    /// @dev Ghost accounting (wei).
    uint256 internal escrowIn;
    uint256 internal refundsOut;
    uint256 internal paidOut;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        manager = new AccessManager(address(this));
        escrow = new MockRevenueEscrow();
        economics = new MockWorkTermsResolver();
        economics.set(seller, networkFee, FEE_SHARE);
        stream = new MockMasterStream();
        stream.setRenderer(address(new MockEditionRenderer()));
        editions = new Editions(
            address(manager), address(stream), makeAddr("marketOwner"), address(0), new address[](0)
        );
        directory = new Directory(
            address(manager), address(0xACC), address(0xFED), address(0x7E), address(0x2EC)
        );
        english = new MockOneOfOneAuction();
        auction = _deployAuction(defaultConfig());
        ua = IUniformEditionAuction(address(auction));
        lens = IUniformEditionAuctionLens(address(auction));
        lensAddress = auction.lens();
        auction.setTarget(address(editions), true);
        _addMinter(address(auction));
        english.set(
            address(stream),
            ID,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
    }

    /// @dev The lens in its own deployment, then the adapter pinning it (F8).
    function _deployAuction(IUniformEditionAuction.AuctionConfig memory config)
        internal
        returns (UniformEditionAuction)
    {
        address l = address(
            new UniformEditionAuctionLens(
                address(editions),
                address(stream),
                address(english),
                address(escrow),
                address(directory),
                address(economics),
                address(stream)
            )
        );
        return new UniformEditionAuction(
            address(manager),
            address(escrow),
            address(directory),
            address(editions),
            address(english),
            l,
            l.codehash,
            config,
            defaultLimits()
        );
    }

    /// @dev Adds `minter` to 6529 Stream Editions, active at once (the network's wait set to
    ///      zero for the addition, then restored).
    function _addMinter(address minter) internal {
        uint48 delay = editions.moduleDelay();
        editions.setModuleDelay(0);
        editions.addMinter(minter);
        editions.setModuleDelay(delay);
    }

    // ------------------------------------------------------------------ configuration

    /// @dev The launch parameters (ADR 0005 section 4).
    function defaultConfig() internal pure returns (IUniformEditionAuction.AuctionConfig memory) {
        return IUniformEditionAuction.AuctionConfig(1e14, 48, 336, 10_000, 5 minutes, 1 days);
    }

    function _setConfig(IUniformEditionAuction.AuctionConfig memory next) internal {
        auction.setConfig(ua.config(), next);
    }

    /// @dev The launch limit: 100,000 gas per payout.
    function defaultLimits() internal pure returns (IUniformEditionAuction.Limits memory) {
        return IUniformEditionAuction.Limits(100_000);
    }

    /// @dev The limit as `setLimits` takes it: the payout gas.
    function _packedLimits(IUniformEditionAuction.Limits memory l) internal pure returns (uint256) {
        return l.payoutGas;
    }

    function _setLimits(IUniformEditionAuction.Limits memory next) internal {
        auction.setLimits(_packedLimits(ua.limits()), _packedLimits(next));
    }

    // ------------------------------------------------------------------ the master

    /// @dev The EDITION_MASTER item of edition `id` with cap `maxCount`, in the auction's kind and
    ///      ETH; its hash is what the master stream reports for `id`.
    function _item(uint256 id, uint32 maxCount) internal returns (PackageItem memory item) {
        item.kind = uint8(ItemKind.EDITION_MASTER);
        item.collectionId = 1;
        item.contentHash = keccak256(abi.encode("content", id));
        item.mediaHash = keccak256(abi.encode("media", id));
        item.recordFileId = keccak256(abi.encode("record", id));
        item.parties = new Party[](1);
        item.parties[0] = Party(lead, uint8(PartyRole.ARTIST));
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(uint256(uint160(lead)), address(0), 100_000);
        item.license = License("CC0-1.0", keccak256("cc0"));
        item.seedPolicy = uint8(SeedPolicy.NONE);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        item.edition = EditionTerms(maxCount, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
        stream.setWork(id, WorksHashing.itemHash(item), ItemKind.EDITION_MASTER);
    }

    /// @dev Opens edition `ID` with cap `maxCount`; returns the sale ID.
    function _open(uint32 maxCount) internal returns (uint256 saleId) {
        return _openId(ID, maxCount);
    }

    function _openId(uint256 id, uint32 maxCount) internal returns (uint256 saleId) {
        PackageItem memory item = _item(id, maxCount);
        vm.prank(opener);
        saleId = auction.open(address(editions), id, _openData(item));
    }

    /// @dev 6529 Stream Editions' open data (C23): the item, its package root and proof. The
    ///      mock package registry approves every root the test has not revoked.
    function _openData(PackageItem memory item) internal pure returns (bytes memory) {
        return abi.encode(item, ROOT, new bytes32[](0));
    }

    // ------------------------------------------------------------------ bidding

    function _price(uint256 saleId, uint256 step) internal view returns (uint256) {
        return ua.stepPrice(saleId, step);
    }

    function _bid(uint256 saleId, address bidder, uint256 step, uint256 quantity)
        internal
        returns (uint256 bidId)
    {
        uint256 amount = quantity * _price(saleId, step);
        vm.deal(bidder, bidder.balance + amount);
        vm.prank(bidder);
        bidId = auction.bid{ value: amount }(saleId, step, quantity);
        escrowIn += amount;
    }

    function _raise(uint256 saleId, uint256 bidId, uint256 newStep) internal {
        IUniformEditionAuction.Bid memory b = ua.bidOf(saleId, bidId);
        uint256 amount = uint256(b.quantity) * (_price(saleId, newStep) - _price(saleId, b.step));
        vm.deal(b.bidder, b.bidder.balance + amount);
        vm.prank(b.bidder);
        auction.raise{ value: amount }(saleId, bidId, newStep);
        escrowIn += amount;
    }

    // ------------------------------------------------------------------ closing

    /// @dev Settles the 1/1 at its current end, warps past the edition close and settles the
    ///      sale with the lens's full order.
    function _settle(uint256 saleId) internal {
        _closeOneOfOne(saleId);
        uint256 balance = address(auction).balance;
        // Settlement runs in calls of bounded gas: call until it is done.
        for (
            uint256 i;
            !auction.settle(saleId, lens.settlementOrderFor(saleId, address(this)));
            ++i
        ) {
            require(i < 64, "settlement does not advance");
        }
        paidOut += balance - address(auction).balance;
    }

    /// @dev Marks the 1/1 settled at its end and warps to the edition close.
    function _closeOneOfOne(uint256 saleId) internal {
        (, uint64 oneEnd) = english.clockOf(address(stream), ID);
        english.set(address(stream), ID, IEnglishAuction.AuctionState.SETTLED, oneEnd);
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        if (block.timestamp < e.endTime) vm.warp(e.endTime);
    }

    /// @dev Claims every live bid for its bidder, to the bidder; returns the copies minted.
    function _claimAll(uint256 saleId) internal returns (uint256 minted) {
        uint256 count = ua.auction(saleId).bidCount;
        for (uint256 bidId = 1; bidId <= count; ++bidId) {
            if (!_live(saleId, bidId)) continue;
            address bidder = ua.bidOf(saleId, bidId).bidder;
            vm.prank(bidder);
            (uint256 won, uint256 refund) = auction.claimBid(saleId, bidId, bidder);
            minted += won;
            refundsOut += refund;
        }
    }

    function _live(uint256 saleId, uint256 bidId) internal view returns (bool) {
        try ua.bidOf(saleId, bidId) returns (IUniformEditionAuction.Bid memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev ETH conservation: what the auction holds is exactly what it still owes.
    function _assertConserved() internal view {
        assertEq(
            address(auction).balance,
            escrowIn - refundsOut - paidOut,
            "auction balance = escrow in - refunds - payouts"
        );
    }
}
