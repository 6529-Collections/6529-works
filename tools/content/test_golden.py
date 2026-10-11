"""Golden vector tests.

The vectors in `golden/vectors.json` are the contract between this tooling and `ContentStore`:
`test/content/tooling/UploaderGolden.t.sol` loads the same values (through the generated
`UploaderGoldenData.sol`) and asserts a real store reproduces them. These tests assert the Python
side and that nothing committed is stale.
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import io
import json
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

from tools.content import abi, golden
from tools.content import plan as pl
from tools.content.cli import main
from tools.content.encoding import Encoding, decode, encode
from tools.content.golden import GOLDEN_DIR, SPECS, counter_bytes

ZLIB_IS_STOCK = "zlib-ng" not in zlib.ZLIB_RUNTIME_VERSION.lower()


def document() -> dict:
    return json.loads(golden.VECTORS_PATH.read_text(encoding="utf-8"))


class CommittedFilesTest(unittest.TestCase):
    def test_vectors_samples_and_solidity_data_are_consistent_and_fresh(self) -> None:
        self.assertEqual(golden.check(), [])

    def test_cli_check_passes(self) -> None:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(main(["golden", "--check"]), 0)
        self.assertIn("consistent", out.getvalue())

    def test_stale_solidity_data_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            stale = Path(tmp) / "Stale.sol"
            stale.write_text("// not the generated file\n", encoding="utf-8")
            with mock.patch.object(golden, "SOLIDITY_PATH", stale):
                problems = golden.check()
        self.assertTrue(any("stale" in p for p in problems), problems)

    def test_changed_expected_values_are_detected(self) -> None:
        doc = document()
        doc["vectors"][0]["fileId"] = "0x" + "00" * 32
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "vectors.json"
            bad.write_text(json.dumps(doc), encoding="utf-8")
            with mock.patch.object(golden, "VECTORS_PATH", bad):
                problems = golden.check()
        self.assertTrue(any("file ID" in p for p in problems), problems)

    def test_rendering_is_deterministic(self) -> None:
        doc = document()
        streams = golden.committed_streams(doc)
        self.assertEqual(golden.render_solidity(doc, streams), golden.render_solidity(doc, streams))


class CoverageTest(unittest.TestCase):
    def test_a_small_sample_exists_for_every_encoding(self) -> None:
        sample_encodings = {s.encoding for s in SPECS if s.sample is not None}
        self.assertEqual(sample_encodings, set(Encoding))

    def test_multi_chunk_cases_exist_for_every_encoding(self) -> None:
        counts: dict[Encoding, int] = {}
        for v in document()["vectors"]:
            if len(v["chunkHashes"]) > 1:
                counts[Encoding(v["encodingId"])] = max(
                    counts.get(Encoding(v["encodingId"]), 0), len(v["chunkHashes"])
                )
        self.assertEqual(set(counts), set(Encoding))

    def test_the_layout_edges_are_covered(self) -> None:
        by_name = {v["name"]: v for v in document()["vectors"]}
        self.assertEqual(by_name["exact-one-chunk"]["storedLength"], pl.CHUNK_SIZE)
        self.assertEqual(len(by_name["exact-one-chunk"]["chunkHashes"]), 1)
        self.assertEqual(by_name["one-chunk-plus-one"]["storedLength"], pl.CHUNK_SIZE + 1)
        self.assertEqual(len(by_name["one-chunk-plus-one"]["chunkHashes"]), 2)
        self.assertEqual(len(by_name["exact-two-chunks"]["chunkHashes"]), 2)
        self.assertGreater(by_name["multichunk-identity"]["storedLength"], pl.CHUNK_SIZE)

    def test_file_ids_and_hashes_are_unique_across_vectors(self) -> None:
        vectors = document()["vectors"]
        self.assertEqual(len({v["fileId"] for v in vectors}), len(vectors))


class VectorValuesTest(unittest.TestCase):
    """Re-derive each vector from its inputs, independent of the zlib in use."""

    def test_each_vector_re_derives_from_its_inputs(self) -> None:
        doc = document()
        streams = golden.committed_streams(doc)
        for spec, v in zip(SPECS, doc["vectors"]):
            with self.subTest(v["name"]):
                media = golden._media(spec)
                stored = golden.stored_stream(v, media, streams)
                self.assertEqual(decode(stored, spec.encoding), media)
                self.assertEqual(v["mediaSha256"], "0x" + hashlib.sha256(media).hexdigest())
                chunks = pl.split_chunks(stored)
                self.assertEqual(v["chunkHashes"], ["0x" + pl.chunk_hash(c).hex() for c in chunks])
                self.assertEqual(
                    v["fileId"],
                    "0x"
                    + pl.manifest_id(
                        [pl.chunk_hash(c) for c in chunks], len(stored), spec.encoding,
                        spec.mime_type, hashlib.sha256(media).digest(),
                    ).hex(),
                )
                self.assertEqual(
                    v["registerCalldata"],
                    "0x"
                    + abi.encode_register_manifest(
                        [pl.chunk_hash(c) for c in chunks], len(stored), int(spec.encoding),
                        spec.mime_type, hashlib.sha256(media).digest(),
                    ).hex(),
                )

    def test_the_generator_matches_the_solidity_helper(self) -> None:
        # ContentBase._data: word i is keccak256(abi.encode(seed, 32 * i)), truncated.
        data = counter_bytes(5, 70)
        self.assertEqual(len(data), 70)
        first = pl.keccak256((5).to_bytes(32, "big") + (0).to_bytes(32, "big"))
        second = pl.keccak256((5).to_bytes(32, "big") + (32).to_bytes(32, "big"))
        self.assertEqual(data[:32], first)
        self.assertEqual(data[32:64], second)
        self.assertEqual(counter_bytes(5, 64), data[:64])

    def test_base64_vectors_store_the_canonical_text(self) -> None:
        for spec in SPECS:
            if spec.encoding == Encoding.BASE64:
                with self.subTest(spec.name):
                    media = golden._media(spec)
                    self.assertEqual(encode(media, spec.encoding), base64.b64encode(media))


@unittest.skipUnless(ZLIB_IS_STOCK, "zlib-ng and other zlib forks do not reproduce stock deflate output")
class GzipReproductionTest(unittest.TestCase):
    """The committed gzip streams are what this machine's encoder produces now.

    Deflate output depends on the zlib implementation. Stock zlib has been stable across releases
    for these settings; if this fails on a new platform, the encoder's reproducibility claim is
    platform-dependent there, and the committed stream (which is what the file ID commits to)
    is the source of truth.
    """

    def test_encoder_reproduces_the_committed_streams(self) -> None:
        doc = document()
        streams = golden.committed_streams(doc)
        checked = 0
        for spec, v in zip(SPECS, doc["vectors"]):
            if spec.encoding.uses_gzip:
                with self.subTest(v["name"]):
                    self.assertEqual(encode(golden._media(spec), spec.encoding), streams[golden.stored_file_name(v["name"])])
                    checked += 1
        self.assertEqual(checked, 4)

    def test_cli_plan_reproduces_each_sample_file_id(self) -> None:
        doc = document()
        for spec, v in zip(SPECS, doc["vectors"]):
            if spec.sample is None:
                continue
            with self.subTest(v["name"]), tempfile.TemporaryDirectory() as tmp:
                out = io.StringIO()
                manifest = Path(tmp) / "m.json"
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                    code = main([
                        "plan", str(GOLDEN_DIR / "samples" / spec.sample), "--mime", spec.mime_type,
                        "--encoding", spec.encoding.label, "-o", str(manifest),
                    ])
                self.assertEqual(code, 0)
                data = json.loads(manifest.read_text(encoding="utf-8"))
                self.assertEqual(data["fileId"], v["fileId"])
                self.assertEqual(data["chunkHashes"], v["chunkHashes"])
                self.assertEqual(data["mediaSha256"], v["mediaSha256"])


if __name__ == "__main__":
    unittest.main()
