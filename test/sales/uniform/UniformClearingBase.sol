// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { UniformClearing } from "src/sales/UniformClearing.sol";
import { StepLadder } from "src/interfaces/types/StepLadder.sol";

/// @notice External wrappers of {UniformClearing}, so a revert surfaces at a call boundary and
///         gas is metered per call.
contract UniformClearingHarness {
    function isValidLadder(uint256 base, uint256 perDecade) external pure returns (bool) {
        return UniformClearing.isValidLadder(base, perDecade);
    }

    function price(uint256 base, uint256 perDecade, uint256 step) external pure returns (uint256) {
        return StepLadder.price(base, perDecade, step);
    }

    function clear(uint256[] memory live, UniformClearing.Rules memory rules)
        external
        pure
        returns (UniformClearing.Result memory)
    {
        return UniformClearing.clear(live, rules);
    }

    function quote(
        uint256[] memory live,
        UniformClearing.Rules memory rules,
        uint256 step,
        uint256 qty
    )
        external
        pure
        returns (UniformClearing.Result memory result, uint256 won, uint256[] memory after_)
    {
        (result, won) = UniformClearing.quote(live, rules, step, qty);
        after_ = live;
    }

    function sweep(uint256 cutoff, uint256 minPos, uint256 pos, uint256 qty, uint256 index)
        external
        pure
        returns (uint256, uint256)
    {
        return UniformClearing.sweep(cutoff, minPos, pos, qty, index);
    }

    function wonAtCut(uint256 cutoff, uint256 pos, uint256 qty) external pure returns (uint256) {
        return UniformClearing.wonAtCut(cutoff, pos, qty);
    }
}

/// @notice Shared fixtures for the {UniformClearing} suites: the default terms, a packed-book
///         builder, a brute-force reference that expands bids into units, and a seeded generator.
abstract contract UniformClearingBase is Test {
    uint256 internal constant BASE = 1e14; // 0.0001 ETH
    uint256 internal constant N = 48;

    UniformClearingHarness internal h;

    function setUp() public virtual {
        h = new UniformClearingHarness();
    }

    uint256 internal constant TEN_PERCENT = 10_000; // the default margin, out of 100,000

    function _rules(uint256 cap, uint256 marginShare)
        internal
        pure
        returns (UniformClearing.Rules memory)
    {
        return UniformClearing.Rules({
            basePrice: BASE, stepsPerDecade: N, maxCount: cap, marginShare: marginShare
        });
    }

    /// @dev The packed book of `words` words holding `units[i]` at `steps[i]` (repeats add).
    function _book(uint256[] memory steps, uint256[] memory units, uint256 words)
        internal
        pure
        returns (uint256[] memory live)
    {
        live = new uint256[](words);
        for (uint256 i; i < steps.length; ++i) {
            uint256 lane = (live[steps[i] >> 3] >> ((steps[i] & 7) * 32)) & type(uint32).max;
            require(lane + units[i] <= type(uint32).max, "lane overflow");
            live[steps[i] >> 3] += units[i] << ((steps[i] & 7) * 32);
        }
    }

    function _unitsAt(uint256[] memory live, uint256 step) internal pure returns (uint256) {
        return (live[step >> 3] >> ((step & 7) * 32)) & type(uint32).max;
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (a, b);
    }

    /// @dev The trace-2 book of PLAN Appendix C: the owner's bids snapped to the default ladder.
    function _trace2() internal pure returns (uint256[] memory steps, uint256[] memory units) {
        steps = new uint256[](5);
        units = new uint256[](5);
        (steps[0], steps[1], steps[2], steps[3], steps[4]) = (96, 130, 144, 158, 192);
        (units[0], units[1], units[2], units[3], units[4]) = (200, 50, 20, 9, 1);
    }

    /// @dev D138 by definition: every live unit as its own bid, sorted from the highest price,
    ///      cut to the cap; `revenue(k) = k * P(k)` for every `k`; the largest `k` within the
    ///      margin of the best. `prices[s]` is step `s`'s price; `totals[s]` its live units.
    function _bruteForce(uint256[] memory prices, uint256[] memory totals, uint256 cap, uint256 m)
        internal
        pure
        returns (UniformClearing.Result memory r)
    {
        uint256 total;
        for (uint256 s; s < totals.length; ++s) {
            total += totals[s];
        }
        uint256 n = cap != 0 && cap < total ? cap : total;
        if (n == 0) return r;
        uint256[] memory unitStep = new uint256[](n);
        uint256 filled;
        for (uint256 s = totals.length; s != 0 && filled < n;) {
            --s;
            for (uint256 u; u < totals[s] && filled < n; ++u) {
                unitStep[filled++] = s;
            }
        }
        for (uint256 k = 1; k <= n; ++k) {
            uint256 revenue = k * prices[unitStep[k - 1]];
            if (revenue > r.bestRevenue) r.bestRevenue = revenue;
        }
        for (uint256 k = n; k != 0; --k) {
            if (k * prices[unitStep[k - 1]] * 100_000 >= r.bestRevenue * (100_000 - m)) {
                r.count = k;
                break;
            }
        }
        r.step = unitStep[r.count - 1];
        r.price = prices[r.step];
        uint256 above;
        for (uint256 s = r.step + 1; s < totals.length; ++s) {
            above += totals[s];
        }
        r.cutUnits = r.count - above;
        r.unitsAtStep = totals[r.step];
        r.rationed = r.cutUnits < r.unitsAtStep;
    }

    /// @dev The next value of a seeded stream.
    function _next(uint256 seed) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed)));
    }

    /// @dev Terms drawn from `seed`: every governed ladder; bases from 100 wei to 2**96 - 1,
    ///      multiples of 100 or not; caps including none; margins from 0 to 100%.
    function _randomRules(uint256 seed, uint256 total)
        internal
        pure
        returns (UniformClearing.Rules memory r)
    {
        uint256[4] memory ladders = [uint256(24), 48, 96, 192];
        r.stepsPerDecade = ladders[seed % 4];
        seed = _next(seed);
        uint256 b = seed % 7;
        r.basePrice = b < 2
            ? BASE
            : b == 2
                ? 100
                : b == 3
                    ? 1e12 + 1
                    : b == 4
                        ? 1e17
                        : b == 5
                            ? type(uint96).max
                            : 100 + _next(seed) % (uint256(type(uint96).max) - 99);
        seed = _next(seed);
        uint256 c = seed % 9;
        r.maxCount = c < 3 ? 0 : c == 3 ? 1 : c == 4 ? 3 : c == 5 ? 10 : _next(seed) % (total + 4);
        seed = _next(seed);
        uint256 m = seed % 8;
        r.marginShare = m < 3
            ? TEN_PERCENT
            : m == 3
                ? 0
                : m == 4 ? 25_000 : m == 5 ? 50_000 : m == 6 ? 100_000 : _next(seed) % 100_001;
    }
}
