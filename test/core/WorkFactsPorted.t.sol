// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { Facts } from "src/interfaces/core/CoreTypes.sol";
import { ILocators } from "src/interfaces/core/ILocators.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { WorkRules } from "src/records/WorkRules.sol";
import { RulesFixture } from "../records/RulesFixture.sol";

/// @notice `WorkFacts` behaviour carried over from the `WorkRecords` suites that the first port
///         left out: refusals on either side of each compared value, store failures passed on
///         as they are, files of other digest kinds, item values today's enums do not name,
///         previews of any size, the 16-chunk license text bound and the views of a work
///         whose record is not open. Driven through `bare` (a pass-through RECORDS module)
///         unless the test is about `WorkRules`.
contract WorkFactsPortedTest is RulesFixture {
    error Broken();

    address internal b;
    address internal s;

    function setUp() public override {
        super.setUp();
        b = address(bare);
        s = address(stream);
    }

    function _expectBadOpen(uint256 id, PackageItem memory item, MediaFile[] memory media)
        internal
    {
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        facts.open(b, id, item, media);
    }

    /// @dev A one-chunk file of `data` registered with digest kind 1 (not SHA-256), stored.
    function _otherDigestKind(bytes memory data, string memory mime) internal returns (bytes32) {
        store.writeChunk(data);
        (bytes32 list,) = store.writeChunk(abi.encodePacked(keccak256(data)));
        bytes32[] memory lists = new bytes32[](1);
        lists[0] = list;
        return store.registerManifestList(
            lists, 1, data.length, uint8(IContentStore.Encoding.Identity), mime, keccak256(data), 1
        );
    }

    /// @dev A text of `count` chunks (every full chunk the same bytes, then a 10-byte last
    ///      chunk), registered and stored.
    function _longText(uint256 count) internal returns (bytes32) {
        uint256 size = store.CHUNK_SIZE();
        bytes memory full = new bytes(size);
        full[0] = "T";
        bytes memory last = "last chunk";
        bytes32[] memory hashes = new bytes32[](count);
        for (uint256 i; i + 1 < count; ++i) {
            hashes[i] = keccak256(full);
        }
        hashes[count - 1] = keccak256(last);
        store.writeChunk(full);
        store.writeChunk(last);
        return store.registerManifest(
            hashes,
            (count - 1) * size + last.length,
            uint8(IContentStore.Encoding.Identity),
            "text/plain",
            keccak256(abi.encode("long text", count))
        );
    }

    function _withLicense(uint256 salt, License memory license)
        internal
        returns (uint256 id, PackageItem memory item)
    {
        MediaFile[] memory media = _single(salt);
        item = _item(salt, media);
        item.license = license;
        id = _mintItem(bare, item);
        facts.open(b, id, item, media);
    }

    // ---------------------------------------------------------------- open: either way

    /// @dev An item other than the minted one is refused whichever way its hash sorts against
    ///      the minted item's.
    function test_Open_RefusesAnotherItemEitherWay() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        bytes32 minted = WorksHashing.itemHash(item);
        bool below;
        bool above;
        for (uint256 i = 1; !(below && above); ++i) {
            item.recordFileId = keccak256(abi.encode("another record", i));
            bool lower = WorksHashing.itemHash(item) < minted;
            if (lower ? below : above) continue;
            if (lower) below = true;
            else above = true;
            _expectBadOpen(id, item, media);
        }
    }

    /// @dev A media list other than the committed one is refused whichever way its commitment
    ///      sorts against the item's media hash.
    function test_Open_RefusesOtherMediaEitherWay() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        MediaFile[] memory other = new MediaFile[](2);
        other[0] = media[0];
        bool below;
        bool above;
        for (uint256 i = 1; !(below && above); ++i) {
            other[1] = _mediaFile(100 + i, FileRole.AUXILIARY, false);
            bool lower = WorksHashing.mediaHash(other) < item.mediaHash;
            if (lower ? below : above) continue;
            if (lower) below = true;
            else above = true;
            _expectBadOpen(id, item, other);
        }
    }

    /// @dev A content hash other than the primary file's SHA-256 never opens, whichever way the
    ///      two sort.
    function test_Open_RefusesAContentHashOtherThanThePrimarysEitherWay() public {
        bytes32[2] memory wrong = [bytes32(uint256(1)), bytes32(type(uint256).max)];
        for (uint256 i; i < wrong.length; ++i) {
            MediaFile[] memory media = _single(1 + i);
            PackageItem memory item = _item(1 + i, media);
            item.contentHash = wrong[i];
            _expectBadOpen(_mintItem(bare, item), item, media);
        }
    }

    /// @dev A file's declared SHA-256 must be the content store's, whichever way a wrong one
    ///      sorts against it.
    function test_Open_RefusesADeclaredHashOtherThanTheStoresEitherWay() public {
        bytes32[2] memory wrong = [bytes32(uint256(1)), bytes32(type(uint256).max)];
        for (uint256 i; i < wrong.length; ++i) {
            MediaFile[] memory media = _single(1 + i);
            media[0].sha256Hash = wrong[i];
            PackageItem memory item = _item(1 + i, media);
            _expectBadOpen(_mintItem(bare, item), item, media);
        }
    }

    function test_Open_RefusesATokenNeverMinted() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 9));
        facts.open(b, 9, item, media);
    }

    // ------------------------------------------------------------ open: what it stores

    /// @dev An approved license whose text is not even registered opens (it is stored as the
    ///      item states it); finalize is where the store refuses it.
    function test_Open_KeepsAnUnregisteredLicenseTextThatFinalizeRefuses() public {
        bytes32 unknown = keccak256("unregistered text");
        (uint256 id,) = _withLicense(1, License("MIT", unknown));
        assertEq(facts.factsOf(b, id).licenseTextFileId, unknown);
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown));
        records.finalize(b, id);
    }

    /// @dev The CC0 text under another identifier is that identifier's license, whichever way
    ///      its key sorts against CC0's; a CC0 license naming a text next to the deployment's,
    ///      on either side, never opens.
    function test_Open_TheCc0TextUnderAnotherIdentifierAndCc0WithAnotherTextEitherWay() public {
        bytes32[2] memory texts = [bytes32(uint256(cc0Text) - 1), bytes32(uint256(cc0Text) + 1)];
        for (uint256 i; i < texts.length; ++i) {
            MediaFile[] memory media = _single(10 + i);
            PackageItem memory item = _item(10 + i, media);
            item.license = License("cc0-1.0", texts[i]);
            uint256 id = _mintItem(bare, item);
            vm.expectRevert(IWorkFacts.InvalidLicense.selector);
            facts.open(b, id, item, media);
        }
        string[2] memory ids = ["mit", "unlicense"];
        assertLt(uint256(WorksHashing.licenseKey(ids[0])), uint256(WorksHashing.CC0_LICENSE_KEY));
        assertGt(uint256(WorksHashing.licenseKey(ids[1])), uint256(WorksHashing.CC0_LICENSE_KEY));
        for (uint256 i; i < ids.length; ++i) {
            (uint256 id,) = _withLicense(20 + i, License(ids[i], cc0Text));
            assertEq(facts.factsOf(b, id).licenseId, ids[i]);
            // Not CC0, so it may move.
            records.setLicense(b, id, License("CC-BY-4.0", mitText));
        }
    }

    /// @dev `WorkFacts` holds no renderer budget: a preview of any size or encoding opens; an
    ///      unregistered one reverts with the store's own error.
    function test_Open_APreviewOfAnySizeOrEncodingOpens() public {
        uint256[3] memory lengths = [Limits.MAX_PREVIEW_BYTES + 1, 16_384, 4_096];
        IContentStore.Encoding[3] memory encodings = [
            IContentStore.Encoding.Identity,
            IContentStore.Encoding.Base64,
            IContentStore.Encoding.Identity
        ];
        for (uint256 i; i < 3; ++i) {
            MediaFile[] memory media = new MediaFile[](2);
            media[0] = _mediaFile(50 + i, FileRole.PRIMARY, true);
            bytes memory data = new bytes(lengths[i]);
            data[0] = bytes1(uint8(i + 1));
            bytes32[] memory hashes = new bytes32[](1);
            hashes[0] = keccak256(data);
            bytes32 fileId = store.registerManifest(
                hashes, data.length, uint8(encodings[i]), "image/png", sha256(data)
            );
            media[1] = MediaFile(fileId, sha256(data), uint8(FileRole.PREVIEW));
            PackageItem memory item = _item(50 + i, media);
            uint256 id = _mintItem(bare, item);
            facts.open(b, id, item, media);
            assertTrue(facts.factsOf(b, id).opened);
        }
        MediaFile[] memory bad = new MediaFile[](2);
        bad[0] = _mediaFile(60, FileRole.PRIMARY, true);
        bad[1] = MediaFile(keccak256("unregistered preview"), sha256("p"), uint8(FileRole.PREVIEW));
        PackageItem memory badItem = _item(60, bad);
        uint256 badId = _mintItem(bare, badItem);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, bad[1].fileId)
        );
        facts.open(b, badId, badItem, bad);
    }

    /// @dev An item a future mint policy defines opens: kind, seed policy and a party role that
    ///      today's enums do not name, and media roles past today's (`role` is a whole byte),
    ///      stored as given.
    function test_Open_ItemValuesTodaysEnumsDoNotName() public {
        MediaFile[] memory media = new MediaFile[](3);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.AUXILIARY, false);
        media[2] = _mediaFile(3, FileRole.AUXILIARY, false);
        media[1].role = 9;
        media[2].role = 255;
        PackageItem memory item = _item(1, media);
        item.kind = 3;
        item.seedPolicy = 3;
        item.seed = keccak256("future seed");
        item.parties[0].role = 7;
        uint256 id = _mintItem(bare, item);
        facts.open(b, id, item, media);
        Facts memory f = facts.factsOf(b, id);
        assertEq(f.media[1].role, 9);
        assertEq(f.media[2].role, 255);
    }

    // ------------------------------------------------------------- store failures

    /// @dev A failure of the content store is passed on as it is, whatever its selector, never
    ///      read as a plausible default: in `open` and in `WorkRules.setRecord`.
    function test_StoreFailuresPropagate() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        vm.mockCallRevert(
            address(store),
            abi.encodeWithSelector(IContentStore.sha256Of.selector),
            abi.encodeWithSelector(Broken.selector)
        );
        vm.expectRevert(Broken.selector);
        facts.open(b, id, item, media);
        vm.clearMockedCalls();
        facts.open(b, id, item, media);

        (uint256 work,,) = _work(stream, 2);
        bytes32 next = _record(77);
        bytes32 state = rules.workStateHash(s, work);
        bytes[2] memory reasons =
            [abi.encodeWithSelector(Broken.selector), abi.encodePacked(bytes4(0xffffffff))];
        for (uint256 i; i < 2; ++i) {
            vm.mockCallRevert(
                address(store), abi.encodeWithSelector(IContentStore.fileInfo.selector), reasons[i]
            );
            vm.prank(artist);
            vm.expectRevert(reasons[i]);
            rules.setRecord(s, work, next, state);
            vm.clearMockedCalls();
        }
    }

    // --------------------------------------------------------------- digest kinds

    /// @dev Every file the record takes needs a SHA-256 digest: a license text (before and
    ///      after finalize), a record file (set by the rules, or approved and then finalized)
    ///      and a media file, each refused as a complete one-chunk file of digest kind 1.
    function test_DigestKind_EveryFileNeedsSha256() public {
        bytes32 otherText = _otherDigestKind("kind one text", "text/plain");
        assertTrue(store.isComplete(otherText));
        (uint256 id,) = _withLicense(1, License("MIT", mitText));
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.setLicense(b, id, License("Apache-2.0", otherText));
        records.finalize(b, id);
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.setLicense(b, id, License("Apache-2.0", otherText));
        // An approved license text of another kind never finalizes.
        (uint256 approved,) = _withLicense(2, License("MIT", otherText));
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.finalize(b, approved);

        // A record file: refused by the rules, and refused at finalize when approved.
        bytes32 otherRecord = _otherDigestKind('{"name":"kind one"}', "application/json");
        (uint256 work,,) = _work(stream, 3);
        bytes32 state = rules.workStateHash(s, work);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(WorkRules.InvalidRecordFile.selector, otherRecord));
        rules.setRecord(s, work, otherRecord, state);
        MediaFile[] memory media = _single(4);
        PackageItem memory item = _item(4, media);
        item.recordFileId = otherRecord;
        uint256 withRecord = _mintItem(bare, item);
        facts.open(b, withRecord, item, media);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, withRecord));
        records.finalize(b, withRecord);

        // A media file.
        bytes memory data = _mediaBytes(44);
        MediaFile[] memory kindOne = new MediaFile[](1);
        kindOne[0] =
            MediaFile(_otherDigestKind(data, "image/png"), sha256(data), uint8(FileRole.PRIMARY));
        PackageItem memory mediaItem = _item(44, kindOne);
        uint256 minted = _mintItem(bare, mediaItem);
        vm.expectRevert(
            abi.encodeWithSelector(
                IContentStore.ContentDigestNotSha256.selector, kindOne[0].fileId, 1
            )
        );
        facts.open(b, minted, mediaItem, kindOne);
    }

    // ------------------------------------------------------------- license texts

    /// @dev The deployment's CC0 text is held to the same rule as any other: a work on CC0
    ///      finalizes only while that text is complete in the store.
    function test_Finalize_TheDeploymentsCc0TextMustBeCompleteToo() public {
        (uint256 id,,) = _work(bare, 1);
        vm.mockCall(
            address(store), abi.encodeCall(IContentStore.isComplete, (cc0Text)), abi.encode(false)
        );
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.finalize(b, id);
        vm.clearMockedCalls();
        records.finalize(b, id);
    }

    /// @dev A license text that must be complete on-chain has at most 16 chunks: 16 complete
    ///      chunks finalize, 17 never do, and a finalized work cannot move to 17.
    function test_LicenseText_SixteenChunksIsTheBound() public {
        bytes32 sixteen = _longText(16);
        bytes32 seventeen = _longText(17);
        assertTrue(store.isComplete(sixteen) && store.isComplete(seventeen));
        (uint256 tooLong,) = _withLicense(1, License("LicenseRef-Long", seventeen));
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.finalize(b, tooLong);
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.lock(b, tooLong, true, false);

        (uint256 bounded,) = _withLicense(2, License("LicenseRef-Bounded", sixteen));
        records.lock(b, bounded, true, false);
        records.finalize(b, bounded);
        assertTrue(facts.factsOf(b, bounded).finalized);
        (uint256 moved,) = _withLicense(3, License("MIT", mitText));
        records.finalize(b, moved);
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.setLicense(b, moved, License("LicenseRef-Long", seventeen));
        records.setLicense(b, moved, License("LicenseRef-Bounded", sixteen));
    }

    // ----------------------------------------------------------------- views

    /// @dev A minted work whose record is not open: the rules' state hash and the delivery's
    ///      answer refuse it, nothing is renounced, no renderer is pinned, and the token falls
    ///      back to its RENDERER module.
    function test_Views_ARecordNotOpen() public {
        uint256 id = _mintItem(stream, _item(1, _single(1)));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RecordNotOpen.selector, s, id));
        rules.workStateHash(s, id);
        vm.expectRevert(abi.encodeWithSelector(IWorkDelivery.RecordNotOpen.selector, s, id));
        ILocators(address(delivery)).preferredLocator(s, id, bytes32(0));
        assertEq(rules.renouncedPowers(s, id), 0);
        assertEq(facts.rendererOf(s, id), address(0));
        assertFalse(facts.factsOf(s, id).opened);
        assertEq(stream.rendererOf(id), address(renderer));
    }

    /// @dev A pinned renderer whose code moved is refused, whichever way its new code hash
    ///      sorts against the pin.
    function test_RendererOf_RefusesMovedCodeEitherWay() public {
        (uint256 id,,) = _work(bare, 1);
        records.finalize(b, id);
        address pinned = address(renderer);
        bytes memory code = pinned.code;
        bytes32 pin = pinned.codehash;
        bool below;
        bool above;
        for (uint256 i = 1; !(below && above); ++i) {
            bytes memory moved = abi.encodePacked(code, i);
            bool lower = keccak256(moved) < pin;
            if (lower ? below : above) continue;
            if (lower) below = true;
            else above = true;
            vm.etch(pinned, moved);
            vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, pinned));
            facts.rendererOf(b, id);
        }
        vm.etch(pinned, code);
        assertEq(facts.rendererOf(b, id), pinned);
    }
}
