// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Utf8
/// @notice RFC 3629 UTF-8 validation, whole-buffer or streamed across chunks.
/// @dev Rejects overlong forms (C0, C1, E0 80-9F, F0 80-8F), UTF-16 surrogates (ED A0-BF),
///      code points above U+10FFFF (F4 90-BF, F5-FF), stray continuation bytes and truncated
///      sequences. Ported from 6529Stream PR #744's `StreamStaticText.isValidUtf8` (word-skip over
///      ASCII) and `StreamScriptBundles._utf8` (state carried across chunk boundaries).
///
///      Each code point is checked from one word load. ASCII is skipped a word at a time (a short
///      run bytewise, so text that alternates does not pay for a word each time), and every
///      well-formed sequence inside the chunk (two, three or four bytes, each lead with its own
///      second-byte range) takes one short path of about 100 to 400 gas. The general path below
///      handles only what those do not take: an ill-formed sequence, or one cut by the end of the
///      chunk, whose state it carries. The worst text costs about 140 gas a byte (ASCII and
///      multi-byte alternating); plain ASCII 3.
///      A stream state is 0 at a code-point boundary. Otherwise it packs the partial sequence
///      as `remaining | lo << 8 | hi << 16`: the number of continuation bytes still due and the
///      inclusive range allowed for the next one. Pass only 0 or a state returned by
///      {validate}; states that cannot be well-formed are rejected.
library Utf8 {
    /// @dev 0x80 in every byte, for word-at-a-time byte tests.
    uint256 private constant HIGH =
        0x8080808080808080808080808080808080808080808080808080808080808080;

    /// @notice Returns whether `data` is complete, well-formed UTF-8.
    function isValid(bytes memory data) internal pure returns (bool) {
        (bool ok, uint256 state) = validate(0, data);
        return ok && state == 0;
    }

    /// @notice Validates `chunk` as the continuation of a stream in `state`.
    /// @return ok False as soon as an ill-formed byte is found.
    /// @return next The state after `chunk` (0 when `ok` is false). A stream is complete and
    ///         valid only if every chunk returned `ok` and the final state is 0.
    function validate(uint256 state, bytes memory chunk)
        internal
        pure
        returns (bool ok, uint256 next)
    {
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
            // Checks due continuation bytes one at a time from p0, stopping at end.
            function carry(p0, end, due0, lo0, hi0) -> good, q, left, nextLo, nextHi {
                good := 1
                q := p0
                left := due0
                nextLo := lo0
                nextHi := hi0
                for { } and(good, and(gt(left, 0), lt(q, end))) { } {
                    let d := byte(0, mload(q))
                    good := and(iszero(lt(d, nextLo)), iszero(gt(d, nextHi)))
                    left := sub(left, 1)
                    nextLo := 0x80
                    nextHi := 0xbf
                    q := add(q, 1)
                }
            }

            let due := and(state, 0xff)
            let lo := and(shr(8, state), 0xff)
            let hi := shr(16, state)
            switch due
            case 0 { ok := iszero(state) }
            default {
                // A partial sequence needs at most three continuations in a sane range.
                ok := and(
                    lt(due, 4),
                    and(iszero(lt(lo, 0x80)), and(iszero(gt(hi, 0xbf)), iszero(gt(lo, hi))))
                )
            }

            let p := add(chunk, 0x20)
            let end := add(p, mload(chunk))
            // Finish a sequence carried in from the previous chunk.
            if and(ok, gt(due, 0)) { ok, p, due, lo, hi := carry(p, end, due, lo, hi) }
            // Loads below may read past the chunk; only bytes before `end` are used.
            for { } and(ok, lt(p, end)) { } {
                let w := mload(p)
                let c := byte(0, w)
                if lt(c, 0x80) {
                    p := add(p, 1)
                    // A lead byte next (text that alternates): no need to look further.
                    if gt(byte(1, w), 0x7f) { continue }
                    // A short run of ASCII is cheaper bytewise: up to 8 bytes, and then the rest a
                    // word at a time.
                    let short := add(p, 8)
                    for { } lt(p, short) { p := add(p, 1) } {
                        if or(iszero(lt(p, end)), gt(byte(0, mload(p)), 0x7f)) { break }
                    }
                    if lt(p, short) { continue }
                    // Skip whole ASCII words, stopping at the first non-ASCII byte.
                    for { } iszero(lt(sub(end, p), 32)) { p := add(p, 32) } {
                        let m := and(mload(p), HIGH)
                        if m {
                            p := add(p, firstFlag(m))
                            break
                        }
                    }
                    continue
                }
                // The common cases first, a whole sequence that ends inside the chunk: two bytes
                // (C2-DF), three (E0-EF) or four (F0-F4), checked from the one word. The second
                // byte has its lead's range (E0: A0-BF, ED: 80-9F, F0: 90-BF, F4: 80-8F), the
                // others 80-BF. What these do not take (invalid, or cut by the end of the chunk)
                // is left to the general path below.
                if and(lt(sub(c, 0xc2), 0x1e), lt(add(p, 1), end)) {
                    if lt(sub(byte(1, w), 0x80), 0x40) {
                        p := add(p, 2)
                        continue
                    }
                }
                if and(lt(sub(c, 0xe0), 0x10), lt(add(p, 2), end)) {
                    let l3 := 0x80
                    if eq(c, 0xe0) { l3 := 0xa0 }
                    let h3 := 0xbf
                    if eq(c, 0xed) { h3 := 0x9f }
                    let b3 := byte(1, w)
                    if and(
                        and(iszero(lt(b3, l3)), iszero(gt(b3, h3))),
                        lt(sub(byte(2, w), 0x80), 0x40)
                    ) {
                        p := add(p, 3)
                        continue
                    }
                }
                if and(lt(sub(c, 0xf0), 5), lt(add(p, 3), end)) {
                    let l4 := 0x80
                    if eq(c, 0xf0) { l4 := 0x90 }
                    let h4 := 0xbf
                    if eq(c, 0xf4) { h4 := 0x8f }
                    let b4 := byte(1, w)
                    if and(
                        and(iszero(lt(b4, l4)), iszero(gt(b4, h4))),
                        and(lt(sub(byte(2, w), 0x80), 0x40), lt(sub(byte(3, w), 0x80), 0x40))
                    ) {
                        p := add(p, 4)
                        continue
                    }
                }
                // A lead byte: n continuations, the first of them within [lo, hi].
                let n := 0
                lo := 0x80
                hi := 0xbf
                switch shr(4, c)
                case 0xc {
                    n := 1
                    ok := iszero(lt(c, 0xc2))
                }
                case 0xd { n := 1 }
                case 0xe {
                    n := 2
                    if eq(c, 0xe0) { lo := 0xa0 }
                    if eq(c, 0xed) { hi := 0x9f }
                }
                case 0xf {
                    n := 3
                    ok := lt(c, 0xf5)
                    if eq(c, 0xf0) { lo := 0x90 }
                    if eq(c, 0xf4) { hi := 0x8f }
                }
                default { ok := 0 } // 0x80-0xbf: a continuation byte without a lead
                if iszero(ok) { break }
                switch lt(add(p, n), end)
                case 1 {
                    // The whole sequence is in this chunk, and the paths above did not take it:
                    // a continuation is out of range.
                    ok := 0
                }
                default {
                    // The sequence runs past the chunk: check what is here, carry the rest.
                    ok, p, due, lo, hi := carry(add(p, 1), end, n, lo, hi)
                }
            }
            if ok {
                if due { next := or(due, or(shl(8, lo), shl(16, hi))) }
            }
        }
    }
}
