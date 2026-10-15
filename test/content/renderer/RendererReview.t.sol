// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Rec, RendererBase } from "./RendererBase.sol";
import { MockEditions, MockEntropy } from "../../mocks/RendererMocks.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";

/// @dev A records satellite whose `preferredLocator` burns gas, like a stream lane that walks a
///      large file to answer it.
contract BurningRecords {
    address internal immutable inner;
    uint256 internal immutable burn;

    constructor(address inner_, uint256 burn_) {
        inner = inner_;
        burn = burn_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        if (bytes4(data) == IWorkRecords.preferredLocator.selector) {
            uint256 start = gasleft();
            while (start - gasleft() < burn) { }
        }
        (bool ok, bytes memory ret) = inner.staticcall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}

/// @dev Regression tests for the findings of the review of the renderer (each is a case the
///      review demonstrated, and each now has a defined, safe outcome): what a record may hold,
///      what the renderer copies, and what it refuses.
contract RendererReviewTest is RendererBase {
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

    // ---------------------------------------------------------------- M3: keys

    /// @dev `name` is `name` to every JSON parser. Matched on its raw text it would be a
    ///      second `name` to the renderer only; a key with a backslash makes the record invalid.
    function test_M3_AKeyWithAnEscapeMakesTheRecordInvalid() public {
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

    // ---------------------------------------------------------------- M4: NUL and surrogates

    function test_M4_NulAndLoneSurrogatesMakeTheRecordInvalid() public {
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

    /// @dev Whatever a record says in its strings, if the renderer accepts it the output is JSON
    ///      that serde_json reads, and the text comes back as written.
    function testFuzz_M4_AcceptedRecordsGiveJsonEveryParserReads(uint256 seed, uint8 length)
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

    // ---------------------------------------------------------------- H2: bounds

    function test_H2_TheYearIsAnIntegerOfAtMostSixDigits() public {
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

    function test_H2_AtMostTheCapOfPercentAndHashEscapes() public {
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

    function test_H2_AtMostTheCapOfAttributes() public {
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

    function test_H2_AtMostTheCapOfJsonValues() public {
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

    // ---------------------------------------------------------------- the second review

    /// @dev N1: `@` and the backtick are not hex digits; a record with one in a `\u` escape is
    ///      invalid, wherever the escape is (the name, a description, a trait name, a surrogate).
    function test_N1_ARecordWithABadHexDigitIsInvalid() public {
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

    /// @dev N2: a number that is out of the binary64 range is invalid (serde_json refuses the
    ///      whole document and JavaScript reads Infinity), as an attribute value or anywhere.
    function test_N2_ANumberOutOfRangeIsInvalid() public {
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

    /// @dev N3: a member twice in an attribute (`display_type` here) is a record that parsers read
    ///      differently (first wins, last wins, an error): it is invalid, and so is an attribute
    ///      with a member that is not one of the four OpenSea keys.
    function test_N3_ADuplicatedAttributeMemberIsInvalid() public {
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

    /// @dev H2: every backslash escape counts against the 1,024 of values: a description of
    ///      escapes is accepted up to the budget, and refused beyond it.
    function test_H2_EscapesCountAgainstTheValueBudget() public {
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

    // ---------------------------------------------------------------- L1: license URL

    function test_L1_TheLicenseUrlComesOnlyFromAnSpdxIdentifier() public {
        _install(_file(png, IDENTITY, "image/png"));
        // A license that tries to break out of the string or the URL.
        string[9] memory bad = [
            'MIT","name":"Forged',
            "MIT/../x",
            "MIT x",
            "MIT%41",
            "MIT#frag",
            "MIT?x",
            "MIT\\x",
            unicode"MITé",
            "MIT<>"
        ];
        for (uint256 i; i < bad.length; ++i) {
            records.setLicense(ID, License(bad[i], bytes32(0)));
            string memory j = _decode(renderer.tokenURI(address(stream), ID));
            assertEq(_str(j, ".name"), "Title", bad[i]);
            assertEq(_str(j, ".license"), bad[i]);
            assertFalse(_has(j, ".license_url"), bad[i]);
        }
        string[5] memory good =
            ["Apache-2.0", "GPL-3.0+", "AGPL-3.0-only", "LGPL-2.1-or-later", "A.b+c-1"];
        for (uint256 i; i < good.length; ++i) {
            records.setLicense(ID, License(good[i], bytes32(0)));
            assertEq(
                _str(_decode(renderer.tokenURI(address(stream), ID)), ".license_url"),
                string.concat("https://spdx.org/licenses/", good[i], ".html")
            );
        }
    }

    // ---------------------------------------------------------------- L2: reserved traits

    function _traitRecord(string memory name) internal pure returns (bytes memory) {
        return bytes(
            string.concat('{"attributes":[{"trait_type":"', name, '","value":"v"}],"name":"N"}')
        );
    }

    /// @dev The ten names the renderer writes are the ones a record may not use.
    function test_L2_ARecordCannotUseARendererTraitName() public {
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

    function test_L2_OtherNamesAreFine() public {
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

    /// @dev CONTENT-5: the renderer's names are matched in any case and with any spaces, and two
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

    /// @dev CONTENT-5: the word-at-a-time check finds two spaces in a row (also across a word
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

    /// @dev CONTENT-5: a trait name is printable ASCII, so no character from another script, no
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

    /// @dev Decision H2: a name with a backslash, as a key, is refused, so an escape cannot spell a
    ///      reserved name. The refusal is for any backslash, of any name length; only names of
    ///      at most 16 characters besides spaces are compared with the reserved list.
    function test_L2_ANameWithABackslashIsRefused() public {
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

    /// @dev The backslash check reads a name a word at a time: it finds a backslash (here the first
    ///      byte of an escaped backslash) at every offset of names of every length up to two words
    ///      and a bit, and takes the same names without one.
    function test_L2_ABackslashIsFoundAtEveryOffset() public {
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

    /// @dev The names the renderer writes have at most 16 letters; the one of 16 ("Dispute
    ///      statement") is still found, and a name one letter longer is not reserved.
    function test_L2_TheLongestReservedNameIsFound() public {
        assertEq(bytes('"Dispute statement"').length, 19);
        _raw(_traitRecord("Dispute statement"));
        _assertCoreOnly("invalid");
        _raw(_traitRecord("Dispute statementt"));
        assertFalse(_has(_out(), ".record_status"));
    }

    /// @dev Every trait the renderer writes is a name a record may not use: the output of a work
    ///      with a collection, a seed, a dispute and a record, of an edition, and of a work with
    ///      no record (the only one with `Artist ID`).
    function test_L2_TheReservedNamesAreExactlyTheOnesTheRendererWrites() public {
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
        MockEditions editions = new MockEditions(address(stream));
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

    // ---------------------------------------------------------------- L4: license text

    function test_L4_ALicenseRefGivesItsTextFileAndALocatorOfIt() public {
        bytes32 text = _file("The terms.", IDENTITY, "text/plain");
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = MediaFile(file, _sha(file), FileRole.PRIMARY);
        media[1] = MediaFile(text, _sha(text), FileRole.AUXILIARY);
        records.setMedia(ID, media);
        records.setLicense(ID, License("LicenseRef-Studio-1", text));
        records.addLocator(ID, text, Locator(LocatorKind.ARWEAVE, "ar://terms"));

        string memory j = _out();

        assertEq(_str(j, ".license"), "LicenseRef-Studio-1");
        assertEq(_str(j, ".license_text_file"), vm.toString(text));
        assertEq(_str(j, ".license_url"), "ar://terms");
    }

    function test_L4_WithoutAListedFileOrALocatorThereIsNoUrl() public {
        bytes32 text = _file("The terms.", IDENTITY, "text/plain");
        _install(_file(png, IDENTITY, "image/png"));
        records.setLicense(ID, License("LicenseRef-Studio-1", text));

        // The text file is not one of the work's media: no URL, even if the satellite happens to
        // know a copy of it (locators exist for media files, and are not read for other files).
        records.addLocator(ID, text, Locator(LocatorKind.ARWEAVE, "ar://not-media"));
        string memory j = _out();
        assertEq(_str(j, ".license_text_file"), vm.toString(text));
        assertFalse(_has(j, ".license_url"));

        // Listed, but with no copy anywhere: still no URL.
        bytes32 bare = _file("Other terms.", IDENTITY, "text/plain");
        records.setLicense(ID, License("LicenseRef-Studio-1", bare));
        bytes32 file = _file(png, IDENTITY, "image/png");
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = MediaFile(file, _sha(file), FileRole.PRIMARY);
        media[1] = MediaFile(bare, _sha(bare), FileRole.AUXILIARY);
        records.setMedia(ID, media);
        j = _out();
        assertEq(_str(j, ".license_text_file"), vm.toString(bare));
        assertFalse(_has(j, ".license_url"));
    }

    function test_L4_AnSpdxLicenseWithATextFileKeepsTheSpdxPage() public {
        bytes32 text = _file("The terms.", IDENTITY, "text/plain");
        _install(_file(png, IDENTITY, "image/png"));
        records.setLicense(ID, License("MIT", text));

        string memory j = _out();

        assertEq(_str(j, ".license_url"), "https://spdx.org/licenses/MIT.html");
        assertEq(_str(j, ".license_text_file"), vm.toString(text));
    }

    function test_L4_NoTextFileNoField() public {
        _install(_file(png, IDENTITY, "image/png"));
        assertFalse(_has(_out(), ".license_text_file"));
    }

    // ---------------------------------------------------------------- M1: locator reads

    /// @dev A satellite that spends its gas cap on `preferredLocator` (a stream lane walking a
    ///      large file to answer an on-chain preference) fails the call: it is not "no media".
    function test_M1_APreferredLocatorThatRunsOutOfGasFailsClosed() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 5), IDENTITY, "text/html");
        _install(file);
        records.addLocator(ID, file, Locator(LocatorKind.ARWEAVE, "ar://tx"));
        assertTrue(_has(_out(), ".animation_url"));

        BurningRecords burning = new BurningRecords(address(records), 310_000);
        stream.setWorkRecords(address(burning));

        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector,
                address(burning),
                IWorkRecords.preferredLocator.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    // ---------------------------------------------------------------- E6: escaping

    /// @dev Strings from the Stream, the store and the satellite reach a `data:` URI too: a `%`
    ///      or `#` in a collection name, a locator or a license identifier is escaped as well.
    function test_E6_PercentAndHashInStreamAndSatelliteStringsAreEscaped() public {
        bytes32 file = _file(_data(THRESHOLD + 1, 6), IDENTITY, "image/png");
        _install(file);
        IStream.WorkCore memory core = _core();
        core.collectionId = 1;
        core.serial = 4;
        stream.setWork(ID, core);
        stream.setCollection(1, IStream.Collection("50% off #1", bytes32(0), 4));
        records.addLocator(ID, file, Locator(LocatorKind.IPFS, "ipfs://a%b#c"));
        records.setLicense(ID, License("Nonsense%License#1", bytes32(0)));

        string memory uri = _uri();
        string memory j = _decode(uri); // fails on a raw `#` or a stray `%`

        assertEq(_attr(j, "Collection"), "50% off #1");
        assertEq(_str(j, ".image"), "ipfs://a%b#c");
        assertEq(_str(j, ".license"), "Nonsense%License#1");
        // And the same in the core-only form, whose name is the collection's.
        _setOpen(false);
        assertEq(_str(_out(), ".name"), "50% off #1 #4");
    }
}
