#!/usr/bin/env python3
"""Checks that every invariant test is selected by exactly one part of each sharded CI job.

Usage (Python 3.10 or later, standard library only), from anywhere:

    python tools/check_invariant_shards.py          # check; exit 1 on a problem
    python tools/check_invariant_shards.py --list   # also print which part runs each test

Why. The Tests job of .github/workflows/ci.yml and the Deep invariants job of nightly.yml run
`forge test` in parallel parts, each with its own filter. A new invariant suite whose contract
name no filter matches would run in no part, and one that two filters match would run twice.
Forge passes when a filter selects nothing, so neither shows up as a failure.

What it does. It reads the Solidity sources (no build is needed), finds every invariant test
Forge would run, and applies each part's filter as Forge does:

- An invariant test is a function whose name starts with `invariant` or `statefulFuzz`, in a
  contract that is not abstract or inherited by one that is not. A function a test contract
  inherits from a base contract counts as that test contract's.
- `--match-test` and `--no-match-test` are regular expressions searched in the test's
  signature (`invariant_Name()`), not its bare name, so a pattern that ends in `$` after the
  name matches nothing. `--match-contract` and `--no-match-contract` are searched in the
  contract's name. `--match-path` and `--no-match-path` are globs over the source path.
- A filter with any other option is refused: this tool would not know what it selects.

Every (contract, test) pair must be selected by exactly one part of each job in JOBS. A job
that is missing, or that has no part with a filter, is a failure too.

Limits. Sources are scanned, not compiled: a contract is found by its `contract X is A, B {`
header, and a base contract by name (the one in the same file first). Regular expressions are
evaluated by Python's `re`, which agrees with Forge's for the patterns a filter needs
(anchors, groups, alternation, classes).
"""

from __future__ import annotations

import argparse
import fnmatch
import re
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Every folder Forge compiles test contracts from: test/Integrators.t.sol imports examples/
# and keeper/test/, so their test contracts run too.
SOURCE_DIRS = ("src", "test", "script", "examples", "keeper")
# (workflow file, job ID): the jobs whose matrix `filter` values split the invariant tests.
JOBS = (
    (".github/workflows/ci.yml", "tests"),
    (".github/workflows/nightly.yml", "deep-invariants"),
)
TEST_PREFIX = re.compile(r"^(?:invariant|statefulFuzz)")
REGEX_OPTIONS = {
    "--match-test": ("test", True),
    "--mt": ("test", True),
    "--no-match-test": ("test", False),
    "--nmt": ("test", False),
    "--match-contract": ("contract", True),
    "--mc": ("contract", True),
    "--no-match-contract": ("contract", False),
    "--nmc": ("contract", False),
}
GLOB_OPTIONS = {
    "--match-path": True,
    "--mp": True,
    "--no-match-path": False,
    "--nmp": False,
}

CONTRACT = re.compile(
    r"\b(abstract\s+)?contract\s+([A-Za-z_$][\w$]*)\s*(?:\bis\b([^{]*))?\{"
)
FUNCTION = re.compile(r"\bfunction\s+([A-Za-z_$][\w$]*)\s*\(([^)]*)\)")
JOB_KEY = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$")
PART_NAME = re.compile(r"^\s*-\s+name:\s*(.+?)\s*$")
PART_FILTER = re.compile(r"^\s*(?:-\s+)?filter:\s*(.+?)\s*$")


class ShardError(Exception):
    pass


@dataclass(frozen=True)
class Test:
    path: str
    contract: str
    name: str

    @property
    def signature(self) -> str:
        return f"{self.name}()"

    def __str__(self) -> str:
        return f"{self.path}:{self.contract}.{self.name}"


@dataclass
class Contract:
    path: str
    name: str
    abstract: bool
    bases: list[str]
    functions: list[str] = field(default_factory=list)


@dataclass
class Filter:
    """One part's `forge test` filter."""

    name: str
    text: str
    # (subject, must match, pattern) for the regular expressions; (must match, glob) for paths.
    regexes: list[tuple[str, bool, re.Pattern]] = field(default_factory=list)
    globs: list[tuple[bool, str]] = field(default_factory=list)

    def selects(self, test: Test) -> bool:
        subjects = {"test": test.signature, "contract": test.contract}
        for subject, wanted, pattern in self.regexes:
            if bool(pattern.search(subjects[subject])) != wanted:
                return False
        for wanted, glob in self.globs:
            if fnmatch.fnmatchcase(test.path, glob) != wanted:
                return False
        return True


# ------------------------------------------------------------------------------- sources


def strip_comments_and_strings(text: str) -> str:
    """`text` with comments removed and string literals emptied, so braces can be counted."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        two = text[i : i + 2]
        if two == "//":
            end = text.find("\n", i)
            i = n if end == -1 else end
        elif two == "/*":
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
            out.append(" ")
        elif text[i] in "\"'":
            quote = text[i]
            i += 1
            while i < n and text[i] != quote:
                i += 2 if text[i] == "\\" else 1
            i += 1
            out.append(quote * 2)
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def _body_end(text: str, open_brace: int) -> int:
    """The index just past the brace that closes the one at `open_brace`."""
    depth = 0
    for i in range(open_brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    return len(text)


def _base_names(clause: str | None) -> list[str]:
    """The contract names of an `is A, B(1, 2), Lib.C` clause."""
    if not clause:
        return []
    names, depth, current = [], 0, ""
    for ch in clause + ",":
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "," and depth == 0:
            name = current.strip().split("(")[0].strip().split(".")[-1]
            if name:
                names.append(name)
            current = ""
            continue
        if depth == 0 or ch == "(":
            current += ch
    return names


def parse_contracts(source: str, path: str) -> list[Contract]:
    """Every contract `source` declares, with the test functions written in its own body."""
    text = strip_comments_and_strings(source)
    found = []
    for m in CONTRACT.finditer(text):
        body = text[m.end() - 1 : _body_end(text, m.end() - 1)]
        contract = Contract(path, m.group(2), bool(m.group(1)), _base_names(m.group(3)))
        for f in FUNCTION.finditer(body):
            if not TEST_PREFIX.match(f.group(1)):
                continue
            if f.group(2).strip():
                raise ShardError(
                    f"{path}: {contract.name}.{f.group(1)} takes parameters; an invariant "
                    "test takes none"
                )
            contract.functions.append(f.group(1))
        found.append(contract)
    return found


def discover(contracts: list[Contract]) -> list[Test]:
    """Every invariant test of every contract that is not abstract, inherited ones included."""
    by_name: dict[str, list[Contract]] = {}
    for c in contracts:
        by_name.setdefault(c.name, []).append(c)

    def resolve(name: str, near: str) -> Contract | None:
        candidates = by_name.get(name, [])
        for c in candidates:
            if c.path == near:
                return c
        return candidates[0] if candidates else None

    def functions(c: Contract, seen: set[tuple[str, str]]) -> list[str]:
        if (c.path, c.name) in seen:
            return []
        seen.add((c.path, c.name))
        names = list(c.functions)
        for base in c.bases:
            parent = resolve(base, c.path)
            if parent:
                names += [f for f in functions(parent, seen) if f not in names]
        return names

    tests = []
    for c in contracts:
        if c.abstract:
            continue
        tests += [Test(c.path, c.name, f) for f in functions(c, set())]
    return sorted(tests, key=lambda t: (t.path, t.contract, t.name))


def scan(root: Path = ROOT) -> list[Test]:
    contracts: list[Contract] = []
    for folder in SOURCE_DIRS:
        for path in sorted((root / folder).rglob("*.sol")):
            rel = path.relative_to(root).as_posix()
            contracts += parse_contracts(path.read_text(encoding="utf-8"), rel)
    return discover(contracts)


# ------------------------------------------------------------------------------- filters


def parse_filter(name: str, text: str) -> Filter:
    """The filter of one part, from its `forge test` arguments."""
    try:
        words = shlex.split(text)
    except ValueError as exc:
        raise ShardError(f"part '{name}': cannot split the filter {text!r}: {exc}") from exc
    result = Filter(name, text)
    i = 0
    while i < len(words):
        option, _, inline = words[i].partition("=")
        if option not in REGEX_OPTIONS and option not in GLOB_OPTIONS:
            raise ShardError(f"part '{name}': the filter option {words[i]!r} is not understood")
        if inline:
            value = inline
        elif i + 1 < len(words):
            i += 1
            value = words[i]
        else:
            raise ShardError(f"part '{name}': {option} has no value")
        if option in GLOB_OPTIONS:
            result.globs.append((GLOB_OPTIONS[option], value))
        else:
            subject, wanted = REGEX_OPTIONS[option]
            try:
                result.regexes.append((subject, wanted, re.compile(value)))
            except re.error as exc:
                raise ShardError(f"part '{name}': {value!r} is not a pattern: {exc}") from exc
        i += 1
    return result


def _unquote(value: str) -> str:
    value = value.split(" #", 1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def workflow_filters(text: str, job: str) -> list[Filter]:
    """The matrix parts of `job` that have a `filter`, in order.

    The workflow is read as text: the job's lines run from `  <job>:` to the next key at the
    same indent, and a part is a `- name:` line with the `filter:` line that follows it.
    """
    lines = text.splitlines()
    start = next(
        (n for n, line in enumerate(lines) if (m := JOB_KEY.match(line)) and m.group(1) == job),
        None,
    )
    if start is None:
        raise ShardError(f"no job '{job}'")
    filters: list[Filter] = []
    name: str | None = None
    for line in lines[start + 1 :]:
        if JOB_KEY.match(line):
            break
        if line.lstrip().startswith("#"):
            continue
        if m := PART_NAME.match(line):
            name = _unquote(m.group(1))
        elif m := PART_FILTER.match(line):
            if name is None:
                raise ShardError(f"job '{job}': a filter has no part name before it")
            filters.append(parse_filter(name, _unquote(m.group(1))))
            name = None
    if not filters:
        raise ShardError(f"job '{job}' has no part with a filter")
    return filters


# --------------------------------------------------------------------------------- check


def check(tests: list[Test], filters: list[Filter]) -> tuple[list[str], dict[str, list[Test]]]:
    """The problems, and the tests each part selects."""
    problems: list[str] = []
    parts: dict[str, list[Test]] = {f.name: [] for f in filters}
    for test in tests:
        chosen = [f.name for f in filters if f.selects(test)]
        for name in chosen:
            parts[name].append(test)
        if not chosen:
            problems.append(f"{test}: no part selects it")
        elif len(chosen) > 1:
            problems.append(f"{test}: selected by {len(chosen)} parts: {', '.join(chosen)}")
    return problems, parts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--list", action="store_true", help="print the tests of each part")
    args = parser.parse_args(argv)
    failed = False
    try:
        tests = scan()
        if not tests:
            raise ShardError("no invariant test found under " + ", ".join(SOURCE_DIRS))
        for workflow, job in JOBS:
            text = (ROOT / workflow).read_text(encoding="utf-8")
            filters = workflow_filters(text, job)
            problems, parts = check(tests, filters)
            for problem in problems:
                print(f"{workflow} ({job}): {problem}", file=sys.stderr)
            failed = failed or bool(problems)
            counts = ", ".join(f"{name}: {len(found)}" for name, found in parts.items())
            print(f"{workflow} ({job}): {len(tests)} invariant tests; {counts}")
            if args.list:
                for name, found in parts.items():
                    for test in found:
                        print(f"  {name}: {test}")
    except (ShardError, OSError) as exc:
        print(f"invariant shards: {exc}", file=sys.stderr)
        return 1
    if failed:
        print(
            "invariant shards: each invariant test must run in exactly one part; change the "
            "filters in the workflow",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
