#!/usr/bin/env python3
"""Writes the replay lane's fixtures under test/fixtures/real/.

Two outputs, both reproducible byte for byte (`--check` compares and changes nothing):

- `museum-work.json`: real-data vectors from a 6529 Network Museum work. The inputs are the
  Museum's own records, copied byte for byte from a pinned commit into
  `test/fixtures/real/museum/` (Museum-authored records are CC0, the Museum's `RIGHTS.md`), and
  the digests of the work's display image (its bytes are a reproduction of a third-party
  artwork and are not copied: only its length, SHA-256, chunk hashes and pixel size are kept).
  From them it derives the 6529 Works record JSON of the work, its content-store file ID, the
  image's file ID, the `tokenURI` fragments the renderer must produce, and the hash of a
  catalogue statement citing the Museum record. `test/replay/RealVectors.t.sol` checks each one
  against the real contracts.
- `event-topics.json`: every event in the compiled ABI of each permanent contract the replay
  suites rebuild, with its canonical signature and topic0, read from Foundry's `out/`
  (run `forge build` first). `test/replay/ReplayBase.sol` requires each one to be replayed.

Usage, from the repository root (Python 3.10 or later, standard library only):

    python tools/make_vectors.py                      # write both outputs
    python tools/make_vectors.py --check              # exit 1 if a committed output differs
    python tools/make_vectors.py --refresh --museum PATH_TO_MUSEUM_CLONE [--commit REF]

`--refresh` re-copies the Museum inputs with `git show REF:PATH` (so only the commit matters,
not the clone's working tree) and recomputes the image digests. With `--museum`, `--check` also
verifies the committed inputs against the clone. Without it, `--check` verifies each copied
record against the git blob ID recorded for it at the pinned commit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.content.encoding import Encoding  # noqa: E402
from tools.content.keccak import keccak256  # noqa: E402
from tools.content.plan import chunk_hash, manifest_id, split_chunks  # noqa: E402

FIXTURES = ROOT / "test" / "fixtures" / "real"
INPUTS = FIXTURES / "museum"
SOURCE = INPUTS / "source.json"
VECTORS = FIXTURES / "museum-work.json"
TOPICS = FIXTURES / "event-topics.json"

MUSEUM_REPOSITORY = "https://github.com/6529-Collections/6529networkmuseum"
DEFAULT_COMMIT = "3926d78faacf67a62b8d9b48e15d26c43b52eae9"
# (input name, path in the Museum repository)
RECORDS = [
    ("work", "records/entities/6529NM-W-0029.json"),
    ("object", "records/accessions/6529NM.2026.003/objects/6529NM.2026.003.01.json"),
    ("artist1", "records/entities/6529NM-ART-0022.json"),
    ("artist2", "records/entities/6529NM-ART-0023.json"),
]
MEDIA_PATH = (
    "media/accessions/6529NM.2026.003/6529NM-W-0029/"
    "c1b6541832f2a237555adffae2f4870143a976549e591e2dbaa4d3d87f75d166/"
    "webp-v2-q82-m6-fixed-icc/2400.webp"
)
MEDIA_MIME = "image/webp"
RECORD_MIME = "application/json"

# The permanent contracts the replay suites rebuild: (name, artifact path under out/).
CONTRACTS = [
    ("Stream", "Stream.sol/Stream.json"),
    ("WorkRecords", "WorkRecords.sol/WorkRecords.json"),
    ("Editions", "Editions.sol/Editions.json"),
    ("ContentStore", "ContentStore.sol/ContentStore.json"),
    ("SplitLedger", "SplitLedger.sol/SplitLedger.json"),
    ("RevenueEscrow", "RevenueEscrow.sol/RevenueEscrow.json"),
    ("FederationRegistry", "FederationRegistry.sol/FederationRegistry.json"),
    ("ArtistRegistry", "ArtistRegistry.sol/ArtistRegistry.json"),
]

HASHREF_TYPEHASH = keccak256(b"HashRef(uint16 algorithm,bytes32 digest)")
STATEMENT_TYPEHASH = keccak256(
    b"Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,"
    b"bytes32 fileId,bytes32 supersedes)HashRef(uint16 algorithm,bytes32 digest)"
)
HASH_KECCAK256 = 1  # HashRef.algorithm 1: keccak256 (the Museum envelope's algorithm 1)


class VectorError(Exception):
    """A source does not reproduce, or an input is missing."""


def hex0x(data: bytes) -> str:
    return "0x" + data.hex()


def word(value: int | bytes) -> bytes:
    """One ABI word: a left-padded integer or a 32-byte value."""
    if isinstance(value, bytes):
        if len(value) != 32:
            raise ValueError("a word is 32 bytes")
        return value
    return value.to_bytes(32, "big")


def rel(path: Path) -> str:
    """`path` relative to the repository when it is inside it, for messages."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def git_blob_id(data: bytes) -> str:
    """The git object ID of a blob with these bytes (`git hash-object`)."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def canonical_json(value: Any) -> bytes:
    """Sorted keys, no whitespace, UTF-8: RFC 8785 for records with only strings, integers,
    booleans, null, arrays and objects with ASCII keys (each use is checked against the
    record's own envelope digest)."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def webp_size(data: bytes) -> tuple[int, int]:
    """The canvas width and height of a WebP image, from its RIFF header."""
    if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise VectorError("the media is not a WebP image")
    kind = data[12:16]
    if kind == b"VP8X":
        width = int.from_bytes(data[24:27], "little") + 1
        height = int.from_bytes(data[27:30], "little") + 1
    elif kind == b"VP8 ":
        width, height = struct.unpack("<HH", data[26:30])
        width, height = width & 0x3FFF, height & 0x3FFF
    elif kind == b"VP8L":
        bits = int.from_bytes(data[21:25], "little")
        width, height = (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    else:
        raise VectorError(f"unknown WebP chunk {kind!r}")
    return width, height


def media_digest(data: bytes) -> dict[str, Any]:
    width, height = webp_size(data)
    return {
        "length": len(data),
        "sha256": hex0x(hashlib.sha256(data).digest()),
        "chunkHashes": [hex0x(chunk_hash(c)) for c in split_chunks(data)],
        "width": width,
        "height": height,
    }


# ---------------------------------------------------------------------------- inputs


def git_show(museum: Path, commit: str, path: str) -> bytes:
    return subprocess.run(
        ["git", "-C", str(museum), "show", f"{commit}:{path}"], check=True, capture_output=True
    ).stdout


def read_inputs_from_clone(museum: Path, commit: str) -> tuple[dict[str, Any], dict[str, bytes]]:
    commit = subprocess.run(
        ["git", "-C", str(museum), "rev-parse", commit], check=True, capture_output=True, text=True
    ).stdout.strip()
    files = {name: git_show(museum, commit, path) for name, path in RECORDS}
    media = git_show(museum, commit, MEDIA_PATH)
    source = {
        "repository": MUSEUM_REPOSITORY,
        "commit": commit,
        "license": "Museum-authored records: CC0-1.0 (RIGHTS.md). The image is not copied: "
        "only its digests are kept.",
        "records": {
            name: {"path": path, "file": Path(path).name, "blob": git_blob_id(files[name])}
            for name, path in RECORDS
        },
        "media": {"path": MEDIA_PATH, "blob": git_blob_id(media), **media_digest(media)},
    }
    return source, {source["records"][n]["file"]: b for n, b in files.items()}


def read_committed_inputs() -> tuple[dict[str, Any], dict[str, bytes]]:
    if not SOURCE.is_file():
        raise VectorError(f"{rel(SOURCE)} is missing: run --refresh --museum PATH")
    source = json.loads(SOURCE.read_text(encoding="utf-8"))
    files = {}
    for name, entry in source["records"].items():
        data = (INPUTS / entry["file"]).read_bytes()
        if git_blob_id(data) != entry["blob"]:
            raise VectorError(
                f"{entry['file']} is not the blob {entry['blob']} of the pinned commit"
            )
        files[entry["file"]] = data
    return source, files


def source_json(source: dict[str, Any]) -> str:
    return json.dumps(source, indent=2, ensure_ascii=False) + "\n"


# ---------------------------------------------------------------------------- the vectors


def build_vectors(source: dict[str, Any], files: dict[str, bytes]) -> dict[str, Any]:
    records = {name: json.loads(files[e["file"]]) for name, e in source["records"].items()}
    work = records["work"]
    envelope = work["envelope"]
    digest = keccak256(canonical_json(work["payload"]))
    if hex0x(digest) != envelope["contentHash"]["digest"]:
        raise VectorError("the work record's payload does not reproduce its envelope digest")
    if envelope["contentHash"]["algorithm"] != HASH_KECCAK256:
        raise VectorError("the work record's content hash is not keccak256")
    profile = work["payload"]["profile"]
    obj = records["object"]["payload"]
    media = source["media"]
    stream_record = {
        "name": obj["title"],
        "description": profile["identity_boundary"]
        + " 6529 Network Museum record "
        + work["payload"]["record_id"]
        + ".",
        "artists": [
            records["artist1"]["payload"]["preferred_label"],
            records["artist2"]["payload"]["preferred_label"],
        ],
        "year": int(profile["creation_date"]["display"]),
        "medium": obj["medium"],
        "dimensions": f"{media['width']} x {media['height']} px (Museum display image)",
    }
    record_bytes = json.dumps(stream_record, separators=(",", ":"), ensure_ascii=False).encode()
    if len(record_bytes) > 12_288:
        raise VectorError("the derived record exceeds the renderer's 12 KiB")
    record_chunks = [chunk_hash(c) for c in split_chunks(record_bytes)]
    record_sha = hashlib.sha256(record_bytes).digest()
    record_id = manifest_id(
        record_chunks, len(record_bytes), Encoding.IDENTITY, RECORD_MIME, record_sha
    )
    media_chunks = [bytes.fromhex(h[2:]) for h in media["chunkHashes"]]
    media_sha = bytes.fromhex(media["sha256"][2:])
    media_id = manifest_id(media_chunks, media["length"], Encoding.IDENTITY, MEDIA_MIME, media_sha)

    subject = bytes.fromhex(envelope["subjectId"][2:])
    kind = keccak256(b"CATALOGUE_ENTRY")
    schema = bytes.fromhex(envelope["schemaId"][2:])
    uri = envelope["uri"]
    content = keccak256(word(HASHREF_TYPEHASH) + word(HASH_KECCAK256) + word(digest))
    statement_hash = keccak256(
        word(STATEMENT_TYPEHASH)
        + word(0)  # token: the pre-mint subject names no token
        + word(subject)
        + word(kind)
        + word(schema)
        + word(content)
        + word(keccak256(uri.encode()))
        + word(0)  # fileId: one locator only, the Museum's URI (DSP)
        + word(0)  # supersedes
    )

    def escaped(text: str) -> str:
        # The renderer copies the record's JSON text and percent-escapes `%` and `#` (RND).
        return text.replace("%", "%25").replace("#", "%23")

    def js(value: Any) -> str:
        return json.dumps(value, ensure_ascii=False)

    fragments = [escaped('"name":' + js(stream_record["name"]))]
    fragments += [
        escaped('{"trait_type":"Artist","value":' + js(a) + "}") for a in stream_record["artists"]
    ]
    fragments.append('{"trait_type":"Year","value":' + str(stream_record["year"]) + "}")
    for trait in ("Medium", "Dimensions"):
        value = js(stream_record[trait.lower()])
        fragments.append(escaped('{"trait_type":"' + trait + '","value":' + value + "}"))

    return {
        "source": {
            "repository": source["repository"],
            "commit": source["commit"],
            "license": source["license"],
        },
        "museumRecord": {
            "path": source["records"]["work"]["path"],
            "recordId": work["payload"]["record_id"],
            "subjectId": envelope["subjectId"],
            "schemaId": envelope["schemaId"],
            "contentDigest": hex0x(digest),
            "uri": uri,
        },
        "record": {
            "json": record_bytes.decode(),
            "bytes": hex0x(record_bytes),
            "length": len(record_bytes),
            "sha256": hex0x(record_sha),
            "chunkHashes": [hex0x(h) for h in record_chunks],
            "mimeType": RECORD_MIME,
            "fileId": hex0x(record_id),
        },
        "media": {
            "path": media["path"],
            "length": media["length"],
            "sha256": media["sha256"],
            "chunkHashes": media["chunkHashes"],
            "mimeType": MEDIA_MIME,
            "fileId": hex0x(media_id),
        },
        "tokenUriFragments": fragments,
        "statement": {
            "kind": hex0x(kind),
            "schema": hex0x(schema),
            "contentAlgorithm": HASH_KECCAK256,
            "contentDigest": hex0x(digest),
            "uri": uri,
            "statementHash": hex0x(statement_hash),
        },
    }


# ---------------------------------------------------------------------------- event topics


def canonical_type(param: dict[str, Any]) -> str:
    kind = param["type"]
    if kind.startswith("tuple"):
        inner = ",".join(canonical_type(c) for c in param["components"])
        return f"({inner}){kind[len('tuple'):]}"
    return kind


def event_signatures(abi_entries: list[dict[str, Any]]) -> list[str]:
    signatures = {
        e["name"] + "(" + ",".join(canonical_type(p) for p in e["inputs"]) + ")"
        for e in abi_entries
        if e.get("type") == "event"
    }
    return sorted(signatures)


def build_topics(out_dir: Path) -> dict[str, Any]:
    topics: dict[str, Any] = {}
    for name, artifact in CONTRACTS:
        path = out_dir / artifact
        if not path.is_file():
            raise VectorError(f"{rel(path)} is missing: run `forge build` first")
        signatures = event_signatures(json.loads(path.read_text(encoding="utf-8"))["abi"])
        topics[name] = {
            "signatures": signatures,
            "topics": [hex0x(keccak256(s.encode())) for s in signatures],
        }
    return topics


def dump(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


# ---------------------------------------------------------------------------- main


def write_or_check(path: Path, text: str, check: bool) -> bool:
    if check:
        current = path.read_text(encoding="utf-8") if path.is_file() else None
        if current != text:
            print(f"{rel(path)} differs from what make_vectors.py writes")
            return False
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {rel(path)}")
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--check", action="store_true", help="compare, write nothing")
    parser.add_argument(
        "--refresh", action="store_true", help="re-copy the Museum inputs (needs --museum)"
    )
    parser.add_argument("--museum", type=Path, help="a clone of the Museum repository")
    parser.add_argument("--commit", default=DEFAULT_COMMIT, help="the Museum commit to read")
    parser.add_argument("--out-dir", type=Path, default=ROOT / "out", help="Foundry's artifacts")
    args = parser.parse_args(argv)
    if args.refresh and (args.check or args.museum is None):
        parser.error("--refresh needs --museum and cannot be combined with --check")
    try:
        ok = True
        if args.museum is not None:
            source, files = read_inputs_from_clone(args.museum, args.commit)
            if args.refresh:
                for name, data in files.items():
                    (INPUTS / name).parent.mkdir(parents=True, exist_ok=True)
                    (INPUTS / name).write_bytes(data)
                write_or_check(SOURCE, source_json(source), False)
            else:
                ok &= write_or_check(SOURCE, source_json(source), True)
                for name, data in files.items():
                    if not (INPUTS / name).is_file() or (INPUTS / name).read_bytes() != data:
                        print(f"{name} differs from the Museum clone")
                        ok = False
        source, files = read_committed_inputs()
        ok &= write_or_check(VECTORS, dump(build_vectors(source, files)), args.check)
        ok &= write_or_check(TOPICS, dump(build_topics(args.out_dir)), args.check)
    except (VectorError, subprocess.CalledProcessError, OSError, KeyError) as error:
        print(f"make_vectors: {error}", file=sys.stderr)
        return 2
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
