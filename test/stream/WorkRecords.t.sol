// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { ItemKind, License, PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { MockRenderer } from "../mocks/stream/StreamMocks.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { RecordsFixture } from "./RecordsFixture.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { SignatureReverts } from "test/helpers/SignatureReverts.sol";

contract WorkRecordsTest is RecordsFixture {
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    uint256 internal constant NONE = type(uint256).max;

    // ------------------------------------------------------------------------------ deploy

    function test_constructor_wiring() public view {
        assertEq(records.stream(), address(stream));
        assertEq(records.artistRegistry(), address(artists));
        assertEq(records.contentStore(), address(store));
        assertEq(records.cc0TextFileId(), _textFileId("cc0-1.0"));
        assertEq(records.entropyModule(), address(entropy));
        assertTrue(records.supportsInterface(type(IWorkRecords).interfaceId));
        assertTrue(records.supportsInterface(0x01ffc9a7));
        assertFalse(records.supportsInterface(0xffffffff));
        assertEq(uint8(records.preferredKind()), uint8(LocatorKind.NONE));
        (, string memory name, string memory version, uint256 chainId, address verifying,,) =
            records.eip712Domain();
        assertEq(name, "6529 Works Records");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(records));
    }

    function test_constructor_rejects() public {
        address eoa = makeAddr("eoa");
        License memory cc0 = _license("cc0-1.0");
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new WorkRecords(address(manager), eoa, address(store), cc0);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(store))
        );
        new WorkRecords(address(manager), address(store), address(store), cc0);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new WorkRecords(address(manager), address(stream), eoa, cc0);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        new WorkRecords(address(manager), address(stream), address(store), _license("mit"));
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        new WorkRecords(address(manager), address(stream), address(store), _license("cc0 1.0"));
        // The CC0 text must be a registered content-store file.
        bytes32 unknown = keccak256("unregistered cc0 text");
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown));
        new WorkRecords(
            address(manager), address(stream), address(store), License("cc0-1.0", unknown)
        );
    }

    /// @dev SPDX IDs keep their original case; only the license key is lowercased.
    function test_constructor_keepsCc0Case() public {
        WorkRecords other = new WorkRecords(
            address(manager), address(stream), address(store), _license("CC0-1.0")
        );
        assertEq(other.cc0TextFileId(), _license("CC0-1.0").textFileId);
    }

    function test_supportsInterface_refusesALowerId() public view {
        bytes4 lower = bytes4(uint32(type(IWorkRecords).interfaceId) - 1);
        assertTrue(lower != 0x01ffc9a7);
        assertFalse(records.supportsInterface(lower));
    }

    /// @dev The deployment's CC0 license must carry CC0's key: an identifier whose key sorts
    ///      below it ("mit") or above it ("unlicense") is refused.
    function test_constructor_refusesANonCc0KeyEitherWay() public {
        string[2] memory ids = ["mit", "unlicense"];
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(IWorkRecords.InvalidLicense.selector);
            new WorkRecords(address(manager), address(stream), address(store), _license(ids[i]));
        }
    }

    // ------------------------------------------------------------------------ openRecord

    function test_openRecord_permissionless() public {
        (uint256 tokenId, PackageItem memory item, MediaFile[] memory media) = _minted(1, false);
        vm.expectEmit(address(records));
        emit IWorkRecords.RecordOpened(tokenId, item.recordFileId, item.mediaHash);
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(outsider);
        records.openRecord(tokenId, item, media);

        IWorkRecords.RecordInfo memory info = records.record(tokenId);
        assertEq(info.recordFileId, item.recordFileId);
        assertEq(info.mediaHash, item.mediaHash);
        assertEq(info.licenseKey, WorksHashing.CC0_LICENSE_KEY);
        assertEq(info.version, 0);
        assertTrue(records.isOpen(tokenId));
        assertFalse(info.finalized);
        assertFalse(info.onChainComplete);
        assertEq(info.renderer, address(0));
        assertEq(abi.encode(records.mediaOf(tokenId)), abi.encode(media));
        assertEq(abi.encode(records.licenseOf(tokenId)), abi.encode(_license("cc0-1.0")));
        assertEq(records.pinnedRenderer(tokenId), address(0));
    }

    function test_openRecord_multiFileWithRoles() public {
        MediaFile[] memory media = new MediaFile[](3);
        media[0] = _mediaFile(1, FileRole.PRIMARY, false);
        media[1] = _mediaFile(2, FileRole.PREVIEW, false);
        media[2] = _mediaFile(3, FileRole.AUXILIARY, false);
        PackageItem memory item = _recordsItem(1, media);
        item.license = _license("cc-by-4.0");
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertEq(abi.encode(records.mediaOf(tokenId)), abi.encode(media));
        assertEq(records.record(tokenId).licenseKey, keccak256("cc-by-4.0"));
        assertEq(records.licenseOf(tokenId).spdxId, "cc-by-4.0");
    }

    function test_openRecord_rejectsMismatches() public {
        (uint256 tokenId, PackageItem memory item, MediaFile[] memory media) = _minted(1, false);
        records.openRecord(tokenId, item, media);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.RecordAlreadyOpen.selector, tokenId));
        records.openRecord(tokenId, item, media);

        (uint256 other, PackageItem memory otherItem, MediaFile[] memory otherMedia) =
            _minted(2, false);
        // The item of another token.
        _expectBadOpen(other, item, otherMedia);
        // Media that is not the committed list.
        _expectBadOpen(other, otherItem, media);
        _expectBadOpen(other, otherItem, new MediaFile[](0));

        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, 9));
        records.openRecord(9, otherItem, otherMedia);
        auction.burn(stream, other, 1);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownWork.selector, other));
        records.openRecord(other, otherItem, otherMedia);
    }

    function test_openRecord_rejectsBadMediaFacts() public {
        // The primary's hash is not the item's content hash.
        MediaFile[] memory media = _single(1, false);
        PackageItem memory item = _recordsItem(1, media);
        item.contentHash = keccak256("other");
        _expectBadOpen(_mint(item), item, media);

        // A declared SHA-256 that is not the content store's.
        media = _single(2, false);
        media[0].sha256Hash = keccak256("lie");
        item = _recordsItem(2, media);
        _expectBadOpen(_mint(item), item, media);

        // An unregistered file: the store's own error.
        media = _single(3, false);
        media[0].fileId = keccak256("unregistered");
        item = _recordsItem(3, media);
        uint256 tokenId = _mint(item);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, media[0].fileId)
        );
        records.openRecord(tokenId, item, media);

        // The primary is not first, or there are two.
        media = new MediaFile[](2);
        media[0] = _mediaFile(4, FileRole.PREVIEW, false);
        media[1] = _mediaFile(5, FileRole.PRIMARY, false);
        item = _recordsItem(4, media);
        _expectBadOpen(_mint(item), item, media);
        media[0] = _mediaFile(14, FileRole.PRIMARY, false);
        item = _recordsItem(5, media);
        _expectBadOpen(_mint(item), item, media);

        // More than 32 files.
        media = new MediaFile[](33);
        media[0] = _mediaFile(6, FileRole.PRIMARY, false);
        for (uint256 i = 1; i < 33; ++i) {
            media[i] = _mediaFile(100 + i, FileRole.AUXILIARY, false);
        }
        item = _recordsItem(6, media);
        _expectBadOpen(_mint(item), item, media);

        // An invalid license identifier cannot reach `openRecord`: the core refuses it at mint
        // (`Stream.t.sol`, `test_mint_revertsForStreamRuleBreaks`).
    }

    /// @dev An item other than the minted one is refused whichever way its hash sorts against
    ///      the minted item's (found by mutation testing).
    function test_openRecord_refusesAnotherItemEitherWay() public {
        (uint256 tokenId, PackageItem memory item, MediaFile[] memory media) = _minted(1, false);
        bytes32 minted = WorksHashing.itemHash(item);
        bool below;
        bool above;
        for (uint256 i = 1; !(below && above); ++i) {
            item.recordFileId = keccak256(abi.encode("another record", i));
            bool lower = WorksHashing.itemHash(item) < minted;
            if (lower ? below : above) continue;
            if (lower) below = true;
            else above = true;
            _expectBadOpen(tokenId, item, media);
        }
    }

    /// @dev A valid media list other than the committed one is refused whichever way its
    ///      commitment sorts against the item's media hash (found by mutation testing).
    function test_openRecord_refusesOtherMediaEitherWay() public {
        (uint256 tokenId, PackageItem memory item, MediaFile[] memory media) = _minted(1, false);
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
            _expectBadOpen(tokenId, item, other);
        }
    }

    /// @dev An item whose content hash is not its primary file's SHA-256 never opens, whichever
    ///      way the two sort (found by mutation testing).
    function test_openRecord_refusesAContentHashOtherThanThePrimarysEitherWay() public {
        bytes32[2] memory wrong = [bytes32(uint256(1)), bytes32(type(uint256).max)];
        for (uint256 i; i < wrong.length; ++i) {
            MediaFile[] memory media = _single(1 + i, false);
            PackageItem memory item = _recordsItem(1 + i, media);
            item.contentHash = wrong[i];
            _expectBadOpen(_mint(item), item, media);
        }
    }

    /// @dev A file's declared SHA-256 must be the content store's, whichever way a wrong one
    ///      sorts against it (found by mutation testing).
    function test_openRecord_refusesADeclaredHashOtherThanTheStoresEitherWay() public {
        bytes32[2] memory wrong = [bytes32(uint256(1)), bytes32(type(uint256).max)];
        for (uint256 i; i < wrong.length; ++i) {
            MediaFile[] memory media = _single(1 + i, false);
            media[0].sha256Hash = wrong[i];
            PackageItem memory item = _recordsItem(1 + i, media);
            _expectBadOpen(_mint(item), item, media);
        }
    }

    /// @dev `openRecord` stores the approved license as it is, so an unregistered text cannot
    ///      freeze the work; `finalize` is where the text must be stored.
    function test_openRecord_storesUnregisteredLicenseText() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        bytes32 unknown = keccak256("unregistered text");
        item.license = License("MIT", unknown);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertEq(records.licenseOf(tokenId).textFileId, unknown);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown));
        records.finalize(tokenId, state);
    }

    /// @dev Finalize needs the license text complete on-chain, the default CC0 text included,
    ///      so a finalized work's license text is permanent (ADR 0001 section 8).
    function test_finalize_needsStoredLicenseText() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.license = License("MIT", _registerTextOnly("MIT text"));
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.finalize(tokenId, state);
        store.writeChunk("MIT text");
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertTrue(records.record(tokenId).finalized);

        // The deployment's default CC0 text is held to the same rule.
        bytes32 cc0Text = records.cc0TextFileId();
        (uint256 cc0Work,) = _work(2);
        state = records.workStateHash(cc0Work);
        vm.mockCall(
            address(store), abi.encodeCall(IContentStore.isComplete, (cc0Text)), abi.encode(false)
        );
        vm.prank(artist);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.finalize(cc0Work, state);
    }

    /// @dev The SPDX ID is stored in its original case; the key is of its lowercase form.
    function test_openRecord_keepsLicenseCase() public {
        MediaFile[] memory media = _single(1, false);
        PackageItem memory item = _recordsItem(1, media);
        item.license = _license("CC-BY-4.0");
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertEq(records.licenseOf(tokenId).spdxId, "CC-BY-4.0");
        assertEq(records.record(tokenId).licenseKey, keccak256("cc-by-4.0"));
    }

    error Broken();

    /// @dev Only the store's "unknown file" error reads as unregistered; any other store
    ///      failure propagates instead of passing for a plausible default.
    function test_storeFailuresPropagate() public {
        (uint256 tokenId, PackageItem memory item, MediaFile[] memory media) = _minted(1, true);
        vm.mockCallRevert(
            address(store),
            abi.encodeWithSelector(IContentStore.sha256Of.selector),
            abi.encodeWithSelector(Broken.selector)
        );
        vm.expectRevert(Broken.selector);
        records.openRecord(tokenId, item, media);
        vm.clearMockedCalls();
        records.openRecord(tokenId, item, media);

        bytes32 next = _record(77);
        bytes32 state = records.workStateHash(tokenId);
        vm.mockCallRevert(
            address(store),
            abi.encodeWithSelector(IContentStore.fileInfo.selector),
            abi.encodeWithSelector(Broken.selector)
        );
        vm.prank(artist);
        vm.expectRevert(Broken.selector);
        records.setRecord(tokenId, next, state);
    }

    /// @dev An unregistered approved record file still opens (the renderer serves core-only
    ///      metadata); finalize refuses it until the artist sets a valid one.
    function test_openRecord_storesUnknownRecordFile() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.recordFileId = keccak256("no such record");
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertEq(records.record(tokenId).recordFileId, item.recordFileId);
        _expectRecordFixable(tokenId, item.recordFileId);
    }

    /// Regression: F1 in the reviews of #22
    /// @dev SPDX's canonical casing mints, opens, amends and finalizes; CC0 stays irrevocable
    ///      whatever its case.
    function test_openRecord_uppercaseSpdxMintsOpensAndAmends() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        // The deployment's CC0 text, under the identifier's canonical casing.
        item.license = License("CC0-1.0", records.cc0TextFileId());
        assertEq(WorksHashing.licenseKey("CC0-1.0"), WorksHashing.CC0_LICENSE_KEY);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertEq(records.licenseOf(tokenId).spdxId, "CC0-1.0");
        assertEq(records.record(tokenId).licenseKey, WorksHashing.CC0_LICENSE_KEY);

        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 10_000, state, deadline));
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 10_000, item, state, deadline, sigs);
        assertEq(stream.work(tokenId).royaltyRate, 10_000);

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.LicenseIrrevocable.selector, tokenId));
        records.relicense(tokenId, _license("mit"), item, bytes32(0), 0, new bytes[](0));

        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertTrue(records.record(tokenId).finalized);
    }

    /// Regression: F1b in the reviews of #22
    /// @dev Media commitments are not visible at mint. A mis-committed item mints and can
    ///      never open, which is why the curation signer's tooling MUST simulate `openRecord`
    ///      before attesting (a trust obligation, documented in `openRecord` and the README).
    function test_openRecord_aMisCommittedItemMintsButNeverOpens() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.contentHash = keccak256("not the primary");
        uint256 tokenId = _mint(item);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRecordData.selector, tokenId));
        records.openRecord(tokenId, item, media);
    }

    function _manifest(bytes32[] memory hashes, uint256 length, IContentStore.Encoding enc)
        internal
        returns (bytes32)
    {
        return store.registerManifest(hashes, length, enc, "application/json", keccak256("x"));
    }

    /// @dev The work's approved record is `bad`: finalize refuses it, and the artist replaces
    ///      it with a valid record and finalizes.
    function _fixRecord(uint256 tokenId, bytes32 bad) internal {
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, bad));
        records.finalize(tokenId, state);
        bytes32 good = _record(99);
        vm.prank(artist);
        records.setRecord(tokenId, good, state);
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(records.record(tokenId).recordFileId, good);
    }

    /// Regression: N1a in the reviews of #22
    /// @dev An approved two-chunk record (longer than one content-store chunk) opens, and the
    ///      artist replaces it with `setRecord` before finalize.
    function test_openRecord_aTwoChunkRecordOpensAndIsFixable() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("chunk0");
        hashes[1] = keccak256("chunk1");
        item.recordFileId =
            _manifest(hashes, store.CHUNK_SIZE() + 100, IContentStore.Encoding.Identity);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertTrue(records.isOpen(tokenId));
        _fixRecord(tokenId, item.recordFileId);
    }

    /// Regression: N1b in the reviews of #22
    /// @dev An approved gzip-encoded record opens, and is fixable the same way.
    function test_openRecord_aGzipRecordOpensAndIsFixable() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        bytes memory data = bytes("gzip-stream");
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(data);
        item.recordFileId = _manifest(hashes, data.length, IContentStore.Encoding.Gzip);
        store.writeChunk(data);
        assertTrue(store.isComplete(item.recordFileId));
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        _fixRecord(tokenId, item.recordFileId);
    }

    /// Regression: N1c in the reviews of #22
    /// @dev A license whose text file ID has no manifest opens. Finalize refuses it until the
    ///      parties and governance relicense to a stored text.
    function test_openRecord_anUnregisteredLicenseTextOpensAndIsFixable() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        bytes32 unknown = keccak256("typo in the text file id");
        item.license = License("CC-BY-4.0", unknown);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown));
        records.finalize(tokenId, state);

        _relicense(tokenId, item, _license("CC-BY-4.0"));
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(records.licenseOf(tokenId).textFileId, _license("CC-BY-4.0").textFileId);
    }

    /// Regression: N1c in the reviews of #22, amended when #56 pinned the CC0 text
    /// @dev A CC0 license names the deployment's CC0 text, so an approved CC0 license with a
    ///      mistyped text cannot open (there is no correction to make later), while the
    ///      deployment's text in any casing opens and finalizes; leaving CC0 stays refused.
    function test_openRecord_cc0TextMustBeTheDeploymentText() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.license = License("CC0-1.0", keccak256("typo"));
        uint256 tokenId = _mint(item);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.openRecord(tokenId, item, media);

        media = _single(2, true);
        item = _recordsItem(2, media);
        item.license = License("CC0-1.0", records.cc0TextFileId());
        tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.LicenseIrrevocable.selector, tokenId));
        records.relicense(tokenId, _license("mit"), item, bytes32(0), 0, new bytes[](0));
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(records.record(tokenId).licenseKey, WorksHashing.CC0_LICENSE_KEY);
    }

    /// @dev `bad` is the work's record: finalize refuses it, and the artist replaces it with a
    ///      valid record and finalizes.
    function _expectRecordFixable(uint256 tokenId, bytes32 bad) internal {
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, bad));
        records.finalize(tokenId, state);
        bytes32 good = _record(tokenId + 500);
        vm.prank(artist);
        records.setRecord(tokenId, good, state);
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(records.record(tokenId).recordFileId, good);
    }

    /// @dev Registers a record manifest over `chunks` with `encoding`, uploading them if asked.
    function _recordFile(bytes[] memory chunks, IContentStore.Encoding encoding, bool upload)
        internal
        returns (bytes32)
    {
        bytes32[] memory hashes = new bytes32[](chunks.length);
        uint256 length;
        for (uint256 i; i < chunks.length; ++i) {
            hashes[i] = keccak256(chunks[i]);
            length += chunks[i].length;
            if (upload) store.writeChunk(chunks[i]);
        }
        return store.registerManifest(
            hashes, length, encoding, "application/json", keccak256(abi.encode(hashes))
        );
    }

    function _oneChunk(bytes memory data) internal pure returns (bytes[] memory chunks) {
        chunks = new bytes[](1);
        chunks[0] = data;
    }

    /// @dev `recordFileId` is refused by `setRecord`; as an approved record it still opens,
    ///      and the artist fixes it before finalize.
    function _expectBadRecord(uint256 salt, bytes32 recordFileId) internal {
        (uint256 tokenId,) = _work(salt);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, recordFileId)
        );
        records.setRecord(tokenId, recordFileId, state);

        MediaFile[] memory media = _single(salt + 1000, true);
        PackageItem memory item = _recordsItem(salt + 1000, media);
        item.recordFileId = recordFileId;
        tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        _expectRecordFixable(tokenId, recordFileId);
    }

    /// @dev The structural record bounds, at every set and at finalize: one complete
    ///      `Identity` chunk of at most `MAX_RECORD_BYTES`.
    function test_recordBounds_rejectStructuralBreaks() public {
        bytes memory json = '{"name":"r"}';
        // Registered, not stored yet.
        _expectBadRecord(1, _recordFile(_oneChunk(json), IContentStore.Encoding.Identity, false));
        // Stored, but not `Identity` encoding.
        _expectBadRecord(2, _recordFile(_oneChunk(json), IContentStore.Encoding.Gzip, true));
        _expectBadRecord(3, _recordFile(_oneChunk(json), IContentStore.Encoding.Base64, true));
        // Two stored chunks, and so longer than `MAX_RECORD_BYTES`.
        bytes[] memory two = new bytes[](2);
        two[0] = new bytes(store.CHUNK_SIZE());
        two[1] = "}";
        _expectBadRecord(4, _recordFile(two, IContentStore.Encoding.Identity, true));
        // One chunk, one byte over the bound (when the bound is below a full chunk).
        if (Limits.MAX_RECORD_BYTES < store.CHUNK_SIZE()) {
            _expectBadRecord(
                5,
                _recordFile(
                    _oneChunk(new bytes(Limits.MAX_RECORD_BYTES + 1)),
                    IContentStore.Encoding.Identity,
                    true
                )
            );
        }
    }

    /// @dev A full chunk is accepted, and the JSON is not parsed here: the renderer validates
    ///      it and falls back to core-only metadata for an invalid record.
    function test_recordBounds_acceptCompleteSingleChunk() public {
        (uint256 tokenId,) = _work(1);
        bytes32 full = _recordFile(
            _oneChunk(new bytes(Limits.MAX_RECORD_BYTES)), IContentStore.Encoding.Identity, true
        );
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.setRecord(tokenId, full, state);
        assertEq(records.record(tokenId).recordFileId, full);

        bytes32 notJson = _recordFile(_oneChunk("not json"), IContentStore.Encoding.Identity, true);
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.setRecord(tokenId, notJson, state);
        state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(records.record(tokenId).recordFileId, notJson);
    }

    /// @dev A PREVIEW file is at most `Limits.MAX_PREVIEW_BYTES`, an `Identity` one counting four
    ///      times; an unregistered one reverts with the store's error, like any media file.
    function test_openRecord_previewCap() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(40, FileRole.PRIMARY, false);
        bytes memory big = new bytes(Limits.MAX_PREVIEW_BYTES / 4 + 1);
        media[1] = MediaFile(_file(big, "image/png", false), sha256(big), FileRole.PREVIEW);
        PackageItem memory item = _recordsItem(40, media);
        _expectBadOpen(_mint(item), item, media);

        // At the cap it opens.
        media[0] = _mediaFile(41, FileRole.PRIMARY, false);
        bytes memory fits = new bytes(Limits.MAX_PREVIEW_BYTES / 4);
        media[1] = MediaFile(_file(fits, "image/png", false), sha256(fits), FileRole.PREVIEW);
        item = _recordsItem(41, media);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertTrue(records.isOpen(tokenId));

        media[0] = _mediaFile(42, FileRole.PRIMARY, false);
        media[1].fileId = keccak256("unregistered preview");
        item = _recordsItem(42, media);
        tokenId = _mint(item);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, media[1].fileId)
        );
        records.openRecord(tokenId, item, media);
    }

    /// @dev The cap is exactly 16,384 bytes (16 KiB, as the README states): a preview declared
    ///      `Base64` of that length opens, one byte more does not, and an `Identity` one counts
    ///      four times its length.
    function test_openRecord_previewCapIsExact() public {
        uint256[3] memory lengths = [uint256(16_384), 16_385, 4_096];
        IContentStore.Encoding[3] memory encodings = [
            IContentStore.Encoding.Base64,
            IContentStore.Encoding.Base64,
            IContentStore.Encoding.Identity
        ];
        bool[3] memory opens = [true, false, true];
        for (uint256 i; i < 3; ++i) {
            MediaFile[] memory media = new MediaFile[](2);
            media[0] = _mediaFile(50 + i, FileRole.PRIMARY, false);
            bytes memory data = new bytes(lengths[i]);
            data[0] = bytes1(uint8(i + 1));
            bytes32[] memory hashes = new bytes32[](1);
            hashes[0] = keccak256(data);
            bytes32 fileId = store.registerManifest(
                hashes, data.length, encodings[i], "image/png", sha256(data)
            );
            media[1] = MediaFile(fileId, sha256(data), FileRole.PREVIEW);
            PackageItem memory item = _recordsItem(50 + i, media);
            uint256 tokenId = _mint(item);
            if (opens[i]) {
                records.openRecord(tokenId, item, media);
                assertTrue(records.isOpen(tokenId));
            } else {
                _expectBadOpen(tokenId, item, media);
            }
        }
    }

    function _expectBadOpen(uint256 tokenId, PackageItem memory item, MediaFile[] memory media)
        internal
    {
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRecordData.selector, tokenId));
        records.openRecord(tokenId, item, media);
    }

    function test_views_revertBeforeOpen() public {
        (uint256 tokenId,,) = _minted(1, false);
        bytes memory notOpen = abi.encodeWithSelector(IWorkRecords.RecordNotOpen.selector, tokenId);
        vm.expectRevert(notOpen);
        records.record(tokenId);
        vm.expectRevert(notOpen);
        records.workStateHash(tokenId);
        vm.expectRevert(notOpen);
        records.mediaOf(tokenId);
        vm.expectRevert(notOpen);
        records.licenseOf(tokenId);
        vm.expectRevert(notOpen);
        records.syncOnChain(tokenId);
        vm.expectRevert(notOpen);
        records.pinnedRenderer(tokenId);
        vm.expectRevert(notOpen);
        records.seedOf(tokenId);
        vm.expectRevert(notOpen);
        records.locators(tokenId, bytes32(0));
        vm.expectRevert(notOpen);
        records.filePreference(tokenId, bytes32(0));
        vm.expectRevert(notOpen);
        records.preferredLocator(tokenId, bytes32(0));
        assertFalse(records.isOpen(tokenId));
        // The core falls back to its default renderer for a work with no open record.
        assertEq(stream.rendererOf(tokenId), address(renderer));
    }

    /// @dev A CC0 license must name the deployment's CC0 text, whichever way another text sorts;
    ///      and the CC0 text under another identifier, sorting below or above "cc0-1.0", is that
    ///      identifier's license, not the default.
    function test_openRecord_cc0TextAndDefaultLicenseEitherWay() public {
        bytes32 cc0Text = records.cc0TextFileId();
        bytes32[2] memory texts = [bytes32(uint256(cc0Text) - 1), bytes32(uint256(cc0Text) + 1)];
        for (uint256 i; i < texts.length; ++i) {
            MediaFile[] memory media = _single(10 + i, true);
            PackageItem memory item = _recordsItem(10 + i, media);
            item.license = License("cc0-1.0", texts[i]);
            uint256 tokenId = _mint(item);
            vm.expectRevert(IWorkRecords.InvalidLicense.selector);
            records.openRecord(tokenId, item, media);
        }
        string[2] memory ids = ["mit", "unlicense"];
        for (uint256 i; i < ids.length; ++i) {
            MediaFile[] memory media = _single(20 + i, true);
            PackageItem memory item = _recordsItem(20 + i, media);
            item.license = License(ids[i], cc0Text);
            uint256 tokenId = _mint(item);
            records.openRecord(tokenId, item, media);
            assertEq(records.licenseOf(tokenId).spdxId, ids[i]);
        }
    }

    // --------------------------------------------------------------------------- records

    function test_setRecord() public {
        (uint256 tokenId,) = _work(1);
        bytes32 next = _record(77);
        bytes32 before = records.workStateHash(tokenId);
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(artist);
        records.setRecord(tokenId, next, before);
        IWorkRecords.RecordInfo memory info = records.record(tokenId);
        assertEq(info.recordFileId, next);
        assertEq(info.version, 1);
        assertTrue(records.workStateHash(tokenId) != before);
    }

    function test_setRecord_emitsNewStateHash() public {
        (uint256 tokenId,) = _work(1);
        bytes32 next = _record(77);
        bytes32 before = records.workStateHash(tokenId);
        vm.recordLogs();
        vm.prank(artist);
        records.setRecord(tokenId, next, before);
        assertEq(vm.getRecordedLogs()[0].data, abi.encode(next, records.workStateHash(tokenId)));
    }

    function test_setRecord_identicalIsNoOp() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 before = records.workStateHash(tokenId);
        vm.recordLogs();
        vm.prank(artist);
        records.setRecord(tokenId, item.recordFileId, bytes32(0));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(records.workStateHash(tokenId), before);
        assertEq(records.record(tokenId).version, 0);
    }

    function test_setRecord_reverts() public {
        (uint256 tokenId,) = _work(1);
        bytes32 next = _record(77);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.NotWorkArtist.selector, tokenId, outsider)
        );
        records.setRecord(tokenId, next, state);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.StateHashMismatch.selector, bytes32(0), state)
        );
        records.setRecord(tokenId, next, bytes32(0));
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, keccak256("x"))
        );
        records.setRecord(tokenId, keccak256("x"), state);
        vm.prank(artist);
        records.finalize(tokenId, state);
        bytes32 finalState = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.WorkIsFinalized.selector, tokenId));
        records.setRecord(tokenId, next, finalState);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.RecordNotOpen.selector, 99));
        records.setRecord(99, next, state);
    }

    function test_setRecord_followsCurrentAuthority() public {
        (uint256 tokenId,) = _work(1);
        address newKey = makeAddr("newKey");
        artists.setAuthority(uint256(uint160(artist)), newKey);
        bytes32 state = records.workStateHash(tokenId);
        bytes32 next = _record(77);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.NotWorkArtist.selector, tokenId, artist)
        );
        records.setRecord(tokenId, next, state);
        vm.prank(newKey);
        records.setRecord(tokenId, next, state);
        assertEq(records.record(tokenId).recordFileId, next);
    }

    /// @dev Only the store's `ContentFileUnknown` reads as an unknown record file: a failure whose
    ///      selector sorts above it propagates as it is, like `Broken`, which sorts below.
    function test_setRecord_propagatesAStoreFailureSortingAboveUnknownFile() public {
        (uint256 tokenId,) = _work(1);
        bytes32 next = _record(77);
        bytes32 state = records.workStateHash(tokenId);
        bytes memory high = abi.encodePacked(bytes4(0xffffffff));
        vm.mockCallRevert(
            address(store), abi.encodeWithSelector(IContentStore.fileInfo.selector), high
        );
        vm.prank(artist);
        vm.expectRevert(high);
        records.setRecord(tokenId, next, state);
    }

    // -------------------------------------------------------------------------- finalize

    function test_finalize_pinsDefaultRenderer() public {
        (uint256 tokenId,) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        IWorkRecords.RecordInfo memory info = records.record(tokenId);
        assertTrue(info.finalized);
        assertEq(info.renderer, address(renderer));
        assertEq(info.version, 1);
        assertEq(stream.rendererOf(tokenId), address(renderer));

        MockRenderer next = new MockRenderer("next");
        vm.prank(governor);
        stream.setDefaultRenderer(address(renderer), address(next), address(next).codehash);
        assertEq(stream.rendererOf(tokenId), address(renderer));
        assertEq(stream.tokenURI(tokenId), renderer.tokenURI(address(stream), tokenId));
    }

    function test_finalize_emitsWorkFinalized() public {
        (uint256 tokenId,) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        vm.recordLogs();
        vm.prank(artist);
        records.finalize(tokenId, state);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(records)
                    && logs[i].topics[0] == IWorkRecords.WorkFinalized.selector
            ) {
                assertEq(logs[i].topics[1], bytes32(tokenId));
                (address r, bytes32 h) = abi.decode(logs[i].data, (address, bytes32));
                assertEq(r, address(renderer));
                assertEq(h, records.workStateHash(tokenId));
                found = true;
            }
        }
        assertTrue(found, "WorkFinalized");
    }

    function test_finalize_compareAndSetCatchesRendererChange() public {
        (uint256 tokenId,) = _work(1);
        bytes32 signed = records.workStateHash(tokenId);
        MockRenderer next = new MockRenderer("next");
        vm.prank(governor);
        stream.setDefaultRenderer(address(renderer), address(next), address(next).codehash);
        bytes32 actual = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.StateHashMismatch.selector, signed, actual)
        );
        records.finalize(tokenId, signed);
    }

    /// @dev A pending record file is refused when set; once stored, it sets and finalizes.
    ///      Finalize checks the record file again. Stored chunks are permanent, so a store that
    ///      reports the file incomplete is simulated.
    function test_finalize_needsCompleteRecordFile() public {
        (uint256 tokenId,) = _work(1);
        bytes memory json = '{"name":"pending"}';
        bytes32 pending = _file(json, "application/json", false);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, pending));
        records.setRecord(tokenId, pending, state);
        store.writeChunk(json);
        vm.prank(artist);
        records.setRecord(tokenId, pending, state);
        state = records.workStateHash(tokenId);

        vm.mockCall(
            address(store), abi.encodeCall(IContentStore.isComplete, (pending)), abi.encode(false)
        );
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, pending));
        records.finalize(tokenId, state);
        vm.clearMockedCalls();
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertTrue(records.record(tokenId).finalized);
    }

    function test_finalize_reverts() public {
        (uint256 tokenId,) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.NotWorkArtist.selector, tokenId, outsider)
        );
        records.finalize(tokenId, state);
        vm.prank(artist);
        records.finalize(tokenId, state);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.WorkIsFinalized.selector, tokenId));
        records.finalize(tokenId, state);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.RecordNotOpen.selector, 99));
        records.finalize(99, state);
    }

    function _relicense(uint256 tokenId, PackageItem memory item, License memory next) internal {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash = keccak256(
            abi.encode(
                Typehashes.RELICENSE,
                tokenId,
                WorksHashing.licenseKey(next.spdxId),
                next.textFileId,
                state,
                deadline
            )
        );
        bytes[] memory sigs = _both(structHash);
        vm.prank(governor);
        records.relicense(tokenId, next, item, state, deadline, sigs);
    }

    /// @dev An external hop so `vm.expectRevert` sees exactly the relicense call.
    function relicenseAs(uint256 tokenId, PackageItem memory item, License memory next) external {
        _relicense(tokenId, item, next);
    }

    /// Regression: N2 in the reviews of #22
    /// @dev A finalized work's license text is on-chain. A registered but unstored text
    ///      blocks finalize until it is stored, and a finalized work's relicense needs a stored
    ///      text too.
    function test_finalize_andRelicenseNeedAStoredLicenseText() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.license = License("CC-BY-4.0", _registerTextOnly("CC-BY-4.0 legal code"));
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        records.syncOnChain(tokenId);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.finalize(tokenId, state);
        store.writeChunk("CC-BY-4.0 legal code");
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertTrue(records.record(tokenId).finalized);
        assertTrue(records.record(tokenId).onChainComplete);
        assertTrue(store.isComplete(records.licenseOf(tokenId).textFileId));

        License memory next = License("CC-BY-SA-4.0", _registerTextOnly("CC-BY-SA-4.0 code"));
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        this.relicenseAs(tokenId, item, next);
        store.writeChunk("CC-BY-SA-4.0 code");
        _relicense(tokenId, item, next);
        assertTrue(store.isComplete(records.licenseOf(tokenId).textFileId));
    }

    /// @dev Before finalize a license text needs only to be registered: a relicense to a text
    ///      that is not stored yet goes through (found by mutation testing).
    function test_relicense_beforeFinalizeNeedsOnlyARegisteredText() public {
        MediaFile[] memory media = _single(2, true);
        PackageItem memory item = _recordsItem(2, media);
        item.license = License("CC-BY-4.0", _registerTextOnly("CC-BY-4.0 legal code"));
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        License memory next = License("CC-BY-SA-4.0", _registerTextOnly("CC-BY-SA-4.0 code"));
        assertFalse(store.isComplete(next.textFileId));
        _relicense(tokenId, item, next);
        assertEq(records.licenseOf(tokenId).textFileId, next.textFileId);
    }

    /// @dev What the record checks cost, measured cold.
    function test_gas_recordChecks() public {
        (uint256 tokenId, PackageItem memory item, MediaFile[] memory media) = _minted(1, true);
        vm.cool(address(store));
        vm.cool(address(records));
        uint256 before = gasleft();
        records.openRecord(tokenId, item, media);
        console2.log("openRecord, 1 file, cold:", before - gasleft());
        bytes32 next = _record(2);
        bytes32 state = records.workStateHash(tokenId);
        vm.cool(address(store));
        vm.prank(artist);
        before = gasleft();
        records.setRecord(tokenId, next, state);
        console2.log("setRecord, cold store:", before - gasleft());
        state = records.workStateHash(tokenId);
        vm.cool(address(store));
        vm.prank(artist);
        before = gasleft();
        records.finalize(tokenId, state);
        console2.log("finalize, cold store:", before - gasleft());
    }

    // ------------------------------------------------------------------------ syncOnChain

    function test_syncOnChain() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, false);
        media[1] = _mediaFile(2, FileRole.AUXILIARY, false);
        PackageItem memory item = _recordsItem(1, media);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        bytes32 state = records.workStateHash(tokenId);

        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId));
        records.syncOnChain(tokenId);
        _upload(1);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId));
        records.syncOnChain(tokenId);
        _upload(2);
        vm.expectEmit(address(records));
        emit IWorkRecords.WorkOnChainComplete(tokenId);
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(outsider);
        records.syncOnChain(tokenId);
        assertTrue(records.record(tokenId).onChainComplete);
        assertEq(records.workStateHash(tokenId), state);

        vm.recordLogs();
        records.syncOnChain(tokenId);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// Regression: the reviews of #22
    /// @dev On-chain completeness needs every media file; until then ONCHAIN never resolves.
    function test_syncOnChain_needsEveryFile() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PREVIEW, false);
        PackageItem memory item = _recordsItem(1, media);
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId));
        records.syncOnChain(tokenId);
        (Locator memory loc, uint256 index) = records.preferredLocator(tokenId, media[0].fileId);
        assertEq(uint8(loc.kind), uint8(LocatorKind.NONE));
        assertEq(index, type(uint256).max);
        _upload(2);
        records.syncOnChain(tokenId);
        (loc,) = records.preferredLocator(tokenId, media[1].fileId);
        assertEq(uint8(loc.kind), uint8(LocatorKind.ONCHAIN));
    }

    // --------------------------------------------------------------------------- relicense

    function _relicenseHash(uint256 tokenId, License memory next, bytes32 state, uint64 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                Typehashes.RELICENSE,
                tokenId,
                WorksHashing.licenseKey(next.spdxId),
                next.textFileId,
                state,
                deadline
            )
        );
    }

    function _byWork() internal returns (uint256 tokenId, PackageItem memory item) {
        MediaFile[] memory media = _single(1, true);
        item = _recordsItem(1, media);
        item.license = _license("cc-by-4.0");
        tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
    }

    function test_relicense_withEveryConsent() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        License memory next = _license("cc0-1.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes[] memory sigs = _both(_relicenseHash(tokenId, next, state, deadline));

        vm.expectEmit(address(records));
        emit IWorkRecords.LicenseChanged(tokenId, _license("cc-by-4.0"), next);
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(governor);
        records.relicense(tokenId, next, item, state, deadline, sigs);
        assertEq(abi.encode(records.licenseOf(tokenId)), abi.encode(next));
        assertEq(records.record(tokenId).licenseKey, WorksHashing.CC0_LICENSE_KEY);
        assertEq(records.record(tokenId).version, 1);

        // CC0 is now irrevocable. (Replay of consents is tested between non-CC0 licenses.)
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.LicenseIrrevocable.selector, tokenId));
        records.relicense(tokenId, _license("mit"), item, state, deadline, sigs);
    }

    function test_relicense_betweenNonCc0Licenses() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        License memory next = _license("cc-by-sa-4.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes[] memory sigs = _both(_relicenseHash(tokenId, next, state, deadline));
        vm.prank(governor);
        records.relicense(tokenId, next, item, state, deadline, sigs);
        assertEq(records.licenseOf(tokenId).spdxId, "cc-by-sa-4.0");
        bytes32 current = records.workStateHash(tokenId);
        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.StateHashMismatch.selector, state, current)
        );
        records.relicense(tokenId, _license("cc-by-4.0"), item, state, deadline, sigs);
    }

    function test_relicense_cc0IsIrrevocableInAnyCase() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        // Another spelling of the identifier: stored as given, and CC0 by its key.
        item.license = License("CC0-1.0", records.cc0TextFileId());
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertEq(records.licenseOf(tokenId).spdxId, "CC0-1.0");
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.LicenseIrrevocable.selector, tokenId));
        records.relicense(tokenId, _license("mit"), item, bytes32(0), 0, new bytes[](0));
    }

    /// @dev A CC0 license names the deployment's CC0 text: `openRecord` refuses an approved one
    ///      with another text, and a relicense to CC0 with another text is refused before the
    ///      consents are checked.
    function test_relicense_cc0TextOnlyToTheDeploymentText() public {
        MediaFile[] memory media = _single(2, true);
        PackageItem memory item = _recordsItem(2, media);
        item.license = License("cc0-1.0", _registerText("cc0 text with a typo"));
        uint256 tokenId = _mint(item);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.openRecord(tokenId, item, media);

        (uint256 byWork, PackageItem memory byItem) = _byWork();
        License memory other = License("CC0-1.0", _registerText("other terms"));
        vm.prank(governor);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.relicense(byWork, other, byItem, bytes32(0), 0, new bytes[](0));
    }

    function test_relicense_identicalIsNoOp() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        vm.recordLogs();
        vm.prank(governor);
        records.relicense(tokenId, _license("cc-by-4.0"), item, bytes32(0), 0, new bytes[](0));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_relicense_rejectsInvalidNext() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        bytes32 unknown = keccak256("unregistered text");
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown));
        records.relicense(tokenId, License("mit", unknown), item, bytes32(0), 0, new bytes[](0));
        vm.startPrank(governor);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.relicense(tokenId, _license(""), item, bytes32(0), 0, new bytes[](0));
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.relicense(
            tokenId, _license(string(new bytes(65))), item, bytes32(0), 0, new bytes[](0)
        );
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.relicense(tokenId, _license("MIT License"), item, bytes32(0), 0, new bytes[](0));
        vm.stopPrank();
    }

    function test_relicense_rejectsMissingOrBadConsent() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        License memory next = _license("cc0-1.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash = _relicenseHash(tokenId, next, state, deadline);

        bytes[] memory onlyArtist = new bytes[](1);
        onlyArtist[0] = _sign(artistKey, structHash);
        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, 1));
        records.relicense(tokenId, next, item, state, deadline, onlyArtist);

        bytes[] memory forged = _both(structHash);
        forged[1] = _sign(0xBAD, structHash);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, 1));
        records.relicense(tokenId, next, item, state, deadline, forged);

        bytes[] memory otherPayload =
            _both(_relicenseHash(tokenId, _license("mit"), state, deadline));
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, 0));
        records.relicense(tokenId, next, item, state, deadline, otherPayload);

        PackageItem memory other = _item(9);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRecordData.selector, tokenId));
        records.relicense(tokenId, next, other, state, deadline, _both(structHash));
        vm.stopPrank();

        vm.warp(deadline + 1);
        bytes[] memory late = _both(structHash);
        vm.prank(governor);
        vm.expectRevert(SignatureReverts.expired(deadline));
        records.relicense(tokenId, next, item, state, deadline, late);
    }

    function test_relicense_needsGovernance() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        records.relicense(tokenId, _license("cc0-1.0"), item, bytes32(0), 0, new bytes[](0));
    }

    function test_relicense_consentFollowsCurrentAuthority() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        uint256 newKey = 0xC0FFEE;
        artists.setAuthority(uint256(uint160(collaborator)), vm.addr(newKey));
        License memory next = _license("cc0-1.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash = _relicenseHash(tokenId, next, state, deadline);
        bytes[] memory sigs = _both(structHash);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, 1));
        records.relicense(tokenId, next, item, state, deadline, sigs);
        sigs[1] = _sign(newKey, structHash);
        vm.prank(governor);
        records.relicense(tokenId, next, item, state, deadline, sigs);
        assertEq(records.licenseOf(tokenId).spdxId, "cc0-1.0");
    }

    /// @dev A party named by an account its artist rotated to consents under the artist's ID
    ///      (the first authority's address, which `artistIdOf` maps it to), not as an
    ///      unregistered account under its own address (found by mutation testing).
    function test_relicense_consentOfAPartyNamedByALaterAuthority() public {
        uint256 newKey = 0xC0FFEE;
        address rotated = vm.addr(newKey);
        artists.setAuthority(uint256(uint160(collaborator)), rotated);
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.license = _license("cc-by-4.0");
        item.parties[1].account = rotated;
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);

        License memory next = _license("cc0-1.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash = _relicenseHash(tokenId, next, state, deadline);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(artistKey, structHash);
        sigs[1] = _sign(newKey, structHash);
        vm.prank(governor);
        records.relicense(tokenId, next, item, state, deadline, sigs);
        assertEq(records.licenseOf(tokenId).spdxId, "cc0-1.0");
    }

    /// @dev Consents are checked against the work's own item: another item is refused whichever
    ///      way its hash sorts against the minted one's, even with every party's consent (found
    ///      by mutation testing).
    function test_relicense_refusesAnotherItemEitherWay() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        bytes32 minted = WorksHashing.itemHash(item);
        License memory next = _license("cc0-1.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes[] memory sigs = _both(_relicenseHash(tokenId, next, state, deadline));
        bool below;
        bool above;
        vm.startPrank(governor);
        for (uint256 i = 1; !(below && above); ++i) {
            item.recordFileId = keccak256(abi.encode("another record", i));
            bool lower = WorksHashing.itemHash(item) < minted;
            if (lower ? below : above) continue;
            if (lower) below = true;
            else above = true;
            vm.expectRevert(
                abi.encodeWithSelector(IWorkRecords.InvalidRecordData.selector, tokenId)
            );
            records.relicense(tokenId, next, item, state, deadline, sigs);
        }
        vm.stopPrank();
    }

    function test_relicense_acceptsCompactSignatures() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        License memory next = _license("cc0-1.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = _digest(_relicenseHash(tokenId, next, state, deadline));
        bytes[] memory sigs = new bytes[](2);
        (bytes32 r, bytes32 vs) = vm.signCompact(artistKey, digest);
        sigs[0] = abi.encodePacked(r, vs);
        (r, vs) = vm.signCompact(collaboratorKey, digest);
        sigs[1] = abi.encodePacked(r, vs);
        vm.prank(governor);
        records.relicense(tokenId, next, item, state, deadline, sigs);
        assertEq(records.licenseOf(tokenId).spdxId, "cc0-1.0");
    }

    /// @dev Leaving CC0 is refused whichever way the next license's key sorts against CC0's:
    ///      "mit" sorts below it, "unlicense" above.
    function test_relicense_leavingCc0IsRefusedEitherWay() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.license = License("cc0-1.0", records.cc0TextFileId());
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        string[2] memory nexts = ["mit", "unlicense"];
        for (uint256 i; i < nexts.length; ++i) {
            vm.prank(governor);
            vm.expectRevert(
                abi.encodeWithSelector(IWorkRecords.LicenseIrrevocable.selector, tokenId)
            );
            records.relicense(tokenId, _license(nexts[i]), item, bytes32(0), 0, new bytes[](0));
        }
    }

    /// @dev A license whose key sorts above CC0's is not CC0: the work can leave it.
    function test_relicense_leavesALicenseKeyedAboveCc0() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.license = _license("unlicense");
        assertGt(
            uint256(WorksHashing.licenseKey("unlicense")), uint256(WorksHashing.CC0_LICENSE_KEY)
        );
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        _relicenseTo(tokenId, item, _license("mit"));
        assertEq(records.licenseOf(tokenId).spdxId, "mit");
    }

    /// @dev Another identifier with the same text is a change, not a no-op, whichever way its key
    ///      sorts: "gpl-3.0-only" sorts below "cc-by-4.0", and "mit" above both.
    function test_relicense_anotherIdentifierWithTheSameTextEitherWay() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        bytes32 text = records.licenseOf(tokenId).textFileId;
        string[2] memory nexts = ["gpl-3.0-only", "mit"];
        for (uint256 i; i < nexts.length; ++i) {
            _relicenseTo(tokenId, item, License(nexts[i], text));
            assertEq(records.licenseOf(tokenId).spdxId, nexts[i]);
            assertEq(records.record(tokenId).version, i + 1);
        }
    }

    function _relicenseTo(uint256 tokenId, PackageItem memory item, License memory next) internal {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes[] memory sigs = _both(_relicenseHash(tokenId, next, state, deadline));
        vm.prank(governor);
        records.relicense(tokenId, next, item, state, deadline, sigs);
    }

    /// @dev One signature per party: an extra one is refused, not ignored.
    function test_relicense_refusesAnExtraSignature() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        License memory next = _license("mit");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes[] memory both = _both(_relicenseHash(tokenId, next, state, deadline));
        bytes[] memory three = new bytes[](3);
        (three[0], three[1], three[2]) = (both[0], both[1], both[1]);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, 3));
        records.relicense(tokenId, next, item, state, deadline, three);
    }

    // ------------------------------------------------------------------------ royalty rate

    function test_setRoyaltyRate_withEveryConsent() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 15 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 10_000, state, deadline));
        vm.expectEmit(address(stream));
        emit IStream.RoyaltyRateChanged(tokenId, 6_529, 10_000);
        // The new state hash: version 1 at the new rate.
        vm.expectEmit(true, false, false, false, address(records));
        emit IWorkRecords.RoyaltyRateSet(tokenId, 6_529, 10_000, bytes32(0));
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.recordLogs();
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 10_000, item, state, deadline, sigs);
        (address receiver, uint256 amount) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, _royaltyWallet(_sellerOf(item.payees), feeRecipient, 25_000));
        assertEq(amount, 0.1 ether);
        assertEq(records.record(tokenId).version, 1);
        bytes32 next = records.workStateHash(tokenId);
        assertTrue(next != state);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IWorkRecords.RoyaltyRateSet.selector) {
                (,, bytes32 reported) = abi.decode(logs[i].data, (uint32, uint32, bytes32));
                assertEq(reported, next);
                found = true;
            }
        }
        assertTrue(found);
    }

    function test_setRoyaltyRate_reverts() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 100_001, state, deadline));
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IStream.InvalidRoyaltyRate.selector, 100_001));
        records.setRoyaltyRate(tokenId, 100_001, item, state, deadline, sigs);
        sigs = _both(_royaltyHash(tokenId, 1, state, deadline));
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, 0));
        records.setRoyaltyRate(tokenId, 2, item, state, deadline, sigs);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        records.setRoyaltyRate(tokenId, 1, item, state, deadline, sigs);
    }

    function test_setRoyaltyRate_identicalIsNoOp() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        vm.recordLogs();
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 6_529, item, bytes32(0), 0, new bytes[](0));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_setRoyaltyRate_followsToLinkedEdition() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.kind = ItemKind.EDITION_MASTER;
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        auction.settle(stream, tokenId);
        editionsMock.link(stream, tokenId, tokenId);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 15 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 8_000, state, deadline));
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 8_000, item, state, deadline, sigs);
        assertEq(stream.work(tokenId).royaltyRate, 8_000);
        assertEq(editionsMock.rateOf(tokenId), 8_000);
    }

    /// Regression: M4 in the reviews of #22
    /// @dev A rate round trip A -> B -> A does not let the first consents replay; the
    ///      version moved, so the state hash they bind is gone.
    function test_setRoyaltyRate_aRoundTripDoesNotReplayConsents() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 s0 = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes[] memory toB = _both(_royaltyHash(tokenId, 10_000, s0, deadline));
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 10_000, item, s0, deadline, toB);
        bytes32 s1 = records.workStateHash(tokenId);
        bytes[] memory toA = _both(_royaltyHash(tokenId, 6_529, s1, deadline));
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 6_529, item, s1, deadline, toA);
        bytes32 s2 = records.workStateHash(tokenId);
        assertTrue(s2 != s0);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.StateHashMismatch.selector, s0, s2));
        records.setRoyaltyRate(tokenId, 10_000, item, s0, deadline, toB);
        assertEq(stream.work(tokenId).royaltyRate, 6_529);
    }

    // ------------------------------------------------------------------------------ seeds

    function test_seedOf_byPolicy() public {
        (uint256 none, PackageItem memory noneItem) = _work(1);
        // A work without a seed policy never asks the entropy module, even if it has a seed.
        entropy.deliver(WorksHashing.itemHash(noneItem), keccak256("not asked"));
        (SeedPolicy policy, bytes32 seed) = records.seedOf(none);
        assertEq(uint8(policy), uint8(SeedPolicy.NONE));
        assertEq(seed, bytes32(0));

        MediaFile[] memory media = _single(2, true);
        PackageItem memory item = _recordsItem(2, media);
        item.seedPolicy = SeedPolicy.ARTIST;
        item.seed = keccak256("artist seed");
        uint256 seeded = _mint(item);
        records.openRecord(seeded, item, media);
        (policy, seed) = records.seedOf(seeded);
        assertEq(uint8(policy), uint8(SeedPolicy.ARTIST));
        assertEq(seed, keccak256("artist seed"));

        media = _single(3, true);
        item = _recordsItem(3, media);
        item.seedPolicy = SeedPolicy.VRF;
        bytes32 itemHash = WorksHashing.itemHash(item);
        entropy.deliver(itemHash, keccak256("vrf seed"));
        uint256 vrf = _mint(item);
        records.openRecord(vrf, item, media);
        (policy, seed) = records.seedOf(vrf);
        assertEq(uint8(policy), uint8(SeedPolicy.VRF));
        assertEq(seed, keccak256("vrf seed"));
    }

    // ------------------------------------------------------------------------------ repin

    function _repinHash(uint256 tokenId, address r, bytes32 state, uint64 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(Typehashes.RENDERER_REPIN, tokenId, r, r.codehash, state, deadline)
        );
    }

    function _finalized(uint256 salt) internal returns (uint256 tokenId) {
        (tokenId,) = _work(salt);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
    }

    function test_repinRenderer_errataPath() public {
        uint256 tokenId = _finalized(1);
        MockRenderer next = new MockRenderer("errata");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 31 days);
        bytes memory sig = _sign(artistKey, _repinHash(tokenId, address(next), state, deadline));
        vm.expectEmit(address(records));
        emit IWorkRecords.RendererRepinned(
            tokenId, address(renderer), address(next), address(next).codehash
        );
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(governor);
        records.repinRenderer(tokenId, address(next), address(next).codehash, state, deadline, sig);
        assertEq(stream.rendererOf(tokenId), address(next));
        assertEq(records.record(tokenId).version, 2);
    }

    function test_repinRenderer_reverts() public {
        (uint256 open,) = _work(9);
        MockRenderer next = new MockRenderer("errata");
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.WorkNotFinalized.selector, open));
        records.repinRenderer(open, address(next), bytes32(0), bytes32(0), deadline, "");

        uint256 tokenId = _finalized(1);
        bytes32 state = records.workStateHash(tokenId);
        address eoa = makeAddr("eoa");
        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        records.repinRenderer(tokenId, eoa, bytes32(0), state, deadline, "");
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(next))
        );
        records.repinRenderer(tokenId, address(next), keccak256("wrong"), state, deadline, "");
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(store))
        );
        records.repinRenderer(tokenId, address(store), address(store).codehash, state, deadline, "");
        bytes memory wrong =
            _sign(collaboratorKey, _repinHash(tokenId, address(next), state, deadline));
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, 0));
        records.repinRenderer(
            tokenId, address(next), address(next).codehash, state, deadline, wrong
        );
        vm.stopPrank();

        bytes memory sig = _sign(artistKey, _repinHash(tokenId, address(next), state, deadline));
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        records.repinRenderer(tokenId, address(next), address(next).codehash, state, deadline, sig);
        vm.warp(deadline + 1);
        vm.prank(governor);
        vm.expectRevert(SignatureReverts.expired(deadline));
        records.repinRenderer(tokenId, address(next), address(next).codehash, state, deadline, sig);
    }

    function test_repinRenderer_samePinIsNoOp() public {
        uint256 tokenId = _finalized(1);
        vm.recordLogs();
        vm.prank(governor);
        records.repinRenderer(tokenId, address(renderer), bytes32(0), bytes32(0), 0, "");
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// @dev A pinned renderer whose code moved is refused, whichever way its new code hash sorts
    ///      against the pin.
    function test_pinnedRenderer_refusesMovedCodeEitherWay() public {
        uint256 tokenId = _finalized(1);
        address pinned = records.pinnedRenderer(tokenId);
        bytes memory code = pinned.code;
        bytes32 pin = pinned.codehash;
        bool below;
        bool above;
        for (uint8 i = 1; !(below && above); ++i) {
            bytes memory moved = abi.encodePacked(code, i);
            bool lower = keccak256(moved) < pin;
            if (lower ? below : above) continue;
            if (lower) below = true;
            else above = true;
            vm.etch(pinned, moved);
            vm.expectRevert(
                abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, pinned)
            );
            records.pinnedRenderer(tokenId);
        }
    }

    /// @dev A repin names the renderer's code hash exactly (a wrong one sorting below or above
    ///      is refused), and consents are good through their deadline second.
    function test_repinRenderer_refusesAWrongHashEitherWayAndKeepsTheDeadlineSecond() public {
        uint256 tokenId = _finalized(1);
        MockRenderer next = new MockRenderer("errata");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32[2] memory wrong = [bytes32(0), bytes32(type(uint256).max)];
        vm.startPrank(governor);
        for (uint256 i; i < wrong.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(next))
            );
            records.repinRenderer(tokenId, address(next), wrong[i], state, deadline, "");
        }
        vm.stopPrank();
        bytes memory sig = _sign(artistKey, _repinHash(tokenId, address(next), state, deadline));
        vm.warp(deadline);
        vm.prank(governor);
        records.repinRenderer(tokenId, address(next), address(next).codehash, state, deadline, sig);
        assertEq(stream.rendererOf(tokenId), address(next));
    }

    /// @dev A renderer keeps the code hash it was first pinned with: once its code moved, a
    ///      repin to it is refused whichever way the new hash sorts against that first pin
    ///      (found by mutation testing).
    function test_repinRenderer_refusesARendererWhoseCodeMovedSinceItsPinEitherWay() public {
        uint256 first = _finalized(1);
        MockRenderer next = new MockRenderer("errata");
        bytes32 state = records.workStateHash(first);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(artistKey, _repinHash(first, address(next), state, deadline));
        vm.prank(governor);
        records.repinRenderer(first, address(next), address(next).codehash, state, deadline, sig);

        uint256 tokenId = _finalized(2);
        state = records.workStateHash(tokenId);
        bytes memory code = address(next).code;
        bytes32 pin = address(next).codehash;
        bool below;
        bool above;
        for (uint8 i = 1; !(below && above); ++i) {
            bytes memory moved = abi.encodePacked(code, i);
            bool lower = keccak256(moved) < pin;
            if (lower ? below : above) continue;
            if (lower) below = true;
            else above = true;
            vm.etch(address(next), moved);
            sig = _sign(artistKey, _repinHash(tokenId, address(next), state, deadline));
            vm.prank(governor);
            vm.expectRevert(
                abi.encodeWithSelector(Dependency.DependencyCodeChanged.selector, address(next))
            );
            records.repinRenderer(tokenId, address(next), keccak256(moved), state, deadline, sig);
        }
    }

    // -------------------------------------------------------------------- edition masters

    function test_editionMaster_notifiesEditions() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.kind = ItemKind.EDITION_MASTER;
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertEq(editionsMock.notified(tokenId), 0);
        auction.settle(stream, tokenId);
        editionsMock.link(stream, tokenId, tokenId);
        vm.prank(platform);
        records.addLocator(tokenId, media[0].fileId, _ar("tx"));
        assertEq(editionsMock.notified(tokenId), 1);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        assertEq(editionsMock.notified(tokenId), 2);
    }

    // --------------------------------------------------------------------------- locators

    /// @dev A well-formed locator derived from `id` (`ContentAddresses`).
    function _ar(string memory id) internal pure returns (Locator memory) {
        return CA.ar(id);
    }

    function _ipfs(string memory id) internal pure returns (Locator memory) {
        return CA.ipfsLocator(id);
    }

    function _primary(uint256 tokenId) internal view returns (bytes32) {
        return records.mediaOf(tokenId)[0].fileId;
    }

    function test_addLocator_byArtistAndPlatform() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        bytes32 state = records.workStateHash(tokenId);
        vm.expectEmit(address(records));
        emit IWorkRecords.LocatorAdded(tokenId, file, 0, _ar("tx1"));
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(artist);
        records.addLocator(tokenId, file, _ar("tx1"));
        vm.prank(platform);
        records.addLocator(tokenId, file, _ipfs("bafy1"));
        Locator[] memory list = records.locators(tokenId, file);
        assertEq(list.length, 2);
        assertEq(list[1].uri, CA.ipfs("bafy1"));
        assertEq(records.workStateHash(tokenId), state);

        vm.prank(artist);
        records.finalize(tokenId, state);
        vm.prank(platform);
        records.addLocator(tokenId, file, _ar("tx2"));
        assertEq(records.locators(tokenId, file).length, 3);
        // After finalize only the PLATFORM role adds locators.
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        records.addLocator(tokenId, file, _ar("tx3"));
    }

    function test_addLocator_reverts() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        records.addLocator(tokenId, file, _ar("tx"));

        vm.startPrank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.FileNotInWork.selector, tokenId, keccak256("x"))
        );
        records.addLocator(tokenId, keccak256("x"), _ar("tx"));
        string memory txid = CA.arweave("tx");
        string memory cid = CA.ipfs("cid");
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ONCHAIN, txid));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.NONE, txid));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, cid));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, txid));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, "ipfs://"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, "ipfs:/"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, "https://example.com"));
        // One byte changed, in each position class: the scheme, the profile prefix, the
        // address, and a byte added or removed at the end.
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, _with(txid, 2, "/")));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, _with(txid, 5, "=")));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, _with(txid, 47, "+")));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, string.concat(txid, "A")));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, _with(cid, 9, "y")));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, _with(cid, 14, "1")));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, _with(cid, 65, "A")));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, string.concat(cid, "a")));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, unicode"ipfs://é"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, _with(cid, 30, hex"ff")));
        records.addLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, txid));
        records.addLocator(tokenId, file, Locator(LocatorKind.IPFS, cid));
        records.addLocator(tokenId, file, Locator(LocatorKind.IPFS, CA.ipfsRoot("cid")));
        vm.stopPrank();
    }

    /// @dev `s` with byte `i` replaced by `b`.
    function _with(string memory s, uint256 i, bytes1 b) internal pure returns (string memory) {
        bytes memory out = bytes(string.concat(s));
        out[i] = b;
        return string(out);
    }

    /// @dev The artist and the platform each add at most 8 locators per file, so neither can
    ///      fill the file's 16 slots and lock the other out.
    function test_addLocator_separateQuotas() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        vm.startPrank(platform);
        for (uint256 i; i < 8; ++i) {
            records.addLocator(tokenId, file, _ar(string.concat("p", vm.toString(i))));
        }
        _expectBadLocator(tokenId, file, _ar("p8"));
        vm.stopPrank();
        vm.startPrank(artist);
        for (uint256 i; i < 8; ++i) {
            records.addLocator(tokenId, file, _ipfs(string.concat("a", vm.toString(i))));
        }
        _expectBadLocator(tokenId, file, _ipfs("a8"));
        vm.stopPrank();
        assertEq(records.locators(tokenId, file).length, 16);
        // Quotas are per file: the work's other files are unaffected.
        (uint256 other,) = _work(2);
        bytes32 otherFile = _primary(other);
        vm.prank(platform);
        records.addLocator(other, otherFile, _ar("p0"));
    }

    /// @dev After finalize the artist adds no locators, so the platform may fill the file's 16
    ///      slots, the artist's unused ones included, and no more.
    function test_addLocator_platformTakesTheArtistsUnusedSlotsAfterFinalize() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        vm.startPrank(artist);
        for (uint256 i; i < 3; ++i) {
            records.addLocator(tokenId, file, _ipfs(string.concat("a", vm.toString(i))));
        }
        vm.stopPrank();
        vm.startPrank(platform);
        for (uint256 i; i < 8; ++i) {
            records.addLocator(tokenId, file, _ar(string.concat("p", vm.toString(i))));
        }
        _expectBadLocator(tokenId, file, _ar("p8"));
        vm.stopPrank();
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        vm.startPrank(platform);
        for (uint256 i = 8; i < 13; ++i) {
            records.addLocator(tokenId, file, _ar(string.concat("p", vm.toString(i))));
        }
        assertEq(records.locators(tokenId, file).length, Limits.MAX_LOCATORS_PER_FILE);
        _expectBadLocator(tokenId, file, _ar("p13"));
        vm.stopPrank();
    }

    /// @dev A URI already registered for the file is refused, whoever adds it again.
    function test_addLocator_rejectsDuplicateUri() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        vm.prank(artist);
        records.addLocator(tokenId, file, _ar("tx"));
        vm.prank(artist);
        _expectBadLocator(tokenId, file, _ar("tx"));
        vm.prank(platform);
        _expectBadLocator(tokenId, file, _ar("tx"));
        vm.prank(platform);
        records.addLocator(tokenId, file, _ar("tx2"));
        assertEq(records.locators(tokenId, file).length, 2);
    }

    /// Regression: the reviews of #22
    /// @dev The artist's and the platform's quotas are independent; the duplicate set is shared, so either side
    ///      may add a URI first (it is still listed); duplicates compare exact bytes.
    function test_addLocator_separateQuotasShareOneDuplicateSet() public {
        (uint256 tokenId,) = _work(1);
        bytes32 fileId = records.mediaOf(tokenId)[0].fileId;
        for (uint256 i; i < 8; ++i) {
            vm.prank(artist);
            records.addLocator(tokenId, fileId, _ipfs(vm.toString(i)));
        }
        vm.prank(artist);
        vm.expectRevert(IWorkRecords.InvalidLocator.selector);
        records.addLocator(tokenId, fileId, _ipfs("artist-9"));
        vm.prank(platform);
        records.addLocator(tokenId, fileId, _ipfs("p0"));
        vm.prank(platform);
        vm.expectRevert(IWorkRecords.InvalidLocator.selector);
        records.addLocator(tokenId, fileId, _ipfs("0"));
        // The same CID as a dag-pb root is another spelling, so another URI.
        vm.prank(platform);
        records.addLocator(tokenId, fileId, Locator(LocatorKind.IPFS, CA.ipfsRoot("0")));
        assertEq(records.locators(tokenId, fileId).length, 10);
    }

    /// @dev A NUL byte is in no character set: not inside an ID, not as its last character.
    function test_addLocator_rejectsANulCharacter() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        Locator[2] memory good = [_ar("nul"), _ipfs("nul")];
        for (uint256 i; i < 2; ++i) {
            bytes memory uri = bytes(good[i].uri);
            bytes memory inside = bytes.concat(uri);
            inside[uri.length - 2] = 0x00;
            bytes memory last = bytes.concat(uri);
            last[uri.length - 1] = 0x00;
            vm.prank(artist);
            _expectBadLocator(tokenId, file, Locator(good[i].kind, string(inside)));
            vm.prank(artist);
            _expectBadLocator(tokenId, file, Locator(good[i].kind, string(last)));
        }
        vm.prank(artist);
        records.addLocator(tokenId, file, good[0]);
    }

    function _expectBadLocator(uint256 tokenId, bytes32 file, Locator memory locator) internal {
        vm.expectRevert(IWorkRecords.InvalidLocator.selector);
        records.addLocator(tokenId, file, locator);
    }

    function test_preferredLocator_mostSpecificWins() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        vm.startPrank(platform);
        records.addLocator(tokenId, file, _ar("a0"));
        records.addLocator(tokenId, file, _ipfs("i1"));
        records.addLocator(tokenId, file, _ar("a2"));
        vm.stopPrank();

        _expectPreferred(tokenId, file, 0, CA.arweave("a0"));
        vm.startPrank(storageOperator);
        records.setPreferredKind(LocatorKind.IPFS);
        _expectPreferred(tokenId, file, 1, CA.ipfs("i1"));
        records.setCollectionPreferredKind(collectionId, LocatorKind.ARWEAVE);
        _expectPreferred(tokenId, file, 0, CA.arweave("a0"));
        records.setFilePreference(tokenId, file, 2);
        assertEq(records.filePreference(tokenId, file), 2);
        _expectPreferred(tokenId, file, 2, CA.arweave("a2"));
        records.setCollectionPreferredKind(collectionId, LocatorKind.ONCHAIN);
        _expectPreferred(tokenId, file, 2, CA.arweave("a2"));
        records.setFilePreference(tokenId, file, NONE);
        // The media is stored but the work is not synced, so ONCHAIN falls through to IPFS.
        _expectPreferred(tokenId, file, 1, CA.ipfs("i1"));
        vm.stopPrank();
        records.syncOnChain(tokenId);
        (Locator memory chosen, uint256 index) = records.preferredLocator(tokenId, file);
        assertEq(index, NONE);
        assertEq(uint8(chosen.kind), uint8(LocatorKind.ONCHAIN));
    }

    /// @dev ONCHAIN matches only the stored `onChainComplete` flag: uploading the media is not
    ///      enough until `syncOnChain` runs, and resolution never scans the content store.
    function test_preferredLocator_onchainOnlyWhenSynced() public {
        (uint256 tokenId, PackageItem memory item, MediaFile[] memory media) = _minted(1, false);
        records.openRecord(tokenId, item, media);
        bytes32 file = media[0].fileId;
        _expectNoLocator(tokenId, file);
        vm.prank(storageOperator);
        records.setPreferredKind(LocatorKind.ONCHAIN);
        vm.prank(platform);
        records.addLocator(tokenId, file, _ipfs("i0"));
        _expectPreferred(tokenId, file, 0, CA.ipfs("i0"));
        _upload(1);
        _expectPreferred(tokenId, file, 0, CA.ipfs("i0"));
        records.syncOnChain(tokenId);
        vm.expectCall(address(store), abi.encodeWithSelector(IContentStore.isComplete.selector), 0);
        (Locator memory chosen, uint256 index) = records.preferredLocator(tokenId, file);
        assertEq(index, NONE);
        assertEq(uint8(chosen.kind), uint8(LocatorKind.ONCHAIN));
        assertEq(bytes(chosen.uri).length, 0);
    }

    function _expectNoLocator(uint256 tokenId, bytes32 file) internal view {
        (Locator memory chosen, uint256 index) = records.preferredLocator(tokenId, file);
        assertEq(index, NONE);
        assertEq(uint8(chosen.kind), uint8(LocatorKind.NONE));
        assertEq(bytes(chosen.uri).length, 0);
    }

    function test_preferredLocator_implicitOnchainFallback() public {
        (uint256 tokenId,) = _work(1);
        _expectNoLocator(tokenId, _primary(tokenId));
        records.syncOnChain(tokenId);
        (Locator memory chosen, uint256 index) =
            records.preferredLocator(tokenId, _primary(tokenId));
        assertEq(index, NONE);
        assertEq(uint8(chosen.kind), uint8(LocatorKind.ONCHAIN));
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.FileNotInWork.selector, tokenId, keccak256("x"))
        );
        records.preferredLocator(tokenId, keccak256("x"));
    }

    function _expectPreferred(uint256 tokenId, bytes32 file, uint256 index, string memory uri)
        internal
        view
    {
        (Locator memory chosen, uint256 got) = records.preferredLocator(tokenId, file);
        assertEq(got, index);
        assertEq(chosen.uri, uri);
    }

    /// @dev Every preference setter is governed: an outsider sets none of them.
    function test_preferenceSetters_needTheStorageOperator() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        bytes memory refused =
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider);
        vm.startPrank(outsider);
        vm.expectRevert(refused);
        records.setPreferredKind(LocatorKind.IPFS);
        vm.expectRevert(refused);
        records.setCollectionPreferredKind(collectionId, LocatorKind.IPFS);
        vm.expectRevert(refused);
        records.setFilePreference(tokenId, file, NONE);
        vm.stopPrank();
    }

    /// @dev With nothing minted there is nothing to refresh: no `BatchMetadataUpdate(1, 0)`.
    function test_preferenceSetters_refreshNothingBeforeAMint() public {
        assertEq(stream.totalMinted(), 0);
        vm.recordLogs();
        vm.prank(storageOperator);
        records.setPreferredKind(LocatorKind.ARWEAVE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(stream), "the core emitted a refresh");
        }
    }

    function test_preferenceSetters_eventsAndRefresh() public {
        (uint256 tokenId,) = _work(1);
        _minted(2, true);
        bytes32 file = _primary(tokenId);
        vm.startPrank(storageOperator);
        vm.expectEmit(address(records));
        emit IWorkRecords.PreferredKindSet(LocatorKind.NONE, LocatorKind.ARWEAVE);
        vm.expectEmit(address(stream));
        emit BatchMetadataUpdate(1, 2);
        records.setPreferredKind(LocatorKind.ARWEAVE);
        assertEq(uint8(records.preferredKind()), uint8(LocatorKind.ARWEAVE));

        vm.expectEmit(address(records));
        emit IWorkRecords.CollectionPreferredKindSet(
            collectionId, LocatorKind.NONE, LocatorKind.IPFS
        );
        vm.expectEmit(address(stream));
        emit BatchMetadataUpdate(1, 2);
        records.setCollectionPreferredKind(collectionId, LocatorKind.IPFS);
        assertEq(uint8(records.collectionPreferredKind(collectionId)), uint8(LocatorKind.IPFS));
        vm.stopPrank();

        vm.prank(platform);
        records.addLocator(tokenId, file, _ar("a0"));
        vm.expectEmit(address(records));
        emit IWorkRecords.FilePreferenceSet(tokenId, file, NONE, 0);
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(storageOperator);
        records.setFilePreference(tokenId, file, 0);
        assertEq(records.filePreference(tokenId, file), 0);
    }

    function test_preferenceSetters_notifyAllEditions() public {
        _work(1);
        vm.startPrank(storageOperator);
        records.setPreferredKind(LocatorKind.IPFS);
        assertEq(editionsMock.notifiedAll(), 1);
        records.setCollectionPreferredKind(collectionId, LocatorKind.ARWEAVE);
        assertEq(editionsMock.notifiedAll(), 2);
        vm.stopPrank();
    }

    function test_preferenceSetters_reverts() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        vm.startPrank(storageOperator);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownCollection.selector, 7));
        records.setCollectionPreferredKind(7, LocatorKind.IPFS);
        vm.expectRevert(IWorkRecords.InvalidLocator.selector);
        records.setFilePreference(tokenId, file, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.FileNotInWork.selector, tokenId, keccak256("x"))
        );
        records.setFilePreference(tokenId, keccak256("x"), NONE);
        vm.stopPrank();
        vm.prank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, platform)
        );
        records.setPreferredKind(LocatorKind.IPFS);
    }

    /// @dev Near misses the URI and file checks must refuse: an IPFS address under a kind that is
    ///      not IPFS, a scheme byte that sorts above `:`, an Arweave address one character short
    ///      (its last character still valid), and a file ID above every file of the work.
    function test_addLocator_refusesNearMisses() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        string memory txid = CA.arweave("tx");
        string memory cid = CA.ipfs("cid");
        bytes memory id = bytes(txid);
        bytes memory short = new bytes(id.length - 1);
        for (uint256 i; i < short.length; ++i) {
            short[i] = id[i < short.length - 1 ? i : i + 1];
        }
        vm.startPrank(platform);
        _expectBadLocator(tokenId, file, Locator(LocatorKind.NONE, cid));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ONCHAIN, cid));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, _with(txid, 2, ";")));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, string(short)));
        bytes32 above = bytes32(type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.FileNotInWork.selector, tokenId, above));
        records.addLocator(tokenId, above, _ar("tx"));
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.FileNotInWork.selector, tokenId, bytes32(0))
        );
        records.addLocator(tokenId, bytes32(0), _ar("tx"));
        vm.stopPrank();
    }

    /// @dev A preference index must name a listed locator: one past the end is refused, and so
    ///      is any index further out.
    function test_setFilePreference_refusesEveryIndexPastTheList() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        vm.prank(platform);
        records.addLocator(tokenId, file, _ar("a0"));
        vm.startPrank(storageOperator);
        for (uint256 index = 1; index < 4; ++index) {
            vm.expectRevert(IWorkRecords.InvalidLocator.selector);
            records.setFilePreference(tokenId, file, index);
        }
        records.setFilePreference(tokenId, file, 0);
        vm.stopPrank();
        assertEq(records.filePreference(tokenId, file), 0);
    }

    /// @dev Any existing collection takes a preferred kind, not only the newest.
    function test_setCollectionPreferredKind_acceptsAnOlderCollection() public {
        vm.prank(platform);
        uint256 newer = stream.createCollection("Second", keccak256("second"));
        assertGt(newer, collectionId);
        vm.prank(storageOperator);
        records.setCollectionPreferredKind(collectionId, LocatorKind.IPFS);
        vm.prank(storageOperator);
        vm.expectRevert(abi.encodeWithSelector(IStream.UnknownCollection.selector, newer + 1));
        records.setCollectionPreferredKind(newer + 1, LocatorKind.IPFS);
    }

    // ------------------------------------------------------------------------ state hash

    function test_stateHash_ignoresPermissionlessActions() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(platform);
        records.addLocator(tokenId, file, _ar("a0"));
        records.syncOnChain(tokenId);
        vm.prank(storageOperator);
        records.setFilePreference(tokenId, file, 0);
        assertEq(records.workStateHash(tokenId), state);
    }

    function test_stateHash_changesWithDefaultRendererBeforeFinalizeOnly() public {
        (uint256 tokenId,) = _work(1);
        uint256 finalized = _finalized(2);
        bytes32 open = records.workStateHash(tokenId);
        bytes32 closed = records.workStateHash(finalized);
        MockRenderer next = new MockRenderer("next");
        vm.prank(governor);
        stream.setDefaultRenderer(address(renderer), address(next), address(next).codehash);
        assertTrue(records.workStateHash(tokenId) != open);
        assertEq(records.workStateHash(finalized), closed);
    }

    function test_stateHash_golden() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("6529WORKS_WORK_STATE_V1"),
                tokenId,
                uint32(0),
                item.recordFileId,
                WorksHashing.CC0_LICENSE_KEY,
                _textFileId("cc0-1.0"),
                uint32(6_529),
                address(renderer)
            )
        );
        assertEq(records.workStateHash(tokenId), expected);
    }
}
