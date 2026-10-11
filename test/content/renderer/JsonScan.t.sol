// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { JsonScan } from "src/content/JsonScan.sol";
import { Utf8 } from "src/libraries/Utf8.sol";

contract JsonScanHarness {
    function object(bytes memory json, bytes32[] memory keys)
        external
        pure
        returns (bool, uint256[] memory)
    {
        return JsonScan.object(json, keys);
    }

    function members(bytes memory json, uint256 start, bytes32[] memory keys)
        external
        pure
        returns (bool, uint256[] memory)
    {
        return JsonScan.members(json, start, keys);
    }

    function elements(bytes memory json, uint256 start, uint256 max)
        external
        pure
        returns (bool, uint256[] memory)
    {
        return JsonScan.elements(json, start, max);
    }

    function records(bytes memory json, uint256 start, bytes32[] memory keys, uint256 max)
        external
        pure
        returns (bool, uint256[] memory)
    {
        return JsonScan.records(json, start, keys, max);
    }

    function slice(bytes memory json, uint256 span) external pure returns (bytes memory) {
        return JsonScan.slice(json, span);
    }

    /// @dev Whether the scanner accepts `json` as one object (no keys collected).
    function accepts(bytes memory json) external pure returns (bool ok) {
        (ok,) = JsonScan.object(json, new bytes32[](0));
    }
}

/// @dev The strict JSON scanner: vectors, spans, limits, and a differential fuzz against
///      Foundry's `parseJsonKeys` (serde_json), which accepts exactly RFC 8259 text.
contract JsonScanTest is Test {
    JsonScanHarness internal h = new JsonScanHarness();

    function _keys1(string memory a) internal pure returns (bytes32[] memory k) {
        k = new bytes32[](1);
        k[0] = keccak256(bytes(a));
    }

    function _text(bytes memory json, uint256 span) internal view returns (string memory) {
        return string(h.slice(json, span));
    }

    function _obj(bytes memory json, bytes32[] memory keys)
        internal
        view
        returns (uint256[] memory s)
    {
        bool ok;
        (ok, s) = h.object(json, keys);
        assertTrue(ok, string(json));
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

        uint256[] memory s = _obj(json, keys);

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

        uint256[] memory s = _obj(json, keys);

        assertEq(_text(json, s[0]), "[ 1 , 2 ]");
        assertEq(_text(json, s[1]), "{ }");
    }

    function test_Object_EmptyObject() public view {
        assertTrue(h.accepts("{}"));
        assertTrue(h.accepts(" { } "));
        assertEq(_obj("{}", _keys1("a"))[0], 0);
    }

    function test_Object_KeysMatchOnTheirTextWithoutQuotes() public view {
        bytes memory json = '{"ab":1,"a":2,"abc":3}';
        assertEq(_text(json, _obj(json, _keys1("a"))[0]), "2");
        assertEq(_text(json, _obj(json, _keys1("ab"))[0]), "1");
        assertEq(_obj(json, _keys1('"a"'))[0], 0);
    }

    function test_Elements_SpansAndLimit() public view {
        bytes memory json = '{"x":["a",1,[2],{"k":"v"},null]}';
        uint256[] memory s = _obj(json, _keys1("x"));
        (bool ok, uint256[] memory e) = h.elements(json, s[0] >> 128, 5);

        assertTrue(ok);
        assertEq(e.length, 5);
        assertEq(_text(json, e[0]), '"a"');
        assertEq(_text(json, e[1]), "1");
        assertEq(_text(json, e[2]), "[2]");
        assertEq(_text(json, e[3]), '{"k":"v"}');
        assertEq(_text(json, e[4]), "null");

        (ok,) = h.elements(json, s[0] >> 128, 4);
        assertFalse(ok, "a fifth element is one too many");
    }

    function test_Elements_EmptyArrayHasNoElements() public view {
        bytes memory json = '{"x":[],"y":[ ]}';
        uint256[] memory s = _obj(json, _keys1("x"));
        (bool ok, uint256[] memory e) = h.elements(json, s[0] >> 128, 8);
        assertTrue(ok);
        assertEq(e.length, 0);
        s = _obj(json, _keys1("y"));
        (ok, e) = h.elements(json, s[0] >> 128, 8);
        assertTrue(ok);
        assertEq(e.length, 0);
    }

    function test_Elements_NotAnArrayIsNotOk() public view {
        bytes memory json = '{"x":{"a":1}}';
        uint256[] memory s = _obj(json, _keys1("x"));
        (bool ok,) = h.elements(json, s[0] >> 128, 8);
        assertFalse(ok);
    }

    function test_Members_OfANestedObject() public view {
        bytes memory json = '{"o":{"a":"x","b":[1]}}';
        uint256[] memory s = _obj(json, _keys1("o"));
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = keccak256("b");
        keys[1] = keccak256("a");
        (bool ok, uint256[] memory m) = h.members(json, s[0] >> 128, keys);
        assertTrue(ok);
        assertEq(_text(json, m[0]), "[1]");
        assertEq(_text(json, m[1]), '"x"');

        (ok,) = h.members('{"o":[1]}', 5, keys); // not an object
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- records

    function _two() internal pure returns (bytes32[] memory k) {
        k = new bytes32[](2);
        k[0] = keccak256("trait_type");
        k[1] = keccak256("value");
    }

    function test_Records_SpansOfEachElementAndItsMembers() public view {
        bytes memory json =
            '{"attributes":[{"trait_type":"a","value":1},{"value":[2,{"x":"}"}],"trait_type":"b\\\\"},{}, { "trait_type" : "c" , "value" : null , "other" : "]" }]}';
        uint256[] memory s = _obj(json, _keys1("attributes"));
        (bool ok, uint256[] memory r) = h.records(json, s[0] >> 128, _two(), 8);

        assertTrue(ok);
        assertEq(r.length, 4 * 3);
        assertEq(_text(json, r[0]), '{"trait_type":"a","value":1}');
        assertEq(_text(json, r[1]), '"a"');
        assertEq(_text(json, r[2]), "1");
        assertEq(_text(json, r[3]), '{"value":[2,{"x":"}"}],"trait_type":"b\\\\"}');
        assertEq(_text(json, r[4]), '"b\\\\"');
        assertEq(_text(json, r[5]), '[2,{"x":"}"}]');
        assertEq(_text(json, r[6]), "{}");
        assertEq(r[7], 0);
        assertEq(r[8], 0);
        assertEq(_text(json, r[10]), '"c"');
        assertEq(_text(json, r[11]), "null");
    }

    function test_Records_LimitsAndWhatIsNotAnObject() public view {
        bytes32[] memory top = _keys1("a");
        bytes memory json = '{"a":[{"k":1},{"k":2}],"b":[1],"c":{},"d":[],"e":[{"k":1,"k":2}]}';
        bytes32[] memory k = _keys1("k");

        uint256[] memory s = _obj(json, top);
        (bool ok, uint256[] memory r) = h.records(json, s[0] >> 128, k, 2);
        assertTrue(ok);
        assertEq(r.length, 4);
        (ok,) = h.records(json, s[0] >> 128, k, 1);
        assertFalse(ok, "one element too many");

        bytes32[] memory more = new bytes32[](4);
        more[0] = keccak256("b");
        more[1] = keccak256("c");
        more[2] = keccak256("d");
        more[3] = keccak256("e");
        s = _obj(json, more);
        (ok,) = h.records(json, s[0] >> 128, k, 4);
        assertFalse(ok, "an element that is a number");
        (ok,) = h.records(json, s[1] >> 128, k, 4);
        assertFalse(ok, "not an array");
        (ok, r) = h.records(json, s[2] >> 128, k, 4);
        assertTrue(ok, "an empty array");
        assertEq(r.length, 0);
        (ok,) = h.records(json, s[3] >> 128, k, 4);
        assertFalse(ok, "a duplicated key inside an element");
    }

    /// @dev The navigation functions never revert and never read outside the text, whatever they
    ///      are given: not JSON, a start past the end, a text that stops in the middle of a value.
    function testFuzz_Navigation_IsSafeOnAnyText(bytes memory json, uint256 start, uint8 pick)
        public
        view
    {
        start = bound(start, 0, json.length + 2);
        bytes32[] memory k = _two();
        if (pick % 3 == 0) h.members(json, start, k);
        if (pick % 3 == 1) h.elements(json, start, 4);
        if (pick % 3 == 2) h.records(json, start, k, 4);
        h.accepts(json);
    }

    function test_Navigation_TextThatStopsInTheMiddleOfAValue() public view {
        bytes memory json = '{"a":[{"k":"x';
        (bool ok,) = h.elements(json, 5, 4);
        assertFalse(ok);
        (ok,) = h.members(json, 6, _keys1("k"));
        assertFalse(ok);
        (ok,) = h.records(json, 5, _keys1("k"), 4);
        assertFalse(ok);
        json = '{"a":[1,2';
        (ok,) = h.elements(json, 5, 4);
        assertFalse(ok);
        (ok,) = h.elements(json, 500, 4);
        assertFalse(ok);
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
            '{"a":"\\u0001\\u12aF\\uFFFF\\ud83d\\ude00"}',
            '{"":1}',
            '{"a":[[[[[[[[]]]]]]]]}',
            '{"a":{"b":{"c":{"d":{"e":{"f":{"g":{}}}}}}}}',
            '{"a":"caf\xc3\xa9 \xf0\x9f\x98\x80"}',
            '{"a":1,"a":2}', // duplicates are fine unless the member is requested
            '{"a":"\\ud800\\udc00\\udbff\\udfff"}'
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

    /// @dev M3: a key that reads the same to every parser. `name` is `name` to a JSON
    ///      parser, so it is refused rather than matched as a different key.
    function test_Keys_NoBackslash() public view {
        assertFalse(h.accepts('{"n\\u0061me":1}'));
        assertFalse(h.accepts('{"a\\nb":1}'));
        assertFalse(h.accepts('{"\\\\":1}'));
        assertTrue(h.accepts('{"a":"\\u0061"}'), "values may hold escapes");
    }

    /// @dev M4: NUL and surrogates. A high surrogate must be followed by a low one, and a low
    ///      one must follow a high one.
    function test_Escapes_NulAndSurrogates() public view {
        assertFalse(h.accepts('{"a":"\\u0000"}'));
        assertFalse(h.accepts('{"a":"x\\u0000"}'));
        assertFalse(h.accepts('{"a":"\\ud800"}'));
        assertFalse(h.accepts('{"a":"\\udbff"}'));
        assertFalse(h.accepts('{"a":"\\udc00"}'));
        assertFalse(h.accepts('{"a":"\\udfff"}'));
        assertFalse(h.accepts('{"a":"\\ud800x"}'));
        assertFalse(h.accepts('{"a":"\\ud800\\u0041"}'));
        assertFalse(h.accepts('{"a":"\\ud800\\ud800"}'));
        assertFalse(h.accepts('{"a":"\\udc00\\ud800"}'));
        assertFalse(h.accepts('{"a":"\\udc00\\udc00"}'));
        assertFalse(h.accepts('{"a":"\\ud800\\udc0"}'));
        assertFalse(h.accepts('{"a":"\\ud800\\u"}'));
        assertFalse(h.accepts('{"a":"\\ud800\\'));
        assertFalse(h.accepts('{"a":"\\ud800'));
        assertTrue(h.accepts('{"a":"\\ud800\\udc00"}'));
        assertTrue(h.accepts('{"a":"\\uD83D\\uDE00\\uD83D\\uDE00"}'));
        assertTrue(h.accepts('{"a":"\\ud7ff\\ue000"}'), "just outside the surrogate range");
    }

    /// @dev Escapes that straddle the end of the text or a 32-byte word are checked, whatever
    ///      their offset.
    function test_Escapes_AtEveryOffsetAndTheExactEnd() public view {
        for (uint256 pad; pad < 70; ++pad) {
            bytes memory a = new bytes(pad);
            for (uint256 i; i < pad; ++i) {
                a[i] = "a";
            }
            assertTrue(h.accepts(bytes.concat('{"k":"', a, '\\u00e9","z":1}')));
            assertTrue(h.accepts(bytes.concat('{"k":"', a, '\\ud83d\\ude00","z":1}')));
            assertTrue(h.accepts(bytes.concat('{"k":"', a, '\\"","z":1}')));
            assertFalse(h.accepts(bytes.concat('{"k":"', a, '\\u00g9","z":1}')));
            assertFalse(h.accepts(bytes.concat('{"k":"', a, '\\ud83d","z":1}')));
            assertFalse(h.accepts(bytes.concat('{"k":"', a, hex"01", '","z":1}')));
            assertFalse(h.accepts(bytes.concat('{"k":"', a, '\\"}')));
            // The four digits (or the pair) run exactly to the end of the text, or one short.
            assertFalse(h.accepts(bytes.concat('{"k":"', a, "\\u00e9")));
            assertFalse(h.accepts(bytes.concat('{"k":"', a, "\\u00e")));
            assertFalse(h.accepts(bytes.concat('{"k":"', a, "\\ud83d\\ude0")));
            assertFalse(h.accepts(bytes.concat('{"k":"', a, "\\ud83d\\ude00")));
        }
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

    /// @dev H2: at most `MAX_VALUES` values: every string, number, literal, array and object.
    function test_Accepts_ValueCap() public view {
        // `{"a":[0,0,...]}`: the array is one value and each 0 another.
        assertTrue(h.accepts(_zeros(JsonScan.MAX_VALUES - 1)));
        assertFalse(h.accepts(_zeros(JsonScan.MAX_VALUES)));
        // Members: `{"a":0,"a":0,...}` is one value per member.
        assertTrue(h.accepts(_members(JsonScan.MAX_VALUES)));
        assertFalse(h.accepts(_members(JsonScan.MAX_VALUES + 1)));
        // Empty arrays and strings count too.
        bytes memory many = "[";
        for (uint256 i; i < 600; ++i) {
            many = bytes.concat(many, i == 0 ? bytes("") : bytes(","), '"",[]');
        }
        assertFalse(h.accepts(bytes.concat('{"a":', many, "]}")));
    }

    function _zeros(uint256 n) internal pure returns (bytes memory json) {
        // The array holds n - 1 zeros: one value for the array, the rest are its elements.
        json = '{"a":[';
        for (uint256 i; i < n; ++i) {
            json = bytes.concat(json, i == 0 ? bytes("0") : bytes(",0"));
        }
        json = bytes.concat(json, "]}");
    }

    function _members(uint256 n) internal pure returns (bytes memory json) {
        json = "{";
        for (uint256 i; i < n; ++i) {
            json = bytes.concat(json, i == 0 ? bytes('"a":0') : bytes(',"a":0'));
        }
        json = bytes.concat(json, "}");
    }

    function test_Object_DuplicateRequestedKeyIsRejected() public view {
        bytes memory json = '{"a":1,"b":2,"a":3}';
        (bool ok,) = h.object(json, _keys1("a"));
        assertFalse(ok);
        // Unrequested duplicates are not tracked.
        (ok,) = h.object(json, _keys1("b"));
        assertTrue(ok);
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
            uint256[] memory s = _obj(json, keys);
            assertEq(h.slice(json, s[0]).length, n + 2);
            assertEq(_text(json, s[1]), "1");
        }
    }

    function test_Numbers() public view {
        assertTrue(h.accepts('{"a":-0.0e-0}'));
        assertFalse(h.accepts('{"a":-}'));
        assertFalse(h.accepts('{"a":--1}'));
        assertFalse(h.accepts('{"a":1.e5}'));
        assertFalse(h.accepts('{"a":0x10}'));
        assertFalse(h.accepts('{"a":Infinity}'));
        assertFalse(h.accepts('{"a":NaN}'));
        assertFalse(h.accepts('{"a":-01}'));
        assertFalse(h.accepts('{"a":00}'));
    }

    function test_NotJsonWhitespaceOrBytes() public view {
        assertFalse(h.accepts(hex"efbbbf7b7d")); // BOM + {}
        assertFalse(h.accepts(hex"0c7b7d")); // form feed
        assertFalse(h.accepts(hex"7b7d00")); // trailing NUL
        assertFalse(h.accepts(hex"a07b7d")); // NBSP
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
    ///      for valid UTF-8 texts. The scanner is never more lenient than JSON: whatever it
    ///      accepts, serde_json accepts. It is stricter in three ways, and only these may make
    ///      it refuse what serde_json takes: a `\u0000` escape, a backslash in a key, and
    ///      nesting above eight levels. The corpus has multi-byte UTF-8, surrogate pairs and
    ///      depth, and the edits make lone surrogates and broken escapes, which serde_json
    ///      refuses as well.
    function testFuzz_AgreesWithSerdeJson(uint256 seed) public view {
        string[8] memory bases = [
            '{"a":[1,-2.5e3,"x\\n\\"y",true,false,null,{"b":{}}],"name":"N","year":2026}',
            '{"attributes":[{"trait_type":"k","value":"v"},{"trait_type":"n","value":3}],"name":"\\u00e9"}',
            ' { "a" : [ ] , "b" : { "c" : [ 1 , 2 ] } , "d" : "\\\\ \\/" } ',
            '{"x":{"y":{"z":[0,1,2,3,{"k":"\\t"}]}},"w":"tail"}',
            '{"name":"caf\xc3\xa9 \xe2\x82\xac \xf0\x9f\x98\x80","d":"\\ud83d\\ude00 \\u20ac"}',
            '{"a":[[[[[[[["deep"]]]]]]]],"b":{"c":{"d":{"e":{"f":"g"}}}}}',
            '{"s":"\\ud800\\udc00","t":"\\udbff\\udfff","u":"\\ud7ff\\ue000"}',
            '{"p":"\xc3\xa9\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80 \\ud83d\\ude00 end","q":[{"r":{"s":[[]]}}]}'
        ];
        bytes memory json = bytes(bases[seed % bases.length]);
        bytes memory alphabet = '{}[]",:\\ 01-+.eEtrufalsnduD8cA\n\x00';
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
        // serde_json reads UTF-8 text; the renderer checks UTF-8 before it scans.
        if (!Utf8.isValid(json)) return;
        // Only objects are in scope (a bare value is no record).
        if (_firstNonSpace(json) != "{") return;

        bool mine = h.accepts(json);
        bool theirs = this.tryParse(string(json));
        if (mine) {
            assertTrue(theirs, "accepted what serde_json refuses");
        } else if (theirs) {
            assertTrue(_stricter(json), "refused what serde_json accepts");
        }
    }

    /// @dev For a text that is valid JSON: whether it has a backslash in a key, a `\u0000`
    ///      escape, or more than eight levels of nesting, the three stricter rules.
    function _stricter(bytes memory json) internal pure returns (bool) {
        uint256 depth;
        uint256 isObject; // bit per level: set for an object
        bool afterOpener = true; // the last significant byte was `{` or `,` (a key may follow)
        for (uint256 i; i < json.length; ++i) {
            bytes1 c = json[i];
            if (c == '"') {
                bool key = afterOpener && depth != 0 && (isObject >> (depth - 1)) & 1 == 1;
                for (++i; json[i] != '"'; ++i) {
                    if (json[i] != "\\") continue;
                    if (key) return true;
                    ++i;
                    if (
                        json[i] == "u" && json[i + 1] == "0" && json[i + 2] == "0"
                            && json[i + 3] == "0" && json[i + 4] == "0"
                    ) return true;
                }
                afterOpener = false;
            } else if (c == "{" || c == "[") {
                if (++depth > 8) return true;
                isObject = (isObject & ~(uint256(1) << (depth - 1)))
                    | (c == "{" ? uint256(1) << (depth - 1) : 0);
                afterOpener = c == "{";
            } else if (c == "}" || c == "]") {
                --depth;
                afterOpener = false;
            } else if (c == ",") {
                afterOpener = true;
            } else if (c != 0x20 && c != 0x09 && c != 0x0a && c != 0x0d) {
                afterOpener = false;
            }
        }
        return false;
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

    // ---------------------------------------------------------------- cost

    function test_Gas_PerByteOfPlainText() public view {
        bytes memory text = new bytes(20_000);
        for (uint256 i; i < text.length; ++i) {
            text[i] = "a";
        }
        bytes memory json = bytes.concat('{"k":"', text, '"}');
        uint256 before = gasleft();
        h.object(json, _keys1("k"));
        // One long string is a handful of cheap word skips (the rest is copying 20 KB through
        // the harness).
        assertLt(before - gasleft(), 300_000);
    }
}
