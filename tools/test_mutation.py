"""Unit tests for mutation.py, which sits beside this file.

Run with `python tools/test_mutation.py` or, from the repository root,
`python -m tools.test_mutation`. They need neither Slither nor Foundry.
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

_SPEC = importlib.util.spec_from_file_location("mutation", Path(__file__).with_name("mutation.py"))
mt = importlib.util.module_from_spec(_SPEC)
sys.modules["mutation"] = mt  # dataclasses resolve annotations through sys.modules
_SPEC.loader.exec_module(mt)

ROOT = Path(__file__).resolve().parent.parent

# The shape slither-mutate 0.11.6 logs: one summary line per category, one line per survivor
# (a revert-replacement survivor quotes a whole multi-line body).
LOG = """INFO:Slither-Mutate:Starting mutation campaign in src/x/Thing.sol
INFO:Slither-Mutate:Mutating contract Thing
INFO:Slither-Mutate:[RR] Line 12: '{
        total += amount;
    }' ==> '{revert();}' --> UNCAUGHT
INFO:Slither-Mutate:Tests took too long, consider increasing the timeout
INFO:Slither-Mutate:[CR] Line 20: 'emit Done(x)' ==> '//emit Done(x)' --> UNCAUGHT
INFO:Slither-Mutate:[ROR] Line 31: 'a < b' ==> 'a <= b' --> UNCAUGHT
INFO:Slither-Mutate:[ROR] Line 33: 'c > d' ==> 'c >= d' --> UNCAUGHT
INFO:Slither-Mutate:Done mutating Thing.
INFO:Slither-Mutate:Revert mutants: 3 caught of 4 (75.0% caught)
INFO:Slither-Mutate:Comment mutants: 9 caught of 10 (90.0% caught)
INFO:Slither-Mutate:Tweak mutants: 18 caught of 20 (90.0% caught)
"""

CONSTANTS = """library L {
    uint256 internal constant MAX = 1_024;
    uint8 private constant SMALL = 0;
    uint256 constant internal HEX = 0x10;
    bytes32 internal constant HASH = keccak256("x");
    uint256 internal constant SUM = A + 1;
    uint256 internal notConstant = 7;
}
"""


class ParseLogTest(unittest.TestCase):
    def test_counts_and_survivors(self) -> None:
        r = mt.FileResult("src/x/Thing.sol")
        mt.parse_log(LOG, r)
        self.assertEqual(r.status, "ok")
        self.assertEqual(r.total, {"revert": 4, "comment": 10, "tweak": 20, "constant": 0})
        self.assertEqual(r.caught, {"revert": 3, "comment": 9, "tweak": 18, "constant": 0})
        self.assertEqual(r.mutants, 34)
        self.assertEqual(r.killed, 30)
        self.assertEqual(r.timeouts, 1)
        self.assertEqual(
            [(s.rule, s.line) for s in r.survivors],
            [("RR", 12), ("CR", 20), ("ROR", 31), ("ROR", 33)],
        )
        # The n-th survivor of a rule is the file slither-mutate saved as <stem>_<rule>_<n>.
        self.assertEqual([s.mutant_file for s in r.survivors], ["RR_0", "CR_0", "ROR_0", "ROR_1"])
        self.assertIn("total += amount;", r.survivors[0].old)

    def test_a_survivor_count_that_disagrees_with_the_totals_fails(self) -> None:
        r = mt.FileResult("src/x/Thing.sol")
        with self.assertRaises(mt.MutationError):
            mt.parse_log(LOG.replace("18 caught of 20", "19 caught of 20"), r)

    def test_an_aborted_campaign_is_reported(self) -> None:
        r = mt.FileResult("src/x/Thing.sol")
        mt.parse_log("ERROR:Slither-Mutate:Test suite fails with mutations, aborting\n", r)
        self.assertEqual(r.status, "aborted")

    def test_rechecked_survivors_count_as_killed(self) -> None:
        r = mt.FileResult("src/x/Thing.sol")
        mt.parse_log(LOG, r)
        r.survivors[0].recheck = "killed"
        r.survivors[1].recheck = "timeout"
        r.survivors[2].recheck = "survived"
        self.assertEqual(r.killed, 32)
        self.assertAlmostEqual(mt.kill_rate(r), 100.0 * 32 / 34)


class ShardTest(unittest.TestCase):
    def test_every_file_with_code_has_its_shards_and_no_other_file_does(self) -> None:
        all_shards = mt.shards(ROOT)
        files = mt.source_files(ROOT)
        self.assertEqual(sorted({s.path for s in all_shards.values()}), files)
        for f in files:
            mine = [s for s in all_shards.values() if s.path == f]
            self.assertEqual(len(mine), len(mt.SPLIT_GROUPS) if f in mt.SPLIT_FILES else 1, f)
            # Every file gets the CONST pass exactly once.
            self.assertEqual(sum(s.constants for s in mine), 1, f)
        self.assertNotIn("src/interfaces/IStream.sol", files)  # an interface only
        self.assertIn("src/interfaces/types/HashRef.sol", files)  # file-level code

    def test_split_groups_and_skipped_operators_cover_every_mutator_once(self) -> None:
        groups = [set(m.split(",")) for m in mt.SPLIT_GROUPS.values()]
        groups.append(set(mt.SKIPPED_ON_SPLIT_FILES.split(",")))
        seen: set[str] = set()
        for g in groups:
            self.assertFalse(seen & g, g)
            seen |= g
        self.assertEqual(len(seen), 15)  # slither-mutate 0.11.6 has 15 operators
        self.assertEqual(mt.SPLIT_GROUPS["statements"], "RR,CR")

    def test_every_module_runs_tests(self) -> None:
        for module, glob in mt.MODULE_TESTS.items():
            self.assertTrue(glob.startswith("test/"), module)

    def test_every_floor_names_a_file_with_code_as_a_whole_percentage(self) -> None:
        floors = json.loads((ROOT / "tools" / "mutation-floors.json").read_text(encoding="utf-8"))
        self.assertIsInstance(floors["margin"], float)
        files = set(mt.source_files(ROOT))
        for path, floor in floors["files"].items():
            self.assertIn(path, files, "a floor for a file that is gone or has no code")
            self.assertIsInstance(floor, int, path)
            self.assertTrue(0 <= floor <= 100, path)


class BudgetTest(unittest.TestCase):
    def test_a_command_that_outruns_its_timeout_is_stopped(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "sleep.log"
            code = mt._run_logged([sys.executable, "-c", "import time; time.sleep(60)"], log, 0.5)
            self.assertEqual(code, -1)
            self.assertIn("timed out", log.read_text(encoding="utf-8"))

    def test_the_deadline_shortens_each_timeout(self) -> None:
        self.assertIsNone(mt.Deadline(None).cap(None))
        self.assertEqual(mt.Deadline(None).cap(5), 5)
        self.assertFalse(mt.Deadline(None).passed)
        self.assertLessEqual(mt.Deadline(1).cap(1200), 1)
        self.assertTrue(mt.Deadline(0).passed)
        self.assertEqual(mt.Deadline(0).cap(1200), 0)

    def test_a_spent_budget_ends_the_constants_as_timeout_and_the_recheck_as_a_lower_bound(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source = root / "src" / "x" / "Thing.sol"
            source.parent.mkdir(parents=True)
            source.write_bytes(CONSTANTS.encode("utf-8"))
            shard = mt.Shard("x-Thing", "src/x/Thing.sol", "test/x/**", None, True)
            r = mt.FileResult(shard.path)
            mt.run_constants(root, shard, root, 60, r, mt.Deadline(0))
            self.assertEqual(r.status, "timeout")
            self.assertEqual(r.total["constant"], 0)
            self.assertEqual(source.read_bytes(), CONSTANTS.encode("utf-8"))

            r = mt.FileResult(shard.path)
            mt.parse_log(LOG, r)
            mt.recheck(root, r, root, 60, mt.Deadline(0))
            # Every mutant ran against its module's tests: complete, the rate a lower bound.
            self.assertEqual(r.status, "ok")
            self.assertEqual(r.unrechecked, 4)
            self.assertEqual(r.killed, 30)
            self.assertEqual(source.read_bytes(), CONSTANTS.encode("utf-8"))
        text = mt.markdown([r])
        self.assertIn("**Lower bounds:**", text)
        self.assertIn("- `src/x/Thing.sol`: 4 not re-checked", text)


class RestoreTest(unittest.TestCase):
    def test_slither_mutate_leaves_the_source_as_it_found_it_on_any_exit(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source = root / "src" / "x" / "Thing.sol"
            source.parent.mkdir(parents=True)
            source.write_bytes(CONSTANTS.encode("utf-8"))
            shard = mt.Shard("x-Thing", "src/x/Thing.sol", "test/x/**", None, True)

            def interrupted(cmd, log, timeout=None, env=None):
                source.write_bytes(b"// a mutant left behind")
                raise KeyboardInterrupt

            real = mt._run_logged
            mt._run_logged = interrupted
            try:
                with self.assertRaises(KeyboardInterrupt):
                    mt.run_slither_mutate(
                        root, shard, root, 60, mt.FileResult(shard.path), mt.Deadline(None)
                    )
            finally:
                mt._run_logged = real
            self.assertEqual(source.read_bytes(), CONSTANTS.encode("utf-8"))


class RorTest(unittest.TestCase):
    def test_the_replacements_equivalent_for_an_unsigned_comparison_with_zero(self) -> None:
        eq = mt.unsigned_zero_equivalent
        # x == 0, x != 0, x > 0, x <= 0 (zero on the right) and their mirrors.
        self.assertEqual(
            [eq(op, "right") for op in ("==", "!=", ">", "<=", "<", ">=")],
            ["<=", ">", "!=", "==", None, None],
        )
        self.assertEqual(
            [eq(op, "left") for op in ("==", "!=", "<", ">=", ">", "<=")],
            [">=", "<", "!=", "==", None, None],
        )
        self.assertIsNone(eq("==", None))  # not a comparison of an unsigned value with zero


class ConstantTest(unittest.TestCase):
    def test_integer_literal_constants_move_one_up_and_one_down(self) -> None:
        mutants = mt.constant_mutants(CONSTANTS)
        self.assertEqual(
            [(line, new) for line, _, new, _ in mutants],
            [
                (2, "uint256 internal constant MAX = 1025;"),
                (2, "uint256 internal constant MAX = 1023;"),
                (3, "uint8 private constant SMALL = 1;"),  # never below zero
                (4, "uint256 constant internal HEX = 0x11;"),
                (4, "uint256 constant internal HEX = 0xf;"),
            ],
        )
        # Each mutant changes exactly that value and nothing else.
        self.assertEqual(mutants[0][3].replace("MAX = 1025;", "MAX = 1_024;"), CONSTANTS)


class ReportTest(unittest.TestCase):
    def _write(self, d: Path, name: str, r) -> None:
        path = d / name / "results.json"
        path.parent.mkdir()
        path.write_text(json.dumps({"shard": name, "files": [mt.asdict(r)]}), encoding="utf-8")

    def _results(self, d: Path) -> Path:
        r = mt.FileResult("src/x/Thing.sol")
        mt.parse_log(LOG, r)
        r.survivors[0].recheck = "killed"
        self._write(d, "x", r)
        return d

    def test_markdown_lists_the_rate_and_the_live_survivors(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            results = mt.load_results([self._results(Path(d))])
        text = mt.markdown(results)
        self.assertIn(
            "| `src/x/Thing.sol` | 34 | 31 | 3 | 91.2% | 3/4 | 9/10 | 18/20 | 0/0 |", text
        )
        self.assertNotIn("total += amount", text)  # killed on re-check
        self.assertIn("`a < b` to `a <= b`", text)

    def test_the_groups_of_a_split_file_are_merged(self) -> None:
        statements = mt.FileResult("src/x/Big.sol")
        statements.total.update(revert=2, comment=3, constant=2)
        statements.caught.update(revert=2, comment=3, constant=1)
        statements.survivors.append(mt.Survivor("CONST", 5, "A = 1;", "A = 2;"))
        operators = mt.FileResult("src/x/Big.sol")
        operators.total.update(tweak=10)
        operators.caught.update(tweak=10)
        with tempfile.TemporaryDirectory() as d:
            self._write(Path(d), "x-Big-statements", statements)
            self._write(Path(d), "x-Big-operators", operators)
            (merged,) = mt.load_results([Path(d)])
        self.assertEqual(merged.mutants, 17)
        self.assertEqual(merged.killed, 16)
        self.assertEqual(len(merged.survivors), 1)

    def test_floors(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            results = mt.load_results([self._results(Path(d))])
            floors = Path(d) / "floors.json"
            floors.write_text(json.dumps({"files": {"src/x/Thing.sol": 91.0}}), encoding="utf-8")
            self.assertEqual(mt.check_floors(results, floors), [])
            floors.write_text(json.dumps({"files": {"src/x/Thing.sol": 92.0}}), encoding="utf-8")
            self.assertEqual(len(mt.check_floors(results, floors)), 1)

    def test_written_floors_are_the_rate_minus_the_margin(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            results = mt.load_results([self._results(Path(d))])  # 91.2%
            path = Path(d) / "floors.json"
            mt.write_floors(results, path, 2.0)
            written = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(written, {"margin": 2.0, "files": {"src/x/Thing.sol": 89}})
            self.assertEqual(mt.check_floors(results, path), [])

    def test_report_command_fails_below_a_floor(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            base = self._results(Path(d))
            floors = Path(d) / "floors.json"
            floors.write_text(json.dumps({"files": {"src/x/Thing.sol": 99.0}}), encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = mt.main(["report", str(base), "--floors", str(floors)])
        self.assertEqual(code, 1)
        self.assertIn("below its floor", err.getvalue())

    def test_results_name_their_shards(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            (r,) = mt.load_results([self._results(Path(d))])
        self.assertEqual(r.shards, ["x"])

    def _plan(self) -> dict:
        big = [
            mt.Shard(f"x-Big-{g}", "src/x/Big.sol", "test/x/**", m, g == "statements")
            for g, m in mt.SPLIT_GROUPS.items()
        ]
        new = mt.Shard("x-New", "src/x/New.sol", "test/x/**", None, True)
        thing = mt.Shard("x", "src/x/Thing.sol", "test/x/**", None, True)
        return {s.name: s for s in [*big, new, thing]}

    def test_a_planned_shard_without_results_marks_its_file_missing(self) -> None:
        operators = mt.FileResult("src/x/Big.sol", shards=["x-Big-operators"])
        operators.total.update(tweak=10)
        operators.caught.update(tweak=10)
        with tempfile.TemporaryDirectory() as d:
            self._results(Path(d))
            self._write(Path(d), "x-Big-operators", operators)
            results = mt.apply_plan(mt.load_results([Path(d)]), self._plan())
        by_path = {r.path: r for r in results}
        self.assertEqual(sorted(by_path), ["src/x/Big.sol", "src/x/New.sol", "src/x/Thing.sol"])
        # A split file with some groups reported is not scored as if it were whole.
        big = by_path["src/x/Big.sol"]
        self.assertEqual(big.status, "missing")
        self.assertEqual(big.missing, ["x-Big-statements", "x-Big-relations", "x-Big-conditions"])
        # A planned file with no results at all still gets its row.
        self.assertEqual(by_path["src/x/New.sol"].missing, ["x-New"])
        self.assertEqual(by_path["src/x/Thing.sol"].status, "ok")
        text = mt.markdown(results)
        self.assertIn("**2 contract(s) without a complete result:**", text)
        self.assertIn("- `src/x/New.sol`: missing: no results from x-New", text)
        self.assertIn("| `src/x/Big.sol` (missing) | 10 |", text)

    def test_floors_fail_an_unfinished_file_and_a_file_without_a_floor(self) -> None:
        thing = mt.FileResult("src/x/Thing.sol")
        mt.parse_log(LOG, thing)  # 88.2%
        late = mt.FileResult("src/x/Late.sol", status="timeout")
        empty = mt.FileResult("src/x/Types.sol")  # nothing to mutate
        new = mt.FileResult("src/x/New.sol")
        new.total.update(tweak=4)
        new.caught.update(tweak=3)
        with tempfile.TemporaryDirectory() as d:
            floors = Path(d) / "floors.json"
            floors.write_text(
                json.dumps({"files": {"src/x/Thing.sol": 88, "src/x/Late.sol": 50}}),
                encoding="utf-8",
            )
            failures = mt.check_floors([thing, late, empty, new], floors)
        self.assertEqual(len(failures), 2, failures)
        self.assertEqual(failures[0], "src/x/Late.sol: timeout")
        self.assertIn("src/x/New.sol: kill rate 75.0% and no floor", failures[1])

    def test_an_unusable_floors_file_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            results = mt.load_results([self._results(Path(d))])
            path = Path(d) / "floors.json"
            with self.assertRaises(mt.MutationError):
                mt.check_floors(results, path)  # missing
            for text in ("{", '{"margin": 2.0}', '{"files": []}', '{"files": {"a": "90"}}',
                         '{"files": {"a": true}}'):
                path.write_text(text, encoding="utf-8")
                with self.assertRaises(mt.MutationError, msg=text):
                    mt.check_floors(results, path)
            path.write_text('{"files": {"src/x/Thing.sol": 80}}', encoding="utf-8")
            self.assertEqual(mt.check_floors(results, path), [])
            out, err = io.StringIO(), io.StringIO()
            path.write_text("{", encoding="utf-8")
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = mt.main(["report", d, "--floors", str(path)])
        self.assertEqual(code, 2)
        self.assertIn("no usable floors", err.getvalue())

    def test_written_floors_keep_the_floors_of_files_not_measured(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            results = mt.load_results([self._results(Path(d))])  # 91.2%
            path = Path(d) / "floors.json"
            path.write_text(
                json.dumps({"margin": 2.0, "files": {"src/a/Old.sol": 77, "src/x/Thing.sol": 50}}),
                encoding="utf-8",
            )
            mt.write_floors(results, path, 2.0)
            written = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(written["files"], {"src/a/Old.sol": 77, "src/x/Thing.sol": 89})

    def test_report_command_names_a_planned_shard_that_left_no_results(self) -> None:
        # Real shard names: the plan is checked against `tools/mutation.py list`.
        shard = mt.shards(ROOT)["libraries-Utf8"]
        r = mt.FileResult(shard.path, shards=[shard.name])
        r.total.update(tweak=2)
        r.caught.update(tweak=2)
        with tempfile.TemporaryDirectory() as d:
            self._write(Path(d), shard.name, r)
            out, err = io.StringIO(), io.StringIO()
            with contextlib.chdir(ROOT), contextlib.redirect_stdout(out), \
                    contextlib.redirect_stderr(err):
                ok = mt.main(["report", d, "--shards", '["libraries-Utf8"]'])
                missing = mt.main(["report", d, "--shards", "libraries-Utf8 libraries-SSTORE2"])
                unknown = mt.main(["report", d, "--shards", "libraries-Nothing"])
                # A run whose shards all failed has no results at all, and says which.
                none = mt.main(["report", str(Path(d) / "none"), "--shards", "libraries-Utf8"])
        self.assertEqual((ok, missing, unknown, none), (0, 1, 2, 1))
        self.assertIn(
            "src/libraries/SSTORE2.sol: missing: no results from libraries-SSTORE2", err.getvalue()
        )


if __name__ == "__main__":
    unittest.main()
