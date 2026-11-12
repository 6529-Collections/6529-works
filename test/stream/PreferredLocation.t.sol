// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice Fuzzes preferred-location resolution (D10: file override, then collection kind, then
///         global kind, then first registered, then the implicit ONCHAIN copy) against a model.
///         ONCHAIN matches only a work marked on-chain complete by `syncOnChain`, and only the
///         file override selects a locator the platform added (RFX-REC-1).
contract PreferredLocationTest is RecordsFixture {
    uint256 internal constant NONE = type(uint256).max;

    /// @dev Maps a fuzzed byte onto a preference kind: NONE, ARWEAVE, IPFS or ONCHAIN.
    function _kind(uint8 raw) internal pure returns (LocatorKind) {
        return LocatorKind(raw % 4);
    }

    /// @dev The first artist locator of `kind` (`byArtist`), or the implicit ONCHAIN copy.
    function _modelFirst(
        LocatorKind[] memory kinds,
        bool[] memory byArtist,
        LocatorKind kind,
        bool onChain
    ) internal pure returns (bool, uint256) {
        if (kind == LocatorKind.NONE) return (false, 0);
        if (kind == LocatorKind.ONCHAIN) return (onChain, NONE);
        for (uint256 i; i < kinds.length; ++i) {
            if (byArtist[i] && kinds[i] == kind) return (true, i);
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
        if (sync) records.syncOnChain(tokenId);
        kinds = new LocatorKind[](count);
        byArtist = new bool[](count);
        uint256 artistAdded;
        for (uint256 i; i < count; ++i) {
            kinds[i] = (kindBits >> i) & 1 == 0 ? LocatorKind.ARWEAVE : LocatorKind.IPFS;
            string memory seed = vm.toString(i);
            string memory uri = kinds[i] == LocatorKind.ARWEAVE ? CA.arweave(seed) : CA.ipfs(seed);
            // Each side has a quota of 8; a full side passes to the other.
            bool artistAdds = (adderBits >> i) & 1 == 1;
            if (artistAdds && artistAdded == 8) artistAdds = false;
            if (!artistAdds && i - artistAdded == 8) artistAdds = true;
            byArtist[i] = artistAdds;
            if (artistAdds) ++artistAdded;
            vm.prank(artistAdds ? artist : platform);
            records.addLocator(tokenId, file, Locator(kinds[i], uri));
        }
    }

    function _modelFirstArtist(bool[] memory byArtist) internal pure returns (bool, uint256) {
        for (uint256 i; i < byArtist.length; ++i) {
            if (byArtist[i]) return (true, i);
        }
        return (false, 0);
    }

    function _model(
        LocatorKind[] memory kinds,
        bool[] memory byArtist,
        uint256 filePref,
        LocatorKind collectionKind,
        LocatorKind globalKind,
        bool onChain
    ) internal pure returns (bool found, uint256 expected) {
        found = filePref != NONE;
        expected = filePref;
        if (!found) (found, expected) = _modelFirst(kinds, byArtist, collectionKind, onChain);
        if (!found) (found, expected) = _modelFirst(kinds, byArtist, globalKind, onChain);
        if (!found) (found, expected) = _modelFirstArtist(byArtist);
        if (!found && onChain) (found, expected) = (true, NONE);
    }

    /// Regression: RFX-REC-1 (the adder of each locator is fuzzed)
    function testFuzz_preferredLocator_matchesModel(
        uint8 count,
        uint256 kindBits,
        uint256 adderBits,
        uint8 globalRaw,
        uint8 collectionRaw,
        uint8 filePrefRaw,
        bool complete,
        bool synced
    ) public {
        count = uint8(bound(count, 0, 16));
        // A complete file that was never synced does not resolve on-chain.
        bool onChain = complete && synced;
        (uint256 tokenId, bytes32 file, LocatorKind[] memory kinds, bool[] memory byArtist) =
            _workWithLocators(count, kindBits, adderBits, complete, onChain);

        LocatorKind globalKind = _kind(globalRaw);
        LocatorKind collectionKind = _kind(collectionRaw);
        uint256 filePref = count == 0 || filePrefRaw % 3 == 0 ? NONE : filePrefRaw % count;
        vm.startPrank(storageOperator);
        records.setPreferredKind(globalKind);
        records.setCollectionPreferredKind(collectionId, collectionKind);
        records.setFilePreference(tokenId, file, filePref);
        vm.stopPrank();

        (bool found, uint256 expected) =
            _model(kinds, byArtist, filePref, collectionKind, globalKind, onChain);
        (Locator memory chosen, uint256 index) = records.preferredLocator(tokenId, file);
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
            assertEq(chosen.uri, records.locators(tokenId, file)[expected].uri);
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
        records.addLocator(idA, fileA, CA.ipfsLocator("a"));
        records.addLocator(idB, fileB, CA.ar("b"));
        vm.stopPrank();
        vm.startPrank(storageOperator);
        records.setPreferredKind(_kind(globalRaw));
        records.setCollectionPreferredKind(collectionId, _kind(collectionRaw));
        vm.stopPrank();
        (Locator memory chosen,) = records.preferredLocator(idA, fileA);
        assertEq(chosen.uri, CA.ipfs("a"));
        (chosen,) = records.preferredLocator(idB, fileB);
        assertEq(chosen.uri, CA.arweave("b"));
    }
}
