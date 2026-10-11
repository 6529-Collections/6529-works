// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { IWorkRecords } from "src/stream/IWorkRecords.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice Fuzzes preferred-location resolution (D10: file override, then collection kind, then
///         global kind, then first registered, then the implicit ONCHAIN copy) against a model.
contract PreferredLocationTest is RecordsFixture {
    uint256 internal constant NONE = type(uint256).max;

    /// @dev Maps a fuzzed byte onto a preference kind: NONE, ARWEAVE, IPFS or ONCHAIN.
    function _kind(uint8 raw) internal pure returns (LocatorKind) {
        uint8 k = raw % 4;
        if (k == 3) return LocatorKind.ONCHAIN;
        return LocatorKind(k);
    }

    function _modelFirst(LocatorKind[] memory kinds, LocatorKind kind, bool complete)
        internal
        pure
        returns (bool, uint256)
    {
        if (kind == LocatorKind.NONE) return (false, 0);
        if (kind == LocatorKind.ONCHAIN) return (complete, NONE);
        for (uint256 i; i < kinds.length; ++i) {
            if (kinds[i] == kind) return (true, i);
        }
        return (false, 0);
    }

    function testFuzz_preferredLocator_matchesModel(
        uint8 count,
        uint256 kindBits,
        uint8 globalRaw,
        uint8 collectionRaw,
        uint8 filePrefRaw,
        bool complete
    ) public {
        count = uint8(bound(count, 0, 16));
        PackageItem memory item = _recordsItem(1, complete);
        uint256 tokenId = _mint(item);
        records.register(tokenId, item, _one(item.contentId));
        bytes32 file = item.contentId;

        LocatorKind[] memory kinds = new LocatorKind[](count);
        vm.startPrank(platform);
        for (uint256 i; i < count; ++i) {
            kinds[i] = (kindBits >> i) & 1 == 0 ? LocatorKind.ARWEAVE : LocatorKind.IPFS;
            string memory scheme = kinds[i] == LocatorKind.ARWEAVE ? "ar://" : "ipfs://";
            records.addLocator(
                tokenId, file, Locator(kinds[i], string.concat(scheme, vm.toString(i)))
            );
        }
        vm.stopPrank();

        LocatorKind globalKind = _kind(globalRaw);
        LocatorKind collectionKind = _kind(collectionRaw);
        uint256 filePref = count == 0 || filePrefRaw % 3 == 0 ? NONE : filePrefRaw % count;
        vm.startPrank(storageOperator);
        records.setPreferredKind(globalKind);
        records.setCollectionPreferredKind(collectionId, collectionKind);
        records.setFilePreference(tokenId, file, filePref);
        vm.stopPrank();

        bool found = filePref != NONE;
        uint256 expected = filePref;
        if (!found) (found, expected) = _modelFirst(kinds, collectionKind, complete);
        if (!found) (found, expected) = _modelFirst(kinds, globalKind, complete);
        if (!found && count != 0) (found, expected) = (true, 0);
        if (!found && complete) (found, expected) = (true, NONE);

        if (!found) {
            vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NoLocator.selector, tokenId, file));
            records.preferredLocator(tokenId, file);
            return;
        }
        (Locator memory chosen, uint256 index) = records.preferredLocator(tokenId, file);
        assertEq(index, expected);
        if (expected == NONE) {
            assertEq(uint8(chosen.kind), uint8(LocatorKind.ONCHAIN));
            assertEq(bytes(chosen.uri).length, 0);
        } else {
            assertEq(uint8(chosen.kind), uint8(kinds[expected]));
            Locator[] memory list = records.locators(tokenId, file);
            assertEq(chosen.uri, list[expected].uri);
        }
    }

    /// @dev The storage operator can never select a copy of another file: whatever it sets,
    ///      the resolved locator is one registered for this file or its on-chain bytes.
    function testFuzz_preferredLocator_staysWithinFile(uint8 globalRaw, uint8 collectionRaw)
        public
    {
        PackageItem memory a = _recordsItem(1, false);
        PackageItem memory b = _recordsItem(2, false);
        uint256 idA = _mint(a);
        uint256 idB = _mint(b);
        records.register(idA, a, _one(a.contentId));
        records.register(idB, b, _one(b.contentId));
        vm.startPrank(platform);
        records.addLocator(idA, a.contentId, Locator(LocatorKind.IPFS, "ipfs://a"));
        records.addLocator(idB, b.contentId, Locator(LocatorKind.ARWEAVE, "ar://b"));
        vm.stopPrank();
        vm.startPrank(storageOperator);
        records.setPreferredKind(_kind(globalRaw));
        records.setCollectionPreferredKind(collectionId, _kind(collectionRaw));
        vm.stopPrank();
        (Locator memory chosen,) = records.preferredLocator(idA, a.contentId);
        assertEq(chosen.uri, "ipfs://a");
        (chosen,) = records.preferredLocator(idB, b.contentId);
        assertEq(chosen.uri, "ar://b");
    }
}
