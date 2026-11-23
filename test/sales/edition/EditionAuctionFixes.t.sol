// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";
import { DirectMinter } from "./UniformEditionAuctionAdopt.t.sol";

/// @notice The edition auction after the reviews: a removed auction's open sale voids with full
///         refunds and leaves the edition open for the network's rebind (review A M-1); `adopt`
///         refuses an edition whose maximum the sale could pass (review C M-4); the network
///         closes a moved edition that will never be sold (the lane-2 gap).
contract EditionAuctionFixesTest is EditionAuctionBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    UniformEditionAuction internal next;

    function setUp() public override {
        super.setUp();
        next = _deployAuction(defaultConfig());
        next.setTarget(address(editions), true);
        _addMinter(address(next));
    }

    // ------------------------------------------------- a removed auction (review A M-1)

    function test_RemovedAuction_ItsOpenSaleVoidsWithFullRefundsAndNoSeal() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 2);
        _bid(saleId, bob, 50, 1);
        editions.removeMinter(address(auction));
        _closeOneOfOne(saleId);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionVoided(saleId);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        assertEq(_claimAll(saleId), 0, "nothing minted");
        assertEq(alice.balance - aliceBefore, 2 * _price(saleId, 100));
        assertEq(bob.balance - bobBefore, _price(saleId, 50));
        assertFalse(editions.editionOf(ID).supplySealed, "left open for the rebind");
        assertEq(editions.editionOf(ID).minted, 0);
        _assertConserved();
        // The network moves it and the next auction sells it (the master's sale ended: the
        // adopted sale runs on its own).
        stream.setOutcome(ID, Outcome.SOLD);
        skip(editions.rebindDelay());
        editions.rebind(ID, address(next));
        next.adopt(address(editions), ID, _openData(_item(ID, 0)));
    }

    function test_RemovedAuction_ItsAbandonedSaleIsNotSealed() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 10, 1);
        english.setRefuseClock(true);
        editions.removeMinter(address(auction));
        vm.warp(ua.endTimes(saleId).closeAt + 21 days);
        auction.abandon(saleId);
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertFalse(editions.editionOf(ID).supplySealed);
    }

    // -------------------------------------------------------------------- adopt (review C M-4)

    function _directEdition() internal returns (DirectMinter direct) {
        _item(ID, 0); // the master exists
        direct = new DirectMinter();
        _addMinter(address(direct));
        direct.create(editions, ID); // maximum 5
        editions.removeMinter(address(direct));
        skip(editions.rebindDelay());
        editions.rebind(ID, address(next));
    }

    function test_Adopt_RefusesAnUncappedSaleOfACappedEdition() public {
        _directEdition();
        bytes memory data = _openData(_item(ID, 0));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), ID)
        );
        next.adopt(address(editions), ID, data);
    }

    function test_Adopt_RefusesACapAboveTheEditionsMaximum() public {
        _directEdition();
        bytes memory data = _openData(_item(ID, 6));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), ID)
        );
        next.adopt(address(editions), ID, data);
    }

    function test_Adopt_TakesACapWithinTheMaximumAndSettles() public {
        _directEdition();
        stream.setOutcome(ID, Outcome.SOLD); // the master's sale ended: it runs on its own
        uint256 saleId = next.adopt(address(editions), ID, _openData(_item(ID, 5)));
        IUniformEditionAuction n = IUniformEditionAuction(address(next));
        uint256 amount = 6 * n.stepPrice(saleId, 10);
        vm.deal(alice, amount);
        vm.prank(alice);
        next.bid{ value: amount }(saleId, 10, 6);
        vm.warp(n.endTimes(saleId).endTime);
        assertTrue(next.settle(saleId, new uint256[](0)));
        assertEq(editions.editionOf(ID).maxSupply, 5, "sealed at the cap, within the maximum");
    }

    // ----------------------------------------------------- closing a moved edition (lane 2)

    function test_CloseEdition_AMovedEditionWhoseMasterWasCancelled() public {
        _open(0);
        editions.removeMinter(address(auction));
        english.set(
            address(stream), ID, IEnglishAuction.AuctionState.CANCELLED, uint64(block.timestamp)
        );
        skip(editions.rebindDelay());
        editions.rebind(ID, address(next));
        bytes memory data = _openData(_item(ID, 0));
        vm.expectRevert();
        next.adopt(address(editions), ID, data);
        uint256 saleId = ua.saleIdOf(address(editions), ID);
        vm.expectEmit(address(next));
        emit IUniformEditionAuction.EditionClosed(saleId, address(editions), ID);
        next.closeEdition(address(editions), ID);
        assertTrue(editions.editionOf(ID).supplySealed);
        assertEq(editions.editionOf(ID).maxSupply, 0);
    }

    /// @dev An edition moved here with copies already minted is closed at those copies.
    function test_CloseEdition_AMovedEditionWithCopiesIsSealedAtThem() public {
        _item(ID, 0); // the master exists
        DirectMinter first = new DirectMinter();
        _addMinter(address(first));
        first.create(editions, ID);
        for (uint256 i; i < 3; ++i) {
            first.mint(editions, ID, alice);
        }
        editions.removeMinter(address(first));
        skip(editions.rebindDelay());
        editions.rebind(ID, address(next));
        next.closeEdition(address(editions), ID);
        assertTrue(editions.editionOf(ID).supplySealed);
        assertEq(editions.editionOf(ID).maxSupply, 3);
        assertEq(editions.balanceOf(alice, ID), 3);
    }

    // ------------------------------------------- a fee resolver that reverts (review C L-6)

    /// @dev The clearing call pays the recipient stored at open when the resolver cannot be
    ///      read, so a failing resolver does not hold a sale's settlement.
    function test_Settle_AResolverThatRevertsFallsBackToTheRecipientStoredAtOpen() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 2);
        _closeOneOfOne(saleId);
        vm.mockCallRevert(
            address(economics),
            abi.encodeWithSelector(IEconomicsResolver.networkFeeRecipient.selector),
            "resolver down"
        );
        uint256 before = networkFee.balance;
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLED)
        );
        uint256 revenue = 2 * _price(saleId, 100);
        assertEq(networkFee.balance - before, revenue * FEE_SHARE / 100_000, "the stored recipient");
    }

    function test_CloseEdition_TheNetworkOnlyAndNeverASaleOpenedHere() public {
        uint256 saleId = _open(0);
        vm.prank(alice);
        vm.expectRevert();
        auction.closeEdition(address(editions), ID);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.AuctionExists.selector, saleId)
        );
        auction.closeEdition(address(editions), ID);
        // Not this adapter's edition: the core refuses the seal.
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, ID, address(next))
        );
        next.closeEdition(address(editions), ID);
    }
}
