"""Unit tests for check_rules.py, which sits beside this file.

Run with `python tools/test_check_rules.py` or, from the repository root,
`python -m tools.test_check_rules`. Each test builds a small repository in a temporary directory
and shows that the checker reports the fault it exists to find.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location("check_rules", Path(__file__).with_name("check_rules.py"))
cr = importlib.util.module_from_spec(_SPEC)
sys.modules["check_rules"] = cr
_SPEC.loader.exec_module(cr)

TESTS = """contract WidgetTest {
    function test_Move_PaysTheOwner() public { }
    function testFuzz_Move_NeverOverpays(uint256 x) public { }
    function test_GasRule_MoveAtAnyCost() public { }
}

contract WidgetHandler {
    uint256 public violations;
    function forceMove() external { }
}

contract WidgetInvariant {
    function invariant_BalanceCoversOwed() public { }
    function afterInvariant() public { }
}
"""

SPEC = """# Widgets

| ID | Rule | Enforced in | Tested by |
| --- | --- | --- | --- |
| WG-1 | A move pays the owner. | `Widget.move` | [`Widget.t.sol`](../../test/Widget.t.sol) `test_Move_PaysTheOwner` |
| WG-2 | A move never overpays. | `Widget.move` | `testFuzz_Move_NeverOverpays`, INV-WG-1 |
| WG-3 | A move costs what it costs. | `Widget.move` | `test_GasRule_*` |
| WG-4 | (Removed: there is no second move.) | | |
"""

INVARIANTS = """# Invariants

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-WG-1 | The balance covers what is owed. | `invariant_BalanceCoversOwed` | `forceMove` |
| INV-WG-2 | A forced move is refused. | handler check: `forceMove` (`violations`) | as named |
| INV-WG-3 | Every move ends. | after-campaign: `WidgetInvariant.afterInvariant` | all |

| ID | Property | Tests |
| --- | --- | --- |
| PROP-WG-1 | Moves round-trip. | `Widget.t.sol` `testFuzz_Move_NeverOverpays` |
"""

ALLOWLIST = "WG-4 removed no second move\n"


class TempRepo:
    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.write("test/Widget.t.sol", TESTS)
        self.write("docs/spec/widgets.md", SPEC)
        self.write("docs/audit/invariants.md", INVARIANTS)
        self.write("tools/rules-uncovered.txt", ALLOWLIST)

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def edit(self, rel: str, old: str, new: str) -> None:
        path = self.root / rel
        text = path.read_text(encoding="utf-8")
        assert old in text, old
        path.write_text(text.replace(old, new), encoding="utf-8")

    def problems(self) -> list[str]:
        return cr.check(self.root).problems

    def cleanup(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)


class CheckRulesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.cleanup)

    def assertOneProblem(self, needle: str) -> None:
        problems = self.repo.problems()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(needle, problems[0])

    def test_TheCleanTreePasses(self) -> None:
        result = cr.check(self.repo.root)
        self.assertEqual(result.problems, [])
        self.assertEqual(result.rules, 5)
        self.assertEqual(result.invariants, 3)
        self.assertEqual(result.uncovered, [("WG-4", "removed", "no second move")])

    def test_ARuleWithNoTestFails(self) -> None:
        self.repo.edit("docs/spec/widgets.md", "`test_GasRule_*` |", "Per module |")
        self.assertOneProblem("WG-3: names no test")

    def test_AFileAloneIsNotATest(self) -> None:
        self.repo.edit("docs/spec/widgets.md", ") `test_Move_PaysTheOwner` |", ") |")
        self.assertOneProblem("WG-1: names no test")

    def test_ATestThatDoesNotExistFails(self) -> None:
        self.repo.edit("docs/spec/widgets.md", "`test_Move_PaysTheOwner`", "`test_Move_PaysTheOwnr`")
        problems = self.repo.problems()
        self.assertIn("no test function matches test_Move_PaysTheOwnr", problems[0])
        self.assertIn("WG-1: names no test", problems[1])

    def test_AMissingTestFailsEvenBesideOneThatExists(self) -> None:
        self.repo.edit("docs/spec/widgets.md", "`testFuzz_Move_NeverOverpays`, INV", "`testFuzz_Gone`, INV")
        self.assertOneProblem("no test function matches testFuzz_Gone")

    def test_AWildcardMatchingNothingFails(self) -> None:
        self.repo.edit("docs/spec/widgets.md", "`test_GasRule_*`", "`test_WorstCase_*`")
        problems = self.repo.problems()
        self.assertIn("no test function matches test_WorstCase_*", problems[0])

    def test_AMissingTestFileFails(self) -> None:
        self.repo.edit("docs/spec/widgets.md", "[`Widget.t.sol`]", "[`Gadget.t.sol`]")
        self.assertOneProblem("no test file named Gadget.t.sol")

    def test_AnUnknownInvariantIdFails(self) -> None:
        self.repo.edit("docs/spec/widgets.md", "INV-WG-1 |", "INV-WG-9 |")
        self.assertOneProblem("names INV-WG-9")

    def test_AnInvariantNamingAMissingFunctionFails(self) -> None:
        self.repo.edit("docs/audit/invariants.md", "`invariant_BalanceCoversOwed`", "`invariant_Gone`")
        problems = self.repo.problems()
        self.assertIn("INV-WG-1: no test function named invariant_Gone", problems[0])

    def test_AnInvariantNamingNoFunctionFails(self) -> None:
        self.repo.edit("docs/audit/invariants.md", "handler check: `forceMove` (`violations`)", "handler check")
        self.assertOneProblem("INV-WG-2: names no test function")

    def test_AnInvariantNamingAnUnknownContractFails(self) -> None:
        self.repo.edit("docs/audit/invariants.md", "`WidgetInvariant.afterInvariant`", "`GadgetBase.afterInvariant`")
        problems = self.repo.problems()
        self.assertIn("INV-WG-3: no test contract named GadgetBase", problems[0])
        self.assertIn("INV-WG-3: names no test function", problems[1])

    def test_AnUnlistedUncoveredRuleFails(self) -> None:
        self.repo.write("tools/rules-uncovered.txt", "")
        self.assertOneProblem("WG-4: names no test")

    def test_TheAllowlistCanOnlyShrink(self) -> None:
        self.repo.write("tools/rules-uncovered.txt", ALLOWLIST + "WG-1 uncovered stale\n")
        self.assertOneProblem("WG-1: names a test now; remove it")

    def test_AnAllowlistEntryForAnUnknownRuleFails(self) -> None:
        self.repo.write("tools/rules-uncovered.txt", ALLOWLIST + "WG-99 uncovered no such rule\n")
        self.assertOneProblem("WG-99 is not a rule")

    def test_ALiveRuleCannotBeListedAsRemoved(self) -> None:
        self.repo.edit("docs/spec/widgets.md", "`test_GasRule_*` |", "Per module |")
        self.repo.write("tools/rules-uncovered.txt", ALLOWLIST + "WG-3 removed not really\n")
        self.assertOneProblem("WG-3: listed as removed, but the row is a live rule")

    def test_AnUnknownCategoryFails(self) -> None:
        self.repo.write("tools/rules-uncovered.txt", "WG-4 later someday\n")
        problems = self.repo.problems()
        self.assertTrue(any("expected '<ID>" in p for p in problems), problems)

    def test_ADuplicateRuleIdFails(self) -> None:
        self.repo.write("docs/spec/more.md", "| WG-1 | Again. | x | `test_Move_PaysTheOwner` |\n")
        self.assertOneProblem("WG-1: also defined at")

    def test_MainExitsOneOnAProblemAndZeroOtherwise(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(cr.main([], root=self.repo.root), 0)
        self.assertIn("known uncovered: 0 uncovered, 0 declaration-only, 1 removed", out.getvalue())
        self.repo.edit("docs/spec/widgets.md", "`test_GasRule_*` |", "Per module |")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cr.main([], root=self.repo.root), 1)


if __name__ == "__main__":
    unittest.main()
