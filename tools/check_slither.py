#!/usr/bin/env python3
"""Fail on High or Medium Slither findings that the triage record does not disposition.

The gate:
  1. runs Slither on the Foundry project (config: slither.config.json, which filters
     lib/, test/ and script/ so only src/ is analysed) and reads its JSON report, or
     reads a report you already have with `--report`;
  2. requires every High or Medium impact finding to match a row of
     docs/security/slither-triage.md (detector, location, disposition, reason);
  3. fails closed: an unreadable or failed report, a Slither run that analysed no
     contracts, a malformed finding or a malformed triage row all fail the gate.

Lower impacts (Low, Informational, Optimization) are counted but never gate.

Run from anywhere: `python tools/check_slither.py`. Standard library only; Slither
itself comes from the hash-locked requirements-tools.lock. Note that Slither runs
`forge clean` and a full `forge build`, so it rebuilds your local out/ directory.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

GATED_IMPACTS = ("High", "Medium")
DISPOSITIONS = ("false-positive", "accepted")
TRIAGE_PATH = "docs/security/slither-triage.md"
CONFIG_PATH = "slither.config.json"

DETECTOR = re.compile(r"^[a-z0-9][a-z0-9-]*$")
LOCATION = re.compile(
    r"^(?P<file>[^:\s]+\.sol)"
    r"(?::(?P<contract>[A-Za-z_$][\w$]*)(?:\.(?P<function>[A-Za-z_$][\w$]*))?)?$"
)
SEPARATOR_CELL = re.compile(r"^:?-{3,}:?$")
ANALYZED = re.compile(r"analyzed \((\d+) contracts?")
MAX_PARENT_DEPTH = 6


@dataclass(frozen=True)
class Location:
    """Where a finding sits: a file, optionally narrowed to a contract and a function.

    Line numbers are deliberately absent so a triage row survives unrelated edits.
    """

    file: str
    contract: str | None = None
    function: str | None = None

    def __str__(self) -> str:
        text = self.file
        if self.contract:
            text += f":{self.contract}"
            if self.function:
                text += f".{self.function}"
        return text


@dataclass(frozen=True)
class Row:
    detector: str
    location: Location
    disposition: str
    reason: str
    line: int

    def covers(self, detector: str, found: Location) -> bool:
        """A row covers a finding of its detector at its file, contract or function."""
        return (
            self.detector == detector
            and self.location.file == found.file
            and self.location.contract in (None, found.contract)
            and self.location.function in (None, found.function)
        )


class Report:
    """Ordered result lines, like the budget checker: `ok`, `note` or `FAIL`."""

    def __init__(self) -> None:
        self.lines: list[tuple[str, str]] = []
        self.failures = 0

    def ok(self, message: str) -> None:
        self.lines.append(("ok   ", message))

    def note(self, message: str) -> None:
        self.lines.append(("note ", message))

    def fail(self, message: str) -> None:
        self.failures += 1
        self.lines.append(("FAIL ", message))

    def extra(self, message: str) -> None:
        self.lines.append(("     ", message))

    def render(self) -> str:
        return "\n".join(prefix + message for prefix, message in self.lines)


def parse_triage(text: str) -> tuple[list[Row], list[str]]:
    """Rows of the triage tables, plus an error for every malformed table row.

    A table row is a line starting with `|` outside a code fence. The header and the
    separator are skipped; everything else must be detector | location | disposition |
    reason, with a known disposition and a non-empty reason.
    """
    rows: list[Row] = []
    errors: list[str] = []
    fenced = False
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if line.startswith("```"):
            fenced = not fenced
            continue
        if fenced or not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if all(SEPARATOR_CELL.match(cell) for cell in cells):
            continue
        if cells[0].strip("`*").lower() == "detector":
            continue
        if len(cells) != 4:
            errors.append(f"line {number}: expected 4 cells (detector, location, disposition, reason)")
            continue
        detector, location, disposition, reason = (cell.strip("`*") for cell in cells)
        parsed = LOCATION.match(location)
        if not DETECTOR.match(detector):
            errors.append(f"line {number}: invalid detector {detector!r}")
        elif not parsed:
            errors.append(
                f"line {number}: invalid location {location!r}"
                " (use path.sol, path.sol:Contract or path.sol:Contract.function)"
            )
        elif disposition not in DISPOSITIONS:
            errors.append(
                f"line {number}: disposition {disposition!r} is not one of {', '.join(DISPOSITIONS)}"
            )
        elif not reason:
            errors.append(f"line {number}: a disposition needs a reason")
        else:
            rows.append(
                Row(
                    detector,
                    Location(parsed["file"], parsed["contract"], parsed["function"]),
                    disposition,
                    reason,
                    number,
                )
            )
    return rows, errors


def element_location(element: object) -> Location | None:
    """The file, contract and function of a Slither element, found by walking its parents.

    A function reports its contract as parent; a statement reports its function; a
    variable reports its contract or function; a contract stands alone.
    """
    chain: list[dict] = []
    node = element
    while isinstance(node, dict) and len(chain) < MAX_PARENT_DEPTH:
        chain.append(node)
        fields = node.get("type_specific_fields")
        node = fields.get("parent") if isinstance(fields, dict) else None
    file = contract = function = None
    for item in chain:
        mapping = item.get("source_mapping")
        if file is None and isinstance(mapping, dict):
            name = mapping.get("filename_relative")
            if isinstance(name, str) and name:
                file = name.replace("\\", "/")
        if contract is None and item.get("type") == "contract":
            contract = item.get("name")
        if function is None and item.get("type") == "function":
            function = item.get("name")
    if file is None:
        return None
    return Location(
        file,
        contract if isinstance(contract, str) else None,
        function if isinstance(function, str) and isinstance(contract, str) else None,
    )


def finding_location(finding: dict) -> Location | None:
    """The location of a finding's first element that has one (Slither lists the primary first)."""
    for element in finding.get("elements") or []:
        found = element_location(element)
        if found:
            return found
    return None


def _headline(finding: dict) -> str:
    description = finding.get("description")
    return description.strip().splitlines()[0] if isinstance(description, str) and description.strip() else ""


def evaluate(slither: object, rows: list[Row], triage_name: str, report: Report) -> None:
    """Check a decoded Slither JSON report against the triage rows."""
    if not isinstance(slither, dict):
        report.fail("slither report: expected a JSON object")
        return
    if slither.get("success") is not True:
        report.fail(f"slither report: analysis did not succeed ({slither.get('error')})")
        return
    results = slither.get("results")
    findings = results.get("detectors") if isinstance(results, dict) else None
    if not isinstance(findings, list):
        report.fail("slither report: no results.detectors list")
        return

    used: set[int] = set()
    counts: Counter[str] = Counter()
    gated = 0
    for index, finding in enumerate(findings):
        if not isinstance(finding, dict) or not isinstance(finding.get("check"), str) or not isinstance(
            finding.get("impact"), str
        ):
            report.fail(f"slither report: finding {index} lacks a check name or impact")
            continue
        detector, impact = finding["check"], finding["impact"].title()
        counts[impact] += 1
        if impact not in GATED_IMPACTS:
            continue
        gated += 1
        found = finding_location(finding)
        label = f"{detector} ({impact}) at {found or 'an unknown location'}"
        row = next(
            (candidate for candidate in rows if found and candidate.covers(detector, found)), None
        )
        if row:
            used.add(row.line)
            report.ok(f"{label}: {row.disposition} (triage line {row.line})")
        else:
            report.fail(f"{label}: not dispositioned in {triage_name}")
            report.extra(_headline(finding))
    for row in rows:
        if row.line not in used:
            report.note(f"triage line {row.line} ({row.detector} at {row.location}) matches no finding")
    others = ", ".join(f"{name} {count}" for name, count in sorted(counts.items()) if name not in GATED_IMPACTS)
    report.ok(f"{gated} High/Medium findings gated; not gated: {others or 'none'}")


def run_slither(root: Path, config: Path, command: list[str], output: Path) -> tuple[str, int]:
    """Run Slither, writing its JSON report to `output`; returns its combined log."""
    result = subprocess.run(
        [*command, ".", "--config-file", str(config), "--json", str(output), "--fail-none"],
        cwd=root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return result.stdout + result.stderr, result.returncode


def check_report_file(path: Path, rows: list[Row], triage_name: str, report: Report) -> None:
    try:
        slither = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        report.fail(f"slither report: cannot read {path.name} ({error})")
        return
    evaluate(slither, rows, triage_name, report)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, help="repository root (default: this file's parent)")
    parser.add_argument("--report", type=Path, help="check this Slither JSON report instead of running Slither")
    parser.add_argument("--triage", type=Path, help=f"triage record (default: {TRIAGE_PATH})")
    parser.add_argument("--config", type=Path, help=f"Slither config (default: {CONFIG_PATH})")
    parser.add_argument(
        "--slither-command",
        help="shell-style command that starts Slither (default: this Python's slither module)",
    )
    args = parser.parse_args(argv)

    root = args.root or Path(__file__).resolve().parent.parent
    triage = args.triage or root / TRIAGE_PATH
    config = args.config or root / CONFIG_PATH
    report = Report()

    try:
        rows, errors = parse_triage(triage.read_text(encoding="utf-8"))
    except OSError as error:
        rows, errors = [], [f"cannot read {triage} ({error})"]
    for error in errors:
        report.fail(f"{triage.name}: {error}")

    if args.report:
        check_report_file(args.report, rows, triage.name, report)
    else:
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "slither.json"
            command = shlex.split(args.slither_command) if args.slither_command else [
                sys.executable,
                "-m",
                "slither",
            ]
            log, code = run_slither(root, config, command, output)
            analyzed = ANALYZED.search(log)
            if not output.is_file():
                report.fail(f"slither produced no report (exit {code}); its output follows")
                report.extra(log.strip()[-3000:])
            elif not analyzed or int(analyzed.group(1)) == 0:
                report.fail("slither analysed no contracts: check slither.config.json filters")
                report.extra(log.strip()[-3000:])
            else:
                report.ok(f"slither analysed {analyzed.group(1)} contracts")
                check_report_file(output, rows, triage.name, report)

    print(report.render())
    if report.failures:
        print(f"slither triage: {report.failures} failure(s)")
        return 1
    print("slither triage: every High/Medium finding is dispositioned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
