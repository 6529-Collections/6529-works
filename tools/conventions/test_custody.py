"""The custody-attestation reader check: DCL-20 (who may post, the custodian's signature, the
token the message names), DCL-21 (latest asOf counts, future-dated discarded, staleness) and
DCL-22 (recognized custodians and the "custodian not named" outcome)."""

from __future__ import annotations

import copy
import unittest
from typing import Any

from tools.conventions import custody, testdata
from tools.conventions.custody import DAY, UNNAMED_LABEL, evaluate_custody

AS_OF = 1794700800
OBJECT = "0x27036a7eaf555d00bc19a8fca75c359fbaeb5ab2a6dddb13075526d251ff035b"
SUCCESSOR = "0x" + "5c" * 20
STRANGER = "0x" + "57" * 20


def att(**changes: Any) -> dict:
    """An attestation input built from the example document."""
    doc = testdata.example("custody-attestation.json")
    message = changes.pop("message", {})
    doc["message"].update(message)
    for key in ("custodian",):
        if key in changes:
            doc[key] = changes.pop(key)
    entry = {"document": doc, "recordedAt": AS_OF + 100, "posterRole": "OWNER",
             "poster": testdata.ANVIL_1, "signatureValid": True}
    entry.update(changes)
    return entry


def declarations() -> dict:
    return testdata.example("declarations.json")


class ExampleTest(unittest.TestCase):
    def test_example_is_recognized_and_fresh(self) -> None:
        """DCL-21, DCL-22: the example attestation by the named custodian, read a day later."""
        result = evaluate_custody(declarations(), [att()], AS_OF + DAY)
        self.assertEqual(result["discarded"], [])
        self.assertEqual(custody.card_custody(result), [{"objectId": OBJECT, "custodian": testdata.ANVIL_0,
                                                         "recognized": True, "status": "HELD",
                                                         "asOf": AS_OF, "stale": False}])  # fmt: skip

    def test_digest_matches_the_spec(self) -> None:
        """DCL-19: the example's digest."""
        self.assertEqual(custody.attestation_digest(testdata.example("custody-attestation.json")).hex(),
                         "a03cc2c3767834df2ef6c583fd5d08e6d65ddd616d2f90a96e0ad8e00e152e2a")

    def test_signature_check_uses_the_custodian_and_the_digest(self) -> None:
        """DCL-20: the custodian's signature, checked as SignatureVerifier does (stub backend)."""
        doc = testdata.example("custody-attestation.json")
        digest = custody.attestation_digest(doc)
        ok = custody.attestation_signature(doc, ecdsa=lambda s, d, sig: s == testdata.ANVIL_0 and d == digest)
        self.assertTrue(ok.valid)
        bad = custody.attestation_signature(dict(doc, custodian=testdata.ANVIL_1),
                                            ecdsa=lambda s, d, sig: s == testdata.ANVIL_0)
        self.assertFalse(bad.valid)


class StalenessTest(unittest.TestCase):
    def test_named_custodian_uses_its_max_age(self) -> None:
        """DCL-21: stale when now - asOf exceeds the declarations' maxAttestationAgeDays."""
        doc = declarations()
        doc["custodians"][0]["maxAttestationAgeDays"] = 30
        edge = evaluate_custody(doc, [att()], AS_OF + 30 * DAY)["entries"][0]
        self.assertFalse(edge["stale"])
        late = evaluate_custody(doc, [att()], AS_OF + 30 * DAY + 1)["entries"][0]
        self.assertTrue(late["stale"])

    def test_unnamed_custodian_uses_365_days(self) -> None:
        """DCL-21: 365 days for a custodian the declarations do not name; DCL-22: shown as not
        named, with the poster's role and address, never as the object's custody."""
        entry = evaluate_custody(None, [att()], AS_OF + 365 * DAY)["entries"][0]
        self.assertEqual((entry["recognized"], entry["stale"], entry["maxAgeDays"]), (False, False, 365))
        self.assertEqual((entry["label"], entry["posterRole"], entry["poster"]),
                         (UNNAMED_LABEL, "OWNER", testdata.ANVIL_1))
        self.assertTrue(evaluate_custody(None, [att()], AS_OF + 365 * DAY + 1)["entries"][0]["stale"])

    def test_custodian_named_for_another_object_is_not_recognized(self) -> None:
        doc = declarations()
        doc["custodians"][0]["objectId"] = "0x" + "01" * 32
        entries = evaluate_custody(doc, [att()], AS_OF)["entries"]
        found = next(e for e in entries if e["objectId"] == OBJECT)
        self.assertFalse(found["recognized"])
        self.assertEqual(found["label"], UNNAMED_LABEL)

    def test_latest_as_of_counts_not_latest_entry(self) -> None:
        """DCL-21: for each object and custodian the latest asOf counts."""
        newer = att(message={"asOf": AS_OF + 10, "status": 3})
        older_posted_later = att(message={"asOf": AS_OF}, recordedAt=AS_OF + 500)
        entries = evaluate_custody(declarations(), [newer, older_posted_later], AS_OF + DAY)["entries"]
        self.assertEqual([(e["status"], e["asOf"]) for e in entries], [("MISSING", AS_OF + 10)])

    def test_named_custodian_without_attestation(self) -> None:
        """DCL-21: a named custodian with nothing counting shows status NONE and stale."""
        entries = evaluate_custody(declarations(), [], AS_OF)["entries"]
        self.assertEqual(custody.card_custody({"entries": entries}),
                         [{"objectId": OBJECT, "custodian": testdata.ANVIL_0, "recognized": True,
                           "status": "NONE", "asOf": 0, "stale": True}])  # fmt: skip


class DiscardTest(unittest.TestCase):
    def test_discards(self) -> None:
        """DCL-20 and DCL-21: what makes an attestation not count at all."""
        doc_other_token = att()
        doc_other_token["document"]["message"]["tokenId"] = "43"
        mismatched_subject = att(subject={"chainId": 1, "contract": "0x" + "12" * 20, "tokenId": "42"})
        invalid_doc = att()
        invalid_doc["document"]["message"]["status"] = 9
        cases = {
            "more than one hour after": att(message={"asOf": AS_OF + 3601}, recordedAt=AS_OF),
            "signature is not valid": att(signatureValid=False),
            "role DCL-20 does not count": att(posterRole="CURATOR"),
            "another token": doc_other_token,
            "statement's subject": mismatched_subject,
            "not a valid custody-attestation.v1": invalid_doc,
        }
        for needle, entry in cases.items():
            with self.subTest(needle):
                result = evaluate_custody(declarations(), [entry], AS_OF)
                self.assertEqual(len(result["discarded"]), 1)
                self.assertIn(needle, result["discarded"][0]["reason"])
                self.assertEqual([e["status"] for e in result["entries"]], ["NONE"])

    def test_one_hour_skew_is_allowed(self) -> None:
        result = evaluate_custody(declarations(), [att(message={"asOf": AS_OF + 3600}, recordedAt=AS_OF)], AS_OF)
        self.assertEqual(result["discarded"], [])

    def test_every_poster_role_counts(self) -> None:
        for role in ("OWNER", "ARTIST", "PLATFORM"):
            with self.subTest(role):
                self.assertEqual(evaluate_custody(declarations(), [att(posterRole=role)], AS_OF)["discarded"], [])


class SuccessorTest(unittest.TestCase):
    def test_released_successor_is_recognized_transitively(self) -> None:
        """DCL-22: a recognized custodian's valid RELEASED attestation names its successor,
        who is then recognized, and so on."""
        release = att(message={"status": 2, "successor": SUCCESSOR, "asOf": AS_OF + 1})
        second = att(custodian=SUCCESSOR, message={"status": 2, "successor": STRANGER, "asOf": AS_OF + 2})
        third = att(custodian=STRANGER, message={"status": 1, "asOf": AS_OF + 3})
        entries = {e["custodian"]: e for e in evaluate_custody(declarations(), [release, second, third], AS_OF + 4)["entries"]}
        self.assertTrue(all(e["recognized"] for e in entries.values()))
        self.assertEqual(entries[STRANGER]["maxAgeDays"], 365)
        self.assertEqual(entries[testdata.ANVIL_0]["status"], "RELEASED")

    def test_successor_named_by_an_unrecognized_custodian_is_not(self) -> None:
        release = att(custodian=STRANGER, message={"status": 2, "successor": SUCCESSOR})
        held = att(custodian=SUCCESSOR, message={"status": 1})
        entries = {e["custodian"]: e for e in evaluate_custody(declarations(), [release, held], AS_OF)["entries"]}
        self.assertFalse(entries[SUCCESSOR]["recognized"])
        self.assertFalse(entries[STRANGER]["recognized"])

    def test_discarded_release_does_not_recognize(self) -> None:
        release = att(message={"status": 2, "successor": SUCCESSOR}, signatureValid=False)
        held = att(custodian=SUCCESSOR)
        entries = {e["custodian"]: e for e in evaluate_custody(declarations(), [release, held], AS_OF)["entries"]}
        self.assertFalse(entries[SUCCESSOR]["recognized"])


if __name__ == "__main__":
    unittest.main()
