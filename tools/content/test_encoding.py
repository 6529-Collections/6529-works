"""Encoding tests: the reproducible gzip profile, strict decoding, canonical base64."""

from __future__ import annotations

import base64
import gzip
import struct
import unittest
import zlib

from tools.content import encoding as enc
from tools.content.encoding import Encoding
from tools.content.errors import EncodingError, ToolError

TEXT = (b"6529 Works content store. " * 200) + bytes(range(256)) * 4


class GzipProfileTest(unittest.TestCase):
    def test_header_is_fixed(self) -> None:
        stream = enc.gzip_encode(TEXT)
        # magic, deflate, no flags (no name, extra, comment or header CRC), MTIME 0, XFL 2, OS 255
        self.assertEqual(stream[:10].hex(), "1f8b08000000000002ff")
        self.assertEqual(stream[:10], enc.GZIP_HEADER)

    def test_trailer_is_crc32_and_size(self) -> None:
        stream = enc.gzip_encode(TEXT)
        crc, size = struct.unpack("<II", stream[-8:])
        self.assertEqual(crc, zlib.crc32(TEXT) & 0xFFFFFFFF)
        self.assertEqual(size, len(TEXT))

    def test_size_field_wraps_modulo_2_32(self) -> None:
        # ISIZE is the input size mod 2**32; exercised through the packing, not a 4 GiB input.
        self.assertEqual(struct.pack("<I", (2**32 + 5) & 0xFFFFFFFF), struct.pack("<I", 5))

    def test_encoding_is_deterministic(self) -> None:
        self.assertEqual(enc.gzip_encode(TEXT), enc.gzip_encode(TEXT))

    def test_round_trip_and_standard_decoders_agree(self) -> None:
        stream = enc.gzip_encode(TEXT)
        self.assertEqual(enc.gzip_decode(stream), TEXT)
        self.assertEqual(gzip.decompress(stream), TEXT)  # any standard gunzip reads it

    def test_empty_and_single_byte_media(self) -> None:
        for media in (b"", b"\x00", b"a"):
            with self.subTest(media=media):
                self.assertEqual(enc.gzip_decode(enc.gzip_encode(media)), media)

    def test_level_9_actually_compresses(self) -> None:
        self.assertLess(len(enc.gzip_encode(b"abc" * 10_000)), 200)

    def test_no_name_or_timestamp_even_though_gzip_module_would_add_them(self) -> None:
        default = gzip.compress(TEXT)  # carries a timestamp: it must NOT be what we emit
        self.assertNotEqual(default[4:8], bytes(4))
        self.assertEqual(enc.gzip_encode(TEXT)[4:8], bytes(4))


class GzipDecodeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.stream = enc.gzip_encode(TEXT)

    def test_rejects_trailing_bytes(self) -> None:
        with self.assertRaisesRegex(EncodingError, "follow the gzip stream"):
            enc.gzip_decode(self.stream + b"\x00")

    def test_rejects_a_second_member(self) -> None:
        with self.assertRaisesRegex(EncodingError, "follow the gzip stream"):
            enc.gzip_decode(self.stream + enc.gzip_encode(b"more"))

    def test_rejects_truncation(self) -> None:
        for cut in (1, 8, len(self.stream) // 2):
            with self.subTest(cut=cut), self.assertRaises(EncodingError):
                enc.gzip_decode(self.stream[:-cut])

    def test_rejects_a_bad_crc(self) -> None:
        broken = bytearray(self.stream)
        broken[-8] ^= 0xFF
        with self.assertRaises(EncodingError):
            enc.gzip_decode(bytes(broken))

    def test_rejects_a_wrong_size_field(self) -> None:
        broken = bytearray(self.stream)
        broken[-1] ^= 0x01
        with self.assertRaises(EncodingError):
            enc.gzip_decode(bytes(broken))

    def test_rejects_non_gzip_input(self) -> None:
        with self.assertRaises(EncodingError):
            enc.gzip_decode(zlib.compress(TEXT))  # zlib wrapper, not gzip
        with self.assertRaises(EncodingError):
            enc.gzip_decode(b"plain text")
        with self.assertRaises(EncodingError):
            enc.gzip_decode(b"")

    def test_output_size_is_bounded(self) -> None:
        bomb = enc.gzip_encode(bytes(1_000_000))
        self.assertEqual(len(enc.gzip_decode(bomb, limit=1_000_000)), 1_000_000)
        with self.assertRaisesRegex(EncodingError, "expands beyond"):
            enc.gzip_decode(bomb, limit=999_999)

    def test_accepts_foreign_but_valid_gzip(self) -> None:
        # A stream from the gzip module (timestamp and all) decodes: only ENCODING is fixed.
        self.assertEqual(enc.gzip_decode(gzip.compress(TEXT)), TEXT)


class Base64Test(unittest.TestCase):
    def test_matches_rfc_4648_vectors(self) -> None:
        for raw, text in (
            (b"", b""), (b"f", b"Zg=="), (b"fo", b"Zm8="), (b"foo", b"Zm9v"),
            (b"foob", b"Zm9vYg=="), (b"fooba", b"Zm9vYmE="), (b"foobar", b"Zm9vYmFy"),
        ):
            with self.subTest(raw=raw):
                self.assertEqual(enc.base64_encode(raw), text)
                self.assertEqual(enc.base64_decode(text), raw)

    def test_uses_the_standard_alphabet_with_padding_and_no_line_breaks(self) -> None:
        text = enc.base64_encode(bytes([0xFB, 0xFF, 0xFE]) * 100)
        self.assertIn(b"+", text)
        self.assertIn(b"/", text)
        self.assertNotIn(b"-", text)
        self.assertNotIn(b"_", text)
        self.assertNotIn(b"\n", text)

    def test_rejects_non_canonical_text(self) -> None:
        for bad in (
            b"Zg",  # missing padding
            b"Zg==\n",  # trailing line break
            b"Zm9v\nYmFy",  # embedded line break
            b"Zh==",  # non-zero trailing bits (decodes to the same byte as Zg==)
            b"Zm9v-w==",  # URL-safe alphabet
            b"Zm9v YmFy",  # space
            b"Zg==Zg==",  # data after padding
            b"====",
        ):
            with self.subTest(bad=bad), self.assertRaises(EncodingError):
                enc.base64_decode(bad)


class PipelineTest(unittest.TestCase):
    def test_every_encoding_round_trips(self) -> None:
        for encoding in Encoding:
            with self.subTest(encoding=encoding.label):
                stored = enc.encode(TEXT, encoding)
                self.assertEqual(enc.decode(stored, encoding), TEXT)

    def test_stored_forms(self) -> None:
        self.assertEqual(enc.encode(TEXT, Encoding.IDENTITY), TEXT)
        self.assertEqual(enc.encode(TEXT, Encoding.GZIP), enc.gzip_encode(TEXT))
        self.assertEqual(enc.encode(TEXT, Encoding.BASE64), base64.b64encode(TEXT))
        self.assertEqual(
            enc.encode(TEXT, Encoding.GZIP_BASE64), base64.b64encode(enc.gzip_encode(TEXT))
        )

    def test_decode_order_is_base64_then_gzip(self) -> None:
        stored = enc.encode(TEXT, Encoding.GZIP_BASE64)
        self.assertEqual(enc.decode(stored, Encoding.GZIP_BASE64), TEXT)
        with self.assertRaises(EncodingError):
            enc.decode(stored, Encoding.GZIP)  # still base64 text, not a gzip stream

    def test_labels_and_ids(self) -> None:
        self.assertEqual([int(e) for e in Encoding], [0, 1, 2, 3])
        for encoding in Encoding:
            self.assertEqual(Encoding.parse(encoding.label), encoding)
            self.assertEqual(Encoding.from_id(int(encoding)), encoding)
        with self.assertRaises(ToolError):
            Encoding.parse("zip")
        with self.assertRaises(ToolError):
            Encoding.from_id(4)


if __name__ == "__main__":
    unittest.main()
