// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Facts } from "src/interfaces/core/CoreTypes.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { Limits } from "src/interfaces/types/Limits.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { CodeRenderer } from "../mocks/records/RulesMocks.sol";
import { RulesFixture } from "../records/RulesFixture.sol";

/// @notice Rules of `StreamWorkFacts6529` that the main suite pins only in part: every change
///         of a work waits for its record to be opened (WS-1), and the number of media files a
///         record opens with (WS-2). Driven through `bare`, a token whose RECORDS module passes
///         every call straight through.
contract WorkFactsRulesTest is RulesFixture {
    address internal b;

    function setUp() public override {
        super.setUp();
        b = address(bare);
    }

    /// @dev `count` media files, the first the uploaded primary, the rest registered previews.
    function _mediaList(uint256 salt, uint256 count) internal returns (MediaFile[] memory media) {
        media = new MediaFile[](count);
        for (uint256 i; i < count; ++i) {
            media[i] = _mediaFile(salt + i, i == 0 ? FileRole.PRIMARY : FileRole.PREVIEW, i == 0);
        }
    }

    /// WS-1: each of the six per-token changes (record, license, finalize, repin, lock,
    /// on-chain complete) reverts with `RecordNotOpen` for a minted work whose record is not
    /// open, and each one applies once the record is opened.
    function test_ModuleCalls_EveryChangeWaitsForTheRecordToOpen() public {
        MediaFile[] memory media = _single(1);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        bytes32 nextRecord = _record(2);
        address nextRenderer = address(new CodeRenderer(1));
        License memory sameLicense = License("cc0-1.0", cc0Text);
        bytes memory notOpen = abi.encodeWithSelector(IWorkFacts.RecordNotOpen.selector, b, id);

        vm.expectRevert(notOpen);
        records.setRecord(b, id, nextRecord);
        vm.expectRevert(notOpen);
        records.setLicense(b, id, sameLicense);
        vm.expectRevert(notOpen);
        records.finalize(b, id);
        vm.expectRevert(notOpen);
        records.repin(b, id, nextRenderer);
        vm.expectRevert(notOpen);
        records.lock(b, id, true, false);
        vm.expectRevert(notOpen);
        facts.markOnChainComplete(b, id);
        Facts memory f = facts.factsOf(b, id);
        assertFalse(f.opened || f.finalized || f.licenseLocked || f.onChainComplete);
        assertEq(f.recordFileId, bytes32(0));

        facts.open(b, id, item, media);
        records.setRecord(b, id, nextRecord);
        records.setLicense(b, id, sameLicense);
        records.finalize(b, id);
        records.repin(b, id, nextRenderer);
        records.lock(b, id, true, true);
        facts.markOnChainComplete(b, id);
        f = facts.factsOf(b, id);
        assertEq(f.recordFileId, nextRecord);
        assertEq(f.licenseId, "cc0-1.0");
        assertEq(f.renderer, nextRenderer);
        assertTrue(f.finalized && f.licenseLocked && f.repinLocked && f.onChainComplete);
    }

    /// WS-2: a record opens with exactly `Limits.MAX_MEDIA_FILES` files, for any caller, and is
    /// refused with one more.
    function test_Open_TheMostMediaFilesOpenAndOneMoreIsRefused() public {
        uint256 most = Limits.MAX_MEDIA_FILES;
        MediaFile[] memory media = _mediaList(100, most);
        PackageItem memory item = _item(1, media);
        uint256 id = _mintItem(bare, item);
        vm.prank(stranger);
        facts.open(b, id, item, media);
        Facts memory f = facts.factsOf(b, id);
        assertTrue(f.opened);
        assertEq(f.media.length, most);
        assertEq(f.media[most - 1].fileId, media[most - 1].fileId);

        MediaFile[] memory over = _mediaList(200, most + 1);
        PackageItem memory big = _item(2, over);
        uint256 id2 = _mintItem(bare, big);
        vm.expectRevert(abi.encodeWithSelector(IWorkFacts.InvalidRecord.selector, b, id2));
        facts.open(b, id2, big, over);
        assertFalse(facts.factsOf(b, id2).opened);
    }
}
