#!/usr/bin/env python3
"""Fail on broken relative links and #anchors in the repository's Markdown files.

For every tracked `*.md` file (lib/ excluded) it checks each relative link, image,
reference definition and HTML `href`/`src`:
  1. the target file or directory exists, with exactly the same letter case (GitHub is
     case-sensitive even where your checkout is not) and stays inside the repository;
  2. a `#anchor` on a Markdown target (or on the file itself) matches a heading,
     generated the way GitHub does it, or an explicit `id`/`name` attribute.

External links (`https:`, `mailto:` and any other scheme) are not fetched. Links inside
code fences, code spans and HTML comments are ignored. Anchors are compared
case-insensitively, as GitHub's own navigation does. Line anchors such as `#L10-L20`
on non-Markdown files (source views) are not checked.

Run from anywhere: `python tools/check_markdown_links.py`. Standard library only. The
repository root is the parent of tools/ unless `--root` is given, and the file list
comes from `git ls-files` (falling back to walking the tree when there is no git).
"""

from __future__ import annotations

import argparse
import html
import os
import re
import subprocess
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote

EXCLUDED_DIRS = {"lib", ".git", "node_modules", "out", "cache"}
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
ATX_HEADING = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")
SETEXT_UNDERLINE = re.compile(r"^ {0,3}(=+|-+)[ \t]*$")
NOT_PARAGRAPH = re.compile(r"^\s*(#|>|\||[-*+]\s|\d+[.)]\s|```|~~~|<)")
REFERENCE_DEFINITION = re.compile(r"^ {0,3}\[(?!\^)[^\]\n]+\]:[ \t]*(<[^>\n]*>|\S+)", re.MULTILINE)
HTML_URL = re.compile(r"""\b(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)')""", re.IGNORECASE)
HTML_ANCHOR = re.compile(r"""\b(?:id|name)\s*=\s*(?:"([^"]+)"|'([^']+)')""", re.IGNORECASE)
NUL = chr(0)


@dataclass(frozen=True)
class Link:
    destination: str
    line: int


# ---------------------------------------------------------------------------
# Reading Markdown


def blank_out(text: str, start: int, end: int) -> str:
    """Replace text[start:end] with spaces, keeping line breaks."""
    return text[:start] + re.sub(r"[^\n]", " ", text[start:end]) + text[end:]


def strip_code(text: str) -> str:
    """Blank fenced code, HTML comments and code spans, preserving every line break."""
    lines = text.split("\n")
    fence: str | None = None
    for index, line in enumerate(lines):
        match = FENCE.match(line)
        if fence is None:
            if match:
                fence = match.group(1)
                lines[index] = ""
            continue
        if match and match.group(1)[0] == fence[0] and len(match.group(1)) >= len(fence):
            if line.strip() == match.group(1):
                fence = None
        lines[index] = ""
    text = "\n".join(lines)
    for comment in reversed(list(re.finditer(r"<!--.*?-->", text, re.DOTALL))):
        text = blank_out(text, comment.start(), comment.end())
    # A code span opens with a backtick run and closes with a run of the same length.
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        if text[i] != "`":
            out.append(text[i])
            i += 1
            continue
        run = i
        while run < n and text[run] == "`":
            run += 1
        ticks = text[i:run]
        close = text.find(ticks, run)
        while close != -1 and text[close + len(ticks) : close + len(ticks) + 1] == "`":
            # The closing run must not be part of a longer run.
            close = text.find(ticks, close + len(ticks) + 1)
        if close == -1:
            out.append(ticks)
            i = run
        else:
            end = close + len(ticks)
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
    return "".join(out)


def _has_opening_bracket(text: str, close: int) -> bool:
    """True if the `]` at text[close] closes a `[` in the same paragraph."""
    depth = 1
    for i in range(close - 1, -1, -1):
        c = text[i]
        if c == "\n" and (i == 0 or text[i - 1] == "\n"):
            return False  # a blank line ends the paragraph
        if i > 0 and text[i - 1] == "\\":
            continue
        if c == "]":
            depth += 1
        elif c == "[":
            depth -= 1
            if depth == 0:
                return True
    return False


def _inline_destination(text: str, start: int) -> str | None:
    """The destination of an inline link whose `(` is just before text[start]."""
    n = len(text)
    i = start
    while i < n and text[i] in " \t\n":
        i += 1
    if i < n and text[i] == "<":
        end = text.find(">", i + 1)
        newline = text.find("\n", i + 1)
        if end == -1 or (newline != -1 and newline < end):
            return None
        return text[i + 1 : end]
    depth = 0
    begin = i
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c in " \t\n":
            break
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                break
            depth -= 1
        i += 1
    return text[begin:i]


def extract_links(text: str) -> list[Link]:
    """Every link destination in `text` outside code, with its 1-based line number."""
    code_free = strip_code(text)
    found: list[tuple[int, str]] = []
    for match in re.finditer(r"\]\(", code_free):
        if not _has_opening_bracket(code_free, match.start()):
            continue
        destination = _inline_destination(code_free, match.end())
        if destination is not None:
            found.append((match.end(), destination))
    for match in REFERENCE_DEFINITION.finditer(code_free):
        destination = match.group(1)
        found.append((match.start(1), destination[1:-1] if destination.startswith("<") else destination))
    for match in HTML_URL.finditer(code_free):
        found.append((match.start(), match.group(1) if match.group(1) is not None else match.group(2)))
    links = [Link(dest, code_free.count("\n", 0, offset) + 1) for offset, dest in sorted(found)]
    return [link for link in links if link.destination]


def github_slug(heading: str) -> str:
    """GitHub's anchor for a heading's text, before duplicate numbering."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)  # links and images: their text
    text = re.sub(r"!?\[([^\]]*)\]\[[^\]]*\]", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)  # inline HTML tags
    text = html.unescape(text)
    text = re.sub(r"`+", "", text)
    text = re.sub(r"(\*\*|\*|__)(.+?)\1", r"\2", text)
    text = re.sub(r"(?<![\w])_(.+?)_(?![\w])", r"\1", text)
    text = text.strip().lower()
    kept = [
        c
        for c in text
        if c in "- " or unicodedata.category(c)[0] in "LMN" or unicodedata.category(c) == "Pc"
    ]
    return "".join(kept).replace(" ", "-")


def heading_anchors(text: str) -> set[str]:
    """Lower-cased anchors a Markdown file offers: headings and id/name attributes."""
    code_free = strip_code(text)
    lines = code_free.split("\n")
    anchors: set[str] = set()
    seen: dict[str, int] = {}

    def add(heading: str) -> None:
        slug = github_slug(heading)
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        anchors.add(slug if count == 0 else f"{slug}-{count}")

    for index, line in enumerate(lines):
        atx = ATX_HEADING.match(line)
        if atx:
            add(atx.group(2) or "")
            continue
        if SETEXT_UNDERLINE.match(line) and index > 0:
            previous = lines[index - 1]
            if previous.strip() and not NOT_PARAGRAPH.match(previous):
                add(previous.strip())
    for match in HTML_ANCHOR.finditer(code_free):
        anchors.add((match.group(1) or match.group(2)).lower())
    return anchors


# ---------------------------------------------------------------------------
# Resolving links


def markdown_files(root: Path, use_git: bool = True) -> list[str]:
    """Repo-relative POSIX paths of the Markdown files to check, lib/ excluded."""
    names: list[str] | None = None
    if use_git:
        try:
            result = subprocess.run(
                ["git", "-C", str(root), "ls-files", "-z", "--", "*.md"],
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
        except OSError:  # git is not installed
            result = None
        if result is not None and result.returncode == 0:
            names = [name for name in result.stdout.split(NUL) if name]
    if names is None:
        names = []
        for directory, subdirectories, files in os.walk(root):
            subdirectories[:] = sorted(d for d in subdirectories if d not in EXCLUDED_DIRS)
            names += [
                (Path(directory) / name).relative_to(root).as_posix()
                for name in files
                if name.endswith(".md")
            ]
    return sorted(
        name for name in names if name.split("/")[0] not in EXCLUDED_DIRS and (root / name).is_file()
    )


class Repo:
    """Existence checks with exact letter case, and cached heading anchors."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self._listings: dict[tuple[str, ...], set[str]] = {}
        self._anchors: dict[str, set[str]] = {}

    def listing(self, parts: tuple[str, ...]) -> set[str]:
        if parts not in self._listings:
            try:
                self._listings[parts] = set(os.listdir(self.root.joinpath(*parts)))
            except OSError:
                self._listings[parts] = set()
        return self._listings[parts]

    def exists(self, parts: tuple[str, ...]) -> bool:
        return all(part in self.listing(parts[:depth]) for depth, part in enumerate(parts))

    def is_dir(self, parts: tuple[str, ...]) -> bool:
        return self.root.joinpath(*parts).is_dir()

    def anchors(self, parts: tuple[str, ...]) -> set[str]:
        key = "/".join(parts)
        if key not in self._anchors:
            text = self.root.joinpath(*parts).read_text(encoding="utf-8-sig", errors="replace")
            self._anchors[key] = heading_anchors(text)
        return self._anchors[key]


def resolve(source_dir: tuple[str, ...], path: str) -> tuple[str, ...] | None:
    """The repo-relative parts a link path points to, or None if it leaves the repository."""
    parts = [] if path.startswith("/") else list(source_dir)
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                return None
            parts.pop()
        else:
            parts.append(part)
    return tuple(parts)


def check_link(repo: Repo, source: str, destination: str) -> str | None:
    """The problem with one link in the file `source`, or None if it is fine."""
    if SCHEME.match(destination) or destination.startswith("//"):
        return None
    path, _, fragment = destination.partition("#")
    path = unquote(path.partition("?")[0])
    fragment = unquote(fragment)
    source_parts = tuple(source.split("/"))
    if path:
        target = resolve(source_parts[:-1], path)
        if target is None:
            return f"{destination!r} leaves the repository"
        if not repo.exists(target):
            return f"missing target {'/'.join(target) or '.'!r} (from {destination!r})"
    else:
        target = source_parts
    if not fragment or fragment.lower() == "top":
        return None
    if repo.is_dir(target):
        readme = next((name for name in sorted(repo.listing(target)) if name.lower() == "readme.md"), None)
        if readme is None:
            return f"anchor #{fragment} on directory {'/'.join(target) or '.'!r}, which has no README.md"
        target = (*target, readme)
    if not target[-1].lower().endswith(".md"):
        return None  # source files have line anchors such as #L10, which are not checkable here
    if fragment.lower() not in repo.anchors(target):
        return f"missing anchor #{fragment} in {'/'.join(target)!r}"
    return None


def check(root: Path, files: list[str]) -> tuple[list[str], int]:
    """(problem lines, number of links checked) for the given repo-relative files."""
    repo = Repo(root)
    problems: list[str] = []
    checked = 0
    for name in files:
        text = (root / name).read_text(encoding="utf-8-sig", errors="replace")
        for link in extract_links(text):
            checked += 1
            problem = check_link(repo, name, link.destination)
            if problem:
                problems.append(f"{name}:{link.line}: {problem}")
    return problems, checked


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, help="repository root (default: parent of tools/)")
    parser.add_argument("--no-git", action="store_true", help="walk the tree instead of git ls-files")
    args = parser.parse_args(argv)

    root = (args.root or Path(__file__).resolve().parent.parent).resolve()
    files = markdown_files(root, use_git=not args.no_git)
    problems, checked = check(root, files)
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        print(f"markdown links: {len(problems)} broken of {checked} checked in {len(files)} files")
        return 1
    print(f"markdown links: {checked} links in {len(files)} files, none broken")
    return 0


if __name__ == "__main__":
    sys.exit(main())
