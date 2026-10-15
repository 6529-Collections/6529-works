#!/usr/bin/env python3
"""Report line and branch coverage per src/ contract and fail on a regression.

Reads the LCOV file `forge coverage --report lcov` writes and:
  1. prints a per-file table (lines, branches, functions) for every src/ file that has
     executable code, plus the src/ total, as Markdown (also appended to
     $GITHUB_STEP_SUMMARY when that variable is set);
  2. compares each file with its floor in tools/coverage-floors.json and fails when a file
     falls below either floor. A src/ file without an entry must meet the default floor, so new
     code arrives tested; an entry whose file no longer reports coverage fails, so the floors
     stay in step with the tree;
  3. with `--uncovered`, lists every line and branch the run did not reach, file by file;
  4. with `--write-floors`, rewrites the floors from this run: each file's current figure
     minus the margin, rounded down to 0.1. Use it to ratchet floors up after adding tests,
     and review the diff: lowering a floor needs a reason in the PR.

Why per-file floors with a margin. A total hides a regression in a small, critical file
behind growth elsewhere, so each file keeps its own floor. Fuzz and invariant tests reach
some branches only on some seeds, so a floor sits a little below the measured figure (the
margin) instead of on it; anything more than that is a regression the gate reports.

Run from the repository root after
`FOUNDRY_PROFILE=lite forge coverage --report lcov --report summary`:
`python tools/check_coverage.py`. Standard library only.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_LCOV = "lcov.info"
DEFAULT_FLOORS = "tools/coverage-floors.json"
SOURCE_PREFIX = "src/"
METRICS = ("lines", "branches")


@dataclass
class FileCoverage:
    """Coverage of one source file, as LCOV reports it."""

    path: str
    lines_found: int = 0
    lines_hit: int = 0
    branches_found: int = 0
    branches_hit: int = 0
    functions_found: int = 0
    functions_hit: int = 0
    uncovered_lines: list[int] = field(default_factory=list)
    # (line, block, branch) of every branch never taken.
    uncovered_branches: list[tuple[int, int, int]] = field(default_factory=list)

    def percent(self, metric: str) -> float:
        found, hit = {
            "lines": (self.lines_found, self.lines_hit),
            "branches": (self.branches_found, self.branches_hit),
            "functions": (self.functions_found, self.functions_hit),
        }[metric]
        return 100.0 if found == 0 else 100.0 * hit / found


class CoverageError(Exception):
    """The LCOV file or the floors file cannot be used."""


def parse_lcov(text: str) -> dict[str, FileCoverage]:
    """Parses LCOV records into per-file coverage, keyed by the path LCOV names.

    The totals come from the LF/LH, BRF/BRH and FNF/FNH summary lines, which are what
    `forge coverage --report summary` prints; DA and BRDA lines give the uncovered items.
    """
    files: dict[str, FileCoverage] = {}
    current: FileCoverage | None = None
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        if line == "end_of_record":
            if current is None:
                raise CoverageError(f"line {number}: end_of_record without SF")
            current = None
            continue
        key, sep, value = line.partition(":")
        if not sep:
            raise CoverageError(f"line {number}: not an LCOV field: {raw!r}")
        if key == "SF":
            if current is not None:
                raise CoverageError(f"line {number}: SF inside an open record")
            path = value.replace("\\", "/")
            if path in files:
                raise CoverageError(f"line {number}: {path} reported twice")
            current = files[path] = FileCoverage(path)
            continue
        if current is None:
            if key in ("TN",):
                continue
            raise CoverageError(f"line {number}: {key} outside a record")
        try:
            if key == "DA":
                fields = value.split(",")
                line_no, hits = int(fields[0]), int(fields[1])
                if hits == 0:
                    current.uncovered_lines.append(line_no)
            elif key == "BRDA":
                line_no, block, branch, taken = value.split(",")
                where = (int(line_no), int(block), int(branch))
                if taken == "-" or int(taken) == 0:
                    current.uncovered_branches.append(where)
            elif key == "LF":
                current.lines_found = int(value)
            elif key == "LH":
                current.lines_hit = int(value)
            elif key == "BRF":
                current.branches_found = int(value)
            elif key == "BRH":
                current.branches_hit = int(value)
            elif key == "FNF":
                current.functions_found = int(value)
            elif key == "FNH":
                current.functions_hit = int(value)
        except (ValueError, IndexError) as exc:
            raise CoverageError(f"line {number}: malformed {key}: {raw!r}") from exc
    if current is not None:
        raise CoverageError("the last record has no end_of_record")
    return files


def source_files(files: dict[str, FileCoverage]) -> dict[str, FileCoverage]:
    """The src/ files with executable code (interfaces and constant-only files report none)."""
    return {
        path: cov
        for path, cov in sorted(files.items())
        if path.startswith(SOURCE_PREFIX) and cov.lines_found > 0
    }


def total(files: dict[str, FileCoverage]) -> FileCoverage:
    agg = FileCoverage("total")
    for cov in files.values():
        agg.lines_found += cov.lines_found
        agg.lines_hit += cov.lines_hit
        agg.branches_found += cov.branches_found
        agg.branches_hit += cov.branches_hit
        agg.functions_found += cov.functions_found
        agg.functions_hit += cov.functions_hit
    return agg


def _cell(cov: FileCoverage, metric: str) -> str:
    found, hit = {
        "lines": (cov.lines_found, cov.lines_hit),
        "branches": (cov.branches_found, cov.branches_hit),
        "functions": (cov.functions_found, cov.functions_hit),
    }[metric]
    return f"{cov.percent(metric):.2f}% ({hit}/{found})"


def table(files: dict[str, FileCoverage]) -> str:
    rows = [
        "| Contract | Lines | Branches | Functions |",
        "| --- | ---: | ---: | ---: |",
    ]
    for path, cov in files.items():
        rows.append(
            f"| `{path}` | {_cell(cov, 'lines')} | {_cell(cov, 'branches')} "
            f"| {_cell(cov, 'functions')} |"
        )
    agg = total(files)
    rows.append(
        f"| **src/ total** | {_cell(agg, 'lines')} | {_cell(agg, 'branches')} "
        f"| {_cell(agg, 'functions')} |"
    )
    return "\n".join(rows) + "\n"


def uncovered_report(files: dict[str, FileCoverage]) -> str:
    out = []
    for path, cov in files.items():
        if not cov.uncovered_lines and not cov.uncovered_branches:
            continue
        out.append(f"{path}:")
        if cov.uncovered_lines:
            out.append("  lines: " + ", ".join(str(n) for n in sorted(set(cov.uncovered_lines))))
        if cov.uncovered_branches:
            out.append(
                "  branches (line:block:branch): "
                + ", ".join(f"{l}:{b}:{r}" for l, b, r in sorted(cov.uncovered_branches))
            )
    return "\n".join(out) + ("\n" if out else "")


def load_floors(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise CoverageError(f"{path}: not found") from exc
    except json.JSONDecodeError as exc:
        raise CoverageError(f"{path}: not JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise CoverageError(f"{path}: must be a JSON object")
    for key in ("margin", "default", "files"):
        if not isinstance(data.get(key), dict):
            raise CoverageError(f"{path}: '{key}' must be an object")
    for name, floors in [("margin", data["margin"]), ("default", data["default"])] + [
        (f"files[{p}]", f) for p, f in data["files"].items()
    ]:
        if not isinstance(floors, dict) or set(floors) != set(METRICS):
            raise CoverageError(f"{path}: {name} must give exactly {list(METRICS)}")
        for metric in METRICS:
            value = floors[metric]
            if not isinstance(value, (int, float)) or not 0 <= value <= 100:
                raise CoverageError(f"{path}: {name}.{metric} must be a percentage")
    return data


def check(files: dict[str, FileCoverage], floors: dict) -> list[str]:
    """Every failure: a file under a floor, or a floor entry with no file."""
    failures = []
    for path, cov in files.items():
        file_floors = floors["files"].get(path, floors["default"])
        source = "floor" if path in floors["files"] else "default floor (no entry)"
        for metric in METRICS:
            got = cov.percent(metric)
            # Compare at the floors' precision so 99.95 is not "below" a 99.95 floor.
            if round(got, 6) < file_floors[metric]:
                failures.append(
                    f"{path}: {metric} {got:.2f}% is below its {source} {file_floors[metric]}%"
                )
    for path in floors["files"]:
        if path not in files:
            failures.append(
                f"{path}: has a floor but no coverage was reported for it (removed or renamed? "
                "update tools/coverage-floors.json)"
            )
    return failures


def _floor_at(value: float, margin: float) -> float:
    return max(0.0, math.floor((value - margin) * 10 + 1e-9) / 10)


def write_floors(files: dict[str, FileCoverage], floors: dict, path: Path) -> None:
    margin = floors["margin"]
    floors["files"] = {
        p: {m: _floor_at(cov.percent(m), margin[m]) for m in METRICS} for p, cov in files.items()
    }
    path.write_text(json.dumps(floors, indent=2) + "\n", encoding="utf-8", newline="\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lcov", default=DEFAULT_LCOV, help="LCOV file (default: lcov.info)")
    parser.add_argument("--floors", default=DEFAULT_FLOORS, help="floors JSON")
    parser.add_argument("--uncovered", action="store_true", help="list unreached lines/branches")
    parser.add_argument(
        "--write-floors", action="store_true", help="rewrite the floors from this run"
    )
    args = parser.parse_args(argv)

    try:
        files = source_files(parse_lcov(Path(args.lcov).read_text(encoding="utf-8")))
        if not files:
            raise CoverageError(f"{args.lcov}: no src/ file reported coverage")
        floors = load_floors(Path(args.floors))
    except (CoverageError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    report = table(files)
    print(report)
    if args.uncovered:
        print("Unreached lines and branches:\n")
        print(uncovered_report(files) or "none\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("## Coverage (src/)\n\n" + report + "\n")

    if args.write_floors:
        write_floors(files, floors, Path(args.floors))
        print(f"wrote {args.floors}")
        return 0

    failures = check(files, floors)
    if failures:
        print("Coverage regressions:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"Coverage floors hold for {len(files)} src/ files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
