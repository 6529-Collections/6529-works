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
                           write OUT/SHARD/results.json and the logs; --budget MINUTES stops
                           a shard that runs longer, with status `timeout`
  report OUT [...]         merge results.json files into a Markdown report (--markdown) and a
                           JSON summary (--json); --shards names the shards the run planned
                           and fails when one left no results; --floors FILE fails when a
                           contract did not finish, has no floor, or falls below its floor
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
import contextlib
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
# other file runs all fifteen. A file belongs here when its whole shard does not finish in a
# CI job: the run's report then lists it as `timeout` (see `--budget`).
SPLIT_FILES = {
    "src/content/ContentStore.sol",
    "src/content/JsonScan.sol",
    "src/content/Renderer.sol",
    "src/curation/PackageRegistry.sol",
    "src/governance/GovernanceConfig.sol",
    "src/identity/ArtistRegistry.sol",
    "src/sales/EnglishAuction.sol",
    "src/sales/EnglishAuctionLens.sol",
    "src/sales/UniformClearing.sol",
    "src/sales/UniformEditionAuction.sol",
    "src/sales/UniformEditionAuctionLens.sol",
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
    # ok; aborted (the unmutated suite failed); error (slither-mutate failed); timeout (the
    # shard ran out of its --budget before every mutant had run against its module's tests);
    # missing (a planned shard left no results, see `missing`).
    status: str = "ok"
    caught: dict[str, int] = field(default_factory=lambda: {c: 0 for c in CATEGORIES})
    total: dict[str, int] = field(default_factory=lambda: {c: 0 for c in CATEGORIES})
    survivors: list[Survivor] = field(default_factory=list)
    # Mutants counted as killed because the test command timed out (slither-mutate's rule).
    timeouts: int = 0
    seconds: float = 0.0
    # The shards whose results were merged into this file, and (in a report) the planned
    # shards of this file that left none.
    shards: list[str] = field(default_factory=list)
    missing: list[str] = field(default_factory=list)

    @property
    def mutants(self) -> int:
        return sum(self.total.values())

    @property
    def unrechecked(self) -> int:
        """Survivors left out of the re-check (the budget ran out): the rate is a lower bound."""
        return sum(1 for s in self.survivors if s.recheck == "not-rechecked")

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
                    skip = unsigned_zero_equivalent(ir.type.value, _zero_side(ir))
                    for op in replacements:
                        if op.value == skip:
                            continue
                        new_str = old_str.replace(ir.type.value, op.value)
                        create_patch_with_line(
                            result, self.in_file, start, stop, old_str, new_str,
                            node.source_mapping.lines[0],
                        )
        return result

    def _zero_side(ir) -> str | None:
        """'right' for `x OP 0` with `x` unsigned, 'left' for `0 OP x`, otherwise None."""
        from slither.slithir.variables import Constant

        def zero(v) -> bool:
            return isinstance(v, Constant) and v.value == 0

        def unsigned(v) -> bool:
            return str(v.type).startswith("uint")

        if zero(ir.variable_right) and unsigned(ir.variable_left):
            return "right"
        if zero(ir.variable_left) and unsigned(ir.variable_right):
            return "left"
        return None

    ROR.ROR._mutate = ror_mutate


# For an unsigned `x`, the replacement of a comparison with the literal 0 that cannot change
# its result: `x == 0` read as `x <= 0`, `x != 0` as `x > 0`, `x > 0` as `x != 0`, `x <= 0` as
# `x == 0`, and the mirrors with the zero on the left. Each one survives, and each survivor
# costs a re-check against the whole suite (minutes), so ROR does not make them.
_UNSIGNED_ZERO_EQUIVALENTS = {
    "right": {"==": "<=", "!=": ">", ">": "!=", "<=": "=="},
    "left": {"==": ">=", "!=": "<", "<": "!=", ">=": "=="},
}


def unsigned_zero_equivalent(operator: str, zero_side: str | None) -> str | None:
    """The replacement of `operator` that is equivalent when one operand is unsigned and the
    other the literal 0, on `zero_side` ('right' or 'left'); None otherwise."""
    return _UNSIGNED_ZERO_EQUIVALENTS.get(zero_side or "", {}).get(operator)


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


class Deadline:
    """The end of a shard's time budget (`run --budget`); no end when the budget is None.

    A CI job that reaches its own time limit is cancelled before the shard writes anything, so
    the report could only say that the shard left no results. A shard that stops at its budget
    still writes results.json, with status `timeout`, and the report names it.
    """

    def __init__(self, seconds: float | None) -> None:
        self.end = None if seconds is None else time.monotonic() + seconds

    def cap(self, timeout: float | None) -> float | None:
        """`timeout`, shortened to the time the budget has left."""
        if self.end is None:
            return timeout
        left = max(0.0, self.end - time.monotonic())
        return left if timeout is None else min(timeout, left)

    @property
    def passed(self) -> bool:
        return self.end is not None and time.monotonic() >= self.end


def _kill_tree(proc: subprocess.Popen) -> None:
    """Kills a command and everything it started (slither-mutate runs forge, forge runs solc)."""
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/F", "/T", "/PID", str(proc.pid)], capture_output=True, check=False
        )
    else:
        import signal

        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, signal.SIGKILL)
    proc.wait()


def _run_logged(
    cmd: list[str], log: Path, timeout: float | None = None, env: dict | None = None
) -> int:
    """Runs `cmd` with its output in `log`; -1 when it ran out of `timeout` seconds."""
    if env is None:
        # The default profile for slither-mutate's own `forge clean` and compile check; the
        # test command picks the lite profile itself.
        env = {k: v for k, v in os.environ.items() if k != "FOUNDRY_PROFILE"}
    with log.open("w", encoding="utf-8") as fh:
        # Its own process group, so that a timeout stops the commands it started too.
        group = {} if os.name == "nt" else {"start_new_session": True}
        proc = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT, env=env, **group)
        try:
            return proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_tree(proc)
            fh.write("\n[tools/mutation.py] timed out\n")
            return -1
        except BaseException:
            _kill_tree(proc)  # Ctrl+C does not reach a separate process group
            raise


def run_slither_mutate(
    root: Path, shard: Shard, out: Path, timeout: int, result: FileResult, deadline: Deadline
) -> None:
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
    source = root / shard.path
    original = source.read_bytes()
    try:
        code = _run_logged(cmd, log, timeout=deadline.cap(None), env=env)
    finally:
        # slither-mutate restores the file only when it finishes; this covers a stop at the
        # budget, a crash and Ctrl+C. Its process tree has exited by now, so nothing races.
        source.write_bytes(original)
    if code == -1 and deadline.passed:
        result.status = "timeout"
        return
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


def run_constants(
    root: Path, shard: Shard, out: Path, timeout: int, result: FileResult, deadline: Deadline
) -> None:
    source = root / shard.path
    original = source.read_bytes()
    text = original.decode("utf-8")
    campaign = out / "campaign" / "const"
    try:
        for i, (line, old, new, mutated) in enumerate(constant_mutants(text)):
            if deadline.passed:
                result.status = "timeout"
                return
            source.write_bytes(mutated.encode("utf-8"))
            build = _run_logged(
                ["forge", "build", shard.path],
                out / f"const-{i}.build.log",
                deadline.cap(timeout),
                _lite_env(),
            )
            if build == -1 and deadline.passed:
                result.status = "timeout"
                return
            if build != 0:
                continue  # does not compile (the value no longer fits its type)
            code = _run_logged(
                ["forge", "test", "--fail-fast", "--match-path", shard.tests],
                out / f"const-{i}.log",
                deadline.cap(timeout),
                _lite_env(),
            )
            if code == -1 and deadline.passed:
                result.status = "timeout"  # the budget ran out, not the mutant's own time
                return
            result.total["constant"] += 1
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


def recheck(
    root: Path, result: FileResult, out: Path, timeout: float, deadline: Deadline
) -> None:
    """Runs each survivor against the whole suite; restores the source afterwards.

    Every mutant has run against its module's tests by then, so a spent budget leaves nothing
    unmeasured: the survivors not re-checked stay `not-rechecked` and count as survived, which
    makes the kill rate a lower bound (the report says how many).
    """
    source = root / result.path
    original = source.read_bytes()
    try:
        for i, s in enumerate(result.survivors):
            if deadline.passed:
                return
            mutant = Path(s.mutant_file)
            if not mutant.is_file():
                s.recheck = "not-rechecked"
                continue
            shutil.copyfile(mutant, source)
            code = _run_logged(
                _self("forge-test", "--match-path", RECHECK_TESTS),
                out / f"recheck-{i}.log",
                deadline.cap(timeout),
            )
            if code == -1 and deadline.passed:
                return  # the budget ran out, not the mutant's own time: left not re-checked
            s.recheck = "survived" if code == 0 else "timeout" if code == -1 else "killed"
    finally:
        source.write_bytes(original)


def run_shard(root: Path, shard: Shard, out: Path, do_recheck: bool, timeout: int,
              recheck_timeout: float, budget: float | None = None) -> dict:
    """Runs one shard; `budget` (seconds) ends it early, with status `timeout`."""
    shard_out = out / shard.name
    shard_out.mkdir(parents=True, exist_ok=True)
    result = FileResult(shard.path, shards=[shard.name])
    deadline = Deadline(budget)
    started = dt.datetime.now(dt.timezone.utc)
    clock = time.monotonic()
    print(f"[{shard.name}] mutating {shard.path}", flush=True)
    run_slither_mutate(root, shard, shard_out, timeout, result, deadline)
    if shard.constants and result.status == "ok":
        print(f"[{shard.name}] moving the constants of {shard.path}", flush=True)
        run_constants(root, shard, shard_out, timeout, result, deadline)
    if do_recheck and result.survivors and result.status == "ok":
        print(f"[{shard.name}] re-checking {len(result.survivors)} survivors", flush=True)
        recheck(root, result, shard_out, recheck_timeout, deadline)
    result.seconds = round(time.monotonic() - clock, 1)
    print(
        f"[{shard.name}] {shard.path}: {result.status}, {result.killed}/{result.mutants} killed "
        f"in {result.seconds}s",
        flush=True,
    )
    if result.status == "timeout":
        hint = "" if shard.path in SPLIT_FILES else " (split it: SPLIT_FILES in tools/mutation.py)"
        print(
            f"[{shard.name}] stopped at its {budget / 60:.0f}-minute budget; the report lists "
            f"{shard.path} as `timeout`{hint}",
            file=sys.stderr,
            flush=True,
        )
    elif result.unrechecked:
        print(
            f"[{shard.name}] the budget ran out while re-checking: {result.unrechecked} "
            "survivors were not re-checked and count as survived",
            file=sys.stderr,
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


def load_results(paths: list[Path], allow_empty: bool = False) -> list[FileResult]:
    """Every result, with the groups of a split file merged into one.

    `allow_empty` accepts a path without any results.json (a run whose shards all failed: the
    plan then lists each as missing).
    """
    merged: dict[str, FileResult] = {}
    for base in paths:
        files = [base] if base.is_file() else sorted(base.glob("**/results.json"))
        if not files and not allow_empty:
            raise MutationError(f"{base}: no results.json")
        for f in files:
            data = json.loads(f.read_text(encoding="utf-8"))
            for entry in data["files"]:
                survivors = [Survivor(**s) for s in entry.pop("survivors")]
                r = FileResult(**entry, survivors=survivors)
                if not r.shards and data.get("shard"):
                    r.shards = [data["shard"]]  # results written before the field existed
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
                m.shards.extend(r.shards)
                if r.status != "ok":
                    m.status = r.status
    return sorted(merged.values(), key=lambda r: r.path)


def planned_shards(root: Path, spec: str) -> dict[str, Shard]:
    """The shards a run planned, from a JSON list or space-separated names."""
    names = json.loads(spec) if spec.lstrip().startswith("[") else spec.split()
    known = shards(root)
    unknown = [n for n in names if n not in known]
    if unknown:
        raise MutationError(f"unknown shards {unknown}; see `tools/mutation.py list`")
    return {n: known[n] for n in names}


def apply_plan(results: list[FileResult], planned: dict[str, Shard]) -> list[FileResult]:
    """Every planned file gets a row; a planned shard that left no results marks its file
    `missing` (a partly reported split file too, whose counts would otherwise look whole)."""
    by_path = {r.path: r for r in results}
    reported = {name for r in results for name in r.shards}
    for name, shard in planned.items():
        if name in reported:
            continue
        r = by_path.setdefault(shard.path, FileResult(shard.path))
        r.missing.append(name)
        r.status = "missing"
    return sorted(by_path.values(), key=lambda r: r.path)


def _status(r: FileResult) -> str:
    if r.missing:
        return f"missing: no results from {', '.join(r.missing)}"
    return r.status


def kill_rate(r: FileResult) -> float | None:
    return None if r.mutants == 0 else 100.0 * r.killed / r.mutants


def markdown(results: list[FileResult]) -> str:
    lines = []
    unfinished = [r for r in results if r.status != "ok"]
    if unfinished:
        lines.append(f"**{len(unfinished)} contract(s) without a complete result:**")
        lines.append("")
        lines.extend(f"- `{r.path}`: {_status(r)}" for r in unfinished)
        lines.append("")
    partial = [r for r in results if r.status == "ok" and r.unrechecked]
    if partial:
        lines.append(
            "**Lower bounds:** the budget ran out while these re-checked survivors against the "
            "whole suite; a survivor not re-checked counts as survived."
        )
        lines.append("")
        lines.extend(f"- `{r.path}`: {r.unrechecked} not re-checked" for r in partial)
        lines.append("")
    lines += [
        "| Contract | Mutants | Killed | Survived | Kill rate | Revert | Comment | Tweak | "
        "Constant |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    total = killed = 0
    for r in results:
        rate = kill_rate(r)
        cats = " | ".join(f"{r.caught[c]}/{r.total[c]}" for c in CATEGORIES)
        status = "" if r.status == "ok" else f" ({'missing' if r.missing else r.status})"
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
    """Each measured contract's kill rate minus `margin` points, rounded down to a whole point.

    Floors of contracts these results do not measure (a run of some shards only) are kept.
    """
    floors: dict[str, float] = {}
    if path.is_file():
        floors.update(load_floors(path))
    floors.update(
        (r.path, max(0, int(rate - margin)))
        for r in results
        if r.status == "ok" and (rate := kill_rate(r)) is not None
    )
    data = {"margin": margin, "files": dict(sorted(floors.items()))}
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8", newline="\n")


def load_floors(path: Path) -> dict[str, float]:
    """The `files` map of a floors file; a missing or malformed file fails closed."""
    try:
        floors = json.loads(path.read_text(encoding="utf-8"))["files"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise MutationError(f"{path.as_posix()}: no usable floors ({exc!r})") from exc
    if not isinstance(floors, dict) or not all(
        isinstance(v, (int, float)) and not isinstance(v, bool) for v in floors.values()
    ):
        raise MutationError(f"{path.as_posix()}: `files` must map each contract to a number")
    return floors


def check_floors(results: list[FileResult], floors_path: Path) -> list[str]:
    """Each reported contract must have finished, and must kill at least its floor.

    A contract with something to mutate and no floor fails too, so that a new src/ file gets
    one recorded (`report --write-floors`). Floors of contracts the run did not plan are not
    checked: a run on demand may cover only some shards.
    """
    floors = load_floors(floors_path)
    failures = []
    for r in results:
        rate = kill_rate(r)
        floor = floors.get(r.path)
        if r.status != "ok":
            failures.append(f"{r.path}: {_status(r)}")
        elif rate is None:
            continue  # nothing to mutate
        elif floor is None:
            failures.append(
                f"{r.path}: kill rate {rate:.1f}% and no floor in {floors_path.as_posix()}; "
                "record one (report --write-floors)"
            )
        elif rate + 1e-9 < floor:
            failures.append(f"{r.path}: kill rate {rate:.1f}% is below its floor {floor}%")
    return failures


def _github_errors(title: str, lines: list[str]) -> None:
    """Annotations on the workflow run's page, so a failure shows without opening a log."""
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for line in lines:
            message = line.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error title={title}::{message}", flush=True)


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
        "--budget",
        type=float,
        help="minutes per shard: a shard still running then stops and reports `timeout` "
        "(CI sets it below the job's time limit, which would leave no results at all)",
    )
    run.add_argument(
        "--mutators",
        help="run only these slither-mutate operators (comma-separated), without CONST; the "
        "results go to SHARD-MUTATORS, which the report merges with the shard's own",
    )
    report = sub.add_parser("report")
    report.add_argument("results", nargs="+", type=Path)
    report.add_argument("--markdown", type=Path)
    report.add_argument("--json", type=Path)
    report.add_argument(
        "--shards",
        help="the shards the run planned (a JSON list or space-separated names): every planned "
        "file gets a row, and a planned shard without results fails the report by name",
    )
    report.add_argument(
        "--floors",
        type=Path,
        help="fail when a contract is below its kill-rate floor in FILE, has none, or did not "
        "finish",
    )
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
            budget = None if args.budget is None else args.budget * 60
            for name in args.shards:
                shard = all_shards[name]
                if args.mutators:
                    suffix = args.mutators.replace(",", "-")
                    shard = Shard(f"{name}-{suffix}", shard.path, shard.tests, args.mutators, False)
                run_shard(root, shard, args.out, not args.no_recheck, args.timeout,
                          args.recheck_timeout, budget)
            return 0
        results = load_results(args.results, allow_empty=args.shards is not None)
        if args.shards is not None:
            results = apply_plan(results, planned_shards(root, args.shards))
        text = markdown(results)
        print(text)
        if args.markdown:
            args.markdown.write_text(text, encoding="utf-8", newline="\n")
        if args.json:
            summary = {
                r.path: {"mutants": r.mutants, "killed": r.killed, "kill_rate": kill_rate(r),
                         "timeouts": r.timeouts, "status": r.status, "shards": r.shards,
                         "missing_shards": r.missing, "not_rechecked": r.unrechecked}
                for r in results
            }
            args.json.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8",
                                 newline="\n")
        if args.floors:
            failures = check_floors(results, args.floors)
        else:
            failures = [f"{r.path}: {_status(r)}" for r in results if r.missing]
        summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_file:
            with open(summary_file, "a", encoding="utf-8") as fh:
                fh.write("## Mutation testing\n\n")
                if failures:
                    fh.write("**The report fails:**\n\n")
                    fh.write("".join(f"- {f}\n" for f in failures) + "\n")
                fh.write(text)
        if args.write_floors:
            write_floors(results, args.write_floors, args.margin)
        if failures:
            print("Mutation report failures:", file=sys.stderr)
            for f in failures:
                print(f"  {f}", file=sys.stderr)
            _github_errors("Mutation testing", failures)
            return 1
        return 0
    except MutationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
