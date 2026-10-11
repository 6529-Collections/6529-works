"""Tests for the emitted transactions, the gas model and the cap check."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.content import abi, calls, gas
from tools.content import plan as pl
from tools.content.address import checksum_address, parse_address
from tools.content.encoding import Encoding
from tools.content.errors import ToolError
from tools.content.golden import counter_bytes

STORE = bytes.fromhex("5fbdb2315678afecb367f032d93f642f64180aa3")


def manifest_for(plan: pl.Plan) -> pl.Manifest:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "m.json"
        path.write_text(json.dumps(pl.manifest_dict(plan, "m.stored", None)), encoding="utf-8")
        return pl.load_manifest(path)


class AddressTest(unittest.TestCase):
    # The EIP-55 reference vectors.
    CHECKSUMMED = (
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
        "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
        "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
        "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
    )

    def test_eip55_vectors(self) -> None:
        for text in self.CHECKSUMMED:
            with self.subTest(text):
                raw = parse_address(text)
                self.assertEqual(checksum_address(raw), text)
                self.assertEqual(parse_address(text.lower()), raw)

    def test_bad_checksum_and_shapes_are_rejected(self) -> None:
        good = self.CHECKSUMMED[0]
        swapped = good[:-1] + ("d" if good[-1] != "d" else "e")
        for bad in (swapped, "0x1234", "5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", "0x" + "g" * 40, ""):
            with self.subTest(bad), self.assertRaises(ToolError):
                parse_address(bad)


class GasModelTest(unittest.TestCase):
    def test_calldata_gas(self) -> None:
        self.assertEqual(gas.calldata_gas(b"\x00\x00\x01\xff"), 4 + 4 + 16 + 16)
        self.assertEqual(gas.calldata_gas(b""), 0)

    def test_floor_gas_never_lowers_the_charge(self) -> None:
        data = b"\x01" * 100
        self.assertEqual(gas.calldata_floor_gas(data), 21_000 + 10 * 400)
        self.assertEqual(gas.transaction_gas(5_000_000, data), 21_000 + 1_600 + 5_000_000)
        # With almost no execution, the EIP-7623 floor is what the transaction pays.
        self.assertEqual(gas.transaction_gas(0, data), gas.calldata_floor_gas(data))

    def test_models_match_the_measured_anchor_points(self) -> None:
        # Measured on ContentStore (README gas table): a full new chunk, and 512 chunks.
        self.assertGreaterEqual(gas.write_chunk_execution(24_575), 5_020_261)
        self.assertGreaterEqual(gas.register_execution(512, 9), 11_460_012)
        self.assertGreaterEqual(gas.register_execution(512, 64), 11_524_566)
        self.assertGreaterEqual(gas.register_execution(1, 9), 122_923)
        self.assertGreaterEqual(gas.register_execution(43, 9), 1_054_701)

    def test_models_stay_close_to_the_measurements(self) -> None:
        # A bound that is far too loose would hide a cap problem: stay within 3 percent.
        self.assertLess(gas.write_chunk_execution(24_575), int(5_020_261 * 1.03))
        self.assertLess(gas.register_execution(512, 9), int(11_460_012 * 1.03))

    def test_largest_transactions_fit_the_cap_with_the_quarter_reserve(self) -> None:
        register = abi.encode_register_manifest(
            [bytes([i % 255 + 1] * 32) for i in range(512)], pl.MAX_STORED_BYTES, 1, "a/" + "b" * 62,
            bytes([7] * 32),
        )
        estimate = gas.estimate_register(512, 64, register)
        self.assertTrue(estimate.within_cap and estimate.has_margin, estimate)
        self.assertLess(estimate.gas_limit, gas.TX_GAS_CAP)
        chunk = abi.encode_write_chunk(bytes([0xAA] * 24_575))
        write = gas.estimate_write_chunk(24_575, chunk)
        self.assertTrue(write.within_cap and write.has_margin, write)

    def test_gas_limit_adds_headroom_but_never_exceeds_the_cap(self) -> None:
        self.assertEqual(gas.GasEstimate(1, 1_000_000).gas_limit, 1_100_000)
        self.assertEqual(gas.GasEstimate(1, 16_000_000).gas_limit, gas.TX_GAS_CAP)
        self.assertEqual(gas.GasEstimate(1, 123_456).gas_limit % 1000, 0)
        self.assertFalse(gas.GasEstimate(1, gas.TX_GAS_CAP + 1).within_cap)
        self.assertFalse(gas.GasEstimate(1, 13_000_000).has_margin)

    def test_a_batch_of_chunks_per_transaction_is_not_safe_beyond_two(self) -> None:
        # Documents the README guidance: three full chunks leave almost no margin under the cap.
        one = gas.estimate_write_chunk(24_575, abi.encode_write_chunk(bytes([1] * 24_575)))
        self.assertLessEqual(2 * one.transaction, gas.TX_GAS_CAP * 3 // 4)
        self.assertGreater(3 * one.transaction, gas.TX_GAS_CAP * 95 // 100)

    def test_oversized_inputs_are_refused(self) -> None:
        with self.assertRaises(ValueError):
            gas.write_chunk_execution(24_576)


class BuildCallsTest(unittest.TestCase):
    def build(self, media: bytes, encoding: Encoding = Encoding.IDENTITY, **kwargs):
        plan = pl.plan_from_media(media, "application/octet-stream", encoding)
        return plan, calls.build_calls(manifest_for(plan), plan.stored, **kwargs)

    def test_small_file(self) -> None:
        plan, built = self.build(b"hello 6529")
        self.assertEqual([c.name for c in built], ["registerManifest", "writeChunk"])
        register, write = built
        self.assertEqual(
            register.data,
            abi.encode_register_manifest(
                plan.chunk_hashes, plan.stored_length, 0, "application/octet-stream",
                plan.media_sha256,
            ),
        )
        self.assertEqual(write.data, abi.encode_write_chunk(b"hello 6529"))
        self.assertEqual(write.chunk_indexes, (0,))
        self.assertEqual(register.filename, "000-registerManifest.calldata")
        self.assertEqual(write.filename, "001-writeChunk-000.calldata")

    def test_register_last(self) -> None:
        _, built = self.build(counter_bytes(1, 60_000), register="last")
        self.assertEqual([c.name for c in built], ["writeChunk"] * 3 + ["registerManifest"])
        self.assertEqual([c.index for c in built], [0, 1, 2, 3])

    def test_multi_chunk_order_and_calldata(self) -> None:
        media = counter_bytes(2, 60_000)
        plan, built = self.build(media)
        writes = built[1:]
        self.assertEqual([w.chunk_indexes for w in writes], [(0,), (1,), (2,)])
        self.assertEqual(
            [w.data for w in writes], [abi.encode_write_chunk(c) for c in plan.chunks()]
        )

    def test_a_repeated_chunk_is_written_once(self) -> None:
        block = counter_bytes(3, pl.CHUNK_SIZE)
        plan, built = self.build(block * 3 + b"tail")
        self.assertEqual(len(plan.chunk_hashes), 4)
        self.assertEqual(len({*plan.chunk_hashes}), 2)
        writes = [c for c in built if c.name == "writeChunk"]
        self.assertEqual([w.chunk_indexes for w in writes], [(0, 1, 2), (3,)])

    def test_skipping_what_the_chain_already_has(self) -> None:
        media = counter_bytes(4, 60_000)
        plan = pl.plan_from_media(media, "a/b", Encoding.IDENTITY)
        built = calls.build_calls(
            manifest_for(plan), plan.stored, skip_register=True,
            present_chunk_hashes=[plan.chunk_hashes[0], plan.chunk_hashes[2]],
        )
        self.assertEqual([(c.name, c.chunk_indexes) for c in built], [("writeChunk", (1,))])
        nothing = calls.build_calls(
            manifest_for(plan), plan.stored, skip_register=True,
            present_chunk_hashes=plan.chunk_hashes,
        )
        self.assertEqual(nothing, [])

    def test_a_stream_that_is_not_the_manifests_is_refused(self) -> None:
        plan = pl.plan_from_media(counter_bytes(5, 60_000), "a/b", Encoding.IDENTITY)
        tampered = bytearray(plan.stored)
        tampered[30_000] ^= 1
        with self.assertRaises(ToolError):
            calls.build_calls(manifest_for(plan), bytes(tampered))

    def test_each_transaction_is_checked_against_the_gas_cap(self) -> None:
        plan = pl.plan_from_media(b"x" * 1000, "a/b", Encoding.IDENTITY)
        with mock.patch.object(gas, "TX_GAS_CAP", 100_000):
            with self.assertRaisesRegex(ToolError, "cap"):
                calls.build_calls(manifest_for(plan), plan.stored)

    def test_every_transaction_estimate_is_within_the_cap(self) -> None:
        _, built = self.build(counter_bytes(6, 3 * pl.CHUNK_SIZE))
        for c in built:
            self.assertTrue(c.estimate.within_cap)
            self.assertLessEqual(c.gas_limit, gas.TX_GAS_CAP)
            self.assertGreaterEqual(c.gas_limit, c.estimate.transaction)

    def test_invalid_register_option(self) -> None:
        plan = pl.plan_from_media(b"x", "a/b", Encoding.IDENTITY)
        with self.assertRaises(ToolError):
            calls.build_calls(manifest_for(plan), plan.stored, register="middle")


class RenderTest(unittest.TestCase):
    def setUp(self) -> None:
        self.plan = pl.plan_from_media(counter_bytes(7, 60_000), "image/png", Encoding.BASE64)
        self.built = calls.build_calls(manifest_for(self.plan), self.plan.stored)

    def test_script_has_one_cast_send_per_transaction_and_no_secrets(self) -> None:
        script = calls.render_script(self.built, self.plan.file_id, STORE)
        sends = [line for line in script.splitlines() if line.startswith("cast send")]
        self.assertEqual(len(sends), len(self.built))
        for line, call in zip(sends, self.built):
            self.assertIn(f"$(cat {call.filename})", line)
            self.assertIn(f"--gas-limit {call.gas_limit}", line)
            self.assertIn('--rpc-url "$ETH_RPC_URL"', line)
            self.assertTrue(line.endswith("$SIGNER"))
        self.assertIn("set -euo pipefail", script)
        self.assertIn(f"STORE={checksum_address(STORE)}", script)
        self.assertIn("0x" + self.plan.file_id.hex(), script)
        lowered = script.lower()
        for forbidden in ("--private-key", "--mnemonic", "--interactive", "http://", "https://"):
            self.assertNotIn(forbidden, lowered)

    def test_document_lists_files_not_calldata(self) -> None:
        doc = calls.calls_document(
            self.built, self.plan.file_id, STORE, skipped_register=False, skipped_chunks=0
        )
        self.assertEqual(doc["schema"], calls.CALLS_SCHEMA)
        self.assertEqual(doc["gasCap"], 16_777_216)
        self.assertEqual(len(doc["transactions"]), len(self.built))
        first = doc["transactions"][0]
        self.assertEqual(first["name"], "registerManifest")
        self.assertEqual(first["value"], "0")
        self.assertEqual(first["to"], checksum_address(STORE))
        self.assertEqual(first["calldataBytes"], len(self.built[0].data))
        self.assertNotIn(self.built[0].data.hex(), json.dumps(doc))
        self.assertEqual(doc["totalGasEstimate"], sum(c.estimate.transaction for c in self.built))

    def test_calldata_files_are_0x_hex(self) -> None:
        text = calls.calldata_file_text(self.built[0])
        self.assertEqual(text, "0x" + self.built[0].data.hex() + "\n")


if __name__ == "__main__":
    unittest.main()
