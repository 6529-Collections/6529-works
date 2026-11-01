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
    ///      are minted and every wei is accounted for. Nightly runs it 10,000 times (deep).
    /// forge-config: deep.fuzz.runs = 10000
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
        bool done = auction.settle(saleId, lens.settlementOrderFor(saleId, address(this)));
        paidOut += balance - address(auction).balance;
        if (!done) {
            assertTrue(auction.settle(saleId, lens.settlementOrderFor(saleId, address(this))));
        }
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

    /// @dev The scan at its numeric limits: the widest governed ladder of the highest prices
    ///      (base 10^17 wei, 24 steps per decade, 512 steps: a top price near 2 × 10^38 wei),
    ///      every step holding its share of the most live units a sale can have (2^32 - 1), and
    ///      the cap one short of them, so the scan reads every word, carries the largest demand
    ///      and revenue through its scan word, and is rationed at step 0. The adapter must
    ///      settle exactly as `UniformClearing.clear` clears, in every field.
    function test_Settlement_AtTheNumericLimits() public {
        IUniformEditionAuction.AuctionConfig memory c = defaultConfig();
        (c.basePrice, c.stepsPerDecade, c.stepCount) = (1e17, 24, 512);
        _setConfig(c);
        uint256 total = type(uint32).max;
        uint256 each = total / 512;
        uint256 saleId = _open(uint32(total - 1));
        _bid(saleId, makeAddr("bottom"), 0, each + total % 512);
        for (uint256 step = 1; step < 512; ++step) {
            _bid(saleId, makeAddr("whale"), step, each);
        }
        assertEq(ua.auction(saleId).liveUnits, total, "every unit a sale can hold");
        IUniformEditionAuction.Clearing memory live = ua.clearing(saleId);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        // The first call scans 24 words and keeps its state in the scan word: the demand of 192
        // steps, below 2^32.
        assertFalse(auction.settle(saleId, new uint256[](0)));
        uint256 left = auction.storageWord(IUniformEditionAuctionStorage.Space.SCAN, saleId, 0);
        assertEq(uint8(left), 40, "the cursor: 64 words less 24");
        assertEq(uint32(left >> 8), 192 * each, "the demand so far");
        uint256 balance = address(auction).balance;
        for (
            uint256 i;
            !auction.settle(saleId, lens.settlementOrderFor(saleId, address(this)));
            ++i
        ) {
            require(i < 8, "settlement does not advance");
        }
        paidOut += balance - address(auction).balance;
        IUniformEditionAuction.Settlement memory s = ua.settlement(saleId);
        assertEq(s.count, live.count, "count");
        assertEq(s.step, live.step, "step");
        assertEq(s.price, live.price, "price");
        assertEq(s.rationed, live.rationed, "rationed");
        assertEq(s.cutUnits, live.cutUnits, "cut units");
        assertEq(live.revenue, live.count * live.price);
        assertGt(live.bestRevenue, 2 ** 128, "a revenue far past 128 bits");
    }

    /// @dev Every unit a sale can hold at the top of the highest ladder: the largest single
    ///      revenue (about 8.4 × 10^47 wei) goes through the scan and the payout unchanged.
    function test_Settlement_AllUnitsAtTheTopPrice() public {
        IUniformEditionAuction.AuctionConfig memory c = defaultConfig();
        (c.basePrice, c.stepsPerDecade, c.stepCount) = (1e17, 24, 512);
        _setConfig(c);
        uint256 saleId = _open(0);
        _bid(saleId, makeAddr("whale"), 511, type(uint32).max - 1);
        _bid(saleId, makeAddr("bottom"), 0, 1);
        IUniformEditionAuction.Clearing memory live = ua.clearing(saleId);
        assertEq(live.count, type(uint32).max - 1);
        assertEq(live.step, 511);
        _settle(saleId);
        assertEq(ua.settlement(saleId).count, live.count);
        assertEq(seller.balance + networkFee.balance, live.revenue, "paid in full");
        assertEq(_claimAll(saleId), live.count);
        _assertConserved();
    }

    /// @dev Every bid's claim against the lens, over any governed ladder and any chunking. The
    ///      ladder is random (24, 48, 96 or 192 steps per decade, any governed base price and
    ///      any step count the bounds allow), so a resumed scan starts in any decade. The book is
    ///      spread or clustered on a few steps, with raises and dispute withdrawals leaving
    ///      departures at the cut step. A griefer settles first with a random skipping or
    ///      out-of-order order (its progress, if any, is its own). The honest settler is then fed
    ///      random prefixes of the order, so its sweep resumes at any boundary. Before settling,
    ///      each live bid's `bidOutcome`
    ///      is read from the lens, which counts the live units ahead of a bid rather than
    ///      sweeping a cutoff; each claim must then pay exactly that outcome, and the sale must
    ///      mint exactly `k` and leave nothing behind.
    function testFuzz_Settlement_AnyLadderAndChunkingPaysEveryOutcome(
        uint256 seed,
        uint8 bids,
        uint32 maxCount,
        uint32 marginShare,
        uint256 ladder,
        bool spread
    ) public {
        uint256 steps = _randomLadder(ladder, marginShare);
        uint256 saleId = _open(uint32(bound(maxCount, 0, 300)));
        _randomBook(saleId, seed, bound(bids, 1, 60), steps, spread);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        IUniformEditionAuction.Clearing memory live = ua.clearing(saleId);
        uint256 count = ua.auction(saleId).bidCount;
        IUniformEditionAuction.BidOutcome[] memory outcomes =
            new IUniformEditionAuction.BidOutcome[](count + 1);
        for (uint256 bidId = 1; bidId <= count; ++bidId) {
            if (_live(saleId, bidId)) outcomes[bidId] = ua.bidOutcome(saleId, bidId);
        }
        _grief(saleId, seed);
        _settleInRandomSlices(saleId, seed);
        IUniformEditionAuction.Settlement memory s = ua.settlement(saleId);
        assertEq(s.count, live.count, "count");
        assertEq(s.price, live.price, "price");
        assertEq(s.rationed, live.rationed, "rationed");
        if (live.rationed) assertEq(s.cutoff, live.cutoff, "cutoff");
        assertEq(_claimAgainst(saleId, outcomes), live.count, "exactly k");
        _assertConserved();
        assertEq(address(auction).balance, 0, "nothing left behind");
    }

    /// @dev Sets a random governed ladder and margin; returns its step count. A ladder whose top
    ///      step is below the 10 ETH floor becomes the widest, highest one of its kind.
    function _randomLadder(uint256 ladder, uint32 marginShare) internal returns (uint256) {
        IUniformEditionAuction.AuctionConfig memory c = defaultConfig();
        c.stepsPerDecade = uint16(24 << (ladder % 4));
        // Governed base prices are the powers of ten from 10^12 to 10^17 (`isBasePrice`).
        c.basePrice = uint96(10 ** (12 + (ladder >> 8) % 6));
        c.stepCount = uint16(bound(ladder >> 128, 64, 512));
        c.marginShare = uint32(bound(marginShare, 0, 50_000));
        try auction.setConfig(auction.config(), c) { }
        catch {
            (c.basePrice, c.stepCount) = (1e17, 512);
            _setConfig(c);
        }
        return c.stepCount;
    }

    /// @dev `bids` random bids over `steps` steps, spread or on four steps, with every third
    ///      raising an earlier live bid and every fifth (otherwise) withdrawing one during a
    ///      dispute pause: departures in a capped sale.
    function _randomBook(uint256 saleId, uint256 seed, uint256 bids, uint256 steps, bool spread)
        internal
    {
        uint256 low = bound(seed >> 200, 0, steps - 8);
        for (uint256 i; i < bids; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _bid(
                saleId,
                makeAddr(vm.toString(i % 7)),
                spread ? r % steps : low + r % 4,
                1 + (r >> 16) % 40
            );
            uint256 bidId = 1 + (r >> 32) % (i + 1);
            if (!_live(saleId, bidId)) continue;
            if (i % 3 == 2) {
                uint256 from = ua.bidOf(saleId, bidId).step;
                uint256 room = steps - 1 - from;
                // Clustered books raise by one or two steps, so departures stay near the cut.
                uint256 span = spread || room < 2 ? room : 2;
                if (room != 0) _raise(saleId, bidId, from + 1 + (r >> 40) % span);
            } else if (i % 5 == 4) {
                _withdrawDuringPause(saleId, bidId);
            }
        }
    }

    /// @dev A griefer's settle call with the order corrupted: one entry dropped (a strictly
    ///      increasing subset) or two neighbours swapped. It may scan, clear and pay, or revert;
    ///      it must never finish the sweep or strand the sale.
    function _grief(uint256 saleId, uint256 seed) internal {
        uint256[] memory order = ua.settlementOrder(saleId);
        uint256 r = uint256(keccak256(abi.encode(seed, "grief")));
        bool corrupted = order.length >= 2;
        if (corrupted) {
            uint256 k = r % order.length;
            if ((r >> 64) % 2 == 0) {
                for (uint256 i = k; i + 1 < order.length; ++i) {
                    order[i] = order[i + 1];
                }
                uint256 shorter = order.length - 1;
                assembly ("memory-safe") {
                    mstore(order, shorter)
                }
            } else {
                uint256 j = k + 1 == order.length ? k - 1 : k + 1;
                (order[k], order[j]) = (order[j], order[k]);
            }
        }
        uint256 balance = address(auction).balance;
        vm.prank(makeAddr("griefer"));
        try auction.settle(saleId, order) returns (bool settled) {
            assertFalse(corrupted && settled, "a corrupted order never completes the sweep");
        } catch { }
        paidOut += balance - address(auction).balance;
    }

    /// @dev The honest settler: on each call, a random nonempty prefix of the rest of its own
    ///      sweep (`settlementOrderFor`), so its sweep stops and resumes at arbitrary points.
    function _settleInRandomSlices(uint256 saleId, uint256 seed) internal {
        uint256 balance = address(auction).balance;
        for (uint256 call;; ++call) {
            require(call < 64, "settlement does not advance");
            uint256[] memory order = lens.settlementOrderFor(saleId, address(this));
            uint256 take = order.length == 0
                ? 0
                : 1 + uint256(keccak256(abi.encode(seed, "slice", call))) % order.length;
            assembly ("memory-safe") {
                mstore(order, take)
            }
            if (auction.settle(saleId, order)) break;
        }
        paidOut += balance - address(auction).balance;
    }

    /// @dev A 600-departure cut step settled by a fresh settler in slices of at most one chunk:
    ///      each call's calldata carries only its chunk (16 entries in the clearing call, 96
    ///      after), and each call stays within 350,000 gas.
    function test_Settlement_SixHundredDeparturesInChunkSlices() public {
        uint256 saleId = _open(900);
        address crowd = makeAddr("crowd");
        for (uint256 i; i < 1200; ++i) {
            _bid(saleId, crowd, 100, 1);
        }
        for (uint256 bidId = 1200; bidId > 600; --bidId) {
            _raise(saleId, bidId, 101);
        }
        IUniformEditionAuction.Clearing memory live = ua.clearing(saleId);
        assertEq(live.step, 100);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        address keeper = makeAddr("keeper");
        uint256 balance = address(auction).balance;
        uint256 calls;
        for (bool settled; !settled; ++calls) {
            require(calls < 16, "settlement does not advance");
            uint256[] memory rest = lens.settlementOrderFor(saleId, keeper);
            uint256 chunk = calls == 0 ? 16 : 96;
            if (rest.length > chunk) {
                assembly ("memory-safe") {
                    mstore(rest, chunk)
                }
            }
            bytes memory data = abi.encodeCall(auction.settle, (saleId, rest));
            assertLe(data.length, 4 + 32 * (3 + 96), "calldata of one chunk");
            vm.prank(keeper);
            uint256 g = gasleft();
            (bool ok, bytes memory ret) = address(auction).call(data);
            uint256 used = g - gasleft();
            assertTrue(ok);
            assertLe(used, 350_000, "each call within the settlement budget");
            settled = abi.decode(ret, (bool));
        }
        paidOut += balance - address(auction).balance;
        assertEq(calls, 8, "16, then six chunks of 96, then 8");
        assertEq(ua.settlement(saleId).cutoff, live.cutoff);
        assertEq(_claimAll(saleId), 900);
        _assertConserved();
    }

    /// @dev Claims every live bid for its bidder and checks each against `outcomes`; returns the
    ///      copies minted.
    function _claimAgainst(uint256 saleId, IUniformEditionAuction.BidOutcome[] memory outcomes)
        internal
        returns (uint256 minted)
    {
        for (uint256 bidId = 1; bidId < outcomes.length; ++bidId) {
            if (!_live(saleId, bidId)) continue;
            address bidder = ua.bidOf(saleId, bidId).bidder;
            vm.prank(bidder);
            (uint256 won, uint256 refund) = auction.claimBid(saleId, bidId, bidder);
            assertEq(won, outcomes[bidId].unitsWon, "units won as the lens said");
            assertEq(refund, outcomes[bidId].refund, "refund as the lens said");
            minted += won;
            refundsOut += refund;
        }
    }
}
