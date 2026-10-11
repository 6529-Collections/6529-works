// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DataUri } from "src/content/DataUri.sol";
import { HtmlScript } from "src/content/HtmlScript.sol";

contract TextHelpersHarness {
    function neutralize(string calldata js) external pure returns (string memory) {
        return HtmlScript.neutralize(js);
    }

    function percent(string calldata text) external pure returns (string memory out) {
        bool ok;
        (ok, out) = DataUri.escape(text, type(uint256).max);
        require(ok, "cap");
    }

    function percentUpTo(string calldata text, uint256 maxHits)
        external
        pure
        returns (bool, string memory)
    {
        return DataUri.escape(text, maxHits);
    }
}

/// @dev `HtmlScript` and `DataUri` against byte-loop oracles, plus the properties that matter:
///      nothing that can end a script element, open a comment, end a URL or start an escape is
///      left, and nothing else changes.
contract TextHelpersTest is Test {
    TextHelpersHarness internal h = new TextHelpersHarness();

    // ---------------------------------------------------------------- oracles

    function _lower(bytes1 c) internal pure returns (bytes1) {
        return c >= "A" && c <= "Z" ? bytes1(uint8(c) + 32) : c;
    }

    function _at(bytes memory s, uint256 i, bytes memory needle) internal pure returns (bool) {
        if (i + needle.length > s.length) return false;
        for (uint256 k; k < needle.length; ++k) {
            if (_lower(s[i + k]) != needle[k]) return false;
        }
        return true;
    }

    /// @dev One backslash after the `<` of every `</script` (any case) and every `<!--`.
    function _oracleScript(bytes memory s) internal pure returns (bytes memory out) {
        out = new bytes(s.length * 2);
        uint256 n;
        for (uint256 i; i < s.length; ++i) {
            out[n++] = s[i];
            if (s[i] == "<" && (_at(s, i, "</script") || _at(s, i, "<!--"))) out[n++] = "\\";
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _oraclePercent(bytes memory s) internal pure returns (bytes memory out) {
        out = new bytes(s.length * 3);
        uint256 n;
        for (uint256 i; i < s.length; ++i) {
            if (s[i] == "%") {
                (out[n++], out[n++], out[n++]) = ("%", "2", "5");
            } else if (s[i] == "#") {
                (out[n++], out[n++], out[n++]) = ("%", "2", "3");
            } else {
                out[n++] = s[i];
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _text(uint256 seed, uint256 length, bytes memory alphabet)
        internal
        pure
        returns (string memory)
    {
        bytes memory out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            out[i] = alphabet[seed % alphabet.length];
        }
        return string(out);
    }

    // ---------------------------------------------------------------- HtmlScript

    function test_Script_Vectors() public view {
        assertEq(h.neutralize(""), "");
        assertEq(h.neutralize("var a = 1;"), "var a = 1;");
        assertEq(h.neutralize("</script>"), "<\\/script>");
        assertEq(h.neutralize("</SCRIPT"), "<\\/SCRIPT");
        assertEq(h.neutralize("</sCrIpT >"), "<\\/sCrIpT >");
        assertEq(h.neutralize("<!--"), "<\\!--");
        assertEq(h.neutralize("a<!--b<!--c"), "a<\\!--b<\\!--c");
        assertEq(h.neutralize("<!--<script>"), "<\\!--<script>");
        assertEq(h.neutralize("</script<!--</script"), "<\\/script<\\!--<\\/script");
        // Near misses are left alone.
        assertEq(h.neutralize("</scrip"), "</scrip");
        assertEq(h.neutralize("<!-"), "<!-");
        assertEq(h.neutralize("<! --"), "<! --");
        assertEq(h.neutralize("<script>"), "<script>");
        assertEq(h.neutralize("<"), "<");
        assertEq(h.neutralize("a < b && c > d"), "a < b && c > d");
    }

    function test_Script_MatchesAcrossWordBoundaries() public view {
        for (uint256 pad; pad < 70; ++pad) {
            bytes memory pre = new bytes(pad);
            for (uint256 i; i < pad; ++i) {
                pre[i] = "x";
            }
            assertEq(
                h.neutralize(string.concat(string(pre), "</script><!--")),
                string.concat(string(pre), "<\\/script><\\!--"),
                "pad"
            );
        }
    }

    function testFuzz_Script_MatchesTheOracle(uint256 seed, uint8 length) public view {
        string memory s = _text(seed, length, "</!-scriptSCRIPT> x");
        assertEq(bytes(h.neutralize(s)), _oracleScript(bytes(s)));
    }

    function testFuzz_Script_NothingDangerousIsLeft(uint256 seed, uint16 length) public view {
        bytes memory out = bytes(h.neutralize(_text(seed, length, "</!-scriptSCRIPT> x\n")));
        for (uint256 i; i < out.length; ++i) {
            if (out[i] == "<") {
                assertFalse(_at(out, i, "</script"), "end tag");
                assertFalse(_at(out, i, "<!--"), "comment");
            }
        }
    }

    /// @dev Removing the added backslashes gives back the input, so nothing else changed.
    function testFuzz_Script_OnlyAddsBackslashes(uint256 seed, uint16 length) public view {
        bytes memory input = bytes(_text(seed, length, "</!-scriptSCRIPT> x"));
        bytes memory out = bytes(h.neutralize(string(input)));
        uint256 j;
        for (uint256 i; i < out.length; ++i) {
            if (out[i] == "\\" && i > 0 && out[i - 1] == "<") continue;
            assertEq(out[i], input[j++]);
        }
        assertEq(j, input.length);
    }

    function test_Script_LargeInputIsLinearAndExact() public view {
        bytes memory js = new bytes(65_536);
        for (uint256 i; i < js.length; ++i) {
            js[i] = i % 97 == 0 ? bytes1("<") : bytes1("a");
        }
        // Plant matches across the whole range.
        for (uint256 p = 5; p + 8 < js.length; p += 4_099) {
            bytes memory tag = p % 2 == 0 ? bytes("</script") : bytes("<!--");
            for (uint256 k; k < tag.length; ++k) {
                js[p + k] = tag[k];
            }
        }
        assertEq(bytes(h.neutralize(string(js))), _oracleScript(js));
    }

    // ---------------------------------------------------------------- DataUri

    function test_Percent_Vectors() public view {
        assertEq(h.percent(""), "");
        assertEq(h.percent("plain text, {}\"\\ <>"), "plain text, {}\"\\ <>");
        assertEq(h.percent("%"), "%25");
        assertEq(h.percent("#"), "%23");
        assertEq(h.percent("100% #1"), "100%25 %231");
        assertEq(h.percent("%25"), "%2525");
        assertEq(h.percent("##%%"), "%23%23%25%25");
        assertEq(h.percent(unicode"café %"), unicode"café %25");
    }

    /// @dev The cap on hits: exactly the cap is fine, one more is refused, at any offset and
    ///      whether the hits are together or a word apart.
    function test_Percent_TheHitCapIsInclusive() public view {
        for (uint256 gap = 0; gap < 70; gap += 7) {
            bytes memory unit = new bytes(gap + 1);
            for (uint256 i; i < gap; ++i) {
                unit[i] = "a";
            }
            unit[gap] = gap % 2 == 0 ? bytes1("%") : bytes1("#");
            bytes memory text;
            for (uint256 k; k < 5; ++k) {
                text = bytes.concat(text, unit);
            }
            (bool ok, string memory out) = h.percentUpTo(string(text), 5);
            assertTrue(ok, "at the cap");
            assertEq(bytes(out), _oraclePercent(text));
            (ok,) = h.percentUpTo(string(text), 4);
            assertFalse(ok, "over the cap");
        }
        (bool fine, string memory same) = h.percentUpTo("plain", 0);
        assertTrue(fine);
        assertEq(same, "plain");
        (fine,) = h.percentUpTo("%", 0);
        assertFalse(fine);
        (fine,) = h.percentUpTo("", 0);
        assertTrue(fine);
    }

    /// @dev A text of nothing but hits is refused at a small cap after only a few steps, not after
    ///      a scan of the whole text.
    function test_Percent_AnOverCapTextIsRefusedEarly() public view {
        bytes memory text = new bytes(24_575);
        for (uint256 i; i < text.length; ++i) {
            text[i] = "%";
        }
        uint256 before = gasleft();
        (bool ok,) = h.percentUpTo(string(text), 2_048);
        uint256 used = before - gasleft();
        assertFalse(ok);
        // The harness copies 24 KiB of calldata; the scan itself stops after 2,049 hits.
        assertLt(used, 1_000_000);
        // At the cap, the whole text is escaped within the renderer's budget.
        bytes memory capped = new bytes(2_048);
        for (uint256 i; i < capped.length; ++i) {
            capped[i] = "%";
        }
        (ok,) = h.percentUpTo(string(capped), 2_048);
        assertTrue(ok);
    }

    function testFuzz_Percent_TheCapDecidesExactly(uint256 seed, uint8 length, uint8 cap)
        public
        view
    {
        bytes memory text = bytes(_text(seed, length, "ab %#25\"{}"));
        uint256 hits;
        for (uint256 i; i < text.length; ++i) {
            if (text[i] == "%" || text[i] == "#") ++hits;
        }
        (bool ok, string memory out) = h.percentUpTo(string(text), cap);
        assertEq(ok, hits <= cap);
        if (ok) assertEq(bytes(out), _oraclePercent(text));
    }

    function testFuzz_Percent_MatchesTheOracle(uint256 seed, uint16 length) public view {
        string memory s = _text(seed, length, "ab %#25\"{}");
        assertEq(bytes(h.percent(s)), _oraclePercent(bytes(s)));
    }

    /// @dev Percent-decoding the output gives back the input, and the output carries no `#`
    ///      and no `%` that is not an escape.
    function testFuzz_Percent_RoundTrips(uint256 seed, uint16 length) public view {
        bytes memory input = bytes(_text(seed, length, "ab %#25\"{}"));
        bytes memory out = bytes(h.percent(string(input)));
        uint256 j;
        for (uint256 i; i < out.length; ++i) {
            assertTrue(out[i] != "#");
            if (out[i] == "%") {
                assertEq(out[i + 1], "2");
                assertTrue(out[i + 2] == "5" || out[i + 2] == "3");
                assertEq(input[j++], out[i + 2] == "5" ? bytes1("%") : bytes1("#"));
                i += 2;
            } else {
                assertEq(out[i], input[j++]);
            }
        }
        assertEq(j, input.length);
    }
}
