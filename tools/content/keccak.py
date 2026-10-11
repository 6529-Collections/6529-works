"""Keccak-256 in pure Python (standard library only).

This is the original Keccak submission that Ethereum and Solidity's `keccak256` use: rate 136
bytes, capacity 64 bytes, domain padding byte `0x01` (pad10*1). It is NOT `hashlib.sha3_256`,
which is the NIST SHA-3 standard and pads with `0x06`, so the two differ on every input.

The permutation is unrolled with local variables because chunk hashing dominates the run time
of a large upload: a maximum-size file (512 chunks, about 12.6 MB) takes on the order of
seconds to tens of seconds here. Correctness is pinned by known-answer vectors in
`test_keccak.py`, and the cross-language golden vectors check every chunk hash and file ID
against the Solidity `keccak256`.
"""

from __future__ import annotations

import struct

RATE = 136  # bytes absorbed per permutation: 1600 bits minus 2 * 256 bits of capacity
_M = 0xFFFFFFFFFFFFFFFF

_ROUND_CONSTANTS = (
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
)  # fmt: skip

_BLOCK = struct.Struct("<17Q")


def _permute(state: list[int]) -> None:
    """Keccak-f[1600] on 25 little-endian 64-bit lanes, in place (lane index is x + 5 * y)."""
    M = _M
    (a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19,
     a20, a21, a22, a23, a24) = state  # fmt: skip
    for rc in _ROUND_CONSTANTS:
        c0 = a0 ^ a5 ^ a10 ^ a15 ^ a20
        c1 = a1 ^ a6 ^ a11 ^ a16 ^ a21
        c2 = a2 ^ a7 ^ a12 ^ a17 ^ a22
        c3 = a3 ^ a8 ^ a13 ^ a18 ^ a23
        c4 = a4 ^ a9 ^ a14 ^ a19 ^ a24
        d0 = c4 ^ (((c1 << 1) | (c1 >> 63)) & M)
        d1 = c0 ^ (((c2 << 1) | (c2 >> 63)) & M)
        d2 = c1 ^ (((c3 << 1) | (c3 >> 63)) & M)
        d3 = c2 ^ (((c4 << 1) | (c4 >> 63)) & M)
        d4 = c3 ^ (((c0 << 1) | (c0 >> 63)) & M)
        b0 = a0 ^ d0
        t = a5 ^ d0
        b16 = ((t << 36) | (t >> 28)) & M
        t = a10 ^ d0
        b7 = ((t << 3) | (t >> 61)) & M
        t = a15 ^ d0
        b23 = ((t << 41) | (t >> 23)) & M
        t = a20 ^ d0
        b14 = ((t << 18) | (t >> 46)) & M
        t = a1 ^ d1
        b10 = ((t << 1) | (t >> 63)) & M
        t = a6 ^ d1
        b1 = ((t << 44) | (t >> 20)) & M
        t = a11 ^ d1
        b17 = ((t << 10) | (t >> 54)) & M
        t = a16 ^ d1
        b8 = ((t << 45) | (t >> 19)) & M
        t = a21 ^ d1
        b24 = ((t << 2) | (t >> 62)) & M
        t = a2 ^ d2
        b20 = ((t << 62) | (t >> 2)) & M
        t = a7 ^ d2
        b11 = ((t << 6) | (t >> 58)) & M
        t = a12 ^ d2
        b2 = ((t << 43) | (t >> 21)) & M
        t = a17 ^ d2
        b18 = ((t << 15) | (t >> 49)) & M
        t = a22 ^ d2
        b9 = ((t << 61) | (t >> 3)) & M
        t = a3 ^ d3
        b5 = ((t << 28) | (t >> 36)) & M
        t = a8 ^ d3
        b21 = ((t << 55) | (t >> 9)) & M
        t = a13 ^ d3
        b12 = ((t << 25) | (t >> 39)) & M
        t = a18 ^ d3
        b3 = ((t << 21) | (t >> 43)) & M
        t = a23 ^ d3
        b19 = ((t << 56) | (t >> 8)) & M
        t = a4 ^ d4
        b15 = ((t << 27) | (t >> 37)) & M
        t = a9 ^ d4
        b6 = ((t << 20) | (t >> 44)) & M
        t = a14 ^ d4
        b22 = ((t << 39) | (t >> 25)) & M
        t = a19 ^ d4
        b13 = ((t << 8) | (t >> 56)) & M
        t = a24 ^ d4
        b4 = ((t << 14) | (t >> 50)) & M
        a0 = b0 ^ (~b1 & b2)
        a1 = b1 ^ (~b2 & b3)
        a2 = b2 ^ (~b3 & b4)
        a3 = b3 ^ (~b4 & b0)
        a4 = b4 ^ (~b0 & b1)
        a5 = b5 ^ (~b6 & b7)
        a6 = b6 ^ (~b7 & b8)
        a7 = b7 ^ (~b8 & b9)
        a8 = b8 ^ (~b9 & b5)
        a9 = b9 ^ (~b5 & b6)
        a10 = b10 ^ (~b11 & b12)
        a11 = b11 ^ (~b12 & b13)
        a12 = b12 ^ (~b13 & b14)
        a13 = b13 ^ (~b14 & b10)
        a14 = b14 ^ (~b10 & b11)
        a15 = b15 ^ (~b16 & b17)
        a16 = b16 ^ (~b17 & b18)
        a17 = b17 ^ (~b18 & b19)
        a18 = b18 ^ (~b19 & b15)
        a19 = b19 ^ (~b15 & b16)
        a20 = b20 ^ (~b21 & b22)
        a21 = b21 ^ (~b22 & b23)
        a22 = b22 ^ (~b23 & b24)
        a23 = b23 ^ (~b24 & b20)
        a24 = b24 ^ (~b20 & b21)
        a0 ^= rc
    state[:] = (a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17,
                a18, a19, a20, a21, a22, a23, a24)  # fmt: skip


def keccak256(data: bytes | bytearray | memoryview) -> bytes:
    """The 32-byte Keccak-256 digest of `data`, as Solidity's `keccak256` computes it."""
    data = bytes(data)
    state = [0] * 25
    full = len(data) // RATE * RATE
    for offset in range(0, full, RATE):
        lanes = _BLOCK.unpack_from(data, offset)
        for i in range(17):
            state[i] ^= lanes[i]
        _permute(state)
    # Final block: the remainder, then 0x01, zeros, and 0x80 in the last rate byte. When one
    # byte is left both marks share it (0x81). A full-rate input still gets a whole pad block.
    tail = bytearray(data[full:])
    tail.append(0x01)
    tail.extend(bytes(RATE - len(tail)))
    tail[RATE - 1] |= 0x80
    lanes = _BLOCK.unpack(bytes(tail))
    for i in range(17):
        state[i] ^= lanes[i]
    _permute(state)
    return struct.pack("<4Q", *state[:4])
