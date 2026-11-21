"""Unit tests for make_vectors.py, which sits beside this file.

Run with `python -m unittest tools.test_make_vectors` from the repository root, or
`python tools/test_make_vectors.py`.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_SPEC = importlib.util.spec_from_file_location(
    "make_vectors", Path(__file__).with_name("make_vectors.py")
)
mv = importlib.util.module_from_spec(_SPEC)
sys.modules["make_vectors"] = mv
_SPEC.loader.exec_module(mv)


def _event(name: str, *inputs: dict) -> dict:
    return {"type": "event", "name": name, "inputs": list(inputs), "anonymous": False}


class EventTopicsTest(unittest.TestCase):
    def test_signature_expands_tuples_and_arrays(self) -> None:
        payee = {
            "type": "tuple[]",
            "components": [{"type": "uint256"}, {"type": "address"}, {"type": "uint32"}],
        }
        abi = [
            _event(
                "WalletCreated",
                {"type": "address"},
                {"type": "bytes32"},
                {"type": "bytes32"},
                payee,
            ),
            _event("Transfer", {"type": "address"}, {"type": "address"}, {"type": "uint256"}),
            {"type": "function", "name": "f", "inputs": []},
        ]
        self.assertEqual(
            mv.event_signatures(abi),
            [
                "Transfer(address,address,uint256)",
                "WalletCreated(address,bytes32,bytes32,(uint256,address,uint32)[])",
            ],
        )

    def test_nested_tuple(self) -> None:
        inner = {"type": "tuple", "components": [{"type": "uint16"}, {"type": "bytes32"}]}
        outer = {"type": "tuple", "components": [{"type": "string"}, inner]}
        self.assertEqual(mv.canonical_type(outer), "(string,(uint16,bytes32))")

    def test_topic0_is_keccak_of_the_signature(self) -> None:
        # ERC-721 Transfer, the known topic0.
        self.assertEqual(
            mv.hex0x(mv.keccak256(b"Transfer(address,address,uint256)")),
            "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        )

    def test_missing_artifact_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(mv.VectorError):
                mv.build_topics(Path(tmp))


class HelpersTest(unittest.TestCase):
    def test_git_blob_id_of_the_empty_blob(self) -> None:
        self.assertEqual(mv.git_blob_id(b""), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")

    def test_webp_sizes(self) -> None:
        size = (99).to_bytes(3, "little") + (49).to_bytes(3, "little")
        vp8x = b"RIFF\0\0\0\0WEBPVP8X" + b"\x0a\0\0\0" + b"\0\0\0\0" + size
        self.assertEqual(mv.webp_size(vp8x), (100, 50))
        size = (640).to_bytes(2, "little") + (480).to_bytes(2, "little")
        vp8 = b"RIFF\0\0\0\0WEBPVP8 " + b"\0" * 10 + size
        self.assertEqual(mv.webp_size(vp8), (640, 480))
        bits = (31) | (15 << 14)
        vp8l = b"RIFF\0\0\0\0WEBPVP8L" + b"\0\0\0\0\x2f" + bits.to_bytes(4, "little")
        self.assertEqual(mv.webp_size(vp8l), (32, 16))
        with self.assertRaises(mv.VectorError):
            mv.webp_size(b"\x89PNG\r\n\x1a\n" + b"\0" * 32)

    def test_typehashes_match_the_contract_source(self) -> None:
        source = (mv.ROOT / "src" / "records" / "StatementLog.sol").read_text(encoding="utf-8")
        strings = re.findall(r'keccak256\(\s*"([^"]+)"\s*\)', source)
        self.assertIn(mv.HASHREF_TYPEHASH, [mv.keccak256(s.encode()) for s in strings])
        self.assertIn(mv.STATEMENT_TYPEHASH, [mv.keccak256(s.encode()) for s in strings])


class VectorsTest(unittest.TestCase):
    def test_committed_vectors_reproduce(self) -> None:
        source, files = mv.read_committed_inputs()
        built = mv.dump(mv.build_vectors(source, files))
        self.assertEqual(built, mv.VECTORS.read_text(encoding="utf-8"))

    def test_canonical_payload_reproduces_the_envelope_digest(self) -> None:
        source, files = mv.read_committed_inputs()
        work = json.loads(files[source["records"]["work"]["file"]])
        digest = mv.keccak256(mv.canonical_json(work["payload"]))
        self.assertEqual(mv.hex0x(digest), work["envelope"]["contentHash"]["digest"])

    def test_a_changed_input_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "museum"
            shutil.copytree(mv.INPUTS, copy)
            record = copy / "6529NM-W-0029.json"
            record.write_bytes(record.read_bytes().replace(b"Themes", b"Themas", 1))
            inputs = mock.patch.object(mv, "INPUTS", copy)
            with inputs, mock.patch.object(mv, "SOURCE", copy / "source.json"):
                with self.assertRaises(mv.VectorError):
                    mv.read_committed_inputs()

    def test_a_payload_that_does_not_match_its_envelope_is_refused(self) -> None:
        source, files = mv.read_committed_inputs()
        name = source["records"]["work"]["file"]
        work = json.loads(files[name])
        work["payload"]["record_id"] = "6529NM-W-9999"
        files = dict(files, **{name: json.dumps(work).encode()})
        with self.assertRaises(mv.VectorError):
            mv.build_vectors(source, files)

    def test_check_reports_a_stale_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            stale = Path(tmp) / "museum-work.json"
            stale.write_text("{}\n", encoding="utf-8")
            topics = Path(tmp) / "event-topics.json"
            topics.write_text(mv.TOPICS.read_text(encoding="utf-8"), encoding="utf-8")
            out = io.StringIO()
            with (
                mock.patch.object(mv, "VECTORS", stale),
                mock.patch.object(mv, "TOPICS", topics),
                mock.patch.object(mv, "build_topics", lambda _: json.loads(topics.read_text())),
                mock.patch.object(mv, "ROOT", Path(tmp)),
                contextlib.redirect_stdout(out),
            ):
                self.assertEqual(mv.main(["--check"]), 1)
                self.assertEqual(stale.read_text(encoding="utf-8"), "{}\n", "check writes nothing")
            self.assertIn("differs", out.getvalue())


if __name__ == "__main__":
    unittest.main()
