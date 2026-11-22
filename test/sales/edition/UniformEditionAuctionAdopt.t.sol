// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice Another sale contract that creates, mints and seals an edition directly.
contract DirectMinter {
    function create(IEditions editions, uint256 id) external {
        editions.create(id, 5, address(0), 0);
    }

    function mint(IEditions editions, uint256 id, address to) external {
        editions.mint(to, id, 1, 0);
    }

    function seal(IEditions editions, uint256 id) external {
        editions.seal(id, 3);
    }
}

/// @notice The network removing an edition auction: its sales still settle and its winners
///         still claim; an edition it never sold is moved by the network (`IEditions.rebind`) to
///         another auction, which opens its sale with `adopt`; the removed auction's own sale of
///         it is then void with full refunds.
contract UniformEditionAuctionAdoptTest is EditionAuctionBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    UniformEditionAuction internal next;

    function setUp() public override {
        super.setUp();
        next = _deployAuction(defaultConfig());
        next.setTarget(address(editions), true);
        _addMinter(address(next));
    }

    function _nextData() internal returns (bytes memory) {
        return _openData(_item(ID, 0));
    }

    /// @dev Removes the fixture's auction and moves edition `ID` to `next` once the rebind wait
    ///      has passed.
    function _removeAndRebind() internal {
        editions.removeMinter(address(auction));
        skip(editions.rebindDelay());
        editions.rebind(ID, address(next));
    }

    function _nextBid(uint256 saleId, address bidder, uint256 step, uint256 quantity)
        internal
        returns (uint256 bidId)
    {
        uint256 amount =
            quantity * IUniformEditionAuction(address(next)).stepPrice(saleId, step);
        vm.deal(bidder, bidder.balance + amount);
        vm.prank(bidder);
        bidId = next.bid{ value: amount }(saleId, step, quantity);
    }

    // ------------------------------------------------------------------ a removed auction

    /// @dev A removed auction opens nothing new. A sale it settled before its removal sealed
    ///      the edition, so its winners still claim: a removed minter mints up to the seal. (A
    ///      sale still open at the removal voids with full refunds: `EditionAuctionFixes`.)
    function test_RemovedAuction_ItsWinnersStillClaim() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 2);
        _bid(saleId, bob, 50, 1);
        _settle(saleId);
        editions.removeMinter(address(auction));
        english.set(
            address(stream),
            8,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        PackageItem memory other = _item(8, 0);
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(auction)));
        auction.open(address(editions), 8, _openData(other));
        assertEq(_claimAll(saleId), 2);
        assertEq(editions.balanceOf(alice, ID), 2);
        assertEq(editions.balanceOf(bob, ID), 0, "outbid: refunded");
        assertTrue(editions.editionOf(ID).supplySealed);
        _assertConserved();
    }

    // ------------------------------------------------------------------ rebind and adopt

    /// @dev The master's sale has an outcome: the adopted sale runs on its own for
    ///      `ADOPTED_RUN`, then 15 minutes, and settles without reading the 1/1 (here its
    ///      English auction no longer answers at all). Only the seller's wallet is deployed;
    ///      the edition keeps its royalty receiver and rate.
    function test_Adopt_AfterRebind_RunsOnItsOwnAndSettlesWithoutTheOneOfOne() public {
        uint256 old = _open(0);
        _bid(old, alice, 10, 1);
        stream.setOutcome(ID, Outcome.SOLD);
        english.setRefuseClock(true);
        _removeAndRebind();
        uint256 wallets = economics.createWalletCalls();
        uint256 saleId = ua.saleIdOf(address(editions), ID);
        bytes memory data = _nextData();
        vm.expectEmit(address(next));
        emit IUniformEditionAuction.EditionAdopted(saleId, address(editions), ID, true);
        assertEq(next.adopt(address(editions), ID, data), saleId);
        assertEq(economics.createWalletCalls(), wallets + 1, "the seller's wallet only");
        IUniformEditionAuction n = IUniformEditionAuction(address(next));
        IUniformEditionAuction.EndTimes memory e = n.endTimes(saleId);
        assertEq(e.closeAt, block.timestamp + 1 days + 15 minutes);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.SETTLED));
        assertTrue(e.biddingOpen);
        (bool ok, uint256 at) = n.abandonable(saleId);
        assertFalse(ok, "an adopted sale is never abandoned");
        assertEq(at, 0);
        _nextBid(saleId, bob, 100, 2);
        vm.warp(n.endTimes(saleId).endTime);
        uint256 sellerBefore = seller.balance;
        assertTrue(next.settle(saleId, new uint256[](0)));
        vm.prank(bob);
        (uint256 won,) = next.claimBid(saleId, 1, bob);
        assertEq(won, 2);
        assertEq(editions.balanceOf(bob, ID), 2);
        assertGt(seller.balance, sellerBefore);
        assertEq(editions.editionOf(ID).royaltyRate, 6529, "the edition's royalty stays");
        vm.warp(block.timestamp + 400 days);
        (ok,) = n.abandonable(saleId);
        assertFalse(ok);
    }

    /// @dev The removed auction's own sale of a rebound edition: with its 1/1 auction answering
    ///      settled, settlement voids it (the edition is no longer its own); every bid is
    ///      refunded in full and nothing is sealed.
    function test_Rebind_TheRemovedAuctionsSaleVoidsWithFullRefunds() public {
        uint256 old = _open(0);
        _bid(old, alice, 10, 1);
        _bid(old, bob, 20, 2);
        _closeOneOfOne(old);
        _removeAndRebind();
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionVoided(old);
        assertTrue(auction.settle(old, new uint256[](0)));
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        assertEq(_claimAll(old), 0);
        assertEq(alice.balance - aliceBefore, _price(old, 10));
        assertEq(bob.balance - bobBefore, 2 * _price(old, 20));
        assertFalse(editions.editionOf(ID).supplySealed);
        assertEq(editions.editionOf(ID).minter, address(next));
        _assertConserved();
    }

    /// @dev The same when its 1/1 auction stopped answering: `abandon` after the wait voids it
    ///      and leaves the edition to the new minter.
    function test_Rebind_TheRemovedAuctionsSaleIsAbandonedWithoutSealing() public {
        uint256 old = _open(0);
        _bid(old, alice, 10, 1);
        english.setRefuseClock(true);
        _removeAndRebind();
        vm.warp(ua.endTimes(old).closeAt + 21 days);
        auction.abandon(old);
        assertEq(uint8(ua.auction(old).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertFalse(editions.editionOf(ID).supplySealed, "not sealed: not its edition");
        assertEq(_claimAll(old), 0);
        _assertConserved();
    }

    /// @dev Rebound while the master's 1/1 still runs: the adopted sale follows the 1/1 as an
    ///      opened one does.
    function test_Adopt_WhileTheOneOfOneRunsFollowsIt() public {
        _open(0);
        editions.setRebindDelay(0);
        editions.removeMinter(address(auction));
        editions.rebind(ID, address(next));
        uint256 saleId = next.adopt(address(editions), ID, _nextData());
        IUniformEditionAuction.EndTimes memory e =
            IUniformEditionAuction(address(next)).endTimes(saleId);
        (, uint64 oneEnd) = english.clockOf(address(stream), ID);
        assertEq(e.closeAt, uint256(oneEnd) + 15 minutes);
        assertEq(uint8(e.oneOfOneState), uint8(IEnglishAuction.AuctionState.ACTIVE));
        // The 1/1 extends: the adopted sale follows.
        english.set(address(stream), ID, IEnglishAuction.AuctionState.ACTIVE, oneEnd + 1 hours);
        e = IUniformEditionAuction(address(next)).endTimes(saleId);
        assertEq(e.closeAt, uint256(oneEnd) + 1 hours + 15 minutes);
    }

    // ------------------------------------------------------------------ refusals

    function test_Adopt_TheNetworkOnly() public {
        _open(0);
        stream.setOutcome(ID, Outcome.SOLD);
        _removeAndRebind();
        bytes memory data = _nextData();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        next.adopt(address(editions), ID, data);
    }

    function test_Adopt_RefusesAnEditionThatIsNotItsOwn() public {
        _open(0);
        bytes memory terms =
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), ID);
        bytes memory data = _nextData();
        vm.expectRevert(terms);
        next.adopt(address(editions), ID, data);
        // Never created at all.
        english.set(
            address(stream),
            8,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        PackageItem memory item = _item(8, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), 8)
        );
        next.adopt(address(editions), 8, _openData(item));
    }

    /// @dev An edition with copies or a seal is never adopted: the lens refuses it.
    function test_Adopt_RefusesAnEditionWithCopiesOrASeal() public {
        DirectMinter direct = new DirectMinter();
        _addMinter(address(direct));
        PackageItem memory item = _item(ID, 0);
        direct.create(editions, ID);
        direct.mint(editions, ID, alice);
        bytes memory terms =
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), ID);
        vm.prank(address(direct));
        vm.expectRevert(terms);
        IUniformEditionAuctionLens(lensAddress)
            .masterTerms(address(editions), ID, _openData(item), true);
        item = _item(8, 0);
        direct.create(editions, 8);
        direct.seal(editions, 8);
        vm.prank(address(direct));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), 8)
        );
        IUniformEditionAuctionLens(lensAddress)
            .masterTerms(address(editions), 8, _openData(item), true);
    }

    function test_Adopt_RefusedWhilePausedOrForAnotherItem() public {
        _open(0);
        stream.setOutcome(ID, Outcome.SOLD);
        _removeAndRebind();
        next.pause();
        bytes memory data = _nextData();
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        next.adopt(address(editions), ID, data);
        next.unpause();
        PackageItem memory other = _item(ID, 0);
        other.contentHash = keccak256("another");
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), ID)
        );
        next.adopt(address(editions), ID, _openData(other));
        // Once adopted, a second adoption is refused.
        next.adopt(address(editions), ID, data);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.AuctionExists.selector, ua.saleIdOf(address(editions), ID)
            )
        );
        next.adopt(address(editions), ID, data);
    }
}
