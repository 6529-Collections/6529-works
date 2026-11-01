// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice Regression for the review finding on `_sweep` (PR #77, 2026-10-31): a settle call whose
///         order skips a departure (strictly increasing positions, but not every departure) is
///         accepted, moves `nextPosition` past the skipped one, and leaves the sweep unable to
///         finish: the sale stays SETTLING and no bid can ever be claimed.
/// @dev Failed on 087b245 and ebbf3e2: the sale never settled. Fixed by per-settler sweep
///      progress: a skipping order strands only its own sender's progress.
contract SweepSkipRegressionTest is EditionAuctionBase {
    function test_Settle_ASkippedDepartureCannotStrandTheSale() public {
        uint256 saleId = _open(5);
        _bid(saleId, makeAddr("alice"), 10, 2); // position 0
        _bid(saleId, makeAddr("bob"), 10, 2); // position 2
        _bid(saleId, makeAddr("carol"), 10, 3); // position 4
        _bid(saleId, makeAddr("dan"), 10, 3); // position 7
        _raise(saleId, 2, 11); // departure 0: position 2
        _raise(saleId, 1, 11); // departure 1: position 0
        IUniformEditionAuction.Clearing memory c = ua.clearing(saleId);
        assertTrue(c.rationed);
        assertEq(c.step, 10);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        // Anyone settles first, with an order that skips departure 1 (position 0).
        uint256[] memory skip = new uint256[](1);
        skip[0] = 0;
        vm.prank(makeAddr("anyone"));
        auction.settle(saleId, skip);
        // An honest settler must still be able to finish, with the correct cutoff.
        for (
            uint256 i;
            !auction.settle(saleId, lens.settlementOrderFor(saleId, address(this)));
            ++i
        ) {
            require(i < 8, "settlement stranded: SETTLING forever, every claim refused");
        }
        assertEq(ua.settlement(saleId).cutoff, c.cutoff, "the cutoff counts every departure");
        assertEq(_claimAll(saleId), 5);
    }

    /// @dev The skipping settler itself is stuck (its next entry is below its progress), but
    ///      its stranded progress is its own: it never reaches the result or the sale.
    function test_Settle_ASkippingSettlerStrandsOnlyItself() public {
        uint256 saleId = _fourBidsTwoDepartures();
        address griefer = makeAddr("griefer");
        uint256[] memory skip = new uint256[](1);
        skip[0] = 0;
        uint256 balance = address(auction).balance;
        vm.prank(griefer);
        assertFalse(auction.settle(saleId, skip));
        paidOut += balance - address(auction).balance;
        // Its own rest (position 0 is behind its progress) can never be swept.
        uint256[] memory order = ua.settlementOrder(saleId);
        uint256[] memory left = new uint256[](1);
        left[0] = 1;
        vm.prank(griefer);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.InvalidSettlementOrder.selector, 0)
        );
        auction.settle(saleId, left);
        assertEq(ua.settlement(saleId).departuresSwept, 0, "nothing shared moved");
        assertTrue(auction.settle(saleId, order), "an honest settler finishes in one call");
        // After the sale settled, the griefer's call stops cleanly.
        vm.prank(griefer);
        assertTrue(auction.settle(saleId, order));
        assertEq(_claimAll(saleId), 5);
        _assertConserved();
    }

    /// @dev Two honest settlers interleave chunks of a long sweep: each resumes its own
    ///      progress, the first to sweep every departure settles the sale, with the cutoff the
    ///      lens computes, and the other's later call stops cleanly.
    function test_Settle_TwoSettlersInterleaveChunks() public {
        uint256 saleId = _open(250);
        address crowd = makeAddr("crowd");
        // 300 one-unit bids at step 10; 200 of them raised to step 11 in reverse order: 200
        // departures at the cut step, so the sweep takes several chunks.
        for (uint256 i; i < 300; ++i) {
            _bid(saleId, crowd, 10, 1);
        }
        for (uint256 bidId = 300; bidId > 100; --bidId) {
            _raise(saleId, bidId, 11);
        }
        IUniformEditionAuction.Clearing memory c = ua.clearing(saleId);
        assertEq(c.step, 10);
        assertTrue(c.rationed);
        uint256[] memory order = ua.settlementOrder(saleId);
        assertEq(order.length, 200);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        address one = makeAddr("settlerOne");
        address two = makeAddr("settlerTwo");
        uint256 balance = address(auction).balance;
        vm.prank(one);
        assertFalse(auction.settle(saleId, order)); // clears, pays, sweeps 16
        paidOut += balance - address(auction).balance;
        _settleAs(two, saleId, false); // its own first 96
        _settleAs(one, saleId, false); // 16 + 96 = 112
        (uint256 oneSwept,,) = lens.sweepOf(saleId, one);
        (uint256 twoSwept,,) = lens.sweepOf(saleId, two);
        assertEq(oneSwept, 112);
        assertEq(twoSwept, 96);
        _settleAs(two, saleId, false); // 192
        _settleAs(two, saleId, true); // 200: settled by the second settler
        vm.prank(one);
        assertTrue(auction.settle(saleId, order), "the other's call stops cleanly");
        IUniformEditionAuction.Settlement memory s = ua.settlement(saleId);
        assertEq(s.cutoff, c.cutoff);
        assertEq(s.departuresSwept, 200);
        assertEq(_claimAll(saleId), 250);
        _assertConserved();
    }

    function _settleAs(address settler, uint256 saleId, bool settles) internal {
        uint256[] memory rest = lens.settlementOrderFor(saleId, settler);
        vm.prank(settler);
        assertEq(auction.settle(saleId, rest), settles);
    }

    function _fourBidsTwoDepartures() internal returns (uint256 saleId) {
        saleId = _open(5);
        _bid(saleId, makeAddr("alice"), 10, 2); // position 0
        _bid(saleId, makeAddr("bob"), 10, 2); // position 2
        _bid(saleId, makeAddr("carol"), 10, 3); // position 4
        _bid(saleId, makeAddr("dan"), 10, 3); // position 7
        _raise(saleId, 2, 11); // departure 0: position 2
        _raise(saleId, 1, 11); // departure 1: position 0
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
    }
}
