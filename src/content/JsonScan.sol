// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title JsonScan
/// @notice A strict JSON (RFC 8259) scanner over memory. It validates what it reads and reports
///         where each value sits, so the caller can copy a validated span verbatim; it never
///         decodes a value.
/// @dev A span is `start << 128 | end` (end exclusive) over the scanned bytes; zero means absent.
///      Strings are checked for control bytes and escapes (`\u` needs four hex digits), numbers
///      against the JSON grammar. The caller checks UTF-8 separately (`Utf8`). Nesting is capped
///      at `MAX_DEPTH`. Only the members and elements the caller asks about are collected; every
///      other value is validated and skipped. Duplicate keys of a requested member are rejected.
///      Any violation reverts with `JsonInvalid`, and a caller that sets a `max` number of
///      elements gets the same error for one more. The cost is linear: whole 32-byte words of
///      string with no quote, backslash or control byte are skipped at once, so a long plain string
///      costs about 5 gas a byte, and a value about 3,000.
library JsonScan {
    /// @notice The text is not well-formed JSON, nests too deep, or has too many elements.
    error JsonInvalid();

    uint256 internal constant MAX_DEPTH = 8;
    uint256 private constant ONES =
        0x0101010101010101010101010101010101010101010101010101010101010101;
    uint256 private constant LOW7 =
        0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f;
    uint256 private constant HIGH =
        0x8080808080808080808080808080808080808080808080808080808080808080;

    /// @notice Validates `json` as one JSON object and returns the span of the value of each of
    ///         `keys` (hashes of the key text without quotes), in order.
    function object(bytes memory json, bytes32[] memory keys)
        internal
        pure
        returns (uint256[] memory spans)
    {
        uint256 end;
        (end, spans) = _object(json, _ws(json, 0), keys, MAX_DEPTH);
        if (_ws(json, end) != json.length) revert JsonInvalid();
    }

    /// @notice The spans of the elements of the array whose value starts at `start`, at most `max`.
    function elements(bytes memory json, uint256 start, uint256 max)
        internal
        pure
        returns (uint256[] memory spans)
    {
        (, spans) = _array(json, start, max, MAX_DEPTH);
    }

    /// @notice A copy of the bytes of `span`.
    function slice(bytes memory json, uint256 span) internal pure returns (bytes memory out) {
        uint256 start = span >> 128;
        uint256 length = (span & type(uint128).max) - start;
        out = new bytes(length);
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(json, 0x20), start), length)
        }
    }

    function _object(bytes memory j, uint256 i, bytes32[] memory keys, uint256 depth)
        private
        pure
        returns (uint256 end, uint256[] memory spans)
    {
        spans = new uint256[](keys.length);
        if (_byte(j, i) != "{") revert JsonInvalid();
        i = _ws(j, i + 1);
        if (_byte(j, i) == "}") return (i + 1, spans);
        for (;;) {
            uint256 key = i;
            i = _string(j, i);
            bytes32 hash;
            assembly ("memory-safe") {
                hash := keccak256(add(add(j, 0x21), key), sub(sub(i, key), 2))
            }
            i = _ws(j, i);
            if (_byte(j, i) != ":") revert JsonInvalid();
            i = _ws(j, i + 1);
            uint256 value = i;
            i = _value(j, i, depth);
            for (uint256 k; k < keys.length; ++k) {
                if (keys[k] != hash) continue;
                if (spans[k] != 0) revert JsonInvalid();
                spans[k] = (value << 128) | i;
            }
            i = _ws(j, i);
            bytes1 c = _byte(j, i++);
            if (c == "}") return (i, spans);
            if (c != ",") revert JsonInvalid();
            i = _ws(j, i);
        }
    }

    /// @dev With `max` zero nothing is collected and the array may be any length.
    function _array(bytes memory j, uint256 i, uint256 max, uint256 depth)
        private
        pure
        returns (uint256 end, uint256[] memory spans)
    {
        spans = new uint256[](max);
        if (_byte(j, i) != "[") revert JsonInvalid();
        i = _ws(j, i + 1);
        uint256 count;
        if (_byte(j, i) == "]") {
            ++i;
        } else {
            for (;;) {
                uint256 value = i;
                i = _value(j, i, depth);
                if (max != 0) {
                    if (count == max) revert JsonInvalid();
                    spans[count] = (value << 128) | i;
                }
                ++count;
                i = _ws(j, i);
                bytes1 c = _byte(j, i++);
                if (c == "]") break;
                if (c != ",") revert JsonInvalid();
                i = _ws(j, i);
            }
        }
        // Cut the collected spans to the count; an uncollected (empty) array stays as it is.
        if (max != 0) {
            assembly ("memory-safe") {
                mstore(spans, count)
            }
        }
        return (i, spans);
    }

    function _value(bytes memory j, uint256 i, uint256 depth) private pure returns (uint256) {
        bytes1 c = _byte(j, i);
        if (c == '"') return _string(j, i);
        if (c == "{" || c == "[") {
            if (depth == 0) revert JsonInvalid();
            if (c == "[") (i,) = _array(j, i, 0, depth - 1);
            else (i,) = _object(j, i, new bytes32[](0), depth - 1);
            return i;
        }
        if (c == "t") return _word(j, i, "true");
        if (c == "f") return _word(j, i, "false");
        if (c == "n") return _word(j, i, "null");
        return _number(j, i);
    }

    function _word(bytes memory j, uint256 i, bytes memory word) private pure returns (uint256) {
        for (uint256 k; k < word.length; ++k) {
            if (_byte(j, i + k) != word[k]) revert JsonInvalid();
        }
        return i + word.length;
    }

    /// @dev `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
    function _number(bytes memory j, uint256 i) private pure returns (uint256) {
        if (_byte(j, i) == "-") ++i;
        i = _byte(j, i) == "0" ? i + 1 : _digits(j, i);
        if (i < j.length && j[i] == ".") i = _digits(j, i + 1);
        if (i < j.length && (j[i] == "e" || j[i] == "E")) {
            ++i;
            if (i < j.length && (j[i] == "+" || j[i] == "-")) ++i;
            i = _digits(j, i);
        }
        return i;
    }

    function _digits(bytes memory j, uint256 i) private pure returns (uint256 end) {
        end = i;
        while (end < j.length && j[end] >= "0" && j[end] <= "9") ++end;
        if (end == i) revert JsonInvalid();
    }

    /// @dev The index after the string that opens at `i`. Whole words with no quote, backslash
    ///      or control byte are skipped at once; the bytes of any other word are checked one by
    ///      one.
    function _string(bytes memory j, uint256 i) private pure returns (uint256 end) {
        if (_byte(j, i) != '"') revert JsonInvalid();
        assembly ("memory-safe") {
            // Index (0-31) of the first non-zero byte of the non-zero word m.
            function firstFlag(m) -> idx {
                if iszero(shr(128, m)) {
                    idx := 16
                    m := shl(128, m)
                }
                if iszero(shr(192, m)) {
                    idx := add(idx, 8)
                    m := shl(64, m)
                }
                if iszero(shr(224, m)) {
                    idx := add(idx, 4)
                    m := shl(32, m)
                }
                if iszero(shr(240, m)) {
                    idx := add(idx, 2)
                    m := shl(16, m)
                }
                if iszero(shr(248, m)) { idx := add(idx, 1) }
            }
            let base := add(j, 0x20)
            let limit := add(base, mload(j))
            let done := 0
            for { let p := add(base, add(i, 1)) } and(lt(p, limit), iszero(done)) { } {
                let wordEnd := add(p, 32)
                if iszero(lt(sub(limit, p), 32)) {
                    // Each of y, z, w has a zero byte exactly where the word has '"', '\' or a
                    // byte below 0x20; ((v & LOW7) + LOW7) | v has the top bit set in the others.
                    let x := mload(p)
                    let y := xor(x, mul(ONES, 0x22))
                    let z := xor(x, mul(ONES, 0x5c))
                    let w := and(x, mul(ONES, 0xe0))
                    let flags :=
                        and(
                            not(
                                and(
                                    and(
                                        or(add(and(y, LOW7), LOW7), y),
                                        or(add(and(z, LOW7), LOW7), z)
                                    ),
                                    or(add(and(w, LOW7), LOW7), w)
                                )
                            ),
                            HIGH
                        )
                    if iszero(flags) {
                        p := wordEnd
                        continue
                    }
                    // Jump to the first flagged byte; the rest of the word is checked bytewise.
                    p := add(p, firstFlag(flags))
                }
                if gt(wordEnd, limit) { wordEnd := limit }
                for { } and(lt(p, wordEnd), iszero(done)) { } {
                    let c := byte(0, mload(p))
                    p := add(p, 1)
                    if eq(c, 0x22) {
                        end := sub(p, base)
                        done := 1
                    }
                    if lt(c, 0x20) { done := 1 }
                    if eq(c, 0x5c) {
                        // An escape: one of ", \, /, b, f, n, r, t, or u and four hex digits.
                        let e := byte(0, mload(p))
                        let simple :=
                            or(
                                or(or(eq(e, 0x22), eq(e, 0x5c)), or(eq(e, 0x2f), eq(e, 0x62))),
                                or(or(eq(e, 0x66), eq(e, 0x6e)), or(eq(e, 0x72), eq(e, 0x74)))
                            )
                        switch and(simple, lt(p, limit))
                        case 1 { p := add(p, 1) }
                        default {
                            let ok := and(eq(e, 0x75), lt(add(p, 4), limit))
                            for { let k := 1 } and(ok, lt(k, 5)) { k := add(k, 1) } {
                                let d := byte(0, mload(add(p, k)))
                                ok := or(lt(sub(d, 0x30), 10), lt(sub(or(d, 0x20), 0x61), 6))
                            }
                            if iszero(ok) { done := 1 }
                            p := add(p, 5)
                        }
                    }
                }
            }
        }
        if (end == 0) revert JsonInvalid();
    }

    function _ws(bytes memory j, uint256 i) private pure returns (uint256) {
        assembly ("memory-safe") {
            let base := add(j, 0x20)
            for { let n := mload(j) } lt(i, n) { i := add(i, 1) } {
                let c := byte(0, mload(add(base, i)))
                // Space, tab, line feed, carriage return.
                if iszero(or(or(eq(c, 0x20), eq(c, 0x09)), or(eq(c, 0x0a), eq(c, 0x0d)))) {
                    break
                }
            }
        }
        return i;
    }

    function _byte(bytes memory j, uint256 i) private pure returns (bytes1 b) {
        if (i >= j.length) revert JsonInvalid();
        assembly ("memory-safe") {
            b := shl(248, byte(0, mload(add(add(j, 0x20), i))))
        }
    }
}
