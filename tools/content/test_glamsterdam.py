"""Tests for the gas schedules: Glamsterdam's state pricing and cap semantics, batching, the
warnings, the cost quotes, gas limits from a node, and golden values tied to the Sepolia receipts
in `deployments/11155111/flows.md` and `deployments/11155111/README.md`.

The Prague model and its golden vectors are covered, unchanged, by `test_calls.py`,
`test_golden.py` and `test_anvil.py`.
"""

from __future__ import annotations

import json
import os
import unittest
from decimal import Decimal
from pathlib import Path
from unittest import mock

from tools.content import abi, calls, gas
from tools.content import plan as pl
from tools.content.encoding import Encoding
from tools.content.errors import ToolError
from tools.content.fake_chain import NodeError, Revert
from tools.content.fake_chain import FakeChain
from tools.content.golden import counter_bytes
from tools.content.keccak import keccak256
from tools.content.test_calls import manifest_for
from tools.content.test_cli import STORE, TempDirCase, run

G = gas.GLAMSTERDAM
P = gas.PRAGUE
FULL = pl.CHUNK_SIZE

# --- Sepolia receipts (r2 and r1 ran the same ContentStore code and cost the same) ---

# writeChunk: (stored bytes, Sepolia gasUsed, the same transaction replayed with Prague costs).
# Base64 media and a JSON record: every byte is non-zero, like the fill used below.
WRITE_RECEIPTS = (
    (191, 625_103, 123_587),  # a record, r2 0x542eda40
    (1_024, 1_914_322, 304_754),  # r2 0x2a3f7814
    (8_192, 13_008_576, 1_864_224),  # r2 0xf8236b59
    (24_572, 38_364_370, 5_431_552),  # r2 0x2a82b6ac
)
# The 7,048-byte CC0 legal code (text/plain), written at deployment: r1 0x7076b65e, r2 0x6dcc6877.
CC0_WRITE = (7_048, 11_238_006)
CC0_REGISTER = ("text/plain", 577_737)  # r2 0x15eb1c0c
# registerManifest of one chunk: (MIME type, Sepolia gasUsed, Prague replay). 5 new slots.
REGISTER_RECEIPTS = (
    ("image/png", 577_375, 143_475),  # r2 0xa164e300
    ("application/json", 579_897, 145_997),  # r2 0x61eeb022
)
# Manifests by size on r1's store (eth_estimateGas; the 256-chunk row is a simulated gasUsed).
REGISTER_BY_SIZE = ((1, 583_137), (11, 1_698_112), (43, 5_265_859), (256, 28_784_463))
# attestBase64 of one chunk: (stored bytes, Sepolia gasUsed, Prague replay).
ATTEST_RECEIPTS = ((1_024, 153_123, 70_103), (8_192, 205_248, 122_228), (24_572, 325_172, 242_152))
# The Sepolia line through the writeChunk receipts: 328,760 + 1,547.9 gas per byte.
FULL_CHUNK_SEPOLIA = 328_760 + 15_479 * FULL // 10


def write_estimate(length: int, schedule: gas.Schedule = G, **kwargs) -> gas.GasEstimate:
    data = abi.encode_write_chunk(b"A" * length)
    return gas.estimate_write_chunk(length, data, schedule, **kwargs)


def register_estimate(
    count: int, mime: str = "image/png", schedule: gas.Schedule = G, **kwargs
) -> gas.GasEstimate:
    hashes = [keccak256(b"chunk" + i.to_bytes(4, "big")) for i in range(count)]
    data = abi.encode_register_manifest(
        hashes, count * FULL, int(Encoding.BASE64), mime, keccak256(b"media")
    )
    return gas.estimate_register(count, len(mime), data, schedule, **kwargs)


def attest_estimate(chunks: int = 1, schedule: gas.Schedule = G, **kwargs) -> gas.GasEstimate:
    data = abi.encode_call(abi.ATTEST_BASE64, keccak256(b"file"))
    return gas.estimate_attest(chunks, data, schedule, **kwargs)


def call_of(name: str, estimate: gas.GasEstimate, index: int = 0) -> calls.CallPlan:
    return calls.CallPlan(index, name, (), b"", estimate, f"{index}.calldata")


def base64_plan(stored_length: int) -> pl.Plan:
    """A base64 file whose stored text is `stored_length` bytes, rounded down to a multiple of 4."""
    media = (bytes(range(256)) * (stored_length // 256 + 1))[: stored_length // 4 * 3]
    plan = pl.plan_from_media(media, "image/png", Encoding.BASE64)
    assert plan.stored_length == stored_length // 4 * 4
    return plan


class SepoliaGoldenTest(unittest.TestCase):
    """The Glamsterdam model against the receipts it was fitted to: never below, and close."""

    def test_write_chunk_receipts(self) -> None:
        for length, sepolia, _ in (*WRITE_RECEIPTS, (CC0_WRITE[0], CC0_WRITE[1], None)):
            with self.subTest(length=length):
                estimate = write_estimate(length)
                self.assertGreaterEqual(estimate.transaction, sepolia)
                self.assertLessEqual(estimate.transaction, sepolia * 102 // 100)

    def test_the_cc0_text_write_and_registration(self) -> None:
        length, sepolia = CC0_WRITE
        self.assertEqual(length, 7_048)
        estimate = write_estimate(length)
        self.assertGreaterEqual(estimate.transaction, sepolia)
        self.assertLessEqual(estimate.transaction, sepolia * 1005 // 1000)
        mime, sepolia = CC0_REGISTER
        estimate = register_estimate(1, mime)
        self.assertGreaterEqual(estimate.transaction, sepolia)
        self.assertLessEqual(estimate.transaction, sepolia * 104 // 100)

    def test_write_surcharge_is_the_measured_increase_over_prague(self) -> None:
        # Sepolia minus the Prague replay of the same transaction is the state repricing alone.
        for length, sepolia, prague in WRITE_RECEIPTS:
            with self.subTest(length=length):
                increase = sepolia - prague
                state = write_estimate(length).state
                self.assertGreaterEqual(state, increase)
                self.assertLessEqual(state, increase * 1001 // 1000)

    def test_a_full_chunk_costs_about_38_4m(self) -> None:
        estimate = write_estimate(FULL)
        self.assertGreaterEqual(estimate.transaction, FULL_CHUNK_SEPOLIA)
        self.assertLessEqual(estimate.transaction, FULL_CHUNK_SEPOLIA * 1005 // 1000)
        # About 1,548 gas per stored byte on Sepolia, against about 218 on Prague.
        per_byte = (write_estimate(FULL).transaction - write_estimate(0).transaction) / FULL
        self.assertTrue(1_548 <= per_byte <= 1_556, per_byte)

    def test_register_receipts_and_their_surcharge(self) -> None:
        for mime, sepolia, prague in REGISTER_RECEIPTS:
            with self.subTest(mime=mime):
                estimate = register_estimate(1, mime)
                self.assertEqual(estimate.footprint.slots, 5)
                self.assertGreaterEqual(estimate.transaction, sepolia)
                self.assertLessEqual(estimate.transaction, sepolia * 104 // 100)
                self.assertGreaterEqual(estimate.state, sepolia - prague)
                self.assertLessEqual(estimate.state, (sepolia - prague) * 104 // 100)

    def test_manifests_by_size(self) -> None:
        for count, sepolia in REGISTER_BY_SIZE:
            with self.subTest(count=count):
                estimate = register_estimate(count)
                tolerance = 103 if count == 1 else 102
                self.assertGreaterEqual(estimate.transaction, sepolia)
                self.assertLessEqual(estimate.transaction, sepolia * tolerance // 100)

    def test_the_largest_manifest_costs_about_57_6m(self) -> None:
        estimate = register_estimate(pl.MAX_CHUNKS)
        self.assertGreaterEqual(estimate.transaction, 57_600_000)
        self.assertLessEqual(estimate.transaction, 57_600_000 * 101 // 100)
        self.assertTrue(estimate.above_estimate_cap)
        # Its regular part still keeps the quarter reserve under the cap.
        self.assertTrue(estimate.within_cap and estimate.has_margin, estimate)

    def test_a_50m_capped_node_cannot_estimate_above_about_440_chunks(self) -> None:
        largest = max(
            n for n in range(400, pl.MAX_CHUNKS + 1) if not register_estimate(n).above_estimate_cap
        )
        self.assertEqual(largest, 440)

    def test_attest_receipts(self) -> None:
        estimate = attest_estimate(1)
        for length, sepolia, prague in ATTEST_RECEIPTS:
            with self.subTest(length=length):
                self.assertGreaterEqual(estimate.transaction, sepolia)
                # The repricing is the one new slot that records the attestation.
                self.assertGreaterEqual(estimate.state, sepolia - prague)
                self.assertLessEqual(estimate.state, (sepolia - prague) * 108 // 100)

    def test_what_a_work_costs_on_chain(self) -> None:
        # flows.md: 256 KiB is about 413M gas (0.41 ETH at 1 gwei; Prague about 60M, 0.06 ETH),
        # 1 MiB about 1,650M (1.65 ETH; Prague about 241M, 0.24 ETH): upload, manifest, attest.
        cases = (
            (256 * 1024, (413_000_000, 420_000_000), (60_000_000, 63_000_000)),
            (1024 * 1024, (1_650_000_000, 1_670_000_000), (241_000_000, 248_000_000)),
        )
        for stored, glam_range, prague_range in cases:
            with self.subTest(stored=stored):
                built = calls.calls_for_plan(base64_plan(stored))
                quotes = {q.schedule: q for q in calls.quotes(built, Decimal(1))}
                self.assertTrue(glam_range[0] <= quotes["glamsterdam"].gas <= glam_range[1])
                self.assertTrue(prague_range[0] <= quotes["prague"].gas <= prague_range[1])
        self.assertTrue(Decimal("1.65") <= quotes["glamsterdam"].eth <= Decimal("1.67"))
        self.assertTrue(Decimal("0.24") <= quotes["prague"].eth <= Decimal("0.25"))


class ScheduleTest(unittest.TestCase):
    def test_prague_is_the_default_and_adds_nothing(self) -> None:
        self.assertIs(gas.DEFAULT_SCHEDULE, P)
        self.assertEqual(P.state_gas(gas.Footprint(3, 70_000, 600)), 0)
        data = abi.encode_write_chunk(b"x" * 1000)
        self.assertEqual(
            gas.estimate_write_chunk(1000, data), gas.estimate_write_chunk(1000, data, P)
        )
        plan = pl.plan_from_media(counter_bytes(60, 30_000), "a/b", Encoding.BASE64)
        default = calls.build_calls(manifest_for(plan), plan.stored)
        explicit = calls.build_calls(manifest_for(plan), plan.stored, schedule=P)
        self.assertEqual(default, explicit)
        self.assertTrue(all(c.estimate.state == 0 for c in default))

    def test_schedules_by_name(self) -> None:
        self.assertIs(gas.schedule_named("glamsterdam"), G)
        self.assertIs(gas.schedule_named("prague"), P)
        with self.assertRaises(ValueError):
            gas.schedule_named("osaka")

    def test_footprints_follow_the_contract(self) -> None:
        # A chunk is a CREATE2 contract of STOP plus data, and its chunkPointer slot.
        self.assertEqual(gas.write_chunk_footprint(100), gas.Footprint(1, 101, 1))
        # A File: SHA-256, length and encoding, the MIME string, the list length, then the hashes.
        self.assertEqual(gas.register_footprint(43, 9).slots, 4 + 43)
        self.assertEqual(gas.register_footprint(1, 31).slots, 5)
        self.assertEqual(gas.register_footprint(1, 32).slots, 5 + 1)
        self.assertEqual(gas.register_footprint(1, 64).slots, 5 + 2)
        self.assertEqual(gas.attest_footprint(True).slots, 1)
        self.assertEqual(gas.attest_footprint(False).slots, 0)

    def test_regular_gas_is_the_prague_estimate_and_state_is_the_surcharge(self) -> None:
        for make in (
            lambda s: write_estimate(FULL, s),
            lambda s: register_estimate(300, "a/" + "b" * 40, s),
            lambda s: attest_estimate(48, s),
        ):
            glam, prague = make(G), make(P)
            self.assertEqual(glam.regular, prague.transaction)
            self.assertEqual(glam.state, G.state_gas(glam.footprint))
            self.assertEqual(glam.transaction, glam.regular + glam.state)
            self.assertEqual(glam.execution, prague.execution)
            self.assertEqual(prague.under(G), glam)
            self.assertEqual(glam.under(P), prague)

    def test_only_the_first_attest_call_writes_a_new_slot(self) -> None:
        plan = base64_plan(50 * FULL)  # 50 chunks: two attest calls
        attests = [c for c in calls.calls_for_plan(plan, schedule=G) if c.name == "attestBase64"]
        self.assertEqual([c.estimate.footprint.slots for c in attests], [1, 0])
        self.assertEqual(attests[1].estimate.state, 0)


class CapSemanticsTest(unittest.TestCase):
    def test_a_full_chunk_is_over_the_cap_in_total_but_not_in_regular_gas(self) -> None:
        glam = write_estimate(FULL)
        self.assertGreater(glam.transaction, gas.TX_GAS_CAP)
        self.assertTrue(glam.within_cap and glam.has_margin)
        self.assertEqual(glam.cap_fraction, glam.regular / gas.TX_GAS_CAP)
        # Not clamped to the cap: the limit is the estimate plus 10%, rounded up to 1,000.
        self.assertGreater(glam.gas_limit, gas.TX_GAS_CAP)
        padded = -(-glam.transaction * 11 // 10)
        self.assertEqual(glam.gas_limit, -(-padded // 1000) * 1000)
        self.assertLessEqual(write_estimate(FULL, P).gas_limit, gas.TX_GAS_CAP)

    def test_the_cap_still_bounds_regular_gas(self) -> None:
        plan = pl.plan_from_media(counter_bytes(61, FULL), "a/b", Encoding.IDENTITY)
        with mock.patch.object(gas, "TX_GAS_CAP", 5_000_000):
            with self.assertRaisesRegex(ToolError, "regular"):
                calls.build_calls(manifest_for(plan), plan.stored, schedule=G)
        # A huge state part on a small regular part is fine.
        built = calls.build_calls(manifest_for(plan), plan.stored, schedule=G)
        self.assertTrue(all(c.estimate.within_cap for c in built))

    def test_the_limit_never_exceeds_the_assumed_block_gas_limit(self) -> None:
        estimate = register_estimate(pl.MAX_CHUNKS)  # about 58M, plus 10% is about 63.8M
        self.assertEqual(estimate.gas_limit, gas.DEFAULT_BLOCK_GAS)
        self.assertGreater(estimate.gas_limit, estimate.transaction)
        roomy = register_estimate(pl.MAX_CHUNKS, block_gas=200_000_000)
        self.assertGreater(roomy.gas_limit, gas.DEFAULT_BLOCK_GAS)
        # A transaction too big for the block keeps its headroom rather than a useless clamp.
        small_blocks = write_estimate(FULL, block_gas=30_000_000)
        self.assertTrue(small_blocks.above_block_gas)
        self.assertGreater(small_blocks.gas_limit, small_blocks.transaction)


class BatchingTest(unittest.TestCase):
    def test_full_chunks_per_transaction(self) -> None:
        self.assertEqual(gas.chunks_per_transaction(FULL, P), 2)  # about two thirds of the cap
        self.assertEqual(gas.chunks_per_transaction(FULL, G), 1)  # two would be about 77M

    def test_more_than_one_full_chunk_only_while_the_regular_part_fits(self) -> None:
        unlimited = {"block_gas": 10**12, "estimate_cap": 10**12}
        one = write_estimate(FULL)
        by_regular = gas.TX_GAS_CAP * 3 // 4 // one.regular
        self.assertEqual(gas.chunks_per_transaction(FULL, G, **unlimited), by_regular)
        with mock.patch.object(gas, "TX_GAS_CAP", one.regular * 2):  # not even two fit
            self.assertEqual(gas.chunks_per_transaction(FULL, G, **unlimited), 1)

    def test_small_chunks_batch_within_the_estimate_cap_and_the_block(self) -> None:
        for length, block_gas in ((1_024, gas.DEFAULT_BLOCK_GAS), (8_192, 40_000_000)):
            with self.subTest(length=length):
                one = write_estimate(length, block_gas=block_gas)
                count = gas.chunks_per_transaction(length, G, block_gas)
                limit = min(gas.RPC_ESTIMATE_CAP, block_gas)
                self.assertGreater(count, 1)
                self.assertLessEqual(count * one.transaction, limit)
                self.assertGreater((count + 1) * one.transaction, limit)
                self.assertLessEqual(count * one.regular * 4, gas.TX_GAS_CAP * 3)


class WarningsTest(unittest.TestCase):
    def test_the_largest_manifest_cannot_be_estimated_by_a_capped_node(self) -> None:
        warnings = calls.gas_warnings([call_of("registerManifest", register_estimate(512))])
        self.assertEqual(len(warnings), 1)
        self.assertIn("1 registerManifest", warnings[0])
        self.assertIn("50,000,000", warnings[0])

    def test_above_the_block_gas_assumption(self) -> None:
        estimate = register_estimate(512, block_gas=50_000_000)
        warnings = calls.gas_warnings([call_of("registerManifest", estimate)])
        self.assertEqual(len(warnings), 2)
        self.assertIn("block gas limit of 50,000,000", warnings[1])

    def test_no_warning_for_ordinary_calls(self) -> None:
        plan = base64_plan(3 * FULL)
        for schedule in (P, G):
            with self.subTest(schedule=schedule.name):
                built = calls.calls_for_plan(plan, schedule=schedule)
                self.assertEqual(calls.gas_warnings(built), [])
        largest_estimable = call_of("registerManifest", register_estimate(440))
        self.assertEqual(calls.gas_warnings([largest_estimable]), [])

    def test_no_reserve_left(self) -> None:
        estimate = gas.GasEstimate(1, 13_000_000)
        self.assertIn("three quarters", calls.gas_warnings([call_of("x", estimate)])[0])


class QuoteTest(unittest.TestCase):
    def test_arithmetic(self) -> None:
        self.assertEqual(gas.Quote("g", 413_000_000, Decimal(1)).eth, Decimal("0.413"))
        self.assertEqual(gas.Quote("g", 413_000_000, Decimal(10)).eth, Decimal("4.13"))
        self.assertEqual(gas.Quote("g", 413_000_000, Decimal("0.05")).eth, Decimal("0.02065"))
        self.assertEqual(
            gas.Quote("g", 2_843_000_123, Decimal("1.5")).eth, Decimal("4.2645001845")
        )
        self.assertEqual(gas.Quote("g", 1, Decimal("0.000000001")).eth, Decimal("1E-18"))

    def test_a_quote_reprices_every_transaction(self) -> None:
        built = calls.calls_for_plan(base64_plan(3 * FULL), schedule=P)
        prague, glam = calls.quotes(built, Decimal(2))
        self.assertEqual((prague.schedule, glam.schedule), ("prague", "glamsterdam"))
        self.assertEqual(prague.gas, sum(c.estimate.transaction for c in built))
        self.assertEqual(
            glam.gas, sum(c.estimate.regular + G.state_gas(c.estimate.footprint) for c in built)
        )
        self.assertEqual(glam.eth, Decimal(glam.gas) * 2 / 10**9)
        # The schedule the calls were built under does not change the quotes.
        rebuilt = calls.calls_for_plan(base64_plan(3 * FULL), schedule=G)
        self.assertEqual(calls.quotes(rebuilt, Decimal(2)), [prague, glam])


class CommandLineTest(TempDirCase):
    def manifest(self, media: bytes, encoding: str = "identity") -> Path:
        source = self.media_file(data=media)
        manifest = self.dir / "m.json"
        code, _, err = run(
            "plan", str(source), "--mime", "text/plain", "--encoding", encoding,
            "-o", str(manifest),
        )
        self.assertEqual(code, 0, err)
        return manifest

    def test_glamsterdam_limits_are_not_clamped_to_the_cap(self) -> None:
        manifest = self.manifest(counter_bytes(62, FULL + 100))
        code, out, err = run(
            "calls", str(manifest), "--store", STORE, "--schedule", "glamsterdam", "--json"
        )
        self.assertEqual(code, 0, err)
        document = json.loads(out)
        self.assertEqual(document["gasSchedule"], "glamsterdam")
        self.assertFalse(document["gasCapCountsStateGas"])
        writes = [t for t in document["transactions"] if t["name"] == "writeChunk"]
        full = writes[0]
        self.assertGreater(full["gasEstimate"], gas.TX_GAS_CAP)
        self.assertGreater(full["gasLimit"], full["gasEstimate"])
        self.assertEqual(full["regularGasEstimate"] + full["stateGasEstimate"], full["gasEstimate"])
        self.assertLess(full["regularGasEstimate"], gas.TX_GAS_CAP)
        self.assertEqual(full["gasLimitSource"], "model")
        script = (self.dir / "m.calls" / "send.sh").read_text(encoding="utf-8")
        self.assertIn(f"--gas-limit {full['gasLimit']}", script)
        self.assertIn("gas schedule  glamsterdam", script)
        self.assertIn("bounds regular gas only", err)
        self.assertIn("at most 1 full chunk(s) per transaction under glamsterdam", err)

    def test_quotes_for_both_schedules(self) -> None:
        manifest = self.manifest(counter_bytes(63, 30_000))
        code, out, err = run("calls", str(manifest), "--store", STORE, "--gwei", "2.5", "--json")
        self.assertEqual(code, 0, err)
        document = json.loads(out)
        self.assertEqual(document["gasSchedule"], "prague")
        self.assertEqual([q["schedule"] for q in document["quotes"]], ["prague", "glamsterdam"])
        for q in document["quotes"]:
            self.assertEqual(Decimal(q["eth"]), Decimal(q["gas"]) * Decimal("2.5") / 10**9)
        self.assertEqual(document["quotes"][0]["gas"], document["totalGasEstimate"])
        self.assertIn("cost quote at 2.5 gwei", err)
        self.assertIn("glamsterdam", err.split("cost quote")[1])

    def test_plan_prints_the_quote(self) -> None:
        source = self.media_file(data=counter_bytes(64, 50_000))
        code, out, err = run(
            "plan", str(source), "--mime", "image/png", "--encoding", "base64", "--gwei", "10"
        )
        self.assertEqual(code, 0, err)
        self.assertIn(
            "on-chain copy 5 transaction(s): registerManifest, 3 writeChunk, 1 attestBase64", out
        )
        self.assertIn("cost quote at 10 gwei", out)
        self.assertRegex(out, r"glamsterdam +[\d,]+ gas +[\d.]+ ETH")

    def test_bad_gas_options_are_refused(self) -> None:
        manifest = self.manifest(b"tiny")
        for extra in (
            ("--gwei", "0"), ("--gwei", "abc"), ("--gwei", "NaN"), ("--block-gas", "1000"),
            ("--block-gas", "lots"), ("--schedule", "osaka"), ("--gas-limits", "node"),
        ):
            with self.subTest(extra=extra), self.assertRaises(SystemExit):
                run("calls", str(manifest), "--store", STORE, *extra)

    def test_a_block_gas_assumption_warns(self) -> None:
        manifest = self.manifest(counter_bytes(65, FULL))
        code, _, err = run(
            "calls", str(manifest), "--store", STORE, "--schedule", "glamsterdam",
            "--block-gas", "30,000,000",
        )
        self.assertEqual(code, 0, err)
        self.assertIn(
            "warning: 1 writeChunk need(s) more gas than the assumed block gas limit of 30,000,000",
            err,
        )


class RpcLimitsTest(TempDirCase):
    def setUp(self) -> None:
        super().setUp()
        source = self.media_file(data=counter_bytes(70, FULL + 4_000))
        self.manifest = self.dir / "m.json"
        code, _, err = run(
            "plan", str(source), "--mime", "text/plain", "--encoding", "base64",
            "-o", str(self.manifest),
        )
        self.assertEqual(code, 0, err)

    def calls(self, chain: FakeChain, *extra: str) -> tuple[int, dict, str]:
        code, out, err = run(
            "calls", str(self.manifest), "--store", STORE, "--rpc", chain.url,
            "--gas-limits", "rpc", "--json", "--force", *extra,
        )
        return code, (json.loads(out) if code == 0 else {}), err

    @staticmethod
    def node(write: int, register: int):
        def estimate(data: bytes) -> int:
            if data[:4] == abi.WRITE_CHUNK:
                return write
            if data[:4] == abi.REGISTER_MANIFEST:
                return register
            raise Revert(abi.CONTENT_CHUNK_MISSING + bytes(96))  # attest before the upload
        return estimate

    def test_limits_come_from_the_node_and_unestimable_calls_keep_the_model(self) -> None:
        with FakeChain() as chain:
            chain.store.estimator = self.node(30_000_000, 700_000)
            code, document, err = self.calls(chain, "--schedule", "glamsterdam")
        self.assertEqual(code, 0, err)
        by_name = {}
        for t in document["transactions"]:
            by_name.setdefault(t["name"], []).append(t)
        for t in by_name["writeChunk"]:
            self.assertEqual((t["gasLimitSource"], t["nodeGasEstimate"]), ("rpc", 30_000_000))
            self.assertEqual(t["gasLimit"], 33_000_000)
        self.assertEqual(by_name["registerManifest"][0]["gasLimit"], 770_000)
        attest = by_name["attestBase64"][0]
        self.assertEqual((attest["gasLimitSource"], attest["nodeGasEstimate"]), ("model", None))
        self.assertTrue(
            any("1 attestBase64 call(s) could not be estimated" in w for w in document["warnings"])
        )
        self.assertIn("ContentChunkMissing", err)
        self.assertIn("gas limits from the node's eth_estimateGas plus 10% for 3 of 4", err)

    def test_a_node_gas_cap_falls_back_to_the_model(self) -> None:
        def capped(data: bytes) -> int:
            raise NodeError("gas required exceeds allowance (50000000)")

        with FakeChain() as chain:
            chain.store.estimator = capped
            code, document, err = self.calls(chain, "--schedule", "glamsterdam")
        self.assertEqual(code, 0, err)
        self.assertTrue(all(t["gasLimitSource"] == "model" for t in document["transactions"]))
        self.assertIn("exceeds allowance", err)

    def test_an_estimate_above_the_model_is_flagged(self) -> None:
        with FakeChain() as chain:
            chain.store.estimator = self.node(45_000_000, 700_000)
            code, document, err = self.calls(chain, "--schedule", "glamsterdam")
        self.assertEqual(code, 0, err)
        self.assertIn("above the glamsterdam model", err)
        self.assertEqual(document["transactions"][1]["gasLimit"], 49_500_000)

    def test_prague_limits_on_a_glamsterdam_chain_are_refused(self) -> None:
        with FakeChain() as chain:
            chain.store.estimator = self.node(38_000_000, 700_000)
            code, _, err = self.calls(chain)
            self.assertEqual(code, 2)
            self.assertIn("use --schedule glamsterdam", err)
            self.assertFalse((self.dir / "m.calls").exists())

            chain.chain_id = 11_155_111  # Sepolia: refused from the chain ID alone
            code, _, err = run(
                "calls", str(self.manifest), "--store", STORE, "--rpc", chain.url, "--only-missing"
            )
            self.assertEqual(code, 2)
            self.assertIn("Sepolia", err)
            self.assertIn("pass --schedule glamsterdam", err)
            code, _, err = run(
                "calls", str(self.manifest), "--store", STORE, "--rpc", chain.url,
                "--only-missing", "--schedule", "glamsterdam",
            )
            self.assertEqual(code, 0, err)

    def test_rpc_limits_need_an_endpoint(self) -> None:
        saved = os.environ.pop("ETH_RPC_URL", None)
        try:
            code, _, err = run("calls", str(self.manifest), "--store", STORE, "--gas-limits", "rpc")
        finally:
            if saved is not None:
                os.environ["ETH_RPC_URL"] = saved
        self.assertEqual((code, "--gas-limits rpc needs --rpc" in err), (2, True))

    def test_only_read_only_methods_are_used(self) -> None:
        with FakeChain() as chain:
            chain.store.estimator = self.node(30_000_000, 700_000)
            self.assertEqual(self.calls(chain, "--schedule", "glamsterdam", "--only-missing")[0], 0)
            methods = set(chain.methods)
        self.assertLessEqual(methods, {"eth_call", "eth_getCode", "eth_chainId", "eth_estimateGas"})
        self.assertIn("eth_estimateGas", methods)


if __name__ == "__main__":
    unittest.main()
