"""The ordered transactions that stage a planned file, as calldata and `cast send` lines.

Nothing is signed or sent. The tool handles no private key and never reads one: the operator runs
the emitted `cast send` lines (or feeds the calldata to any other tool) with their own signer.

Order: `registerManifest` first by default, so the commitment exists on chain from the start and
anyone can see what is missing with `missingChunks` and finish the upload, then one `writeChunk`
per DISTINCT chunk (a file that repeats a chunk needs it stored once). `--register last` puts the
registration after the chunks instead. The store is permissionless and idempotent, so any order,
any repetition and any split between senders is safe.

A `Base64` or `GzipBase64` file then needs `attestBase64(fileId)` before a renderer will inline
it. Each call reads the chunks it validates, and the call that reaches the end of the file also
reads the last chunk to find the padding, so the final call cannot succeed until the file is
complete. The attest calls therefore come LAST, after the manifest is registered and all chunks
are stored (earlier calls on a big file could run while the upload is still going, but one
simple order is easier to review). One call validates at most 48 chunks, so a file needs
`ceil(chunks / 48)` calls (a repeat call on an attested file is a cheap no-op). Anyone may
send them.

Each transaction is priced by the offline model in `gas.py` under one schedule (`prague` by
default, or `glamsterdam`), which sets its gas limit. `with_rpc_limits` can instead take each
limit from a node's `eth_estimateGas`, plus the same headroom; the model still prices the quotes.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, replace
from decimal import Decimal
from typing import Any, Callable, Iterable, Sequence

from . import abi, gas
from .address import checksum_address
from .encoding import Encoding
from .errors import RpcError, ToolError
from .plan import (
    ATTEST_CHUNKS_PER_CALL,
    CHUNK_SIZE,
    Manifest,
    Plan,
    attest_call_count,
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
    name: str  # "registerManifest", "writeChunk" or "attestBase64"
    chunk_indexes: tuple[int, ...]  # manifest positions a writeChunk call fills
    data: bytes
    estimate: gas.GasEstimate
    filename: str
    rpc_estimate: int | None = None  # the node's eth_estimateGas, when limits come from it

    @property
    def gas_limit(self) -> int:
        if self.rpc_estimate is not None:
            return gas.gas_limit_for(self.rpc_estimate, self.estimate.limit_ceiling)
        return self.estimate.gas_limit

    @property
    def gas_limit_source(self) -> str:
        return "model" if self.rpc_estimate is None else "rpc"


def build_calls(
    manifest: Manifest,
    stored: bytes,
    *,
    register: str = "first",
    skip_register: bool = False,
    present_chunk_hashes: Iterable[bytes] = (),
    attest: bool = True,
    skip_attest: bool = False,
    schedule: gas.Schedule = gas.DEFAULT_SCHEDULE,
    block_gas: int = gas.DEFAULT_BLOCK_GAS,
) -> list[CallPlan]:
    """The transactions for `manifest`, after proving `stored` is the stream it commits to.

    `skip_register`, `present_chunk_hashes` and `skip_attest` drop work the chain already has
    (used with `--only-missing`). A `Base64` or `GzipBase64` file gets its `attestBase64` calls
    after everything else unless `attest` is false. Each transaction is priced under `schedule`,
    with `block_gas` as the assumed block gas limit. Raises `ToolError` if any transaction's
    regular gas would not fit the EIP-7825 cap, or if a base64 file would fail attestation on
    chain.
    """
    if register not in ("first", "last"):
        raise ToolError("register must be 'first' or 'last'")
    check_stored(manifest, stored)
    return _build(
        manifest.chunk_hashes, split_chunks(stored), manifest.stored_length, manifest.encoding,
        manifest.mime_type, manifest.media_sha256, manifest.file_id, register=register,
        skip_register=skip_register, present_chunk_hashes=present_chunk_hashes, attest=attest,
        skip_attest=skip_attest, schedule=schedule, block_gas=block_gas,
    )


def calls_for_plan(
    plan: Plan, *, schedule: gas.Schedule = gas.DEFAULT_SCHEDULE,
    block_gas: int = gas.DEFAULT_BLOCK_GAS,
) -> list[CallPlan]:
    """Every transaction that puts a freshly planned file on chain (registration, each distinct
    chunk, and the attest calls of a base64 file), for quoting. `plan` already proved its own
    stream, so nothing is re-checked."""
    return _build(
        plan.chunk_hashes, list(plan.chunks()), plan.stored_length, plan.encoding,
        plan.mime_type, plan.media_sha256, plan.file_id, register="first", skip_register=False,
        present_chunk_hashes=(), attest=True, skip_attest=False, schedule=schedule,
        block_gas=block_gas,
    )


def _build(
    chunk_hashes: Sequence[bytes],
    chunks: Sequence[bytes],
    stored_length: int,
    encoding: Encoding,
    mime_type: str,
    media_sha256: bytes,
    file_id: bytes,
    *,
    register: str,
    skip_register: bool,
    present_chunk_hashes: Iterable[bytes],
    attest: bool,
    skip_attest: bool,
    schedule: gas.Schedule,
    block_gas: int,
) -> list[CallPlan]:
    present = set(present_chunk_hashes)
    writes: list[tuple[tuple[int, ...], bytes]] = []
    positions: dict[bytes, list[int]] = {}
    for index, digest in enumerate(chunk_hashes):
        positions.setdefault(digest, []).append(index)
    seen: set[bytes] = set()
    for index, digest in enumerate(chunk_hashes):
        if digest in seen:
            continue
        seen.add(digest)
        if digest not in present:
            writes.append((tuple(positions[digest]), chunks[index]))

    drafts: list[tuple[str, tuple[int, ...], bytes, gas.GasEstimate]] = []
    for indexes, chunk in writes:
        data = abi.encode_write_chunk(chunk)
        estimate = gas.estimate_write_chunk(len(chunk), data, schedule, block_gas)
        drafts.append(("writeChunk", indexes, data, estimate))
    if not skip_register:
        data = abi.encode_register_manifest(
            chunk_hashes, stored_length, int(encoding), mime_type, media_sha256
        )
        estimate = gas.estimate_register(
            len(chunk_hashes), len(mime_type.encode("utf-8")), data, schedule, block_gas
        )
        item = ("registerManifest", (), data, estimate)
        if register == "first":
            drafts.insert(0, item)
        else:
            drafts.append(item)
    if attest and encoding.uses_base64 and not skip_attest:
        data = abi.encode_call(abi.ATTEST_BASE64, file_id)
        total = len(chunk_hashes)
        for start in range(0, total, ATTEST_CHUNKS_PER_CALL):
            stop = min(start + ATTEST_CHUNKS_PER_CALL, total)
            estimate = gas.estimate_attest(
                stop - start, data, schedule, block_gas, first_call=start == 0
            )
            drafts.append(("attestBase64", tuple(range(start, stop)), data, estimate))
        assert sum(d[0] == "attestBase64" for d in drafts) == attest_call_count(total)

    width = max(3, len(str(len(drafts))))
    calls: list[CallPlan] = []
    for n, (name, indexes, data, estimate) in enumerate(drafts):
        if not estimate.within_cap:
            if schedule.cap_counts_state:
                raise ToolError(
                    f"{name} would use about {estimate.transaction:,} gas, over the EIP-7825 "
                    f"transaction cap of {gas.TX_GAS_CAP:,}"
                )
            raise ToolError(
                f"{name} would use about {estimate.regular:,} gas of regular (non-state) gas, "
                f"over the EIP-7825 transaction cap of {gas.TX_GAS_CAP:,}"
            )
        suffix = f"-{indexes[0]:03d}" if indexes else ""
        calls.append(
            CallPlan(n, name, indexes, data, estimate, f"{n:0{width}d}-{name}{suffix}.calldata")
        )
    return calls


def quotes(calls: Sequence[CallPlan], gwei: Decimal) -> list[gas.Quote]:
    """What these transactions cost under each schedule, from the offline model, at `gwei`."""
    estimates = [c.estimate for c in calls]
    return [gas.quote(estimates, schedule, gwei) for schedule in gas.SCHEDULES.values()]


def gas_warnings(calls: Sequence[CallPlan]) -> list[str]:
    """What an operator must know before sending: a transaction that leaves no reserve under the
    cap, that a node with the default 50M RPC gas cap cannot estimate, or that needs more gas
    than the assumed block gas limit."""
    out: list[str] = []
    no_margin = [c for c in calls if not c.estimate.has_margin]
    if no_margin:
        out.append(
            f"{_names(no_margin)} use(s) more than three quarters of the EIP-7825 gas cap"
            + ("" if no_margin[0].estimate.schedule.cap_counts_state else " in regular gas")
        )
    over_estimate = [c for c in calls if c.estimate.above_estimate_cap]
    if over_estimate:
        out.append(
            f"{_names(over_estimate)} need(s) more than {gas.RPC_ESTIMATE_CAP:,} gas (largest "
            f"{max(c.estimate.transaction for c in over_estimate):,}): a node with the default "
            "RPC gas cap cannot estimate or simulate it, so keep the offline model's gas limit "
            "or use a node whose cap you raised"
        )
    over_block = [c for c in calls if c.estimate.above_block_gas]
    if over_block:
        out.append(
            f"{_names(over_block)} need(s) more gas than the assumed block gas limit of "
            f"{over_block[0].estimate.block_gas:,} (largest "
            f"{max(c.estimate.transaction for c in over_block):,}): no such block can include "
            "it; check the chain's block gas limit (--block-gas)"
        )
    return out


def _names(calls: Sequence[CallPlan]) -> str:
    counts: dict[str, int] = {}
    for c in calls:
        counts[c.name] = counts.get(c.name, 0) + 1
    return ", ".join(f"{n} {name}" for name, n in counts.items())


def with_rpc_limits(
    calls: Sequence[CallPlan], estimate_gas: Callable[[bytes], int]
) -> tuple[list[CallPlan], list[str]]:
    """Each call's gas limit taken from the node's `eth_estimateGas` (`estimate_gas(calldata)`),
    plus the model's headroom, instead of from the offline model.

    A call the node cannot estimate keeps the model's limit, and a note says so: the attest calls
    revert until every chunk is stored, and a node with the default RPC gas cap refuses anything
    above 50M gas (a manifest of more than about 440 chunks under Glamsterdam). Under a schedule
    whose cap counts every unit of gas (Prague), an estimate above the cap is refused: the chain
    prices state creation differently, and `--schedule glamsterdam` is probably what it needs.
    """
    out: list[CallPlan] = []
    failed: dict[str, list[tuple[CallPlan, str]]] = {}
    above_model: list[tuple[CallPlan, int]] = []
    for c in calls:
        try:
            node = estimate_gas(c.data)
        except RpcError as exc:
            failed.setdefault(c.name, []).append((c, str(exc)))
            out.append(c)
            continue
        if c.estimate.schedule.cap_counts_state and node > gas.TX_GAS_CAP:
            raise ToolError(
                f"the node estimates {c.name} (transaction {c.index + 1}) at {node:,} gas, over "
                f"the EIP-7825 cap of {gas.TX_GAS_CAP:,} that the "
                f"{c.estimate.schedule.name} schedule applies to all gas: the chain prices state "
                "creation differently (use --schedule glamsterdam on a Glamsterdam chain)"
            )
        if node > c.estimate.transaction:
            above_model.append((c, node))
        out.append(replace(c, rpc_estimate=node))
    notes: list[str] = []
    for name, group in failed.items():
        notes.append(
            f"{len(group)} {name} call(s) could not be estimated by the node and keep the "
            f"offline model's gas limit (first: {group[0][1]})"
        )
    if above_model:
        c, node = max(above_model, key=lambda item: item[1] - item[0].estimate.transaction)
        notes.append(
            f"the node estimates {len(above_model)} call(s) above the "
            f"{c.estimate.schedule.name} model, for example {c.name} (transaction "
            f"{c.index + 1}) at {node:,} against {c.estimate.transaction:,}"
        )
    return out, notes


def calls_document(
    calls: list[CallPlan], file_id: bytes, store: bytes, *, skipped_register: bool,
    skipped_chunks: int, skipped_attest: bool = False,
    schedule: gas.Schedule = gas.DEFAULT_SCHEDULE, block_gas: int = gas.DEFAULT_BLOCK_GAS,
    gwei: Decimal = Decimal(1), notes: Sequence[str] = (),
) -> dict[str, Any]:
    """The machine-readable `calls.json`. Calldata lives in the named files, not inline."""
    return {
        "schema": CALLS_SCHEMA,
        "fileId": hex0x(file_id),
        "store": checksum_address(store),
        "chunkSize": CHUNK_SIZE,
        "gasCap": gas.TX_GAS_CAP,
        "gasSchedule": schedule.name,
        "gasCapCountsStateGas": schedule.cap_counts_state,
        "blockGasAssumption": block_gas,
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
                "regularGasEstimate": c.estimate.regular,
                "stateGasEstimate": c.estimate.state,
                "gasLimit": c.gas_limit,
                "gasLimitSource": c.gas_limit_source,
                "nodeGasEstimate": c.rpc_estimate,
            }
            for c in calls
        ],
        "skipped": {
            "registerManifest": skipped_register,
            "chunksAlreadyStored": skipped_chunks,
            "attestBase64": skipped_attest,
        },
        "totalGasEstimate": sum(c.estimate.transaction for c in calls),
        "quotes": [
            {"schedule": q.schedule, "gas": q.gas, "gwei": str(q.gwei), "eth": str(q.eth)}
            for q in quotes(calls, gwei)
        ],
        "warnings": [*gas_warnings(calls), *notes],
    }


def calls_json(document: dict[str, Any]) -> str:
    return json.dumps(document, indent=2) + "\n"


def calldata_file_text(call: CallPlan) -> str:
    return hex0x(call.data) + "\n"


def render_script(
    calls: list[CallPlan], file_id: bytes, store: bytes, schedule: gas.Schedule | None = None
) -> str:
    """A bash script of `cast send` lines, one per transaction, that the operator reviews and runs.

    The calldata is read from the files beside the script (a chunk is about 49,000 hex characters,
    too long for some shells to paste). The signer is the operator's: `$SIGNER` holds their own
    `cast` signer flags. Whole file contents are never inlined, so the script stays readable.
    """
    store_text = checksum_address(store)
    largest = max((c.estimate.transaction for c in calls), default=0)
    if schedule is None:
        schedule = calls[0].estimate.schedule if calls else gas.DEFAULT_SCHEDULE
    if schedule.cap_counts_state:
        cap_note = f" the EIP-7825 cap is {gas.TX_GAS_CAP:,})"
    else:
        cap_note = f" the EIP-7825 cap of {gas.TX_GAS_CAP:,} bounds regular gas only)"
    lines = [
        "#!/usr/bin/env bash",
        "# Generated by `python -m tools.content calls`. Nothing here has been sent.",
        "# Review each command, then run this yourself with your own signer.",
        f"#   file ID       {hex0x(file_id)}",
        f"#   content store {store_text}",
        f"#   gas schedule  {schedule.name}",
        f"#   transactions  {len(calls)} (largest estimate {largest:,} gas;{cap_note}",
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
        if c.name == "registerManifest":
            what = f"registerManifest ({c.estimate.execution:,} gas of execution)"
        elif c.name == "attestBase64":
            what = f"attestBase64, chunks {c.chunk_indexes[0]} to {c.chunk_indexes[-1]}"
        else:
            what = f"writeChunk, chunk {', '.join(map(str, c.chunk_indexes))}"
        lines.append(f"# {c.index + 1}/{total} {what}; estimate {c.estimate.transaction:,} gas")
        lines.append(
            f'cast send "$STORE" --data "$(cat {c.filename})" --gas-limit {c.gas_limit}'
            ' --rpc-url "$ETH_RPC_URL" $SIGNER'
        )
    return "\n".join(lines) + "\n"
