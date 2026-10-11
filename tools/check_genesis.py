#!/usr/bin/env python3
"""Check the committed genesis configuration against the compiled contracts and the sources.

Checks `config/genesis.example.json`:
  1. every listed signature (mapped, genesis-only or deferred) is a method of its contract's
     compiled ABI, with the listed selector (`forge inspect <path:Contract> methodIdentifiers`);
  2. every `restricted` function of an implemented contract, including those it inherits from
     abstract bases under src/, is mapped, genesis-only or deferred, so nothing silently falls
     back to ADMIN;
  3. every concrete contract under src/ that has, or inherits, a `restricted` function is in
     the configuration (abstract bases are covered through their concrete children);
  4. every wiring call targets a listed contract with a genesis function, and its calldata
     starts with that function's selector; every genesis-only entry is wired, and no deferred
     entry is;
  5. every mapped function's role exists and its delay matches the role's execution delay and
     its class.

A configured contract whose artifact source is not in the repository yet (a lane that has
not merged) is reported as pending and skips checks 1 and 2; it fails nothing.

Run from anywhere: `python tools/check_genesis.py`. Standard library only. Method IDs come from
`forge inspect` by default, or from a build's artifact directory with `--artifacts out`.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

CONFIG = "config/genesis.example.json"
CLASS_DELAY = {"immediate": 0, "standard": 172_800, "funds": 1_209_600, "successor": 2_592_000}
# Functions `GovernanceConfig.isGenesisSelector` admits (one-shot binds, admitted minters,
# sale targets, first default currencies, the epoch-0 manifest). The Solidity tests pin the
# selectors themselves.
GENESIS_FUNCTIONS = frozenset({
    "bindWorkRecords", "bindEditions", "bindStream", "bindPackageRegistry", "bindSplitFactory",
    "bindFederationRegistry", "setAdmittedMinter", "setTarget", "setDefaultCurrency",
    "appendGovernanceManifest",
})

DECLARATION = re.compile(
    r"\b(abstract\s+)?(contract|interface|library)\s+([A-Za-z_$][\w$]*)"
)
ARTIFACT_REF = re.compile(r"^[^:\s]+\.sol:[A-Za-z_$][\w$]*$")
HEX = re.compile(r"^0x(?:[0-9a-fA-F]{2})*$")
STATIC_TYPE = re.compile(r"^(?:address|bool|u?int\d{0,3}|bytes(?:[1-9]|[12]\d|3[0-2]))$")
FUNCTION = re.compile(r"\bfunction\s+([A-Za-z_$][\w$]*)\s*\(")
WORD = re.compile(r"[A-Za-z_$][\w$]*")

MethodIds = Callable[[str], dict]
Present = Callable[[str], bool]


def strip_comments(text: str) -> str:
    """Blank out comments and string contents, keeping line breaks."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c, nxt = text[i], text[i + 1] if i + 1 < n else ""
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
            out.append(c)
            i += 1
            while i < n and text[i] != c and text[i] != "\n":
                i += 2 if text[i] == "\\" else 1
            out.append(c)
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _modifiers(code: str, paren: int) -> list[str]:
    """Words of a function header after its parameter list, up to `{` or `;`."""
    depth, i, words, after = 0, paren, [], False
    while i < len(code):
        c = code[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                after = True
        elif depth == 0 and c in "{;":
            break
        elif depth == 0 and after:
            match = WORD.match(code, i)
            if match:
                words.append(match.group(0))
                i = match.end()
                continue
        i += 1
    return words


@dataclass
class Declared:
    """A contract declared under src/: its bases and its own `restricted` functions."""

    abstract: bool
    bases: list[str] = field(default_factory=list)
    restricted: set[str] = field(default_factory=set)


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


def _bases(header: str) -> list[str]:
    """Base contract names from the text between a contract's name and its `{`."""
    match = re.match(r"\s*is\b(.*)", header, re.S)
    if not match:
        return []
    bases, depth, current = [], 0, ""
    for c in match.group(1):
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == "," and depth == 0:
            bases.append(current)
            current = ""
            continue
        if depth == 0 and c != ")":
            current += c
    bases.append(current)
    names = [WORD.match(b.strip().split(".")[-1]) for b in bases if b.strip()]
    return [m.group(0) for m in names if m]


def declarations(text: str) -> dict[str, Declared]:
    """Every contract declared in `text` (interfaces and libraries skipped), by name."""
    code = strip_comments(text)
    found: dict[str, Declared] = {}
    for m in DECLARATION.finditer(code):
        brace = code.find("{", m.end())
        if brace < 0:
            continue
        if m.group(2) != "contract":
            continue
        end = _matching_brace(code, brace)
        decl = Declared(abstract=bool(m.group(1)), bases=_bases(code[m.end():brace]))
        body = code[brace:end]
        for f in FUNCTION.finditer(body):
            if "restricted" in _modifiers(body, f.end() - 1):
                decl.restricted.add(f.group(1))
        found[m.group(3)] = decl
    return found


def restricted_functions(text: str) -> dict[str, set[str]]:
    """Names of the `restricted` functions each contract in `text` declares itself."""
    return {name: d.restricted for name, d in declarations(text).items() if d.restricted}


def scan_sources(src: Path) -> dict[str, set[str]]:
    """`path:Contract` (relative to the repository root) to the `restricted` function names of
    every concrete contract under `src` that declares or inherits one. Restricted functions of
    abstract bases count for each concrete descendant; abstract contracts are not listed."""
    declared: dict[str, tuple[str, Declared]] = {}
    for path in sorted(src.rglob("*.sol")):
        rel = path.relative_to(src.parent).as_posix()
        for name, decl in declarations(path.read_text(encoding="utf-8")).items():
            declared[name] = (rel, decl)

    def inherited(name: str, seen: set[str]) -> set[str]:
        if name in seen or name not in declared:
            return set()
        seen.add(name)
        decl = declared[name][1]
        names = set(decl.restricted)
        for base in decl.bases:
            names |= inherited(base, seen)
        return names

    result: dict[str, set[str]] = {}
    for name, (rel, decl) in declared.items():
        if decl.abstract:
            continue
        names = inherited(name, set())
        if names:
            result[f"{rel}:{name}"] = names
    return result


def _check_ref(ref: object) -> str:
    if not isinstance(ref, str) or not ARTIFACT_REF.match(ref):
        raise SystemExit(f"malformed artifact reference {ref!r} (expected path/File.sol:Contract)")
    return ref


def _method_map(data: object, where: str) -> dict:
    methods = data.get("methodIdentifiers") if isinstance(data, dict) else None
    if not isinstance(methods, dict):
        raise SystemExit(f"{where}: no methodIdentifiers object")
    return methods


def forge_inspect(root: Path) -> MethodIds:
    cache: dict[str, dict] = {}

    def ids(ref: str) -> dict:
        ref = _check_ref(ref)
        if ref not in cache:
            result = subprocess.run(
                ["forge", "inspect", ref, "methodIdentifiers", "--json"],
                cwd=root, capture_output=True, text=True, encoding="utf-8",
            )
            if result.returncode != 0:
                raise SystemExit(f"forge inspect {ref} failed:\n{result.stderr}")
            try:
                cache[ref] = _method_map({"methodIdentifiers": json.loads(result.stdout)}, ref)
            except json.JSONDecodeError as error:
                raise SystemExit(f"forge inspect {ref}: unreadable output ({error})") from None
        return cache[ref]

    return ids


def artifact_ids(out: Path) -> MethodIds:
    def ids(ref: str) -> dict:
        path, contract = _check_ref(ref).split(":")
        artifact = out / Path(path).name / f"{contract}.json"
        if not artifact.is_file():
            raise SystemExit(f"no artifact {artifact} (run forge build)")
        try:
            data = json.loads(artifact.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise SystemExit(f"unreadable artifact {artifact} ({error})") from None
        return _method_map(data, str(artifact))

    return ids


def _selector(entry: dict) -> str:
    return entry.get("selector", "").lower().removeprefix("0x")


def _static_params(sig: str) -> list[str] | None:
    """Parameter types when every one is a static elementary type, else None."""
    inner = sig[sig.index("(") + 1 : -1]
    params = inner.split(",") if inner else []
    return params if all(STATIC_TYPE.match(p) for p in params) else None


def _check_calldata(where: str, sig: str, data: str, args: list, addresses: dict) -> list[str]:
    """Shape and argument checks for one wiring call's calldata."""
    if not isinstance(data, str) or not HEX.match(data) or len(data) < 10:
        return [f"{where}: calldata is not 0x-prefixed, even-length hex with a selector"]
    params = _static_params(sig)
    if params is None:
        return []
    words = data[10:]
    if len(words) != 64 * len(params):
        return [f"{where}: calldata has {len(words) // 2} argument bytes, expected {32 * len(params)}"]
    problems = []
    for i, (kind, arg) in enumerate(zip(params, args)):
        word = int(words[64 * i : 64 * (i + 1)], 16)
        if kind == "address" and isinstance(arg, str) and arg in addresses:
            if word != int(addresses[arg], 16):
                problems.append(f"{where}: argument {i} is not the address of {arg}")
        elif kind == "bool" and isinstance(arg, bool) and word != int(arg):
            problems.append(f"{where}: argument {i} is not {str(arg).lower()}")
    return problems


def source_present(root: Path) -> Present:
    """Whether an artifact reference's source file exists under `root`."""
    return lambda ref: isinstance(ref, str) and (root / ref.split(":")[0]).is_file()


def pending(config: dict, present: Present) -> list[str]:
    """Configured contracts whose artifact source is not in the repository yet."""
    return [c["name"] for c in config.get("contracts", []) if not present(c["artifact"])]


def check(
    config: dict,
    ids: MethodIds,
    restricted: dict[str, set[str]],
    present: Present = lambda ref: True,
) -> list[str]:
    """Every problem found, as one line each. Contracts whose artifact source is not present
    (unmerged lanes) skip the ABI and `restricted` coverage checks."""
    problems: list[str] = []
    roles = {r["name"]: r for r in config.get("roles", [])}
    by_name = {c["name"]: c for c in config.get("contracts", [])}
    peers = {p["name"] for p in config.get("peers", [])}
    addresses = {c["name"]: c["address"] for c in by_name.values()}
    addresses.update({p["name"]: p["address"] for p in config.get("peers", [])})
    implemented = {c["implementation"] for c in by_name.values() if c.get("implementation")}

    for name, c in by_name.items():
        here = present(c["artifact"])
        methods = ids(c["artifact"]) if here else {}
        groups = {g: c.get(g, []) for g in ("functions", "genesisOnly", "deferred")}
        listed = set()
        for group, entries in groups.items():
            for e in entries:
                sig = e["signature"]
                listed.add(sig)
                if not here:
                    continue
                if sig not in methods:
                    problems.append(f"{name}: {group} {sig} is not a method of {c['artifact']}")
                elif methods[sig] != _selector(e):
                    problems.append(
                        f"{name}: {group} {sig} selector 0x{_selector(e)} != compiled 0x{methods[sig]}"
                    )
        for e in groups["functions"]:
            role = roles.get(e.get("role"))
            if role is None:
                problems.append(f"{name}: {e['signature']} has unknown role {e.get('role')}")
                continue
            delay = e.get("delay")
            if delay != role["executionDelay"] or delay != CLASS_DELAY.get(e.get("class")):
                problems.append(
                    f"{name}: {e['signature']} delay {delay} / class {e.get('class')} does not "
                    f"match {e['role']} ({role['executionDelay']})"
                )
        impl = c.get("implementation")
        if impl and present(impl):
            impl_methods = ids(impl)
            for fn in sorted(restricted.get(impl, set())):
                for sig in sorted(s for s in impl_methods if s.split("(")[0] == fn):
                    if sig not in listed:
                        problems.append(
                            f"{name}: restricted {sig} in {impl} is not mapped, genesis-only or "
                            f"deferred (it would fall back to ADMIN)"
                        )

    for ref in sorted(restricted):
        if ref not in implemented:
            problems.append(f"{ref} has restricted functions but no contract in the configuration")

    wired: set[tuple[str, str]] = set()
    for i, w in enumerate(config.get("wiring", [])):
        name, sig = w["contract"], w["signature"]
        where = f"wiring[{i}] {name}.{sig}"
        if name not in by_name:
            problems.append(f"{where}: unknown contract")
            continue
        if sig.split("(")[0] not in GENESIS_FUNCTIONS:
            problems.append(f"{where}: not a genesis function")
        artifact = by_name[name]["artifact"]
        methods = ids(artifact) if present(artifact) else {sig: None}
        data = w.get("calldata", "").lower().removeprefix("0x")
        if sig not in methods:
            problems.append(f"{where}: not a method of {by_name[name]['artifact']}")
        elif methods[sig] is not None and data[:8] != methods[sig]:
            problems.append(f"{where}: calldata selector 0x{data[:8]} != 0x{methods[sig]}")
        problems += _check_calldata(
            where, sig, w.get("calldata"), w.get("args", []), addresses
        )
        for arg in w.get("args", []):
            if isinstance(arg, str) and not arg.startswith("0x") and arg not in by_name \
                    and arg not in peers:
                problems.append(f"{where}: argument {arg} names no contract or peer")
        wired.add((name, sig))
    for name, c in by_name.items():
        for e in c.get("genesisOnly", []):
            if (name, e["signature"]) not in wired:
                problems.append(f"{name}: genesis-only {e['signature']} is not wired")
        for e in c.get("deferred", []):
            if (name, e["signature"]) in wired:
                problems.append(f"{name}: deferred {e['signature']} is wired")
    return problems


def find_root(start: Path) -> Path:
    for candidate in [start, *start.parents]:
        if (candidate / "foundry.toml").is_file():
            return candidate
    raise SystemExit(f"no foundry.toml above {start}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, help="repository root (default: auto-detected)")
    parser.add_argument("--config", type=Path, help=f"configuration (default: {CONFIG})")
    parser.add_argument("--artifacts", type=Path, help="read method IDs from this out/ directory")
    args = parser.parse_args(argv)

    root = args.root or find_root(Path(__file__).resolve().parent)
    path = args.config or root / CONFIG
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read the genesis configuration {path}: {error}") from None
    if not isinstance(config, dict):
        raise SystemExit(f"{path}: the configuration must be a JSON object")
    ids = artifact_ids(args.artifacts) if args.artifacts else forge_inspect(root)
    present = source_present(root)
    try:
        problems = check(config, ids, scan_sources(root / "src"), present)
        waiting = pending(config, present)
    except (KeyError, TypeError, AttributeError, ValueError) as error:
        raise SystemExit(f"{path}: malformed configuration ({type(error).__name__}: {error})") from None
    for line in problems:
        print(f"FAIL {line}")
    contracts = len(config.get("contracts", []))
    wiring = len(config.get("wiring", []))
    if problems:
        print(f"genesis configuration: {len(problems)} problem(s)")
        return 1
    note = f"; pending (not merged yet): {', '.join(waiting)}" if waiting else ""
    print(
        f"genesis configuration: {contracts} contracts and {wiring} wiring calls match the build"
        f"{note}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
