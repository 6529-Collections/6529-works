#!/usr/bin/env python3
"""Export the integrator ABIs in abi/ from the default-profile Foundry build.

Writes one JSON ABI per deployable contract declared in src/ (a concrete `contract`, not an
abstract contract or a library) and per public interface (every `interface` declared under
src/interfaces/, except the third-party ones in src/interfaces/external/, and under
src/economics/interfaces/), plus abi/manifest.json, which lists for each file:

  - the contract name, its kind (`contract` or `interface`) and its source path;
  - for an interface, its ERC-165 interface ID: the XOR of the selectors of the functions the
    interface itself declares, not inherited ones (Solidity's `type(I).interfaceId`). Whether a
    deployed contract answers it through `supportsInterface` is in
    docs/integrators/abis-and-interface-ids.md;
  - the number of functions, events and errors in the ABI;
  - the solc version that compiled it;
  - the SHA-256 of the exported ABI file's bytes, which does not depend on git;
  - `"testOnly": true` for a contract that is not part of the protocol (TEST_ONLY below).

One contract outside src/ is exported too: the Sepolia open gate (script/sepolia/), a test-only
contract a test page calls on a Sepolia instance. It is never deployed on mainnet, and its
manifest entry says so with `testOnly`.

Some contracts answer part of their surface through a lens or an extension they forward calls
to with a read-only `staticcall` (docs/integrators/abis-and-interface-ids.md). For those,
abi/full/<Name>.json is the contract's ABI merged with what that call can serve (the forwarded
surface's view and pure functions, events and errors): the ABI to call the deployed address with.

If a name is ever declared twice in src/, the one under src/core/ or src/interfaces/core/ is
exported as abi/core/<Name>.json. Today every name is declared once, so abi/core/ is empty.

The output is deterministic: entries are sorted by kind, name and signature, keys are sorted,
and nothing from the compiler metadata or bytecode is written. `--check` compares the committed
abi/ against a fresh export from out/ and fails on any difference, missing or extra file.

Run `forge build` first (the default profile writes out/), then from the repository root:

    python tools/export_abis.py            # write abi/
    python tools/export_abis.py --check    # fail if abi/ differs from the build

Standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ABI_DIR = "abi"
MANIFEST = "manifest.json"
FULL_DIR = "full"
INTERFACE_DIRS = ("src/interfaces/", "src/economics/interfaces/")
EXCLUDED_DIRS = ("src/interfaces/external/",)
# The deployed contract, and the ABI of what it forwards with a read-only call (its lens or
# extension). Only the edition auctions have one: they forward every call they do not declare to
# their lens (the Independent Stream edition auction shares the edition auction's fallback). Keyed by
# source path.
FORWARDED = {
    "src/sales/UniformEditionAuction.sol": "UniformEditionAuctionLens",
    "src/independent/IndependentEditionAuction.sol": "IndependentEditionAuctionLens",
}
# Contracts outside src/ that are exported all the same, by source path. Each is test-only: not
# part of the protocol and never deployed on mainnet. Its manifest entry carries `testOnly`.
TEST_ONLY = {
    "script/sepolia/SepoliaOpenGate.sol": "SepoliaOpenGate",
}
# Sources of the plain permanent core; a name declared both here and elsewhere is exported
# under core/.
CORE_DIRS = ("src/core/", "src/interfaces/core/")
CORE_PREFIX = "core/"
# The paths the exporter owns in abi/: it writes, checks and removes only these.
MANAGED = re.compile(r"(?:full/)?(?:core/)?[A-Za-z_$][\w$]*\.json")
KIND_ORDER = {"constructor": 0, "fallback": 1, "receive": 2, "function": 3, "event": 4, "error": 5}

DECLARATION = re.compile(r"\b(abstract\s+contract|contract|interface|library)\s+([A-Za-z_$][\w$]*)")
FUNCTION_NAME = re.compile(r"\bfunction\s+([A-Za-z_$][\w$]*)\s*\(")
PARENT = re.compile(r"([A-Za-z_$][\w$.]*)\s*(?:\([^)]*\))?\s*(?:,|$)")


class ExportError(Exception):
    """The build output cannot be exported as it stands."""


# ------------------------------------------------------------------ source scanning


def strip_solidity(text: str) -> str:
    """Blank out comments and string-literal contents, keeping line breaks and code tokens."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
        elif c == "/" and nxt == "*":
            out.append(" ")  # a comment separates tokens: `function/* x */f()` is `function f()`
            i += 2
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                if text[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        elif c in "\"'":
            out.append(c)
            i += 1
            while i < n and text[i] != c:
                i += 2 if text[i] == "\\" else 1
            out.append(c)
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def declarations(code: str) -> list[tuple[str, str, str, list[str]]]:
    """Each top-level declaration in stripped `code`: (kind, name, body, parent names)."""
    found = []
    for m in DECLARATION.finditer(code):
        kind = "abstract" if m.group(1).startswith("abstract") else m.group(1)
        open_index = code.find("{", m.end())
        if open_index < 0:
            continue
        header = code[m.end() : open_index].strip()
        parents = PARENT.findall(header[2:].strip()) if re.match(r"is\b", header) else []
        depth = 0
        for close_index in range(open_index, len(code)):
            if code[close_index] == "{":
                depth += 1
            elif code[close_index] == "}":
                depth -= 1
                if depth == 0:
                    break
        found.append((kind, m.group(2), code[open_index + 1 : close_index], parents))
    return found


def own_functions(body: str) -> list[tuple[str, int]]:
    """(name, parameter count) of every function a contract body declares itself, sorted, one
    entry per declaration (two overloads of one arity give two equal entries)."""
    found = []
    for m in FUNCTION_NAME.finditer(body):
        depth, start = 1, m.end()
        i = start
        while depth and i < len(body):
            if body[i] == "(":
                depth += 1
            elif body[i] == ")":
                depth -= 1
            i += 1
        text = body[start : i - 1]
        level, count, seen = 0, 0, False
        for ch in text:
            if ch in "([":
                level += 1
            elif ch in ")]":
                level -= 1
            elif ch == "," and level == 0:
                count += 1
            seen = seen or not ch.isspace()
        found.append((m.group(1), count + 1 if seen else 0))
    return sorted(found)


def is_public_interface(source: str) -> bool:
    return source.startswith(INTERFACE_DIRS) and not source.startswith(EXCLUDED_DIRS)


# ------------------------------------------------------------------ ABI shaping


def canonical_type(param: dict) -> str:
    """The canonical ABI type of one parameter, tuples expanded."""
    t = param["type"]
    if t.startswith("tuple"):
        inner = ",".join(canonical_type(c) for c in param.get("components", []))
        return f"({inner}){t[len('tuple'):]}"
    return t


def signature(entry: dict) -> str:
    inputs = ",".join(canonical_type(p) for p in entry.get("inputs", []))
    return f"{entry.get('name', '')}({inputs})"


def sort_key(entry: dict) -> tuple:
    return (KIND_ORDER.get(entry["type"], 9), entry.get("name", ""), signature(entry))


def normalize(abi: list[dict]) -> list[dict]:
    """The ABI sorted by kind, name and signature, with each entry's keys sorted."""
    return [json.loads(json.dumps(e, sort_keys=True)) for e in sorted(abi, key=sort_key)]


def forwardable(entry: dict) -> bool:
    """Whether a forwarded entry works through a read-only `staticcall`: events, errors, and the
    view and pure functions (one that writes, such as a lens's `masterTerms`, reverts there)."""
    if entry["type"] == "function":
        return entry.get("stateMutability") in ("view", "pure")
    return entry["type"] in ("event", "error")


def merged(abi: list[dict], forwarded: list[dict]) -> list[dict]:
    """`abi` plus the forwardable entries of `forwarded` it lacks (by signature)."""
    seen = {(e["type"], signature(e)) for e in abi}
    extra = [e for e in forwarded if forwardable(e) and (e["type"], signature(e)) not in seen]
    return normalize(abi + extra)


def interface_id(
    abi: list[dict],
    selectors: dict[str, str],
    own: list[tuple[str, int]],
    inherited: set[str] | None = None,
) -> str:
    """XOR of the selectors of the functions the interface itself declares. Each declaration is
    matched by name and parameter count; when the ABI has more functions of that name and arity
    than the interface declares, those its parents' ABIs list (`inherited`, by signature) are
    left out. A match that stays ambiguous fails."""
    value = 0
    for name, arity in sorted(set(own)):
        count = own.count((name, arity))
        matches = [
            signature(e)
            for e in abi
            if e["type"] == "function" and e["name"] == name and len(e["inputs"]) == arity
        ]
        if len(matches) != count and inherited is not None:
            matches = [s for s in matches if s not in inherited]
        if len(matches) != count:
            raise ExportError(f"cannot match {name} with {arity} parameters to one ABI function")
        for sig in matches:
            value ^= int(selectors[sig], 16)
    return f"0x{value:08x}"


def encode(data: object) -> bytes:
    return (json.dumps(data, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("utf-8")


# ------------------------------------------------------------------ export


def collect(root: Path, out: Path) -> dict[str, dict]:
    """Every exported contract by name: kind, source, ABI, selectors and solc version."""
    source_cache: dict[str, list[tuple[str, str, str, list[str]]]] = {}
    by_name: dict[str, list[dict]] = {}
    abis_by_name: dict[str, list[list]] = {}  # every artifact's ABI, for interface parents
    for path in sorted(out.rglob("*.json")):
        if path.parent.name == "build-info":
            continue
        try:
            artifact = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise ExportError(f"{path}: unreadable artifact ({exc}); rebuild with `forge build`")
        if not isinstance(artifact, dict):
            raise ExportError(f"{path}: malformed artifact (not a JSON object)")
        metadata = artifact.get("metadata")
        if not isinstance(metadata, dict) or "abi" not in artifact:
            continue
        target = metadata.get("settings", {}).get("compilationTarget", {})
        if not isinstance(target, dict) or len(target) != 1:
            continue
        source, name = next(iter(target.items()))
        abi, selectors = artifact["abi"], artifact.get("methodIdentifiers", {})
        if not (
            isinstance(abi, list)
            and all(isinstance(e, dict) and isinstance(e.get("type"), str) for e in abi)
            and isinstance(selectors, dict)
        ):
            raise ExportError(f"{path}: malformed artifact (abi or methodIdentifiers)")
        abis_by_name.setdefault(name, []).append(abi)
        if not source.startswith("src/") and TEST_ONLY.get(source) != name:
            continue
        if source not in source_cache:
            # A restored compiler cache can hold artifacts of sources that no longer exist, or of
            # contracts a source no longer declares; forge leaves them in `out/`. They are not
            # part of this build, so they are skipped.
            file = root / source
            text = file.read_text(encoding="utf-8") if file.is_file() else ""
            source_cache[source] = declarations(strip_solidity(text))
        decl = next((d for d in source_cache[source] if d[1] == name), None)
        if decl is None:
            continue
        kind, _, body, parents = decl
        if exported(kind, source):
            if any(c["source"] == source for c in by_name.get(name, [])):
                continue  # one source compiled twice (two artifact folders)
            by_name.setdefault(name, []).append({
                "name": name,
                "kind": kind,
                "source": source,
                "abi": abi,
                "selectors": selectors,
                "own": own_functions(body),
                "parents": parents,
                "solc": metadata.get("compiler", {}).get("version", ""),
            })
    found = keyed(by_name)
    if not found:
        raise ExportError(f"no src/ artifacts under {out}: run `forge build` first")
    missing = sorted(set(expected(root)) - {c["name"] for c in found.values()})
    if missing:
        raise ExportError(f"declared in src/ but missing from the build: {', '.join(missing)}")
    for c in found.values():
        c["inherited"] = inherited(c["parents"], abis_by_name)
    return found


def keyed(by_name: dict[str, list[dict]]) -> dict[str, dict]:
    """Every exported contract by its file key: its name, or `core/<name>` for the plain-core
    one of two contracts sharing a name. Any other repeated name fails."""
    found: dict[str, dict] = {}
    for name, items in sorted(by_name.items()):
        if len(items) == 1:
            found[name] = items[0]
            continue
        core = [c for c in items if c["source"].startswith(CORE_DIRS)]
        if len(items) != 2 or len(core) != 1:
            sources = ", ".join(sorted(c["source"] for c in items))
            raise ExportError(f"two exported contracts are named {name} ({sources})")
        old = next(c for c in items if c is not core[0])
        found[name] = old
        found[CORE_PREFIX + name] = core[0]
    return found


def exported(kind: str, source: str) -> bool:
    if not source.startswith("src/"):
        return kind == "contract" and source in TEST_ONLY
    return kind == "contract" or (kind == "interface" and is_public_interface(source))


def expected(root: Path) -> list[str]:
    """Every contract and public interface the sources under src/ declare, and the test-only
    contracts of TEST_ONLY whose source exists."""
    names = [name for source, name in sorted(TEST_ONLY.items()) if (root / source).is_file()]
    for file in sorted((root / "src").rglob("*.sol")):
        source = file.relative_to(root).as_posix()
        for kind, name, _, _ in declarations(strip_solidity(file.read_text(encoding="utf-8"))):
            if exported(kind, source):
                names.append(name)
    return names


def inherited(parents: list[str], abis_by_name: dict[str, list[list]]) -> set[str] | None:
    """The function signatures the parents' ABIs list, or None when a parent's artifact is
    missing or ambiguous (two different ABIs under its name)."""
    sigs: set[str] = set()
    for parent in parents:
        abis = {encode(normalize(a)) for a in abis_by_name.get(parent.split(".")[-1], [])}
        if len(abis) != 1:
            return None
        sigs |= {signature(e) for e in json.loads(abis.pop()) if e["type"] == "function"}
    return sigs


def render(found: dict[str, dict]) -> dict[str, bytes]:
    """Every file of abi/ by relative path, as bytes."""
    files: dict[str, bytes] = {}
    entries = []
    for key in sorted(found):
        c = found[key]
        abi = normalize(c["abi"])
        data = encode(abi)
        files[f"{key}.json"] = data
        entry = {
            "name": c["name"],
            "kind": c["kind"],
            "source": c["source"],
            "abi": f"{key}.json",
            "functions": sum(e["type"] == "function" for e in abi),
            "events": sum(e["type"] == "event" for e in abi),
            "errors": sum(e["type"] == "error" for e in abi),
            "solc": c["solc"],
            "sha256": hashlib.sha256(data).hexdigest(),
        }
        if c["source"] in TEST_ONLY:
            entry["testOnly"] = True
        if c["kind"] == "interface":
            entry["interfaceId"] = interface_id(abi, c["selectors"], c["own"], c["inherited"])
        lens = FORWARDED.get(c["source"])
        if lens is not None:
            if lens not in found:
                raise ExportError(
                    f"{c['source']} forwards to {lens}, which the build lacks: update FORWARDED"
                )
            full = encode(merged(c["abi"], found[lens]["abi"]))
            files[f"{FULL_DIR}/{key}.json"] = full
            entry["forwardsTo"] = lens
            entry["fullAbi"] = f"{FULL_DIR}/{key}.json"
            entry["fullSha256"] = hashlib.sha256(full).hexdigest()
        entries.append(entry)
    solc = sorted({e["solc"] for e in entries})
    manifest = {
        "generator": "tools/export_abis.py",
        "profile": "default",
        "solc": solc[0] if len(solc) == 1 else solc,
        "contracts": entries,
    }
    files[MANIFEST] = encode(manifest)
    return files


def existing(abi_dir: Path) -> dict[str, bytes]:
    """The files of `abi_dir` the exporter owns (MANAGED); anything else there is left alone."""
    if not abi_dir.is_dir():
        return {}
    found = {}
    for p in sorted(abi_dir.rglob("*")):
        rel = p.relative_to(abi_dir).as_posix()
        if p.is_file() and MANAGED.fullmatch(rel):
            found[rel] = p.read_bytes()
    return found


def diff(committed: dict[str, bytes], fresh: dict[str, bytes]) -> list[str]:
    problems = []
    for rel in sorted(set(committed) | set(fresh)):
        if rel not in fresh:
            problems.append(f"abi/{rel}: committed but not produced by the build (stale)")
        elif rel not in committed:
            problems.append(f"abi/{rel}: missing; run python tools/export_abis.py")
        elif committed[rel] != fresh[rel]:
            problems.append(f"abi/{rel}: differs from the build; run python tools/export_abis.py")
    return problems


def write(abi_dir: Path, fresh: dict[str, bytes]) -> None:
    for rel in existing(abi_dir):
        if rel not in fresh:
            (abi_dir / rel).unlink()
    for rel, data in fresh.items():
        path = abi_dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.is_file() or path.read_bytes() != data:
            path.write_bytes(data)


def find_root(start: Path) -> Path:
    for candidate in (start, *start.parents):
        if (candidate / "foundry.toml").is_file():
            return candidate
    raise SystemExit("no foundry.toml found above " + str(start))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, help="repository root (default: auto-detected)")
    parser.add_argument("--out", type=Path, help="Foundry artifacts (default: <root>/out)")
    parser.add_argument("--abi-dir", type=Path, help="export directory (default: <root>/abi)")
    parser.add_argument("--check", action="store_true", help="fail if abi/ differs; write nothing")
    args = parser.parse_args(argv)

    root = args.root or find_root(Path(__file__).resolve().parent)
    out = args.out or root / "out"
    abi_dir = args.abi_dir or root / ABI_DIR
    try:
        fresh = render(collect(root, out))
    except ExportError as exc:
        print(f"export_abis: {exc}", file=sys.stderr)
        return 2
    if args.check:
        problems = diff(existing(abi_dir), fresh)
        for p in problems:
            print(p, file=sys.stderr)
        if problems:
            return 1
        print(f"abi/ matches the build ({len(fresh)} files)")
        return 0
    write(abi_dir, fresh)
    print(f"wrote {len(fresh)} files to {abi_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
