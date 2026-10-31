"""Unit tests for edition_auction_ref.py, which sits beside this file.

Run with `python tools/test_edition_auction_ref.py` or, from the repository root,
`python -m tools.test_edition_auction_ref`. They also fail when the committed golden vectors
under test/fixtures/edition-auction/ are stale.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from decimal import Decimal
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "edition_auction_ref", Path(__file__).with_name("edition_auction_ref.py")
)
ref = importlib.util.module_from_spec(_SPEC)
sys.modules["edition_auction_ref"] = ref  # dataclasses resolve annotations through sys.modules
_SPEC.loader.exec_module(ref)

ETH = 10**18
ROOT = ref.repo_root(Path(__file__))


def book_of(events, cap=0, config=ref.DEFAULT, prices=None):
    book = ref.Book(config=config, cap=cap, prices=prices)
    for event in events:
        book.apply(event)
    return book


class LadderTest(unittest.TestCase):
    def test_mantissas(self):
        t = ref.MANTISSAS
        self.assertEqual(len(t), 192)
        self.assertEqual(t[:8], [100, 101, 102, 104, 105, 106, 107, 109])
        self.assertEqual(t[-3:], [965, 976, 988])
        self.assertEqual([t[j * 4] for j in range(48)][-6:], [750, 787, 825, 866, 909, 953])
        self.assertTrue(all(a < b for a, b in zip(t, t[1:])))
        self.assertLess(t[-1], 1000)

    def test_mantissas_are_far_from_a_rounding_boundary(self):
        # Doubles agree with the exact table: no value sits within 1e-3 of x.5.
        self.assertGreater(ref.mantissa_rounding_margin(), Decimal("0.001"))

    def test_default_ladder(self):
        prices = ref.ladder()
        self.assertEqual(len(prices), 336)
        self.assertEqual(prices[0], 10**14)
        self.assertEqual(prices[48], 10**15)
        self.assertEqual(prices[192], ETH)
        self.assertEqual(prices[-1], 953 * ETH)
        self.assertEqual([ref.eth(prices[i]) for i in (127, 128, 129, 130)],
                         ["0.0442", "0.0464", "0.0487", "0.0511"])
        self.assertTrue(all(a < b for a, b in zip(prices, prices[1:])))

    def test_every_allowed_ladder_rises_and_nests(self):
        for n in ref.STEPS_PER_DECADE:
            prices = [ref.price(i, 10**14, n) for i in range(3 * n + 1)]
            self.assertTrue(all(a < b for a, b in zip(prices, prices[1:])), n)
            self.assertEqual(prices[n], 10**15)
            # A coarser ladder is a subset of every finer one.
            for m in ref.STEPS_PER_DECADE:
                if m > n:
                    self.assertEqual(prices[1], ref.price(m // n, 10**14, m))

    def test_step_ratio_bounds(self):
        e48 = [ref.MANTISSAS[j * 4] for j in range(48)] + [1000]
        ratios = [b / a for a, b in zip(e48, e48[1:])]
        self.assertGreaterEqual(min(ratios), 1.043)
        self.assertLessEqual(max(ratios), 1.054)

    def test_ladder_bounds(self):
        self.assertTrue(ref.ladder_is_valid(10**14, 48, 336))
        self.assertFalse(ref.ladder_is_valid(10**14, 192, 336))  # tops out below 10 ETH
        self.assertFalse(ref.ladder_is_valid(10**14, 48, 513))
        self.assertFalse(ref.ladder_is_valid(10**12 - 1, 48, 336))
        self.assertFalse(ref.ladder_is_valid(10**14, 12, 336))
        self.assertTrue(ref.ladder_is_valid(10**17, 192, 512))

    def test_price_rejects_other_ladders(self):
        with self.assertRaises(ValueError):
            ref.price(1, 10**14, 12)

    def test_eth_formatting(self):
        self.assertEqual(ref.eth(10**14), "0.0001")
        self.assertEqual(ref.eth(953 * ETH), "953")
        self.assertEqual(ref.eth(0), "0")


class ClearingTest(unittest.TestCase):
    def test_owner_example(self):
        prices = ref.OWNER_PRICES
        totals = {0: 200, 1: 50, 2: 20, 3: 9, 4: 1}
        c = ref.clear(totals, 0, 10_000, prices.__getitem__)
        self.assertEqual((c.count, c.price, c.revenue), (80, 5 * 10**16, 4 * ETH))
        self.assertEqual(c.network_fee(), ETH)
        self.assertEqual(ref.clear(totals, 0, 30_000, prices.__getitem__).count, 280)

    def test_trace_2_and_the_tilt(self):
        book = book_of(ref.trace2_events())
        c = book.clearing()
        self.assertEqual((c.count, c.step, c.revenue), (80, 130, 4_088 * 10**15))
        self.assertEqual(c.network_fee(), 1_022 * 10**15)
        tilt = book.quote(128, 1)
        self.assertEqual((tilt["unitsWon"], tilt["result"].count, tilt["result"].step),
                         (1, 81, 128))
        self.assertEqual((tilt["unitsPushedOut"], tilt["unitsPulledIn"]), (0, 0))
        self.assertEqual(book.quote(127, 1)["unitsWon"], 0)
        self.assertEqual(book.lowest_winning_step(1), 128)

    def test_trace_3_cap_fifo_and_the_sweep(self):
        book = book_of(ref.trace3_events(), cap=60)
        c = book.clearing()
        self.assertEqual((c.count, c.step, c.rationed, c.cut_units), (60, 130, True, 30))
        self.assertEqual(book.cutoff(c), 45)
        won = {o["bidder"]: o["unitsWon"] for o in book.outcomes()}
        self.assertEqual((won["B1"], won["B2"], won["B3"], won["B4"]), (20, 15, 10, 0))
        refund = {o["bidder"]: o["refund"] for o in book.outcomes()}
        self.assertEqual(refund["B2"], 7_335 * 10**14)
        self.assertEqual(refund["B4"], 1_022 * 10**15)
        self.assertEqual(c.network_fee(), 7_665 * 10**14)
        # Without the sweep, B3 would win nothing and 10 editions would be lost.
        self.assertEqual(max(0, min(c.cut_units - 35, 10)), 0)

    def test_no_bids(self):
        self.assertEqual(ref.Book().clearing(), ref.NO_RESULT)

    def test_matches_brute_force(self):
        ref.check_clearing(4_000)

    def test_fifo_sums_and_order(self):
        ref.check_fifo(2_000)

    def test_winning_is_monotone_in_the_step(self):
        ref.check_monotone(600)


class BookTest(unittest.TestCase):
    def test_positions_only_when_capped(self):
        uncapped = book_of(ref._bids(("A", 5, 2), ("B", 5, 3)))
        self.assertEqual([b.position for b in uncapped.bids.values()], [0, 0])
        capped = book_of(ref._bids(("A", 5, 2), ("B", 5, 3)), cap=4)
        self.assertEqual([b.position for b in capped.bids.values()], [0, 2])

    def test_raise_rejoins_at_the_back_and_pays_the_difference(self):
        book = book_of(ref._bids(("A", 5, 2), ("B", 6, 3), ("C", 5, 1)), cap=5)
        top_up = book.raise_bid(1, 6)
        self.assertEqual(top_up, 2 * (ref.price(6) - ref.price(5)))
        self.assertEqual(book.bids[1].position, 3)
        self.assertEqual(book.departures[5], [(0, 2)])
        self.assertEqual(book.units_ahead(book.bids[3]), 0)

    def test_refused_actions(self):
        book = book_of(ref._bids(("A", 5, 2)))
        for action in (lambda: book.raise_bid(1, 5), lambda: book.bid("B", 336, 1),
                       lambda: book.bid("B", 0, 0), lambda: book.bid("B", 0, 2**32),
                       lambda: book.raise_bid(9, 7)):
            with self.assertRaises(ref.InvalidAction):
                action()
        book.withdraw(1)
        with self.assertRaises(ref.InvalidAction):
            book.withdraw(1)

    def test_settlement_order_sorts_the_cut_step_departures(self):
        book = book_of(ref.fifo_holes_events(), cap=30)
        c = book.clearing()
        self.assertEqual(book.departures[200], [(6, 5), (21, 8), (35, 4), (0, 6)])
        self.assertEqual(book.settlement_order(c), [3, 0, 1, 2])
        self.assertEqual((c.cut_units, book.cutoff(c)), (11, 30))


class VectorTest(unittest.TestCase):
    def test_committed_vectors_are_current(self):
        self.assertEqual(ref.main(["--check", "--root", str(ROOT)]), 0)

    def test_every_case_matches_brute_force_and_sums(self):
        data = json.loads((ROOT / ref.VECTOR_DIR / "clearing.json").read_text(encoding="utf-8"))
        names = [c["name"] for c in data["cases"]]
        self.assertEqual(len(names), len(set(names)))
        for case in data["cases"]:
            expected = case["expected"]
            won = sum(b["unitsWon"] for b in expected["bids"])
            self.assertEqual(won, expected["clearing"]["count"], case["name"])

    def test_ladder_vector(self):
        data = json.loads((ROOT / ref.VECTOR_DIR / "ladder.json").read_text(encoding="utf-8"))
        self.assertEqual(len(data["steps"]), 336)
        self.assertEqual(data["steps"][-1]["priceEth"], "953")
        self.assertEqual(data["mantissas"], ref.MANTISSAS)


if __name__ == "__main__":
    unittest.main()
