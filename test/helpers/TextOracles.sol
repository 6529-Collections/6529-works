// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Deliberately naive reference implementations for differential tests.
/// @dev `escape` and `scriptText` are the byte-loop oracles 6529Stream PR #744 froze as
///      `FrozenRenderContextV1` (the historical output the optimized code must match).
///      `isValidUtf8` decodes code points and checks their range, an algorithm independent of
///      the byte-range table used by `Utf8`.
library TextOracles {
    bytes16 internal constant HEX = "0123456789abcdef";
    bytes1 internal constant BACKSLASH = 0x5c;

    function escape(bytes memory raw) internal pure returns (bytes memory) {
        bytes memory out = new bytes(raw.length * 6);
        uint256 cursor;
        for (uint256 i; i < raw.length; ++i) {
            uint8 b = uint8(raw[i]);
            if (b == 0x22 || b == 0x5c) {
                out[cursor++] = BACKSLASH;
                out[cursor++] = bytes1(b);
            } else if (b < 0x20 || b == 0x3c) {
                out[cursor++] = BACKSLASH;
                out[cursor++] = "u";
                out[cursor++] = "0";
                out[cursor++] = "0";
                out[cursor++] = HEX[b >> 4];
                out[cursor++] = HEX[b & 15];
            } else if (
                b == 0xe2 && i + 2 < raw.length && raw[i + 1] == 0x80
                    && (raw[i + 2] == 0xa8 || raw[i + 2] == 0xa9)
            ) {
                out[cursor++] = BACKSLASH;
                out[cursor++] = "u";
                out[cursor++] = "2";
                out[cursor++] = "0";
                out[cursor++] = "2";
                out[cursor++] = raw[i + 2] == 0xa8 ? bytes1("8") : bytes1("9");
                i += 2;
            } else {
                out[cursor++] = raw[i];
            }
        }
        assembly ("memory-safe") {
            mstore(out, cursor)
        }
        return out;
    }

    function scriptText(bytes memory raw) internal pure returns (bytes memory) {
        bytes memory out = new bytes(raw.length + raw.length / 8);
        uint256 cursor;
        for (uint256 i; i < raw.length; ++i) {
            if (isEndTagAt(raw, i)) {
                out[cursor++] = 0x3c;
                out[cursor++] = BACKSLASH;
                ++i;
            }
            out[cursor++] = raw[i];
        }
        assembly ("memory-safe") {
            mstore(out, cursor)
        }
        return out;
    }

    /// @dev Case-insensitive "</script" starting at `i`.
    function isEndTagAt(bytes memory raw, uint256 i) internal pure returns (bool) {
        return i + 8 <= raw.length && raw[i] == 0x3c && raw[i + 1] == 0x2f
            && (uint8(raw[i + 2]) | 32) == 0x73 && (uint8(raw[i + 3]) | 32) == 0x63
            && (uint8(raw[i + 4]) | 32) == 0x72 && (uint8(raw[i + 5]) | 32) == 0x69
            && (uint8(raw[i + 6]) | 32) == 0x70 && (uint8(raw[i + 7]) | 32) == 0x74;
    }

    function isValidUtf8(bytes memory s) internal pure returns (bool) {
        uint256 i;
        while (i < s.length) {
            uint256 c = uint8(s[i]);
            if (c < 0x80) {
                ++i;
                continue;
            }
            uint256 n;
            uint256 cp;
            uint256 min;
            if (c & 0xe0 == 0xc0) {
                (n, cp, min) = (1, c & 0x1f, 0x80);
            } else if (c & 0xf0 == 0xe0) {
                (n, cp, min) = (2, c & 0x0f, 0x800);
            } else if (c & 0xf8 == 0xf0) {
                (n, cp, min) = (3, c & 0x07, 0x10000);
            } else {
                return false;
            }
            if (i + n >= s.length) return false;
            for (uint256 j = 1; j <= n; ++j) {
                uint256 d = uint8(s[i + j]);
                if (d & 0xc0 != 0x80) return false;
                cp = (cp << 6) | (d & 0x3f);
            }
            if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return false;
            i += n + 1;
        }
        return true;
    }

    /// @dev UTF-8 encoding of a Unicode scalar value (no surrogates, at most U+10FFFF).
    function encode(uint256 cp) internal pure returns (bytes memory) {
        if (cp < 0x80) return abi.encodePacked(uint8(cp));
        if (cp < 0x800) {
            return abi.encodePacked(uint8(0xc0 | (cp >> 6)), uint8(0x80 | (cp & 0x3f)));
        }
        if (cp < 0x10000) {
            return abi.encodePacked(
                uint8(0xe0 | (cp >> 12)),
                uint8(0x80 | ((cp >> 6) & 0x3f)),
                uint8(0x80 | (cp & 0x3f))
            );
        }
        return abi.encodePacked(
            uint8(0xf0 | (cp >> 18)),
            uint8(0x80 | ((cp >> 12) & 0x3f)),
            uint8(0x80 | ((cp >> 6) & 0x3f)),
            uint8(0x80 | (cp & 0x3f))
        );
    }

    function fill(uint256 n, bytes1 value) internal pure returns (bytes memory result) {
        result = new bytes(n);
        for (uint256 i; i < n; ++i) {
            result[i] = value;
        }
    }

    function hasEndTag(bytes memory raw) internal pure returns (bool) {
        for (uint256 i; i < raw.length; ++i) {
            if (isEndTagAt(raw, i)) return true;
        }
        return false;
    }
}
