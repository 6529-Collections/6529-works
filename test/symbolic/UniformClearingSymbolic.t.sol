// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { UniformClearing } from "src/sales/UniformClearing.sol";
import { StepLadder } from "src/interfaces/types/StepLadder.sol";

/// @notice Halmos proofs for the edition auction's clearing library (docs/testing/README.md,
///         "Symbolic"): the ladder, the D138 clearing rule unit by unit, and the cut step's
///         first-in-first-out split.
/// @dev The ladder proof covers every index of `StepLadder`'s table (UNBOUNDED): every entry
///      lies in 100..988, rises with the index, and the last is below ten times the first. With
///      every base of at least 100, `floor(base * x / 100)` rises with the integer `x`, so every
///      price of every ladder rises with the step; test/interfaces/StepLadder.t.sol pins every
///      price to the golden vector, and test/sales/uniform checks every step of every ladder at
///      the domain's extreme bases. A proof over the prices themselves, symbolic in the base,
///      needs 256-bit division by 100 and timed out. The clearing proofs are BOUNDED: books of 3
///      used steps uncapped, or 2 with every cap below 256, of up to 255 units a step; the
///      library branches on every used step, so the paths multiply with the steps, and these fit
///      the CI job. The split proof covers queues of 5 entries. The differential fuzz tests in
///      test/sales/uniform cover larger books.
contract UniformClearingSymbolicTest is Test {
    /// @dev The clearing proofs price books on the 100-wei base: every decade of a ladder has
    ///      the same price ratios, so the rule decides alike, and the solver's constants stay
    ///      small.
    uint256 internal constant BASE = 100;
    uint256 internal constant D = 100_000;

    // ---------------------------------------------------------------------------------------
    // The ladder
    // ---------------------------------------------------------------------------------------

    /// @notice The packed table decodes to 192 mantissas from 100 to 988 that strictly rise
    ///         with the index, and the last is below ten times the first, so every ladder (a
    ///         subset of the table, scaled by ten each decade) rises across decade boundaries too.
    ///         Every index; the exact values are pinned to the golden vector by
    ///         test/interfaces/StepLadder.t.sol.
    function check_mantissa_isBoundedAndStrictlyIncreasing(uint256 j) public pure {
        assert(StepLadder.mantissa(191) < 10 * StepLadder.mantissa(0));
        if (j >= 191) return;
        uint256 m = StepLadder.mantissa(j);
        assert(m >= 100 && m < StepLadder.mantissa(j + 1) && StepLadder.mantissa(j + 1) <= 988);
    }

    // ---------------------------------------------------------------------------------------
    // Clearing: D138 unit by unit
    // ---------------------------------------------------------------------------------------

    // Branch-free helpers with bit masks, so the reference adds no paths of its own and no
    // product of two symbolic values (which the solver handles far worse than bit operations).

    function _min(uint256 a, uint256 b) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := xor(b, and(xor(a, b), sub(0, lt(a, b))))
        }
    }

    function _select(bool c, uint256 a, uint256 b) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := xor(b, and(xor(a, b), sub(0, c)))
        }
    }

    /// @dev The price and step of the k-th highest unit (1 <= k <= the book's units) of a book
    ///      with `t[i]` units at step `steps[i]` (ascending), the units strictly above it, and
    ///      `revenue(k) = k * P(k)`.
    function _unit(uint256[] memory t, uint256[] memory steps, uint256 k)
        internal
        pure
        returns (uint256 p, uint256 step, uint256 above, uint256 revenue)
    {
        uint256 d;
        bool found;
        for (uint256 i = t.length; i != 0;) {
            --i;
            uint256 next = d + t[i];
            // The first step from the top whose units reach k.
            bool here;
            assembly ("memory-safe") {
                here := and(iszero(found), iszero(gt(k, next)))
                found := or(found, here)
            }
            uint256 pi = StepLadder.price(BASE, 48, steps[i]);
            p = _select(here, pi, p);
            revenue = _select(here, k * pi, revenue);
            step = _select(here, steps[i], step);
            above = _select(here, d, above);
            d = next;
        }
    }

    /// @dev Whether `best` is the revenue of some step top: the count `min(D_s, units)` at the
    ///      price of a step `s`.
    function _attained(uint256[] memory t, uint256[] memory steps, uint256 units, uint256 best)
        internal
        pure
        returns (bool hit)
    {
        uint256 d;
        for (uint256 i = t.length; i != 0;) {
            --i;
            d += t[i];
            uint256 revenue = _min(d, units) * StepLadder.price(BASE, 48, steps[i]);
            assembly ("memory-safe") {
                hit := or(hit, and(iszero(iszero(revenue)), eq(revenue, best)))
            }
        }
    }

    /// @dev D138 checked unit by unit on a book of `t.length` steps: the result is the
    ///      `count`-th unit's step and price, with the cut step's fields; `R*` is the revenue of
    ///      a step top (so of some count); the result passes the margin; and the symbolic count
    ///      `k` earns at most `R*` and, above the result, fails the margin.
    function _clearing(
        uint256[] memory t,
        uint256 cap,
        uint256 k,
        uint256[] memory steps,
        uint256 margin
    ) internal pure {
        uint256 units;
        UniformClearing.Result memory r;
        {
            uint256[] memory live = new uint256[](steps[steps.length - 1] / 8 + 1);
            uint256 total;
            for (uint256 i; i < t.length; ++i) {
                live[steps[i] >> 3] |= t[i] << ((steps[i] & 7) * 32);
                total += t[i];
            }
            r = UniformClearing.clear(
                live,
                UniformClearing.Rules({
                    basePrice: BASE, stepsPerDecade: 48, maxCount: cap, marginShare: margin
                })
            );
            units = _select(cap == 0, total, _min(cap, total));
        }
        if (units == 0) {
            assert(r.count == 0 && r.step == 0 && r.price == 0 && r.bestRevenue == 0);
            assert(r.cutUnits == 0 && r.unitsAtStep == 0 && !r.rationed);
            return;
        }
        assert(r.count >= 1 && r.count <= units);
        {
            (uint256 p, uint256 step, uint256 above,) = _unit(t, steps, r.count);
            assert(r.step == step && r.price == p);
            assert(r.cutUnits == r.count - above);
            uint256 atStep;
            for (uint256 i; i < t.length; ++i) {
                atStep = _select(steps[i] == step, t[i], atStep);
            }
            assert(r.unitsAtStep == atStep);
            assert(r.rationed == (r.cutUnits < atStep));
        }
        assert(_attained(t, steps, units, r.bestRevenue));
        assert(r.count * r.price * D >= r.bestRevenue * (D - margin));
        if (k == 0 || k > units) return;
        (,,, uint256 revenue) = _unit(t, steps, k);
        assert(revenue <= r.bestRevenue);
        // No count above the result passes the margin.
        assert(k <= r.count || revenue * D < r.bestRevenue * (D - margin));
    }

    function _list(uint256 a, uint256 b, uint256 c, uint256 d, uint256 n)
        internal
        pure
        returns (uint256[] memory r)
    {
        r = new uint256[](n);
        (r[0], r[1]) = (a, b);
        if (n > 2) r[2] = c;
        if (n > 3) r[3] = d;
    }

    /// @notice D138 without a cap on three steps a decade apart (0, 48 and 96), at the default
    ///         10% margin: every book of 0 to 255 units a step, every count `k`.
    function check_clear_isD138UncappedOnThreeSteps(uint8 a, uint8 b, uint8 c, uint256 k)
        public
        pure
    {
        _clearing(_list(a, b, c, 0, 3), 0, k, _list(0, 48, 96, 0, 3), 10_000);
    }

    /// @notice D138 with a creator cap: two neighbouring steps, every cap from 1 to 255, at the
    ///         default margin. The cap may bind inside either step or above both.
    function check_clear_isD138CappedOnTwoSteps(uint8 a, uint8 b, uint8 cap, uint256 k)
        public
        pure
    {
        if (cap == 0) return;
        _clearing(_list(a, b, 0, 0, 2), cap, k, _list(2, 3, 0, 0, 2), 10_000);
    }

    /// @notice D138 without a margin, the largest count earning the maximum: two steps a decade
    ///         apart (0 and 48), every cap below 256 or none.
    function check_clear_isD138WithNoMargin(uint8 a, uint8 b, uint8 cap, uint256 k) public pure {
        _clearing(_list(a, b, 0, 0, 2), cap, k, _list(0, 48, 0, 0, 2), 0);
    }

    /// @notice D138 at the largest margin the governed bounds allow, 50%: two steps of PLAN
    ///         Appendix C's ratio (0.01 and 0.0511 ETH on the default ladder, steps 0 and 34
    ///         here), every cap below 256 or none.
    function check_clear_isD138AtTheLargestMargin(uint8 a, uint8 b, uint8 cap, uint256 k)
        public
        pure
    {
        _clearing(_list(a, b, 0, 0, 2), cap, k, _list(0, 34, 0, 0, 2), 50_000);
    }

    // ---------------------------------------------------------------------------------------
    // The cut step
    // ---------------------------------------------------------------------------------------

    /// @notice First in, first out at a split cut step: for every queue of 5 entries of up to
    ///         255 units each, any of which may have left (a raise out or a dispute withdrawal),
    ///         and every cut of the live units, the swept cut-off hands out exactly the cut, and
    ///         no entry wins while an earlier one is short.
    function check_sweep_unitsWonSumToTheCutInArrivalOrder(
        uint8[5] memory q,
        bool[5] memory gone,
        uint256 cut
    ) public pure {
        uint256[5] memory pos;
        uint256 entered;
        uint256 live;
        for (uint256 i; i < 5; ++i) {
            if (q[i] == 0) return; // a log entry always has units
            pos[i] = entered;
            entered += q[i];
            if (!gone[i]) live += q[i];
        }
        if (cut == 0 || cut > live) return;
        uint256 x = cut;
        uint256 minPos;
        for (uint256 i; i < 5; ++i) {
            if (gone[i]) (x, minPos) = UniformClearing.sweep(x, minPos, pos[i], q[i], i);
        }
        uint256 sum;
        bool short;
        for (uint256 i; i < 5; ++i) {
            if (gone[i]) continue;
            uint256 won = UniformClearing.wonAtCut(x, pos[i], q[i]);
            assert(won <= q[i]);
            if (won != 0) assert(!short);
            if (won < q[i]) short = true;
            sum += won;
        }
        assert(sum == cut);
    }

    /// @dev External, so a revert in `sweep` can be observed.
    function sweep(uint256 cutoff, uint256 minPos, uint256 pos, uint256 qty)
        external
        pure
        returns (uint256, uint256)
    {
        return UniformClearing.sweep(cutoff, minPos, pos, qty, 0);
    }

    /// @notice The sweep accepts a departure exactly when it holds units and lies strictly after
    ///         the previous one, and then moves the cut-off past it only when it starts below.
    function check_sweep_acceptsExactlyTheNextDeparture(
        uint64 cutoff,
        uint64 minPos,
        uint64 pos,
        uint64 qty
    ) public view {
        try this.sweep(cutoff, minPos, pos, qty) returns (uint256 x, uint256 next) {
            assert(qty != 0 && pos >= minPos);
            assert(x == (pos < cutoff ? uint256(cutoff) + qty : cutoff));
            assert(next == uint256(pos) + 1);
        } catch {
            assert(qty == 0 || pos < minPos);
        }
    }

    /// @notice `wonAtCut` is `clamp(cutoff - pos, 0, qty)` for every input.
    function check_wonAtCut_isTheClamp(uint256 cutoff, uint256 pos, uint256 qty) public pure {
        uint256 won = UniformClearing.wonAtCut(cutoff, pos, qty);
        if (cutoff <= pos) assert(won == 0);
        else if (cutoff - pos >= qty) assert(won == qty);
        else assert(won == cutoff - pos);
    }
}
