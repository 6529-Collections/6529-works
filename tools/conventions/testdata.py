"""Shared test inputs built from the committed examples in docs/spec/schemas/examples/.

Not a test module itself (no `test_` prefix): the tests import it.
"""

from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
from typing import Any

from . import jcs, schema
from .floor import DECLARATIONS_MIME

ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = ROOT / "docs" / "spec" / "schemas" / "examples"

#: Every example file and the schema it follows.
EXAMPLE_SCHEMAS = {
    "catalogue.json": "catalogue",
    "catalogue-entry.json": "catalogue-entry",
    "citation.json": "citation",
    "content-change-acceptance.json": "content-change-acceptance",
    "content-change-proposal.json": "content-change-proposal",
    "content-change-restore.json": "content-change-acceptance",
    "control-proof.json": "control-proof",
    "custody-attestation.json": "custody-attestation",
    "declarations.json": "declarations",
    "declarations-generative.json": "declarations",
    "declarations-time-capsule.json": "declarations",
    "floor-result.json": "floor-result",
    "promise-card.json": "promise-card",
    "promise-grade.json": "promise-grade",
}

ANVIL_0 = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"  # public Anvil test account 0
ANVIL_1 = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
ZERO = "0x" + "00" * 20
ZERO32 = "0x" + "00" * 32
DECL_FILE = "0x" + "66" * 32
LICENSE_TEXT = "0x" + "77" * 32
CC0_TEXT_SHA = "0xa2010f343487d3f7618affe54f789f5487602331c0a8d03f49e9a7c547cf0499"
RENDERER = "0xa4d100c8f6faed2d7db97a3bc68f9e215a8aea8f"


def example(name: str) -> Any:
    return json.loads((EXAMPLES / name).read_text(encoding="utf-8"))


def canonical(doc: Any) -> bytes:
    return jcs.canonicalize(doc)


def sha(data: bytes) -> str:
    return "0x" + hashlib.sha256(data).hexdigest()


def receipts_observed(doc: dict) -> dict[str, str]:
    """Every receipt URI of a declarations document mapped to its file's SHA-256 (a good copy)."""
    out = {}
    for f in doc.get("conservation", {}).get("storage", {}).get("files", []):
        for r in f["receipts"]:
            out[r["uri"]] = f["sha256"]
    return out


def floor_input(doc: dict, media: list[tuple[str, str, str, str]], *, seed: str = "NONE",
                record_deps: Any = None, decl_bytes: bytes | None = None) -> dict:
    """`media`: (fileId, sha256, role, mime) for each non-declarations file, in order; the
    declarations file is appended last as AUXILIARY."""
    data = canonical(doc) if decl_bytes is None else decl_bytes
    files = {LICENSE_TEXT: {"sha256Hash": CC0_TEXT_SHA, "length": 7048, "encoding": "Identity",
                            "mimeType": "text/plain", "complete": True}}
    entries = []
    for fid, digest, role, mime in media:
        entries.append({"fileId": fid, "sha256Hash": digest, "role": role})
        files[fid] = {"sha256Hash": digest, "length": 1000, "encoding": "Identity",
                      "mimeType": mime, "complete": True}
    entries.append({"fileId": DECL_FILE, "sha256Hash": sha(data), "role": "AUXILIARY"})
    files[DECL_FILE] = {"sha256Hash": sha(data), "length": len(data), "encoding": "Identity",
                        "mimeType": DECLARATIONS_MIME, "complete": True}
    dims = {}
    for f in doc.get("conservation", {}).get("format", {}).get("files", []):
        if "width" in f:
            dims[f["fileId"]] = {"width": f["width"], "height": f["height"]}
    return {
        "package": {
            "item": {"contentHash": doc["contentHash"], "seedPolicy": seed,
                     "license": {"spdxId": "CC0-1.0", "textFileId": LICENSE_TEXT},
                     "recordDependencies": record_deps},
            "media": entries,
            "files": files,
        },
        "policy": {"requiresDeclarations": True, "waivable": [], "allowsTimeCapsule": False},
        "contents": {DECL_FILE: data},
        "observed": {"fetched": receipts_observed(doc), "dimensions": dims,
                     "defaultRenderer": RENDERER, "codeHash": {RENDERER: "0x" + "44" * 32},
                     "dependencies": {}},
    }


def still_floor_input() -> dict:
    doc = example("declarations.json")
    return floor_input(doc, [
        ("0x" + "11" * 32, "0x0899f7c16ef4cb9720aa1e6d9cf54481e1667ba856dd5a8fd962dc0bfac1d4da", "PRIMARY", "image/png"),
        ("0x" + "22" * 32, "0x38d991bcec7d27ad28bffa161f122d8d619642858b4af6987a458fbc1978489f", "PREVIEW", "image/webp"),
    ])  # fmt: skip


def generative_floor_input() -> dict:
    doc = example("declarations-generative.json")
    return floor_input(doc, [
        ("0x" + "33" * 32, "0xd0055a8735b5a69a40b9bf41ba553896ca536bcdd61444737a043a2f79d74e64", "PRIMARY", "text/javascript"),
    ], seed="VRF", record_deps=[])  # fmt: skip


CIPHERTEXT_FILE = "0x" + "55" * 32


def time_capsule_floor_input() -> dict:
    """The time-capsule example: the sealed PRIMARY image and the ciphertext as an AUXILIARY file."""
    doc = example("declarations-time-capsule.json")
    return floor_input(doc, [
        ("0x" + "11" * 32, "0x0899f7c16ef4cb9720aa1e6d9cf54481e1667ba856dd5a8fd962dc0bfac1d4da", "PRIMARY", "image/png"),
        (CIPHERTEXT_FILE, "0x" + "5c" * 32, "AUXILIARY", "application/octet-stream"),
    ])  # fmt: skip


def example_card_inputs() -> dict:
    """Reads and documents that reproduce the example promise card (see test_card)."""
    decl = canonical(example("declarations.json"))
    custody_doc = example("custody-attestation.json")
    card = example("promise-card.json")
    f1, f2 = "0x" + "11" * 32, "0x" + "22" * 32
    still = example("declarations.json")["conservation"]["storage"]["files"]
    locs = {f["fileId"]: [{"kind": "ARWEAVE" if r["network"] == "arweave" else "IPFS", "uri": r["uri"]}
                          for r in f["receipts"]] for f in still}  # fmt: skip
    roles = copy.deepcopy(card["changeable"])
    for row in roles:
        del row["until"]
        if row["what"] == "renderer":
            row["phase"] = "afterFinalize"
    roles += [
        {"what": "record", "who": ["ARTIST"], "delaySeconds": 0, "guardianCancel": False},
        {"what": "license", "who": ["EVERY_PARTY", "PARAMETER_SETTER"], "delaySeconds": 172800,
         "guardianCancel": True},
        {"what": "renderer", "who": ["SUCCESSOR_SETTER"], "delaySeconds": 2592000,
         "guardianCancel": True, "phase": "beforeFinalize"},
        {"what": "burn_and_release", "who": ["PLATFORM", "PARAMETER_SETTER"], "delaySeconds": 172800,
         "guardianCancel": True},
    ]  # fmt: skip
    return {
        "generator": card["generator"],
        "reads": {
            "at": card["at"],
            "token": card["work"]["token"],
            "tokenId": "42",
            "WorkMinted": {"contentHash": card["work"]["contentHash"]},
            "Stream": {
                "ownerOf": card["work"]["owner"],
                "coreOf": {"itemHash": card["work"]["itemHash"], "artistId": card["work"]["artistId"],
                           "collectionId": "1", "kind": "ORIGINAL", "seedPolicy": "NONE"},
                "primarySale": {"outcome": "SOLD", "currency": ZERO, "price": "1250000000000000000"},
                "editionOf": {"editionsContract": ZERO, "editionId": "0"},
                "rendererOf": RENDERER,
            },
            "WorkRecords": {
                "isOpen": True,
                "record": {"version": 3, "finalized": True, "onChainComplete": True},
                "mediaOf": [
                    {"fileId": f1, "sha256Hash": still[0]["sha256"], "role": "PRIMARY"},
                    {"fileId": f2, "sha256Hash": still[1]["sha256"], "role": "PREVIEW"},
                    {"fileId": DECL_FILE, "sha256Hash": sha(decl), "role": "AUXILIARY"},
                ],
                "licenseOf": {"spdxId": "CC0-1.0", "textFileId": LICENSE_TEXT},
                "workStateHash": card["record"]["stateHash"],
                "pinnedRenderer": RENDERER,
                "locators": {f1: locs[f1], f2: locs[f2], DECL_FILE: []},
                "preferredLocator": {f1: {"kind": "ONCHAIN", "uri": ""}, f2: {"kind": "ONCHAIN", "uri": ""},
                                     DECL_FILE: {"kind": "ONCHAIN", "uri": ""}},
                "RecordOpened": {"timestamp": 1794182400 - 30 * 86400},
            },
            "ContentStore": {
                "fileInfo": {
                    f1: {"sha256Hash": still[0]["sha256"], "length": 900000, "chunkCount": 37,
                         "encoding": "Identity", "mimeType": "image/png"},
                    f2: {"sha256Hash": still[1]["sha256"], "length": 30000, "chunkCount": 2,
                         "encoding": "Identity", "mimeType": "image/webp"},
                    DECL_FILE: {"sha256Hash": sha(decl), "length": len(decl), "chunkCount": 1,
                                "encoding": "Identity", "mimeType": DECLARATIONS_MIME},
                },
                "isComplete": {f1: True, f2: True, DECL_FILE: True, LICENSE_TEXT: True},
                "read": {DECL_FILE: "0x" + decl.hex()},
            },
            "StatementLog": {
                "latestDisputeOutcome": ZERO32,
                "disputeOutcomeOf": {"entryHash": ZERO32, "index": 0},
                "chainOf": card["statements"],
                "artistResolver": card["artist"]["resolver"],
            },
            "ArtistRegistry": {"activeAuthorityOf": card["artist"]["activeAuthority"],
                               "pendingChange": {"kind": "NONE"}},
        },
        "floor": example("floor-result.json"),  # the published result (DCL-33)
        "attestations": [{"document": custody_doc, "recordedAt": 1794700900, "posterRole": "OWNER",
                          "poster": card["work"]["owner"], "signatureValid": True}],
        "roles": roles,
    }  # fmt: skip
