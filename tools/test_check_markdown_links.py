"""Unit tests for check_markdown_links.py, which sits beside this file.

Run with `python tools/test_check_markdown_links.py` or, from the repository root,
`python -m tools.test_check_markdown_links`.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "check_markdown_links", Path(__file__).with_name("check_markdown_links.py")
)
cm = importlib.util.module_from_spec(_SPEC)
sys.modules["check_markdown_links"] = cm  # dataclasses resolve annotations through sys.modules
_SPEC.loader.exec_module(cm)


def destinations(text: str) -> list[str]:
    return [link.destination for link in cm.extract_links(text)]


class SlugTest(unittest.TestCase):
    def test_github_slugs(self) -> None:
        cases = {
            "3. Curation and approved packages": "3-curation-and-approved-packages",
            "17. Reuse plan (from RC1 and PR #744)": "17-reuse-plan-from-rc1-and-pr-744",
            "6. 6529 Editions": "6-6529-editions",
            "Q&A: what's new?": "qa-whats-new",
            "Non-goals and deferrals": "non-goals-and-deferrals",
            "snake_case_name": "snake_case_name",
            "`forge fmt` and *build*": "forge-fmt-and-build",
            "A **bold** and _italic_ word": "a-bold-and-italic-word",
            "[Link text](docs/x.md) heading": "link-text-heading",
            "![alt text](img.png) image": "alt-text-image",
            "<code>html</code> tag": "html-tag",
            "Two  spaces": "two--spaces",
            "  padded  ": "padded",
            "Ünïcode Überschrift": "ünïcode-überschrift",
            "日本語 heading": "日本語-heading",
            "Trailing dash -": "trailing-dash--",
            "Emoji \U0001f680 launch": "emoji--launch",
        }
        for heading, slug in cases.items():
            with self.subTest(heading):
                self.assertEqual(cm.github_slug(heading), slug)

    def test_headings_atx_setext_and_duplicates(self) -> None:
        text = (
            "# Title\n\n## Usage ##\n\nSetext heading\n---------------\n\nOther\n=====\n\n"
            "## Usage\n\n### Usage\n\n##Not a heading\n\n#hashtag\n"
        )
        self.assertEqual(
            cm.heading_anchors(text),
            {"title", "usage", "setext-heading", "other", "usage-1", "usage-2"},
        )

    def test_headings_in_code_and_comments_do_not_count(self) -> None:
        text = (
            "# Real\n\n```\n# In a fence\n```\n\n~~~md\n## Tilde fence\n~~~\n\n"
            "<!-- ## In a comment -->\n\n`# not a heading`\n"
        )
        self.assertEqual(cm.heading_anchors(text), {"real"})

    def test_table_rows_and_rules_are_not_setext_headings(self) -> None:
        text = "| a | b |\n|---|---|\n\n- item\n---\n\nText\n\n---\n"
        self.assertEqual(cm.heading_anchors(text), set())

    def test_explicit_id_and_name_anchors(self) -> None:
        text = '<a name="Legacy-Anchor"></a>\n<div id=\'box\'></div>\n'
        self.assertEqual(cm.heading_anchors(text), {"legacy-anchor", "box"})


class ExtractTest(unittest.TestCase):
    def test_inline_links_images_titles_and_angle_destinations(self) -> None:
        text = (
            "[a](one.md) and ![img](two.png) and [t](three.md \"Title\") and\n"
            "[sp](<with space.md>) and [b](four.md#frag) and [e]()\n"
        )
        self.assertEqual(
            destinations(text),
            ["one.md", "two.png", "three.md", "with space.md", "four.md#frag"],
        )

    def test_nested_badge_link_and_balanced_parentheses(self) -> None:
        text = "[![badge](https://x/b.svg)](docs/a.md) and [p](docs/f(1).md) and (see [q](q.md))\n"
        self.assertEqual(destinations(text), ["https://x/b.svg", "docs/a.md", "docs/f(1).md", "q.md"])

    def test_reference_definitions_and_html_urls(self) -> None:
        text = (
            "[ref]: docs/ref.md\n[angle]: <docs/angle.md> \"t\"\n[^1]: footnote text\n\n"
            '<a href="docs/a.md#x">a</a> <img src=\'img/p.png\'>\n'
        )
        self.assertEqual(destinations(text), ["docs/ref.md", "docs/angle.md", "docs/a.md#x", "img/p.png"])

    def test_code_comments_and_stray_brackets_are_ignored(self) -> None:
        text = (
            "```\n[fenced](a.md)\n```\n"
            "~~~\n[tilde](b.md)\n~~~\n"
            "`[span](c.md)` and ``[double `tick`](d.md)``\n"
            "<!-- [commented](e.md) -->\n"
            "a stray ](args) with no opening bracket\n\n"
            "[opened here\n\nclosed in the next paragraph](nolink.md)\n\n"
            "[real](real.md)\n"
        )
        self.assertEqual(destinations(text), ["real.md"])

    def test_unclosed_fence_swallows_the_rest(self) -> None:
        self.assertEqual(destinations("[a](a.md)\n```\n[b](b.md)\n"), ["a.md"])

    def test_line_numbers(self) -> None:
        text = "first\n\n```\ncode\n```\n[x](x.md)\n<!-- one\ntwo -->\n[y](y.md)\n"
        self.assertEqual([(l.destination, l.line) for l in cm.extract_links(text)], [("x.md", 6), ("y.md", 9)])


class TempRepo:
    def __init__(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name).resolve()

    def write(self, relative: str, text: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def problems(self) -> list[str]:
        return cm.check(self.root, cm.markdown_files(self.root, use_git=False))[0]

    def run(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cm.main(["--root", str(self.root), *args])
        return code, out.getvalue()

    def close(self) -> None:
        self._dir.cleanup()


class CheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.close)
        self.repo.write("README.md", "# Home\n\n## Sub section\n")
        self.repo.write("docs/guide.md", "# Guide\n\n## 3. Rules (v1)\n")
        self.repo.write("src/a/README.md", "# a\n")
        self.repo.write("src/Token.sol", "contract Token {}\n")

    def check(self, source: str, text: str) -> list[str]:
        self.repo.write(source, text)
        return [p for p in self.repo.problems() if p.startswith(source + ":")]

    def test_valid_links_pass(self) -> None:
        self.repo.write(
            "src/a/README.md",
            "# a\n[home](../../README.md#sub-section) [guide](../../docs/guide.md#3-rules-v1)\n"
            "[dir](../) [self](#a) [top](#top) [abs](/docs/guide.md) [sol](../Token.sol)\n"
            "[line](../Token.sol#L1-L2) [q](../../docs/guide.md?plain=1#guide) [enc](../../docs/gu%69de.md)\n"
            "[ext](https://example.com/x.md#nope) [mail](mailto:a@b.c) [proto](//cdn.example/x)\n",
        )
        self.assertEqual(self.repo.problems(), [])

    def test_missing_file_reports_file_and_line(self) -> None:
        problems = self.check("src/a/README.md", "# a\n\n[bad](../../docs/missing.md)\n")
        self.assertEqual(
            problems,
            ["src/a/README.md:3: missing target 'docs/missing.md' (from '../../docs/missing.md')"],
        )

    def test_missing_anchor_in_another_file_and_in_the_same_file(self) -> None:
        problems = self.check("src/a/README.md", "# a\n[x](../../docs/guide.md#nope)\n[y](#nowhere)\n")
        self.assertEqual(
            problems,
            [
                "src/a/README.md:2: missing anchor #nope in 'docs/guide.md'",
                "src/a/README.md:3: missing anchor #nowhere in 'src/a/README.md'",
            ],
        )

    def test_anchors_are_case_insensitive(self) -> None:
        self.assertEqual(self.check("src/a/README.md", "# a\n[x](../../docs/guide.md#GUIDE)\n"), [])

    def test_link_that_leaves_the_repository_fails(self) -> None:
        problems = self.check("src/a/README.md", "# a\n[x](../../../outside.md)\n")
        self.assertEqual(len(problems), 1)
        self.assertIn("leaves the repository", problems[0])

    def test_case_mismatch_fails_even_on_a_case_insensitive_filesystem(self) -> None:
        problems = self.check("src/a/README.md", "# a\n[x](../../Docs/guide.md)\n[y](../../docs/GUIDE.md)\n")
        self.assertEqual(len(problems), 2)
        self.assertTrue(all("missing target" in p for p in problems))

    def test_directory_targets_and_anchors_on_directories(self) -> None:
        self.repo.write("empty/.keep.txt", "")
        problems = self.check(
            "src/a/README.md",
            "# a\n[ok](../a/) [readme](../../docs) [bad](../../empty#x) [home](../../#sub-section)\n"
            "[ok2](../../src/a#a) [bad2](../../src/a#zzz)\n",
        )
        self.assertEqual(len(problems), 2, problems)
        self.assertIn("anchor #x on directory 'empty', which has no README.md", problems[0])
        self.assertIn("missing anchor #zzz in 'src/a/README.md'", problems[1])

    def test_anchor_on_a_non_markdown_target_is_not_checked(self) -> None:
        self.assertEqual(self.check("src/a/README.md", "# a\n[x](../Token.sol#L10)\n[y](../Token.sol#anything)\n"), [])

    def test_reference_definitions_and_html_links_are_checked(self) -> None:
        problems = self.check(
            "src/a/README.md", '# a\n[r]: ../../nope.md\n<a href="../../docs/guide.md#missing">x</a>\n'
        )
        self.assertEqual(len(problems), 2)
        self.assertIn(":2: missing target 'nope.md'", problems[0])
        self.assertIn(":3: missing anchor #missing", problems[1])

    def test_links_in_code_are_not_checked(self) -> None:
        self.assertEqual(self.check("src/a/README.md", "# a\n```\n[x](gone.md)\n```\n`[y](gone.md)`\n"), [])

    def test_lib_is_excluded(self) -> None:
        self.repo.write("lib/vendor/README.md", "[gone](missing.md)\n")
        self.assertEqual(self.repo.problems(), [])
        self.assertNotIn("lib/vendor/README.md", cm.markdown_files(self.repo.root, use_git=False))

    def test_non_markdown_files_are_not_scanned(self) -> None:
        self.repo.write("notes.txt", "[gone](missing.md)\n")
        self.assertEqual(self.repo.problems(), [])

    def test_duplicate_headings_get_numbered_anchors(self) -> None:
        self.repo.write("docs/dup.md", "# Same\n\n# Same\n")
        self.assertEqual(self.check("src/a/README.md", "# a\n[x](../../docs/dup.md#same-1)\n"), [])
        self.assertEqual(len(self.check("src/a/README.md", "# a\n[x](../../docs/dup.md#same-2)\n")), 1)

    def test_bom_and_crlf_files(self) -> None:
        (self.repo.root / "docs/win.md").write_bytes("﻿# Windows\r\n\r\n## Two words\r\n".encode("utf-8"))
        self.assertEqual(self.check("src/a/README.md", "# a\n[x](../../docs/win.md#windows) [y](../../docs/win.md#two-words)\n"), [])


class MainTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = TempRepo()
        self.addCleanup(self.repo.close)

    def test_clean_tree_exits_zero(self) -> None:
        self.repo.write("README.md", "# Home\n[self](#home) [ext](https://example.com)\n")
        code, out = self.repo.run("--no-git")
        self.assertEqual(code, 0, out)
        self.assertIn("markdown links: 2 links in 1 files, none broken", out)

    def test_broken_links_exit_one_and_are_listed(self) -> None:
        self.repo.write("README.md", "[a](gone.md)\n[b](#nope)\n")
        code, out = self.repo.run("--no-git")
        self.assertEqual(code, 1)
        self.assertIn("FAIL README.md:1: missing target 'gone.md'", out)
        self.assertIn("FAIL README.md:2: missing anchor #nope", out)
        self.assertIn("markdown links: 2 broken of 2 checked in 1 files", out)

    @unittest.skipUnless(shutil.which("git"), "git is not installed")
    def test_file_list_comes_from_git_ls_files(self) -> None:
        self.repo.write("README.md", "[a](gone.md)\n")
        self.repo.write("untracked.md", "[b](gone.md)\n")
        self.repo.write("lib/dep/README.md", "[c](gone.md)\n")
        subprocess.run(["git", "init", "-q"], cwd=self.repo.root, check=True)
        subprocess.run(["git", "add", "README.md", "lib/dep/README.md"], cwd=self.repo.root, check=True)
        self.assertEqual(cm.markdown_files(self.repo.root), ["README.md"])
        code, out = self.repo.run()
        self.assertEqual(code, 1)
        self.assertIn("README.md:1", out)
        self.assertNotIn("untracked.md", out)
        self.assertNotIn("lib/dep", out)

    def test_without_git_the_tree_is_walked(self) -> None:
        self.repo.write("a/b/c.md", "x\n")
        self.repo.write("lib/d.md", "x\n")
        self.assertEqual(cm.markdown_files(self.repo.root, use_git=False), ["a/b/c.md"])


if __name__ == "__main__":
    unittest.main()
