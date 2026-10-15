"""Unit tests for check_docs_facts.py, which sits beside this file.

Run with `python tools/test_check_docs_facts.py` or, from the repository root,
`python -m tools.test_check_docs_facts`.
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

_SPEC = importlib.util.spec_from_file_location(
    "check_docs_facts", Path(__file__).with_name("check_docs_facts.py")
)
cf = importlib.util.module_from_spec(_SPEC)
sys.modules["check_docs_facts"] = cf
_SPEC.loader.exec_module(cf)

SOURCE = """// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// a comment
contract Widget {
    event Moved(address indexed from, uint256 amount);

    function move() external { }
}
"""

PINS = """contract InterfacesCompileTest {
    function test_interfaceIds() public pure {
        assertEq(type(IWidget).interfaceId, bytes4(0x12345678), "IWidget");
        assertEq(
            type(IGadget).interfaceId, bytes4(0x0badc0de), "IGadget"
        );
    }
}
"""

MOVED = "Moved(address,uint256)"


class TempRepo:
    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.write("src/Widget.sol", SOURCE)
        self.write("src/interfaces/IWidget.sol", "interface IWidget {\n    function move() external;\n}\n")
        self.write("test/interfaces/InterfacesCompile.t.sol", PINS)
        self.write("test/Widget.t.sol", "contract WidgetTest {\n    function test_MovesExist() public { }\n"
                   "    function invariant_Holds() public { }\n}\n")
        self.write("tools/test_thing.py", "def test_python_case():\n    pass\n")
        self.lines = cf.nsloc(self.root / "src/Widget.sol")

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def artifacts(self, runtime: int = 100, init: int = 150, events=None, selectors=None) -> Path:
        out = self.root / "out"
        abi = [{"type": "event", "name": name, "inputs": inputs} for name, inputs in (events or [
            ("Moved", [{"type": "address"}, {"type": "uint256"}])])]
        data = {"abi": abi, "bytecode": {"object": "0x" + "00" * init},
                "deployedBytecode": {"object": "0x" + "00" * runtime},
                "methodIdentifiers": selectors or {"move()": "d5e3ded1"}}
        (out / "Widget.sol").mkdir(parents=True, exist_ok=True)
        (out / "Widget.sol" / "Widget.json").write_text(json.dumps(data), encoding="utf-8")
        return out

    def run(self, artifacts: Path | None = None, update: bool = False) -> cf.Report:
        return cf.run(self.root, artifacts, update)

    def close(self) -> None:
        shutil.rmtree(self.root)


class TestNamesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.close)

    def test_existing_names_pass_and_missing_ones_fail(self) -> None:
        self.repo.write("docs/a.md", "Tested by `test_MovesExist`, `invariant_Holds` and `test_python_case`.\n")
        self.assertEqual(self.repo.run().problems, [])
        self.repo.write("docs/a.md", "Tested by `test_Gone`.\n")
        problems = self.repo.run().problems
        self.assertEqual(len(problems), 1)
        self.assertIn("test_Gone", problems[0])

    def test_modules_files_and_wildcards_are_not_test_names(self) -> None:
        self.repo.write(
            "docs/a.md",
            "Run `python -m tools.test_check_budgets` and `tools/content/test_anvil.py`; the "
            "`test_WorstCase_*` tests.\n",
        )
        self.assertEqual(self.repo.run().problems, [])

    def test_names_outside_code_spans_are_ignored(self) -> None:
        self.repo.write("docs/a.md", "A sentence about test_Gone in prose.\n")
        self.assertEqual(self.repo.run().problems, [])


class InterfaceIdTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.close)

    def test_pinned_and_standard_ids(self) -> None:
        self.repo.write("docs/ids.md", "| Interface | ID |\n| --- | --- |\n| `IWidget` | `0x12345678` |\n"
                        "| `IGadget` | `0x0badc0de` |\n| `IERC2981` | `0x2a55205a` |\n")
        report = self.repo.run()
        self.assertEqual(report.problems, [])
        self.assertEqual(report.checked["interface IDs"], 3)

    def test_a_wrong_id_fails(self) -> None:
        self.repo.write("docs/ids.md", "| `IWidget` | `0x12345679` | r2 `0x00000000` |\n")
        problems = self.repo.run().problems
        self.assertEqual(len(problems), 1)
        self.assertIn("0x12345678", problems[0])

    def test_computed_from_artifacts_when_not_pinned(self) -> None:
        out = self.repo.artifacts()
        (out / "IThing.sol").mkdir()
        (out / "IThing.sol" / "IThing.json").write_text(json.dumps(
            {"abi": [], "methodIdentifiers": {"a()": "0000000f", "b()": "000000f0"}}), encoding="utf-8")
        self.repo.write("docs/ids.md", "| `IThing` | `0x000000ff` |\n")
        self.assertEqual(self.repo.run(out).problems, [])
        self.repo.write("docs/ids.md", "| `IThing` | `0x000000fe` |\n")
        self.assertEqual(len(self.repo.run(out).problems), 1)


class TopicTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.close)
        self.full = cf.hex_keccak(MOVED)

    def page(self, rows: str) -> None:
        self.repo.write(cf.EVENTS_PAGE, "| Event | topic0 |\n| --- | --- |\n" + rows)

    def test_full_and_short_values(self) -> None:
        self.page(f"| `Moved(address indexed from, uint256 amount)` | `{self.full[:10]}…` |\n"
                  f"| `{MOVED}` | `{self.full}` |\n")
        report = self.repo.run()
        self.assertEqual(report.problems, [])
        self.assertEqual(report.checked["topic0 values"], 2)

    def test_a_wrong_prefix_fails(self) -> None:
        self.page("| `Moved(address indexed from, uint256 amount)` | `0x00000000…` |\n")
        self.assertEqual(len(self.repo.run().problems), 1)

    def test_struct_signatures_need_the_artifacts(self) -> None:
        tuple_sig = "Logged((address,uint256))"
        self.page(f"| `Logged(Entry entry)` | `{cf.hex_keccak(tuple_sig)[:10]}…` |\n")
        self.assertEqual(self.repo.run().problems, [])  # unchecked without artifacts
        out = self.repo.artifacts(events=[("Logged", [{"type": "tuple", "components": [
            {"type": "address"}, {"type": "uint256"}]}])])
        report = self.repo.run(out)
        self.assertEqual(report.problems, [])
        self.assertEqual(report.checked["topic0 values"], 1)

    def test_rows_with_two_events_pair_them_in_order(self) -> None:
        other = cf.hex_keccak("Other()")
        self.page(f"| `Moved(…)`, `Other()` | `{self.full[:10]}…`, `{other[:10]}…` |\n")
        out = self.repo.artifacts(events=[("Moved", [{"type": "address"}, {"type": "uint256"}]),
                                          ("Other", [])])
        self.assertEqual(self.repo.run(out).problems, [])
        self.page(f"| `Moved(…)`, `Other()` | `{other[:10]}…`, `{self.full[:10]}…` |\n")
        self.assertEqual(len(self.repo.run(out).problems), 2)

    def test_an_event_missing_from_the_abis_fails(self) -> None:
        self.page(f"| `Vanished(uint256 x)` | `{cf.hex_keccak('Vanished(uint256)')[:10]}…` |\n")
        out = self.repo.artifacts()
        self.assertEqual(len(self.repo.run(out).problems), 1)


class FiguresTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.close)

    def scope(self, lines: int, runtime: int, init: int, margin: int) -> None:
        self.repo.write(cf.SCOPE_PAGE, (
            "| Source lines | 0 non-blank, non-comment lines in 0 files under `src/` |\n\n"
            "| Contract | Source | nSLOC | Runtime | Initcode | Margin |\n| --- | --- | ---: | ---: | ---: | ---: |\n"
            f"| `Widget` | [`src/Widget.sol`](../../src/Widget.sol) | {lines} | {runtime:,} | {init:,} | {margin:,} |\n"
        ))

    def total(self) -> int:
        return sum(cf.nsloc(p) for p in (self.repo.root / "src").rglob("*.sol"))

    def test_stale_figures_fail_and_update_fixes_them(self) -> None:
        out = self.repo.artifacts(runtime=100, init=150)
        self.scope(self.repo.lines + 1, 101, 150, 1)
        problems = self.repo.run(out).problems
        self.assertEqual(len(problems), 4)  # nSLOC, runtime, margin, the summary total
        report = self.repo.run(out, update=True)
        self.assertEqual(report.updated, [cf.SCOPE_PAGE])
        self.assertEqual(self.repo.run(out).problems, [])
        text = (self.repo.root / cf.SCOPE_PAGE).read_text(encoding="utf-8")
        self.assertIn(f"| {self.repo.lines} | 100 | 150 | {cf.EIP170 - 100:,} |", text)
        self.assertIn(f"{self.total()} non-blank, non-comment lines in 2 files", text)

    def test_sizes_are_checked_only_with_artifacts(self) -> None:
        self.scope(self.repo.lines, 1, 1, 1)
        problems = self.repo.run().problems
        self.assertEqual(len(problems), 1)  # only the summary total
        self.assertIn("the sources give", problems[0])

    def test_readme_module_table(self) -> None:
        self.repo.write(cf.README, "| Contract | Purpose | nSLOC |\n| --- | --- | ---: |\n"
                        f"| [`Widget`](src/README.md) | Moves | {self.repo.lines} |\n\nAfter.\n")
        self.assertEqual(self.repo.run().problems, [])
        self.repo.write(cf.README, "| Contract | Purpose | nSLOC |\n| --- | --- | ---: |\n"
                        "| [`Widget`](src/README.md) | Moves | 999 |\n")
        self.assertEqual(len(self.repo.run().problems), 1)
        self.repo.run(update=True)
        self.assertIn(f"| {self.repo.lines} |", (self.repo.root / cf.README).read_text(encoding="utf-8"))


class MainTest(unittest.TestCase):
    def test_the_repository_passes_its_source_checks(self) -> None:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cf.main([])
        self.assertEqual(code, 0, out.getvalue())

    def test_missing_artifacts_directory_fails(self) -> None:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cf.main(["--artifacts", "no-such-dir-for-docs-facts"])
        self.assertEqual(code, 1)
        self.assertIn("does not exist", out.getvalue())


if __name__ == "__main__":
    unittest.main()
