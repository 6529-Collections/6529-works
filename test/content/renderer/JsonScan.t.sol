// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { JsonScan } from "src/content/JsonScan.sol";
import { Utf8 } from "src/libraries/Utf8.sol";

contract JsonScanHarness {
    function object(bytes memory json, bytes32[] memory keys)
        external
        pure
        returns (uint256[] memory)
    {
        return JsonScan.object(json, keys);
    }

    function elements(bytes memory json, uint256 start, uint256 max)
        external
        pure
        returns (uint256[] memory)
    {
        return JsonScan.elements(json, start, max);
    }

    function slice(bytes memory json, uint256 span) external pure returns (bytes memory) {
        return JsonScan.slice(json, span);
    }

    /// @dev Whether the scanner accepts `json` as one object (no keys collected).
    function accepts(bytes memory json) external view returns (bool) {
        try this.object(json, new bytes32[](0)) returns (uint256[] memory) {
            return true;
        } catch {
            return false;
        }
    }
}

/// @dev The strict JSON scanner: vectors, spans, limits, and a differential fuzz against
///      Foundry's `parseJson` (serde_json), which accepts exactly RFC 8259 text.
contract JsonScanTest is Test {
    JsonScanHarness internal h = new JsonScanHarness();

    function _keys1(string memory a) internal pure returns (bytes32[] memory k) {
        k = new bytes32[](1);
        k[0] = keccak256(bytes(a));
    }

    function _text(bytes memory json, uint256 span) internal view returns (string memory) {
        return string(h.slice(json, span));
    }

    // ---------------------------------------------------------------- spans

    function test_Object_SpansOfTheRequestedMembers() public view {
        bytes memory json = '{"a":1,"b":"two","c":[1,2],"d":{"e":null},"f":true}';
        bytes32[] memory keys = new bytes32[](5);
        keys[0] = keccak256("b");
        keys[1] = keccak256("d");
        keys[2] = keccak256("c");
        keys[3] = keccak256("missing");
        keys[4] = keccak256("f");

        uint256[] memory s = h.object(json, keys);

        assertEq(_text(json, s[0]), '"two"');
        assertEq(_text(json, s[1]), '{"e":null}');
        assertEq(_text(json, s[2]), "[1,2]");
        assertEq(s[3], 0);
        assertEq(_text(json, s[4]), "true");
    }

    function test_Object_WhitespaceEverywhere() public view {
        bytes memory json = ' \t\r\n{ "a" \n: \t[ 1 , 2 ] ,\r\n"b" : { } }\n ';
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = keccak256("a");
        keys[1] = keccak256("b");

        uint256[] memory s = h.object(json, keys);

        assertEq(_text(json, s[0]), "[ 1 , 2 ]");
        assertEq(_text(json, s[1]), "{ }");
    }

    function test_Object_EmptyObject() public view {
        assertTrue(h.accepts("{}"));
        assertTrue(h.accepts(" { } "));
        assertEq(h.object("{}", _keys1("a"))[0], 0);
    }

    function test_Object_KeysMatchOnTheirTextWithoutQuotes() public view {
        bytes memory json = '{"ab":1,"a":2,"abc":3}';
        assertEq(_text(json, h.object(json, _keys1("a"))[0]), "2");
        assertEq(_text(json, h.object(json, _keys1("ab"))[0]), "1");
        assertEq(h.object(json, _keys1("\"a\""))[0], 0);
    }

    function test_Elements_SpansAndLimit() public {
        bytes memory json = '{"x":["a",1,[2],{"k":"v"},null]}';
        uint256[] memory s = h.object(json, _keys1("x"));
        uint256[] memory e = h.elements(json, s[0] >> 128, 5);

        assertEq(e.length, 5);
        assertEq(_text(json, e[0]), '"a"');
        assertEq(_text(json, e[1]), "1");
        assertEq(_text(json, e[2]), "[2]");
        assertEq(_text(json, e[3]), '{"k":"v"}');
        assertEq(_text(json, e[4]), "null");

        vm.expectRevert(JsonScan.JsonInvalid.selector);
        h.elements(json, s[0] >> 128, 4);
    }

    function test_Elements_EmptyArrayHasNoElements() public view {
        bytes memory json = '{"x":[],"y":[ ]}';
        uint256[] memory s = h.object(json, _keys1("x"));
        assertEq(h.elements(json, s[0] >> 128, 8).length, 0);
        s = h.object(json, _keys1("y"));
        assertEq(h.elements(json, s[0] >> 128, 8).length, 0);
    }

    // ---------------------------------------------------------------- what is accepted

    function test_Accepts_ValidDocuments() public view {
        string[16] memory good = [
            "{}",
            '{"a":0}',
            '{"a":-0}',
            '{"a":10.5e-3}',
            '{"a":1E+2}',
            '{"a":0.0}',
            '{"a":true,"b":false,"c":null}',
            '{"a":""}',
            '{"a":"\\"\\\\\\/\\b\\f\\n\\r\\t"}',
            '{"a":"\\u0000\\u12aF\\uFFFF"}',
            '{"":1}',
            '{"a":[[[[[[[[]]]]]]]]}',
            '{"a":{"b":{"c":{"d":{"e":{"f":{"g":{}}}}}}}}',
            '{"a":"caf\xc3\xa9 \xf0\x9f\x98\x80"}',
            '{"a":1,"a":2}', // duplicates are fine unless the member is requested
            '{"a\\n":1}'
        ];
        for (uint256 i; i < good.length; ++i) {
            assertTrue(h.accepts(bytes(good[i])), good[i]);
        }
    }

    function test_Accepts_RejectsInvalidDocuments() public view {
        string[28] memory bad = [
            "",
            " ",
            "{",
            "}",
            "[]",
            '"a"',
            "1",
            "{} {}",
            "{}x",
            '{"a"}',
            '{"a":}',
            '{"a":1,}',
            '{,"a":1}',
            '{"a":1 "b":2}',
            "{a:1}",
            "{'a':1}",
            '{"a":+1}',
            '{"a":.5}',
            '{"a":1.}',
            '{"a":01}',
            '{"a":1e}',
            '{"a":tru}',
            '{"a":nulll}',
            '{"a":"x}',
            '{"a":"\\x"}',
            '{"a":"\\u12"}',
            '{"a":"\\u12G4"}',
            '{"a":[1,]}'
        ];
        for (uint256 i; i < bad.length; ++i) {
            assertFalse(h.accepts(bytes(bad[i])), bad[i]);
        }
        // A raw control byte, or a string that runs to the end of the text.
        assertFalse(h.accepts(hex"7b2261223a22610a62227d"));
        assertFalse(h.accepts(hex"7b2261223a2261007b"));
        assertFalse(h.accepts('{"a":"\\'));
        assertFalse(h.accepts('{"a":"\\u123'));
    }

    function test_Accepts_NestingIsLimitedToEightLevels() public view {
        // `{"a":` + n arrays: the object is level 0, so eight arrays are allowed.
        assertTrue(h.accepts(_nest(8)));
        assertFalse(h.accepts(_nest(9)));
    }

    function _nest(uint256 n) internal pure returns (bytes memory json) {
        json = '{"a":';
        for (uint256 i; i < n; ++i) {
            json = bytes.concat(json, "[");
        }
        for (uint256 i; i < n; ++i) {
            json = bytes.concat(json, "]");
        }
        json = bytes.concat(json, "}");
    }

    function test_Object_DuplicateRequestedKeyIsRejected() public {
        bytes memory json = '{"a":1,"b":2,"a":3}';
        vm.expectRevert(JsonScan.JsonInvalid.selector);
        h.object(json, _keys1("a"));
        // Unrequested duplicates are not tracked.
        h.object(json, _keys1("b"));
    }

    function test_Strings_LongStringsAcrossWordBoundaries() public view {
        for (uint256 n = 0; n < 100; ++n) {
            bytes memory text = new bytes(n);
            for (uint256 i; i < n; ++i) {
                text[i] = i % 7 == 6 ? bytes1("\\") : bytes1("a");
                if (i % 7 == 6) {
                    // Keep every backslash a valid escape by making it the first of a pair.
                    if (i + 1 < n) {
                        text[i + 1] = "n";
                        ++i;
                    } else {
                        text[i] = "a";
                    }
                }
            }
            bytes memory json = bytes.concat('{"k":"', text, '","z":1}');
            bytes32[] memory keys = new bytes32[](2);
            keys[0] = keccak256("k");
            keys[1] = keccak256("z");
            uint256[] memory s = h.object(json, keys);
            assertEq(h.slice(json, s[0]).length, n + 2);
            assertEq(_text(json, s[1]), "1");
        }
    }

    // ---------------------------------------------------------------- differential fuzz

    /// @dev Whether serde_json parses `json` as an object. (`parseJson` also rejects numbers
    ///      that are not whole, such as 2.5e-3, because it ABI-encodes them; listing the keys
    ///      only parses.)
    function tryParse(string memory json) external pure returns (bool) {
        try vm.parseJsonKeys(json, "$") returns (string[] memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Mutates a valid document at a few places and compares the verdict with serde_json's,
    ///      for the texts both can judge: valid UTF-8 objects without surrogate escapes.
    function testFuzz_AgreesWithSerdeJson(uint256 seed) public view {
        string[4] memory bases = [
            '{"a":[1,-2.5e3,"x\\n\\"y",true,false,null,{"b":{}}],"name":"N","year":2026}',
            '{"attributes":[{"trait_type":"k","value":"v"},{"trait_type":"n","value":3}],"name":"\\u00e9"}',
            ' { "a" : [ ] , "b" : { "c" : [ 1 , 2 ] } , "d" : "\\\\ \\/" } ',
            '{"x":{"y":{"z":[0,1,2,3,{"k":"\\t"}]}},"w":"tail"}'
        ];
        bytes memory json = bytes(bases[seed % bases.length]);
        bytes memory alphabet = '{}[]",:\\ 01-+.eEtrufalsn\n\x00';
        uint256 edits = 1 + (seed >> 8) % 3;
        for (uint256 k; k < edits; ++k) {
            seed = uint256(keccak256(abi.encode(seed, k)));
            uint256 pos = seed % json.length;
            uint256 op = (seed >> 64) % 3;
            bytes1 c = alphabet[(seed >> 128) % alphabet.length];
            if (op == 0) {
                json[pos] = c;
            } else if (op == 1) {
                json = bytes.concat(_cut(json, 0, pos), bytes1(c), _cut(json, pos, json.length));
            } else if (json.length > 2) {
                json = bytes.concat(_cut(json, 0, pos), _cut(json, pos + 1, json.length));
            }
        }
        if (!Utf8.isValid(json) || json.length == 0) return;
        // Out of scope for the oracle: a lone surrogate escape (serde_json rejects it) and a
        // top level that is not an object (the scanner wants an object).
        if (_hasSurrogateEscape(json) || _firstNonSpace(json) != "{") return;

        assertEq(h.accepts(json), this.tryParse(string(json)), vm.toString(json));
    }

    function _cut(bytes memory b, uint256 from, uint256 to)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(to - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[from + i];
        }
    }

    function _firstNonSpace(bytes memory b) internal pure returns (bytes1) {
        for (uint256 i; i < b.length; ++i) {
            if (b[i] != 0x20 && b[i] != 0x09 && b[i] != 0x0a && b[i] != 0x0d) return b[i];
        }
        return 0;
    }

    function _hasSurrogateEscape(bytes memory b) internal pure returns (bool) {
        for (uint256 i; i + 3 < b.length; ++i) {
            if (
                b[i] == "\\" && (b[i + 1] == "u" || b[i + 1] == "U")
                    && (b[i + 2] == "d" || b[i + 2] == "D")
            ) {
                return true;
            }
        }
        return false;
    }

    // ---------------------------------------------------------------- cost

    function test_Gas_PerByteOfPlainText() public view {
        bytes memory text = new bytes(20_000);
        for (uint256 i; i < text.length; ++i) {
            text[i] = "a";
        }
        bytes memory json = bytes.concat('{"k":"', text, '"}');
        uint256 before = gasleft();
        h.object(json, _keys1("k"));
        // One long string is a handful of cheap word skips (the rest is copying 20 KB through the harness).
        assertLt(before - gasleft(), 300_000);
    }
}
