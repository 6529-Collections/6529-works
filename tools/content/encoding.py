"""The four stored encodings of `IContentStore.Encoding`, with a reproducible gzip profile.

`encode(media, encoding)` produces the exact bytes the store holds; `decode(stored, encoding)`
returns the media, whose SHA-256 is what a manifest declares. Decoding is strict: anything but one
well-formed gzip member, or canonical padded base64, is rejected, so a stored stream has one
meaning.

Gzip profile (fixed; part of the file ID's reproducibility, see the README):

- 10-byte header `1f 8b 08 00 00000000 02 ff`: deflate, no flags (so no file name, no extra
  field, no comment, no header CRC), MTIME 0, XFL 2 (maximum compression), OS 255 (unknown). It is
  written by hand because `zlib`'s own gzip wrapper writes an OS byte that depends on the platform.
- Raw deflate from zlib at level 9, memLevel 8, window 15, default strategy.
- Trailer: CRC-32 and input size modulo 2**32, little-endian.

The deflate bytes still depend on the zlib implementation: stock zlib has produced the same output
for these settings across releases, while forks such as zlib-ng differ. Nothing can make that
dependency disappear, so the encoded stream itself is the thing to keep and publish.
"""

from __future__ import annotations

import base64
import binascii
import enum
import re
import struct
import zlib
from dataclasses import dataclass

from .errors import EncodingError, ToolError

GZIP_LEVEL = 9
GZIP_MEM_LEVEL = 8
GZIP_WINDOW_BITS = 15
GZIP_STRATEGY = zlib.Z_DEFAULT_STRATEGY
GZIP_HEADER = bytes.fromhex("1f8b0800" "00000000" "02ff")

# The largest decoded media the tooling will produce. The store holds at most 12.58 MB, and a
# gzip bomb on chain must not exhaust memory in `verify` or `rebuild`.
MAX_DECODED_BYTES = 512 * 1024 * 1024


class Encoding(enum.IntEnum):
    """`IContentStore.Encoding`. The values are part of the file ID."""

    IDENTITY = 0
    GZIP = 1
    BASE64 = 2
    GZIP_BASE64 = 3

    @property
    def label(self) -> str:
        """The command-line spelling."""
        return _LABELS[self]

    @property
    def uses_gzip(self) -> bool:
        return self in (Encoding.GZIP, Encoding.GZIP_BASE64)

    @property
    def uses_base64(self) -> bool:
        return self in (Encoding.BASE64, Encoding.GZIP_BASE64)

    @classmethod
    def parse(cls, text: str) -> "Encoding":
        for encoding, label in _LABELS.items():
            if label == text:
                return encoding
        raise ToolError(f"unknown encoding {text!r}; expected one of {', '.join(_LABELS.values())}")

    @classmethod
    def from_id(cls, value: int) -> "Encoding":
        try:
            return cls(value)
        except ValueError:
            raise ToolError(f"unknown encoding id {value}") from None


_LABELS = {
    Encoding.IDENTITY: "identity",
    Encoding.GZIP: "gzip",
    Encoding.BASE64: "base64",
    Encoding.GZIP_BASE64: "gzipbase64",
}


def gzip_encode(media: bytes) -> bytes:
    """The reproducible gzip stream of `media` (see the module docstring)."""
    deflater = zlib.compressobj(
        GZIP_LEVEL, zlib.DEFLATED, -GZIP_WINDOW_BITS, GZIP_MEM_LEVEL, GZIP_STRATEGY
    )
    body = deflater.compress(media) + deflater.flush()
    trailer = struct.pack("<II", zlib.crc32(media) & 0xFFFFFFFF, len(media) & 0xFFFFFFFF)
    return GZIP_HEADER + body + trailer


def gzip_decode(stored: bytes, limit: int = MAX_DECODED_BYTES) -> bytes:
    """Decode exactly one gzip member, verifying its CRC-32 and size, with no trailing bytes."""
    inflater = zlib.decompressobj(wbits=16 + zlib.MAX_WBITS)  # gzip wrapper only
    out = bytearray()
    pending = bytes(stored)
    try:
        while not inflater.eof:
            piece = inflater.decompress(pending, limit + 1 - len(out))
            out += piece
            if len(out) > limit:
                raise EncodingError(f"gzip stream expands beyond {limit} bytes")
            pending = inflater.unconsumed_tail
            if not piece and not pending:
                break
    except zlib.error as exc:
        raise EncodingError(f"invalid gzip stream: {exc}") from exc
    if not inflater.eof:
        raise EncodingError("truncated gzip stream")
    if inflater.unused_data:
        raise EncodingError(
            f"{len(inflater.unused_data)} bytes follow the gzip stream "
            "(only a single gzip member is accepted)"
        )
    return bytes(out)


def base64_encode(data: bytes) -> bytes:
    """RFC 4648 section 4: standard alphabet, `=` padding, no line breaks."""
    return base64.b64encode(data)


def base64_decode(text: bytes) -> bytes:
    """Decode canonical base64 only: the exact text `base64_encode` would produce."""
    try:
        raw = base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise EncodingError(f"invalid base64: {exc}") from exc
    if base64.b64encode(raw) != text:
        raise EncodingError("base64 is not canonical (padding or trailing bits)")
    return raw


_NOT_ALPHABET = re.compile(rb"[^A-Za-z0-9+/]")


@dataclass(frozen=True)
class Base64Problem:
    """Why `ContentStore.attestBase64` would revert for a stored text. `kind` is `length`
    (`ContentBase64LengthInvalid`) or `alphabet` (`ContentBase64Invalid`, with the byte `offset`
    of the first offending byte; the chunk index is `offset // CHUNK_SIZE`)."""

    kind: str
    offset: int | None = None
    value: int | None = None


def base64_attestation_problem(text: bytes) -> Base64Problem | None:
    """The same rule as `ContentStore.attestBase64`, or `None` if the store would attest `text`.

    The text must be a whole number of 4-byte groups, every byte in `[A-Za-z0-9+/]`, except that
    `=` may be the last one or two bytes of the whole text. This is the alphabet and placement
    rule only: canonical padding bits are not checked (see `base64_decode` for the stricter
    decoder). The checks run in the contract's order: length first, then the first bad byte.
    """
    if len(text) % 4 != 0 or not text:
        return Base64Problem("length")
    pad = 0
    if text.endswith(b"="):
        pad = 2 if text[-2:-1] == b"=" else 1
    bad = _NOT_ALPHABET.search(text, 0, len(text) - pad)
    if bad is not None:
        return Base64Problem("alphabet", bad.start(), text[bad.start()])
    return None


def encode(media: bytes, encoding: Encoding) -> bytes:
    """The bytes the store holds for `media` under `encoding`."""
    data = bytes(media)
    if encoding.uses_gzip:
        data = gzip_encode(data)
    if encoding.uses_base64:
        data = base64_encode(data)
    return data


def decode(stored: bytes, encoding: Encoding) -> bytes:
    """The media that `stored` encodes: base64-decoded first, then gunzipped, as required."""
    data = bytes(stored)
    if encoding.uses_base64:
        data = base64_decode(data)
    if encoding.uses_gzip:
        data = gzip_decode(data)
    return data
