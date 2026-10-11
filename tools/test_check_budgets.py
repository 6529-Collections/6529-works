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

    def test_default_line_limit_is_twelve_thousand(self) -> None:
        self.repo.write("Big.sol", "uint256 constant X = 1;\n" * 12_000)
        self.assertEqual(self.repo.run("--skip-sizes")[0], 0)
        self.repo.write("Bigger.sol", "uint256 constant Y = 1;\n")
        code, out = self.repo.run("--skip-sizes")
        self.assertEqual(code, 1)
        self.assertIn("12001 Solidity code lines in src/ (limit 12000)", out)

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
        code, out = self.repo.run("--sizes-json", str(self.repo.sizes(at_limit)))
        self.assertEqual(code, 0, out)

        over = {
            "A": {"runtime_size": 24_577, "init_size": 100},
            "B": {"runtime_size": 100, "init_size": 49_153},
        }
        code, out = self.repo.run("--sizes-json", str(self.repo.sizes(over)))
        self.assertEqual(code, 1)
        self.assertIn("A runtime 24577 > 24576", out)
        self.assertIn("B initcode 49153 > 49152", out)

    def test_root_and_profile_detection(self) -> None:
        (self.repo.root / "foundry.toml").write_text("[profile.default]\n", encoding="utf-8")
        nested = self.repo.root / "tools" / "v1"
        nested.mkdir(parents=True)
        self.assertEqual(cb.find_root(nested), self.repo.root)
        self.assertEqual(cb.detect_profile(self.repo.root), "default")
        (self.repo.root / "foundry.toml").write_text(
            "[profile.default]\n\n[profile.v1]\nsrc = \"src\"\n", encoding="utf-8"
        )
        self.assertEqual(cb.detect_profile(self.repo.root), "v1")

    def test_missing_src_is_an_error(self) -> None:
        (self.repo.root / "src").rmdir()
        with self.assertRaises(SystemExit):
            self.repo.run("--skip-sizes")


if __name__ == "__main__":
    unittest.main()
