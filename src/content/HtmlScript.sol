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
///      Limits, which artists need to know. The rewrite is exact where the sequences can occur in
///      well-formed JavaScript: inside strings, template literals and comments. Elsewhere it
///      changes the program: in a classic script (the page uses one, not a module) `<!--` starts a
///      single-line comment, so `a<!--b` is a comment to the browser and a syntax error here; and
///      a regular expression that contains `</script` (`x</script/i.test(s)`, a comparison with a
///      regular expression, for one) becomes a different expression. Write such code with the
///      sequence split (`"<" + "/script"`) and it passes through unchanged.
///
///      The text is scanned a 32-byte word at a time and the work is per `<`: a word without one
///      costs about 5 gas a byte, a `<` about 450 gas more, wherever it is. `JsonEscape.scriptText`
///      handles `</script` alone, in two passes that cost about 300 gas per byte on text made of
///      `<`. Because a script made of nothing but `<` would cost about 3.7M gas here for 8 KiB (7M
///      for 16), the caller gives a cap on the number of `<`, and the work stops when it is
///      passed.
library HtmlScript {
    uint256 private constant ONES =
        0x0101010101010101010101010101010101010101010101010101010101010101;
    uint256 private constant LOW7 =
        0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f;
    uint256 private constant HIGH =
        0x8080808080808080808080808080808080808080808080808080808080808080;

    /// @notice Inserts a backslash after the `<` of every `</script` (any case, with all eight
    ///         bytes inside the input) and every `<!--`. The input is not modified and the result
    ///         is a new string. A script with more than `maxLt` `<` bytes gives `ok` false and
    ///         the work stops there, so a caller that takes untrusted text bounds its cost here.
    function neutralize(string memory js, uint256 maxLt)
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

            out := mload(0x40)
            let lts := 0
            let dst := add(out, 0x20)
            let start := add(js, 0x20)
            let end := add(start, mload(js))
            // `run` is the start of the text not yet copied.
            let run := start
            for { let p := start } lt(p, end) { p := add(p, 32) } {
                // 0x80 in each byte of the word that is '<' (y has a zero byte exactly there, and
                // ((y & LOW7) + LOW7) | y has the top bit set in every other), but not at or
                // after `end`.
                let y := xor(mload(p), mul(ONES, 0x3c))
                let z := and(not(or(add(and(y, LOW7), LOW7), y)), HIGH)
                if lt(sub(end, p), 32) { z := and(z, not(shr(shl(3, sub(end, p)), not(0)))) }
                // Jump from `<` to `<` within the word.
                for { } z { } {
                    let i := firstFlag(z)
                    let at := add(p, i)
                    // Clear the flag of this byte (bit 255 - 8 * i).
                    z := xor(z, shl(sub(255, shl(3, i)), 1))
                    lts := add(lts, 1)
                    // Too many: stop; the caller refuses the script.
                    if gt(lts, maxLt) {
                        p := end
                        break
                    }
                    // "<!--", or "</script" with the six letters compared case-blind. The
                    // second byte picks the one test worth making.
                    let w := mload(at)
                    let second := byte(1, w)
                    let hit := 0
                    if eq(second, 0x21) {
                        hit := and(iszero(lt(sub(end, at), 4)), eq(shr(224, w), 0x3c212d2d))
                    }
                    if eq(second, 0x2f) {
                        hit := and(
                            iszero(lt(sub(end, at), 8)),
                            eq(or(shr(192, w), 0x0000202020202020), 0x3c2f736372697074)
                        )
                    }
                    if hit {
                        // Copy through the '<', then insert the backslash.
                        let n := add(sub(at, run), 1)
                        mcopy(dst, run, n)
                        mstore8(add(dst, n), 0x5c)
                        dst := add(dst, add(n, 1))
                        run := add(at, 1)
                    }
                }
            }
            ok := iszero(gt(lts, maxLt))
            if ok {
                mcopy(dst, run, sub(end, run))
                dst := add(dst, sub(end, run))
                mstore(out, sub(dst, add(out, 0x20)))
                mstore(dst, 0) // zero the final word's padding
                mstore(0x40, and(add(dst, 31), not(31)))
            }
        }
    }
}
