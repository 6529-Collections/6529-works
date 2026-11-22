// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { Facts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { HostileModule } from "../mocks/core/CoreMocks.sol";
import { CodeRenderer, ReenteringToken } from "../mocks/records/RulesMocks.sol";
import { RulesFixture } from "../records/RulesFixture.sol";

/// @notice `WorkFacts`, the permanent record, driven through a token (`bare`) whose RECORDS
///         module passes every call straight through: what holds here holds whatever a RECORDS
///         module does.
contract WorkFactsTest is RulesFixture {
    address internal b;

    function setUp() public override {
        super.setUp();
        b = address(bare);
    }

    function _open(uint256 salt) internal returns (uint256 id, PackageItem memory item) {
        (id, item,) = _work(bare, salt);
    }

    /// @dev A two-chunk JSON file, uploaded.
    function _twoChunk() internal returns (bytes32 fileId) {
        uint256 chunk = store.CHUNK_SIZE();
        bytes memory first = new bytes(chunk);
        bytes memory last = "x";
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256(first);
        hashes[1] = keccak256(last);
        fileId = store.registerManifest(
            hashes, chunk + 1, 0, "application/json", sha256(bytes.concat(first, last))
        );
        store.writeChunk(first);
        store.writeChunk(last);
    }

    /// @dev A registered text of 17 chunks (never stored).
    function _longText() internal returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](17);
        for (uint256 i; i < 17; ++i) {
            hashes[i] = keccak256(abi.encode("chunk", i));
        }
        return store.registerManifest(
            hashes, 16 * store.CHUNK_SIZE() + 1, 0, "text/plain", keccak256("long")
        );
    }

    // ---------------------------------------------------------------------------- open

    function test_Open_AnyoneOpensWithTheMintedItemAndItsMedia() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PREVIEW, false);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        vm.expectEmit(address(facts));
        emit IWorkFacts.RecordOpened(b, id, item, media);
        vm.expectEmit(b);
        emit IERC4906.MetadataUpdate(id);
        vm.prank(stranger);
        facts.open(b, id, item, media);
        Facts memory f = facts.factsOf(b, id);
        assertTrue(f.opened);
        assertEq(f.recordFileId, item.recordFileId);
        assertEq(f.licenseId, "CC0-1.0");
        assertEq(f.licenseTextFileId, cc0Text);
        assertEq(f.media.length, 2);
        assertEq(f.media[0].fileId, media[0].fileId);
        assertEq(f.media[1].fileId, media[1].fileId);
        assertEq(f.media[1].role, uint8(FileRole.PREVIEW));
        assertFalse(f.finalized || f.onChainComplete || f.licenseLocked || f.repinLocked);
        assertEq(f.renderer, address(0));
    }

    function test_Open_RefusesTwice() public {
        (uint256 id, PackageItem memory item) = _open(1);
        MediaFile[] memory media = _single(1);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RecordAlreadyOpen.selector, b, id));
        facts.open(b, id, item, media);
    }

    function test_Open_RefusesAnotherItem() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        item.recordFileId = bytes32(uint256(7));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        facts.open(b, id, item, media);
    }

    function test_Open_RefusesMediaTheItemDidNotCommitTo() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        MediaFile[] memory other = _single(2);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        facts.open(b, id, item, other);
    }

    /// @dev The primary matches; a later file is not the one the item committed to.
    function test_Open_RefusesASecondaryFileTheItemDidNotCommitTo() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PREVIEW, false);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        media[1] = _mediaFile(3, FileRole.PREVIEW, false);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        facts.open(b, id, item, media);
    }

    function test_Open_RefusesAPrimaryOtherThanTheContentHash() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        item.contentHash = keccak256("other content");
        uint256 id = _mintItem(bare, item);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        facts.open(b, id, item, media);
    }

    function test_Open_RefusesNoMediaAndMoreThanTheLimit() public {
        MediaFile[] memory none = new MediaFile[](0);
        PackageItem memory item = _item(1, _single(1));
        item.mediaHash = WorksHashing.mediaHash(none);
        uint256 id = _mintItem(bare, item);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        facts.open(b, id, item, none);

        MediaFile[] memory many = new MediaFile[](33);
        for (uint256 i; i < 33; ++i) {
            many[i] = _mediaFile(100 + i, i == 0 ? FileRole.PRIMARY : FileRole.PREVIEW, false);
        }
        PackageItem memory big = _item(2, many);
        uint256 id2 = _mintItem(bare, big);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id2));
        facts.open(b, id2, big, many);
    }

    function test_Open_ThePrimaryRoleIsFirstAndOnlyFirst() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PRIMARY, false);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        facts.open(b, id, item, media);

        media[0] = _mediaFile(4, FileRole.PREVIEW, true);
        media[1] = _mediaFile(3, FileRole.PREVIEW, false);
        PackageItem memory item2 = _item(2, media);
        uint256 id2 = _mintItem(bare, item2);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id2));
        facts.open(b, id2, item2, media);
    }

    function test_Open_RefusesADigestOtherThanTheStoresDeclaration() public {
        MediaFile[] memory media = _single(1);
        media[0].sha256Hash = keccak256("not the declared digest");
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        facts.open(b, id, item, media);
    }

    function test_Open_AnUnknownFileRevertsInTheStore() public {
        MediaFile[] memory media = new MediaFile[](1);
        media[0] = MediaFile(keccak256("unknown"), sha256("x"), 0);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, media[0].fileId)
        );
        facts.open(b, id, item, media);
    }

    function test_Open_RefusesABurnedToken() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        sale.burn(b, id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        facts.open(b, id, item, media);
    }

    function test_Open_ACc0LicenseMustNameTheDeploymentText() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        item.license = License("cc0-1.0", mitText);
        uint256 id = _mintItem(bare, item);
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        facts.open(b, id, item, media);
    }

    function test_Open_KeepsALicenseWithAnEmptyIdentifierButItNeverFinalizes() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        item.license = License("", cc0Text);
        uint256 id = _mintItem(bare, item);
        facts.open(b, id, item, media);
        assertEq(facts.factsOf(b, id).licenseId, "");
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        records.finalize(b, id);
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.lock(b, id, true, false);
    }

    function test_Open_ATokenCallingBackFromItsMetadataHookCannotOpenTwice() public {
        ReenteringToken t = new ReenteringToken(facts);
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        t.set(WorksHashing.itemHash(item), address(records), address(renderer));
        t.arm(abi.encodeCall(IWorkFacts.open, (address(t), 1, item, media)));
        facts.open(address(t), 1, item, media);
        assertEq(t.reentered(), 0);
        assertEq(facts.factsOf(address(t), 1).media.length, 1);
    }

    // ----------------------------------------------------------------- on-chain complete

    function test_MarkOnChainComplete_OnlyWhenEveryFileIsStored() public {
        MediaFile[] memory media = new MediaFile[](2);
        media[0] = _mediaFile(1, FileRole.PRIMARY, true);
        media[1] = _mediaFile(2, FileRole.PREVIEW, false);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RecordNotOpen.selector, b, id));
        facts.markOnChainComplete(b, id);
        facts.open(b, id, item, media);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.NotOnChainComplete.selector, b, id));
        facts.markOnChainComplete(b, id);
        store.writeChunk(_mediaBytes(2));
        vm.expectEmit(address(facts));
        emit IWorkFacts.OnChainComplete(b, id);
        vm.prank(stranger);
        facts.markOnChainComplete(b, id);
        assertTrue(facts.factsOf(b, id).onChainComplete);
        // Again: nothing more happens.
        vm.recordLogs();
        facts.markOnChainComplete(b, id);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // -------------------------------------------------------------- the RECORDS module

    function test_ModuleCalls_OnlyTheTokensRecordsModule() public {
        (uint256 id,) = _open(1);
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeCall(IWorkFacts.setRecord, (b, id, bytes32(0)));
        calls[1] = abi.encodeCall(IWorkFacts.setLicense, (b, id, License("MIT", mitText)));
        calls[2] = abi.encodeCall(IWorkFacts.finalize, (b, id));
        calls[3] = abi.encodeCall(IWorkFacts.repin, (b, id, address(renderer)));
        calls[4] = abi.encodeCall(IWorkFacts.lock, (b, id, true, false));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(stranger);
            (bool ok, bytes memory ret) = address(facts).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(IWorkFacts.NotRecordsModule.selector, b, stranger));
        }
        // The RECORDS module of another token is a stranger here.
        vm.prank(address(rules));
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.NotRecordsModule.selector, b, address(rules))
        );
        facts.setRecord(b, id, bytes32(0));
    }

    function test_ModuleCalls_NeedAnOpenRecord() public {
        uint256 id = _mintItem(bare, _item(1, _single(1)));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RecordNotOpen.selector, b, id));
        records.setRecord(b, id, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RecordNotOpen.selector, b, id));
        records.finalize(b, id);
    }

    function test_SetRecord_UntilFinalizeThenNever() public {
        (uint256 id,) = _open(1);
        bytes32 next = _record(2);
        vm.expectEmit(address(facts));
        emit IWorkFacts.RecordSet(b, id, next);
        records.setRecord(b, id, next);
        assertEq(facts.factsOf(b, id).recordFileId, next);
        records.finalize(b, id);
        bytes32 late = _record(3);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.WorkIsFinalized.selector, b, id));
        records.setRecord(b, id, late);
        assertEq(facts.factsOf(b, id).recordFileId, next);
    }

    // ------------------------------------------------------------------------ licenses

    function test_SetLicense_ACc0WorkStaysCc0InAnyCase() public {
        (uint256 id,) = _open(1);
        string[3] memory others = ["MIT", "CC-BY-4.0", "LicenseRef-cc0-1.0"];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(IWorkFacts.InvalidLicense.selector);
            records.setLicense(b, id, License(others[i], mitText));
        }
        // CC0 in another case, with the deployment's text, is still CC0.
        vm.expectEmit(address(facts));
        emit IWorkFacts.LicenseSet(b, id, License("cc0-1.0", cc0Text));
        records.setLicense(b, id, License("cc0-1.0", cc0Text));
        // CC0 never names another text.
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.setLicense(b, id, License("CC0-1.0", mitText));
        assertEq(facts.factsOf(b, id).licenseId, "cc0-1.0");
    }

    function test_SetLicense_ANonCc0WorkMayMoveAndMayBecomeCc0() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        item.license = License("MIT", mitText);
        uint256 id = _mintItem(bare, item);
        facts.open(b, id, item, media);
        records.setLicense(b, id, License("CC-BY-4.0", mitText));
        records.setLicense(b, id, _cc0());
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.setLicense(b, id, License("MIT", mitText));
    }

    function test_SetLicense_RefusesAnInvalidIdentifierOrText() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        item.license = License("MIT", mitText);
        uint256 id = _mintItem(bare, item);
        facts.open(b, id, item, media);
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.setLicense(b, id, License("", mitText));
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.setLicense(b, id, License("MIT License", mitText));
        bytes32 longText = _longText();
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.setLicense(b, id, License("Apache-2.0", longText));
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, bytes32(uint256(9)))
        );
        records.setLicense(b, id, License("Apache-2.0", bytes32(uint256(9))));
    }

    function test_SetLicense_AfterFinalizeTheTextMustBeStored() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        item.license = License("MIT", mitText);
        uint256 id = _mintItem(bare, item);
        facts.open(b, id, item, media);
        bytes32 unstored = _file("Apache text", "text/plain", false);
        records.setLicense(b, id, License("Apache-2.0", unstored));
        records.setLicense(b, id, License("MIT", mitText));
        records.finalize(b, id);
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.setLicense(b, id, License("Apache-2.0", unstored));
    }

    function test_SetLicense_NeverOnceLocked() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        item.license = License("MIT", mitText);
        uint256 id = _mintItem(bare, item);
        facts.open(b, id, item, media);
        records.lock(b, id, true, false);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.LicenseIsLocked.selector, b, id));
        records.setLicense(b, id, _cc0());
    }

    // ------------------------------------------------------------------------ finalize

    function test_Finalize_PinsTheTokensRendererModuleOnce() public {
        (uint256 id,) = _open(1);
        vm.expectEmit(address(facts));
        emit IWorkFacts.Finalized(b, id, address(renderer), address(renderer).codehash);
        records.finalize(b, id);
        Facts memory f = facts.factsOf(b, id);
        assertTrue(f.finalized);
        assertEq(f.renderer, address(renderer));
        assertEq(f.rendererCodeHash, address(renderer).codehash);
        assertEq(facts.rendererOf(b, id), address(renderer));
        assertEq(bare.rendererOf(id), address(renderer));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.WorkIsFinalized.selector, b, id));
        records.finalize(b, id);
    }

    function test_Finalize_TheRecordIsOneCompleteChunkStoredAsItIs() public {
        (uint256 id,) = _open(1);
        records.setRecord(b, id, _twoChunk());
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        records.finalize(b, id);
        records.setRecord(b, id, _file("{}", "application/json", false));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        records.finalize(b, id);
        bytes memory gz = "gzipped";
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(gz);
        bytes32 gzip = store.registerManifest(
            hashes, gz.length, uint8(IContentStore.Encoding.Gzip), "application/json", sha256(gz)
        );
        store.writeChunk(gz);
        records.setRecord(b, id, gzip);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        records.finalize(b, id);
        records.setRecord(b, id, _record(9));
        records.finalize(b, id);
    }

    /// @dev The rule kept from `WorkRecords`: a CC0 text under an empty identifier never
    ///      finalizes, nor any other license whose identifier is invalid.
    function test_Finalize_RefusesALicenseWithAnEmptyOrInvalidIdentifier() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        item.license = License("", cc0Text);
        uint256 id = _mintItem(bare, item);
        facts.open(b, id, item, media);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id));
        records.finalize(b, id);
        assertFalse(facts.factsOf(b, id).finalized);

        PackageItem memory bad = _item(2, _single(2));
        bad.license = License("MIT License", mitText);
        uint256 id2 = _mintItem(bare, bad);
        facts.open(b, id2, bad, _single(2));
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id2));
        records.finalize(b, id2);
    }

    function test_Finalize_TheLicenseTextMustBeStored() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        item.license = License("MIT", _file("unstored MIT", "text/plain", false));
        uint256 id = _mintItem(bare, item);
        facts.open(b, id, item, media);
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.finalize(b, id);
    }

    function test_Finalize_RefusesWhenTheTokenHasNoRenderer() public {
        (uint256 id,) = _open(1);
        bare.removeModule(Slots.RENDERER);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, address(0)));
        records.finalize(b, id);
    }

    // ------------------------------------------------------------------- repin and lock

    function test_Repin_OnlyAfterFinalizeAndNeverOnceLocked() public {
        (uint256 id,) = _open(1);
        CodeRenderer next = new CodeRenderer(1);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.WorkNotFinalized.selector, b, id));
        records.repin(b, id, address(next));
        records.finalize(b, id);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, address(0xdead))
        );
        records.repin(b, id, address(0xdead));
        vm.expectEmit(address(facts));
        emit IWorkFacts.RendererRepinned(b, id, address(next), address(next).codehash);
        records.repin(b, id, address(next));
        assertEq(facts.rendererOf(b, id), address(next));
        records.lock(b, id, false, true);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.RepinIsLocked.selector, b, id));
        records.repin(b, id, address(renderer));
        assertEq(facts.rendererOf(b, id), address(next));
    }

    function test_Lock_IsOneWayAndReportsBothLocks() public {
        (uint256 id,) = _open(1);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.WorkNotFinalized.selector, b, id));
        records.lock(b, id, false, true);
        vm.expectEmit(address(facts));
        emit IWorkFacts.Locked(b, id, true, false);
        records.lock(b, id, true, false);
        records.finalize(b, id);
        vm.expectEmit(address(facts));
        emit IWorkFacts.Locked(b, id, true, true);
        records.lock(b, id, false, true);
        // Nothing unlocks.
        records.lock(b, id, false, false);
        Facts memory f = facts.factsOf(b, id);
        assertTrue(f.licenseLocked && f.repinLocked);
    }

    function test_Lock_ALicenseLocksOnlyWithAValidIdentifierAndText() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        item.license = License("MIT", _longText());
        uint256 id = _mintItem(bare, item);
        facts.open(b, id, item, media);
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        records.lock(b, id, true, false);
        // A text that is only missing chunks may lock: anyone may store them later.
        records.setLicense(b, id, License("MIT", _file("later", "text/plain", false)));
        records.lock(b, id, true, false);
    }

    // --------------------------------------------------------------------- renderer pin

    function test_RendererOf_RefusesAPinnedRendererWhoseCodeChanged() public {
        (uint256 id,) = _open(1);
        assertEq(facts.rendererOf(b, id), address(0));
        records.finalize(b, id);
        vm.etch(address(renderer), address(new CodeRenderer(7)).code);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, address(renderer))
        );
        facts.rendererOf(b, id);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, address(renderer))
        );
        bare.tokenURI(id);
    }

    // ------------------------------------------------------------------ hostile RECORDS

    /// @dev A hostile RECORDS module tries every write a module must not succeed at.
    function test_Hostile_ARecordsModuleCannotBreakAnyGuarantee() public {
        (uint256 id,) = _open(1);
        HostileModule hostile = new HostileModule();
        bare.proposeModule(Slots.RECORDS, address(hostile));
        skip(bare.moduleDelay());
        bare.activateModule(Slots.RECORDS);
        bytes32 before = keccak256(abi.encode(facts.factsOf(b, id).media));
        bool ok;
        // Finalize (allowed), then try what finalize forbids.
        (ok,) = hostile.exec(address(facts), abi.encodeCall(IWorkFacts.finalize, (b, id)));
        assertTrue(ok);
        bytes32 recordAtFinalize = facts.factsOf(b, id).recordFileId;
        (ok,) = hostile.exec(
            address(facts), abi.encodeCall(IWorkFacts.setRecord, (b, id, bytes32(uint256(1))))
        );
        assertFalse(ok, "record after finalize");
        (ok,) = hostile.exec(address(facts), abi.encodeCall(IWorkFacts.finalize, (b, id)));
        assertFalse(ok, "finalize twice");
        (ok,) = hostile.exec(
            address(facts), abi.encodeCall(IWorkFacts.setLicense, (b, id, License("MIT", mitText)))
        );
        assertFalse(ok, "leave CC0");
        (ok,) = hostile.exec(
            address(facts),
            abi.encodeCall(IWorkFacts.setLicense, (b, id, License("CC0-1.0", mitText)))
        );
        assertFalse(ok, "CC0 with another text");
        (ok,) = hostile.exec(address(facts), abi.encodeCall(IWorkFacts.lock, (b, id, true, true)));
        assertTrue(ok);
        (ok,) = hostile.exec(
            address(facts), abi.encodeCall(IWorkFacts.repin, (b, id, address(hostile)))
        );
        assertFalse(ok, "repin past the lock");
        (ok,) = hostile.exec(address(facts), abi.encodeCall(IWorkFacts.setLicense, (b, id, _cc0())));
        assertFalse(ok, "license past the lock");
        // It cannot reach another token's records either.
        (uint256 other,,) = _work(stream, 2);
        (ok,) = hostile.exec(
            address(facts), abi.encodeCall(IWorkFacts.setRecord, (address(stream), other, 0))
        );
        assertFalse(ok, "another token");
        Facts memory f = facts.factsOf(b, id);
        assertEq(keccak256(abi.encode(f.media)), before);
        assertEq(f.recordFileId, recordAtFinalize);
        assertEq(f.licenseId, "CC0-1.0");
        assertEq(f.renderer, address(renderer));
        assertTrue(f.finalized && f.licenseLocked && f.repinLocked);
        // The token itself is untouched.
        assertEq(bare.ownerOf(id), address(sale));
        assertEq(hostile.attack(b, id, address(sale)), 0);
    }

    /// @dev A pinned renderer that reverts or burns its gas fails only `tokenURI`.
    function test_Hostile_APinnedRendererFailsOnlyTokenUri() public {
        HostileModule hostile = new HostileModule();
        bare.proposeModule(Slots.RENDERER, address(hostile));
        skip(bare.moduleDelay());
        bare.activateModule(Slots.RENDERER);
        (uint256 id,) = _open(1);
        records.finalize(b, id);
        assertEq(facts.rendererOf(b, id), address(hostile));
        hostile.setMode(HostileModule.Mode.REVERT);
        vm.expectRevert();
        bare.tokenURI(id);
        hostile.setMode(HostileModule.Mode.BURN_GAS);
        vm.expectRevert();
        bare.tokenURI{ gas: 1_000_000 }(id);
        // The work's facts and the token still answer.
        assertTrue(facts.factsOf(b, id).finalized);
        sale.record(b, id, true, collector, 1);
        sale.send(b, id, collector);
        assertEq(bare.ownerOf(id), collector);
    }

    // ----------------------------------------------------------------------- fuzz

    /// @dev Whatever license a CC0 work is offered, it ends CC0 with the CC0 text.
    function testFuzz_SetLicense_CC0IsNeverLeft(string memory spdxId, bytes32 textFileId) public {
        (uint256 id,) = _open(1);
        try records.setLicense(b, id, License(spdxId, textFileId)) { } catch { }
        Facts memory f = facts.factsOf(b, id);
        assertEq(WorksHashing.licenseKey(f.licenseId), WorksHashing.CC0_LICENSE_KEY);
        assertEq(f.licenseTextFileId, cc0Text);
    }
}
