"""The structural validator against every committed schema and example (DCL-1: a document follows
the schema whose `$id` its statement names; DCL-2 step 4 discards one that does not)."""

from __future__ import annotations

import copy
import unittest
from typing import Any, Callable

from tools.conventions import schema, testdata
from tools.conventions.schema import SchemaError, Validator


def mutate(doc: Any, change: Callable[[Any], None]) -> Any:
    out = copy.deepcopy(doc)
    change(out)
    return out


def setp(path: list, value: Any) -> Callable[[Any], None]:
    def apply(doc: Any) -> None:
        node = doc
        for key in path[:-1]:
            node = node[key]
        node[path[-1]] = value
    return apply


def delp(path: list) -> Callable[[Any], None]:
    def apply(doc: Any) -> None:
        node = doc
        for key in path[:-1]:
            node = node[key]
        del node[path[-1]]
    return apply


# (example file, description, change): each must make the document invalid.
MALFORMED = [
    ("declarations.json", "v is not 1", setp(["v"], 2)),
    ("declarations.json", "v is true, not 1", setp(["v"], True)),
    ("declarations.json", "contentHash missing", delp(["contentHash"])),
    ("declarations.json", "contentHash uppercase", setp(["contentHash"], "0x" + "AB" * 32)),
    ("declarations.json", "contentHash with a trailing newline", setp(["contentHash"], "0x" + "ab" * 32 + "\n")),
    ("declarations.json", "unknown top-level member", setp(["extra"], 1)),
    ("declarations.json", "conservation without display", delp(["conservation", "display"])),
    ("declarations.json", "waived storage without reason", setp(["conservation", "storage"], {"waived": True})),
    ("declarations.json", "waived with an empty reason", setp(["conservation", "display"], {"waived": True, "reason": ""})),
    ("declarations.json", "unwaived storage without files", setp(["conservation", "storage"], {"waived": False})),
    ("declarations.json", "storage fact with an unknown member", setp(["conservation", "storage", "note"], "x")),
    ("declarations.json", "receipt with an https URI", setp(["conservation", "storage", "files", 0, "receipts", 0, "uri"], "https://example.com/x")),
    ("declarations.json", "receipt network unknown", setp(["conservation", "storage", "files", 0, "receipts", 0, "network"], "filecoin")),
    ("declarations.json", "receipt URI with nonzero padding bits", setp(["conservation", "storage", "files", 0, "receipts", 0, "uri"], "ar://oPSkhDkQRE6xQF7RQgVgRkmoJKW7XueRtNdpwXEEnRd")),
    ("declarations.json", "format MIME with parameters", setp(["conservation", "format", "files", 0, "mimeType"], "image/png; q=1")),
    ("declarations.json", "width zero", setp(["conservation", "format", "files", 0, "width"], 0)),
    ("declarations.json", "width fractional", setp(["conservation", "format", "files", 0, "width"], 1.5)),
    ("declarations.json", "license without textSha256", delp(["conservation", "license", "textSha256"])),
    ("declarations.json", "custodian age above 3650", setp(["custodians", 0, "maxAttestationAgeDays"], 3651)),
    ("declarations.json", "custodian missing objectId", delp(["custodians", 0, "objectId"])),
    ("declarations.json", "empty custodians array", setp(["custodians"], [])),
    ("declarations.json", "citation tokenId as a number", setp(["citations", 0, "work", "tokenId"], 7)),
    ("declarations.json", "citation relation unknown", setp(["citations", 0, "relation"], "likes")),
    ("declarations.json", "power name lowercase", setp(["intendedRenunciations", 0, "power"], "record_edits")),
    ("declarations.json", "renunciation days negative", setp(["intendedRenunciations", 0, "withinDaysOfRecordOpen"], -1)),
    ("declarations-generative.json", "generative without runtime", delp(["conservation", "generative", "runtime"])),
    ("declarations-generative.json", "seed policy unknown", setp(["conservation", "generative", "seedPolicy"], "BLOCKHASH")),
    ("declarations-generative.json", "dependency name with uppercase", setp(["conservation", "generative", "dependencies"], [{"name": "P5", "version": "1", "fileId": "0x" + "00" * 32}])),
    ("declarations-generative.json", "living-work drivers repeated", setp(["livingWork", "drivers"], ["time", "time"])),
    ("declarations-generative.json", "living-work refresh zero", setp(["livingWork", "suggestedRefreshSeconds"], 0)),
    ("declarations-time-capsule.json", "time capsule policy status changed", setp(["timeCapsule", "policyStatus"], "approved")),
    ("declarations-time-capsule.json", "time capsule hash algorithm 4", setp(["timeCapsule", "plaintextCommitment", "algorithm"], 4)),
    ("promise-card.json", "card without residualRisks", delp(["residualRisks"])),
    ("promise-card.json", "record status unknown", setp(["record", "status"], "closed")),
    ("promise-card.json", "open record without stateHash", lambda d: (d["record"].update(status="open"), d["record"].pop("stateHash"))),
    ("promise-card.json", "SOLD without price", delp(["sale", "price"])),
    ("promise-card.json", "sale outcome unknown", setp(["sale", "outcome"], "BURNED")),
    ("promise-card.json", "dispute entryHash zero-length string", setp(["dispute", "entryHash"], "")),
    ("promise-card.json", "dispute scope unknown", setp(["dispute", "scope"], "artist")),
    ("promise-card.json", "powers available without lists", setp(["powers", "available"], True)),
    ("promise-card.json", "floor state unknown", setp(["conservationFloor", "storage"], "partial")),
    ("promise-card.json", "floor fact missing", delp(["conservationFloor", "generative"])),
    ("promise-card.json", "accepted display change without acceptedBy", setp(["displayChange"], {"state": "accepted"})),
    ("promise-card.json", "custody status number", setp(["custody", 0, "status"], 1)),
    ("promise-card.json", "changeable what unknown", setp(["changeable", 0, "what"], "price")),
    ("promise-card.json", "changeable who empty", setp(["changeable", 0, "who"], [])),
    ("promise-card.json", "residual risk not a LIM ID", setp(["residualRisks", 0], "RISK-1")),
    ("promise-card.json", "residual risks repeated", setp(["residualRisks", 1], "LIM-CNT-2")),
    ("promise-card.json", "locators above 16", setp(["storage", "files", 0, "locators"], 17)),
    ("promise-card.json", "file role unknown", setp(["storage", "files", 0, "role"], "SOURCE")),
    ("promise-card.json", "chainId zero", setp(["at", "chainId"], 0)),
    ("promise-grade.json", "rubric 2", setp(["rubric"], 2)),
    ("promise-grade.json", "score above 100", setp(["score"], 101)),
    ("promise-grade.json", "letter F", setp(["letter"], "F")),
    ("promise-grade.json", "reason row name", setp(["reasons", 0, "row"], "ROW1")),
    ("promise-grade.json", "card not a hash", setp(["card"], "0x1234")),
    ("control-proof.json", "message without signer", delp(["message", "signer"])),
    ("control-proof.json", "empty venue", setp(["message", "venue"], "")),
    ("control-proof.json", "nonce of 31 bytes", setp(["message", "nonce"], "0x" + "11" * 31)),
    ("control-proof.json", "tokenId with a leading zero", setp(["message", "tokenId"], "042")),
    ("control-proof.json", "signature of 63 bytes", setp(["signature"], "0x" + "11" * 63)),
    ("control-proof.json", "signature uppercase", setp(["signature"], "0x" + "AB" * 65)),
    ("control-proof.json", "issuedAt negative", setp(["message", "issuedAt"], -1)),
    ("custody-attestation.json", "no signature", delp(["signature"])),
    ("custody-attestation.json", "status 5", setp(["message", "status"], 5)),
    ("custody-attestation.json", "HELD with a successor", setp(["message", "successor"], testdata.ANVIL_1)),
    ("custody-attestation.json", "subject tokenId number", setp(["subject", "tokenId"], 42)),
    ("custody-attestation.json", "evidence not a content address", setp(["evidence", 0], "https://x")),
    ("custody-attestation.json", "unknown member", setp(["poster"], testdata.ANVIL_1)),
]  # fmt: skip


class ExamplesTest(unittest.TestCase):
    def test_every_example_is_valid(self) -> None:
        """DCL-1: every committed example validates against its schema."""
        files = sorted(p.name for p in testdata.EXAMPLES.glob("*.json"))
        self.assertEqual(files, sorted(testdata.EXAMPLE_SCHEMAS), "an example has no schema mapping")
        for name, schema_name in testdata.EXAMPLE_SCHEMAS.items():
            with self.subTest(example=name):
                self.assertEqual(schema.validate(testdata.example(name), schema_name), [])

    def test_every_schema_loads_and_uses_only_supported_keywords(self) -> None:
        validator = schema.default_validator()
        self.assertEqual(len(validator.ids), 11)
        for sid in validator.ids:
            with self.subTest(schema=sid):
                validator.errors({}, sid)  # raises SchemaError on an unsupported keyword

    def test_malformed_variants_are_invalid(self) -> None:
        """DCL-2 step 4: a document that breaks its schema is discarded."""
        for name, description, change in MALFORMED:
            with self.subTest(example=name, case=description):
                doc = mutate(testdata.example(name), change)
                self.assertNotEqual(schema.validate(doc, testdata.EXAMPLE_SCHEMAS[name]), [])

    def test_released_attestation_may_name_a_successor(self) -> None:
        doc = testdata.example("custody-attestation.json")
        doc["message"].update(status=2, successor=testdata.ANVIL_1)
        self.assertEqual(schema.validate(doc, "custody-attestation"), [])

    def test_waived_fact_needs_nothing_but_the_reason(self) -> None:
        doc = testdata.example("declarations.json")
        doc["conservation"]["format"] = {"waived": True, "reason": "Measured by the venue."}
        self.assertEqual(schema.validate(doc, "declarations"), [])


class KeywordTest(unittest.TestCase):
    def make(self, body: dict) -> Validator:
        return Validator([{"$id": "urn:t", **body}])

    def test_unsupported_keyword_fails_closed(self) -> None:
        with self.assertRaises(SchemaError):
            self.make({"format": "email"}).errors("x", "urn:t")

    def test_unresolvable_ref(self) -> None:
        with self.assertRaises(SchemaError):
            self.make({"$ref": "urn:other#/$defs/x"}).errors(1, "urn:t")

    def test_unknown_schema_id(self) -> None:
        with self.assertRaises(SchemaError):
            self.make({}).errors(1, "urn:nope")

    def test_types_keep_booleans_apart(self) -> None:
        v = self.make({"type": "integer"})
        self.assertEqual(v.errors(3, "urn:t"), [])
        self.assertEqual(v.errors(3.0, "urn:t"), [])
        self.assertNotEqual(v.errors(True, "urn:t"), [])
        self.assertNotEqual(v.errors(3.5, "urn:t"), [])

    def test_enum_and_const_use_json_equality(self) -> None:
        self.assertNotEqual(self.make({"const": 1}).errors(True, "urn:t"), [])
        self.assertEqual(self.make({"enum": [1, None]}).errors(1.0, "urn:t"), [])
        self.assertEqual(self.make({"enum": [1, None]}).errors(None, "urn:t"), [])

    def test_pattern_dollar_is_end_of_string(self) -> None:
        v = self.make({"pattern": "^a$"})
        self.assertEqual(v.errors("a", "urn:t"), [])
        self.assertNotEqual(v.errors("a\n", "urn:t"), [])

    def test_one_of_needs_exactly_one(self) -> None:
        v = self.make({"oneOf": [{"type": "integer"}, {"minimum": 0}]})
        self.assertNotEqual(v.errors(1, "urn:t"), [])  # both match
        self.assertEqual(v.errors(-1, "urn:t"), [])

    def test_any_of_and_not(self) -> None:
        self.assertNotEqual(self.make({"anyOf": [{"type": "string"}, {"type": "null"}]}).errors(1, "urn:t"), [])
        self.assertNotEqual(self.make({"not": {"type": "string"}}).errors("x", "urn:t"), [])

    def test_unevaluated_properties_see_through_all_of(self) -> None:
        v = self.make({"allOf": [{"properties": {"a": True}}], "unevaluatedProperties": False})
        self.assertEqual(v.errors({"a": 1}, "urn:t"), [])
        self.assertNotEqual(v.errors({"a": 1, "b": 2}, "urn:t"), [])


if __name__ == "__main__":
    unittest.main()
