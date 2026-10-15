#!/usr/bin/env python3
"""Check that every externally visible declaration in src/ carries complete NatSpec.

Rules, for every Solidity file under src/ (interfaces, libraries and contracts alike):
  1. every `external` or `public` function, and every `receive` or `fallback`, has a
     `@notice` (an untagged comment counts, as it does for solc) or an `@inheritdoc`;
     without `@inheritdoc` it also has one `@param` for each named parameter and exactly
     one `@return` for each return value (named returns must be cited by name);
  2. every event has a `@notice` and one `@param` for each named parameter;
  3. every error has a `@notice`;
  4. every `public` state variable (a generated getter) has a `@notice` or an
     `@inheritdoc`.

A `@param` that names no parameter is reported too. The comment attached to a
declaration follows solc: the last `///` run or `/** */` block before it, where
consecutive `///` lines merge and ordinary comments in between are ignored.

Run from anywhere: `python tools/check_natspec.py`. Standard library only; it reads
sources, not build output. The repository root is the nearest ancestor with a
foundry.toml, or `--root`.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

IDENT = re.compile(r"[A-Za-z_$][\w$]*")
CONTAINERS = {"contract", "interface", "library"}
# Words that end a parameter's type without naming it (`address payable`, `bytes calldata`).
NOT_A_NAME = {"memory", "calldata", "storage", "indexed", "payable"}
SKIPPED_MEMBERS = {"constructor", "modifier", "struct", "enum", "using", "type", "pragma", "import"}


@dataclass
class DocComment:
    start: int
    end: int
    text: str
    triple_slash: bool


@dataclass
class Tags:
    notice: bool = False
    inheritdoc: bool = False
    params: list[str] = field(default_factory=list)
    returns: list[str] = field(default_factory=list)


@dataclass
class Declaration:
    kind: str  # function, event, error or variable
    name: str
    line: int
    params: list[str | None]  # None for an unnamed parameter
    returns: list[str | None]
    doc: Tags | None


def scan(text: str) -> tuple[str, list[DocComment]]:
    """Return the code with comments and string contents blanked, and the NatSpec comments.

    Offsets in the returned code match `text`, so a declaration's position maps back.
    """
    code = list(text)
    docs: list[DocComment] = []
    i, n = 0, len(text)

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if code[k] != "\n":
                code[k] = " "

    while i < n:
        c = text[i]
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end == -1 else end
            if text.startswith("///", i) and not text.startswith("////", i):
                docs.append(DocComment(i, end, text[i + 3 : end], True))
            blank(i, end)
            i = end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end == -1 else end + 2
            body = text[i + 3 : end - 2]
            if text.startswith("/**", i) and not text.startswith("/**/", i):
                lines = [re.sub(r"^\s*\*?", "", line) for line in body.split("\n")]
                docs.append(DocComment(i, end, "\n".join(lines), False))
            blank(i, end)
            i = end
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            blank(i + 1, min(j, n))
            i = j + 1
        else:
            i += 1
    return "".join(code), _merge(text, docs)


def _merge(text: str, docs: list[DocComment]) -> list[DocComment]:
    """Merge `///` lines separated only by whitespace into one comment, as solc does."""
    merged: list[DocComment] = []
    for doc in docs:
        last = merged[-1] if merged else None
        if (
            last is not None
            and last.triple_slash
            and doc.triple_slash
            and text[last.end : doc.start].strip() == ""
        ):
            merged[-1] = DocComment(last.start, doc.end, last.text + "\n" + doc.text, True)
        else:
            merged.append(doc)
    return merged


def parse_tags(doc: str) -> Tags:
    """Parse a NatSpec comment's tags the way solc's DocStringParser does.

    A tag starts at the first `@` of a line; other lines continue the previous tag. Text
    before any tag, at the very start of the comment, is an implicit `@notice`.
    """
    tags = Tags()
    current: str | None = None
    for index, line in enumerate(doc.split("\n")):
        at = line.find("@")
        if at != -1:
            match = re.match(r"@([\w:-]+)\s*(.*)", line[at:])
            name = match.group(1) if match else ""
            rest = match.group(2).strip() if match else ""
            current = name
            if name == "notice" and rest:
                tags.notice = True
            elif name == "inheritdoc":
                tags.inheritdoc = True
            elif name == "param":
                tags.params.append(rest.split()[0] if rest else "")
            elif name == "return":
                tags.returns.append(rest)
        elif current is not None:
            if current == "notice" and line.strip():
                tags.notice = True
        elif index == 0 and line.strip():
            current = "notice"
            tags.notice = True
    return tags


def _match(code: str, open_index: int, opener: str, closer: str) -> int:
    depth = 0
    for k in range(open_index, len(code)):
        if code[k] == opener:
            depth += 1
        elif code[k] == closer:
            depth -= 1
            if depth == 0:
                return k
    raise ValueError(f"unbalanced {opener}{closer} at offset {open_index}")


def _split_top(code: str) -> list[str]:
    parts, depth, start = [], 0, 0
    for k, c in enumerate(code):
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "," and depth == 0:
            parts.append(code[start:k])
            start = k + 1
    parts.append(code[start:])
    return [p.strip() for p in parts if p.strip()]


def _flatten(code: str) -> str:
    """Blank every parenthesized or bracketed group (mapping keys, array sizes, arguments)."""
    previous = None
    while previous != code:
        previous, code = code, re.sub(r"\([^()]*\)|\[[^\[\]]*\]", " ", code)
    return code


def parameter_names(code: str) -> list[str | None]:
    """The names in a parameter list's text, None for each unnamed parameter."""
    names: list[str | None] = []
    for part in _split_top(code):
        flat = _flatten(part)
        words = IDENT.findall(flat)
        last = words[-1] if words else ""
        named = len(words) >= 2 and last not in NOT_A_NAME and not part.rstrip().endswith("]")
        names.append(last if named else None)
    return names


def _items(code: str, start: int, end: int):
    """Yield (start, end, block_open) for each member between offsets, skipping whitespace.

    A member ends at a `;` outside brackets, or with the `}` that closes its first
    top-level `{` (a body). `block_open` is that `{`'s offset, or -1.
    """
    i = start
    while i < end:
        while i < end and code[i].isspace():
            i += 1
        if i >= end:
            return
        depth, k = 0, i
        while k < end:
            c = code[k]
            if c in "([":
                depth += 1
            elif c in ")]":
                depth -= 1
            elif c == ";" and depth == 0:
                yield i, k + 1, -1
                break
            elif c == "{" and depth == 0:
                close = _match(code, k, "{", "}")
                yield i, close + 1, k
                k = close
                break
            k += 1
        else:
            return
        i = k + 1


def _doc_for(docs: list[DocComment], gap_start: int, item_start: int) -> Tags | None:
    attached = [d for d in docs if gap_start <= d.start and d.end <= item_start]
    return parse_tags(attached[-1].text) if attached else None


def _header(code: str, item_start: int, item_end: int, block_open: int) -> str:
    return code[item_start : block_open if block_open != -1 else item_end]


def _function(header: str, offset: int, line_of, doc: Tags | None) -> Declaration | None:
    head = re.match(r"\s*(function\s+([A-Za-z_$][\w$]*)|receive|fallback)\s*\(", header)
    if head is None:
        return None
    name = head.group(2) or head.group(1)
    open_paren = header.index("(", head.start(1))
    close_paren = _match(header, open_paren, "(", ")")
    params = parameter_names(header[open_paren + 1 : close_paren])
    tail = header[close_paren + 1 :]
    words = set(IDENT.findall(_flatten(tail)))
    if name not in ("receive", "fallback") and not words & {"external", "public"}:
        return None
    returns: list[str | None] = []
    found = re.search(r"\breturns\s*\(", tail)
    if found:
        r_open = tail.index("(", found.start())
        returns = parameter_names(tail[r_open + 1 : _match(tail, r_open, "(", ")")])
    return Declaration("function", name, line_of(offset), params, returns, doc)


def declarations(text: str) -> list[Declaration]:
    """Every function, event, error and state variable declared in a source file."""
    code, docs = scan(text)
    starts = [0]
    for k, c in enumerate(text):
        if c == "\n":
            starts.append(k + 1)

    def line_of(offset: int) -> int:
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    found: list[Declaration] = []

    def walk(start: int, end: int, in_container: bool) -> None:
        gap = start
        for item_start, item_end, block_open in _items(code, start, end):
            header = _header(code, item_start, item_end, block_open)
            words = IDENT.findall(header)
            first = words[0] if words else ""
            doc = _doc_for(docs, gap, item_start)
            gap = item_end
            if first == "abstract" and len(words) > 1:
                first = words[1]
            if first in CONTAINERS and block_open != -1:
                walk(block_open + 1, item_end - 1, True)
            elif first in ("function", "receive", "fallback"):
                decl = _function(header, item_start, line_of, doc)
                if decl is not None:
                    found.append(decl)
            elif first in ("event", "error"):
                open_paren = header.find("(")
                params = []
                if open_paren != -1:
                    close_paren = _match(header, open_paren, "(", ")")
                    params = parameter_names(header[open_paren + 1 : close_paren])
                name = words[1] if len(words) > 1 else ""
                found.append(Declaration(first, name, line_of(item_start), params, [], doc))
            elif in_container and first and first not in SKIPPED_MEMBERS:
                names = IDENT.findall(_flatten(header).split("=", 1)[0])
                if "public" in names:
                    found.append(
                        Declaration("variable", names[-1], line_of(item_start), [], [], doc)
                    )

    walk(0, len(code), False)
    return found


def problems(decl: Declaration) -> list[str]:
    """What a declaration's NatSpec lacks, as human-readable phrases."""
    doc = decl.doc
    if doc is None:
        return ["no NatSpec"]
    if decl.kind in ("function", "variable") and doc.inheritdoc:
        return []
    issues: list[str] = []
    if not doc.notice:
        inheritable = decl.kind in ("function", "variable")
        issues.append("no @notice" + (" or @inheritdoc" if inheritable else ""))
    if decl.kind in ("function", "event"):
        named = [p for p in decl.params if p]
        issues += [f"no @param {p}" for p in named if p not in doc.params]
        issues += [f"@param {p} names no parameter" for p in doc.params if p not in named]
    if decl.kind == "function":
        if len(doc.returns) != len(decl.returns):
            issues.append(f"{len(doc.returns)} @return for {len(decl.returns)} return value(s)")
        else:
            for name, text in zip(decl.returns, doc.returns):
                if name and text.split()[:1] != [name]:
                    issues.append(f"@return does not start with the name {name}")
    return issues


def check_file(path: Path, display: str) -> list[str]:
    failures = []
    for decl in declarations(path.read_text(encoding="utf-8")):
        for issue in problems(decl):
            failures.append(f"{display}:{decl.line}: {decl.kind} {decl.name}: {issue}")
    return failures


def find_root(start: Path) -> Path:
    for candidate in [start, *start.parents]:
        if (candidate / "foundry.toml").is_file():
            return candidate
    raise SystemExit(f"no foundry.toml above {start}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, help="repository root (default: auto-detected)")
    args = parser.parse_args(argv)

    root = args.root or find_root(Path(__file__).resolve().parent)
    src = root / "src"
    if not src.is_dir():
        raise SystemExit(f"no src/ directory under {root}")
    files = sorted(src.rglob("*.sol"))
    failures: list[str] = []
    for path in files:
        display = path.relative_to(root).as_posix()
        try:
            failures += check_file(path, display)
        except (ValueError, UnicodeDecodeError) as exc:
            failures.append(f"{display}: cannot parse: {exc}")
    for line in failures:
        print(line)
    if failures:
        print(f"NatSpec: {len(failures)} problem(s) in {len(files)} files")
        return 1
    print(f"NatSpec: complete in {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
