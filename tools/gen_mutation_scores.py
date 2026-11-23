#!/usr/bin/env python3
"""Generate the tables of docs/testing/mutation-scores.md from tools/mutation-scores.json.

The page keeps its hand-written prose. This script owns only the regions between a pair of
marker lines, each an HTML comment on a line of its own:

  <!-- generated:scores tier=1 -->   the kill-rate table of the permanent contracts
  <!-- generated:scores tier=2 -->   ... of the modules that hold money or authorise mints
  <!-- generated:scores tier=3 -->   ... of every other file
  <!-- generated:tests -->           the count and the list of the tests added
  <!-- generated:survivors -->       one section per file whose survivors were triaged
  <!-- /generated -->                closes the region opened last

Everything between an opening marker and its closing marker is rewritten: one blank line,
the generated text, one blank line. Everything outside the markers is left as it is.

The data file, tools/mutation-scores.json:

  "margin"     points between a file's final score and its floor.
  "files"      path -> {"tier": 1, 2 or 3 (the table the file is listed in),
                        "mutants", "killed", "timedOut": the campaign's counts
                            (a mutant that timed out counts as killed),
                        "newKills": survivors a test added afterwards kills,
                        "floor": the floor in whole points, null for a file with no mutants,
                        "was": the floor before this measurement, or null,
                        "remeasured": optional {"mutants", "killed"}, a later whole
                            measurement of the file,
                        "measuredAt": optional, the commit `--merge` was given}.
               Survived is mutants - killed. Score is killed / mutants. Final is
               (killed + newKills) / mutants, or the rate of "remeasured" where there is one
               (shown with "(measured again)"). The floor must be the final score minus the
               margin, rounded down, and never below zero: anything else fails.
  "survivors"  path -> the file's surviving mutants in page order, each
               {"line", "rule", "verdict", "why"}. A file listed here must list every
               survivor, and as many "killed" rows as its "newKills". The line under the
               heading ("48 survivors: 45 equivalent, 2 killed, 1 gas.") is counted from the
               rows, verdicts in the order they first appear.
  "addenda"    path -> blocks shown after the file's survivor table, each {"text": [lines]}
               or {"rows": [survivor rows]}. Their rows are not counted as survivors.
  "tests"      the tests added: [{"file", "tests": [{"name", "where": ["Stem L123", ...]}]}].
               "name" is the text between the backticks. The count on the page is the
               number of these entries.

Usage, from anywhere:
  python tools/gen_mutation_scores.py                 rewrite the regions of the page
  python tools/gen_mutation_scores.py --check         fail if the page, the data and
                                                      tools/mutation-floors.json disagree (CI)
  python tools/gen_mutation_scores.py --write-floors  also write the floors file from the data
  python tools/gen_mutation_scores.py --merge REPORT.json [--commit SHA]
        take new measurements from `python tools/mutation.py report ... --json REPORT.json`,
        then rewrite the data file and the page

`--merge` replaces a file's counts with the report's, keeps its previous floor as "was",
sets "newKills" to zero, and drops the file's "remeasured" figures, survivor rows and addenda:
they describe mutants of older code. A file the report did not finish (a status other than
"ok"), or one the data file does not list, refuses the whole merge.

Standard library only.
"""

from __future__ import annotations

import argparse
import copy
import difflib
import json
import math
import re
import sys
from fractions import Fraction
from pathlib import Path

DATA = "tools/mutation-scores.json"
PAGE = "docs/testing/mutation-scores.md"
FLOORS = "tools/mutation-floors.json"

TIERS = (1, 2, 3)
REGIONS = tuple(f"scores tier={tier}" for tier in TIERS) + ("tests", "survivors")

OPEN_MARKER = re.compile(r"<!-- generated:([a-z]+(?: [a-z]+=[a-z0-9]+)*) -->")
CLOSE_MARKER = "<!-- /generated -->"
MARKER_LIKE = re.compile(r"\s*<!--\s*/?generated\b")

TOP_KEYS = ("margin", "files", "survivors", "addenda", "tests")
FILE_KEYS = ("tier", "mutants", "killed", "timedOut", "newKills", "floor", "was")
FILE_OPTIONAL_KEYS = ("remeasured", "measuredAt")
ROW_KEYS = ("line", "rule", "verdict", "why")

SCORES_HEADER = (
    "| Contract | Mutants | Killed | Survived | Timed out | Score | Killed by new tests "
    "| Final | Floor |\n"
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"
)
SURVIVORS_HEADER = "| Line | Rule | Verdict | Why, or the test |\n| ---: | --- | --- | --- |\n"


class DataError(Exception):
    """The data file, a report or the page's markers cannot be used as they are."""


# Scores and floors


def percent(killed: int, mutants: int) -> str:
    """A kill rate to one decimal, or "n/a" for a file with nothing to mutate."""
    return "n/a" if mutants == 0 else f"{100.0 * killed / mutants:.1f}%"


def final_counts(entry: dict) -> tuple[int, int]:
    """The (killed, mutants) pair a file's final score and floor are counted from."""
    again = entry.get("remeasured")
    if again:
        return again["killed"], again["mutants"]
    return entry["killed"] + entry["newKills"], entry["mutants"]


def compute_floor(killed: int, mutants: int, margin: float) -> int | None:
    """The rate minus `margin` points, rounded down, never below zero; None with no mutants.

    Exact arithmetic: a rate of exactly 93.0% with a margin of 2 gives 91, and 92.98% gives 90.
    """
    if mutants == 0:
        return None
    return max(0, math.floor(Fraction(100 * killed, mutants) - Fraction(str(margin))))


def expected_floor(entry: dict, margin: float) -> int | None:
    killed, mutants = final_counts(entry)
    return compute_floor(killed, mutants, margin)


def _is_count(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def validate(data: dict) -> list[str]:
    """Every reason the data cannot be rendered; an empty list when it is consistent."""
    errors: list[str] = []
    unknown = sorted(set(data) - set(TOP_KEYS))
    if unknown:
        errors.append(f"unknown keys {unknown}")
    margin = data.get("margin")
    if isinstance(margin, bool) or not isinstance(margin, (int, float)) or margin < 0:
        return errors + ["margin is not a number of points"]
    files = data.get("files")
    if not isinstance(files, dict):
        return errors + ["files is not a map"]

    for path, entry in files.items():
        missing = [key for key in FILE_KEYS if key not in entry]
        extra = sorted(set(entry) - set(FILE_KEYS) - set(FILE_OPTIONAL_KEYS))
        if missing or extra:
            errors.append(f"{path}: missing keys {missing}, unknown keys {extra}")
            continue
        if entry["tier"] not in TIERS:
            errors.append(f"{path}: tier {entry['tier']!r} is not one of {list(TIERS)}")
        counts = ("mutants", "killed", "timedOut", "newKills")
        if not all(_is_count(entry[key]) for key in counts):
            errors.append(f"{path}: {', '.join(counts)} must be whole numbers")
            continue
        if entry["killed"] > entry["mutants"] or entry["timedOut"] > entry["killed"]:
            errors.append(f"{path}: more killed than mutants, or more timed out than killed")
            continue
        if entry["newKills"] > entry["mutants"] - entry["killed"]:
            errors.append(f"{path}: more killed by new tests than survived")
            continue
        again = entry.get("remeasured")
        if again is not None and not (
            isinstance(again, dict) and set(again) == {"mutants", "killed"}
            and _is_count(again["mutants"]) and _is_count(again["killed"])
            and 0 < again["mutants"] >= again["killed"]
        ):
            errors.append(f"{path}: remeasured must be {{mutants, killed}} with mutants")
            continue
        if entry["was"] is not None and not _is_count(entry["was"]):
            errors.append(f"{path}: was must be a whole number or null")
        want = expected_floor(entry, margin)
        if entry["floor"] != want:
            killed, mutants = final_counts(entry)
            errors.append(
                f"{path}: floor {_shown(entry['floor'])} is not the final score "
                f"{percent(killed, mutants)} minus {margin:g} points, rounded down "
                f"({_shown(want)})"
            )

    survivors = data.get("survivors", {})
    for path, rows in survivors.items():
        if path not in files:
            errors.append(f"survivors of {path}: the file is not in files")
            continue
        bad = _bad_rows(rows)
        if bad:
            errors.append(f"survivors of {path}: {bad}")
            continue
        entry = files[path]
        if not all(_is_count(entry.get(key)) for key in ("mutants", "killed", "newKills")):
            continue
        survived = entry["mutants"] - entry["killed"]
        if len(rows) != survived:
            errors.append(f"survivors of {path}: {len(rows)} rows for {survived} survivors")
        killed_rows = sum(1 for row in rows if row["verdict"] == "killed")
        if killed_rows != entry["newKills"]:
            errors.append(
                f"survivors of {path}: {killed_rows} rows are killed, "
                f"but newKills is {entry['newKills']}"
            )

    for path, blocks in data.get("addenda", {}).items():
        if path not in survivors:
            errors.append(f"addenda of {path}: the file has no survivors listed")
        for block in blocks if isinstance(blocks, list) else [None]:
            if isinstance(block, dict) and set(block) == {"text"} and _is_text_lines(block["text"]):
                continue
            if isinstance(block, dict) and set(block) == {"rows"} and not _bad_rows(block["rows"]):
                continue
            errors.append(f"addenda of {path}: a block is neither text lines nor survivor rows")

    tests = data.get("tests", [])
    for group in tests if isinstance(tests, list) else [None]:
        if not (isinstance(group, dict) and set(group) == {"file", "tests"}
                and isinstance(group["file"], str) and isinstance(group["tests"], list)):
            errors.append("tests: an entry is not {file, tests}")
            continue
        for test in group["tests"]:
            if not (isinstance(test, dict) and set(test) == {"name", "where"}
                    and isinstance(test["name"], str) and "`" not in test["name"]
                    and isinstance(test["where"], list) and test["where"]
                    and all(isinstance(place, str) for place in test["where"])):
                errors.append(f"tests of {group['file']}: an entry is not {{name, where}}")
    return errors


def _shown(floor: int | None) -> str:
    return "none" if floor is None else str(floor)


def _is_text_lines(value: object) -> bool:
    return isinstance(value, list) and bool(value) and all(
        isinstance(line, str) and line for line in value
    )


def _bad_rows(rows: object) -> str:
    if not isinstance(rows, list):
        return "not a list of rows"
    for row in rows:
        if not (isinstance(row, dict) and set(row) == set(ROW_KEYS)):
            return f"a row does not have exactly {list(ROW_KEYS)}"
        if not _is_count(row["line"]):
            return "a row's line is not a whole number"
        if not all(isinstance(row[key], str) and row[key] for key in ROW_KEYS[1:]):
            return "a row has an empty or non-text cell"
    return ""


# Rendering


def escape_cell(text: str) -> str:
    """Text as one table cell: a pipe is escaped and a line break becomes a space."""
    return text.replace("|", "\\|").replace("\n", " ")


def render_scores(files: dict, tier: int, margin: float) -> str:
    """The kill-rate table of one tier: a row per file by path, then the totals."""
    out = [SCORES_HEADER]
    total = {"mutants": 0, "killed": 0, "timedOut": 0, "newKills": 0}
    for path in sorted(p for p, entry in files.items() if entry["tier"] == tier):
        entry = files[path]
        for key in total:
            total[key] += entry[key]
        mutants, killed = entry["mutants"], entry["killed"]
        final = percent(*final_counts(entry))
        if entry.get("remeasured"):
            final += " (measured again)"
        floor = _shown(expected_floor(entry, margin))
        if entry["was"] is not None and entry["was"] != entry["floor"]:
            floor += f" (was {entry['was']})"
        out.append(
            f"| `{path}` | {mutants} | {killed} | {mutants - killed} | {entry['timedOut']} "
            f"| {percent(killed, mutants)} | {entry['newKills']} | {final} | {floor} |\n"
        )
    mutants, killed = total["mutants"], total["killed"]
    cells = [
        "Total", mutants, killed, mutants - killed, total["timedOut"], percent(killed, mutants),
        total["newKills"], percent(killed + total["newKills"], mutants),
    ]
    out.append("| " + " | ".join(f"**{cell}**" for cell in cells) + " | |\n")
    return "".join(out)


def render_tests(tests: list) -> str:
    """The count of the tests added and the list: test file, test, the mutants it kills."""
    count = sum(len(group["tests"]) for group in tests)
    if count == 0:
        return ""
    out = [f"{count} test functions, each shown to fail on the mutants it is listed with:\n\n"]
    for group in tests:
        out.append(f"- `{group['file']}`\n")
        for test in group["tests"]:
            out.append(f"  - `{test['name']}` ({', '.join(test['where'])})\n")
    return "".join(out)


def survivor_summary(rows: list) -> str:
    """"10 survivors: 8 equivalent, 2 killed." with verdicts in the order they first appear."""
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["verdict"]] = counts.get(row["verdict"], 0) + 1
    parts = ", ".join(f"{count} {verdict}" for verdict, count in counts.items())
    return f"{len(rows)} survivors: {parts}."


def render_survivor_table(rows: list) -> str:
    out = [SURVIVORS_HEADER]
    for row in rows:
        out.append(
            f"| {row['line']} | {escape_cell(row['rule'])} | {escape_cell(row['verdict'])} "
            f"| {escape_cell(row['why'])} |\n"
        )
    return "".join(out)


def render_survivors(files: dict, survivors: dict, addenda: dict) -> str:
    """A section per file with survivors listed, ordered by tier and then by path."""
    sections = []
    for path in sorted(survivors, key=lambda p: (files[p]["tier"], p)):
        rows = survivors[path]
        if not rows:
            continue
        blocks = [f"### `{path}`\n", survivor_summary(rows) + "\n", render_survivor_table(rows)]
        for block in addenda.get(path, []):
            if "text" in block:
                blocks.append("".join(line + "\n" for line in block["text"]))
            else:
                blocks.append(render_survivor_table(block["rows"]))
        sections.append("\n".join(blocks))
    return "\n".join(sections)


def render_regions(data: dict) -> dict[str, str]:
    """The text of every region, by the name its opening marker carries."""
    errors = validate(data)
    if errors:
        raise DataError("\n".join(errors))
    regions = {
        f"scores tier={tier}": render_scores(data["files"], tier, data["margin"])
        for tier in TIERS
    }
    regions["tests"] = render_tests(data.get("tests", []))
    regions["survivors"] = render_survivors(
        data["files"], data.get("survivors", {}), data.get("addenda", {})
    )
    return regions


# The page


def parse_regions(page: str) -> list[tuple[str | None, str]]:
    """The page as (region name or None, text) pieces in order.

    A piece named None is hand-written text and includes the marker lines around it; a named
    piece is what lies between a region's markers. Joining the texts gives the page back.
    A marker that is malformed, nested, unclosed, repeated, unknown or missing is an error.
    """
    pieces: list[tuple[str | None, str]] = []
    buffer: list[str] = []
    current: str | None = None
    opened_at = 0
    seen: set[str] = set()
    for number, line in enumerate(page.splitlines(keepends=True), start=1):
        text = line.rstrip("\n")
        opening = OPEN_MARKER.fullmatch(text)
        if opening:
            name = opening.group(1)
            if current is not None:
                raise DataError(
                    f"line {number}: `{name}` opens inside `{current}` (line {opened_at})"
                )
            if name not in REGIONS:
                raise DataError(f"line {number}: unknown region `{name}`")
            if name in seen:
                raise DataError(f"line {number}: region `{name}` appears twice")
            seen.add(name)
            buffer.append(line)
            pieces.append((None, "".join(buffer)))
            buffer, current, opened_at = [], name, number
        elif text == CLOSE_MARKER:
            if current is None:
                raise DataError(f"line {number}: a closing marker with no region open")
            pieces.append((current, "".join(buffer)))
            buffer, current = [line], None
        elif MARKER_LIKE.match(text):
            raise DataError(f"line {number}: malformed marker `{text.strip()}`")
        else:
            buffer.append(line)
    if current is not None:
        raise DataError(f"line {opened_at}: region `{current}` is never closed")
    pieces.append((None, "".join(buffer)))
    missing = [name for name in REGIONS if name not in seen]
    if missing:
        raise DataError("no marker for " + ", ".join(f"`{name}`" for name in missing))
    return pieces


def region_body(text: str) -> str:
    """What stands between two markers: the text with a blank line on each side."""
    return "\n" + text + "\n" if text else "\n"


def regenerate(page: str, data: dict) -> str:
    """The page with every region rewritten from the data."""
    regions = render_regions(data)
    return "".join(
        text if name is None else region_body(regions[name])
        for name, text in parse_regions(page)
    )


# The floors file


def floors_from(data: dict) -> dict[str, int]:
    return {
        path: entry["floor"]
        for path, entry in sorted(data["files"].items())
        if entry["floor"] is not None
    }


def floor_mismatches(data: dict, floors: dict) -> list[str]:
    """Every difference between the data's floors and a loaded floors file."""
    out = []
    if floors.get("margin") != data["margin"]:
        out.append(f"margin is {floors.get('margin')!r} there and {data['margin']!r} in the data")
    want, have = floors_from(data), floors.get("files", {})
    for path in sorted(set(want) | set(have)):
        if path not in have:
            out.append(f"{path}: floor {want[path]} in the data, none there")
        elif path not in want:
            reason = "is not in the data" if path not in data["files"] else "has no floor in the data"
            out.append(f"{path}: floor {have[path]} there, but the file {reason}")
        elif have[path] != want[path]:
            out.append(f"{path}: floor {want[path]} in the data, {have[path]} there")
    return out


def updated_floors(data: dict, floors: dict) -> dict:
    """A floors file with the data's margin and floors; its other keys are kept."""
    out = dict(floors)
    out["margin"] = data["margin"]
    out["files"] = floors_from(data)
    return out


# Merging a report


def merge_report(data: dict, report: dict, commit: str | None = None) -> dict:
    """The data with the measurements of a `tools/mutation.py report --json` file taken in.

    Each reported file gets the report's counts, its previous floor as "was", no kills by new
    tests, a floor computed afresh, and `commit` as "measuredAt" when one is given. Its
    "remeasured" figures, survivor rows and addenda are dropped. The tests added are kept.
    A file that did not finish, or that the data does not list, refuses the whole merge.
    """
    refused = []
    for path, result in report.items():
        if path not in data["files"]:
            refused.append(f"{path}: not in {DATA}; add it there with its tier first")
        elif result.get("status") != "ok":
            refused.append(f"{path}: status is {result.get('status')!r}, not \"ok\"")
        elif not all(_is_count(result.get(key)) for key in ("mutants", "killed", "timeouts")):
            refused.append(f"{path}: mutants, killed and timeouts must be whole numbers")
    if refused:
        raise DataError("\n".join(refused))
    out = copy.deepcopy(data)
    for path, result in report.items():
        old = out["files"][path]
        entry = {
            "tier": old["tier"],
            "mutants": result["mutants"],
            "killed": result["killed"],
            "timedOut": result["timeouts"],
            "newKills": 0,
            "floor": compute_floor(result["killed"], result["mutants"], out["margin"]),
            "was": old["floor"],
        }
        if commit:
            entry["measuredAt"] = commit
        out["files"][path] = entry
        out.get("survivors", {}).pop(path, None)
        out.get("addenda", {}).pop(path, None)
    return out


# Files


def dump_data(data: dict) -> str:
    """The data file's text: fixed key order, files and survivors by path, two-space indent."""
    def ordered(entry: dict, keys: tuple[str, ...]) -> dict:
        return {key: entry[key] for key in keys if key in entry}

    def rows(items: list) -> list:
        return [ordered(row, ROW_KEYS) for row in items]

    out = {
        "margin": data["margin"],
        "files": {
            path: ordered(entry, FILE_KEYS + FILE_OPTIONAL_KEYS)
            for path, entry in sorted(data["files"].items())
        },
        "survivors": {path: rows(items) for path, items in sorted(data.get("survivors", {}).items())},
        "addenda": {
            path: [{"rows": rows(b["rows"])} if "rows" in b else {"text": b["text"]} for b in blocks]
            for path, blocks in sorted(data.get("addenda", {}).items())
        },
        "tests": [
            {"file": g["file"], "tests": [ordered(t, ("name", "where")) for t in g["tests"]]}
            for g in data.get("tests", [])
        ],
    }
    return json.dumps(out, indent=2, ensure_ascii=False) + "\n"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").replace("\r\n", "\n")


def write_text(path: Path, text: str) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def check(root: Path) -> list[str]:
    """Every reason the data, the page and the floors file disagree; empty when in sync."""
    data = json.loads(read_text(root / DATA))
    errors = [f"{DATA}: {error}" for error in validate(data)]
    if errors:
        return errors
    page = read_text(root / PAGE)
    try:
        wanted = regenerate(page, data)
    except DataError as error:
        return [f"{PAGE}: {line}" for line in str(error).splitlines()]
    if wanted != page:
        diff = difflib.unified_diff(
            page.splitlines(), wanted.splitlines(), f"{PAGE} (committed)", f"{PAGE} (generated)",
            lineterm="", n=1,
        )
        errors.extend(list(diff)[:60])
        errors.append(f"{PAGE} is not current: run `python tools/gen_mutation_scores.py`")
    try:
        floors = json.loads(read_text(root / FLOORS))
    except (OSError, ValueError) as error:
        return errors + [f"{FLOORS}: cannot be read ({error})"]
    mismatches = [f"{FLOORS}: {line}" for line in floor_mismatches(data, floors)]
    if mismatches:
        mismatches.append(
            f"{FLOORS} differs from {DATA}: run "
            "`python tools/gen_mutation_scores.py --write-floors`"
        )
    return errors + mismatches


def repository_root() -> Path:
    return Path(__file__).resolve().parent.parent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, help="repository root (default: parent of tools/)")
    parser.add_argument("--check", action="store_true",
                        help=f"fail if {PAGE}, {DATA} and {FLOORS} disagree")
    parser.add_argument("--write-floors", action="store_true",
                        help=f"also write {FLOORS} from the data")
    parser.add_argument("--merge", type=Path, metavar="REPORT.json",
                        help="take the measurements of a `tools/mutation.py report --json` file")
    parser.add_argument("--commit", metavar="SHA",
                        help="with --merge: the commit the report measured")
    args = parser.parse_args(argv)
    if args.check and (args.write_floors or args.merge):
        parser.error("--check writes nothing: it cannot be combined with --write-floors or --merge")
    if args.commit and not args.merge:
        parser.error("--commit needs --merge")

    root = (args.root or repository_root()).resolve()
    if args.check:
        failures = check(root)
        for line in failures:
            print(line)
        if failures:
            print("FAIL mutation scores are not in sync")
            return 1
        print(f"mutation scores: {PAGE} and {FLOORS} agree with {DATA}")
        return 0

    try:
        data = json.loads(read_text(root / DATA))
        if args.merge:
            report = json.loads(read_text(args.merge))
            data = merge_report(data, report, args.commit)
        page = regenerate(read_text(root / PAGE), data)
    except DataError as error:
        for line in str(error).splitlines():
            print(f"FAIL {line}")
        return 1
    if args.merge:
        write_text(root / DATA, dump_data(data))
        print(f"mutation scores: merged {len(report)} file(s) into {DATA}")
    write_text(root / PAGE, page)
    print(f"mutation scores: wrote the generated regions of {PAGE}")
    if args.write_floors:
        floors_path = root / FLOORS
        floors = json.loads(read_text(floors_path)) if floors_path.exists() else {}
        write_text(floors_path, json.dumps(updated_floors(data, floors), indent=2) + "\n")
        print(f"mutation scores: wrote {FLOORS}")
    elif args.merge:
        print(f"mutation scores: {FLOORS} is unchanged; write it with --write-floors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
