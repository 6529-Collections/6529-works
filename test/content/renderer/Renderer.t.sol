// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Rec, RendererBase, Trait } from "./RendererBase.sol";
import { RendererEditionsMock, RendererEntropyMock } from "../../mocks/content/RendererMocks.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
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
        assertEq(renderer.DEFAULT_INLINE_THRESHOLD(), 262_144);
    }

    function test_SupportsInterface() public view {
        assertTrue(renderer.supportsInterface(type(IRenderer).interfaceId));
        assertTrue(renderer.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(renderer.supportsInterface(0xffffffff));
        assertFalse(renderer.supportsInterface(0xd9b67a26)); // ERC-1155
    }

    function test_Constructor_RejectsBadThresholds() public {
        IStatementLog none = IStatementLog(address(0));
        vm.expectRevert(abi.encodeWithSelector(IRenderer.RendererThresholdInvalid.selector, 0));
        new Renderer(store, none, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRenderer.RendererThresholdInvalid.selector, 1_048_577)
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
        RendererEntropyMock entropy = new RendererEntropyMock();
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
            abi.encodeWithSelector(IRenderer.RendererNotInlineable.selector, address(stream), ID)
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
        RendererEditionsMock editions = new RendererEditionsMock(address(stream));
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
                IRenderer.RendererReadFailed.selector,
                address(records),
                IWorkRecords.isOpen.selector
            )
        );
        renderer.tokenURI(address(stream), ID);
    }

    function test_FullTokenURI_SameMetadataAsCompactForSmallWork() public {
        bytes32 file = _file(png, IDENTITY, "image/png");
        _install(file);
        assertEq(renderer.fullTokenURI(address(stream), ID), _uri());
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
        vm.expectRevert(IRenderer.RendererInvalidUtf8.selector);
        renderer.tokenURI(address(stream), ID);

        records.setLicense(ID, _license());
        IStream.WorkCore memory core = _core();
        core.collectionId = 1;
        stream.setWork(ID, core);
        stream.setCollection(1, IStream.Collection(bad, bytes32(0), 1));
        vm.expectRevert(IRenderer.RendererInvalidUtf8.selector);
        renderer.tokenURI(address(stream), ID);

        // A locator is read only when the file is not inlined.
        bytes32 big = _file(_data(THRESHOLD + 1, 1), IDENTITY, "image/png");
        _install(big);
        records.addLocator(ID, big, Locator(LocatorKind.IPFS, bad));
        vm.expectRevert(IRenderer.RendererInvalidUtf8.selector);
        renderer.tokenURI(address(stream), ID);
    }

    /// Regression: E6 in the review of #20
    /// @dev Strings from the Stream, the store and the satellite reach a `data:` URI too: a `%`
    ///      or `#` in a collection name, a locator or a license identifier is escaped as well.
    function test_Escaping_PercentAndHashInStreamAndSatelliteStrings() public {
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

    /// Regression: L1 in the review of #20
    function test_License_TheUrlComesOnlyFromAnSpdxIdentifier() public {
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

    /// Regression: L4 in the review of #20
    function test_License_ALicenseRefGivesItsTextFileAndALocatorOfIt() public {
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

    /// Regression: L4 in the review of #20
    function test_License_WithoutAListedFileOrALocatorThereIsNoUrl() public {
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

    /// Regression: L4 in the review of #20
    function test_License_AnSpdxLicenseWithATextFileKeepsTheSpdxPage() public {
        bytes32 text = _file("The terms.", IDENTITY, "text/plain");
        _install(_file(png, IDENTITY, "image/png"));
        records.setLicense(ID, License("MIT", text));

        string memory j = _out();

        assertEq(_str(j, ".license_url"), "https://spdx.org/licenses/MIT.html");
        assertEq(_str(j, ".license_text_file"), vm.toString(text));
    }

    /// Regression: L4 in the review of #20
    function test_License_NoTextFileNoField() public {
        _install(_file(png, IDENTITY, "image/png"));
        assertFalse(_has(_out(), ".license_text_file"));
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
        RendererEditionsMock editions = new RendererEditionsMock(address(stream));
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
                IRenderer.RendererReadFailed.selector,
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
        RendererEditionsMock editions = new RendererEditionsMock(address(stream));
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
        RendererEditionsMock editions = new RendererEditionsMock(address(stream));
        editions.setMaster(5, ID, bytes32(uint256(0xbad)));

        vm.expectRevert(
            abi.encodeWithSelector(IRenderer.RendererRecordInvalid.selector, address(editions), 5)
        );
        renderer.tokenURI(address(editions), 5);
    }

    function test_Edition_UnknownEditionFailsClosed() public {
        RendererEditionsMock editions = new RendererEditionsMock(address(stream));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector,
                address(editions),
                IEditions.masterOf.selector
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
                    IRenderer.RendererReadFailed.selector, address(stream), onStream[i]
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
                    IRenderer.RendererReadFailed.selector, address(records), onRecords[i]
                )
            );
            renderer.tokenURI(address(stream), ID);
            records.fail(onRecords[i], false);
        }
    }

    function test_FailsClosed_NotAToken() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector, address(0xdead), IStream.work.selector
            )
        );
        renderer.tokenURI(address(0xdead), 1);
    }

    function test_FailsClosed_ABurnedOrUnknownToken() public {
        stream.fail(IStream.work.selector, true); // `UnknownWork` in the real Stream
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererReadFailed.selector, address(stream), IStream.work.selector
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
            abi.encodeWithSelector(IRenderer.RendererRecordInvalid.selector, address(stream), ID)
        );
    }

    function test_TheMostExpensiveRecordStaysWithinTheBudget() public {
        // 16 artists and the most attributes, with a description filling the record limit.
        bytes32 file = _file(png, IDENTITY, "image/png");
        Rec memory r = _rec();
        r.artists = new string[](16);
        for (uint256 i; i < 16; ++i) {
            r.artists[i] = _text(64);
        }
        r.attributes = new Trait[](MAX_ATTRIBUTES);
        for (uint256 i; i < MAX_ATTRIBUTES; ++i) {
            r.attributes[i] = Trait(_text(24), _text(64));
        }
        r.description = "";
        r.description = _text(Limits.MAX_RECORD_BYTES - _json(r).length);
        assertEq(_json(r).length, Limits.MAX_RECORD_BYTES);
        _install(file, r);
        uint256 before = gasleft();
        string memory uri = renderer.tokenURI(address(stream), ID);
        uint256 used = before - gasleft();
        emit log_named_uint("tokenURI gas, maximal record", used);
        assertLt(used, 8_000_000);
        assertGt(bytes(uri).length, Limits.MAX_RECORD_BYTES);
    }

    function _text(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = bytes1(uint8(97 + (i % 26)));
        }
        return string(b);
    }
}
