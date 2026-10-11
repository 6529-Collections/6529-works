// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HtmlScript
/// @notice Makes script text safe to place inside an HTML `<script>` element.
/// @dev Two byte sequences can end or confuse a script element: `</script` (any case), which
///      closes it, and `<!--`, which can start the parser's "double escaped" state so that the
///      next `</script>` no longer closes it. Each match gains a backslash after its `<`
///      (`<\/script`, `<\!--`), which keeps its meaning inside JavaScript strings, template
///      literals and comments, the only places the sequences can appear in valid code. Only
///      script text needs this: a document inlined as a base64 `data:` URI is never parsed
///      together with the renderer's own markup, and rewriting it would break it.
///
///      One pass, linear in every case. `JsonEscape.scriptText` handles `</script` alone, in two
///      passes that cost about 300 gas per byte on text made of `<` (this one costs about 40),
///      and the renderer's gas budget has to hold for any script.
library HtmlScript {
    uint256 private constant ONES =
        0x0101010101010101010101010101010101010101010101010101010101010101;
    uint256 private constant LOW7 =
        0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f;
    uint256 private constant HIGH =
        0x8080808080808080808080808080808080808080808080808080808080808080;

    /// @notice Inserts a backslash after the `<` of every `</script` (any case, with all eight
    ///         bytes inside the input) and every `<!--`. The input is not modified and the result
    ///         is a new string.
    function neutralize(string memory js) internal pure returns (string memory out) {
        assembly ("memory-safe") {
            out := mload(0x40)
            let dst := add(out, 0x20)
            let start := add(js, 0x20)
            let end := add(start, mload(js))
            let run := start
            for { let p := start } lt(p, end) { } {
                let wordEnd := add(p, 32)
                if iszero(lt(sub(end, p), 32)) {
                    // A full word with no '<' is skipped whole: y has a zero byte exactly at
                    // each '<', and ((y & LOW7) + LOW7) | y has the top bit set in every other.
                    let y := xor(mload(p), mul(ONES, 0x3c))
                    if iszero(and(not(or(add(and(y, LOW7), LOW7), y)), HIGH)) {
                        p := wordEnd
                        continue
                    }
                }
                if gt(wordEnd, end) { wordEnd := end }
                for { } lt(p, wordEnd) { p := add(p, 1) } {
                    let w := mload(p)
                    if eq(byte(0, w), 0x3c) {
                        // "<!--", or "</script" with the six letters compared case-blind. The
                        // second byte picks the one test worth making.
                        let second := byte(1, w)
                        let hit := 0
                        if eq(second, 0x21) {
                            hit := and(iszero(lt(sub(end, p), 4)), eq(shr(224, w), 0x3c212d2d))
                        }
                        if eq(second, 0x2f) {
                            hit := and(
                                iszero(lt(sub(end, p), 8)),
                                eq(or(shr(192, w), 0x0000202020202020), 0x3c2f736372697074)
                            )
                        }
                        if hit {
                            // Copy through the '<', then insert the backslash.
                            let n := add(sub(p, run), 1)
                            mcopy(dst, run, n)
                            mstore8(add(dst, n), 0x5c)
                            dst := add(dst, add(n, 1))
                            run := add(p, 1)
                        }
                    }
                }
            }
            mcopy(dst, run, sub(end, run))
            dst := add(dst, sub(end, run))
            mstore(out, sub(dst, add(out, 0x20)))
            mstore(dst, 0) // zero the final word's padding
            mstore(0x40, and(add(dst, 31), not(31)))
        }
    }
}
