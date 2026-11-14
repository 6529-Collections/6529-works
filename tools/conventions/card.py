"""The promise-card builder (DCL-26 to DCL-29).

`build_card(inputs)` turns the on-chain reads of one work at one block, plus the documents a
reader holds, into a promise-card.v1 document. It makes no RPC call: the caller makes every read
at the same block `B` (DCL-26) and passes the answers in the shape below, named after the
functions the spec cites. The existing chain tooling (`tools/content/rpc.py`) reaches a node over
JSON-RPC with `urllib`, not by shelling out, so fetching is left to the caller.

`inputs`:

```text
reads:
  at:          {chainId, blockNumber, blockHash, timestamp}            # block B
  token, tokenId
  WorkMinted:  {contentHash}            # the event; no view returns the content hash
  Stream:
    ownerOf:         address | null     # null when it reverted: a burned token has no card
    coreOf:          {itemHash, artistId, collectionId, kind, seedPolicy}
    primarySale:     {outcome, currency, price}
    editionOf:       {editionsContract, editionId}
    rendererOf:      address
  WorkRecords:
    isOpen:          bool
    record:          {version, finalized, onChainComplete}             # when open
    mediaOf:         [{fileId, sha256Hash, role}]                      # when open
    licenseOf:       {spdxId, textFileId}  # reverts before the open: pass the item's license (DCL-28)
    workStateHash:   bytes32                                           # when open
    pinnedRenderer:  address                                           # when open
    locators:        {fileId: [{kind, uri}]}                           # when open
    preferredLocator:{fileId: {kind, uri}}                             # when open
    RecordOpened:    {timestamp}            # the event's block time, for DCL-8
  ContentStore:
    fileInfo:   {fileId: {sha256Hash, length, chunkCount, encoding, mimeType}}
    isComplete: {fileId: bool}              # media files and the license text file
    read:       {fileId: "0x…"}             # the declarations bytes, when complete
  StatementLog:
    latestDisputeOutcome: bytes32
    disputeOutcomeOf:     {entryHash, index}
    chainOf:              {count, head}
    artistResolver:       address
  ArtistRegistry:
    activeAuthorityOf: address              # zero while restrained
    pendingChange:     {kind}
  UniformEditionAuction:
    clearing: {count, price}                # for a master that has an edition
  IWorkPowers:                              # optional; absent = WorkRecords does not report it
    renouncedMask: "0x…"                    # renouncedPowers(tokenId): bit i set = powers[i]
    powers: [NAME, …]                       # optional; default POWERS, in bit order (DCL-8)
    covers: {NAME: [what, …]}               # optional; default COVERS (DCL-8, DCL-27)
declarationsCopies: {fileId: "0x…"}         # a copy fetched from a locator (not complete on chain)
floor:        a floor-result.v1 object (the published curation evidence, DCL-33), or a
              floor.check_floor result the reader recomputed; absent = every fact unmet
attestations: [custody attestation inputs, as custody.evaluate_custody takes them]
displayChange:{proposal, acceptance, contentSha256, acceptedBy}   # the DCL-12 winner, if any
dispute:      {documentVerified}            # optional (DCL-28)
roles:        [{what, who, delaySeconds, guardianCancel, phase?}] # from the role matrix (DCL-27);
              phase is "beforeFinalize" or "afterFinalize" for a path that applies only then
generator:    {name, version}               # optional
```
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any, Mapping

from tools.content.errors import ToolError

from . import custody, floor
from .schema import validate

ZERO_ADDRESS = "0x" + "00" * 20
ZERO32 = "0x" + "00" * 32
DAY = 86_400
FLOOR_STATES = ("met", "waived", "unmet", "not_applicable")
CC0_KEY = floor.license_key("CC0-1.0")

ALWAYS_RISKS = (
    "LIM-GV-1", "LIM-GV-2", "LIM-GV-9", "LIM-GV-10", "LIM-GV-11", "LIM-ID-11", "LIM-ID-13",
    "LIM-CNT-2", "LIM-CNT-3", "LIM-CNT-12", "LIM-CNT-13", "LIM-SAL-8",
)  # fmt: skip
#: The `WorkPowers` names in bit order (bit 0 = 1, bit 1 = 2), and the `changeable` row each
#: covers (DCL-8, DCL-27).
POWERS = floor.WORK_POWERS
COVERS = {"ROYALTY_RATE": ["royalty_rate"], "RELICENSE": ["license"]}
UNTIL = {"record": "finalize", "burn_and_release": "settlement"}
GENERATOR = {"name": "6529-works tools.conventions", "version": "1"}


class NoCard(ToolError):
    """A burned token has no card (DCL-28)."""


@dataclass
class CardResult:
    card: dict
    notes: dict = field(default_factory=dict)


def _lc(value: Any) -> Any:
    return value.lower() if isinstance(value, str) else value


def _need(mapping: Mapping[str, Any], key: str, where: str) -> Any:
    if not isinstance(mapping, Mapping) or key not in mapping:
        raise ToolError(f"missing read {where}.{key}")
    return mapping[key]


def _per_file(mapping: Mapping[str, Any], file_id: str, where: str) -> Any:
    table = mapping or {}
    for key in (file_id, file_id.lower()):
        if key in table:
            return table[key]
    for key, value in table.items():
        if key.lower() == file_id.lower():
            return value
    raise ToolError(f"missing read {where}[{file_id}]")


def _risk_key(risk: str) -> tuple[str, int]:
    _, area, number = risk.split("-")
    return area, int(number)


def residual_risks(*, on_chain_complete: bool, finalized: bool, ea14: bool) -> list[str]:
    """DCL-29, sorted by area then number."""
    risks = set(ALWAYS_RISKS)
    if not on_chain_complete:
        risks.add("LIM-CNT-1")
    if finalized:
        risks.add("LIM-CNT-10")
    if ea14:
        risks.add("LIM-EA-14")
    return sorted(risks, key=_risk_key)


def declarations_status(
    media: list[Mapping[str, Any]] | None,
    content_store: Mapping[str, Any],
    copies: Mapping[str, str],
    content_hash: str,
) -> tuple[str, dict | None, str | None, list[str]]:
    """DCL-3 as a reader applies it: `(status, doc, fileId, problems)`.

    `unreadable` when the record is not open (mediaOf reverts) or the bytes cannot be obtained
    (not complete on chain and no copy matching the media entry's SHA-256); `invalid` when bytes
    were obtained and break DCL-3."""
    if media is None:
        return "unreadable", None, None, ["the record is not open, so mediaOf reverts"]
    infos = content_store.get("fileInfo", {})
    found = []
    for m in media:
        if m["role"] == "AUXILIARY":
            info = _per_file(infos, m["fileId"], "ContentStore.fileInfo")
            if info.get("mimeType") == floor.DECLARATIONS_MIME:
                found.append((m, info))
    if not found:
        return "absent", None, None, []
    if len(found) > 1:
        return "ambiguous", None, None, ["more than one declarations file"]
    entry, info = found[0]
    file_id = _lc(entry["fileId"])
    complete = _per_file(content_store.get("isComplete", {}), file_id, "ContentStore.isComplete")
    data: bytes | None = None
    problems: list[str] = []
    if complete:
        raw = _per_file(content_store.get("read", {}), file_id, "ContentStore.read")
        data = bytes.fromhex(raw[2:])
    else:
        for key, raw in (copies or {}).items():
            if key.lower() == file_id:
                copy = bytes.fromhex(raw[2:])
                if "0x" + hashlib.sha256(copy).hexdigest() == _lc(entry["sha256Hash"]):
                    data = copy
                else:
                    problems.append("a fetched copy does not match the media entry's SHA-256")
        if data is None:
            return "unreadable", None, file_id, problems + ["no copy of the declarations bytes"]
    info = dict(info, complete=complete)
    doc, more = floor.read_declarations(entry, info, data, content_hash, require_complete=False)
    if more or doc is None:
        return "invalid", None, file_id, problems + more
    return "valid", doc, file_id, problems


def _powers(reads: Mapping[str, Any]) -> tuple[dict, dict[str, list[str]]]:
    view = reads.get("IWorkPowers")
    if view is None:
        return {"available": False}, {}
    names = list(view.get("powers", POWERS))
    mask = int(_need(view, "renouncedMask", "IWorkPowers"), 16)
    if mask >> len(names):
        raise ToolError("IWorkPowers.renouncedMask sets a bit with no power name")
    renounced = [n for i, n in enumerate(names) if mask >> i & 1]
    retained = [n for i, n in enumerate(names) if not mask >> i & 1]
    return {"available": True, "renounced": renounced, "retained": retained}, view.get("covers", COVERS)


def _changeable(roles, *, finalized: bool, cc0: bool, sale_outcome: str, powers: dict, covers) -> list[dict]:
    rows = []
    renounced = powers.get("renounced", []) if powers["available"] else []
    for row in roles:
        what = row["what"]
        phase = row.get("phase")
        if (phase == "beforeFinalize" and finalized) or (phase == "afterFinalize" and not finalized):
            continue
        if what == "record" and finalized:
            continue
        if what == "license" and cc0:
            continue  # WS-12: never for CC0
        if what == "burn_and_release" and sale_outcome != "NONE":
            continue  # until settlement
        out = {"what": what, "who": list(row["who"]), "delaySeconds": row["delaySeconds"],
               "guardianCancel": row["guardianCancel"], "until": UNTIL.get(what, "permanent")}  # fmt: skip
        by = next((p for p in renounced if what in covers.get(p, [])), None)
        if by is not None:
            out["until"] = "renounced"
            out["renouncedBy"] = by
        rows.append(out)
    return rows


def _floor_states(
    published: Any, item_hash: str, status: str, decl_file: str | None
) -> tuple[dict[str, str], str | None]:
    """DCL-33: the floor states the card shows, and why they fell back to `unmet` if they did.

    `published` is a floor-result.v1 object, or a `floor.check_floor` result the reader
    recomputed (turned into one with the card's item hash). It is used only when the
    declarations are `valid` or `absent` and it names the work's item hash and the declarations
    file the card found (None when absent); otherwise every fact is `unmet`."""
    unmet = {k: "unmet" for k in floor.FACTS}
    if published is None:
        return unmet, "no floor result was published for the item"
    if status not in ("valid", "absent"):
        return unmet, f"the declarations are {status}"
    if isinstance(published, Mapping) and "ok" in published and "refusals" in published:
        if not published["ok"]:
            return unmet, "the recomputed floor check refused the item"
        published = floor.floor_result(published, item_hash)
    if validate(published, "floor-result"):
        return unmet, "the published floor result is not a valid floor-result.v1"
    if published["itemHash"] != item_hash:
        return unmet, "the published floor result names another item"
    if published["declarationsFileId"] != decl_file:
        return unmet, "the published floor result names another declarations file"
    return dict(published["facts"]), None


def build_card(inputs: Mapping[str, Any]) -> CardResult:
    reads = _need(inputs, "reads", "inputs")
    at = _need(reads, "at", "reads")
    token = _lc(_need(reads, "token", "reads"))
    token_id = str(_need(reads, "tokenId", "reads"))
    stream = _need(reads, "Stream", "reads")
    owner = stream.get("ownerOf")
    if owner is None:
        raise NoCard("the token is burned (ownerOf reverts): a burned token has no card")
    core = _need(stream, "coreOf", "Stream")
    records = _need(reads, "WorkRecords", "reads")
    store = reads.get("ContentStore", {})
    log = _need(reads, "StatementLog", "reads")
    registry = _need(reads, "ArtistRegistry", "reads")
    content_hash = _lc(_need(_need(reads, "WorkMinted", "reads"), "contentHash", "WorkMinted"))
    notes: dict[str, Any] = {}

    is_open = bool(_need(records, "isOpen", "WorkRecords"))
    if is_open:
        rec = _need(records, "record", "WorkRecords")
        finalized = bool(rec["finalized"])
        on_chain_complete = bool(rec["onChainComplete"])
        pinned = _lc(_need(records, "pinnedRenderer", "WorkRecords"))
        record = {
            "status": "finalized" if finalized else "open",
            "version": rec["version"],
            "stateHash": _lc(_need(records, "workStateHash", "WorkRecords")),
            "renderer": _lc(_need(stream, "rendererOf", "Stream")),
            "rendererPinned": pinned != ZERO_ADDRESS,
        }
        media = list(_need(records, "mediaOf", "WorkRecords"))
    else:
        finalized = on_chain_complete = False
        record = {"status": "not_open"}
        media = None

    files = []
    for m in media or []:
        fid = _lc(m["fileId"])
        info = _per_file(store.get("fileInfo", {}), fid, "ContentStore.fileInfo")
        preferred = _per_file(records.get("preferredLocator", {}), fid, "WorkRecords.preferredLocator")
        files.append({
            "fileId": fid, "role": m["role"], "sha256": _lc(m["sha256Hash"]),
            "mimeType": info["mimeType"],
            "complete": bool(_per_file(store.get("isComplete", {}), fid, "ContentStore.isComplete")),
            "locators": len(_per_file(records.get("locators", {}), fid, "WorkRecords.locators")),
            "preferredKind": preferred.get("kind", "NONE"),
        })  # fmt: skip

    lic = _need(records, "licenseOf", "WorkRecords")
    text_id = _lc(lic["textFileId"])
    license_ = {
        "spdxId": lic["spdxId"],
        "cc0": floor.license_key(lic["spdxId"]) == CC0_KEY,
        "textFileId": text_id,
        "textOnChain": bool(_per_file(store.get("isComplete", {}), text_id, "ContentStore.isComplete")),
    }

    ps = _need(stream, "primarySale", "Stream")
    sale: dict[str, Any] = {"outcome": ps["outcome"]}
    if ps["outcome"] == "SOLD":
        sale["currency"] = _lc(ps["currency"])
        sale["price"] = str(ps["price"])
    edition_of = stream.get("editionOf") or {}
    has_edition = _lc(edition_of.get("editionsContract", ZERO_ADDRESS)) != ZERO_ADDRESS
    if core["kind"] == "EDITION_MASTER" and has_edition:
        clearing = _need(_need(reads, "UniformEditionAuction", "reads"), "clearing", "UniformEditionAuction")
        sale["edition"] = {"editionId": str(edition_of["editionId"]), "copies": str(clearing["count"]),
                           "pricePerCopy": str(clearing["price"])}  # fmt: skip

    latest = _lc(_need(log, "latestDisputeOutcome", "StatementLog"))
    dispute: dict[str, Any] = {"entryHash": None, "scope": None}
    if latest != ZERO32:
        own = _lc(_need(_need(log, "disputeOutcomeOf", "StatementLog"), "entryHash", "disputeOutcomeOf"))
        dispute = {"entryHash": latest, "scope": "token" if own == latest else "item"}
        verified = (inputs.get("dispute") or {}).get("documentVerified")
        if verified is not None:
            dispute["documentVerified"] = bool(verified)

    powers, covers = _powers(reads)

    status, doc, decl_file, problems = declarations_status(
        media, store, inputs.get("declarationsCopies") or {}, content_hash
    )
    if problems:
        notes["declarations"] = problems
    declarations: dict[str, Any] = {"status": status}
    if decl_file is not None:
        declarations["fileId"] = decl_file
    if doc is not None:
        declarations["timeCapsule"] = "timeCapsule" in doc
        declarations["livingWork"] = "livingWork" in doc
        opened = (records.get("RecordOpened") or {}).get("timestamp")
        if doc.get("intendedRenunciations") and opened is not None:
            items = []
            for r in doc["intendedRenunciations"]:
                due = opened + r["withinDaysOfRecordOpen"] * DAY
                if not powers["available"]:
                    state = "unknown"
                elif r["power"] in powers["renounced"]:
                    state = "renounced"
                elif at["timestamp"] < due:  # due from dueAt on (DCL-8)
                    state = "pending"
                else:
                    state = "overdue"
                items.append({"power": r["power"], "dueAt": due, "state": state})
            declarations["intendedRenunciations"] = items

    conservation, why = _floor_states(inputs.get("floor"), _lc(core["itemHash"]), status, decl_file)
    if why is not None:
        notes["conservationFloor"] = why

    change = inputs.get("displayChange")
    if change:
        display = {"state": "accepted", "proposal": _lc(change["proposal"]),
                   "acceptance": _lc(change["acceptance"]),
                   "contentSha256": _lc(change["contentSha256"]),
                   "acceptedBy": _lc(change["acceptedBy"]),
                   "acceptedByCurrentOwner": _lc(change["acceptedBy"]) == _lc(owner)}  # fmt: skip
    else:
        display = {"state": "none"}

    evaluation = custody.evaluate_custody(doc, inputs.get("attestations") or [], at["timestamp"])
    if evaluation["discarded"] or any(not e["recognized"] for e in evaluation["entries"]):
        notes["custody"] = evaluation

    cc0 = license_["cc0"]
    changeable = _changeable(inputs.get("roles") or [], finalized=finalized, cc0=cc0,
                             sale_outcome=ps["outcome"], powers=powers, covers=covers)  # fmt: skip

    authority = _lc(_need(registry, "activeAuthorityOf", "ArtistRegistry"))
    chain = _need(log, "chainOf", "StatementLog")
    card = {
        "v": 1,
        "generator": dict(inputs.get("generator") or GENERATOR),
        "at": {"chainId": at["chainId"], "blockNumber": at["blockNumber"],
               "blockHash": _lc(at["blockHash"]), "timestamp": at["timestamp"]},
        "work": {"token": token, "tokenId": token_id, "owner": _lc(owner), "kind": core["kind"],
                 "itemHash": _lc(core["itemHash"]), "contentHash": content_hash,
                 "artistId": str(core["artistId"]), "collectionId": str(core["collectionId"])},
        "artist": {"activeAuthority": authority, "restrained": authority == ZERO_ADDRESS,
                   "pendingChange": _need(registry, "pendingChange", "ArtistRegistry")["kind"],
                   "resolver": _lc(_need(log, "artistResolver", "StatementLog"))},
        "record": record,
        "storage": {"onChainComplete": on_chain_complete, "files": files},
        "license": license_,
        "sale": sale,
        "dispute": dispute,
        "powers": powers,
        "declarations": declarations,
        "conservationFloor": conservation,
        "displayChange": display,
        "custody": custody.card_custody(evaluation),
        "changeable": changeable,
        "residualRisks": residual_risks(
            on_chain_complete=on_chain_complete, finalized=finalized,
            ea14=core["kind"] == "EDITION_MASTER" and has_edition and dispute["entryHash"] is not None,
        ),
        "statements": {"count": chain["count"], "head": _lc(chain["head"])},
    }  # fmt: skip
    errors = validate(card, "promise-card")
    if errors:
        raise ToolError("the reads do not give a valid promise-card.v1: " + "; ".join(errors[:5]))
    return CardResult(card, notes)
