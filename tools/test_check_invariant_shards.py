"""Unit tests for check_invariant_shards.py, which sits beside this file.

Run with `python tools/test_check_invariant_shards.py`.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "check_invariant_shards", Path(__file__).with_name("check_invariant_shards.py")
)
cs = importlib.util.module_from_spec(_SPEC)
sys.modules["check_invariant_shards"] = cs
_SPEC.loader.exec_module(cs)

SOURCE = """
// contract Commented is Test { function invariant_NotCode() public {} }
abstract contract Base is Test {
    function invariant_FromTheBase() public view {}
    function helper() internal {}
}

contract LedgerInvariantTest is Base, Other(1, 2) {
    string internal s = "} contract Fake { function invariant_InAString() public {}";

    function invariant_Ledger() public view {
        if (true) { }
    }

    function test_NotAnInvariant() public {}
    function statefulFuzz_Ledger() public {}
    function invariant_Helper(uint256 x) internal pure returns (uint256) { return x; }
    function invariantPrivate() private {}
}

contract Handler {
    function act(uint256 seed) external {}
}
"""

WORKFLOW = """
jobs:
  docs:
    name: Docs
  tests:
    name: Tests (${{ matrix.name }})
    strategy:
      matrix:
        include:
          - name: unit
            filter: --no-match-test ^invariant
          # - name: commented out
          #   filter: --match-test ^invariant
          - name: ledger
            filter: --match-test ^invariant --match-contract ^Ledger
          - name: "others"
            filter: "--match-test ^invariant --no-match-contract ^Ledger"
    steps:
      - name: Checkout
        uses: actions/checkout@v4
  walkthrough:
    name: Local walkthrough
    strategy:
      matrix:
        include:
          - name: another job
            filter: --match-test ^invariant
"""


def tests_of(source: str, path: str = "test/A.t.sol") -> list[tuple[str, str]]:
    return [(t.contract, t.name) for t in cs.discover(cs.parse_contracts(source, path))]


class DiscoveryTest(unittest.TestCase):
    def test_finds_the_invariants_of_deployable_contracts_and_their_bases(self) -> None:
        self.assertEqual(
            tests_of(SOURCE),
            [
                ("LedgerInvariantTest", "invariant_FromTheBase"),
                ("LedgerInvariantTest", "invariant_Ledger"),
                ("LedgerInvariantTest", "statefulFuzz_Ledger"),
            ],
        )

    def test_an_abstract_contract_runs_nothing_itself(self) -> None:
        self.assertEqual(tests_of("abstract contract A { function invariant_X() public {} }"), [])

    def test_a_base_in_another_file_is_resolved_by_name(self) -> None:
        contracts = cs.parse_contracts(
            "abstract contract Shared { function invariant_Shared() public {} }", "test/S.sol"
        ) + cs.parse_contracts("contract T is Shared { }", "test/T.t.sol")
        self.assertEqual(
            [str(t) for t in cs.discover(contracts)], ["test/T.t.sol:T.invariant_Shared"]
        )

    def test_the_base_in_the_same_file_wins_over_a_namesake(self) -> None:
        contracts = cs.parse_contracts(
            "abstract contract H { function invariant_Elsewhere() public {} }", "test/a/H.sol"
        ) + cs.parse_contracts(
            "abstract contract H { function invariant_Here() public {} } contract T is H { }",
            "test/b/T.t.sol",
        )
        self.assertEqual([t.name for t in cs.discover(contracts)], ["invariant_Here"])

    def test_a_base_imported_under_another_name_is_followed(self) -> None:
        contracts = cs.parse_contracts(
            "abstract contract Shared { function invariant_Shared() public {} }", "test/S.sol"
        ) + cs.parse_contracts(
            'import { Other, Shared as Renamed } from "./S.sol";\ncontract T is Renamed { }',
            "test/T.t.sol",
        )
        self.assertEqual(
            [str(t) for t in cs.discover(contracts)], ["test/T.t.sol:T.invariant_Shared"]
        )

    def test_an_invariant_with_parameters_is_refused_unless_it_is_hidden(self) -> None:
        for visibility in ("public", "external"):
            with self.assertRaises(cs.ShardError):
                cs.parse_contracts(
                    f"contract T {{ function invariant_X(uint256 a) {visibility} {{}} }}", "t.sol"
                )
        for visibility in ("internal", "private", "internal pure"):
            source = f"contract T {{ function invariant_X(uint256 a) {visibility} {{}} }}"
            self.assertEqual(tests_of(source), [])

    def test_the_repository_has_invariant_tests(self) -> None:
        tests = cs.scan()
        self.assertTrue(tests)
        self.assertTrue(all(cs.TEST_PREFIX.match(t.name) for t in tests))
        self.assertEqual(len(tests), len(set(tests)))


class FilterTest(unittest.TestCase):
    TEST = cs.Test("test/economics/Ledger.t.sol", "LedgerInvariantTest", "invariant_Ledger")

    def selects(self, text: str) -> bool:
        return cs.parse_filter("part", text).selects(self.TEST)

    def test_the_test_pattern_is_searched_in_the_signature(self) -> None:
        self.assertTrue(self.selects("--match-test ^invariant"))
        self.assertTrue(self.selects("--match-test ^invariant_(Ledger|Other)"))
        # The signature is `invariant_Ledger()`, so `$` right after the name matches nothing.
        self.assertFalse(self.selects("--match-test ^invariant_Ledger$"))
        self.assertTrue(self.selects(r"--match-test ^invariant_Ledger\("))
        self.assertFalse(self.selects("--no-match-test ^invariant"))

    def test_the_contract_pattern_is_searched_in_the_name(self) -> None:
        self.assertTrue(self.selects("--match-contract ^Ledger"))
        self.assertTrue(self.selects("--match-contract Invariant"))
        self.assertFalse(self.selects("--match-contract ^Invariant"))
        self.assertFalse(self.selects("--no-match-contract ^(Ledger|Auction)"))

    def test_every_condition_must_hold(self) -> None:
        self.assertTrue(self.selects("--match-test ^invariant --match-contract ^Ledger"))
        self.assertFalse(self.selects("--match-test ^invariant --match-contract ^Auction"))
        self.assertFalse(self.selects("--match-test ^invariant --no-match-contract ^Ledger"))

    def test_path_globs_and_short_and_inline_forms(self) -> None:
        self.assertTrue(self.selects("--match-path test/economics/*"))
        self.assertFalse(self.selects("--no-match-path test/economics/*"))
        self.assertTrue(self.selects("--mt ^invariant --mc ^Ledger"))
        self.assertTrue(self.selects("--match-test=^invariant"))
        self.assertFalse(self.selects("--nmc=^Ledger"))

    def test_an_option_the_tool_does_not_know_is_refused(self) -> None:
        for text in ("--fuzz-runs 10", "--match-test", "--match-test (", "-vv"):
            with self.assertRaises(cs.ShardError, msg=text):
                cs.parse_filter("part", text)

    def test_a_quoted_pattern_is_refused(self) -> None:
        # `forge test $FILTER` removes no quotes: Forge would get them inside the pattern
        # and select nothing.
        for text in ("--match-test '^invariant'", '--match-test "^invariant"'):
            with self.assertRaises(cs.ShardError, msg=text):
                cs.parse_filter("part", text)


class WorkflowTest(unittest.TestCase):
    def test_reads_the_parts_of_the_named_job_only(self) -> None:
        filters = cs.workflow_filters(WORKFLOW, "tests")
        self.assertEqual([f.name for f in filters], ["unit", "ledger", "others"])
        self.assertEqual(filters[2].text, "--match-test ^invariant --no-match-contract ^Ledger")

    def test_a_missing_job_or_a_job_without_a_matrix_fails(self) -> None:
        with self.assertRaises(cs.ShardError):
            cs.workflow_filters(WORKFLOW, "absent")
        with self.assertRaises(cs.ShardError):
            cs.workflow_filters(WORKFLOW, "docs")

    def test_a_part_without_a_filter_or_a_name_fails(self) -> None:
        # GitHub reads a missing matrix value as empty, so the part would run every test.
        unfiltered = WORKFLOW.replace(
            "          - name: ledger\n", "          - name: everything\n          - name: ledger\n"
        )
        with self.assertRaisesRegex(cs.ShardError, "'everything' has no filter"):
            cs.workflow_filters(unfiltered, "tests")
        unnamed = WORKFLOW.replace("          - name: ledger\n            filter:", "          - filter:")
        with self.assertRaisesRegex(cs.ShardError, "has no name"):
            cs.workflow_filters(unnamed, "tests")


class CheckTest(unittest.TestCase):
    TESTS = [
        cs.Test("test/a.t.sol", "LedgerInvariantTest", "invariant_A"),
        cs.Test("test/b.t.sol", "AuctionInvariantTest", "invariant_B"),
    ]

    def test_each_test_in_exactly_one_part_passes(self) -> None:
        problems, parts = cs.check(self.TESTS, cs.workflow_filters(WORKFLOW, "tests"))
        self.assertEqual(problems, [])
        self.assertEqual({name: len(found) for name, found in parts.items()},
                         {"unit": 0, "ledger": 1, "others": 1})

    def test_a_test_no_part_selects_is_reported(self) -> None:
        filters = [cs.parse_filter("ledger", "--match-test ^invariant --match-contract ^Ledger")]
        problems, _ = cs.check(self.TESTS, filters)
        self.assertEqual(
            problems, ["test/b.t.sol:AuctionInvariantTest.invariant_B: no part selects it"]
        )

    def test_a_test_two_parts_select_is_reported(self) -> None:
        filters = [
            cs.parse_filter("ledger", "--match-test ^invariant --match-contract ^Ledger"),
            cs.parse_filter("all", "--match-test ^invariant"),
            cs.parse_filter("auction", "--match-test ^invariant --match-contract ^Auction"),
        ]
        problems, _ = cs.check(self.TESTS, filters)
        self.assertEqual(len(problems), 2)
        self.assertIn("selected by 2 parts: ledger, all", problems[0])
        self.assertIn("selected by 2 parts: all, auction", problems[1])

    def test_the_workflows_select_every_invariant_exactly_once(self) -> None:
        tests = cs.scan()
        for workflow, job in cs.JOBS:
            text = (cs.ROOT / workflow).read_text(encoding="utf-8")
            problems, _ = cs.check(tests, cs.workflow_filters(text, job))
            self.assertEqual(problems, [], workflow)


if __name__ == "__main__":
    unittest.main()
