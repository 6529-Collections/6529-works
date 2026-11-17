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
  - the SHA-256 of the exported ABI file's bytes, which does not depend on git.

Three contracts answer part of their surface through a lens or an extension they forward calls
to (docs/integrators/abis-and-interface-ids.md). For those, abi/full/<Name>.json is the contract's
ABI merged with the forwarded surface: the ABI to call the deployed address with.

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
# extension). The fallback of Stream forwards only IStreamViews; the two auctions forward every
# call they do not declare to their lens.
FORWARDED = {
    "Stream": "IStreamViews",
    "EnglishAuction": "EnglishAuctionLens",
    "UniformEditionAuction": "UniformEditionAuctionLens",
}
KIND_ORDER = {"constructor": 0, "fallback": 1, "receive": 2, "function": 3, "event": 4, "error": 5}

DECLARATION = re.compile(r"\b(abstract\s+contract|contract|interface|library)\s+([A-Za-z_$][\w$]*)")
FUNCTION_NAME = re.compile(r"\bfunction\s+([A-Za-z_$][\w$]*)\s*\(")


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


def declarations(code: str) -> list[tuple[str, str, str]]:
    """Each top-level declaration in stripped `code`: (kind, name, body)."""
    found = []
    for m in DECLARATION.finditer(code):
        kind = "abstract" if m.group(1).startswith("abstract") else m.group(1)
        open_index = code.find("{", m.end())
        if open_index < 0:
            continue
        depth = 0
        for close_index in range(open_index, len(code)):
            if code[close_index] == "{":
                depth += 1
            elif code[close_index] == "}":
                depth -= 1
                if depth == 0:
                    break
        found.append((kind, m.group(2), code[open_index + 1 : close_index]))
    return found


def own_functions(body: str) -> set[tuple[str, int]]:
    """(name, parameter count) of every function a contract body declares itself."""
    found = set()
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
        found.add((m.group(1), count + 1 if seen else 0))
    return found


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


def merged(abi: list[dict], forwarded: list[dict]) -> list[dict]:
    """`abi` plus the functions, events and errors of `forwarded` it lacks (by signature)."""
    seen = {(e["type"], signature(e)) for e in abi}
    extra = [
        e
        for e in forwarded
        if e["type"] in ("function", "event", "error") and (e["type"], signature(e)) not in seen
    ]
    return normalize(abi + extra)


def interface_id(abi: list[dict], selectors: dict[str, str], own: set[tuple[str, int]]) -> str:
    """XOR of the selectors of the functions the interface itself declares, matched by name and
    parameter count; an ambiguous match (an inherited overload of the same arity) fails."""
    value = 0
    for name, arity in sorted(own):
        matches = [
            e
            for e in abi
            if e["type"] == "function" and e["name"] == name and len(e["inputs"]) == arity
        ]
        if len(matches) != 1:
            raise ExportError(f"cannot match {name} with {arity} parameters to one ABI function")
        value ^= int(selectors[signature(matches[0])], 16)
    return f"0x{value:08x}"


def encode(data: object) -> bytes:
    return (json.dumps(data, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("utf-8")


# ------------------------------------------------------------------ export


def collect(root: Path, out: Path) -> dict[str, dict]:
    """Every exported contract by name: kind, source, ABI, selectors and solc version."""
    source_cache: dict[str, list[tuple[str, str, str]]] = {}
    found: dict[str, dict] = {}
    for path in sorted(out.rglob("*.json")):
        if path.parent.name == "build-info":
            continue
        try:
            artifact = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        metadata = artifact.get("metadata")
        if not isinstance(metadata, dict) or "abi" not in artifact:
            continue
        target = metadata.get("settings", {}).get("compilationTarget", {})
        if len(target) != 1:
            continue
        source, name = next(iter(target.items()))
        if not source.startswith("src/"):
            continue
        if source not in source_cache:
            text = (root / source).read_text(encoding="utf-8")
            source_cache[source] = declarations(strip_solidity(text))
        decl = next((d for d in source_cache[source] if d[1] == name), None)
        if decl is None:
            raise ExportError(f"{name} is not declared in {source}")
        kind, _, body = decl
        if kind == "contract" or (kind == "interface" and is_public_interface(source)):
            if name in found:
                raise ExportError(f"two exported contracts are named {name}")
            found[name] = {
                "kind": kind,
                "source": source,
                "abi": artifact["abi"],
                "selectors": artifact.get("methodIdentifiers", {}),
                "own": own_functions(body),
                "solc": metadata.get("compiler", {}).get("version", ""),
            }
    if not found:
        raise ExportError(f"no src/ artifacts under {out}: run `forge build` first")
    for name, lens in FORWARDED.items():
        if name not in found or lens not in found:
            raise ExportError(f"{name} or its forwarded surface {lens} is missing from the build")
    return found


def render(found: dict[str, dict]) -> dict[str, bytes]:
    """Every file of abi/ by relative path, as bytes."""
    files: dict[str, bytes] = {}
    entries = []
    for name in sorted(found):
        c = found[name]
        abi = normalize(c["abi"])
        data = encode(abi)
        files[f"{name}.json"] = data
        entry = {
            "name": name,
            "kind": c["kind"],
            "source": c["source"],
            "abi": f"{name}.json",
            "functions": sum(e["type"] == "function" for e in abi),
            "events": sum(e["type"] == "event" for e in abi),
            "errors": sum(e["type"] == "error" for e in abi),
            "solc": c["solc"],
            "sha256": hashlib.sha256(data).hexdigest(),
        }
        if c["kind"] == "interface":
            entry["interfaceId"] = interface_id(abi, c["selectors"], c["own"])
        if name in FORWARDED:
            full = encode(merged(c["abi"], found[FORWARDED[name]]["abi"]))
            files[f"{FULL_DIR}/{name}.json"] = full
            entry["forwardsTo"] = FORWARDED[name]
            entry["fullAbi"] = f"{FULL_DIR}/{name}.json"
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
    if not abi_dir.is_dir():
        return {}
    return {
        p.relative_to(abi_dir).as_posix(): p.read_bytes()
        for p in sorted(abi_dir.rglob("*"))
        if p.is_file()
    }


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
