// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionStorage } from "src/interfaces/IUniformEditionAuctionStorage.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice Settlement in calls of bounded gas: the adapter's own scan, resumable across calls,
///         against `UniformClearing.clear` (which the lens runs) on random books, and the state a
///         sale shows while its scan is in progress.
contract UniformEditionAuctionSettlementTest is EditionAuctionBase {
    /// @dev The adapter's settlement equals the lens's clearing (`UniformClearing.clear`) on
    ///      random books: steps spread over the whole ladder or clustered, random quantities,
    ///      caps and margins, and raises (departures) in capped sales. Exactly `count` copies
    ///      are minted and every wei is accounted for.
    function testFuzz_Settlement_EqualsTheLibraryClearing(
        uint256 seed,
        uint8 bids,
        uint32 maxCount,
        uint32 marginShare,
        bool spread
    ) public {
        bids = uint8(bound(bids, 1, 60));
        IUniformEditionAuction.AuctionConfig memory c = defaultConfig();
        c.marginShare = uint32(bound(marginShare, 0, 50_000));
        _setConfig(c);
        uint256 saleId = _open(uint32(bound(maxCount, 0, 400)));
        for (uint256 i; i < bids; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 step = spread ? r % 336 : 120 + r % 24;
            _bid(saleId, makeAddr(vm.toString(i % 7)), step, 1 + (r >> 16) % 40);
            // Every third bid raises an earlier one, leaving departures in a capped sale.
            if (i % 3 == 2) {
                uint256 bidId = 1 + (r >> 32) % (i + 1);
                uint256 from = ua.bidOf(saleId, bidId).step;
                if (from + 1 < 336) _raise(saleId, bidId, from + 1 + (r >> 40) % (335 - from));
            }
        }
        IUniformEditionAuction.Clearing memory live = ua.clearing(saleId);
        _settle(saleId);
        IUniformEditionAuction.Settlement memory s = ua.settlement(saleId);
        assertEq(s.count, live.count, "count");
        assertEq(s.price, live.price, "price");
        if (live.count != 0) assertEq(s.step, live.step, "step");
        assertEq(s.rationed, live.rationed, "rationed");
        assertEq(s.cutUnits, live.cutUnits, "cut units");
        if (live.rationed) assertEq(s.cutoff, live.cutoff, "cutoff");
        assertEq(_claimAll(saleId), live.count, "exactly k");
        _assertConserved();
        assertEq(address(auction).balance, 0);
    }

    /// @dev A book wider than one call's scan (24 words) settles over several calls; meanwhile
    ///      the sale is SETTLING, refuses bids and claims, shows no stored result, and its
    ///      settlement order is the live clearing's.
    function test_Settlement_ScansAWideBookOverCalls() public {
        uint256 saleId = _open(30);
        _bid(saleId, makeAddr("low"), 0, 40);
        _bid(saleId, makeAddr("high"), 300, 1);
        _bid(saleId, makeAddr("mid"), 150, 3);
        _bid(saleId, makeAddr("first"), 0, 2);
        _raise(saleId, 4, 1);
        IUniformEditionAuction.Clearing memory live = ua.clearing(saleId);
        uint256[] memory order = ua.settlementOrder(saleId);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        // 38 words from step 300 down to step 0: the first call scans 24 and stops.
        vm.expectEmit(address(auction));
        emit IUniformEditionAuctionStorage.SettlementScanned(saleId, 14);
        assertFalse(auction.settle(saleId, new uint256[](0)));
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        assertTrue(auction.storageWord(IUniformEditionAuctionStorage.Space.SCAN, saleId, 0) != 0);
        assertEq(ua.settlement(saleId).count, 0, "no result yet");
        assertEq(ua.settlementOrder(saleId), order, "the live clearing's order");
        uint256 price = _price(saleId, 5);
        vm.deal(makeAddr("late"), price);
        vm.prank(makeAddr("late"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.SETTLING
            )
        );
        auction.bid{ value: price }(saleId, 5, 1);
        vm.prank(makeAddr("high"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.SETTLING
            )
        );
        auction.claimBid(saleId, 2, makeAddr("high"));
        // The next call finishes the scan, clears and pays.
        uint256 balance = address(auction).balance;
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionCleared(
            saleId, live.count, live.step, live.price, live.revenue, live.rationed, live.cutUnits
        );
        bool done = auction.settle(saleId, ua.settlementOrder(saleId));
        paidOut += balance - address(auction).balance;
        if (!done) assertTrue(auction.settle(saleId, ua.settlementOrder(saleId)));
        assertEq(auction.storageWord(IUniformEditionAuctionStorage.Space.SCAN, saleId, 0), 0);
        IUniformEditionAuction.Settlement memory s = ua.settlement(saleId);
        assertEq(s.count, live.count);
        if (live.rationed) assertEq(s.cutoff, live.cutoff);
        assertEq(_claimAll(saleId), live.count);
        _assertConserved();
    }

    /// @dev A missing edition stops the clearing call, not the scan before it: once created,
    ///      the next call clears.
    function test_Settlement_WaitsForTheEditionAtTheClearingCall() public {
        uint256 saleId = _open(0);
        _bid(saleId, makeAddr("low"), 0, 3);
        _bid(saleId, makeAddr("high"), 300, 1);
        _closeOneOfOne(saleId);
        assertFalse(auction.settle(saleId, new uint256[](0)), "the first chunk");
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.EditionNotCreated.selector, address(editions), ID
            )
        );
        auction.settle(saleId, new uint256[](0));
        editions.setExists(ID, true);
        uint256 balance = address(auction).balance;
        assertTrue(auction.settle(saleId, new uint256[](0)));
        paidOut += balance - address(auction).balance;
        assertEq(_claimAll(saleId), ua.settlement(saleId).count);
        _assertConserved();
    }
}
