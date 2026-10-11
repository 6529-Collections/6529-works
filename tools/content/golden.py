"""Golden vectors: fixed inputs with the file ID, chunk hashes and SHA-256 the store must agree on.

`golden/vectors.json` is the committed reference. `golden/samples/` holds the small sample files
(one per encoding) and the stored gzip streams. `test/content/tooling/UploaderGoldenData.sol` is
GENERATED from the vectors and carries them into Foundry, where `UploaderGolden.t.sol` registers
the same chunks on a real `ContentStore` and asserts the identical file IDs, hashes and calldata.

    python -m tools.content golden --write    # regenerate everything from the sample inputs
    python -m tools.content golden --check    # fail if a committed file is stale or inconsistent

The checks that do not depend on the zlib in use run everywhere: the committed stored streams are
decoded, re-hashed and compared. Whether THIS machine's gzip encoder still produces those exact
streams is a separate check (see `test_golden.py`), since stock zlib is stable for these settings
but forks of zlib are not.

Large vectors are generated, not committed: the media bytes are
`keccak256(abi.encode(seed, offset))` for offset 0, 32, 64, ... truncated to the length, the same
generator as `_data` in `test/content/ContentBase.sol`, so Solidity can rebuild them.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import abi, gas
from .encoding import Encoding, decode, encode
from .errors import ToolError
from .keccak import keccak256
from .plan import (
    CHUNK_SIZE,
    Plan,
    hex0x,
    parse_hex,
    plan_from_media,
    plan_from_stored,
    split_chunks,
)

ROOT = Path(__file__).resolve().parents[2]
GOLDEN_DIR = Path(__file__).resolve().parent / "golden"
SAMPLES_DIR = GOLDEN_DIR / "samples"
VECTORS_PATH = GOLDEN_DIR / "vectors.json"
SOLIDITY_PATH = ROOT / "test" / "content" / "tooling" / "UploaderGoldenData.sol"
SCHEMA = "6529-works/content-golden/v1"


@dataclass(frozen=True)
class Spec:
    """How one vector's media is produced. Exactly one of `sample` and `seed` is set."""

    name: str
    mime_type: str
    encoding: Encoding
    sample: str | None = None  # file name under golden/samples/
    seed: int | None = None  # keccak-counter generator seed
    length: int | None = None  # generated media length in bytes


OCTETS = "application/octet-stream"

SPECS: tuple[Spec, ...] = (
    Spec("identity", "image/svg+xml", Encoding.IDENTITY, sample="identity.svg"),
    Spec("gzip", "text/plain", Encoding.GZIP, sample="gzip.txt"),
    Spec("base64", "image/png", Encoding.BASE64, sample="base64.png"),
    Spec("gzipbase64", "text/javascript", Encoding.GZIP_BASE64, sample="gzipbase64.js"),
    # The layout rule's edges: one full chunk, one byte over, two full chunks.
    Spec("exact-one-chunk", OCTETS, Encoding.IDENTITY, seed=101, length=CHUNK_SIZE),
    Spec("one-chunk-plus-one", OCTETS, Encoding.IDENTITY, seed=102, length=CHUNK_SIZE + 1),
    Spec("exact-two-chunks", OCTETS, Encoding.IDENTITY, seed=103, length=2 * CHUNK_SIZE),
    # Multi-chunk files, one per encoding.
    Spec("multichunk-identity", OCTETS, Encoding.IDENTITY, seed=104, length=60_000),
    Spec("multichunk-gzip", OCTETS, Encoding.GZIP, seed=105, length=30_000),
    Spec("multichunk-base64", OCTETS, Encoding.BASE64, seed=106, length=40_000),
    Spec("multichunk-gzipbase64", OCTETS, Encoding.GZIP_BASE64, seed=107, length=30_000),
)


def counter_bytes(seed: int, length: int) -> bytes:
    """The deterministic generator shared with Solidity (`ContentBase._data`)."""
    out = bytearray()
    word = seed.to_bytes(32, "big")
    for offset in range(0, length, 32):
        out += keccak256(word + offset.to_bytes(32, "big"))
    return bytes(out[:length])


def stored_file_name(name: str) -> str:
    return f"{name}.stored"


def _media(spec: Spec) -> bytes:
    if spec.sample is not None:
        return (SAMPLES_DIR / spec.sample).read_bytes()
    assert spec.seed is not None and spec.length is not None
    return counter_bytes(spec.seed, spec.length)


def _vector(spec: Spec, plan: Plan) -> dict[str, Any]:
    source: dict[str, Any] = (
        {"kind": "file", "path": f"samples/{spec.sample}"}
        if spec.sample is not None
        else {"kind": "keccak-counter", "seed": spec.seed, "length": spec.length}
    )
    vector: dict[str, Any] = {
        "name": spec.name,
        "source": source,
        "mimeType": spec.mime_type,
        "encoding": spec.encoding.label,
        "encodingId": int(spec.encoding),
        "mediaLength": plan.media_length,
        "mediaSha256": hex0x(plan.media_sha256),
        "storedLength": plan.stored_length,
        "storedSha256": hex0x(plan.stored_sha256),
        "chunkHashes": [hex0x(h) for h in plan.chunk_hashes],
        "fileId": hex0x(plan.file_id),
        "registerCalldata": hex0x(
            abi.encode_register_manifest(
                plan.chunk_hashes, plan.stored_length, int(plan.encoding), plan.mime_type,
                plan.media_sha256,
            )
        ),
    }
    if spec.encoding.uses_gzip:
        vector["storedFile"] = f"samples/{stored_file_name(spec.name)}"
    return vector


def gas_model() -> dict[str, int]:
    return {
        "writeChunkBase": gas.WRITE_CHUNK_BASE_GAS,
        "writeChunkPerByte": gas.WRITE_CHUNK_BYTE_GAS,
        "registerBase": gas.REGISTER_BASE_GAS,
        "registerPerChunk": gas.REGISTER_CHUNK_GAS,
        "registerPerMimeByte": gas.REGISTER_MIME_BYTE_GAS,
        "registerLongMime": gas.REGISTER_LONG_MIME_GAS,
        "txGasCap": gas.TX_GAS_CAP,
    }


def build() -> tuple[dict[str, Any], dict[str, bytes]]:
    """The vectors document and the stored gzip streams, computed from the sample inputs with
    this machine's encoder."""
    vectors: list[dict[str, Any]] = []
    streams: dict[str, bytes] = {}
    for spec in SPECS:
        plan = plan_from_media(_media(spec), spec.mime_type, spec.encoding)
        vectors.append(_vector(spec, plan))
        if spec.encoding.uses_gzip:
            streams[stored_file_name(spec.name)] = plan.stored
    document = {
        "schema": SCHEMA,
        "chunkSize": CHUNK_SIZE,
        "generator": (
            "keccak-counter: media = first `length` bytes of "
            "keccak256(abi.encode(uint256 seed, uint256 offset)) for offset = 0, 32, 64, ..."
        ),
        "gasModel": gas_model(),
        "vectors": vectors,
    }
    return document, streams


# --- Solidity data ---


def _hex_literal(data: bytes) -> str:
    return f'hex"{data.hex()}"'


def _solidity_vector(
    index: int, v: dict[str, Any], stored: bytes | None, media: bytes | None
) -> str:
    inline = v["source"]["kind"] == "file"
    lines = [
        f"    function _v{index}() private pure returns (Vector memory v) {{",
        f'        v.name = "{v["name"]}";',
        f'        v.mimeType = "{v["mimeType"]}";',
        f"        v.encoding = {v['encodingId']};",
        f"        v.mediaLength = {v['mediaLength']};",
        f"        v.mediaSha256 = {v['mediaSha256']};",
        f"        v.storedLength = {v['storedLength']};",
        f"        v.chunkHashes = new bytes32[]({len(v['chunkHashes'])});",
    ]
    for i, digest in enumerate(v["chunkHashes"]):
        lines.append(f"        v.chunkHashes[{i}] = {digest};")
    lines.append(f"        v.fileId = {v['fileId']};")
    register_calldata = bytes.fromhex(v["registerCalldata"][2:])
    lines.append(f"        v.registerCalldata = {_hex_literal(register_calldata)};")
    if inline:
        assert stored is not None and media is not None
        lines.append(f"        v.media = {_hex_literal(media)};")
        lines.append(f"        v.stored = {_hex_literal(stored)};")
        chunks = split_chunks(stored)
        lines.append(f"        v.writeCalldata = new bytes[]({len(chunks)});")
        for i, chunk in enumerate(chunks):
            literal = _hex_literal(abi.encode_write_chunk(chunk))
            lines.append(f"        v.writeCalldata[{i}] = {literal};")
    else:
        lines.append(f"        v.seed = {v['source']['seed']};")
    lines.append("    }")
    return "\n".join(lines)


def render_solidity(document: dict[str, Any], streams: dict[str, bytes]) -> str:
    """`UploaderGoldenData.sol`: the vectors as Solidity, grouped by what Solidity can check."""
    vectors = document["vectors"]
    functions: list[str] = []
    inline: list[int] = []
    uploadable: list[int] = []
    hash_only: list[int] = []
    for index, v in enumerate(vectors):
        encoding = Encoding.from_id(v["encodingId"])
        source = v["source"]
        stored = media = None
        if source["kind"] == "file":
            media = (GOLDEN_DIR / source["path"]).read_bytes()
            stored = stored_stream(v, media, streams)
            inline.append(index)
        elif encoding.uses_gzip:
            hash_only.append(index)  # Solidity cannot gzip, so only hashes and IDs are checked
        else:
            uploadable.append(index)  # Solidity rebuilds the media and the base64 itself
        functions.append(_solidity_vector(index, v, stored, media))

    def group(name: str, indexes: list[int], doc: str) -> str:
        body = [
            f"    /// @dev {doc}",
            f"    function {name}() internal pure returns (Vector[] memory out) {{",
            f"        out = new Vector[]({len(indexes)});",
        ]
        body += [f"        out[{slot}] = _v{i}();" for slot, i in enumerate(indexes)]
        body.append("    }")
        return "\n".join(body)

    g = document["gasModel"]
    header = f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// GENERATED by `python -m tools.content golden --write` from tools/content/golden/vectors.json.
// Do not edit by hand: `--check` (and the Python tests) fail if this file is stale.

/// @dev Golden vectors shared with the Python uploader tooling. Each vector's expected values were
///      computed by `tools/content`; `UploaderGolden.t.sol` makes a real `ContentStore` agree.
// forgefmt: disable-start
library UploaderGoldenData {{
    /// @param encoding `IContentStore.Encoding` as its `uint8` value.
    /// @param media The decoded media (inline vectors only).
    /// @param stored The stored stream (inline vectors only).
    /// @param writeCalldata `writeChunk` calldata per chunk as the tooling encodes it (inline
    ///        vectors only).
    /// @param seed Generator seed (generated vectors only): media is the first `mediaLength` bytes
    ///        of `keccak256(abi.encode(seed, offset))` for offset 0, 32, 64, ...
    struct Vector {{
        string name;
        string mimeType;
        uint8 encoding;
        uint256 mediaLength;
        bytes32 mediaSha256;
        uint256 storedLength;
        bytes32[] chunkHashes;
        bytes32 fileId;
        bytes registerCalldata;
        bytes media;
        bytes stored;
        bytes[] writeCalldata;
        uint256 seed;
    }}

    // Gas model constants from tools/content/gas.py; the test asserts measured gas stays below it.
    uint256 internal constant GAS_WRITE_CHUNK_BASE = {g["writeChunkBase"]};
    uint256 internal constant GAS_WRITE_CHUNK_PER_BYTE = {g["writeChunkPerByte"]};
    uint256 internal constant GAS_REGISTER_BASE = {g["registerBase"]};
    uint256 internal constant GAS_REGISTER_PER_CHUNK = {g["registerPerChunk"]};
    uint256 internal constant GAS_REGISTER_PER_MIME_BYTE = {g["registerPerMimeByte"]};
    uint256 internal constant GAS_REGISTER_LONG_MIME = {g["registerLongMime"]};
    uint256 internal constant TX_GAS_CAP = {g["txGasCap"]};
"""
    parts = [
        header.rstrip(),
        group("samples", inline, "One small sample per encoding, with its bytes."),
        group(
            "generated",
            uploadable,
            "Large identity and base64 vectors Solidity rebuilds from `seed` and uploads.",
        ),
        group(
            "hashOnly",
            hash_only,
            "Large gzip vectors: Solidity cannot gzip, so it checks the file ID and registration.",
        ),
        "\n\n".join(functions),
    ]
    return "\n\n".join(parts) + "\n}\n// forgefmt: disable-end\n"


# --- Reading and checking the committed files ---


def _load() -> dict[str, Any]:
    try:
        return json.loads(VECTORS_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ToolError(f"cannot read {VECTORS_PATH}: {exc}") from exc


def committed_streams(document: dict[str, Any]) -> dict[str, bytes]:
    """The stored gzip streams committed beside the vectors, by file name."""
    out: dict[str, bytes] = {}
    for v in document["vectors"]:
        if "storedFile" in v:
            out[stored_file_name(v["name"])] = (GOLDEN_DIR / v["storedFile"]).read_bytes()
    return out


def stored_stream(vector: dict[str, Any], media: bytes, streams: dict[str, bytes]) -> bytes:
    encoding = Encoding.from_id(vector["encodingId"])
    if encoding.uses_gzip:
        return streams[stored_file_name(vector["name"])]
    return encode(media, encoding)


def check() -> list[str]:
    """Every way the committed vectors, samples and generated Solidity can be wrong or stale.
    Independent of this machine's zlib: gzip streams are read from their committed files."""
    problems: list[str] = []
    try:
        document = _load()
        streams = committed_streams(document)
    except (ToolError, OSError, KeyError) as exc:
        return [str(exc)]
    if document.get("schema") != SCHEMA:
        problems.append("vectors.json has the wrong schema")
    if document.get("gasModel") != gas_model():
        problems.append("vectors.json gasModel differs from tools/content/gas.py")
    names = [v["name"] for v in document["vectors"]]
    if names != [s.name for s in SPECS]:
        problems.append("vectors.json lists different vectors than golden.SPECS")
    for spec, v in zip(SPECS, document["vectors"]):
        try:
            problems += _check_vector(spec, v, streams)
        except (ToolError, OSError, KeyError, ValueError) as exc:
            problems.append(f"{spec.name}: {exc}")
    try:
        expected = render_solidity(document, streams)
        actual = SOLIDITY_PATH.read_text(encoding="utf-8")
        if actual != expected:
            problems.append(f"{SOLIDITY_PATH.name} is stale: run `golden --write`")
    except (ToolError, OSError, KeyError) as exc:
        problems.append(f"cannot check the Solidity data: {exc}")
    return problems


def _check_vector(spec: Spec, v: dict[str, Any], streams: dict[str, bytes]) -> list[str]:
    problems: list[str] = []
    media = _media(spec)
    stored = stored_stream(v, media, streams)
    plan = plan_from_stored(stored, v["mimeType"], Encoding.from_id(v["encodingId"]))

    def expect(label: str, actual: object, expected: object) -> None:
        if actual != expected:
            problems.append(f"{spec.name}: {label} differs from the committed vector")

    expect("mime type", v["mimeType"], spec.mime_type)
    expect("encoding", v["encodingId"], int(spec.encoding))
    expect("decoded media", decode(stored, spec.encoding), media)
    expect("media length", v["mediaLength"], len(media))
    expect("media sha256", hex0x(plan.media_sha256), v["mediaSha256"])
    expect("stored length", plan.stored_length, v["storedLength"])
    expect("stored sha256", hex0x(plan.stored_sha256), v["storedSha256"])
    expect("chunk hashes", [hex0x(h) for h in plan.chunk_hashes], v["chunkHashes"])
    expect("file ID", hex0x(plan.file_id), v["fileId"])
    calldata = abi.encode_register_manifest(
        plan.chunk_hashes, plan.stored_length, int(plan.encoding), plan.mime_type, plan.media_sha256
    )
    expect("registerManifest calldata", hex0x(calldata), v["registerCalldata"])
    parse_hex(v["fileId"], "fileId", 32)
    return problems


def write() -> None:
    document, streams = build()
    for name, data in streams.items():
        (SAMPLES_DIR / name).write_bytes(data)
    VECTORS_PATH.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8", newline="\n")
    SOLIDITY_PATH.parent.mkdir(parents=True, exist_ok=True)
    SOLIDITY_PATH.write_text(render_solidity(document, streams), encoding="utf-8", newline="\n")


def run(write_files: bool) -> int:
    if write_files:
        write()
        print(f"wrote {VECTORS_PATH.relative_to(ROOT)} and {SOLIDITY_PATH.relative_to(ROOT)}")
        return 0
    problems = check()
    for problem in problems:
        print(f"stale: {problem}")
    if not problems:
        print("golden vectors are consistent")
    return 1 if problems else 0
