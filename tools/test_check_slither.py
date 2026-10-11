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


def report(*findings: dict) -> dict:
    return {"success": True, "error": None, "results": {"detectors": list(findings)}}


def shift_finding() -> dict:
    fn = function("validate", "Utf8", UTF8)
    return finding("incorrect-shift", "High", fn, node("x >> 1", fn, UTF8))


def evaluate(slither: object, triage: str = "") -> tuple[int, str]:
    rows, errors = cs.parse_triage(textwrap.dedent(triage))
    assert not errors, errors
    out = cs.Report()
    cs.evaluate(slither, rows, "slither-triage.md", out)
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

    def test_first_element_with_a_location_decides(self) -> None:
        located = function("f", "A", "src/A.sol")
        self.assertEqual(
            cs.finding_location({"elements": [{"type": "pragma"}, located, function("g", "B", "src/B.sol")]}),
            cs.Location("src/A.sol", "A", "f"),
        )
        self.assertIsNone(cs.finding_location({"elements": []}))
        self.assertIsNone(cs.finding_location({}))

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

    def test_running_slither_checks_its_report(self) -> None:
        command = self.fake_slither(
            f"""\
            import json, sys
            out = sys.argv[sys.argv.index("--json") + 1]
            assert "--fail-none" in sys.argv and sys.argv[1] == "."
            json.dump({report(shift_finding())!r}, open(out, "w"))
            print("src analyzed (8 contracts with 102 detectors), 1 result(s) found", file=sys.stderr)
            sys.exit(255)  # a non-zero exit with findings is normal and not itself a failure
            """
        )
        code, out = self.run_main("--slither-command", command)
        self.assertEqual(code, 0, out)
        self.assertIn("ok   slither analysed 8 contracts", out)

    def test_slither_that_analysed_nothing_fails(self) -> None:
        command = self.fake_slither(
            f"""\
            import json, sys
            out = sys.argv[sys.argv.index("--json") + 1]
            json.dump({report()!r}, open(out, "w"))
            print("src analyzed (0 contracts with 102 detectors), 0 result(s) found", file=sys.stderr)
            """
        )
        code, out = self.run_main("--slither-command", command)
        self.assertEqual(code, 1)
        self.assertIn("slither analysed no contracts", out)

    def test_slither_without_the_analysed_line_fails(self) -> None:
        command = self.fake_slither(
            f"""\
            import json, sys
            json.dump({report()!r}, open(sys.argv[sys.argv.index("--json") + 1], "w"))
            """
        )
        code, out = self.run_main("--slither-command", command)
        self.assertEqual(code, 1)
        self.assertIn("slither analysed no contracts", out)

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
            print("src analyzed (3 contracts with 102 detectors)", file=sys.stderr)
            """
        )
        code, out = self.run_main("--slither-command", command)
        self.assertEqual(code, 1)
        self.assertIn("Solidity 0.9 unsupported", out)


if __name__ == "__main__":
    unittest.main()
