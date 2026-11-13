"""Unit tests for check_budgets.py, which sits beside this file.

Run with `python tools/test_check_budgets.py` or, from the repository root,
`python -m tools.test_check_budgets`.
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
from unittest import mock

_SPEC = importlib.util.spec_from_file_location(
    "check_budgets", Path(__file__).with_name("check_budgets.py")
)
cb = importlib.util.module_from_spec(_SPEC)
sys.modules["check_budgets"] = cb  # dataclasses resolve annotations through sys.modules
_SPEC.loader.exec_module(cb)


def _library(name: str, visibility: str) -> str:
    return f"library {name} {{\n    function f(uint256 x) {visibility} pure returns (uint256) {{ return x; }}\n}}\n"


class TempRepo:
    """A throwaway repository root with a src/ tree."""

    def __init__(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)
        (self.root / "src").mkdir()

    def write(self, relative: str, text: str) -> None:
        path = self.root / "src" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def sizes(self, sizes: dict) -> Path:
        path = self.root / "sizes.json"
        path.write_text(json.dumps(sizes), encoding="utf-8")
        return path

    def run(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cb.main(["--root", str(self.root), *args])
        return code, out.getvalue()

    def close(self) -> None:
        self._dir.cleanup()


class StripTest(unittest.TestCase):
    def test_comments_and_strings_are_blanked_but_lines_kept(self) -> None:
        text = (
            "// delegatecall in a line comment\n"
            "/* delegatecall\n   in a block */ uint256 a;\n"
            'string s = "delegatecall // not a comment";\n'
            "string t = 'it\\'s /* not a comment */';\n"
            "/// delegatecall in NatSpec\n"
        )
        code = cb.strip_solidity(text)
        self.assertEqual(code.count("\n"), text.count("\n"))
        self.assertNotIn("delegatecall", code)
        self.assertIn("uint256 a;", code)
        self.assertIn('string s = "";', code)
        self.assertIn("string t = '';", code)
        self.assertEqual(cb.count_code_lines(code), 3)

    def test_blank_and_comment_only_lines_do_not_count(self) -> None:
        text = "\n\n   // only a comment\n/**\n * NatSpec\n */\npragma solidity ^0.8.24;\n\t\n"
        self.assertEqual(cb.count_code_lines(cb.strip_solidity(text)), 1)


class LinkedLibraryTest(unittest.TestCase):
    def test_visibility_decides(self) -> None:
        code = cb.strip_solidity(
            _library("Internal", "internal")
            + _library("Private", "private")
            + _library("External", "external")
            + _library("Public", "public")
        )
        self.assertEqual(cb.linked_libraries(code), ["External", "Public"])

    def test_function_types_in_signatures_are_not_visibility(self) -> None:
        code = cb.strip_solidity(
            "library L {\n"
            "    function apply(function (uint256) external returns (uint256) f) internal\n"
            "        returns (function () external g) { g = g; f; }\n"
            "    function body() internal { function (uint256) external h; h; }\n"
            "}\n"
            "contract C { function e() external {} }\n"
        )
        self.assertEqual(cb.linked_libraries(code), [])


class BudgetTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.close)

    def test_clean_tree_passes(self) -> None:
        self.repo.write("libraries/A.sol", _library("A", "internal"))
        code, out = self.repo.run("--skip-sizes")
        self.assertEqual(code, 0, out)
        self.assertIn("all checks passed", out)

    def test_delegatecall_in_code_fails(self) -> None:
        self.repo.write("a/Solidity.sol", "contract A { function f(address t) external { t.delegatecall(\"\"); } }\n")
        self.repo.write("b/Yul.sol", "contract B {\n function f() external { assembly { pop(delegatecall(gas(), 0, 0, 0, 0, 0)) } }\n}\n")
        self.repo.write("c/Legacy.sol", "contract C { function f() external { assembly { pop(callcode(gas(), 0, 0, 0, 0, 0, 0)) } } }\n")
        code, out = self.repo.run("--skip-sizes")
        self.assertEqual(code, 1)
        self.assertIn("delegatecall at src/a/Solidity.sol:1", out)
        self.assertIn("delegatecall at src/b/Yul.sol:2", out)
        self.assertIn("callcode at src/c/Legacy.sol:1", out)

    def test_delegatecall_in_comments_and_strings_passes(self) -> None:
        self.repo.write(
            "A.sol",
            '/// Never uses delegatecall.\ncontract A { string constant NOTE = "no delegatecall"; }\n',
        )
        code, out = self.repo.run("--skip-sizes")
        self.assertEqual(code, 0, out)

    def test_line_limit(self) -> None:
        self.repo.write("A.sol", "// header\npragma solidity ^0.8.24;\n\ncontract A {\n}\n")
        self.assertEqual(self.repo.run("--skip-sizes", "--max-lines", "3")[0], 0)
        code, out = self.repo.run("--skip-sizes", "--max-lines", "2")
        self.assertEqual(code, 1)
        self.assertIn("3 Solidity code lines", out)

    def test_default_line_limit_is_thirteen_thousand(self) -> None:
        self.repo.write("Big.sol", "uint256 constant X = 1;\n" * 13_000)
        self.assertEqual(self.repo.run("--skip-sizes")[0], 0)
        self.repo.write("Bigger.sol", "uint256 constant Y = 1;\n")
        code, out = self.repo.run("--skip-sizes")
        self.assertEqual(code, 1)
        self.assertIn("13001 Solidity code lines in src/ (limit 13000)", out)

    def test_lib_directories_are_excluded(self) -> None:
        self.repo.write("lib/vendor/V.sol", "contract V { function f(address t) external { t.delegatecall(\"\"); } }\n")
        code, out = self.repo.run("--skip-sizes")
        self.assertEqual(code, 0, out)

    def test_at_most_five_linked_libraries(self) -> None:
        for i in range(5):
            self.repo.write(f"L{i}.sol", _library(f"L{i}", "external"))
        self.repo.write("Internal.sol", _library("Internal", "internal"))
        code, out = self.repo.run("--skip-sizes")
        self.assertEqual(code, 0, out)
        self.repo.write("L5.sol", _library("L5", "public"))
        code, out = self.repo.run("--skip-sizes")
        self.assertEqual(code, 1)
        self.assertIn("6 linked libraries (limit 5): L0, L1, L2, L3, L4, L5", out)

    def test_contract_size_limits(self) -> None:
        self.repo.write("A.sol", "contract A {}\n")
        at_limit = {"A": {"runtime_size": 24_576, "init_size": 49_152}}
        # The margin floor is tested on its own (MarginTest); here only EIP-170 and EIP-3860.
        no_floor = ("--min-margin", "0")
        code, out = self.repo.run("--sizes-json", str(self.repo.sizes(at_limit)), *no_floor)
        self.assertEqual(code, 0, out)

        over = {
            "A": {"runtime_size": 24_577, "init_size": 100},
            "B": {"runtime_size": 100, "init_size": 49_153},
        }
        code, out = self.repo.run("--sizes-json", str(self.repo.sizes(over)), *no_floor)
        self.assertEqual(code, 1)
        self.assertIn("A runtime 24577 > 24576", out)
        self.assertIn("B initcode 49153 > 49152", out)

    def test_malformed_size_entries_fail_naming_the_contract(self) -> None:
        self.repo.write("A.sol", "contract A {}\n")
        malformed = {
            "Good": {"runtime_size": 100, "init_size": 120},
            "NotAnObject": 123,
            "NullEntry": None,
            "ListEntry": [1, 2],
            "MissingInit": {"runtime_size": 100},
            "MissingRuntime": {"init_size": 100},
            "StringSize": {"runtime_size": "100", "init_size": 120},
            "FloatSize": {"runtime_size": 100.5, "init_size": 120},
            "BoolSize": {"runtime_size": True, "init_size": 120},
            "NullSize": {"runtime_size": None, "init_size": 120},
            "NegativeSize": {"runtime_size": -1, "init_size": 120},
        }
        code, out = self.repo.run("--sizes-json", str(self.repo.sizes(malformed)))
        self.assertEqual(code, 1)
        for name in malformed:
            if name != "Good":
                self.assertIn(f"FAIL {name}: malformed size entry", out)
        self.assertNotIn("Good:", out)
        self.assertIn("FAIL 11 contracts within EIP-170/EIP-3860 (largest Good 100 bytes)", out)

    def test_malformed_entry_does_not_hide_an_oversized_contract(self) -> None:
        self.repo.write("A.sol", "contract A {}\n")
        sizes = {
            "Broken": {"runtime_size": "big"},
            "Huge": {"runtime_size": 24_577, "init_size": 100},
        }
        code, out = self.repo.run("--sizes-json", str(self.repo.sizes(sizes)))
        self.assertEqual(code, 1)
        self.assertIn("FAIL Broken: malformed size entry", out)
        self.assertIn("FAIL Huge runtime 24577 > 24576", out)

    def test_only_malformed_entries_report_no_largest_contract(self) -> None:
        report = cb.Report()
        cb.check_sizes({"Broken": {}}, report)
        self.assertEqual(len(report.failures), 2)
        self.assertIn("FAIL Broken: malformed size entry", report.failures[0])
        self.assertIn("(no contracts)", report.failures[1])

    def test_non_object_forge_output_fails_cleanly(self) -> None:
        self.repo.write("A.sol", "contract A {}\n")
        code, out = self.repo.run("--sizes-json", str(self.repo.sizes([1, 2, 3])))
        self.assertEqual(code, 1)
        self.assertIn("expected a JSON object from forge", out)

    def test_empty_forge_output_has_no_contracts(self) -> None:
        self.repo.write("A.sol", "contract A {}\n")
        code, out = self.repo.run("--sizes-json", str(self.repo.sizes({})))
        self.assertIn("ok   0 contracts within EIP-170/EIP-3860 (no contracts)", out)
        # The margin gate still fails: src/ declares a contract nobody measured.
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL A: declared in src/ but has no size measurement", out)

    def test_root_is_the_nearest_foundry_toml_ancestor(self) -> None:
        (self.repo.root / "foundry.toml").write_text("[profile.default]\n", encoding="utf-8")
        nested = self.repo.root / "tools" / "v1"
        nested.mkdir(parents=True)
        self.assertEqual(cb.find_root(nested), self.repo.root)

    def _measured_profile(self, *args: str) -> str:
        """The profile main() asks forge to measure, without running forge."""
        calls: list[str] = []

        def fake_forge_sizes(root: Path, profile: str) -> dict:
            calls.append(profile)
            return {"A": {"runtime_size": 100, "init_size": 120}}

        real = cb.forge_sizes
        cb.forge_sizes = fake_forge_sizes
        try:
            code, out = self.repo.run(*args)
        finally:
            cb.forge_sizes = real
        self.assertEqual(code, 0, out)
        self.assertEqual(len(calls), 1)
        return calls[0]

    def test_measured_profile_defaults_to_default(self) -> None:
        self.repo.write("A.sol", "contract A {}\n")
        self.assertEqual(self._measured_profile(), "default")

    def test_a_v1_profile_in_foundry_toml_is_not_preferred(self) -> None:
        self.repo.write("A.sol", "contract A {}\n")
        (self.repo.root / "foundry.toml").write_text(
            '[profile.default]\n\n[profile.v1]\nsrc = "src"\n', encoding="utf-8"
        )
        self.assertEqual(self._measured_profile(), "default")

    def test_explicit_profile_flag_is_used(self) -> None:
        self.repo.write("A.sol", "contract A {}\n")
        self.assertEqual(self._measured_profile("--profile", "default"), "default")
        self.assertEqual(self._measured_profile("--profile", "ci"), "ci")

    def test_forge_runs_under_the_requested_profile(self) -> None:
        completed = mock.Mock(returncode=0, stdout="{}", stderr="")
        with mock.patch.object(cb.subprocess, "run", return_value=completed) as run:
            self.assertEqual(cb.forge_sizes(self.repo.root, "ci"), {})
        self.assertEqual(run.call_args.kwargs["env"]["FOUNDRY_PROFILE"], "ci")
        self.assertEqual(run.call_args.args[0], ["forge", "build", "--sizes", "--json"])

    def test_missing_src_is_an_error(self) -> None:
        (self.repo.root / "src").rmdir()
        with self.assertRaises(SystemExit):
            self.repo.run("--skip-sizes")


def _runtime(margin: int) -> dict:
    """A size entry leaving `margin` bytes under EIP-170."""
    return {"runtime_size": cb.MAX_RUNTIME_BYTES - margin, "init_size": 100}


class MarginTest(unittest.TestCase):
    """Regression: RFX-TOOL-1. The EIP-170 margin floor and its recorded exemptions."""

    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.close)
        self.repo.write(
            "Core.sol",
            "abstract contract Base {}\ncontract Core is Base {}\ncontract Tight {}\n",
        )

    def _exempt(self, entries: dict) -> None:
        path = self.repo.root / "tools" / "size-margins.json"
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps({"exempt": entries}), encoding="utf-8")

    def _run(self, sizes: dict, *args: str) -> tuple[int, str]:
        return self.repo.run("--sizes-json", str(self.repo.sizes(sizes)), *args)

    def test_floor_is_512_bytes(self) -> None:
        self.assertEqual(cb.MIN_RUNTIME_MARGIN, 512)
        code, out = self._run({"Core": _runtime(512), "Tight": _runtime(600)})
        self.assertEqual(code, 0, out)
        self.assertIn("ok   2 src/ contracts keep 512 bytes of EIP-170 margin (0 exempt)", out)
        code, out = self._run({"Core": _runtime(511), "Tight": _runtime(600)})
        self.assertEqual(code, 1)
        self.assertIn("FAIL Core margin 511 bytes < 512 (runtime 24065)", out)

    def test_only_contracts_declared_in_src_are_held_to_the_floor(self) -> None:
        # A test contract, an abstract base and a name only in a comment or string.
        self.repo.write("Notes.sol", '// contract Commented {}\nstring constant S = "contract Quoted";\n')
        sizes = {
            "Core": _runtime(600),
            "Tight": _runtime(600),
            "TestOnlyHandler": _runtime(0),
            "Base": _runtime(0),
            "Commented": _runtime(0),
            "Quoted": _runtime(0),
        }
        code, out = self._run(sizes)
        self.assertEqual(code, 0, out)
        self.assertEqual(cb.deployable_contracts(self.repo.root / "src"), {"Core", "Tight"})

    def test_an_exempt_contract_may_not_lose_margin(self) -> None:
        self._exempt({"Tight": {"margin": 203, "reason": "not upgradeable"}})
        code, out = self._run({"Core": _runtime(600), "Tight": _runtime(203)})
        self.assertEqual(code, 0, out)
        self.assertIn("ok   Tight margin 203 bytes (exempt, recorded 203)", out)
        self.assertIn("(1 exempt)", out)
        code, out = self._run({"Core": _runtime(600), "Tight": _runtime(202)})
        self.assertEqual(code, 1)
        self.assertIn(
            "FAIL Tight margin 202 bytes < its recorded 203 (runtime 24374; exempt from the"
            " 512-byte floor: not upgradeable)",
            out,
        )

    def test_a_gain_is_reported_and_a_recovered_contract_loses_its_exemption(self) -> None:
        self._exempt({"Tight": {"margin": 203, "reason": "not upgradeable"}})
        code, out = self._run({"Core": _runtime(600), "Tight": _runtime(300)})
        self.assertEqual(code, 0, out)
        self.assertIn("Tight margin 300 bytes (exempt, recorded 203: raise the record", out)
        code, out = self._run({"Core": _runtime(600), "Tight": _runtime(512)})
        self.assertEqual(code, 1)
        self.assertIn("Tight margin 512 bytes is back at or above the 512-byte floor", out)

    def test_a_contract_missing_from_partial_measurements_fails(self) -> None:
        """Regression: RFX-TOOL-1. Leaving a src/ contract out of the sizes must not pass."""
        code, out = self._run({"Core": _runtime(600)})
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL Tight: declared in src/ but has no size measurement", out)
        self.assertNotIn("Core: declared", out)
        self.assertIn("FAIL 1 src/ contracts keep 512 bytes of EIP-170 margin", out)
        # An exemption does not excuse a missing measurement either.
        self._exempt({"Tight": {"margin": 100, "reason": "r"}})
        code, out = self._run({"Core": _runtime(600)})
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL Tight: declared in src/ but has no size measurement", out)

    def test_empty_measurements_fail_naming_every_contract(self) -> None:
        """Regression: RFX-TOOL-1. An empty size report measures nothing and fails."""
        code, out = self._run({})
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL Core: declared in src/ but has no size measurement", out)
        self.assertIn("FAIL Tight: declared in src/ but has no size measurement", out)
        self.assertIn("FAIL 0 src/ contracts keep 512 bytes of EIP-170 margin", out)

    def test_a_malformed_measurement_counts_as_missing(self) -> None:
        """Regression: RFX-TOOL-1. A src/ contract whose only entry is malformed is unmeasured."""
        code, out = self._run({"Core": _runtime(600), "Tight": {"runtime_size": "big"}})
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL Tight: malformed size entry", out)
        self.assertIn("FAIL Tight: declared in src/ but has no size measurement", out)

    def test_an_exemption_for_an_unmeasured_contract_fails(self) -> None:
        self._exempt({"Gone": {"margin": 100, "reason": "removed since"}})
        code, out = self._run({"Core": _runtime(600), "Tight": _runtime(600)})
        self.assertEqual(code, 1)
        self.assertIn("FAIL Gone: exempt in tools/size-margins.json, but no src/ contract", out)

    def test_a_malformed_exemptions_file_fails(self) -> None:
        cases = {
            "no reason": {"exempt": {"Tight": {"margin": 100}}},
            "blank reason": {"exempt": {"Tight": {"margin": 100, "reason": " "}}},
            "string margin": {"exempt": {"Tight": {"margin": "100", "reason": "r"}}},
            "bool margin": {"exempt": {"Tight": {"margin": True, "reason": "r"}}},
            "negative margin": {"exempt": {"Tight": {"margin": -1, "reason": "r"}}},
            "margin at the floor": {"exempt": {"Tight": {"margin": 512, "reason": "r"}}},
            "no exempt object": {"Tight": {"margin": 100, "reason": "r"}},
            "not an object": [1, 2],
        }
        path = self.repo.root / "tools" / "size-margins.json"
        path.parent.mkdir(exist_ok=True)
        for label, data in cases.items():
            with self.subTest(label):
                path.write_text(json.dumps(data), encoding="utf-8")
                code, out = self._run({"Core": _runtime(600), "Tight": _runtime(100)})
                self.assertEqual(code, 1, out)
                self.assertIn("FAIL size-margins.json", out)
        path.write_text("{not json", encoding="utf-8")
        code, out = self._run({"Core": _runtime(600), "Tight": _runtime(100)})
        self.assertEqual(code, 1)
        self.assertIn("FAIL size-margins.json: not JSON", out)

    def test_a_missing_exemptions_file_exempts_nothing(self) -> None:
        code, out = self._run({"Core": _runtime(600), "Tight": _runtime(100)})
        self.assertEqual(code, 1)
        self.assertIn("FAIL Tight margin 100 bytes < 512", out)

    def test_an_explicit_exemptions_file_and_floor(self) -> None:
        other = self.repo.root / "other.json"
        other.write_text(
            json.dumps({"exempt": {"Tight": {"margin": 100, "reason": "r"}}}), encoding="utf-8"
        )
        sizes = {"Core": _runtime(600), "Tight": _runtime(100)}
        code, out = self._run(sizes, "--margins", str(other))
        self.assertEqual(code, 0, out)
        code, out = self._run(sizes, "--min-margin", "1024")
        self.assertEqual(code, 1)
        self.assertIn("FAIL Core margin 600 bytes < 1024", out)

    def test_the_committed_exemptions_are_well_formed(self) -> None:
        path = Path(__file__).with_name("size-margins.json")
        exempt = cb.load_margins(path, cb.MIN_RUNTIME_MARGIN)
        self.assertTrue(exempt, "the committed file lists the contracts below the floor")
        for name, entry in exempt.items():
            self.assertLess(entry["margin"], cb.MIN_RUNTIME_MARGIN, name)


if __name__ == "__main__":
    unittest.main()
