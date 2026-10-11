"""A conservative offline gas model for the two content-store transactions.

The constants are upper bounds fitted to measurements of `ContentStore` (Foundry 1.7.1, Solidity
0.8.37, optimizer 200 runs, cold storage): `writeChunk` costs about 63,500 + 201.5 gas per byte for
a new chunk, and `registerManifest` costs about 98,000 + 22,186 per chunk, plus about 350 per MIME
byte and one extra storage slot pair once the MIME type is longer than 31 bytes. The model sits one
to two percent above the measurements at the limits so it survives small compiler drift.
`test/content/tooling/UploaderGolden.t.sol` asserts, on a real `ContentStore`, that the measured
gas never exceeds this model, and that the generated constants there equal the ones below.

It is an estimate for planning and for the cap check, not a substitute for `eth_estimateGas`
against the real chain state. `writeChunk` is priced as a NEW chunk (the worst case); a chunk the
store already holds costs about 16,000.
"""

from __future__ import annotations

from dataclasses import dataclass

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

# A transaction above this share of the cap is flagged: the repository keeps a quarter of the
# cap in reserve for repricing.
MARGIN_FRACTION_NUM, MARGIN_FRACTION_DEN = 3, 4
# The gas limit to send is the estimate plus this much headroom (and never above the cap).
LIMIT_HEADROOM_NUM, LIMIT_HEADROOM_DEN = 11, 10


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


@dataclass(frozen=True)
class GasEstimate:
    execution: int
    transaction: int  # execution + 21,000 + calldata, or the EIP-7623 floor if higher

    @property
    def gas_limit(self) -> int:
        """What to pass as the transaction's gas limit: the estimate plus headroom, rounded up to
        a multiple of 1,000, never above the cap."""
        padded = -(-self.transaction * LIMIT_HEADROOM_NUM // LIMIT_HEADROOM_DEN)
        return min(TX_GAS_CAP, -(-padded // 1000) * 1000)

    @property
    def within_cap(self) -> bool:
        return self.transaction <= TX_GAS_CAP

    @property
    def has_margin(self) -> bool:
        """Whether the estimate leaves the quarter-of-the-cap reserve untouched."""
        return self.transaction * MARGIN_FRACTION_DEN <= TX_GAS_CAP * MARGIN_FRACTION_NUM

    @property
    def cap_fraction(self) -> float:
        return self.transaction / TX_GAS_CAP


def estimate_write_chunk(chunk_length: int, calldata: bytes) -> GasEstimate:
    execution = write_chunk_execution(chunk_length)
    return GasEstimate(execution, transaction_gas(execution, calldata))


def estimate_register(chunk_count: int, mime_length: int, calldata: bytes) -> GasEstimate:
    execution = register_execution(chunk_count, mime_length)
    return GasEstimate(execution, transaction_gas(execution, calldata))
