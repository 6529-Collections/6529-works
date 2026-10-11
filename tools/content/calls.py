"""The ordered transactions that stage a planned file, as calldata and `cast send` lines.

Nothing is signed or sent. The tool handles no private key and never reads one: the operator runs
the emitted `cast send` lines (or feeds the calldata to any other tool) with their own signer.

Order: `registerManifest` first by default, so the commitment exists on chain from the start and
anyone can see what is missing with `missingChunks` and finish the upload, then one `writeChunk`
per DISTINCT chunk (a file that repeats a chunk needs it stored once). `--register last` puts the
registration after the chunks instead. The store is permissionless and idempotent, so any order,
any repetition and any split between senders is safe.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Iterable

from . import abi, gas
from .address import checksum_address
from .errors import ToolError
from .plan import (
    CHUNK_SIZE,
    Manifest,
    check_stored,
    hex0x,
    split_chunks,
)

CALLS_SCHEMA = "6529-works/content-calls/v1"


@dataclass(frozen=True)
class CallPlan:
    """One transaction to send to the store. `value` is always zero: the store has no payable
    function."""

    index: int
    name: str  # "registerManifest" or "writeChunk"
    chunk_indexes: tuple[int, ...]  # manifest positions a writeChunk call fills
    data: bytes
    estimate: gas.GasEstimate
    filename: str

    @property
    def gas_limit(self) -> int:
        return self.estimate.gas_limit


def build_calls(
    manifest: Manifest,
    stored: bytes,
    *,
    register: str = "first",
    skip_register: bool = False,
    present_chunk_hashes: Iterable[bytes] = (),
) -> list[CallPlan]:
    """The transactions for `manifest`, after proving `stored` is the stream it commits to.

    `skip_register` and `present_chunk_hashes` drop work the chain already has (used with
    `--only-missing`). Raises `ToolError` if any transaction would not fit the Fusaka gas cap.
    """
    if register not in ("first", "last"):
        raise ToolError("register must be 'first' or 'last'")
    check_stored(manifest, stored)
    present = set(present_chunk_hashes)

    writes: list[tuple[tuple[int, ...], bytes]] = []
    positions: dict[bytes, list[int]] = {}
    chunks = split_chunks(stored)
    for index, digest in enumerate(manifest.chunk_hashes):
        positions.setdefault(digest, []).append(index)
    seen: set[bytes] = set()
    for index, digest in enumerate(manifest.chunk_hashes):
        if digest in seen:
            continue
        seen.add(digest)
        if digest not in present:
            writes.append((tuple(positions[digest]), chunks[index]))

    drafts: list[tuple[str, tuple[int, ...], bytes, gas.GasEstimate]] = []
    for indexes, chunk in writes:
        data = abi.encode_write_chunk(chunk)
        drafts.append(("writeChunk", indexes, data, gas.estimate_write_chunk(len(chunk), data)))
    if not skip_register:
        data = abi.encode_register_manifest(
            manifest.chunk_hashes,
            manifest.stored_length,
            int(manifest.encoding),
            manifest.mime_type,
            manifest.media_sha256,
        )
        estimate = gas.estimate_register(
            len(manifest.chunk_hashes), len(manifest.mime_type.encode("utf-8")), data
        )
        item = ("registerManifest", (), data, estimate)
        if register == "first":
            drafts.insert(0, item)
        else:
            drafts.append(item)

    width = max(3, len(str(len(drafts))))
    calls: list[CallPlan] = []
    for n, (name, indexes, data, estimate) in enumerate(drafts):
        if not estimate.within_cap:
            raise ToolError(
                f"{name} would use about {estimate.transaction:,} gas, over the EIP-7825 "
                f"transaction cap of {gas.TX_GAS_CAP:,}"
            )
        suffix = f"-{indexes[0]:03d}" if name == "writeChunk" else ""
        calls.append(
            CallPlan(n, name, indexes, data, estimate, f"{n:0{width}d}-{name}{suffix}.calldata")
        )
    return calls


def calls_document(
    calls: list[CallPlan], file_id: bytes, store: bytes, *, skipped_register: bool,
    skipped_chunks: int,
) -> dict[str, Any]:
    """The machine-readable `calls.json`. Calldata lives in the named files, not inline."""
    return {
        "schema": CALLS_SCHEMA,
        "fileId": hex0x(file_id),
        "store": checksum_address(store),
        "chunkSize": CHUNK_SIZE,
        "gasCap": gas.TX_GAS_CAP,
        "transactions": [
            {
                "index": c.index,
                "name": c.name,
                "to": checksum_address(store),
                "value": "0",
                "calldataFile": c.filename,
                "calldataBytes": len(c.data),
                "chunkIndexes": list(c.chunk_indexes),
                "gasEstimate": c.estimate.transaction,
                "gasLimit": c.gas_limit,
            }
            for c in calls
        ],
        "skipped": {"registerManifest": skipped_register, "chunksAlreadyStored": skipped_chunks},
        "totalGasEstimate": sum(c.estimate.transaction for c in calls),
    }


def calls_json(document: dict[str, Any]) -> str:
    return json.dumps(document, indent=2) + "\n"


def calldata_file_text(call: CallPlan) -> str:
    return hex0x(call.data) + "\n"


def render_script(calls: list[CallPlan], file_id: bytes, store: bytes) -> str:
    """A bash script of `cast send` lines, one per transaction, that the operator reviews and runs.

    The calldata is read from the files beside the script (a chunk is about 49,000 hex characters,
    too long for some shells to paste). The signer is the operator's: `$SIGNER` holds their own
    `cast` signer flags. Whole file contents are never inlined, so the script stays readable.
    """
    store_text = checksum_address(store)
    largest = max((c.estimate.transaction for c in calls), default=0)
    lines = [
        "#!/usr/bin/env bash",
        "# Generated by `python -m tools.content calls`. Nothing here has been sent.",
        "# Review each command, then run this yourself with your own signer.",
        f"#   file ID       {hex0x(file_id)}",
        f"#   content store {store_text}",
        f"#   transactions  {len(calls)} (largest estimate {largest:,} gas;"
        f" the EIP-7825 cap is {gas.TX_GAS_CAP:,})",
        "# Environment:",
        "#   ETH_RPC_URL  the RPC endpoint of the chain the content store is on",
        '#   SIGNER       your `cast` signer flags, for example "--account my-keystore" or',
        '#                "--ledger". Never put a raw private key here or in shell history.',
        "# shellcheck disable=SC2086  # $SIGNER is deliberately word-split into flags",
        "set -euo pipefail",
        'cd "$(dirname "$0")"',
        ': "${ETH_RPC_URL:?set ETH_RPC_URL to your RPC endpoint}"',
        ': "${SIGNER:?set SIGNER to your cast signer flags}"',
        f"STORE={store_text}",
        "",
    ]
    total = len(calls)
    for c in calls:
        what = (
            f"registerManifest ({c.estimate.execution:,} gas of execution)"
            if c.name == "registerManifest"
            else f"writeChunk, chunk {', '.join(map(str, c.chunk_indexes))}"
        )
        lines.append(f"# {c.index + 1}/{total} {what}; estimate {c.estimate.transaction:,} gas")
        lines.append(
            f'cast send "$STORE" --data "$(cat {c.filename})" --gas-limit {c.gas_limit}'
            ' --rpc-url "$ETH_RPC_URL" $SIGNER'
        )
    return "\n".join(lines) + "\n"
