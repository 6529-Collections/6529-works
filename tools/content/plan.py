"""Chunking, hashing and file IDs, exactly as `ContentStore` defines them, and the plan manifest.

The rules mirrored from `src/content/ContentStore.sol`:

- every chunk except the last holds exactly `CHUNK_SIZE` (24,575) bytes, and a file has 1 to
  `MAX_CHUNKS` (512) chunks;
- a chunk's hash is `keccak256(chunk bytes)`;
- the file ID is `keccak256(abi.encode(bytes32[] chunkHashes, uint256 length, uint8 encoding,
  string mimeType, bytes32 sha256Hash))`, where `length` is the STORED length and `sha256Hash`
  is the SHA-256 of the fully DECODED media;
- the MIME type is lowercase `type/subtype` from `[a-z0-9+._-]`, at most 64 bytes, with exactly
  one interior slash.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterator, Sequence

from . import abi
from .encoding import (
    GZIP_HEADER,
    MAX_DECODED_BYTES,
    GZIP_LEVEL,
    GZIP_MEM_LEVEL,
    GZIP_WINDOW_BITS,
    Encoding,
    decode,
    encode,
)
from .errors import ToolError
from .keccak import keccak256

CHUNK_SIZE = 24_575  # SSTORE2.MAX_CHUNK_LENGTH: EIP-170's 24,576 minus the STOP byte
MAX_CHUNKS = 512  # IContentStore.MAX_CHUNKS
MAX_MIME_LENGTH = 64  # ContentStore.MAX_MIME_LENGTH
MAX_STORED_BYTES = CHUNK_SIZE * MAX_CHUNKS  # 12,582,400

SCHEMA = "6529-works/content-plan/v1"

_MIME_CHARS = re.compile(r"[a-z0-9+._-]+")


def validate_mime(mime_type: str) -> None:
    """Apply `ContentStore._requireMime`: lowercase `type/subtype`, one interior slash."""
    try:
        raw = mime_type.encode("ascii")
    except UnicodeEncodeError:
        raise ToolError("MIME type must be ASCII") from None
    if len(raw) > MAX_MIME_LENGTH:
        raise ToolError(f"MIME type is longer than {MAX_MIME_LENGTH} bytes")
    kind, slash, subtype = mime_type.partition("/")
    if (
        not slash
        or not kind
        or not subtype
        or not _MIME_CHARS.fullmatch(kind)
        or not _MIME_CHARS.fullmatch(subtype)
    ):
        raise ToolError(
            f"invalid MIME type {mime_type!r}: the store accepts lowercase type/subtype from "
            "[a-z0-9+._-] with exactly one slash and no parameters (for example text/html)"
        )


def chunk_count(stored_length: int) -> int:
    """`ceil(stored_length / CHUNK_SIZE)`."""
    return -(-stored_length // CHUNK_SIZE)


def check_stored_length(stored_length: int) -> None:
    """Reject a stream the store could not hold: empty, or more than `MAX_CHUNKS` chunks."""
    if stored_length <= 0:
        raise ToolError("the stored stream is empty; the store needs at least one byte")
    count = chunk_count(stored_length)
    if count > MAX_CHUNKS:
        raise ToolError(
            f"the stored stream is {stored_length:,} bytes, {count} chunks; the store accepts "
            f"at most {MAX_CHUNKS} chunks ({MAX_STORED_BYTES:,} bytes)"
        )


def max_input_bytes(encoding: Encoding, already_encoded: bool) -> int:
    """The largest input file `plan` will even read. The stored stream is capped at
    `MAX_STORED_BYTES`, so an identity or already-encoded input cannot be larger, base64 media
    cannot exceed three quarters of it, and gzip can shrink anything, so only the decoder's
    own bound applies. Checked from the file size, before the file is read into memory."""
    if already_encoded or encoding == Encoding.IDENTITY:
        return MAX_STORED_BYTES
    if encoding == Encoding.BASE64:
        return MAX_STORED_BYTES // 4 * 3
    return MAX_DECODED_BYTES


def split_chunks(stored: bytes) -> list[bytes]:
    """Canonical chunking: full `CHUNK_SIZE` pieces, then the shorter remainder."""
    check_stored_length(len(stored))
    view = memoryview(stored)
    return [bytes(view[i : i + CHUNK_SIZE]) for i in range(0, len(stored), CHUNK_SIZE)]


def chunk_hash(chunk: bytes) -> bytes:
    """`ContentStore.writeChunk`'s hash of a chunk."""
    return keccak256(chunk)


def manifest_id(
    chunk_hashes: Sequence[bytes], length: int, encoding: Encoding, mime_type: str, sha256: bytes
) -> bytes:
    """`ContentStore.manifestId`: the chain- and deployment-independent file ID."""
    preimage = abi.encode_manifest_args(chunk_hashes, length, int(encoding), mime_type, sha256)
    return keccak256(preimage)


def hex0x(value: bytes) -> str:
    return "0x" + value.hex()


def parse_hex(text: Any, field_name: str, size: int | None = None) -> bytes:
    """Strict `0x` + lowercase-or-uppercase hex, optionally of a fixed byte size."""
    if not isinstance(text, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", text):
        raise ToolError(f"{field_name} must be a 0x-prefixed hex string")
    raw = bytes.fromhex(text[2:])
    if size is not None and len(raw) != size:
        raise ToolError(f"{field_name} must be {size} bytes, got {len(raw)}")
    return raw


@dataclass(frozen=True)
class Plan:
    """Everything the store needs for one file, derived from the bytes.

    `reproducible` records the reproduction check: decoding `stored` and encoding the result again
    gives `stored` byte for byte. It is always true for a plan built from media, and for a plan
    built from an already-encoded stream it says whether this tool's encoder would have produced
    that stream (a foreign gzip stream is valid and storable but not reproducible).
    """

    mime_type: str
    encoding: Encoding
    media_sha256: bytes
    media_length: int
    stored: bytes = field(repr=False)
    chunk_hashes: tuple[bytes, ...]
    file_id: bytes
    reproducible: bool

    @property
    def stored_length(self) -> int:
        return len(self.stored)

    @property
    def stored_sha256(self) -> bytes:
        return hashlib.sha256(self.stored).digest()

    def chunks(self) -> Iterator[bytes]:
        view = memoryview(self.stored)
        for i in range(0, len(self.stored), CHUNK_SIZE):
            yield bytes(view[i : i + CHUNK_SIZE])


def _build(
    stored: bytes, media_sha256: bytes, media_length: int, mime_type: str, encoding: Encoding,
    reproducible: bool,
) -> Plan:
    chunks = split_chunks(stored)
    hashes = tuple(chunk_hash(c) for c in chunks)
    file_id = manifest_id(hashes, len(stored), encoding, mime_type, media_sha256)
    return Plan(
        mime_type, encoding, media_sha256, media_length, bytes(stored), hashes, file_id,
        reproducible,
    )


def plan_from_media(media: bytes, mime_type: str, encoding: Encoding) -> Plan:
    """Encode `media` and plan its upload, proving the encoding reproduces.

    The proof: the stored stream decodes back to `media`, and encoding that decoded media again
    yields the same stream. A failure means the encoder is not deterministic on this machine, so
    no plan is produced.
    """
    validate_mime(mime_type)
    stored = encode(media, encoding)
    check_stored_length(len(stored))  # before any hashing, so an oversize file fails fast
    decoded = decode(stored, encoding)
    if decoded != media or encode(decoded, encoding) != stored:
        raise ToolError("the encoding does not reproduce: re-encoding the decoded media differs")
    return _build(stored, hashlib.sha256(media).digest(), len(media), mime_type, encoding, True)


def plan_from_stored(stored: bytes, mime_type: str, encoding: Encoding) -> Plan:
    """Plan the upload of an already-encoded stream (for example one fetched from Arweave).

    The stream must decode cleanly under `encoding`; the media SHA-256 comes from the decoded
    bytes. `reproducible` reports whether this tool's encoder reproduces the stream.
    """
    validate_mime(mime_type)
    check_stored_length(len(stored))
    media = decode(stored, encoding)
    reproducible = encode(media, encoding) == stored
    digest = hashlib.sha256(media).digest()
    return _build(stored, digest, len(media), mime_type, encoding, reproducible)


# --- The manifest file ---


def encoder_description(encoding: Encoding) -> dict[str, Any] | None:
    """The gzip profile in effect, recorded for the humans reproducing a stream elsewhere."""
    if not encoding.uses_gzip:
        return None
    return {
        "gzip": {
            "header": GZIP_HEADER.hex(),
            "deflate": {
                "library": "zlib",
                "level": GZIP_LEVEL,
                "memLevel": GZIP_MEM_LEVEL,
                "windowBits": GZIP_WINDOW_BITS,
                "strategy": "default",
            },
            "zlibVersion": zlib.ZLIB_RUNTIME_VERSION,
        }
    }


def manifest_dict(plan: Plan, stored_file: str | None, source_name: str | None) -> dict[str, Any]:
    """The JSON manifest for `plan`, in a fixed key order. Deterministic: no timestamps."""
    out: dict[str, Any] = {
        "schema": SCHEMA,
        "fileId": hex0x(plan.file_id),
        "mimeType": plan.mime_type,
        "encoding": plan.encoding.label,
        "encodingId": int(plan.encoding),
        "mediaSha256": hex0x(plan.media_sha256),
        "mediaLength": plan.media_length,
        "storedLength": plan.stored_length,
        "storedSha256": hex0x(plan.stored_sha256),
        "chunkSize": CHUNK_SIZE,
        "chunkCount": len(plan.chunk_hashes),
        "chunkHashes": [hex0x(h) for h in plan.chunk_hashes],
        "reproducible": plan.reproducible,
    }
    encoder = encoder_description(plan.encoding)
    if encoder is not None:
        out["encoder"] = encoder
    if stored_file is not None:
        out["storedFile"] = stored_file
    if source_name is not None:
        out["source"] = source_name
    return out


def manifest_json(manifest: dict[str, Any]) -> str:
    return json.dumps(manifest, indent=2) + "\n"


@dataclass(frozen=True)
class Manifest:
    """A manifest read back from disk, with every derived field re-checked."""

    file_id: bytes
    mime_type: str
    encoding: Encoding
    media_sha256: bytes
    media_length: int | None
    stored_length: int
    stored_sha256: bytes | None
    chunk_hashes: tuple[bytes, ...]
    stored_file: str | None


def load_manifest(path: Path) -> Manifest:
    """Read a manifest, rejecting anything inconsistent: the file ID must be the hash of the
    declared fields, the chunk list must fit the stored length, and the MIME type must be valid."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ToolError(f"cannot read manifest {path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        raise ToolError(f"{path} is not a {SCHEMA} manifest")
    for key in ("fileId", "mimeType", "encodingId", "mediaSha256", "storedLength", "chunkHashes"):
        if key not in data:
            raise ToolError(f"manifest is missing {key!r}")

    encoding_id = data["encodingId"]
    if not isinstance(encoding_id, int) or isinstance(encoding_id, bool):
        raise ToolError("manifest encodingId must be an integer")
    encoding = Encoding.from_id(encoding_id)
    if "encoding" in data and data["encoding"] != encoding.label:
        raise ToolError("manifest encoding and encodingId disagree")

    mime_type = data["mimeType"]
    if not isinstance(mime_type, str):
        raise ToolError("manifest mimeType must be a string")
    validate_mime(mime_type)

    stored_length = data["storedLength"]
    if not isinstance(stored_length, int) or isinstance(stored_length, bool):
        raise ToolError("manifest storedLength must be an integer")
    check_stored_length(stored_length)

    hashes_raw = data["chunkHashes"]
    if not isinstance(hashes_raw, list):
        raise ToolError("manifest chunkHashes must be a list")
    hashes = tuple(parse_hex(h, "chunkHashes[]", 32) for h in hashes_raw)
    if len(hashes) != chunk_count(stored_length):
        raise ToolError(
            f"manifest lists {len(hashes)} chunks but a stored length of {stored_length} needs "
            f"{chunk_count(stored_length)}"
        )
    if "chunkCount" in data and data["chunkCount"] != len(hashes):
        raise ToolError("manifest chunkCount disagrees with chunkHashes")
    if "chunkSize" in data and data["chunkSize"] != CHUNK_SIZE:
        raise ToolError(f"manifest chunkSize is not {CHUNK_SIZE}")

    media_sha256 = parse_hex(data["mediaSha256"], "mediaSha256", 32)
    if media_sha256 == bytes(32):
        raise ToolError("manifest mediaSha256 is zero; the store rejects a zero digest")
    file_id = parse_hex(data["fileId"], "fileId", 32)
    expected = manifest_id(hashes, stored_length, encoding, mime_type, media_sha256)
    if file_id != expected:
        raise ToolError(
            f"manifest fileId {hex0x(file_id)} is not the hash of its fields ({hex0x(expected)})"
        )

    media_length = data.get("mediaLength")
    if media_length is not None and (
        not isinstance(media_length, int) or isinstance(media_length, bool) or media_length < 0
    ):
        raise ToolError("manifest mediaLength must be a non-negative integer")
    stored_sha256 = (
        parse_hex(data["storedSha256"], "storedSha256", 32) if "storedSha256" in data else None
    )
    stored_file = data.get("storedFile")
    if stored_file is not None and not isinstance(stored_file, str):
        raise ToolError("manifest storedFile must be a string")
    return Manifest(
        file_id, mime_type, encoding, media_sha256, media_length, stored_length, stored_sha256,
        hashes, stored_file,
    )


def check_stored(manifest: Manifest, stored: bytes) -> None:
    """Prove `stored` is the stream the manifest commits to, before anything is sent: the length,
    every chunk hash, and the decoded media's SHA-256 (and length, when the manifest has one)."""
    if len(stored) != manifest.stored_length:
        raise ToolError(
            f"stored stream is {len(stored)} bytes but the manifest says {manifest.stored_length}"
        )
    stored_digest = hashlib.sha256(stored).digest()
    if manifest.stored_sha256 is not None and stored_digest != manifest.stored_sha256:
        raise ToolError("stored stream does not match the manifest's storedSha256")
    for index, chunk in enumerate(split_chunks(stored)):
        if chunk_hash(chunk) != manifest.chunk_hashes[index]:
            raise ToolError(f"chunk {index} of the stored stream does not match the manifest")
    media = decode(stored, manifest.encoding)
    if hashlib.sha256(media).digest() != manifest.media_sha256:
        raise ToolError("the decoded media does not match the manifest's mediaSha256")
    if manifest.media_length is not None and len(media) != manifest.media_length:
        raise ToolError("the decoded media length does not match the manifest's mediaLength")


def resolve_stored_path(manifest_path: Path, stored_file: str) -> Path:
    """The stored-stream file named by a manifest. It must sit beside the manifest: a manifest
    from someone else must not be able to point the tool at an arbitrary local file."""
    name = Path(stored_file)
    plain = len(name.parts) == 1 and name.name not in (".", "..")
    if name.is_absolute() or not plain or "\\" in stored_file:
        raise ToolError(
            f"manifest storedFile {stored_file!r} must be a plain file name beside the manifest"
        )
    return Path(manifest_path).resolve().parent / name


def write_new_file(path: Path, data: bytes, force: bool) -> None:
    """Write `data` to `path` atomically, refusing to overwrite unless `force`."""
    path = Path(path)
    if path.exists() and not force:
        raise ToolError(f"{path} already exists (use --force to overwrite)")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_bytes(data)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()
