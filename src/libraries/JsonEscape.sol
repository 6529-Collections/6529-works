// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title JsonEscape
/// @notice Byte-exact escaping for JSON string values and for inline `<script>` text.
/// @dev Ported from 6529Stream PR #744's `StreamRenderContextV1.escape`/`scriptText`, keeping their output
///      byte for byte. Escaping preserves every other byte, including malformed UTF-8; validate
///      UTF-8 separately with `Utf8`. Inputs are never modified, and an input that needs no
///      change is returned as the same memory reference. Each encoder walks the input twice
///      (count, then write): it skips whole 32-byte words that hold nothing to escape and
///      jumps straight to the first byte that may. Byte reads may load memory past the
///      input's end; only bytes inside the input are used.
library JsonEscape {
    /// @dev Bit b is set when byte b needs escaping: 0x00-0x1f, '"', '<', '\' and 0xe2 (the
    ///      lead byte of U+2028/U+2029, which is escaped only when the full sequence follows).
    uint256 private constant SPECIAL = 0x4000000000000000000000000000000001000000010000004ffffffff;

    /// @dev 0x01, 0x7f and 0x80 in every byte, for word-at-a-time byte tests.
    uint256 private constant ONES =
        0x0101010101010101010101010101010101010101010101010101010101010101;
    uint256 private constant LOW7 =
        0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f;
    uint256 private constant HIGH =
        0x8080808080808080808080808080808080808080808080808080808080808080;

    /// @notice Escapes `value` for use inside a JSON string literal.
    /// @dev Double quote and backslash gain a leading backslash; bytes below 0x20 and `<`
    ///      become a backslash, `u00` and two lowercase hex digits, so the result is also safe
    ///      inside an HTML `<script>` element; U+2028 and U+2029 (`e2 80 a8`, `e2 80 a9`)
    ///      become a backslash, `u202` and `8` or `9`, for JavaScript string compatibility.
    function escape(string memory value) internal pure returns (string memory out) {
        assembly ("memory-safe") {
            // Index (0-31) of the first non-zero byte of the non-zero word m.
            function firstFlag(m) -> i {
                if iszero(shr(128, m)) {
                    i := 16
                    m := shl(128, m)
                }
                if iszero(shr(192, m)) {
                    i := add(i, 8)
                    m := shl(64, m)
                }
                if iszero(shr(224, m)) {
                    i := add(i, 4)
                    m := shl(32, m)
                }
                if iszero(shr(240, m)) {
                    i := add(i, 2)
                    m := shl(16, m)
                }
                if iszero(shr(248, m)) { i := add(i, 1) }
            }
            // Walks [start, end) and returns the number of extra output bytes; when dst is
            // non-zero it also writes the escaped output there.
            function walk(start, end, dst) -> extra {
                let run := start
                for { let p := start } lt(p, end) { } {
                    // Jump to the first special byte of a full word, or past a clean word.
                    if iszero(lt(sub(end, p), 32)) {
                        // For each class, y has a zero byte exactly where x matches, and
                        // ((y & LOW7) + LOW7) | y clears that byte's top bit, with no carry
                        // between bytes. So m flags (0x80) exactly the special bytes.
                        let x := mload(p)
                        let y := and(x, mul(ONES, 0xe0)) // zero iff the byte is below 0x20
                        let a := or(add(and(y, LOW7), LOW7), y)
                        y := xor(x, mul(ONES, 0x22))
                        a := and(a, or(add(and(y, LOW7), LOW7), y))
                        y := xor(x, mul(ONES, 0x5c))
                        a := and(a, or(add(and(y, LOW7), LOW7), y))
                        y := xor(x, mul(ONES, 0x3c))
                        a := and(a, or(add(and(y, LOW7), LOW7), y))
                        y := xor(x, mul(ONES, 0xe2))
                        a := and(a, or(add(and(y, LOW7), LOW7), y))
                        let m := and(not(a), HIGH)
                        if iszero(m) {
                            p := add(p, 32)
                            continue
                        }
                        p := add(p, firstFlag(m))
                    }
                    let b := byte(0, mload(p))
                    if iszero(and(shr(b, SPECIAL), 1)) {
                        p := add(p, 1)
                        continue
                    }
                    // 1: backslash + byte; 2: backslash-u00xx; 3: U+2028/U+2029 (3 bytes in).
                    let k := 2
                    if or(eq(b, 0x22), eq(b, 0x5c)) { k := 1 }
                    if eq(b, 0xe2) {
                        k := 0
                        if lt(add(p, 2), end) {
                            let c := byte(2, mload(p))
                            if and(eq(byte(1, mload(p)), 0x80), or(eq(c, 0xa8), eq(c, 0xa9))) {
                                k := 3
                            }
                        }
                    }
                    if iszero(k) {
                        p := add(p, 1)
                        continue
                    }
                    if dst {
                        mcopy(dst, run, sub(p, run))
                        dst := put(add(dst, sub(p, run)), k, p)
                    }
                    switch k
                    case 1 { extra := add(extra, 1) }
                    case 2 { extra := add(extra, 5) }
                    default {
                        extra := add(extra, 3)
                        p := add(p, 2)
                    }
                    p := add(p, 1)
                    run := p
                }
                if dst { mcopy(dst, run, sub(end, run)) }
            }
            // Writes the escape of class k for the input at p to dst; returns its end.
            function put(dst, k, p) -> next {
                let b := byte(0, mload(p))
                mstore8(dst, 0x5c)
                next := add(dst, 6)
                switch k
                case 1 {
                    mstore8(add(dst, 1), b)
                    next := add(dst, 2)
                }
                case 2 {
                    let digits := "0123456789abcdef"
                    mstore8(add(dst, 1), 0x75) // u
                    mstore8(add(dst, 2), 0x30)
                    mstore8(add(dst, 3), 0x30)
                    mstore8(add(dst, 4), byte(shr(4, b), digits))
                    mstore8(add(dst, 5), byte(and(b, 15), digits))
                }
                default {
                    mstore8(add(dst, 1), 0x75) // u
                    mstore8(add(dst, 2), 0x32)
                    mstore8(add(dst, 3), 0x30)
                    mstore8(add(dst, 4), 0x32)
                    mstore8(add(dst, 5), add(0x38, eq(byte(2, mload(p)), 0xa9)))
                }
            }

            let start := add(value, 0x20)
            let end := add(start, mload(value))
            out := value
            let extra := walk(start, end, 0)
            if extra {
                let length := add(mload(value), extra)
                out := mload(0x40)
                mstore(out, length)
                let words := and(add(length, 31), not(31))
                mstore(add(out, words), 0) // zero the final word's padding
                mstore(0x40, add(add(out, 0x20), words))
                pop(walk(start, end, add(out, 0x20)))
            }
        }
    }

    /// @notice Neutralizes HTML end tags in text placed inside a `<script>` element.
    /// @dev Every case-insensitive eight-byte `</script` prefix gains a backslash after its
    ///      `<`, with or without a following `>`. Valid JavaScript keeps its meaning inside
    ///      strings, template literals and comments.
    function scriptText(string memory value) internal pure returns (string memory out) {
        assembly ("memory-safe") {
            // Index (0-31) of the first non-zero byte of the non-zero word m.
            function firstFlag(m) -> i {
                if iszero(shr(128, m)) {
                    i := 16
                    m := shl(128, m)
                }
                if iszero(shr(192, m)) {
                    i := add(i, 8)
                    m := shl(64, m)
                }
                if iszero(shr(224, m)) {
                    i := add(i, 4)
                    m := shl(32, m)
                }
                if iszero(shr(240, m)) {
                    i := add(i, 2)
                    m := shl(16, m)
                }
                if iszero(shr(248, m)) { i := add(i, 1) }
            }
            // Walks [start, end) and returns the number of end tags; when dst is non-zero it
            // also writes the neutralized output there.
            function walk(start, end, dst) -> matches {
                let run := start
                for { let p := start } lt(p, end) { } {
                    // Jump to the first '<' of a full word, or past a word without one.
                    if iszero(lt(sub(end, p), 32)) {
                        // y has a zero byte exactly at each '<'; m flags exactly those bytes.
                        let y := xor(mload(p), mul(ONES, 0x3c))
                        let m := and(not(or(add(and(y, LOW7), LOW7), y)), HIGH)
                        if iszero(m) {
                            p := add(p, 32)
                            continue
                        }
                        p := add(p, firstFlag(m))
                    }
                    // Case-insensitive "</script" with all eight bytes inside the input:
                    // '<' and '/' exactly, the six letters with 0x20 OR-ed in.
                    let tag := 0
                    if iszero(lt(sub(end, p), 8)) {
                        tag := eq(or(shr(192, mload(p)), 0x0000202020202020), 0x3c2f736372697074)
                    }
                    if iszero(tag) {
                        p := add(p, 1)
                        continue
                    }
                    if dst {
                        // Copy through the '<', then insert the backslash.
                        let n := add(sub(p, run), 1)
                        mcopy(dst, run, n)
                        mstore8(add(dst, n), 0x5c)
                        dst := add(dst, add(n, 1))
                    }
                    matches := add(matches, 1)
                    run := add(p, 1)
                    p := add(p, 8)
                }
                if dst { mcopy(dst, run, sub(end, run)) }
            }

            let start := add(value, 0x20)
            let end := add(start, mload(value))
            out := value
            let matches := walk(start, end, 0)
            if matches {
                let length := add(mload(value), matches)
                out := mload(0x40)
                mstore(out, length)
                let words := and(add(length, 31), not(31))
                mstore(add(out, words), 0) // zero the final word's padding
                mstore(0x40, add(add(out, 0x20), words))
                pop(walk(start, end, add(out, 0x20)))
            }
        }
    }
}
