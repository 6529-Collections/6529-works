// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title UniformClearing
/// @notice The pure core of the 6529 Stream Editions uniform-price auction (D138): the fixed
///         price ladder, the clearing rule, the first-in-first-out split of the cut step and the
///         what-if quote behind the views. The auction, its views and the Halmos proofs share
///         this one implementation.
/// @dev Internal functions only, so nothing here is linked. Every function is pure.
///
///      **The book.** The caller passes the live units per step as packed words: `live[w]` holds
///      steps `8w` to `8w + 7`, step `8w + i` in bits `32i` to `32i + 31`. A book has at most
///      {MAX_STEPS} steps, so at most 64 words.
///
///      **The ladder** ({price}). Step `s` costs `basePrice * M[(s % N) * (192 / N)] *
///      10**(s / N) / 100` wei, dividing last, where `N` is the number of steps per decade and
///      `M` the 192 three-digit mantissas `round(100 * 10**(j / 192))`, rounded half up (E192).
///      Each `N` (24, 48, 96 or 192) uses a subset of the one table, so prices read cleanly
///      (0.0464, 0.0487, 0.0511 ETH at the default `N` of 48 and base of 0.0001 ETH), need no
///      storage, and every client reproduces them exactly.
///
///      **Units.** The breadth margin is a share out of {DENOMINATOR} (100,000), like every
///      other share in the protocol.
library UniformClearing {
    /// @notice The clearing terms of one auction, locked when it opens.
    /// @param basePrice The price of step 0 in wei, at least 100 and below 2**96.
    /// @param stepsPerDecade Steps per tenfold rise, `N`: 24, 48, 96 or 192.
    /// @param maxCount The creator's cap on the number of editions; 0 means no cap.
    /// @param marginShare The breadth margin, out of {DENOMINATOR}.
    struct Rules {
        uint256 basePrice;
        uint256 stepsPerDecade;
        uint256 maxCount;
        uint256 marginShare;
    }

    /// @notice The result of clearing a book.
    /// @param count `k`, the number of editions sold; 0 only for an empty book.
    /// @param step The clearing step, whose price every winner pays; 0 when `count` is 0.
    /// @param price The clearing step's price in wei; 0 when `count` is 0.
    /// @param bestRevenue `R*`, the highest revenue of any count up to the cap.
    /// @param rationed Whether the cap binds inside `step`, so its queue is split.
    /// @param cutUnits The units that win at `step`: `count` minus the units above it.
    /// @param unitsAtStep The live units at `step`.
    struct Result {
        uint256 count;
        uint256 step;
        uint256 price;
        uint256 bestRevenue;
        bool rationed;
        uint256 cutUnits;
        uint256 unitsAtStep;
    }

    /// @notice The most steps a book may have: 64 packed words of 8 steps.
    uint256 internal constant MAX_STEPS = 512;

    /// @notice The denominator of the breadth margin: 100,000 parts make the whole.
    uint256 internal constant DENOMINATOR = 100_000;

    /// @notice The most units one step can hold (a 32-bit lane).
    uint256 internal constant MAX_STEP_UNITS = type(uint32).max;

    /// @notice The ladder is outside the library's domain: see {isValidLadder}.
    /// @param basePrice The rejected base price.
    /// @param stepsPerDecade The rejected number of steps per decade.
    error UnsupportedLadder(uint256 basePrice, uint256 stepsPerDecade);

    /// @notice The book has more than {MAX_STEPS} steps.
    /// @param steps The number of steps the book's words cover.
    error TooManySteps(uint256 steps);

    /// @notice The breadth margin is above {DENOMINATOR}.
    /// @param marginShare The rejected margin.
    error MarginTooLarge(uint256 marginShare);

    /// @notice Adding the quoted units would take the step past {MAX_STEP_UNITS}.
    /// @param step The step quoted.
    error StepUnitsOverflow(uint256 step);

    /// @notice The departure at `index` of the settler's order is not strictly after the one
    ///         before it, or is not an entry of the departure log (it records no units). The
    ///         selector equals `IUniformEditionAuction.InvalidSettlementOrder`.
    /// @param index The departure's place in the settler's order.
    error InvalidSettlementOrder(uint256 index);

    // The E192 mantissas, 24 to a word, entry j in bits 10 * (j % 24) of word j / 24. Each
    // comment lists its word's entries; test/sales/uniform/UniformClearing.t.sol checks every
    // entry against the reference model (test/fixtures/uniform-clearing/ladder.json).
    // j = 0..23: 100 101 102 104 105 106 107 109 110 111 113 114 115 117 118 120 121 123 124 126 127 129 130 132
    uint256 private constant E192_0 = 0x210822047f1f87c1ec791e0761d4731c8711bc6e1b46b1a8691a06619464;
    // j = 24..47: 133 135 137 138 140 142 143 145 147 149 150 152 154 156 158 160 162 164 165 167 169 172 174 176
    uint256 private constant E192_1 = 0x2c0ae2b0a929ca5290a22809e2709a26096254932448f2388c2288921c85;
    // j = 48..71: 178 180 182 184 187 189 191 193 196 198 200 203 205 208 210 213 215 218 221 223 226 229 232 234
    uint256 private constant E192_2 = 0x3a8e8394e237cdd368d7354d2340cd32cc8318c4304bf2f4bb2e0b62d0b2;
    // j = 72..95: 237 240 243 246 249 252 255 258 261 264 267 271 274 277 280 284 287 291 294 298 301 305 309 312
    uint256 private constant E192_3 = 0x4e1354c52d4a92648d1f471184551243d0b42105408ff3f0f93d8f33c0ed;
    // j = 96..119: 316 320 324 328 332 336 340 344 348 352 357 361 365 370 374 379 383 388 392 397 402 407 412 417
    uint256 private constant E192_4 = 0x6859c65d92635886117f5ed765c96d5a5655815c561545414c521445013c;
    // j = 120..143: 422 427 432 437 442 448 453 459 464 470 475 481 487 493 499 505 511 517 523 530 536 542 549 556
    uint256 private constant E192_5 = 0x8b22587a1884a0b815ff7e5f37b5e7785db759d072dc5701ba6d5b06ada6;
    // j = 144..167: 562 569 576 583 590 597 604 612 619 626 634 642 649 657 665 673 681 690 698 706 715 723 732 741
    uint256 private constant E192_6 = 0xb96dcb4ecbb0abaacaa9a8699a4689a0a7a9ca6b9925c9564e91e408e632;
    // j = 168..191: 750 759 768 777 787 796 806 816 825 835 845 856 866 876 887 898 909 919 931 942 953 965 976 988
    uint256 private constant E192_7 = 0xf73d0f17b9ebba3e5f8de0b77db362d634dd0f39cc326c7313c2700bdeee;

    /// @notice Whether `(basePrice, stepsPerDecade)` is inside the library's domain:
    ///         `basePrice` from 100 to 2**96 - 1, and `stepsPerDecade` 24, 48, 96 or 192.
    /// @dev On the domain every price of a book of at most {MAX_STEPS} steps is strictly above
    ///      the one below it (exact, with no rounding, when `basePrice` is a multiple of 100),
    ///      and {clear} cannot overflow. The governed bounds (`StepLadder.isValid`: 10**12 to
    ///      10**17 wei) lie inside it, so a settlement on terms an auction locked cannot revert.
    /// @param basePrice The price of step 0 in wei.
    /// @param stepsPerDecade Steps per decade.
    /// @return Whether the ladder is supported.
    function isValidLadder(uint256 basePrice, uint256 stepsPerDecade)
        internal
        pure
        returns (bool)
    {
        return basePrice >= 100 && basePrice <= type(uint96).max
            && (stepsPerDecade == 24 || stepsPerDecade == 48 || stepsPerDecade == 96
                || stepsPerDecade == 192);
    }

    /// @notice The price of `step` in wei: `basePrice * M[(step % N) * (192 / N)] *
    ///         10**(step / N) / 100` with `N = stepsPerDecade`, dividing last.
    /// @dev Checked arithmetic, so a step far past {MAX_STEPS} reverts rather than wraps. Meant
    ///      for ladders {isValidLadder} accepts; on them it equals the reference model's price.
    /// @param basePrice The price of step 0 in wei.
    /// @param stepsPerDecade Steps per decade.
    /// @param step The step.
    /// @return The step's price in wei.
    function price(uint256 basePrice, uint256 stepsPerDecade, uint256 step)
        internal
        pure
        returns (uint256)
    {
        uint256 decade = step / stepsPerDecade;
        uint256 m = _mantissa((step - decade * stepsPerDecade) * (192 / stepsPerDecade));
        return basePrice * m * 10 ** decade / 100;
    }

    /// @notice Clears a book by the D138 rule, in one pass over its words.
    /// @dev **The rule, per unit.** A bid of `q` units counts as `q` unit bids. `P(k)` is the
    ///      k-th highest unit price and `revenue(k) = k * P(k)` for `1 <= k <= K`, where `K` is
    ///      the number of live units, or the cap when that is lower. `R*` is the highest revenue.
    ///      The result is the LARGEST `k` with `revenue(k) * 100,000 >= R* * (100,000 -
    ///      marginShare)`, at the price `P(k)`: an exact comparison, with no rounding.
    ///
    ///      **One candidate per step.** Let `D_s` be the units at or above step `s`. Every `k`
    ///      in `(D_{s+1}, D_s]` has `P(k) = p_s`, so revenue rises with `k` inside a step and the
    ///      step's best count is its top, `min(D_s, cap)`. So `R*` is the best candidate, and if
    ///      any `k` inside a step passes the margin test so does the step's top: the largest
    ///      passing `k` is the top of the lowest passing step. Once the units above a step reach
    ///      the cap, every `k <= cap` lies above it, so the scan stops there.
    ///
    ///      **One pass.** The scan runs from the top step down, keeping the running maximum
    ///      `best`, and records a candidate when it passes against `best` so far (`best`
    ///      including it). The lowest candidate that passes against `R*` also passed then, as
    ///      `best <= R*`; every candidate after the one attaining `R*` was tested against `R*`
    ///      itself, and that one passes; so the last candidate recorded is the lowest that
    ///      passes against `R*`.
    ///
    ///      Without a cap no step is split: `rationed` is false and every unit at or above
    ///      `step` wins. With a cap that binds inside `step`, its `cutUnits` go in arrival
    ///      order ({sweep}, {wonAtCut}).
    ///
    ///      Never reverts for a ladder {isValidLadder} accepts, a margin of at most
    ///      {DENOMINATOR} and a book of at most {MAX_STEPS} steps, whatever the units.
    /// @param live The book: 8 steps of 32-bit live units per word (see the library notes).
    /// @param rules The locked terms.
    /// @return result The clearing; all zero for an empty book.
    function clear(uint256[] memory live, Rules memory rules)
        internal
        pure
        returns (Result memory result)
    {
        (uint256 pick, uint256 best, uint256 capOrMax) = _scan(live, rules);
        if (pick == 0) return result;
        uint256 demand = pick & type(uint64).max;
        uint256 above = (pick >> 64) & type(uint64).max;
        uint256 count = demand < capOrMax ? demand : capOrMax;
        result.count = count;
        result.step = pick >> 128;
        result.price = price(rules.basePrice, rules.stepsPerDecade, result.step);
        result.bestRevenue = best;
        result.cutUnits = count - above;
        result.unitsAtStep = demand - above;
        result.rationed = count < demand;
    }

    /// @notice The clearing if one more bid of `qty` units arrived at `step`, and the units that
    ///         bid would win.
    /// @dev The new bid joins the back of its step's queue, so at a split cut step it wins what
    ///      is left once the live units already there are filled. Quote a raise by first taking
    ///      the bid's units off its old step in `live`. `live` is restored before returning.
    /// @param live The book (see {clear}); `step` must lie inside it.
    /// @param rules The locked terms.
    /// @param step The new bid's step.
    /// @param qty The new bid's units.
    /// @return result The clearing with the bid.
    /// @return won The units the new bid would win.
    function quote(uint256[] memory live, Rules memory rules, uint256 step, uint256 qty)
        internal
        pure
        returns (Result memory result, uint256 won)
    {
        uint256 word = live[step >> 3];
        uint256 shift = (step & 7) << 5;
        uint256 before = (word >> shift) & MAX_STEP_UNITS;
        if (qty > MAX_STEP_UNITS - before) revert StepUnitsOverflow(step);
        live[step >> 3] = word + (qty << shift);
        result = clear(live, rules);
        live[step >> 3] = word;
        if (result.count == 0 || step < result.step) return (result, 0);
        if (step > result.step) return (result, qty);
        // cutUnits <= before + qty, the step's live units with the bid.
        won = result.cutUnits > before ? result.cutUnits - before : 0;
    }

    /// @notice One step of the departure sweep at a split cut step (PLAN section 1.6): checks
    ///         that the departure lies strictly after the one before it, and moves the cut-off
    ///         past it when it starts below the cut-off.
    /// @dev A bid's position counts the units entered at its step before it, so positions only
    ///      grow; a raise out of the step, or a dispute withdrawal, leaves a hole `[pos, pos +
    ///      qty)`. Start with `cutoff = cutUnits` and `minPos = 0`, and feed the cut step's
    ///      departures in the settler's order, carrying both values across calls when the sweep
    ///      is chunked. The strict order rules out repeats, so the order is complete when the
    ///      number swept equals the log's count, which the caller checks. The final cut-off `X`
    ///      is then the least `X >= cutUnits` with `X = cutUnits + (units of the departures
    ///      starting below X)`: exactly `cutUnits` live units start below it, and {wonAtCut}
    ///      hands out exactly `cutUnits` (PLAN section 1.6; proved in test/symbolic).
    /// @param cutoff The cut-off so far.
    /// @param minPos The lowest position accepted next: 0 at the start.
    /// @param pos The departure's position.
    /// @param qty The departure's units; a log entry always has at least one, so 0 marks an
    ///        index past the log.
    /// @param index The departure's place in the settler's order, for the error.
    /// @return newCutoff The cut-off after this departure.
    /// @return newMinPos The lowest position accepted after this departure.
    function sweep(uint256 cutoff, uint256 minPos, uint256 pos, uint256 qty, uint256 index)
        internal
        pure
        returns (uint256 newCutoff, uint256 newMinPos)
    {
        if (qty == 0 || pos < minPos) revert InvalidSettlementOrder(index);
        return (pos < cutoff ? cutoff + qty : cutoff, pos + 1);
    }

    /// @notice The units a bid at the cut step wins: `clamp(cutoff - pos, 0, qty)`.
    /// @dev `cutoff` is the swept cut-off ({sweep}). At a cut step that is not split every bid
    ///      wins in full, which `cutoff = type(uint256).max` also gives.
    /// @param cutoff The swept cut-off `X`.
    /// @param pos The bid's position at the step.
    /// @param qty The bid's units.
    /// @return The units the bid wins.
    function wonAtCut(uint256 cutoff, uint256 pos, uint256 qty) internal pure returns (uint256) {
        if (cutoff <= pos) return 0;
        unchecked {
            uint256 room = cutoff - pos;
            return room < qty ? room : qty;
        }
    }

    /// @dev The scan behind {clear}. Returns the lowest passing candidate packed as
    ///      `step << 128 | unitsAbove << 64 | unitsAtOrAbove` (0 for an empty book), `R*`, and
    ///      the cap, or `type(uint256).max` without one.
    function _scan(uint256[] memory live, Rules memory rules)
        private
        pure
        returns (uint256 pick, uint256 best, uint256 capOrMax)
    {
        uint256 perDecade = rules.stepsPerDecade;
        uint256 keep;
        uint256 i;
        uint256 decadeStart;
        uint256 scale;
        {
            uint256 basePrice = rules.basePrice;
            if (!isValidLadder(basePrice, perDecade)) {
                revert UnsupportedLadder(basePrice, perDecade);
            }
            i = live.length << 3;
            if (i > MAX_STEPS) revert TooManySteps(i);
            uint256 marginShare = rules.marginShare;
            if (marginShare > DENOMINATOR) revert MarginTooLarge(marginShare);
            keep = DENOMINATOR - marginShare;
            capOrMax = rules.maxCount == 0 ? type(uint256).max : rules.maxCount;
            if (i == 0) return (0, 0, capOrMax);
            uint256 decade = (i - 1) / perDecade;
            decadeStart = decade * perDecade;
            scale = basePrice * 10 ** decade;
        }
        uint256 demand;
        // On the domain: demand < 2**41 (512 steps of 32 bits); scale < 2**166 (a base below
        // 2**96, at most 21 decades); a mantissa below 2**10; so a revenue is below 2**217 and
        // times 100,000 below 2**234. Nothing below wraps.
        unchecked {
            while (i != 0) {
                uint256 word = live[(i - 1) >> 3];
                if (word == 0) {
                    i -= 8;
                    continue;
                }
                // Lanes from the word's top step down; once the rest of the word is empty, drop
                // to the word below.
                do {
                    --i;
                    uint256 units = word >> 224;
                    word <<= 32;
                    if (units == 0) continue;
                    if (demand >= capOrMax) {
                        i = 0;
                        break;
                    }
                    while (i < decadeStart) {
                        decadeStart -= perDecade;
                        scale /= 10;
                    }
                    demand += units;
                    uint256 revenue = (demand < capOrMax ? demand : capOrMax)
                        * (scale * _mantissa((i - decadeStart) * (192 / perDecade)) / 100);
                    if (revenue > best) best = revenue;
                    if (revenue * DENOMINATOR >= best * keep) {
                        pick = (i << 128) | ((demand - units) << 64) | demand;
                    }
                } while (word != 0);
                i &= ~uint256(7);
            }
        }
    }

    /// @dev Entry `j` (below 192) of the E192 table.
    function _mantissa(uint256 j) private pure returns (uint256) {
        unchecked {
            uint256 q = j / 24;
            uint256 w;
            if (q < 4) {
                if (q < 2) w = q == 0 ? E192_0 : E192_1;
                else w = q == 2 ? E192_2 : E192_3;
            } else {
                if (q < 6) w = q == 4 ? E192_4 : E192_5;
                else w = q == 6 ? E192_6 : E192_7;
            }
            return (w >> ((j - q * 24) * 10)) & 0x3ff;
        }
    }
}
