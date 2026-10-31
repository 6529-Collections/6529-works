#!/usr/bin/env python3
"""Reference model of the 6529 Stream Editions auction (ADR 0005; 6529chain D138-D141).

The one executable definition of the edition auction's arithmetic, for the contracts' tests,
the frontend and CI. Standard library only. It covers:
  - the step ladder: `MANTISSAS`, round half up of 100 * 10^(j/192) for j < 192, and
    `price(step)`, exactly as `src/interfaces/types/StepLadder.sol` computes it;
  - the clearing rule (`clear`) and a brute force over unit bids (`brute`) that defines it;
  - an event-sourced bid book (`Book`): bids, raises and dispute withdrawals, FIFO queue
    positions at each step when a cap is set, the departure log, the sorted departure sweep
    that settlement runs at the cut step, and every bid's outcome;
  - the views a client shows: `Book.quote` (what a new bid would win and change) and
    `Book.lowest_winning_step`;
  - the golden vectors under `test/fixtures/edition-auction/`, which `--write` regenerates and
    `--check` (CI) compares.

Conventions, as in the contracts: amounts are integers in wei; shares and the breadth margin
are out of 100,000 (`DENOMINATOR`); steps are 0-based ladder indices; a cap of 0 means none.

Run from anywhere:
  python tools/edition_auction_ref.py --check    fail if the committed vectors are stale (CI)
  python tools/edition_auction_ref.py --write    regenerate the vectors
  python tools/edition_auction_ref.py --ladder   print the default ladder
Its tests: `python -m tools.test_edition_auction_ref`.
"""

from __future__ import annotations

import argparse
import copy
import json
import random
import sys
from dataclasses import dataclass, field
from decimal import ROUND_HALF_UP, Context, Decimal
from pathlib import Path

DENOMINATOR = 100_000
TABLE_SIZE = 192
STEPS_PER_DECADE = (24, 48, 96, 192)
MAX_QUANTITY = 2**32 - 1
NETWORK_FEE_SHARE = 25_000

VECTOR_DIR = Path("test") / "fixtures" / "edition-auction"


# --------------------------------------------------------------------------------- ladder


def _mantissa_table() -> list[int]:
    ctx = Context(prec=60)
    table = []
    for j in range(TABLE_SIZE):
        value = ctx.multiply(ctx.power(Decimal(10), ctx.divide(Decimal(j), Decimal(TABLE_SIZE))), 100)
        table.append(int(value.quantize(Decimal(1), rounding=ROUND_HALF_UP, context=ctx)))
    return table


MANTISSAS: list[int] = _mantissa_table()


def mantissa_rounding_margin() -> Decimal:
    """The smallest distance of any 100 * 10^(j/192) from a rounding boundary (x.5).

    A positive margin far above float64 error means a client that computes the table with
    doubles gets the same integers; the vectors still list it so nobody has to.
    """
    ctx = Context(prec=60)
    worst = Decimal(1)
    for j in range(TABLE_SIZE):
        value = ctx.multiply(ctx.power(Decimal(10), ctx.divide(Decimal(j), Decimal(TABLE_SIZE))), 100)
        frac = value - int(value)
        worst = min(worst, abs(frac - Decimal("0.5")))
    return worst


@dataclass(frozen=True)
class Config:
    """The governed parameters an auction locks when it opens (`IUniformEditionAuction`)."""

    base_price: int = 10**14
    steps_per_decade: int = 48
    step_count: int = 336
    margin_share: int = 10_000
    close_offset: int = 15 * 60
    soft_window: int = 5 * 60
    max_extension: int = 24 * 60 * 60

    def price(self, step: int) -> int:
        return price(step, self.base_price, self.steps_per_decade)

    def as_json(self) -> dict:
        return {
            "basePrice": str(self.base_price),
            "stepsPerDecade": self.steps_per_decade,
            "stepCount": self.step_count,
            "marginShare": self.margin_share,
            "closeOffset": self.close_offset,
            "softWindow": self.soft_window,
            "maxExtension": self.max_extension,
        }


DEFAULT = Config()


def price(step: int, base_price: int = DEFAULT.base_price, steps_per_decade: int = 48) -> int:
    """`base * MANTISSAS[(step % N) * (192 / N)] * 10^(step / N) / 100`, dividing last."""
    if steps_per_decade not in STEPS_PER_DECADE:
        raise ValueError(f"steps per decade {steps_per_decade} not in {STEPS_PER_DECADE}")
    if step < 0:
        raise ValueError("negative step")
    stride = TABLE_SIZE // steps_per_decade
    decade, index = divmod(step, steps_per_decade)
    return base_price * 10**decade * MANTISSAS[index * stride] // 100


def ladder(config: Config = DEFAULT) -> list[int]:
    return [config.price(i) for i in range(config.step_count)]


# The ladder bounds governance may set (`StepLadder.isValid`). The base price is a power of
# ten (`StepLadder.isBasePrice`), so every price reads as the table does (decision 3).
MIN_BASE_PRICE, MAX_BASE_PRICE = 10**12, 10**17
BASE_PRICES = tuple(10**k for k in range(12, 18))
MIN_STEP_COUNT, MAX_STEP_COUNT = 64, 512
MIN_TOP_PRICE = 10 * 10**18


def ladder_is_valid(base_price: int, steps_per_decade: int, step_count: int) -> bool:
    return (steps_per_decade in STEPS_PER_DECADE
            and base_price in BASE_PRICES
            and MIN_STEP_COUNT <= step_count <= MAX_STEP_COUNT
            and price(step_count - 1, base_price, steps_per_decade) >= MIN_TOP_PRICE)


def eth(wei: int) -> str:
    """Exact decimal ETH, without trailing zeros."""
    text = format(Decimal(wei).scaleb(-18), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text


# ------------------------------------------------------------------------------- clearing


@dataclass(frozen=True)
class Clearing:
    """The result of the clearing rule on a book of step totals.

    `count` editions at `step`'s `price`. `rationed`: a cap binds inside `step`, so only
    `cut_units` of its `units_at_step` live units win. `best_revenue` is R*, the highest
    candidate revenue. With no bids, `count` is 0 and `step` is None.
    """

    count: int
    step: int | None
    price: int
    revenue: int
    best_revenue: int
    rationed: bool
    cut_units: int
    units_at_step: int

    def network_fee(self, fee_share: int = NETWORK_FEE_SHARE) -> int:
        return self.revenue * fee_share // DENOMINATOR


NO_RESULT = Clearing(0, None, 0, 0, 0, False, 0, 0)


def clear(totals: dict[int, int], cap: int, margin_share: int, price_of) -> Clearing:
    """The D138 rule in one pass over the used steps, from the top.

    Each used step s is a candidate: k_s = min(D_s, cap) editions at p(s), where D_s is the
    number of live units at or above s. The scan stops once the demand strictly above the
    current step has reached the cap. R* is the highest candidate revenue; the result is the
    lowest-priced candidate with `revenue * 100,000 >= R* * (100,000 - margin)`.
    """
    candidates = []
    demand = 0
    best = 0
    for step in sorted((s for s, n in totals.items() if n > 0), reverse=True):
        above = demand
        if cap and above >= cap:
            break
        demand += totals[step]
        k = min(demand, cap) if cap else demand
        revenue = k * price_of(step)
        candidates.append((step, k, revenue, above))
        best = max(best, revenue)
    if not candidates:
        return NO_RESULT
    pick = None
    for step, k, revenue, above in candidates:  # top-down: the last match is the lowest step
        if revenue * DENOMINATOR >= best * (DENOMINATOR - margin_share):
            pick = (step, k, revenue, above)
    step, k, revenue, above = pick
    units = totals[step]
    return Clearing(k, step, price_of(step), revenue, best, k < above + units, k - above, units)


def brute(totals: dict[int, int], cap: int, margin_share: int, price_of) -> tuple[int, int]:
    """D138 per unit: revenue(k) = k * the k-th highest unit bid; (count, price)."""
    units: list[int] = []
    for step in sorted(totals, reverse=True):
        units += [price_of(step)] * totals[step]
    if cap:
        units = units[:cap]
    if not units:
        return (0, 0)
    revenues = [(k + 1) * units[k] for k in range(len(units))]
    best = max(revenues)
    k = max(
        i + 1
        for i in range(len(units))
        if revenues[i] * DENOMINATOR >= best * (DENOMINATOR - margin_share)
    )
    return (k, units[k - 1])


def sweep(clearing: Clearing, departures: list[tuple[int, int]]) -> int:
    """The cutoff X at a rationed cut step: start at the units the step wins (A) and, in
    position order, add each departure (a hole left by a raise or a withdrawal) whose position
    is below X. Bid b at the step then wins clamp(X - pos_b, 0, qty_b)."""
    cutoff = clearing.cut_units
    for position, quantity in sorted(departures):
        if position < cutoff:
            cutoff += quantity
        else:
            break
    return cutoff


# ----------------------------------------------------------------------------------- book


@dataclass
class Bid:
    bid_id: int
    bidder: str
    step: int
    quantity: int
    position: int
    escrow: int
    active: bool = True


class InvalidAction(ValueError):
    """An action the contract would refuse."""


@dataclass
class Book:
    """One auction's bid book, built from its events in order.

    Positions are counted in entered units per step and never decrease; they exist only when
    a cap is set (an uncapped step is never split, so its bids all report position 0). A raise
    or a withdrawal at a capped auction leaves a departure (its old position and quantity) at
    its old step; settlement sweeps the cut step's departures in position order.
    """

    config: Config = DEFAULT
    cap: int = 0
    fee_share: int = NETWORK_FEE_SHARE
    prices: list[int] | None = None  # an explicit price per step, instead of the ladder
    live: dict[int, int] = field(default_factory=dict)
    entered: dict[int, int] = field(default_factory=dict)
    departures: dict[int, list[tuple[int, int]]] = field(default_factory=dict)
    bids: dict[int, Bid] = field(default_factory=dict)
    next_id: int = 1

    # -- prices
    def price(self, step: int) -> int:
        if self.prices is not None:
            return self.prices[step]
        return self.config.price(step)

    @property
    def step_count(self) -> int:
        return len(self.prices) if self.prices is not None else self.config.step_count

    @property
    def margin_share(self) -> int:
        return self.config.margin_share

    # -- actions
    def _check_step(self, step: int) -> None:
        if not 0 <= step < self.step_count:
            raise InvalidAction(f"step {step} outside the ladder")

    def _check_entry(self, step: int, quantity: int, moving: bool = False) -> None:
        """Refuses (`InvalidQuantity`) `quantity` more units at `step` that would take the
        step's entered units (capped sales, where positions exist) or live units, or the sale's
        live units, past 2^32 - 1. `moving`: the units already count in the sale's live units
        (a raise moves them from another step). Changes nothing."""
        if self.cap and self.entered.get(step, 0) + quantity > MAX_QUANTITY:
            raise InvalidAction("step's entered units past 2^32 - 1")
        if self.live.get(step, 0) + quantity > MAX_QUANTITY:
            raise InvalidAction("step's live units past 2^32 - 1")
        if not moving and self.total_units() + quantity > MAX_QUANTITY:
            raise InvalidAction("sale's live units past 2^32 - 1")

    def _enter(self, step: int, quantity: int) -> int:
        """Validates first, then queues `quantity` units at `step`; returns their position."""
        self._check_entry(step, quantity)
        position = 0
        if self.cap:
            position = self.entered.get(step, 0)
            self.entered[step] = position + quantity
        self.live[step] = self.live.get(step, 0) + quantity
        return position

    def _leave(self, bid: Bid) -> None:
        self.live[bid.step] -= bid.quantity
        if self.cap:
            self.departures.setdefault(bid.step, []).append((bid.position, bid.quantity))

    def bid(self, bidder: str, step: int, quantity: int) -> int:
        self._check_step(step)
        if not 1 <= quantity <= MAX_QUANTITY:
            raise InvalidAction(f"quantity {quantity}")
        position = self._enter(step, quantity)
        bid_id = self.next_id
        self.next_id += 1
        self.bids[bid_id] = Bid(bid_id, bidder, step, quantity, position, quantity * self.price(step))
        return bid_id

    def raise_bid(self, bid_id: int, new_step: int) -> int:
        """Moves a whole bid up; returns the exact top-up it pays."""
        bid = self._active(bid_id)
        self._check_step(new_step)
        if new_step <= bid.step:
            raise InvalidAction("a raise must move up")
        # Every check before the bid leaves its step, so a refused raise changes nothing.
        self._check_entry(new_step, bid.quantity, moving=True)
        top_up = bid.quantity * (self.price(new_step) - self.price(bid.step))
        self._leave(bid)
        bid.step = new_step
        bid.position = self._enter(new_step, bid.quantity)
        bid.escrow += top_up
        return top_up

    def withdraw(self, bid_id: int) -> int:
        """A withdrawal while the 1/1 is paused for a dispute; returns the refund."""
        bid = self._active(bid_id)
        self._leave(bid)
        bid.active = False
        return bid.escrow

    def _active(self, bid_id: int) -> Bid:
        bid = self.bids.get(bid_id)
        if bid is None or not bid.active:
            raise InvalidAction(f"no active bid {bid_id}")
        return bid

    def apply(self, event: dict) -> None:
        op = event["op"]
        if op == "bid":
            self.bid(event["bidder"], event["step"], event["quantity"])
        elif op == "raise":
            self.raise_bid(event["bidId"], event["toStep"])
        elif op == "withdraw":
            self.withdraw(event["bidId"])
        else:
            raise ValueError(f"unknown op {op}")

    # -- reads
    def total_units(self) -> int:
        return sum(self.live.values())

    def totals(self) -> dict[int, int]:
        return {s: n for s, n in self.live.items() if n > 0}

    def clearing(self) -> Clearing:
        return clear(self.totals(), self.cap, self.margin_share, self.price)

    def settlement_order(self, clearing: Clearing | None = None) -> list[int]:
        """The cut step's departure indexes (in log order) sorted by position: the hint
        `settle` takes. Empty unless the result is rationed."""
        clearing = clearing or self.clearing()
        if not clearing.rationed:
            return []
        log = self.departures.get(clearing.step, [])
        return sorted(range(len(log)), key=lambda i: log[i][0])

    def cutoff(self, clearing: Clearing | None = None) -> int | None:
        clearing = clearing or self.clearing()
        if not clearing.rationed:
            return None
        return sweep(clearing, self.departures.get(clearing.step, []))

    def units_won(self, bid: Bid, clearing: Clearing, cutoff: int | None) -> int:
        if not bid.active or clearing.count == 0 or bid.step < clearing.step:
            return 0
        if bid.step > clearing.step or not clearing.rationed:
            return bid.quantity
        return max(0, min(cutoff - bid.position, bid.quantity))

    def units_ahead(self, bid: Bid) -> int:
        """Live units ahead of `bid` in its step's queue (capped auctions; 0 otherwise)."""
        if not self.cap or not bid.active:
            return 0
        holes = sum(q for p, q in self.departures.get(bid.step, []) if p < bid.position)
        return bid.position - holes

    def outcomes(self) -> list[dict]:
        clearing = self.clearing()
        cutoff = self.cutoff(clearing)
        out = []
        for bid in self.bids.values():
            won = self.units_won(bid, clearing, cutoff)
            paid = won * clearing.price
            out.append({
                "bidId": bid.bid_id,
                "bidder": bid.bidder,
                "active": bid.active,
                "step": bid.step,
                "quantity": bid.quantity,
                "position": bid.position,
                "escrow": bid.escrow if bid.active else 0,
                "unitsWon": won,
                "refund": (bid.escrow - paid) if bid.active else 0,
                "unitsAhead": self.units_ahead(bid),
            })
        return out

    def quote(self, step: int, quantity: int) -> dict:
        """What a new bid of `quantity` at `step` would win if the auction closed now, and the
        net change in the existing bids' winning units (at most one of the two is nonzero)."""
        before = self.clearing()
        trial = copy.deepcopy(self)
        bid_id = trial.bid("quote", step, quantity)
        after = trial.clearing()
        won = trial.units_won(trial.bids[bid_id], after, trial.cutoff(after))
        others = after.count - won
        return {
            "unitsWon": won,
            "escrow": quantity * self.price(step),
            "unitsPushedOut": max(0, before.count - others),
            "unitsPulledIn": max(0, others - before.count),
            "result": after,
        }

    def lowest_winning_step(self, quantity: int) -> int | None:
        """The lowest step at which a new bid of `quantity` would win at least one unit, by a
        linear scan (the definition; the contract may search faster where it is equivalent)."""
        for step in range(self.step_count):
            if self.quote(step, quantity)["unitsWon"] > 0:
                return step
        return None


# ------------------------------------------------------------------------ golden vectors


def _clearing_json(c: Clearing, cutoff: int | None, fee_share: int) -> dict:
    return {
        "count": c.count,
        "step": c.step,
        "price": str(c.price),
        "priceEth": eth(c.price),
        "revenue": str(c.revenue),
        "revenueEth": eth(c.revenue),
        "networkFee": str(c.network_fee(fee_share)),
        "networkFeeEth": eth(c.network_fee(fee_share)),
        "bestRevenue": str(c.best_revenue),
        "rationed": c.rationed,
        "cutUnits": c.cut_units,
        "unitsAtStep": c.units_at_step,
        "cutoff": cutoff,
    }


def _bid_json(outcome: dict) -> dict:
    o = dict(outcome)
    o["escrow"] = str(o["escrow"])
    o["refund"] = str(o["refund"])
    return o


def _case(name: str, description: str, events: list[dict], *, cap: int = 0,
          config: Config = DEFAULT, prices: list[int] | None = None,
          quotes: tuple[tuple[int, int], ...] = (), lowest: tuple[int, ...] = ()) -> dict:
    book = Book(config=config, cap=cap, prices=prices)
    for event in events:
        book.apply(event)
    clearing = book.clearing()
    cutoff = book.cutoff(clearing)
    winners = sum(o["unitsWon"] for o in book.outcomes())
    assert winners == clearing.count, (name, winners, clearing.count)
    k, p = brute(book.totals(), cap, config.margin_share, book.price)
    assert (k, p if k else 0) == (clearing.count, clearing.price), (name, k, p, clearing)
    used = sorted(book.totals())
    case = {
        "name": name,
        "description": description,
        "config": config.as_json(),
        "cap": cap,
        "events": events,
        "expected": {
            "clearing": _clearing_json(clearing, cutoff, book.fee_share),
            "stepTotals": {str(s): book.live[s] for s in used},
            "settlementOrder": book.settlement_order(clearing),
            "departures": {
                str(s): [list(d) for d in log] for s, log in sorted(book.departures.items())
            },
            "bids": [_bid_json(o) for o in book.outcomes()],
        },
    }
    if prices is not None:
        case["prices"] = [str(x) for x in prices]
    if quotes:
        case["quotes"] = []
        for step, quantity in quotes:
            q = book.quote(step, quantity)
            r = q["result"]
            case["quotes"].append({
                "step": step,
                "quantity": quantity,
                "unitsWon": q["unitsWon"],
                "escrow": str(q["escrow"]),
                "unitsPushedOut": q["unitsPushedOut"],
                "unitsPulledIn": q["unitsPulledIn"],
                "result": _clearing_json(r, None, book.fee_share),
            })
    if lowest:
        case["lowestWinningStep"] = [
            {"quantity": q, "step": book.lowest_winning_step(q)} for q in lowest
        ]
    return case


def _bids(*items: tuple[str, int, int]) -> list[dict]:
    return [{"op": "bid", "bidder": b, "step": s, "quantity": q} for b, s, q in items]


# The owner's D138 figures and Appendix C of the plan, snapped to the default ladder.
STEP_0_01, STEP_0_0442, STEP_0_0464, STEP_0_0511 = 96, 127, 128, 130
STEP_0_1, STEP_0_196, STEP_1 = 144, 158, 192
OWNER_PRICES = [10**16, 5 * 10**16, 10**17, 2 * 10**17, 10**18]  # 0.01 .. 1.0 ETH


def trace2_events() -> list[dict]:
    """1 @ 1.00, 9 @ 0.196, 20 @ 0.100, 50 @ 0.0511, 200 @ 0.0100: cumulative 1/10/30/80/280."""
    return _bids(("A", STEP_1, 1), ("C", STEP_0_196, 9), ("D", STEP_0_1, 20),
                 ("E", STEP_0_0511, 50), ("F", STEP_0_01, 200))


def trace3_events() -> list[dict]:
    """Trace 2's final book under a cap of 60, built with the queue the plan describes at
    step 130: B1 20 (position 0), B2 15 (20, later raised to 0.100, leaving a hole), B3 10 (35),
    B4 20 (45). B2's raise is what brings step 144 to its 20 units."""
    events = _bids(("A", STEP_1, 1), ("C", STEP_0_196, 9), ("D", STEP_0_1, 5),
                   ("B1", STEP_0_0511, 20), ("B2", STEP_0_0511, 15), ("B3", STEP_0_0511, 10),
                   ("B4", STEP_0_0511, 20), ("F", STEP_0_01, 200))
    events.append({"op": "raise", "bidId": 5, "toStep": STEP_0_1})
    return events


def dense_events(config: Config = DEFAULT) -> list[dict]:
    """Every step used, 1 + (step % 7) units each: the settlement worst case."""
    return _bids(*((f"U{i}", i, 1 + i % 7) for i in range(config.step_count)))


def fifo_holes_events() -> list[dict]:
    """A capped cut step (200) with four holes, logged out of position order: three below the
    final cutoff (two raises and a dispute withdrawal) and one above it (a raise)."""
    events = _bids(("T", 210, 4), ("Q1", 200, 6), ("Q2", 200, 5), ("Q3", 200, 7),
                   ("Q4", 200, 3), ("Q5", 200, 8), ("Q6", 200, 6), ("Q7", 200, 4),
                   ("L", 150, 40))
    events += [
        {"op": "raise", "bidId": 3, "toStep": 210},   # Q2: hole at position 6
        {"op": "withdraw", "bidId": 6},               # Q5, during a 1/1 pause: hole at 21
        {"op": "raise", "bidId": 8, "toStep": 205},   # Q7: hole at 35, above the cutoff
        {"op": "raise", "bidId": 2, "toStep": 205},   # Q1: hole at 0
    ]
    return events


def clearing_vectors() -> dict:
    owner = Config(margin_share=10_000)
    cases = [
        _case("d138-owner-example",
              "The owner's D138 figures on their own prices (steps 0-4 = 0.01, 0.05, 0.1, 0.2 "
              "and 1.0 ETH): 80 editions at 0.05 ETH, 4 ETH raised, 1 ETH to the network.",
              _bids(("A", 4, 1), ("B", 3, 9), ("C", 2, 20), ("D", 1, 50), ("E", 0, 200)),
              config=owner, prices=OWNER_PRICES),
        _case("d138-owner-example-margin-0",
              "The same book with no breadth margin: the revenue maximum alone, 80 at 0.05.",
              _bids(("A", 4, 1), ("B", 3, 9), ("C", 2, 20), ("D", 1, 50), ("E", 0, 200)),
              config=Config(margin_share=0), prices=OWNER_PRICES),
        _case("d138-owner-example-margin-30",
              "The same book with a 30% margin: 280 at 0.01 passes, since 2.8 >= 0.7 * 4.0.",
              _bids(("A", 4, 1), ("B", 3, 9), ("C", 2, 20), ("D", 1, 50), ("E", 0, 200)),
              config=Config(margin_share=30_000), prices=OWNER_PRICES),
        _case("trace-2-default-ladder",
              "The owner's bids snapped to the default ladder: 80 at 0.0511 ETH, 4.088 ETH "
              "raised, 1.022 ETH to the network. A new bid of 1 gets in from 0.0464 (step 128) "
              "and moves everyone to 81 at 0.0464; at 0.0442 (step 127) it does not get in.",
              trace2_events(),
              quotes=((STEP_0_0464, 1), (STEP_0_0442, 1), (STEP_0_0511, 1), (STEP_1, 1),
                      (STEP_0_1, 60)),
              lowest=(1, 10, 100)),
        _case("trace-2-breadth-tilt",
              "Trace 2 plus one unit at 0.0464: 81 x 0.0464 = 3.7584 >= 0.9 x 4.088, so the "
              "result tilts to 81 at 0.0464 and revenue falls 8%.",
              trace2_events() + _bids(("G", STEP_0_0464, 1))),
        _case("trace-2-no-tilt",
              "Trace 2 plus one unit at 0.0442: 81 x 0.0442 = 3.5802 < 3.6792, so the result "
              "stays 80 at 0.0511 and the new unit loses.",
              trace2_events() + _bids(("G", STEP_0_0442, 1))),
        _case("trace-2-margin-50",
              "Trace 2 with the largest margin the bounds allow (50%): 280 at 0.0100 passes "
              "(2.8 >= 0.5 x 4.088).",
              trace2_events(), config=Config(margin_share=50_000)),
        _case("trace-3-cap-60-fifo-hole",
              "Trace 2's book under a cap of 60. 60 x 0.0511 = 3.066 is R*; step 130 is "
              "rationed (A = 30 of its 50 units). The sweep starts at X = 30, meets B2's hole "
              "at position 20 and ends at 45: B1 wins 20, B3 10, B4 0. Without the sweep B3 "
              "would get nothing and 10 editions would be lost. B2 wins 15 at 0.0511 above the "
              "cut and gets 0.7335 ETH back.",
              trace3_events(), cap=60),
        _case("zero-bids", "No bids: no editions, nothing paid.", []),
        _case("one-bid", "One bid of 3 at step 100: 3 editions at its step's price.",
              _bids(("A", 100, 3))),
        _case("one-step-uncapped",
              "Every bid on one step and no cap: all of them win, unsplit.",
              _bids(("A", 120, 5), ("B", 120, 12), ("C", 120, 1), ("D", 120, 19))),
        _case("one-step-capped",
              "The same bids under a cap of 20: the step is rationed and fills in arrival "
              "order; C (1 unit) is not rounded away, D is partly filled.",
              _bids(("A", 120, 5), ("B", 120, 12), ("C", 120, 1), ("D", 120, 19)), cap=20),
        _case("cap-1",
              "A cap of 1: the single edition goes to the first unit entered at the highest "
              "step, at that step's price.",
              _bids(("A", 90, 2), ("B", 140, 3), ("C", 140, 1), ("D", 60, 50)), cap=1,
              quotes=((141, 1), (140, 5)), lowest=(1,)),
        _case("ladder-ends",
              "Bids at the base step (0.0001 ETH) and the top step (953 ETH).",
              _bids(("A", 0, 1000), ("B", DEFAULT.step_count - 1, 1))),
        _case("fifo-holes",
              "A capped auction (cap 30) whose cut step (200) logged four departures out of "
              "position order: Q2's raise (position 6), Q5's dispute withdrawal (21), Q7's "
              "raise (35) and Q1's raise (0). The settler's order sorts them by position. The "
              "sweep starts at A = 11 and takes the holes at 0, 6 and 21 (X = 30); the hole at "
              "35 is above X. Q3 wins 7, Q4 3 and Q6 1 of 6.",
              fifo_holes_events(), cap=30),
        _case("dense-book",
              "All 336 steps used, 1 + (step % 7) units each: the settlement worst case.",
              dense_events()),
        _case("dense-book-capped",
              "The dense book under a cap of 100: the scan stops once demand above reaches it.",
              dense_events(), cap=100),
    ]
    return {
        "description": "Golden vectors of the 6529 Stream Editions auction (ADR 0005). Each "
                       "case replays its events (bid, raise, withdraw; bid IDs from 1 in order) "
                       "on a fresh auction with `config` and `cap`, then expects the live "
                       "clearing, the settlement order and every bid's outcome as if the "
                       "auction closed now. Prices come from the ladder, or from `prices` "
                       "(wei per step index) where given. Amounts are wei as decimal strings; "
                       "`*Eth` fields are the same amounts in ETH, for reading. Network fee: "
                       "25,000 of 100,000. `cutoff` is the settlement sweep's X (rationed only); "
                       "positions count entered units per step (capped auctions only).",
        "model": "tools/edition_auction_ref.py",
        "denominator": DENOMINATOR,
        "networkFeeShare": NETWORK_FEE_SHARE,
        "cases": cases,
    }


def ladder_vectors() -> dict:
    steps = [{"step": i, "price": str(p), "priceEth": eth(p)} for i, p in enumerate(ladder())]
    others = {}
    for n in STEPS_PER_DECADE:
        cfg = Config(steps_per_decade=n)
        stride = TABLE_SIZE // n
        others[str(n)] = {
            "mantissas": [MANTISSAS[j * stride] for j in range(n)],
            "first": [str(cfg.price(i)) for i in range(5)],
            "stepsToOneEth": next(i for i in range(4096) if cfg.price(i) >= 10**18),
        }
    ratios = [MANTISSAS[(j + 1) * 4] / MANTISSAS[j * 4] for j in range(47)]
    ratios.append(1000 / MANTISSAS[47 * 4])
    bounds = [
        (10**14, 48, 336), (10**14, 48, 64), (10**14, 48, 512), (10**14, 24, 336),
        (10**14, 96, 336), (10**14, 96, 512), (10**14, 192, 512), (10**17, 192, 512),
        (10**12, 48, 336), (10**12 - 1, 48, 336), (10**17, 48, 336), (10**17 + 1, 48, 336),
        (10**14, 48, 63), (10**14, 48, 513), (10**14, 12, 336), (10**14, 0, 336),
        (10**16, 192, 512),  # the top step at 4.59 ETH
        (10**12, 48, 512), (10**13, 48, 336), (10**15, 48, 336), (10**16, 48, 336),
        # In range and with a top step above 10 ETH, but not powers of ten.
        (3 * 10**16, 192, 512), (5 * 10**14, 48, 336), (10**14 + 1, 48, 336),
        (2 * 10**12, 48, 512), (10**17 - 1, 48, 336),
        (10**14, 48, 240), (10**14, 48, 241),  # the top step at 9.53 ETH, then exactly 10 ETH
    ]
    return {
        "description": "The step ladder of the 6529 Stream Editions auction (ADR 0005): "
                       "price(step) = basePrice * mantissas[(step % stepsPerDecade) * "
                       "(192 / stepsPerDecade)] * 10^(step / stepsPerDecade) / 100, integer "
                       "division last. `mantissas` is round half up of 100 * 10^(j / 192). "
                       "`prices` and `steps` are the default ladder (wei, and readable ETH); "
                       "`ladders` gives the mantissas and first prices of each allowed "
                       "steps-per-decade at the default base price; `bounds` gives ladders "
                       "governance may or may not set (`StepLadder.isValid`: among them, "
                       "the base price is a power of ten from 10^12 to 10^17 wei).",
        "model": "tools/edition_auction_ref.py",
        "mantissas": MANTISSAS,
        "default": {
            "basePrice": str(DEFAULT.base_price),
            "stepsPerDecade": DEFAULT.steps_per_decade,
            "stepCount": DEFAULT.step_count,
            "topPrice": str(DEFAULT.price(DEFAULT.step_count - 1)),
            "topPriceEth": eth(DEFAULT.price(DEFAULT.step_count - 1)),
            "stepRatioMin": f"{min(ratios):.4f}",
            "stepRatioMax": f"{max(ratios):.4f}",
        },
        "prices": [str(p) for p in ladder()],
        "steps": steps,
        "ladders": others,
        "bounds": [
            {"basePrice": str(b), "stepsPerDecade": n, "stepCount": c,
             "valid": ladder_is_valid(b, n, c)}
            for b, n, c in bounds
        ],
    }


def vectors() -> dict[str, dict]:
    return {"ladder.json": ladder_vectors(), "clearing.json": clearing_vectors()}


def _flat(value) -> bool:
    if isinstance(value, dict):
        return all(not isinstance(v, (dict, list)) for v in value.values())
    if isinstance(value, list):
        return all(not isinstance(v, (dict, list)) for v in value)
    return True


def _render(value, indent: int) -> str:
    pad, inner = " " * indent, " " * (indent + 2)
    if isinstance(value, dict) and value and not (_flat(value) and indent > 2):
        items = [f"{inner}{json.dumps(k)}: {_render(v, indent + 2)}" for k, v in value.items()]
        return "{\n" + ",\n".join(items) + f"\n{pad}}}"
    if isinstance(value, list) and value and not all(isinstance(v, int) for v in value):
        if all(_flat(v) for v in value):
            # One flat object (an event, a bid, a step) per line keeps the file reviewable.
            return "[\n" + ",\n".join(inner + json.dumps(v) for v in value) + f"\n{pad}]"
        return "[\n" + ",\n".join(inner + _render(v, indent + 2) for v in value) + f"\n{pad}]"
    return json.dumps(value)


def render(data: dict) -> str:
    """JSON with two-space nesting, and flat objects and integer lists on one line each."""
    text = _render(data, 0) + "\n"
    assert json.loads(text) == data
    return text


def repo_root(start: Path | None = None) -> Path:
    here = (start or Path(__file__)).resolve()
    for parent in [here, *here.parents]:
        if (parent / "foundry.toml").is_file():
            return parent
    raise SystemExit("no foundry.toml above this script")


# ------------------------------------------------------------------------- self checks


def random_book(rng: random.Random) -> tuple[dict[int, int], int, int, Config]:
    n = rng.randint(1, 12)
    cfg = Config(steps_per_decade=rng.choice(STEPS_PER_DECADE), step_count=max(n, 1),
                 margin_share=rng.choice([0, 5_000, 10_000, 25_000, 50_000]))
    totals = {i: rng.choice([0, 0, 1, 2, 3, 5, 8, 20]) for i in range(n)}
    cap = rng.choice([0, 0, 1, 3, 5, 10, 25])
    return {s: q for s, q in totals.items() if q}, cap, cfg.margin_share, cfg


def check_clearing(trials: int, seed: int = 1) -> None:
    rng = random.Random(seed)
    for _ in range(trials):
        totals, cap, margin, cfg = random_book(rng)
        c = clear(totals, cap, margin, cfg.price)
        k, p = brute(totals, cap, margin, cfg.price)
        assert c.count == k, (totals, cap, margin, c, k)
        if k:
            assert c.price == p
        if not cap:
            assert not c.rationed, (totals, margin, c)  # without a cap no step is split


def random_events(rng: random.Random, steps: int) -> list[dict]:
    events: list[dict] = []
    bids: dict[int, int] = {}
    active: set[int] = set()
    next_id = 1
    for _ in range(rng.randint(1, 25)):
        roll = rng.random()
        if active and roll < 0.30:
            b = rng.choice(sorted(active))
            if bids[b] < steps - 1:
                to = rng.randint(bids[b] + 1, steps - 1)
                events.append({"op": "raise", "bidId": b, "toStep": to})
                bids[b] = to
            continue
        if active and roll < 0.38:
            b = rng.choice(sorted(active))
            events.append({"op": "withdraw", "bidId": b})
            active.discard(b)
            continue
        step = rng.randrange(steps)
        events.append({"op": "bid", "bidder": f"b{next_id}", "step": step,
                       "quantity": rng.randint(1, 6)})
        bids[next_id] = step
        active.add(next_id)
        next_id += 1
    return events


def check_fifo(trials: int, seed: int = 2) -> None:
    """Units won sum to the count, the cut step fills in queue order, refunds are exact."""
    rng = random.Random(seed)
    for _ in range(trials):
        steps = rng.randint(2, 6)
        events = random_events(rng, steps)
        probe = Book(config=Config(step_count=steps))
        for e in events:
            probe.apply(e)
        cap = rng.randint(1, max(1, probe.total_units()))
        book = Book(config=Config(step_count=steps), cap=cap)
        for e in events:
            book.apply(e)
        c = book.clearing()
        outcomes = book.outcomes()
        assert sum(o["unitsWon"] for o in outcomes) == c.count, (events, cap)
        assert all(o["refund"] >= 0 for o in outcomes)
        if c.count:
            cut = sorted((o for o in outcomes if o["active"] and o["step"] == c.step),
                         key=lambda o: o["position"])
            for a, b in zip(cut, cut[1:]):
                assert not (b["unitsWon"] > 0 and a["unitsWon"] < a["quantity"]), (events, cap)


def check_monotone(trials: int, seed: int = 3) -> None:
    """If a new bid of q units wins at least one unit at step s, it does at every higher step
    too (with and without a cap), so `lowest_winning_step` may be found by binary search."""
    rng = random.Random(seed)
    for _ in range(trials):
        steps = rng.randint(2, 9)
        events = random_events(rng, steps)
        probe = Book(config=Config(step_count=steps))
        for e in events:
            probe.apply(e)
        cap = rng.choice([0, rng.randint(1, probe.total_units() + 3)])
        book = Book(config=Config(step_count=steps,
                                  margin_share=rng.choice([0, 10_000, 25_000, 50_000])), cap=cap)
        for e in events:
            book.apply(e)
        quantity = rng.randint(1, 8)
        wins = [book.quote(s, quantity)["unitsWon"] > 0 for s in range(steps)]
        assert not any(a and not b for a, b in zip(wins, wins[1:])), (events, cap, quantity)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="fail if the vectors are stale")
    mode.add_argument("--write", action="store_true", help="regenerate the vectors")
    mode.add_argument("--ladder", action="store_true", help="print the default ladder")
    parser.add_argument("--root", type=Path, help="repository root (default: found from here)")
    args = parser.parse_args(argv)
    if args.ladder:
        for i, p in enumerate(ladder()):
            print(f"{i:4d}  {eth(p)}")
        return 0
    root = args.root or repo_root()
    out = root / VECTOR_DIR
    stale = []
    for name, data in vectors().items():
        path = out / name
        text = render(data)
        if args.write:
            out.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8", newline="\n")
        elif not path.is_file() or path.read_text(encoding="utf-8") != text:
            stale.append(str(path.relative_to(root)))
    if stale:
        print("stale golden vectors (run python tools/edition_auction_ref.py --write): "
              + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
