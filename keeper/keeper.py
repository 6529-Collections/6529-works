#!/usr/bin/env python3
"""Reference keeper for 6529 Works: runs the permissionless steps that are due, once.

A reference implementation, not production software: pre-audit, unaudited, with no monitoring,
alerting, retries across runs or key management. See keeper/README.md.

Each run is stateless and idempotent. It reads the chain (the deployment's event logs from
`--from-block`, and views), decides which permissionless steps are due now, simulates each with
eth_call, and sends the ones that would succeed (or, with --dry-run, only prints them). A step
someone else already took is simply no longer due. The keeper holds no role: its key only pays
gas. Reads go to the node over JSON-RPC; every transaction is signed and sent by Foundry's
`cast send`, with `--account <keystore name>` or `--unlocked` (a local node's own accounts).
This program never reads, prints or accepts a private key.

The steps (script/README.md, "Operating procedures"). Sales are in ETH only (ADR 0010). The
unclaimed period is the network's setting `StreamDirectory6529.unclaimedPeriod()` (180 days at launch),
read on every run, never a constant here:
  start       start each 1/1 in --starts through SaleStarter (vaults and record in one call);
              when someone started it directly first, deploy its vaults and open its record
              in WorkFacts
  open        open the edition sale of every EDITION_MASTER 1/1 that has none yet (the open
              creates the edition, in the same call)
  settle      settle every ended 1/1
  editions    settle every closed edition sale, with the keeper's own settlement order (the
              settlement seals the edition at the count sold)
  abandon     abandon every edition sale that has become abandonable (21 days after close)
  adopt       report (never send) editions the network moved to the edition auction that
              have no sale yet: `adopt` is the network's action
  finalize    finalize every work whose finalize notice has come due (WorkRules)
  vaults      deploy any missing seller or royalty vault of a 6529 Stream work
  attest      walk the content store's completeness of each opened work's media files
              (attestComplete, in pieces) and then mark the work complete on chain
  expire      send aged credits to the network once they have waited the unclaimed period
              (both auctions, the escrow); money that arrived later keeps its own clock
  forfeit     forfeit every split-wallet mark older than the unclaimed period
  rescues     report (never send) tokens a removed minter still holds unsold once the
              network's rescue period (`Stream6529.rescueDelay()`) has passed: a network action
  release     push the fixed payees' shares of royalty wallets through the ClaimRouter
              (opt-in: --release); the network's own index is left out of a batch whose
              wallet and asset also release another payee
  mark        mark unclaimed split-wallet shares (opt-in: --mark; starts the unclaimed period)
  notice      record finalize notices for settled, unfinalized works (opt-in: --notice)

Standard library only (plus the repository's pure-Python keccak in tools/content).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.content.keccak import keccak256  # noqa: E402  (the repository's own keccak)

DEFAULT_STEPS = (
    "start,open,settle,editions,abandon,adopt,finalize,vaults,attest,expire,forfeit,rescues"
)
OPT_IN_STEPS = ("release", "mark", "notice")
ETH = "0x" + "00" * 20
EDITION_MASTER = 1
# English auction states; edition auction statuses.
ENDED, SETTLED_1 = 3, 4
EA_SETTLED, EA_VOID = 4, 5
# `Outcome` of a work's first sale (src/interfaces/core/CoreTypes.sol).
OUTCOME_NONE = 0
# keccak256("PRODUCT_STREAM") (src/interfaces/types/EconomicsTypes.sol).
PRODUCT_STREAM = keccak256(b"PRODUCT_STREAM")
# How many chunks one attestComplete call walks; a large file takes several calls.
ATTEST_CHUNKS = 512

# Canonical ABI types (src/interfaces/types/PackageTypes.sol, ContentTypes.sol, ISplitWallet.sol).
PAYEES = "(uint256,address,uint32)[]"
MEDIA = "(bytes32,bytes32,uint8)[]"
# MintFacts, logged whole by Stream's WorkMinted (src/interfaces/core/CoreTypes.sol).
MINT_FACTS = (
    "(bytes32,bytes32,uint256,uint256,uint8,uint8,bytes32,address,uint24,bytes32,bytes32,"
    "bytes32,address)"
)
ITEM = (
    "(uint8,uint256,bytes32,bytes32,bytes32,(address,uint8)[]," + PAYEES + ",(string,bytes32),"
    "uint8,bytes32,(bytes32,address,bytes),(uint32,address,bytes32,bytes))"
)


# ------------------------------------------------------------------ ABI, by hand


def selector(signature: str) -> bytes:
    return keccak256(signature.encode())[:4]


def topic(signature: str) -> str:
    return "0x" + keccak256(signature.encode()).hex()


class Dyn(bytes):
    """A dynamic argument's tail encoding (offsets inside it are relative to its own start)."""


def word(value: int | str | bytes) -> bytes:
    if isinstance(value, str):  # an address or a 0x-prefixed word
        value = int(value, 16)
    if isinstance(value, bytes):
        return value.rjust(32, b"\0")
    return value.to_bytes(32, "big")


def blob(data: bytes) -> Dyn:
    """`bytes` as a dynamic argument: its length, then the data padded to a word."""
    return Dyn(word(len(data)) + data + b"\0" * (-len(data) % 32))


def encode(*args: int | str | bytes | Dyn) -> bytes:
    """The ABI encoding of a tuple of static words and dynamic tails."""
    head, tail = b"", b""
    offset = 32 * len(args)
    for a in args:
        if isinstance(a, Dyn):
            head += word(offset + len(tail))
            tail += a
        else:
            head += word(a)
    return head + tail


def array(items: list[bytes], dynamic: bool) -> Dyn:
    """An array of encoded elements; dynamic elements get offsets."""
    if not dynamic:
        return Dyn(word(len(items)) + b"".join(items))
    offsets, tails, at = b"", b"", 32 * len(items)
    for item in items:
        offsets += word(at + len(tails))
        tails += item
    return Dyn(word(len(items)) + offsets + tails)


def call_data(signature: str, *args: int | str | bytes | Dyn) -> bytes:
    return selector(signature) + encode(*args)


def w(data: bytes, i: int) -> int:
    return int.from_bytes(data[32 * i : 32 * i + 32], "big")


def a(data: bytes, i: int) -> str:
    return "0x" + data[32 * i + 12 : 32 * i + 32].hex()


def tail(data: bytes, start: int, end: int | None = None) -> Dyn:
    return Dyn(data[start:end])


# Field positions in a PackageItem's head (src/interfaces/types/PackageTypes.sol).
ITEM_KIND, ITEM_CONTENT_HASH, ITEM_PAYEES, ITEM_LICENSE = 0, 2, 6, 7


def item_payees(item: bytes) -> Dyn:
    """The `payees` array inside an encoded PackageItem (canonical encoding: it ends where the
    next dynamic member, the license, begins)."""
    return tail(item, w(item, ITEM_PAYEES), w(item, ITEM_LICENSE))


def royalty_payees(seller: str, fee_recipient: str, fee_share: int) -> Dyn:
    """`Splits.royaltyPayees`: the seller wallet and the fee recipient, sorted by address."""
    entries = [(int(seller, 16), 100_000 - fee_share), (int(fee_recipient, 16), fee_share)]
    entries.sort()
    return array([word(0) + word(account) + word(share) for account, share in entries], False)


def payee_list(payees: Dyn) -> list[tuple[int, str, int]]:
    """(artistId, account, share) of each payee in an encoded payee array."""
    n = w(payees, 0)
    return [(w(payees, 1 + 3 * i), a(payees, 2 + 3 * i), w(payees, 3 + 3 * i)) for i in range(n)]


def topic_address(log: dict, i: int) -> str:
    return "0x" + log["topics"][i][-40:]


# ------------------------------------------------------------------ the node


class Reverted(Exception):
    pass


class Rpc:
    def __init__(self, url: str) -> None:
        self.url = url
        self._id = 0

    def request(self, method: str, params: list) -> object:
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params})
        req = urllib.request.Request(self.url, body.encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            reply = json.loads(resp.read())
        if "error" in reply:
            raise Reverted(json.dumps(reply["error"]))
        return reply["result"]

    def call(self, to: str, data: bytes, sender: str | None = None) -> bytes:
        tx = {"to": to, "data": "0x" + data.hex()}
        if sender:
            tx["from"] = sender
        return bytes.fromhex(self.request("eth_call", [tx, "latest"])[2:])

    def ok(self, to: str, data: bytes, sender: str) -> bool:
        try:
            self.call(to, data, sender)
            return True
        except Reverted:
            return False

    def now(self) -> int:
        return int(self.request("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)

    def logs(self, address: str, sig: str, from_block: int) -> list[dict]:
        query = {"address": address, "topics": [topic(sig)], "fromBlock": hex(from_block)}
        return self.request("eth_getLogs", [dict(query, toBlock="latest")])


# ------------------------------------------------------------------ the keeper


@dataclass
class Keeper:
    rpc: Rpc
    c: dict[str, str]  # contract name -> address
    sender: str
    cast_signing: list[str]
    from_block: int = 0
    dry_run: bool = False
    starts: list[dict] = field(default_factory=list)
    sent: list[str] = field(default_factory=list)
    planned: list[str] = field(default_factory=list)

    # -------------------------------------------------------------- plumbing

    def view(self, contract: str, signature: str, *args) -> bytes:
        return self.rpc.call(self.c[contract], call_data(signature, *args), self.sender)

    def send(self, contract: str, signature: str, *args, label: str) -> bool:
        """Simulate, then send (or print). Returns False when the step would revert now."""
        to, data = self.c[contract], call_data(signature, *args)
        try:
            self.rpc.call(to, data, self.sender)
        except Reverted as exc:
            print(f"skip  {label}: would revert ({_short(exc)})")
            return False
        self.planned.append(label)
        if self.dry_run:
            print(f"plan  {label}\n      cast send {to} 0x{data.hex()[:40]}...")
            return True
        cmd = ["cast", "send", to, "0x" + data.hex(), "--rpc-url", self.rpc.url, *self.cast_signing]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            # Someone may have taken the step between the simulation and the send.
            print(f"fail  {label}: {result.stderr.strip().splitlines()[-1:]}")
            return False
        print(f"sent  {label}")
        self.sent.append(label)
        return True

    def logs(self, contract: str, sig: str) -> list[dict]:
        return self.rpc.logs(self.c[contract], sig, self.from_block)

    # -------------------------------------------------------------- what the chain says

    def works(self) -> dict[int, dict]:
        """Every 6529 Stream work: token ID -> minter, package root, content hash and seller
        (WorkMinted logs the whole MintFacts)."""
        out = {}
        sig = f"WorkMinted(uint256,uint256,uint256,address,uint32,{MINT_FACTS})"
        for log in self.logs("Stream6529", sig):
            data = bytes.fromhex(log["data"][2:])
            # Non-indexed: minter, serial, then MintFacts inline (thirteen static words):
            # itemHash, contentHash, artistId, collectionId, kind, seedPolicy, seed,
            # royaltyReceiver, royaltyRate, packageRoot, mediaHash, recordFileId, seller.
            out[int(log["topics"][1], 16)] = {
                "minter": a(data, 0),
                "content": data[32 * 3 : 32 * 4],
                "root": data[32 * 11 : 32 * 12],
                "seller": a(data, 14),
            }
        return out

    def items(self) -> dict[int, tuple[Dyn, Dyn]]:
        """Each opened 6529 Stream record's item and media, from WorkFacts' RecordOpened
        (token and token ID indexed; item, media): the item ends where the media begin."""
        out = {}
        sig = f"RecordOpened(address,uint256,{ITEM},{MEDIA})"
        for log in self.logs("StreamWorkFacts6529", sig):
            if topic_address(log, 1).lower() != self.c["Stream6529"].lower():
                continue  # an Independent Stream token's record
            data = bytes.fromhex(log["data"][2:])
            item, media = tail(data, w(data, 0), w(data, 1)), tail(data, w(data, 1))
            out[int(log["topics"][2], 16)] = (item, media)
        return out

    def facts(self, token_id: int) -> dict[str, bool]:
        """The flags of a 6529 Stream work's permanent record (`StreamWorkFacts6529.factsOf`): the
        returned struct is dynamic, so its head starts at the offset in word 0."""
        data = self.view("StreamWorkFacts6529", "factsOf(address,uint256)", self.c["Stream6529"], token_id)
        head = data[w(data, 0) :]
        return {"opened": bool(w(head, 3)), "finalized": bool(w(head, 4)), "onChain": bool(w(head, 5))}

    def work(self, token_id: int) -> bytes | None:
        """`Stream6529.workOf` (eleven static words), or None for a burned or unknown token."""
        try:
            return self.view("Stream6529", "workOf(uint256)", token_id)
        except Reverted:
            return None

    def unclaimed_period(self) -> int:
        """The network's unclaimed period now (`StreamDirectory6529.unclaimedPeriod()`)."""
        return w(self.view("StreamDirectory6529", "unclaimedPeriod()"), 0)

    def sales(self, contract: str) -> list[tuple[int, str, int]]:
        sig = "SaleStarted(uint256,address,uint256,bytes32,address,uint256,uint64,uint64)"
        return [
            (int(g["topics"][1], 16), topic_address(g, 2), int(g["topics"][3], 16))
            for g in self.logs(contract, sig)
        ]

    def request_for(self, content: bytes) -> dict | None:
        return next((r for r in self.starts if r["content"] == content), None)

    def item_of(self, token_id: int, works: dict, items: dict) -> Dyn | None:
        if token_id in items:
            return items[token_id][0]
        req = self.request_for(works.get(token_id, {}).get("content", b""))
        return req["item"] if req else None

    # -------------------------------------------------------------- the steps

    def step_start(self, works: dict) -> None:
        """Start each request through SaleStarter; if it was started directly, finish it."""
        for req in self.starts:
            # One live token per content: a burned token's content may be minted again.
            live = w(self.view("Stream6529", "tokenOfContent(bytes32)", req["content"]), 0)
            if live and self.work(live) is None:
                live = 0
            if live == 0:
                self.send(
                    "SaleStarter",
                    f"start(address,address,bytes,{MEDIA})",
                    self.c["EnglishAuction"],
                    self.c["Stream6529"],
                    blob(req["mintData"]),
                    req["media"],
                    label=f"start {req['name']} through SaleStarter",
                )
                continue
            # The newest work with this content (an earlier one may have been burned and its
            # content released for a new start).
            token_id = max((t for t, v in works.items() if v["content"] == req["content"]), default=0)
            if not token_id:
                continue  # started in a block after this run's log read; the next run sees it
            self.ensure_vaults(token_id, req["payees"], works.get(token_id, {}))
            if not self.facts(token_id)["opened"]:
                self.send(
                    "StreamWorkFacts6529",
                    f"open(address,uint256,{ITEM},{MEDIA})",
                    self.c["Stream6529"],
                    token_id,
                    req["item"],
                    req["media"],
                    label=f"open the record of work {token_id} (started by someone else)",
                )

    def ensure_vaults(self, token_id: int, payees: Dyn | None, minted: dict) -> None:
        """Deploy the work's seller vault (its payees from the item) and its royalty vault when
        missing. The royalty vault's payees are the seller vault and the network's fee recipient
        at the sale's fee share (`Splits.royaltyPayees`); the keeper deploys it only when that
        list derives the work's royalty receiver, and otherwise reports it (the TERMS module
        sets a new receiver, and deploys it, when the network's share is lowered)."""
        work = self.work(token_id)
        if work is None:
            return  # burned (a sale cancelled after an upheld dispute): no vaults to deploy
        seller = minted.get("seller")
        if payees is not None and seller and self.wallet_missing(seller):
            self.send(
                "SplitFactory",
                f"createWallet({PAYEES},bytes32)",
                payees,
                0,
                label=f"createWallet seller vault of work {token_id} ({seller})",
            )
        receiver = a(work, 7)
        if not seller or receiver == seller or not int(receiver, 16):
            return
        if not self.wallet_missing(receiver):
            return
        royalty = self.royalty_payees_of(token_id, seller)
        if royalty is not None and self.wallet_for(royalty).lower() == receiver.lower():
            self.send(
                "SplitFactory",
                f"createWallet({PAYEES},bytes32)",
                royalty,
                0,
                label=f"createWallet royalty vault of work {token_id} ({receiver})",
            )
        else:
            print(f"note  royalty receiver {receiver} of work {token_id} is not a deployed vault")

    def royalty_payees_of(self, token_id: int, seller: str) -> Dyn | None:
        """The royalty vault's payee list of a work sold by the English auction: the seller
        vault and the network fee recipient now, at the fee share the sale locked."""
        sig = "saleIdOf(address,uint256)"
        sale = w(self.view("EnglishAuction", sig, self.c["Stream6529"], token_id), 0)
        try:
            fee_share = w(self.view("EnglishAuction", "auction(uint256)", sale), 3)
        except Reverted:
            return None  # not sold by this auction
        sig = "networkFeeRecipient(bytes32)"
        fee = a(self.view("EconomicsResolver", sig, PRODUCT_STREAM), 0)
        return royalty_payees(seller, fee, fee_share)

    def wallet_missing(self, wallet: str) -> bool:
        return w(self.view("SplitFactory", "isWallet(address)", wallet), 0) == 0

    def wallet_for(self, payees: Dyn) -> str:
        return a(self.view("SplitFactory", f"walletFor({PAYEES},bytes32)", payees, 0), 0)

    def step_open(self, works: dict, items: dict) -> None:
        for sale_1, token, token_id in self.sales("EnglishAuction"):
            if token.lower() != self.c["Stream6529"].lower():
                continue
            item = self.item_of(token_id, works, items)
            if item is None or w(item, ITEM_KIND) != EDITION_MASTER:
                continue
            if token_id not in works:
                continue  # minted after this run's WorkMinted read; the next run sees it
            sig = "saleIdOf(address,uint256)"
            sale = w(self.view("UniformEditionAuction", sig, self.c["StreamEditions6529"], token_id), 0)
            if self.rpc.ok(self.c["UniformEditionAuction"], call_data("auction(uint256)", sale), ""):
                continue  # already open (auction() reverts with UnknownAuction before)
            state = w(self.view("EnglishAuction", "auctionClock(uint256)", sale_1), 0)
            if state >= SETTLED_1:
                continue  # settled or cancelled: past the edition sale's open window
            req = self.request_for(works[token_id]["content"])
            proof = req["proof"] if req else array([], False)  # a one-item package has no proof
            data = encode(item, works[token_id]["root"], proof)
            self.send(
                "UniformEditionAuction",
                "open(address,uint256,bytes)",
                self.c["StreamEditions6529"],
                token_id,
                blob(data),
                label=f"open the edition sale of work {token_id}",
            )

    def step_settle(self) -> None:
        for sale, _, token_id in self.sales("EnglishAuction"):
            clock = self.view("EnglishAuction", "auctionClock(uint256)", sale)
            if w(clock, 0) == ENDED:
                label = f"settle 1/1 sale of token {token_id}"
                self.send("EnglishAuction", "settle(uint256)", sale, label=label)

    def step_editions(self, now: int) -> None:
        for sale, _, edition_id in self.sales("UniformEditionAuction"):
            status = w(self.view("UniformEditionAuction", "auction(uint256)", sale), 4)
            if status in (EA_SETTLED, EA_VOID):
                continue
            # endTimes: (oneOfOneEnd, closeAt, softEnd, endTime, backstop, oneOfOneState, open)
            times = self.view("UniformEditionAuction", "endTimes(uint256)", sale)
            if now < w(times, 3) and w(times, 5) != 5:  # not closed, and the 1/1 not cancelled
                continue
            for _ in range(64):  # each call advances settlement; a typical sale needs one
                # The rest of this keeper's own sweep (each settler sweeps on its own).
                sig = "settlementOrderFor(uint256,address)"
                order = tail(self.view("UniformEditionAuction", sig, sale, self.sender), 32)
                data = call_data("settle(uint256,uint256[])", sale, order)
                try:
                    result = self.rpc.call(self.c["UniformEditionAuction"], data, self.sender)
                    done = w(result, 0) == 1
                except Reverted as exc:  # the 1/1 not settled yet, or the edition not created
                    print(f"skip  settle edition sale of edition {edition_id}: {_short(exc)}")
                    break
                if not self.send(
                    "UniformEditionAuction",
                    "settle(uint256,uint256[])",
                    sale,
                    order,
                    label=f"settle edition sale of edition {edition_id}",
                ) or done or self.dry_run:
                    break

    def step_abandon(self) -> None:
        for sale, _, edition_id in self.sales("UniformEditionAuction"):
            if w(self.view("UniformEditionAuction", "abandonable(uint256)", sale), 0):
                self.send(
                    "UniformEditionAuction",
                    "abandon(uint256)",
                    sale,
                    label=f"abandon edition sale of edition {edition_id}",
                )

    def step_adopt(self) -> None:
        """Report editions the network moved to this edition auction (`IEditions.rebind`) that
        have no sale here yet. `adopt` opens that sale; it is the network's action, because the
        network chooses when the moved sale runs. The keeper only says it is waiting."""
        adapter = self.c["UniformEditionAuction"]
        for log in self.logs("StreamEditions6529", "EditionRebound(uint256,address,address)"):
            if topic_address(log, 3).lower() != adapter.lower():
                continue
            edition_id = int(log["topics"][1], 16)
            sig = "saleIdOf(address,uint256)"
            sale = w(self.view("UniformEditionAuction", sig, self.c["StreamEditions6529"], edition_id), 0)
            if self.rpc.ok(adapter, call_data("auction(uint256)", sale), self.sender):
                continue  # adopted already
            print(
                f"due   adopt of edition {edition_id}, moved to the edition auction"
                " (a network action: UniformEditionAuction.adopt(editions, id, data))"
            )

    def step_finalize(self, works: dict, now: int, notice: bool) -> None:
        due = {}
        stream = self.c["Stream6529"]
        for log in self.logs("WorkRules", "FinalizeNoticeRecorded(address,uint256,uint256)"):
            if topic_address(log, 1).lower() == stream.lower():
                due[int(log["topics"][2], 16)] = int(log["data"][2:66], 16)
        for token_id in sorted(works):
            facts = self.facts(token_id)
            if not facts["opened"] or facts["finalized"]:
                continue
            sig = "finalize(address,uint256,bytes32)"
            if token_id in due and now >= due[token_id]:
                label = f"finalize work {token_id}"
                self.send("WorkRules", sig, stream, token_id, 0, label=label)
            elif token_id not in due and notice:
                work = self.work(token_id)
                if work is not None and w(work, 6) != OUTCOME_NONE:  # the first sale has ended
                    label = f"record the finalize notice of work {token_id}"
                    self.send("WorkRules", sig, stream, token_id, 0, label=label)

    def step_vaults(self, works: dict, items: dict) -> None:
        for token_id in sorted(works):
            item = self.item_of(token_id, works, items)
            payees = item_payees(item) if item is not None else None
            self.ensure_vaults(token_id, payees, works[token_id])

    def step_attest(self, works: dict, items: dict) -> None:
        """Walk each media file's completeness in the content store (permissionless, in pieces
        of ATTEST_CHUNKS chunks; chunks are never removed, so it never reverses), then mark the
        work complete on chain once every file is."""
        for token_id in sorted(items):
            if token_id not in works or self.facts(token_id)["onChain"]:
                continue
            media = items[token_id][1]
            files = [media[32 + 96 * i : 64 + 96 * i] for i in range(w(media, 0))]
            complete = True
            for file_id in files:
                if w(self.view("ContentStore", "isComplete(bytes32)", file_id), 0):
                    continue
                complete = False
                self.send(
                    "ContentStore",
                    "attestComplete(bytes32,uint256)",
                    file_id,
                    ATTEST_CHUNKS,
                    label=f"attest file 0x{file_id.hex()[:12]}... of work {token_id}",
                )
            if complete and files:
                self.send(
                    "StreamWorkFacts6529",
                    "markOnChainComplete(address,uint256)",
                    self.c["Stream6529"],
                    token_id,
                    label=f"mark work {token_id} complete on chain",
                )

    def step_expire(self, now: int) -> None:
        """Expire aged credits (src/libraries/AgedCredits.sol). An auction credit is
        (total, aged, since): only `aged`, which has itself waited the unclaimed period since
        `since`, can go to the network; money that arrived later keeps its own clock. The
        period is the network's setting now (`StreamDirectory6529.unclaimedPeriod()`). The edition auction
        answers `creditOf(account)`; the English auction answers `expiresAt(account)`, which is
        `since` plus that period (zero with no credit). The escrow keeps its own windows and
        answers what an expiry would move now (`expirableAt`)."""
        period = self.unclaimed_period()
        sig = "Credited(address,address,uint256,uint256)"
        for account in sorted({topic_address(g, 1) for g in self.logs("EnglishAuction", sig)}):
            due = w(self.view("EnglishAuction", "expiresAt(address)", account), 0)
            if due and now >= due:
                self.send(
                    "EnglishAuction",
                    "expireCredit(address)",
                    account,
                    label=f"expire {account}'s aged credit on EnglishAuction",
                )
        edition_logs = self.logs("UniformEditionAuction", sig)
        for account in sorted({topic_address(g, 1) for g in edition_logs}):
            credit = self.view("UniformEditionAuction", "creditOf(address)", account)
            if w(credit, 1) and now >= w(credit, 2) + period:
                self.send(
                    "UniformEditionAuction",
                    "expireCredit(address,address)",
                    account,
                    ETH,
                    label=f"expire {account}'s aged credit on UniformEditionAuction",
                )
        escrow_sig = "Credited(address,address,address,uint256,uint256)"
        credits = self.logs("RevenueEscrow", escrow_sig)
        pairs = sorted({(topic_address(g, 1), topic_address(g, 2)) for g in credits})
        for wallet, asset in pairs:
            sig = "expirableAt(address,address,uint256)"
            if w(self.view("RevenueEscrow", sig, wallet, asset, now), 0):
                label = f"expire the aged escrow credit of {wallet}"
                self.send("RevenueEscrow", "expire(address,address)", wallet, asset, label=label)

    def step_rescues(self, works: dict, now: int) -> None:
        """Report tokens a removed minter still holds with no outcome, once the network's rescue
        period has passed since the removal. `rescue` is the network's action; the keeper only
        says it is possible."""
        delay = w(self.view("Stream6529", "rescueDelay()"), 0)
        for token_id in sorted(works):
            work = self.work(token_id)
            if work is None or w(work, 6) != OUTCOME_NONE:
                continue
            minter = works[token_id]["minter"]
            removed_at = w(self.view("Stream6529", "minterOf(address)", minter), 1)
            try:
                holder = a(self.view("Stream6529", "ownerOf(uint256)", token_id), 0)
            except Reverted:
                # Burned with no outcome (its sale was cancelled after a dispute): `workOf` still
                # answers, nobody holds the token and there is nothing to rescue.
                continue
            if removed_at and holder.lower() == minter.lower() and now >= removed_at + delay:
                print(
                    f"due   rescue of work {token_id} from removed minter {minter}"
                    " (a network action: Stream.rescue(tokenId, to))"
                )

    def wallets(self) -> list[tuple[str, bytes, Dyn]]:
        """Every split wallet: address, salt and payee list (WalletCreated)."""
        out = []
        for log in self.logs("SplitFactory", f"WalletCreated(address,bytes32,bytes32,{PAYEES})"):
            data = bytes.fromhex(log["data"][2:])  # salt, then the payee list
            out.append((topic_address(log, 1), data[:32], tail(data, w(data, 1))))
        return out

    def step_marks(self, now: int, mark: bool) -> None:
        """Forfeit matured marks; with `mark`, place marks on unclaimed shares (ETH only)."""
        network = self.c["FeeRecipientVault"].lower()
        period = self.unclaimed_period()
        for wallet, salt, payees in self.wallets():
            for index, (_, account, _) in enumerate(payee_list(payees)):
                if account.lower() == network:
                    continue  # the network's own share
                sig = "markOf(address,address,uint256)"
                mark_of = self.view("SplitFactory", sig, wallet, ETH, index)
                target, marked_at = w(mark_of, 0), w(mark_of, 1)
                args = (payees, salt, ETH, index)
                # A mark stays recorded after the payee releases up to its target; only one not
                # yet reached is pending (forfeitable once mature). A reached one may be replaced.
                if target:
                    sig = "released(address,address,uint256)"
                    done = w(self.view("SplitFactory", sig, wallet, ETH, index), 0)
                    target = target if done < target else 0
                if target and now >= marked_at + period:
                    self.send(
                        "SplitFactory",
                        f"forfeit({PAYEES},bytes32,address,uint256)",
                        *args,
                        label=f"forfeit payee {index} of {wallet}",
                    )
                elif not target and mark:
                    if self.releasable(*args):
                        self.send(
                            "SplitFactory",
                            f"mark({PAYEES},bytes32,address,uint256)",
                            *args,
                            label=f"mark payee {index} of {wallet}",
                        )

    def releasable(self, payees: Dyn, salt: bytes, asset: str, index: int) -> int:
        sig = f"releasable({PAYEES},bytes32,address,uint256)"
        return w(self.view("SplitFactory", sig, payees, salt, asset, index), 0)

    def step_release(self) -> None:
        """Push fixed payees' ETH shares through the ClaimRouter, in batches. Artist-resolved
        payees (a nonzero artist ID) are pull-only and skipped. For each wallet, the network's
        index is included only when no other payee of that wallet is released in the batch."""
        network = self.c["FeeRecipientVault"].lower()
        claims = []
        for _, salt, payees in self.wallets():
            due = []
            for index, (artist_id, account, _) in enumerate(payee_list(payees)):
                if artist_id:
                    continue
                if self.releasable(payees, salt, ETH, index):
                    due.append((index, account.lower() == network))
            others = [i for i, is_network in due if not is_network]
            for index in others or [i for i, _ in due]:
                claims.append(Dyn(encode(payees, salt, ETH, index)))
        if not claims:
            return
        # Continue mode takes at most MAX_CONTINUE_CLAIMS items (fewer than plain MAX_CLAIMS).
        size = w(self.view("ClaimRouter", "MAX_CONTINUE_CLAIMS()"), 0)
        for start in range(0, len(claims), size):
            batch = claims[start : start + size]
            self.send(
                "ClaimRouter",
                f"claim(({PAYEES},bytes32,address,uint256)[],bool)",
                array(batch, True),
                1,  # continue mode: one refused item does not stop the rest
                label=f"push {len(batch)} release(s) through the ClaimRouter",
            )

    # -------------------------------------------------------------- one run

    def run(self, steps: set[str]) -> None:
        now = self.rpc.now()
        works = self.works()
        if "start" in steps:
            self.step_start(works)
            works = self.works()
        items = self.items()
        if "open" in steps:
            self.step_open(works, items)
        if "settle" in steps:
            self.step_settle()
        if "editions" in steps:
            self.step_editions(now)
        if "abandon" in steps:
            self.step_abandon()
        if "adopt" in steps:
            self.step_adopt()
        if "finalize" in steps or "notice" in steps:
            self.step_finalize(works, now, "notice" in steps)
        if "vaults" in steps:
            self.step_vaults(works, items)
        if "attest" in steps:
            self.step_attest(works, items)
        if "expire" in steps:
            self.step_expire(now)
        if "forfeit" in steps or "mark" in steps:
            self.step_marks(now, "mark" in steps)
        if "release" in steps:
            self.step_release()
        if "rescues" in steps:
            self.step_rescues(works, now)


def _short(exc: Exception) -> str:
    text = str(exc)
    return text if len(text) < 160 else text[:157] + "..."


def contracts_of(record: dict) -> dict[str, str]:
    """Contract name -> address from a deployment record: the flat form
    `script/DeployCore.s.sol` writes (`{"Stream6529": "0x..", ...}`), or the nested form
    (`{"contracts": {"Stream6529": {"address": "0x.."}}}`)."""
    if "contracts" in record:
        return {name: v["address"] for name, v in record["contracts"].items()}
    return {
        name: v
        for name, v in record.items()
        if isinstance(v, str) and v.startswith("0x") and len(v) == 42
    }


def load_request(path: Path) -> dict:
    """A start request: {"mintData": hex, "media": hex of abi.encode(MediaFile[]),
    "proof": hex of abi.encode(bytes32[]) (optional, for the edition sale's open; by default the
    proof inside mintData)}."""
    raw = json.loads(path.read_text(encoding="utf-8"))
    mint = bytes.fromhex(raw["mintData"].removeprefix("0x"))
    if w(mint, 0) != 32:
        raise SystemExit(f"{path}: mintData must be abi.encode(StreamMintRequest)")
    body = mint[32:]  # StreamMintRequest(packageRoot, item, proof, move)
    item = tail(body, w(body, 1), w(body, 2))
    media = bytes.fromhex(raw["media"].removeprefix("0x"))
    if "proof" in raw:
        proof = tail(bytes.fromhex(raw["proof"].removeprefix("0x")), 32)
    else:
        at = w(body, 2)
        proof = tail(body, at, at + 32 * (1 + w(body[at:], 0)))
    return {
        "name": path.stem,
        "mintData": mint,
        "item": item,
        "payees": item_payees(item),
        "content": item[32 * ITEM_CONTENT_HASH : 32 * ITEM_CONTENT_HASH + 32],
        "media": tail(media, 32),
        "proof": proof,
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--rpc-url", required=True)
    p.add_argument("--deployment", required=True, type=Path, help="deployment record JSON")
    p.add_argument("--from", dest="sender", required=True, help="the keeper's address")
    sign = p.add_mutually_exclusive_group()
    sign.add_argument("--account", help="Foundry keystore name (cast send --account)")
    sign.add_argument("--unlocked", action="store_true", help="the node holds the key (anvil)")
    p.add_argument("--password-file", help="forwarded to cast send with --account")
    p.add_argument("--dry-run", action="store_true", help="print the due steps; send nothing")
    p.add_argument("--from-block", type=int, help="first block to read logs from")
    p.add_argument("--starts", type=Path, help="directory of start-request JSON files")
    p.add_argument("--steps", default=DEFAULT_STEPS, help=f"comma-separated ({DEFAULT_STEPS})")
    for opt in OPT_IN_STEPS:
        p.add_argument(f"--{opt}", action="store_true", help=f"also run the opt-in '{opt}' step")
    args = p.parse_args(argv)

    if not args.dry_run and not (args.account or args.unlocked):
        p.error("sending needs --account or --unlocked (or use --dry-run)")
    signing: list[str] = []
    if args.unlocked:
        signing = ["--unlocked", "--from", args.sender]
    elif args.account:
        signing = ["--account", args.account]
        if args.password_file:
            signing += ["--password-file", args.password_file]
    record = json.loads(args.deployment.read_text(encoding="utf-8"))
    contracts = contracts_of(record)
    starts = [load_request(f) for f in sorted(args.starts.glob("*.json"))] if args.starts else []
    steps = set(filter(None, args.steps.split(","))) | {o for o in OPT_IN_STEPS if getattr(args, o)}
    keeper = Keeper(
        rpc=Rpc(args.rpc_url),
        c=contracts,
        sender=args.sender,
        cast_signing=signing,
        from_block=int(record.get("startBlock", 0)) if args.from_block is None else args.from_block,
        dry_run=args.dry_run,
        starts=starts,
    )
    keeper.run(steps)
    print(f"done: {len(keeper.sent)} sent, {len(keeper.planned) - len(keeper.sent)} not sent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
