// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DutchPricing } from "src/sales/DutchPricing.sol";
import { DutchBase } from "./DutchBase.sol";

/// @notice Fuzzing of the Dutch price curve: monotonicity, bounds, endpoints, step shape,
///         rounding toward the seller and overflow freedom for any price.
contract DutchPricingTest is Test {
    struct Curve {
        uint256 start;
        uint256 rest;
        uint256 startTime;
        uint64 duration;
        uint64 step;
    }

    /// @dev A valid curve from arbitrary seeds, prices across the full uint256 range.
    function _curve(uint256 start, uint256 rest, uint256 t0, uint64 duration, uint64 step)
        internal
        pure
        returns (Curve memory c)
    {
        c.start = start;
        c.rest = bound(rest, 0, start);
        c.startTime = bound(t0, 0, type(uint64).max);
        if (step % 2 == 0) {
            c.duration = uint64(bound(duration, 1, 365 days));
        } else {
            // Equal drops: `count` steps of `c.step` seconds.
            uint64 count = uint64(bound(step, 1, 1000));
            c.step = uint64(bound(duration, 1, 365 days / count));
            c.duration = count * c.step;
        }
        assertTrue(DutchPricing.isValid(c.start, c.rest, c.duration, c.step));
    }

    function _price(Curve memory c, uint256 t) internal pure returns (uint256) {
        return DutchPricing.priceAt(c.start, c.rest, c.startTime, c.duration, c.step, t);
    }

    function testFuzz_PriceNeverRisesOverTime(
        uint256 start,
        uint256 rest,
        uint256 t0,
        uint64 duration,
        uint64 step,
        uint256 a,
        uint256 b
    ) public pure {
        Curve memory c = _curve(start, rest, t0, duration, step);
        uint256 t1 = bound(a, 0, c.startTime + 2 * uint256(c.duration));
        uint256 t2 = bound(b, t1, c.startTime + 2 * uint256(c.duration));
        assertGe(_price(c, t1), _price(c, t2));
    }

    function testFuzz_PriceStaysWithinItsBounds(
        uint256 start,
        uint256 rest,
        uint256 t0,
        uint64 duration,
        uint64 step,
        uint256 t
    ) public pure {
        Curve memory c = _curve(start, rest, t0, duration, step);
        uint256 price = _price(c, t);
        assertLe(price, c.start);
        assertGe(price, c.rest);
    }

    function testFuzz_Endpoints(
        uint256 start,
        uint256 rest,
        uint256 t0,
        uint64 duration,
        uint64 step,
        uint256 after_
    ) public pure {
        Curve memory c = _curve(start, rest, t0, duration, step);
        assertEq(_price(c, 0), c.start);
        assertEq(_price(c, c.startTime), c.start);
        uint256 end = c.startTime + c.duration;
        assertEq(_price(c, end), c.rest);
        assertEq(_price(c, bound(after_, end, type(uint256).max)), c.rest);
        if (c.start != c.rest && c.step == 0 && c.duration > 1) {
            // Just before the end the linear price has not yet reached rest unless rounding
            // reaches it exactly; it never undershoots.
            assertGe(_price(c, end - 1), c.rest);
        }
    }

    function testFuzz_SteppedIsConstantWithinAStepAndAboveLinear(
        uint256 start,
        uint256 rest,
        uint256 t0,
        uint64 duration,
        uint64 step,
        uint256 t
    ) public pure {
        Curve memory c = _curve(start, rest, t0, duration, step | 1);
        vm.assume(c.step != 0);
        uint256 moment = bound(t, c.startTime, c.startTime + c.duration);
        uint256 stepStart = moment - (moment - c.startTime) % c.step;
        assertEq(_price(c, moment), _price(c, stepStart));
        Curve memory linear = c;
        linear.step = 0;
        assertGe(_price(c, moment), _price(linear, moment));
    }

    function testFuzz_LinearRoundsTowardTheSeller(
        uint128 start,
        uint128 rest,
        uint64 duration,
        uint256 t
    ) public pure {
        Curve memory c = _curve(start, rest, 1000, duration, 0);
        uint256 moment = bound(t, c.startTime, c.startTime + c.duration);
        uint256 elapsed = moment - c.startTime;
        // price * duration >= start * duration - (start - rest) * elapsed (exact curve).
        uint256 lhs = _price(c, moment) * c.duration;
        uint256 rhs = c.start * c.duration - (c.start - c.rest) * elapsed;
        assertGe(lhs, rhs);
        assertLt(lhs - rhs, c.duration);
    }

    function test_IsValid() public pure {
        assertTrue(DutchPricing.isValid(10, 10, 0, 0));
        assertTrue(DutchPricing.isValid(10, 0, 100, 0));
        assertTrue(DutchPricing.isValid(10, 1, 100, 25));
        assertFalse(DutchPricing.isValid(10, 11, 100, 0));
        assertFalse(DutchPricing.isValid(10, 9, 0, 0));
        assertFalse(DutchPricing.isValid(10, 1, 100, 30));
    }
}

/// @notice The adapter's `currentPrice` never rises as time moves forward.
contract DutchCurrentPriceFuzzTest is DutchBase {
    function testFuzz_CurrentPriceIsMonotonic(uint16[6] calldata gaps, bool stepped) public {
        uint256 saleId = _openNow(stepped ? STEPPED : LINEAR);
        uint256 last = dutch.currentPrice(saleId);
        for (uint256 i; i < gaps.length; ++i) {
            vm.warp(block.timestamp + gaps[i] % 400);
            uint256 price = dutch.currentPrice(saleId);
            assertLe(price, last);
            last = price;
        }
    }
}
