"""ABI encoding and decoding tests.

The expected calldata below was produced by Foundry's `cast calldata` and `cast abi-encode` from
the same arguments, so the hand-written encoder agrees with an independent implementation. The
Foundry golden test additionally compares it with `abi.encodeCall` on the real contract.
"""

from __future__ import annotations

import unittest

from tools.content import abi
from tools.content.errors import AbiError
from tools.content.keccak import keccak256

H1, H2, H3 = bytes([0x11] * 32), bytes([0x22] * 32), bytes([0x33] * 32)

REGISTER_TWO_CHUNKS = (
    "e90c46ad"
    "00000000000000000000000000000000000000000000000000000000000000a0"
    "0000000000000000000000000000000000000000000000000000000000007530"
    "0000000000000000000000000000000000000000000000000000000000000001"
    "0000000000000000000000000000000000000000000000000000000000000100"
    "3333333333333333333333333333333333333333333333333333333333333333"
    "0000000000000000000000000000000000000000000000000000000000000002"
    "1111111111111111111111111111111111111111111111111111111111111111"
    "2222222222222222222222222222222222222222222222222222222222222222"
    "0000000000000000000000000000000000000000000000000000000000000009"
    "746578742f68746d6c0000000000000000000000000000000000000000000000"
)
LONG_MIME = "application/vnd.6529works.longmime-" + "x" * 29  # exactly 64 bytes
REGISTER_LONG_MIME = (
    "e90c46ad"
    "00000000000000000000000000000000000000000000000000000000000000a0"
    "0000000000000000000000000000000000000000000000000000000000000005"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "00000000000000000000000000000000000000000000000000000000000000e0"
    "3333333333333333333333333333333333333333333333333333333333333333"
    "0000000000000000000000000000000000000000000000000000000000000001"
    "1111111111111111111111111111111111111111111111111111111111111111"
    "0000000000000000000000000000000000000000000000000000000000000040"
    "6170706c69636174696f6e2f766e642e36353239776f726b732e6c6f6e676d69"
    "6d652d7878787878787878787878787878787878787878787878787878787878"
)
WRITE_CHUNK_40_BYTES = (
    "6fba0bf5"
    "0000000000000000000000000000000000000000000000000000000000000020"
    "0000000000000000000000000000000000000000000000000000000000000028"
    + "ab" * 40
    + "00" * 24
)
MANIFEST_ID_PREIMAGE_HASH = "ebd48310af312075f40279eda266f8fd089f8aa89b4ade99f7c86e1392f7c891"


class EncodeTest(unittest.TestCase):
    def test_register_manifest_matches_cast(self) -> None:
        data = abi.encode_register_manifest([H1, H2], 30000, 1, "text/html", H3)
        self.assertEqual(data.hex(), REGISTER_TWO_CHUNKS)

    def test_register_manifest_with_a_two_slot_mime_matches_cast(self) -> None:
        self.assertEqual(len(LONG_MIME), 64)
        data = abi.encode_register_manifest([H1], 5, 0, LONG_MIME, H3)
        self.assertEqual(data.hex(), REGISTER_LONG_MIME)

    def test_write_chunk_matches_cast(self) -> None:
        self.assertEqual(abi.encode_write_chunk(b"\xab" * 40).hex(), WRITE_CHUNK_40_BYTES)

    def test_write_chunk_of_a_word_multiple_has_no_padding(self) -> None:
        data = abi.encode_write_chunk(bytes(64))
        self.assertEqual(len(data), 4 + 32 + 32 + 64)

    def test_manifest_args_are_the_file_id_preimage(self) -> None:
        # abi.encode(...) is the register calldata without its selector.
        args = abi.encode_manifest_args([H1, H2], 30000, 1, "text/html", H3)
        self.assertEqual(args, abi.encode_register_manifest([H1, H2], 30000, 1, "text/html", H3)[4:])
        self.assertEqual(keccak256(args).hex(), MANIFEST_ID_PREIMAGE_HASH)

    def test_static_call_encoding(self) -> None:
        data = abi.encode_call(abi.READ_CHUNK, H1, 7)
        self.assertEqual(data, abi.READ_CHUNK + H1 + (7).to_bytes(32, "big"))

    def test_rejects_bad_inputs(self) -> None:
        with self.assertRaises(AbiError):
            abi.uint_word(-1)
        with self.assertRaises(AbiError):
            abi.uint_word(1 << 256)
        with self.assertRaises(AbiError):
            abi.bytes32_word(b"short")
        with self.assertRaises(AbiError):
            abi.encode_manifest_args([H1], 1, 256, "a/b", H3)


class DecodeTest(unittest.TestCase):
    def test_file_info_round_trip(self) -> None:
        mime = b"text/html"
        ret = (
            abi.uint_word(32) + H3 + abi.uint_word(30000) + abi.uint_word(2) + abi.uint_word(1)
            + abi.uint_word(160) + abi.uint_word(len(mime)) + mime + bytes(32 - len(mime))
        )
        info = abi.decode_file_info(ret)
        self.assertEqual(
            (info.sha256, info.length, info.chunk_count, info.encoding, info.mime_type),
            (H3, 30000, 2, 1, "text/html"),
        )

    def test_bytes_and_arrays(self) -> None:
        self.assertEqual(
            abi.decode_bytes(abi.uint_word(32) + abi.uint_word(3) + b"abc" + bytes(29)), b"abc"
        )
        ret = abi.uint_word(32) + abi.uint_word(2) + abi.uint_word(4) + abi.uint_word(9)
        self.assertEqual(abi.decode_uint_array(ret), [4, 9])
        self.assertEqual(abi.decode_uint_array(abi.uint_word(32) + abi.uint_word(0)), [])

    def test_scalars(self) -> None:
        self.assertEqual(abi.decode_uint(abi.uint_word(24575)), 24575)
        self.assertTrue(abi.decode_bool(abi.uint_word(1)))
        self.assertIsNone(abi.decode_address(bytes(32)))
        self.assertEqual(abi.decode_address(bytes(12) + b"\x01" * 20), b"\x01" * 20)
        with self.assertRaises(AbiError):
            abi.decode_bool(abi.uint_word(2))
        with self.assertRaises(AbiError):
            abi.decode_address(b"\x01" + bytes(31))

    def test_truncated_or_lying_data_is_rejected(self) -> None:
        with self.assertRaises(AbiError):
            abi.decode_uint(b"\x00" * 31)
        with self.assertRaises(AbiError):
            abi.decode_bytes(abi.uint_word(32) + abi.uint_word(100) + b"abc")
        with self.assertRaises(AbiError):
            # An array claiming a huge length must not be walked.
            abi.decode_uint_array(abi.uint_word(32) + abi.uint_word(10**9))
        with self.assertRaises(AbiError):
            abi.decode_file_info(abi.uint_word(32) + H3)
        with self.assertRaises(AbiError):
            abi.decode_bytes(abi.uint_word(1 << 200))


class RevertTest(unittest.TestCase):
    def test_known_custom_errors(self) -> None:
        data = abi.selector("ContentFileUnknown(bytes32)") + H1
        self.assertEqual(abi.describe_revert(data), "ContentFileUnknown(0x" + "11" * 32 + ")")
        data = abi.selector("ContentChunkMissing(bytes32,uint256,bytes32)") + H1 + abi.uint_word(3) + H2
        self.assertEqual(
            abi.describe_revert(data), f"ContentChunkMissing(0x{'11' * 32}, 3, 0x{'22' * 32})"
        )
        self.assertEqual(
            abi.describe_revert(abi.selector("ContentDigestMissing()")), "ContentDigestMissing()"
        )

    def test_standard_errors_and_fallbacks(self) -> None:
        reason = abi.selector("Error(string)") + abi.uint_word(32) + abi.uint_word(2) + b"no" + bytes(30)
        self.assertEqual(abi.describe_revert(reason), "reverted: no")
        self.assertEqual(
            abi.describe_revert(abi.selector("Panic(uint256)") + abi.uint_word(0x11)),
            "panic code 0x11",
        )
        self.assertEqual(abi.describe_revert(b""), "reverted without data")
        self.assertIn("unknown error", abi.describe_revert(b"\xde\xad\xbe\xef"))
        self.assertIn("malformed", abi.describe_revert(abi.selector("ContentFileUnknown(bytes32)") + b"\x01"))


if __name__ == "__main__":
    unittest.main()
