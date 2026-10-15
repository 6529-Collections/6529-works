// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { JsonEscape } from "src/libraries/JsonEscape.sol";
import { Utf8 } from "src/libraries/Utf8.sol";
import { TextOracles as O } from "../helpers/TextOracles.sol";
import { Pr744Escape } from "../helpers/Pr744Escape.sol";

contract JsonEscapeHarness {
    function escape(string calldata raw) external pure returns (string memory) {
        return JsonEscape.escape(raw);
    }

    function scriptText(string calldata raw) external pure returns (string memory) {
        return JsonEscape.scriptText(raw);
    }

    function oracleEscape(string calldata raw) external pure returns (string memory) {
        return string(O.escape(bytes(raw)));
    }

    function oracleScriptText(string calldata raw) external pure returns (string memory) {
        return string(O.scriptText(bytes(raw)));
    }

    function pr744Escape(string calldata raw) external pure returns (string memory) {
        return Pr744Escape.escape(raw);
    }

    function pr744ScriptText(string calldata raw) external pure returns (string memory) {
        return Pr744Escape.scriptText(raw);
    }
}

/// @notice Parity, golden and fuzz tests ported from 6529Stream PR #744's `StreamJsonEscaping.t.sol` and
///         `StreamStaticPureEncoding.t.sol`. Every parity check compares against both the
///         frozen byte-loop oracles and 6529Stream PR #744's optimized encoders, copied verbatim.
contract JsonEscapeTest is Test {
    bytes internal constant TAG = "</script";

    function _escape(bytes memory raw) internal pure returns (bytes memory) {
        return bytes(JsonEscape.escape(string(raw)));
    }

    function _script(bytes memory raw) internal pure returns (bytes memory) {
        return bytes(JsonEscape.scriptText(string(raw)));
    }

    /// @dev Both encoders match their oracles and leave the input untouched.
    function _parity(bytes memory raw) internal pure {
        bytes32 before = keccak256(raw);
        uint256 length = raw.length;
        bytes memory escaped = _escape(raw);
        bytes memory scripted = _script(raw);
        assertEq(escaped, O.escape(raw), "escape parity (oracle)");
        assertEq(scripted, O.scriptText(raw), "script parity (oracle)");
        assertEq(escaped, bytes(Pr744Escape.escape(string(raw))), "escape parity (#744)");
        assertEq(scripted, bytes(Pr744Escape.scriptText(string(raw))), "script parity (#744)");
        assertEq(raw.length, length, "input length changed");
        assertEq(keccak256(raw), before, "input bytes changed");
    }

    // ---------------------------------------------------------------- golden vectors

    function test_Empty() public pure {
        assertEq(_escape(""), "");
        assertEq(_script(""), "");
    }

    function test_GoldenEscapes() public pure {
        assertEq(
            _escape(hex"00225c3ce280a8e280a9"),
            hex"5c75303030305c225c5c5c75303033635c75323032385c7532303239"
        );
        // Every control byte uses the \u00xx form; DEL (0x7f) and '>' pass through.
        assertEq(
            _escape(hex"080c0a0d091f7f3e"),
            hex"5c75303030385c75303030635c75303030615c75303030645c75303030395c75303031667f3e"
        );
        assertEq(_escape("plain text / ok"), "plain text / ok");
    }

    function test_GoldenScriptText() public pure {
        assertEq(
            _script("</scriptX</ScRiPt></script"),
            bytes.concat("<", hex"5c", "/scriptX<", hex"5c", "/ScRiPt><", hex"5c", "/script")
        );
        // Incomplete prefixes are not end tags.
        for (uint256 n; n < 8; ++n) {
            bytes memory truncated = new bytes(n);
            for (uint256 j; j < n; ++j) {
                truncated[j] = TAG[j];
            }
            assertEq(_script(truncated), truncated);
        }
    }

    function test_UnchangedInputIsReturnedAsIs() public pure {
        string memory value = "no specials here";
        string memory escaped = JsonEscape.escape(value);
        string memory scripted = JsonEscape.scriptText(value);
        uint256 a;
        uint256 b;
        uint256 c;
        assembly {
            a := value
            b := escaped
            c := scripted
        }
        assertEq(a, b);
        assertEq(a, c);
    }

    // ---------------------------------------------------------------- exhaustive parity

    function test_EveryByteIndividuallyAndTogether() public pure {
        bytes memory all = new bytes(256);
        for (uint256 i; i < 256; ++i) {
            all[i] = bytes1(uint8(i));
            _parity(abi.encodePacked(bytes1(uint8(i))));
        }
        _parity(all);
    }

    function test_EveryWordBoundary() public pure {
        bytes memory all = new bytes(256);
        for (uint256 i; i < all.length; ++i) {
            all[i] = bytes1(uint8(i));
        }
        for (uint256 n; n < 65; ++n) {
            bytes memory prefix = O.fill(n, "a");
            _parity(
                bytes.concat(
                    prefix, all, hex"e280a8e280a9e280e2e280aa80a8", "</ScRiPtX</script</SCRIPTx"
                )
            );
            _parity(bytes.concat(prefix, TAG));
            _parity(bytes.concat(prefix, hex"e280a8"));
            _parity(bytes.concat(prefix, hex"e280a9"));
            _parity(bytes.concat(prefix, hex"e280"));
        }
    }

    function test_SeparatorLookalikes() public pure {
        _parity(hex"e280a7e280aae280e2e280f09f8ea8f09feda080ff");
        _parity(hex"e2e280a8");
        _parity(hex"e280e280a9");
    }

    function test_AllCaseVariantsAdjacentMatchesAndLongRuns() public pure {
        bytes memory tag = bytes(TAG);
        for (uint256 mask; mask < 64; ++mask) {
            for (uint256 j; j < 6; ++j) {
                uint8 lower = uint8(TAG[j + 2]);
                tag[j + 2] = bytes1((mask & (uint256(1) << j)) == 0 ? lower : lower - 32);
            }
            _parity(bytes.concat(tag, tag, "!", O.fill(67, "a"), tag));
        }
        bytes memory repeated = new bytes(24_576);
        for (uint256 i; i < repeated.length; ++i) {
            repeated[i] = TAG[i % 8];
        }
        _parity(repeated);
    }

    /// @dev Every single-byte substitution in each position of "</script" (2,048 cases),
    ///      including bytes that equal a tag letter only after OR-ing 0x20.
    function test_EverySubstitutionInTheTag() public pure {
        for (uint256 k; k < 8; ++k) {
            for (uint256 b; b < 256; ++b) {
                bytes memory tag = bytes.concat(TAG);
                tag[k] = bytes1(uint8(b));
                bytes memory raw = bytes.concat("x", tag, "y");
                assertEq(_script(raw), O.scriptText(raw));
            }
        }
    }

    function test_InvalidUtf8PassesThroughUnchanged() public pure {
        bytes memory raw = hex"ff80c0afe080aff4908080eda080fe";
        assertEq(_escape(raw), raw);
        assertFalse(Utf8.isValid(raw), "validation is separate");
    }

    function test_AllocationBoundaries() public pure {
        uint256[14] memory lengths =
            [uint256(0), 1, 31, 32, 33, 63, 64, 65, 255, 256, 2047, 2048, 8191, 8192];
        for (uint256 j; j < lengths.length; ++j) {
            bytes memory raw = new bytes(lengths[j]);
            for (uint256 i; i < raw.length; ++i) {
                raw[i] = bytes1(uint8(i));
            }
            _parity(raw);
        }
    }

    function test_MaximumSixfoldExpansion() public pure {
        bytes memory escaped = _escape(new bytes(8192));
        assertEq(escaped.length, 49_152);
        for (uint256 i; i < escaped.length; i += 6) {
            assertEq(
                bytes6(
                    bytes.concat(
                        escaped[i],
                        escaped[i + 1],
                        escaped[i + 2],
                        escaped[i + 3],
                        escaped[i + 4],
                        escaped[i + 5]
                    )
                ),
                bytes6(hex"5c7530303030")
            );
        }
    }

    // ---------------------------------------------------------------- memory safety

    function test_RepeatedCallsAndSubsequentAllocationsPreserveValues() public pure {
        bytes memory input = hex"00225c1f2021ff3c";
        bytes memory first = _escape(input);
        bytes32 inputHash = keccak256(input);
        bytes32 firstHash = keccak256(first);
        bytes memory canary = O.fill(513, 0xab);
        bytes memory second = _escape(O.fill(33, 0x22));
        bytes memory third = _script(bytes.concat(O.fill(40, "z"), TAG));
        (bytes memory a, bytes memory b, bytes memory c, bytes memory d, bytes memory e) = abi.decode(
            abi.encode(input, first, canary, second, third), (bytes, bytes, bytes, bytes, bytes)
        );
        assertEq(keccak256(input), inputHash);
        assertEq(keccak256(first), firstHash);
        assertEq(a, input);
        assertEq(b, first);
        assertEq(c, O.fill(513, 0xab));
        assertEq(d, second);
        assertEq(e, third);
    }

    function test_InputAndNeighbouringMemoryUnchanged() public pure {
        for (uint256 n; n < 65; ++n) {
            bytes memory raw = bytes.concat(O.fill(n, "a"), TAG, hex"223c", hex"e280a8");
            bytes memory neighbour = O.fill(96, 0xff);
            bytes32 neighbourBefore = keccak256(neighbour);
            _parity(raw);
            assertEq(keccak256(neighbour), neighbourBefore, "neighbouring memory changed");
        }
    }

    /// @dev Bytes in memory right after the input never complete a sequence the input only
    ///      starts: `e2 80` before an `a8`, or `</scr` before `ipt`, at every length and word
    ///      offset. Mutation testing found the two end-of-input bounds unpinned (the tests'
    ///      memory past the end was always zero).
    function test_BytesPastTheEndAreNotRead() public pure {
        bytes[2] memory heads = [bytes(hex"e280"), "</scr"];
        bytes[2] memory tails = [bytes(hex"a8"), "ipt"];
        for (uint256 h; h < heads.length; ++h) {
            for (uint256 n; n < 40; ++n) {
                // The text and what follows it in one allocation, then the length shortened, so
                // the tail sits in memory right after the text's last byte.
                bytes memory text = bytes.concat(O.fill(n, "a"), heads[h], tails[h]);
                uint256 length = n + heads[h].length;
                assembly ("memory-safe") {
                    mstore(text, length)
                }
                string memory out =
                    h == 0 ? JsonEscape.escape(string(text)) : JsonEscape.scriptText(string(text));
                assertEq(bytes(out), text, "a byte past the end was read");
            }
        }
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_ParityWithOracles(bytes memory raw) public pure {
        vm.assume(raw.length <= 4096);
        _parity(raw);
    }

    function testFuzz_SpecialSpansAcrossBoundaries(bytes memory raw, uint8 offset) public pure {
        vm.assume(raw.length <= 2048);
        _parity(
            bytes.concat(
                O.fill(uint256(offset) % 65, "x"), raw, hex"e280a83c225c0001e280a9", "</SCRIPT", raw
            )
        );
    }

    function testFuzz_EscapedOutputIsInert(bytes memory raw) public pure {
        vm.assume(raw.length <= 4096);
        bytes memory escaped = _escape(raw);
        for (uint256 i; i < escaped.length; ++i) {
            uint8 b = uint8(escaped[i]);
            assertTrue(b >= 0x20 && b != 0x3c, "control byte or '<' left");
            if (b == 0xe2 && i + 2 < escaped.length && escaped[i + 1] == 0x80) {
                assertTrue(escaped[i + 2] != 0xa8 && escaped[i + 2] != 0xa9, "separator left");
            }
        }
        assertFalse(O.hasEndTag(_script(raw)), "end tag left");
    }

    // ---------------------------------------------------------------- gas

    function test_Gas24576ByteInputs() public {
        JsonEscapeHarness h = new JsonEscapeHarness();
        bytes memory ascii = O.fill(24_576, "a");
        bytes memory mixed = O.fill(24_576, "a");
        for (uint256 i; i < mixed.length; i += 97) {
            mixed[i] = "<";
        }
        bytes memory dense = new bytes(24_576);
        for (uint256 i; i < dense.length; ++i) {
            dense[i] = bytes1(uint8(0x20 + (i % 0x60)));
        }
        _report("escape, ASCII", h.escape, h.pr744Escape, h.oracleEscape, ascii);
        _report("escape, '<' every 97 bytes", h.escape, h.pr744Escape, h.oracleEscape, mixed);
        _report("escape, printable cycle", h.escape, h.pr744Escape, h.oracleEscape, dense);
        _report("scriptText, ASCII", h.scriptText, h.pr744ScriptText, h.oracleScriptText, ascii);
        _report(
            "scriptText, '<' every 97 bytes",
            h.scriptText,
            h.pr744ScriptText,
            h.oracleScriptText,
            mixed
        );
        _report(
            "scriptText, printable cycle",
            h.scriptText,
            h.pr744ScriptText,
            h.oracleScriptText,
            dense
        );
    }

    function _report(
        string memory label,
        function(string memory) external pure returns (string memory) optimized,
        function(string memory) external pure returns (string memory) pr744,
        function(string memory) external pure returns (string memory) naive,
        bytes memory raw
    ) internal view {
        (uint256 gOptimized, bytes memory a) = _gas(optimized, raw);
        (uint256 gReference, bytes memory b) = _gas(pr744, raw);
        (uint256 gNaive, bytes memory c) = _gas(naive, raw);
        assertEq(a, b);
        assertEq(a, c);
        console2.log(label);
        console2.log("  24,576 bytes: v1 / #744 / naive", gOptimized, gReference, gNaive);
        assertLt(gOptimized, gReference, "no regression against #744");
    }

    // forgefmt: disable-next-item
    function _gas(
        function(string memory) external pure returns (string memory) f,
        bytes memory raw
    ) internal view returns (uint256 used, bytes memory result) {
        uint256 start = gasleft();
        result = bytes(f(string(raw)));
        used = start - gasleft();
    }
}
