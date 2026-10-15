"""The deterministic IPFS CID of a file under the fixed profile of ADR 0001 section 8.

The profile: CIDv1, sha2-256, raw leaves, a fixed-size chunker of 262,144 bytes, UnixFS files
built with the balanced layout of at most 174 links per node, and the lowercase base32
multibase (`b...`). A file of at most one chunk is a single raw block, `bafkrei...`; a larger
file's root is a dag-pb UnixFS node, `bafybei...`. This is what

    ipfs add --only-hash --quieter --cid-version=1 --raw-leaves --chunker=size-262144 FILE

prints with kubo's default import settings (balanced layout, 174 links per node, no inlining,
no trickle). It is the form `WorkRecords.addLocator` accepts as `ipfs://<cid>`: 66 bytes, a
`bafkrei` or `bafybei` prefix, a 32-byte sha2-256 digest, canonical padding.

Standard library only. The DAG is built as kubo builds it (boxo `importer/balanced`):

- each chunk is a raw block (codec 0x55), linked by its length;
- the first leaf is the root until a second chunk exists; then the root becomes a dag-pb node
  (codec 0x70) of depth 1 holding the old root as its first link and as many further leaves as
  fit, and so on: each time the root is full it becomes the first child of a root one level
  deeper, whose further children are full subtrees of the level below;
- a dag-pb node is `Links` (field 2, in order) then `Data` (field 1). A link is the child's binary
  CID (field 1), an empty `Name` (field 2, written as present and empty, as go-ipfs writes it)
  and `Tsize` (field 3): the child's block size plus its own links' `Tsize`s. `Data` is a UnixFS
  `File` (`Type` 2), its `filesize`, and one `blocksizes` entry per child (the child's file
  bytes), unpacked as proto2 writes repeated scalars.

`ipfs add -w` (`--wrap-with-directory`) prints a directory's CID on its last line: that is not
the file's CID and is not what a locator may name.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import BinaryIO, Iterator

CHUNK_SIZE = 262_144
MAX_LINKS = 174
CODEC_RAW = 0x55
CODEC_DAG_PB = 0x70
SHA2_256 = 0x12
_B32 = "abcdefghijklmnopqrstuvwxyz234567"
_UNIXFS_FILE = 2

KUBO_COMMAND = (
    "ipfs add --only-hash --quieter --cid-version=1 --raw-leaves --chunker=size-262144 FILE"
)


@dataclass(frozen=True)
class Node:
    """A block of the DAG as its parent links it."""

    cid: bytes  # binary CIDv1
    tsize: int  # the block's size plus its links' Tsize
    filesize: int  # the file bytes under it


@dataclass(frozen=True)
class CidResult:
    cid: str
    size: int
    chunks: int
    depth: int  # 0 for a single raw block

    @property
    def uri(self) -> str:
        return f"ipfs://{self.cid}"

    @property
    def kind(self) -> str:
        return "raw" if self.depth == 0 else "dag-pb"


# --- encodings ---


def varint(value: int) -> bytes:
    """Unsigned LEB128, as protobuf and multiformats write it."""
    if value < 0:
        raise ValueError("varint of a negative number")
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def base32(data: bytes) -> str:
    """RFC 4648 base32, lowercase, without padding."""
    bits = 0
    buffer = 0
    out = []
    for byte in data:
        buffer = (buffer << 8) | byte
        bits += 8
        while bits >= 5:
            bits -= 5
            out.append(_B32[(buffer >> bits) & 31])
        buffer &= (1 << bits) - 1
    if bits:
        out.append(_B32[(buffer << (5 - bits)) & 31])
    return "".join(out)


def unbase32(text: str) -> bytes:
    """The inverse of `base32`; raises `ValueError` for a character outside the alphabet."""
    bits = 0
    buffer = 0
    out = bytearray()
    for char in text:
        index = _B32.find(char)
        if index < 0:
            raise ValueError(f"not base32: {char!r}")
        buffer = (buffer << 5) | index
        bits += 5
        if bits >= 8:
            bits -= 8
            out.append((buffer >> bits) & 0xFF)
        buffer &= (1 << bits) - 1
    return bytes(out)


def binary_cid(codec: int, block: bytes) -> bytes:
    """CIDv1 of `block` under `codec` with a sha2-256 multihash."""
    return bytes([0x01, codec, SHA2_256, 32]) + hashlib.sha256(block).digest()


def text_cid(binary: bytes) -> str:
    return "b" + base32(binary)


def _field_bytes(number: int, value: bytes) -> bytes:
    return varint(number << 3 | 2) + varint(len(value)) + value


def _field_varint(number: int, value: int) -> bytes:
    return varint(number << 3) + varint(value)


def unixfs_file(children: list[Node]) -> bytes:
    """The UnixFS `Data` of an internal file node: Type File, filesize, blocksizes."""
    out = _field_varint(1, _UNIXFS_FILE) + _field_varint(3, sum(c.filesize for c in children))
    for child in children:
        out += _field_varint(4, child.filesize)
    return out


def dag_pb_node(children: list[Node]) -> bytes:
    """The dag-pb block of an internal file node: its links, then its UnixFS data."""
    out = b""
    for child in children:
        link = _field_bytes(1, child.cid) + _field_bytes(2, b"") + _field_varint(3, child.tsize)
        out += _field_bytes(2, link)
    return out + _field_bytes(1, unixfs_file(children))


# --- the balanced layout ---


def _leaf(chunk: bytes) -> Node:
    return Node(binary_cid(CODEC_RAW, chunk), len(chunk), len(chunk))


def _internal(children: list[Node]) -> Node:
    block = dag_pb_node(children)
    return Node(
        binary_cid(CODEC_DAG_PB, block),
        len(block) + sum(c.tsize for c in children),
        sum(c.filesize for c in children),
    )


class _Leaves:
    """The chunks of a stream as leaves, with one chunk of look-ahead (kubo's `Done()`)."""

    def __init__(self, chunks: Iterator[bytes]) -> None:
        self._chunks = chunks
        self._next = next(chunks, None)
        self.count = 0

    def done(self) -> bool:
        return self._next is None

    def take(self) -> Node:
        assert self._next is not None
        chunk, self._next = self._next, next(self._chunks, None)
        self.count += 1
        return _leaf(chunk)


def _fill(leaves: _Leaves, first: Node | None, depth: int, max_links: int) -> Node:
    """`fillNodeRec`: a node of `depth` holding `first` (if any), then leaves (depth 1) or
    filled subtrees of `depth - 1`, while it has room and data remains."""
    children = [first] if first is not None else []
    while len(children) < max_links and not leaves.done():
        children.append(
            leaves.take() if depth == 1 else _fill(leaves, None, depth - 1, max_links)
        )
    return _internal(children)


def _layout(chunks: Iterator[bytes], max_links: int) -> tuple[Node, int, int]:
    leaves = _Leaves(chunks)
    if leaves.done():
        return _leaf(b""), 0, 0
    root = leaves.take()
    depth = 0
    while not leaves.done():
        depth += 1
        root = _fill(leaves, root, depth, max_links)
    return root, leaves.count, depth


def _chunks_of(stream: BinaryIO, chunk_size: int) -> Iterator[bytes]:
    while True:
        chunk = stream.read(chunk_size)
        while chunk and len(chunk) < chunk_size:
            more = stream.read(chunk_size - len(chunk))
            if not more:
                break
            chunk += more
        if not chunk:
            return
        yield chunk


def cid_of_stream(
    stream: BinaryIO, chunk_size: int = CHUNK_SIZE, max_links: int = MAX_LINKS
) -> CidResult:
    """The profile's CID of everything `stream` yields, read one chunk at a time."""
    if chunk_size <= 0 or max_links < 2:
        raise ValueError("the chunk size must be positive and a node must hold two links")
    root, chunks, depth = _layout(_chunks_of(stream, chunk_size), max_links)
    return CidResult(text_cid(root.cid), root.filesize, max(chunks, 1), depth)


def cid_of_bytes(data: bytes, chunk_size: int = CHUNK_SIZE, max_links: int = MAX_LINKS) -> CidResult:
    chunks = (data[i : i + chunk_size] for i in range(0, len(data), chunk_size))
    if chunk_size <= 0 or max_links < 2:
        raise ValueError("the chunk size must be positive and a node must hold two links")
    root, count, depth = _layout(iter(chunks), max_links)
    return CidResult(text_cid(root.cid), root.filesize, max(count, 1), depth)


# --- the locator rule ---


_CID_CHARS = set(_B32)
_CID_LAST = set("aeimquy4")


def locator_accepted(uri: str) -> bool:
    """`WorkRecords._checkUri` for an IPFS locator, restated: `ipfs://` then `bafkrei` or
    `bafybei`, a character in `a`-`h`, base32 characters, 66 bytes in all, and a last character
    whose two padding bits are zero."""
    if len(uri) != 66 or not (uri.startswith("ipfs://bafkrei") or uri.startswith("ipfs://bafybei")):
        return False
    if not "a" <= uri[14] <= "h" or uri[-1] not in _CID_LAST:
        return False
    return all(c in _CID_CHARS for c in uri[15:-1])


def describe(text: str) -> tuple[int, int, bytes]:
    """The version, codec and sha2-256 digest of a profile CID; raises `ValueError` otherwise."""
    if not text.startswith("b"):
        raise ValueError("not a base32 multibase CID")
    raw = unbase32(text[1:])
    if len(raw) != 36 or raw[0] != 1 or raw[2] != SHA2_256 or raw[3] != 32:
        raise ValueError("not a CIDv1 with a 32-byte sha2-256 multihash")
    if raw[1] not in (CODEC_RAW, CODEC_DAG_PB):
        raise ValueError("not a raw or dag-pb CID")
    if text_cid(raw) != text:
        raise ValueError("not the canonical spelling")
    return raw[0], raw[1], raw[4:]
