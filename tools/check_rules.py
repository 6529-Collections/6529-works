#!/usr/bin/env python3
"""Checks that every rule of the specification and every invariant names tests that exist.

Usage (Python 3.10 or later, standard library only), from anywhere:

    python tools/check_rules.py              # check
    python tools/check_rules.py --uncovered  # also list the known uncovered rules

Rules. Every rule row of a table in docs/spec/*.md (a row whose first cell is a rule ID such as
`ECO-13`, `WS-37` or `DCL-4`) and every property row in docs/audit/invariants.md (`PROP-ECO-1`)
has its tests in its last cell. The checker requires that cell to name at least one test that
resolves:

- a test function in backticks, `test_*`, `testFuzz_*`, `invariant_*`, `check_*` or
  `property_*`, possibly qualified by its contract (`AuctionHandlerCoverage.test_EveryPathRuns`),
  must be a function defined in a Solidity file under test/. A `*` matches any characters, so
  `test_GasRule_*` must match at least one function;
- an invariant or property ID (`INV-ECO-2`, `PROP-CNT-1`) must be one docs/audit/invariants.md
  defines.

A Solidity file named in the cell (`SplitVault.t.sol`) must exist under test/, but a file alone
is not a test. A test function named in any cell must exist, whatever else the cell names.

Invariants. Every invariant row of docs/audit/invariants.md (`| INV-STR-1 | ... | Test | ... |`)
must name in its Test cell at least one function defined under test/: an `invariant_*`
function, a handler action that asserts the property ("handler check"), or an `afterInvariant`
hook ("after-campaign"). Every other identifier in backticks in that cell must occur in a test
file, and a qualifying contract (`AuctionInvariantBase.afterInvariant`) must be defined there.

Known uncovered rules. A rule with no test today is listed in tools/rules-uncovered.txt, one
per line: the rule ID, a category (`removed` for a row the spec keeps only to say the rule was
removed, `declaration` for an off-chain convention with no on-chain behaviour to test,
`uncovered` for a rule that should have a test and has none yet) and a note. A listed rule is
reported as known uncovered, not as a failure. The list can only shrink: an entry for a rule
that now names a test, or for an ID the specification does not define, is itself a failure,
and a `removed` entry must be a row whose rule cell starts with "(Removed" or "Retired".

Exits 0 when every reference resolves and every rule without a test is listed, 1 otherwise.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC_DIR = "docs/spec"
INVARIANTS = "docs/audit/invariants.md"
TESTS = "test"
ALLOWLIST = "tools/rules-uncovered.txt"
CATEGORIES = ("removed", "declaration", "uncovered")
REMOVED_MARKS = ("(Removed", "Retired")

RULE_ROW = re.compile(r"^\|\s*([A-Z]{2,4}-\d+[a-z]?)\s*\|(.*)\|\s*$")
INV_ROW = re.compile(r"^\|\s*(INV-[A-Z]{2,4}-\d+)\s*\|(.*)\|\s*$")
PROP_ROW = re.compile(r"^\|\s*(PROP-[A-Z]{2,4}-\d+)\s*\|(.*)\|\s*$")
CATALOGUE_ID = re.compile(r"\b((?:INV|PROP)-[A-Z]{2,4}-\d+)\b")
TICKED = re.compile(r"`([^`\n]+)`")
TEST_PREFIXES = ("test_", "testFuzz_", "invariant_", "check_", "property_")
TEST_TOKEN = re.compile(
    r"^(?:([A-Z][A-Za-z0-9_]*)\.)?((?:test|testFuzz|invariant|check|property)_[A-Za-z0-9_*]+)$"
)
IDENT_TOKEN = re.compile(r"^(?:([A-Z][A-Za-z0-9_]*)\.)?([A-Za-z_][A-Za-z0-9_]*)$")
FUNCTION_DEF = re.compile(r"\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
CONTRACT_DEF = re.compile(r"\b(?:contract|library|interface)\s+([A-Za-z_][A-Za-z0-9_]*)")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


@dataclass
class TestTree:
    """What the Solidity files under test/ define."""

    functions: set[str] = field(default_factory=set)
    contracts: set[str] = field(default_factory=set)
    files: set[str] = field(default_factory=set)
    words: set[str] = field(default_factory=set)

    @classmethod
    def scan(cls, root: Path) -> "TestTree":
        tree = cls()
        for path in sorted(root.rglob("*.sol")):
            tree.files.add(path.name)
            source = path.read_text(encoding="utf-8")
            tree.functions.update(FUNCTION_DEF.findall(source))
            tree.contracts.update(CONTRACT_DEF.findall(source))
            tree.words.update(WORD.findall(source))
        return tree

    def matches(self, name: str) -> bool:
        """Whether a function called `name` exists; `*` in `name` matches any characters."""
        if "*" not in name:
            return name in self.functions
        pattern = re.compile("^" + re.escape(name).replace(r"\*", "[A-Za-z0-9_]*") + "$")
        return any(pattern.match(f) for f in self.functions)


@dataclass
class Row:
    rule: str
    page: str
    line: int
    cells: list[str]

    @property
    def tests(self) -> str:
        return self.cells[-1] if self.cells else ""

    @property
    def text(self) -> str:
        return self.cells[0] if self.cells else ""


def _cells(body: str) -> list[str]:
    return [c.strip() for c in body.split("|")]


def parse_rows(text: str, page: str, pattern: re.Pattern) -> list[Row]:
    rows = []
    for n, line in enumerate(text.splitlines(), 1):
        m = pattern.match(line)
        if m:
            rows.append(Row(m.group(1), page, n, _cells(m.group(2))))
    return rows


def check_rule(row: Row, tree: TestTree, catalogue: set[str]) -> tuple[list[str], int]:
    """Problems with a rule's tests cell, and how many tests in it resolve."""
    problems: list[str] = []
    resolved = 0
    where = f"{row.page}:{row.line} {row.rule}"
    for token in TICKED.findall(row.tests):
        token = token.strip()
        m = TEST_TOKEN.match(token)
        if m:
            owner, name = m.groups()
            if not tree.matches(name):
                problems.append(f"{where}: no test function matches {name}")
            elif owner and owner not in tree.contracts:
                problems.append(f"{where}: no test contract named {owner}")
            else:
                resolved += 1
        elif token.endswith(".sol"):
            if Path(token).name not in tree.files:
                problems.append(f"{where}: no test file named {token}")
    for ref in CATALOGUE_ID.findall(row.tests):
        if ref in catalogue:
            resolved += 1
        else:
            problems.append(f"{where}: names {ref}, which {INVARIANTS} does not define")
    return problems, resolved


def check_invariant(row: Row, tree: TestTree, catalogue: set[str]) -> list[str]:
    """Problems with an invariant row's Test cell (the second-to-last cell)."""
    where = f"{row.page}:{row.line} {row.rule}"
    cell = row.cells[-2] if len(row.cells) >= 3 else row.tests
    problems: list[str] = []
    functions = 0
    for token in TICKED.findall(cell):
        token = token.strip()
        m = IDENT_TOKEN.match(token)
        if not m:
            continue
        owner, name = m.groups()
        if owner and owner not in tree.contracts:
            problems.append(f"{where}: no test contract named {owner}")
        elif name.startswith(TEST_PREFIXES) or owner:
            if name in tree.functions:
                functions += 1
            else:
                problems.append(f"{where}: no test function named {name}")
        elif name in tree.functions:
            functions += 1
        elif name not in tree.words:
            problems.append(f"{where}: {name} occurs in no test file")
    for ref in CATALOGUE_ID.findall(cell):
        if ref not in catalogue:
            problems.append(f"{where}: names {ref}, which is not defined")
    if functions == 0:
        problems.append(f"{where}: names no test function, handler check or after-campaign hook")
    return problems


def parse_allowlist(text: str) -> tuple[dict[str, tuple[str, str]], list[str]]:
    entries: dict[str, tuple[str, str]] = {}
    problems: list[str] = []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) < 2 or parts[1] not in CATEGORIES:
            problems.append(f"{ALLOWLIST}:{n}: expected '<ID> <{'|'.join(CATEGORIES)}> <note>'")
            continue
        if parts[0] in entries:
            problems.append(f"{ALLOWLIST}:{n}: {parts[0]} is listed twice")
        entries[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else "")
    return entries, problems


@dataclass
class Result:
    problems: list[str] = field(default_factory=list)
    uncovered: list[tuple[str, str, str]] = field(default_factory=list)
    rules: int = 0
    invariants: int = 0


def check(root: Path) -> Result:
    tree = TestTree.scan(root / TESTS)
    inv_text = (root / INVARIANTS).read_text(encoding="utf-8")
    invariants = parse_rows(inv_text, INVARIANTS, INV_ROW)
    props = parse_rows(inv_text, INVARIANTS, PROP_ROW)
    catalogue = {r.rule for r in invariants} | {r.rule for r in props}
    rules: list[Row] = []
    for page in sorted((root / SPEC_DIR).glob("*.md")):
        rel = page.relative_to(root).as_posix()
        rules += parse_rows(page.read_text(encoding="utf-8"), rel, RULE_ROW)
    rules += props

    result = Result(rules=len(rules), invariants=len(invariants))
    allow_path = root / ALLOWLIST
    allow, problems = parse_allowlist(allow_path.read_text(encoding="utf-8")) if allow_path.exists() else ({}, [])
    result.problems += problems

    seen: dict[str, Row] = {}
    for row in rules:
        if row.rule in seen:
            other = seen[row.rule]
            result.problems.append(
                f"{row.page}:{row.line} {row.rule}: also defined at {other.page}:{other.line}"
            )
            continue
        seen[row.rule] = row
        problems, resolved = check_rule(row, tree, catalogue)
        result.problems += problems
        listed = allow.get(row.rule)
        if resolved and listed:
            result.problems.append(
                f"{row.page}:{row.line} {row.rule}: names a test now; remove it from {ALLOWLIST}"
            )
        elif not resolved and not listed:
            result.problems.append(f"{row.page}:{row.line} {row.rule}: names no test")
        elif not resolved:
            category, note = listed
            if category == "removed" and not row.text.startswith(REMOVED_MARKS):
                result.problems.append(
                    f"{row.page}:{row.line} {row.rule}: listed as removed, but the row is a live rule"
                )
            result.uncovered.append((row.rule, category, note))
    for rule in sorted(set(allow) - set(seen)):
        result.problems.append(f"{ALLOWLIST}: {rule} is not a rule the specification defines")

    seen_inv: set[str] = set()
    for row in invariants:
        if row.rule in seen_inv:
            result.problems.append(f"{row.page}:{row.line} {row.rule}: defined twice")
        seen_inv.add(row.rule)
        result.problems += check_invariant(row, tree, catalogue)
    return result


def main(argv: list[str], root: Path = ROOT) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--uncovered", action="store_true", help="list the known uncovered rules")
    args = ap.parse_args(argv)
    result = check(root)
    if args.uncovered:
        for rule, category, note in result.uncovered:
            print(f"known uncovered: {rule} ({category}) {note}".rstrip())
    for p in result.problems:
        print(p)
    counts = {c: sum(1 for u in result.uncovered if u[1] == c) for c in CATEGORIES}
    summary = (
        f"{result.rules} rules and {result.invariants} invariants; known uncovered: "
        f"{counts['uncovered']} uncovered, {counts['declaration']} declaration-only, "
        f"{counts['removed']} removed ({ALLOWLIST})"
    )
    if result.problems:
        print(f"{len(result.problems)} problem(s). {summary}")
        return 1
    print(f"Every rule and invariant names tests that exist. {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
