"""RFC 8785 canonical JSON (DCL-1: convention documents are canonical; DCL-30: the grade names the
SHA-256 of the card's canonical JSON). Number vectors are RFC 8785 Appendix B; the sorting vector
is RFC 8785 section 3.2.3."""

from __future__ import annotations

import json
import struct
import unittest

from tools.conventions import jcs
from tools.conventions.jcs import CanonicalJsonError


def double(hex_bits: str) -> float:
    return struct.unpack(">d", bytes.fromhex(hex_bits))[0]


NUMBERS = [
    ("0000000000000000", "0"),
    ("8000000000000000", "0"),
    ("0000000000000001", "5e-324"),
    ("8000000000000001", "-5e-324"),
    ("7fefffffffffffff", "1.7976931348623157e+308"),
    ("ffefffffffffffff", "-1.7976931348623157e+308"),
    ("4340000000000000", "9007199254740992"),
    ("c340000000000000", "-9007199254740992"),
    ("4430000000000000", "295147905179352830000"),
    ("44b52d02c7e14af5", "9.999999999999997e+22"),
    ("44b52d02c7e14af6", "1e+23"),
    ("44b52d02c7e14af7", "1.0000000000000001e+23"),
    ("444b1ae4d6e2ef4e", "999999999999999700000"),
    ("444b1ae4d6e2ef4f", "999999999999999900000"),
    ("444b1ae4d6e2ef50", "1e+21"),
    ("3eb0c6f7a0b5ed8c", "9.999999999999997e-7"),
    ("3eb0c6f7a0b5ed8d", "0.000001"),
    ("41b3de4355555553", "333333333.3333332"),
    ("41b3de4355555554", "333333333.33333325"),
    ("41b3de4355555555", "333333333.3333333"),
    ("41b3de4355555556", "333333333.3333334"),
    ("41b3de4355555557", "333333333.33333343"),
    ("becbf647612f3696", "-0.0000033333333333333333"),
    ("43143ff3c1cb0959", "1424953923781206.2"),
]


class NumberTest(unittest.TestCase):
    def test_rfc8785_appendix_b(self) -> None:
        """DCL-1: numbers serialize as ECMAScript Number::toString (RFC 8785 Appendix B)."""
        for bits, expected in NUMBERS:
            with self.subTest(bits=bits):
                self.assertEqual(jcs.canonicalize(double(bits)), expected.encode())

    def test_integers_and_integral_doubles(self) -> None:
        for value, expected in ((0, "0"), (-7, "-7"), (1.0, "1"), (1794787200, "1794787200"),
                                (2**53, "9007199254740992"), (10**21, "1e+21")):  # fmt: skip
            with self.subTest(value=value):
                self.assertEqual(jcs.canonicalize(value), expected.encode())

    def test_nan_and_infinity_are_refused(self) -> None:
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(value=value), self.assertRaises(CanonicalJsonError):
                jcs.canonicalize(value)


class StructureTest(unittest.TestCase):
    def test_member_order_is_utf16_code_units(self) -> None:
        """DCL-1: RFC 8785 section 3.2.3's sorting example."""
        doc = {"€": "Euro Sign", "\r": "Carriage Return", "דּ": "Hebrew Letter Dalet With Dagesh",
               "1": "One", "\U0001f600": "Emoji: Grinning Face", "\u0080": "Control",
               "ö": "Latin Small Letter O With Diaeresis"}  # fmt: skip
        keys = list(json.loads(jcs.canonicalize(doc)).keys())
        self.assertEqual(keys, ["\r", "1", "\u0080", "ö", "€", "\U0001f600", "דּ"])

    def test_strings_escape_like_json_stringify(self) -> None:
        cases = [
            ("a\"b\\c", '"a\\"b\\\\c"'),
            ("\b\t\n\f\r", '"\\b\\t\\n\\f\\r"'),
            ("\x00\x1f", '"\\u0000\\u001f"'),
            ("\x7f/ é\U0001f600", '"\x7f/ é\U0001f600"'),
        ]
        for value, expected in cases:
            with self.subTest(value=value):
                self.assertEqual(jcs.canonicalize(value), expected.encode("utf-8"))

    def test_nested_and_whitespace_free(self) -> None:
        doc = {"b": [1, {"d": None, "c": True}], "a": False}
        self.assertEqual(jcs.canonicalize(doc), b'{"a":false,"b":[1,{"c":true,"d":null}]}')

    def test_lone_surrogates_and_bad_types_are_refused(self) -> None:
        for value in ("\ud800", {"\udc00": 1}, {1: 2}, b"bytes", {"a": object()}):
            with self.subTest(value=value), self.assertRaises(CanonicalJsonError):
                jcs.canonicalize(value)


class ParseTest(unittest.TestCase):
    def test_strict_parse_refusals(self) -> None:
        """DCL-1: documents are I-JSON; DCL-5 refuses a declarations file that is not."""
        cases = {
            "duplicate member": b'{"a":1,"a":2}',
            "byte order mark": b'\xef\xbb\xbf{"a":1}',
            "not UTF-8": b'{"a":"\xff"}',
            "NaN": b'{"a":NaN}',
            "Infinity": b'[Infinity]',
            "escaped lone surrogate": b'["\\ud800"]',
            "not JSON": b'{"a":',
        }
        for name, data in cases.items():
            with self.subTest(name), self.assertRaises(CanonicalJsonError):
                jcs.parse(data)

    def test_integer_beyond_a_double_is_a_canonical_json_error(self) -> None:
        """An integer no IEEE 754 double holds is refused as bad input, not an OverflowError."""
        huge = b"1" + b"0" * 400
        with self.assertRaises(CanonicalJsonError):
            jcs.parse(huge)
        with self.assertRaises(CanonicalJsonError):
            jcs.canonicalize(10**400)
        self.assertFalse(jcs.is_canonical(huge))
        self.assertEqual(jcs.canonicalize(10**300), b"1e+300")  # still a double: rounded, kept

    def test_deep_nesting_is_a_canonical_json_error(self) -> None:
        """Nesting past MAX_DEPTH, or past Python's recursion limit, is refused as bad input when
        parsing and when serializing, not a RecursionError."""
        for depth in (jcs.MAX_DEPTH + 1, 100_000):
            data = b"[" * depth + b"]" * depth
            with self.subTest(depth=depth):
                with self.assertRaises(CanonicalJsonError):
                    jcs.parse(data)
                self.assertFalse(jcs.is_canonical(data))
        value: list = []
        for _ in range(5_000):
            value = [value]
        with self.assertRaises(CanonicalJsonError):
            jcs.canonicalize(value)
        nested_ok = b"[" * jcs.MAX_DEPTH + b"]" * jcs.MAX_DEPTH
        self.assertTrue(jcs.is_canonical(nested_ok))

    def test_is_canonical(self) -> None:
        self.assertTrue(jcs.is_canonical(b'{"a":1,"b":"x"}'))
        for data in (b'{"b":"x","a":1}', b'{"a": 1}', b'{"a":1.0}', b'{"a":1}\n', b'{"a":1,"a":1}'):
            with self.subTest(data=data):
                self.assertFalse(jcs.is_canonical(data))


if __name__ == "__main__":
    unittest.main()
