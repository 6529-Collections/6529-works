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
from types import SimpleNamespace

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
            expected = (
                len(mt.SPLIT_GROUPS) if f in mt.SPLIT_FILES
                else len(mt.FULL_SPLIT_GROUPS) if f in mt.FULL_SPLIT_FILES
                else 1
            ) + mt.RELATION_PARTS.get(f, 1) - 1
            expected += sum(n - 1 for n in mt.GROUP_PARTS.get(f, {}).values())
            self.assertEqual(len(mine), expected, f)
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

    def test_full_split_groups_cover_every_mutator_once_and_files_split_one_way(self) -> None:
        seen: set[str] = set()
        for g in (set(m.split(",")) for m in mt.FULL_SPLIT_GROUPS.values()):
            self.assertFalse(seen & g, g)
            seen |= g
        self.assertEqual(len(seen), 15)
        self.assertFalse(mt.SPLIT_FILES & mt.FULL_SPLIT_FILES)
        shards = mt.shards(ROOT)
        for f in mt.FULL_SPLIT_FILES:
            mine = {s.name: s for s in shards.values() if s.path == f}
            self.assertEqual(sorted(set(s.mutators for s in mine.values())),
                             sorted(mt.FULL_SPLIT_GROUPS.values()), f)
            # Only the statements group runs CONST, as on a four-way split file.
            self.assertEqual([s.name for s in mine.values() if s.constants],
                             [n for n in mine if n.endswith("-statements")], f)

    def test_relation_parts_split_one_relations_shard_into_disjoint_parts(self) -> None:
        shards = mt.shards(ROOT)
        self.assertTrue(mt.RELATION_PARTS)
        for f, n in mt.RELATION_PARTS.items():
            self.assertIn(f, mt.SPLIT_FILES | mt.FULL_SPLIT_FILES)
            ror = sorted((s for s in shards.values() if s.path == f and s.mutators == "ROR"),
                         key=lambda s: s.name)
            # One shard per part, no unparted relations shard, no CONST pass on a part.
            self.assertEqual([s.part for s in ror], [(k, n) for k in range(n)], f)
            self.assertFalse(any(s.constants for s in ror), f)
            self.assertEqual(
                [s.name for s in ror],
                [f"{mt._module(f)}-{Path(f).stem}-relations-{k + 1}-of-{n}" for k in range(n)],
            )
            # Every comparison, by its position in ROR's visit order, falls in exactly one part.
            for ordinal in range(500):
                self.assertEqual(sum(ordinal % s.part[1] == s.part[0] for s in ror), 1)
        # Every other shard is a whole file's shard, or a part of a group in GROUP_PARTS.
        self.assertTrue(all(s.part is None for s in shards.values()
                            if s.path not in mt.GROUP_PARTS
                            and (s.path not in mt.RELATION_PARTS or s.mutators != "ROR")))

    def test_group_parts_split_a_group_into_disjoint_parts_with_one_const_pass(self) -> None:
        shards = mt.shards(ROOT)
        self.assertTrue(mt.GROUP_PARTS)
        for f, groups in mt.GROUP_PARTS.items():
            self.assertIn(f, mt.SPLIT_FILES | mt.FULL_SPLIT_FILES)
            self.assertNotIn(f, mt.RELATION_PARTS)
            for group, n in groups.items():
                base = f"{mt._module(f)}-{Path(f).stem}-{group}"
                mine = [shards[f"{base}-{k + 1}-of-{n}"] for k in range(n)]
                self.assertNotIn(base, shards)  # no unparted shard beside the parts
                self.assertEqual([s.part for s in mine], [(k, n) for k in range(n)])
                # CONST runs once, with the first statements part.
                self.assertEqual([s.constants for s in mine],
                                 [group == "statements" and k == 0 for k in range(n)])
        # The parts of one operator's mutants are disjoint and together the whole list.
        patches = [{"start": 9 - i, "end": 20, "new_string": str(i)} for i in range(10)]
        parts = [mt.take_part(patches, (k, 3)) for k in range(3)]
        self.assertEqual(sorted(p["start"] for part in parts for p in part), list(range(10)))
        self.assertEqual([p["start"] for p in parts[0]], [0, 3, 6, 9])  # in source order

    def test_statement_parts_together_are_the_whole_group_when_a_revert_mutant_survives(
        self,
    ) -> None:
        # slither-mutate runs RR, then CR, and makes no CR mutant on a line where an RR mutant
        # survived. Eleven statements on lines 10 to 20; the revert mutant of line 10 survives.
        lines = list(range(10, 21))
        survives = {10}

        def patch(line: int, new: str) -> dict:
            return {"start": line * 100, "end": line * 100 + 9, "new_string": new,
                    "line_number": line}

        def node(line: int | None, file: str = "Thing.sol") -> SimpleNamespace:
            mapping = SimpleNamespace(
                lines=[] if line is None else [line], filename=SimpleNamespace(absolute=file)
            )
            return SimpleNamespace(source_mapping=mapping)

        # A statement of an inherited file and a node without lines are not counted.
        nodes = [node(n) for n in lines] + [node(3, "Base.sol"), node(None)]
        contract = SimpleNamespace(
            functions_and_modifiers_declared=[SimpleNamespace(nodes=nodes)]
        )

        def operators() -> tuple[type, type]:
            class Fake:
                def __init__(self, dont_mutate_line: list[int]) -> None:
                    self.contract = contract
                    self.in_file = "Thing.sol"
                    self.dont_mutate_line = dont_mutate_line

                def _mutate(self) -> dict:
                    made = [patch(n, self.NEW) for n in lines if n not in self.dont_mutate_line]
                    return {"patches": {"Thing.sol": made}} if made else {}

            return (type("RR", (Fake,), {"NAME": "RR", "NEW": "revert()"}),
                    type("CR", (Fake,), {"NAME": "CR", "NEW": "//"}))

        def campaign(part: tuple[int, int] | None) -> list[tuple[str, int]]:
            """The mutants one slither-mutate run tests, as (operator, line)."""
            rr, cr = operators()
            if part:
                mt.in_parts(rr, part)
                mt.in_parts(cr, part)
            dont_mutate: list[int] = []  # one list for the run, as in slither-mutate
            ran = []
            for operator in (rr, cr):
                made = operator(dont_mutate)._mutate().get("patches", {}).get("Thing.sol", [])
                for p in made:
                    ran.append((operator.NAME, p["line_number"]))
                    if operator.NAME == "RR" and p["line_number"] in survives:
                        dont_mutate.append(p["line_number"])
            return ran

        self.assertEqual(mt.statement_lines(operators()[0]([])), lines)
        whole = campaign(None)
        self.assertEqual(len(whole), 11 + 10)
        self.assertNotIn(("CR", 10), whole)
        for n in (2, 3, 10, 11, 12):
            merged = [m for k in range(n) for m in campaign((k, n))]
            self.assertEqual(sorted(merged), sorted(whole), n)  # none twice, none left out
        # Both mutants of a line run in the same part, and the parts are even.
        tenth = [campaign((k, 10)) for k in range(10)]
        self.assertEqual(tenth[0], [("RR", 10), ("RR", 20), ("CR", 20)])
        self.assertEqual(tenth[1], [("RR", 11), ("CR", 11)])
        # Cut by position in each operator's own list, the same run has line 11's comment mutant
        # in two parts (the first part's list starts at line 11, the second's at line 10) and
        # line 20's in none.
        by_position = []
        for k in range(10):
            cr_lines = [n for n in lines if not (n in survives and lines.index(n) % 10 == k)]
            by_position += [p["line_number"]
                            for p in mt.take_part([patch(n, "//") for n in cr_lines], (k, 10))]
        self.assertEqual(by_position.count(11), 2)
        self.assertNotIn(20, by_position)

    def test_take_line_part_cuts_by_line_and_keeps_every_patch_of_a_line_together(self) -> None:
        patches = [{"line_number": n, "new_string": s} for n in (7, 7, 9, 30, 31) for s in "ab"]
        lines = [31, 7, 9, 9, 30, 12]  # line 12 has a statement and no patch
        parts = [mt.take_line_part(patches, lines, (k, 2)) for k in range(2)]
        # Lines 7, 12 and 31 are the first, third and fifth: part 0. Lines 9 and 30: part 1.
        self.assertEqual([p["line_number"] for p in parts[0]], [7, 7, 7, 7, 31, 31])
        self.assertEqual([p["line_number"] for p in parts[1]], [9, 9, 30, 30])
        with self.assertRaises(KeyError):  # a patch on a line without a statement: not dropped
            mt.take_line_part([{"line_number": 99}], lines, (0, 2))

    def test_only_the_statement_operators_are_cut_by_line(self) -> None:
        self.assertEqual(set(mt.LINE_PARTED), set(mt.SPLIT_GROUPS["statements"].split(",")))

    def test_ror_part_reads_k_of_n(self) -> None:
        self.assertIsNone(mt.ror_part(""))
        self.assertEqual(mt.ror_part("2/4"), (2, 4))
        for bad in ("4/4", "-1/3"):
            with self.assertRaises(mt.MutationError):
                mt.ror_part(bad)

    def test_a_file_with_another_contract_is_mutated_once_per_contract(self) -> None:
        # slither-mutate alone would mutate only the contract named like the file.
        both = "abstract contract ThingBase {}\n// contract Gone {}\ncontract Thing is ThingBase {}\n"
        self.assertEqual(mt.mutation_targets(both, "Thing"), ["ThingBase", "Thing"])
        self.assertEqual(mt.mutation_targets("contract Thing {}\n", "Thing"), [None])
        self.assertEqual(mt.mutation_targets("library Other {}\n", "Thing"), ["Other"])
        self.assertEqual(mt.mutation_targets("interface IThing {}\n", "Thing"), [None])
        modules = (ROOT / "src" / "core" / "Modules.sol").read_text(encoding="utf-8")
        self.assertEqual(mt.mutation_targets(modules, "Modules"), ["ModuleSlots", "Modules"])
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source = root / "src" / "x" / "Thing.sol"
            source.parent.mkdir(parents=True)
            source.write_bytes(both.encode("utf-8"))
            seen = []

            def record(cmd, log, timeout=None, env=None):
                seen.append((cmd, env))
                log.write_text("INFO:Slither-Mutate:Done mutating.\n", encoding="utf-8")
                return 0

            real = mt._run_logged
            mt._run_logged = record
            try:
                shard = mt.Shard("x-Thing-operators-2-of-3", "src/x/Thing.sol", "test/x/**",
                                 "AOR,LOR,UOR", False, (1, 3))
                result = mt.FileResult(shard.path)
                mt.run_slither_mutate(root, shard, root, 60, result, mt.Deadline(None))
            finally:
                mt._run_logged = real
            self.assertEqual(result.status, "ok")
            # The build is cleaned between the two runs (the second would read the records the
            # first run's mutants left), in the default profile, and not before the first.
            self.assertEqual([cmd[-2:] for cmd, _ in seen].index(["forge", "clean"]), 1)
            self.assertIsNone(seen[1][1])
            self.assertEqual(len(seen), 3)
            seen = [seen[0], seen[2]]
            named = [cmd[cmd.index("--contract-names") + 1] for cmd, _ in seen]
            self.assertEqual(named, ["ThingBase", "Thing"])
            # A part of another group than relations reaches every operator but ROR.
            self.assertEqual([env[mt.PART_ENV] for _, env in seen], ["1/3", "1/3"])
            self.assertEqual([env[mt.ROR_PART_ENV] for _, env in seen], ["", ""])
            self.assertTrue((root / "slither-mutate-ThingBase.log").is_file())

    def test_a_target_that_did_not_finish_fails_the_shard_whatever_the_exit_code(self) -> None:
        # slither-mutate exits with 0 when its first test run outlasts --timeout: no mutant ran.
        both = "abstract contract ThingBase {}\ncontract Thing is ThingBase {}\n"
        finished = LOG.replace("Thing", "ThingBase")
        early = (
            "INFO:Slither-Mutate:Timing tests..\n"
            "INFO:Slither-Mutate:Provided timeout 60 is too short for tests that run in 75 "
            "seconds\n"
        )
        nothing_to_mutate = (
            "INFO:Slither-Mutate:Mutating contract Thing\n"
            "INFO:Slither-Mutate:Done mutating Thing.\n"
            "INFO:Slither-Mutate:Zero Revert mutants analyzed\n"
        )

        def status(logs: list[str], clean: int = 0) -> tuple[str, int]:
            with tempfile.TemporaryDirectory() as d:
                root = Path(d)
                source = root / "src" / "x" / "Thing.sol"
                source.parent.mkdir(parents=True)
                source.write_bytes(both.encode("utf-8"))
                texts = iter(logs)

                def run(cmd, log, timeout=None, env=None):
                    if cmd == ["forge", "clean"]:
                        return clean
                    log.write_text(next(texts), encoding="utf-8")
                    return 0

                real = mt._run_logged
                mt._run_logged = run
                try:
                    shard = mt.Shard("x-Thing", "src/x/Thing.sol", "test/x/**", None, True)
                    result = mt.FileResult(shard.path)
                    with contextlib.redirect_stderr(io.StringIO()) as err:
                        mt.run_slither_mutate(root, shard, root, 60, result, mt.Deadline(None))
                finally:
                    mt._run_logged = real
                if result.status == "error":
                    want = (
                        "`forge clean` before Thing failed" if clean
                        else "an operator failed for Thing" if mt.MUTATOR_FAILED in logs[-1]
                        else "did not finish Thing"
                    )
                    self.assertIn(want, err.getvalue())
                return result.status, result.mutants

        # The first target's 34 mutants would pass a floor on their own.
        self.assertEqual(status([finished, early]), ("error", 34))
        self.assertEqual(status([finished, ""]), ("error", 34))
        # A target that finished with nothing to mutate is fine.
        self.assertEqual(status([finished, nothing_to_mutate]), ("ok", 34))
        # A run that finished after one of its operators raised lacks that operator's mutants
        # (slither-mutate logs the failure and counts none for it): not a result either.
        failed_operator = (
            "INFO:Slither-Mutate:Mutating contract Thing\n"
            "ERROR:Slither-Mutate:CR mutator failed in Thing: 99\n" + LOG.split("\n", 2)[2]
        )
        self.assertIn(mt.COMPLETED, failed_operator)
        self.assertEqual(status([finished, failed_operator]), ("error", 34))
        # The second target is not run on a build that could not be cleaned.
        self.assertEqual(status([finished, nothing_to_mutate], clean=1), ("error", 34))
        # A file that is not `ok` fails the floor check by name, whatever its rate.
        failed = mt.FileResult("src/x/Thing.sol", status="error")
        failed.total["tweak"] = failed.caught["tweak"] = 34
        with tempfile.TemporaryDirectory() as d:
            floors = Path(d) / "floors.json"
            floors.write_text(json.dumps({"files": {"src/x/Thing.sol": 50}}), encoding="utf-8")
            self.assertEqual(mt.check_floors([failed], floors), ["src/x/Thing.sol: error"])

    def test_a_relations_part_reaches_slither_mutate_through_the_environment(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            source = root / "src" / "x" / "Thing.sol"
            source.parent.mkdir(parents=True)
            source.write_bytes(CONSTANTS.encode("utf-8"))
            seen = []

            def record(cmd, log, timeout=None, env=None):
                seen.append((cmd, env))
                log.write_text("", encoding="utf-8")
                return 1  # no summary: the shard reads as an error, which is fine here

            real = mt._run_logged
            mt._run_logged = record
            try:
                for part, want in (((1, 3), "1/3"), (None, "")):
                    shard = mt.Shard("x-Thing-relations", "src/x/Thing.sol", "test/x/**",
                                     "ROR", False, part)
                    with contextlib.redirect_stderr(io.StringIO()):
                        mt.run_slither_mutate(
                            root, shard, root, 60, mt.FileResult(shard.path), mt.Deadline(None)
                        )
                    self.assertEqual(seen[-1][1][mt.ROR_PART_ENV], want)
                    self.assertIn("ROR", seen[-1][0])
            finally:
                mt._run_logged = real

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
        # Finished with no mutants, yet a floor was recorded from mutants: nothing was measured.
        blank = mt.FileResult("src/x/Blank.sol")
        with tempfile.TemporaryDirectory() as d:
            floors = Path(d) / "floors.json"
            floors.write_text(
                json.dumps(
                    {"files": {"src/x/Thing.sol": 88, "src/x/Late.sol": 50, "src/x/Blank.sol": 90}}
                ),
                encoding="utf-8",
            )
            failures = mt.check_floors([thing, late, empty, new, blank], floors)
        self.assertEqual(len(failures), 3, failures)
        self.assertEqual(failures[0], "src/x/Late.sol: timeout")
        self.assertIn("src/x/New.sol: kill rate 75.0% and no floor", failures[1])
        self.assertEqual(failures[2], "src/x/Blank.sol: no mutants, though its floor is 90%")

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
