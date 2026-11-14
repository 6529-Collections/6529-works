"""The conservation-floor check a curation signer runs before attesting (DCL-3 to DCL-5, DCL-7)
and the result it publishes (DCL-33).

`check_floor(package, policy, contents, observed)` is `CHECK_FLOOR` of
[DCL-5](../../docs/spec/declarations-and-conventions.md#the-conservation-floor) as a pure
function. It makes no network or chain call: everything the pseudo-rules read from the content
store, the chain or a storage provider is an input, gathered by the caller at the block and time
it attests.

Inputs (plain dicts; hex values `0x`-prefixed):

- `package`: `item` (`contentHash`, `seedPolicy` `NONE|ARTIST|VRF`, `license`
  `{spdxId, textFileId}`, `recordDependencies`: the record file's `dependencies` member as an
  ordered list of `{name, version}`, or null when the record has no such member; an empty list
  and null both declare no dependency), `media` (the ordered media list,
  `[{fileId, sha256Hash, role}]`, the PRIMARY file first), `files` (`ContentStore.fileInfo` per
  file ID: `{sha256Hash, length, encoding, mimeType, complete}`; `encoding` is
  `Identity|Gzip|Base64|GzipBase64` and `complete` is `isComplete`) and, optionally, `work`
  (`{chainId, contract, tokenId}`, when the token is known: a citation of it is refused).
  `files` must also hold the license text file, whose `sha256Hash` is `sha256Of`.
- `policy`: the wave's policy `P`: `requiresDeclarations` (bool), `waivable` (fact names),
  `allowsTimeCapsule` (bool), and optionally `workPowers`, the power names an intended
  renunciation may use; absent or null means `WORK_POWERS`, the `WorkPowers` names (DCL-8).
- `contents`: `{fileId: bytes}`, the declarations file's stored bytes (`ContentStore.read`).
- `observed`: what the signer's own tooling saw: `fetched` (`{uri: bytes | "0x<sha256>" | None}`:
  the bytes fetched at a receipt's URI, which this module checks as the receipt's `form` says
  (`stored`: `fileInfo.length` bytes whose chunks reproduce the file ID, decoded by the file's
  encoding; `decoded`: hashed as they are); or the SHA-256 of the decoded media when the caller
  checked the bytes itself, accepted for a `stored` receipt only of an `Identity` file, whose
  stored stream is the decoded media; None when the fetch failed), `dimensions`
  (`{fileId: {width, height}}` measured by decoding the file),
  `defaultRenderer`, `codeHash` (`{address: extcodehash}`) and `dependencies`
  (`{"name@version": {fileId, deprecated}}`: `DependencyRegistry.resolve(label(name),
  label(version))`, see `dependency_label`; missing = unresolved).

The result: `{"ok": bool, "refusals": [...], "facts": {fact: {"state", "reasons"}},
"declarationsFileId": "0x…" | None}`. `ok` is false when any `require` fails or any `REFUSE` is
reached; every failure is listed, with the fact it belongs to. A fact's state is `met`, `waived`,
`unmet`, `not_applicable` or `failed`. `floor_result(result, item_hash)` turns a passing result
into the floor-result.v1 object the curation evidence publishes (DCL-33).
"""

from __future__ import annotations

import hashlib
import re
from typing import Any, Mapping

from tools.content.cid import locator_accepted
from tools.content.encoding import Encoding, decode
from tools.content.errors import ToolError
from tools.content.keccak import keccak256
from tools.content.plan import chunk_hash, manifest_id, split_chunks

from . import jcs
from .schema import validate

DECLARATIONS_MIME = "application/vnd.6529-works.declarations+json"
MAX_DECLARATIONS_BYTES = 24_575
FACTS = ("storage", "format", "license", "generative", "display")
SCRIPT_MIMES = frozenset({"text/html", "text/javascript", "application/javascript", "text/ecmascript",
                          "application/ecmascript", "image/svg+xml"})  # fmt: skip
WORK_POWERS = ("ROYALTY_RATE", "RELICENSE")  # WorkPowers bit order: bit 0, bit 1 (DCL-8)
_ENCODINGS = {"Identity": Encoding.IDENTITY, "Gzip": Encoding.GZIP, "Base64": Encoding.BASE64,
              "GzipBase64": Encoding.GZIP_BASE64}  # fmt: skip
_AR = re.compile(r"ar://[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]\Z")
ZERO32 = "0x" + "00" * 32
ZERO_ADDRESS = "0x" + "00" * 20


def locator_network(uri: str) -> str | None:
    """WS-18's locator shape: `arweave` or `ipfs` for an accepted spelling, else None."""
    if isinstance(uri, str) and len(uri) == 48 and _AR.match(uri):
        return "arweave"
    if isinstance(uri, str) and locator_accepted(uri):
        return "ipfs"
    return None


def dependency_label(text: str) -> str:
    """DCL-5 `label`: the bytes32 `DependencyRegistry` takes for a name or version, its ASCII
    bytes left-aligned and zero-padded (`bytes32("p5.js")`), as `0x` hex. Refuses a string the
    registry would not accept (1 to 32 bytes of `[a-z0-9._-]`)."""
    if not isinstance(text, str) or not re.fullmatch(r"[a-z0-9._-]{1,32}", text):
        raise ToolError(f"{text!r} is not a DependencyRegistry label (1 to 32 of [a-z0-9._-])")
    return "0x" + text.encode("ascii").ljust(32, b"\0").hex()


def record_declares_dependencies(record_deps: Any) -> bool:
    """DCL-4/DCL-5: the record's `dependencies` member is present and non-empty."""
    return bool(record_deps)


def license_key(spdx_id: str) -> bytes:
    """`WorksHashing.licenseKey`: keccak256 of the ASCII-lowercased identifier."""
    lowered = "".join(c.lower() if "A" <= c <= "Z" else c for c in spdx_id)
    return keccak256(lowered.encode("ascii", "replace"))


def _sha256_hex(data: bytes) -> str:
    return "0x" + hashlib.sha256(data).hexdigest()


def _norm(value: Any) -> Any:
    return value.lower() if isinstance(value, str) else value


def _declarations_entries(package: Mapping[str, Any]) -> tuple[list[dict], list[str]]:
    files = package.get("files", {})
    found: list[dict] = []
    problems: list[str] = []
    for m in package["media"]:
        if m["role"] != "AUXILIARY":
            continue
        info = files.get(_norm(m["fileId"])) or files.get(m["fileId"])
        if info is None:
            problems.append(f"no fileInfo for AUXILIARY file {m['fileId']}")
            continue
        if info.get("mimeType") == DECLARATIONS_MIME:
            found.append(m)
    return found, problems


def _info(package: Mapping[str, Any], file_id: str) -> dict | None:
    files = package.get("files", {})
    return files.get(_norm(file_id)) or files.get(file_id)


def read_declarations(
    entry: Mapping[str, Any],
    info: Mapping[str, Any] | None,
    data: bytes | None,
    content_hash: str,
    require_complete: bool = True,
) -> tuple[dict | None, list[str]]:
    """DCL-3's checks of one declarations media entry and its stored bytes: `(doc, problems)`.
    The signer requires the file complete in the content store (DCL-5); a reader may use a copy
    fetched from a locator instead (`require_complete=False`)."""
    problems: list[str] = []
    if info is None:
        return None, [f"no fileInfo for the declarations file {entry['fileId']}"]
    if info.get("encoding") != "Identity":
        problems.append("the declarations file is not stored as Identity")
    if not isinstance(info.get("length"), int) or info["length"] > MAX_DECLARATIONS_BYTES:
        problems.append(f"the declarations file is longer than {MAX_DECLARATIONS_BYTES} bytes")
    if require_complete and not info.get("complete"):
        problems.append("the declarations file is not complete in the content store")
    if data is None:
        return None, problems + ["the declarations bytes were not supplied"]
    if isinstance(info.get("length"), int) and len(data) != info["length"]:
        problems.append("the declarations bytes are not fileInfo.length long")
    if _sha256_hex(data) != _norm(entry["sha256Hash"]):
        problems.append("the declarations bytes do not hash to the media entry's SHA-256")
    try:
        doc = jcs.parse(data)
    except ToolError as exc:
        return None, problems + [f"the declarations document is not strict JSON: {exc}"]
    if jcs.canonicalize(doc) != data:
        problems.append("the declarations document is not in RFC 8785 canonical form")
    errors = validate(doc, "declarations")
    if errors:
        problems += [f"declarations.v1: {e}" for e in errors]
        return None, problems
    if doc["contentHash"] != _norm(content_hash):
        problems.append("the declarations contentHash is not the item's content hash")
    return doc, problems


def stored_file_id(data: bytes, info: Mapping[str, Any]) -> str:
    """The file ID `ContentStore.manifestId` gives `data` as a file's stored stream with the
    file's other committed fields (length, encoding, MIME type, declared SHA-256): equal to the
    file's ID exactly when `data` reproduces every committed chunk hash (WS-25)."""
    chunks = split_chunks(data)
    return "0x" + manifest_id(
        [chunk_hash(c) for c in chunks], len(data), _ENCODINGS[info["encoding"]], info["mimeType"],
        bytes.fromhex(_norm(info["sha256Hash"])[2:]),
    ).hex()  # fmt: skip


def _hash_fetched(value: Any, form: str, info: Mapping[str, Any], file_id: str) -> tuple[str | None, str]:
    """The SHA-256 of the decoded media a receipt's copy gives, checked as its `form` says. A
    `stored` copy must also be the committed stream itself: its chunks must reproduce the file
    ID, since another encoding of the same media (a different gzip header, say) decodes to the
    same SHA-256 but cannot rebuild the content-store file."""
    if value is None:
        return None, "could not be fetched"
    if isinstance(value, str):
        if not re.fullmatch(r"0x[0-9a-f]{64}", value):
            return None, "has an observed hash that is not lowercase 0x and 32 bytes of hex"
        if form == "stored" and info.get("encoding") != "Identity":
            return None, ("is a stored copy of a file that is not Identity, so it needs the fetched "
                          "bytes, to check them against the committed chunk hashes")  # fmt: skip
        return value, ""
    data = bytes(value)
    if form == "decoded":
        return _sha256_hex(data), ""
    encoding = info.get("encoding")
    if encoding not in _ENCODINGS:
        return None, "has a file whose encoding is unknown"
    if len(data) != info.get("length"):
        return None, "is not fileInfo.length bytes, so it is not the stored stream"
    if not isinstance(info.get("mimeType"), str) or not isinstance(info.get("sha256Hash"), str):
        return None, "has a file whose fileInfo lacks the MIME type or SHA-256 the file ID commits to"
    try:
        if stored_file_id(data, info) != _norm(file_id):
            return None, "does not reproduce the file's committed chunk hashes (file ID), so it is not the stored stream"
        return _sha256_hex(decode(data, _ENCODINGS[encoding])), ""
    except (ToolError, ValueError) as exc:
        return None, f"cannot be checked as the stored {encoding} stream: {exc}"


def _check_storage(doc, S, package, observed) -> list[str]:
    reasons: list[str] = []
    fact = doc["conservation"]["storage"]
    listed = fact.get("files", [])
    media_by_id = {_norm(m["fileId"]): m for m in S}
    if {f["fileId"] for f in listed} != set(media_by_id):
        reasons.append("storage.files does not name exactly the media files other than the declarations")
    fetched = observed.get("fetched", {})
    for f in listed:
        m = media_by_id.get(f["fileId"])
        if m is None:
            continue
        if f["sha256"] != _norm(m["sha256Hash"]):
            reasons.append(f"{f['fileId']}: sha256 is not the media entry's")
        if len({(r["network"], r["provider"]) for r in f["receipts"]}) < 2:
            reasons.append(f"{f['fileId']}: fewer than two receipts of distinct network or provider")
        info = _info(package, f["fileId"]) or {}
        for r in f["receipts"]:
            network = locator_network(r["uri"])
            if network is None:
                reasons.append(f"{r['uri']}: not a WorkRecords locator (WS-18)")
            elif network != r["network"]:
                reasons.append(f"{r['uri']}: network {r['network']} does not match the address")
            digest, why = _hash_fetched(fetched.get(r["uri"]), r["form"], info, m["fileId"])
            if digest is None:
                reasons.append(f"{r['uri']}: {why}")
            elif digest != _norm(m["sha256Hash"]):
                reasons.append(f"{r['uri']}: the fetched copy does not decode to the file's SHA-256")
    return reasons


def _check_format(doc, S, package, observed) -> list[str]:
    reasons: list[str] = []
    listed = doc["conservation"]["format"].get("files", [])
    if {f["fileId"] for f in listed} != {_norm(m["fileId"]) for m in S}:
        reasons.append("format.files does not name exactly the media files other than the declarations")
    dims = observed.get("dimensions", {})
    for f in listed:
        info = _info(package, f["fileId"])
        if info is None:
            reasons.append(f"{f['fileId']}: no fileInfo")
            continue
        if f["mimeType"] != info.get("mimeType"):
            reasons.append(f"{f['fileId']}: mimeType is not the content store's")
        mime = f["mimeType"]
        if mime.startswith(("image/", "video/")):
            if "width" not in f or "height" not in f:
                reasons.append(f"{f['fileId']}: an image or video needs width and height")
            else:
                measured = dims.get(f["fileId"])
                if measured is None:
                    reasons.append(f"{f['fileId']}: dimensions were not measured by decoding")
                elif (measured.get("width"), measured.get("height")) != (f["width"], f["height"]):
                    reasons.append(f"{f['fileId']}: decoding gives other dimensions")
        if mime.startswith(("audio/", "video/")) and "durationSeconds" not in f:
            reasons.append(f"{f['fileId']}: time-based media needs durationSeconds")
    return reasons


def _check_license(doc, package) -> list[str]:
    reasons: list[str] = []
    fact = doc["conservation"]["license"]
    item_license = package["item"]["license"]
    if license_key(fact["spdxId"]) != license_key(item_license["spdxId"]):
        reasons.append("spdxId is not the item's license")
    text = _info(package, item_license["textFileId"])
    if text is None:
        reasons.append("no fileInfo for the license text file, so sha256Of is unknown")
    elif fact["textSha256"] != _norm(text.get("sha256Hash")):
        reasons.append("textSha256 is not sha256Of the license text file")
    return reasons


def _check_generative(doc, package, observed) -> list[str]:
    reasons: list[str] = []
    fact = doc["conservation"]["generative"]
    renderer = fact["renderer"]
    default = _norm(observed.get("defaultRenderer"))
    if default is None:
        reasons.append("Stream.defaultRenderer() was not observed")
    elif renderer["address"] != default:
        reasons.append("renderer.address is not Stream.defaultRenderer()")
    code_hash = {_norm(k): _norm(v) for k, v in observed.get("codeHash", {}).items()}
    if code_hash.get(renderer["address"]) != renderer["codeHash"]:
        reasons.append("renderer.codeHash is not the renderer's extcodehash")
    resolved = observed.get("dependencies", {})
    for dep in fact["dependencies"]:
        key = f"{dep['name']}@{dep['version']}"
        got = resolved.get(key)
        if got is None:
            reasons.append(f"{key}: DependencyRegistry.resolve did not resolve it")
        elif _norm(got.get("fileId")) != dep["fileId"] or got.get("deprecated"):
            reasons.append(f"{key}: resolves to another file, or is deprecated")
    record_deps = package["item"].get("recordDependencies") or []
    declared = [(d.get("name"), d.get("version")) for d in record_deps]
    if declared != [(d["name"], d["version"]) for d in fact["dependencies"]]:
        reasons.append("the record's declared dependencies are not generative.dependencies, in order")
    if fact["seedPolicy"] != package["item"].get("seedPolicy"):
        reasons.append("seedPolicy is not the item's seed policy")
    return reasons


def _always(doc, policy, S, package) -> list[str]:
    refusals: list[str] = []
    if "timeCapsule" in doc:
        if not policy.get("allowsTimeCapsule"):
            refusals.append("time capsule outside policy (DCL-7)")
        auxiliary = {_norm(m["fileId"]) for m in S if m["role"] == "AUXILIARY"}
        if doc["timeCapsule"]["ciphertextFileId"] not in auxiliary:
            refusals.append("the time capsule's ciphertext file is not an AUXILIARY media file (DCL-7)")
    powers = policy.get("workPowers")
    powers = WORK_POWERS if powers is None else powers
    for r in doc.get("intendedRenunciations", []):
        if r["power"] not in powers:
            refusals.append(f"{r['power']}: not a WorkPowers power (DCL-8)")
    custodians = doc.get("custodians", [])
    pairs = [(c["address"], c["objectId"]) for c in custodians]
    if len(set(pairs)) != len(pairs):
        refusals.append("custodian (address, objectId) pairs are not distinct")
    if any(c["address"] == ZERO_ADDRESS for c in custodians):
        refusals.append("a custodian address is zero")
    work = package.get("work")
    for c in doc.get("citations", []):
        ref = c["work"]
        if ref["chainId"] == 0:  # the schema already refuses it; checked as DCL-18 states it
            refusals.append("a citation names chain ID zero (DCL-18)")
        if work is not None and (ref["chainId"], _norm(ref["contract"]), str(ref["tokenId"])) == (
            work["chainId"], _norm(work["contract"]), str(work["tokenId"])
        ):
            refusals.append("a citation names the work itself (DCL-18)")
    return refusals


def check_floor(
    package: Mapping[str, Any],
    policy: Mapping[str, Any],
    contents: Mapping[str, bytes],
    observed: Mapping[str, Any] | None = None,
) -> dict:
    """DCL-5 `CHECK_FLOOR(item, media, P)`."""
    observed = observed or {}
    facts = {k: {"state": "unmet", "reasons": []} for k in FACTS}
    refusals: list[str] = []
    declarations_file: list[str | None] = [None]

    def result() -> dict:
        return {"ok": not refusals, "refusals": refusals, "facts": facts,
                "declarationsFileId": declarations_file[0]}  # fmt: skip

    D, problems = _declarations_entries(package)
    if problems:
        refusals += problems
        return result()
    if len(D) > 1:
        refusals.append("ambiguous declarations")
        return result()
    media = package["media"]
    primary = _info(package, media[0]["fileId"]) if media else None
    if primary is None or not isinstance(primary.get("mimeType"), str):
        # Fail closed: without the PRIMARY file's MIME type, G (and so the generative fact's
        # applicability) is unknown.
        refusals.append("no fileInfo with a MIME type for the PRIMARY file, so G is unknown")
        return result()
    G = (
        primary["mimeType"] in SCRIPT_MIMES
        or record_declares_dependencies(package["item"].get("recordDependencies"))
        or package["item"].get("seedPolicy") != "NONE"
    )
    if not D:
        if policy.get("requiresDeclarations"):
            refusals.append("no declarations")
        if not G:
            facts["generative"] = {"state": "not_applicable", "reasons": []}
        return result()  # every other fact "unmet"
    d = D[0]
    declarations_file[0] = _norm(d["fileId"])
    data = contents.get(_norm(d["fileId"]), contents.get(d["fileId"]))
    doc, problems = read_declarations(d, _info(package, d["fileId"]), data, package["item"]["contentHash"])
    if problems or doc is None:
        refusals += problems
        return result()

    S = [m for m in media if m is not d]
    applicable = [k for k in FACTS if k != "generative" or G]
    for k in applicable:
        if k not in doc.get("conservation", {}):
            refusals.append(f"missing {k}")
            facts[k] = {"state": "failed", "reasons": [f"missing {k}"]}
            continue
        fact = doc["conservation"][k]
        if fact["waived"]:
            if k not in policy.get("waivable", []):
                refusals.append(f"waiver not allowed: {k}")
                facts[k] = {"state": "failed", "reasons": [f"waiver not allowed: {k}"]}
            else:
                facts[k] = {"state": "waived", "reasons": [fact["reason"]]}
            continue
        if k == "storage":
            reasons = _check_storage(doc, S, package, observed)
        elif k == "format":
            reasons = _check_format(doc, S, package, observed)
        elif k == "license":
            reasons = _check_license(doc, package)
        elif k == "generative":
            reasons = _check_generative(doc, package, observed)
        else:
            reasons = [] if fact.get("instructions") else ["display.instructions is missing"]
        if reasons:
            refusals += [f"{k}: {r}" for r in reasons]
            facts[k] = {"state": "failed", "reasons": reasons}
        else:
            facts[k] = {"state": "met", "reasons": []}
    if not G:
        facts["generative"] = {"state": "not_applicable", "reasons": []}
    refusals += _always(doc, policy, S, package)
    return result()


def floor_states(result: Mapping[str, Any]) -> dict[str, str]:
    """The `{fact: state}` map of a passing check (DCL-28)."""
    if not result["ok"]:
        raise ToolError("a refused check has no floor states to publish")
    return {k: v["state"] for k, v in result["facts"].items()}


def floor_result(result: Mapping[str, Any], item_hash: str) -> dict:
    """DCL-33: the floor-result.v1 object the signer publishes in its curation evidence for a
    passing check of the item `item_hash`."""
    doc = {"v": 1, "itemHash": _norm(item_hash), "declarationsFileId": result["declarationsFileId"],
           "facts": floor_states(result)}  # fmt: skip
    errors = validate(doc, "floor-result")
    if errors:  # pragma: no cover - a passing check always gives a valid result
        raise ToolError("internal error: not a valid floor-result.v1: " + "; ".join(errors))
    return doc
