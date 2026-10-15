#!/usr/bin/env python3
"""Mutation testing of src/ with slither-mutate: run a shard, re-check survivors, report.

slither-mutate (part of the pinned Slither install, requirements-tools.lock) rewrites one
source file at a time (revert a function body, comment out a statement, swap an operator,
replace a literal, and so on), checks that the mutant compiles, and runs a test command. A
mutant is KILLED when the tests fail and SURVIVES when they pass. Every survivor is either an
equivalent mutant (the change does not alter behaviour) or a missing test.

slither-mutate never changes a `constant`, and the protocol's limits are constants, so this
tool adds one rule of its own, CONST: every integer-literal constant is moved one up and one
down, and each change must fail a test.

Subcommands:
  list                     the shards: one per src/ file with code, the largest split into
                           four mutator groups (SPLIT_FILES, SPLIT_GROUPS)
  run SHARD [...]          mutate the shard's file against its module's tests, re-run every
                           survivor against the whole suite (--no-recheck skips that) and
                           write OUT/SHARD/results.json and the logs
  report OUT [...]         merge results.json files into a Markdown report (--markdown) and a
                           JSON summary (--json); --floors FILE fails when a contract's kill
                           rate falls below its recorded floor
  forge-test [ARGS ...]    the test command slither-mutate runs (internal): `forge test
                           --fail-fast ARGS` under FOUNDRY_PROFILE=lite
  slither-mutate [ARGS]    slither-mutate itself, with source files written byte for byte
                           (internal; see below)

Why two stages. Each mutant recompiles what depends on the mutated file, so running the
whole suite for every mutant would take days. The module's own tests run first; only the
mutants they miss run against everything (integration flows, deploy tests, other modules),
so a mutant the integration tests kill still counts as killed.

Why FOUNDRY_PROFILE=lite for the tests. slither-mutate checks each mutant with crytic-compile,
which runs `forge clean` and a targeted `forge build` in the default profile first. The lite
profile builds into out-lite/ and cache-lite/, so that clean does not throw away the test
build and each mutant recompiles only what changed. Lite also runs fewer fuzz and invariant
cases (see foundry.toml).

Why slither-mutate runs through this script. It restores each source file after a mutant by
writing text, which on Windows turns LF line endings into CRLF. solc's byte offsets then stop
matching the file, so every later mutant lands in the wrong place and fails to compile. The
`slither-mutate` subcommand runs the same tool with text written exactly as read (a no-op on
Linux and macOS, where text mode does not translate line endings), and with two operators
fixed: ROR no longer aborts on a Yul comparison and LIR no longer aborts on a `bool` literal
(see `_patch_mutators`).

The working tree is modified while a shard runs (slither-mutate restores every file at the
end, and so does this script): run it in a scratch checkout, never in one you are editing.

Run from the repository root: `python tools/mutation.py run libraries-Utf8`. Needs Foundry,
and Slither from requirements-tools.lock. Standard library only otherwise.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

# The tests a mutant of a file under src/<module>/ runs first (a `forge test --match-path`
# glob). The re-check of a survivor runs every test.
MODULE_TESTS: dict[str, str] = {
    "content": "test/content/**",
    "curation": "test/curation/**",
    "economics": "test/economics/**",
    "editions": "test/editions/**",
    "entropy": "test/entropy/**",
    "governance": "test/{governance,deploy}/**",
    "identity": "test/identity/**",
    "interfaces": "test/{interfaces,libraries,helpers}/**",
    "libraries": "test/{libraries,interfaces,helpers}/**",
    "records": "test/records/**",
    "sales": "test/sales/**",
    "stream": "test/stream/**",
}
RECHECK_TESTS = "test/**"

# Files too large for one CI job (6 hours on a 4-core runner) are split into one shard per
# mutator group, run in parallel and merged again in the report: the statement group (revert a
# body, comment out a statement) with CONST, and three groups of the operators that change
# logic (arithmetic, logical and unary operators; relational operators; `if` conditions).
# These files skip the other eight operators (assignment, bitwise, literal, initialiser,
# function-header, `while`-wrap and Solidity-specific swaps): on the first campaign they gave
# almost only equivalent or repeated mutants (nine assignment variants of one subtraction, a
# literal 0 replaced by 0, `storage` read as `memory`) at the price of hours per file. Every
# other file runs all fifteen.
SPLIT_FILES = {
    "src/content/Renderer.sol",
    "src/content/JsonScan.sol",
    "src/curation/PackageRegistry.sol",
    "src/identity/ArtistRegistry.sol",
    "src/sales/EnglishAuction.sol",
    "src/stream/Stream.sol",
    "src/stream/WorkRecords.sol",
}
SPLIT_GROUPS = {
    "statements": "RR,CR",
    "operators": "AOR,LOR,UOR",
    "relations": "ROR",
    "conditions": "MIA",
}
SKIPPED_ON_SPLIT_FILES = "ASOR,BOR,FHR,LIR,MVIE,MVIV,MWA,SBR"
# The split files' relational shard uses two replacements per comparison instead of five.
SUFFICIENT_ROR_ENV = "MUTATION_SUFFICIENT_ROR"

CATEGORIES = ("revert", "comment", "tweak", "constant")
SUMMARY = re.compile(r"(Revert|Comment|Tweak) mutants: (\d+) caught of (\d+)", re.IGNORECASE)
UNCAUGHT = re.compile(r"\[(\w+)\] Line (\d+): '(.*?)' ==> '(.*?)' --> UNCAUGHT", re.S)
ABORTED = "Test suite fails with mutations, aborting"
TIMED_OUT = "Tests took too long"
# `uint256 internal constant NAME = 1_000;` (any visibility order), integer literals only.
CONSTANT = re.compile(
    r"^(?P<head>[ \t]*u?int\d*(?:[ \t]+(?:internal|private|public|constant))+[ \t]+"
    r"[A-Za-z_]\w*[ \t]*=[ \t]*)(?P<value>0x[0-9a-fA-F_]+|\d[\d_]*)(?P<tail>[ \t]*;)",
    re.M,
)
# A contract or library, or a file-level function or constant (HashRef.sol has both).
CODE = re.compile(
    r"^\s*(?:abstract\s+)?(?:contract|library)\s+\w+|^function\s|^u?int\d*\s+constant\s",
    re.M,
)


@dataclass(frozen=True)
class Shard:
    name: str
    path: str
    tests: str
    mutators: str | None  # None: every slither-mutate mutator
    constants: bool


@dataclass
class Survivor:
    rule: str
    line: int
    old: str
    new: str
    mutant_file: str = ""
    # "killed" by the whole suite, "survived" it, "timeout" (counted as killed), or
    # "not-rechecked".
    recheck: str = "not-rechecked"


@dataclass
class FileResult:
    path: str
    status: str = "ok"  # ok, aborted, error
    caught: dict[str, int] = field(default_factory=lambda: {c: 0 for c in CATEGORIES})
    total: dict[str, int] = field(default_factory=lambda: {c: 0 for c in CATEGORIES})
    survivors: list[Survivor] = field(default_factory=list)
    # Mutants counted as killed because the test command timed out (slither-mutate's rule).
    timeouts: int = 0
    seconds: float = 0.0

    @property
    def mutants(self) -> int:
        return sum(self.total.values())

    @property
    def killed(self) -> int:
        """Killed by the module's tests, plus survivors the whole suite killed."""
        return sum(self.caught.values()) + sum(
            1 for s in self.survivors if s.recheck in ("killed", "timeout")
        )


class MutationError(Exception):
    pass


# ------------------------------------------------------------------------------------ shards


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def source_files(root: Path) -> list[str]:
    """Every src/ file with code to mutate (interface-only files have none)."""
    out = []
    for path in root.glob("src/**/*.sol"):
        if CODE.search(_strip_comments(path.read_text(encoding="utf-8"))):
            out.append(path.relative_to(root).as_posix())
    return sorted(out)


def _module(rel: str) -> str:
    parts = rel.split("/")
    return parts[1] if len(parts) > 2 else ""


def shards(root: Path) -> dict[str, Shard]:
    out: dict[str, Shard] = {}
    for rel in source_files(root):
        module = _module(rel)
        if module not in MODULE_TESTS:
            raise MutationError(f"{rel}: no tests are mapped for module {module!r}")
        base = f"{module}-{Path(rel).stem}"
        tests = MODULE_TESTS[module]
        if rel in SPLIT_FILES:
            for group, mutators in SPLIT_GROUPS.items():
                name = f"{base}-{group}"
                out[name] = Shard(name, rel, tests, mutators, group == "statements")
        else:
            out[base] = Shard(base, rel, tests, None, True)
    missing = SPLIT_FILES - {s.path for s in out.values()}
    if missing:
        raise MutationError(f"SPLIT_FILES names files that do not exist: {sorted(missing)}")
    return out


# ------------------------------------------------------------------------- slither-mutate


def parse_log(text: str, result: FileResult) -> None:
    """Fills `result` from one slither-mutate log."""
    if ABORTED in text:
        result.status = "aborted"
        return
    result.timeouts += text.count(TIMED_OUT)
    for kind, caught, total in SUMMARY.findall(text):
        result.caught[kind.lower()] += int(caught)
        result.total[kind.lower()] += int(total)
    counters: dict[str, int] = {}
    found = 0
    for rule, line, old, new in UNCAUGHT.findall(text):
        index = counters.get(rule, 0)
        counters[rule] = index + 1
        found += 1
        result.survivors.append(
            Survivor(rule, int(line), old.strip(), new.strip(), mutant_file=f"{rule}_{index}")
        )
    uncaught = sum(result.total[c] - result.caught[c] for c in ("revert", "comment", "tweak"))
    if found != uncaught:
        raise MutationError(
            f"{result.path}: log lists {found} survivors but its totals imply {uncaught}"
        )


def slither_mutate(args: list[str]) -> int:
    """Runs slither-mutate's own entry point with text files written without newline changes."""
    import builtins
    import pathlib

    real_open = builtins.open
    real_path_open = pathlib.Path.open
    real_write_text = pathlib.Path.write_text

    def _keep(mode: str, rest: tuple, kw: dict) -> None:
        # Text writes only, and only when the caller did not choose (newline is the 4th
        # optional positional argument after mode).
        if "b" not in mode and any(c in mode for c in "wax+") and len(rest) < 4:
            kw.setdefault("newline", "")

    def open_keeping_newlines(file, mode="r", *rest, **kw):
        _keep(mode, rest, kw)
        return real_open(file, mode, *rest, **kw)

    def path_open_keeping_newlines(self, mode="r", *rest, **kw):
        _keep(mode, rest, kw)
        return real_path_open(self, mode, *rest, **kw)

    def write_text_keeping_newlines(self, data, encoding=None, errors=None, newline=""):
        return real_write_text(self, data, encoding=encoding, errors=errors, newline=newline)

    builtins.open = open_keeping_newlines
    pathlib.Path.open = path_open_keeping_newlines
    pathlib.Path.write_text = write_text_keeping_newlines
    _patch_mutators()
    from slither.tools.mutator.__main__ import main as slither_mutate_main

    sys.argv = ["slither-mutate", *args]
    try:
        slither_mutate_main()
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 1
    return 0


def _patch_mutators() -> None:
    """Works around two slither-mutate 0.11.6 bugs that silently drop a whole operator.

    ROR splits the statement's text on the operator's symbol, which a Yul comparison (`lt`,
    `gt`, `eq`) does not contain: the IndexError aborts ROR for the entire contract, so no
    relational mutant of any Solidity comparison in a file with assembly is made. The patched
    ROR skips such comparisons only. LIR asks a `bool` for its minimum and maximum, which it
    has none of, and aborts the same way; `bool` gets `false` and `true`.
    """
    from slither.core.solidity_types import elementary_type
    from slither.slithir.operations import Binary
    from slither.tools.mutator.mutators import ROR
    from slither.tools.mutator.utils.patch import create_patch_with_line

    elementary_type.MinValues.setdefault("bool", "false")
    elementary_type.MaxValues.setdefault("bool", "true")
    BinaryType = ROR.BinaryType
    # Per comparison, the boundary shift and the equality flip, which subsume the other
    # replacements (Kaminski, Ammann and Offutt, 2011); `if` conditions forced to true or false
    # come from MIA. Used where all five replacements would take too long (SUFFICIENT_ROR_ENV).
    sufficient = {
        BinaryType.LESS: (BinaryType.LESS_EQUAL, BinaryType.NOT_EQUAL),
        BinaryType.GREATER: (BinaryType.GREATER_EQUAL, BinaryType.NOT_EQUAL),
        BinaryType.LESS_EQUAL: (BinaryType.LESS, BinaryType.EQUAL),
        BinaryType.GREATER_EQUAL: (BinaryType.GREATER, BinaryType.EQUAL),
        BinaryType.EQUAL: (BinaryType.LESS_EQUAL, BinaryType.GREATER_EQUAL),
        BinaryType.NOT_EQUAL: (BinaryType.LESS, BinaryType.GREATER),
    }
    use_sufficient = os.environ.get(SUFFICIENT_ROR_ENV) == "1"

    def ror_mutate(self) -> dict:
        result: dict = {}
        source = self.slither.source_code[self.in_file].encode("utf8")
        for function in self.contract.functions_and_modifiers_declared:
            if not self.should_mutate_function(function):
                continue
            for node in function.nodes:
                if not self.should_mutate_node(node):
                    continue
                for ir in node.irs:
                    if not (isinstance(ir, Binary) and ir.type in ROR.relational_operators):
                        continue
                    # Address comparisons are skipped, as the stock operator intends; it compares
                    # the right operand's name, not its type, with "address".
                    if "address" in (str(ir.variable_left.type), str(ir.variable_right.type)):
                        continue
                    left = getattr(ir.expression, "expression_left", None)
                    right = getattr(ir.expression, "expression_right", None)
                    if left is None or right is None:
                        continue
                    # Replace the operator between the two operands, and nothing else (the
                    # stock operator rewrote the whole statement's text into the comparison's
                    # place). A Yul comparison (`lt`, `gt`, `eq`) has no symbol there: skipped.
                    start = left.source_mapping.start + left.source_mapping.length
                    stop = right.source_mapping.start
                    if not 0 <= start < stop <= len(source):
                        continue
                    old_str = source[start:stop].decode("utf8")
                    if old_str.count(ir.type.value) != 1 or (
                        ir.type.value in ("<", ">") and old_str.count(ir.type.value + "=") != 0
                    ):
                        continue
                    replacements = (
                        sufficient[ir.type]
                        if use_sufficient
                        else [op for op in ROR.relational_operators if op != ir.type]
                    )
                    for op in replacements:
                        new_str = old_str.replace(ir.type.value, op.value)
                        create_patch_with_line(
                            result, self.in_file, start, stop, old_str, new_str,
                            node.source_mapping.lines[0],
                        )
        return result

    ROR.ROR._mutate = ror_mutate


def _python() -> str:
    return sys.executable or "python"


def _quote(arg: str) -> str:
    return subprocess.list2cmdline([arg]) if os.name == "nt" else shlex.quote(arg)


def _self(*args: str) -> list[str]:
    return [_python(), str(Path(__file__).resolve()), *args]


def test_command(tests: str) -> str:
    return " ".join(_quote(a) for a in _self("forge-test", "--match-path", tests))


def _lite_env() -> dict[str, str]:
    return dict(os.environ, FOUNDRY_PROFILE="lite")


def forge_test(args: list[str]) -> int:
    return subprocess.run(["forge", "test", "--fail-fast", *args], env=_lite_env()).returncode


def _run_logged(
    cmd: list[str], log: Path, timeout: float | None = None, env: dict | None = None
) -> int:
    if env is None:
        # The default profile for slither-mutate's own `forge clean` and compile check; the
        # test command picks the lite profile itself.
        env = {k: v for k, v in os.environ.items() if k != "FOUNDRY_PROFILE"}
    with log.open("w", encoding="utf-8") as fh:
        try:
            return subprocess.run(
                cmd, stdout=fh, stderr=subprocess.STDOUT, timeout=timeout, env=env
            ).returncode
        except subprocess.TimeoutExpired:
            fh.write("\n[tools/mutation.py] timed out\n")
            return -1


def run_slither_mutate(shard: Shard, out: Path, timeout: int, result: FileResult) -> None:
    stem = Path(shard.path).stem
    campaign = out / "campaign"
    cmd = _self(
        "slither-mutate",
        shard.path,
        "--test-cmd",
        test_command(shard.tests),
        "--output-dir",
        str(campaign),
        "--skip-clean",
        # Generous: a timeout counts as a kill, and an incremental build under load can take
        # several times the first timed run. Looping mutants end at the block gas limit.
        "--timeout",
        str(timeout),
    )
    if shard.mutators:
        cmd += ["--mutators-to-run", shard.mutators]
    log = out / "slither-mutate.log"
    env = {k: v for k, v in os.environ.items() if k != "FOUNDRY_PROFILE"}
    env[SUFFICIENT_ROR_ENV] = "1" if shard.path in SPLIT_FILES else "0"
    code = _run_logged(cmd, log, env=env)
    text = log.read_text(encoding="utf-8", errors="replace")
    if code != 0 and "Done mutating" not in text:
        result.status = "error"
        return
    parse_log(text, result)
    for s in result.survivors:
        if s.rule == "CONST":
            continue
        rule, index = s.mutant_file.rsplit("_", 1)
        s.mutant_file = (campaign / stem / f"{stem}_{rule}_{index}.sol").as_posix()


# --------------------------------------------------------------------------------- CONST


def constant_mutants(text: str) -> list[tuple[int, str, str, str]]:
    """(line, old, new, mutated text) for each integer constant moved one up and one down."""
    out = []
    for m in CONSTANT.finditer(text):
        if not re.search(r"\bconstant\b", m.group("head")):
            continue  # a state variable's initial value, which slither-mutate already covers
        raw = m.group("value")
        value = int(raw.replace("_", ""), 16 if raw.lower().startswith("0x") else 10)
        line = text.count("\n", 0, m.start()) + 1
        for new_value in (value + 1, value - 1):
            if new_value < 0:
                continue
            new_raw = hex(new_value) if raw.lower().startswith("0x") else str(new_value)
            mutated = text[: m.start("value")] + new_raw + text[m.end("value") :]
            new_line = f"{m.group('head')}{new_raw}{m.group('tail')}".strip()
            out.append((line, m.group(0).strip(), new_line, mutated))
    return out


def run_constants(root: Path, shard: Shard, out: Path, timeout: int, result: FileResult) -> None:
    source = root / shard.path
    original = source.read_bytes()
    text = original.decode("utf-8")
    campaign = out / "campaign" / "const"
    try:
        for i, (line, old, new, mutated) in enumerate(constant_mutants(text)):
            source.write_bytes(mutated.encode("utf-8"))
            build = _run_logged(
                ["forge", "build", shard.path], out / f"const-{i}.build.log", timeout, _lite_env()
            )
            if build != 0:
                continue  # does not compile (the value no longer fits its type)
            result.total["constant"] += 1
            code = _run_logged(
                ["forge", "test", "--fail-fast", "--match-path", shard.tests],
                out / f"const-{i}.log",
                timeout,
                _lite_env(),
            )
            if code != 0:
                result.caught["constant"] += 1
                result.timeouts += code == -1
                continue
            campaign.mkdir(parents=True, exist_ok=True)
            mutant = campaign / f"{Path(shard.path).stem}_CONST_{i}.sol"
            mutant.write_bytes(mutated.encode("utf-8"))
            result.survivors.append(Survivor("CONST", line, old, new, mutant.as_posix()))
    finally:
        source.write_bytes(original)


# -------------------------------------------------------------------------------- re-check


def recheck(root: Path, result: FileResult, out: Path, timeout: float) -> None:
    """Runs each survivor against the whole suite; restores the source afterwards."""
    source = root / result.path
    original = source.read_bytes()
    try:
        for i, s in enumerate(result.survivors):
            mutant = Path(s.mutant_file)
            if not mutant.is_file():
                s.recheck = "not-rechecked"
                continue
            shutil.copyfile(mutant, source)
            code = _run_logged(
                _self("forge-test", "--match-path", RECHECK_TESTS),
                out / f"recheck-{i}.log",
                timeout,
            )
            s.recheck = "survived" if code == 0 else "timeout" if code == -1 else "killed"
    finally:
        source.write_bytes(original)


def run_shard(root: Path, shard: Shard, out: Path, do_recheck: bool, timeout: int,
              recheck_timeout: float) -> dict:
    shard_out = out / shard.name
    shard_out.mkdir(parents=True, exist_ok=True)
    result = FileResult(shard.path)
    started = dt.datetime.now(dt.timezone.utc)
    clock = time.monotonic()
    print(f"[{shard.name}] mutating {shard.path}", flush=True)
    run_slither_mutate(shard, shard_out, timeout, result)
    if shard.constants and result.status == "ok":
        print(f"[{shard.name}] moving the constants of {shard.path}", flush=True)
        run_constants(root, shard, shard_out, timeout, result)
    if do_recheck and result.survivors and result.status == "ok":
        print(f"[{shard.name}] re-checking {len(result.survivors)} survivors", flush=True)
        recheck(root, result, shard_out, recheck_timeout)
    result.seconds = round(time.monotonic() - clock, 1)
    print(
        f"[{shard.name}] {shard.path}: {result.status}, {result.killed}/{result.mutants} killed "
        f"in {result.seconds}s",
        flush=True,
    )
    data = {
        "shard": shard.name,
        "tests": shard.tests,
        "mutators": shard.mutators or "all",
        "constants": shard.constants,
        "recheck_tests": RECHECK_TESTS if do_recheck else None,
        "started": started.isoformat(timespec="seconds"),
        "finished": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "commit": os.environ.get("MUTATION_COMMIT") or _git(["rev-parse", "HEAD"]),
        "files": [asdict(result)],
    }
    (shard_out / "results.json").write_text(
        json.dumps(data, indent=2) + "\n", encoding="utf-8", newline="\n"
    )
    return data


def _git(args: list[str]) -> str:
    try:
        return subprocess.run(
            ["git", *args], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


# ---------------------------------------------------------------------------------- report


def load_results(paths: list[Path]) -> list[FileResult]:
    """Every result, with the groups of a split file merged into one."""
    merged: dict[str, FileResult] = {}
    for base in paths:
        files = [base] if base.is_file() else sorted(base.glob("**/results.json"))
        if not files:
            raise MutationError(f"{base}: no results.json")
        for f in files:
            data = json.loads(f.read_text(encoding="utf-8"))
            for entry in data["files"]:
                survivors = [Survivor(**s) for s in entry.pop("survivors")]
                r = FileResult(**entry, survivors=survivors)
                for c in CATEGORIES:
                    r.caught.setdefault(c, 0)
                    r.total.setdefault(c, 0)
                if r.path not in merged:
                    merged[r.path] = r
                    continue
                m = merged[r.path]
                for c in CATEGORIES:
                    m.caught[c] += r.caught[c]
                    m.total[c] += r.total[c]
                m.survivors.extend(r.survivors)
                m.timeouts += r.timeouts
                m.seconds += r.seconds
                if r.status != "ok":
                    m.status = r.status
    return sorted(merged.values(), key=lambda r: r.path)


def kill_rate(r: FileResult) -> float | None:
    return None if r.mutants == 0 else 100.0 * r.killed / r.mutants


def markdown(results: list[FileResult]) -> str:
    lines = [
        "| Contract | Mutants | Killed | Survived | Kill rate | Revert | Comment | Tweak | "
        "Constant |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    total = killed = 0
    for r in results:
        rate = kill_rate(r)
        cats = " | ".join(f"{r.caught[c]}/{r.total[c]}" for c in CATEGORIES)
        status = "" if r.status == "ok" else f" ({r.status})"
        lines.append(
            f"| `{r.path}`{status} | {r.mutants} | {r.killed} | {r.mutants - r.killed} | "
            f"{'n/a' if rate is None else f'{rate:.1f}%'} | {cats} |"
        )
        total += r.mutants
        killed += r.killed
    rate = "n/a" if total == 0 else f"{100.0 * killed / total:.1f}%"
    lines.append(f"| **Total** | {total} | {killed} | {total - killed} | {rate} | | | | |")
    lines.append("")
    lines.append(
        "The category columns count what the module's own tests killed, out of the mutants that"
    )
    lines.append("compile; the kill rate also counts survivors the whole suite killed on re-check.")
    lines.append("")
    lines.append("### Survivors")
    lines.append("")
    for r in results:
        alive = [s for s in r.survivors if s.recheck not in ("killed", "timeout")]
        if not alive:
            continue
        lines.append(f"#### `{r.path}`")
        lines.append("")
        lines.append("| Rule | Line | Mutation | Re-check |")
        lines.append("| --- | ---: | --- | --- |")
        for s in sorted(alive, key=lambda s: (s.line, s.rule)):
            old = " ".join(s.old.split())
            new = " ".join(s.new.split())
            if len(old) > 80:
                old = old[:77] + "..."
            if len(new) > 80:
                new = new[:77] + "..."
            mutation = f"`{old}` to `{new}`".replace("|", "\\|")
            lines.append(f"| {s.rule} | {s.line} | {mutation} | {s.recheck} |")
        lines.append("")
    return "\n".join(lines) + "\n"


def write_floors(results: list[FileResult], path: Path, margin: float) -> None:
    """Each contract's kill rate minus `margin` points, rounded down to a whole point."""
    floors = {
        r.path: max(0, int(rate - margin))
        for r in results
        if r.status == "ok" and (rate := kill_rate(r)) is not None
    }
    data = {"margin": margin, "files": dict(sorted(floors.items()))}
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8", newline="\n")


def check_floors(results: list[FileResult], floors_path: Path) -> list[str]:
    floors = json.loads(floors_path.read_text(encoding="utf-8"))
    failures = []
    by_path = {r.path: r for r in results}
    for path, floor in floors.get("files", {}).items():
        r = by_path.get(path)
        if r is None:
            continue  # a run on demand may cover only some shards
        rate = kill_rate(r)
        if r.status != "ok":
            failures.append(f"{path}: campaign {r.status}")
        elif rate is not None and rate + 1e-9 < floor:
            failures.append(f"{path}: kill rate {rate:.1f}% is below its floor {floor}%")
    return failures


# ------------------------------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    # Passed through untouched: argparse would read forge's own options as ours.
    if argv[:1] == ["forge-test"]:
        return forge_test(argv[1:])
    if argv[:1] == ["slither-mutate"]:
        return slither_mutate(argv[1:])
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    listing = sub.add_parser("list")
    listing.add_argument("--json", action="store_true", help="the shard names as a JSON list")
    run = sub.add_parser("run")
    run.add_argument("shards", nargs="+")
    run.add_argument("--out", default="mutation", type=Path)
    run.add_argument("--no-recheck", action="store_true")
    run.add_argument("--timeout", type=int, default=1200, help="seconds per mutant")
    run.add_argument("--recheck-timeout", type=float, default=1800.0, help="seconds")
    run.add_argument(
        "--mutators",
        help="run only these slither-mutate operators (comma-separated), without CONST; the "
        "results go to SHARD-MUTATORS, which the report merges with the shard's own",
    )
    report = sub.add_parser("report")
    report.add_argument("results", nargs="+", type=Path)
    report.add_argument("--markdown", type=Path)
    report.add_argument("--json", type=Path)
    report.add_argument("--floors", type=Path, help="fail below the kill-rate floors in FILE")
    report.add_argument("--write-floors", type=Path, help="write floors from these results")
    report.add_argument("--margin", type=float, default=2.0, help="points below each rate")
    sub.add_parser("forge-test", help="forge test --fail-fast ARGS under the lite profile")
    sub.add_parser("slither-mutate", help="slither-mutate ARGS, writing files byte for byte")
    args = parser.parse_args(argv)

    root = Path.cwd()
    try:
        if args.command == "list":
            all_shards = shards(root)
            if args.json:
                print(json.dumps(list(all_shards)))
                return 0
            for s in all_shards.values():
                groups = s.mutators or "all mutators"
                const = ", CONST" if s.constants else ""
                print(f"{s.name}: {s.path} ({groups}{const}) against {s.tests}")
            return 0
        if args.command == "run":
            try:
                import slither.tools.mutator  # noqa: F401
            except ImportError as exc:
                raise MutationError(
                    "slither-analyzer is not installed (requirements-tools.lock)"
                ) from exc
            all_shards = shards(root)
            unknown = [s for s in args.shards if s not in all_shards]
            if unknown:
                raise MutationError(f"unknown shards {unknown}; see `tools/mutation.py list`")
            for name in args.shards:
                shard = all_shards[name]
                if args.mutators:
                    suffix = args.mutators.replace(",", "-")
                    shard = Shard(f"{name}-{suffix}", shard.path, shard.tests, args.mutators, False)
                run_shard(root, shard, args.out, not args.no_recheck, args.timeout,
                          args.recheck_timeout)
            return 0
        results = load_results(args.results)
        text = markdown(results)
        print(text)
        if args.markdown:
            args.markdown.write_text(text, encoding="utf-8", newline="\n")
        if args.json:
            summary = {
                r.path: {"mutants": r.mutants, "killed": r.killed, "kill_rate": kill_rate(r),
                         "timeouts": r.timeouts, "status": r.status}
                for r in results
            }
            args.json.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8",
                                 newline="\n")
        summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_file:
            with open(summary_file, "a", encoding="utf-8") as fh:
                fh.write("## Mutation testing\n\n" + text)
        if args.write_floors:
            write_floors(results, args.write_floors, args.margin)
        if args.floors:
            failures = check_floors(results, args.floors)
            if failures:
                print("Mutation kill-rate regressions:", file=sys.stderr)
                for f in failures:
                    print(f"  {f}", file=sys.stderr)
                return 1
        return 0
    except MutationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
