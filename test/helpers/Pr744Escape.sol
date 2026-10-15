// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice 6529Stream PR #744 code copied verbatim from `smart-contracts/domains/metadata/StreamRenderContextV1.sol` at
///         `origin/codex/v1-integration` (19432ea43). Test-only: proves byte parity with, and measures
///         gas against, the implementation the v1 library ports. Not formatted.
// forgefmt: disable-start
library Pr744Escape {
    /// @dev Count exact expansion first; ordinary spans are copied in words. The old encoder's
    /// byte rules deliberately preserve arbitrary non-special bytes, including malformed UTF-8.
    function escape(string memory value) internal pure returns (string memory) {
        bytes memory raw = bytes(value);
        uint256 extra;
        assembly ("memory-safe") {
            function at(p) -> b { b := byte(and(p, 31), mload(and(p, not(31)))) }
            let end := add(add(raw, 32), mload(raw))
            for { let p := add(raw, 32) } lt(p, end) { p := add(p, 1) } {
                let b := at(p)
                switch or(eq(b, 34), eq(b, 92))
                case 1 { extra := add(extra, 1) }
                default {
                    switch or(lt(b, 32), eq(b, 60))
                    case 1 { extra := add(extra, 5) }
                    default {
                        if and(eq(b, 0xe2), lt(add(p, 2), end)) {
                            if and(
                                eq(at(add(p, 1)), 0x80),
                                or(eq(at(add(p, 2)), 0xa8), eq(at(add(p, 2)), 0xa9))
                            ) {
                                extra := add(extra, 3)
                                p := add(p, 2)
                            }
                        }
                    }
                }
            }
        }
        if (extra == 0) return value;
        bytes memory out = new bytes(raw.length + extra);
        assembly ("memory-safe") {
            function at(p) -> b { b := byte(and(p, 31), mload(and(p, not(31)))) }
            function copy(dst, src, size) {
                for { } iszero(lt(size, 32)) { size := sub(size, 32) } {
                    mstore(dst, mload(src))
                    dst := add(dst, 32)
                    src := add(src, 32)
                }
                for { } gt(size, 0) { size := sub(size, 1) } {
                    mstore8(dst, at(src))
                    dst := add(dst, 1)
                    src := add(src, 1)
                }
            }
            let end := add(add(raw, 32), mload(raw))
            let run := add(raw, 32)
            let dst := add(out, 32)
            let hexDigits := 0x3031323334353637383961626364656600000000000000000000000000000000
            for { let p := run } lt(p, end) { p := add(p, 1) } {
                let b := at(p)
                let kind := 0
                if or(eq(b, 34), eq(b, 92)) { kind := 1 }
                if or(lt(b, 32), eq(b, 60)) { kind := 2 }
                if and(eq(b, 0xe2), lt(add(p, 2), end)) {
                    if and(
                        eq(at(add(p, 1)), 0x80),
                        or(eq(at(add(p, 2)), 0xa8), eq(at(add(p, 2)), 0xa9))
                    ) { kind := 3 }
                }
                if kind {
                    let size := sub(p, run)
                    copy(dst, run, size)
                    dst := add(dst, size)
                    mstore8(dst, 92)
                    switch kind
                    case 1 {
                        mstore8(add(dst, 1), b)
                        dst := add(dst, 2)
                    }
                    default {
                        mstore8(add(dst, 1), 117)
                        switch kind
                        case 2 {
                            mstore8(add(dst, 2), 48)
                            mstore8(add(dst, 3), 48)
                            mstore8(add(dst, 4), byte(shr(4, b), hexDigits))
                            mstore8(add(dst, 5), byte(and(b, 15), hexDigits))
                        }
                        case 3 {
                            mstore8(add(dst, 2), 50)
                            mstore8(add(dst, 3), 48)
                            mstore8(add(dst, 4), 50)
                            mstore8(add(dst, 5), add(56, eq(at(add(p, 2)), 0xa9)))
                            p := add(p, 2)
                        }
                        dst := add(dst, 6)
                    }
                    run := add(p, 1)
                }
            }
            copy(dst, run, sub(end, run))
        }
        return string(out);
    }
}
