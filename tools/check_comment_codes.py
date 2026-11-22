#!/usr/bin/env python3
"""List internal reference codes in the comments of src/, which a reader cannot look up.

A comment may cite only (AGENTS.md, "Comments"):
  - a rule ID that the specification defines today (`AUC-3`), an invariant or property ID of
    docs/audit/invariants.md, or a limitation ID of docs/audit/known-limitations.md;
  - an ADR, EIP or ERC by number; standard names such as SHA-256, UTF-8 or CC0-1.0;
  - a file, contract, function or error in this repository.

Everything else is reported: owner decisions by number, bare letter-number codes (`R9`, `C8`,
`D140`), review and finding labels (`MARKET-4`, `QUALITY-6`), rule IDs that no page defines,
pull request numbers and names of review passes.

Usage (standard library only), from anywhere:

    python tools/check_comment_codes.py                 # every file under src/; exit 1 on a code
    python tools/check_comment_codes.py src/core        # only these paths
    python tools/check_comment_codes.py --summary       # counts per file and per kind
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ID_PAGES = ["docs/spec", "docs/audit/invariants.md", "docs/audit/known-limitations.md"]

# Prefixes that are standards, not codes.
STANDARD_PREFIXES = {"ERC", "EIP", "SHA", "UTF", "CC0", "BIP", "RFC", "ISO", "CAIP", "ADR"}

ROW_ID = re.compile(r"^\|\s*\**([A-Z][A-Z0-9]*(?:-[A-Z][A-Z0-9]*)*-\d+[a-z]?)\**\s*\|", re.M)
LABEL = re.compile(r"\b([A-Z][A-Z0-9]*(?:-[A-Z][A-Z0-9]*)*)-(\d+[a-z]?)\b")
PATTERNS = [
    ("owner decision", re.compile(r"\b(?:owner(?:'s)?\s+)?decisions?\s+(?:[A-Z]?\d+|no\.\s*\d+)", re.I)),
    ("bare code", re.compile(r"(?<![\w./-])[RCD]\d{1,3}(?![\w-])")),
    ("pull request", re.compile(r"\b(?:PR|pull request)\s*#\d+", re.I)),
    ("review name", re.compile(
        r"\b(?:rc\.\d\b[^.\n]{0,20}review|seven-lens|second[- ]pass|fix pass|study [A-Z]\b"
        r"|finding \d+|lane \d+|cold review|tilt audit)", re.I)),
]
COMMENT = re.compile(r"//(.*)$|/\*(.*?)\*/", re.S | re.M)


@dataclass(frozen=True)
class Hit:
    path: str
    line: int
    kind: str
    text: str


def defined_ids(root: Path = ROOT) -> set[str]:
    """Every rule, invariant, property and limitation ID that a page defines in a table row."""
    ids: set[str] = set()
    for page in ID_PAGES:
        p = root / page
        files = sorted(p.glob("*.md")) if p.is_dir() else [p]
        for f in files:
            if f.exists():
                ids.update(ROW_ID.findall(f.read_text(encoding="utf-8")))
    return ids


def comments(source: str):
    """Yield (line number, comment text) for every comment in a Solidity source."""
    for m in COMMENT.finditer(source):
        text = m.group(1) if m.group(1) is not None else m.group(2)
        start = source.count("\n", 0, m.start()) + 1
        for offset, line in enumerate(text.split("\n")):
            yield start + offset, line


def scan(source: str, path: str, ids: set[str]) -> list[Hit]:
    """The codes in one file's comments."""
    hits: list[Hit] = []
    for line_no, text in comments(source):
        for kind, pattern in PATTERNS:
            for m in pattern.finditer(text):
                hits.append(Hit(path, line_no, kind, m.group(0)))
        for m in LABEL.finditer(text):
            prefix, code = m.group(1), m.group(0)
            if prefix.split("-")[0] in STANDARD_PREFIXES or code in ids:
                continue
            kind = "undefined rule ID" if any(i.startswith(prefix + "-") for i in ids) else "label"
            hits.append(Hit(path, line_no, kind, code))
    return hits


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("paths", nargs="*", default=["src"])
    parser.add_argument("--summary", action="store_true", help="counts per file and kind")
    args = parser.parse_args(argv)
    ids = defined_ids()
    hits: list[Hit] = []
    for given in args.paths:
        p = (ROOT / given) if not Path(given).is_absolute() else Path(given)
        files = sorted(p.rglob("*.sol")) if p.is_dir() else [p]
        for f in files:
            rel = f.relative_to(ROOT).as_posix()
            hits.extend(scan(f.read_text(encoding="utf-8"), rel, ids))
    if args.summary:
        for path, n in Counter(h.path for h in hits).most_common():
            print(f"{n:5d}  {path}")
        for kind, n in Counter(h.kind for h in hits).most_common():
            print(f"{n:5d}  [{kind}]")
    else:
        for h in hits:
            print(f"{h.path}:{h.line}: {h.kind}: {h.text}")
    print(f"comment codes: {len(hits)} found", file=sys.stderr)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
