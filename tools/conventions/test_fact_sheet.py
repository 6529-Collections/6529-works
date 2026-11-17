"""The fact-sheet builder: DCL-3 as a reader applies it, DCL-8 (renounced powers), DCL-12/13
(display change, by the current owner or not), DCL-22 (recognized custodians), DCL-26 (every read
at one block), DCL-27 (who can change what) and DCL-28 (the states the sheet distinguishes)."""

from __future__ import annotations

import unittest
from typing import Any, Callable

from tools.content.errors import ToolError
from tools.conventions import fact_sheet, schema, testdata
from tools.conventions.fact_sheet import NoFactSheet, build_fact_sheet
from tools.conventions.testdata import DECL_FILE, ZERO, ZERO32, canonical, sha

ENTRY = "0x" + "e1" * 32


def build(change: Callable[[dict], Any] | None = None) -> dict:
    inputs = testdata.example_sheet_inputs()
    if change:
        change(inputs)
    return build_fact_sheet(inputs).sheet


def reads(inputs: dict) -> dict:
    return inputs["reads"]


def _with(change: Callable[[dict], Any]) -> dict:
    inputs = testdata.example_sheet_inputs()
    change(inputs)
    return inputs


def not_open(inputs: dict) -> None:
    wr = reads(inputs)["WorkRecords"]
    for key in ("record", "mediaOf", "workStateHash", "pinnedRenderer", "locators", "preferredLocator"):
        wr.pop(key)
    wr["isOpen"] = False


def open_unfinalized(inputs: dict) -> None:
    rec = reads(inputs)["WorkRecords"]
    rec["record"].update(finalized=False, onChainComplete=False)
    rec["pinnedRenderer"] = ZERO


class ExampleSheetTest(unittest.TestCase):
    def test_reproduces_the_example_sheet(self) -> None:
        """DCL-26 to DCL-28: the example's reads give the example fact sheet exactly, including
        the real SHA-256 of the canonical declarations.json."""
        expected = testdata.example("fact-sheet.json")
        self.assertEqual(expected["storage"]["files"][2]["sha256"],
                         sha(canonical(testdata.example("declarations.json"))))
        self.assertEqual(build(), expected)

    def test_every_sheet_built_here_validates(self) -> None:
        for change in (None, not_open, open_unfinalized):
            with self.subTest(change=change):
                self.assertEqual(schema.validate(build(change), "fact-sheet"), [])

    def test_states_facts_only(self) -> None:
        """O2: no residual-risk list and no guardian column, whatever the role rows carry."""
        def extra(i: dict) -> None:
            for row in i["roles"]:
                row["guardianCancel"] = True
        c = build(extra)
        self.assertNotIn("residualRisks", c)
        for row in c["changeable"]:
            self.assertEqual(set(row) - {"renouncedBy"}, {"what", "who", "delaySeconds", "until"})

    def test_burned_token_has_no_sheet(self) -> None:
        """DCL-28: a burned token has no fact sheet."""
        with self.assertRaises(NoFactSheet):
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

    def test_boolean_reads_must_be_json_booleans(self) -> None:
        """DCL-26: a bool read given as a string or a number is refused; `"false"` must never
        become true (it would mark a work on-chain complete or finalized)."""
        f1 = "0x" + "11" * 32
        setters: dict[str, Callable[[dict, Any], None]] = {
            "isOpen": lambda i, v: reads(i)["WorkRecords"].update(isOpen=v),
            "finalized": lambda i, v: reads(i)["WorkRecords"]["record"].update(finalized=v),
            "onChainComplete": lambda i, v: reads(i)["WorkRecords"]["record"].update(onChainComplete=v),
            "isComplete of a media file": lambda i, v: reads(i)["ContentStore"]["isComplete"].update({f1: v}),
            "isComplete of the license text": lambda i, v: reads(i)["ContentStore"]["isComplete"].update({testdata.LICENSE_TEXT: v}),
            "isComplete of the declarations": lambda i, v: reads(i)["ContentStore"]["isComplete"].update({DECL_FILE: v}),
            "documentVerified": lambda i, v: (reads(i)["StatementLog"].update(
                latestDisputeOutcome=ENTRY, disputeOutcomeOf={"entryHash": ENTRY, "index": 0}),
                i.update(dispute={"documentVerified": v})),
        }  # fmt: skip
        for name, setter in setters.items():
            for bad in ("false", "true", 0, 1) + ((None,) if name != "documentVerified" else ()):
                with self.subTest(read=name, value=bad), self.assertRaises(ToolError):
                    build(lambda i: setter(i, bad))

    def test_record_flags_must_be_present(self) -> None:
        for key in ("finalized", "onChainComplete"):
            with self.subTest(key), self.assertRaises(ToolError):
                build(lambda i: reads(i)["WorkRecords"]["record"].pop(key))

    def test_roles_are_required(self) -> None:
        """DCL-27: the role matrix rows are an input; without them the sheet would claim nothing
        can change, so a missing or malformed `roles` is refused."""
        with self.assertRaises(ToolError):
            build(lambda i: i.pop("roles"))
        with self.assertRaises(ToolError):
            build(lambda i: i.update(roles={"what": "record"}))
        self.assertEqual(build(lambda i: i.update(roles=[]))["changeable"], [])  # given, and empty

    def test_owner_read_must_be_present(self) -> None:
        """DCL-28: ownerOf is null when it reverted (burned); an absent read is not a burn."""
        with self.assertRaises(ToolError) as caught:
            build(lambda i: reads(i)["Stream"].pop("ownerOf"))
        self.assertNotIsInstance(caught.exception, NoFactSheet)

    def test_renounced_mask_must_be_hex(self) -> None:
        for bad in (1, "1", "-0x1", " 0x1", "0x", None):
            with self.subTest(bad=bad), self.assertRaises(ToolError):
                build(lambda i: reads(i).update(IWorkPowers={"renouncedMask": bad}))


class RecordStatesTest(unittest.TestCase):
    def test_record_not_open(self) -> None:
        """DCL-28: record not open; mediaOf reverts so the declarations are unreadable, and the
        license is the approved item's."""
        c = build(not_open)
        self.assertEqual(c["record"], {"status": "not_open"})
        self.assertEqual(c["storage"], {"onChainComplete": False, "files": []})
        self.assertEqual(c["declarations"], {"status": "unreadable"})
        self.assertEqual(c["license"]["spdxId"], "CC0-1.0")
        self.assertEqual(set(c["conservationFloor"].values()), {"unmet"})

    def test_record_open_not_finalized(self) -> None:
        """DCL-28: open and not on-chain complete; DCL-27: the record row stays until finalize
        and the renderer row is the before-finalize path."""
        c = build(open_unfinalized)
        self.assertEqual(c["record"]["status"], "open")
        self.assertFalse(c["record"]["rendererPinned"])
        self.assertFalse(c["storage"]["onChainComplete"])
        rows = {(r["what"], tuple(r["who"])): r for r in c["changeable"]}
        self.assertEqual(rows[("record", ("ARTIST",))]["until"], "finalize")
        self.assertIn(("renderer", ("SUCCESSOR_SETTER",)), rows)
        self.assertNotIn(("renderer", ("ARTIST", "SUCCESSOR_SETTER")), rows)

    def test_complete_only_in_an_added_store(self) -> None:
        """DCL-28: an on-chain complete work with a media file not complete in the content store
        shows both facts: the work on-chain complete, the file not complete in the store."""
        self.assertTrue(all(f["complete"] for f in build()["storage"]["files"]))
        f1 = "0x" + "11" * 32
        c = build(lambda i: reads(i)["ContentStore"]["isComplete"].update({f1: False}))
        self.assertTrue(c["storage"]["onChainComplete"])
        self.assertFalse(c["storage"]["files"][0]["complete"])

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
        """DCL-32 reads on the sheet for a master with an edition, disputed or not."""
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
        disputed = build(lambda i: master(i, True))
        self.assertEqual(disputed["sale"]["edition"], c["sale"]["edition"])
        self.assertEqual(disputed["dispute"]["scope"], "token")

    def test_restrained_artist(self) -> None:
        c = build(lambda i: reads(i)["ArtistRegistry"].update(activeAuthorityOf=ZERO, pendingChange={"kind": "REPLACEMENT"}))
        self.assertTrue(c["artist"]["restrained"])
        self.assertEqual(c["artist"]["pendingChange"], "REPLACEMENT")


class PowersTest(unittest.TestCase):
    def with_view(self, mask: str, **explicit: Any) -> Callable[[dict], None]:
        """`renouncedPowers` only, so the default WorkPowers names and covers apply, unless
        `powers` or `covers` are given explicitly."""
        def apply(i: dict) -> None:
            reads(i)["IWorkPowers"] = {"renouncedMask": mask, **explicit}
        return apply

    def test_default_names_and_covers(self) -> None:
        """DCL-8: ROYALTY_RATE is bit 0 and covers royalty_rate; RELICENSE is bit 1 and covers
        license."""
        self.assertEqual(fact_sheet.POWERS, ("ROYALTY_RATE", "RELICENSE", "RENDERER_REPIN"))
        self.assertEqual(
            fact_sheet.COVERS,
            {"ROYALTY_RATE": ["royalty_rate"], "RELICENSE": ["license"], "RENDERER_REPIN": ["renderer"]},
        )

    def test_relicense_covers_the_license_row(self) -> None:
        """DCL-27 rule 6: with RELICENSE renounced (mask 0x2) the license row of a non-CC0 work
        is marked renounced, and the royalty row stays."""
        def mit(i: dict) -> None:
            reads(i)["WorkRecords"]["licenseOf"]["spdxId"] = "MIT"
            i["floor"] = None
        c = build(lambda i: (mit(i), self.with_view("0x2")(i)))
        self.assertEqual(c["powers"], {"available": True, "renounced": ["RELICENSE"],
                                       "retained": ["ROYALTY_RATE", "RENDERER_REPIN"]})
        rows = {r["what"]: r for r in c["changeable"]}
        self.assertEqual((rows["license"]["until"], rows["license"]["renouncedBy"]), ("renounced", "RELICENSE"))
        self.assertEqual(rows["royalty_rate"]["until"], "permanent")

    def test_explicit_names_are_accepted(self) -> None:
        """The view's names and covers may be given explicitly (forward compatibility); the sheet
        still validates only WorkPowers names."""
        c = build(self.with_view("0x1", powers=["ROYALTY_RATE", "RELICENSE"], covers={}))
        row = next(r for r in c["changeable"] if r["what"] == "royalty_rate")
        self.assertEqual(row["until"], "permanent")
        with self.assertRaises(ToolError):
            build(self.with_view("0x1", powers=["RECORD_EDITS"]))

    def test_absent_view_is_not_reported(self) -> None:
        """DCL-28: `available: false` without IWorkPowers."""
        c = build()
        self.assertEqual(c["powers"], {"available": False})

    def test_mask_gives_renounced_and_retained(self) -> None:
        """DCL-28: each power renounced or retained; DCL-27: a row a renounced power covers is
        marked renounced with the power's name."""
        c = build(self.with_view("0x1"))
        self.assertEqual(c["powers"], {"available": True, "renounced": ["ROYALTY_RATE"],
                                       "retained": ["RELICENSE", "RENDERER_REPIN"]})
        row = next(r for r in c["changeable"] if r["what"] == "royalty_rate")
        self.assertEqual((row["until"], row["renouncedBy"]), ("renounced", "ROYALTY_RATE"))

    def test_mask_beyond_the_names_is_refused(self) -> None:
        with self.assertRaises(ToolError):
            build(self.with_view("0x8"))

    def test_renderer_repin_covers_the_renderer_row(self) -> None:
        """DCL-8: RENDERER_REPIN (bit 2) covers the renderer row of a finalized work."""
        c = build(self.with_view("0x4"))
        self.assertEqual(c["powers"], {"available": True, "renounced": ["RENDERER_REPIN"],
                                       "retained": ["ROYALTY_RATE", "RELICENSE"]})
        rows = {r["what"]: r for r in c["changeable"]}
        if "renderer" in rows and "renouncedBy" in rows["renderer"]:
            self.assertEqual(rows["renderer"]["renouncedBy"], "RENDERER_REPIN")


class DeclarationsTest(unittest.TestCase):
    """DCL-3 as a reader applies it; DCL-28: absent, valid, invalid, ambiguous or unreadable."""

    def test_absent(self) -> None:
        """DCL-33: the published result names a declarations file the work does not list, so
        every fact is unmet."""
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
        """DCL-33: invalid declarations make every floor fact unmet whatever was published."""
        def corrupt(i: dict) -> None:
            reads(i)["ContentStore"]["read"][DECL_FILE] = "0x" + canonical({"v": 1}).hex()
        c = build(corrupt)
        self.assertEqual(c["declarations"], {"status": "invalid", "fileId": DECL_FILE})
        self.assertEqual(set(c["conservationFloor"].values()), {"unmet"})

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

    def test_published_floor_result(self) -> None:
        """DCL-33: the sheet shows the published floor-result.v1 (or a recomputed check) only when
        it names the work's item hash and declarations file; otherwise every fact is unmet."""
        from tools.conventions import floor
        inp = testdata.still_floor_input()
        recomputed = floor.check_floor(inp["package"], inp["policy"], inp["contents"], inp["observed"])
        self.assertEqual(build(lambda i: i.update(floor=recomputed))["conservationFloor"]["storage"], "met")
        self.assertEqual(build()["conservationFloor"]["storage"], "met")
        published = testdata.example("floor-result.json")
        for why, bad in {
            "absent": None,
            "not floor-result.v1": {"storage": "met"},
            "another item": dict(published, itemHash="0x" + "ab" * 32),
            "another declarations file": dict(published, declarationsFileId="0x" + "99" * 32),
            "a refused recomputed check": dict(recomputed, ok=False),
        }.items():  # fmt: skip
            with self.subTest(why):
                result = build_fact_sheet(dict(testdata.example_sheet_inputs(), floor=bad))
                self.assertEqual(set(result.sheet["conservationFloor"].values()), {"unmet"})
                self.assertIn("conservationFloor", result.notes)

    def test_absent_declarations_use_a_matching_published_result(self) -> None:
        """DCL-33: with no declarations file the sheet uses a result naming none, in which a
        still image's generative fact is not_applicable (DCL-5)."""
        def drop(i: dict) -> None:
            reads(i)["WorkRecords"]["mediaOf"].pop()
            i["floor"] = {"v": 1, "itemHash": reads(i)["Stream"]["coreOf"]["itemHash"], "declarationsFileId": None,
                          "facts": {"storage": "unmet", "format": "unmet", "license": "unmet",
                                    "generative": "not_applicable", "display": "unmet"}}  # fmt: skip
        c = build(drop)
        self.assertEqual(c["declarations"], {"status": "absent"})
        self.assertEqual(c["conservationFloor"]["generative"], "not_applicable")

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

    def test_named_custodian_with_no_attestation(self) -> None:
        """DCL-21, DCL-28: NONE, no date, stale."""
        c = build(lambda i: i.update(attestations=[]))
        self.assertEqual(c["custody"], [{"objectId": c["custody"][0]["objectId"], "custodian": testdata.ANVIL_0,
                                         "recognized": True, "status": "NONE", "stale": True}])  # fmt: skip

    def test_custody_of_another_work_is_not_shown(self) -> None:
        """DCL-20: the sheet evaluates custody for its own (chainId, token, tokenId); an attestation
        about another token is discarded, so the named custodian shows NONE."""
        def other_token(i: dict) -> None:
            doc = i["attestations"][0]["document"]
            doc["subject"]["tokenId"] = doc["message"]["tokenId"] = "43"
        result = build_fact_sheet(_with(other_token))
        self.assertEqual([e["status"] for e in result.sheet["custody"]], ["NONE"])
        self.assertIn("another work", result.notes["custody"]["discarded"][0]["reason"])
        other_chain = build_fact_sheet(_with(lambda i: i["attestations"][0]["document"]["subject"].update(chainId=1)))
        self.assertEqual([e["status"] for e in other_chain.sheet["custody"]], ["NONE"])

    def test_custody_recognized_and_stale(self) -> None:
        """DCL-21, DCL-22, DCL-28: recognized or not, fresh or stale."""
        self.assertEqual(build()["custody"][0]["stale"], False)
        later = build(lambda i: reads(i)["at"].update(timestamp=1794700800 + 365 * 86400 + 1))
        self.assertTrue(later["custody"][0]["stale"])


if __name__ == "__main__":
    unittest.main()
