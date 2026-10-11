// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Base64Validator
/// @notice Strict RFC 4648 section 4 alphabet check, 32 bytes per step. Internal, so nothing
///         here is linked.
/// @dev Each byte of a word is classified with carry-free arithmetic: once every byte is below
///      0x80, adding a constant of at most 0x55 to a byte stays under 0x100 and subtracting a byte
///      from a constant of at least 0xAE never borrows, so bit 7 of each byte reports a range
///      test independently of its neighbours. A byte is valid when it lies in `[0x2B, 0x7A]` and
///      outside the three gaps `[0x2C, 0x2E]`, `[0x3A, 0x40]` and `[0x5B, 0x60]`, which leaves
///      `+`, `/`, `0-9`, `A-Z` and `a-z`. A byte of 0x80 or more may carry into or borrow from
///      its neighbour, which is harmless because the word is rejected. It already fails its own
///      span test whatever its neighbours do, and the explicit bit-7 check is kept so that the
///      rejection does not rest on that argument alone.
library Base64Validator {
    /// @notice Whether the first `length` bytes of `data` are all in `[A-Za-z0-9+/]`. `=` is not
    ///         in the alphabet; the caller handles padding by excluding it from `length`.
    /// @dev Leaves memory as it found it. To check whole words it fills the bytes from `length`
    ///      to the next 32-byte boundary with "A", which can lie past the end of `data`: a
    ///      `bytes memory` from `new bytes(n)` or `abi.decode` is padded to a whole word, but one
    ///      from `abi.encodePacked` or `bytes.concat` is not, and the fill would then overwrite
    ///      the next object. So it saves the last word first and restores it afterwards, and
    ///      nothing else is written. `length` must not exceed `data.length`.
    function isAlphabet(bytes memory data, uint256 length) internal pure returns (bool) {
        uint256 bad;
        assembly ("memory-safe") {
            let p := add(data, 0x20)
            let end := add(p, length)
            // Fill the unused tail of the final word with "A" so whole words can be checked,
            // keeping the word to put back. `last` stays zero when there is no partial word.
            let last := 0
            let saved := 0
            {
                let rem := and(length, 31)
                if rem {
                    last := sub(end, rem)
                    saved := mload(last)
                    let keep := not(shr(shl(3, rem), not(0)))
                    mstore(
                        last,
                        or(
                            and(saved, keep),
                            and(
                                0x4141414141414141414141414141414141414141414141414141414141414141,
                                not(keep)
                            )
                        )
                    )
                    end := add(last, 32)
                }
            }
            for { } lt(p, end) { p := add(p, 32) } {
                let w := mload(p)
                // bit 7 of each byte: 0x2B <= b <= 0x7A
                let span :=
                    and(
                        add(w, 0x5555555555555555555555555555555555555555555555555555555555555555),
                        sub(0xfafafafafafafafafafafafafafafafafafafafafafafafafafafafafafafafa, w)
                    )
                // bit 7 of each byte: b is in one of the three gaps
                let gap :=
                    or(
                        or(
                            and(
                                add(
                                    w,
                                    0x5454545454545454545454545454545454545454545454545454545454545454
                                ),
                                sub(
                                    0xaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae,
                                    w
                                )
                            ),
                            and(
                                add(
                                    w,
                                    0x4646464646464646464646464646464646464646464646464646464646464646
                                ),
                                sub(
                                    0xc0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0,
                                    w
                                )
                            )
                        ),
                        and(
                            add(
                                w,
                                0x2525252525252525252525252525252525252525252525252525252525252525
                            ),
                            sub(
                                0xe0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0,
                                w
                            )
                        )
                    )
                let high := 0x8080808080808080808080808080808080808080808080808080808080808080
                // Rejected: a byte >= 0x80, or a byte not in the span, or a byte in a gap.
                bad := or(bad, or(and(w, high), xor(and(and(span, not(gap)), high), high)))
            }
            if last { mstore(last, saved) }
        }
        return bad == 0;
    }
}
