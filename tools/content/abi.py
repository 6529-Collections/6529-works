"""Minimal ABI encoding and decoding for the `IContentStore` calls the tooling makes.

Only the shapes `ContentStore` uses are supported: `bytes`, `bytes32[]`, `string`, `uint256`,
`uint8`, `bytes32` and `address`. The encoder follows the Solidity ABI specification exactly
(head/tail layout, 32-byte padding); the Foundry test `UploaderGolden.t.sol` asserts byte
equality with `abi.encodeCall` and `abi.encode` for the golden vectors.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from .errors import AbiError
from .keccak import keccak256

WORD = 32

# --- Function selectors (the first four bytes of the keccak-256 of the canonical signature) ---


def selector(signature: str) -> bytes:
    return keccak256(signature.encode("ascii"))[:4]


WRITE_CHUNK = selector("writeChunk(bytes)")
REGISTER_MANIFEST = selector("registerManifest(bytes32[],uint256,uint8,string,bytes32)")
FILE_INFO = selector("fileInfo(bytes32)")
CHUNK_HASH = selector("chunkHash(bytes32,uint256)")
CHUNK_POINTER = selector("chunkPointer(bytes32)")
READ_CHUNK = selector("readChunk(bytes32,uint256)")
MISSING_CHUNKS = selector("missingChunks(bytes32)")
CHUNK_SIZE = selector("CHUNK_SIZE()")
MAX_CHUNKS = selector("MAX_CHUNKS()")
ATTEST_BASE64 = selector("attestBase64(bytes32)")
IS_BASE64_ATTESTED = selector("isBase64Attested(bytes32)")
ATTEST_CHUNKS_PER_CALL = selector("ATTEST_CHUNKS_PER_CALL()")

# --- Encoding ---


def uint_word(value: int) -> bytes:
    if not 0 <= value < 1 << 256:
        raise AbiError(f"value {value} does not fit uint256")
    return value.to_bytes(WORD, "big")


def bytes32_word(value: bytes) -> bytes:
    if len(value) != WORD:
        raise AbiError(f"expected 32 bytes, got {len(value)}")
    return bytes(value)


def _padded(data: bytes) -> bytes:
    return data + bytes(-len(data) % WORD)


def _dynamic_bytes(data: bytes) -> bytes:
    """The tail encoding of `bytes` and `string`: length, then the data padded to 32 bytes."""
    return uint_word(len(data)) + _padded(data)


def encode_manifest_args(
    chunk_hashes: Sequence[bytes], length: int, encoding: int, mime_type: str, sha256: bytes
) -> bytes:
    """`abi.encode(bytes32[] chunkHashes, uint256 length, uint8 encoding, string mimeType,
    bytes32 sha256Hash)`: the argument block of `registerManifest` and the preimage of the file
    ID. `encoding` is the enum's `uint8` value (an enum encodes as a full 32-byte word)."""
    if not 0 <= encoding <= 0xFF:
        raise AbiError(f"encoding {encoding} does not fit uint8")
    array_tail = uint_word(len(chunk_hashes)) + b"".join(bytes32_word(h) for h in chunk_hashes)
    head_size = 5 * WORD
    string_offset = head_size + len(array_tail)
    head = (
        uint_word(head_size)
        + uint_word(length)
        + uint_word(encoding)
        + uint_word(string_offset)
        + bytes32_word(sha256)
    )
    return head + array_tail + _dynamic_bytes(mime_type.encode("utf-8"))


def encode_register_manifest(
    chunk_hashes: Sequence[bytes], length: int, encoding: int, mime_type: str, sha256: bytes
) -> bytes:
    """Calldata for `registerManifest(bytes32[],uint256,uint8,string,bytes32)`."""
    return REGISTER_MANIFEST + encode_manifest_args(
        chunk_hashes, length, encoding, mime_type, sha256
    )


def encode_write_chunk(data: bytes) -> bytes:
    """Calldata for `writeChunk(bytes)`: selector, offset 0x20, then the length-prefixed data."""
    return WRITE_CHUNK + uint_word(WORD) + _dynamic_bytes(data)


def encode_call(sel: bytes, *words: bytes | int) -> bytes:
    """Calldata for a function whose arguments are all static words (`bytes32`, `uint256`)."""
    return sel + b"".join(uint_word(w) if isinstance(w, int) else bytes32_word(w) for w in words)


# --- Decoding ---


def _word(ret: bytes, offset: int) -> int:
    if offset < 0 or offset + WORD > len(ret):
        raise AbiError("return data is too short")
    return int.from_bytes(ret[offset : offset + WORD], "big")


def decode_uint(ret: bytes) -> int:
    return _word(ret, 0)


def decode_bool(ret: bytes) -> bool:
    value = _word(ret, 0)
    if value > 1:
        raise AbiError("not a bool")
    return bool(value)


def decode_bytes32(ret: bytes) -> bytes:
    _word(ret, 0)
    return bytes(ret[:WORD])


def decode_address(ret: bytes) -> bytes | None:
    """The 20-byte address, or `None` for the zero address."""
    value = _word(ret, 0)
    if value >> 160:
        raise AbiError("not an address")
    return None if value == 0 else value.to_bytes(20, "big")


def _decode_dynamic(ret: bytes, base: int, offset: int) -> tuple[int, int]:
    """Position and length of a dynamic value whose offset (relative to `base`) is `offset`."""
    start = base + offset
    length = _word(ret, start)
    return start + WORD, length


def decode_bytes(ret: bytes) -> bytes:
    """A single `bytes` (or `string`) return value."""
    start, length = _decode_dynamic(ret, 0, _word(ret, 0))
    if start + length > len(ret):
        raise AbiError("bytes length runs past the return data")
    return bytes(ret[start : start + length])


def decode_uint_array(ret: bytes) -> list[int]:
    """A single `uint256[]` return value."""
    start, count = _decode_dynamic(ret, 0, _word(ret, 0))
    if start + count * WORD > len(ret):
        raise AbiError("array length runs past the return data")
    return [_word(ret, start + i * WORD) for i in range(count)]


@dataclass(frozen=True)
class FileInfoData:
    """What `fileInfo` returns: the struct `IContentStore.FileInfo`."""

    sha256: bytes
    length: int
    chunk_count: int
    encoding: int
    mime_type: str


def decode_file_info(ret: bytes) -> FileInfoData:
    """The `FileInfo` struct, which is dynamic (it holds a string), so it is returned behind an
    offset: `[offset][sha256][length][chunkCount][encoding][mimeOffset] ... [mimeLen][mime]`."""
    base = _word(ret, 0)
    sha256 = bytes(ret[base : base + WORD]) if base + WORD <= len(ret) else b""
    if len(sha256) != WORD:
        raise AbiError("return data is too short")
    length = _word(ret, base + WORD)
    chunk_count = _word(ret, base + 2 * WORD)
    encoding = _word(ret, base + 3 * WORD)
    start, mime_length = _decode_dynamic(ret, base, _word(ret, base + 4 * WORD))
    if start + mime_length > len(ret):
        raise AbiError("string length runs past the return data")
    try:
        mime = bytes(ret[start : start + mime_length]).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise AbiError("the MIME type is not valid UTF-8") from exc
    return FileInfoData(sha256, length, chunk_count, encoding, mime)


# --- Custom errors, for readable revert messages ---

_ERRORS: dict[bytes, tuple[str, tuple[str, ...]]] = {}


def _register_error(name: str, types: tuple[str, ...] = ()) -> None:
    _ERRORS[selector(f"{name}({','.join(types)})")] = (name, types)


for _name, _types in (
    ("ContentFileUnknown", ("bytes32",)),
    ("ContentChunkCountInvalid", ("uint256",)),
    ("ContentLengthInvalid", ("uint256", "uint256")),
    ("ContentDigestMissing", ()),
    ("ContentMimeInvalid", ()),
    ("ContentChunkIndexOutOfBounds", ("bytes32", "uint256")),
    ("ContentRangeOutOfBounds", ("uint256", "uint256", "uint256")),
    ("ContentChunkMissing", ("bytes32", "uint256", "bytes32")),
    ("ContentChunkLengthMismatch", ("bytes32", "uint256", "uint256", "uint256")),
    ("ContentNotBase64", ("bytes32", "uint8")),
    ("ContentBase64LengthInvalid", ("bytes32", "uint256")),
    ("ContentBase64Invalid", ("bytes32", "uint256")),
    ("SSTORE2ChunkTooLarge", ("uint256",)),
    ("SSTORE2WriteFailed", ()),
    ("SSTORE2InvalidPointer", ("address",)),
    ("SSTORE2OutOfBounds", ("uint256", "uint256", "uint256")),
    ("SSTORE2HashMismatch", ("address",)),
):
    _register_error(_name, _types)

CONTENT_FILE_UNKNOWN = selector("ContentFileUnknown(bytes32)")
CONTENT_CHUNK_MISSING = selector("ContentChunkMissing(bytes32,uint256,bytes32)")
_ERROR_STRING = selector("Error(string)")
_PANIC = selector("Panic(uint256)")


def describe_revert(data: bytes) -> str:
    """A short description of revert data: a known custom error with its arguments, `Error(string)`,
    `Panic(uint256)`, or the raw selector."""
    if len(data) < 4:
        return "reverted without data"
    sel, args = data[:4], data[4:]
    try:
        if sel == _ERROR_STRING:
            return f"reverted: {decode_bytes(args).decode('utf-8', 'replace')}"
        if sel == _PANIC:
            return f"panic code {decode_uint(args):#x}"
    except AbiError:
        return f"reverted with malformed data {data[:36].hex()}"
    known = _ERRORS.get(sel)
    if known is None:
        return f"reverted with unknown error {sel.hex()}"
    name, types = known
    parts: list[str] = []
    for i, kind in enumerate(types):
        chunk = args[i * WORD : (i + 1) * WORD]
        if len(chunk) != WORD:
            return f"{name}(malformed arguments)"
        if kind in ("uint256", "uint8"):
            parts.append(str(int.from_bytes(chunk, "big")))
        elif kind == "address":
            parts.append("0x" + chunk[12:].hex())
        else:
            parts.append("0x" + chunk.hex())
    return f"{name}({', '.join(parts)})"
