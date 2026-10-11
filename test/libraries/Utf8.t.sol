// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { Utf8 } from "src/libraries/Utf8.sol";
import { TextOracles as O } from "../helpers/TextOracles.sol";
import { Pr744Utf8 } from "../helpers/Pr744Utf8.sol";

/// @dev Measures inside a fresh call frame, so the test contract's memory never inflates it.
contract Utf8Harness {
    function measure(bytes calldata data)
        external
        view
        returns (bool valid, uint256 used, uint256 pr744Used, uint256 oracleUsed)
    {
        bytes memory copy = data;
        uint256 start = gasleft();
        valid = Utf8.isValid(copy);
        used = start - gasleft();
        start = gasleft();
        bool pr744Valid = Pr744Utf8.isValidUtf8(string(copy));
        pr744Used = start - gasleft();
        start = gasleft();
        bool oracleValid = O.isValidUtf8(copy);
        oracleUsed = start - gasleft();
        require(valid == pr744Valid && valid == oracleValid, "validators disagree");
    }
}

/// @notice RFC 3629 vectors, exhaustive two-byte and boundary tables, word-boundary placement,
///         streaming across every split point, and differential fuzzing against both a
///         code-point decoding oracle and 6529Stream PR #744's validator, copied verbatim.
contract Utf8Test is Test {
    function _check(bytes memory data, bool expected) internal pure {
        assertEq(Utf8.isValid(data), expected);
        assertEq(O.isValidUtf8(data), expected, "oracle disagrees with the vector");
        assertEq(Pr744Utf8.isValidUtf8(string(data)), expected, "#744 disagrees with the vector");
    }

    function _parity(bytes memory data) internal pure {
        bool valid = Utf8.isValid(data);
        assertEq(valid, O.isValidUtf8(data), "oracle parity");
        assertEq(valid, Pr744Utf8.isValidUtf8(string(data)), "#744 parity");
    }

    // ---------------------------------------------------------------- vectors

    function test_ValidBoundaryVectors() public pure {
        bytes[14] memory valid = [
            bytes(""),
            hex"00",
            hex"7f",
            hex"c280", // U+0080
            hex"dfbf", // U+07FF
            hex"e0a080", // U+0800
            hex"ed9fbf", // U+D7FF
            hex"ee8080", // U+E000
            hex"efbfbf", // U+FFFF
            hex"efbbbf", // BOM
            hex"f0908080", // U+10000
            hex"f48fbfbf", // U+10FFFF
            hex"e280a8e280a9", // separators are valid text
            bytes("6529 Stream: ascii, caf\xc3\xa9, \xe6\x97\xa5\xe6\x9c\xac, \xf0\x9f\x8e\xa8")
        ];
        for (uint256 i; i < valid.length; ++i) {
            _check(valid[i], true);
        }
    }

    /// @dev The short paths for two- and three-byte sequences (C2-DF, E1-EC and EE-EF with plain
    ///      continuations) sit next to the end of the text at every offset in a word: a sequence that
    ///      ends exactly at the end, one cut short, one with a bad continuation, and the lead bytes
    ///      the short path leaves to the general one (E0 and ED).
    function test_ShortPathsAtTheEndAtEveryOffset() public pure {
        for (uint256 pad; pad < 70; ++pad) {
            bytes memory pre = new bytes(pad);
            for (uint256 i; i < pad; ++i) {
                pre[i] = "a";
            }
            _check(bytes.concat(pre, hex"c3a9"), true);
            _check(bytes.concat(pre, hex"c3"), false);
            _check(bytes.concat(pre, hex"c3a9c3a9c3a9"), true);
            _check(bytes.concat(pre, hex"c341"), false);
            _check(bytes.concat(pre, hex"c3c3"), false);
            _check(bytes.concat(pre, hex"e282ac"), true);
            _check(bytes.concat(pre, hex"e282"), false);
            _check(bytes.concat(pre, hex"e2"), false);
            _check(bytes.concat(pre, hex"e28241"), false);
            _check(bytes.concat(pre, hex"e24182"), false);
            _check(bytes.concat(pre, hex"e282acc3a9e282ac"), true);
            _check(bytes.concat(pre, hex"e0a080"), true);
            _check(bytes.concat(pre, hex"e09f80"), false);
            _check(bytes.concat(pre, hex"ed9fbf"), true);
            _check(bytes.concat(pre, hex"eda080"), false);
            _check(bytes.concat(pre, hex"efbfbf"), true);
            _check(bytes.concat(pre, hex"c0af"), false);
            _check(bytes.concat(pre, hex"c2"), false);
            _check(bytes.concat(pre, hex"dfbf"), true);
            _check(bytes.concat(pre, hex"f09f9880"), true);
            _check(bytes.concat(pre, hex"f09f98"), false);
        }
    }

    /// @dev The short paths read the bytes of a sequence from one word, and must not take a byte
    ///      after the end of the text for one of its continuations, whatever the memory holds
    ///      there (here 0xa9, a good continuation).
    function test_ShortPathsDoNotReadPastTheEnd() public pure {
        bytes[6] memory cut =
            [bytes(hex"c3"), hex"e2", hex"e282", hex"c3a9c3", hex"e282ace2", hex"e282ace282"];
        for (uint256 pad; pad < 34; ++pad) {
            for (uint256 c; c < cut.length; ++c) {
                bytes memory text = bytes.concat(new bytes(pad), cut[c]);
                for (uint256 i; i < pad; ++i) {
                    text[i] = "a";
                }
                uint256 length = text.length;
                assembly ("memory-safe") {
                    for { let i := 0 } lt(i, 40) { i := add(i, 1) } {
                        mstore8(add(add(text, add(0x20, length)), i), 0xa9)
                    }
                }
                assertFalse(Utf8.isValid(text), "a sequence cut short");
            }
        }
    }

    function test_InvalidVectors() public pure {
        bytes[22] memory invalid = [
            bytes(hex"80"), // lone continuation
            hex"bf",
            hex"c0af", // overlong '/'
            hex"c180",
            hex"e080af", // overlong 3-byte
            hex"e09fbf",
            hex"eda080", // surrogate U+D800
            hex"edbfbf", // surrogate U+DFFF
            hex"f08080af", // overlong 4-byte
            hex"f08fbfbf",
            hex"f4908080", // U+110000
            hex"f5808080",
            hex"f8888080",
            hex"ff",
            hex"fe",
            hex"c2", // truncated
            hex"e0a0",
            hex"f09f8e",
            hex"c241", // continuation replaced by ASCII
            hex"e0a041",
            hex"f09f8e41",
            hex"41c2" // truncated at the very end
        ];
        for (uint256 i; i < invalid.length; ++i) {
            _check(invalid[i], false);
        }
    }

    function test_EverySingleByte() public pure {
        for (uint256 b; b < 256; ++b) {
            _check(abi.encodePacked(uint8(b)), b < 0x80);
        }
    }

    /// @dev All 65,536 two-byte inputs.
    function test_AllTwoByteSequences() public pure {
        for (uint256 a; a < 256; ++a) {
            for (uint256 b; b < 256; ++b) {
                _parity(abi.encodePacked(uint8(a), uint8(b)));
            }
        }
    }

    /// @dev Every lead byte from 0xe0 with every second byte, then a valid third (and fourth).
    function test_ThreeAndFourByteBoundaryTables() public pure {
        for (uint256 lead = 0xe0; lead < 0x100; ++lead) {
            for (uint256 second; second < 256; ++second) {
                bytes memory three = abi.encodePacked(uint8(lead), uint8(second), uint8(0x80));
                bytes memory four = bytes.concat(three, hex"80");
                _parity(three);
                _parity(four);
            }
        }
    }

    /// @dev The ASCII word skip must never jump over a non-ASCII byte, at any offset.
    function test_WordBoundaries() public pure {
        bytes[5] memory probes = [bytes(hex"f09f8ea8"), hex"c3a9", hex"80", hex"eda080", hex"c2"];
        bool[5] memory expected = [true, true, false, false, false];
        for (uint256 n; n < 97; ++n) {
            bytes memory prefix = O.fill(n, "a");
            for (uint256 j; j < probes.length; ++j) {
                _check(bytes.concat(prefix, probes[j]), expected[j]);
                _check(bytes.concat(prefix, probes[j], O.fill(40, "b")), expected[j]);
            }
            _check(prefix, true);
        }
    }

    // ---------------------------------------------------------------- streaming

    function test_StreamEverySplitPoint() public pure {
        bytes memory text = bytes.concat(
            O.fill(35, "a"), hex"f09f8ea8c3a9e697a5", O.fill(33, "b"), hex"f48fbfbfe0a080c280"
        );
        assertTrue(Utf8.isValid(text));
        for (uint256 k; k <= text.length; ++k) {
            (bytes memory a, bytes memory b) = _split(text, k);
            (bool ok, uint256 state) = Utf8.validate(0, a);
            assertTrue(ok);
            (ok, state) = Utf8.validate(state, b);
            assertTrue(ok);
            assertEq(state, 0);
        }
    }

    function test_StreamCarriesPartialSequences() public pure {
        (bool ok, uint256 state) = Utf8.validate(0, hex"f0");
        assertTrue(ok);
        assertEq(state, 3 | (0x90 << 8) | (0xbf << 16));
        (ok, state) = Utf8.validate(state, hex"9f");
        assertTrue(ok);
        assertEq(state, 2 | (0x80 << 8) | (0xbf << 16));
        (ok, state) = Utf8.validate(state, hex"8e");
        assertTrue(ok);
        (ok, state) = Utf8.validate(state, hex"a8");
        assertTrue(ok);
        assertEq(state, 0);
        // The continuation range survives the split: f0 then 80 is overlong.
        (, state) = Utf8.validate(0, hex"f0");
        (ok, state) = Utf8.validate(state, hex"80");
        assertFalse(ok);
        assertEq(state, 0);
        // A stream that ends mid-sequence is incomplete.
        (ok, state) = Utf8.validate(0, hex"41e0a0");
        assertTrue(ok);
        assertTrue(state != 0);
        assertFalse(Utf8.isValid(hex"41e0a0"));
    }

    function test_StreamRejectsForgedStates() public pure {
        uint256[7] memory forged = [
            uint256(4 | (0x80 << 8) | (0xbf << 16)), // four continuations due
            1 | (0x7f << 8) | (0xbf << 16), // range below 0x80
            1 | (0x80 << 8) | (0xc0 << 16), // range above 0xbf
            1 | (0xa0 << 8) | (0x9f << 16), // empty range
            0x80 << 8, // stray bits at a boundary
            1 | (0x80 << 8) | (0xbf << 16) | (1 << 24), // bits above the state
            type(uint256).max
        ];
        for (uint256 i; i < forged.length; ++i) {
            (bool ok, uint256 state) = Utf8.validate(forged[i], "");
            assertFalse(ok, vm.toString(i));
            assertEq(state, 0);
            (ok,) = Utf8.validate(forged[i], hex"80");
            assertFalse(ok, vm.toString(i));
        }
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_MatchesOracles(bytes memory data) public pure {
        _parity(data);
    }

    function testFuzz_MostlyAsciiMatchesOracle(bytes memory noise, uint8 offset) public pure {
        _parity(bytes.concat(O.fill(uint256(offset) % 70, "a"), noise, O.fill(33, "z")));
    }

    function testFuzz_EncodedScalarsAreValid(uint32[] memory points, uint256 split) public pure {
        bytes memory text;
        for (uint256 i; i < points.length && i < 64; ++i) {
            uint256 cp = uint256(points[i]) % 0x10f800; // scalar values minus the surrogates
            if (cp >= 0xd800) cp += 0x800;
            text = bytes.concat(text, O.encode(cp));
        }
        assertTrue(Utf8.isValid(text));
        (bytes memory a, bytes memory b) =
            _split(text, text.length == 0 ? 0 : split % (text.length + 1));
        (bool ok, uint256 state) = Utf8.validate(0, a);
        assertTrue(ok);
        (ok, state) = Utf8.validate(state, b);
        assertTrue(ok);
        assertEq(state, 0);
    }

    function testFuzz_StreamingEqualsWhole(bytes memory data, uint256 split) public pure {
        (bytes memory a, bytes memory b) =
            _split(data, data.length == 0 ? 0 : split % (data.length + 1));
        (bool ok, uint256 state) = Utf8.validate(0, a);
        if (ok) (ok, state) = Utf8.validate(state, b);
        assertEq(ok && state == 0, Utf8.isValid(data));
    }

    // ---------------------------------------------------------------- gas

    function test_Gas24576Bytes() public {
        Utf8Harness h = new Utf8Harness();
        _report(h, "ASCII", O.fill(24_576, "a"));
        _report(
            h,
            "Latin-1 text",
            _repeat(hex"436166c3a9206372c3a86d65206272c3bb6cc3a9652c206e61c3af76652e20")
        );
        _report(h, "CJK text", _repeat(hex"e697a5e69cace8aa9ee381aee69687e7aba0e381a7e38199e38082"));
    }

    function _repeat(bytes memory unit) internal pure returns (bytes memory out) {
        out = new bytes((24_576 / unit.length) * unit.length);
        for (uint256 i; i < out.length; ++i) {
            out[i] = unit[i % unit.length];
        }
    }

    function _report(Utf8Harness h, string memory label, bytes memory data) internal view {
        (bool valid, uint256 used, uint256 pr744Used, uint256 oracleUsed) = h.measure(data);
        assertTrue(valid);
        console2.log(label);
        console2.log("  bytes", data.length);
        console2.log("  gas: v1 / #744 / naive", used, pr744Used, oracleUsed);
        assertLt(used, pr744Used, "no regression against #744");
    }

    function _split(bytes memory data, uint256 k)
        internal
        pure
        returns (bytes memory a, bytes memory b)
    {
        a = new bytes(k);
        b = new bytes(data.length - k);
        for (uint256 i; i < k; ++i) {
            a[i] = data[i];
        }
        for (uint256 i; i < b.length; ++i) {
            b[i] = data[k + i];
        }
    }
}
