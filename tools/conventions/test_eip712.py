"""EIP-712 digests and the reader's signature check: DCL-19 (the custody typed data and its type
hash, the example digest), DCL-23 (the control-proof typed data and its type hash, the example
digest) and DCL-20 / DCL-24 step 3 (low-s ECDSA, EIP-7702, ERC-1271, as SignatureVerifier).

The example signatures were made with the public Anvil test account 0. They are checked with
Foundry's `cast` when it is installed (set CONVENTIONS_CAST_REQUIRE=1 to fail instead of skip);
everything else uses a stub recovery backend."""

from __future__ import annotations

import os
import shutil
import unittest

from tools.content.errors import ToolError
from tools.conventions import eip712, testdata
from tools.conventions.eip712 import HALF_N, SECP256K1_N, verify_signature

CUSTODY_DIGEST = "a03cc2c3767834df2ef6c583fd5d08e6d65ddd616d2f90a96e0ad8e00e152e2a"
CONTROL_DIGEST = "2548db021144b031169071ded42000449c5128184168ca0bd94e5d56c4e0a057"


def sig_bytes(doc: dict) -> bytes:
    return bytes.fromhex(doc["signature"][2:])


def compact(sig65: bytes) -> bytes:
    """ERC-2098: r || (v - 27) << 255 | s."""
    vs = int.from_bytes(sig65[32:64], "big") | ((sig65[64] - 27) << 255)
    return sig65[:32] + vs.to_bytes(32, "big")


def high_s(sig65: bytes) -> bytes:
    s = int.from_bytes(sig65[32:64], "big")
    return sig65[:32] + (SECP256K1_N - s).to_bytes(32, "big") + bytes([55 - sig65[64]])


class Recorder:
    """A stub backend: accepts exactly the (signer, digest, signature) triples it is given."""

    def __init__(self, *accepted: tuple[str, bytes, bytes]) -> None:
        self.accepted = set(accepted)
        self.calls: list[tuple[str, bytes, bytes]] = []

    def __call__(self, signer: str, digest: bytes, signature: bytes) -> bool:
        self.calls.append((signer, digest, signature))
        return (signer, digest, signature) in self.accepted


class DigestTest(unittest.TestCase):
    def test_type_hashes(self) -> None:
        """DCL-19 and DCL-23: the type hashes the spec prints."""
        self.assertEqual(eip712.CUSTODY_TYPEHASH.hex(),
                         "3dc91787a59cbc3117d2a54785ad6b184b56a9699733e6713675770b4787fe15")
        self.assertEqual(eip712.CONTROL_TYPEHASH.hex(),
                         "551abbed9e673b4462640aaa67f046692206a5f53883fb9c6187674681c102eb")

    def test_example_digests(self) -> None:
        """DCL-19, DCL-23: the example documents' digests, as the spec prints them."""
        custody = testdata.example("custody-attestation.json")
        self.assertEqual(eip712.custody_digest(custody["subject"]["chainId"], custody["message"]).hex(),
                         CUSTODY_DIGEST)
        control = testdata.example("control-proof.json")
        self.assertEqual(eip712.control_digest(control["message"]).hex(), CONTROL_DIGEST)

    def test_every_field_and_the_domain_change_the_digest(self) -> None:
        msg = testdata.example("control-proof.json")["message"]
        base = eip712.control_digest(msg)
        variants = {"venue": "https://other.example", "nonce": "0x" + "00" * 32, "issuedAt": 1,
                    "expiresAt": 2, "chainId": 1, "token": testdata.ZERO, "tokenId": "43",
                    "holder": testdata.ANVIL_0, "signer": testdata.ANVIL_1}  # fmt: skip
        for key, value in variants.items():
            with self.subTest(key):
                self.assertNotEqual(eip712.control_digest(dict(msg, **{key: value})), base)
        self.assertNotEqual(eip712.control_digest(msg, domain_chain_id=1), base)

    def test_out_of_range_fields_are_refused(self) -> None:
        msg = testdata.example("custody-attestation.json")["message"]
        for key, value in (("status", 256), ("asOf", 2**64), ("tokenId", "-1"), ("token", "0x12"),
                           ("objectId", "0x" + "zz" * 32), ("status", True)):  # fmt: skip
            with self.subTest(key=key, value=value), self.assertRaises(ToolError):
                eip712.custody_digest(1, dict(msg, **{key: value}))


class SignatureRulesTest(unittest.TestCase):
    """DCL-20 / DCL-24 step 3 with a stub backend."""

    def setUp(self) -> None:
        self.doc = testdata.example("control-proof.json")
        self.digest = bytes.fromhex(CONTROL_DIGEST)
        self.sig = sig_bytes(self.doc)
        self.ecdsa = Recorder((testdata.ANVIL_0, self.digest, self.sig))

    def check(self, signature: bytes, code: bytes = b"", signer: str = testdata.ANVIL_0, erc1271=None):
        return verify_signature(signer, self.digest, signature, code=code, ecdsa=self.ecdsa, erc1271=erc1271)

    def test_eoa_ecdsa(self) -> None:
        self.assertEqual(self.check(self.sig), eip712.SignatureCheck(True, "ecdsa"))
        self.assertFalse(self.check(self.sig, signer=testdata.ANVIL_1).valid)

    def test_erc2098_compact_is_normalized(self) -> None:
        self.assertTrue(self.check(compact(self.sig)).valid)
        self.assertEqual(self.ecdsa.calls[-1][2], self.sig)

    def test_refused_before_recovery(self) -> None:
        """SignatureVerifier.isValidECDSA: length, v, r and low s are checked first."""
        r_zero = bytes(32) + self.sig[32:]
        cases = {
            "high s": high_s(self.sig),
            "v = 29": self.sig[:64] + bytes([29]),
            "v = 0": self.sig[:64] + bytes([0]),
            "63 bytes": self.sig[:63],
            "66 bytes": self.sig + b"\x00",
            "r = 0": r_zero,
        }
        for name, signature in cases.items():
            with self.subTest(name):
                self.ecdsa.calls.clear()
                self.assertFalse(self.check(signature).valid)
                self.assertEqual(self.ecdsa.calls, [])
        self.assertEqual(HALF_N, 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0)

    def test_zero_signer_and_oversized_signature(self) -> None:
        self.assertFalse(self.check(self.sig, signer=testdata.ZERO).valid)
        self.assertFalse(self.check(b"\x01" * 4097, code=b"\x60\x00").valid)

    def test_contract_uses_erc1271_only(self) -> None:
        code = bytes.fromhex("6080604052")
        erc1271 = Recorder((testdata.ANVIL_0, self.digest, b"\x01" * 100))
        self.assertEqual(self.check(b"\x01" * 100, code=code, erc1271=erc1271),
                         eip712.SignatureCheck(True, "erc1271"))
        self.assertFalse(self.check(self.sig, code=code, erc1271=erc1271).valid)
        self.assertEqual(self.ecdsa.calls, [])
        with self.assertRaises(ToolError):
            self.check(self.sig, code=code)

    def test_eip7702_tries_ecdsa_then_erc1271(self) -> None:
        delegated = eip712.DELEGATION_PREFIX + b"\x22" * 20
        self.assertTrue(eip712.is_delegated(delegated))
        self.assertFalse(eip712.is_delegated(delegated + b"\x00"))
        refuse = Recorder()
        self.assertEqual(self.check(self.sig, code=delegated, erc1271=refuse).path, "7702-ecdsa")
        self.assertEqual(refuse.calls, [])
        accept = Recorder((testdata.ANVIL_0, self.digest, b"\x02" * 80))
        self.assertEqual(self.check(b"\x02" * 80, code=delegated, erc1271=accept),
                         eip712.SignatureCheck(True, "7702-erc1271"))


@unittest.skipUnless(shutil.which("cast") or os.environ.get("CONVENTIONS_CAST_REQUIRE"),
                     "cast (Foundry) is not installed")
class CastBackendTest(unittest.TestCase):
    """The example signatures reproduce with the public Anvil test account 0 (DCL-19, DCL-23)."""

    def test_example_signatures_verify(self) -> None:
        control = testdata.example("control-proof.json")
        self.assertTrue(verify_signature(testdata.ANVIL_0, bytes.fromhex(CONTROL_DIGEST), sig_bytes(control), code=b"").valid)
        custody = testdata.example("custody-attestation.json")
        self.assertTrue(verify_signature(testdata.ANVIL_0, bytes.fromhex(CUSTODY_DIGEST), sig_bytes(custody), code=b"").valid)

    def test_compact_form_verifies_and_other_signer_fails(self) -> None:
        sig = sig_bytes(testdata.example("control-proof.json"))
        digest = bytes.fromhex(CONTROL_DIGEST)
        self.assertTrue(verify_signature(testdata.ANVIL_0, digest, compact(sig), code=b"").valid)
        self.assertFalse(verify_signature(testdata.ANVIL_1, digest, sig, code=b"").valid)
        self.assertFalse(verify_signature(testdata.ANVIL_0, bytes.fromhex(CUSTODY_DIGEST), sig, code=b"").valid)


if __name__ == "__main__":
    unittest.main()
