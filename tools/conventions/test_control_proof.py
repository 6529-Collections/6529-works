"""The control-proof verifier: DCL-23 (the message), DCL-24 (the verifier's steps 1 to 6) and
DCL-25 (a cold holder through a consolidated signer). Signature recovery is a stub here; the
example signature itself is checked against `cast` in test_eip712."""

from __future__ import annotations

import copy
import unittest
from typing import Any

from tools.conventions import control_proof, testdata
from tools.conventions.control_proof import MemoryNonceStore, issue_challenge, verify_response
from tools.conventions.schema import validate

STREAM = "0x02617dbdc0b0521124cb4c2a3ef602977e29bd91"
EDITIONS = "0x" + "ed" * 20
AUCTION = "0x" + "a0" * 20
VENUE = "https://gallery.example"
DIGEST = bytes.fromhex("2548db021144b031169071ded42000449c5128184168ca0bd94e5d56c4e0a057")


def accept_example(signer: str, digest: bytes, signature: bytes) -> bool:
    return signer == testdata.ANVIL_0 and digest == DIGEST


def any_signature(signer: str, digest: bytes, signature: bytes) -> bool:
    return True


class Fixture:
    def __init__(self) -> None:
        self.doc = testdata.example("control-proof.json")
        self.store = MemoryNonceStore()
        self.store.add(self.doc["message"])
        self.kwargs: dict[str, Any] = dict(
            venue=VENUE, chain_id=11155111, now=1794787260, store=self.store,
            official_tokens={STREAM: "stream", EDITIONS: "editions"},
            block={"number": 100, "timestamp": 1794787250}, head_block=110, signer_code=b"",
            ownership={"ownerOf": testdata.ANVIL_1},
            consolidation={"isEstablished": True, "effectiveAt": 1700000000},
            ecdsa=accept_example,
        )  # fmt: skip

    def verify(self, doc: dict | None = None, **overrides: Any) -> control_proof.Verdict:
        return verify_response(doc or self.doc, **{**self.kwargs, **overrides})

    def issued(self, change: Any) -> dict:
        """A response to a challenge the venue issued with `change` applied: the store holds
        the changed challenge, so the response equals it (DCL-24 step 2)."""
        doc = copy.deepcopy(self.doc)
        change(doc["message"])
        self.store.outstanding.clear()
        self.store.add(doc["message"])
        return doc


class ExampleTest(unittest.TestCase):
    def test_example_through_an_established_consolidation(self) -> None:
        """DCL-24 steps 2 to 5 and DCL-25: the example's holder (Anvil 1) differs from its signer
        (Anvil 0), so it is accepted only through an established consolidation."""
        f = Fixture()
        verdict = f.verify()
        self.assertTrue(verdict.accepted, verdict)
        self.assertEqual((verdict.trust, verdict.step), ("full", "DCL-25"))
        self.assertEqual(verdict.digest, "0x" + DIGEST.hex())

    def test_nonce_is_spent_whatever_the_outcome(self) -> None:
        """DCL-24 step 6, and step 2's 'unused': a replay is refused."""
        f = Fixture()
        self.assertTrue(f.verify().accepted)
        replay = f.verify()
        self.assertFalse(replay.accepted)
        self.assertIn("nonce", replay.reason)
        g = Fixture()
        self.assertFalse(g.verify(venue="https://other.example").accepted)
        self.assertFalse(g.store.is_outstanding(g.doc["message"]["nonce"]))


class StepTwoTest(unittest.TestCase):
    def test_refusals(self) -> None:
        """DCL-24 step 2: venue, nonce, time window, chain and official token; DCL-23: the
        document's shape and a signature."""
        msg = testdata.example("control-proof.json")["message"]
        cases = [
            ("venue", {"venue": "https://evil.example"}, None),
            ("nonce", {"store": MemoryNonceStore()}, None),
            ("time", {"now": msg["issuedAt"] - 61}, None),
            ("time", {"now": msg["expiresAt"] + 1}, None),
            ("chainId", {"chain_id": 1}, None),
            ("official", {"official_tokens": {EDITIONS: "editions"}}, None),
            ("signature", {}, lambda d: d.pop("signature")),
            ("control-proof.v1", {}, lambda d: d["message"].pop("holder")),
        ]
        for needle, overrides, change in cases:
            with self.subTest(needle=needle, overrides=list(overrides)):
                f = Fixture()
                doc = copy.deepcopy(f.doc)
                if change:
                    change(doc)
                verdict = f.verify(doc, **overrides)
                self.assertFalse(verdict.accepted)
                self.assertIn(needle, verdict.reason)

    def test_window_edges_are_inclusive(self) -> None:
        """DCL-24 step 2: [issuedAt - 60 s, expiresAt]."""
        msg = testdata.example("control-proof.json")["message"]
        for now in (msg["issuedAt"] - 60, msg["expiresAt"]):
            with self.subTest(now=now):
                f = Fixture()
                self.assertTrue(f.verify(now=now, block={"number": 100, "timestamp": msg["issuedAt"]}).accepted)

    def test_response_must_equal_the_issued_challenge(self) -> None:
        """DCL-24 step 2: a response whose message differs from the issued challenge in any field
        is refused, even with a valid signature over what it carries, and the nonce is spent."""
        changes = {
            "tokenId": "43", "holder": testdata.ANVIL_0, "signer": testdata.ANVIL_1, "token": EDITIONS,
            "chainId": 1, "venue": "https://other.example", "issuedAt": 1794787201, "expiresAt": 1794787700,
        }  # fmt: skip
        for key, value in changes.items():
            with self.subTest(field=key):
                f = Fixture()
                doc = copy.deepcopy(f.doc)
                doc["message"][key] = value
                verdict = f.verify(doc, ecdsa=any_signature)
                self.assertEqual((verdict.accepted, verdict.step), (False, "DCL-24.2"))
                self.assertIn("issued challenge", verdict.reason)
                self.assertFalse(f.store.is_outstanding(f.doc["message"]["nonce"]))

    def test_digest_uses_the_verifiers_chain_id(self) -> None:
        """DCL-24 step 3: the digest is built with the verifier's own chain ID, so a signature
        made in another chain's domain does not verify."""
        f = Fixture()
        other_chain = control_proof.eip712.control_digest(f.doc["message"], 1)
        verdict = f.verify(ecdsa=lambda s, d, sig: d == other_chain)
        self.assertEqual((verdict.accepted, verdict.step), (False, "DCL-24.3"))
        self.assertEqual(verdict.digest, "0x" + DIGEST.hex())


class SignatureAndOwnershipTest(unittest.TestCase):
    def test_bad_signature_is_refused_at_step_three(self) -> None:
        """DCL-24 step 3."""
        verdict = Fixture().verify(ecdsa=lambda *a: False)
        self.assertEqual((verdict.accepted, verdict.step), (False, "DCL-24.3"))

    def test_contract_signer_uses_erc1271(self) -> None:
        """DCL-24 step 3: ERC-1271 isValidSignature for a contract signer, at block B."""
        f = Fixture()
        verdict = f.verify(signer_code=b"\x60\x80", erc1271=lambda s, d, sig: d == DIGEST)
        self.assertEqual((verdict.accepted, verdict.signature_path), (True, "erc1271"))

    def test_block_choice(self) -> None:
        """DCL-24 step 4: B within the freshness bound and not before issuedAt."""
        stale = Fixture().verify(head_block=100 + 65)
        self.assertEqual((stale.accepted, stale.step), (False, "DCL-24.4"))
        early = Fixture().verify(block={"number": 100, "timestamp": 1794787199})
        self.assertIn("before issuedAt", early.reason)
        self.assertTrue(Fixture().verify(head_block=164).accepted)

    def test_ownership_reads(self) -> None:
        """DCL-24 step 4: ownerOf names the holder; an edition needs a balance; the auction's
        pending-delivery buyer counts only when the venue accepts it."""
        f = Fixture()
        self.assertFalse(f.verify(ownership={"ownerOf": testdata.ANVIL_0}).accepted)
        pending = {"ownerOf": AUCTION, "englishAuction": AUCTION, "pendingDelivery": testdata.ANVIL_1}
        self.assertFalse(Fixture().verify(ownership=pending).accepted)
        self.assertTrue(Fixture().verify(ownership=pending, accept_pending_delivery=True).accepted)
        wrong_buyer = dict(pending, pendingDelivery=testdata.ANVIL_0)
        self.assertFalse(Fixture().verify(ownership=wrong_buyer, accept_pending_delivery=True).accepted)

    def test_edition_balance(self) -> None:
        def edition_doc(f: Fixture) -> dict:
            return f.issued(lambda m: m.update(token=EDITIONS))
        for balance, ok in ((1, True), (0, False), (None, False), (True, False)):
            with self.subTest(balance=balance):
                f = Fixture()
                verdict = f.verify(edition_doc(f), ownership={"balanceOf": balance}, ecdsa=any_signature)
                self.assertEqual(verdict.accepted, ok, verdict)


class ConsolidationTest(unittest.TestCase):
    def test_holder_is_signer(self) -> None:
        """DCL-24 step 5: holder == signer is accepted with no consolidation read."""
        f = Fixture()
        doc = f.issued(lambda m: m.update(holder=testdata.ANVIL_0))
        verdict = f.verify(doc, ownership={"ownerOf": testdata.ANVIL_0}, consolidation=None, ecdsa=any_signature)
        self.assertEqual((verdict.accepted, verdict.step), (True, "DCL-24.5"))

    def test_consolidation_paths(self) -> None:
        """DCL-25: established is accepted; a live, younger pair only at lower trust when the
        venue allows it; no two-way consolidation is refused."""
        young = {"isEstablished": False, "effectiveAt": 1794787250 + 86400}
        cases = [
            ({"isEstablished": False, "effectiveAt": 0}, {}, False, None),
            ({"isEstablished": False, "effectiveAt": 1700000000}, {}, False, None),
            (young, {}, False, None),
            (young, {"accept_young_consolidation": True}, True, "low"),
            (None, {}, False, None),
        ]
        for consolidation, extra, accepted, trust in cases:
            with self.subTest(consolidation=consolidation, extra=extra):
                verdict = Fixture().verify(consolidation=consolidation, **extra)
                self.assertEqual((verdict.accepted, verdict.trust), (accepted, trust), verdict)


class ChallengeTest(unittest.TestCase):
    def test_issue_challenge(self) -> None:
        """DCL-24 step 1: a fresh nonce, at most 10 minutes, stored as outstanding; DCL-23: the
        challenge is a control-proof.v1 document without a signature."""
        store = MemoryNonceStore()
        doc = issue_challenge(venue=VENUE, chain_id=11155111, token=STREAM.upper().replace("0X", "0x"),
                              token_id=42, holder=testdata.ANVIL_1, signer=testdata.ANVIL_0,
                              now=1794787200, store=store)  # fmt: skip
        self.assertEqual(validate(doc, "control-proof"), [])
        self.assertNotIn("signature", doc)
        self.assertEqual(doc["message"]["expiresAt"] - doc["message"]["issuedAt"], 600)
        self.assertTrue(store.is_outstanding(doc["message"]["nonce"]))
        other = issue_challenge(venue=VENUE, chain_id=1, token=STREAM, token_id=1, holder=testdata.ANVIL_1,
                                signer=testdata.ANVIL_0, now=0)  # fmt: skip
        self.assertNotEqual(other["message"]["nonce"], doc["message"]["nonce"])
        for bad in (601, 0):
            with self.subTest(validity=bad), self.assertRaises(ValueError):
                issue_challenge(venue=VENUE, chain_id=1, token=STREAM, token_id=1, holder=testdata.ANVIL_1,
                                signer=testdata.ANVIL_0, now=0, validity_seconds=bad)  # fmt: skip

    def test_issued_challenge_round_trips(self) -> None:
        """DCL-24 steps 1 to 6 end to end with a stub backend and the challenge's own digest."""
        store = MemoryNonceStore()
        doc = issue_challenge(venue=VENUE, chain_id=11155111, token=STREAM, token_id=7,
                              holder=testdata.ANVIL_0, signer=testdata.ANVIL_0, now=1000, store=store)  # fmt: skip
        doc["signature"] = "0x" + "11" * 32 + "22" * 32 + "1b"
        verdict = verify_response(
            doc, venue=VENUE, chain_id=11155111, now=1100, store=store,
            official_tokens={STREAM: "stream"}, block={"number": 5, "timestamp": 1050}, head_block=6,
            signer_code=b"", ownership={"ownerOf": testdata.ANVIL_0},
            ecdsa=lambda s, d, sig: d == control_proof.eip712.control_digest(doc["message"]),
        )  # fmt: skip
        self.assertTrue(verdict.accepted, verdict)


if __name__ == "__main__":
    unittest.main()
