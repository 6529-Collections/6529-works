"""Unit tests for check_coverage.py, which sits beside this file.

Run with `python tools/test_check_coverage.py` or, from the repository root,
`python -m tools.test_check_coverage`.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "check_coverage", Path(__file__).with_name("check_coverage.py")
)
cc = importlib.util.module_from_spec(_SPEC)
sys.modules["check_coverage"] = cc  # dataclasses resolve annotations through sys.modules
_SPEC.loader.exec_module(cc)


def _record(path: str, lines: dict[int, int], branches: list[tuple[int, str]], fns=(1, 1)) -> str:
    """One LCOV record: `lines` maps line to hits, `branches` lists (line, taken)."""
    out = ["TN:", f"SF:{path}"]
    out += [f"DA:{n},{h}" for n, h in lines.items()]
    out += [f"BRDA:{line},{i},0,{taken}" for i, (line, taken) in enumerate(branches)]
    hit_branches = sum(1 for _, t in branches if t not in ("-", "0"))
    out += [
        f"FNF:{fns[0]}",
        f"FNH:{fns[1]}",
        f"LF:{len(lines)}",
        f"LH:{sum(1 for h in lines.values() if h > 0)}",
        f"BRF:{len(branches)}",
        f"BRH:{hit_branches}",
        "end_of_record",
    ]
    return "\n".join(out) + "\n"


FULL = _record("src/a/Full.sol", {1: 3, 2: 1}, [(2, "4"), (2, "1")])
PARTIAL = _record("src/a/Partial.sol", {1: 1, 2: 0, 3: 1, 4: 1}, [(3, "2"), (3, "-")])
TEST_FILE = _record("test/A.t.sol", {1: 0}, [])
INTERFACE = _record("src/a/IThing.sol", {}, [], fns=(0, 0))


def _floors(files: dict | None = None) -> dict:
    return {
        "margin": {"lines": 1.0, "branches": 2.5},
        "default": {"lines": 95.0, "branches": 85.0},
        "files": files or {},
    }


class ParseTest(unittest.TestCase):
    def test_totals_come_from_the_summary_fields(self) -> None:
        files = cc.parse_lcov(FULL + PARTIAL)
        p = files["src/a/Partial.sol"]
        self.assertEqual((p.lines_found, p.lines_hit), (4, 3))
        self.assertEqual((p.branches_found, p.branches_hit), (2, 1))
        self.assertEqual(p.uncovered_lines, [2])
        self.assertEqual(p.uncovered_branches, [(3, 1, 0)])
        self.assertAlmostEqual(p.percent("lines"), 75.0)
        self.assertAlmostEqual(p.percent("branches"), 50.0)

    def test_a_file_without_branches_is_fully_covered_on_branches(self) -> None:
        f = cc.parse_lcov(_record("src/B.sol", {1: 1}, []))["src/B.sol"]
        self.assertEqual(f.percent("branches"), 100.0)

    def test_only_src_files_with_code_are_reported(self) -> None:
        files = cc.source_files(cc.parse_lcov(FULL + TEST_FILE + INTERFACE))
        self.assertEqual(list(files), ["src/a/Full.sol"])

    def test_windows_separators_are_normalised(self) -> None:
        files = cc.parse_lcov(_record("src\\a\\W.sol", {1: 1}, []))
        self.assertIn("src/a/W.sol", files)

    def test_malformed_input_fails_closed(self) -> None:
        for text in (
            "SF:src/A.sol\nDA:1,1\n",  # no end_of_record
            "DA:1,1\nend_of_record\n",  # field outside a record
            "SF:src/A.sol\nDA:x,1\nend_of_record\n",  # not a number
            "SF:src/A.sol\nnonsense\nend_of_record\n",  # not a field
            "SF:src/A.sol\nSF:src/B.sol\nend_of_record\n",  # nested record
            FULL + FULL,  # the same file twice
        ):
            with self.subTest(text=text[:30]):
                with self.assertRaises(cc.CoverageError):
                    cc.parse_lcov(text)


class CheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.files = cc.source_files(cc.parse_lcov(FULL + PARTIAL))

    def test_files_at_or_above_their_floors_pass(self) -> None:
        floors = _floors(
            {
                "src/a/Full.sol": {"lines": 99.0, "branches": 97.5},
                "src/a/Partial.sol": {"lines": 75.0, "branches": 50.0},
            }
        )
        self.assertEqual(cc.check(self.files, floors), [])

    def test_a_file_below_a_floor_fails(self) -> None:
        floors = _floors(
            {
                "src/a/Full.sol": {"lines": 99.0, "branches": 97.5},
                "src/a/Partial.sol": {"lines": 75.1, "branches": 50.0},
            }
        )
        failures = cc.check(self.files, floors)
        self.assertEqual(len(failures), 1)
        self.assertIn("src/a/Partial.sol: lines 75.00%", failures[0])

    def test_a_file_without_an_entry_meets_the_default(self) -> None:
        failures = cc.check(self.files, _floors({"src/a/Full.sol": {"lines": 0, "branches": 0}}))
        # Partial: 75% lines < 95, 50% branches < 85.
        self.assertEqual(len(failures), 2)
        self.assertTrue(all("default floor" in f for f in failures))

    def test_a_floor_without_a_file_fails(self) -> None:
        floors = _floors(
            {
                "src/a/Full.sol": {"lines": 0, "branches": 0},
                "src/a/Partial.sol": {"lines": 0, "branches": 0},
                "src/a/Gone.sol": {"lines": 0, "branches": 0},
            }
        )
        failures = cc.check(self.files, floors)
        self.assertEqual(len(failures), 1)
        self.assertIn("src/a/Gone.sol", failures[0])

    def test_written_floors_are_the_figure_minus_the_margin_rounded_down(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "floors.json"
            cc.write_floors(self.files, _floors(), path)
            written = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(written["files"]["src/a/Full.sol"], {"lines": 99.0, "branches": 97.5})
        self.assertEqual(written["files"]["src/a/Partial.sol"], {"lines": 74.0, "branches": 47.5})
        # And the run that wrote them passes them.
        self.assertEqual(cc.check(self.files, written), [])

    def test_floors_file_shape_is_checked(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "floors.json"
            for bad in (
                {"margin": {}, "default": {}, "files": {}},
                {**_floors(), "default": {"lines": 101, "branches": 0}},
                {**_floors(), "files": {"src/A.sol": {"lines": 1}}},
                [],
            ):
                path.write_text(json.dumps(bad), encoding="utf-8")
                with self.subTest(bad=bad), self.assertRaises(cc.CoverageError):
                    cc.load_floors(path)


class MainTest(unittest.TestCase):
    def _run(self, lcov: str, floors: dict, *args: str) -> tuple[int, str, str]:
        with tempfile.TemporaryDirectory() as d:
            lcov_path = Path(d) / "lcov.info"
            lcov_path.write_text(lcov, encoding="utf-8")
            floors_path = Path(d) / "floors.json"
            floors_path.write_text(json.dumps(floors), encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = cc.main(["--lcov", str(lcov_path), "--floors", str(floors_path), *args])
            return code, out.getvalue(), err.getvalue()

    def test_table_and_pass(self) -> None:
        code, out, _ = self._run(FULL, _floors(), "--uncovered")
        self.assertEqual(code, 0)
        self.assertIn("| `src/a/Full.sol` | 100.00% (2/2) | 100.00% (2/2)", out)
        self.assertIn("src/ total", out)

    def test_regression_exits_one(self) -> None:
        code, _, err = self._run(PARTIAL, _floors(), "--uncovered")
        self.assertEqual(code, 1)
        self.assertIn("Coverage regressions", err)

    def test_no_src_coverage_is_an_error(self) -> None:
        code, _, err = self._run(TEST_FILE, _floors())
        self.assertEqual(code, 2)
        self.assertIn("no src/ file", err)


if __name__ == "__main__":
    unittest.main()
