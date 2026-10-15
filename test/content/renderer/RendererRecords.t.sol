// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Rec, RendererBase } from "./RendererBase.sol";
import { RendererEditionsMock } from "../../mocks/content/RendererMocks.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { SSTORE2 } from "src/libraries/SSTORE2.sol";
import { License, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";

/// @notice The work record as the renderer reads it: the JSON it accepts (strict, with bounded
///         nesting, values, escapes and attributes, and a size limit), what it copies into the
///         metadata, the trait names reserved for its own traits, and every record it refuses
///         (falling back to core-only metadata marked `invalid`). Many of these cases began as
///         the PR #20 review's demonstrations, and each now has a defined, safe outcome.
contract RendererRecordsTest is RendererBase {
    bytes internal png = hex"89504e470d0a1a0a0000000d49484452";

    function _raw(bytes memory json) internal {
        _installRaw(json, _media(_file(png, IDENTITY, "image/png"), 0));
    }

    /// @dev Whether serde_json (Rust indexers, Foundry) parses `json` as an object.
    function parses(string memory json) external pure returns (bool) {
        try vm.parseJsonKeys(json, "$") returns (string[] memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _bytes(string memory a, string memory b) internal pure returns (bytes memory) {
        return bytes.concat(bytes(a), bytes(b));
    }

    function _fill(bytes memory unit, uint256 n) internal pure returns (bytes memory j) {
        j = new bytes(n);
        for (uint256 i; i < n; ++i) {
            j[i] = unit[i % unit.length];
        }
    }

    // ---------------------------------------------------------------- structure and copying

    function test_Record_WhitespaceAndUnknownMembersAreAccepted() public {
        _raw(
            bytes(
                ' { "files" : { "a.js" : 0 } , "name" : "N" , "dependencies" : [ { "name" : "p5", "version" : "1.9.0" } ] ,'
                ' "extra": [ 1, -2.5e3, true, false, null, { "k": [ ] } ], "year": 1999 , "attributes" : [ ] } '
            )
        );

        string memory j = _out();

        assertEq(_str(j, ".name"), "N");
        assertEq(_str(j, ".description"), "");
        assertEq(_attrNum(j, "Year"), 1999);
    }

    function test_Record_NumbersAndStringsAsAttributeValues() public {
        _raw(
            bytes(
                '{"attributes":[{"trait_type":"Rank","value":3},{"trait_type":"Score","value":-1.5e2},'
                '{"trait_type":"Mood","value":"calm"}],"name":"N"}'
            )
        );

        string memory j = _out();

        assertEq(_attrNum(j, "Rank"), 3);
        assertEq(vm.parseJsonInt(j, _at(_attrIndex(j, "Score"), ".value")), -150);
        assertEq(_attr(j, "Mood"), "calm");
    }

    function test_Record_PercentAndHashInRecordStringsSurviveTheUri() public {
        _raw(bytes('{"description":"100% #1 %25","name":"a#b%c"}'));

        string memory j = _out();

        assertEq(_str(j, ".name"), "a#b%c");
        assertEq(_str(j, ".description"), "100% #1 %25");
    }

    function test_Record_EscapesAreCopiedAsTheyAre() public {
        _raw(bytes('{"description":"q\\" b\\\\ s\\/ \\n \\u00e9 \\ud83d\\ude00","name":"N"}'));

        assertEq(
            _str(_out(), ".description"),
            string(bytes.concat('q" b\\ s/ \n ', hex"c3a9", " ", hex"f09f9880"))
        );
    }

    function test_Record_MalformedRecordsFallBackToCoreOnly() public {
        string[13] memory bad = [
            "{",
            '{"name":"N"',
            '{"name":"N"} x',
            "{\"name\":N}",
            '{"name":"N",}',
            "{\"name\":\"a\nb\"}", // a raw newline inside a string
            '{"name":"\\x"}', // an unknown escape
            '{"name":"\\u12G4"}', // a bad unicode escape
            '{"name":"N","year":01}',
            '{"name":"N","year":1.}',
            '{"name":"N","extra":tru}',
            '{"name":"unterminated}',
            '["name"]'
        ];
        for (uint256 i; i < bad.length; ++i) {
            _raw(bytes(bad[i]));
            _assertCoreOnly("invalid");
        }
    }

    function test_Record_NestingBeyondTheLimitFallsBack() public {
        _raw(_nested(9));
        _assertCoreOnly("invalid");

        // Eight levels are fine.
        _raw(_nested(8));
        assertEq(_str(_out(), ".name"), "N");
    }

    function _nested(uint256 levels) internal pure returns (bytes memory json) {
        json = '{"name":"N","x":';
        for (uint256 i; i < levels; ++i) {
            json = bytes.concat(json, "[");
        }
        json = bytes.concat(json, "1");
        for (uint256 i; i < levels; ++i) {
            json = bytes.concat(json, "]");
        }
        json = bytes.concat(json, "}");
    }

    function test_Record_DuplicatedMembersFallBack() public {
        string[2] memory bad = ['{"name":"A","name":"B"}', '{"name":"A","year":1,"year":2}'];
        for (uint256 i; i < bad.length; ++i) {
            _raw(bytes(bad[i]));
            _assertCoreOnly("invalid");
        }
    }

    function test_Record_WrongTypesAndMissingNameAreRejected() public {
        string[11] memory bad = [
            '{"description":"no name"}',
            '{"name":""}',
            '{"name":5}',
            '{"name":"N","description":5}',
            '{"name":"N","medium":[]}',
            '{"name":"N","year":"2026"}',
            '{"name":"N","year":[1]}',
            '{"name":"N","artists":[1]}',
            '{"name":"N","artists":[""]}',
            '{"name":"N","artists":"Ada"}',
            '{"name":"N","attributes":5}'
        ];
        for (uint256 i; i < bad.length; ++i) {
            _raw(bytes(bad[i]));
            _assertCoreOnly("invalid");
        }
        // An attribute is an object with a string name and a string or number value; nothing
        // else is vouched for.
        string[8] memory badTraits = [
            '{"name":"N","attributes":[5]}',
            '{"name":"N","attributes":[{"value":1}]}',
            '{"name":"N","attributes":[{"trait_type":"k"}]}',
            '{"name":"N","attributes":[{"trait_type":5,"value":1}]}',
            '{"name":"N","attributes":[{"trait_type":"k","value":true}]}',
            '{"name":"N","attributes":[{"trait_type":"k","value":null}]}',
            '{"name":"N","attributes":[{"trait_type":"k","value":[1]}]}',
            '{"name":"N","attributes":[{"trait_type":"k","value":{}}]}'
        ];
        for (uint256 i; i < badTraits.length; ++i) {
            _raw(bytes(badTraits[i]));
            _assertCoreOnly("invalid");
        }
    }

    /// @dev Decision M2: the renderer never reverts for a record: it says so and shows the core.
    function test_Record_AnInvalidRecordKeepsTheChainTraits() public {
        _raw(bytes('{"name":5}'));
        IStream.WorkCore memory core = _core();
        core.collectionId = 3;
        core.serial = 12;
        core.artistId = 0xabc;
        stream.setWork(ID, core);
        stream.setCollection(3, IStream.Collection("Spring", bytes32(0), 12));
        disputeLog.set(address(stream), ID, bytes32(uint256(9)));

        string memory j = _out();

        assertEq(_str(j, ".name"), "Spring #12");
        assertEq(_str(j, ".record_status"), "invalid");
        assertEq(_attr(j, "Collection"), "Spring");
        assertEq(_attr(j, "Artist ID"), "0x0abc");
        assertEq(_attr(j, "Dispute statement"), vm.toString(bytes32(uint256(9))));
    }

    function test_Record_ARecordThatIsFineHasNoRecordStatus() public {
        _raw(bytes('{"name":"N"}'));
        assertFalse(_has(_out(), ".record_status"));
    }

    function test_Record_AttributesAreCopiedAfterTheRenderersOwnTraits() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _installRaw(
            bytes(
                '{"attributes": [ {"trait_type":"Mood","value":"calm"} , {"trait_type":"N","value":3} ],"name":"N"}'
            ),
            _media(file, 0)
        );
        IStream.WorkCore memory core = _core();
        core.collectionId = 1;
        core.serial = 4;
        stream.setWork(ID, core);
        stream.setCollection(1, IStream.Collection("C", bytes32(0), 4));

        string memory j = _out();

        assertEq(_str(j, ".attributes[0].trait_type"), "Collection");
        assertEq(_str(j, ".attributes[1].trait_type"), "Serial");
        assertEq(_str(j, ".attributes[2].trait_type"), "Mood");
        assertEq(_str(j, ".attributes[2].value"), "calm");
        assertEq(_attrNum(j, "N"), 3);
    }

    function test_Record_EmptyOrBlankAttributesLeaveOnlyTheRenderersTraits() public {
        string[3] memory docs = [
            '{"attributes":[],"artists":["Ada"],"name":"N"}',
            '{"attributes":[ \n ],"artists":["Ada"],"name":"N"}',
            '{"artists":["Ada"],"name":"N"}'
        ];
        bytes32 file = _file(png, IDENTITY, "image/png");
        for (uint256 i; i < docs.length; ++i) {
            _installRaw(bytes(docs[i]), _media(file, 0));
            string memory j = _out();
            assertEq(_attr(j, "Artist"), "Ada");
            assertFalse(_has(j, _at(1, "")), "one trait only");
        }
        // And with nothing of the renderer's own, the record's attributes stand alone.
        _installRaw(
            bytes('{"attributes":[{"trait_type":"k","value":"v"}],"name":"N"}'), _media(file, 0)
        );
        assertEq(_attr(_out(), "k"), "v");
        assertFalse(_has(_out(), _at(1, "")));
    }

    function test_Record_TooManyArtistsFallBack() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        Rec memory r = _rec();
        r.artists = new string[](Limits.MAX_ARTISTS);
        for (uint256 i; i < r.artists.length; ++i) {
            r.artists[i] = "x";
        }
        _install(file, r);
        assertEq(_str(_out(), ".name"), "Title"); // the limit itself is fine

        r.artists = new string[](Limits.MAX_ARTISTS + 1);
        for (uint256 i; i < r.artists.length; ++i) {
            r.artists[i] = "x";
        }
        _install(file, r);
        _assertCoreOnly("invalid");
    }

    function test_Record_MustBeAnIdentityFileWithinTheSizeLimit() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        IWorkRecords.RecordInfo memory info = _info();

        info.recordFileId = _file(bytes('{"name":"N"}'), GZIP, "application/json");
        _setRecordInfo(info);
        _assertCoreOnly("invalid");

        info.recordFileId = _file(bytes('{"name":"N"}'), BASE64, "application/json");
        _setRecordInfo(info);
        _assertCoreOnly("invalid");

        // One byte over the limit.
        info.recordFileId =
            _file(_data(Limits.MAX_RECORD_BYTES + 1, 2), IDENTITY, "application/json");
        _setRecordInfo(info);
        _assertCoreOnly("invalid");
    }

    /// @dev A record of at most `Limits.MAX_RECORD_BYTES` is a single store chunk, so it is read
    ///      with one `readChunk`, and the shared limit is what the renderer reads.
    function test_Record_TheLimitFitsOneStoreChunk() public pure {
        assertLe(Limits.MAX_RECORD_BYTES, SSTORE2.MAX_CHUNK_LENGTH);
        assertEq(Limits.MAX_RECORD_BYTES, 12_288);
        assertEq(Limits.MAX_ARTISTS, 16);
    }

    function test_Record_ARecordOfExactlyTheLimitIsRead() public {
        // A record padded with whitespace to exactly the limit.
        bytes memory json = '{"name":"N"}';
        uint256 limit = Limits.MAX_RECORD_BYTES;
        bytes memory padded = new bytes(limit);
        for (uint256 i; i < limit; ++i) {
            padded[i] = i < json.length ? json[i] : bytes1(" ");
        }
        _raw(padded);
        assertEq(_str(_out(), ".name"), "N");
    }

    /// @dev A record one byte over the limit is invalid even when it is otherwise a fine record
    ///      (white space after the closing brace), and at the limit it is read.
    function test_Record_OneByteOverTheLimitIsInvalid() public {
        bytes memory json = '{"name":"N"}';
        uint256 limit = Limits.MAX_RECORD_BYTES;
        bytes memory padded = new bytes(limit + 1);
        for (uint256 i; i < padded.length; ++i) {
            padded[i] = i < json.length ? json[i] : bytes1(" ");
        }
        _raw(padded);
        _assertCoreOnly("invalid");
        bytes memory exact = new bytes(limit);
        for (uint256 i; i < exact.length; ++i) {
            exact[i] = padded[i];
        }
        _raw(exact);
        assertEq(_str(_out(), ".name"), "N");
    }

    /// Regression: CONTENT-2 (docs/security/internal-review-2026-10.md)
    /// @dev CONTENT-2: a record file the store does not know (an approved manifest never
    ///      registered) is not complete: core-only metadata, never a revert. The primary file's
    ///      own read still fails closed (`test_Store_AnOversizedFileInfoFailsClosed`).
    function test_Record_NotAFileTheStoreKnowsIsIncomplete() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        IWorkRecords.RecordInfo memory info = _info();
        info.recordFileId = bytes32(uint256(0xdead));
        _setRecordInfo(info);
        _assertCoreOnly("incomplete");
        vm.expectRevert(
            abi.encodeWithSelector(IRenderer.RendererNotInlineable.selector, address(stream), ID)
        );
        renderer.fullTokenURI(address(stream), ID);
    }

    // ---------------------------------------------------------------- keys and strings

    /// Regression: M3 in the review of #20
    /// @dev `name` is `name` to every JSON parser. Matched on its raw text it would be a
    ///      second `name` to the renderer only; a key with a backslash makes the record invalid.
    function test_Record_AKeyWithAnEscapeIsInvalid() public {
        string[4] memory bad = [
            '{"name":"Shown","n\\u0061me":"Seen by curators"}',
            '{"n\\u0061me":"N"}',
            '{"name":"N","a\\nb":1}',
            '{"name":"N","x":{"\\u0061":1}}'
        ];
        for (uint256 i; i < bad.length; ++i) {
            _raw(bytes(bad[i]));
            _assertCoreOnly("invalid");
        }
        // A backslash in a value is as good as ever.
        _raw(bytes('{"name":"N\\u0061","description":"a\\nb"}'));
        assertEq(_str(_out(), ".name"), "Na");
    }

    /// Regression: M4 in the review of #20
    function test_Record_NulAndLoneSurrogatesAreInvalid() public {
        string[8] memory bad = [
            '{"name":"a\\u0000b"}',
            '{"name":"\\ud800"}',
            '{"name":"\\udbff"}',
            '{"name":"\\udc00"}',
            '{"name":"\\udfff"}',
            '{"name":"\\ud800x"}',
            '{"name":"\\ud800\\u0041"}',
            '{"name":"N","description":"\\udc00\\ud800"}'
        ];
        for (uint256 i; i < bad.length; ++i) {
            _raw(bytes(bad[i]));
            _assertCoreOnly("invalid");
        }
        // A pair is fine, and the output is JSON every parser reads.
        _raw(bytes('{"name":"\\ud83d\\ude00 \\ud7ff \\ue000"}'));
        string memory j = _out();
        assertTrue(this.parses(j));
        assertEq(
            _str(j, ".name"),
            string(bytes.concat(hex"f09f9880", " ", hex"ed9fbf", " ", hex"ee8080"))
        );
    }

    /// Regression: M4 in the review of #20
    /// @dev Whatever a record says in its strings, if the renderer accepts it the output is JSON
    ///      that serde_json reads, and the text comes back as written.
    function testFuzz_Record_AcceptedRecordsGiveJsonEveryParserReads(uint256 seed, uint8 length)
        public
    {
        string[14] memory pieces = [
            "a",
            " ",
            "%",
            "#",
            '\\"',
            "\\\\",
            "\\n",
            "\\u00e9",
            "\\u0000",
            "\\ud83d",
            "\\ude00",
            "\\ud83d\\ude00",
            "\\u2028",
            string(bytes(hex"f09f9a80"))
        ];
        bytes memory text;
        for (uint256 i; i < length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            text = bytes.concat(text, bytes(pieces[seed % pieces.length]));
        }
        _raw(bytes.concat('{"name":"N","description":"', text, '"}'));

        string memory j = _out();

        if (_has(j, ".record_status")) {
            assertEq(_str(j, ".record_status"), "invalid");
        } else {
            assertTrue(this.parses(j), "serde_json reads the output");
        }
    }

    // ---------------------------------------------------------------- bounds

    /// Regression: H2 in the review of #20
    function test_Record_TheYearIsAnIntegerOfAtMostSixDigits() public {
        string[6] memory good = ["2026", "-500", "0", "999999", "-999999", "1"];
        for (uint256 i; i < good.length; ++i) {
            _raw(_bytes('{"name":"N","year":', string.concat(good[i], "}")));
            assertEq(
                vm.parseJsonInt(_out(), _at(_attrIndex(_out(), "Year"), ".value")),
                vm.parseInt(good[i])
            );
        }
        string[9] memory bad =
            ["1000000", "-1000000", "1e400", "1e3", "2026.5", "2026.0", "1E2", '"2026"', "null"];
        for (uint256 i; i < bad.length; ++i) {
            _raw(_bytes('{"name":"N","year":', string.concat(bad[i], "}")));
            _assertCoreOnly("invalid");
        }
        // A thousand digits are a number JSON allows, and no year.
        _raw(bytes.concat('{"name":"N","year":1', _fill("0", 1_000), "}"));
        _assertCoreOnly("invalid");
    }

    /// Regression: H2 in the review of #20
    function test_Record_AtMostTheCapOfPercentAndHashEscapes() public {
        uint256 cap = MAX_ESCAPES;
        bytes memory open = '{"name":"N","description":"';
        // `%` and `#` together make the count.
        _raw(bytes.concat(open, _fill("%#", cap), '"}'));
        string memory j = _out();
        assertEq(bytes(_str(j, ".description")).length, cap);
        _raw(bytes.concat(open, _fill("%#", cap + 1), '"}'));
        _assertCoreOnly("invalid");
        // Ordinary text between them does not count.
        _raw(bytes.concat(open, _fill("a%", 2 * cap), '"}'));
        assertEq(bytes(_str(_out(), ".description")).length, 2 * cap);
        _raw(bytes.concat(open, _fill("a%", 2 * cap + 2), '"}'));
        _assertCoreOnly("invalid");
    }

    /// Regression: H2 in the review of #20
    function test_Record_AtMostTheCapOfAttributes() public {
        uint256 cap = MAX_ATTRIBUTES;
        bytes memory one = '{"trait_type":"k","value":1}';
        for (uint256 n = cap; n <= cap + 1; ++n) {
            bytes memory list;
            for (uint256 i; i < n; ++i) {
                list = bytes.concat(list, i == 0 ? bytes("") : bytes(","), one);
            }
            _raw(bytes.concat('{"name":"N","attributes":[', list, "]}"));
            if (n == cap) {
                assertTrue(_has(_out(), _at(cap - 1, "")));
                assertFalse(_has(_out(), _at(cap, "")));
            } else {
                _assertCoreOnly("invalid");
            }
        }
    }

    /// Regression: H2 in the review of #20
    function test_Record_AtMostTheCapOfJsonValues() public {
        // `name` and its value, `a` and the array are six units (a top-level key is two), and
        // each zero is one: 1,018 are the most.
        uint256 cap = 1_024;
        bytes memory open = '{"name":"N","a":[0';
        _raw(bytes.concat(open, _fill(",0", 2 * (cap - 7)), "]}"));
        assertEq(_str(_out(), ".name"), "N");
        _raw(bytes.concat(open, _fill(",0", 2 * (cap - 6)), "]}"));
        _assertCoreOnly("invalid");
        // Top-level members are three units each: 340 of them and `name` are the most.
        _raw(bytes.concat('{"name":"N"', _fill(',"a":0', 6 * 340), "}"));
        assertEq(_str(_out(), ".name"), "N");
        _raw(bytes.concat('{"name":"N"', _fill(',"a":0', 6 * 341), "}"));
        _assertCoreOnly("invalid");
    }

    // ---------------------------------------------------------------- strict JSON

    /// Regression: N1 in the second review of #20
    /// @dev `@` and the backtick are not hex digits; a record with one in a `\u` escape is
    ///      invalid, wherever the escape is (the name, a description, a trait name, a surrogate).
    function test_Record_ABadHexDigitInAnEscapeIsInvalid() public {
        string[6] memory bad = [
            '{"name":"Title\\u004@"}',
            '{"name":"N","description":"\\u`041"}',
            '{"name":"N","description":"\\ud800\\udc0@"}',
            '{"name":"N","attributes":[{"trait_type":"Seed\\u00@@","value":"x"}]}',
            '{"name":"N","attributes":[{"trait_type":"k","value":"\\u004g"}]}',
            '{"name":"N","artists":["\\u00G1"]}'
        ];
        for (uint256 i; i < bad.length; ++i) {
            _raw(bytes(bad[i]));
            _assertCoreOnly("invalid");
        }
    }

    /// Regression: N2 in the second review of #20
    /// @dev A number that is out of the binary64 range is invalid (serde_json refuses the
    ///      whole document and JavaScript reads Infinity), as an attribute value or anywhere.
    function test_Record_ANumberOutOfRangeIsInvalid() public {
        string[5] memory bad = [
            '{"name":"N","attributes":[{"trait_type":"Size","value":1e400}]}',
            '{"name":"N","attributes":[{"trait_type":"Size","value":-1e999}]}',
            '{"name":"N","ignored":1e400}',
            '{"name":"N","ignored":[1e100]}',
            '{"name":"N","attributes":[{"trait_type":"Size","value":0.0000000000000000000000001}]}'
        ];
        for (uint256 i; i < bad.length; ++i) {
            _raw(bytes(bad[i]));
            _assertCoreOnly("invalid");
        }
        // The largest the scanner takes is finite everywhere.
        _raw(bytes('{"name":"N","attributes":[{"trait_type":"Size","value":-9.99999999999e+99}]}'));
        string memory j = _out();
        assertFalse(_has(j, ".record_status"));
        assertTrue(this.parses(j), "serde_json reads the output");
    }

    /// Regression: N3 in the second review of #20
    /// @dev A member twice in an attribute (`display_type` here) is a record that parsers read
    ///      differently (first wins, last wins, an error): it is invalid, and so is an attribute
    ///      with a member that is not one of the four OpenSea keys.
    function test_Record_ADuplicatedAttributeMemberIsInvalid() public {
        _raw(
            bytes(
                '{"name":"N","attributes":[{"trait_type":"When","value":1700000000,"display_type":"date","display_type":"number"}]}'
            )
        );
        _assertCoreOnly("invalid");
        _raw(
            bytes(
                '{"name":"N","attributes":[{"trait_type":"When","value":1,"trait_type":"Other"}]}'
            )
        );
        _assertCoreOnly("invalid");
        // One display type is what OpenSea documents, and is copied as it is.
        _raw(
            bytes(
                '{"name":"N","attributes":[{"trait_type":"When","value":1700000000,"display_type":"date","max_value":5}]}'
            )
        );
        string memory j = _out();
        assertFalse(_has(j, ".record_status"));
        assertEq(_str(j, _at(_attrIndex(j, "When"), ".display_type")), "date");
        // The four keys are all there is: any other member, or a fifth, is invalid.
        string[4] memory other = [
            '{"trait_type":"k","value":1,"rarity":2}',
            '{"trait_type":"k","value":1,"display_type":"date","max_value":5,"a":1}',
            '{"trait_type":"k","value":1,"Max_Value":5}',
            '{"trait_type":"k","value":1,"max_value ":5}'
        ];
        for (uint256 i; i < other.length; ++i) {
            _raw(bytes.concat('{"name":"N","attributes":[', bytes(other[i]), "]}"));
            _assertCoreOnly("invalid");
        }
        // Each of the four may be missing (the two required ones are checked as before).
        _raw(
            bytes(
                '{"name":"N","attributes":[{"max_value":5,"value":2,"trait_type":"k"},{"trait_type":"m","value":"x","display_type":"number"}]}'
            )
        );
        assertFalse(_has(_out(), ".record_status"));
    }

    /// Regression: H2 in the second review of #20
    /// @dev Every backslash escape counts against the 1,024 of values: a description of
    ///      escapes is accepted up to the budget, and refused beyond it.
    function test_Record_EscapesCountAgainstTheValueBudget() public {
        bytes memory open = '{"name":"N","description":"';
        // `name` and `description` with their keys are six units, so 1,018 escapes make 1,024.
        _raw(bytes.concat(open, _fill("\\n", 2 * 1_018), '"}'));
        assertEq(bytes(_str(_out(), ".description")).length, 1_018);
        _raw(bytes.concat(open, _fill("\\n", 2 * 1_019), '"}'));
        _assertCoreOnly("invalid");
        _raw(bytes.concat(open, _fill("\\u00e9", 6 * 1_018), '"}'));
        assertEq(bytes(_str(_out(), ".description")).length, 2 * 1_018);
        _raw(bytes.concat(open, _fill("\\ud83d\\ude00", 12 * 509), '"}'));
        assertEq(bytes(_str(_out(), ".description")).length, 4 * 509);
        _raw(bytes.concat(open, _fill("\\ud83d\\ude00", 12 * 510), '"}'));
        _assertCoreOnly("invalid");
        // The record that is all escapes, as long as one can be.
        _raw(bytes.concat(open, _fill("\\\\", 12_288 - open.length - 2), '"}'));
        _assertCoreOnly("invalid");
    }

    // ---------------------------------------------------------------- reserved trait names

    function _traitRecord(string memory name) internal pure returns (bytes memory) {
        return bytes(
            string.concat('{"attributes":[{"trait_type":"', name, '","value":"v"}],"name":"N"}')
        );
    }

    /// Regression: L2 in the review of #20
    /// @dev The ten names the renderer writes are the ones a record may not use.
    function test_TraitNames_ARecordCannotUseARendererTraitName() public {
        string[10] memory reserved = [
            "Artist",
            "Artist ID",
            "Year",
            "Medium",
            "Dimensions",
            "Collection",
            "Serial",
            "Edition of",
            "Seed",
            "Dispute statement"
        ];
        for (uint256 i; i < reserved.length; ++i) {
            _raw(_traitRecord(reserved[i]));
            _assertCoreOnly("invalid");
        }
        // The same names spelled with an escape for an ASCII character.
        string[4] memory escaped =
            ["\\u0041rtist", "Ye\\u0061r", "Dispute\\u0020statement", "S\\u0065ed"];
        for (uint256 i; i < escaped.length; ++i) {
            _raw(_traitRecord(escaped[i]));
            _assertCoreOnly("invalid");
        }
    }

    /// Regression: L2 in the review of #20
    function test_TraitNames_OtherNamesAreFine() public {
        string[10] memory fine = [
            "Artists",
            "Year 2",
            "Seed2",
            "Edition",
            "Dispute",
            "Dispute statements",
            "Palette",
            "Cafe",
            "A'B 100% #1",
            ""
        ];
        for (uint256 i; i < fine.length; ++i) {
            _raw(_traitRecord(fine[i]));
            string memory j = _out();
            assertFalse(_has(j, ".record_status"), fine[i]);
            assertEq(_str(j, ".attributes[0].value"), "v");
        }
    }

    /// Regression: CONTENT-5 (docs/security/internal-review-2026-10.md)
    /// @dev The renderer's names are matched in any case and with any spaces, and two
    ///      spaces in a row are refused, so a name that displays like one of them (`Artist ID`,
    ///      `SEED`, `Serial `, `ArtistID`, `Artist  ID`) is refused.
    function test_TraitNames_ReservedInAnyCaseAndSpacing() public {
        string[14] memory alike = [
            "artist",
            "ARTIST ID",
            "ArtistID",
            "Artist  ID",
            " Year",
            "Year ",
            "Me dium",
            "dimensions",
            "COLLECTION",
            "Serial   ",
            "EditionOf",
            "SEED",
            "Dispute Statement",
            "d i s p u t e s t a t e m e n t"
        ];
        for (uint256 i; i < alike.length; ++i) {
            _raw(_traitRecord(alike[i]));
            _assertCoreOnly("invalid");
        }
        // Long names made of spaces around a reserved name are refused (two spaces in a row).
        _raw(_traitRecord(string.concat(string(_fill(" ", 200)), "Seed", string(_fill(" ", 200)))));
        _assertCoreOnly("invalid");
        _raw(_traitRecord("Color  palette"));
        _assertCoreOnly("invalid");
        // Only up to 16 letters are a reserved name: 17 spaced out (33 bytes) are fine, and so
        // are long names with single spaces.
        _raw(_traitRecord("d i s p u t e s t a t e m e n t s"));
        assertFalse(_has(_out(), ".record_status"));
        _raw(_traitRecord("The palette of the work as the artist describes it, in a few words"));
        assertFalse(_has(_out(), ".record_status"));
    }

    /// Regression: CONTENT-5 (docs/security/internal-review-2026-10.md)
    /// @dev The word-at-a-time check finds two spaces in a row (also across a word
    ///      boundary), a non-ASCII character and DEL at the offsets around each word boundary of
    ///      names of the lengths around them, and takes the same names with a single space.
    function test_TraitNames_AreCheckedAroundWordBoundaries() public {
        uint8[11] memory lengths = [2, 3, 31, 32, 33, 34, 35, 63, 64, 65, 66];
        uint8[11] memory offsets = [0, 1, 29, 30, 31, 32, 33, 61, 62, 63, 64];
        for (uint256 i; i < lengths.length; ++i) {
            uint256 length = lengths[i];
            for (uint256 o; o < offsets.length && offsets[o] + 2 <= length; ++o) {
                _checkAt(length, offsets[o]);
            }
            _checkAt(length, length - 2);
        }
    }

    /// @dev Name `length` bytes of `a` with two bytes at `pos`: two spaces, U+00E9, DEL (each
    ///      refused), then one space (fine).
    function _checkAt(uint256 length, uint256 pos) internal {
        bytes memory name = _fill("a", length);
        (name[pos], name[pos + 1]) = (" ", " ");
        _raw(_traitRecord(string(name)));
        _assertCoreOnly("invalid");
        (name[pos], name[pos + 1]) = (bytes1(0xc3), bytes1(0xa9));
        _raw(_traitRecord(string(name)));
        _assertCoreOnly("invalid");
        (name[pos], name[pos + 1]) = (bytes1(0x7f), "a");
        _raw(_traitRecord(string(name)));
        _assertCoreOnly("invalid");
        name[pos] = " ";
        _raw(_traitRecord(string(name)));
        assertFalse(_has(_out(), ".record_status"), "one space");
    }

    /// Regression: CONTENT-5 (docs/security/internal-review-2026-10.md)
    /// @dev A trait name is printable ASCII, so no character from another script, no
    ///      invisible or no-break space and no DEL can make a name display like the renderer's
    ///      own. Values may still be any UTF-8.
    function test_TraitNames_ArePrintableAscii() public {
        bytes[7] memory bad = [
            bytes(hex"417274697374c2a04944"), // "Artist", U+00A0, "ID"
            hex"436f6c6c656374696f6ee2808b", // "Collection", U+200B
            hex"446973707574d0b52073746174656d656e74", // "Disput", U+0435, " statement"
            bytes(unicode"Caf\u00e9"),
            bytes(unicode"\u8272"),
            hex"536565647f", // "Seed", DEL
            hex"7f"
        ];
        for (uint256 i; i < bad.length; ++i) {
            _raw(_traitRecord(string(bad[i])));
            _assertCoreOnly("invalid");
        }
        // A non-ASCII value is fine.
        _raw(
            bytes(unicode'{"attributes":[{"trait_type":"Palette","value":"Caf\u00e9"}],"name":"N"}')
        );
        assertEq(_str(_out(), ".attributes[0].value"), unicode"Caf\u00e9");
    }

    /// Regression: L2 and H2 in the review of #20
    /// @dev A name with a backslash, as a key, is refused, so an escape cannot spell a reserved
    ///      name (the review's decision on H2). The refusal is for any backslash, of any name length; only names of
    ///      at most 16 characters besides spaces are compared with the reserved list.
    function test_TraitNames_ANameWithABackslashIsRefused() public {
        string[6] memory bad = [
            "Artis\\u0074",
            "Caf\\u00e9",
            'A\\"B',
            "\\\\u0041",
            "a\\nb",
            "\\u0041rtist and then some more text that is far longer than any reserved name"
        ];
        for (uint256 i; i < bad.length; ++i) {
            _raw(_traitRecord(bad[i]));
            _assertCoreOnly("invalid");
        }
        // A long name with a backslash at the very end of a 132-byte name.
        _raw(_traitRecord(string.concat(string(_fill("a", 130)), "\\n")));
        _assertCoreOnly("invalid");
        // The same long name without it is fine.
        _raw(_traitRecord(string(_fill("a", 132))));
        assertFalse(_has(_out(), ".record_status"));
    }

    /// Regression: L2 in the review of #20
    /// @dev The backslash check reads a name a word at a time: it finds a backslash (here the first
    ///      byte of an escaped backslash) at every offset of names of every length up to two words
    ///      and a bit, and takes the same names without one.
    function test_TraitNames_ABackslashIsFoundAtEveryOffset() public {
        for (uint256 length = 2; length < 71; ++length) {
            for (uint256 pos; pos + 2 <= length; pos += (length < 40 ? 1 : 7)) {
                bytes memory name = _fill("a", length);
                name[pos] = "\\";
                name[pos + 1] = "\\";
                _raw(_traitRecord(string(name)));
                _assertCoreOnly("invalid");
            }
            _raw(_traitRecord(string(_fill("a", length))));
            assertFalse(_has(_out(), ".record_status"), "no backslash");
        }
    }

    /// Regression: L2 in the review of #20
    /// @dev The names the renderer writes have at most 16 letters; the one of 16 ("Dispute
    ///      statement") is still found, and a name one letter longer is not reserved.
    function test_TraitNames_TheLongestReservedNameIsFound() public {
        assertEq(bytes('"Dispute statement"').length, 19);
        _raw(_traitRecord("Dispute statement"));
        _assertCoreOnly("invalid");
        _raw(_traitRecord("Dispute statementt"));
        assertFalse(_has(_out(), ".record_status"));
    }

    /// Regression: L2 in the review of #20
    /// @dev Every trait the renderer writes is a name a record may not use: the output of a work
    ///      with a collection, a seed, a dispute and a record, of an edition, and of a work with
    ///      no record (the only one with `Artist ID`).
    function test_TraitNames_TheReservedNamesAreExactlyTheOnesTheRendererWrites() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        Rec memory r = _rec();
        r.dimensions = "1 x 1";
        _install(file, r);
        IStream.WorkCore memory core = _core();
        core.collectionId = 1;
        core.serial = 3;
        core.seedPolicy = SeedPolicy.ARTIST;
        stream.setWork(ID, core);
        stream.setCollection(1, IStream.Collection("C", bytes32(0), 3));
        records.setSeed(ID, SeedPolicy.ARTIST, bytes32(uint256(1)));
        disputeLog.set(address(stream), ID, bytes32(uint256(1)));
        string memory full = _out();
        RendererEditionsMock editions = new RendererEditionsMock(address(stream));
        editions.setMaster(5, ID, _sha(file));
        string memory edition = _decode(renderer.tokenURI(address(editions), 5));
        _setOpen(false);
        string memory coreOnly = _out();

        string[10] memory names = [
            "Artist",
            "Artist ID",
            "Year",
            "Medium",
            "Dimensions",
            "Collection",
            "Serial",
            "Edition of",
            "Seed",
            "Dispute statement"
        ];
        assertTrue(_hasAttr(coreOnly, "Artist ID"));
        assertTrue(_hasAttr(edition, "Edition of"));
        for (uint256 i; i < names.length; ++i) {
            bool written = _hasAttr(full, names[i]) || _hasAttr(edition, names[i])
                || _hasAttr(coreOnly, names[i]);
            assertTrue(written, names[i]);
            _setOpen(true);
            _raw(_traitRecord(names[i]));
            _assertCoreOnly("invalid");
        }
        // And nothing else is written under another name: count the traits of the full output.
        uint256 count;
        while (_has(full, _at(count, ""))) ++count;
        assertEq(count, 8, "Artist, Year, Medium, Dimensions, Collection, Serial, Seed, Dispute");
    }
}
