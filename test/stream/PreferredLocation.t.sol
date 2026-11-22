// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ILocators } from "src/interfaces/core/ILocators.sol";
import { Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { RulesFixture } from "../records/RulesFixture.sol";

/// @notice Fuzzes preferred-location resolution against a model: the file's preference, then
///         the collection's kind, then the token's kind, then the first live locator, then the
///         on-chain copy of a work `WorkFacts` records as on-chain complete. Every tier chooses
///         among the live locators, whoever added them; a dead locator is never served.
contract PreferredLocationTest is RulesFixture {
    uint256 internal constant NONE = type(uint256).max;

    struct Case {
        uint256 count;
        uint256 kindBits;
        uint256 adderBits;
        uint8 tokenRaw;
        uint8 collectionRaw;
        uint8 filePrefRaw;
        uint256 deadBits;
        bool onChain;
    }

    function _kind(uint8 raw) internal pure returns (LocatorKind) {
        return LocatorKind(raw % 4);
    }

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

    function _model(Case memory c, LocatorKind[] memory kinds, bool[] memory live, uint256 pref)
        internal
        pure
        returns (bool found, uint256 expected)
    {
        found = pref != NONE && live[pref];
        expected = pref;
        if (!found) {
            (found, expected) = _modelFirst(kinds, live, _kind(c.collectionRaw), c.onChain);
        }
        if (!found) (found, expected) = _modelFirst(kinds, live, _kind(c.tokenRaw), c.onChain);
        if (!found) {
            for (uint256 i; i < live.length; ++i) {
                if (live[i]) return (true, i);
            }
        }
        if (!found && c.onChain) (found, expected) = (true, NONE);
    }

    function _add(uint256 id, bytes32 file, LocatorKind kind, uint256 i, bool byArtist) internal {
        string memory seed = vm.toString(i);
        string memory uri = kind == LocatorKind.ARWEAVE ? CA.arweave(seed) : CA.ipfs(seed);
        if (byArtist) vm.prank(artist);
        delivery.addLocator(address(stream), id, file, Locator(kind, uri));
    }

    function _check(Case memory c) internal {
        MediaFile[] memory media;
        uint256 id;
        (id,, media) = _work(stream, 1);
        bytes32 file = media[0].fileId;
        if (c.onChain) facts.markOnChainComplete(address(stream), id);
        LocatorKind[] memory kinds = new LocatorKind[](c.count);
        uint256 artistAdded;
        for (uint256 i; i < c.count; ++i) {
            kinds[i] = (c.kindBits >> i) & 1 == 0 ? LocatorKind.ARWEAVE : LocatorKind.IPFS;
            bool byArtist = (c.adderBits >> i) & 1 == 1;
            if (byArtist && artistAdded == 8) byArtist = false;
            if (!byArtist && i - artistAdded == 8) byArtist = true;
            if (byArtist) ++artistAdded;
            _add(id, file, kinds[i], i, byArtist);
        }
        uint256 pref = c.count == 0 || c.filePrefRaw % 3 == 0 ? NONE : c.filePrefRaw % c.count;
        delivery.setPreferredKind(address(stream), _kind(c.tokenRaw));
        delivery.setCollectionPreferredKind(address(stream), 1, _kind(c.collectionRaw));
        delivery.setFilePreference(address(stream), id, file, pref);
        bool[] memory live = new bool[](c.count);
        for (uint256 i; i < c.count; ++i) {
            live[i] = (c.deadBits >> i) & 1 == 0;
            if (!live[i]) delivery.markLocatorDead(address(stream), id, file, i);
        }
        (bool found, uint256 expected) = _model(c, kinds, live, pref);
        (ILocators.Location memory l, uint256 index) =
            ILocators(address(delivery)).preferredLocator(address(stream), id, file);
        if (!found) {
            assertEq(index, NONE);
            assertEq(l.kind, 0);
            assertEq(bytes(l.uri).length, 0);
            return;
        }
        assertEq(index, expected);
        if (expected == NONE) {
            assertEq(l.kind, uint8(LocatorKind.ONCHAIN));
        } else {
            assertEq(l.kind, uint8(kinds[expected]));
            assertEq(l.uri, delivery.locators(address(stream), id, file)[expected].uri);
        }
    }

    function testFuzz_PreferredLocator_MatchesTheModel(
        uint8 count,
        uint256 kindBits,
        uint256 adderBits,
        uint8 tokenRaw,
        uint8 collectionRaw,
        uint8 filePrefRaw,
        uint256 deadBits,
        bool onChain
    ) public {
        _check(
            Case(
                bound(count, 0, 16),
                kindBits,
                adderBits,
                tokenRaw,
                collectionRaw,
                filePrefRaw,
                deadBits,
                onChain
            )
        );
    }

    function test_PreferredLocator_TheFirstLiveAfterTwoDead() public {
        _check(Case(5, 0, 0, 0, 0, 0, 0xb, false));
    }

    function test_PreferredLocator_TheArtistsLocatorAtAHighIndex() public {
        _check(Case(16, 0x5555, 0xff00, 1, 2, 31, 0x00ff, true));
    }
}
