// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DataUri
/// @notice Percent-encoding for text placed in a non-base64 `data:` URI.
/// @dev In a `data:` URI the first `#` starts the fragment (the body ends there) and a `%`
///      starts an escape (a stray one makes percent-decoding fail). Escaping just those two
///      bytes keeps every other byte, including multi-byte UTF-8 and the quotes and braces of
///      JSON, as it is. The renderer applies this to every string it takes from a record. The
///      text is scanned a 32-byte word at a time: a word with neither byte costs about 5 gas a
///      byte to count, a hit about 600 gas more to write, wherever the hits are.
library DataUri {
    uint256 private constant ONES =
        0x0101010101010101010101010101010101010101010101010101010101010101;
    uint256 private constant LOW7 =
        0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f;
    uint256 private constant HIGH =
        0x8080808080808080808080808080808080808080808080808080808080808080;

    /// @notice Replaces every `%` with `%25` and every `#` with `%23`. An input with neither is
    ///         returned as the same memory reference. An input with more than `maxHits` of them
    ///         gives `ok` false (and the input itself) after a count that costs about 7 gas a
    ///         byte, so a caller that takes untrusted text bounds the cost of the writes here
    ///         (each hit costs about 470 gas).
    function escape(string memory value, uint256 maxHits)
        internal
        pure
        returns (bool ok, string memory out)
    {
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

            // 0x80 in each byte of the word at p that is '%' or '#', zero in the others (a or b has
            // a zero byte exactly at each, and ((v & LOW7) + LOW7) | v has the top bit set in the
            // others); the bytes at and after `end` do not count.
            function marks(p, end) -> z {
                let x := mload(p)
                let a := xor(x, mul(ONES, 0x25))
                let b := xor(x, mul(ONES, 0x23))
                z := and(
                    not(and(or(add(and(a, LOW7), LOW7), a), or(add(and(b, LOW7), LOW7), b))),
                    HIGH
                )
                if lt(sub(end, p), 32) { z := and(z, not(shr(shl(3, sub(end, p)), not(0)))) }
            }

            let start := add(value, 0x20)
            let end := add(start, mload(value))
            out := value
            // Count the hits, about 7 gas a byte. A word's marks are 0x80 bytes, so shifting them
            // to 1 and taking the remainder by 255 adds the bytes (there are at most 32, and 256
            // is 1 modulo 255).
            let hits := 0
            let p := start
            for { } lt(p, end) { p := add(p, 32) } {
                hits := add(hits, mod(shr(7, marks(p, end)), 255))
            }
            ok := iszero(gt(hits, maxHits))
            if and(ok, gt(hits, 0)) {
                let length := add(mload(value), mul(hits, 2))
                out := mload(0x40)
                mstore(out, length)
                let words := and(add(length, 31), not(31))
                mstore(add(out, words), 0) // zero the final word's padding
                mstore(0x40, add(add(out, 0x20), words))
                let dst := add(out, 0x20)
                // `run` is the start of the text not yet copied. Every hit copies the run before
                // it and writes the escape, jumping from hit to hit within a word.
                let run := start
                for { p := start } lt(p, end) { p := add(p, 32) } {
                    let z := marks(p, end)
                    for { } z { } {
                        let i := firstFlag(z)
                        let at := add(p, i)
                        mcopy(dst, run, sub(at, run))
                        dst := add(dst, sub(at, run))
                        mstore8(dst, 0x25)
                        mstore8(add(dst, 1), 0x32)
                        // '5' for %25, '3' for %23.
                        mstore8(add(dst, 2), 0x35)
                        if eq(byte(0, mload(at)), 0x23) { mstore8(add(dst, 2), 0x33) }
                        dst := add(dst, 3)
                        run := add(at, 1)
                        // Clear the flag of this byte (bit 255 - 8 * i).
                        z := xor(z, shl(sub(255, shl(3, i)), 1))
                    }
                }
                mcopy(dst, run, sub(end, run))
            }
        }
    }
}
