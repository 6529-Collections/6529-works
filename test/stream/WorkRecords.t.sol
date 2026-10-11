// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem, Party, SeedPolicy } from "src/interfaces/types/PackageTypes.sol";
import { IStreamCore } from "src/stream/IStreamCore.sol";
import { IWorkRecords } from "src/stream/IWorkRecords.sol";
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
        assertEq(records.entropyModule(), address(entropy));
        assertEq(uint8(records.preferredKind()), uint8(LocatorKind.NONE));
    }

    function test_constructor_rejectsNonContracts() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidDependency.selector, eoa));
        new WorkRecords(address(manager), address(stream), eoa, address(0));
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidDependency.selector, eoa));
        new WorkRecords(address(manager), address(stream), address(store), eoa);
    }

    function test_typehashes_golden() public view {
        assertEq(records.LICENSE_TYPEHASH(), keccak256("License(string spdxId,bytes32 textFileId)"));
        assertEq(
            records.RELICENSE_TYPEHASH(),
            keccak256(
                "Relicense(uint256 tokenId,License next,bytes32 stateHash,uint64 deadline)License(string spdxId,bytes32 textFileId)"
            )
        );
        assertEq(
            records.ROYALTY_TYPEHASH(),
            keccak256(
                "RoyaltyChange(uint256 tokenId,uint32 rate,bytes32 stateHash,uint64 deadline)"
            )
        );
        assertEq(
            records.REPIN_TYPEHASH(),
            keccak256(
                "RendererRepin(uint256 tokenId,address renderer,bytes32 stateHash,uint64 deadline)"
            )
        );
        (, string memory name, string memory version, uint256 chainId, address verifying,,) =
            records.eip712Domain();
        assertEq(name, "6529 Stream Records");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(records));
    }

    // -------------------------------------------------------------------------- register

    function test_register_singleFileIsPermissionless() public {
        PackageItem memory item = _recordsItem(1, false);
        uint256 tokenId = _mint(item);
        vm.expectEmit(address(records));
        emit IWorkRecords.WorkRegistered(tokenId, item.metadataHash, _one(item.contentId));
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(outsider);
        records.register(tokenId, item, _one(item.contentId));

        IWorkRecords.RecordState memory state = records.recordState(tokenId);
        assertEq(state.record, item.metadataHash);
        assertEq(state.renderer, address(0));
        assertEq(state.version, 0);
        assertEq(state.mediaCount, 1);
        assertEq(uint8(state.seedPolicy), uint8(SeedPolicy.NONE));
        assertFalse(state.finalized);
        assertFalse(state.onChainComplete);
        assertEq(records.media(tokenId), _one(item.contentId));
        assertEq(records.pinnedRenderer(tokenId), address(0));
        (SeedPolicy policy, bytes32 seed, bool available) = records.seedOf(tokenId);
        assertEq(uint8(policy), uint8(SeedPolicy.NONE));
        assertEq(seed, bytes32(0));
        assertTrue(available);
    }

    function test_register_multiFileNeedsArtistOrPlatform() public {
        PackageItem memory item = _recordsItem(1, false);
        uint256 tokenId = _mint(item);
        bytes32[] memory list = new bytes32[](2);
        list[0] = item.contentId;
        list[1] = _media(99, false);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        records.register(tokenId, item, list);
        vm.prank(platform);
        records.register(tokenId, item, list);
        assertEq(records.media(tokenId), list);

        PackageItem memory second = _recordsItem(2, false);
        uint256 secondId = _mint(second);
        list[0] = second.contentId;
        vm.prank(artist);
        records.register(secondId, second, list);
        assertEq(records.recordState(secondId).mediaCount, 2);
    }

    function test_register_storesArtistSeed() public {
        PackageItem memory item = _recordsItem(1, false);
        item.seedPolicy = SeedPolicy.ARTIST;
        item.seed = keccak256("seed");
        uint256 tokenId = _mint(item);
        records.register(tokenId, item, _one(item.contentId));
        (SeedPolicy policy, bytes32 seed, bool available) = records.seedOf(tokenId);
        assertEq(uint8(policy), uint8(SeedPolicy.ARTIST));
        assertEq(seed, keccak256("seed"));
        assertTrue(available);
    }

    function test_register_reverts() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.AlreadyRegistered.selector, tokenId));
        records.register(tokenId, item, _one(item.contentId));

        PackageItem memory other = _recordsItem(2, false);
        uint256 otherId = _mint(other);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.ItemMismatch.selector, otherId));
        records.register(otherId, item, _one(item.contentId));

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 9));
        records.register(9, other, _one(other.contentId));

        auction.burn(stream, otherId, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, otherId)
        );
        records.register(otherId, other, _one(other.contentId));
    }

    function test_register_rejectsBadMedia() public {
        PackageItem memory item = _recordsItem(1, false);
        uint256 tokenId = _mint(item);
        vm.startPrank(platform);
        vm.expectRevert(IWorkRecords.InvalidMedia.selector);
        records.register(tokenId, item, new bytes32[](0));
        vm.expectRevert(IWorkRecords.InvalidMedia.selector);
        records.register(tokenId, item, _one(keccak256("other")));
        bytes32[] memory dup = new bytes32[](2);
        dup[0] = item.contentId;
        dup[1] = item.contentId;
        vm.expectRevert(IWorkRecords.InvalidMedia.selector);
        records.register(tokenId, item, dup);
        bytes32[] memory tooMany = new bytes32[](33);
        tooMany[0] = item.contentId;
        vm.expectRevert(IWorkRecords.InvalidMedia.selector);
        records.register(tokenId, item, tooMany);
        bytes32[] memory unknown = new bytes32[](2);
        unknown[0] = item.contentId;
        unknown[1] = keccak256("unregistered");
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown[1])
        );
        records.register(tokenId, item, unknown);
        vm.stopPrank();
    }

    function test_register_rejectsBadRecordFile() public {
        PackageItem memory item = _recordsItem(1, false);
        item.metadataHash = _file("not json", "text/plain", true);
        uint256 tokenId = _mint(item);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidRecord.selector, item.metadataHash)
        );
        records.register(tokenId, item, _one(item.contentId));

        PackageItem memory pending = _recordsItem(2, false);
        pending.metadataHash = _file('{"x":1}', "application/json", false);
        uint256 pendingId = _mint(pending);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidRecord.selector, pending.metadataHash)
        );
        records.register(pendingId, pending, _one(pending.contentId));
    }

    function test_views_revertForUnregistered() public {
        uint256 tokenId = _mint(_recordsItem(1, false));
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownWork.selector, tokenId));
        records.recordState(tokenId);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownWork.selector, tokenId));
        records.workStateHash(tokenId);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownWork.selector, tokenId));
        records.media(tokenId);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownWork.selector, tokenId));
        records.seedOf(tokenId);
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
        IWorkRecords.RecordState memory state = records.recordState(tokenId);
        assertEq(state.record, next);
        assertEq(state.version, 1);
        assertTrue(records.workStateHash(tokenId) != before);
    }

    function test_setRecord_emitsStateHash() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 next = _record(77);
        bytes32 before = records.workStateHash(tokenId);
        vm.recordLogs();
        vm.prank(artist);
        records.setRecord(tokenId, next, before);
        bytes32 afterHash = records.workStateHash(tokenId);
        assertEq(vm.getRecordedLogs()[0].data, abi.encode(item.metadataHash, next, afterHash));
    }

    function test_setRecord_identicalIsNoOp() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 before = records.workStateHash(tokenId);
        vm.recordLogs();
        vm.prank(artist);
        records.setRecord(tokenId, item.metadataHash, bytes32(0));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(records.workStateHash(tokenId), before);
        assertEq(records.recordState(tokenId).version, 0);
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
        bytes32 png = _media(55, true);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRecord.selector, png));
        records.setRecord(tokenId, png, state);
        vm.prank(artist);
        records.finalize(tokenId, state);
        bytes32 finalState = records.workStateHash(tokenId);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.WorkIsFinalized.selector, tokenId));
        records.setRecord(tokenId, next, finalState);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownWork.selector, 99));
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
        assertEq(records.recordState(tokenId).record, next);
    }

    // -------------------------------------------------------------------------- finalize

    function test_finalize_pinsDefaultRenderer() public {
        (uint256 tokenId,) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        IWorkRecords.RecordState memory info = records.recordState(tokenId);
        assertTrue(info.finalized);
        assertEq(info.renderer, address(renderer));
        assertEq(info.version, 1);
        assertEq(stream.rendererOf(tokenId), address(renderer));

        MockRenderer next = new MockRenderer("next");
        vm.prank(governor);
        stream.setDefaultRenderer(address(renderer), address(next));
        assertEq(stream.rendererOf(tokenId), address(renderer));
        assertEq(stream.tokenURI(tokenId), renderer.tokenURI(address(stream), tokenId));
    }

    function test_finalize_compareAndSetCatchesRendererChange() public {
        (uint256 tokenId,) = _work(1);
        bytes32 signed = records.workStateHash(tokenId);
        MockRenderer next = new MockRenderer("next");
        vm.prank(governor);
        stream.setDefaultRenderer(address(renderer), address(next));
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
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownWork.selector, 99));
        records.finalize(99, state);
    }

    // ------------------------------------------------------------------------ syncOnChain

    function test_syncOnChain() public {
        PackageItem memory item = _recordsItem(1, false);
        uint256 tokenId = _mint(item);
        bytes32[] memory list = new bytes32[](2);
        list[0] = item.contentId;
        list[1] = _media(2, false);
        vm.prank(artist);
        records.register(tokenId, item, list);
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
        assertTrue(records.recordState(tokenId).onChainComplete);
        assertEq(records.workStateHash(tokenId), state);

        vm.recordLogs();
        records.syncOnChain(tokenId);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // --------------------------------------------------------------------------- relicense

    function _relicenseHash(uint256 tokenId, License memory next, bytes32 state, uint64 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 license = keccak256(
            abi.encode(records.LICENSE_TYPEHASH(), keccak256(bytes(next.spdxId)), next.textFileId)
        );
        return
            keccak256(abi.encode(records.RELICENSE_TYPEHASH(), tokenId, license, state, deadline));
    }

    function _bylicensedWork() internal returns (uint256 tokenId, PackageItem memory item) {
        item = _recordsItem(1, true);
        item.license = _license("CC-BY-4.0");
        tokenId = _mint(item);
        records.register(tokenId, item, _one(item.contentId));
    }

    function test_relicense_withEveryConsent() public {
        (uint256 tokenId, PackageItem memory item) = _bylicensedWork();
        License memory next = _license("CC0-1.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes[] memory sigs = _both(_relicenseHash(tokenId, next, state, deadline));

        vm.expectEmit(address(stream));
        emit IStreamCore.LicenseChanged(tokenId, _license("CC-BY-4.0"), next);
        vm.prank(governor);
        records.relicense(tokenId, item.parties, next, state, deadline, sigs);
        assertEq(stream.licenseOf(tokenId).spdxId, "CC0-1.0");
        assertEq(records.recordState(tokenId).version, 1);

        // A replay of the same consents hits the version bump.
        bytes32 current = records.workStateHash(tokenId);
        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.StateHashMismatch.selector, state, current)
        );
        records.relicense(tokenId, item.parties, _license("MIT"), state, deadline, sigs);
    }

    function test_relicense_cc0IsIrrevocable() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        License memory next = _license("CC-BY-4.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes[] memory sigs = _both(_relicenseHash(tokenId, next, state, deadline));
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.LicenseIrrevocable.selector, tokenId));
        records.relicense(tokenId, item.parties, next, state, deadline, sigs);
    }

    function test_relicense_identicalIsNoOp() public {
        (uint256 tokenId, PackageItem memory item) = _bylicensedWork();
        vm.recordLogs();
        vm.prank(governor);
        records.relicense(
            tokenId, item.parties, _license("CC-BY-4.0"), bytes32(0), 0, new bytes[](0)
        );
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_relicense_rejectsMissingOrBadConsent() public {
        (uint256 tokenId, PackageItem memory item) = _bylicensedWork();
        License memory next = _license("CC0-1.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash = _relicenseHash(tokenId, next, state, deadline);

        bytes[] memory onlyArtist = new bytes[](1);
        onlyArtist[0] = _sign(artistKey, structHash);
        vm.startPrank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, address(0))
        );
        records.relicense(tokenId, item.parties, next, state, deadline, onlyArtist);

        bytes[] memory forged = _both(structHash);
        forged[1] = _sign(0xBAD, structHash);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, collaborator)
        );
        records.relicense(tokenId, item.parties, next, state, deadline, forged);

        bytes[] memory otherPayload =
            _both(_relicenseHash(tokenId, _license("MIT"), state, deadline));
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, artist)
        );
        records.relicense(tokenId, item.parties, next, state, deadline, otherPayload);

        Party[] memory fewer = new Party[](1);
        fewer[0] = item.parties[0];
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.PartiesMismatch.selector, tokenId));
        records.relicense(tokenId, fewer, next, state, deadline, onlyArtist);
        vm.stopPrank();

        vm.warp(deadline + 1);
        bytes[] memory late = _both(structHash);
        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, address(0))
        );
        records.relicense(tokenId, item.parties, next, state, deadline, late);
    }

    function test_relicense_needsGovernance() public {
        (uint256 tokenId, PackageItem memory item) = _bylicensedWork();
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        records.relicense(tokenId, item.parties, _license("CC0-1.0"), bytes32(0), 0, new bytes[](0));
    }

    function test_relicense_consentFollowsCurrentAuthority() public {
        (uint256 tokenId, PackageItem memory item) = _bylicensedWork();
        uint256 newKey = 0xC0FFEE;
        artists.setAuthority(uint256(uint160(collaborator)), vm.addr(newKey));
        License memory next = _license("CC0-1.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 structHash = _relicenseHash(tokenId, next, state, deadline);
        bytes[] memory sigs = _both(structHash);
        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, collaborator)
        );
        records.relicense(tokenId, item.parties, next, state, deadline, sigs);
        sigs[1] = _sign(newKey, structHash);
        vm.prank(governor);
        records.relicense(tokenId, item.parties, next, state, deadline, sigs);
        assertEq(stream.licenseOf(tokenId).spdxId, "CC0-1.0");
    }

    function test_relicense_acceptsCompactSignatures() public {
        (uint256 tokenId, PackageItem memory item) = _bylicensedWork();
        License memory next = _license("CC0-1.0");
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = _digest(_relicenseHash(tokenId, next, state, deadline));
        bytes[] memory sigs = new bytes[](2);
        (bytes32 r, bytes32 vs) = vm.signCompact(artistKey, digest);
        sigs[0] = abi.encodePacked(r, vs);
        (r, vs) = vm.signCompact(collaboratorKey, digest);
        sigs[1] = abi.encodePacked(r, vs);
        vm.prank(governor);
        records.relicense(tokenId, item.parties, next, state, deadline, sigs);
        assertEq(stream.licenseOf(tokenId).spdxId, "CC0-1.0");
    }

    // ------------------------------------------------------------------------ royalty rate

    function _royaltyHash(uint256 tokenId, uint32 rate, bytes32 state, uint64 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(records.ROYALTY_TYPEHASH(), tokenId, rate, state, deadline));
    }

    function test_setRoyaltyRate_withEveryConsent() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 15 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 10_000, state, deadline));
        vm.expectEmit(address(stream));
        emit IStreamCore.RoyaltyChanged(tokenId, royaltyWallet, 6_529, 10_000);
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, item.parties, 10_000, state, deadline, sigs);
        (address receiver, uint256 amount) = stream.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, royaltyWallet);
        assertEq(amount, 0.1 ether);
        assertEq(records.recordState(tokenId).version, 1);
    }

    function test_setRoyaltyRate_reverts() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes[] memory sigs = _both(_royaltyHash(tokenId, 100_001, state, deadline));
        vm.prank(governor);
        vm.expectRevert(IStreamCore.InvalidRoyalty.selector);
        records.setRoyaltyRate(tokenId, item.parties, 100_001, state, deadline, sigs);
        sigs = _both(_royaltyHash(tokenId, 1, state, deadline));
        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, artist)
        );
        records.setRoyaltyRate(tokenId, item.parties, 2, state, deadline, sigs);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        records.setRoyaltyRate(tokenId, item.parties, 1, state, deadline, sigs);
    }

    function test_setRoyaltyRate_identicalIsNoOp() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        vm.recordLogs();
        vm.prank(governor);
        records.setRoyaltyRate(tokenId, item.parties, 6_529, bytes32(0), 0, new bytes[](0));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ------------------------------------------------------------------------------ repin

    function _repinHash(uint256 tokenId, address r, bytes32 state, uint64 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(records.REPIN_TYPEHASH(), tokenId, r, state, deadline));
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
        emit IWorkRecords.RendererRepinned(tokenId, address(renderer), address(next));
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(governor);
        records.repinRenderer(tokenId, address(next), state, deadline, sig);
        assertEq(stream.rendererOf(tokenId), address(next));
        assertEq(records.recordState(tokenId).version, 2);
    }

    function test_repinRenderer_reverts() public {
        (uint256 open,) = _work(9);
        MockRenderer next = new MockRenderer("errata");
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.WorkNotFinalized.selector, open));
        records.repinRenderer(open, address(next), bytes32(0), deadline, "");

        uint256 tokenId = _finalizedAs(1);
        bytes32 state = records.workStateHash(tokenId);
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.InvalidRenderer.selector, eoa));
        records.repinRenderer(tokenId, eoa, state, deadline, "");
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidRenderer.selector, address(store))
        );
        records.repinRenderer(tokenId, address(store), state, deadline, "");
        bytes memory wrong =
            _sign(collaboratorKey, _repinHash(tokenId, address(next), state, deadline));
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, artist)
        );
        records.repinRenderer(tokenId, address(next), state, deadline, wrong);
        vm.stopPrank();

        bytes memory sig = _sign(artistKey, _repinHash(tokenId, address(next), state, deadline));
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        records.repinRenderer(tokenId, address(next), state, deadline, sig);
        vm.warp(deadline + 1);
        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.InvalidConsent.selector, tokenId, artist)
        );
        records.repinRenderer(tokenId, address(next), state, deadline, sig);
    }

    function _finalizedAs(uint256 salt) internal returns (uint256 tokenId) {
        vm.stopPrank();
        tokenId = _finalized(salt);
        vm.startPrank(governor);
    }

    function test_repinRenderer_samePinIsNoOp() public {
        uint256 tokenId = _finalized(1);
        vm.recordLogs();
        vm.prank(governor);
        records.repinRenderer(tokenId, address(renderer), bytes32(0), 0, "");
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // --------------------------------------------------------------------------- locators

    function _ar(string memory id) internal pure returns (Locator memory) {
        return Locator(LocatorKind.ARWEAVE, string.concat("ar://", id));
    }

    function _ipfs(string memory id) internal pure returns (Locator memory) {
        return Locator(LocatorKind.IPFS, string.concat("ipfs://", id));
    }

    function test_addLocator_byArtistAndPlatform() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        vm.expectEmit(address(records));
        emit IWorkRecords.LocatorAdded(tokenId, item.contentId, 0, _ar("tx1"));
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(artist);
        records.addLocator(tokenId, item.contentId, _ar("tx1"));
        vm.prank(platform);
        records.addLocator(tokenId, item.contentId, _ipfs("bafy1"));
        Locator[] memory list = records.locators(tokenId, item.contentId);
        assertEq(list.length, 2);
        assertEq(list[1].uri, "ipfs://bafy1");
        assertEq(records.workStateHash(tokenId), state);

        vm.prank(artist);
        records.finalize(tokenId, state);
        vm.prank(platform);
        records.addLocator(tokenId, item.contentId, _ar("tx2"));
        assertEq(records.locators(tokenId, item.contentId).length, 3);
    }

    function test_addLocator_reverts() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 file = item.contentId;
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
        _expectBadLocator(tokenId, file, Locator(LocatorKind.HTTPS, "https://example.com/a"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ONCHAIN, "ar://tx"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.NONE, "ar://tx"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, "ipfs://cid"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, "ipfs://"));
        _expectBadLocator(tokenId, file, Locator(LocatorKind.IPFS, "ipfs:/"));
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
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 file = item.contentId;
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
        records.setFilePreference(tokenId, file, NONE);
        (Locator memory chosen, uint256 index) = records.preferredLocator(tokenId, file);
        assertEq(index, NONE);
        assertEq(uint8(chosen.kind), uint8(LocatorKind.ONCHAIN));
        vm.stopPrank();
    }

    function test_preferredLocator_onchainOnlyWhenComplete() public {
        PackageItem memory item = _recordsItem(1, false);
        uint256 tokenId = _mint(item);
        records.register(tokenId, item, _one(item.contentId));
        bytes32 file = item.contentId;
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NoLocator.selector, tokenId, file));
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
        (uint256 tokenId, PackageItem memory item) = _work(1);
        (Locator memory chosen, uint256 index) = records.preferredLocator(tokenId, item.contentId);
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
        (uint256 tokenId, PackageItem memory item) = _work(1);
        _mint(_recordsItem(2, true));
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
        records.addLocator(tokenId, item.contentId, _ar("a0"));
        vm.expectEmit(address(records));
        emit IWorkRecords.FilePreferenceSet(tokenId, item.contentId, NONE, 0);
        vm.expectEmit(address(stream));
        emit MetadataUpdate(tokenId);
        vm.prank(storageOperator);
        records.setFilePreference(tokenId, item.contentId, 0);
        assertEq(records.filePreference(tokenId, item.contentId), 0);
    }

    function test_preferenceSetters_reverts() public {
        (uint256 tokenId, PackageItem memory item) = _work(1);
        vm.startPrank(storageOperator);
        vm.expectRevert(IWorkRecords.InvalidPreference.selector);
        records.setPreferredKind(LocatorKind.HTTPS);
        vm.expectRevert(IWorkRecords.InvalidPreference.selector);
        records.setCollectionPreferredKind(collectionId, LocatorKind.HTTPS);
        vm.expectRevert(abi.encodeWithSelector(IStreamCore.UnknownCollection.selector, 7));
        records.setCollectionPreferredKind(7, LocatorKind.IPFS);
        vm.expectRevert(IWorkRecords.InvalidPreference.selector);
        records.setFilePreference(tokenId, item.contentId, 0);
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
        (uint256 tokenId, PackageItem memory item) = _work(1);
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(platform);
        records.addLocator(tokenId, item.contentId, _ar("a0"));
        records.syncOnChain(tokenId);
        vm.prank(storageOperator);
        records.setFilePreference(tokenId, item.contentId, 0);
        assertEq(records.workStateHash(tokenId), state);
    }

    function test_stateHash_changesWithDefaultRendererBeforeFinalizeOnly() public {
        (uint256 tokenId,) = _work(1);
        uint256 finalized = _finalized(2);
        bytes32 open = records.workStateHash(tokenId);
        bytes32 closed = records.workStateHash(finalized);
        MockRenderer next = new MockRenderer("next");
        vm.prank(governor);
        stream.setDefaultRenderer(address(renderer), address(next));
        assertTrue(records.workStateHash(tokenId) != open);
        assertEq(records.workStateHash(finalized), closed);
    }

    // ------------------------------------------------------------------------------ seeds

    function test_seedOf_vrfReadsEntropyModule() public {
        PackageItem memory item = _recordsItem(1, true);
        item.seedPolicy = SeedPolicy.VRF;
        uint256 tokenId = _mint(item);
        records.register(tokenId, item, _one(item.contentId));
        (SeedPolicy policy, bytes32 seed, bool available) = records.seedOf(tokenId);
        assertEq(uint8(policy), uint8(SeedPolicy.VRF));
        assertEq(seed, bytes32(0));
        assertFalse(available);
        entropy.deliver(address(stream), tokenId, keccak256("vrf"));
        (, seed, available) = records.seedOf(tokenId);
        assertEq(seed, keccak256("vrf"));
        assertTrue(available);
    }
}
