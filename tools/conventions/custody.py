"""The custody-attestation reader check (DCL-19 to DCL-22).

`evaluate_custody(declarations, attestations, now, work=...)` decides, for each object and
custodian of the work `work`, which attestation counts, whether its custodian is recognized and
whether it is stale. It is a pure function: signature validity is an input (`signatureValid`, a
JSON boolean from `attestation_signature` or the caller's own DCL-20 check at the reader's block).

An attestation input is `{"document": <custody-attestation.v1>, "recordedAt": <entry time>,
"posterRole": "OWNER|ARTIST|PLATFORM|CURATOR", "poster": "0x…", "signatureValid": bool}`, plus
optionally `"subject"` (`{chainId, contract, tokenId}`, the statement's own subject; default the
document's). `declarations` is a valid declarations document, or None when the work has none or
its declarations are not valid (then no custodian is named).
"""

from __future__ import annotations

from typing import Any, Iterable, Mapping

from tools.content.errors import ToolError

from . import eip712
from .schema import validate

STATUS = {1: "HELD", 2: "RELEASED", 3: "MISSING", 4: "DESTROYED"}
POSTER_ROLES = frozenset({"OWNER", "ARTIST", "PLATFORM"})
FUTURE_SKEW_SECONDS = 3600
DEFAULT_MAX_AGE_DAYS = 365
DAY = 86_400
UNNAMED_LABEL = "custodian not named by the work's declarations"


def attestation_digest(document: Mapping[str, Any]) -> bytes:
    """DCL-19: the digest, in the domain of the work's chain (the document's subject chain)."""
    return eip712.custody_digest(document["subject"]["chainId"], document["message"])


def attestation_signature(
    document: Mapping[str, Any],
    *,
    code: bytes = b"",
    ecdsa: eip712.EcdsaVerifier | None = None,
    erc1271: eip712.Erc1271Verifier | None = None,
) -> eip712.SignatureCheck:
    """DCL-20: the custodian's signature over the digest, checked as `SignatureVerifier` does."""
    signature = bytes.fromhex(document["signature"][2:])
    return eip712.verify_signature(
        document["custodian"], attestation_digest(document), signature,
        code=code, ecdsa=ecdsa, erc1271=erc1271,
    )  # fmt: skip


def work_key(ref: Mapping[str, Any]) -> tuple[Any, str, str]:
    """`(chainId, contract, tokenId)` of a work reference, contract lowercased and the token ID
    as a decimal string, so references compare equal however a caller spelled them."""
    if not isinstance(ref, Mapping) or not {"chainId", "contract", "tokenId"} <= set(ref):
        raise ToolError("a work is {chainId, contract, tokenId}")
    contract = ref["contract"]
    return ref["chainId"], contract.lower() if isinstance(contract, str) else contract, str(ref["tokenId"])


def _discard_reason(att: Mapping[str, Any], work: tuple[Any, str, str]) -> str | None:
    doc = att["document"]
    errors = validate(doc, "custody-attestation")
    if errors:
        return "not a valid custody-attestation.v1 document: " + errors[0]
    if att.get("posterRole") not in POSTER_ROLES:
        return "posted under a role DCL-20 does not count"
    subject = work_key(att.get("subject", doc["subject"]))
    message = doc["message"]
    if subject != work_key(doc["subject"]):
        return "the document's subject is not the statement's subject (DCL-2)"
    if subject != work:
        return "the attestation is about another work than the one evaluated (DCL-20)"
    if (message["token"], message["tokenId"]) != subject[1:]:
        return "the message names another token than the statement's subject (DCL-20)"
    if att.get("signatureValid") is not True:
        return "the custodian's signature is not valid (DCL-20)"
    if message["asOf"] > att["recordedAt"] + FUTURE_SKEW_SECONDS:
        return "asOf is more than one hour after the entry's recordedAt (DCL-21)"
    return None


def evaluate_custody(
    declarations: Mapping[str, Any] | None,
    attestations: Iterable[Mapping[str, Any]],
    now: int,
    *,
    work: Mapping[str, Any],
) -> dict:
    """DCL-21 and DCL-22 at reader time `now`. Returns `{"entries": [...], "discarded": [...]}`.

    `work` is the evaluated work, `{chainId, contract, tokenId}`: an attestation whose subject is
    another work is discarded (DCL-20), so it can neither count for this work nor recognize a
    successor here. `attestations` are in log order: of two valid attestations with the same
    `asOf`, the later one counts (DCL-21).

    Each entry: `objectId`, `custodian`, `recognized`, `status`, `asOf`, `stale`, `maxAgeDays`,
    and for an unrecognized custodian `label` (DCL-22) with `posterRole` and `poster`. A named
    custodian with no counting attestation has an entry with status `NONE`, no `asOf` and
    `stale` true, so it is never shown as current custody.
    """
    evaluated = work_key(work)
    named = {}
    for c in (declarations or {}).get("custodians", []):
        named[(c["objectId"], c["address"])] = c["maxAttestationAgeDays"]
    discarded: list[dict] = []
    counting: dict[tuple[str, str], tuple[int, Mapping[str, Any]]] = {}
    for index, att in enumerate(attestations):
        reason = _discard_reason(att, evaluated)
        if reason:
            discarded.append({"index": index, "reason": reason})
            continue
        doc = att["document"]
        key = (doc["message"]["objectId"], doc["custodian"])
        best = counting.get(key)
        # DCL-21: the latest asOf counts, not the latest entry; on a tie the later entry.
        if best is None or doc["message"]["asOf"] >= best[1]["document"]["message"]["asOf"]:
            counting[key] = (index, att)
    # DCL-22: named custodians, then the successor in a recognized custodian's counting (latest)
    # attestation when it is RELEASED, to a fixpoint. An earlier RELEASED one recognizes no one.
    recognized = set(named)
    changed = True
    while changed:
        changed = False
        for key, (_, att) in counting.items():
            msg = att["document"]["message"]
            if msg["status"] == 2 and key in recognized:
                nxt = (msg["objectId"], msg["successor"])
                if msg["successor"] != eip712.ZERO_ADDRESS and nxt not in recognized:
                    recognized.add(nxt)
                    changed = True
    entries: list[dict] = []
    for (object_id, custodian), (_, att) in sorted(counting.items(), key=lambda kv: kv[1][0]):
        msg = att["document"]["message"]
        max_days = named.get((object_id, custodian), DEFAULT_MAX_AGE_DAYS)
        entry = {
            "objectId": object_id,
            "custodian": custodian,
            "recognized": (object_id, custodian) in recognized,
            "status": STATUS[msg["status"]],
            "asOf": msg["asOf"],
            "stale": now - msg["asOf"] > max_days * DAY,
            "maxAgeDays": max_days,
        }
        if not entry["recognized"]:
            entry.update(label=UNNAMED_LABEL, posterRole=att["posterRole"], poster=att["poster"])
        entries.append(entry)
    for (object_id, custodian), max_days in named.items():
        if (object_id, custodian) not in counting:
            entries.append({
                "objectId": object_id, "custodian": custodian, "recognized": True,
                "status": "NONE", "stale": True, "maxAgeDays": max_days,
            })  # fmt: skip
    return {"entries": entries, "discarded": discarded}


def card_custody(evaluation: Mapping[str, Any]) -> list[dict]:
    """The promise card's `custody` array (promise-card.v1 fields only; no `asOf` for NONE)."""
    keys = ("objectId", "custodian", "recognized", "status", "asOf", "stale")
    return [{k: e[k] for k in keys if k in e} for e in evaluation["entries"]]
