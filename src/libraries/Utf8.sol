// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Utf8
/// @notice RFC 3629 UTF-8 validation, whole-buffer or streamed across chunks.
/// @dev Rejects overlong forms (C0, C1, E0 80-9F, F0 80-8F), UTF-16 surrogates (ED A0-BF),
///      code points above U+10FFFF (F4 90-BF, F5-FF), stray continuation bytes and truncated
///      sequences. Ported from 6529Stream PR #744's `StreamStaticText.isValidUtf8` (word-skip over ASCII)
///      and `StreamScriptBundles._utf8` (state carried across chunk boundaries).
///
///      Each code point is checked from one word load; ASCII runs are skipped a word at a time, and
///      the common two- and three-byte sequences take a shorter path (about a quarter of the gas
///      of the general one, which checks every lead byte's special range).
///      A stream state is 0 at a code-point boundary. Otherwise it packs the partial sequence
///      as `remaining | lo << 8 | hi << 16`: the number of continuation bytes still due and the
///      inclusive range allowed for the next one. Pass only 0 or a state returned by
///      {validate}; states that cannot be well-formed are rejected.
library Utf8 {
    /// @dev 0x01 and 0x80 in every byte, for word-at-a-time byte tests.
    uint256 private constant ONES =
        0x0101010101010101010101010101010101010101010101010101010101010101;
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
                    // ASCII: skip whole ASCII words, stopping at the first non-ASCII byte.
                    p := add(p, 1)
                    for { } iszero(lt(sub(end, p), 32)) { p := add(p, 32) } {
                        let m := and(mload(p), HIGH)
                        if m {
                            p := add(p, firstFlag(m))
                            break
                        }
                    }
                    continue
                }
                // The common cases first, a sequence of two bytes (C2-DF) or three (E1-EC, EE-EF)
                // that ends inside the chunk, whose continuations take the plain range 80-BF.
                if and(lt(sub(c, 0xc2), 0x1e), lt(add(p, 1), end)) {
                    if lt(sub(byte(1, w), 0x80), 0x40) {
                        p := add(p, 2)
                        continue
                    }
                }
                if and(lt(sub(c, 0xe1), 0x0f), and(iszero(eq(c, 0xed)), lt(add(p, 2), end))) {
                    if and(lt(sub(byte(1, w), 0x80), 0x40), lt(sub(byte(2, w), 0x80), 0x40)) {
                        p := add(p, 3)
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
                    // The whole sequence is in this chunk: check it from the one word.
                    let bits := shl(3, n)
                    let cont := and(shr(sub(248, bits), w), sub(shl(bits, 1), 1))
                    let ones := shr(sub(256, bits), ONES)
                    let first := shr(sub(bits, 8), cont)
                    ok := and(
                        eq(and(cont, mul(0xc0, ones)), mul(0x80, ones)),
                        and(iszero(lt(first, lo)), iszero(gt(first, hi)))
                    )
                    p := add(p, add(n, 1))
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
