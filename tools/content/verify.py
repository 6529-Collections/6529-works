"""Read a stored file back from the chain and check everything the store promises.

`verify_file` trusts neither the RPC nor the contract: it re-derives the file ID from the
manifest fields the store reports, re-hashes every chunk it reads, checks the layout, decodes the
stored bytes and compares their SHA-256 with the declared one. `rebuild` is the same pass, and
writes the decoded media only when every check holds.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any, Callable

from .encoding import Encoding, decode, encode
from .errors import RevertError, ToolError
from .plan import (
    CHUNK_SIZE,
    MAX_CHUNKS,
    chunk_count,
    chunk_hash,
    hex0x,
    manifest_id,
    validate_mime,
)
from .rpc import StoreClient
from .address import checksum_address


@dataclass
class Report:
    """The outcome of verifying one file. `ok`: registered, complete, every check passed."""

    file_id: bytes
    store: bytes
    registered: bool = False
    mime_type: str | None = None
    encoding: str | None = None
    stored_length: int | None = None
    chunk_count: int | None = None
    declared_media_sha256: bytes | None = None
    missing_chunks: list[int] = field(default_factory=list)
    bad_chunks: list[dict[str, Any]] = field(default_factory=list)
    file_id_matches: bool | None = None
    stored_length_matches: bool | None = None
    media_sha256_matches: bool | None = None
    media_length: int | None = None
    reproducible: bool | None = None
    complete: bool = False
    problems: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.registered and self.complete and not self.problems

    def to_dict(self) -> dict[str, Any]:
        return {
            "fileId": hex0x(self.file_id),
            "store": checksum_address(self.store),
            "ok": self.ok,
            "registered": self.registered,
            "complete": self.complete,
            "mimeType": self.mime_type,
            "encoding": self.encoding,
            "storedLength": self.stored_length,
            "chunkCount": self.chunk_count,
            "declaredMediaSha256": (
                hex0x(self.declared_media_sha256) if self.declared_media_sha256 else None
            ),
            "missingChunks": self.missing_chunks,
            "badChunks": self.bad_chunks,
            "fileIdMatches": self.file_id_matches,
            "storedLengthMatches": self.stored_length_matches,
            "mediaSha256Matches": self.media_sha256_matches,
            "mediaLength": self.media_length,
            "reproducible": self.reproducible,
            "problems": self.problems,
        }

    def render(self) -> str:
        lines = [
            f"file ID       {hex0x(self.file_id)}",
            f"store         {checksum_address(self.store)}",
        ]
        if not self.registered:
            lines.append("registered    no")
        else:
            lines += [
                "registered    yes",
                f"mime type     {self.mime_type}",
                f"encoding      {self.encoding}",
                f"stored        {self.stored_length:,} bytes in {self.chunk_count} chunk(s)",
                f"media sha256  {hex0x(self.declared_media_sha256 or b'')} (declared)",
                f"file ID check {_yes_no(self.file_id_matches)}",
                "chunks        "
                + (
                    "all present"
                    if not self.missing_chunks and not self.bad_chunks
                    else f"{len(self.missing_chunks)} missing, {len(self.bad_chunks)} bad"
                ),
            ]
            if self.missing_chunks:
                lines.append(f"missing       {_ranges(self.missing_chunks)}")
            for bad in self.bad_chunks:
                lines.append(f"bad chunk     {bad['index']}: {bad['problem']}")
            if self.complete:
                lines += [
                    f"length check  {_yes_no(self.stored_length_matches)}",
                    f"media sha256  {_yes_no(self.media_sha256_matches)} "
                    f"(decoded, {self.media_length:,} bytes)"
                    if self.media_length is not None
                    else "media sha256  not checked",
                    f"reproducible  {_yes_no(self.reproducible)} "
                    "(this tool's encoder gives the same stored bytes)",
                ]
        for problem in self.problems:
            lines.append(f"PROBLEM       {problem}")
        lines.append("result        " + ("OK" if self.ok else "NOT OK"))
        return "\n".join(lines)


def _yes_no(value: bool | None) -> str:
    return "n/a" if value is None else ("yes" if value else "NO")


def _ranges(indexes: list[int]) -> str:
    """`[0, 1, 2, 5]` as `0-2, 5`."""
    out: list[str] = []
    start = prev = None
    for i in indexes:
        if start is None:
            start = prev = i
        elif i == prev + 1:
            prev = i
        else:
            out.append(str(start) if start == prev else f"{start}-{prev}")
            start = prev = i
    if start is not None:
        out.append(str(start) if start == prev else f"{start}-{prev}")
    return ", ".join(out)


@dataclass
class Result:
    report: Report
    stored: bytes | None = None
    media: bytes | None = None


def verify_file(
    client: StoreClient, file_id: bytes, progress: Callable[[str], None] | None = None
) -> Result:
    """Verify `file_id` against the store behind `client`. Never raises for a bad file: every
    finding goes into the report. Raises `ToolError` only when the store cannot be queried."""
    say = progress or (lambda _message: None)
    report = Report(file_id=file_id, store=client.store)
    client.check_contract()
    info = client.file_info(file_id)
    if info is None:
        report.problems.append("no manifest is registered under this file ID in this store")
        return Result(report)

    report.registered = True
    report.mime_type = info.mime_type
    report.stored_length = info.length
    report.chunk_count = info.chunk_count
    report.declared_media_sha256 = info.sha256
    try:
        encoding = Encoding.from_id(info.encoding)
    except ToolError:
        report.problems.append(f"the store reports an unknown encoding id {info.encoding}")
        return Result(report)
    report.encoding = encoding.label

    count = info.chunk_count
    if not 1 <= count <= MAX_CHUNKS or chunk_count(info.length) != count:
        report.problems.append(
            f"the manifest's length {info.length} does not fit its {count} chunk(s)"
        )
        return Result(report)
    try:
        validate_mime(info.mime_type)
    except ToolError as exc:
        report.problems.append(f"the manifest's MIME type is invalid: {exc}")

    say(f"reading {count} chunk hash(es)")
    hashes = [client.chunk_hash(file_id, i) for i in range(count)]
    report.file_id_matches = (
        manifest_id(hashes, info.length, encoding, info.mime_type, info.sha256) == file_id
    )
    if not report.file_id_matches:
        report.problems.append(
            "the manifest the store reports does not hash to this file ID "
            "(wrong store address, or an untrustworthy RPC)"
        )

    report.missing_chunks = client.missing_chunks(file_id)
    missing = set(report.missing_chunks)
    chunks: dict[int, bytes] = {}
    for index in range(count):
        if index in missing:
            continue
        say(f"reading chunk {index + 1}/{count}")
        expected = CHUNK_SIZE if index < count - 1 else info.length - index * CHUNK_SIZE
        try:
            data = client.read_chunk(file_id, index)
        except RevertError as exc:
            report.bad_chunks.append({"index": index, "problem": str(exc)})
            continue
        if chunk_hash(data) != hashes[index]:
            report.bad_chunks.append(
                {"index": index, "problem": "bytes do not match the chunk hash"}
            )
        elif len(data) != expected:
            report.bad_chunks.append(
                {"index": index, "problem": f"length {len(data)}, layout requires {expected}"}
            )
        else:
            chunks[index] = data

    if missing:
        report.problems.append(f"{len(missing)} chunk(s) are not stored yet")
    if report.bad_chunks:
        report.problems.append(f"{len(report.bad_chunks)} stored chunk(s) failed verification")
    if missing or report.bad_chunks:
        return Result(report)

    stored = b"".join(chunks[i] for i in range(count))
    report.complete = True
    report.stored_length_matches = len(stored) == info.length
    if not report.stored_length_matches:
        report.problems.append("the stored bytes are not as long as the manifest declares")
        return Result(report, stored)
    try:
        media = decode(stored, encoding)
    except ToolError as exc:
        report.problems.append(f"the stored bytes do not decode as {encoding.label}: {exc}")
        return Result(report, stored)
    report.media_length = len(media)
    report.media_sha256_matches = hashlib.sha256(media).digest() == info.sha256
    if not report.media_sha256_matches:
        report.problems.append("the decoded media does not match the declared SHA-256")
    report.reproducible = encode(media, encoding) == stored
    return Result(report, stored, media)
