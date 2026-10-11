// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DataUri
/// @notice Percent-encoding for text placed in a non-base64 `data:` URI.
/// @dev In a `data:` URI the first `#` starts the fragment (the body ends there) and a `%`
///      starts an escape (a stray one makes percent-decoding fail). Escaping just those two
///      bytes keeps every other byte, including multi-byte UTF-8 and the quotes and braces of
///      JSON, as it is. The renderer applies this to every string it takes from a record. Whole
///      32-byte words with neither byte are skipped at once, so ordinary text costs about 2 gas
///      a byte.
library DataUri {
    uint256 private constant ONES =
        0x0101010101010101010101010101010101010101010101010101010101010101;
    uint256 private constant LOW7 =
        0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f;
    uint256 private constant HIGH =
        0x8080808080808080808080808080808080808080808080808080808080808080;

    /// @notice Replaces every `%` with `%25` and every `#` with `%23`. An input with neither is
    ///         returned as the same memory reference. An input with more than `maxHits` of them
    ///         gives `ok` false (and the input itself): each hit costs about 200 gas, so a caller
    ///         that takes untrusted text bounds its cost here.
    function escape(string memory value, uint256 maxHits)
        internal
        pure
        returns (bool ok, string memory out)
    {
        assembly ("memory-safe") {
            // Walks [start, end) and returns the number of `%` and `#`; when dst is non-zero it
            // also writes the escaped text there.
            function walk(start, end, dst, max) -> hits {
                let run := start
                for { let p := start } lt(p, end) { } {
                    let wordEnd := add(p, 32)
                    if iszero(lt(sub(end, p), 32)) {
                        // A zero byte of a or b marks a '%' or a '#'; the others have the top
                        // bit set in ((v & LOW7) + LOW7) | v.
                        let x := mload(p)
                        let a := xor(x, mul(ONES, 0x25))
                        let b := xor(x, mul(ONES, 0x23))
                        let zero :=
                            and(
                                not(
                                    and(
                                        or(add(and(a, LOW7), LOW7), a),
                                        or(add(and(b, LOW7), LOW7), b)
                                    )
                                ),
                                HIGH
                            )
                        if iszero(zero) {
                            p := wordEnd
                            continue
                        }
                    }
                    if gt(wordEnd, end) { wordEnd := end }
                    for { } lt(p, wordEnd) { p := add(p, 1) } {
                        let c := byte(0, mload(p))
                        if or(eq(c, 0x25), eq(c, 0x23)) {
                            hits := add(hits, 1)
                            // Too many: stop counting, the caller refuses the text.
                            if gt(hits, max) {
                                p := end
                                wordEnd := end
                            }
                            if dst {
                                mcopy(dst, run, sub(p, run))
                                dst := add(dst, sub(p, run))
                                mstore8(dst, 0x25)
                                mstore8(add(dst, 1), 0x32)
                                // '5' for %25, '3' for %23.
                                mstore8(add(dst, 2), 0x35)
                                if eq(c, 0x23) { mstore8(add(dst, 2), 0x33) }
                                dst := add(dst, 3)
                                run := add(p, 1)
                            }
                        }
                    }
                }
                if dst { mcopy(dst, run, sub(end, run)) }
            }

            let start := add(value, 0x20)
            let end := add(start, mload(value))
            out := value
            let hits := walk(start, end, 0, maxHits)
            ok := iszero(gt(hits, maxHits))
            if and(ok, gt(hits, 0)) {
                let length := add(mload(value), mul(hits, 2))
                out := mload(0x40)
                mstore(out, length)
                let words := and(add(length, 31), not(31))
                mstore(add(out, words), 0) // zero the final word's padding
                mstore(0x40, add(add(out, 0x20), words))
                pop(walk(start, end, add(out, 0x20), maxHits))
            }
        }
    }
}
