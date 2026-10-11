#!/usr/bin/env python3
"""Enforce the ADR 0001 engineering budgets on the v1 sources in src/.

Checks:
  1. at most 12,000 non-comment, non-blank Solidity lines under src/ (lib/ excluded);
  2. no `delegatecall` (or the equivalent legacy `callcode`) in src/ code;
  3. at most 5 libraries with public or external functions (each would be linked);
  4. every contract built by the measured Foundry profile fits EIP-170 (24,576-byte
     runtime) and EIP-3860 (49,152-byte initcode), read from
     `forge build --sizes --json`.

Run from anywhere: `python tools/check_budgets.py`. Standard library only. The
repository root is the nearest ancestor with a foundry.toml. Sizes always come from
the profile named by `--profile`, which is `default` unless given; the measured
profile is never inferred from foundry.toml, so adding a profile cannot silently
change which bytecode the gate measures. CI passes `--profile default` explicitly.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

MAX_LINES = 12_000
MAX_LINKED_LIBRARIES = 5
MAX_RUNTIME_BYTES = 24_576
MAX_INITCODE_BYTES = 49_152
DEFAULT_PROFILE = "default"
SIZE_FIELDS = ("runtime_size", "init_size")

FORBIDDEN_CALL = re.compile(r"\b(delegatecall|callcode)\b")
LIBRARY = re.compile(r"\blibrary\s+([A-Za-z_$][\w$]*)\s*\{")
NAMED_FUNCTION = re.compile(r"\bfunction\s+([A-Za-z_$][\w$]*)\s*\(")
WORD = re.compile(r"[A-Za-z_$][\w$]*")


def strip_solidity(text: str) -> str:
    """Blank out comments and string-literal contents, preserving line breaks.

    The result keeps every code token at its original line, so line counts and
    token searches see code only.
    """
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
        elif c == "/" and nxt == "*":
            i += 2
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                if text[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        elif c in "\"'":
            quote = c
            out.append(quote)
            i += 1
            while i < n and text[i] != quote and text[i] != "\n":
                if text[i] == "\\":
                    i += 1
                i += 1
            out.append(quote)
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def count_code_lines(code: str) -> int:
    return sum(1 for line in code.splitlines() if line.strip())


def _matching_brace(code: str, open_index: int) -> int:
    depth = 0
    for i in range(open_index, len(code)):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return len(code)


def _is_public_or_external(code: str, paren_index: int) -> bool:
    """Scan a function header from its parameter list to `{` or `;`."""
    depth = 0
    i = paren_index
    words: list[str] = []
    while i < len(code):
        c = code[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif depth == 0 and c in "{;":
            break
        elif depth == 0:
            match = WORD.match(code, i)
            if match:
                words.append(match.group(0))
                i = match.end()
                continue
        i += 1
    return "public" in words or "external" in words


def linked_libraries(code: str) -> list[str]:
    """Names of libraries declaring at least one public or external function."""
    names = []
    for match in LIBRARY.finditer(code):
        body_start = match.end() - 1
        body = code[body_start : _matching_brace(code, body_start) + 1]
        for function in NAMED_FUNCTION.finditer(body):
            if _is_public_or_external(body, function.end() - 1):
                names.append(match.group(1))
                break
    return names


@dataclass
class Report:
    failures: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def check(self, ok: bool, message: str) -> None:
        (self.notes if ok else self.failures).append(("ok   " if ok else "FAIL ") + message)


def source_files(src: Path) -> list[Path]:
    return sorted(p for p in src.rglob("*.sol") if "lib" not in p.relative_to(src).parts)


def check_sources(src: Path, report: Report, max_lines: int, max_linked: int) -> None:
    files = source_files(src)
    total = 0
    linked: list[str] = []
    calls: list[str] = []
    for path in files:
        code = strip_solidity(path.read_text(encoding="utf-8"))
        total += count_code_lines(code)
        for number, line in enumerate(code.splitlines(), 1):
            for hit in FORBIDDEN_CALL.finditer(line):
                calls.append(f"{hit.group(1)} at {path.relative_to(src.parent).as_posix()}:{number}")
        linked += linked_libraries(code)
    for call in calls:
        report.check(False, call)
    report.check(not calls, f"{len(calls)} delegatecall/callcode uses in {len(files)} source files")
    report.check(total <= max_lines, f"{total} Solidity code lines in src/ (limit {max_lines})")
    listed = ", ".join(sorted(linked)) or "none"
    report.check(
        len(linked) <= max_linked,
        f"{len(linked)} linked libraries (limit {max_linked}): {listed}",
    )


def _is_size_entry(entry: object) -> bool:
    """True for an object whose runtime_size and init_size are non-negative integers."""
    return isinstance(entry, dict) and all(
        type(entry.get(key)) is int and entry[key] >= 0 for key in SIZE_FIELDS
    )


def check_sizes(sizes: dict, report: Report) -> None:
    """Check every contract in forge's size JSON, failing cleanly on unexpected shapes.

    The gate is the only EIP-170 enforcement in CI, so a changed or truncated forge
    output must produce a FAIL line naming the contract, never an exception.
    """
    if not isinstance(sizes, dict):
        report.check(False, "contract sizes: expected a JSON object from forge")
        return
    problems = []
    valid: dict[str, dict] = {}
    for name, entry in sorted(sizes.items()):
        if not _is_size_entry(entry):
            problems.append(
                f"{name}: malformed size entry, expected an object with integer"
                " runtime_size and init_size"
            )
            continue
        valid[name] = entry
        if entry["runtime_size"] > MAX_RUNTIME_BYTES:
            problems.append(f"{name} runtime {entry['runtime_size']} > {MAX_RUNTIME_BYTES}")
        if entry["init_size"] > MAX_INITCODE_BYTES:
            problems.append(f"{name} initcode {entry['init_size']} > {MAX_INITCODE_BYTES}")
    for message in problems:
        report.check(False, message)
    if valid:
        largest = max(valid.items(), key=lambda item: item[1]["runtime_size"])
        detail = f"largest {largest[0]} {largest[1]['runtime_size']} bytes"
    else:
        detail = "no contracts"
    report.check(not problems, f"{len(sizes)} contracts within EIP-170/EIP-3860 ({detail})")


def find_root(start: Path) -> Path:
    for candidate in [start, *start.parents]:
        if (candidate / "foundry.toml").is_file():
            return candidate
    raise SystemExit(f"no foundry.toml above {start}")


def forge_sizes(root: Path, profile: str) -> dict:
    env = dict(os.environ, FOUNDRY_PROFILE=profile)
    result = subprocess.run(
        ["forge", "build", "--sizes", "--json"],
        cwd=root,
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    # forge exits non-zero when a contract is oversized, but still prints the JSON.
    if result.returncode == 0 and not result.stdout.strip():
        return {}
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(f"could not read `forge build --sizes --json` (exit {result.returncode})")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, help="repository root (default: auto-detected)")
    parser.add_argument(
        "--profile",
        default=DEFAULT_PROFILE,
        help=f"Foundry profile whose bytecode is measured (default: {DEFAULT_PROFILE})",
    )
    parser.add_argument("--sizes-json", type=Path, help="read sizes from this file, not forge")
    parser.add_argument("--skip-sizes", action="store_true", help="skip the contract-size check")
    parser.add_argument("--max-lines", type=int, default=MAX_LINES)
    parser.add_argument("--max-linked-libraries", type=int, default=MAX_LINKED_LIBRARIES)
    args = parser.parse_args(argv)

    root = args.root or find_root(Path(__file__).resolve().parent)
    report = Report()
    src = root / "src"
    if not src.is_dir():
        raise SystemExit(f"no src/ directory under {root}")
    check_sources(src, report, args.max_lines, args.max_linked_libraries)
    if not args.skip_sizes:
        if args.sizes_json:
            sizes = json.loads(args.sizes_json.read_text(encoding="utf-8"))
        else:
            sizes = forge_sizes(root, args.profile)
        check_sizes(sizes, report)

    for line in report.notes + report.failures:
        print(line)
    if report.failures:
        print(f"v1 budgets: {len(report.failures)} failure(s)")
        return 1
    print("v1 budgets: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
