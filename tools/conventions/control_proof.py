"""The control-proof challenge and verifier (DCL-23 to DCL-25).

`issue_challenge` is step 1 of DCL-24; `verify_response` runs steps 2 to 6 as a pure function of
its inputs: the venue's identity and clock, a store of the issued challenges, the official token
addresses, and the reads the venue made at its chosen block `B` (the signer's code, the ownership
read, the consolidation read). Signature recovery is pluggable (see `eip712`). A response is
accepted only when its message equals the issued challenge, and the digest is built from that
challenge with the verifier's own chain ID (DCL-24 steps 2 and 3).

The steps are applied in order and the first refusal stops the check; the nonce is spent
whatever the outcome (step 6).
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any, Mapping, Protocol

from . import eip712
from .schema import validate

MAX_VALIDITY_SECONDS = 600  # DCL-24 step 1: expiresAt at most 10 minutes after issuedAt
CLOCK_SKEW_SECONDS = 60  # DCL-24 step 2: [issuedAt - 60 s, expiresAt]
DEFAULT_FRESHNESS_BLOCKS = 64  # DCL-24 step 4's example bound


class NonceStore(Protocol):
    def is_outstanding(self, nonce: str) -> bool: ...
    def challenge(self, nonce: str) -> Mapping[str, Any] | None: ...
    def spend(self, nonce: str) -> None: ...


@dataclass
class MemoryNonceStore:
    """An in-memory store of issued challenges, keyed by nonce: issued and not yet spent are
    outstanding."""

    outstanding: dict[str, dict] = field(default_factory=dict)
    spent: set[str] = field(default_factory=set)

    def add(self, message: Mapping[str, Any]) -> None:
        self.outstanding[message["nonce"]] = dict(message)

    def is_outstanding(self, nonce: str) -> bool:
        return nonce in self.outstanding and nonce not in self.spent

    def spend(self, nonce: str) -> None:
        self.outstanding.pop(nonce, None)
        self.spent.add(nonce)

    def challenge(self, nonce: str) -> dict | None:
        return self.outstanding.get(nonce)


def issue_challenge(
    *,
    venue: str,
    chain_id: int,
    token: str,
    token_id: int | str,
    holder: str,
    signer: str,
    now: int,
    validity_seconds: int = MAX_VALIDITY_SECONDS,
    nonce: bytes | None = None,
    store: MemoryNonceStore | None = None,
) -> dict:
    """DCL-24 step 1: a control-proof.v1 challenge document (no signature)."""
    if not 0 < validity_seconds <= MAX_VALIDITY_SECONDS:
        raise ValueError(f"a challenge is valid for at most {MAX_VALIDITY_SECONDS} seconds")
    nonce = os.urandom(32) if nonce is None else nonce
    if len(nonce) != 32:
        raise ValueError("a nonce is 32 bytes")
    message = {
        "venue": venue,
        "nonce": "0x" + nonce.hex(),
        "issuedAt": now,
        "expiresAt": now + validity_seconds,
        "chainId": chain_id,
        "token": token.lower(),
        "tokenId": str(int(token_id)),
        "holder": holder.lower(),
        "signer": signer.lower(),
    }
    if store is not None:
        store.add(message)
    return {"v": 1, "message": message}


@dataclass(frozen=True)
class Verdict:
    accepted: bool
    trust: str | None  # "full", "low" (a live, younger consolidation the venue accepts) or None
    step: str  # the DCL-24/25 step that decided
    reason: str
    digest: str | None = None
    signature_path: str | None = None


def verify_response(
    document: Mapping[str, Any],
    *,
    venue: str,
    chain_id: int,
    now: int,
    store: NonceStore,
    official_tokens: Mapping[str, str],
    block: Mapping[str, int],
    head_block: int,
    signer_code: bytes,
    ownership: Mapping[str, Any],
    consolidation: Mapping[str, Any] | None = None,
    freshness_blocks: int = DEFAULT_FRESHNESS_BLOCKS,
    accept_pending_delivery: bool = False,
    accept_young_consolidation: bool = False,
    ecdsa: eip712.EcdsaVerifier | None = None,
    erc1271: eip712.Erc1271Verifier | None = None,
) -> Verdict:
    """DCL-24 steps 2 to 6 and DCL-25.

    - `official_tokens`: `{address: "stream" | "editions"}`, the official 6529 Stream and 6529
      Stream Editions addresses of `chain_id`.
    - `block`: `{number, timestamp}` of `B`; `head_block`: the head's number when `B` was chosen.
    - `signer_code`: the signer's code at `B` (empty for an account without code).
    - `ownership` at `B`: for Stream, `{"ownerOf": addr}` and, for the pending-delivery path,
      `{"englishAuction": addr, "pendingDelivery": addr}`; for Editions, `{"balanceOf": int}`.
    - `consolidation` at `B`, from `ArtistRegistry.consolidationSource()`:
      `{"isEstablished": bool, "effectiveAt": int}`; needed only when holder != signer.
    - `store`: the issued challenges; the response's message must equal `store.challenge(nonce)`
      in every field (DCL-24 step 2).
    """
    message = document.get("message", {}) if isinstance(document, Mapping) else {}
    nonce = message.get("nonce") if isinstance(message, Mapping) else None
    try:
        return _verify(
            document, venue=venue, chain_id=chain_id, now=now, store=store,
            official_tokens={k.lower(): v for k, v in official_tokens.items()}, block=block,
            head_block=head_block, signer_code=signer_code, ownership=ownership,
            consolidation=consolidation, freshness_blocks=freshness_blocks,
            accept_pending_delivery=accept_pending_delivery,
            accept_young_consolidation=accept_young_consolidation, ecdsa=ecdsa, erc1271=erc1271,
        )  # fmt: skip
    finally:
        if isinstance(nonce, str):
            store.spend(nonce)  # step 6, whatever the outcome


def _refuse(step: str, reason: str, digest: bytes | None = None, path: str | None = None) -> Verdict:
    return Verdict(False, None, step, reason, "0x" + digest.hex() if digest else None, path)


def _verify(document, *, venue, chain_id, now, store, official_tokens, block, head_block,
            signer_code, ownership, consolidation, freshness_blocks, accept_pending_delivery,
            accept_young_consolidation, ecdsa, erc1271) -> Verdict:  # fmt: skip
    errors = validate(document, "control-proof")
    if errors:
        return _refuse("DCL-23", "not a valid control-proof.v1 document: " + errors[0])
    if "signature" not in document:
        return _refuse("DCL-23", "a challenge without a signature is not a response")
    m = document["message"]
    # Step 2: the response is the issued challenge, field for field.
    if not store.is_outstanding(m["nonce"]):
        return _refuse("DCL-24.2", "the nonce is not outstanding, or was used")
    issued = store.challenge(m["nonce"])
    if issued is None or dict(issued) != dict(m):
        return _refuse("DCL-24.2", "the response's message is not the issued challenge")
    m = dict(issued)
    if m["venue"] != venue:
        return _refuse("DCL-24.2", "the venue is not this verifier's")
    if not m["issuedAt"] - CLOCK_SKEW_SECONDS <= now <= m["expiresAt"]:
        return _refuse("DCL-24.2", "the time is outside [issuedAt - 60 s, expiresAt]")
    if m["chainId"] != chain_id:
        return _refuse("DCL-24.2", "chainId is not the domain's")
    kind = official_tokens.get(m["token"])
    if kind not in ("stream", "editions"):
        return _refuse("DCL-24.2", "the token is not the official 6529 Stream or Editions address")
    # Step 3: the digest of the issued challenge, in the domain of the verifier's own chain ID.
    digest = eip712.control_digest(m, chain_id)
    check = eip712.verify_signature(
        m["signer"], digest, bytes.fromhex(document["signature"][2:]),
        code=signer_code, ecdsa=ecdsa, erc1271=erc1271,
    )  # fmt: skip
    if not check.valid:
        return _refuse("DCL-24.3", check.reason, digest, check.path)
    # Step 4.
    if head_block - block["number"] > freshness_blocks:
        return _refuse("DCL-24.4", "block B is older than the venue's freshness bound", digest, check.path)
    if block["timestamp"] < m["issuedAt"]:
        return _refuse("DCL-24.4", "block B is before issuedAt", digest, check.path)
    holder = m["holder"]
    if kind == "stream":
        owner = (ownership.get("ownerOf") or "").lower()
        holds = owner == holder
        if not holds and accept_pending_delivery:
            auction = (ownership.get("englishAuction") or "").lower()
            buyer = (ownership.get("pendingDelivery") or "").lower()
            holds = bool(auction) and owner == auction and buyer == holder
        if not holds:
            return _refuse("DCL-24.4", "the ownership read at B does not name the holder", digest, check.path)
    else:
        balance = ownership.get("balanceOf")
        if not isinstance(balance, int) or isinstance(balance, bool) or balance <= 0:
            return _refuse("DCL-24.4", "the holder has no copy of the edition at B", digest, check.path)
    # Step 5 and DCL-25.
    if holder == m["signer"]:
        return Verdict(True, "full", "DCL-24.5", "the holder signed", "0x" + digest.hex(), check.path)
    if consolidation is None:
        return _refuse("DCL-25", "holder is not the signer and no consolidation read was supplied", digest, check.path)
    if consolidation.get("isEstablished") is True:
        return Verdict(True, "full", "DCL-25", "established consolidation", "0x" + digest.hex(), check.path)
    effective_at = consolidation.get("effectiveAt") or 0
    if effective_at > block["timestamp"]:
        if accept_young_consolidation:
            return Verdict(True, "low", "DCL-25", "live, younger consolidation", "0x" + digest.hex(), check.path)
        return _refuse("DCL-25", "the consolidation is live but not yet established", digest, check.path)
    return _refuse("DCL-25", "no established two-way consolidation of holder and signer", digest, check.path)
