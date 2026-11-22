// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IWorkDelivery, IWorkLocators } from "src/interfaces/IWorkDelivery.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

import { preferredOf } from "test/helpers/WorkItems.sol";

/// @notice Fuzzes preferred-location resolution (D10: file override, then collection kind, then
///         global kind, then first registered, then the implicit ONCHAIN copy) against a model.
///         ONCHAIN matches only a work marked on-chain complete by `syncOnChain`. Every tier
///         chooses among the live locators whoever added them (C33); a locator the storage
///         operator marked dead is never served, a file override naming one included (C21).
contract PreferredLocationTest is RecordsFixture {
    uint256 internal constant NONE = type(uint256).max;

    /// @dev Maps a fuzzed byte onto a preference kind: NONE, ARWEAVE, IPFS or ONCHAIN.
    function _kind(uint8 raw) internal pure returns (LocatorKind) {
        return LocatorKind(raw % 4);
    }

    /// @dev The first live locator of `kind`, or the implicit ONCHAIN copy.
    function _modelFirst(
        LocatorKind[] memory kinds,
        bool[] memory live,
        LocatorKind kind,
        bool onChain
    ) internal pure returns (bool, uint256) {
        if (kind == LocatorKind.NONE) return (false, 0);
        if (kind == LocatorKind.ONCHAIN) return (onChain, NONE);
        for (uint256 i; i < kinds.length; ++i) {
            if (live[i] && kinds[i] == kind) return (true, i);
        }
        return (false, 0);
    }

    /// @dev Mints and opens a work with `count` locators on its primary file, ARWEAVE or IPFS
    ///      by the bits of `kindBits`, added by the artist or the platform by the bits of
    ///      `adderBits` (the other side once one's quota of 8 is used); uploads its media if
    ///      `complete` and syncs it if `sync`.
    function _workWithLocators(
        uint256 count,
        uint256 kindBits,
        uint256 adderBits,
        bool complete,
        bool sync
    )
        internal
        returns (uint256 tokenId, bytes32 file, LocatorKind[] memory kinds, bool[] memory byArtist)
    {
        PackageItem memory item;
        MediaFile[] memory media;
        (tokenId, item, media) = _minted(1, complete);
        records.openRecord(tokenId, item, media);
        file = media[0].fileId;
        if (sync) records.syncOnChain(tokenId, 0, type(uint256).max);
        kinds = new LocatorKind[](count);
        byArtist = new bool[](count);
        uint256 artistAdded;
        for (uint256 i; i < count; ++i) {
            kinds[i] = (kindBits >> i) & 1 == 0 ? LocatorKind.ARWEAVE : LocatorKind.IPFS;
            // Each side has a quota of 8; a full side passes to the other.
            bool artistAdds = (adderBits >> i) & 1 == 1;
            if (artistAdds && artistAdded == 8) artistAdds = false;
            if (!artistAdds && i - artistAdded == 8) artistAdds = true;
            byArtist[i] = artistAdds;
            if (artistAdds) ++artistAdded;
            _addLocator(tokenId, file, kinds[i], i, artistAdds);
        }
    }

    /// @dev The artist or the platform adds locator `i` of `kind` (its own helper: the
    ///      unoptimized coverage build runs out of stack slots in the loop above otherwise).
    function _addLocator(uint256 tokenId, bytes32 file, LocatorKind kind, uint256 i, bool byArtist)
        internal
    {
        string memory seed = vm.toString(i);
        string memory uri = kind == LocatorKind.ARWEAVE ? CA.arweave(seed) : CA.ipfs(seed);
        vm.prank(byArtist ? artist : platform);
        delivery.addLocator(tokenId, file, Locator(kind, uri));
    }

    function _modelFirstLive(bool[] memory live) internal pure returns (bool, uint256) {
        for (uint256 i; i < live.length; ++i) {
            if (live[i]) return (true, i);
        }
        return (false, 0);
    }

    function _model(
        LocatorKind[] memory kinds,
        bool[] memory live,
        uint256 filePref,
        LocatorKind collectionKind,
        LocatorKind globalKind,
        bool onChain
    ) internal pure returns (bool found, uint256 expected) {
        found = filePref != NONE && live[filePref];
        expected = filePref;
        if (!found) (found, expected) = _modelFirst(kinds, live, collectionKind, onChain);
        if (!found) (found, expected) = _modelFirst(kinds, live, globalKind, onChain);
        if (!found) (found, expected) = _modelFirstLive(live);
        if (!found && onChain) (found, expected) = (true, NONE);
    }

    /// @dev The storage operator marks dead each locator whose bit of `deadBits` is set.
    function _markDead(uint256 tokenId, bytes32 file, uint256 count, uint256 deadBits)
        internal
        returns (bool[] memory live)
    {
        live = new bool[](count);
        vm.startPrank(storageOperator);
        for (uint256 i; i < count; ++i) {
            live[i] = (deadBits >> i) & 1 == 0;
            if (!live[i]) delivery.markLocatorDead(tokenId, file, i);
        }
        vm.stopPrank();
    }

    /// @dev One fuzzed case: locators, their adders, the preferences and the dead set. Bit 254
    ///      of `deadBits`: the media is uploaded; bit 255: synced.
    struct Case {
        uint256 count;
        uint256 kindBits;
        uint256 adderBits;
        uint8 globalRaw;
        uint8 collectionRaw;
        uint8 filePrefRaw;
        uint256 deadBits;
    }

    /// Regression: RFX-REC-1 (the adder of each locator is fuzzed; C21 and C33: so are the dead
    /// locators, and the adder no longer matters)
    function testFuzz_preferredLocator_matchesModel(
        uint8 count,
        uint256 kindBits,
        uint256 adderBits,
        uint8 globalRaw,
        uint8 collectionRaw,
        uint8 filePrefRaw,
        uint256 deadBits
    ) public {
        _check(
            Case(
                bound(count, 0, 16),
                kindBits,
                adderBits,
                globalRaw,
                collectionRaw,
                filePrefRaw,
                deadBits
            )
        );
    }

    function _check(Case memory c) internal {
        // A complete file that was never synced does not resolve on-chain.
        bool onChain = c.deadBits >> 254 == 3;
        (uint256 tokenId, bytes32 file, LocatorKind[] memory kinds,) = _workWithLocators(
            c.count, c.kindBits, c.adderBits, (c.deadBits >> 254) & 1 == 1, onChain
        );
        uint256 filePref = c.count == 0 || c.filePrefRaw % 3 == 0 ? NONE : c.filePrefRaw % c.count;
        vm.startPrank(storageOperator);
        delivery.setPreferredKind(_kind(c.globalRaw));
        delivery.setCollectionPreferredKind(collectionId, _kind(c.collectionRaw));
        delivery.setFilePreference(tokenId, file, filePref);
        vm.stopPrank();
        bool[] memory live = _markDead(tokenId, file, c.count, c.deadBits);
        (bool found, uint256 expected) =
            _model(kinds, live, filePref, _kind(c.collectionRaw), _kind(c.globalRaw), onChain);
        (Locator memory chosen, uint256 index) = preferredOf(records, tokenId, file);
        if (!found) {
            assertEq(index, NONE);
            assertEq(uint8(chosen.kind), uint8(LocatorKind.NONE));
            assertEq(bytes(chosen.uri).length, 0);
            return;
        }
        assertEq(index, expected);
        if (expected == NONE) {
            assertEq(uint8(chosen.kind), uint8(LocatorKind.ONCHAIN));
            assertEq(bytes(chosen.uri).length, 0);
        } else {
            assertEq(uint8(chosen.kind), uint8(kinds[expected]));
            assertEq(chosen.uri, delivery.locators(tokenId, file)[expected].uri);
        }
    }

    /// @dev With no preference the first live locator is served, however many dead ones come
    ///      before it.
    function test_preferredLocator_theFirstLiveAfterTwoDead() public {
        _check(Case(5, 0, 0, 0, 0, 0, 0xb));
    }

    /// @dev A file of another work is refused by name (`FileNotInWork`), by the resolution and
    ///      by every per-file setting.
    function test_delivery_refusesAFileNotInTheWork() public {
        (uint256 tokenId, bytes32 file,,) = _workWithLocators(1, 0, 0, false, false);
        bytes32 other = keccak256("not this work's file");
        bytes memory reason =
            abi.encodeWithSelector(IWorkRecords.FileNotInWork.selector, tokenId, other);
        vm.expectRevert(reason);
        delivery.preferredLocator(tokenId, other);
        vm.startPrank(storageOperator);
        vm.expectRevert(reason);
        delivery.setFilePreference(tokenId, other, 0);
        vm.expectRevert(reason);
        delivery.markLocatorDead(tokenId, other, 0);
        vm.stopPrank();
        delivery.preferredLocator(tokenId, file);
    }

    /// @dev An IPFS locator starts with exactly one of the two fixed CID prefixes: a prefix
    ///      just below either is refused, the prefixes themselves are accepted.
    function test_delivery_ipfsLocatorsNeedAFixedPrefix() public {
        (uint256 tokenId, bytes32 file,,) = _workWithLocators(0, 0, 0, false, false);
        string[2] memory valid = [CA.ipfs("prefix"), CA.ipfsRoot("prefix")];
        vm.startPrank(platform);
        for (uint256 i; i < valid.length; ++i) {
            bytes memory below = abi.encodePacked(valid[i]);
            below[13] = "h"; // "ipfs://bafkreh" / "ipfs://bafybeh": just below the prefix
            vm.expectRevert(IWorkLocators.InvalidLocator.selector);
            delivery.addLocator(tokenId, file, Locator(LocatorKind.IPFS, string(below)));
            delivery.addLocator(tokenId, file, Locator(LocatorKind.IPFS, valid[i]));
        }
        vm.stopPrank();
    }

    function test_delivery_supportsOnlyTheExactIds() public view {
        bytes4[3] memory ids = [
            type(IWorkDelivery).interfaceId,
            type(IWorkLocators).interfaceId,
            type(IERC165).interfaceId
        ];
        for (uint256 i; i < ids.length; ++i) {
            assertTrue(delivery.supportsInterface(ids[i]));
            assertFalse(delivery.supportsInterface(bytes4(uint32(ids[i]) - 1)));
            assertFalse(delivery.supportsInterface(bytes4(uint32(ids[i]) + 1)));
        }
    }

    /// @dev The storage operator can never select a copy of another file: whatever it sets,
    ///      the resolved locator is one registered for this file or its on-chain bytes.
    function testFuzz_preferredLocator_staysWithinFile(uint8 globalRaw, uint8 collectionRaw)
        public
    {
        (uint256 idA, PackageItem memory a, MediaFile[] memory mediaA) = _minted(1, false);
        (uint256 idB, PackageItem memory b, MediaFile[] memory mediaB) = _minted(2, false);
        records.openRecord(idA, a, mediaA);
        records.openRecord(idB, b, mediaB);
        bytes32 fileA = mediaA[0].fileId;
        bytes32 fileB = mediaB[0].fileId;
        vm.startPrank(artist);
        delivery.addLocator(idA, fileA, CA.ipfsLocator("a"));
        delivery.addLocator(idB, fileB, CA.ar("b"));
        vm.stopPrank();
        vm.startPrank(storageOperator);
        delivery.setPreferredKind(_kind(globalRaw));
        delivery.setCollectionPreferredKind(collectionId, _kind(collectionRaw));
        vm.stopPrank();
        (Locator memory chosen,) = preferredOf(records, idA, fileA);
        assertEq(chosen.uri, CA.ipfs("a"));
        (chosen,) = preferredOf(records, idB, fileB);
        assertEq(chosen.uri, CA.arweave("b"));
    }
}
