#!/usr/bin/env python3
"""Check the facts the documentation quotes from the code, so the docs cannot drift silently.

Checks every Markdown file under docs/, plus README.md:
  1. every test function a page cites in a code span (`test_*`, `testFuzz_*`, `invariant_*`)
     is defined somewhere under test/;
  2. every ERC-165 interface ID in a table row that starts with an interface name matches the
     value `test/interfaces/InterfacesCompile.t.sol` pins, a well-known standard ID, or (with
     `--artifacts`) the ID computed from the compiled selectors;
  3. every event topic0 on the events page (a full value, or a short `0x12345678…` prefix next
     to an event signature) is the keccak-256 of that event's canonical signature (with
     `--artifacts`, the signature as the compiled ABIs declare it);
  4. the audit scope's nSLOC figures and the README's module table match the sources (the line
     rules of tools/check_budgets.py), and with `--artifacts`, the scope's runtime, initcode and
     EIP-170 margin figures match the compiled bytecode.

`--update` rewrites the nSLOC and size figures in docs/audit/scope.md and README.md instead of
failing on them (other checks still fail). Run from anywhere:

  python tools/check_docs_facts.py                      # source-only checks
  python tools/check_docs_facts.py --artifacts out      # all checks, after `forge build`
  python tools/check_docs_facts.py --artifacts out --update

Standard library only. Keccak-256 comes from tools/content/keccak.py.
"""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

EVENTS_PAGE = "docs/integrators/events-and-indexing.md"
SCOPE_PAGE = "docs/audit/scope.md"
README = "README.md"
PIN_FILE = "test/interfaces/InterfacesCompile.t.sol"
EIP170 = 24_576

# Standard interface IDs the docs may list next to the protocol's own.
STANDARD_IDS = {
    "IERC165": "0x01ffc9a7",
    "IERC721": "0x80ac58cd",
    "IERC721Metadata": "0x5b5e139f",
    "IERC1155": "0xd9b67a26",
    "IERC1155MetadataURI": "0x0e89341c",
    "IERC2981": "0x2a55205a",
}

CODE_SPAN = re.compile(r"`([^`\n]+)`")
# A test function name in a code span, not a Python module (`tools.test_x`) or file (`test_x.py`).
TEST_NAME = re.compile(
    r"(?<![\w./])((?:test|testFuzz|invariant)_[A-Za-z0-9_]*[A-Za-z0-9])(?![A-Za-z0-9_*]|\.py)"
)
PY_TEST = re.compile(r"^\s*def\s+(test_\w+)\s*\(", re.MULTILINE)
SOL_FUNCTION = re.compile(r"\bfunction\s+([A-Za-z_$][\w$]*)\s*\(")
PIN = re.compile(r"type\(\s*(\w+)\s*\)\.interfaceId\s*,\s*bytes4\(\s*(0x[0-9a-fA-F]{8})\s*\)")
INTERFACE_ROW = re.compile(r"^\|\s*`(I[A-Z][A-Za-z0-9]*)`\s*\|")
ID_VALUE = re.compile(r"`(0x[0-9a-f]{8})`")
# A full topic0 (`0x` and 64 hex digits) or a short prefix (`0x` and 8 hex digits, then `…`).
TOPIC = re.compile(r"`(0x[0-9a-f]{64}(?=`)|0x[0-9a-f]{8}(?=…))")
EVENT_SIG = re.compile(r"`([A-Z][A-Za-z0-9]*)\(([^`]*)\)`")
NUMBER = re.compile(r"\d[\d,]*")
ELEMENTARY = re.compile(r"^(?:address|bool|string|bytes(?:[1-9]|[12]\d|3[0-2])?|u?int(?:\d{1,3})?)(?:\[\d*\])*$")
SRC_LINK = re.compile(r"\]\(\.\./\.\./(src/[^)]+\.sol)\)")

_KECCAK = None


def keccak256(data: bytes) -> bytes:
    global _KECCAK
    if _KECCAK is None:
        path = Path(__file__).resolve().parent / "content" / "keccak.py"
        spec = importlib.util.spec_from_file_location("works_keccak_docs", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _KECCAK = module.keccak256
    return _KECCAK(data)


def hex_keccak(text: str) -> str:
    return "0x" + keccak256(text.encode("ascii")).hex()


_BUDGETS = None


def _load_budgets():
    """tools/check_budgets.py, whose line rules the budget gate uses, loaded once by path."""
    global _BUDGETS
    if _BUDGETS is None:
        path = Path(__file__).resolve().parent / "check_budgets.py"
        spec = importlib.util.spec_from_file_location("works_budgets_docs", path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module  # its dataclasses resolve through sys.modules
        spec.loader.exec_module(module)
        _BUDGETS = module
    return _BUDGETS


def nsloc(path: Path) -> int:
    budgets = _load_budgets()
    return budgets.count_code_lines(budgets.strip_solidity(path.read_text(encoding="utf-8")))


def fmt(n: int) -> str:
    return f"{n:,}"


@dataclass
class Report:
    problems: list[str] = field(default_factory=list)
    checked: dict[str, int] = field(default_factory=dict)
    updated: list[str] = field(default_factory=list)

    def count(self, what: str, n: int = 1) -> None:
        self.checked[what] = self.checked.get(what, 0) + n

    def fail(self, where: str, message: str) -> None:
        self.problems.append(f"{where}: {message}")


def doc_files(root: Path) -> list[Path]:
    files = sorted((root / "docs").rglob("*.md"))
    if (root / README).exists():
        files.append(root / README)
    return files


# ---------------------------------------------------------------------------
# 1. Test names


def defined_test_functions(root: Path) -> set[str]:
    """Solidity functions under test/, and the Python tools' unit tests."""
    names: set[str] = set()
    for path in (root / "test").rglob("*.sol"):
        names.update(SOL_FUNCTION.findall(path.read_text(encoding="utf-8")))
    for path in (root / "tools").rglob("test_*.py"):
        names.update(PY_TEST.findall(path.read_text(encoding="utf-8")))
    return names


def check_test_names(root: Path, report: Report) -> None:
    defined = defined_test_functions(root)
    for path in doc_files(root):
        rel = path.relative_to(root).as_posix()
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for span in CODE_SPAN.findall(line):
                for name in TEST_NAME.findall(span):
                    report.count("test names")
                    if name not in defined:
                        report.fail(f"{rel}:{number}", f"cites `{name}`, which no test defines")


# ---------------------------------------------------------------------------
# Artifacts


@dataclass
class Artifacts:
    events: dict[str, set[str]] = field(default_factory=dict)  # name -> canonical signatures
    selectors: dict[str, set[str]] = field(default_factory=dict)  # contract -> selectors
    sizes: dict[str, tuple[int, int]] = field(default_factory=dict)  # contract -> (runtime, init)


def canonical_type(entry: dict) -> str:
    kind = entry["type"]
    if kind.startswith("tuple"):
        inner = ",".join(canonical_type(c) for c in entry.get("components", []))
        return f"({inner}){kind[len('tuple'):]}"
    return kind


def load_artifacts(directory: Path) -> Artifacts:
    out = Artifacts()
    for path in sorted(directory.glob("*/*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or "abi" not in data:
            continue
        contract = path.stem
        for entry in data.get("abi", []):
            if entry.get("type") == "event":
                sig = f"{entry['name']}({','.join(canonical_type(i) for i in entry['inputs'])})"
                out.events.setdefault(entry["name"], set()).add(sig)
        out.selectors[contract] = set((data.get("methodIdentifiers") or {}).values())
        runtime = (data.get("deployedBytecode") or {}).get("object", "0x")
        init = (data.get("bytecode") or {}).get("object", "0x")
        out.sizes[contract] = (max(len(runtime) - 2, 0) // 2, max(len(init) - 2, 0) // 2)
    return out


# ---------------------------------------------------------------------------
# 2. Interface IDs


def pinned_interface_ids(root: Path) -> dict[str, str]:
    text = (root / PIN_FILE).read_text(encoding="utf-8")
    return {name: value.lower() for name, value in PIN.findall(text)}


def interface_bases(root: Path) -> dict[str, list[str]]:
    bases: dict[str, list[str]] = {}
    pattern = re.compile(r"\binterface\s+(\w+)\s*(?:is\s+([^{]+))?\{")
    for path in (root / "src").rglob("*.sol"):
        for name, parents in pattern.findall(path.read_text(encoding="utf-8")):
            bases[name] = [p.strip() for p in parents.split(",")] if parents.strip() else []
    return bases


def computed_interface_id(name: str, artifacts: Artifacts, bases: dict[str, list[str]]) -> str | None:
    own = set(artifacts.selectors.get(name, set()))
    if not own and name not in artifacts.selectors:
        return None
    stack = list(bases.get(name, []))
    seen: set[str] = set()
    while stack:
        base = stack.pop()
        if base in seen:
            continue
        seen.add(base)
        own -= artifacts.selectors.get(base, set())
        stack.extend(bases.get(base, []))
    value = 0
    for selector in own:
        value ^= int(selector, 16)
    return f"0x{value:08x}"


def check_interface_ids(root: Path, report: Report, artifacts: Artifacts | None) -> None:
    pins = pinned_interface_ids(root)
    bases = interface_bases(root)
    for path in doc_files(root):
        rel = path.relative_to(root).as_posix()
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            match = INTERFACE_ROW.match(line)
            if not match:
                continue
            values = ID_VALUE.findall(line[match.end():])
            if not values:
                continue
            name, shown = match.group(1), values[0]
            expected = pins.get(name) or STANDARD_IDS.get(name)
            if expected is None and artifacts is not None:
                expected = computed_interface_id(name, artifacts, bases)
            if expected is None:
                continue
            report.count("interface IDs")
            if shown != expected:
                report.fail(f"{rel}:{number}", f"`{name}` shows {shown}; the code gives {expected}")


# ---------------------------------------------------------------------------
# 3. Event topic0 values


def canonical_from_doc(params: str) -> str | None:
    """`uint64 indexed roleId, address account` -> `uint64,address`, or None if not elementary."""
    if not params.strip():
        return ""
    types = []
    for part in params.split(","):
        words = [w for w in part.split() if w != "indexed"]
        if not words or not ELEMENTARY.match(words[0]):
            return None
        types.append(words[0])
    return ",".join(types)


def check_topics(root: Path, report: Report, artifacts: Artifacts | None) -> None:
    path = root / EVENTS_PAGE
    if not path.exists():
        return
    rel = path.relative_to(root).as_posix()
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.startswith("|"):
            continue
        sigs = EVENT_SIG.findall(line)
        topics = TOPIC.findall(line)
        if not sigs or not topics:
            continue
        per_sig: list[tuple[str, set[str]]] = []
        for name, params in sigs:
            candidates: set[str] = set()
            if artifacts is not None and name in artifacts.events:
                candidates = {hex_keccak(s) for s in artifacts.events[name]}
            local = canonical_from_doc(params)
            if local is not None:
                candidates.add(hex_keccak(f"{name}({local})"))
                if (artifacts is not None and name in artifacts.events and " " not in params.strip()
                        and f"{name}({local})" not in artifacts.events[name]):
                    report.fail(f"{rel}:{number}", f"`{name}({local})` is not a compiled signature")
            if artifacts is not None and name not in artifacts.events:
                report.fail(f"{rel}:{number}", f"event `{name}` is in no compiled ABI")
                candidates = set()
            per_sig.append((name, candidates))
        # One topic per signature: pair them in order. Otherwise any of the row's signatures.
        if len(per_sig) == len(topics):
            pairs = list(zip(per_sig, topics))
        else:
            union = (" or ".join(n for n, _ in per_sig), set().union(*(c for _, c in per_sig)))
            pairs = [(union, t) for t in topics]
        for (name, candidates), topic in pairs:
            if not candidates:
                continue
            report.count("topic0 values")
            if not any(c.startswith(topic) for c in candidates):
                shown = topic if len(topic) == 66 else f"{topic}…"
                report.fail(f"{rel}:{number}", f"`{name}` topic0 {shown} matches no signature of it")


# ---------------------------------------------------------------------------
# 4. Scope and README figures


def _cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def _num(cell: str) -> int | None:
    match = NUMBER.search(cell.replace("*", ""))
    return int(match.group(0).replace(",", "")) if match else None


def _replace_number(cell: str, value: int) -> str:
    return NUMBER.sub(fmt(value), cell, count=1)


def check_scope(root: Path, report: Report, artifacts: Artifacts | None, update: bool) -> None:
    path = root / SCOPE_PAGE
    if not path.exists():
        return
    rel = path.relative_to(root).as_posix()
    lines = path.read_text(encoding="utf-8").splitlines()
    changed = False
    for index, line in enumerate(lines):
        link = SRC_LINK.search(line)
        if not line.startswith("|") or not link:
            continue
        cells = _cells(line)
        source = root / link.group(1)
        if not source.exists() or len(cells) < 3:
            continue
        name_match = re.match(r"`(\w+)`", cells[0])
        contract = name_match.group(1) if name_match else None
        new_cells = list(cells)
        lines_shown = _num(cells[2])
        if lines_shown is not None:
            report.count("nSLOC figures")
            actual = nsloc(source)
            if lines_shown != actual:
                if update:
                    new_cells[2] = _replace_number(cells[2], actual)
                else:
                    report.fail(f"{rel}:{index + 1}", f"{cells[0]} shows {fmt(lines_shown)} nSLOC; the source has {fmt(actual)}")
        if artifacts is not None and contract and len(cells) >= 6 and contract in artifacts.sizes:
            runtime, init = artifacts.sizes[contract]
            for col, actual, label in ((3, runtime, "runtime"), (4, init, "initcode"), (5, EIP170 - runtime, "EIP-170 margin")):
                shown = _num(cells[col])
                if shown is None:
                    continue
                report.count("bytecode sizes")
                if shown != actual:
                    if update:
                        new_cells[col] = _replace_number(cells[col], actual)
                    else:
                        report.fail(f"{rel}:{index + 1}", f"{contract} {label} shows {fmt(shown)}; the build gives {fmt(actual)}")
        if new_cells != cells:
            lines[index] = "| " + " | ".join(new_cells) + " |"
            changed = True
    # Summary totals.
    src = sorted((root / "src").rglob("*.sol"))
    total = sum(nsloc(p) for p in src)
    iface = sum(nsloc(p) for p in src if "interfaces" in p.relative_to(root / "src").parts)
    totals = (
        (re.compile(r"([\d,]+) non-blank, non-comment lines in ([\d,]+) files"), (total, len(src))),
        (re.compile(r"([\d,]+) nSLOC in \[`src/interfaces/`\]"), (iface,)),
    )
    for index, line in enumerate(lines):
        for pattern, values in totals:
            match = pattern.search(line)
            if not match:
                continue
            report.count("nSLOC figures", len(values))
            shown = tuple(int(g.replace(",", "")) for g in match.groups())
            if shown != values:
                if update:
                    text = match.group(0)
                    for old, new in zip(match.groups(), values):
                        text = text.replace(old, fmt(new), 1)
                    lines[index] = line.replace(match.group(0), text)
                    changed = True
                else:
                    report.fail(f"{rel}:{index + 1}", f"shows {', '.join(fmt(v) for v in shown)}; the sources give {', '.join(fmt(v) for v in values)}")
    if changed:
        path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        report.updated.append(rel)


def source_of(root: Path, contract: str) -> Path | None:
    matches = sorted((root / "src").rglob(f"{contract}.sol"))
    return matches[0] if matches else None


def check_readme(root: Path, report: Report, update: bool) -> None:
    path = root / README
    if not path.exists():
        return
    lines = path.read_text(encoding="utf-8").splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.startswith("| Contract") and "nSLOC" in l)
    except StopIteration:
        return
    header = _cells(lines[start])
    column = header.index("nSLOC")
    changed = False
    for index in range(start + 2, len(lines)):
        line = lines[index]
        if not line.startswith("|"):
            break
        cells = _cells(line)
        names = re.findall(r"`(\w+)`", cells[0])
        numbers = [int(n.replace(",", "")) for n in NUMBER.findall(cells[column])]
        if not names or len(names) != len(numbers):
            report.fail(f"{README}:{index + 1}", "module row needs one nSLOC figure per contract named")
            continue
        actual = []
        for name in names:
            source = source_of(root, name)
            actual.append(nsloc(source) if source else None)
        report.count("nSLOC figures", len(names))
        if None in actual:
            report.fail(f"{README}:{index + 1}", f"no source file for {names[actual.index(None)]}")
            continue
        if numbers != actual:
            if update:
                cells[column] = " + ".join(fmt(n) for n in actual)
                lines[index] = "| " + " | ".join(cells) + " |"
                changed = True
            else:
                report.fail(f"{README}:{index + 1}", f"{', '.join(names)}: shows {numbers}; the sources give {actual}")
    if changed:
        path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        report.updated.append(README)


# ---------------------------------------------------------------------------


def run(root: Path, artifacts_dir: Path | None, update: bool) -> Report:
    report = Report()
    artifacts = load_artifacts(artifacts_dir) if artifacts_dir else None
    check_test_names(root, report)
    check_interface_ids(root, report, artifacts)
    check_topics(root, report, artifacts)
    check_scope(root, report, artifacts, update)
    check_readme(root, report, update)
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, help="repository root (default: parent of tools/)")
    parser.add_argument("--artifacts", type=Path, help="forge's out/ directory, for the build-based checks")
    parser.add_argument("--update", action="store_true", help="rewrite stale nSLOC and size figures")
    args = parser.parse_args(argv)
    with contextlib.suppress(AttributeError, ValueError):
        sys.stdout.reconfigure(encoding="utf-8")
    root = (args.root or Path(__file__).resolve().parent.parent).resolve()
    artifacts = None
    if args.artifacts:
        artifacts = args.artifacts if args.artifacts.is_absolute() else root / args.artifacts
        if not artifacts.is_dir():
            print(f"FAIL artifacts directory {artifacts} does not exist (run forge build)")
            return 1
    report = run(root, artifacts, args.update)
    for path in report.updated:
        print(f"updated {path}")
    for problem in report.problems:
        print(f"FAIL {problem}")
    summary = ", ".join(f"{n} {what}" for what, n in sorted(report.checked.items()))
    if report.problems:
        hint = " (stale figures: rerun with --artifacts out --update)" if any(
            "nSLOC" in p or "the build gives" in p for p in report.problems) else ""
        print(f"docs facts: {len(report.problems)} problems; checked {summary}{hint}")
        return 1
    print(f"docs facts: checked {summary}; all match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
