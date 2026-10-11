// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IStream } from "src/interfaces/IStream.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { ItemKind, License, PackageItem, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { MockRenderer } from "../mocks/stream/StreamMocks.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

contract WorkRecordsTest is RecordsFixture {
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    uint256 internal constant NONE = type(uint256).max;

    // ------------------------------------------------------------------------------ deploy

    function test_constructor_wiring() public view {
        assertEq(records.stream(), address(stream));
        assertEq(records.artistRegistry(), address(artists));
        assertEq(records.contentStore(), address(store));
        assertEq(records.cc0TextFileId(), keccak256("cc0-1.0"));
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
        vm.expectRevert(abi.encodeWithSelector(WorkRecords.InvalidDependency.selector, eoa));
        new WorkRecords(address(manager), eoa, address(store), cc0);
        vm.expectRevert(
            abi.encodeWithSelector(WorkRecords.InvalidDependency.selector, address(store))
        );
        new WorkRecords(address(manager), address(store), address(store), cc0);
        vm.expectRevert(abi.encodeWithSelector(WorkRecords.InvalidDependency.selector, eoa));
        new WorkRecords(address(manager), address(stream), eoa, cc0);
        vm.expectRevert(WorkRecords.InvalidLicense.selector);
        new WorkRecords(address(manager), address(stream), address(store), _license("mit"));
        // Identifiers are normalised to lowercase, so an uppercase CC0 is rejected.
        vm.expectRevert(WorkRecords.InvalidLicense.selector);
        new WorkRecords(
            address(manager), address(stream), address(store), License("CC0-1.0", bytes32(0))
        );
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

        // An unregistered file.
        media = _single(3, false);
        media[0].fileId = keccak256("unregistered");
        item = _recordsItem(3, media);
        _expectBadOpen(_mint(item), item, media);

        // The primary is not first, or there are two.
        media = new MediaFile[](2);
        media[0] = _mediaFile(4, FileRole.PREVIEW, false);
        media[1] = _mediaFile(5, FileRole.PRIMARY, false);
        item = _recordsItem(4, media);
        _expectBadOpen(_mint(item), item, media);
        media[0] = _mediaFile(4, FileRole.PRIMARY, false);
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

        // An invalid license identifier: empty, or not normalised lowercase.
        media = _single(7, false);
        item = _recordsItem(7, media);
        item.license = _license("");
        _expectBadOpen(_mint(item), item, media);
        media = _single(8, false);
        item = _recordsItem(8, media);
        item.license = License("CC-BY-4.0", bytes32(0));
        _expectBadOpen(_mint(item), item, media);
    }

    function test_openRecord_rejectsUnknownRecordFile() public {
        MediaFile[] memory media = _single(1, false);
        PackageItem memory item = _recordsItem(1, media);
        item.recordFileId = keccak256("no such record");
        uint256 tokenId = _mint(item);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.UnknownRecordFile.selector, item.recordFileId)
        );
        records.openRecord(tokenId, item, media);
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

        // A replay of the same consents hits the version bump.
        bytes32 current = records.workStateHash(tokenId);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.LicenseIrrevocable.selector, tokenId));
        records.relicense(tokenId, _license("mit"), item, state, deadline, sigs);
        assertTrue(current != state);
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
        item.license = License("cc0-1.0", keccak256("other cc0 text"));
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertEq(records.licenseOf(tokenId).spdxId, "cc0-1.0");
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.LicenseIrrevocable.selector, tokenId));
        records.relicense(tokenId, _license("mit"), item, bytes32(0), 0, new bytes[](0));
    }

    function test_relicense_identicalIsNoOp() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        vm.recordLogs();
        vm.prank(governor);
        records.relicense(
            tokenId,
            License("cc-by-4.0", keccak256("cc-by-4.0")),
            item,
            bytes32(0),
            0,
            new bytes[](0)
        );
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_relicense_rejectsInvalidNext() public {
        (uint256 tokenId, PackageItem memory item) = _byWork();
        vm.startPrank(governor);
        vm.expectRevert(WorkRecords.InvalidLicense.selector);
        records.relicense(tokenId, _license(""), item, bytes32(0), 0, new bytes[](0));
        vm.expectRevert(WorkRecords.InvalidLicense.selector);
        records.relicense(
            tokenId, _license(string(new bytes(65))), item, bytes32(0), 0, new bytes[](0)
        );
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
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, 2));
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

    // ------------------------------------------------------------------------ royalty rate

    function _royaltyHash(uint256 tokenId, uint32 rate, bytes32 state, uint64 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(Typehashes.ROYALTY_RATE_CHANGE, tokenId, rate, state, deadline));
    }

    function test_setRoyaltyRate_withEveryConsent() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 15 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 10_000, state, deadline));
        vm.expectEmit(address(stream));
        emit IStream.RoyaltyRateChanged(tokenId, 6_529, 10_000);
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 10_000, item, state, deadline, sigs);
        (address receiver, uint256 amount) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, _defaultRoyaltyWallet());
        assertEq(amount, 0.1 ether);
        assertEq(records.record(tokenId).version, 1);
        assertTrue(records.workStateHash(tokenId) != state);
    }

    function test_setRoyaltyRate_reverts() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 100_001, state, deadline));
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(_streamError("InvalidRoyaltyRate(uint32)"), 100_001));
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

    function _streamError(string memory signature) internal pure returns (bytes4) {
        return bytes4(keccak256(bytes(signature)));
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
        editionsMock.link(stream, tokenId, tokenId);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 15 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 8_000, state, deadline));
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, 8_000, item, state, deadline, sigs);
        assertEq(stream.work(tokenId).royaltyRate, 8_000);
        assertEq(editionsMock.rateOf(tokenId), 8_000);
    }

    // ------------------------------------------------------------------------------ seeds

    function test_seedOf_byPolicy() public {
        (uint256 none,) = _work(1);
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
        vm.expectRevert(abi.encodeWithSelector(WorkRecords.WorkNotFinalized.selector, open));
        records.repinRenderer(open, address(next), bytes32(0), bytes32(0), deadline, "");

        uint256 tokenId = _finalized(1);
        bytes32 state = records.workStateHash(tokenId);
        address eoa = makeAddr("eoa");
        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRenderer.selector, eoa));
        records.repinRenderer(tokenId, eoa, bytes32(0), state, deadline, "");
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidRenderer.selector, address(next))
        );
        records.repinRenderer(tokenId, address(next), keccak256("wrong"), state, deadline, "");
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidRenderer.selector, address(store))
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
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, 0));
        records.repinRenderer(tokenId, address(next), address(next).codehash, state, deadline, sig);
    }

    function test_repinRenderer_samePinIsNoOp() public {
        uint256 tokenId = _finalized(1);
        vm.recordLogs();
        vm.prank(governor);
        records.repinRenderer(tokenId, address(renderer), bytes32(0), bytes32(0), 0, "");
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // -------------------------------------------------------------------- edition masters

    function test_editionMaster_notifiesEditions() public {
        MediaFile[] memory media = _single(1, true);
        PackageItem memory item = _recordsItem(1, media);
        item.kind = ItemKind.EDITION_MASTER;
        uint256 tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
        assertEq(editionsMock.notified(tokenId), 0);
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

    function _ar(string memory id) internal pure returns (Locator memory) {
        return Locator(LocatorKind.ARWEAVE, string.concat("ar://", id));
    }

    function _ipfs(string memory id) internal pure returns (Locator memory) {
        return Locator(LocatorKind.IPFS, string.concat("ipfs://", id));
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
        assertEq(list[1].uri, "ipfs://bafy1");
        assertEq(records.workStateHash(tokenId), state);

        vm.prank(artist);
        records.finalize(tokenId, state);
        vm.prank(platform);
        records.addLocator(tokenId, file, _ar("tx2"));
        assertEq(records.locators(tokenId, file).length, 3);
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
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ONCHAIN, "ar://tx"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.NONE, "ar://tx"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, "ipfs://cid"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, "ipfs://"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, "ipfs:/"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, "https://example.com"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, "ipfs://a b"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, 'ipfs://a"b'));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, "ipfs://a<b"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, "ipfs://a\\b"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, unicode"ipfs://é"));
        _expectBadLocator(
            tokenId, file, Locator(LocatorKind.IPFS, string.concat("ipfs://", _repeat(2042)))
        );
        records.addLocator(
            tokenId, file, Locator(LocatorKind.IPFS, string.concat("ipfs://", _repeat(2041)))
        );
        for (uint256 i = 1; i < 16; ++i) {
            records.addLocator(tokenId, file, _ar(vm.toString(i)));
        }
        _expectBadLocator(tokenId, file, _ar("seventeenth"));
        vm.stopPrank();
    }

    function _expectBadLocator(uint256 tokenId, bytes32 file, Locator memory locator) internal {
        vm.expectRevert(IWorkRecords.InvalidLocator.selector);
        records.addLocator(tokenId, file, locator);
    }

    function _repeat(uint256 n) internal pure returns (string memory) {
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = "a";
        }
        return string(out);
    }

    function test_preferredLocator_mostSpecificWins() public {
        (uint256 tokenId,) = _work(1);
        bytes32 file = _primary(tokenId);
        vm.startPrank(platform);
        records.addLocator(tokenId, file, _ar("a0"));
        records.addLocator(tokenId, file, _ipfs("i1"));
        records.addLocator(tokenId, file, _ar("a2"));
        vm.stopPrank();

        _expectPreferred(tokenId, file, 0, "ar://a0");
        vm.startPrank(storageOperator);
        records.setPreferredKind(LocatorKind.IPFS);
        _expectPreferred(tokenId, file, 1, "ipfs://i1");
        records.setCollectionPreferredKind(collectionId, LocatorKind.ARWEAVE);
        _expectPreferred(tokenId, file, 0, "ar://a0");
        records.setFilePreference(tokenId, file, 2);
        _expectPreferred(tokenId, file, 2, "ar://a2");
        records.setCollectionPreferredKind(collectionId, LocatorKind.ONCHAIN);
        _expectPreferred(tokenId, file, 2, "ar://a2");
        records.setFilePreference(tokenId, file, NONE);
        (Locator memory chosen, uint256 index) = records.preferredLocator(tokenId, file);
        assertEq(index, NONE);
        assertEq(uint8(chosen.kind), uint8(LocatorKind.ONCHAIN));
        vm.stopPrank();
    }

    function test_preferredLocator_onchainOnlyWhenComplete() public {
        (uint256 tokenId, PackageItem memory item, MediaFile[] memory media) = _minted(1, false);
        records.openRecord(tokenId, item, media);
        bytes32 file = media[0].fileId;
        vm.expectRevert(abi.encodeWithSelector(WorkRecords.NoLocator.selector, tokenId, file));
        records.preferredLocator(tokenId, file);
        vm.prank(storageOperator);
        records.setPreferredKind(LocatorKind.ONCHAIN);
        vm.prank(platform);
        records.addLocator(tokenId, file, _ipfs("i0"));
        _expectPreferred(tokenId, file, 0, "ipfs://i0");
        _upload(1);
        (Locator memory chosen, uint256 index) = records.preferredLocator(tokenId, file);
        assertEq(index, NONE);
        assertEq(uint8(chosen.kind), uint8(LocatorKind.ONCHAIN));
        assertEq(bytes(chosen.uri).length, 0);
    }

    function test_preferredLocator_implicitOnchainFallback() public {
        (uint256 tokenId,) = _work(1);
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
                keccak256("cc0-1.0"),
                uint32(6_529),
                address(renderer)
            )
        );
        assertEq(records.workStateHash(tokenId), expected);
    }
}
