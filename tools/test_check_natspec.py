"""Unit tests for check_natspec.py, which sits beside this file.

Run with `python tools/test_check_natspec.py` or, from the repository root,
`python -m tools.test_check_natspec`.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "check_natspec", Path(__file__).with_name("check_natspec.py")
)
cn = importlib.util.module_from_spec(_SPEC)
sys.modules["check_natspec"] = cn  # dataclasses resolve annotations through sys.modules
_SPEC.loader.exec_module(cn)


def issues(source: str) -> list[str]:
    """Every problem in `source`, as `kind name: issue`."""
    return [
        f"{d.kind} {d.name}: {issue}" for d in cn.declarations(source) for issue in cn.problems(d)
    ]


class TagParsingTest(unittest.TestCase):
    def test_untagged_comment_is_a_notice(self) -> None:
        self.assertTrue(cn.parse_tags(" Does a thing.").notice)

    def test_untagged_text_after_a_tag_continues_it(self) -> None:
        tags = cn.parse_tags(" @dev Internal.\n More detail.")
        self.assertFalse(tags.notice)

    def test_params_returns_and_inheritdoc(self) -> None:
        tags = cn.parse_tags(
            " @notice N.\n @param a The a.\n @param b The b.\n @return x The x.\n @return The y."
        )
        self.assertEqual(tags.params, ["a", "b"])
        self.assertEqual(tags.returns, ["x The x.", "The y."])
        self.assertTrue(cn.parse_tags(" @inheritdoc IFoo").inheritdoc)

    def test_an_empty_notice_is_no_notice(self) -> None:
        self.assertFalse(cn.parse_tags(" @notice\n @param a A.").notice)
        self.assertTrue(cn.parse_tags(" @notice\n    Continued on the next line.").notice)


class ScanTest(unittest.TestCase):
    def test_triple_slash_lines_merge_and_block_comments_parse(self) -> None:
        _, docs = cn.scan("/// one\n/// two\nuint x;\n/**\n * @notice three\n */\n")
        self.assertEqual([d.text for d in docs], [" one\n two", "\n @notice three\n"])

    def test_an_ordinary_comment_breaks_a_triple_slash_run(self) -> None:
        _, docs = cn.scan("/// one\n// plain\n/// two\n")
        self.assertEqual(len(docs), 2)

    def test_four_slashes_and_strings_are_not_natspec(self) -> None:
        code, docs = cn.scan('//// not doc\nstring s = "/// not doc";\n')
        self.assertEqual(docs, [])
        self.assertNotIn("not doc", code)
        self.assertEqual(len(code), len('//// not doc\nstring s = "/// not doc";\n'))


class ParameterTest(unittest.TestCase):
    def test_names_and_unnamed_parameters(self) -> None:
        self.assertEqual(
            cn.parameter_names(
                "address payable to, uint256, bytes calldata data, uint256[2] memory xs,"
                " address indexed who, address payable"
            ),
            ["to", None, "data", "xs", "who", None],
        )

    def test_nested_types(self) -> None:
        self.assertEqual(cn.parameter_names("IFoo.Bar[] calldata bars, uint256[]"), ["bars", None])


class DeclarationRulesTest(unittest.TestCase):
    def test_a_complete_function_passes(self) -> None:
        src = """
        interface I {
            /// @notice Adds.
            /// @param a The first.
            /// @param b The second.
            /// @return sum The sum.
            function add(uint256 a, uint256 b) external pure returns (uint256 sum);
        }
        """
        self.assertEqual(issues(src), [])

    def test_missing_param_and_return_are_reported(self) -> None:
        src = """
        contract C {
            /// @notice Adds.
            /// @param a The first.
            function add(uint256 a, uint256 b) external pure returns (uint256, uint256) {
                return (a, b);
            }
        }
        """
        self.assertEqual(
            issues(src),
            ["function add: no @param b", "function add: 0 @return for 2 return value(s)"],
        )

    def test_a_param_that_names_nothing_is_reported(self) -> None:
        src = """
        interface I {
            /// @notice F.
            /// @param wrong Nothing.
            function f() external;
        }
        """
        self.assertEqual(issues(src), ["function f: @param wrong names no parameter"])

    def test_a_named_return_must_be_cited_by_name(self) -> None:
        src = """
        interface I {
            /// @notice F.
            /// @return The value.
            function f() external view returns (uint256 value);
        }
        """
        self.assertEqual(issues(src), ["function f: @return does not start with the name value"])

    def test_inheritdoc_satisfies_a_function_and_a_variable(self) -> None:
        src = """
        contract C is I {
            /// @inheritdoc I
            uint256 public value;
            /// @inheritdoc I
            function f(uint256 a) external returns (uint256) { return a; }
        }
        """
        self.assertEqual(issues(src), [])

    def test_internal_and_private_functions_are_ignored(self) -> None:
        src = """
        library L {
            function f(uint256 a) internal pure returns (uint256) { return a; }
            function g(uint256 a) private pure returns (uint256) { return a; }
        }
        function free(uint256 a) pure returns (uint256) { return a; }
        """
        self.assertEqual(issues(src), [])

    def test_undocumented_declarations_of_every_kind(self) -> None:
        src = """
        error FileLevel();
        contract C {
            event E(address indexed who);
            error Bad(uint256 code);
            mapping(address => uint256) public balances;
            uint256 private hidden;
            receive() external payable { }
            function f() public { }
        }
        """
        self.assertEqual(
            issues(src),
            [
                "error FileLevel: no NatSpec",
                "event E: no NatSpec",
                "error Bad: no NatSpec",
                "variable balances: no NatSpec",
                "function receive: no NatSpec",
                "function f: no NatSpec",
            ],
        )

    def test_events_need_params_and_errors_need_only_a_notice(self) -> None:
        src = """
        interface I {
            /// @notice Moved.
            /// @param from The sender.
            event Moved(address indexed from, address indexed to, uint256);
            /// @notice Too low.
            error TooLow(uint256 required, uint256 offered);
            /// @dev Developer text only.
            error NoNotice();
        }
        """
        self.assertEqual(
            issues(src), ["event Moved: no @param to", "error NoNotice: no @notice"]
        )

    def test_the_last_comment_before_a_declaration_is_attached(self) -> None:
        src = """
        contract C {
            /// @notice Stale text for nothing.

            // forge-lint: disable-next-line(mixed-case-function)
            /// @notice F.
            function f() external { }
            uint256 internal x; /// @notice G, a trailing comment documents the next member.
            function g() external { }
        }
        """
        self.assertEqual(issues(src), [])

    def test_a_comment_inside_a_body_documents_nothing_outside_it(self) -> None:
        src = """
        contract C {
            function f() internal {
                /// @notice Not g's.
            }
            function g() external { }
        }
        """
        self.assertEqual(issues(src), ["function g: no NatSpec"])

    def test_multi_line_signatures_and_modifiers_with_arguments(self) -> None:
        src = """
        abstract contract C {
            /// @notice F.
            /// @param a A.
            /// @return Whether.
            function f(uint256 a)
                external
                view
                override(IA, IB)
                onlyRole(keccak256("X"))
                returns (bool)
            {
                return a > 0;
            }
        }
        """
        self.assertEqual(issues(src), [])

    def test_block_comment_natspec(self) -> None:
        src = """
        interface I {
            /**
             * @notice F.
             * @param a A.
             */
            function f(uint256 a) external;
        }
        """
        self.assertEqual(issues(src), [])

    def test_public_constant_and_mapping_getter_names(self) -> None:
        names = [d.name for d in cn.declarations(
            "contract C {\n uint256 public constant MAX = 1;\n"
            " mapping(address a => mapping(address b => uint256)) public owed;\n}"
        )]
        self.assertEqual(names, ["MAX", "owed"])


class MainTest(unittest.TestCase):
    def run_main(self, files: dict[str, str]) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative, text in files.items():
                path = root / "src" / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = cn.main(["--root", str(root)])
            return code, out.getvalue()

    def test_complete_sources_pass(self) -> None:
        code, out = self.run_main({"I.sol": "interface I {\n /// @notice F.\n function f() external;\n}\n"})
        self.assertEqual(code, 0)
        self.assertIn("complete in 1 files", out)

    def test_problems_fail_with_their_location(self) -> None:
        code, out = self.run_main({"a/I.sol": "interface I {\n\n function f() external;\n}\n"})
        self.assertEqual(code, 1)
        self.assertIn("src/a/I.sol:3: function f: no NatSpec", out)
        self.assertIn("1 problem(s) in 1 files", out)

    def test_an_unparsable_file_is_reported_and_the_others_still_checked(self) -> None:
        code, out = self.run_main(
            {
                "A.sol": "contract A {\n function f() external {\n",
                "B.sol": "interface B {\n function g() external;\n}\n",
            }
        )
        self.assertEqual(code, 1)
        self.assertIn("src/A.sol: cannot parse: unbalanced", out)
        self.assertIn("src/B.sol:2: function g: no NatSpec", out)

    def test_a_missing_src_directory_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(SystemExit):
            cn.main(["--root", directory])


if __name__ == "__main__":
    unittest.main()
