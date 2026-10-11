"""End-to-end tests of the command line against an in-memory store behind a local JSON-RPC server.

The fake store models the contract's reads (see `fake_chain.py`); the real contract is covered by
the Foundry golden test and `test_anvil.py`.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

from tools.content import abi, calls
from tools.content import plan as pl
from tools.content import verify as verify_module
from tools.content.address import checksum_address
from tools.content.cli import main
from tools.content.encoding import Encoding
from tools.content.errors import RpcError, ToolError
from tools.content.fake_chain import STORE_ADDRESS, FakeChain
from tools.content.golden import counter_bytes
from tools.content.rpc import JsonRpc

STORE = checksum_address(STORE_ADDRESS)
MEDIA = (b"6529 Works " * 1500) + counter_bytes(11, 20_000)


def run(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = main(list(argv))
    return code, out.getvalue(), err.getvalue()


class TempDirCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self._saved = os.environ.get("NO_PROXY")
        os.environ["NO_PROXY"] = "127.0.0.1"
        self.addCleanup(self._restore_env)

    def _restore_env(self) -> None:
        if self._saved is None:
            os.environ.pop("NO_PROXY", None)
        else:
            os.environ["NO_PROXY"] = self._saved

    def media_file(self, name: str = "art.bin", data: bytes = MEDIA) -> Path:
        path = self.dir / name
        path.write_bytes(data)
        return path


class PlanCommandTest(TempDirCase):
    def test_plan_writes_manifest_and_stored_stream(self) -> None:
        source = self.media_file()
        code, out, err = run(
            "plan", str(source), "--mime", "text/plain", "--encoding", "gzip",
            "-o", str(self.dir / "m.json"),
        )
        self.assertEqual(code, 0, err)
        manifest = json.loads((self.dir / "m.json").read_text(encoding="utf-8"))
        expected = pl.plan_from_media(MEDIA, "text/plain", Encoding.GZIP)
        self.assertEqual(manifest["fileId"], "0x" + expected.file_id.hex())
        self.assertEqual((self.dir / manifest["storedFile"]).read_bytes(), expected.stored)
        self.assertEqual(manifest["storedFile"], "m.stored")
        self.assertIn("0x" + expected.file_id.hex(), out)
        self.assertIn("reproducible  yes", out)
        self.assertIn("publish the stored stream", err)

    def test_identity_beside_the_input_needs_no_copy(self) -> None:
        source = self.media_file("art.png")
        code, _, err = run("plan", str(source), "--mime", "image/png", "--encoding", "identity")
        self.assertEqual(code, 0, err)
        manifest = json.loads((self.dir / "art.png.content.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["storedFile"], "art.png")
        self.assertEqual([p.name for p in self.dir.iterdir()], ["art.png", "art.png.content.json"])

    def test_refuses_to_overwrite_without_force(self) -> None:
        source = self.media_file()
        args = ["plan", str(source), "--mime", "text/plain", "--encoding", "base64"]
        self.assertEqual(run(*args)[0], 0)
        code, _, err = run(*args)
        self.assertEqual(code, 2)
        self.assertIn("already exists", err)
        self.assertEqual(run(*args, "--force")[0], 0)

    def test_oversize_file_is_refused_cleanly(self) -> None:
        source = self.media_file("big.bin", bytes(pl.MAX_STORED_BYTES + 1))
        code, out, err = run("plan", str(source), "--mime", "a/b", "--encoding", "identity")
        self.assertEqual(code, 2)
        self.assertIn("at most 12,582,400 bytes", err)
        self.assertEqual(out, "")
        self.assertEqual([p.name for p in self.dir.iterdir()], ["big.bin"])

    def test_the_input_limit_depends_on_the_encoding(self) -> None:
        source = self.media_file("big.bin", bytes(pl.MAX_STORED_BYTES // 4 * 3 + 1))
        code, _, err = run("plan", str(source), "--mime", "a/b", "--encoding", "base64")
        self.assertEqual((code, "at most 9,436,800 bytes" in err), (2, True))
        # The same file is fine as gzip, which shrinks it far below the limit.
        code, _, err = run("plan", str(source), "--mime", "a/b", "--encoding", "gzip")
        self.assertEqual(code, 0, err)

    def test_a_refusal_leaves_no_partial_output(self) -> None:
        source = self.media_file()
        manifest = self.dir / "m.json"
        manifest.write_text("keep", encoding="utf-8")  # the manifest exists, the stored file does not
        code, _, err = run(
            "plan", str(source), "--mime", "a/b", "--encoding", "gzip", "-o", str(manifest)
        )
        self.assertEqual((code, "already exists" in err), (2, True))
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["art.bin", "m.json"])

    def test_invalid_input_is_refused_cleanly(self) -> None:
        source = self.media_file()
        code, _, err = run("plan", str(source), "--mime", "Text/Plain", "--encoding", "identity")
        self.assertEqual((code, "invalid MIME type" in err), (2, True))
        code, _, err = run("plan", str(self.dir / "missing"), "--mime", "a/b", "--encoding", "gzip")
        self.assertEqual((code, "cannot read" in err), (2, True))

    def test_already_encoded_stream(self) -> None:
        reference = pl.plan_from_media(MEDIA, "text/plain", Encoding.GZIP)
        stream = self.media_file("art.gz", reference.stored)
        code, _, err = run(
            "plan", str(stream), "--mime", "text/plain", "--encoding", "gzip", "--already-encoded"
        )
        self.assertEqual(code, 0, err)
        manifest = json.loads((self.dir / "art.gz.content.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["fileId"], "0x" + reference.file_id.hex())
        self.assertEqual(manifest["storedFile"], "art.gz")
        code, _, err = run(
            "plan", str(self.media_file("raw.bin")), "--mime", "text/plain", "--encoding", "gzip",
            "--already-encoded",
        )
        self.assertEqual((code, "invalid gzip" in err), (2, True))


class CallsCommandTest(TempDirCase):
    def plan(self, encoding: str = "identity", media: bytes = MEDIA) -> Path:
        source = self.media_file(data=media)
        manifest = self.dir / "m.json"
        self.assertEqual(
            run("plan", str(source), "--mime", "text/plain", "--encoding", encoding, "-o", str(manifest))[0],
            0,
        )
        return manifest

    def test_calls_writes_files_and_prints_the_script(self) -> None:
        manifest = self.plan("gzipbase64")
        code, out, err = run("calls", str(manifest), "--store", STORE)
        self.assertEqual(code, 0, err)
        out_dir = self.dir / "m.calls"
        names = sorted(p.name for p in out_dir.iterdir())
        document = json.loads((out_dir / "calls.json").read_text(encoding="utf-8"))
        self.assertEqual(document["store"], STORE)
        self.assertIn("send.sh", names)
        self.assertEqual(
            names, sorted(["send.sh", "calls.json", *[t["calldataFile"] for t in document["transactions"]]])
        )
        self.assertEqual((out_dir / "send.sh").read_text(encoding="utf-8"), out)
        self.assertIn("nothing was sent", err)
        loaded = pl.load_manifest(manifest)
        first = (out_dir / document["transactions"][0]["calldataFile"]).read_text(encoding="utf-8")
        self.assertEqual(
            first.strip(),
            "0x"
            + abi.encode_register_manifest(
                loaded.chunk_hashes, loaded.stored_length, int(loaded.encoding), loaded.mime_type,
                loaded.media_sha256,
            ).hex(),
        )

    def test_json_output_and_register_last(self) -> None:
        manifest = self.plan()
        code, out, _ = run("calls", str(manifest), "--store", STORE.lower(), "--json", "--register", "last")
        self.assertEqual(code, 0)
        document = json.loads(out)
        self.assertEqual(document["transactions"][-1]["name"], "registerManifest")
        self.assertEqual(document["schema"], calls.CALLS_SCHEMA)

    def test_refuses_a_non_empty_out_dir_and_bad_inputs(self) -> None:
        manifest = self.plan()
        self.assertEqual(run("calls", str(manifest), "--store", STORE)[0], 0)
        code, _, err = run("calls", str(manifest), "--store", STORE)
        self.assertEqual((code, "not empty" in err), (2, True))
        stale = self.dir / "m.calls" / "999-writeChunk-999.calldata"
        stale.write_text("0x00", encoding="utf-8")
        self.assertEqual(run("calls", str(manifest), "--store", STORE, "--force")[0], 0)
        self.assertFalse(stale.exists(), "a previous run's calldata file was left behind")
        code, _, err = run("calls", str(manifest), "--store", "0x1234")
        self.assertEqual((code, "20-byte address" in err), (2, True))

    def test_a_modified_stored_stream_is_refused(self) -> None:
        manifest = self.plan("gzip")
        stored = self.dir / "m.stored"
        data = bytearray(stored.read_bytes())
        data[40] ^= 0xFF
        stored.write_bytes(bytes(data))
        code, out, err = run("calls", str(manifest), "--store", STORE)
        self.assertEqual(code, 2)
        self.assertIn("does not match", err)
        self.assertEqual(out, "")
        self.assertFalse((self.dir / "m.calls").exists())

    def test_a_manifest_cannot_point_at_another_file(self) -> None:
        manifest = self.plan()
        data = json.loads(manifest.read_text(encoding="utf-8"))
        data["storedFile"] = "../secret.txt"
        manifest.write_text(json.dumps(data), encoding="utf-8")
        code, _, err = run("calls", str(manifest), "--store", STORE)
        self.assertEqual((code, "plain file name" in err), (2, True))

    def test_only_missing_skips_what_the_chain_has(self) -> None:
        media = counter_bytes(20, 40_000)
        manifest = self.plan(media=media)
        plan = pl.plan_from_media(media, "text/plain", Encoding.IDENTITY)
        self.assertEqual(len(plan.chunk_hashes), 2)
        with FakeChain() as chain:
            chain.store.write_chunk(next(plan.chunks()))  # chunk 0 is stored; nothing registered
            code, out, err = run(
                "calls", str(manifest), "--store", STORE, "--rpc", chain.url, "--only-missing", "--json"
            )
            self.assertEqual(code, 0, err)
            names = [(t["name"], t["chunkIndexes"]) for t in json.loads(out)["transactions"]]
            self.assertEqual(names, [("registerManifest", []), ("writeChunk", [1])])

            chain.store.register(plan)
            code, out, _ = run(
                "calls", str(manifest), "--store", STORE, "--rpc", chain.url, "--only-missing",
                "--json", "--force",
            )
            document = json.loads(out)
            self.assertEqual([t["name"] for t in document["transactions"]], ["writeChunk"])
            self.assertEqual(document["skipped"], {"registerManifest": True, "chunksAlreadyStored": 1})

            chain.store.upload(plan)
            code, out, err = run(
                "calls", str(manifest), "--store", STORE, "--rpc", chain.url, "--only-missing",
                "--json", "--force",
            )
            self.assertEqual(json.loads(out)["transactions"], [])
            self.assertIn("0 transaction(s)", err)

    def test_only_missing_needs_an_rpc_endpoint(self) -> None:
        manifest = self.plan()
        saved = os.environ.pop("ETH_RPC_URL", None)
        try:
            code, _, err = run("calls", str(manifest), "--store", STORE, "--only-missing")
        finally:
            if saved is not None:
                os.environ["ETH_RPC_URL"] = saved
        self.assertEqual((code, "--rpc" in err), (2, True))


class VerifyAndRebuildTest(TempDirCase):
    def staged(self, chain: FakeChain, encoding: Encoding, media: bytes = MEDIA, upload: bool = True) -> pl.Plan:
        plan = pl.plan_from_media(media, "image/png", encoding)
        chain.store.register(plan)
        if upload:
            chain.store.upload(plan)
        return plan

    def verify(self, chain: FakeChain, file_id: bytes, *extra: str) -> tuple[int, str, str]:
        return run("verify", "--rpc", chain.url, "--store", STORE, "0x" + file_id.hex(), "-q", *extra)

    def test_a_complete_file_verifies_for_every_encoding(self) -> None:
        for encoding in Encoding:
            with self.subTest(encoding=encoding.label), FakeChain() as chain:
                plan = self.staged(chain, encoding)
                code, out, err = self.verify(chain, plan.file_id)
                self.assertEqual(code, 0, out + err)
                self.assertIn("result        OK", out)
                self.assertIn("reproducible  yes", out)

    def test_json_report(self) -> None:
        with FakeChain() as chain:
            plan = self.staged(chain, Encoding.GZIP)
            code, out, _ = self.verify(chain, plan.file_id, "--json")
            report = json.loads(out)
        self.assertEqual(code, 0)
        self.assertTrue(report["ok"] and report["complete"] and report["fileIdMatches"])
        self.assertTrue(report["mediaSha256Matches"] and report["reproducible"])
        self.assertEqual(report["mediaLength"], len(MEDIA))
        self.assertEqual(report["declaredMediaSha256"], "0x" + plan.media_sha256.hex())
        self.assertEqual(report["store"], STORE)

    def test_missing_chunks_are_reported_not_read(self) -> None:
        media = counter_bytes(12, 5 * pl.CHUNK_SIZE - 10)
        with FakeChain() as chain:
            plan = self.staged(chain, Encoding.IDENTITY, media, upload=False)
            chain.store.upload(plan, only=[0, 2, 3])
            code, out, _ = self.verify(chain, plan.file_id)
            reads = [c for c in chain.store.calls if c[:4] == abi.READ_CHUNK]
        self.assertEqual(code, 1)
        self.assertIn("missing       1, 4", out)
        self.assertIn("2 missing", out)
        self.assertIn("2 chunk(s) are not stored yet", out)
        self.assertEqual(len(reads), 3)  # only the present chunks were read

    def test_nothing_uploaded_lists_every_chunk(self) -> None:
        with FakeChain() as chain:
            plan = self.staged(chain, Encoding.IDENTITY, counter_bytes(13, 60_000), upload=False)
            code, out, _ = self.verify(chain, plan.file_id, "--json")
        report = json.loads(out)
        self.assertEqual((code, report["missingChunks"], report["complete"]), (1, [0, 1, 2], False))

    def test_unknown_file_and_wrong_store(self) -> None:
        with FakeChain() as chain:
            code, out, _ = self.verify(chain, bytes([9] * 32))
            self.assertEqual(code, 1)
            self.assertIn("no manifest is registered", out)
            code, _, err = run(
                "verify", "--rpc", chain.url, "--store", "0x" + "11" * 20, "0x" + "00" * 32, "-q"
            )
            self.assertEqual((code, "no contract" in err), (2, True))

    def test_a_chunk_whose_bytes_do_not_match_its_hash_is_flagged(self) -> None:
        with FakeChain() as chain:
            plan = self.staged(chain, Encoding.IDENTITY, counter_bytes(14, 60_000))
            first = bytearray(next(plan.chunks()))
            first[0] ^= 1
            chain.store.tamper[plan.chunk_hashes[0]] = bytes(first)
            code, out, _ = self.verify(chain, plan.file_id)
        self.assertEqual(code, 1)
        self.assertIn("bad chunk     0", out)

    def test_a_wrong_declared_digest_is_caught(self) -> None:
        # An honest-looking manifest over the right chunks that declares the wrong media digest
        # has its own file ID; the bytes still do not decode to the digest it declares.
        media = counter_bytes(15, 40_000)
        real = pl.plan_from_media(media, "image/png", Encoding.IDENTITY)
        lie = bytes([0xEE] * 32)
        lying_id = pl.manifest_id(real.chunk_hashes, real.stored_length, Encoding.IDENTITY, "image/png", lie)
        with FakeChain() as chain:
            chain.store.files[lying_id] = {
                "sha256": lie, "length": real.stored_length, "encoding": 0, "mime": "image/png",
                "chunks": list(real.chunk_hashes),
            }
            chain.store.upload(real)
            code, out, _ = self.verify(chain, lying_id, "--json")
        report = json.loads(out)
        self.assertEqual(code, 1)
        self.assertTrue(report["fileIdMatches"])
        self.assertFalse(report["mediaSha256Matches"])
        self.assertIn("does not match the declared SHA-256", " ".join(report["problems"]))

    def test_a_store_that_reports_a_different_manifest_is_caught(self) -> None:
        a = pl.plan_from_media(counter_bytes(16, 1000), "image/png", Encoding.IDENTITY)
        b = pl.plan_from_media(counter_bytes(17, 1000), "image/png", Encoding.IDENTITY)
        with FakeChain() as chain:
            chain.store.register(b)
            chain.store.files[a.file_id] = chain.store.files[b.file_id]  # a's ID, b's record
            chain.store.upload(b)
            code, out, _ = self.verify(chain, a.file_id, "--json")
        report = json.loads(out)
        self.assertEqual(code, 1)
        self.assertFalse(report["fileIdMatches"])

    def test_undecodable_stored_bytes_are_reported(self) -> None:
        stored = b"this is not gzip at all"
        digest = bytes([5] * 32)
        file_id = pl.manifest_id([pl.chunk_hash(stored)], len(stored), Encoding.GZIP, "a/b", digest)
        with FakeChain() as chain:
            chain.store.files[file_id] = {
                "sha256": digest, "length": len(stored), "encoding": 1, "mime": "a/b",
                "chunks": [pl.chunk_hash(stored)],
            }
            chain.store.write_chunk(stored)
            code, out, _ = self.verify(chain, file_id, "--json")
        report = json.loads(out)
        self.assertEqual(code, 1)
        self.assertIn("do not decode as gzip", " ".join(report["problems"]))

    def test_rebuild_writes_the_decoded_media_for_every_encoding(self) -> None:
        for encoding in Encoding:
            with self.subTest(encoding=encoding.label), FakeChain() as chain:
                plan = self.staged(chain, encoding)
                out_path = self.dir / f"out-{encoding.label}.bin"
                code, out, err = run(
                    "rebuild", "--rpc", chain.url, "--store", STORE, "0x" + plan.file_id.hex(),
                    "-o", str(out_path), "-q",
                )
                self.assertEqual(code, 0, out + err)
                self.assertEqual(out_path.read_bytes(), MEDIA)
                self.assertIn("verified", out)

    def test_rebuild_can_write_the_stored_stream(self) -> None:
        with FakeChain() as chain:
            plan = self.staged(chain, Encoding.GZIP_BASE64)
            out_path = self.dir / "stored.bin"
            code, _, _ = run(
                "rebuild", "--rpc", chain.url, "--store", STORE, "0x" + plan.file_id.hex(),
                "-o", str(out_path), "--stored", "-q",
            )
        self.assertEqual(code, 0)
        self.assertEqual(out_path.read_bytes(), plan.stored)

    def test_rebuild_writes_nothing_when_the_file_does_not_verify(self) -> None:
        with FakeChain() as chain:
            plan = self.staged(chain, Encoding.IDENTITY, counter_bytes(18, 60_000), upload=False)
            chain.store.upload(plan, only=[0, 1])
            out_path = self.dir / "partial.bin"
            code, out, err = run(
                "rebuild", "--rpc", chain.url, "--store", STORE, "0x" + plan.file_id.hex(),
                "-o", str(out_path), "-q",
            )
        self.assertEqual(code, 1)
        self.assertFalse(out_path.exists())
        self.assertIn("missing", out)
        self.assertIn("nothing was written", err)

    def test_rebuild_refuses_to_overwrite(self) -> None:
        with FakeChain() as chain:
            plan = self.staged(chain, Encoding.IDENTITY)
            out_path = self.dir / "exists.bin"
            out_path.write_bytes(b"keep me")
            args = ["rebuild", "--rpc", chain.url, "--store", STORE, "0x" + plan.file_id.hex(), "-o", str(out_path), "-q"]
            code, _, err = run(*args)
            self.assertEqual((code, "already exists" in err), (2, True))
            self.assertEqual(out_path.read_bytes(), b"keep me")
            self.assertEqual(run(*args, "--force")[0], 0)
            self.assertEqual(out_path.read_bytes(), MEDIA)

    def test_a_store_with_other_layout_constants_is_refused(self) -> None:
        with FakeChain() as chain:
            original = chain.store.call

            def different(data: bytes) -> bytes:
                return abi.uint_word(1000) if data[:4] == abi.CHUNK_SIZE else original(data)

            chain.store.call = different  # type: ignore[method-assign]
            code, _, err = run("verify", "--rpc", chain.url, "--store", STORE, "0x" + "00" * 32, "-q")
        self.assertEqual((code, "CHUNK_SIZE" in err), (2, True))

    def test_a_file_that_hashes_with_a_repeated_chunk_verifies(self) -> None:
        block = counter_bytes(19, pl.CHUNK_SIZE)
        with FakeChain() as chain:
            plan = self.staged(chain, Encoding.IDENTITY, block * 3 + b"end")
            code, out, _ = self.verify(chain, plan.file_id)
        self.assertEqual(code, 0, out)


class ReportFormattingTest(unittest.TestCase):
    def test_missing_chunk_ranges(self) -> None:
        self.assertEqual(verify_module._ranges([]), "")
        self.assertEqual(verify_module._ranges([4]), "4")
        self.assertEqual(verify_module._ranges([0, 1, 2, 5, 7, 8]), "0-2, 5, 7-8")


class RpcClientTest(TempDirCase):
    def test_only_http_and_https_endpoints_are_accepted(self) -> None:
        for url in ("file:///etc/passwd", "ftp://host/", "ws://host/", "localhost:8545", "", "http://"):
            with self.subTest(url), self.assertRaises(ToolError):
                JsonRpc(url)

    def test_the_endpoint_is_never_echoed(self) -> None:
        secret = "s3cr3t-api-key"
        rpc = JsonRpc(f"http://user:{secret}@127.0.0.1:1/v2/{secret}", timeout=2)
        self.assertNotIn(secret, rpc.label)
        with self.assertRaises(RpcError) as ctx:
            rpc.get_code(STORE_ADDRESS)
        self.assertNotIn(secret, str(ctx.exception))

    def test_cli_errors_do_not_leak_the_endpoint(self) -> None:
        secret = "s3cr3t-api-key"
        code, out, err = run(
            "verify", "--rpc", f"http://127.0.0.1:1/{secret}", "--store", STORE, "0x" + "00" * 32, "-q"
        )
        self.assertEqual(code, 2)
        self.assertNotIn(secret, out + err)
        self.assertIn("cannot reach http://127.0.0.1:1", err)

    def test_missing_endpoint_is_an_error(self) -> None:
        saved = os.environ.pop("ETH_RPC_URL", None)
        try:
            code, _, err = run("verify", "--store", STORE, "0x" + "00" * 32)
        finally:
            if saved is not None:
                os.environ["ETH_RPC_URL"] = saved
        self.assertEqual((code, "ETH_RPC_URL" in err), (2, True))

    def test_the_endpoint_may_come_from_the_environment(self) -> None:
        with FakeChain() as chain:
            plan = pl.plan_from_media(b"env", "a/b", Encoding.IDENTITY)
            chain.store.register(plan)
            chain.store.upload(plan)
            os.environ["ETH_RPC_URL"] = chain.url
            try:
                code, _, _ = run("verify", "--store", STORE, "0x" + plan.file_id.hex(), "-q")
            finally:
                del os.environ["ETH_RPC_URL"]
        self.assertEqual(code, 0)

    def test_the_tool_only_issues_read_only_methods(self) -> None:
        # No method that signs or sends: eth_call, eth_getCode only.
        with FakeChain() as chain:
            plan = pl.plan_from_media(b"read only", "a/b", Encoding.IDENTITY)
            chain.store.register(plan)
            chain.store.upload(plan)
            run("verify", "--rpc", chain.url, "--store", STORE, "0x" + plan.file_id.hex(), "-q")
            methods = list(chain.methods)
        self.assertTrue(methods)
        self.assertEqual(set(methods), {"eth_call", "eth_getCode"})


if __name__ == "__main__":
    unittest.main()
