// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice 6529Stream PR #744 code copied verbatim from `smart-contracts/domains/metadata/StreamStaticText.sol` at
///         `origin/codex/v1-integration` (19432ea43). Test-only: proves byte parity with, and measures
///         gas against, the implementation the v1 library ports. Not formatted.
// forgefmt: disable-start
library Pr744Utf8 {
    function isValidUtf8(string memory raw) internal pure returns (bool valid) {
        // Each load stays inside the allocated string word; only the indexed byte is used.
        // Keep the original optimizer posture: enabling its optional memory guard enlarged
        // two measured products beyond EIP-170. The aligned reads are retained unchanged.
        assembly {
            let cursor := add(raw, 0x20)
            let end := add(cursor, mload(raw))
            valid := 1

            for { } lt(cursor, end) { cursor := add(cursor, 1) } {
                // ASCII bytes (including controls) are all valid UTF-8. Skip only a complete
                // in-bounds word; non-ASCII words retain the original byte validator below.
                if iszero(lt(sub(end, cursor), 32)) {
                    if iszero(
                        and(
                            mload(cursor),
                            0x8080808080808080808080808080808080808080808080808080808080808080
                        )
                    ) {
                        cursor := add(cursor, 31)
                        continue
                    }
                }
                let lead := byte(and(cursor, 31), mload(and(cursor, not(31))))

                if iszero(lt(lead, 0x80)) {
                    if or(lt(lead, 0xc2), gt(lead, 0xf4)) {
                        valid := 0
                        break
                    }

                    cursor := add(cursor, 1)
                    if iszero(lt(cursor, end)) {
                        valid := 0
                        break
                    }

                    let second := byte(and(cursor, 31), mload(and(cursor, not(31))))
                    if iszero(eq(and(second, 0xc0), 0x80)) {
                        valid := 0
                        break
                    }

                    if lt(lead, 0xe0) {
                        continue
                    }

                    if or(
                        and(eq(lead, 0xe0), lt(second, 0xa0)),
                        and(eq(lead, 0xed), gt(second, 0x9f))
                    ) {
                        valid := 0
                        break
                    }

                    cursor := add(cursor, 1)
                    if iszero(lt(cursor, end)) {
                        valid := 0
                        break
                    }
                    if iszero(
                        eq(and(byte(and(cursor, 31), mload(and(cursor, not(31)))), 0xc0), 0x80)
                    ) {
                        valid := 0
                        break
                    }

                    if lt(lead, 0xf0) {
                        continue
                    }

                    if or(
                        and(eq(lead, 0xf0), lt(second, 0x90)),
                        and(eq(lead, 0xf4), gt(second, 0x8f))
                    ) {
                        valid := 0
                        break
                    }

                    cursor := add(cursor, 1)
                    if iszero(lt(cursor, end)) {
                        valid := 0
                        break
                    }
                    if iszero(
                        eq(and(byte(and(cursor, 31), mload(and(cursor, not(31)))), 0xc0), 0x80)
                    ) {
                        valid := 0
                        break
                    }
                }
            }
        }
    }
}
// forgefmt: disable-end
