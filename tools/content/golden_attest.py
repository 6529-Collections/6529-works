"""Golden cases for base64 attestation: texts the store must accept and texts it must refuse.

`ContentStore.attestBase64` accepts a stored text only if it is a whole number of 4-byte groups,
every byte is in `[A-Za-z0-9+/]`, and `=` appears only as the last one or two bytes of the whole
text. `base64_attestation_problem` is this tool's copy of that rule. Each case here carries the
verdict a human intends (`ok`, `length`, or `alphabet` at a given chunk), the generator asserts the
Python rule agrees, and `test/content/tooling/UploaderAttest.t.sol` makes a real `ContentStore`
reach the same verdict: it either attests the text or reverts with `ContentBase64LengthInvalid` or
`ContentBase64Invalid(fileId, chunk)`.

Two bitmaps cover every byte value: which values a text accepts as its FIRST byte (the alphabet
only) and as its LAST byte (the alphabet plus the `=` padding).

Texts are written as `(unit, count)` parts so a multi-chunk text stays a few bytes of data.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .encoding import base64_attestation_problem
from .errors import ToolError
from .plan import CHUNK_SIZE

Parts = tuple[tuple[bytes, int], ...]

EXPECT_CODES = {"ok": 0, "alphabet": 1, "length": 2}


@dataclass(frozen=True)
class Case:
    name: str
    parts: Parts
    expect: str  # ok | alphabet | length
    chunk: int = 0  # alphabet only: the chunk index ContentBase64Invalid reports


def _one(text: bytes) -> Parts:
    return ((text, 1),)


def _around(byte: int) -> Parts:
    """A well-formed group with `byte` swapped in for one of its letters."""
    return _one(b"QU" + bytes([byte]) + b"J")


ALPHABET = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

CASES: tuple[Case, ...] = (
    # --- accepted ---
    Case("no-padding", _one(b"QUJD"), "ok"),
    Case("one-pad", _one(b"QUI="), "ok"),
    Case("two-pads", _one(b"QQ=="), "ok"),
    Case("full-alphabet", _one(ALPHABET), "ok"),
    Case("plus-and-slash", _one(b"+/+/"), "ok"),
    Case("alphabet-extremes", _one(b"+/09AZaz"), "ok"),
    Case("three-full-chunks", ((b"ABCD", 12_288),), "ok"),  # 49,152 bytes
    Case("pad-in-the-last-of-three", ((b"ABCD", 12_287), (b"AB==", 1)), "ok"),
    # The padding is the last one or two bytes of the whole text, so it may straddle chunks.
    Case("two-pads-straddle-chunks", ((b"A", 24_574), (b"=", 2)), "ok"),
    Case("one-pad-alone-in-the-last-chunk", ((b"A", 24_575), (b"=", 1)), "ok"),
    # --- refused: a byte outside the alphabet, or `=` anywhere but the end ---
    Case("equals-in-the-middle", _one(b"QQ=A"), "alphabet", 0),
    Case("only-equals", _one(b"===="), "alphabet", 0),
    Case("leading-equals", _one(b"=QUJ"), "alphabet", 0),
    Case("three-equals", _one(b"Q==="), "alphabet", 0),
    Case("equals-before-the-final-equals", _one(b"A=A="), "alphabet", 0),
    Case("url-safe-minus", _around(ord("-")), "alphabet", 0),
    Case("url-safe-underscore", _around(ord("_")), "alphabet", 0),
    Case("newline", _around(0x0A), "alphabet", 0),
    Case("space", _around(0x20), "alphabet", 0),
    Case("double-quote", _around(0x22), "alphabet", 0),
    Case("backslash", _around(0x5C), "alphabet", 0),
    Case("percent", _around(0x25), "alphabet", 0),
    Case("hash", _around(0x23), "alphabet", 0),
    Case("less-than", _around(0x3C), "alphabet", 0),
    Case("nul", _around(0x00), "alphabet", 0),
    Case("delete", _around(0x7F), "alphabet", 0),
    Case("high-bit", _around(0x80), "alphabet", 0),
    Case("utf-8-letter", _one("QUé".encode("utf-8")), "alphabet", 0),
    # The bytes next to the alphabet's ranges (the word-at-a-time check's edges).
    Case("below-plus", _around(0x2A), "alphabet", 0),
    Case("comma", _around(0x2C), "alphabet", 0),
    Case("period", _around(0x2E), "alphabet", 0),
    Case("colon", _around(0x3A), "alphabet", 0),
    Case("at-sign", _around(0x40), "alphabet", 0),
    Case("open-bracket", _around(0x5B), "alphabet", 0),
    Case("backtick", _around(0x60), "alphabet", 0),
    Case("open-brace", _around(0x7B), "alphabet", 0),
    # Chunk boundaries: the chunk index in the error is the chunk holding the first bad byte.
    Case("three-pads-straddle-chunks", ((b"A", 24_573), (b"=", 3)), "alphabet", 0),
    Case("equals-then-letter-at-the-boundary", ((b"A", 24_574), (b"=A", 1)), "alphabet", 0),
    Case("bad-byte-in-the-second-chunk", ((b"A", 24_575), (b"$", 1)), "alphabet", 1),
    Case("bad-byte-then-more-text", ((b"A", 24_575), (b"%", 1), (b"AAAA", 5)), "alphabet", 1),
    Case("bad-byte-in-the-third-chunk", ((b"A", 49_151), (b'"', 1)), "alphabet", 2),
    # --- refused: the length is not a multiple of 4 (checked before any byte) ---
    Case("length-1", _one(b"Q"), "length"),
    Case("length-2", _one(b"QQ"), "length"),
    Case("length-3-padded", _one(b"QQ="), "length"),
    Case("length-5", _one(b"QUJDQ"), "length"),
    Case("length-5-padded", _one(b"QUJD="), "length"),
    Case("length-one-full-chunk", ((b"A", 24_575),), "length"),
    Case("length-is-checked-before-the-alphabet", _one(b"QU-JQ"), "length"),
)


def text_of(case: Case) -> bytes:
    return b"".join(unit * count for unit, count in case.parts)


def verdict(text: bytes) -> tuple[str, int]:
    """This tool's reading of the rule as (`ok`|`alphabet`|`length`, chunk index)."""
    problem = base64_attestation_problem(text)
    if problem is None:
        return "ok", 0
    if problem.kind == "length":
        return "length", 0
    assert problem.offset is not None
    return "alphabet", problem.offset // CHUNK_SIZE


def accepted_bitmaps() -> tuple[int, int]:
    """Bit `v` set when byte value `v` is accepted as the first byte of an otherwise valid text,
    and (second value) as the last."""
    first = last = 0
    for value in range(256):
        if base64_attestation_problem(bytes([value]) + b"AAA") is None:
            first |= 1 << value
        if base64_attestation_problem(b"AAA" + bytes([value])) is None:
            last |= 1 << value
    return first, last


def build_document() -> dict[str, Any]:
    """The `attest` section of vectors.json. Refuses to build if the Python rule disagrees with
    a case's intended verdict."""
    cases = []
    for case in CASES:
        text = text_of(case)
        got = verdict(text)
        if got != (case.expect, case.chunk if case.expect == "alphabet" else 0):
            raise ToolError(f"attest case {case.name}: the rule says {got}, the case says {case.expect}")
        cases.append(
            {
                "name": case.name,
                "parts": [[unit.hex(), count] for unit, count in case.parts],
                "length": len(text),
                "expect": case.expect,
                "chunk": case.chunk if case.expect == "alphabet" else None,
            }
        )
    first, last = accepted_bitmaps()
    return {
        "rule": (
            "length % 4 == 0; every byte in [A-Za-z0-9+/] except that '=' may be the last one "
            "or two bytes of the whole text; the first bad byte's chunk is reported"
        ),
        "acceptedAsFirst": "0x" + first.to_bytes(32, "big").hex(),
        "acceptedAsLast": "0x" + last.to_bytes(32, "big").hex(),
        "cases": cases,
    }


def check_document(document: dict[str, Any]) -> list[str]:
    """Problems with the committed `attest` section, found by recomputing it."""
    try:
        expected = build_document()
    except ToolError as exc:
        return [str(exc)]
    return [] if document == expected else ["vectors.json attest section is stale: run `golden --write`"]


def render_solidity(document: dict[str, Any]) -> str:
    """The attest cases as members of the generated `UploaderGoldenData` library."""

    def hex_literal(data: bytes) -> str:
        return f'hex"{data.hex()}"'

    cases = document["cases"]
    parts = [
        "    /// @dev One piece of a text: `unit` repeated `count` times.",
        "    struct Part {",
        "        bytes unit;",
        "        uint256 count;",
        "    }",
        "",
        "    /// @param expect 0 accepted, 1 `ContentBase64Invalid` at `chunk`, 2 `ContentBase64LengthInvalid`.",
        "    struct Base64Case {",
        "        string name;",
        "        Part[] parts;",
        "        uint8 expect;",
        "        uint256 chunk;",
        "    }",
        "",
        "    /// @dev Bit v set: byte value v is accepted as the first (resp. last) byte of a text.",
        f"    uint256 internal constant BASE64_ACCEPTED_AS_FIRST = {document['acceptedAsFirst']};",
        f"    uint256 internal constant BASE64_ACCEPTED_AS_LAST = {document['acceptedAsLast']};",
        "",
        "    /// @dev Texts for `attestBase64`: accepted, refused by alphabet, refused by length.",
        "    function base64Cases() internal pure returns (Base64Case[] memory out) {",
        f"        out = new Base64Case[]({len(cases)});",
    ]
    parts += [f"        out[{i}] = _a{i}();" for i in range(len(cases))]
    parts.append("    }")
    for i, case in enumerate(cases):
        parts += [
            "",
            f"    function _a{i}() private pure returns (Base64Case memory c) {{",
            f'        c.name = "{case["name"]}";',
            f"        c.expect = {EXPECT_CODES[case['expect']]};",
            f"        c.chunk = {case['chunk'] or 0};",
            f"        c.parts = new Part[]({len(case['parts'])});",
        ]
        for j, (unit_hex, count) in enumerate(case["parts"]):
            parts.append(f"        c.parts[{j}] = Part({hex_literal(bytes.fromhex(unit_hex))}, {count});")
        parts.append("    }")
    return "\n".join(parts)
