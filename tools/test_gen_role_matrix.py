"""Unit tests for gen_role_matrix.py, which sits beside this file.

Run with `python tools/test_gen_role_matrix.py` or, from the repository root,
`python -m tools.test_gen_role_matrix`.
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "gen_role_matrix", Path(__file__).with_name("gen_role_matrix.py")
)
gm = importlib.util.module_from_spec(_SPEC)
sys.modules["gen_role_matrix"] = gm
_SPEC.loader.exec_module(gm)

ROOT = Path(__file__).resolve().parent.parent


def committed_config() -> dict:
    return json.loads((ROOT / gm.CONFIG).read_text(encoding="utf-8"))


def run(argv: list[str]) -> tuple[int, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = gm.main(argv)
    return code, out.getvalue()


class HelpersTest(unittest.TestCase):
    def test_selector_is_keccak_of_the_signature(self) -> None:
        self.assertEqual(gm.selector("transfer(address,uint256)"), "0xa9059cbb")
        self.assertEqual(gm.selector("pause()"), "0x8456cb59")

    def test_format_delay(self) -> None:
        self.assertEqual(gm.format_delay(0), "immediate")
        self.assertEqual(gm.format_delay(172_800), "48 hours")
        self.assertEqual(gm.format_delay(1_209_600), "14 days")
        self.assertEqual(gm.format_delay(2_592_000), "30 days")
        self.assertEqual(gm.format_delay(90), "90 seconds")

    def test_short_signature_abbreviates_only_long_tuples(self) -> None:
        self.assertEqual(gm.short_signature("pause()"), "pause()")
        self.assertEqual(
            gm.short_signature("addLocator(uint256,bytes32,(uint8,string))"),
            "addLocator(uint256,bytes32,(uint8,string))",
        )
        self.assertEqual(
            gm.short_signature("openSale(address,uint256,(uint64,uint64,bytes32,uint32,bool,bool)[],"
                               "(uint256,uint64,bytes))"),
            "openSale(address,uint256,(…)[],(uint256,uint64,bytes))",
        )

    def test_guardian_cancel_depends_on_the_delay(self) -> None:
        self.assertTrue(gm.guardian_cancel(0).startswith("No"))
        self.assertTrue(gm.guardian_cancel(172_800).startswith("Yes"))


class ValidateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.config = committed_config()

    def first_function(self, config: dict) -> dict:
        return next(c for c in config["contracts"] if c.get("functions"))["functions"][0]

    def test_committed_configuration_is_valid(self) -> None:
        gm.validate(self.config)

    def test_wrong_selector_fails(self) -> None:
        config = copy.deepcopy(self.config)
        self.first_function(config)["selector"] = "0x00000000"
        with self.assertRaisesRegex(gm.ConfigError, "selector"):
            gm.validate(config)

    def test_unknown_role_fails(self) -> None:
        config = copy.deepcopy(self.config)
        self.first_function(config)["role"] = "NOBODY"
        with self.assertRaisesRegex(gm.ConfigError, "unknown role"):
            gm.validate(config)

    def test_delay_that_differs_from_its_role_fails(self) -> None:
        config = copy.deepcopy(self.config)
        entry = next(
            f for c in config["contracts"] for f in c.get("functions", []) if f["delay"] > 0
        )
        entry["delay"] = 0
        with self.assertRaisesRegex(gm.ConfigError, "class or delay"):
            gm.validate(config)

    def test_role_whose_delay_contradicts_its_class_fails(self) -> None:
        config = copy.deepcopy(self.config)
        config["roles"][0]["executionDelay"] = 1
        with self.assertRaisesRegex(gm.ConfigError, "class"):
            gm.validate(config)

    def test_note_for_a_removed_function_fails(self) -> None:
        config = copy.deepcopy(self.config)
        for contract in config["contracts"]:
            if contract["name"] == "RevenueEscrow":
                contract["functions"] = []
        with self.assertRaisesRegex(gm.ConfigError, "note for RevenueEscrow"):
            gm.validate(config)

    def test_wiring_on_an_unknown_contract_fails(self) -> None:
        config = copy.deepcopy(self.config)
        config["wiring"][0]["contract"] = "Nowhere"
        with self.assertRaisesRegex(gm.ConfigError, "unknown contract"):
            gm.validate(config)


class RenderTest(unittest.TestCase):
    def test_render_is_deterministic(self) -> None:
        config = committed_config()
        self.assertEqual(gm.render(config), gm.render(copy.deepcopy(config)))

    def test_every_mapped_selector_appears_once_per_contract(self) -> None:
        config = committed_config()
        text = gm.render(config)
        for contract in config["contracts"]:
            section = text.split(f"### {contract['name']}\n", 1)[1]
            section = section.split("\n### ", 1)[0].split("\n## ", 1)[0]
            for entry in contract.get("functions", []):
                self.assertEqual(section.count(f"`{entry['selector']}`"), 1, entry["signature"])

    def test_optional_suspendable_flag_adds_a_column(self) -> None:
        config = committed_config()
        has_flag = any("suspendable" in r for r in config["roles"])
        self.assertEqual("Guardian may suspend" in gm.render(config), has_flag)
        config = copy.deepcopy(config)
        for role in config["roles"]:
            role["suspendable"] = role["name"] == "PLATFORM"
        text = gm.render(config)
        row = next(line for line in text.splitlines() if line.startswith("| `PLATFORM` |"))
        self.assertTrue(row.endswith(" Yes |"))
        row = next(line for line in text.splitlines() if line.startswith("| `ADMIN` |"))
        self.assertTrue(row.endswith(" No |"))

    def test_manager_functions_from_the_configuration(self) -> None:
        config = copy.deepcopy(committed_config())
        entry = {"signature": "suspend(uint64,address)", "selector": "0x64bf6e5d",
                 "role": "GUARDIAN", "class": "immediate", "delay": 0, "note": "A note."}
        config["manager"] = {"functions": [entry]}
        text = gm.render(config)
        self.assertIn("| `suspend(uint64,address)` | `0x64bf6e5d` | `GUARDIAN` |", text)
        entry["selector"] = "0x00000000"
        with self.assertRaisesRegex(gm.ConfigError, "manager.suspend"):
            gm.render(config)

    def test_immediate_functions_cannot_be_cancelled(self) -> None:
        text = gm.render(committed_config())
        row = next(line for line in text.splitlines() if "`deprecateAsset(address)`" in line)
        self.assertIn("No: executes at once", row)
        row = next(line for line in text.splitlines() if "`recover(address,address,address)`" in line)
        self.assertIn("Yes: any guardian", row)


class MainTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / "config").mkdir()
        shutil.copy(ROOT / gm.CONFIG, self.tmp / gm.CONFIG)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def test_committed_matrix_is_current(self) -> None:
        code, out = run(["--check"])
        self.assertEqual(code, 0, out)

    def test_write_then_check_passes(self) -> None:
        self.assertEqual(run(["--root", str(self.tmp)])[0], 0)
        code, out = run(["--root", str(self.tmp), "--check"])
        self.assertEqual(code, 0, out)

    def test_check_fails_on_a_missing_matrix(self) -> None:
        code, out = run(["--root", str(self.tmp), "--check"])
        self.assertEqual(code, 1)
        self.assertIn("not current", out)

    def test_check_fails_on_a_hand_edit(self) -> None:
        run(["--root", str(self.tmp)])
        target = self.tmp / gm.OUTPUT
        target.write_text(target.read_text(encoding="utf-8").replace("14 days", "7 days"),
                          encoding="utf-8")
        code, out = run(["--root", str(self.tmp), "--check"])
        self.assertEqual(code, 1)
        self.assertIn("-", out)

    def test_check_fails_when_the_configuration_changes(self) -> None:
        run(["--root", str(self.tmp)])
        config = json.loads((self.tmp / gm.CONFIG).read_text(encoding="utf-8"))
        for contract in config["contracts"]:
            for entry in contract.get("functions", []):
                if entry["signature"] == "setIncrementFloor(address,uint64,uint256)":
                    entry.update(role="FUNDS_SETTER", **{"class": "funds"}, delay=1_209_600)
        (self.tmp / gm.CONFIG).write_text(json.dumps(config), encoding="utf-8")
        code, _ = run(["--root", str(self.tmp), "--check"])
        self.assertEqual(code, 1)

    def test_crlf_checkout_still_passes(self) -> None:
        run(["--root", str(self.tmp)])
        target = self.tmp / gm.OUTPUT
        target.write_bytes(target.read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual(run(["--root", str(self.tmp), "--check"])[0], 0)

    def test_invalid_configuration_fails_cleanly(self) -> None:
        config = json.loads((self.tmp / gm.CONFIG).read_text(encoding="utf-8"))
        config["contracts"][0]["functions"][0]["selector"] = "0xdeadbeef"
        (self.tmp / gm.CONFIG).write_text(json.dumps(config), encoding="utf-8")
        code, out = run(["--root", str(self.tmp)])
        self.assertEqual(code, 1)
        self.assertIn("FAIL", out)
        self.assertFalse((self.tmp / gm.OUTPUT).exists())


if __name__ == "__main__":
    unittest.main()
