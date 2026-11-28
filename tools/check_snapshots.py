#!/usr/bin/env python3
"""Checks every src/ contract's ABI and storage layout against the committed snapshots.

Usage (Python 3.10 or later, standard library only), after `forge build`:

    python tools/check_snapshots.py                 # compare, reading the artifacts in out/
    python tools/check_snapshots.py --update        # rewrite the snapshots after an agreed change
    python tools/check_snapshots.py --artifacts DIR # read another build directory

Every contract and library declared in src/ (interfaces and abstract contracts excepted: what
they declare appears in the contracts that implement them) has an ABI snapshot,
test/snapshots/abi/<Name>.json: every function, event and error with its full ABI entry
(parameter names, internal types, mutability, indexed flags), its canonical signature and its
selector or topic hash, sorted by kind and signature. A renamed parameter, a changed event or a
new error shows in review as a short diff. Every contract (not library) also has a storage
snapshot, test/snapshots/storage/<Name>.json: the slot, offset, type and declaring contract of
every state variable, and the same for every member of every struct stored anywhere in its
storage, keyed by the struct's qualified name, with the compiler's AST IDs left out so the file
changes only when the layout does. Storage the code addresses itself in assembly at fixed slots
(for example `StreamLayout`) is not part of the compiler's layout and is pinned by its own tests.

The tool reads the compiled artifacts (`out/<File>.sol/<Name>.json`); the storage layout is
there because foundry.toml asks for it (`extra_output = ["storageLayout"]`, which changes no
bytecode). Exits 0 when every snapshot matches, 1 when any differs, is missing or is stale (a
snapshot for a contract src/ no longer declares), 2 when an artifact is missing or lacks a field.
"""

from __future__ import annotations

import argparse
import difflib
import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SNAPSHOTS = "test/snapshots"
SRC = "src"
DECLARATION = re.compile(r"^(contract|library)\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)

_KECCAK = None


def keccak256(data: bytes) -> bytes:
    global _KECCAK
    if _KECCAK is None:
        path = Path(__file__).resolve().parent / "content" / "keccak.py"
        spec = importlib.util.spec_from_file_location("stream_keccak_snapshots", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _KECCAK = module.keccak256
    return _KECCAK(data)


class ArtifactError(Exception):
    pass


def declared_contracts(root: Path) -> dict[str, tuple[str, str]]:
    """Every contract and library declared at the top level of a file under src/:
    name -> (kind, source path relative to the root). Interfaces and abstract contracts do not
    match the pattern."""
    found: dict[str, tuple[str, str]] = {}
    for path in sorted((root / SRC).rglob("*.sol")):
        rel = path.relative_to(root).as_posix()
        for kind, name in DECLARATION.findall(path.read_text(encoding="utf-8")):
            if name in found:
                raise ArtifactError(f"{name} is declared in both {found[name][1]} and {rel}")
            found[name] = (kind, rel)
    return found


def _type_string(param: dict) -> str:
    t = param["type"]
    if t.startswith("tuple"):
        return "(" + ",".join(_type_string(c) for c in param.get("components", [])) + ")" + t[len("tuple") :]
    return t


def signature(item: dict) -> str:
    return f"{item['name']}({','.join(_type_string(p) for p in item.get('inputs', []))})"


def abi_snapshot(abi: list[dict], method_ids: dict[str, str]) -> list[dict]:
    """The ABI sorted by kind and signature, each function, event and error with its ID: the
    4-byte selector of a function or error, the 32-byte topic0 of an event."""
    entries = []
    for item in abi:
        entry = dict(item)
        kind = item["type"]
        if kind in ("function", "event", "error"):
            sig = signature(item)
            digest = keccak256(sig.encode("ascii")).hex()
            entry["signature"] = sig
            if kind == "event":
                entry["id"] = "0x" + digest
            else:
                entry["id"] = "0x" + digest[:8]
            if kind == "function" and sig in method_ids and method_ids[sig] != digest[:8]:
                # Library functions with storage parameters: the compiler's selector is the
                # authority, and the computed one would be wrong.
                entry["id"] = "0x" + method_ids[sig]
        entries.append(entry)
    return sorted(entries, key=lambda e: (e["type"], e.get("signature", "")))


def storage_snapshot(layout: dict) -> dict:
    """Slots, offsets, type labels and declaring contracts of the state variables and of each
    stored struct's members. Struct keys are the compiler's qualified labels, not type IDs, so
    no AST ID appears."""
    types = layout.get("types") or {}

    def row(var: dict) -> dict:
        return {
            "contract": var.get("contract", "").rsplit(":", 1)[-1],
            "label": var["label"],
            "offset": var["offset"],
            "slot": int(var["slot"]),
            "type": types[var["type"]]["label"],
        }

    structs: dict[str, list[dict]] = {}
    for type_id in sorted(types):
        t = types[type_id]
        if "members" in t:
            members = [row(m) for m in t["members"]]
            for m in members:
                del m["contract"]
            label = t["label"]
            if label in structs and structs[label] != members:
                raise ArtifactError(f"two different structs are labelled {label}")
            structs[label] = members
    return {"variables": [row(v) for v in layout.get("storage", [])], "structs": structs}


def render(data: object) -> str:
    return json.dumps(data, indent=2, sort_keys=True) + "\n"


def load_artifact(artifacts: Path, name: str, source: str) -> dict:
    path = artifacts / Path(source).name / f"{name}.json"
    if not path.exists():
        raise ArtifactError(f"no artifact {path.as_posix()}: run `forge build` first")
    return json.loads(path.read_text(encoding="utf-8"))


def expected_snapshots(root: Path, artifacts: Path) -> dict[str, str]:
    """Every snapshot file (path relative to test/snapshots) as the current build writes it."""
    files: dict[str, str] = {}
    for name, (kind, source) in sorted(declared_contracts(root).items()):
        art = load_artifact(artifacts, name, source)
        if "abi" not in art:
            raise ArtifactError(f"the artifact of {name} has no ABI")
        files[f"abi/{name}.json"] = render(abi_snapshot(art["abi"], art.get("methodIdentifiers") or {}))
        if kind == "contract":
            layout = art.get("storageLayout")
            if layout is None:
                raise ArtifactError(
                    f"the artifact of {name} has no storage layout: foundry.toml must keep "
                    '`extra_output = ["storageLayout"]`'
                )
            files[f"storage/{name}.json"] = render(storage_snapshot(layout))
    return files


def committed_snapshots(directory: Path) -> dict[str, str]:
    if not directory.exists():
        return {}
    return {
        p.relative_to(directory).as_posix(): p.read_text(encoding="utf-8")
        for p in sorted(directory.rglob("*.json"))
    }


def compare(expected: dict[str, str], committed: dict[str, str]) -> list[str]:
    """One report per snapshot that differs, is missing or is stale; empty when all match."""
    reports = []
    for name, text in expected.items():
        old = committed.get(name)
        if old is None:
            reports.append(f"missing snapshot test/snapshots/{name}")
        elif old != text:
            diff = difflib.unified_diff(
                old.splitlines(keepends=True), text.splitlines(keepends=True), f"committed/{name}", f"build/{name}"
            )
            reports.append("".join(diff))
    for name in sorted(set(committed) - set(expected)):
        reports.append(f"stale snapshot test/snapshots/{name}: src/ no longer declares it")
    return reports


def update(expected: dict[str, str], directory: Path) -> tuple[int, int]:
    """Writes every expected snapshot and removes stale ones; returns (written, removed)."""
    removed = 0
    for name in sorted(set(committed_snapshots(directory)) - set(expected)):
        (directory / name).unlink()
        removed += 1
    for name, text in expected.items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
    return len(expected), removed


def main(argv: list[str], root: Path = ROOT) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--update", action="store_true", help="rewrite the snapshots from the current build")
    ap.add_argument("--artifacts", type=Path, default=None, help="build directory (default: out)")
    args = ap.parse_args(argv)
    artifacts = args.artifacts if args.artifacts is not None else root / "out"
    directory = root / SNAPSHOTS
    try:
        expected = expected_snapshots(root, artifacts)
    except ArtifactError as e:
        print(f"check_snapshots.py: {e}")
        return 2
    if args.update:
        written, removed = update(expected, directory)
        print(f"wrote {written} snapshots to {SNAPSHOTS}, removed {removed} stale")
        return 0
    reports = compare(expected, committed_snapshots(directory))
    for r in reports:
        print(r)
    contracts = sum(1 for n in expected if n.startswith("abi/"))
    if reports:
        print(
            f"{len(reports)} snapshot(s) differ. If the change is agreed, run "
            "`python tools/check_snapshots.py --update` and commit the snapshots with it."
        )
        return 1
    print(f"ABI and storage layout of {contracts} contracts and libraries match the snapshots")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
