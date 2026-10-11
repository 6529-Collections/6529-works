"""Planning tests: MIME rules, chunk layout, limits, file IDs, manifests."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.content import encoding as enc
from tools.content import plan as pl
from tools.content.encoding import Encoding
from tools.content.errors import ToolError
from tools.content.golden import counter_bytes

H1, H2, H3 = bytes([0x11] * 32), bytes([0x22] * 32), bytes([0x33] * 32)


class MimeTest(unittest.TestCase):
    def test_accepts_what_the_contract_accepts(self) -> None:
        for mime in (
            "text/html", "image/svg+xml", "application/vnd.api+json", "a/b", "x-y/z_w.1",
            "application/octet-stream", "a/" + "b" * 62,
        ):
            with self.subTest(mime=mime):
                pl.validate_mime(mime)

    def test_rejects_what_the_contract_rejects(self) -> None:
        for mime in (
            "", "text", "/html", "text/", "text/html/x", "//", "Text/html", "text/HTML",
            "text/html; charset=utf-8", "text/ht ml", "text/é", "text//html", "a/" + "b" * 63,
            "text/html\n",
        ):
            with self.subTest(mime=mime), self.assertRaises(ToolError):
                pl.validate_mime(mime)

    def test_length_limit_is_64_bytes(self) -> None:
        pl.validate_mime("a/" + "b" * 62)  # 64
        with self.assertRaises(ToolError):
            pl.validate_mime("a/" + "b" * 63)  # 65


class LayoutTest(unittest.TestCase):
    def test_constants_match_the_contract(self) -> None:
        self.assertEqual(pl.CHUNK_SIZE, 24_575)  # EIP-170 minus the STOP byte
        self.assertEqual(pl.MAX_CHUNKS, 512)
        self.assertEqual(pl.MAX_STORED_BYTES, 12_582_400)

    def test_chunk_counts_at_the_edges(self) -> None:
        cases = {1: 1, 24_574: 1, 24_575: 1, 24_576: 2, 49_150: 2, 49_151: 3, 12_582_400: 512}
        for length, count in cases.items():
            with self.subTest(length=length):
                self.assertEqual(pl.chunk_count(length), count)

    def test_every_chunk_but_the_last_is_full(self) -> None:
        for length in (1, 24_574, 24_575, 24_576, 49_150, 49_151, 73_726):
            data = counter_bytes(1, length)
            chunks = pl.split_chunks(data)
            with self.subTest(length=length):
                self.assertEqual(b"".join(chunks), data)
                self.assertTrue(all(len(c) == pl.CHUNK_SIZE for c in chunks[:-1]))
                self.assertTrue(1 <= len(chunks[-1]) <= pl.CHUNK_SIZE)
                self.assertEqual(len(chunks), pl.chunk_count(length))

    def test_empty_stream_is_rejected(self) -> None:
        with self.assertRaisesRegex(ToolError, "empty"):
            pl.split_chunks(b"")
        with self.assertRaises(ToolError):
            pl.check_stored_length(0)

    def test_max_chunks_is_enforced(self) -> None:
        pl.check_stored_length(pl.MAX_STORED_BYTES)  # exactly 512 full chunks
        with self.assertRaisesRegex(ToolError, "at most 512 chunks"):
            pl.check_stored_length(pl.MAX_STORED_BYTES + 1)
        self.assertEqual(len(pl.split_chunks(bytes(pl.MAX_STORED_BYTES))), 512)

    def test_input_limits_follow_the_encoding(self) -> None:
        self.assertEqual(pl.max_input_bytes(Encoding.IDENTITY, False), 12_582_400)
        self.assertEqual(pl.max_input_bytes(Encoding.GZIP, True), 12_582_400)
        self.assertEqual(pl.max_input_bytes(Encoding.BASE64, False), 9_436_800)
        self.assertEqual(pl.max_input_bytes(Encoding.GZIP, False), enc.MAX_DECODED_BYTES)
        # 9,436,800 bytes of media is exactly 512 chunks of base64 text.
        self.assertEqual(len(enc.base64_encode(bytes(9_436_800))), pl.MAX_STORED_BYTES)

    def test_oversize_files_fail_before_any_hashing(self) -> None:
        with mock.patch.object(pl, "keccak256", side_effect=AssertionError("hashed")):
            with self.assertRaises(ToolError):
                pl.plan_from_media(bytes(pl.MAX_STORED_BYTES + 1), "text/plain", Encoding.IDENTITY)
            with self.assertRaises(ToolError):
                pl.plan_from_stored(bytes(pl.MAX_STORED_BYTES + 1), "text/plain", Encoding.IDENTITY)

    def test_encoding_can_push_a_file_over_the_limit(self) -> None:
        # Base64 adds a third: media that fits as identity may not fit as base64.
        media = bytes(pl.MAX_STORED_BYTES - 100)
        with self.assertRaises(ToolError):
            pl.plan_from_media(media, "text/plain", Encoding.BASE64)


class FileIdTest(unittest.TestCase):
    def test_matches_cast(self) -> None:
        # keccak256(abi.encode(bytes32[],uint256,uint8,string,bytes32)), computed with
        # `cast abi-encode` and `cast keccak` from the same arguments.
        file_id = pl.manifest_id([H1, H2], 30000, Encoding.GZIP, "text/html", H3)
        self.assertEqual(
            file_id.hex(), "ebd48310af312075f40279eda266f8fd089f8aa89b4ade99f7c86e1392f7c891"
        )

    def test_commits_to_every_field(self) -> None:
        base = pl.manifest_id([H1, H2], 30000, Encoding.GZIP, "text/html", H3)
        variants = [
            pl.manifest_id([H2, H1], 30000, Encoding.GZIP, "text/html", H3),
            pl.manifest_id([H1], 30000, Encoding.GZIP, "text/html", H3),
            pl.manifest_id([H1, H2], 30001, Encoding.GZIP, "text/html", H3),
            pl.manifest_id([H1, H2], 30000, Encoding.IDENTITY, "text/html", H3),
            pl.manifest_id([H1, H2], 30000, Encoding.GZIP, "text/plain", H3),
            pl.manifest_id([H1, H2], 30000, Encoding.GZIP, "text/html", H1),
        ]
        self.assertEqual(len({base, *variants}), 7)

    def test_depends_on_nothing_else(self) -> None:
        # No chain ID and no address: the same inputs always give the same ID.
        self.assertEqual(
            pl.manifest_id([H1], 5, Encoding.IDENTITY, "a/b", H3),
            pl.manifest_id([H1], 5, Encoding.IDENTITY, "a/b", H3),
        )


class PlanTest(unittest.TestCase):
    MEDIA = (b"6529 " * 4000) + counter_bytes(9, 3000)

    def test_every_encoding(self) -> None:
        for encoding in Encoding:
            with self.subTest(encoding=encoding.label):
                plan = pl.plan_from_media(self.MEDIA, "text/plain", encoding)
                self.assertEqual(plan.media_sha256, hashlib.sha256(self.MEDIA).digest())
                self.assertEqual(plan.media_length, len(self.MEDIA))
                self.assertEqual(plan.stored, enc.encode(self.MEDIA, encoding))
                self.assertEqual(enc.decode(plan.stored, encoding), self.MEDIA)
                self.assertTrue(plan.reproducible)
                self.assertEqual(
                    plan.file_id,
                    pl.manifest_id(
                        plan.chunk_hashes, len(plan.stored), encoding, "text/plain",
                        plan.media_sha256,
                    ),
                )
                self.assertEqual(
                    plan.chunk_hashes,
                    tuple(pl.chunk_hash(c) for c in pl.split_chunks(plan.stored)),
                )

    def test_media_digest_is_over_the_decoded_media_not_the_stored_bytes(self) -> None:
        plan = pl.plan_from_media(self.MEDIA, "text/plain", Encoding.GZIP_BASE64)
        self.assertNotEqual(plan.media_sha256, hashlib.sha256(plan.stored).digest())
        self.assertEqual(plan.stored_sha256, hashlib.sha256(plan.stored).digest())

    def test_same_media_different_encoding_has_a_different_file_id(self) -> None:
        ids = {pl.plan_from_media(self.MEDIA, "text/plain", e).file_id for e in Encoding}
        self.assertEqual(len(ids), 4)
        same_digest = {pl.plan_from_media(self.MEDIA, "text/plain", e).media_sha256 for e in Encoding}
        self.assertEqual(len(same_digest), 1)  # uniqueness keys on the decoded media's hash

    def test_chunk_hash_is_keccak_of_the_chunk(self) -> None:
        plan = pl.plan_from_media(counter_bytes(3, 24_576), "a/b", Encoding.IDENTITY)
        first, second = plan.chunks()
        self.assertEqual(len(first), 24_575)
        self.assertEqual(len(second), 1)
        self.assertEqual(plan.chunk_hashes, (pl.chunk_hash(first), pl.chunk_hash(second)))

    def test_invalid_mime_is_refused(self) -> None:
        with self.assertRaises(ToolError):
            pl.plan_from_media(b"x", "Text/Plain", Encoding.IDENTITY)

    def test_foreign_gzip_stream_is_storable_but_not_reproducible(self) -> None:
        import gzip

        foreign = gzip.compress(self.MEDIA, mtime=12345)
        plan = pl.plan_from_stored(foreign, "text/plain", Encoding.GZIP)
        self.assertFalse(plan.reproducible)
        self.assertEqual(plan.stored, foreign)
        self.assertEqual(plan.media_sha256, hashlib.sha256(self.MEDIA).digest())

    def test_stored_plan_matches_media_plan_for_this_tools_own_streams(self) -> None:
        for encoding in Encoding:
            with self.subTest(encoding=encoding.label):
                from_media = pl.plan_from_media(self.MEDIA, "text/plain", encoding)
                from_stored = pl.plan_from_stored(from_media.stored, "text/plain", encoding)
                self.assertEqual(from_stored.file_id, from_media.file_id)
                self.assertTrue(from_stored.reproducible)

    def test_undecodable_stored_streams_are_refused(self) -> None:
        with self.assertRaises(ToolError):
            pl.plan_from_stored(b"not gzip", "text/plain", Encoding.GZIP)
        with self.assertRaises(ToolError):
            pl.plan_from_stored(b"not base64!", "text/plain", Encoding.BASE64)

    def test_non_reproducible_encoding_is_caught(self) -> None:
        # If the encoder ever produced different bytes for the same media, no plan is made.
        real = enc.gzip_encode
        calls = {"n": 0}

        def flaky(media: bytes) -> bytes:
            calls["n"] += 1
            return real(media) if calls["n"] == 1 else real(media + b"!")[:-8] + real(media)[-8:]

        with mock.patch.object(enc, "gzip_encode", flaky):
            with self.assertRaises(ToolError):
                pl.plan_from_media(self.MEDIA, "text/plain", Encoding.GZIP)


class ManifestFileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = pl.plan_from_media(counter_bytes(4, 60_000), "image/png", Encoding.BASE64)

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def write(self, data: dict) -> Path:
        path = self.dir / "m.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def good(self) -> dict:
        return pl.manifest_dict(self.plan, "m.stored", "art.png")

    def test_round_trip(self) -> None:
        manifest = pl.load_manifest(self.write(self.good()))
        self.assertEqual(manifest.file_id, self.plan.file_id)
        self.assertEqual(manifest.mime_type, "image/png")
        self.assertEqual(manifest.encoding, Encoding.BASE64)
        self.assertEqual(manifest.chunk_hashes, self.plan.chunk_hashes)
        self.assertEqual(manifest.stored_length, self.plan.stored_length)
        self.assertEqual(manifest.media_sha256, self.plan.media_sha256)
        self.assertEqual(manifest.stored_file, "m.stored")

    def test_fields_and_key_order_are_fixed(self) -> None:
        manifest = self.good()
        self.assertEqual(
            list(manifest),
            [
                "schema", "fileId", "mimeType", "encoding", "encodingId", "mediaSha256",
                "mediaLength", "storedLength", "storedSha256", "chunkSize", "chunkCount",
                "chunkHashes", "reproducible", "storedFile", "source",
            ],
        )
        self.assertEqual(manifest["chunkSize"], 24_575)
        self.assertEqual(pl.manifest_json(manifest), pl.manifest_json(self.good()))
        self.assertTrue(pl.manifest_json(manifest).endswith("\n"))

    def test_gzip_manifests_record_the_encoder_profile(self) -> None:
        plan = pl.plan_from_media(b"x" * 100, "text/plain", Encoding.GZIP)
        encoder = pl.manifest_dict(plan, None, None)["encoder"]["gzip"]
        self.assertEqual(encoder["header"], "1f8b08000000000002ff")
        self.assertEqual(encoder["deflate"]["level"], 9)
        self.assertNotIn("encoder", self.good())  # base64 alone has no profile to record

    def test_tampered_manifests_are_rejected(self) -> None:
        def mutate(key: str, value: object) -> dict:
            data = self.good()
            data[key] = value
            return data

        cases = {
            "mime type changes the file ID": mutate("mimeType", "image/jpeg"),
            "digest changes the file ID": mutate("mediaSha256", "0x" + "ab" * 32),
            "length changes the file ID": mutate("storedLength", self.plan.stored_length - 1),
            "encoding changes the file ID": mutate("encodingId", 0),
            "file ID itself": mutate("fileId", "0x" + "00" * 32),
            "wrong schema": mutate("schema", "something/else"),
            "bad hash": mutate("chunkHashes", ["0x12"] * len(self.plan.chunk_hashes)),
            "label mismatch": mutate("encoding", "gzip"),
            "chunkCount mismatch": mutate("chunkCount", 99),
            "chunkSize mismatch": mutate("chunkSize", 1000),
            "uppercase mime": mutate("mimeType", "Image/PNG"),
            "zero digest": mutate("mediaSha256", "0x" + "00" * 32),
            "bool as length": mutate("storedLength", True),
        }
        for label, data in cases.items():
            with self.subTest(label), self.assertRaises(ToolError):
                pl.load_manifest(self.write(data))

    def test_dropped_chunk_is_rejected(self) -> None:
        data = self.good()
        data["chunkHashes"] = data["chunkHashes"][:-1]
        data["chunkCount"] = len(data["chunkHashes"])
        with self.assertRaisesRegex(ToolError, "needs"):
            pl.load_manifest(self.write(data))

    def test_missing_keys_and_unreadable_files(self) -> None:
        for key in ("fileId", "mimeType", "encodingId", "mediaSha256", "storedLength", "chunkHashes"):
            data = self.good()
            del data[key]
            with self.subTest(key), self.assertRaises(ToolError):
                pl.load_manifest(self.write(data))
        with self.assertRaises(ToolError):
            pl.load_manifest(self.dir / "missing.json")
        path = self.dir / "bad.json"
        path.write_text("{not json", encoding="utf-8")
        with self.assertRaises(ToolError):
            pl.load_manifest(path)

    def test_check_stored_proves_the_stream(self) -> None:
        manifest = pl.load_manifest(self.write(self.good()))
        pl.check_stored(manifest, self.plan.stored)  # the right stream passes
        for label, bad in {
            "truncated": self.plan.stored[:-4],
            "extended": self.plan.stored + b"AAAA",
            "one byte flipped": self.plan.stored[:100] + b"\x41" + self.plan.stored[101:]
            if self.plan.stored[100:101] != b"A"
            else self.plan.stored[:100] + b"B" + self.plan.stored[101:],
        }.items():
            with self.subTest(label), self.assertRaises(ToolError):
                pl.check_stored(manifest, bad)

    def test_check_stored_catches_a_wrong_media_digest_with_matching_chunks(self) -> None:
        # A manifest can be internally consistent yet commit to a digest the bytes do not have.
        lie = pl.manifest_id(
            self.plan.chunk_hashes, self.plan.stored_length, Encoding.BASE64, "image/png", H3
        )
        data = self.good()
        data["mediaSha256"] = "0x" + H3.hex()
        data["fileId"] = "0x" + lie.hex()
        data.pop("storedSha256")
        manifest = pl.load_manifest(self.write(data))
        with self.assertRaisesRegex(ToolError, "mediaSha256"):
            pl.check_stored(manifest, self.plan.stored)

    def test_stored_file_must_be_a_plain_name_beside_the_manifest(self) -> None:
        manifest_path = self.dir / "m.json"
        self.assertEqual(pl.resolve_stored_path(manifest_path, "m.stored"), self.dir.resolve() / "m.stored")
        for bad in ("../secret", "/etc/passwd", "sub/file", "..", ".", "a\\b", "C:\\x"):
            with self.subTest(bad), self.assertRaises(ToolError):
                pl.resolve_stored_path(manifest_path, bad)

    def test_write_new_file_refuses_to_overwrite(self) -> None:
        path = self.dir / "out.bin"
        pl.write_new_file(path, b"one", force=False)
        with self.assertRaisesRegex(ToolError, "already exists"):
            pl.write_new_file(path, b"two", force=False)
        self.assertEqual(path.read_bytes(), b"one")
        pl.write_new_file(path, b"two", force=True)
        self.assertEqual(path.read_bytes(), b"two")
        self.assertEqual([p.name for p in self.dir.iterdir() if p.name.endswith(".tmp")], [])


if __name__ == "__main__":
    unittest.main()
