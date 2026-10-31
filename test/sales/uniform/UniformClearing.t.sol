// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { stdError } from "forge-std/StdError.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { StepLadder } from "src/interfaces/types/StepLadder.sol";
import { UniformClearing } from "src/sales/UniformClearing.sol";
import { UniformClearingBase } from "./UniformClearingBase.sol";

/// @notice The edition auction's clearing library (D138, ADR 0005): its ladder domain, the
///         clearing rule against a brute force over units and against the reference model's
///         golden vectors (`test/fixtures/edition-auction/clearing.json`, from
///         `tools/edition_auction_ref.py`), the plan's worked traces, the what-if quote and the
///         cut step's first-in-first-out split. `StepLadder`'s own prices are pinned in
///         test/interfaces/StepLadder.t.sol.
contract UniformClearingTest is UniformClearingBase {
    uint256[] internal e192;

    function setUp() public override {
        super.setUp();
        e192 = vm.parseJsonUintArray(
            vm.readFile("test/fixtures/edition-auction/ladder.json"), ".mantissas"
        );
    }

    // ---------------------------------------------------------------------------------------
    // The ladder
    // ---------------------------------------------------------------------------------------

    /// @dev The domain's claim: every step of every allowed ladder is the reference formula and
    ///      strictly above the one below, at the smallest and largest base of the domain and at
    ///      bases that are not multiples of 100 (whose prices round down, dividing last).
    function test_IsValidLadder_EveryLadderOfTheDomainRises() public view {
        uint256[4] memory ladders = [uint256(24), 48, 96, 192];
        uint256[4] memory bases = [uint256(100), 101, 1e12 + 1, type(uint96).max];
        for (uint256 l; l < 4; ++l) {
            for (uint256 b; b < 4; ++b) {
                assertTrue(h.isValidLadder(bases[b], ladders[l]));
                uint256 previous;
                for (uint256 s; s < UniformClearing.MAX_STEPS; ++s) {
                    uint256 p = h.price(bases[b], ladders[l], s);
                    assertGt(p, previous, "strictly increasing");
                    assertEq(p, bases[b] * _reference(ladders[l], s) / 100, "formula");
                    previous = p;
                }
            }
        }
    }

    function test_IsValidLadder_AcceptsTheGovernedLadders() public view {
        uint256[4] memory ladders = [uint256(24), 48, 96, 192];
        for (uint256 l; l < 4; ++l) {
            assertTrue(h.isValidLadder(100, ladders[l]));
            assertTrue(h.isValidLadder(1e12, ladders[l]));
            assertTrue(h.isValidLadder(1e12 + 1, ladders[l]));
            assertTrue(h.isValidLadder(BASE, ladders[l]));
            assertTrue(h.isValidLadder(1e17, ladders[l]));
            assertTrue(h.isValidLadder(type(uint96).max, ladders[l]));
        }
    }

    function test_IsValidLadder_RejectsEverythingElse() public view {
        // Bases below 100 would not give strictly increasing prices; 2**96 and up could overflow.
        assertFalse(h.isValidLadder(0, N));
        assertFalse(h.isValidLadder(99, N));
        assertFalse(h.isValidLadder(uint256(type(uint96).max) + 1, N));
        // Steps per decade: only 24, 48, 96 and 192, though 32 and 64 also divide 192.
        uint256[9] memory others = [uint256(0), 1, 12, 23, 32, 47, 64, 191, 384];
        for (uint256 i; i < others.length; ++i) {
            assertFalse(h.isValidLadder(BASE, others[i]));
        }
    }

    // ---------------------------------------------------------------------------------------
    // Clearing: the PLAN Appendix C traces
    // ---------------------------------------------------------------------------------------

    /// @dev Trace 1, the owner's numbers off the ladder, through the brute force: R* = 4.0 ETH at
    ///      80 editions; 280 at 0.01 gives only 2.8, below the 3.6 threshold; a 30% margin takes
    ///      it, as 2.8 >= 0.7 x 4.0.
    function test_Reference_TheOwnersNumbers() public pure {
        uint256[] memory prices = new uint256[](5);
        uint256[] memory totals = new uint256[](5);
        (prices[0], prices[1], prices[2], prices[3], prices[4]) =
        (0.01 ether, 0.05 ether, 0.1 ether, 0.2 ether, 1 ether);
        (totals[0], totals[1], totals[2], totals[3], totals[4]) = (200, 50, 20, 9, 1);
        UniformClearing.Result memory r = _bruteForce(prices, totals, 0, TEN_PERCENT);
        assertEq(r.count, 80);
        assertEq(r.price, 0.05 ether);
        assertEq(r.count * r.price, 4 ether);
        assertEq(r.bestRevenue, 4 ether);
        r = _bruteForce(prices, totals, 0, 30_000);
        assertEq(r.count, 280);
        assertEq(r.price, 0.01 ether);
    }

    /// @dev Trace 2: the same bids on the default ladder clear 80 at 0.0511 ETH, 4.088 ETH raised,
    ///      1.022 ETH (25%) to the network.
    function test_Clear_Trace2TheOwnersBidsOnTheDefaultLadder() public view {
        uint256[] memory live = _trace2Book();
        UniformClearing.Result memory r = h.clear(live, _rules(0, TEN_PERCENT));
        assertEq(r.count, 80);
        assertEq(r.step, 130);
        assertEq(r.price, 0.0511 ether);
        assertEq(r.bestRevenue, 4.088 ether);
        assertEq(r.cutUnits, 50);
        assertEq(r.unitsAtStep, 50);
        assertFalse(r.rationed);
        assertEq(r.count * r.price, 4.088 ether);
        assertEq(r.count * r.price / 4, 1.022 ether);
        // Without a margin the result is the same: 4.088 ETH is the maximum.
        assertEq(h.clear(live, _rules(0, 0)).count, 80);
        // A 30% margin still leaves 280 at 0.01 out (2.8 < 0.7 x 4.088), unlike trace 1.
        assertEq(h.clear(live, _rules(0, 30_000)).count, 80);
        // The largest margin the governed bounds allow, 50%, takes it (2.8 >= 0.5 x 4.088).
        r = h.clear(live, _rules(0, 50_000));
        assertEq(r.count, 280);
        assertEq(r.price, 0.01 ether);
        assertEq(r.bestRevenue, 4.088 ether);
    }

    /// @dev Trace 2's tilt: one unit at 0.0464 (81 x 0.0464 = 3.7584 >= 0.9 x 4.088) clears 81 at
    ///      0.0464; one at 0.0442 gives 3.5802 < 3.6792 and changes nothing.
    function test_Clear_Trace2ALowerUnitWithinTheMarginTiltsTheCount() public view {
        uint256[] memory live = _trace2Book();
        live[128 >> 3] += 1 << ((128 & 7) * 32);
        UniformClearing.Result memory r = h.clear(live, _rules(0, TEN_PERCENT));
        assertEq(r.count, 81);
        assertEq(r.price, 0.0464 ether);
        assertEq(r.count * r.price, 3.7584 ether);
        assertEq(r.bestRevenue, 4.088 ether);

        live = _trace2Book();
        live[127 >> 3] += 1 << ((127 & 7) * 32);
        r = h.clear(live, _rules(0, TEN_PERCENT));
        assertEq(r.count, 80);
        assertEq(r.step, 130);
    }

    /// @dev Trace 3: a cap of 60. Candidates 1.00, 1.96, 3.00 and 60 x 0.0511 = 3.066; the scan
    ///      stops below step 130, which is split: 30 of its 50 units win.
    function test_Clear_Trace3ACapSplitsTheCutStep() public view {
        UniformClearing.Result memory r = h.clear(_trace2Book(), _rules(60, TEN_PERCENT));
        assertEq(r.count, 60);
        assertEq(r.step, 130);
        assertEq(r.cutUnits, 30);
        assertEq(r.unitsAtStep, 50);
        assertTrue(r.rationed);
        assertEq(r.bestRevenue, 3.066 ether);
        assertEq(r.count * r.price, 3.066 ether);
        assertEq(r.count * r.price / 4, 0.7665 ether);
    }

    /// @dev Trace 3's queue at step 130: B1 20 at 0, B2 15 at 20 (raised to 0.100: a hole), B3 10
    ///      at 35, B4 20 at 45. The sweep moves the cut-off from 30 past the hole to 45: B1 wins
    ///      20, B3 10, B4 nothing. Without the sweep B3 would get nothing and 10 editions would
    ///      be lost.
    function test_Sweep_Trace3TheHoleBelowTheCutOffIsSkipped() public view {
        (uint256 x, uint256 minPos) = h.sweep(30, 0, 20, 15, 0);
        assertEq(x, 45);
        assertEq(minPos, 21);
        assertEq(h.wonAtCut(x, 0, 20), 20);
        assertEq(h.wonAtCut(x, 35, 10), 10);
        assertEq(h.wonAtCut(x, 45, 20), 0);
        // Unswept, 10 units are lost.
        assertEq(h.wonAtCut(30, 0, 20) + h.wonAtCut(30, 35, 10) + h.wonAtCut(30, 45, 20), 20);
        // Refunds: B2 (raised to step 144) wins its 15 at 0.0511 and gets 0.7335 ETH back of
        // 1.5; B4 gets all 1.022 ETH back.
        uint256 p = h.price(BASE, N, 130);
        assertEq(15 * h.price(BASE, N, 144) - 15 * p, 0.7335 ether);
        assertEq(20 * p - h.wonAtCut(x, 45, 20) * p, 1.022 ether);
    }

    // ---------------------------------------------------------------------------------------
    // Clearing: edges
    // ---------------------------------------------------------------------------------------

    function test_Clear_AnEmptyBookSellsNothing() public view {
        _assertZero(h.clear(new uint256[](42), _rules(0, TEN_PERCENT)));
        _assertZero(h.clear(new uint256[](0), _rules(5, TEN_PERCENT)));
    }

    function test_Clear_OneUnitAtTheBaseStep() public view {
        uint256[] memory live = new uint256[](1);
        live[0] = 1;
        UniformClearing.Result memory r = h.clear(live, _rules(0, TEN_PERCENT));
        assertEq(r.count, 1);
        assertEq(r.step, 0);
        assertEq(r.price, BASE);
        assertEq(r.bestRevenue, BASE);
        assertEq(r.cutUnits, 1);
        assertEq(r.unitsAtStep, 1);
        assertFalse(r.rationed);
    }

    /// @dev On the 192-step ladder step 58 costs exactly twice step 0: 1 unit at step 58 and 1 at
    ///      step 0 tie at 0.0002 ETH. With no margin the larger count wins the tie.
    function test_Clear_ATieAtTheMaximumGoesToTheLargerCount() public view {
        assertEq(h.price(BASE, 192, 58), 2 * h.price(BASE, 192, 0));
        uint256[] memory live = _book(_pair(0, 58), _pair(1, 1), 8);
        UniformClearing.Rules memory rules = UniformClearing.Rules({
            basePrice: BASE, stepsPerDecade: 192, maxCount: 0, marginShare: 0
        });
        UniformClearing.Result memory r = h.clear(live, rules);
        assertEq(r.count, 2);
        assertEq(r.step, 0);
    }

    /// @dev A cap that lands on a step's top does not split it, and a cap can sell fewer than
    ///      itself: with a cap of 50, 50 x 0.0511 = 2.555 < 0.9 x 3.0, so 30 sell at 0.100.
    function test_Clear_ACapOnAStepBoundaryDoesNotRation() public view {
        UniformClearing.Result memory r = h.clear(_trace2Book(), _rules(30, TEN_PERCENT));
        assertEq(r.count, 30);
        assertEq(r.step, 144);
        assertEq(r.cutUnits, 20);
        assertFalse(r.rationed);
        r = h.clear(_trace2Book(), _rules(50, TEN_PERCENT));
        assertEq(r.count, 30);
        assertEq(r.step, 144);
        assertEq(r.bestRevenue, 3 ether);
        assertFalse(r.rationed);
    }

    function test_Clear_ACapOfOneSellsTheTopUnit() public view {
        UniformClearing.Result memory r = h.clear(_trace2Book(), _rules(1, TEN_PERCENT));
        assertEq(r.count, 1);
        assertEq(r.step, 192);
        assertEq(r.cutUnits, 1);
        assertFalse(r.rationed);
    }

    /// @dev Once the units above a step reach the cap, nothing below can matter, however large.
    function test_Clear_UnitsBelowTheCapAreNeverRead() public view {
        uint256[] memory live = _book(_pair(0, 300), _pair(type(uint32).max, 5), 42);
        UniformClearing.Result memory r = h.clear(live, _rules(5, 0));
        assertEq(r.count, 5);
        assertEq(r.step, 300);
        assertEq(r.cutUnits, 5);
        assertFalse(r.rationed);
        // Uncapped, the bottom step's 2**32 - 1 units win.
        r = h.clear(live, _rules(0, TEN_PERCENT));
        assertEq(r.count, uint256(type(uint32).max) + 5);
        assertEq(r.step, 0);
    }

    /// @dev The largest book on the largest ladder: 512 steps of 2**32 - 1 units at the largest
    ///      base and 24 steps per decade. Nothing overflows; with a 100% margin every unit sells.
    function test_Clear_TheLargestBookDoesNotOverflow() public view {
        uint256[] memory live = new uint256[](64);
        for (uint256 w; w < 64; ++w) {
            live[w] = type(uint256).max;
        }
        UniformClearing.Rules memory rules = UniformClearing.Rules({
            basePrice: type(uint96).max, stepsPerDecade: 24, maxCount: 0, marginShare: 100_000
        });
        UniformClearing.Result memory r = h.clear(live, rules);
        assertEq(r.count, 512 * uint256(type(uint32).max));
        assertEq(r.step, 0);
        rules.marginShare = 0;
        _assertSame(h.clear(live, rules), _stepReference(live, rules));
        rules.maxCount = type(uint256).max;
        _assertSame(h.clear(live, rules), _stepReference(live, rules));
    }

    function test_Clear_RevertsOutsideTheDomain() public {
        uint256[] memory live = new uint256[](42);
        live[0] = 1;
        UniformClearing.Rules memory rules = _rules(0, TEN_PERCENT);
        rules.basePrice = 99;
        vm.expectRevert(abi.encodeWithSelector(UniformClearing.UnsupportedLadder.selector, 99, N));
        h.clear(live, rules);
        rules = _rules(0, TEN_PERCENT);
        rules.stepsPerDecade = 50;
        vm.expectRevert(
            abi.encodeWithSelector(UniformClearing.UnsupportedLadder.selector, BASE, 50)
        );
        h.clear(live, rules);
        vm.expectRevert(abi.encodeWithSelector(UniformClearing.TooManySteps.selector, 520));
        h.clear(new uint256[](65), _rules(0, TEN_PERCENT));
        vm.expectRevert(abi.encodeWithSelector(UniformClearing.MarginTooLarge.selector, 100_001));
        h.clear(live, _rules(0, 100_001));
    }

    /// @dev 64 words (512 steps) is the limit, not past it.
    function test_Clear_AcceptsTheMaximumBook() public view {
        uint256[] memory live = new uint256[](64);
        live[63] = 1 << 224; // step 511
        UniformClearing.Result memory r = h.clear(live, _rules(0, TEN_PERCENT));
        assertEq(r.count, 1);
        assertEq(r.step, 511);
        assertEq(r.price, h.price(BASE, N, 511));
    }

    // ---------------------------------------------------------------------------------------
    // Clearing: the reference model's vectors and the brute force
    // ---------------------------------------------------------------------------------------

    /// @dev The reference model's golden vectors (`tools/edition_auction_ref.py`), case by case:
    ///      the book (each step's live units, from the active bids), the clearing, the sweep of
    ///      the cut step's departures in the settlement order the model gives, every bid's units
    ///      and refund, and every quote. The three cases priced off the ladder (the owner's own
    ///      figures) run through the brute force instead.
    function test_Clear_MatchesTheGoldenVectors() public view {
        string memory json = vm.readFile("test/fixtures/edition-auction/clearing.json");
        uint256 cases;
        while (vm.keyExistsJson(json, string.concat(".cases[", vm.toString(cases), "]"))) {
            ++cases;
        }
        assertGt(cases, 15);
        for (uint256 i; i < cases; ++i) {
            string memory c = string.concat(".cases[", vm.toString(i), "]");
            string memory name = vm.parseJsonString(json, string.concat(c, ".name"));
            GoldenBid[] memory bids = _goldenBids(json, c);
            uint256[] memory totals = new uint256[](UniformClearing.MAX_STEPS);
            for (uint256 b; b < bids.length; ++b) {
                if (bids[b].active) totals[bids[b].step] += bids[b].quantity;
            }
            if (vm.keyExistsJson(json, string.concat(c, ".prices"))) {
                UniformClearing.Result memory b = _bruteForce(
                    _uints(json, string.concat(c, ".prices")),
                    totals,
                    _uint(json, string.concat(c, ".cap")),
                    _uint(json, string.concat(c, ".config.marginShare"))
                );
                _assertGoldenResult(json, string.concat(c, ".expected.clearing"), b, name);
                continue;
            }
            UniformClearing.Rules memory rules = _goldenRules(json, c);
            uint256[] memory live = new uint256[](64);
            for (uint256 s; s < totals.length; ++s) {
                live[s >> 3] |= totals[s] << ((s & 7) * 32);
            }
            UniformClearing.Result memory r = h.clear(live, rules);
            _assertGoldenResult(json, string.concat(c, ".expected.clearing"), r, name);
            _assertGoldenBids(json, c, r, rules, bids, name);
            if (vm.keyExistsJson(json, string.concat(c, ".quotes"))) {
                _assertGoldenQuotes(json, c, live, rules, r.count, name);
            }
        }
    }

    // The golden vectors' helpers. A cheatcode call ABI-encodes the whole vector text (225 KB)
    // into fresh memory; rewinding the free memory pointer after each call keeps the replay's
    // memory, and so its gas, linear in the number of calls.

    function _fmp() internal pure returns (uint256 p) {
        assembly ("memory-safe") {
            p := mload(0x40)
        }
    }

    function _uint(string memory json, string memory key) internal pure returns (uint256 v) {
        uint256 fmp = _fmp();
        v = vm.parseJsonUint(json, key);
        assembly ("memory-safe") {
            mstore(0x40, fmp)
        }
    }

    function _bool(string memory json, string memory key) internal pure returns (bool v) {
        uint256 fmp = _fmp();
        v = vm.parseJsonBool(json, key);
        assembly ("memory-safe") {
            mstore(0x40, fmp)
        }
    }

    /// @dev Copies the result down to where the encoding started, then frees the rest.
    function _uints(string memory json, string memory key)
        internal
        pure
        returns (uint256[] memory r)
    {
        uint256 fmp = _fmp();
        uint256[] memory a = vm.parseJsonUintArray(json, key);
        assembly {
            let size := mul(add(mload(a), 1), 0x20)
            mcopy(fmp, a, size)
            r := fmp
            mstore(0x40, add(fmp, size))
        }
    }

    /// @dev One bid's outcome in a golden vector (fields in the vector's key order).
    struct GoldenBid {
        bool active;
        uint256 bidId;
        string bidder;
        uint256 escrow;
        uint256 position;
        uint256 quantity;
        uint256 refund;
        uint256 step;
        uint256 unitsAhead;
        uint256 unitsWon;
    }

    function _goldenBids(string memory json, string memory c)
        internal
        pure
        returns (GoldenBid[] memory)
    {
        return abi.decode(
            vm.parseJsonTypeArray(
                json,
                string.concat(c, ".expected.bids"),
                "GoldenBid(bool active,uint256 bidId,string bidder,uint256 escrow,uint256 position,"
                "uint256 quantity,uint256 refund,uint256 step,uint256 unitsAhead,uint256 unitsWon)"
            ),
            (GoldenBid[])
        );
    }

    function _goldenRules(string memory json, string memory c)
        internal
        pure
        returns (UniformClearing.Rules memory)
    {
        return UniformClearing.Rules({
            basePrice: _uint(json, string.concat(c, ".config.basePrice")),
            stepsPerDecade: _uint(json, string.concat(c, ".config.stepsPerDecade")),
            maxCount: _uint(json, string.concat(c, ".cap")),
            marginShare: _uint(json, string.concat(c, ".config.marginShare"))
        });
    }

    /// @dev A result against the model's clearing object at `k`.
    function _assertGoldenResult(
        string memory json,
        string memory k,
        UniformClearing.Result memory r,
        string memory name
    ) internal pure {
        assertEq(r.count, _uint(json, string.concat(k, ".count")), name);
        if (r.count == 0) {
            assertEq(r.price + r.bestRevenue + r.cutUnits + r.unitsAtStep, 0, name);
            return;
        }
        assertEq(r.step, _uint(json, string.concat(k, ".step")), name);
        assertEq(r.price, _uint(json, string.concat(k, ".price")), name);
        assertEq(r.count * r.price, _uint(json, string.concat(k, ".revenue")), name);
        assertEq(r.bestRevenue, _uint(json, string.concat(k, ".bestRevenue")), name);
        assertEq(r.rationed, _bool(json, string.concat(k, ".rationed")), name);
        assertEq(r.cutUnits, _uint(json, string.concat(k, ".cutUnits")), name);
        assertEq(r.unitsAtStep, _uint(json, string.concat(k, ".unitsAtStep")), name);
    }

    /// @dev The cut-off the sweep reaches over the cut step's departures, in the model's
    ///      settlement order; `type(uint256).max` when the step is not split.
    function _goldenCutoff(string memory json, string memory c, UniformClearing.Result memory r)
        internal
        view
        returns (uint256 cutoff)
    {
        if (!r.rationed) return type(uint256).max;
        string memory log = string.concat(c, ".expected.departures['", vm.toString(r.step), "'][");
        uint256[] memory order = _uints(json, string.concat(c, ".expected.settlementOrder"));
        cutoff = r.cutUnits;
        uint256 minPos;
        for (uint256 n; n < order.length; ++n) {
            uint256[] memory d = _uints(json, string.concat(log, vm.toString(order[n]), "]"));
            (cutoff, minPos) = h.sweep(cutoff, minPos, d[0], d[1], n);
        }
        assertEq(cutoff, _uint(json, string.concat(c, ".expected.clearing.cutoff")));
    }

    /// @dev Every active bid's units, escrow and refund.
    function _assertGoldenBids(
        string memory json,
        string memory c,
        UniformClearing.Result memory r,
        UniformClearing.Rules memory rules,
        GoldenBid[] memory bids,
        string memory name
    ) internal view {
        uint256 cutoff = _goldenCutoff(json, c, r);
        for (uint256 i; i < bids.length; ++i) {
            GoldenBid memory b = bids[i];
            if (!b.active) continue;
            uint256 units;
            if (r.count != 0 && b.step > r.step) {
                units = b.quantity;
            } else if (r.count != 0 && b.step == r.step) {
                units = h.wonAtCut(cutoff, b.position, b.quantity);
            }
            assertEq(units, b.unitsWon, name);
            uint256 escrow = b.quantity * h.price(rules.basePrice, rules.stepsPerDecade, b.step);
            assertEq(escrow, b.escrow, name);
            assertEq(escrow - units * r.price, b.refund, name);
        }
    }

    /// @dev Each quote: the clearing with the new bid, the units it wins, and the existing
    ///      units it pushes out or pulls in.
    function _assertGoldenQuotes(
        string memory json,
        string memory c,
        uint256[] memory live,
        UniformClearing.Rules memory rules,
        uint256 before,
        string memory name
    ) internal view {
        for (uint256 i; vm.keyExistsJson(json, _at(c, ".quotes", i)); ++i) {
            string memory q = _at(c, ".quotes", i);
            (UniformClearing.Result memory r, uint256 units,) = h.quote(
                live,
                rules,
                _uint(json, string.concat(q, ".step")),
                _uint(json, string.concat(q, ".quantity"))
            );
            _assertGoldenResult(json, string.concat(q, ".result"), r, name);
            assertEq(units, _uint(json, string.concat(q, ".unitsWon")), name);
            uint256 others = r.count - units;
            assertEq(
                before > others ? before - others : 0,
                _uint(json, string.concat(q, ".unitsPushedOut")),
                name
            );
            assertEq(
                others > before ? others - before : 0,
                _uint(json, string.concat(q, ".unitsPulledIn")),
                name
            );
        }
    }

    function _at(string memory c, string memory list, uint256 i)
        internal
        pure
        returns (string memory)
    {
        return string.concat(c, list, "[", vm.toString(i), "]");
    }

    /// @dev PLAN section 4: the library against D138 evaluated unit by unit, over random books on
    ///      every governed ladder, with and without caps, at margins from 0 to 100%.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_Clear_MatchesTheBruteForceOverUnits(uint256 seed) public view {
        (uint256[] memory totals, uint256 words) = _randomTotals(seed, 40);
        uint256 total;
        uint256[] memory live = new uint256[](words);
        for (uint256 s; s < totals.length; ++s) {
            total += totals[s];
            live[s >> 3] |= totals[s] << ((s & 7) * 32);
        }
        UniformClearing.Rules memory rules = _randomRules(_next(seed ^ 1), total);
        uint256[] memory prices = new uint256[](totals.length);
        for (uint256 s; s < totals.length; ++s) {
            prices[s] = StepLadder.price(rules.basePrice, rules.stepsPerDecade, s);
        }
        UniformClearing.Result memory r = h.clear(live, rules);
        _assertSame(r, _bruteForce(prices, totals, rules.maxCount, rules.marginShare));
        if (rules.maxCount == 0) assertFalse(r.rationed);
        else assertLe(r.count, rules.maxCount);
    }

    /// @dev Units up to 2**32 - 1 a step, too many to expand, against a plain two-pass reference
    ///      over step tops in checked arithmetic.
    function testFuzz_Clear_MatchesTheStepReferenceForLargeBooks(uint256 seed) public view {
        uint256 words = 1 + seed % 64;
        uint256[] memory live = new uint256[](words);
        seed = _next(seed);
        uint256 density = seed % 4;
        for (uint256 w; w < words; ++w) {
            seed = _next(seed);
            if (density == 0) live[w] = seed; // every lane random
            else if (seed % (density + 1) == 0) live[w] = _next(seed) & _next(seed + 1);
        }
        UniformClearing.Rules memory rules = _randomRules(_next(seed), type(uint40).max);
        _assertSame(h.clear(live, rules), _stepReference(live, rules));
    }

    // ---------------------------------------------------------------------------------------
    // Quote
    // ---------------------------------------------------------------------------------------

    function test_Quote_Trace2WhatOneMoreBidWouldDo() public view {
        uint256[] memory live = _trace2Book();
        (UniformClearing.Result memory r, uint256 won,) =
            h.quote(live, _rules(0, TEN_PERCENT), 128, 1);
        assertEq(r.count, 81);
        assertEq(r.price, 0.0464 ether);
        assertEq(won, 1);
        (r, won,) = h.quote(live, _rules(0, TEN_PERCENT), 127, 1);
        assertEq(r.count, 80);
        assertEq(r.step, 130);
        assertEq(won, 0);
        (r, won,) = h.quote(live, _rules(0, TEN_PERCENT), 200, 3);
        assertEq(r.count, 83);
        assertEq(won, 3);
        // At a split cut step a new bid joins the back of the queue: with a cap of 60, 30 of
        // step 130's 50 units win, so a new bid there wins nothing.
        (r, won,) = h.quote(live, _rules(60, TEN_PERCENT), 130, 5);
        assertEq(r.count, 60);
        assertEq(r.step, 130);
        assertEq(won, 0);
        // Above the cut step it wins in full and pushes the cut step's share down instead.
        (r, won,) = h.quote(live, _rules(60, TEN_PERCENT), 144, 5);
        assertEq(won, 5);
        assertEq(r.cutUnits, 25);
    }

    function test_Quote_LeavesTheBookUnchanged() public view {
        uint256[] memory live = _trace2Book();
        (,, uint256[] memory after_) = h.quote(live, _rules(0, TEN_PERCENT), 131, 7);
        assertEq(keccak256(abi.encode(after_)), keccak256(abi.encode(live)));
    }

    /// @dev A raise is quoted by taking the bid's units off its old step first.
    function test_Quote_ARaiseMovesTheUnits() public view {
        uint256[] memory live = _trace2Book();
        // Move 9 of step 96's units to step 128.
        live[96 >> 3] -= 9 << ((96 & 7) * 32);
        (UniformClearing.Result memory r, uint256 won,) =
            h.quote(live, _rules(0, TEN_PERCENT), 128, 9);
        live[128 >> 3] += 9 << ((128 & 7) * 32);
        _assertSame(r, h.clear(live, _rules(0, TEN_PERCENT)));
        assertEq(won, 9);
    }

    function test_Quote_ZeroUnitsIsTheCurrentClearing() public view {
        (UniformClearing.Result memory r, uint256 won,) =
            h.quote(new uint256[](42), _rules(0, TEN_PERCENT), 7, 0);
        _assertZero(r);
        assertEq(won, 0);
        (r, won,) = h.quote(_trace2Book(), _rules(0, TEN_PERCENT), 130, 0);
        assertEq(r.count, 80);
        assertEq(won, 0);
    }

    function test_Quote_RevertsWhenTheStepWouldOverflow() public {
        uint256[] memory live = _book(_pair(5, 6), _pair(type(uint32).max - 2, 1), 42);
        vm.expectRevert(abi.encodeWithSelector(UniformClearing.StepUnitsOverflow.selector, 5));
        h.quote(live, _rules(0, TEN_PERCENT), 5, 3);
        // Up to the lane's limit is fine.
        (UniformClearing.Result memory r,,) = h.quote(live, _rules(0, TEN_PERCENT), 5, 2);
        assertGt(r.count, 0);
        vm.expectRevert(stdError.indexOOBError);
        h.quote(live, _rules(0, TEN_PERCENT), 42 * 8, 1);
    }

    /// @dev The quote equals clearing the book with the bid added, and the units it reports equal
    ///      what first-in-first-out gives the newest entry at its step.
    function testFuzz_Quote_EqualsTheClearingOfTheBookWithTheBid(
        uint256 seed,
        uint256 step,
        uint32 qty
    ) public view {
        uint256[] memory live;
        UniformClearing.Rules memory rules;
        {
            (uint256[] memory totals, uint256 words) = _randomTotals(seed, 30);
            step = bound(step, 0, words * 8 - 1);
            uint256 total = qty;
            live = new uint256[](words);
            for (uint256 s; s < totals.length; ++s) {
                live[s >> 3] |= totals[s] << ((s & 7) * 32);
                total += totals[s];
            }
            rules = _randomRules(_next(seed ^ 2), total);
        }
        uint256 q = bound(qty, 0, 60);
        (UniformClearing.Result memory r, uint256 won,) = h.quote(live, rules, step, q);
        (UniformClearing.Result memory c, uint256 expected) = _withNewestBid(live, rules, step, q);
        _assertSame(r, c);
        assertEq(won, expected);
    }

    // ---------------------------------------------------------------------------------------
    // The cut step: sweep and units won
    // ---------------------------------------------------------------------------------------

    function test_Sweep_RevertsOnADepartureOutOfOrder() public {
        (uint256 x, uint256 minPos) = h.sweep(10, 0, 4, 2, 0);
        assertEq(x, 12);
        assertEq(minPos, 5);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.InvalidSettlementOrder.selector, 1)
        );
        h.sweep(x, minPos, 3, 1, 1);
        // The same position twice is refused: the order must be strict.
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.InvalidSettlementOrder.selector, 7)
        );
        h.sweep(x, minPos, 4, 2, 7);
        // The next position up is accepted.
        (x, minPos) = h.sweep(x, minPos, 5, 1, 1);
        assertEq(x, 13);
        assertEq(minPos, 6);
    }

    /// @dev A zero-unit departure is no log entry (an index past the log reads as zeros).
    function test_Sweep_RevertsOnAnEmptyDeparture() public {
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.InvalidSettlementOrder.selector, 3)
        );
        h.sweep(10, 0, 0, 0, 3);
    }

    function test_Sweep_ADepartureAtOrPastTheCutOffChangesNothing() public view {
        (uint256 x, uint256 minPos) = h.sweep(10, 0, 10, 5, 0);
        assertEq(x, 10);
        assertEq(minPos, 11);
        (x,) = h.sweep(10, 0, 9, 5, 0);
        assertEq(x, 15);
    }

    function test_WonAtCut_ClampsToTheBid() public view {
        assertEq(h.wonAtCut(10, 0, 4), 4); // wholly below the cut-off
        assertEq(h.wonAtCut(10, 6, 4), 4); // ends exactly at it
        assertEq(h.wonAtCut(10, 8, 4), 2); // straddles it
        assertEq(h.wonAtCut(10, 9, 4), 1);
        assertEq(h.wonAtCut(10, 10, 4), 0); // starts at it
        assertEq(h.wonAtCut(10, 11, 4), 0); // past it
        assertEq(h.wonAtCut(0, 0, 4), 0);
        assertEq(
            h.wonAtCut(type(uint256).max, type(uint32).max, type(uint32).max), type(uint32).max
        );
    }

    /// @dev One step's queue: entries arrive at growing positions, some leave (raises out,
    ///      withdrawals), and any cut of the live units is handed out exactly, in arrival order.
    function testFuzz_Sweep_UnitsWonSumToTheCutUnits(uint256 seed) public view {
        uint256 entries = 1 + seed % 10;
        uint256[] memory pos = new uint256[](entries);
        uint256[] memory qty = new uint256[](entries);
        bool[] memory gone = new bool[](entries);
        uint256 entered;
        uint256 live;
        for (uint256 i; i < entries; ++i) {
            seed = _next(seed);
            (pos[i], qty[i], gone[i]) = (entered, 1 + seed % 6, (seed >> 8) % 3 == 0);
            entered += qty[i];
            if (!gone[i]) live += qty[i];
        }
        if (live == 0) return;
        uint256 cut = 1 + _next(seed) % live;
        uint256 x = cut;
        uint256 minPos;
        for (uint256 i; i < entries; ++i) {
            if (gone[i]) (x, minPos) = h.sweep(x, minPos, pos[i], qty[i], i);
        }
        uint256 sum;
        bool short;
        for (uint256 i; i < entries; ++i) {
            if (gone[i]) continue;
            uint256 won = h.wonAtCut(x, pos[i], qty[i]);
            // First in, first out: no later entry wins while an earlier one is short.
            if (won != 0) assertFalse(short, "FIFO");
            if (won < qty[i]) short = true;
            sum += won;
        }
        assertEq(sum, cut);
    }

    /// @dev One auction's bids and raises over a few steps: each bid's step, units and position,
    ///      and each departure's step, position and units, in the order they happen.
    struct Market {
        uint256 steps;
        uint256[] entered;
        uint256[] liveUnits;
        uint256[] bStep;
        uint256[] bQty;
        uint256[] bPos;
        uint256 bids;
        uint256[] dStep;
        uint256[] dPos;
        uint256[] dQty;
        uint256 departures;
    }

    /// @dev The model's end-to-end check (FIFO with raise holes): bids and raises over a few
    ///      steps, a random cap, the clearing, the sorted sweep of the cut step's departures;
    ///      the units won by every bid sum to exactly `k`.
    function testFuzz_Sweep_EveryBidTogetherWinsExactlyTheCount(uint256 seed) public view {
        Market memory m = _market(seed);
        uint256 total;
        uint256[] memory live = new uint256[](1);
        for (uint256 s; s < m.steps; ++s) {
            total += m.liveUnits[s];
            live[0] |= m.liveUnits[s] << (s * 32);
        }
        uint256 cap = 1 + _next(seed ^ 3) % (total == 0 ? 1 : total);
        UniformClearing.Result memory r = h.clear(live, _rules(cap, TEN_PERCENT));
        if (r.count == 0) return;
        uint256 x = r.rationed ? _sweepInOrder(m, r.step, r.cutUnits) : type(uint256).max;
        uint256 won;
        for (uint256 b; b < m.bids; ++b) {
            if (m.bStep[b] > r.step) won += m.bQty[b];
            else if (m.bStep[b] == r.step) won += h.wonAtCut(x, m.bPos[b], m.bQty[b]);
        }
        assertEq(won, r.count);
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    function _trace2Book() internal pure returns (uint256[] memory) {
        (uint256[] memory steps, uint256[] memory units) = _trace2();
        return _book(steps, units, 42);
    }

    function _assertSame(UniformClearing.Result memory a, UniformClearing.Result memory b)
        internal
        pure
    {
        assertEq(a.count, b.count, "count");
        assertEq(a.step, b.step, "step");
        assertEq(a.price, b.price, "price");
        assertEq(a.bestRevenue, b.bestRevenue, "best revenue");
        assertEq(a.rationed, b.rationed, "rationed");
        assertEq(a.cutUnits, b.cutUnits, "cut units");
        assertEq(a.unitsAtStep, b.unitsAtStep, "units at step");
    }

    function _assertZero(UniformClearing.Result memory r) internal pure {
        assertEq(r.count + r.step + r.price + r.bestRevenue + r.cutUnits + r.unitsAtStep, 0);
        assertFalse(r.rationed);
    }

    /// @dev `M[(s % n) * (192 / n)] * 10**(s / n)`, from the reference model's table.
    function _reference(uint256 n, uint256 s) internal view returns (uint256) {
        return e192[(s % n) * (192 / n)] * 10 ** (s / n);
    }

    /// @dev A random book small enough to expand into units: up to `maxUsed` used steps of 1 to
    ///      40 units, placed in a span of up to 512 steps.
    function _randomTotals(uint256 seed, uint256 maxUsed)
        internal
        pure
        returns (uint256[] memory totals, uint256 words)
    {
        uint256 span = 1 + seed % 512;
        if ((seed >> 16) % 3 == 0) span = 1 + seed % 24; // dense: neighbouring prices
        words = (span + 7) / 8;
        if ((seed >> 24) % 4 == 0) words = 64; // empty words above the book
        totals = new uint256[](span);
        uint256 used = 1 + (seed >> 32) % maxUsed;
        uint256[9] memory sizes = [uint256(1), 1, 2, 3, 5, 8, 13, 20, 40];
        for (uint256 i; i < used; ++i) {
            seed = _next(seed);
            totals[seed % span] += sizes[(seed >> 64) % 9];
        }
    }

    /// @dev D138 over step tops in checked arithmetic, in two plain passes: every used step
    ///      not below the cap is a candidate `min(D_s, cap)`; `R*` is their maximum; the result
    ///      is the lowest candidate within the margin.
    function _stepReference(uint256[] memory live, UniformClearing.Rules memory rules)
        internal
        pure
        returns (UniformClearing.Result memory r)
    {
        uint256 steps = live.length * 8;
        uint256[] memory rev = new uint256[](steps);
        uint256[] memory k = new uint256[](steps);
        uint256[] memory above = new uint256[](steps);
        uint256 d;
        for (uint256 s = steps; s != 0;) {
            --s;
            uint256 n = _unitsAt(live, s);
            if (n == 0) continue;
            if (rules.maxCount != 0 && d >= rules.maxCount) break;
            above[s] = d;
            d += n;
            k[s] = rules.maxCount != 0 && d > rules.maxCount ? rules.maxCount : d;
            rev[s] = k[s] * StepLadder.price(rules.basePrice, rules.stepsPerDecade, s);
            if (rev[s] > r.bestRevenue) r.bestRevenue = rev[s];
        }
        for (uint256 s; s < steps; ++s) {
            if (k[s] != 0 && rev[s] * 100_000 >= r.bestRevenue * (100_000 - rules.marginShare)) {
                r.count = k[s];
                r.step = s;
                r.price = StepLadder.price(rules.basePrice, rules.stepsPerDecade, s);
                r.cutUnits = k[s] - above[s];
                r.unitsAtStep = _unitsAt(live, s);
                r.rationed = r.cutUnits < r.unitsAtStep;
                return r;
            }
        }
    }

    /// @dev Clears `live` with `q` more units at `step`, and the units first-in-first-out gives
    ///      them as the newest entry there: what is left of the cut once the earlier units fill.
    function _withNewestBid(
        uint256[] memory live,
        UniformClearing.Rules memory rules,
        uint256 step,
        uint256 q
    ) internal view returns (UniformClearing.Result memory r, uint256 won) {
        uint256 before = _unitsAt(live, step);
        live[step >> 3] += q << ((step & 7) * 32);
        r = h.clear(live, rules);
        if (r.count == 0 || step < r.step) return (r, 0);
        if (step > r.step) return (r, q);
        won = r.cutUnits > before ? r.cutUnits - before : 0;
        if (won > q) won = q;
    }

    function _market(uint256 seed) internal pure returns (Market memory m) {
        m.steps = 2 + seed % 5;
        m.entered = new uint256[](m.steps);
        m.liveUnits = new uint256[](m.steps);
        (m.bStep, m.bQty, m.bPos) = (new uint256[](25), new uint256[](25), new uint256[](25));
        (m.dStep, m.dPos, m.dQty) = (new uint256[](25), new uint256[](25), new uint256[](25));
        uint256 events = 1 + _next(seed) % 25;
        for (uint256 e; e < events; ++e) {
            seed = _next(seed);
            if (m.bids != 0 && seed % 100 < 35) {
                _raise(m, (seed >> 8) % m.bids, seed >> 16);
                continue;
            }
            uint256 b = m.bids++;
            (m.bStep[b], m.bQty[b]) = ((seed >> 8) % m.steps, 1 + (seed >> 16) % 6);
            m.bPos[b] = m.entered[m.bStep[b]];
            m.entered[m.bStep[b]] += m.bQty[b];
            m.liveUnits[m.bStep[b]] += m.bQty[b];
        }
    }

    /// @dev Raises bid `b` to a random higher step: it leaves a hole and rejoins at the back.
    function _raise(Market memory m, uint256 b, uint256 seed) internal pure {
        uint256 from = m.bStep[b];
        if (from + 1 == m.steps) return;
        uint256 d = m.departures++;
        (m.dStep[d], m.dPos[d], m.dQty[d]) = (from, m.bPos[b], m.bQty[b]);
        m.liveUnits[from] -= m.bQty[b];
        uint256 to = from + 1 + seed % (m.steps - from - 1);
        (m.bStep[b], m.bPos[b]) = (to, m.entered[to]);
        m.entered[to] += m.bQty[b];
        m.liveUnits[to] += m.bQty[b];
    }

    /// @dev The settler's order (the cut step's departures sorted by position), swept.
    function _sweepInOrder(Market memory m, uint256 cutStep, uint256 x)
        internal
        view
        returns (uint256)
    {
        uint256 minPos;
        for (uint256 swept; swept < m.departures; ++swept) {
            (uint256 next, uint256 nextQty) = (type(uint256).max, 0);
            for (uint256 d; d < m.departures; ++d) {
                if (m.dStep[d] == cutStep && m.dPos[d] >= minPos && m.dPos[d] < next) {
                    (next, nextQty) = (m.dPos[d], m.dQty[d]);
                }
            }
            if (next == type(uint256).max) break;
            (x, minPos) = h.sweep(x, minPos, next, nextQty, swept);
        }
        return x;
    }
}
