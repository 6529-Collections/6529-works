// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice Fuzzes preferred-location resolution (D10: file override, then collection kind, then
///         global kind, then first registered, then the implicit ONCHAIN copy) against a model.
///         ONCHAIN matches only a work marked on-chain complete by `syncOnChain`.
contract PreferredLocationTest is RecordsFixture {
    uint256 internal constant NONE = type(uint256).max;

    /// @dev Maps a fuzzed byte onto a preference kind: NONE, ARWEAVE, IPFS or ONCHAIN.
    function _kind(uint8 raw) internal pure returns (LocatorKind) {
        return LocatorKind(raw % 4);
    }

    /// @dev Locators the artist added after finalize are held: skipped by the kinds and the
    ///      fallback (`held` has bit `i` for locator `i`).
    function _modelFirst(LocatorKind[] memory kinds, uint256 held, LocatorKind kind, bool onChain)
        internal
        pure
        returns (bool, uint256)
    {
        if (kind == LocatorKind.NONE) return (false, 0);
        if (kind == LocatorKind.ONCHAIN) return (onChain, NONE);
        for (uint256 i; i < kinds.length; ++i) {
            if ((held >> i) & 1 == 0 && kinds[i] == kind) return (true, i);
        }
        return (false, 0);
    }

    /// @dev Mints and opens a work with `count` locators on its primary file, ARWEAVE or IPFS
    ///      by the bits of `kindBits`; uploads its media if `complete` and syncs it if `sync`.
    ///      The platform adds the first 8 and the artist the rest; with `finalizeAt` below
    ///      `count`, the artist finalizes the work before locator `finalizeAt`, so its locators
    ///      from there on are held (bits of `held`).
    function _workWithLocators(
        uint256 count,
        uint256 kindBits,
        bool complete,
        bool sync,
        uint256 finalizeAt
    ) internal returns (Setup memory w) {
        (w.tokenId, w.file) = _openWork(complete, sync);
        w.kinds = new LocatorKind[](count);
        for (uint256 i; i < count; ++i) {
            if (i == finalizeAt) _finalize(w.tokenId);
            w.kinds[i] = (kindBits >> i) & 1 == 0 ? LocatorKind.ARWEAVE : LocatorKind.IPFS;
            // The platform's quota of 8, then the artist's.
            if (i >= 8 && i >= finalizeAt) w.held |= 1 << i;
            vm.prank(i < 8 ? platform : artist);
            records.addLocator(w.tokenId, w.file, _locator(w.kinds[i], vm.toString(i)));
        }
    }

    /// @dev A work with locators on its primary file (`file`), their kinds, and which are held.
    struct Setup {
        uint256 tokenId;
        bytes32 file;
        LocatorKind[] kinds;
        uint256 held;
    }

    function _openWork(bool complete, bool sync) internal returns (uint256 tokenId, bytes32 file) {
        PackageItem memory item;
        MediaFile[] memory media;
        (tokenId, item, media) = _minted(1, complete);
        records.openRecord(tokenId, item, media);
        file = media[0].fileId;
        if (sync) records.syncOnChain(tokenId);
    }

    function _finalize(uint256 tokenId) internal {
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
    }

    function _locator(LocatorKind kind, string memory seed) internal pure returns (Locator memory) {
        return kind == LocatorKind.ARWEAVE ? CA.ar(seed) : CA.ipfsLocator(seed);
    }

    function _model(
        LocatorKind[] memory kinds,
        uint256 held,
        uint256 filePref,
        LocatorKind collectionKind,
        LocatorKind globalKind,
        bool onChain
    ) internal pure returns (bool found, uint256 expected) {
        found = filePref != NONE;
        expected = filePref;
        if (!found) (found, expected) = _modelFirst(kinds, held, collectionKind, onChain);
        if (!found) (found, expected) = _modelFirst(kinds, held, globalKind, onChain);
        for (uint256 i; !found && i < kinds.length; ++i) {
            if ((held >> i) & 1 == 0) (found, expected) = (true, i);
        }
        if (!found && onChain) (found, expected) = (true, NONE);
    }

    function testFuzz_preferredLocator_matchesModel(
        uint8 count,
        uint256 kindBits,
        uint8 globalRaw,
        uint8 collectionRaw,
        uint8 filePrefRaw,
        bool complete,
        bool synced
    ) public {
        count = uint8(bound(count, 0, 16));
        // A complete file that was never synced does not resolve on-chain.
        bool onChain = complete && synced;
        // The kinds use the low 16 bits; the high half picks when the artist finalizes: before
        // one of the locators, or never (16 and above).
        Setup memory w =
            _workWithLocators(count, kindBits, complete, onChain, (kindBits >> 128) % 21);

        LocatorKind globalKind = _kind(globalRaw);
        LocatorKind collectionKind = _kind(collectionRaw);
        uint256 filePref = count == 0 || filePrefRaw % 3 == 0 ? NONE : filePrefRaw % count;
        vm.startPrank(storageOperator);
        records.setPreferredKind(globalKind);
        records.setCollectionPreferredKind(collectionId, collectionKind);
        records.setFilePreference(w.tokenId, w.file, filePref);
        vm.stopPrank();

        (bool found, uint256 expected) =
            _model(w.kinds, w.held, filePref, collectionKind, globalKind, onChain);
        (Locator memory chosen, uint256 index) = records.preferredLocator(w.tokenId, w.file);
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
            assertEq(uint8(chosen.kind), uint8(w.kinds[expected]));
            assertEq(chosen.uri, records.locators(w.tokenId, w.file)[expected].uri);
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
        vm.startPrank(platform);
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
