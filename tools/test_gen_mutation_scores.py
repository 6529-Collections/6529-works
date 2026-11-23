"""Unit tests for gen_mutation_scores.py, which sits beside this file.

Run with `python tools/test_gen_mutation_scores.py` or, from the repository root,
`python -m tools.test_gen_mutation_scores`.
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "gen_mutation_scores", Path(__file__).with_name("gen_mutation_scores.py")
)
gs = importlib.util.module_from_spec(_SPEC)
sys.modules["gen_mutation_scores"] = gs
_SPEC.loader.exec_module(gs)

ROOT = Path(__file__).resolve().parent.parent


def entry(tier: int, mutants: int, killed: int, new_kills: int = 0, floor: int | None = None,
          was: int | None = None, **more: object) -> dict:
    out = {"tier": tier, "mutants": mutants, "killed": killed, "timedOut": 0,
           "newKills": new_kills, "floor": floor, "was": was}
    out.update(more)
    return out


def row(line: int, verdict: str, why: str = "same value", rule: str = "ROR") -> dict:
    return {"line": line, "rule": rule, "verdict": verdict, "why": why}


def sample() -> dict:
    """A small consistent data file: one file per tier, one of them with nothing to mutate."""
    return {
        "margin": 2.0,
        "files": {
            "src/a/Core.sol": entry(1, 200, 196, new_kills=2, floor=97, was=95),
            "src/b/Sale.sol": entry(2, 100, 90, floor=88),
            "src/c/Types.sol": entry(3, 0, 0),
        },
        "survivors": {
            "src/a/Core.sol": [
                row(10, "equivalent"),
                row(12, "killed", "`test_A`: the bound was not pinned"),
                row(12, "killed", "`test_A`: the other bound"),
                row(30, "gas", "`a | b` costs less", rule="BOR"),
            ],
        },
        "addenda": {},
        "tests": [
            {"file": "test/a/Core.t.sol",
             "tests": [{"name": "test_A", "where": ["Core L12", "Core L12"]}]},
        ],
    }


PAGE = """# Scores

Hand-written.

<!-- generated:scores tier=1 -->
stale
<!-- /generated -->

Between.

<!-- generated:scores tier=2 -->
<!-- /generated -->
<!-- generated:scores tier=3 -->
<!-- /generated -->

## Tests

<!-- generated:tests -->
<!-- /generated -->

## Survivors

<!-- generated:survivors -->
<!-- /generated -->

The end.
"""


def run(argv: list[str]) -> tuple[int, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = gs.main(argv)
    return code, out.getvalue()


class FloorTest(unittest.TestCase):
    def test_floor_is_the_rate_minus_the_margin_rounded_down(self) -> None:
        self.assertEqual(gs.compute_floor(938, 1000, 2.0), 91)   # 93.8 - 2 = 91.8
        self.assertEqual(gs.compute_floor(93, 100, 2.0), 91)     # exactly 91
        self.assertEqual(gs.compute_floor(106, 114, 2.0), 90)    # 92.98..., shown as 93.0%
        self.assertEqual(gs.compute_floor(100, 100, 2.0), 98)
        self.assertEqual(gs.compute_floor(939, 1000, 2.5), 91)   # 93.9 - 2.5 = 91.4

    def test_floor_is_never_below_zero_and_none_without_mutants(self) -> None:
        self.assertEqual(gs.compute_floor(0, 10, 2.0), 0)
        self.assertIsNone(gs.compute_floor(0, 0, 2.0))

    def test_final_counts_the_new_kills_or_the_second_measurement(self) -> None:
        self.assertEqual(gs.final_counts(entry(1, 200, 196, new_kills=2)), (198, 200))
        again = entry(2, 1113, 1019, new_kills=27, remeasured={"mutants": 1112, "killed": 1045})
        self.assertEqual(gs.final_counts(again), (1045, 1112))
        self.assertEqual(gs.expected_floor(again, 2.0), 91)

    def test_a_consistent_data_file_validates(self) -> None:
        self.assertEqual(gs.validate(sample()), [])

    def test_a_floor_that_is_not_the_formula_fails(self) -> None:
        for wrong in (96, 98, None):
            data = sample()
            data["files"]["src/a/Core.sol"]["floor"] = wrong
            errors = gs.validate(data)
            self.assertEqual(len(errors), 1, errors)
            self.assertIn("src/a/Core.sol: floor", errors[0])
            self.assertIn("(97)", errors[0])
            with self.assertRaises(gs.DataError):
                gs.render_regions(data)

    def test_a_file_without_mutants_may_not_have_a_floor(self) -> None:
        data = sample()
        data["files"]["src/c/Types.sol"]["floor"] = 98
        self.assertIn("(none)", gs.validate(data)[0])

    def test_unknown_keys_fail(self) -> None:
        data = sample()
        data["files"]["src/b/Sale.sol"]["floorOverride"] = 80
        self.assertIn("unknown keys ['floorOverride']", gs.validate(data)[0])
        data = sample()
        data["extra"] = 1
        self.assertIn("unknown keys ['extra']", gs.validate(data)[0])

    def test_survivor_rows_must_match_the_counts(self) -> None:
        data = sample()
        data["survivors"]["src/a/Core.sol"].pop()
        self.assertIn("3 rows and 0 not triaged for 4 survivors", gs.validate(data)[0])
        data = sample()
        data["files"]["src/a/Core.sol"].update(newKills=1, floor=96)
        self.assertIn("2 rows are killed, but newKills is 1", gs.validate(data)[0])
        data = sample()
        data["survivors"]["src/x/Gone.sol"] = []
        self.assertIn("not in files", gs.validate(data)[0])


class RenderTest(unittest.TestCase):
    def test_scores_table_of_a_tier(self) -> None:
        text = gs.render_scores(sample()["files"], 1, 2.0)
        self.assertEqual(text, gs.SCORES_HEADER + (
            "| `src/a/Core.sol` | 200 | 196 | 4 | 0 | 98.0% | 2 | 99.0% | 97 (was 95) |\n"
            "| **Total** | **200** | **196** | **4** | **0** | **98.0%** | **2** | **99.0%** | |\n"
        ))

    def test_scores_rows_are_sorted_by_path_and_summed(self) -> None:
        files = {
            "src/z/Last.sol": entry(3, 10, 5, floor=48, was=48),
            "src/c/Types.sol": entry(3, 0, 0),
            "src/Z/Upper.sol": entry(3, 30, 30, floor=98),
        }
        lines = gs.render_scores(files, 3, 2.0).splitlines()[2:]
        self.assertEqual(lines, [
            "| `src/Z/Upper.sol` | 30 | 30 | 0 | 0 | 100.0% | 0 | 100.0% | 98 |",
            "| `src/c/Types.sol` | 0 | 0 | 0 | 0 | n/a | 0 | n/a | none |",
            "| `src/z/Last.sol` | 10 | 5 | 5 | 0 | 50.0% | 0 | 50.0% | 48 |",
            "| **Total** | **40** | **35** | **5** | **0** | **87.5%** | **0** | **87.5%** | |",
        ])

    def test_the_total_final_score_counts_a_second_measurement(self) -> None:
        files = {
            "src/a/Again.sol": entry(3, 100, 80, floor=88, remeasured={"mutants": 50, "killed": 45}),
            "src/b/Once.sol": entry(3, 100, 90, new_kills=5, floor=93),
        }
        total = gs.render_scores(files, 3, 2.0).splitlines()[-1]
        # The campaign's columns sum the rows; the final score is (45 + 95) of (50 + 100).
        self.assertEqual(
            total, "| **Total** | **200** | **170** | **30** | **0** | **85.0%** | **5** | **93.3%** | |"
        )

    def test_a_second_measurement_is_the_final_score(self) -> None:
        files = {"src/b/Sale.sol": entry(2, 1134, 994, floor=85, was=87,
                                         remeasured={"mutants": 1113, "killed": 979})}
        self.assertIn(
            "| `src/b/Sale.sol` | 1134 | 994 | 140 | 0 | 87.7% | 0 | 88.0% (measured again) "
            "| 85 (was 87) |\n",
            gs.render_scores(files, 2, 2.0),
        )

    def test_an_empty_tier_has_only_the_totals(self) -> None:
        lines = gs.render_scores({}, 2, 2.0).splitlines()
        self.assertEqual(lines[2:], ["| **Total** | **0** | **0** | **0** | **0** | **n/a** "
                                     "| **0** | **n/a** | |"])

    def test_tests_list_counts_every_entry(self) -> None:
        tests = [
            {"file": "test/a/A.t.sol", "tests": [
                {"name": "test_One", "where": ["A L1"]},
                {"name": "test_Two (also test_Three in test/b/B.t.sol)", "where": ["A L2", "B L9"]},
            ]},
            {"file": "test/b/B.t.sol", "tests": [{"name": "test_One", "where": ["B L4"]}]},
        ]
        self.assertEqual(gs.render_tests(tests), (
            "3 test functions, each shown to fail on the mutants it is listed with:\n"
            "\n"
            "- `test/a/A.t.sol`\n"
            "  - `test_One` (A L1)\n"
            "  - `test_Two (also test_Three in test/b/B.t.sol)` (A L2, B L9)\n"
            "- `test/b/B.t.sol`\n"
            "  - `test_One` (B L4)\n"
        ))
        self.assertEqual(gs.render_tests([]), "")

    def test_a_malformed_shape_is_reported_not_raised(self) -> None:
        self.assertIn("not a map", gs.validate(None)[0])
        self.assertIn("not a map", gs.validate([])[0])
        for key, value in (("survivors", None), ("addenda", []), ("tests", {})):
            data = sample()
            data[key] = value
            self.assertIn(f"{key} is not a", gs.validate(data)[0], key)
        data = sample()
        data["files"]["src/b/Sale.sol"] = None
        self.assertIn("src/b/Sale.sol: the entry is not a map", gs.validate(data))
        data = sample()
        data["survivors"]["src/a/Core.sol"] = None
        self.assertIn("not a list of rows", gs.validate(data)[0])

    def test_summary_counts_the_survivors_left_without_a_row(self) -> None:
        rows = [row(1, "equivalent"), row(2, "killed")]
        self.assertEqual(
            gs.survivor_summary(rows, 3), "5 survivors: 1 equivalent, 1 killed, 3 not triaged."
        )

    def test_summary_lists_verdicts_in_order_of_first_appearance(self) -> None:
        rows = [row(1, "killed"), row(2, "equivalent"), row(3, "equivalent"), row(4, "gas"),
                row(5, "killed")]
        self.assertEqual(gs.survivor_summary(rows), "5 survivors: 2 killed, 2 equivalent, 1 gas.")

    def test_survivors_sections_by_tier_then_path_with_addenda(self) -> None:
        data = sample()
        data["files"]["src/b/Sale.sol"].update(killed=99, floor=97)
        data["survivors"]["src/b/Sale.sol"] = [row(7, "open", "no test yet", rule="CR")]
        data["survivors"]["src/c/Types.sol"] = []
        data["addenda"]["src/a/Core.sol"] = [
            {"text": ["Measured again:", "one more."]},
            {"rows": [row(40, "killed", "`test_B`: later")]},
        ]
        self.assertEqual(gs.validate(data), [])
        text = gs.render_survivors(data["files"], data["survivors"], data["addenda"])
        self.assertEqual(text, (
            "### `src/a/Core.sol`\n"
            "\n"
            "4 survivors: 1 equivalent, 2 killed, 1 gas.\n"
            "\n"
            "| Line | Rule | Verdict | Why, or the test |\n"
            "| ---: | --- | --- | --- |\n"
            "| 10 | ROR | equivalent | same value |\n"
            "| 12 | ROR | killed | `test_A`: the bound was not pinned |\n"
            "| 12 | ROR | killed | `test_A`: the other bound |\n"
            "| 30 | BOR | gas | `a \\| b` costs less |\n"
            "\n"
            "Measured again:\n"
            "one more.\n"
            "\n"
            "| Line | Rule | Verdict | Why, or the test |\n"
            "| ---: | --- | --- | --- |\n"
            "| 40 | ROR | killed | `test_B`: later |\n"
            "\n"
            "### `src/b/Sale.sol`\n"
            "\n"
            "1 survivors: 1 open.\n"
            "\n"
            "| Line | Rule | Verdict | Why, or the test |\n"
            "| ---: | --- | --- | --- |\n"
            "| 7 | CR | open | no test yet |\n"
        ))

    def test_a_pipe_in_a_cell_is_escaped(self) -> None:
        self.assertEqual(gs.escape_cell("`|=` equals `+=`"), "`\\|=` equals `+=`")
        self.assertEqual(gs.escape_cell("two\nlines"), "two lines")
        table = gs.render_survivor_table([row(1, "equivalent", "`^` equals `|`")])
        self.assertTrue(table.endswith("| 1 | ROR | equivalent | `^` equals `\\|` |\n"))


class RegionTest(unittest.TestCase):
    def test_pieces_join_back_to_the_page(self) -> None:
        pieces = gs.parse_regions(PAGE)
        self.assertEqual("".join(text for _, text in pieces), PAGE)
        self.assertEqual([name for name, _ in pieces if name], list(gs.REGIONS))
        self.assertEqual(dict((n, t) for n, t in pieces if n)["scores tier=1"], "stale\n")

    def test_regenerate_rewrites_only_what_is_between_the_markers(self) -> None:
        data = sample()
        text = gs.regenerate(PAGE, data)
        self.assertNotIn("stale", text)
        for kept in ("# Scores\n\nHand-written.\n\n<!-- generated:scores tier=1 -->\n\n| Contract",
                     "| |\n\n<!-- /generated -->\n\nBetween.\n",
                     "<!-- generated:tests -->\n\n1 test functions",
                     "(Core L12, Core L12)\n\n<!-- /generated -->\n\n## Survivors\n",
                     "costs less |\n\n<!-- /generated -->\n\nThe end.\n"):
            self.assertIn(kept, text)
        self.assertEqual(gs.regenerate(text, data), text)

    def test_an_empty_region_is_one_blank_line(self) -> None:
        data = sample()
        data["tests"] = []
        self.assertIn("<!-- generated:tests -->\n\n<!-- /generated -->\n", gs.regenerate(PAGE, data))

    def assert_marker_error(self, page: str, message: str) -> None:
        with self.assertRaises(gs.DataError) as caught:
            gs.parse_regions(page)
        self.assertIn(message, str(caught.exception))

    def test_a_missing_region_fails(self) -> None:
        page = PAGE.replace("<!-- generated:tests -->\n<!-- /generated -->\n", "")
        self.assert_marker_error(page, "no marker for `tests`")

    def test_an_unclosed_region_fails(self) -> None:
        page = PAGE.replace("<!-- generated:survivors -->\n<!-- /generated -->\n",
                            "<!-- generated:survivors -->\n")
        self.assert_marker_error(page, "region `survivors` is never closed")

    def test_a_region_opened_inside_another_fails(self) -> None:
        page = PAGE.replace("stale\n<!-- /generated -->\n", "stale\n")
        self.assert_marker_error(page, "`scores tier=2` opens inside `scores tier=1`")

    def test_a_stray_closing_marker_fails(self) -> None:
        self.assert_marker_error(PAGE + "<!-- /generated -->\n", "closing marker with no region open")

    def test_a_repeated_region_fails(self) -> None:
        page = PAGE + "<!-- generated:tests -->\n<!-- /generated -->\n"
        self.assert_marker_error(page, "region `tests` appears twice")

    def test_unknown_and_malformed_markers_fail(self) -> None:
        self.assert_marker_error(PAGE + "<!-- generated:floors -->\n", "unknown region `floors`")
        self.assert_marker_error(PAGE + "<!--generated:tests-->\n", "malformed marker")
        self.assert_marker_error(PAGE + "  <!-- /generated -->\n", "malformed marker")


class FloorsFileTest(unittest.TestCase):
    def test_floors_leave_out_files_without_one(self) -> None:
        self.assertEqual(gs.floors_from(sample()), {"src/a/Core.sol": 97, "src/b/Sale.sol": 88})

    def test_mismatches_are_named(self) -> None:
        data = sample()
        agreed = {"margin": 2.0, "files": gs.floors_from(data)}
        self.assertEqual(gs.floor_mismatches(data, agreed), [])
        floors = {"margin": 3.0, "files": {"src/a/Core.sol": 96, "src/c/Types.sol": 98,
                                           "src/x/Gone.sol": 50}}
        self.assertEqual(gs.floor_mismatches(data, floors), [
            "margin is 3.0 there and 2.0 in the data",
            "src/a/Core.sol: floor 97 in the data, 96 there",
            "src/b/Sale.sol: floor 88 in the data, none there",
            "src/c/Types.sol: floor 98 there, but the file has no floor in the data",
            "src/x/Gone.sol: floor 50 there, but the file is not in the data",
        ])

    def test_writing_keeps_the_other_keys(self) -> None:
        old = {"margin": 2.0, "pending": ["src/x/New.sol"], "pendingNote": "next run",
               "files": {"src/x/Gone.sol": 50}}
        new = gs.updated_floors(sample(), old)
        self.assertEqual(list(new), ["margin", "pending", "pendingNote", "files"])
        self.assertEqual(new["pending"], ["src/x/New.sol"])
        self.assertEqual(new["files"], {"src/a/Core.sol": 97, "src/b/Sale.sol": 88})


def report_row(mutants: int, killed: int, timeouts: int = 0, status: str = "ok") -> dict:
    rate = None if mutants == 0 else 100.0 * killed / mutants
    return {"mutants": mutants, "killed": killed, "kill_rate": rate, "timeouts": timeouts,
            "status": status, "shards": ["x"], "missing_shards": [], "not_rechecked": 0}


class MergeTest(unittest.TestCase):
    def test_a_measured_file_starts_afresh(self) -> None:
        data = sample()
        data["files"]["src/a/Core.sol"]["remeasured"] = {"mutants": 200, "killed": 198}
        data["addenda"]["src/a/Core.sol"] = [{"text": ["A note."]}]
        before = copy.deepcopy(data)
        merged = gs.merge_report(data, {"src/a/Core.sol": report_row(210, 190, timeouts=3)}, "abc1234")
        self.assertEqual(data, before, "the input is not changed")
        self.assertEqual(merged["files"]["src/a/Core.sol"], {
            "tier": 1, "mutants": 210, "killed": 190, "timedOut": 3, "newKills": 0,
            "floor": 88, "was": 97, "measuredAt": "abc1234",
        })
        self.assertNotIn("src/a/Core.sol", merged["survivors"])
        self.assertNotIn("src/a/Core.sol", merged["addenda"])
        self.assertEqual(merged["files"]["src/b/Sale.sol"], before["files"]["src/b/Sale.sol"])
        self.assertEqual(merged["tests"], before["tests"])
        self.assertEqual(gs.validate(merged), [])
        self.assertIn("| 88 (was 97) |", gs.render_scores(merged["files"], 1, 2.0))

    def test_without_a_commit_none_is_recorded(self) -> None:
        data = sample()
        data["files"]["src/b/Sale.sol"]["measuredAt"] = "old"
        merged = gs.merge_report(data, {"src/b/Sale.sol": report_row(100, 90)})
        self.assertNotIn("measuredAt", merged["files"]["src/b/Sale.sol"])
        self.assertEqual(merged["files"]["src/b/Sale.sol"]["was"], 88)
        self.assertIn("| 90.0% | 88 |", gs.render_scores(merged["files"], 2, 2.0),
                      "an unchanged floor shows no earlier one")

    def test_a_file_can_gain_or_lose_its_mutants(self) -> None:
        merged = gs.merge_report(sample(), {"src/c/Types.sol": report_row(4, 4),
                                            "src/b/Sale.sol": report_row(0, 0)})
        self.assertEqual(merged["files"]["src/c/Types.sol"]["floor"], 98)
        self.assertIsNone(merged["files"]["src/c/Types.sol"]["was"])
        self.assertIsNone(merged["files"]["src/b/Sale.sol"]["floor"])
        self.assertEqual(merged["files"]["src/b/Sale.sol"]["was"], 88)
        self.assertEqual(gs.validate(merged), [])

    def test_an_unfinished_or_unknown_file_refuses_the_whole_merge(self) -> None:
        report = {"src/a/Core.sol": report_row(210, 190),
                  "src/b/Sale.sol": report_row(50, 40, status="timeout"),
                  "src/x/New.sol": report_row(5, 5)}
        with self.assertRaises(gs.DataError) as caught:
            gs.merge_report(sample(), report)
        message = str(caught.exception)
        self.assertIn("src/b/Sale.sol: status is 'timeout'", message)
        self.assertIn("src/x/New.sol: not in tools/mutation-scores.json", message)
        self.assertNotIn("src/a/Core.sol", message)


class DumpTest(unittest.TestCase):
    def test_keys_come_out_in_a_fixed_order(self) -> None:
        data = sample()
        shuffled = {key: data[key] for key in reversed(list(data))}
        shuffled["files"] = {
            path: {key: e[key] for key in reversed(list(e))}
            for path, e in reversed(list(data["files"].items()))
        }
        text = gs.dump_data(shuffled)
        self.assertEqual(text, gs.dump_data(data))
        self.assertTrue(text.endswith("}\n"))
        self.assertEqual(list(json.loads(text)), list(gs.TOP_KEYS))
        self.assertEqual(list(json.loads(text)["files"]["src/a/Core.sol"]), list(gs.FILE_KEYS))
        self.assertTrue(text.startswith('{\n  "margin": 2.0,\n  "files": {\n'))


class CommandTest(unittest.TestCase):
    """main() on a small repository in a temporary directory."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        data = sample()
        self.put(gs.DATA, gs.dump_data(data))
        self.put(gs.PAGE, gs.regenerate(PAGE, data))
        self.put(gs.FLOORS, json.dumps(
            {"margin": 2.0, "pendingNote": "kept", "files": gs.floors_from(data)}, indent=2) + "\n")

    def put(self, relative: str, text: str) -> None:
        path = self.tmp / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)

    def get(self, relative: str) -> str:
        return (self.tmp / relative).read_bytes().decode("utf-8")

    def data(self) -> dict:
        return json.loads(self.get(gs.DATA))

    def test_check_is_clean_when_everything_agrees(self) -> None:
        code, out = run(["--root", str(self.tmp), "--check"])
        self.assertEqual((code, out.count("\n")), (0, 1), out)

    def test_check_fails_on_a_stale_page_and_writes_nothing(self) -> None:
        self.put(gs.PAGE, PAGE)
        code, out = run(["--root", str(self.tmp), "--check"])
        self.assertEqual(code, 1)
        self.assertIn("-stale", out)
        self.assertIn("is not current", out)
        self.assertEqual(self.get(gs.PAGE), PAGE)

    def test_a_missing_or_unparsable_file_fails_with_its_path(self) -> None:
        for relative in (gs.DATA, gs.PAGE, gs.FLOORS):
            kept = self.get(relative)
            (self.tmp / relative).unlink()
            code, out = run(["--root", str(self.tmp), "--check"])
            self.assertEqual(code, 1, relative)
            self.assertIn(relative, out)
            self.assertIn("cannot be read", out)
            self.put(relative, kept)
        for relative in (gs.DATA, gs.FLOORS):
            kept = self.get(relative)
            self.put(relative, "{ not json")
            code, out = run(["--root", str(self.tmp), "--check"])
            self.assertEqual(code, 1, relative)
            self.assertIn(f"{relative}: not JSON", out)
            self.put(relative, kept)
        self.assertEqual(run(["--root", str(self.tmp), "--check"])[0], 0)

    def test_the_writing_modes_fail_cleanly_on_bad_input(self) -> None:
        page, floors = self.get(gs.PAGE), self.get(gs.FLOORS)
        self.put(gs.DATA, "[]")
        code, out = run(["--root", str(self.tmp), "--write-floors"])
        self.assertEqual(code, 1)
        self.assertIn(f"FAIL {gs.DATA}: the data is not a map", out)
        self.put(gs.DATA, gs.dump_data(sample()))
        report = self.tmp / "report.json"
        for text, message in (("{ not json", "not JSON"), ("[1]", "not a map of file to result")):
            self.put("report.json", text)
            code, out = run(["--root", str(self.tmp), "--merge", str(report)])
            self.assertEqual(code, 1, text)
            self.assertIn(message, out)
        code, out = run(["--root", str(self.tmp), "--merge", str(self.tmp / "absent.json")])
        self.assertEqual(code, 1)
        self.assertIn("cannot be read", out)
        self.put(gs.FLOORS, "{ not json")
        code, out = run(["--root", str(self.tmp), "--write-floors"])
        self.assertEqual(code, 1)
        self.assertIn(f"{gs.FLOORS}: not JSON", out)
        self.assertEqual(self.get(gs.PAGE), page)
        self.put(gs.FLOORS, floors)

    def test_check_fails_on_a_broken_marker(self) -> None:
        self.put(gs.PAGE, self.get(gs.PAGE).replace("<!-- generated:tests -->\n", ""))
        code, out = run(["--root", str(self.tmp), "--check"])
        self.assertEqual(code, 1)
        self.assertIn("closing marker with no region open", out)

    def test_check_fails_on_an_inconsistent_floor(self) -> None:
        data = self.data()
        data["files"]["src/b/Sale.sol"]["floor"] = 89
        self.put(gs.DATA, gs.dump_data(data))
        code, out = run(["--root", str(self.tmp), "--check"])
        self.assertEqual(code, 1)
        self.assertIn("src/b/Sale.sol: floor 89 is not the final score 90.0% minus 2 points", out)

    def test_check_fails_when_the_floors_file_differs(self) -> None:
        floors = json.loads(self.get(gs.FLOORS))
        floors["files"]["src/a/Core.sol"] = 90
        floors["files"]["src/c/Types.sol"] = 98
        self.put(gs.FLOORS, json.dumps(floors, indent=2) + "\n")
        code, out = run(["--root", str(self.tmp), "--check"])
        self.assertEqual(code, 1)
        self.assertIn("src/a/Core.sol: floor 97 in the data, 90 there", out)
        self.assertIn("src/c/Types.sol: floor 98 there, but the file has no floor in the data", out)

    def test_default_rewrites_the_page(self) -> None:
        current = self.get(gs.PAGE)
        self.put(gs.PAGE, PAGE)
        code, _ = run(["--root", str(self.tmp)])
        self.assertEqual(code, 0)
        self.assertEqual(self.get(gs.PAGE), current)
        self.assertNotIn("\r", current)

    def test_an_inconsistent_floor_writes_nothing(self) -> None:
        data = self.data()
        data["files"]["src/b/Sale.sol"]["floor"] = 89
        self.put(gs.DATA, gs.dump_data(data))
        self.put(gs.PAGE, PAGE)
        code, out = run(["--root", str(self.tmp), "--write-floors"])
        self.assertEqual(code, 1)
        self.assertIn(f"FAIL {gs.DATA}: src/b/Sale.sol: floor 89", out)
        self.assertEqual(self.get(gs.PAGE), PAGE)

    def test_write_floors_keeps_the_other_keys(self) -> None:
        floors = json.loads(self.get(gs.FLOORS))
        floors["files"] = {"src/x/Gone.sol": 50}
        self.put(gs.FLOORS, json.dumps(floors, indent=2) + "\n")
        self.assertEqual(run(["--root", str(self.tmp), "--write-floors"])[0], 0)
        written = json.loads(self.get(gs.FLOORS))
        self.assertEqual(written, {"margin": 2.0, "pendingNote": "kept",
                                   "files": {"src/a/Core.sol": 97, "src/b/Sale.sol": 88}})
        self.assertTrue(self.get(gs.FLOORS).endswith("\n}\n"))
        self.assertEqual(run(["--root", str(self.tmp), "--check"])[0], 0)

    def test_merge_updates_the_data_the_page_and_on_request_the_floors(self) -> None:
        self.put("report.json", json.dumps({"src/a/Core.sol": report_row(210, 190)}))
        report = str(self.tmp / "report.json")
        code, out = run(["--root", str(self.tmp), "--merge", report, "--commit", "abc1234"])
        self.assertEqual(code, 0, out)
        self.assertEqual(self.data()["files"]["src/a/Core.sol"]["measuredAt"], "abc1234")
        self.assertEqual(self.data()["survivors"], {})
        page = self.get(gs.PAGE)
        self.assertIn("| `src/a/Core.sol` | 210 | 190 | 20 | 0 | 90.5% | 0 | 90.5% | 88 (was 97) |", page)
        self.assertNotIn("### `src/a/Core.sol`", page)
        self.assertNotIn("abc1234", page)
        self.assertIn("1 test functions", page)
        code, out = run(["--root", str(self.tmp), "--check"])
        self.assertEqual(code, 1)
        self.assertIn("src/a/Core.sol: floor 88 in the data, 97 there", out)
        self.assertEqual(run(["--root", str(self.tmp), "--write-floors"])[0], 0)
        self.assertEqual(run(["--root", str(self.tmp), "--check"])[0], 0)

    def test_a_refused_merge_writes_nothing(self) -> None:
        before = (self.get(gs.DATA), self.get(gs.PAGE), self.get(gs.FLOORS))
        self.put("report.json", json.dumps({"src/a/Core.sol": report_row(210, 190, status="missing")}))
        code, out = run(["--root", str(self.tmp), "--merge", str(self.tmp / "report.json"),
                         "--write-floors"])
        self.assertEqual(code, 1)
        self.assertIn("FAIL src/a/Core.sol: status is 'missing'", out)
        self.assertEqual((self.get(gs.DATA), self.get(gs.PAGE), self.get(gs.FLOORS)), before)


class CommittedFilesTest(unittest.TestCase):
    def test_the_committed_page_data_and_floors_are_in_sync(self) -> None:
        self.assertEqual(gs.check(ROOT), [])

    def test_the_committed_data_file_is_in_its_canonical_form(self) -> None:
        text = (ROOT / gs.DATA).read_bytes().decode("utf-8")
        self.assertEqual(gs.dump_data(json.loads(text)), text)

    def test_the_committed_page_counts_its_tests(self) -> None:
        data = json.loads((ROOT / gs.DATA).read_text(encoding="utf-8"))
        count = sum(len(group["tests"]) for group in data["tests"])
        page = (ROOT / gs.PAGE).read_text(encoding="utf-8")
        self.assertIn(f"\n{count} test functions, each shown to fail", page)


if __name__ == "__main__":
    unittest.main()
