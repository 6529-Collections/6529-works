"""The promise grade under rubric 1: DCL-30 (rows R1 to R8, letters and caps CAP1 to CAP4, a pure
function of the card) and DCL-31 (rubrics are versioned)."""

from __future__ import annotations

import copy
import itertools
import random
import unittest
from typing import Any, Callable

from tools.content.errors import ToolError
from tools.conventions import grade, schema, testdata
from tools.conventions.grade import card_hash, grade_rubric_1

ENTRY = "0x" + "e1" * 32


def card(change: Callable[[dict], Any] | None = None) -> dict:
    c = testdata.example("promise-card.json")
    if change:
        change(c)
    return c


def points(result: dict) -> dict[str, int]:
    return {r["row"]: r["points"] for r in result["reasons"]}


class ExampleTest(unittest.TestCase):
    def test_example_grade_is_reproduced_exactly(self) -> None:
        """DCL-30: the example card grades 90, A, with the example's reasons and card hash."""
        self.assertEqual(grade.grade(card()), testdata.example("promise-grade.json"))

    def test_card_hash_is_sha256_of_canonical_json(self) -> None:
        self.assertEqual(card_hash(card()), testdata.example("promise-grade.json")["card"])

    def test_pure(self) -> None:
        """DCL-30: the same card always gives the same grade, and the card is not modified."""
        c = card()
        before = copy.deepcopy(c)
        self.assertEqual(grade.grade(c), grade.grade(copy.deepcopy(c)))
        self.assertEqual(c, before)


class RowTest(unittest.TestCase):
    def test_rows(self) -> None:
        """DCL-30 R1 to R8, each condition and its alternative score."""
        def floor(**states: str) -> Callable[[dict], None]:
            return lambda c: c["conservationFloor"].update(states)

        def powers(renounced: int, retained: int) -> Callable[[dict], None]:
            names = [f"P{i}" for i in range(renounced + retained)]
            return lambda c: c.update(powers={"available": True, "renounced": names[:renounced],
                                              "retained": names[renounced:]})
        cases = [
            ("R1", lambda c: None, 20),
            ("R1", lambda c: c["record"].update(status="open"), 5),
            ("R1", lambda c: c.update(record={"status": "not_open"}), 0),
            ("R2", lambda c: c["storage"].update(onChainComplete=False), 0),
            ("R3", lambda c: c["license"].update(textOnChain=False), 0),
            ("R4", lambda c: c["declarations"].update(status="absent"), 0),
            ("R5", floor(display="waived"), 8),
            ("R5", floor(display="unmet"), 0),
            ("R5", floor(storage="waived", display="unmet"), 0),
            ("R5", floor(generative="met"), 15),
            ("R5", floor(storage="not_applicable", format="not_applicable", license="not_applicable",
                         display="not_applicable"), 15),
            ("R6", lambda c: c["storage"]["files"][0].update(locators=1), 5),
            ("R6", lambda c: c["storage"]["files"][0].update(locators=0), 0),
            ("R6", lambda c: c["storage"].update(files=[]), 0),
            ("R7", powers(1, 2), 3),
            ("R7", powers(2, 1), 6),
            ("R7", powers(3, 0), 10),
            ("R7", powers(0, 0), 0),
            ("R7", powers(0, 4), 0),
            ("R8", lambda c: c["declarations"]["intendedRenunciations"][0].update(state="overdue"), 0),
            ("R8", lambda c: c["declarations"].pop("intendedRenunciations"), 5),
        ]  # fmt: skip
        for row, change, expected in cases:
            with self.subTest(row=row, expected=expected):
                result = grade.grade(card(change))
                self.assertEqual(points(result).get(row, 0), expected)
                self.assertEqual(result["score"], sum(r["points"] for r in result["reasons"]))

    def test_rows_with_zero_points_are_not_listed(self) -> None:
        """DCL-30: `reasons` lists each row that scored; R7 scored nothing on the example."""
        self.assertNotIn("R7", points(grade.grade(card())))


class LetterTest(unittest.TestCase):
    def letter_for(self, score_change: Callable[[dict], None]) -> tuple[int, str]:
        result = grade.grade(card(score_change))
        return result["score"], result["letter"]

    def test_letter_thresholds(self) -> None:
        """DCL-30: A from 85, B from 70, C from 50, D below."""
        self.assertEqual(self.letter_for(lambda c: c["storage"]["files"][0].update(locators=1)), (85, "A"))
        self.assertEqual(self.letter_for(lambda c: c["conservationFloor"].update(display="unmet")), (75, "B"))
        self.assertEqual(self.letter_for(lambda c: c["storage"].update(onChainComplete=False)), (65, "C"))
        self.assertEqual(self.letter_for(lambda c: (c["storage"].update(onChainComplete=False),
                                                    c["license"].update(textOnChain=False),
                                                    c["declarations"].update(status="absent"))), (50, "C"))
        self.assertEqual(self.letter_for(lambda c: (c["storage"].update(onChainComplete=False),
                                                    c["license"].update(textOnChain=False),
                                                    c["declarations"].update(status="absent"),
                                                    c["record"].update(status="open"))), (35, "D"))

    def test_caps(self) -> None:
        """DCL-30 CAP1 to CAP4: the letter is capped and the cap is listed after the rows."""
        cases = [
            ("CAP1", lambda c: c["dispute"].update(entryHash=ENTRY, scope="token"), "C"),
            ("CAP2", lambda c: c.update(record={"status": "not_open"}), "D"),
            ("CAP3", lambda c: c["declarations"]["intendedRenunciations"][0].update(state="overdue"), "C"),
            ("CAP4", lambda c: c["declarations"].update(status="invalid"), "C"),
            ("CAP4", lambda c: c["declarations"].update(status="ambiguous"), "C"),
            ("CAP4", lambda c: c["declarations"].update(status="unreadable"), "C"),
        ]
        for cap, change, ceiling in cases:
            with self.subTest(cap=cap):
                result = grade.grade(card(change))
                self.assertEqual(result["letter"], ceiling)
                self.assertEqual(result["reasons"][-1], {"row": cap, "points": 0})

    def test_caps_do_not_raise_a_letter(self) -> None:
        def low_and_disputed(c: dict) -> None:
            c.update(record={"status": "not_open"})
            c["storage"].update(onChainComplete=False)
            c["dispute"].update(entryHash=ENTRY, scope="item")
        result = grade.grade(card(low_and_disputed))
        self.assertEqual(result["letter"], "D")
        self.assertEqual([r["row"] for r in result["reasons"]][-2:], ["CAP1", "CAP2"])


class TotalityTest(unittest.TestCase):
    def test_total_over_valid_cards(self) -> None:
        """DCL-30: grading is total; every valid card gives a valid promise-grade.v1 document."""
        rng = random.Random(6529)
        floor_states = ("met", "waived", "unmet", "not_applicable")
        statuses = ("not_open", "open", "finalized")
        decl = ("absent", "valid", "invalid", "ambiguous", "unreadable")
        count = 0
        for status, chain, text, d_status in itertools.product(statuses, (True, False), (True, False), decl):
            for _ in range(6):
                c = card()
                c["record"] = {"status": "not_open"} if status == "not_open" else dict(c["record"], status=status)
                c["storage"]["onChainComplete"] = chain
                c["license"]["textOnChain"] = text
                c["declarations"] = {"status": d_status, "intendedRenunciations": [
                    {"power": "P", "dueAt": 1, "state": rng.choice(("renounced", "pending", "overdue", "unknown"))}
                    for _ in range(rng.randint(0, 2))]}  # fmt: skip
                c["conservationFloor"] = {k: rng.choice(floor_states) for k in c["conservationFloor"]}
                c["storage"]["files"][0]["locators"] = rng.randint(0, 16)
                if rng.random() < 0.3:
                    c["storage"]["files"] = []
                n = rng.randint(0, 5)
                k = rng.randint(0, n)
                c["powers"] = rng.choice(({"available": False}, {"available": True, "renounced": [f"P{i}" for i in range(k)],
                                                                 "retained": [f"Q{i}" for i in range(n - k)]}))  # fmt: skip
                c["dispute"] = rng.choice(({"entryHash": None, "scope": None}, {"entryHash": ENTRY, "scope": "item"}))
                self.assertEqual(schema.validate(c, "promise-card"), [], c)
                result = grade.grade(c)
                self.assertEqual(schema.validate(result, "promise-grade"), [])
                self.assertEqual(result["score"], sum(r["points"] for r in result["reasons"]))
                count += 1
        self.assertGreater(count, 300)

    def test_invalid_card_and_unknown_rubric_are_refused(self) -> None:
        """DCL-31: a client never grades under a rubric it does not implement."""
        with self.assertRaises(ToolError):
            grade.grade(card(), rubric=2)
        with self.assertRaises(ToolError):
            grade.grade(card(lambda c: c.pop("residualRisks")))
        self.assertEqual(grade_rubric_1(card())["rubric"], 1)


if __name__ == "__main__":
    unittest.main()
