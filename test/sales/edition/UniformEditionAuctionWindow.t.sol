// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionStorage } from "src/interfaces/IUniformEditionAuctionStorage.sol";
import { ItemKind, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice The edition's own open period (a close offset in the artist-signed edition terms,
///         bounded by a governed maximum, locked at open), the governed limits, and the 32-bit
///         clocks at their bound (ADR 0005 section 4, as amended 15 November 2026; EA-17, EA-18).
contract UniformEditionAuctionWindowTest is EditionAuctionBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /// @dev The master item of edition `id` whose edition terms name `offset` seconds.
    function _itemWithOffset(uint256 id, uint32 maxCount, uint256 offset)
        internal
        returns (PackageItem memory item)
    {
        item = _item(id, maxCount);
        item.edition.params = abi.encode(offset);
        stream.setWork(id, WorksHashing.itemHash(item), ItemKind(item.kind));
    }

    function _openWithOffset(uint256 offset) internal returns (uint256 saleId) {
        PackageItem memory item = _itemWithOffset(ID, 0, offset);
        vm.prank(opener);
        saleId = auction.open(address(editions), ID, abi.encode(item));
    }

    function _assertConfig(
        IUniformEditionAuction.AuctionConfig memory got,
        IUniformEditionAuction.AuctionConfig memory want
    ) internal pure {
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(want)), "terms");
    }

    function _oneEnd() internal view returns (uint256) {
        return english.auction(english.saleIdOf(address(stream), ID)).endTime;
    }

    function _termsCount() internal view returns (uint256) {
        return uint24(lens.storageWord(IUniformEditionAuctionStorage.Space.SETTINGS, 0, 0) >> 24);
    }

    // ------------------------------------------------------------------ the window

    /// @dev No params: the governed default (15 minutes), and no extra terms record.
    function test_Window_EmptyParamsLockTheDefault() public {
        uint256 records = _termsCount();
        uint256 saleId = _open(0);
        assertEq(_termsCount(), records, "the current record, reused");
        assertEq(ua.auction(saleId).terms.closeOffset, 15 minutes);
        assertEq(ua.endTimes(saleId).closeAt, _oneEnd() + 15 minutes);
    }

    /// @dev The artist's offset, from zero to the governed maximum: each locks a record of the
    ///      current parameters with it, emitted in `AuctionOpened`, and moves the close.
    function test_Window_TheArtistsOffsetIsLocked() public {
        uint256[4] memory offsets = [uint256(0), 1 days, 30 days, 30 days];
        offsets[3] = ua.limits().maxCloseOffset;
        for (uint256 i; i < offsets.length; ++i) {
            uint256 id = 100 + i;
            english.set(
                address(stream),
                id,
                IEnglishAuction.AuctionState.ACTIVE,
                uint64(block.timestamp + 1 days)
            );
            PackageItem memory item = _itemWithOffset(id, 0, offsets[i]);
            IUniformEditionAuction.AuctionConfig memory expected = defaultConfig();
            expected.closeOffset = uint32(offsets[i]);
            uint256 records = _termsCount();
            vm.recordLogs();
            vm.prank(opener);
            uint256 saleId = auction.open(address(editions), id, abi.encode(item));
            assertEq(_termsCount(), offsets[i] == 15 minutes ? records : records + 1, "one record");
            _assertConfig(ua.auction(saleId).terms, expected);
            assertEq(ua.endTimes(saleId).closeAt, block.timestamp + 1 days + offsets[i]);
        }
    }

    /// @dev An offset equal to the default reuses the current record.
    function test_Window_AnOffsetEqualToTheDefaultWritesNoRecord() public {
        uint256 records = _termsCount();
        uint256 saleId = _openWithOffset(15 minutes);
        assertEq(_termsCount(), records);
        assertEq(ua.auction(saleId).terms.closeOffset, 15 minutes);
    }

    function test_Window_RefusesAnOffsetPastTheMaximumOrMalformedParams() public {
        uint256 max = ua.limits().maxCloseOffset;
        PackageItem memory item = _itemWithOffset(ID, 0, max + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), ID)
        );
        auction.open(address(editions), ID, abi.encode(item));
        item = _itemWithOffset(ID, 0, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), ID)
        );
        auction.open(address(editions), ID, abi.encode(item));
        // Params that are neither empty nor one word.
        bytes[3] memory bad = [bytes(hex"01"), new bytes(31), new bytes(64)];
        for (uint256 i; i < bad.length; ++i) {
            item = _item(ID, 0);
            item.edition.params = bad[i];
            stream.setWork(ID, WorksHashing.itemHash(item), ItemKind(item.kind));
            vm.expectRevert(
                abi.encodeWithSelector(
                    ISaleAdapter.InvalidSaleTerms.selector, address(editions), ID
                )
            );
            auction.open(address(editions), ID, abi.encode(item));
        }
        // The maximum itself is accepted.
        _openWithOffset(max);
    }

    /// @dev A governance change mid-sale (the default, the maximum, the abandonment delay)
    ///      changes nothing for an open sale: its close offset and delay are locked.
    function test_Window_AChangeMidSaleHasNoEffect() public {
        uint256 saleId = _openWithOffset(20 days);
        uint256 closeAt = ua.endTimes(saleId).closeAt;
        IUniformEditionAuction.Limits memory l = defaultLimits();
        l.maxCloseOffset = 2 days;
        l.voidDelayDays = 400;
        IUniformEditionAuction.AuctionConfig memory c = defaultConfig();
        c.closeOffset = 1 days;
        _setConfig(c);
        _setLimits(l);
        assertEq(ua.endTimes(saleId).closeAt, closeAt, "the close");
        assertEq(ua.auction(saleId).terms.closeOffset, 20 days, "the offset");
        uint256 payout = lens.storageWord(IUniformEditionAuctionStorage.Space.PAYOUT, saleId, 0);
        assertEq(payout >> 240, 150, "the abandonment delay locked at open");
        // A new sale with the same terms is refused now: 20 days is past the new maximum.
        english.set(
            address(stream),
            8,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        PackageItem memory item = _itemWithOffset(8, 0, 20 days);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), 8)
        );
        auction.open(address(editions), 8, abi.encode(item));
    }

    /// @dev A 30-day window: bids are taken until the close, firm (no withdrawal once the 1/1
    ///      settled), the sale cannot settle before the close, and settles and seals after it.
    function test_Window_ThirtyDaysBidsFirmUntilTheClose() public {
        uint256 saleId = _openWithOffset(30 days);
        uint256 bidId = _bid(saleId, alice, 10, 2);
        _closeOneOfOneAt(saleId, false);
        vm.warp(_oneEnd() + 29 days);
        _bid(saleId, bob, 12, 1);
        // Firm: the 1/1 settled, so no pause can open withdrawals.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.WithdrawalsClosed.selector, saleId)
        );
        auction.withdrawBid(saleId, bidId, alice);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.SettlementNotReady.selector, saleId)
        );
        auction.settle(saleId, new uint256[](0));
        assertTrue(ua.endTimes(saleId).biddingOpen);
        _settle(saleId);
        assertEq(editions.sealedCount(ID), 3, "sealed at the count sold");
        assertEq(_claimAll(saleId), 3);
        _assertConserved();
    }

    /// @dev Zero offset: the sale closes with the 1/1, and a bid at that second is refused.
    function test_Window_ZeroClosesWithTheOneOfOne() public {
        uint256 saleId = _openWithOffset(0);
        _bid(saleId, alice, 3, 1);
        vm.warp(_oneEnd());
        vm.deal(bob, 1 ether);
        uint256 price = ua.stepPrice(saleId, 3);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.BiddingClosed.selector, saleId, uint64(_oneEnd())
            )
        );
        auction.bid{ value: price }(saleId, 3, 1);
    }

    /// @dev The soft close and its backstop follow the sale's own close.
    function test_Window_TheSoftCloseFollowsALongClose() public {
        uint256 saleId = _openWithOffset(10 days);
        uint256 closeAt = ua.endTimes(saleId).closeAt;
        vm.warp(closeAt - 1 minutes);
        _bid(saleId, alice, 3, 1);
        assertEq(ua.endTimes(saleId).endTime, block.timestamp + 5 minutes);
        // Keep extending: never past closeAt + maxExtension.
        for (uint256 i; i < 400; ++i) {
            IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
            if (!e.biddingOpen) break;
            vm.warp(e.endTime - 1);
            _bid(saleId, bob, 3, 1);
        }
        assertEq(ua.endTimes(saleId).endTime, closeAt + 1 days, "the backstop");
    }

    /// @dev A cancelled 1/1 during a long window voids the sale at once, long before the close.
    function test_Window_ACancelDuringALongWindowVoidsAtOnce() public {
        uint256 saleId = _openWithOffset(30 days);
        _bid(saleId, alice, 10, 2);
        english.set(address(stream), ID, IEnglishAuction.AuctionState.CANCELLED, uint64(_oneEnd()));
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        _claimAll(saleId);
        _assertConserved();
    }

    /// @dev Fuzz: any offset within the maximum moves the close by exactly that much.
    function testFuzz_Window_TheCloseIsTheOneOfOneEndPlusTheOffset(uint256 offset) public {
        offset = bound(offset, 0, ua.limits().maxCloseOffset);
        uint256 saleId = _openWithOffset(offset);
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(e.closeAt, _oneEnd() + offset);
        assertEq(e.backstop, _oneEnd() + offset + 1 days);
    }

    /// @dev Marks the 1/1 settled at its end (6529 Stream's record too, unless `streamless`).
    function _closeOneOfOneAt(uint256, bool streamless) internal {
        english.set(address(stream), ID, IEnglishAuction.AuctionState.SETTLED, uint64(_oneEnd()));
        if (!streamless) stream.setSettled(ID, true);
    }

    // ------------------------------------------------------------------ the limits

    function test_SetLimits_CompareAndSetBoundsAndEvent() public {
        IUniformEditionAuction.Limits memory next =
            IUniformEditionAuction.Limits(60 days, 200, 200_000, 365);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.LimitsSet(_packedLimits(defaultLimits()), _packedLimits(next));
        _setLimits(next);
        IUniformEditionAuction.Limits memory got = ua.limits();
        assertEq(got.maxCloseOffset, 60 days);
        assertEq(got.voidDelayDays, 200);
        assertEq(got.payoutGas, 200_000);
        assertEq(got.rescueCapDays, 365);
        // A stale expectation.
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setLimits(_packedLimits(defaultLimits()), _packedLimits(next));
        // Each bound, one past it.
        IUniformEditionAuction.Limits[10] memory bad = [
            IUniformEditionAuction.Limits(1 days - 1, 150, 200_000, 730),
            IUniformEditionAuction.Limits(3650 days + 1, 150, 200_000, 730),
            IUniformEditionAuction.Limits(30 days, 119, 200_000, 730),
            IUniformEditionAuction.Limits(30 days, 731, 200_000, 730),
            IUniformEditionAuction.Limits(30 days, 150, 29_999, 730),
            IUniformEditionAuction.Limits(30 days, 150, 3_000_001, 730),
            IUniformEditionAuction.Limits(30 days, 150, 200_000, 89),
            IUniformEditionAuction.Limits(30 days, 150, 200_000, 731),
            // The payout gas only rises, at most doubling per change.
            IUniformEditionAuction.Limits(30 days, 150, 199_999, 730),
            IUniformEditionAuction.Limits(30 days, 150, 400_001, 730)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
            auction.setLimits(_packedLimits(next), _packedLimits(bad[i]));
        }
        // Bits past the packing.
        vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
        auction.setLimits(_packedLimits(next), _packedLimits(next) | 1 << 96);
        // The edges; the payout gas doubles to its ceiling and stays there.
        _setLimits(IUniformEditionAuction.Limits(1 days, 120, 400_000, 90));
        _setLimits(IUniformEditionAuction.Limits(3650 days, 730, 800_000, 730));
        _setLimits(IUniformEditionAuction.Limits(3650 days, 730, 1_600_000, 730));
        _setLimits(IUniformEditionAuction.Limits(3650 days, 730, 3_000_000, 730));
        // Restricted.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setLimits(0, 0);
    }

    /// @dev The default and the maximum stay ordered from both sides.
    function test_SetLimits_TheMaximumNeverFallsBelowTheDefault() public {
        IUniformEditionAuction.AuctionConfig memory c = defaultConfig();
        c.closeOffset = 2 days;
        _setConfig(c);
        IUniformEditionAuction.Limits memory l = defaultLimits();
        l.maxCloseOffset = 2 days - 1;
        vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
        auction.setLimits(_packedLimits(defaultLimits()), _packedLimits(l));
        l.maxCloseOffset = 2 days;
        _setLimits(l);
        c.closeOffset = 2 days + 1;
        IUniformEditionAuction.AuctionConfig memory current = ua.config();
        vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
        auction.setConfig(current, c);
    }

    // ------------------------------------------------------------------ the clocks

    /// @dev Every stored time is 32 bits. An open at or past 2^32 seconds is refused; a soft end
    ///      that would pass 2^32 reverts the bid (`ClockOverflow`) instead of wrapping.
    function test_Clocks_RevertAtTheBoundInsteadOfWrapping() public {
        uint256 limit = type(uint32).max;
        // A sale opened just before the bound, closing a few seconds before it.
        vm.warp(limit - 2 hours);
        english.set(
            address(stream), ID, IEnglishAuction.AuctionState.ACTIVE, uint64(limit - 30 minutes)
        );
        uint256 saleId = _openWithOffset(30 minutes - 10);
        // A bid in the window would push the soft end past 2^32 - 1.
        vm.warp(limit - 60);
        uint256 price = ua.stepPrice(saleId, 1);
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.ClockOverflow.selector, limit - 60 + 5 minutes
            )
        );
        auction.bid{ value: price }(saleId, 1, 1);
        // An open past the bound.
        vm.warp(limit + 1);
        english.set(address(stream), 9, IEnglishAuction.AuctionState.ACTIVE, uint64(limit + 1 days));
        PackageItem memory item = _item(9, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), 9)
        );
        auction.open(address(editions), 9, abi.encode(item));
    }

    // ------------------------------------------------------------------ the gas rule (see also
    //                                                                     the GasRule suite)

    /// @dev The 1/1's clock is read forwarding all gas: one that runs out reverts the open with
    ///      `BoundedCallShortfall`, never reads as a missing 1/1; one that refuses is a missing 1/1.
    function test_GasRule_ARefusedOrStarvedClockAtOpen() public {
        PackageItem memory item = _item(ID, 0);
        english.setRefuseClock(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.NoOneOfOneAuction.selector, address(stream), ID
            )
        );
        auction.open(address(editions), ID, abi.encode(item));
        english.setRefuseClock(false);
        english.setBurnClock(true);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(english))
        );
        auction.open{ gas: 2_000_000 }(address(editions), ID, abi.encode(item));
    }

    /// @dev The clearing call seals the edition at the count sold (ED-25), with Editions' event.
    function test_Settle_SealsTheEditionAtTheCount() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 10, 2);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        vm.expectEmit(address(editions));
        emit IEditions.EditionSupplySealed(ID, 2);
        auction.settle(saleId, new uint256[](0));
    }
}
