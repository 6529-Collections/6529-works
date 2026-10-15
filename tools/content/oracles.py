"""Differential vectors for the renderer's text checks, decided by oracles independent of Solidity.

Each set is generated from a fixed seed and written to `test/fixtures/oracles/<name>.json`, which
`test/content/renderer/RendererOracles.t.sol` reads with `vm.readFile` (vectors compiled into
Solidity would take minutes to build):

- `json`: documents full of edge tokens; CPython's strict `json` (no NaN or Infinity, no control
  characters in strings) decides whether each is an RFC 8259 object. Whatever `JsonScan.object`
  accepts, the oracle must accept.
- `utf8`: byte strings around every boundary lead and continuation byte, at every offset of a
  32-byte word; CPython's strict UTF-8 decoder decides. `Utf8.isValid` must agree exactly.
- `html`: scripts made of `<`, `/`, `!`, `-`, `</script` in any case, `<!--` and the like, with
  the output `HtmlScript.neutralize` must produce (a mirror of its documented rule). Before a
  vector is written, a transcription of the WHATWG tokenizer's script-data states (escaped and
  double-escaped included) checks that the page's `<script>` element, holding the output, ends
  exactly at the renderer's own `</script>`.
- `traits`: attribute names built from the renderer's own trait names in other cases and
  spacings, look-alike characters, escapes and word-boundary lengths; the rule (printable ASCII,
  no backslash, no two spaces in a row, not a reserved name once lowered and stripped of spaces)
  decides whether a record with that `trait_type` is accepted.

    python -m tools.content.oracles --write   # regenerate the fixtures
    python -m tools.content.oracles --check   # fail if a committed fixture is stale

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "test" / "fixtures" / "oracles"
SEED = 6529
BS = chr(92)


# ------------------------------------------------------------------------------------- json

JSON_ATOMS = [
    "0", "-0", "1", "-1", "01", "1.", ".5", "1.5", "1e5", "1E+05", "1e-5", "1e", "1e+", "-",
    "1.5e999", "12345678901234567890123", "123456789012345678901234567", "true", "false", "null",
    "tru", "nul", "NaN", "Infinity", '"a"', '""',
    '"' + BS + '""', '"' + BS + BS + '"', '"' + BS + '/"', '"' + BS + 'b"',
    '"' + BS + 'u0041"', '"' + BS + 'u0000"', '"' + BS + 'ud83d' + BS + 'ude00"',
    '"' + BS + 'ud83d"', '"' + BS + 'ude00"', '"' + BS + 'uZZZZ"', '"' + BS + 'x41"',
    '"' + BS + 'a"', '"a' + chr(9) + 'b"', '"a' + chr(10) + 'b"', '"' + chr(0xE9) + '"',
    '"' + chr(0x2028) + '"', '"%#"', "[]", "{}", "[1,]", "[,1]", '{"a":1,}', "{,}", "[1 2]",
    '{"a" 1}', '{"a":}', "{'a':1}", '"' + chr(0x7F) + '"', '"' + chr(0x1F) + '"',
]
JSON_KEYS = ["k", "name", "a", "n" + BS + "u0061me"]


def _no_constant(_: str) -> None:
    raise ValueError("constant")


def _strict(text: str):
    return json.loads(text, parse_constant=_no_constant)


def _strict_atom(atom: str) -> bool:
    try:
        _strict('{"k":' + atom + "}")
        return True
    except ValueError:
        return False


def json_vectors(count: int = 1000) -> list[tuple[bytes, bool]]:
    rng = random.Random(SEED)
    good = [a for a in JSON_ATOMS if _strict_atom(a)]

    def ws() -> str:
        if rng.random() < 0.03:
            return rng.choice([chr(11), chr(12), chr(0xA0)])
        return rng.choice(["", "", "", " ", chr(9), chr(10), chr(13)])

    def value(depth: int) -> str:
        r = rng.random()
        if depth > 0 and r < 0.2:
            inner = ",".join(value(depth - 1) for _ in range(rng.randint(0, 3)))
            return "[" + ws() + inner + ws() + "]"
        if depth > 0 and r < 0.4:
            members = [
                ws() + '"' + rng.choice(JSON_KEYS) + '"' + ws() + ":" + ws() + value(depth - 1)
                for _ in range(rng.randint(0, 3))
            ]
            return "{" + ",".join(members) + "}"
        return rng.choice(JSON_ATOMS) if rng.random() < 0.12 else rng.choice(good)

    def document() -> bytes:
        members = [
            ws() + '"' + rng.choice(["name", "x", "y", "n" + BS + "u0061me"]) + '"'
            + ws() + ":" + ws() + value(3) + ws()
            for _ in range(rng.randint(0, 4))
        ]
        text = ws() + "{" + ",".join(members) + "}" + ws()
        if rng.random() < 0.03:
            text += rng.choice([",", "}", "x", "{}"])
        return text.encode("utf-8")

    def accepted(doc: bytes) -> bool:
        try:
            return isinstance(_strict(doc.decode("utf-8")), dict)
        except ValueError:
            return False

    out: list[tuple[bytes, bool]] = []
    seen: set[bytes] = set()
    while len(out) < count:
        doc = document()
        if doc in seen or len(doc) > 400:
            continue
        seen.add(doc)
        out.append((doc, accepted(doc)))
    return out


# ------------------------------------------------------------------------------------- utf8

UTF8_BYTES = [0x00, 0x09, 0x22, 0x5C, 0x61, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1,
              0xC2, 0xDF, 0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xFF]
UTF8_SEQUENCES = [b"a", "é".encode(), "ࠀ".encode(), "퟿".encode(),
                  "".encode(), "￿".encode(), "\U00010000".encode(),
                  "\U0010ffff".encode(), " ".encode()]


def utf8_vectors(count: int = 600) -> list[tuple[bytes, bool]]:
    rng = random.Random(SEED)

    def sample() -> bytes:
        out = bytearray(b"a" * rng.choice([0, 1, 7, 8, 9, 28, 29, 30, 31, 32, 33, 60, 61, 62, 63]))
        for _ in range(rng.randint(0, 12)):
            r = rng.random()
            if r < 0.45:
                out += rng.choice(UTF8_SEQUENCES)
            elif r < 0.85:
                out.append(rng.choice(UTF8_BYTES))
            else:
                out += b"a" * rng.randint(1, 40)
        if rng.random() < 0.3 and out:
            out = out[: rng.randint(0, len(out))]
        return bytes(out)

    out: list[tuple[bytes, bool]] = []
    seen: set[bytes] = set()
    while len(out) < count:
        s = sample()
        if s in seen:
            continue
        seen.add(s)
        try:
            s.decode("utf-8", "strict")
            ok = True
        except UnicodeDecodeError:
            ok = False
        out.append((s, ok))
    return out


# ------------------------------------------------------------------------------------- html

HTML_WS = {0x09, 0x0A, 0x0C, 0x20}
SHELL_TAIL = b"</script></body></html>"
HTML_PIECES = [b"<", b"/", b"!", b"-", b"--", b">", b"<!--", b"-->", b"</script", b"</SCRIPT",
               b"</ScRiPt", b"<script", b"<SCRIPT", b"script", b"scrip", b"</scrip", b" ", b"\t",
               b"\n", b"\x0c", b"a", b"x", b"\\", b"<!-", b"<<", b"</", b"</script>",
               b"<!---->", b"<script>", b"<script ", b"</script ", b"</script/", b'"', b"'",
               b"`", b"\r"]


def _alpha(c: int) -> bool:
    return 0x41 <= c <= 0x5A or 0x61 <= c <= 0x7A


def _lower(c: int) -> int:
    return c + 0x20 if 0x41 <= c <= 0x5A else c


def neutralize(js: bytes) -> bytes:
    """`HtmlScript.neutralize`'s documented rule: a backslash after the `<` of every `<!--` and
    of every `</script` in any case with all 8 bytes in the input."""
    out = bytearray()
    for i, c in enumerate(js):
        out.append(c)
        if c != 0x3C:
            continue
        if js[i:i + 4] == b"<!--":
            out.append(0x5C)
        elif len(js) - i >= 8 and js[i + 1] == 0x2F and bytes(
            _lower(b) for b in js[i + 2:i + 8]
        ) == b"script":
            out.append(0x5C)
    return bytes(out)


def close_position(text: bytes):
    """Where, in the text after `<script>`, the end tag that closes the element starts (the
    WHATWG tokenizer's script-data states, 13.2.5.4 to 13.2.5.20), or None if it never closes."""
    state, tmp, start, lt, i = "data", bytearray(), None, 0, 0
    while i < len(text):
        c = text[i]
        if state == "data":
            if c == 0x3C:
                state, lt = "lt", i
        elif state == "lt":
            if c == 0x2F:
                tmp, state, start = bytearray(), "endopen", lt
            elif c == 0x21:
                state = "escstart"
            else:
                state = "data"
                continue
        elif state in ("endopen", "escendopen"):
            back = "data" if state == "endopen" else "esc"
            state = ("endname" if state == "endopen" else "escendname") if _alpha(c) else back
            continue
        elif state in ("endname", "escendname"):
            back = "data" if state == "endname" else "esc"
            if c in HTML_WS or c in (0x2F, 0x3E):
                if bytes(tmp) == b"script":
                    return start
                state = back
                continue
            if _alpha(c):
                tmp.append(_lower(c))
            else:
                state = back
                continue
        elif state == "escstart":
            if c == 0x2D:
                state = "escstartdash"
            else:
                state = "data"
                continue
        elif state == "escstartdash":
            if c == 0x2D:
                state = "escdashdash"
            else:
                state = "data"
                continue
        elif state in ("esc", "escdash", "escdashdash"):
            if c == 0x2D:
                state = {"esc": "escdash", "escdash": "escdashdash"}.get(state, state)
            elif c == 0x3C:
                state, lt = "esclt", i
            elif c == 0x3E and state == "escdashdash":
                state = "data"
            elif state != "esc":
                state = "esc"
        elif state == "esclt":
            if c == 0x2F:
                tmp, state, start = bytearray(), "escendopen", lt
            elif _alpha(c):
                tmp, state = bytearray(), "dblstart"
                continue
            else:
                state = "esc"
                continue
        elif state in ("dblstart", "dblend"):
            if c in HTML_WS or c in (0x2F, 0x3E):
                if state == "dblstart":
                    state = "dbl" if bytes(tmp) == b"script" else "esc"
                else:
                    state = "esc" if bytes(tmp) == b"script" else "dbl"
            elif _alpha(c):
                tmp.append(_lower(c))
            else:
                state = "esc" if state == "dblstart" else "dbl"
                continue
        elif state in ("dbl", "dbldash", "dbldashdash"):
            if c == 0x2D:
                state = {"dbl": "dbldash", "dbldash": "dbldashdash"}.get(state, state)
            elif c == 0x3C:
                state = "dbllt"
            elif c == 0x3E and state == "dbldashdash":
                state = "data"
            elif state != "dbl":
                state = "dbl"
        elif state == "dbllt":
            if c == 0x2F:
                tmp, state = bytearray(), "dblend"
            else:
                state = "dbl"
                continue
        i += 1
    return None


def _lf(b: bytes) -> bytes:
    return b.replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def html_vectors(count: int = 600) -> list[tuple[bytes, bytes]]:
    rng = random.Random(SEED)
    out: list[tuple[bytes, bytes]] = []
    early = 0
    while len(out) < count:
        js = b"".join(rng.choice(HTML_PIECES) for _ in range(rng.randint(0, 14)))
        safe = neutralize(js)
        # The page holds `<script>` + safe + SHELL_TAIL; CR becomes LF before tokenizing.
        if close_position(_lf(safe + SHELL_TAIL)) != len(_lf(safe)):
            raise AssertionError(f"the element does not close at the renderer's tag: {js!r}")
        if close_position(_lf(js + SHELL_TAIL)) not in (None, len(_lf(js))):
            early += 1
        out.append((js, safe))
    if early == 0:
        raise AssertionError("the tokenizer check is vacuous: no raw script closes early")
    return out


# ----------------------------------------------------------------------------------- traits

RESERVED = ["Artist", "Artist ID", "Year", "Medium", "Dimensions", "Collection", "Serial",
            "Edition of", "Seed", "Dispute statement"]
RESERVED_SKELETONS = {r.replace(" ", "").lower() for r in RESERVED}
TRAIT_PIECES = ["a", "Z", "k", "7", "-", "_", ".", "#", "%", "'", "(", ")", "/", ":", "~",
                "@", "[", "]", "^", "`", "{", "}", "|", " ", "  ", BS + BS, BS + "u0041",
                BS + "n", " ", "​", "е", "é", "色", "\U0001f600",
                "\u007f", "Seed", "Year", "Artist", "ID", "Edition", "of", "Dispute",
                "statement", "Serial", "Medium"]


def trait_accepted(name: str) -> bool:
    """The rule: printable ASCII without a backslash, no two spaces in a row, and not one of the
    renderer's own names once lowered and stripped of spaces."""
    raw = name.encode("utf-8")
    if any(b < 0x20 or b > 0x7E or b == 0x5C for b in raw) or b"  " in raw:
        return False
    return raw.replace(b" ", b"").lower().decode("ascii") not in RESERVED_SKELETONS


def _spaced(rng: random.Random, name: str) -> str:
    letters = name.replace(" ", "")
    out = ""
    for i, ch in enumerate(letters):
        if i and rng.random() < 0.3:
            out += rng.choice([" ", " ", "  "])
        out += ch.upper() if rng.random() < 0.5 else ch.lower()
    edge = rng.random()
    return (" " + out) if edge < 0.15 else (out + " ") if edge < 0.3 else out


def trait_vectors(count: int = 600) -> list[tuple[bytes, bool]]:
    rng = random.Random(SEED)
    out: list[tuple[bytes, bool]] = []
    seen: set[str] = set()
    while len(out) < count:
        r = rng.random()
        if r < 0.35:
            name = _spaced(rng, rng.choice(RESERVED))
            if rng.random() < 0.2:
                at = rng.randint(0, len(name))
                name = name[:at] + rng.choice([" ", "​", "е", "\u007f", "x"]) + name[at:]
        elif r < 0.55:
            # Lengths around the word boundaries the check works in (content bytes 30 to 35, 62
            # to 66), with a space, two spaces or a non-ASCII byte placed anywhere.
            length = rng.choice([1, 2, 30, 31, 32, 33, 34, 35, 62, 63, 64, 65, 66])
            chars = [rng.choice("abcXYZ019-") for _ in range(length)]
            mark = rng.choice([" ", "  ", "é", "\u007f", BS + BS, "a"])
            at = rng.randint(0, length)
            name = "".join(chars[:at]) + mark + "".join(chars[at:])
        else:
            name = "".join(rng.choice(TRAIT_PIECES) for _ in range(rng.randint(0, 8)))
        if name in seen:
            continue
        seen.add(name)
        out.append((name.encode("utf-8"), trait_accepted(name)))
    return out


# ------------------------------------------------------------------------------------- files

def _hex(b: bytes) -> str:
    return "0x" + b.hex()


def render(name: str) -> str:
    if name == "html":
        pairs = html_vectors()
        doc = {"input": [_hex(a) for a, _ in pairs], "expected": [_hex(b) for _, b in pairs]}
    else:
        pairs = {"json": json_vectors, "utf8": utf8_vectors, "traits": trait_vectors}[name]()
        doc = {"input": [_hex(a) for a, _ in pairs], "expected": [ok for _, ok in pairs]}
    return json.dumps(doc, indent=0) + "\n"


NAMES = ("json", "utf8", "html", "traits")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m tools.content.oracles")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="regenerate the fixtures")
    mode.add_argument("--check", action="store_true", help="fail if a fixture is stale")
    args = parser.parse_args(argv)
    stale = []
    for name in NAMES:
        path = FIXTURES / f"{name}.json"
        text = render(name)
        if args.write:
            FIXTURES.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8", newline="\n")
        elif not path.exists() or path.read_text(encoding="utf-8") != text:
            stale.append(str(path.relative_to(ROOT)))
    if stale:
        print("stale oracle fixtures: " + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
