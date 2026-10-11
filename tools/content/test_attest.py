"""Base64 attestation: the strictness rule, the attest calls `calls` emits, and what `verify` says.

`ContentStore.attestBase64(fileId)` validates a stored `Base64` or `GzipBase64` text (strict
RFC 4648 alphabet, `=` only as the last one or two bytes, length a multiple of 4) at most 48 chunks
per call; a renderer inlines the file only once it is attested. The rule here is this tool's copy
of the contract's; `UploaderAttest.t.sol` and `test_anvil.py` check it against the real store.
"""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from tools.content import abi, calls, gas, golden_attest
from tools.content import plan as pl
from tools.content.address import checksum_address
from tools.content.cli import main
from tools.content.encoding import Encoding, base64_attestation_problem
from tools.content.errors import ToolError
from tools.content.fake_chain import STORE_ADDRESS, FakeChain
from tools.content.golden import counter_bytes
from tools.content.keccak import keccak256

STORE = checksum_address(STORE_ADDRESS)
ALPHABET = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")


def run(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = main(list(argv))
    return code, out.getvalue(), err.getvalue()


def manifest_for(plan: pl.Plan) -> pl.Manifest:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "m.json"
        path.write_text(json.dumps(pl.manifest_dict(plan, "m.stored", None)), encoding="utf-8")
        return pl.load_manifest(path)


def synthetic_manifest(chunks: int, encoding: Encoding = Encoding.BASE64) -> pl.Manifest:
    """A manifest of `chunks` chunks that has no bytes behind it, for sizing the call list."""
    hashes = tuple(keccak256(b"synthetic" + i.to_bytes(2, "big")) for i in range(chunks))
    length = (chunks - 1) * pl.CHUNK_SIZE + 4
    digest = bytes([7] * 32)
    return pl.Manifest(
        pl.manifest_id(hashes, length, encoding, "a/b", digest), "a/b", encoding, digest, None,
        length, None, hashes, None,
    )


class RuleTest(unittest.TestCase):
    """The attestation rule, written here independently of the implementation under test."""

    def verdict(self, text: bytes) -> str:
        problem = base64_attestation_problem(text)
        return "ok" if problem is None else problem.kind

    def test_accepted_texts(self) -> None:
        for text in (b"QUJD", b"QUI=", b"QQ==", b"+/+/", b"AAAA" * 100, b"A" * 24_572):
            with self.subTest(text[:12]):
                self.assertEqual(self.verdict(text), "ok")

    def test_length_must_be_a_multiple_of_four(self) -> None:
        for length in (1, 2, 3, 5, 6, 7, 24_575):
            with self.subTest(length):
                self.assertEqual(self.verdict(b"A" * length), "length")
        self.assertEqual(self.verdict(b""), "length")  # the store never holds an empty file

    def test_padding_only_at_the_very_end(self) -> None:
        for text in (b"QQ=A", b"====", b"=QUJ", b"Q===", b"A=A=", b"AA=A", b"=AAA", b"A==A"):
            with self.subTest(text):
                self.assertEqual(self.verdict(text), "alphabet")
        self.assertEqual(self.verdict(b"AAA=" + b"AAAA"), "alphabet")  # padding ends the text
        self.assertEqual(self.verdict(b"AAAAAAA="), "ok")
        self.assertEqual(self.verdict(b"AA=="), "ok")

    def test_every_byte_value_first_and_last(self) -> None:
        first, last = golden_attest.accepted_bitmaps()
        for value in range(256):
            in_alphabet = value in ALPHABET
            self.assertEqual((first >> value) & 1, int(in_alphabet), value)
            # As the last byte `=` is padding too, and only then.
            self.assertEqual((last >> value) & 1, int(in_alphabet or value == ord("=")), value)

    def test_every_byte_value_in_every_position_of_a_group(self) -> None:
        for position in range(4):
            for value in range(256):
                text = bytearray(b"AAAA")
                text[position] = value
                accepted = value in ALPHABET or (value == ord("=") and position == 3)
                self.assertEqual(self.verdict(bytes(text)) == "ok", accepted, (position, value))

    def test_the_first_bad_byte_is_located(self) -> None:
        problem = base64_attestation_problem(b"AAAA" + b"QU-J" + b"A$AA")
        self.assertEqual((problem.kind, problem.offset, problem.value), ("alphabet", 6, ord("-")))

    def test_length_is_judged_before_any_byte(self) -> None:
        problem = base64_attestation_problem(b"QU-JQ")
        self.assertEqual((problem.kind, problem.offset), ("length", None))

    def test_the_chunk_index_follows_the_first_bad_byte(self) -> None:
        for offset, chunk in ((0, 0), (24_574, 0), (24_575, 1), (49_149, 1), (49_150, 2)):
            text = bytearray(b"A" * 49_152)
            text[offset] = ord("$")
            with self.subTest(offset):
                self.assertEqual(golden_attest.verdict(bytes(text)), ("alphabet", chunk))

    def test_padding_may_straddle_the_chunk_boundary(self) -> None:
        self.assertEqual(self.verdict(b"A" * 24_574 + b"=="), "ok")
        self.assertEqual(self.verdict(b"A" * 24_575 + b"="), "ok")
        self.assertEqual(self.verdict(b"A" * 24_573 + b"==="), "alphabet")

    def test_canonical_trailing_bits_are_not_part_of_the_rule(self) -> None:
        # The contract keeps the text inert; it does not require the one encoding of the bytes.
        self.assertEqual(self.verdict(b"Zh=="), "ok")
        with self.assertRaises(ToolError):  # the decoder is stricter, and plan uses both
            pl.plan_from_stored(b"Zh==", "a/b", Encoding.BASE64)


class GoldenCasesTest(unittest.TestCase):
    def test_every_case_has_the_verdict_its_author_intended(self) -> None:
        for case in golden_attest.CASES:
            with self.subTest(case.name):
                expected = (case.expect, case.chunk if case.expect == "alphabet" else 0)
                self.assertEqual(golden_attest.verdict(golden_attest.text_of(case)), expected)

    def test_the_cases_cover_the_failure_modes(self) -> None:
        kinds = {c.expect for c in golden_attest.CASES}
        self.assertEqual(kinds, {"ok", "alphabet", "length"})
        names = {c.name for c in golden_attest.CASES}
        for needed in (
            "two-pads-straddle-chunks", "one-pad-alone-in-the-last-chunk", "url-safe-minus",
            "bad-byte-in-the-second-chunk", "bad-byte-in-the-third-chunk", "high-bit",
            "length-is-checked-before-the-alphabet", "three-full-chunks",
        ):
            self.assertIn(needed, names)
        chunks = {c.chunk for c in golden_attest.CASES if c.expect == "alphabet"}
        self.assertEqual(chunks, {0, 1, 2})

    def test_the_committed_attest_section_is_current(self) -> None:
        from tools.content import golden

        document = json.loads(golden.VECTORS_PATH.read_text(encoding="utf-8"))
        self.assertEqual(golden_attest.check_document(document["attest"]), [])


class PlanRefusesBadBase64Test(unittest.TestCase):
    def test_a_stored_stream_that_would_fail_on_chain_is_refused_before_anything_is_emitted(self) -> None:
        cases = {
            b"QU-J": "ContentBase64Invalid at chunk 0",
            b"QQ=A": "ContentBase64Invalid at chunk 0",
            b"QUJDQ": "ContentBase64LengthInvalid",
            b"A" * 24_575 + b"$": "ContentBase64Invalid at chunk 1",
        }
        for text, message in cases.items():
            for encoding in (Encoding.BASE64, Encoding.GZIP_BASE64):
                with self.subTest(text[:8], encoding=encoding.label):
                    with self.assertRaisesRegex(ToolError, message):
                        pl.plan_from_stored(text, "a/b", encoding)

    def test_identity_and_gzip_streams_are_not_held_to_the_base64_rule(self) -> None:
        pl.plan_from_stored(b"not base64 at all!", "a/b", Encoding.IDENTITY)

    def test_the_tools_own_base64_output_always_passes(self) -> None:
        for media in (b"x", b"xy", b"xyz", counter_bytes(1, 30_000), bytes(range(256)) * 50):
            for encoding in (Encoding.BASE64, Encoding.GZIP_BASE64):
                pl.plan_from_media(media, "a/b", encoding)

    def test_check_stored_catches_a_tampered_manifest_stream(self) -> None:
        plan = pl.plan_from_media(b"hello 6529 base64", "a/b", Encoding.BASE64)
        manifest = manifest_for(plan)
        broken = plan.stored[:-4] + b"-AA="  # same length, a byte outside the alphabet
        with self.assertRaisesRegex(ToolError, "ContentBase64Invalid|does not match"):
            pl.check_stored(manifest, broken)
        # With chunk hashes matching, the rule itself is what refuses it.
        bad_plan = pl.Plan(
            plan.mime_type, plan.encoding, plan.media_sha256, plan.media_length, broken,
            tuple(pl.chunk_hash(c) for c in pl.split_chunks(broken)),
            pl.manifest_id(
                [pl.chunk_hash(c) for c in pl.split_chunks(broken)], len(broken), plan.encoding,
                plan.mime_type, plan.media_sha256,
            ),
            False,
        )
        with self.assertRaisesRegex(ToolError, "ContentBase64Invalid"):
            pl.check_stored(manifest_for(bad_plan), broken)


class AttestCallsTest(unittest.TestCase):
    def build(self, media: bytes, encoding: Encoding, **kwargs):
        plan = pl.plan_from_media(media, "text/plain", encoding)
        return plan, calls.build_calls(manifest_for(plan), plan.stored, **kwargs)

    def test_attest_calls_come_last_for_both_base64_encodings(self) -> None:
        for encoding in (Encoding.BASE64, Encoding.GZIP_BASE64):
            for register in ("first", "last"):
                with self.subTest(encoding=encoding.label, register=register):
                    plan, built = self.build(counter_bytes(1, 40_000), encoding, register=register)
                    names = [c.name for c in built]
                    self.assertEqual(names[-1], "attestBase64")
                    self.assertEqual(names.count("attestBase64"), 1)
                    self.assertEqual(names.count("registerManifest"), 1)
                    attest = built[-1]
                    self.assertEqual(attest.data, abi.encode_call(abi.ATTEST_BASE64, plan.file_id))
                    self.assertEqual(len(attest.data), 36)
                    self.assertEqual(attest.data[:4].hex(), "0cecb241")
                    self.assertEqual(attest.filename.split("-")[1], "attestBase64")

    def test_identity_and_gzip_files_get_no_attest_call(self) -> None:
        for encoding in (Encoding.IDENTITY, Encoding.GZIP):
            _, built = self.build(counter_bytes(2, 40_000), encoding)
            self.assertNotIn("attestBase64", [c.name for c in built])

    def test_the_call_count_is_ceil_of_chunks_over_48(self) -> None:
        for chunks, expected in ((1, 1), (47, 1), (48, 1), (49, 2), (96, 2), (97, 3), (512, 11)):
            with self.subTest(chunks=chunks):
                built = self._attest_only(synthetic_manifest(chunks))
                self.assertEqual([c.name for c in built], ["attestBase64"] * expected)
                self.assertEqual(expected, pl.attest_call_count(chunks))

    def test_calls_partition_the_chunks_in_order(self) -> None:
        manifest = synthetic_manifest(100)
        built = self._attest_only(manifest)
        ranges = [(c.chunk_indexes[0], c.chunk_indexes[-1]) for c in built]
        self.assertEqual(ranges, [(0, 47), (48, 95), (96, 99)])
        flat = [i for c in built for i in c.chunk_indexes]
        self.assertEqual(flat, list(range(100)))
        self.assertTrue(all(len(c.chunk_indexes) <= 48 for c in built))

    def _attest_only(self, manifest: pl.Manifest) -> list[calls.CallPlan]:
        """The attest calls for a manifest, skipping the bytes proof (there are no bytes)."""
        from unittest import mock

        with mock.patch.object(calls, "check_stored"), mock.patch.object(calls, "split_chunks") as split:
            split.return_value = [b""] * len(manifest.chunk_hashes)
            return calls.build_calls(
                manifest, b"", skip_register=True, present_chunk_hashes=manifest.chunk_hashes
            )

    def test_every_attest_call_fits_the_cap_with_margin(self) -> None:
        for chunks in (1, 11, 48, 49, 96, 97, 512):
            for c in self._attest_only(synthetic_manifest(chunks)):
                with self.subTest(chunks=chunks, call=c.index):
                    self.assertTrue(c.estimate.within_cap)
                    self.assertTrue(c.estimate.has_margin, c.estimate)
                    self.assertLessEqual(c.gas_limit, gas.TX_GAS_CAP)
                    self.assertGreaterEqual(c.gas_limit, c.estimate.transaction)

    def test_the_largest_attest_call_is_about_half_the_cap(self) -> None:
        full = self._attest_only(synthetic_manifest(48))[0]
        self.assertLess(full.estimate.transaction, gas.TX_GAS_CAP * 55 // 100)
        self.assertGreater(full.estimate.transaction, gas.TX_GAS_CAP * 50 // 100)

    def test_the_gas_model_covers_the_measured_calls(self) -> None:
        # Measured on ContentStore (cold, distinct chunks): execution gas.
        for chunks, measured in ((1, 222_944), (5, 924_557), (11, 1_976_847), (24, 4_256_640), (48, 8_466_024)):
            with self.subTest(chunks=chunks):
                self.assertGreaterEqual(gas.attest_execution(chunks), measured)
                self.assertLess(gas.attest_execution(chunks), int(measured * 1.55))
        # The worst call also reads the file's last chunk cold to find the padding.
        self.assertGreaterEqual(gas.attest_execution(48), 8_485_707)
        with self.assertRaises(ValueError):
            gas.attest_execution(49)
        with self.assertRaises(ValueError):
            gas.attest_execution(0)

    def test_no_attest_and_skip_attest(self) -> None:
        _, built = self.build(counter_bytes(3, 40_000), Encoding.BASE64, attest=False)
        self.assertNotIn("attestBase64", [c.name for c in built])
        _, built = self.build(counter_bytes(3, 40_000), Encoding.BASE64, skip_attest=True)
        self.assertNotIn("attestBase64", [c.name for c in built])

    def test_a_bad_base64_stream_is_refused_before_any_call(self) -> None:
        plan = pl.plan_from_media(b"hello hello hello", "a/b", Encoding.BASE64)
        broken = b"!" + plan.stored[1:]
        hashes = tuple(pl.chunk_hash(c) for c in pl.split_chunks(broken))
        manifest = pl.Manifest(
            pl.manifest_id(hashes, len(broken), Encoding.BASE64, "a/b", plan.media_sha256), "a/b",
            Encoding.BASE64, plan.media_sha256, None, len(broken), None, hashes, None,
        )
        with self.assertRaisesRegex(ToolError, "ContentBase64Invalid at chunk 0"):
            calls.build_calls(manifest, broken)

    def test_script_and_document_describe_the_attest_calls(self) -> None:
        plan, built = self.build(counter_bytes(4, 70_000), Encoding.BASE64)
        script = calls.render_script(built, plan.file_id, STORE_ADDRESS)
        self.assertIn("attestBase64, chunks 0 to ", script)
        sends = [line for line in script.splitlines() if line.startswith("cast send")]
        self.assertEqual(len(sends), len(built))
        self.assertIn("attestBase64", sends[-1])
        doc = calls.calls_document(
            built, plan.file_id, STORE_ADDRESS, skipped_register=False, skipped_chunks=0
        )
        last = doc["transactions"][-1]
        self.assertEqual((last["name"], last["calldataBytes"]), ("attestBase64", 36))
        self.assertEqual(doc["skipped"]["attestBase64"], False)


class VerifyAttestationTest(unittest.TestCase):
    MEDIA = counter_bytes(5, 30_000)

    def staged(self, chain: FakeChain, encoding: Encoding = Encoding.BASE64) -> pl.Plan:
        plan = pl.plan_from_media(self.MEDIA, "image/png", encoding)
        chain.store.register(plan)
        chain.store.upload(plan)
        return plan

    def verify(self, chain: FakeChain, plan: pl.Plan, *extra: str) -> tuple[int, str, str]:
        return run(
            "verify", "--rpc", chain.url, "--store", STORE, "0x" + plan.file_id.hex(), "-q", *extra
        )

    def test_attested_and_not_attested(self) -> None:
        with FakeChain() as chain:
            plan = self.staged(chain)
            code, out, _ = self.verify(chain, plan, "--json")
            report = json.loads(out)
            self.assertEqual(code, 0)
            self.assertEqual(
                (report["base64Attested"], report["attestCallsNeeded"], report["base64TextValid"]),
                (False, 1, True),
            )
            code, out, _ = self.verify(chain, plan)
            self.assertIn("NOT ATTESTED", out)
            self.assertIn("1 call(s)", out)
            self.assertIn("result        OK", out)  # the bytes are fine; attestation is separate

            chain.store.attest(plan.file_id)
            code, out, _ = self.verify(chain, plan)
            self.assertEqual(code, 0)
            self.assertIn("attested: a renderer will inline this file", out)
            self.assertIn("passes the attestation rule", out)
            report = json.loads(self.verify(chain, plan, "--json")[1])
            self.assertEqual((report["base64Attested"], report["attestCallsNeeded"]), (True, None))

    def test_the_number_of_calls_needed_follows_the_chunk_count(self) -> None:
        # Registered but not uploaded: the count comes from the manifest, so no bytes are needed.
        for chunks, expected in ((1, 1), (48, 1), (49, 2), (100, 3)):
            manifest = synthetic_manifest(chunks)
            with self.subTest(chunks=chunks), FakeChain() as chain:
                chain.store.files[manifest.file_id] = {
                    "sha256": manifest.media_sha256, "length": manifest.stored_length,
                    "encoding": 2, "mime": "a/b", "chunks": list(manifest.chunk_hashes),
                }
                _, out, _ = run(
                    "verify", "--rpc", chain.url, "--store", STORE, "0x" + manifest.file_id.hex(),
                    "-q", "--json",
                )
                report = json.loads(out)
                self.assertEqual(report["attestCallsNeeded"], expected)
                self.assertEqual(report["missingChunks"], list(range(chunks)))

    def test_require_attested_changes_the_exit_code(self) -> None:
        with FakeChain() as chain:
            plan = self.staged(chain)
            code, _, err = self.verify(chain, plan, "--require-attested")
            self.assertEqual(code, 1)
            self.assertIn("not attested", err)
            chain.store.attest(plan.file_id)
            self.assertEqual(self.verify(chain, plan, "--require-attested")[0], 0)

    def test_files_that_are_not_base64_have_no_attestation_status(self) -> None:
        for encoding in (Encoding.IDENTITY, Encoding.GZIP):
            with self.subTest(encoding=encoding.label), FakeChain() as chain:
                plan = self.staged(chain, encoding)
                code, out, _ = self.verify(chain, plan, "--json", "--require-attested")
                report = json.loads(out)
                self.assertEqual(code, 0)  # nothing to attest, so nothing is required
                self.assertEqual(
                    (report["base64Attested"], report["base64TextValid"], report["attestCallsNeeded"]),
                    (None, None, None),
                )
                self.assertNotIn("attest", self.verify(chain, plan)[1].lower())

    def test_a_store_without_attestation_is_reported_as_such(self) -> None:
        with FakeChain() as chain:
            chain.store.supports_attest = False
            plan = self.staged(chain)
            code, out, _ = self.verify(chain, plan)
            self.assertEqual(code, 0)
            self.assertIn("attestation not available on this store", out)
            self.assertEqual(self.verify(chain, plan, "--require-attested")[0], 1)

    def test_a_text_that_would_fail_attestation_is_a_problem(self) -> None:
        # Registered and uploaded as Base64, but the bytes are not base64: the manifest is
        # consistent (the file ID commits to these bytes), so only the rule catches it.
        text = b"QU-JQUJD"
        digest = bytes([9] * 32)
        hashes = (pl.chunk_hash(text),)
        file_id = pl.manifest_id(hashes, len(text), Encoding.BASE64, "a/b", digest)
        with FakeChain() as chain:
            chain.store.files[file_id] = {
                "sha256": digest, "length": len(text), "encoding": 2, "mime": "a/b",
                "chunks": list(hashes),
            }
            chain.store.write_chunk(text)
            code, out, _ = run(
                "verify", "--rpc", chain.url, "--store", STORE, "0x" + file_id.hex(), "-q", "--json"
            )
        report = json.loads(out)
        self.assertEqual(code, 1)
        self.assertFalse(report["base64TextValid"])
        problems = " ".join(report["problems"])
        self.assertIn("ContentBase64Invalid at chunk 0", problems)

    def test_attested_on_chain_but_rejected_here_is_a_contradiction(self) -> None:
        text = b"QU-JQUJD"
        digest = bytes([9] * 32)
        hashes = (pl.chunk_hash(text),)
        file_id = pl.manifest_id(hashes, len(text), Encoding.BASE64, "a/b", digest)
        with FakeChain() as chain:
            chain.store.files[file_id] = {
                "sha256": digest, "length": len(text), "encoding": 2, "mime": "a/b",
                "chunks": list(hashes),
            }
            chain.store.write_chunk(text)
            chain.store.attested.add(file_id)  # a lying or different store
            _, out, _ = run(
                "verify", "--rpc", chain.url, "--store", STORE, "0x" + file_id.hex(), "-q", "--json"
            )
        self.assertIn("reports this file as attested", " ".join(json.loads(out)["problems"]))


class CallsCommandAttestTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def plan(self, encoding: str, media: bytes) -> Path:
        source = self.dir / "art.bin"
        source.write_bytes(media)
        manifest = self.dir / "m.json"
        code, _, err = run(
            "plan", str(source), "--mime", "text/plain", "--encoding", encoding, "-o", str(manifest)
        )
        self.assertEqual(code, 0, err)
        return manifest

    def test_calls_emits_the_attest_transactions_and_says_so(self) -> None:
        manifest = self.plan("base64", counter_bytes(7, 30_000))
        code, out, err = run("calls", str(manifest), "--store", STORE, "--json")
        self.assertEqual(code, 0, err)
        names = [t["name"] for t in json.loads(out)["transactions"]]
        self.assertEqual(names, ["registerManifest", "writeChunk", "writeChunk", "attestBase64"])
        self.assertIn("1 attestBase64 call(s) come last", err)

    def test_no_attest_flag(self) -> None:
        manifest = self.plan("gzipbase64", counter_bytes(8, 40_000))
        code, out, _ = run("calls", str(manifest), "--store", STORE, "--json", "--no-attest")
        self.assertEqual(code, 0)
        self.assertNotIn("attestBase64", [t["name"] for t in json.loads(out)["transactions"]])

    def test_identity_files_are_unchanged(self) -> None:
        manifest = self.plan("identity", counter_bytes(9, 40_000))
        _, out, _ = run("calls", str(manifest), "--store", STORE, "--json")
        self.assertNotIn("attestBase64", [t["name"] for t in json.loads(out)["transactions"]])

    def test_only_missing_asks_the_chain_whether_the_file_is_attested(self) -> None:
        media = counter_bytes(10, 40_000)
        manifest = self.plan("base64", media)
        plan = pl.plan_from_media(media, "text/plain", Encoding.BASE64)
        with FakeChain() as chain:
            chain.store.register(plan)
            chain.store.upload(plan)
            args = (
                "calls", str(manifest), "--store", STORE, "--rpc", chain.url, "--only-missing",
                "--json", "--force",
            )
            _, out, _ = run(*args)
            document = json.loads(out)
            self.assertEqual([t["name"] for t in document["transactions"]], ["attestBase64"])
            self.assertFalse(document["skipped"]["attestBase64"])

            chain.store.attest(plan.file_id)
            _, out, _ = run(*args)
            document = json.loads(out)
            self.assertEqual(document["transactions"], [])
            self.assertTrue(document["skipped"]["attestBase64"])

    def test_only_missing_against_a_store_without_attestation_warns_and_omits(self) -> None:
        media = counter_bytes(11, 40_000)
        manifest = self.plan("base64", media)
        with FakeChain() as chain:
            chain.store.supports_attest = False
            code, out, err = run(
                "calls", str(manifest), "--store", STORE, "--rpc", chain.url, "--only-missing",
                "--json",
            )
        self.assertEqual(code, 0, err)
        self.assertIn("no attestBase64", err)
        self.assertNotIn("attestBase64", [t["name"] for t in json.loads(out)["transactions"]])

    def test_a_store_with_a_different_attest_batch_size_is_refused(self) -> None:
        manifest = self.plan("base64", counter_bytes(12, 40_000))
        with FakeChain() as chain:
            original = chain.store.call

            def different(data: bytes) -> bytes:
                if data[:4] == abi.ATTEST_CHUNKS_PER_CALL:
                    return abi.uint_word(100)
                return original(data)

            chain.store.call = different  # type: ignore[method-assign]
            code, _, err = run(
                "calls", str(manifest), "--store", STORE, "--rpc", chain.url, "--only-missing"
            )
        self.assertEqual((code, "ATTEST_CHUNKS_PER_CALL is 100" in err), (2, True))


if __name__ == "__main__":
    unittest.main()
