"""Keccak-256 known-answer tests.

Vectors come from the Keccak team's published digests and, for the longer patterned inputs, from
Foundry's `cast keccak` (which is Solidity's `keccak256`). The patterned input of length n is
`bytes((i * 31 + 7) % 256 for i in range(n))`; 136 is the sponge rate, so 135, 136 and 137 sit on
both sides of the padding edge and 272 on the second block's.
"""

from __future__ import annotations

import hashlib
import unittest

from tools.content import abi
from tools.content.keccak import RATE, keccak256


def pattern(n: int) -> bytes:
    return bytes((i * 31 + 7) % 256 for i in range(n))


class KeccakTest(unittest.TestCase):
    def test_empty_string(self) -> None:
        self.assertEqual(
            keccak256(b"").hex(),
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        )

    def test_abc(self) -> None:
        self.assertEqual(
            keccak256(b"abc").hex(),
            "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
        )

    def test_quick_brown_fox(self) -> None:
        self.assertEqual(
            keccak256(b"The quick brown fox jumps over the lazy dog").hex(),
            "4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15",
        )

    def test_patterned_inputs_across_block_boundaries(self) -> None:
        expected = {
            0: "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
            1: "ee2a4bc7db81da2b7164e56b3649b1e2a09c58c455b15dabddd9146c7582cebc",
            55: "97c45d97c802da7b3a6584d91c34ee4ea5cd8d8b052856234405bf5b76c0b043",
            135: "adee8145bb33dc0320ad44945eeeb391e4668f0f7c69ccbbf6550a7cba245e52",
            136: "eaccfc5aa7bf6bf1941809ef7cc9ee6a2fa306a7dd1de3f2e8504849b0a5e3c4",
            137: "ea0e0b9657469f0b4f53604f1068ab4bd4a5e7b0a458d24a78f1fe2ec7bd4db0",
            272: "c62d6a60780d4e03408834062e58004a549cff1c7487c0b9a130810621b0fcae",
            1000: "c77d9bffcae9f0984e6dff7eea63cc14cad5f367f791e27b08a1953f192f30a5",
        }
        self.assertEqual(RATE, 136)
        for length, digest in expected.items():
            with self.subTest(length=length):
                self.assertEqual(keccak256(pattern(length)).hex(), digest)

    def test_is_not_nist_sha3(self) -> None:
        # hashlib's sha3_256 is the NIST standard with different padding: never interchangeable.
        self.assertNotEqual(keccak256(b"").hex(), hashlib.sha3_256(b"").hexdigest())
        self.assertNotEqual(keccak256(b"abc"), hashlib.sha3_256(b"abc").digest())

    def test_accepts_bytes_like_inputs(self) -> None:
        data = pattern(300)
        self.assertEqual(keccak256(bytearray(data)), keccak256(data))
        self.assertEqual(keccak256(memoryview(data)), keccak256(data))

    def test_digest_is_32_bytes(self) -> None:
        self.assertEqual(len(keccak256(b"x")), 32)

    def test_function_selectors(self) -> None:
        # Selectors cross-checked with `cast sig`; the Foundry golden test asserts the same
        # bytes appear in abi.encodeCall output.
        self.assertEqual(abi.selector("transfer(address,uint256)").hex(), "a9059cbb")
        self.assertEqual(abi.WRITE_CHUNK.hex(), "6fba0bf5")
        self.assertEqual(abi.REGISTER_MANIFEST.hex(), "e90c46ad")
        self.assertEqual(abi.FILE_INFO.hex(), "9754c8fd")
        self.assertEqual(abi.READ_CHUNK.hex(), "c203cb0c")
        self.assertEqual(abi.MISSING_CHUNKS.hex(), "0084671c")
        self.assertEqual(abi.CHUNK_HASH.hex(), "ee9f3687")
        self.assertEqual(abi.CHUNK_POINTER.hex(), "23cc7937")
        self.assertEqual(abi.CHUNK_SIZE.hex(), "e91e13a9")
        self.assertEqual(abi.MAX_CHUNKS.hex(), "5ed25346")
        self.assertEqual(abi.CONTENT_FILE_UNKNOWN.hex(), "793ba8b9")
        self.assertEqual(abi.CONTENT_CHUNK_MISSING.hex(), "e495961c")


if __name__ == "__main__":
    unittest.main()
