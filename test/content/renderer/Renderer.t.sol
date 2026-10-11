// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Rec, RendererBase, Trait } from "./RendererBase.sol";
import { MockEditions, MockEntropy } from "../../mocks/RendererMocks.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { SSTORE2 } from "src/libraries/SSTORE2.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";

/// @dev Metadata, record handling, escaping and failure behaviour of the renderer; the media
///      rules are in `RendererMedia.t.sol`.
contract RendererTest is RendererBase {
    bytes internal png = hex"89504e470d0a1a0a0000000d49484452";

    // ---------------------------------------------------------------- constructor

    function test_Constructor_SetsWiring() public view {
        assertEq(renderer.inlineThreshold(), THRESHOLD);
        assertEq(address(renderer.statementLog()), address(disputeLog));
        assertEq(address(renderer.contentStore()), address(store));
        assertEq(renderer.MAX_INLINE_BYTES(), 1_048_576);
        assertEq(renderer.DEFAULT_INLINE_THRESHOLD(), 262_144);
        assertEq(renderer.MAX_RECORD_BYTES(), 12_288);
    }

    function test_SupportsInterface() public view {
        assertTrue(renderer.supportsInterface(type(IRenderer).interfaceId));
        assertTrue(renderer.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(renderer.supportsInterface(0xffffffff));
        assertFalse(renderer.supportsInterface(0xd9b67a26)); // ERC-1155
    }

    function test_Constructor_RejectsBadThresholds() public {
        IStatementLog none = IStatementLog(address(0));
        vm.expectRevert(abi.encodeWithSelector(Renderer.RendererThresholdInvalid.selector, 0));
        new Renderer(store, none, 0);
        vm.expectRevert(
            abi.encodeWithSelector(Renderer.RendererThresholdInvalid.selector, 1_048_577)
        );
        new Renderer(store, none, 1_048_577);
        assertEq(new Renderer(store, none, 1).inlineThreshold(), 1);
        assertEq(new Renderer(store, none, 1_048_576).inlineThreshold(), 1_048_576);
    }

    // ---------------------------------------------------------------- the metadata

    function test_Metadata_FieldsAndTraits() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        Rec memory r = _rec();
        r.dimensions = "30 x 40 cm";
        r.artists = new string[](2);
        r.artists[0] = "Ada";
        r.artists[1] = "Bo";
        r.attributes = new Trait[](2);
        r.attributes[0] = Trait("Palette", "Warm");
        r.attributes[1] = Trait("Edition size", "1");
        _install(file, r);
        IStream.WorkCore memory core = _core();
        core.collectionId = 3;
        core.serial = 12;
        stream.setWork(ID, core);
        stream.setCollection(3, IStream.Collection("Spring", bytes32(0), 12));

        string memory j = _out();

        assertEq(_str(j, ".name"), "Title");
        assertEq(_str(j, ".description"), "Description");
        assertEq(_str(j, ".content_type"), "image/png");
        assertEq(_str(j, ".content_hash"), vm.toString(sha256(png)));
        assertEq(_str(j, ".license"), "CC0-1.0");
        assertEq(_attr(j, "Collection"), "Spring");
        assertEq(_attrNum(j, "Serial"), 12);
        assertEq(_attr(j, "Artist"), "Ada");
        assertEq(_str(j, _at(_attrIndex(j, "Artist") + 1, ".value")), "Bo");
        assertEq(_attrNum(j, "Year"), 2026);
        assertEq(_attr(j, "Medium"), "Oil");
        assertEq(_attr(j, "Dimensions"), "30 x 40 cm");
        assertEq(_attr(j, "Palette"), "Warm");
        assertEq(_attr(j, "Edition size"), "1");
        assertFalse(_hasAttr(j, "Seed"));
        assertFalse(_hasAttr(j, "Dispute statement"));
        assertFalse(_hasAttr(j, "Edition of"));
    }

    function test_Metadata_OmitsEmptyOptionalTraits() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        Rec memory r = _rec();
        r.year = 0;
        r.medium = "";
        r.artists = new string[](0);
        _install(file, r);

        string memory j = _out();

        assertFalse(_hasAttr(j, "Year"));
        assertFalse(_hasAttr(j, "Medium"));
        assertFalse(_hasAttr(j, "Dimensions"));
        assertFalse(_hasAttr(j, "Artist"));
        assertFalse(_hasAttr(j, "Collection"));
        assertEq(_str(j, ".name"), "Title");
    }

    function test_Metadata_Seed() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        IStream.WorkCore memory core = _core();
        core.seedPolicy = SeedPolicy.ARTIST;
        stream.setWork(ID, core);
        records.setSeed(ID, SeedPolicy.ARTIST, bytes32(uint256(0xabc)));
        assertEq(_attr(_out(), "Seed"), vm.toString(bytes32(uint256(0xabc))));

        core.seedPolicy = SeedPolicy.VRF; // delivered before the mint, so always available
        stream.setWork(ID, core);
        records.setSeed(ID, SeedPolicy.VRF, bytes32(uint256(0xdef)));
        assertEq(_attr(_out(), "Seed"), vm.toString(bytes32(uint256(0xdef))));
    }

    /// @dev Decision E9: until `openRecord` has run every view of the satellite reverts, and the
    ///      renderer answers from Stream alone, without a revert.
    function test_CoreOnly_UntilTheRecordIsOpen() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        IStream.WorkCore memory core = _core();
        core.collectionId = 3;
        core.serial = 12;
        core.artistId = 0xabc;
        core.seedPolicy = SeedPolicy.VRF;
        stream.setWork(ID, core);
        stream.setCollection(3, IStream.Collection("Spring", bytes32(0), 12));
        MockEntropy entropy = new MockEntropy();
        entropy.set(core.itemHash, bytes32(uint256(0xfeed)));
        stream.setEntropyModule(address(entropy));
        _setOpen(false);
        disputeLog.set(address(stream), ID, bytes32(uint256(9)));

        string memory j = _out();

        assertEq(_str(j, ".name"), "Spring #12");
        assertEq(_str(j, ".description"), "The work record is not available.");
        assertEq(_str(j, ".record_status"), "not_open");
        assertEq(_attr(j, "Collection"), "Spring");
        assertEq(_attrNum(j, "Serial"), 12);
        assertEq(_attr(j, "Artist ID"), "0x0abc");
        assertEq(_attr(j, "Seed"), vm.toString(bytes32(uint256(0xfeed))));
        assertEq(_attr(j, "Dispute statement"), vm.toString(bytes32(uint256(9))));
        assertFalse(_has(j, ".image"));
        assertFalse(_has(j, ".license"));
        assertFalse(_has(j, ".content_hash"));
        // The full form has nothing to inline, so it reverts (L6).
        vm.expectRevert(
            abi.encodeWithSelector(Renderer.RendererNotInlineable.selector, address(stream), ID)
        );
        renderer.fullTokenURI(address(stream), ID);
    }

    function test_CoreOnly_WithoutACollectionOrSeed() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        _setOpen(false);

        string memory j = _out();

        assertEq(_str(j, ".name"), "6529 Works #7");
        assertFalse(_hasAttr(j, "Collection"));
        assertFalse(_hasAttr(j, "Seed"));
        assertTrue(_hasAttr(j, "Artist ID"));
    }

    function test_CoreOnly_ForAnEditionNamesItsMaster() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        _setOpen(false);
        MockEditions editions = new MockEditions(address(stream));
        editions.setMaster(5, ID, _sha(file));

        string memory j = _decode(renderer.tokenURI(address(editions), 5));

        assertEq(_str(j, ".name"), "6529 Works #5");
        assertEq(_attrNum(j, "Edition of"), ID);
    }

    function test_CoreOnly_WhenTheRecordFileIsNotCompleteYet() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        IWorkRecords.RecordInfo memory info = _info();
        info.recordFileId = _incompleteFile(_data(1_000, 1), IDENTITY, "application/json");
        _setRecordInfo(info);

        assertEq(_assertCoreOnly("incomplete"), "6529 Works #7");

        // Completing the upload ends it. The bytes are not a record (not even UTF-8), so the work
        // is core-only for another reason, and never a revert.
        (bytes[] memory chunks,) = _split(_data(1_000, 1));
        store.writeChunk(chunks[0]);
        _assertCoreOnly("invalid");
    }

    function test_CoreOnly_AnUnreadableOpenFlagFailsClosed() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        records.fail(IWorkRecords.isOpen.selector, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                Renderer.RendererReadFailed.selector, address(records), IWorkRecords.isOpen.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    function test_FullTokenURI_SameMetadataAsCompactForSmallWork() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        assertEq(renderer.fullTokenURI(address(stream), ID), _uri());
    }

    // ---------------------------------------------------------------- the record

    function _raw(bytes memory json) internal {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _installRaw(json, _media(file, 0));
    }

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
        r.artists = new string[](renderer.MAX_ARTISTS());
        for (uint256 i; i < r.artists.length; ++i) {
            r.artists[i] = "x";
        }
        _install(file, r);
        assertEq(_str(_out(), ".name"), "Title"); // the limit itself is fine

        r.artists = new string[](renderer.MAX_ARTISTS() + 1);
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
            _file(_data(renderer.MAX_RECORD_BYTES() + 1, 2), IDENTITY, "application/json");
        _setRecordInfo(info);
        _assertCoreOnly("invalid");
    }

    /// @dev A record of at most `Limits.MAX_RECORD_BYTES` is a single store chunk, so it is read
    ///      with one `readChunk`, and the renderer's limit is the shared one.
    function test_Record_TheLimitFitsOneStoreChunk() public view {
        assertLe(Limits.MAX_RECORD_BYTES, SSTORE2.MAX_CHUNK_LENGTH);
        assertEq(renderer.MAX_RECORD_BYTES(), Limits.MAX_RECORD_BYTES);
        assertEq(renderer.MAX_ARTISTS(), Limits.MAX_ARTISTS);
    }

    function test_Record_ARecordOfExactlyTheLimitIsRead() public {
        // A record padded with whitespace to exactly the limit.
        bytes memory json = '{"name":"N"}';
        uint256 limit = renderer.MAX_RECORD_BYTES();
        bytes memory padded = new bytes(limit);
        for (uint256 i; i < limit; ++i) {
            padded[i] = i < json.length ? json[i] : bytes1(" ");
        }
        _raw(padded);
        assertEq(_str(_out(), ".name"), "N");
    }

    function test_Record_NotAFileTheStoreKnowsFailsClosed() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        IWorkRecords.RecordInfo memory info = _info();
        info.recordFileId = bytes32(uint256(0xdead));
        _setRecordInfo(info);
        vm.expectRevert(
            abi.encodeWithSelector(
                Renderer.RendererReadFailed.selector,
                address(store),
                IContentStore.fileInfo.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    // ---------------------------------------------------------------- escaping and UTF-8

    function test_Escaping_RecordStringsWithSpecials() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        Rec memory r = _rec();
        r.name = string(
            bytes.concat(
                'Quote " slash \\ tab \t nl \n 100% #1 <script> ',
                hex"e280a8", // U+2028
                " e",
                hex"cc81",
                " ",
                hex"f09f9880" // combining acute, U+1F600
            )
        );
        r.description = "</script><!-- % # %25 %23";
        r.attributes = new Trait[](1);
        r.attributes[0] = Trait("A'B 100% #1", "C\\D");
        _install(file, r);

        string memory j = _out();

        assertEq(_str(j, ".name"), r.name);
        assertEq(_str(j, ".description"), r.description);
        assertEq(_attr(j, "A'B 100% #1"), "C\\D");
    }

    function testFuzz_Escaping_AnyValidText(uint256 seed, uint8 length) public {
        // Text from the characters that need escaping plus ordinary ones, always valid UTF-8.
        string[12] memory alphabet = [
            "a",
            "Z",
            " ",
            '"',
            "\\",
            "\n",
            "%",
            "#",
            "<",
            string(bytes(hex"c3a9")),
            string(bytes(hex"e280a9")),
            string(bytes(hex"f09f9a80"))
        ];
        string memory text;
        for (uint256 i; i < length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            text = string.concat(text, alphabet[seed % alphabet.length]);
        }
        bytes32 file = _file(png, IDENTITY, "image/png");
        Rec memory r = _rec();
        r.description = text;
        _install(file, r);

        assertEq(_str(_out(), ".description"), text);
    }

    /// @dev A record that is not UTF-8 is an invalid record (core-only), wherever the bad bytes are.
    function test_InvalidUtf8_InTheRecordMakesItInvalid() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        string memory bad = string(bytes(hex"61c0af62")); // an overlong encoding
        for (uint256 i; i < 4; ++i) {
            Rec memory r = _rec();
            if (i == 0) r.name = bad;
            if (i == 1) r.description = bad;
            if (i == 2) r.artists[0] = bad;
            if (i == 3) {
                r.attributes = new Trait[](1);
                r.attributes[0] = Trait("k", bad);
            }
            _install(file, r);
            _assertCoreOnly("invalid");
        }
    }

    function test_InvalidUtf8_InLicenseCollectionAndLocator() public {
        string memory bad = string(bytes(hex"ff"));
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        records.setLicense(ID, License(bad, bytes32(0)));
        vm.expectRevert(Renderer.RendererInvalidUtf8.selector);
        renderer.tokenURI(address(stream), ID);

        records.setLicense(ID, _license());
        IStream.WorkCore memory core = _core();
        core.collectionId = 1;
        stream.setWork(ID, core);
        stream.setCollection(1, IStream.Collection(bad, bytes32(0), 1));
        vm.expectRevert(Renderer.RendererInvalidUtf8.selector);
        renderer.tokenURI(address(stream), ID);

        // A locator is read only when the file is not inlined.
        bytes32 big = _file(_data(THRESHOLD + 1, 1), IDENTITY, "image/png");
        _install(big);
        records.addLocator(ID, big, Locator(LocatorKind.IPFS, bad));
        vm.expectRevert(Renderer.RendererInvalidUtf8.selector);
        renderer.tokenURI(address(stream), ID);
    }

    // ---------------------------------------------------------------- license

    function test_License_UrlIsTheSpdxPageInTheOriginalCase() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        assertEq(_str(_out(), ".license_url"), "https://spdx.org/licenses/CC0-1.0.html");

        records.setLicense(ID, License("GPL-3.0-or-later", bytes32(0)));
        string memory j = _out();
        assertEq(_str(j, ".license"), "GPL-3.0-or-later");
        assertEq(_str(j, ".license_url"), "https://spdx.org/licenses/GPL-3.0-or-later.html");
    }

    function test_License_NoUrlForALicenseRefInAnyCaseOrAnEmptyId() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        string[5] memory ids =
            ["LicenseRef-All-Rights-Reserved", "licenseref-x", "LICENSEREF-X", "LicenseRef-", ""];
        for (uint256 i; i < ids.length; ++i) {
            records.setLicense(ID, License(ids[i], bytes32(0)));
            string memory j = _out();
            assertEq(_str(j, ".license"), ids[i]);
            assertFalse(_has(j, ".license_url"), ids[i]);
        }
        // Near misses still get a page.
        records.setLicense(ID, License("LicenseRe-1", bytes32(0)));
        assertTrue(_has(_out(), ".license_url"));
        records.setLicense(ID, License("Licenseref", bytes32(0)));
        assertTrue(_has(_out(), ".license_url"));
    }

    // ---------------------------------------------------------------- disputes

    function test_Dispute_ShownWhenTheLogHasAnOutcome() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        disputeLog.set(address(stream), ID, bytes32(uint256(0xd15b)));

        string memory j = _out();

        assertEq(_attr(j, "Dispute statement"), vm.toString(bytes32(uint256(0xd15b))));
    }

    function test_Dispute_ReadsTheMastersSubjectForAnEdition() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        MockEditions editions = new MockEditions(address(stream));
        editions.setMaster(ID, ID, _sha(file));
        disputeLog.set(address(stream), ID, bytes32(uint256(5)));

        string memory j = _decode(renderer.tokenURI(address(editions), ID));

        assertEq(_attr(j, "Dispute statement"), vm.toString(bytes32(uint256(5))));
    }

    function test_Dispute_NoLogConfiguredMeansNone() public {
        Renderer noLog = new Renderer(store, IStatementLog(address(0)), THRESHOLD);
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        disputeLog.set(address(stream), ID, bytes32(uint256(5)));

        assertFalse(_hasAttr(_decode(noLog.tokenURI(address(stream), ID)), "Dispute statement"));
    }

    function test_Dispute_ABrokenLogFailsClosed() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        disputeLog.setBroken(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                Renderer.RendererReadFailed.selector,
                address(disputeLog),
                IStatementLog.latestDisputeOutcome.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    // ---------------------------------------------------------------- editions

    function test_Edition_RendersTheMastersWorkAsAnEdition() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        MockEditions editions = new MockEditions(address(stream));
        editions.setMaster(5, ID, _sha(file));

        string memory j = _decode(renderer.tokenURI(address(editions), 5));

        assertEq(_str(j, ".name"), "Title");
        assertEq(_attrNum(j, "Edition of"), ID);
        assertEq(_str(j, ".license"), "CC0-1.0");
        assertEq(_str(j, ".image"), string.concat("data:image/png;base64,", _b64(png)));
    }

    function test_Edition_ContentHashMustMatchTheMaster() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        MockEditions editions = new MockEditions(address(stream));
        editions.setMaster(5, ID, bytes32(uint256(0xbad)));

        vm.expectRevert(
            abi.encodeWithSelector(Renderer.RendererRecordInvalid.selector, address(editions), 5)
        );
        renderer.tokenURI(address(editions), 5);
    }

    function test_Edition_UnknownEditionFailsClosed() public {
        MockEditions editions = new MockEditions(address(stream));
        vm.expectRevert(
            abi.encodeWithSelector(
                Renderer.RendererReadFailed.selector, address(editions), IEditions.masterOf.selector
            )
        );
        renderer.tokenURI(address(editions), 5);
    }

    // ---------------------------------------------------------------- failing closed

    function test_FailsClosed_EveryReadOfTheStreamAndRecords() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        IStream.WorkCore memory core = _core();
        core.collectionId = 1;
        core.seedPolicy = SeedPolicy.ARTIST;
        stream.setWork(ID, core);
        stream.setCollection(1, IStream.Collection("C", bytes32(0), 1));
        records.setSeed(ID, SeedPolicy.ARTIST, bytes32(uint256(1)));
        renderer.tokenURI(address(stream), ID); // the baseline works

        bytes4[2] memory onStream = [IStream.work.selector, IStream.collection.selector];
        for (uint256 i; i < onStream.length; ++i) {
            stream.fail(onStream[i], true);
            vm.expectRevert(
                abi.encodeWithSelector(
                    Renderer.RendererReadFailed.selector, address(stream), onStream[i]
                )
            );
            renderer.tokenURI(address(stream), ID);
            stream.fail(onStream[i], false);
        }
        bytes4[5] memory onRecords = [
            IWorkRecords.isOpen.selector,
            IWorkRecords.record.selector,
            IWorkRecords.mediaOf.selector,
            IWorkRecords.licenseOf.selector,
            IWorkRecords.seedOf.selector
        ];
        for (uint256 i; i < onRecords.length; ++i) {
            records.fail(onRecords[i], true);
            vm.expectRevert(
                abi.encodeWithSelector(
                    Renderer.RendererReadFailed.selector, address(records), onRecords[i]
                )
            );
            renderer.tokenURI(address(stream), ID);
            records.fail(onRecords[i], false);
        }
    }

    function test_FailsClosed_NotAToken() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Renderer.RendererReadFailed.selector, address(0xdead), IStream.work.selector
            )
        );
        renderer.tokenURI(address(0xdead), 1);
    }

    function test_FailsClosed_ABurnedOrUnknownToken() public {
        stream.fail(IStream.work.selector, true); // `UnknownWork` in the real Stream
        vm.expectRevert(
            abi.encodeWithSelector(
                Renderer.RendererReadFailed.selector, address(stream), IStream.work.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    function test_FailsClosed_ThePrimaryMediaFileIsRequired() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);

        MediaFile[] memory none = new MediaFile[](0);
        records.setMedia(ID, none);
        _expectInvalidRecord();
        renderer.tokenURI(address(stream), ID);

        MediaFile[] memory aux = new MediaFile[](1);
        aux[0] = MediaFile(file, sha256(png), FileRole.AUXILIARY);
        records.setMedia(ID, aux);
        _expectInvalidRecord();
        renderer.tokenURI(address(stream), ID);

        aux[0] = MediaFile(file, sha256(png), FileRole.PREVIEW);
        records.setMedia(ID, aux);
        _expectInvalidRecord();
        renderer.tokenURI(address(stream), ID);
    }

    function _expectInvalidRecord() internal {
        vm.expectRevert(
            abi.encodeWithSelector(Renderer.RendererRecordInvalid.selector, address(stream), ID)
        );
    }

    function test_TheMostExpensiveRecordStaysWithinTheBudget() public {
        // 16 artists and 64 attributes, with a description filling the record limit.
        bytes32 file = _file(png, IDENTITY, "image/png");
        Rec memory r = _rec();
        r.artists = new string[](16);
        for (uint256 i; i < 16; ++i) {
            r.artists[i] = _text(64);
        }
        r.attributes = new Trait[](64);
        for (uint256 i; i < 64; ++i) {
            r.attributes[i] = Trait(_text(24), _text(64));
        }
        r.description = "";
        r.description = _text(renderer.MAX_RECORD_BYTES() - _json(r).length);
        assertEq(_json(r).length, renderer.MAX_RECORD_BYTES());
        _install(file, r);
        uint256 before = gasleft();
        string memory uri = renderer.tokenURI(address(stream), ID);
        uint256 used = before - gasleft();
        emit log_named_uint("tokenURI gas, maximal record", used);
        assertLt(used, 8_000_000);
        assertGt(bytes(uri).length, renderer.MAX_RECORD_BYTES());
    }

    function _text(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = bytes1(uint8(97 + (i % 26)));
        }
        return string(b);
    }
}
