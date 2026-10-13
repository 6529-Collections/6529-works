"""A conservative offline gas model for the content-store transactions, under two pricing schedules.

**Prague** (`PRAGUE`, the default, used by anvil and the tests). The constants are upper bounds
fitted to measurements of `ContentStore` (Foundry 1.7.1, Solidity 0.8.37, optimizer 200 runs,
cold storage): `writeChunk` costs about 63,500 + 201.5 gas per byte for a new chunk, and
`registerManifest` costs about 98,000 + 22,186 per chunk, plus about 350 per MIME byte and one
extra storage slot pair once the MIME type is longer than 31 bytes. The model sits one to two
percent above the measurements at the limits so it survives small compiler drift.
`test/content/tooling/UploaderGolden.t.sol` asserts, on a real `ContentStore`, that the measured
gas never exceeds this model, and that the generated constants there equal the ones below. Under
Prague every unit of gas counts against the EIP-7825 cap.

**Glamsterdam** (`GLAMSTERDAM`). Glamsterdam reprices state creation. The model is the Prague
model plus a state surcharge per new contract, per byte of new contract code and per new storage
slot. The surcharges are the increase over Prague measured on Sepolia, which activated
Glamsterdam on 6 October 2026, from the receipts of 11 and 12 October 2026
(`deployments/11155111/flows.md` and `README.md`). Mainnet parameters may differ. The fit:

- `writeChunk` receipts for 191, 1,024, 8,192 and 24,572 bytes, each against its Prague replay,
  rise by 247,459 + 1,330.19 gas per byte, within 20 gas. A new chunk is one new contract with
  `n + 1` code bytes (the STOP byte and the data) and one new slot (its `chunkPointer`).
- `registerManifest` writes 4 + `chunks` new slots (plus the long-MIME slots). Per chunk hash it
  cost 110,593 (simulated `gasUsed`, 1 to 256 chunks) to 111,497 (`eth_estimateGas`, 1 to 43
  chunks) on Sepolia, against 22,186 on Prague: 88,400 to 89,300 more per new slot.
- So: 89,400 per new slot, 1,331 per code byte, and 157,000 per new contract (the rest of the
  247,459 after one slot and the STOP byte). Each sits at or above every measured increase.

Under Glamsterdam the EIP-7825 cap of 16,777,216 bounds only the regular gas, as observed on
Sepolia: it accepts transactions above the cap when the excess is state-creation gas. The model's
regular part is the Prague estimate, which still prices state creation at its Prague cost and so
bounds the regular gas from above, as far as Sepolia shows (its reads and other execution cost
what they cost on Prague, or slightly less); the state part is the surcharge. That is an
observation of Sepolia, not a reading of the final EIP mechanics.

It is an estimate for planning, for quotes and for the cap check, not a substitute for
`eth_estimateGas` against the real chain state. `writeChunk` is priced as a NEW chunk (the worst
case); a chunk the store already holds costs about 16,000.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from . import abi
from .plan import CHUNK_SIZE

TX_GAS_CAP = 16_777_216  # EIP-7825 (Fusaka): the most any single transaction may use
TX_BASE_GAS = 21_000
ZERO_BYTE_GAS = 4  # EIP-2028
NONZERO_BYTE_GAS = 16
FLOOR_TOKEN_GAS = 10  # EIP-7623: 21,000 + 10 per calldata token, a zero byte is 1 token, else 4

# `writeChunk` execution for a new chunk of n bytes: base + per-byte * n.
WRITE_CHUNK_BASE_GAS = 70_000
WRITE_CHUNK_BYTE_GAS = 205
# `registerManifest` execution: base + per-chunk * count + per-MIME-byte * len(mime), plus a
# one-time charge once the MIME type needs more than one storage slot (longer than 31 bytes).
REGISTER_BASE_GAS = 100_000
REGISTER_CHUNK_GAS = 22_400
REGISTER_MIME_BYTE_GAS = 400
REGISTER_LONG_MIME_GAS = 45_000
SHORT_STRING_MAX = 31
# `attestBase64` execution validating k chunks: base + per-chunk * k. A call reads and checks
# each of its k chunks. A call that reaches the end of the file also reads the file's last chunk
# to find the `=` padding (about 20,000 more when that chunk is not one of the k); earlier calls
# do not. The worst call is 48 checked chunks plus that read, measured at about 8.50M, against
# a model of 8.79M.
ATTEST_BASE_GAS = 150_000
ATTEST_CHUNK_GAS = 180_000

# A transaction above this share of the cap is flagged: the repository keeps a quarter of the
# cap in reserve for repricing.
MARGIN_FRACTION_NUM, MARGIN_FRACTION_DEN = 3, 4
# The gas limit to send is the estimate plus this much headroom (and never above the cap under
# Prague, or the assumed block gas limit under Glamsterdam).
LIMIT_HEADROOM_NUM, LIMIT_HEADROOM_DEN = 11, 10

# --- Glamsterdam (measured on Sepolia, 11 and 12 October 2026; mainnet may differ) ---

# The increase over Prague for each kind of state a transaction creates (see the module notes).
GLAMSTERDAM_CONTRACT_GAS = 157_000  # per new contract (a chunk's CREATE2)
GLAMSTERDAM_CODE_BYTE_GAS = 1_331  # per byte of new contract code
GLAMSTERDAM_SLOT_GAS = 89_400  # per storage slot written from zero
# `registerManifest` writes these slots of a new `File` besides the chunk list's elements: the
# SHA-256, the packed length and encoding, the MIME string and the chunk list's length.
REGISTER_FIXED_SLOTS = 4
# The largest `eth_estimateGas` (and `eth_simulateV1`) the public Sepolia RPC answers, observed;
# geth and reth default to the same 50M cap (`--rpc.gascap`) unless a node operator raises it.
RPC_ESTIMATE_CAP = 50_000_000
# The block gas limit the plan assumes when it warns (a transaction must fit one block). An
# assumption, deliberately conservative: pass the target chain's limit (Sepolia's blocks were
# 200M on 11 October 2026).
DEFAULT_BLOCK_GAS = 60_000_000

GWEI_PER_ETH = 1_000_000_000


@dataclass(frozen=True)
class Footprint:
    """The state a transaction creates, which Glamsterdam prices separately."""

    contracts: int = 0
    code_bytes: int = 0
    slots: int = 0


@dataclass(frozen=True)
class Schedule:
    """A gas pricing schedule: the surcharge over Prague for each kind of new state, and whether
    the EIP-7825 cap counts that state gas."""

    name: str
    contract_gas: int
    code_byte_gas: int
    slot_gas: int
    cap_counts_state: bool

    def state_gas(self, footprint: Footprint) -> int:
        return (
            self.contract_gas * footprint.contracts
            + self.code_byte_gas * footprint.code_bytes
            + self.slot_gas * footprint.slots
        )


PRAGUE = Schedule("prague", 0, 0, 0, cap_counts_state=True)
GLAMSTERDAM = Schedule(
    "glamsterdam",
    GLAMSTERDAM_CONTRACT_GAS,
    GLAMSTERDAM_CODE_BYTE_GAS,
    GLAMSTERDAM_SLOT_GAS,
    cap_counts_state=False,
)
SCHEDULES = {schedule.name: schedule for schedule in (PRAGUE, GLAMSTERDAM)}
DEFAULT_SCHEDULE = PRAGUE


def schedule_named(name: str) -> Schedule:
    try:
        return SCHEDULES[name]
    except KeyError:
        raise ValueError(f"unknown gas schedule {name!r}; known: {', '.join(SCHEDULES)}") from None


def write_chunk_execution(length: int) -> int:
    """Model of the gas `writeChunk` uses to store a new chunk of `length` bytes."""
    if not 0 <= length <= CHUNK_SIZE:
        raise ValueError(f"a chunk is at most {CHUNK_SIZE} bytes")
    return WRITE_CHUNK_BASE_GAS + WRITE_CHUNK_BYTE_GAS * length


def register_execution(chunk_count: int, mime_length: int) -> int:
    """Model of the gas `registerManifest` uses for a new manifest."""
    long_mime = REGISTER_LONG_MIME_GAS if mime_length > SHORT_STRING_MAX else 0
    return (
        REGISTER_BASE_GAS
        + REGISTER_CHUNK_GAS * chunk_count
        + REGISTER_MIME_BYTE_GAS * mime_length
        + long_mime
    )


def attest_execution(chunks_in_call: int) -> int:
    """Model of the gas one `attestBase64` call uses to validate this many chunks (at most 48)."""
    if not 1 <= chunks_in_call <= 48:
        raise ValueError("one attestBase64 call validates 1 to 48 chunks")
    return ATTEST_BASE_GAS + ATTEST_CHUNK_GAS * chunks_in_call


def write_chunk_footprint(length: int) -> Footprint:
    """A new chunk: one CREATE2 contract holding the STOP byte and the data, and its pointer."""
    return Footprint(contracts=1, code_bytes=length + 1, slots=1)


def register_footprint(chunk_count: int, mime_length: int) -> Footprint:
    """A new manifest: the `File` fields, one slot per chunk hash, and a long MIME type's data."""
    mime_slots = -(-mime_length // 32) if mime_length > SHORT_STRING_MAX else 0
    return Footprint(slots=REGISTER_FIXED_SLOTS + chunk_count + mime_slots)


def attest_footprint(first_call: bool) -> Footprint:
    """The attestation record is one slot: the first call writes it from zero, later calls update
    it."""
    return Footprint(slots=1 if first_call else 0)


def calldata_gas(data: bytes) -> int:
    """EIP-2028 calldata cost: 4 gas per zero byte, 16 per other byte."""
    zeros = data.count(0)
    return ZERO_BYTE_GAS * zeros + NONZERO_BYTE_GAS * (len(data) - zeros)


def calldata_floor_gas(data: bytes) -> int:
    """EIP-7623 floor: the transaction costs at least this much whatever execution uses."""
    zeros = data.count(0)
    tokens = zeros + 4 * (len(data) - zeros)
    return TX_BASE_GAS + FLOOR_TOKEN_GAS * tokens


def transaction_gas(execution: int, calldata: bytes) -> int:
    """Gas a transaction with this execution cost and calldata is charged."""
    standard = TX_BASE_GAS + calldata_gas(calldata) + execution
    return max(standard, calldata_floor_gas(calldata))


def gas_limit_for(estimate: int, ceiling: int) -> int:
    """A gas limit for a transaction estimated at `estimate`: plus headroom, rounded up to a
    multiple of 1,000, never above `ceiling`. An estimate already above `ceiling` keeps its
    headroom: no limit could make that transaction fit, and the plan says so."""
    padded = -(-estimate * LIMIT_HEADROOM_NUM // LIMIT_HEADROOM_DEN)
    limit = -(-padded // 1000) * 1000
    return limit if estimate > ceiling else min(ceiling, limit)


@dataclass(frozen=True)
class GasEstimate:
    execution: int  # the modelled execution gas, at Prague prices
    transaction: int  # all the gas the transaction is charged under `schedule`: regular + state
    state: int = 0  # the schedule's state surcharge, included in `transaction`
    footprint: Footprint = Footprint()
    schedule: Schedule = PRAGUE
    block_gas: int = DEFAULT_BLOCK_GAS  # the block gas limit assumed for the warnings

    @property
    def regular(self) -> int:
        """The part of `transaction` the EIP-7825 cap counts (all of it under Prague)."""
        return self.transaction - self.state

    @property
    def limit_ceiling(self) -> int:
        """The most a gas limit may be: the cap when it counts every unit of gas (Prague), else
        the block gas limit, since the cap then bounds only the regular part."""
        return TX_GAS_CAP if self.schedule.cap_counts_state else self.block_gas

    @property
    def gas_limit(self) -> int:
        """What to pass as the transaction's gas limit: the estimate plus headroom, rounded up to
        a multiple of 1,000, never above `limit_ceiling` unless the estimate already is."""
        return gas_limit_for(self.transaction, self.limit_ceiling)

    @property
    def within_cap(self) -> bool:
        return self.regular <= TX_GAS_CAP

    @property
    def has_margin(self) -> bool:
        """Whether the estimate leaves the quarter-of-the-cap reserve untouched."""
        return self.regular * MARGIN_FRACTION_DEN <= TX_GAS_CAP * MARGIN_FRACTION_NUM

    @property
    def cap_fraction(self) -> float:
        return self.regular / TX_GAS_CAP

    @property
    def above_estimate_cap(self) -> bool:
        """Whether a node with the default 50M RPC gas cap cannot estimate or simulate it."""
        return self.transaction > RPC_ESTIMATE_CAP

    @property
    def above_block_gas(self) -> bool:
        """Whether it needs more gas than the assumed block gas limit holds."""
        return self.transaction > self.block_gas

    def under(self, schedule: Schedule, block_gas: int | None = None) -> "GasEstimate":
        """The same transaction priced under another schedule."""
        state = schedule.state_gas(self.footprint)
        return GasEstimate(
            self.execution, self.regular + state, state, self.footprint, schedule,
            self.block_gas if block_gas is None else block_gas,
        )


def _estimate(
    execution: int, calldata: bytes, footprint: Footprint, schedule: Schedule, block_gas: int
) -> GasEstimate:
    regular = transaction_gas(execution, calldata)
    state = schedule.state_gas(footprint)
    return GasEstimate(execution, regular + state, state, footprint, schedule, block_gas)


def estimate_write_chunk(
    chunk_length: int, calldata: bytes, schedule: Schedule = PRAGUE,
    block_gas: int = DEFAULT_BLOCK_GAS,
) -> GasEstimate:
    execution = write_chunk_execution(chunk_length)
    return _estimate(
        execution, calldata, write_chunk_footprint(chunk_length), schedule, block_gas
    )


def estimate_attest(
    chunks_in_call: int, calldata: bytes, schedule: Schedule = PRAGUE,
    block_gas: int = DEFAULT_BLOCK_GAS, *, first_call: bool = True,
) -> GasEstimate:
    execution = attest_execution(chunks_in_call)
    return _estimate(execution, calldata, attest_footprint(first_call), schedule, block_gas)


def estimate_register(
    chunk_count: int, mime_length: int, calldata: bytes, schedule: Schedule = PRAGUE,
    block_gas: int = DEFAULT_BLOCK_GAS,
) -> GasEstimate:
    execution = register_execution(chunk_count, mime_length)
    return _estimate(
        execution, calldata, register_footprint(chunk_count, mime_length), schedule, block_gas
    )


def chunks_per_transaction(
    chunk_length: int = CHUNK_SIZE,
    schedule: Schedule = PRAGUE,
    block_gas: int = DEFAULT_BLOCK_GAS,
    estimate_cap: int = RPC_ESTIMATE_CAP,
) -> int:
    """The most new chunks of `chunk_length` bytes that one batched transaction (for example
    through Multicall3) should carry.

    A batch of k chunks is priced as k single transactions, which pays the 21,000 base k times and
    so covers the batching contract's own overhead. A chunk always goes alone if it must. Another
    is added only while the batch's regular gas keeps the quarter-of-the-cap reserve, and, when
    the cap does not count state gas (Glamsterdam), only while the whole batch stays within
    `estimate_cap` and `block_gas`. Under Prague that is 2 full chunks; under Glamsterdam 1.
    """
    one = estimate_write_chunk(
        chunk_length, abi.encode_write_chunk(b"\xff" * chunk_length), schedule, block_gas
    )
    count = 1
    while True:
        more = count + 1
        if more * one.regular * MARGIN_FRACTION_DEN > TX_GAS_CAP * MARGIN_FRACTION_NUM:
            return count
        if not schedule.cap_counts_state:
            total = more * one.transaction
            if total > estimate_cap or total > block_gas:
                return count
        count = more


@dataclass(frozen=True)
class Quote:
    """What a set of transactions costs under one schedule, at a gas price in gwei."""

    schedule: str
    gas: int
    gwei: Decimal

    @property
    def eth(self) -> Decimal:
        return Decimal(self.gas) * self.gwei / GWEI_PER_ETH


def quote(estimates: list[GasEstimate], schedule: Schedule, gwei: Decimal) -> Quote:
    """The cost of these transactions re-priced under `schedule`, at `gwei` per gas."""
    return Quote(schedule.name, sum(e.under(schedule).transaction for e in estimates), gwei)
