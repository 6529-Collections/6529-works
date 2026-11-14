"""The promise-card builder: DCL-3 as a reader applies it, DCL-8 (intended renunciation states),
DCL-12/13 (display change, by the current owner or not), DCL-22 (recognized custodians), DCL-26
(every read at one block), DCL-27 (who can still change what), DCL-28 (the states the card
distinguishes) and DCL-29 (residual risks)."""

from __future__ import annotations

import copy
import re
import unittest
from typing import Any, Callable

from tools.content.errors import ToolError
from tools.conventions import card as card_module
from tools.conventions import grade, schema, testdata
from tools.conventions.card import NoCard, build_card, residual_risks
from tools.conventions.testdata import DECL_FILE, ZERO, ZERO32, canonical, sha

KNOWN_LIMITATIONS = testdata.ROOT / "docs" / "audit" / "known-limitations.md"
ENTRY = "0x" + "e1" * 32


def build(change: Callable[[dict], Any] | None = None) -> dict:
    inputs = testdata.example_card_inputs()
    if change:
        change(inputs)
    return build_card(inputs).card


def reads(inputs: dict) -> dict:
    return inputs["reads"]


def not_open(inputs: dict) -> None:
    wr = reads(inputs)["WorkRecords"]
    for key in ("record", "mediaOf", "workStateHash", "pinnedRenderer", "locators", "preferredLocator", "RecordOpened"):
        wr.pop(key)
    wr["isOpen"] = False


def open_unfinalized(inputs: dict) -> None:
    rec = reads(inputs)["WorkRecords"]
    rec["record"].update(finalized=False, onChainComplete=False)
    rec["pinnedRenderer"] = ZERO


class ExampleCardTest(unittest.TestCase):
    def test_reproduces_the_example_card(self) -> None:
        """DCL-26 to DCL-29: the example's reads give the example card, except two fields: the
        declarations file's SHA-256 (the example's is a placeholder; here it is the real hash of
        the canonical declarations.json), and LIM-ID-11, which DCL-29 always prints and the
        example omits."""
        expected = testdata.example("promise-card.json")
        expected["storage"]["files"][2]["sha256"] = sha(canonical(testdata.example("declarations.json")))
        expected["residualRisks"] = sorted(expected["residualRisks"] + ["LIM-ID-11"],
                                           key=card_module._risk_key)
        self.assertEqual(build(), expected)

    def test_example_card_omits_lim_id_11(self) -> None:
        """DCL-29 defect pin: the committed example lacks LIM-ID-11; fix the example, then this."""
        self.assertNotIn("LIM-ID-11", testdata.example("promise-card.json")["residualRisks"])

    def test_every_card_built_here_validates(self) -> None:
        for change in (None, not_open, open_unfinalized):
            with self.subTest(change=change):
                self.assertEqual(schema.validate(build(change), "promise-card"), [])

    def test_burned_token_has_no_card(self) -> None:
        """DCL-28: a burned token has no card."""
        with self.assertRaises(NoCard):
            build(lambda i: reads(i)["Stream"].update(ownerOf=None))

    def test_missing_read_is_an_error_not_a_default(self) -> None:
        """DCL-26: every read is made; a missing one is refused, never defaulted."""
        for path in (["Stream", "primarySale"], ["StatementLog", "chainOf"], ["ArtistRegistry", "pendingChange"],
                     ["WorkRecords", "licenseOf"], ["WorkMinted"]):  # fmt: skip
            def drop(i: dict, path: list = path) -> None:
                node = reads(i)
                for key in path[:-1]:
                    node = node[key]
                del node[path[-1]]
            with self.subTest(path=path), self.assertRaises(ToolError):
                build(drop)


class RecordStatesTest(unittest.TestCase):
    def test_record_not_open(self) -> None:
        """DCL-28: record not open; mediaOf reverts so the declarations are unreadable."""
        c = build(not_open)
        self.assertEqual(c["record"], {"status": "not_open"})
        self.assertEqual(c["storage"], {"onChainComplete": False, "files": []})
        self.assertEqual(c["declarations"], {"status": "unreadable"})
        self.assertEqual(set(c["conservationFloor"].values()), {"unmet"})
        self.assertIn("LIM-CNT-1", c["residualRisks"])
        self.assertEqual(grade.grade(c)["letter"], "D")

    def test_record_open_not_finalized(self) -> None:
        """DCL-28: open and not on-chain complete; DCL-29: LIM-CNT-1, no LIM-CNT-10; DCL-27: the
        record row stays until finalize and the renderer row is the before-finalize path."""
        c = build(open_unfinalized)
        self.assertEqual(c["record"]["status"], "open")
        self.assertFalse(c["record"]["rendererPinned"])
        self.assertIn("LIM-CNT-1", c["residualRisks"])
        self.assertNotIn("LIM-CNT-10", c["residualRisks"])
        rows = {(r["what"], tuple(r["who"])): r for r in c["changeable"]}
        self.assertEqual(rows[("record", ("ARTIST",))]["until"], "finalize")
        self.assertIn(("renderer", ("SUCCESSOR_SETTER",)), rows)
        self.assertNotIn(("renderer", ("ARTIST", "SUCCESSOR_SETTER")), rows)

    def test_finalized_drops_record_license_and_burn_rows(self) -> None:
        """DCL-27: record until finalize; license never for CC0 (WS-12); burn until settlement."""
        whats = [r["what"] for r in build()["changeable"]]
        for gone in ("record", "license", "burn_and_release"):
            self.assertNotIn(gone, whats)

    def test_license_row_kept_for_a_non_cc0_license(self) -> None:
        def mit(i: dict) -> None:
            reads(i)["WorkRecords"]["licenseOf"]["spdxId"] = "MIT"
            i["floor"] = None
        c = build(mit)
        self.assertFalse(c["license"]["cc0"])
        self.assertIn("license", [r["what"] for r in c["changeable"]])

    def test_burn_row_kept_before_settlement(self) -> None:
        c = build(lambda i: reads(i)["Stream"]["primarySale"].update(outcome="NONE", currency=ZERO, price="0"))
        row = next(r for r in c["changeable"] if r["what"] == "burn_and_release")
        self.assertEqual(row["until"], "settlement")


class SaleAndDisputeTest(unittest.TestCase):
    def test_every_sale_outcome(self) -> None:
        """DCL-28: NONE, SOLD, UNBID, FROZEN_OUT or RESCUED; only SOLD carries currency and price."""
        for outcome in ("NONE", "SOLD", "UNBID", "FROZEN_OUT", "RESCUED"):
            with self.subTest(outcome):
                c = build(lambda i, o=outcome: reads(i)["Stream"]["primarySale"].update(outcome=o))
                self.assertEqual(c["sale"]["outcome"], outcome)
                self.assertEqual("price" in c["sale"], outcome == "SOLD")

    def test_dispute_scopes(self) -> None:
        """DCL-28: disputed by an outcome about the token, or only about its item."""
        def disputed(own: str) -> Callable[[dict], None]:
            def apply(i: dict) -> None:
                reads(i)["StatementLog"].update(latestDisputeOutcome=ENTRY,
                                                disputeOutcomeOf={"entryHash": own, "index": 3})
                i["dispute"] = {"documentVerified": True}
            return apply
        token = build(disputed(ENTRY))["dispute"]
        self.assertEqual(token, {"entryHash": ENTRY, "scope": "token", "documentVerified": True})
        item = build(disputed(ZERO32))["dispute"]
        self.assertEqual(item["scope"], "item")
        self.assertEqual(build()["dispute"], {"entryHash": None, "scope": None})

    def test_edition_master(self) -> None:
        """DCL-32 reads on the card, and DCL-29 LIM-EA-14 for a master whose edition sale ran
        beside a disputed 1/1."""
        editions = "0x" + "ed" * 20

        def master(i: dict, disputed: bool) -> None:
            r = reads(i)
            r["Stream"]["coreOf"]["kind"] = "EDITION_MASTER"
            r["Stream"]["editionOf"] = {"editionsContract": editions, "editionId": "42"}
            r["UniformEditionAuction"] = {"clearing": {"count": "25", "price": "100000000000000000"}}
            if disputed:
                r["StatementLog"].update(latestDisputeOutcome=ENTRY, disputeOutcomeOf={"entryHash": ENTRY, "index": 0})
        c = build(lambda i: master(i, False))
        self.assertEqual(c["sale"]["edition"], {"editionId": "42", "copies": "25", "pricePerCopy": "100000000000000000"})
        self.assertNotIn("LIM-EA-14", c["residualRisks"])
        self.assertIn("LIM-EA-14", build(lambda i: master(i, True))["residualRisks"])

    def test_restrained_artist(self) -> None:
        c = build(lambda i: reads(i)["ArtistRegistry"].update(activeAuthorityOf=ZERO, pendingChange={"kind": "CONTESTED"}))
        self.assertTrue(c["artist"]["restrained"])
        self.assertEqual(c["artist"]["pendingChange"], "CONTESTED")


class PowersTest(unittest.TestCase):
    POWERS = ["RECORD_EDITS", "RELICENSE", "ROYALTY_RATE"]

    def with_view(self, mask: str, covers: dict | None = None, now: int | None = None) -> Callable[[dict], None]:
        def apply(i: dict) -> None:
            reads(i)["IWorkPowers"] = {"renouncedMask": mask, "powers": self.POWERS,
                                       "covers": covers or {}}
            if now is not None:
                reads(i)["at"]["timestamp"] = now
        return apply

    def test_absent_view_is_not_reported(self) -> None:
        """DCL-28: `available: false` without IWorkPowers; DCL-8: intended renunciations `unknown`."""
        c = build()
        self.assertEqual(c["powers"], {"available": False})
        self.assertEqual(c["declarations"]["intendedRenunciations"][0]["state"], "unknown")

    def test_mask_gives_renounced_and_retained(self) -> None:
        """DCL-28: each power renounced or retained; DCL-27: a row a renounced power covers is
        marked renounced with the power's name."""
        c = build(self.with_view("0x5", {"ROYALTY_RATE": ["royalty_rate"]}))
        self.assertEqual(c["powers"], {"available": True, "renounced": ["RECORD_EDITS", "ROYALTY_RATE"],
                                       "retained": ["RELICENSE"]})
        row = next(r for r in c["changeable"] if r["what"] == "royalty_rate")
        self.assertEqual((row["until"], row["renouncedBy"]), ("renounced", "ROYALTY_RATE"))
        self.assertEqual(c["declarations"]["intendedRenunciations"][0]["state"], "renounced")

    def test_intended_renunciation_pending_and_overdue(self) -> None:
        """DCL-8: due at RecordOpened plus the days; pending before (and at) the due time,
        overdue after it, while the view reports the power retained."""
        due = 1794182400
        self.assertEqual(build(self.with_view("0x0", now=due))["declarations"]["intendedRenunciations"][0],
                         {"power": "RECORD_EDITS", "dueAt": due, "state": "pending"})
        late = build(self.with_view("0x0", now=due + 1))
        self.assertEqual(late["declarations"]["intendedRenunciations"][0]["state"], "overdue")
        self.assertIn({"row": "CAP3", "points": 0}, grade.grade(late)["reasons"])

    def test_mask_beyond_the_names_is_refused(self) -> None:
        with self.assertRaises(ToolError):
            build(self.with_view("0x8"))


class DeclarationsTest(unittest.TestCase):
    """DCL-3 as a reader applies it; DCL-28: absent, valid, invalid, ambiguous or unreadable."""

    def test_absent(self) -> None:
        def drop(i: dict) -> None:
            reads(i)["WorkRecords"]["mediaOf"].pop()
        c = build(drop)
        self.assertEqual(c["declarations"], {"status": "absent"})
        self.assertEqual(set(c["conservationFloor"].values()), {"unmet"})
        self.assertEqual([e["recognized"] for e in c["custody"]], [False])

    def test_ambiguous(self) -> None:
        def twice(i: dict) -> None:
            r = reads(i)
            other = "0x" + "99" * 32
            r["WorkRecords"]["mediaOf"].append({"fileId": other, "sha256Hash": ZERO32, "role": "AUXILIARY"})
            r["ContentStore"]["fileInfo"][other] = r["ContentStore"]["fileInfo"][DECL_FILE]
            r["ContentStore"]["isComplete"][other] = True
            r["WorkRecords"]["locators"][other] = []
            r["WorkRecords"]["preferredLocator"][other] = {"kind": "ONCHAIN", "uri": ""}
        self.assertEqual(build(twice)["declarations"], {"status": "ambiguous"})

    def test_invalid_on_chain_bytes(self) -> None:
        def corrupt(i: dict) -> None:
            reads(i)["ContentStore"]["read"][DECL_FILE] = "0x" + canonical({"v": 1}).hex()
        c = build(corrupt)
        self.assertEqual(c["declarations"], {"status": "invalid", "fileId": DECL_FILE})
        self.assertEqual(set(c["conservationFloor"].values()), {"unmet"})
        self.assertIn({"row": "CAP4", "points": 0}, grade.grade(c)["reasons"])

    def test_unreadable_without_a_copy_and_valid_with_one(self) -> None:
        def incomplete(i: dict) -> None:
            reads(i)["ContentStore"]["isComplete"][DECL_FILE] = False
            reads(i)["ContentStore"]["read"].pop(DECL_FILE)
        self.assertEqual(build(incomplete)["declarations"]["status"], "unreadable")
        good = canonical(testdata.example("declarations.json"))

        def with_copy(data: bytes) -> Callable[[dict], None]:
            return lambda i: (incomplete(i), i.update(declarationsCopies={DECL_FILE: "0x" + data.hex()}))
        self.assertEqual(build(with_copy(good))["declarations"]["status"], "valid")
        self.assertEqual(build(with_copy(b"{}"))["declarations"]["status"], "unreadable")

    def test_published_floor_shapes(self) -> None:
        """DCL-5/DCL-28: the floor comes from the published check; absent means unmet; a
        malformed one is refused."""
        from tools.conventions import floor
        inp = testdata.still_floor_input()
        published = floor.check_floor(inp["package"], inp["policy"], inp["contents"], inp["observed"])
        self.assertEqual(build(lambda i: i.update(floor=published))["conservationFloor"]["storage"], "met")
        self.assertEqual(set(build(lambda i: i.pop("floor"))["conservationFloor"].values()), {"unmet"})
        with self.assertRaises(ToolError):
            build(lambda i: i.update(floor={"storage": "met"}))

    def test_living_work_and_time_capsule_flags(self) -> None:
        c = build()
        self.assertEqual((c["declarations"]["timeCapsule"], c["declarations"]["livingWork"]), (False, False))


class DisplayAndCustodyTest(unittest.TestCase):
    def test_display_change(self) -> None:
        """DCL-12, DCL-13: accepted, by the current owner or not."""
        change = {"proposal": ENTRY, "acceptance": "0x" + "e2" * 32, "contentSha256": "0x" + "c0" * 32}
        by_owner = build(lambda i: i.update(displayChange=dict(change, acceptedBy=testdata.ANVIL_1)))
        self.assertTrue(by_owner["displayChange"]["acceptedByCurrentOwner"])
        by_other = build(lambda i: i.update(displayChange=dict(change, acceptedBy=testdata.ANVIL_0)))
        self.assertEqual(by_other["displayChange"]["state"], "accepted")
        self.assertFalse(by_other["displayChange"]["acceptedByCurrentOwner"])

    def test_custody_recognized_and_stale(self) -> None:
        """DCL-21, DCL-22, DCL-28: recognized or not, fresh or stale."""
        self.assertEqual(build()["custody"][0]["stale"], False)
        later = build(lambda i: reads(i)["at"].update(timestamp=1794700800 + 365 * 86400 + 1))
        self.assertTrue(later["custody"][0]["stale"])


class ResidualRiskTest(unittest.TestCase):
    def test_conditions(self) -> None:
        """DCL-29: the always list, LIM-CNT-1, LIM-CNT-10 and LIM-EA-14 on their conditions."""
        base = residual_risks(on_chain_complete=True, finalized=False, ea14=False)
        self.assertEqual(set(base), set(card_module.ALWAYS_RISKS))
        self.assertIn("LIM-CNT-1", residual_risks(on_chain_complete=False, finalized=False, ea14=False))
        self.assertIn("LIM-CNT-10", residual_risks(on_chain_complete=True, finalized=True, ea14=False))
        self.assertIn("LIM-EA-14", residual_risks(on_chain_complete=True, finalized=False, ea14=True))

    def test_every_printed_id_is_in_known_limitations(self) -> None:
        """DCL-29: each ID links to known limitations, which owns the text."""
        text = KNOWN_LIMITATIONS.read_text(encoding="utf-8")
        for risk in residual_risks(on_chain_complete=False, finalized=True, ea14=True):
            with self.subTest(risk):
                self.assertRegex(text, rf"{re.escape(risk)}(?![0-9])")


if __name__ == "__main__":
    unittest.main()
