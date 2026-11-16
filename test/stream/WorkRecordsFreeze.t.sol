// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice A delivery contract answering one raw `preferredLocator` answer.
contract RawLocatorDelivery {
    address public immutable records;
    address public immutable predecessor;
    bytes internal _raw;

    constructor(address records_, address predecessor_) {
        records = records_;
        predecessor = predecessor_;
    }

    function set(bytes memory raw) external {
        _raw = raw;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IWorkDelivery).interfaceId || id == 0x01ffc9a7;
    }

    function preferredLocator(uint256, bytes32) external view returns (bytes memory) {
        bytes memory raw = _raw;
        assembly ("memory-safe") {
            return(add(raw, 0x20), mload(raw))
        }
    }
}

/// @notice What freezes with a work must be showable and bounded (review B): a license whose
///         ID breaks the mint rule cannot freeze (L3), a license text that must be complete
///         on-chain has at most 16 chunks (I5), media roles stop at 15 (L1), and a delivery
///         answer whose URI is not UTF-8 is not served (M2).
contract WorkRecordsFreezeTest is RecordsFixture {
    function _renounceSig(uint256 tokenId, uint16 powers)
        internal
        view
        returns (bytes32 state, uint64 deadline, bytes memory sig)
    {
        state = records.workStateHash(tokenId);
        deadline = uint64(block.timestamp + 1 days);
        sig = _sign(
            artistKey,
            keccak256(abi.encode(Typehashes.RENOUNCE_POWERS, tokenId, powers, state, deadline))
        );
    }

    /// @dev An opened work whose approved license is `license` (stored as approved).
    function _workWithLicense(uint256 salt, License memory license)
        internal
        returns (uint256 tokenId)
    {
        MediaFile[] memory media = _single(salt, true);
        PackageItem memory item = _recordsItem(salt, media);
        item.license = license;
        tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
    }

    // ------------------------------------------------------------------ L3: the license ID

    /// @dev An approved license ID that breaks the mint rule (`SpdxId`) opens, but can neither
    ///      finalize nor have RELICENSE renounced, so no work freezes a license the renderer
    ///      cannot show; relicensing (still possible) repairs it. Other powers renounce as usual.
    function test_aLicenseTheRendererCannotShowNeverFreezes() public {
        bytes32 text = _registerText("terms");
        registry.setSkipLicenseCheck(true); // a successor policy without the rule
        string[3] memory bad = [string(new bytes(65)), "MIT License", string(hex"4d4954c3a9")];
        for (uint256 i; i < bad.length; ++i) {
            uint256 tokenId = _workWithLicense(100 + i, License(bad[i], text));
            assertEq(records.licenseOf(tokenId).spdxId, bad[i], "stored as approved");
            bytes32 state = records.workStateHash(tokenId);
            vm.prank(artist);
            vm.expectRevert(IWorkRecords.InvalidLicense.selector);
            records.finalize(tokenId, state);
            (bytes32 s, uint64 d, bytes memory sig) = _renounceSig(tokenId, WorkPowers.RELICENSE);
            vm.expectRevert(IWorkRecords.InvalidLicense.selector);
            records.renounce(tokenId, WorkPowers.RELICENSE, s, d, sig);
            (s, d, sig) = _renounceSig(tokenId, WorkPowers.ROYALTY_RATE);
            records.renounce(tokenId, WorkPowers.ROYALTY_RATE, s, d, sig);
        }
        // A valid custom ID freezes.
        uint256 good = _workWithLicense(200, License("LicenseRef-Terms", text));
        (bytes32 s2, uint64 d2, bytes memory sig2) = _renounceSig(good, WorkPowers.RELICENSE);
        records.renounce(good, WorkPowers.RELICENSE, s2, d2, sig2);
        bytes32 state2 = records.workStateHash(good);
        vm.prank(artist);
        records.finalize(good, state2);
        assertTrue(records.record(good).finalized);
    }

    // ------------------------------------------------------------------ I5: the license text

    function _bigText(uint256 salt, uint256 count, bool upload) internal returns (bytes32) {
        uint256 size = store.CHUNK_SIZE();
        bytes32[] memory hashes = new bytes32[](count);
        for (uint256 j; j < count; ++j) {
            bytes memory chunk = new bytes(j + 1 == count ? 10 : size);
            bytes32 tag = keccak256(abi.encode("text", salt, j));
            assembly ("memory-safe") {
                mstore(add(chunk, 0x20), tag)
            }
            hashes[j] = keccak256(chunk);
            if (upload) store.writeChunk(chunk);
        }
        return store.registerManifest(
            hashes,
            (count - 1) * size + 10,
            uint8(IContentStore.Encoding.Identity),
            "text/plain",
            keccak256(abi.encode("text", salt))
        );
    }

    /// @dev A license text that must be complete on-chain (finalize, and relicensing a finalized
    ///      work) has at most 16 chunks, so the check is bounded whatever the text: 17 complete
    ///      chunks are refused before any chunk is read, and 16 complete chunks finalize.
    function test_aPermanentLicenseTextIsBounded() public {
        uint256 tooLong = _workWithLicense(300, License("LicenseRef-Long", _bigText(1, 17, true)));
        bytes32 state = records.workStateHash(tooLong);
        vm.prank(artist);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.finalize(tooLong, state);

        uint256 bounded =
            _workWithLicense(301, License("LicenseRef-Bounded", _bigText(2, 16, true)));
        state = records.workStateHash(bounded);
        vm.prank(artist);
        uint256 before = gasleft();
        records.finalize(bounded, state);
        console2.log("finalize with a 16-chunk license text, gas:", before - gasleft());
        assertTrue(records.record(bounded).finalized);

        // Relicensing the finalized work to a 17-chunk text is refused before the consents.
        bytes32 longer = _bigText(3, 17, true);
        PackageItem memory item;
        vm.prank(governor);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.relicense(
            bounded, License("LicenseRef-Longer", longer), item, bytes32(0), 0, new bytes[](0)
        );
    }

    /// @dev Review round 4: no license can freeze that `finalize` could never accept. Before
    ///      finalize a relicense takes no text of more than 16 chunks (or another digest kind),
    ///      and RELICENSE cannot be renounced while the work's text has more than 16 chunks or
    ///      is unregistered, since only a relicense could then repair it. A registered text of
    ///      at most 16 chunks may still lack chunks: anyone can write them, and the work then
    ///      finalizes. Fails without the change: the renunciation of the 17-chunk text goes
    ///      through and the relicense reaches the consent check (`InvalidRecordData`).
    function test_aLicenseFinalizeCouldNeverAcceptNeverFreezes() public {
        bytes32 longText = _bigText(10, 17, false);
        uint256 tooLong = _workWithLicense(310, License("LicenseRef-Long", longText));
        (bytes32 s, uint64 d, bytes memory sig) = _renounceSig(tooLong, WorkPowers.RELICENSE);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.renounce(tooLong, WorkPowers.RELICENSE, s, d, sig);
        // Before finalize, a relicense to a 17-chunk text is refused before the consents.
        PackageItem memory item;
        bytes32 longer = _bigText(11, 17, false);
        vm.prank(governor);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.relicense(
            tooLong, License("LicenseRef-Longer", longer), item, bytes32(0), 0, new bytes[](0)
        );
        // An unregistered text cannot freeze either: the store's refusal propagates.
        bytes32 unknown = keccak256("unregistered text");
        uint256 unregistered = _workWithLicense(311, License("LicenseRef-Unknown", unknown));
        (s, d, sig) = _renounceSig(unregistered, WorkPowers.RELICENSE);
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown));
        records.renounce(unregistered, WorkPowers.RELICENSE, s, d, sig);
        // Other powers still renounce.
        (s, d, sig) = _renounceSig(tooLong, WorkPowers.ROYALTY_RATE);
        records.renounce(tooLong, WorkPowers.ROYALTY_RATE, s, d, sig);

        // A registered 16-chunk text with no chunk written yet freezes, then finalizes once
        // anyone writes its chunks.
        uint256 bounded =
            _workWithLicense(312, License("LicenseRef-Bounded", _bigText(12, 16, false)));
        (s, d, sig) = _renounceSig(bounded, WorkPowers.RELICENSE);
        records.renounce(bounded, WorkPowers.RELICENSE, s, d, sig);
        bytes32 state = records.workStateHash(bounded);
        vm.prank(artist);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.finalize(bounded, state);
        _bigText(12, 16, true);
        vm.prank(artist);
        records.finalize(bounded, state);
        assertTrue(records.record(bounded).finalized);
    }

    // ------------------------------------------------------------------ L1: media roles

    /// @dev Media roles are stored in four bits: role 15 opens, role 16 never does.
    function test_mediaRolesStopAtFifteen() public {
        for (uint256 r = 15; r <= 16; ++r) {
            MediaFile[] memory media = new MediaFile[](2);
            media[0] = _mediaFile(400 + r, FileRole.PRIMARY, true);
            media[1] = _mediaFile(500 + r, FileRole.PREVIEW, true);
            // forge-lint: disable-next-line(unsafe-typecast)
            media[1].role = uint8(r);
            PackageItem memory item = _recordsItem(400 + r, media);
            uint256 tokenId = _mint(item);
            if (r == 16) {
                vm.expectRevert(
                    abi.encodeWithSelector(IWorkRecords.InvalidRecordData.selector, tokenId)
                );
            }
            records.openRecord(tokenId, item, media);
            if (r == 15) assertEq(records.mediaOf(tokenId)[1].role, 15);
        }
    }

    // ------------------------------------------------------------------ M2: locator shape

    /// @dev A served URI is printable ASCII without `"` or `\` (WS-40): a delivery answer with a
    ///      byte from 0x80 (UTF-8 or not), a control byte, a space, DEL, a quote or a backslash
    ///      is not served; the work's own answer is.
    function test_preferredLocator_onlyPrintableAsciiIsServed() public {
        (uint256 tokenId,) = _work(600);
        bytes32 file = records.mediaOf(tokenId)[0].fileId;
        RawLocatorDelivery raw = new RawLocatorDelivery(address(records), address(delivery));
        vm.prank(governor);
        records.setDelivery(address(delivery), address(raw));
        bytes[9] memory bad = [
            bytes(hex"61723a2f2fff"),
            hex"61723a2f2fc3a9", // "ar://" and a valid UTF-8 "e acute"
            hex"eda080",
            hex"61723a2f2f0a",
            hex"61723a2f2f09",
            bytes("ar:// x"),
            hex"61723a2f2f7f",
            bytes('ar://"x'),
            hex"61723a2f2f5c"
        ];
        for (uint256 i; i < bad.length; ++i) {
            raw.set(abi.encode(IWorkDelivery.Location(1, string(bad[i])), uint256(0)));
            (IWorkDelivery.Location memory l, uint256 index) =
                records.preferredLocator(tokenId, file);
            assertEq(l.kind, uint8(LocatorKind.NONE), vm.toString(i));
            assertEq(bytes(l.uri).length, 0, vm.toString(i));
            assertEq(index, type(uint256).max, vm.toString(i));
        }
        string memory good = "ar://A-z_0~9!#$%&'()*+,./:;<=>?@[]^`{|}";
        raw.set(abi.encode(IWorkDelivery.Location(1, good), uint256(2)));
        (IWorkDelivery.Location memory ok, uint256 at) = records.preferredLocator(tokenId, file);
        assertEq(ok.uri, good);
        assertEq(at, 2);
    }
}
