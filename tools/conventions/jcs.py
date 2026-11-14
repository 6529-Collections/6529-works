"""RFC 8785 (JSON Canonicalization Scheme) in pure Python, and a strict JSON parser.

Convention documents are UTF-8 JSON in RFC 8785 canonical form (DCL-1), and the promise grade
names the SHA-256 of the card's canonical JSON (DCL-30). The rules implemented here:

- object members sorted by their names as UTF-16 code units, no whitespace anywhere;
- strings as ECMAScript `JSON.stringify` writes them: `"` and `\\` escaped, `\\b \\t \\n \\f \\r`
  for those controls, `\\u00xx` (lowercase hex) for the other controls below U+0020, every other
  character written as itself in UTF-8;
- numbers as ECMAScript `Number.prototype.toString` writes an IEEE 754 double, so `1.0` is `1`
  and `1e21` is `1e+21`; NaN and infinities are refused.

`parse` is the I-JSON reading RFC 8785 assumes: strict UTF-8 with no byte order mark, no
duplicate member names, no NaN or Infinity, and no lone surrogates.
"""

from __future__ import annotations

import json
import math
from decimal import Decimal
from typing import Any

from tools.content.errors import ToolError


class CanonicalJsonError(ToolError):
    """A value cannot be canonicalized, or bytes are not strict I-JSON."""


_ESCAPES = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r"}


def _string(text: str) -> str:
    out = ['"']
    for ch in text:
        if ch in _ESCAPES:
            out.append(_ESCAPES[ch])
        elif ch < " ":
            out.append(f"\\u{ord(ch):04x}")
        elif "\ud800" <= ch <= "\udfff":
            raise CanonicalJsonError("a string holds a lone surrogate, which UTF-8 cannot carry")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _number(value: int | float) -> str:
    """ECMAScript Number::toString of the double nearest `value`."""
    if isinstance(value, int):
        if abs(value) <= 2**53:
            return str(value)
        value = float(value)  # RFC 8785 numbers are doubles; a larger integer is rounded
    if math.isnan(value) or math.isinf(value):
        raise CanonicalJsonError("NaN and infinities have no JSON form")
    if value == 0:
        return "0"  # also -0
    sign = "-" if value < 0 else ""
    # repr gives the shortest digit string that round-trips, which is what ECMAScript uses.
    digits_tuple = Decimal(repr(abs(value))).as_tuple()
    digits = "".join(str(d) for d in digits_tuple.digits).rstrip("0") or "0"
    # value = 0.<digits> x 10^n
    n = len(digits_tuple.digits) + digits_tuple.exponent
    k = len(digits)
    if k <= n <= 21:
        body = digits + "0" * (n - k)
    elif 0 < n <= 21:
        body = digits[:n] + "." + digits[n:]
    elif -6 < n <= 0:
        body = "0." + "0" * (-n) + digits
    else:
        exponent = n - 1
        mark = "+" if exponent >= 0 else "-"
        mantissa = digits if k == 1 else digits[0] + "." + digits[1:]
        body = f"{mantissa}e{mark}{abs(exponent)}"
    return sign + body


def _utf16_key(name: str) -> bytes:
    try:
        return name.encode("utf-16-be")
    except UnicodeEncodeError:
        raise CanonicalJsonError("a member name holds a lone surrogate") from None


def _serialize(value: Any, out: list[str]) -> None:
    if value is None:
        out.append("null")
    elif value is True:
        out.append("true")
    elif value is False:
        out.append("false")
    elif isinstance(value, (int, float)):
        out.append(_number(value))
    elif isinstance(value, str):
        out.append(_string(value))
    elif isinstance(value, (list, tuple)):
        out.append("[")
        for i, item in enumerate(value):
            if i:
                out.append(",")
            _serialize(item, out)
        out.append("]")
    elif isinstance(value, dict):
        for key in value:
            if not isinstance(key, str):
                raise CanonicalJsonError("JSON member names are strings")
        out.append("{")
        for i, key in enumerate(sorted(value, key=_utf16_key)):
            if i:
                out.append(",")
            out.append(_string(key))
            out.append(":")
            _serialize(value[key], out)
        out.append("}")
    else:
        raise CanonicalJsonError(f"{type(value).__name__} has no JSON form")


def canonicalize(value: Any) -> bytes:
    """The RFC 8785 canonical UTF-8 bytes of a JSON value."""
    out: list[str] = []
    _serialize(value, out)
    return "".join(out).encode("utf-8")


def _no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, item in pairs:
        if key in result:
            raise CanonicalJsonError(f"duplicate member name {key!r}")
        result[key] = item
    return result


def _no_constant(name: str) -> Any:
    raise CanonicalJsonError(f"{name} is not JSON")


def parse(data: bytes) -> Any:
    """Parse strict I-JSON bytes: UTF-8 without a BOM, unique names, no NaN, no lone surrogates."""
    if data.startswith(b"\xef\xbb\xbf"):
        raise CanonicalJsonError("the document starts with a byte order mark")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CanonicalJsonError(f"not UTF-8: {exc.reason} at byte {exc.start}") from None
    try:
        value = json.loads(text, object_pairs_hook=_no_duplicates, parse_constant=_no_constant)
    except CanonicalJsonError:
        raise
    except ValueError as exc:
        raise CanonicalJsonError(f"not JSON: {exc}") from None
    canonicalize(value)  # refuses lone surrogates that escapes smuggled in
    return value


def is_canonical(data: bytes) -> bool:
    """Whether `data` is strict I-JSON already in RFC 8785 canonical form."""
    try:
        return canonicalize(parse(data)) == data
    except CanonicalJsonError:
        return False
