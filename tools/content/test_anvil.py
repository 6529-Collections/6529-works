"""End-to-end test against the REAL `ContentStore` bytecode on a local Anvil node.

The tooling plans a file, emits calldata, and that exact calldata is sent as transactions (with the
gas limit the tool recommends) to the compiled contract. Then `verify` and `rebuild` read the file
back from the chain. This is the check that the Python ABI encoding, chunking, file ID and gas
model agree with the deployed contract, not just with a model of it.

Needs `anvil` on the PATH and the compiled contract at `out/ContentStore.sol/ContentStore.json`
(`forge build`). Without them the tests are skipped, unless `CONTENT_E2E_REQUIRE=1` is set (CI sets
it), in which case a missing prerequisite is a failure. Anvil's unlocked dev accounts sign the
transactions, so no private key appears anywhere.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any

from tools.content import abi, calls, gas
from tools.content import plan as pl
from tools.content.address import checksum_address
from tools.content.cli import main
from tools.content.encoding import Encoding, base64_attestation_problem
from tools.content.golden import ROOT, counter_bytes
from tools.content.keccak import keccak256
from tools.content.errors import RevertError
from tools.content.rpc import JsonRpc

ARTIFACT = ROOT / "out" / "ContentStore.sol" / "ContentStore.json"
REQUIRED = os.environ.get("CONTENT_E2E_REQUIRE") == "1"
MANIFEST_REGISTERED = keccak256(b"ManifestRegistered(bytes32,uint256,uint256,uint8,bytes32,string)")
BASE64_PROGRESS = keccak256(b"Base64Progress(bytes32,uint256)")
BASE64_ATTESTED = keccak256(b"Base64Attested(bytes32)")

_anvil: subprocess.Popen[bytes] | None = None
_rpc: JsonRpc | None = None
_store: bytes = b""
_sender = ""
_url = ""


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def setUpModule() -> None:
    global _anvil, _rpc, _store, _sender, _url
    anvil = shutil.which("anvil")
    if anvil is None or not ARTIFACT.exists():
        message = "anvil or the compiled ContentStore (forge build) is missing"
        if REQUIRED:
            raise AssertionError(message)
        raise unittest.SkipTest(message)
    os.environ.setdefault("NO_PROXY", "127.0.0.1")
    port = _free_port()
    _anvil = subprocess.Popen(
        [anvil, "--port", str(port), "--silent"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    _url = f"http://127.0.0.1:{port}"
    _rpc = JsonRpc(_url)
    deadline = time.time() + 30
    while True:
        try:
            _rpc.request("eth_chainId", [])
            break
        except Exception:  # noqa: BLE001 - still starting
            if time.time() > deadline or _anvil.poll() is not None:
                raise
            time.sleep(0.2)
    _sender = _rpc.request("eth_accounts", [])[0]
    bytecode = json.loads(ARTIFACT.read_text(encoding="utf-8"))["bytecode"]["object"]
    receipt = _send({"from": _sender, "data": bytecode, "gas": hex(10_000_000)})
    _store = bytes.fromhex(receipt["contractAddress"][2:])


def tearDownModule() -> None:
    if _anvil is not None:
        _anvil.terminate()
        try:
            _anvil.wait(timeout=10)
        except subprocess.TimeoutExpired:
            _anvil.kill()


def _send(tx: dict[str, Any]) -> dict[str, Any]:
    """Send a transaction from Anvil's unlocked account and return its mined receipt."""
    assert _rpc is not None
    tx_hash = _rpc.request("eth_sendTransaction", [tx])
    for _ in range(100):
        receipt = _rpc.request("eth_getTransactionReceipt", [tx_hash])
        if receipt is not None:
            return receipt
        time.sleep(0.05)
    raise AssertionError("transaction was not mined")


def send_call(call: calls.CallPlan) -> dict[str, Any]:
    """Send one emitted call with exactly the calldata and gas limit the tool recommends."""
    return _send(
        {
            "from": _sender,
            "to": checksum_address(_store),
            "data": "0x" + call.data.hex(),
            "gas": hex(call.gas_limit),
        }
    )


def run(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = main(list(argv))
    return code, out.getvalue(), err.getvalue()


def manifest_of(plan: pl.Plan) -> pl.Manifest:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "m.json"
        path.write_text(json.dumps(pl.manifest_dict(plan, "m.stored", None)), encoding="utf-8")
        return pl.load_manifest(path)


class AnvilEndToEndTest(unittest.TestCase):
    def cli(self, command: str, plan: pl.Plan, *extra: str) -> tuple[int, str, str]:
        return run(
            command, "--rpc", _url, "--store", checksum_address(_store),
            "0x" + plan.file_id.hex(), *extra,
        )

    def stage(self, plan: pl.Plan, **kwargs: Any) -> list[dict[str, Any]]:
        receipts = []
        for call in calls.build_calls(manifest_of(plan), plan.stored, **kwargs):
            receipt = send_call(call)
            self.assertEqual(receipt["status"], "0x1", f"{call.name} failed")
            used = int(receipt["gasUsed"], 16)
            self.assertLessEqual(used, call.estimate.transaction, f"{call.name} used more gas than modelled")
            self.assertLessEqual(used, gas.TX_GAS_CAP)
            receipts.append(receipt)
        return receipts

    def test_every_encoding_stages_verifies_and_rebuilds(self) -> None:
        media = (b"6529 Works on chain. " * 1200) + counter_bytes(31, 26_000)
        for encoding in Encoding:
            with self.subTest(encoding=encoding.label), tempfile.TemporaryDirectory() as tmp:
                plan = pl.plan_from_media(media, "text/plain", encoding)
                receipts = self.stage(plan)
                # The contract computed the same file ID: it is the indexed topic of the event.
                registered = [
                    log
                    for r in receipts
                    for log in r["logs"]
                    if log["topics"][0] == "0x" + MANIFEST_REGISTERED.hex()
                ]
                self.assertEqual(len(registered), 1)
                self.assertEqual(registered[0]["topics"][1], "0x" + plan.file_id.hex())

                code, out, err = self.cli("verify", plan, "-q")
                self.assertEqual(code, 0, out + err)
                self.assertIn("reproducible  yes", out)
                target = Path(tmp) / "media.bin"
                code, out, err = self.cli("rebuild", plan, "-o", str(target), "-q")
                self.assertEqual(code, 0, out + err)
                self.assertEqual(target.read_bytes(), media)

    def test_partial_upload_then_resume_with_only_missing(self) -> None:
        media = counter_bytes(32, 3 * pl.CHUNK_SIZE + 500)  # four chunks
        plan = pl.plan_from_media(media, "application/octet-stream", Encoding.IDENTITY)
        built = calls.build_calls(manifest_of(plan), plan.stored)
        for call in built[:3]:  # the registration and the first two chunks
            self.assertEqual(send_call(call)["status"], "0x1")

        code, out, _ = self.cli("verify", plan, "-q", "--json")
        report = json.loads(out)
        self.assertEqual((code, report["missingChunks"], report["complete"]), (1, [2, 3], False))

        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = Path(tmp) / "m.json"
            manifest_path.write_text(json.dumps(pl.manifest_dict(plan, "m.stored", None)), encoding="utf-8")
            (Path(tmp) / "m.stored").write_bytes(plan.stored)
            code, out, err = run(
                "calls", str(manifest_path), "--store", checksum_address(_store),
                "--rpc", _url, "--only-missing", "--json",
            )
            self.assertEqual(code, 0, err)
            remaining = json.loads(out)["transactions"]
            self.assertEqual([(t["name"], t["chunkIndexes"]) for t in remaining], [("writeChunk", [2]), ("writeChunk", [3])])
            resumed = calls.build_calls(
                manifest_of(plan), plan.stored, skip_register=True,
                present_chunk_hashes=plan.chunk_hashes[:2],
            )
            for call in resumed:
                self.assertEqual(send_call(call)["status"], "0x1")
        self.assertEqual(self.cli("verify", plan, "-q")[0], 0)

    def test_chunks_first_then_the_manifest(self) -> None:
        plan = pl.plan_from_media(counter_bytes(33, 30_000), "image/png", Encoding.BASE64)
        self.stage(plan, register="last")
        self.assertEqual(self.cli("verify", plan, "-q")[0], 0)

    def test_a_repeated_chunk_is_stored_once_and_the_file_completes(self) -> None:
        block = counter_bytes(34, pl.CHUNK_SIZE)
        plan = pl.plan_from_media(block * 3 + b"end", "application/octet-stream", Encoding.IDENTITY)
        built = calls.build_calls(manifest_of(plan), plan.stored)
        self.assertEqual([c.name for c in built], ["registerManifest", "writeChunk", "writeChunk"])
        self.stage(plan)
        code, out, _ = self.cli("verify", plan, "-q")
        self.assertEqual(code, 0, out)

    def test_a_different_claim_about_the_same_chunks_is_a_different_file(self) -> None:
        # Same chunks, different claim: a different file that cannot overwrite the honest one.
        media = counter_bytes(35, 5_000)
        honest = pl.plan_from_media(media, "text/plain", Encoding.IDENTITY)
        self.stage(honest)
        other_mime = pl.plan_from_media(media, "text/html", Encoding.IDENTITY)
        self.assertNotEqual(honest.file_id, other_mime.file_id)
        self.assertEqual(self.cli("verify", other_mime, "-q")[0], 1)  # unknown until registered
        self.assertEqual(self.cli("verify", honest, "-q")[0], 0)

    def test_registration_at_the_chunk_limit_is_inside_the_model_and_the_cap(self) -> None:
        hashes = [keccak256(b"limit" + i.to_bytes(2, "big")) for i in range(pl.MAX_CHUNKS)]
        mime = "a/" + "b" * 62
        data = abi.encode_register_manifest(
            hashes, pl.MAX_STORED_BYTES, int(Encoding.GZIP), mime, bytes([9] * 32)
        )
        estimate = gas.estimate_register(pl.MAX_CHUNKS, len(mime), data)
        self.assertTrue(estimate.within_cap and estimate.has_margin)
        call = calls.CallPlan(0, "registerManifest", (), data, estimate, "x")
        receipt = send_call(call)
        self.assertEqual(receipt["status"], "0x1")
        used = int(receipt["gasUsed"], 16)
        self.assertLessEqual(used, estimate.transaction)
        self.assertLess(used, gas.TX_GAS_CAP * 3 // 4)
        # ... and the contract agrees on the ID.
        expected = pl.manifest_id(hashes, pl.MAX_STORED_BYTES, Encoding.GZIP, mime, bytes([9] * 32))
        topics = [log["topics"][1] for log in receipt["logs"]]
        self.assertEqual(topics, ["0x" + expected.hex()])

    def test_a_full_chunk_write_is_inside_the_model_and_the_cap(self) -> None:
        chunk = counter_bytes(36, pl.CHUNK_SIZE)
        data = abi.encode_write_chunk(chunk)
        estimate = gas.estimate_write_chunk(len(chunk), data)
        receipt = send_call(calls.CallPlan(0, "writeChunk", (0,), data, estimate, "x"))
        self.assertEqual(receipt["status"], "0x1")
        used = int(receipt["gasUsed"], 16)
        self.assertLessEqual(used, estimate.transaction)
        self.assertGreater(used, estimate.transaction * 9 // 10, "the model is far too loose")

    # ---------------------------------------------------------------- base64 attestation

    def topics(self, receipt: dict[str, Any]) -> list[str]:
        return [log["topics"][0] for log in receipt["logs"]]

    def test_the_emitted_attest_calls_attest_both_base64_encodings(self) -> None:
        media = (b"attest me " * 2000) + counter_bytes(41, 20_000)
        for encoding in (Encoding.BASE64, Encoding.GZIP_BASE64):
            with self.subTest(encoding=encoding.label):
                plan = pl.plan_from_media(media, "text/plain", encoding)
                built = calls.build_calls(manifest_of(plan), plan.stored)
                self.assertEqual(built[-1].name, "attestBase64")
                self.stage(plan, attest=False)

                # Complete and correct, but a renderer would not inline it yet.
                code, out, err = self.cli("verify", plan, "-q", "--json")
                report = json.loads(out)
                self.assertEqual(code, 0, out + err)
                self.assertEqual(
                    (report["base64Attested"], report["attestCallsNeeded"]), (False, 1)
                )
                self.assertEqual(self.cli("verify", plan, "-q", "--require-attested")[0], 1)

                receipt = send_call(built[-1])
                self.assertEqual(receipt["status"], "0x1")
                self.assertEqual(self.topics(receipt), ["0x" + BASE64_ATTESTED.hex()])
                self.assertLessEqual(int(receipt["gasUsed"], 16), built[-1].estimate.transaction)

                code, out, err = self.cli("verify", plan, "-q", "--json", "--require-attested")
                report = json.loads(out)
                self.assertEqual(code, 0, out + err)
                self.assertEqual((report["base64Attested"], report["base64TextValid"]), (True, True))

    def test_a_file_of_more_than_48_chunks_takes_two_attest_calls(self) -> None:
        # Zero media is the base64 text AAAA...: about 50 chunks, nearly all identical, so only
        # two distinct chunks are uploaded and the flow stays quick. Gas for 48 DISTINCT cold
        # chunks is measured against the model in UploaderAttest.t.sol.
        media = bytes(920_000)
        plan = pl.plan_from_media(media, "application/octet-stream", Encoding.BASE64)
        self.assertGreater(len(plan.chunk_hashes), 48)
        built = calls.build_calls(manifest_of(plan), plan.stored)
        attests = [c for c in built if c.name == "attestBase64"]
        self.assertEqual(len(attests), 2)
        self.assertEqual(len(attests[0].chunk_indexes), 48)
        self.assertEqual(attests[1].chunk_indexes, tuple(range(48, len(plan.chunk_hashes))))
        self.stage(plan, attest=False)

        first = send_call(attests[0])
        self.assertEqual(first["status"], "0x1")
        self.assertEqual(self.topics(first), ["0x" + BASE64_PROGRESS.hex()])
        used = int(first["gasUsed"], 16)
        self.assertLessEqual(used, attests[0].estimate.transaction)
        self.assertLess(used, gas.TX_GAS_CAP * 55 // 100)
        code, out, _ = self.cli("verify", plan, "-q", "--json")
        self.assertEqual((code, json.loads(out)["base64Attested"]), (0, False))

        second = send_call(attests[1])
        self.assertEqual(second["status"], "0x1")
        self.assertEqual(self.topics(second), ["0x" + BASE64_ATTESTED.hex()])
        self.assertLessEqual(int(second["gasUsed"], 16), attests[1].estimate.transaction)
        code, out, _ = self.cli("verify", plan, "-q", "--json", "--require-attested")
        self.assertEqual((code, json.loads(out)["base64Attested"]), (0, True))

        # A further call is a cheap no-op that still succeeds.
        extra = send_call(attests[0])
        self.assertEqual(extra["status"], "0x1")
        self.assertEqual(extra["logs"], [])
        self.assertLess(int(extra["gasUsed"], 16), 50_000)

    def test_only_missing_stops_emitting_attest_calls_once_the_file_is_attested(self) -> None:
        plan = pl.plan_from_media(counter_bytes(42, 30_000), "text/plain", Encoding.BASE64)
        self.stage(plan, attest=False)
        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = Path(tmp) / "m.json"
            manifest_path.write_text(
                json.dumps(pl.manifest_dict(plan, "m.stored", None)), encoding="utf-8"
            )
            (Path(tmp) / "m.stored").write_bytes(plan.stored)
            args = (
                "calls", str(manifest_path), "--store", checksum_address(_store), "--rpc", _url,
                "--only-missing", "--json", "--force",
            )
            code, out, err = run(*args)
            self.assertEqual(code, 0, err)
            self.assertEqual(
                [t["name"] for t in json.loads(out)["transactions"]], ["attestBase64"]
            )
            built = calls.build_calls(
                manifest_of(plan), plan.stored, skip_register=True,
                present_chunk_hashes=plan.chunk_hashes,
            )
            self.assertEqual(send_call(built[-1])["status"], "0x1")
            code, out, _ = run(*args)
            document = json.loads(out)
            self.assertEqual(document["transactions"], [])
            self.assertTrue(document["skipped"]["attestBase64"])

    def test_texts_the_tool_refuses_are_refused_by_the_contract_too(self) -> None:
        # The strictness check against the real store: stage texts that break the rule directly
        # (the tool would not plan them), then read the revert attestBase64 gives.
        cases = {
            b"QU-J": "ContentBase64Invalid({id}, 0)",
            b"QQ=A": "ContentBase64Invalid({id}, 0)",
            b"QUJDQ": "ContentBase64LengthInvalid({id}, 5)",
            b"A" * 24_575 + b"$": "ContentBase64Invalid({id}, 1)",
            b"A" * 24_573 + b"===": "ContentBase64Invalid({id}, 0)",
        }
        assert _rpc is not None
        for text, expected in cases.items():
            with self.subTest(text[:8], length=len(text)):
                self.assertIsNotNone(base64_attestation_problem(text))
                chunks = pl.split_chunks(text)
                hashes = [pl.chunk_hash(c) for c in chunks]
                digest = bytes([3] * 32)
                register = abi.encode_register_manifest(
                    hashes, len(text), int(Encoding.BASE64), "text/plain", digest
                )
                file_id = pl.manifest_id(hashes, len(text), Encoding.BASE64, "text/plain", digest)
                for data in (register, *(abi.encode_write_chunk(c) for c in chunks)):
                    receipt = _send(
                        {
                            "from": _sender,
                            "to": checksum_address(_store),
                            "data": "0x" + data.hex(),
                            "gas": hex(6_000_000),
                        }
                    )
                    self.assertEqual(receipt["status"], "0x1")
                with self.assertRaises(RevertError) as ctx:
                    _rpc.eth_call(_store, abi.encode_call(abi.ATTEST_BASE64, file_id))
                self.assertEqual(str(ctx.exception), expected.format(id="0x" + file_id.hex()))
                attested = _rpc.eth_call(_store, abi.encode_call(abi.IS_BASE64_ATTESTED, file_id))
                self.assertFalse(abi.decode_bool(attested))

    def test_verify_refuses_an_address_with_no_contract(self) -> None:
        assert _rpc is not None
        code, _, err = run(
            "verify", "--rpc", _url, "--store", "0x" + "22" * 20, "0x" + "00" * 32, "-q"
        )
        self.assertEqual((code, "no contract" in err), (2, True))


if __name__ == "__main__":
    unittest.main()
