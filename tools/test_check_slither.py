"""Unit tests for check_slither.py, which sits beside this file.

Run with `python tools/test_check_slither.py` or, from the repository root,
`python -m tools.test_check_slither`. No Slither installation is needed: reports are
synthetic but follow the shape of Slither 0.11 `--json` output.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import shutil
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "check_slither", Path(__file__).with_name("check_slither.py")
)
cs = importlib.util.module_from_spec(_SPEC)
sys.modules["check_slither"] = cs  # dataclasses resolve annotations through sys.modules
_SPEC.loader.exec_module(cs)

UTF8 = "src/libraries/Utf8.sol"
VAULT = "src/economics/Vault.sol"
SRC_FILES = (UTF8, VAULT)


def contract(name: str, file: str) -> dict:
    return {"type": "contract", "name": name, "source_mapping": {"filename_relative": file}}


def function(name: str, owner: str, file: str) -> dict:
    return {
        "type": "function",
        "name": name,
        "source_mapping": {"filename_relative": file},
        "type_specific_fields": {"parent": contract(owner, file)},
    }


def node(statement: str, parent: dict, file: str) -> dict:
    return {
        "type": "node",
        "name": statement,
        "source_mapping": {"filename_relative": file},
        "type_specific_fields": {"parent": parent},
    }


def finding(check: str, impact: str, *elements: dict, description: str = "a finding\nmore") -> dict:
    return {
        "check": check,
        "impact": impact,
        "confidence": "High",
        "description": description,
        "elements": list(elements),
    }


def compilations(*files: str, contracts: int = 1) -> list[dict]:
    """The results.compilations block Slither writes: analysed source units by relative path."""
    units = {
        name: {"ast": {}, "contracts": {f"C{index}": {} for index in range(contracts)}}
        for name in files
    }
    return [{"compilation_units": {"abc123": {"compiler": {}, "source_units": units, "filenames": []}}}]


def report(*findings: dict, files: tuple[str, ...] | None = SRC_FILES) -> dict:
    """A Slither report; `files=None` omits the compilation data."""
    results: dict = {"detectors": list(findings)}
    if files is not None:
        results["compilations"] = compilations(*files)
    return {"success": True, "error": None, "results": results}


def clean_report() -> dict:
    """What Slither writes for a tree with no findings at all: `results` without `detectors`."""
    return {"success": True, "error": None, "results": {"compilations": compilations(*SRC_FILES)}}


def shift_finding() -> dict:
    fn = function("validate", "Utf8", UTF8)
    return finding("incorrect-shift", "High", fn, node("x >> 1", fn, UTF8))


def evaluate(
    slither: object, triage: str = "", src_files: set[str] | None = None
) -> tuple[int, str]:
    rows, errors = cs.parse_triage(textwrap.dedent(triage))
    assert not errors, errors
    out = cs.Report()
    cs.evaluate(slither, rows, "slither-triage.md", out, src_files)
    return out.failures, out.render()


class ParseTriageTest(unittest.TestCase):
    def test_header_separator_prose_and_fenced_examples_are_skipped(self) -> None:
        rows, errors = cs.parse_triage(
            textwrap.dedent(
                """\
                # Title

                Some prose with a | pipe.

                ```markdown
                | example | src/A.sol:A.f | false-positive | not a real row |
                ```

                | Detector | Location | Disposition | Reason |
                | --- | --- | :---: | --- |
                | `incorrect-shift` | `src/libraries/Utf8.sol:Utf8.validate` | false-positive | Yul order. |
                | `reentrancy-eth` | `src/economics/Vault.sol` | accepted | Guarded elsewhere. |
                """
            )
        )
        self.assertEqual(errors, [])
        self.assertEqual([row.detector for row in rows], ["incorrect-shift", "reentrancy-eth"])
        self.assertEqual(rows[0].location, cs.Location(UTF8, "Utf8", "validate"))
        self.assertEqual(rows[1].location, cs.Location(VAULT))
        self.assertEqual(rows[1].disposition, "accepted")
        self.assertEqual(str(rows[0].location), "src/libraries/Utf8.sol:Utf8.validate")

    def test_malformed_rows_are_errors_not_silently_ignored(self) -> None:
        cases = {
            "too few cells": "| unused-return | src/A.sol:A | false-positive |",
            "too many cells": "| unused-return | src/A.sol:A | false-positive | why | extra |",
            "bad disposition": "| unused-return | src/A.sol:A | ignored | why |",
            "typo in disposition": "| unused-return | src/A.sol:A | false positive | why |",
            "empty reason": "| unused-return | src/A.sol:A | false-positive |   |",
            "bad detector": "| Unused Return | src/A.sol:A | false-positive | why |",
            "not a solidity file": "| unused-return | src/A.txt | false-positive | why |",
            "line number location": "| unused-return | src/A.sol#L10 | false-positive | why |",
            "function without contract": "| unused-return | src/A.sol:.f | false-positive | why |",
        }
        for name, row in cases.items():
            with self.subTest(name):
                rows, errors = cs.parse_triage(row)
                self.assertEqual(rows, [])
                self.assertEqual(len(errors), 1)
                self.assertTrue(errors[0].startswith("line 1:"), errors)

    def test_errors_carry_the_line_number(self) -> None:
        _, errors = cs.parse_triage("\n\n| unused-return | src/A.sol | ignored | why |\n")
        self.assertTrue(errors[0].startswith("line 3:"), errors)


class LocationTest(unittest.TestCase):
    def test_function_node_variable_and_contract_elements(self) -> None:
        fn = function("withdraw", "Vault", VAULT)
        self.assertEqual(cs.element_location(fn), cs.Location(VAULT, "Vault", "withdraw"))
        self.assertEqual(
            cs.element_location(node("x = 1", fn, VAULT)), cs.Location(VAULT, "Vault", "withdraw")
        )
        local = {"type": "variable", "name": "x", "source_mapping": fn["source_mapping"],
                 "type_specific_fields": {"parent": fn}}
        self.assertEqual(cs.element_location(local), cs.Location(VAULT, "Vault", "withdraw"))
        state = {"type": "variable", "name": "owner", "source_mapping": fn["source_mapping"],
                 "type_specific_fields": {"parent": contract("Vault", VAULT)}}
        self.assertEqual(cs.element_location(state), cs.Location(VAULT, "Vault"))
        self.assertEqual(cs.element_location(contract("Vault", VAULT)), cs.Location(VAULT, "Vault"))

    def test_windows_separators_are_normalised_and_junk_is_ignored(self) -> None:
        fn = function("f", "A", "src\\A.sol")
        self.assertEqual(cs.element_location(fn), cs.Location("src/A.sol", "A", "f"))
        for junk in (None, 7, "x", {}, {"type": "function", "name": "f"}, []):
            self.assertIsNone(cs.element_location(junk))

    def test_first_in_scope_element_with_a_location_decides(self) -> None:
        located = function("f", "A", "src/A.sol")
        self.assertEqual(
            cs.finding_location({"elements": [{"type": "pragma"}, located, function("g", "B", "src/B.sol")]}),
            cs.Location("src/A.sol", "A", "f"),
        )
        in_lib = function("h", "L", "lib/dep/L.sol")
        self.assertEqual(
            cs.finding_location({"elements": [in_lib, located]}), cs.Location("src/A.sol", "A", "f")
        )
        self.assertIsNone(cs.finding_location({"elements": [in_lib]}))
        self.assertIsNone(cs.finding_location({"elements": []}))
        self.assertIsNone(cs.finding_location({}))
        self.assertIsNone(cs.finding_location({"elements": "junk"}))

    def test_scope_is_the_first_segment_of_the_relative_path(self) -> None:
        for out_of_scope in ("lib/forge-std/src/Test.sol", "test/A.t.sol", "script/Deploy.s.sol", "./lib/x.sol"):
            self.assertFalse(cs.in_scope(out_of_scope), out_of_scope)
        for in_scope in (
            "src/A.sol",
            "src/lib/A.sol",
            "src/test/A.sol",
            "library/A.sol",
            "libs/A.sol",
            "tests/A.sol",
            "scripts/A.sol",
            "content-attest/A.sol",
            "lib.sol",
        ):
            self.assertTrue(cs.in_scope(in_scope), in_scope)

    def test_cyclic_parents_terminate(self) -> None:
        loop: dict = {"type": "node", "name": "n", "source_mapping": {"filename_relative": "src/A.sol"}}
        loop["type_specific_fields"] = {"parent": loop}
        self.assertEqual(cs.element_location(loop), cs.Location("src/A.sol"))


class EvaluateTest(unittest.TestCase):
    ROW = "| incorrect-shift | src/libraries/Utf8.sol:Utf8.validate | false-positive | Yul order. |"

    def test_no_findings_passes(self) -> None:
        failures, out = evaluate(report())
        self.assertEqual(failures, 0)
        self.assertIn("0 High/Medium findings gated; not gated: none", out)

    def test_dispositioned_high_finding_passes(self) -> None:
        failures, out = evaluate(report(shift_finding()), self.ROW)
        self.assertEqual(failures, 0, out)
        self.assertIn(
            "ok   incorrect-shift (High) at src/libraries/Utf8.sol:Utf8.validate: false-positive",
            out,
        )

    def test_undispositioned_high_and_medium_findings_fail(self) -> None:
        fn = function("pay", "Vault", VAULT)
        slither = report(
            shift_finding(),
            finding("reentrancy-eth", "High", fn, description="Reentrancy in Vault.pay()\ndetails"),
            finding("unused-return", "Medium", fn),
        )
        failures, out = evaluate(slither)
        self.assertEqual(failures, 3, out)
        self.assertIn(
            "FAIL reentrancy-eth (High) at src/economics/Vault.sol:Vault.pay: not dispositioned"
            " in slither-triage.md",
            out,
        )
        self.assertIn("     Reentrancy in Vault.pay()", out)
        self.assertNotIn("details", out)
        self.assertIn("FAIL unused-return (Medium)", out)

    def test_lower_impacts_are_counted_but_never_gate(self) -> None:
        fn = function("f", "A", "src/A.sol")
        slither = report(
            finding("assembly", "Informational", fn),
            finding("assembly", "Informational", fn),
            finding("low-level-calls", "Low", fn),
            finding("costly-loop", "Optimization", fn),
        )
        failures, out = evaluate(slither)
        self.assertEqual(failures, 0, out)
        self.assertIn("not gated: Informational 2, Low 1, Optimization 1", out)

    def test_impact_case_is_normalised(self) -> None:
        failures, _ = evaluate(report(finding("x-check", "HIGH", function("f", "A", "src/A.sol"))))
        self.assertEqual(failures, 1)

    def test_a_row_must_match_detector_and_location(self) -> None:
        wrong = {
            "other detector": "| unused-return | src/libraries/Utf8.sol:Utf8.validate | accepted | r |",
            "other function": "| incorrect-shift | src/libraries/Utf8.sol:Utf8.other | accepted | r |",
            "other contract": "| incorrect-shift | src/libraries/Utf8.sol:Other | accepted | r |",
            "other file": "| incorrect-shift | src/libraries/Other.sol | accepted | r |",
        }
        for name, row in wrong.items():
            with self.subTest(name):
                failures, out = evaluate(report(shift_finding()), row)
                self.assertEqual(failures, 1, out)

    def test_coarser_rows_cover_everything_below_them(self) -> None:
        for row in (
            "| incorrect-shift | src/libraries/Utf8.sol:Utf8 | accepted | r |",
            "| incorrect-shift | src/libraries/Utf8.sol | accepted | r |",
        ):
            with self.subTest(row):
                failures, out = evaluate(report(shift_finding()), row)
                self.assertEqual(failures, 0, out)

    def test_a_finding_without_a_location_cannot_be_dispositioned(self) -> None:
        failures, out = evaluate(
            report(finding("incorrect-shift", "High")), "| incorrect-shift | src/A.sol | accepted | r |"
        )
        self.assertEqual(failures, 1)
        self.assertIn("at an unknown location", out)

    def test_stale_rows_are_noted_not_failed(self) -> None:
        failures, out = evaluate(report(), self.ROW)
        self.assertEqual(failures, 0, out)
        self.assertIn("note triage line 1 (incorrect-shift at src/libraries/Utf8.sol:Utf8.validate)", out)

    def test_malformed_reports_fail_closed(self) -> None:
        fn = function("f", "A", "src/A.sol")
        bad = {
            "not an object": ["x"],
            "failed analysis": {"success": False, "error": "compile error", "results": {}},
            "missing success": {"results": {"detectors": []}},
            "no results": {"success": True},
            "detectors not a list": {"success": True, "results": {"detectors": {}}},
            "finding not an object": report("oops"),
            "finding without check": report({"impact": "High", "elements": [fn]}),
            "finding without impact": report({"check": "x", "elements": [fn]}),
            "non-string impact": report({"check": "x", "impact": 3, "elements": [fn]}),
        }
        for name, slither in bad.items():
            with self.subTest(name):
                failures, out = evaluate(slither)
                self.assertGreaterEqual(failures, 1, out)
        self.assertIn("compile error", evaluate(bad["failed analysis"])[1])


class ScopeAndCoverageTest(unittest.TestCase):
    """The gate filters on the repository-relative path and proves src/ was analysed."""

    def test_findings_are_gated_whatever_the_absolute_path_says(self) -> None:
        # A checkout under `content-attest/` (it contains `test/`) gave Slither's own
        # absolute-path filter a match for every file, so every finding vanished.
        fn = function("sweep", "Vault", VAULT)
        fn["source_mapping"]["filename_absolute"] = "/work/content-attest/repo/" + VAULT
        slither = report(finding("arbitrary-send-eth", "High", fn))
        failures, out = evaluate(slither, src_files=set(SRC_FILES))
        self.assertEqual(failures, 1, out)
        self.assertIn("FAIL arbitrary-send-eth (High) at src/economics/Vault.sol:Vault.sweep", out)

    def test_findings_entirely_in_lib_test_and_script_are_ignored_and_noted(self) -> None:
        slither = report(
            finding("reentrancy-eth", "High", function("f", "L", "lib/dep/L.sol")),
            finding("unused-return", "Medium", function("t", "T", "test/T.t.sol")),
            finding("arbitrary-send-eth", "High", function("s", "S", "script/Deploy.s.sol")),
        )
        failures, out = evaluate(slither)
        self.assertEqual(failures, 0, out)
        self.assertIn("0 High/Medium findings gated; not gated: none", out)
        self.assertIn("note 3 findings entirely in lib/, test/, script/ ignored", out)

    def test_look_alike_directories_are_not_out_of_scope(self) -> None:
        slither = report(
            finding("reentrancy-eth", "High", function("a", "A", "src/lib/A.sol")),
            finding("unused-return", "Medium", function("b", "B", "library/B.sol")),
            finding("arbitrary-send-eth", "High", function("c", "C", "scripts/C.sol")),
        )
        failures, out = evaluate(slither)
        self.assertEqual(failures, 3, out)

    def test_a_finding_that_also_touches_src_is_still_gated(self) -> None:
        mixed = finding(
            "reentrancy-eth", "High", function("f", "L", "lib/dep/L.sol"), function("g", "G", "src/G.sol")
        )
        failures, out = evaluate(report(mixed))
        self.assertEqual(failures, 1, out)
        self.assertIn("at src/G.sol:G.g", out)

    def test_a_clean_tree_has_results_without_a_detectors_key(self) -> None:
        failures, out = evaluate(clean_report(), src_files=set(SRC_FILES))
        self.assertEqual(failures, 0, out)
        self.assertIn("ok   slither analysed 2 contracts in 2 src/ files", out)
        self.assertIn("0 High/Medium findings gated", out)

    def test_no_compilation_data_fails_even_with_no_findings(self) -> None:
        for name, slither in {
            "key absent": report(files=None),
            "empty list": {"success": True, "results": {"detectors": [], "compilations": []}},
            "not a list": {"success": True, "results": {"compilations": {}}},
        }.items():
            with self.subTest(name):
                failures, out = evaluate(slither)
                self.assertEqual(failures, 1, out)
                self.assertIn("no compilation data", out)
                self.assertIn("--json-types detectors,compilations", out)

    def test_zero_contracts_analysed_under_src_fails(self) -> None:
        for name, slither in {
            "only dependencies": report(files=("lib/dep/D.sol", "lib/forge-std/src/Test.sol")),
            "no units at all": {"success": True, "results": {"compilations": [{"compilation_units": {}}]}},
            "absolute names": report(files=("/work/repo/src/A.sol",)),
            "src files without contracts": {
                "success": True,
                "results": {"compilations": compilations("src/types/T.sol", contracts=0)},
            },
        }.items():
            with self.subTest(name):
                failures, out = evaluate(slither, src_files={"src/types/T.sol"})
                self.assertEqual(failures, 1, out)
                self.assertIn("slither analysed no contracts under src/", out)

    def test_zero_contracts_under_src_fails_even_when_findings_exist_elsewhere(self) -> None:
        slither = report(finding("x", "Low", function("f", "L", "lib/dep/L.sol")), files=("lib/dep/L.sol",))
        failures, out = evaluate(slither)
        self.assertEqual(failures, 1, out)

    def test_every_src_file_on_disk_must_have_been_analysed(self) -> None:
        on_disk = {*SRC_FILES, "src/Extra.sol", "src/types/T.sol"}
        failures, out = evaluate(report(), src_files=on_disk)
        self.assertEqual(failures, 1, out)
        self.assertIn("slither did not analyse 2 of the src/ files on disk: src/Extra.sol, src/types/T.sol", out)

    def test_many_unanalysed_files_are_summarised(self) -> None:
        on_disk = {*SRC_FILES, *(f"src/Missing{n}.sol" for n in range(8))}
        _, out = evaluate(report(), src_files=on_disk)
        self.assertIn("did not analyse 8 of the src/ files", out)
        self.assertIn("and 3 more", out)

    def test_source_units_merge_across_compilation_units_and_normalise_names(self) -> None:
        slither = {
            "success": True,
            "results": {
                "compilations": [
                    {"compilation_units": {"a": {"source_units": {"src\\A.sol": {"contracts": {"A": {}}}}}}},
                    {"compilation_units": {"b": {"source_units": {"src/A.sol": {"contracts": {"B": {}}}}}}},
                ]
            },
        }
        self.assertEqual(cs.source_units(slither), {"src/A.sol": 2})
        self.assertIsNone(cs.source_units({"results": []}))

    def test_source_files_lists_every_solidity_file_under_src(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("src/A.sol", "src/deep/er/B.sol", "src/README.md", "lib/C.sol", "test/D.sol"):
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text("", encoding="utf-8")
            self.assertEqual(cs.source_files(root), {"src/A.sol", "src/deep/er/B.sol"})


class FilterConfigTest(unittest.TestCase):
    """slither.config.json matches absolute resolved paths; see the check_slither docstring."""

    ROOT = Path(__file__).resolve().parent.parent
    OLD_PATTERN = "(lib/|test/|script/)"

    @staticmethod
    def slither_matches(pattern: str, absolute_path: str) -> bool:
        # Slither strips dots and slashes from both ends of the pattern before `re.search`
        # (slither.core.slither_core._relative_path_format), so a trailing `/` is lost.
        effective = pattern.split("..")[-1].strip(".").strip("/")
        return bool(re.search(effective, absolute_path))

    def config_pattern(self) -> str:
        return json.loads((self.ROOT / cs.CONFIG_PATH).read_text(encoding="utf-8"))["filter_paths"]

    def test_the_old_pattern_hid_every_file_under_a_directory_ending_in_test(self) -> None:
        absolute = "/work/content-attest/repo/src/economics/Vault.sol"
        self.assertTrue(self.slither_matches(self.OLD_PATTERN, absolute))

    def test_the_config_pattern_matches_whole_segments_only(self) -> None:
        pattern = self.config_pattern()
        for path in (
            "/work/repo/lib/forge-std/src/Test.sol",
            "/work/repo/lib/openzeppelin-contracts/contracts/utils/Context.sol",
            "/work/repo/test/Vault.t.sol",
            "/work/repo/script/Deploy.s.sol",
            "C:/work/repo/lib/dep/D.sol",
        ):
            self.assertTrue(self.slither_matches(pattern, path), path)
        for path in (
            "/work/content-attest/repo/src/Vault.sol",
            "/work/latest/repo/src/Vault.sol",
            "/work/contest/repo/src/Vault.sol",
            "/work/library/repo/src/Vault.sol",
            "/work/scripts/repo/src/Vault.sol",
            "/work/repo/src/libraries/Utf8.sol",
            "/work/repo/src/testing/Vault.sol",
            "C:/Users/me/6529-works-test/src/Vault.sol",
        ):
            self.assertFalse(self.slither_matches(pattern, path), path)

    def test_the_override_matches_nothing_and_is_valid(self) -> None:
        for path in ("/work/repo/lib/dep/D.sol", "/work/content-attest/repo/src/Vault.sol", "", "lib/"):
            self.assertFalse(self.slither_matches(cs.MATCH_NOTHING, path), path)


class MainTest(unittest.TestCase):
    TRIAGE = (
        "| Detector | Location | Disposition | Reason |\n| --- | --- | --- | --- |\n"
        "| incorrect-shift | src/libraries/Utf8.sol:Utf8.validate | false-positive | Yul order. |\n"
    )

    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.root = Path(self._dir.name)
        (self.root / "triage.md").write_text(self.TRIAGE, encoding="utf-8")
        for name in SRC_FILES:
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
            (self.root / name).write_text("contract C {}\n", encoding="utf-8")

    def write_report(self, slither: object) -> Path:
        path = self.root / "report.json"
        path.write_text(json.dumps(slither), encoding="utf-8")
        return path

    def run_main(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cs.main(["--root", str(self.root), "--triage", str(self.root / "triage.md"), *args])
        return code, out.getvalue()

    def fake_slither(self, body: str) -> str:
        script = self.root / "fake_slither.py"
        script.write_text(textwrap.dedent(body), encoding="utf-8")
        return f'"{sys.executable}" "{script}"'

    def test_report_file_passes_and_fails(self) -> None:
        code, out = self.run_main("--report", str(self.write_report(report(shift_finding()))))
        self.assertEqual(code, 0, out)
        self.assertIn("every High/Medium finding is dispositioned", out)
        fn = function("pay", "Vault", VAULT)
        code, out = self.run_main("--report", str(self.write_report(report(finding("reentrancy-eth", "High", fn)))))
        self.assertEqual(code, 1)
        self.assertIn("FAIL reentrancy-eth (High)", out)
        self.assertIn("slither triage: 1 failure(s)", out)

    def test_unreadable_or_invalid_report_fails(self) -> None:
        code, out = self.run_main("--report", str(self.root / "missing.json"))
        self.assertEqual(code, 1)
        self.assertIn("cannot read missing.json", out)
        (self.root / "bad.json").write_text("{not json", encoding="utf-8")
        code, out = self.run_main("--report", str(self.root / "bad.json"))
        self.assertEqual(code, 1)
        self.assertIn("cannot read bad.json", out)

    def test_a_malformed_triage_row_fails_even_with_a_clean_report(self) -> None:
        (self.root / "triage.md").write_text("| unused-return | src/A.sol | maybe | r |\n", encoding="utf-8")
        code, out = self.run_main("--report", str(self.write_report(report())))
        self.assertEqual(code, 1)
        self.assertIn("triage.md: line 1: disposition 'maybe'", out)

    def test_missing_triage_file_fails(self) -> None:
        (self.root / "triage.md").unlink()
        code, out = self.run_main("--report", str(self.write_report(report())))
        self.assertEqual(code, 1)
        self.assertIn("triage.md: cannot read", out)

    def test_a_clean_report_passes_when_every_src_file_was_analysed(self) -> None:
        code, out = self.run_main("--report", str(self.write_report(clean_report())))
        self.assertEqual(code, 0, out)

    def test_an_unanalysed_src_file_on_disk_fails(self) -> None:
        (self.root / "src" / "New.sol").write_text("contract New {}\n", encoding="utf-8")
        code, out = self.run_main("--report", str(self.write_report(clean_report())))
        self.assertEqual(code, 1)
        self.assertIn("slither did not analyse 1 of the src/ files on disk: src/New.sol", out)

    def test_a_root_without_src_files_fails(self) -> None:
        for name in SRC_FILES:
            (self.root / name).unlink()
        code, out = self.run_main("--report", str(self.write_report(clean_report())))
        self.assertEqual(code, 1)
        self.assertIn("no src/**/*.sol files", out)

    def test_slither_is_run_with_the_gates_overrides_and_its_report_is_checked(self) -> None:
        command = self.fake_slither(
            f"""\
            import json, sys
            args = sys.argv
            out = args[args.index("--json") + 1]
            assert args[1] == "." and "--fail-none" in args and "--config-file" in args
            assert args[args.index("--filter-paths") + 1] == "(?!)", args
            assert args[args.index("--json-types") + 1] == "detectors,compilations", args
            json.dump({report(shift_finding())!r}, open(out, "w"))
            sys.exit(255)  # a non-zero exit with findings is normal and not itself a failure
            """
        )
        code, out = self.run_main("--slither-command", command)
        self.assertEqual(code, 0, out)
        self.assertIn("ok   slither analysed 2 contracts in 2 src/ files", out)

    def test_slither_whose_report_has_no_src_contracts_fails(self) -> None:
        command = self.fake_slither(
            f"""\
            import json, sys
            out = sys.argv[sys.argv.index("--json") + 1]
            json.dump({report(files=("lib/dep/D.sol",))!r}, open(out, "w"))
            """
        )
        code, out = self.run_main("--slither-command", command)
        self.assertEqual(code, 1)
        self.assertIn("slither analysed no contracts under src/", out)

    def test_slither_whose_report_lacks_compilation_data_fails(self) -> None:
        command = self.fake_slither(
            f"""\
            import json, sys
            json.dump({report(files=None)!r}, open(sys.argv[sys.argv.index("--json") + 1], "w"))
            """
        )
        code, out = self.run_main("--slither-command", command)
        self.assertEqual(code, 1)
        self.assertIn("no compilation data", out)

    def test_slither_that_writes_no_report_fails_with_its_output(self) -> None:
        command = self.fake_slither(
            """\
            import sys
            print("Traceback: could not parse solc output", file=sys.stderr)
            sys.exit(1)
            """
        )
        code, out = self.run_main("--slither-command", command)
        self.assertEqual(code, 1)
        self.assertIn("slither produced no report (exit 1)", out)
        self.assertIn("could not parse solc output", out)

    def test_slither_failing_analysis_fails(self) -> None:
        command = self.fake_slither(
            """\
            import json, sys
            json.dump({"success": False, "error": "Solidity 0.9 unsupported", "results": {}},
                      open(sys.argv[sys.argv.index("--json") + 1], "w"))
            """
        )
        code, out = self.run_main("--slither-command", command)
        self.assertEqual(code, 1)
        self.assertIn("Solidity 0.9 unsupported", out)


def _real_slither_available() -> bool:
    return shutil.which("forge") is not None and importlib.util.find_spec("slither") is not None


@unittest.skipUnless(_real_slither_available(), "needs forge and the slither module")
class RealSlitherInAnAwkwardPathTest(unittest.TestCase):
    """Run the real gate in a checkout under `content-attest/`, which the old filter broke.

    The project carries the OLD `(lib/|test/|script/)` config, which hides every finding
    when Slither runs it against absolute paths; the gate must still see the findings.
    """

    OLD = "(lib/|test/|script/)"
    FOUNDRY_TOML = '[profile.default]\nsrc = "src"\nsolc_version = "0.8.37"\nauto_detect_solc = false\n'
    VAULT = (
        "// SPDX-License-Identifier: MIT\npragma solidity 0.8.37;\n\n"
        "contract Vault {\n    function deposit() external payable {}\n\n"
        "    function sweep(address to) external {\n"
        "        payable(to).transfer(address(this).balance);\n    }\n}\n"
    )
    CLEAN = (
        "// SPDX-License-Identifier: MIT\npragma solidity 0.8.37;\n\n"
        "/// @notice Nothing for a detector to report.\ncontract Clean {\n"
        "    /// @notice Returns its input.\n"
        "    function identity(uint256 x) external pure returns (uint256) {\n        return x;\n    }\n}\n"
    )

    def project(self, source: str) -> Path:
        base = tempfile.TemporaryDirectory()
        self.addCleanup(base.cleanup)
        root = Path(base.name).resolve() / "content-attest" / "repo"
        (root / "src").mkdir(parents=True)
        (root / "foundry.toml").write_text(self.FOUNDRY_TOML, encoding="utf-8")
        (root / "slither.config.json").write_text(json.dumps({"filter_paths": self.OLD}), encoding="utf-8")
        (root / "src" / "Vault.sol").write_text(source, encoding="utf-8")
        (root / "triage.md").write_text("| Detector | Location | Disposition | Reason |\n| --- | --- | --- | --- |\n", encoding="utf-8")
        return root

    def run_gate(self, root: Path) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cs.main(["--root", str(root), "--triage", str(root / "triage.md")])
        return code, out.getvalue()

    def test_the_path_contains_a_directory_the_old_filter_matched(self) -> None:
        root = self.project(self.CLEAN)
        self.assertTrue(re.search(self.OLD, root.as_posix()), root)

    def test_a_real_finding_is_not_hidden(self) -> None:
        code, out = self.run_gate(self.project(self.VAULT))
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL arbitrary-send-eth (High) at src/Vault.sol:Vault.sweep", out)
        self.assertIn("slither analysed 1 contracts in 1 src/ files", out)

    def test_a_clean_contract_passes(self) -> None:
        code, out = self.run_gate(self.project(self.CLEAN))
        self.assertEqual(code, 0, out)
        self.assertIn("ok   slither analysed 1 contracts in 1 src/ files", out)
        self.assertIn("0 High/Medium findings gated", out)


if __name__ == "__main__":
    unittest.main()
