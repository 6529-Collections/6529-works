"""Unit tests for check_comment_codes.py, which sits beside this file.

Run with `python tools/test_check_comment_codes.py`.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "check_comment_codes", Path(__file__).with_name("check_comment_codes.py")
)
cc = importlib.util.module_from_spec(_SPEC)
sys.modules["check_comment_codes"] = cc
_SPEC.loader.exec_module(cc)

IDS = {"AUC-3", "WS-17", "LIM-SAL-9", "INV-STR-1"}


def kinds(source: str) -> list[tuple[str, str]]:
    return [(h.kind, h.text) for h in cc.scan(source, "x.sol", IDS)]


class CommentCodesTest(unittest.TestCase):
    def test_allowed_citations_pass(self) -> None:
        src = "/// @notice See AUC-3, WS-17, LIM-SAL-9, INV-STR-1, ADR 0010, ERC-721, EIP-712.\n"
        src += "/// SHA-256 over UTF-8; CC0-1.0.\nuint256 x;\n"
        self.assertEqual(kinds(src), [])

    def test_owner_decision_and_bare_codes(self) -> None:
        found = kinds("/// owner decision 17 and R9, C8, D140.\n")
        self.assertIn(("owner decision", "owner decision 17"), found)
        self.assertIn(("bare code", "R9"), found)
        self.assertIn(("bare code", "C8"), found)
        self.assertIn(("bare code", "D140"), found)

    def test_labels_and_undefined_rule_ids(self) -> None:
        found = kinds("// MARKET-4 and QUALITY-6 and AUC-99\n")
        self.assertIn(("label", "MARKET-4"), found)
        self.assertIn(("label", "QUALITY-6"), found)
        self.assertIn(("undefined rule ID", "AUC-99"), found)

    def test_code_outside_comments_is_ignored(self) -> None:
        self.assertEqual(kinds('string constant s = "R9 MARKET-4";\n'), [])

    def test_block_comment_line_numbers(self) -> None:
        hits = cc.scan("uint a;\n/* fine\n   PR #12 */\n", "x.sol", IDS)
        self.assertEqual([(h.line, h.kind) for h in hits], [(3, "pull request")])

    def test_ids_are_read_from_table_rows(self) -> None:
        ids = cc.defined_ids()
        self.assertTrue(any(i.startswith("GV-") for i in ids))


if __name__ == "__main__":
    unittest.main()
