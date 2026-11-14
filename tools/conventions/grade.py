"""The promise grade, rubric 1 (DCL-30, DCL-31): a pure function of one promise card.

`grade(card)` is total over every card that validates against promise-card.v1 and returns a
promise-grade.v1 document. Rubric 1 never changes (DCL-31); a new rubric is a new function and
a new `RUBRIC` value, never an edit to `grade_rubric_1`.
"""

from __future__ import annotations

import hashlib
from typing import Any, Mapping

from tools.content.errors import ToolError

from . import jcs
from .schema import validate

RUBRIC = 1
LETTER_FLOORS = (("A", 85), ("B", 70), ("C", 50))
_ORDER = "ABCD"


def card_hash(card: Mapping[str, Any]) -> str:
    """SHA-256 of the card's RFC 8785 canonical JSON (`promise-grade.v1` `card`)."""
    return "0x" + hashlib.sha256(jcs.canonicalize(card)).hexdigest()


def _cap(letter: str, ceiling: str) -> str:
    return letter if _ORDER.index(letter) >= _ORDER.index(ceiling) else ceiling


def grade_rubric_1(card: Mapping[str, Any]) -> dict:
    rows: list[tuple[str, int]] = []
    status = card["record"]["status"]
    rows.append(("R1", 20 if status == "finalized" else 5 if status == "open" else 0))
    rows.append(("R2", 25 if card["storage"]["onChainComplete"] else 0))
    rows.append(("R3", 5 if card["license"]["textOnChain"] else 0))
    rows.append(("R4", 10 if card["declarations"]["status"] == "valid" else 0))
    applicable = [s for s in card["conservationFloor"].values() if s != "not_applicable"]
    if all(s == "met" for s in applicable):
        r5 = 15  # only generative may be not_applicable (promise-card.v1), so four facts count
    elif all(s in ("met", "waived") for s in applicable) and "waived" in applicable:
        r5 = 8
    else:
        r5 = 0
    rows.append(("R5", r5))
    primary = [f for f in card["storage"]["files"] if f["role"] == "PRIMARY"]
    locators = primary[0]["locators"] if primary else 0
    rows.append(("R6", 10 if locators >= 2 else 5 if locators == 1 else 0))
    powers = card["powers"]
    r7 = 0
    if powers["available"]:
        renounced, retained = len(powers["renounced"]), len(powers["retained"])
        if renounced + retained:
            r7 = 10 * renounced // (renounced + retained)
    rows.append(("R7", r7))
    overdue = any(r["state"] == "overdue" for r in card["declarations"].get("intendedRenunciations", []))
    rows.append(("R8", 0 if overdue else 5))
    score = sum(p for _, p in rows)
    by_points = next((name for name, floor in LETTER_FLOORS if score >= floor), "D")
    letter = by_points
    caps: list[tuple[str, str]] = []
    if card["dispute"]["entryHash"] is not None:
        caps.append(("CAP1", "C"))
    if status == "not_open":
        caps.append(("CAP2", "D"))
    if overdue:
        caps.append(("CAP3", "C"))
    if card["declarations"]["status"] in ("invalid", "ambiguous", "unreadable"):
        caps.append(("CAP4", "C"))
    for _, ceiling in caps:
        letter = _cap(letter, ceiling)
    reasons = [{"row": r, "points": p} for r, p in rows if p > 0]
    # DCL-30: a cap is listed, with 0 points, only when its ceiling is below the points' letter.
    reasons += [{"row": c, "points": 0} for c, ceiling in caps if _cap(by_points, ceiling) != by_points]
    return {"v": 1, "rubric": RUBRIC, "card": card_hash(card), "score": score, "letter": letter,
            "reasons": reasons}  # fmt: skip


def grade(card: Mapping[str, Any], rubric: int = RUBRIC) -> dict:
    """Validate the card, grade it under `rubric`, and validate the grade."""
    if rubric != RUBRIC:
        raise ToolError(f"rubric {rubric} is not defined; this tool implements rubric {RUBRIC}")
    errors = validate(card, "promise-card")
    if errors:
        raise ToolError("not a valid promise-card.v1 document: " + "; ".join(errors[:5]))
    result = grade_rubric_1(card)
    errors = validate(result, "promise-grade")
    if errors:  # pragma: no cover - the rubric's own output is always valid
        raise ToolError("internal error: the grade is not promise-grade.v1: " + "; ".join(errors))
    return result
