"""Unit tests for gen_facts.py, which sits beside this file.

Run with `python tools/test_gen_facts.py` or, from the repository root,
`python -m tools.test_gen_facts`.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location("gen_facts", Path(__file__).with_name("gen_facts.py"))
gf = importlib.util.module_from_spec(_SPEC)
sys.modules["gen_facts"] = gf
_SPEC.loader.exec_module(gf)

ROOT = Path(__file__).resolve().parent.parent


def run(argv: list[str]) -> tuple[int, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = gf.main(argv)
    return code, out.getvalue()


class LiteralTest(unittest.TestCase):
    def test_plain_and_grouped_numbers(self) -> None:
        self.assertEqual(gf.literal("5_000"), 5000)
        self.assertEqual(gf.literal("262_144"), 262_144)
        self.assertEqual(gf.literal("1e15"), 10**15)

    def test_time_and_ether_units(self) -> None:
        self.assertEqual(gf.literal("24 hours"), 86_400)
        self.assertEqual(gf.literal("15 minutes"), 900)
        self.assertEqual(gf.literal("7 days"), 604_800)
        self.assertEqual(gf.literal("0.001 ether"), 10**15)
        self.assertEqual(gf.literal("1 gwei"), 10**9)

    def test_refuses_what_it_cannot_evaluate(self) -> None:
        for expr in ("type(uint64).max", "2 ** 8", "1 fortnights", "0.5 seconds", "x"):
            with self.subTest(expr=expr), self.assertRaises(gf.FactError):
                gf.literal(expr)


class SourceTest(unittest.TestCase):
    def test_strip_comments_keeps_strings(self) -> None:
        source = 'a // b\nc /* d */ e "f // g" \'h /* i */\''
        self.assertEqual(gf.strip_comments(source), 'a \nc  e "f // g" \'h /* i */\'')

    def test_constants_resolve_library_references(self) -> None:
        c = gf.Constants(ROOT)
        chunk = c.integer("src/content/ContentStore.sol", "CHUNK_SIZE")
        self.assertEqual(chunk, c.integer("src/libraries/SSTORE2.sol", "MAX_CHUNK_LENGTH"))

    def test_unknown_constant_fails(self) -> None:
        with self.assertRaises(gf.FactError):
            gf.Constants(ROOT).integer("src/governance/Roles.sol", "NOT_A_CONSTANT")

    def test_deploy_default_is_read_from_the_script(self) -> None:
        self.assertEqual(gf.deploy_default(ROOT, "AUCTION_DURATION"), 86_400)
        with self.assertRaises(gf.FactError):
            gf.deploy_default(ROOT, "NO_SUCH_VARIABLE")

    def test_versions_sort_prereleases_before_the_release(self) -> None:
        stems = ["v1.0.0", "v1.0.0-rc.10", "v1.0.0-rc.2", "v0.9.0", "v1.0.0-rc.1"]
        self.assertEqual(
            sorted(stems, key=gf._version_key),
            ["v0.9.0", "v1.0.0-rc.1", "v1.0.0-rc.2", "v1.0.0-rc.10", "v1.0.0"],
        )


class GasRowTest(unittest.TestCase):
    def row(self, *cells: str) -> dict:
        return gf._gas_row(list(cells), "r3")

    def test_a_budgeted_row(self) -> None:
        self.assertEqual(
            self.row("`start`, steady state", "270,138", "350,000", "**5**", "0", "735,859"),
            {
                "operation": "start, steady state",
                "pragueGas": 270_138,
                "pragueCeiling": {"gas": 350_000, "kind": "budget"},
                "newSlots": 5,
                "newSlotsBudgeted": True,
                "newAccounts": 0,
                "sepoliaGas": {"gas": 735_859, "source": "r3"},
            },
        )

    def test_ceiling_kinds_and_sepolia_sources(self) -> None:
        r = self.row("`bid`", "73,464", "75,000 (regression)", "1", "0", "169,060 (r2)")
        self.assertEqual(r["pragueCeiling"], {"gas": 75_000, "kind": "regression"})
        self.assertEqual(r["sepoliaGas"], {"gas": 169_060, "source": "r2"})
        r = self.row("`royaltyInfo` (view)", "41,622", "50,000 of execution", "0", "0", "—")
        self.assertEqual(r["pragueCeiling"]["kind"], "execution")
        self.assertIsNone(r["sepoliaGas"])
        r = self.row("`settle`", "1", "—", "1", "1", "449,934 (sim.)")
        self.assertIsNone(r["pragueCeiling"])
        self.assertEqual(r["sepoliaGas"]["source"], "r3 simulation")
        r = self.row("`tokenURI`", "at most 2,735,362", "8,000,000", "0", "0", "unchanged")
        self.assertTrue(r["pragueGasIsMaximum"])
        self.assertEqual(r["sepoliaGas"], {"note": "unchanged"})

    def test_an_execution_gas_row_with_a_range_of_slots(self) -> None:
        row = gf._gas_row(
            [
                "Edition `settle`, each call",
                "at most 228,103 of execution",
                "350,000 of execution",
                "0 to 2 (the call that clears writes the result)",
                "0",
                "—",
            ],
            "Sepolia r3",
        )
        self.assertEqual(row["pragueGas"], 228_103)
        self.assertTrue(row["pragueGasIsMaximum"])
        self.assertTrue(row["pragueGasIsExecution"])
        self.assertEqual(row["pragueCeiling"], {"gas": 350_000, "kind": "execution"})
        self.assertEqual((row["newSlots"], row["newSlotsRange"]), (2, [0, 2]))
        self.assertEqual(row["newSlotsNote"], "the call that clears writes the result")

    def test_a_regression_ceiling_with_a_note(self) -> None:
        row = gf._gas_row(
            ["`startWithBid`, replaced", "343,200", "346,000 (regression; LIM-GAS-11)", "7", "0", "—"],
            "Sepolia r3",
        )
        self.assertEqual(
            row["pragueCeiling"], {"gas": 346_000, "kind": "regression", "note": "LIM-GAS-11"}
        )

    def test_malformed_cells_fail(self) -> None:
        bad = [
            ("x", "about 70K", "75,000", "1", "0", "—"),
            ("x", "1", "75,000 (budget?)", "1", "0", "—"),
            ("x", "1", "75,000", "**1", "0", "—"),
            ("x", "1", "75,000", "1", "one", "—"),
        ]
        for cells in bad:
            with self.subTest(cells=cells), self.assertRaises(gf.FactError):
                self.row(*cells)


class RepositoryTest(unittest.TestCase):
    def test_the_committed_file_is_current(self) -> None:
        code, out = run(["--check"])
        self.assertEqual(code, 0, out)

    def test_facts_name_their_sources(self) -> None:
        facts = gf.generate(ROOT)
        self.assertEqual(facts["schema"], gf.SCHEMA)
        sepolia = facts["networks"]["sepolia"]
        self.assertTrue(sepolia["deployed"])
        record = json.loads((ROOT / sepolia["record"]).read_text(encoding="utf-8"))
        self.assertEqual(sepolia["contracts"]["Stream"], record["contracts"]["Stream"]["address"])
        self.assertFalse(facts["networks"]["mainnet"]["deployed"])
        names = {c["contract"]: c for c in facts["collections"]}
        self.assertEqual(names["Stream"]["name"], "6529 Stream")
        self.assertEqual(
            (names["Editions"]["name"], names["Editions"]["symbol"]),
            ("6529 Stream Editions", "STREAMEDITIONS"),
        )
        auction = facts["parameters"]["editionAuction"]
        self.assertEqual(auction["breadthMargin"]["default"], 10_000)
        self.assertEqual(auction["closeOffsetSeconds"]["default"], 15 * 60)
        self.assertEqual(auction["stepsPerDecade"]["allowed"], [24, 48, 96, 192])
        self.assertGreater(len(facts["gas"]["rows"]), 10)


class TreeTest(unittest.TestCase):
    """Generation on a copy of the sources, changed one way at a time."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        for rel in ("README.md", "CHANGELOG.md", "SECURITY.md", "script/Deploy.s.sol", "script/DeployV1.sol"):
            self._copy(rel)
        for rel in ("src", "docs", "deployments"):
            shutil.copytree(ROOT / rel, self.tmp / rel)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def _copy(self, rel: str) -> None:
        (self.tmp / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / rel, self.tmp / rel)

    def _edit(self, rel: str, old: str, new: str) -> None:
        path = self.tmp / rel
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def test_the_copy_generates_the_same_facts(self) -> None:
        self.assertEqual(gf.generate(self.tmp), gf.generate(ROOT))

    def test_check_fails_on_a_stale_file_and_writing_fixes_it(self) -> None:
        facts = self.tmp / gf.OUTPUT
        facts.write_text("{}\n", encoding="utf-8")
        code, out = run(["--root", str(self.tmp), "--check"])
        self.assertEqual(code, 1)
        self.assertIn("not current", out)
        self.assertEqual(run(["--root", str(self.tmp)])[0], 0)
        self.assertEqual(run(["--root", str(self.tmp), "--check"])[0], 0)

    def test_a_changed_default_reaches_the_facts(self) -> None:
        self._edit(gf.DEPLOY_SCRIPT, '"AUCTION_DURATION", 24 hours', '"AUCTION_DURATION", 2 days')
        facts = gf.generate(self.tmp)
        self.assertEqual(facts["parameters"]["oneOfOneAuction"]["durationSeconds"]["default"], 172_800)

    def test_the_newest_record_is_the_current_instance(self) -> None:
        directory = self.tmp / "deployments" / "11155111"
        newest = max(directory.glob("*.json"), key=lambda p: json.loads(p.read_text())["timestamp"])
        data = json.loads(newest.read_text(encoding="utf-8"))
        data["timestamp"] += 1
        data["genesisConfig"] = "config/sepolia-r9/genesis.json"
        (directory / "9999999999.json").write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(gf.FactError, "sepolia-r9"):
            gf.generate(self.tmp)
        readme = directory / "README.md"
        readme.write_text(
            readme.read_text(encoding="utf-8")
            + "\n## sepolia-r9: 1 November 2026 (current)\n\n| Source | `main` at `abcdef1` |\n",
            encoding="utf-8",
        )
        sepolia = gf.generate(self.tmp)["networks"]["sepolia"]
        self.assertEqual(
            (sepolia["instance"], sepolia["sourceCommit"], sepolia["deployedOn"]),
            ("sepolia-r9", "abcdef1", "2026-11-01"),
        )

    def test_the_edition_auction_launch_values_are_what_genesis_deploys(self) -> None:
        self._edit(gf.DEPLOY_LIBRARY, "softWindow: 5 minutes", "softWindow: 10 minutes")
        self._edit(gf.ADR_0005, "| Soft-close window (D141) | 5 minutes |", "| Soft-close window (D141) | 10 minutes |")
        auction = gf.generate(self.tmp)["parameters"]["editionAuction"]
        self.assertEqual(auction["softCloseWindowSeconds"]["default"], 600)

    def test_the_deploy_and_adr_0005_must_agree(self) -> None:
        self._edit(gf.DEPLOY_LIBRARY, "closeOffset: 15 minutes", "closeOffset: 20 minutes")
        with self.assertRaisesRegex(gf.FactError, "closeOffset"):
            gf.generate(self.tmp)

    def test_adr_0005_and_the_ladder_code_must_agree(self) -> None:
        self._edit(gf.ADR_0005, "| Steps | 336 |", "| Steps | 320 |")
        with self.assertRaisesRegex(gf.FactError, "stepCount"):
            gf.generate(self.tmp)

    def test_a_missing_edition_parameter_row_fails(self) -> None:
        self._edit(gf.ADR_0005, "| Breadth margin (D138) |", "| Margin |")
        with self.assertRaisesRegex(gf.FactError, "Breadth margin"):
            gf.generate(self.tmp)

    def test_a_reshaped_gas_table_fails(self) -> None:
        self._edit(gf.ADR_0004, "| Operation | Prague gas |", "| Operation | Gas |")
        with self.assertRaisesRegex(gf.FactError, "columns"):
            gf.generate(self.tmp)

    def test_a_missing_linked_page_fails(self) -> None:
        (self.tmp / "docs" / "glossary.md").unlink()
        code, out = run(["--root", str(self.tmp), "--stdout"])
        self.assertEqual(code, 1)
        self.assertIn("docs/glossary.md", out)


if __name__ == "__main__":
    unittest.main()
