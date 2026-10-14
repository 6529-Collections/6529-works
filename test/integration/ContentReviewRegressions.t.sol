// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Regression tests from the content review, on the real stack (`IntegrationBase`).
contract ContentReviewRegressionsTest is IntegrationBase {
    address internal artist;
    address internal collector = makeAddr("contentCollector");

    function setUp() public override {
        super.setUp();
        artist = _actor("contentReviewArtist");
    }

    /// @dev A sold work with its record open: its token ID and primary file.
    function _openWork() internal returns (uint256 tokenId, bytes32 primary) {
        Work memory w = _work(artist, collectionId);
        Work[] memory works = _one(w);
        tokenId = _sell(_publish(works), works, 0, collector, 1 ether);
        records.openRecord(tokenId, w.item, w.media);
        primary = w.media[0].fileId;
    }

    function _finalize(uint256 tokenId) internal {
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
    }

    function _served(uint256 tokenId, bytes32 file) internal view returns (string memory uri) {
        (Locator memory l,) = records.preferredLocator(tokenId, file);
        uri = l.uri;
    }

    function _refused(address caller, uint256 tokenId, bytes32 file, Locator memory l) internal {
        vm.prank(caller);
        vm.expectRevert(IWorkRecords.InvalidLocator.selector);
        records.addLocator(tokenId, file, l);
    }

    // ------------------------------------------------- CONTENT-3: locators are content addresses

    /// @dev Only `ar://` and a 43-character transaction ID, or `ipfs://` and a profile CID with
    ///      nothing after it, are accepted, from the artist and the platform alike.
    function test_Locator_OnlyContentAddressesAreAccepted() public {
        (uint256 tokenId, bytes32 file) = _openWork();
        string memory cid = CA.ipfs("work");
        string memory txid = CA.arweave("work");
        Locator[15] memory bad = [
            Locator(LocatorKind.ARWEAVE, "ar://artist-name_6529"), // a name, not a transaction ID
            Locator(LocatorKind.ARWEAVE, string.concat(txid, "A")), // 44 characters
            Locator(LocatorKind.ARWEAVE, _cut(txid, 1)), // 42 characters
            Locator(LocatorKind.ARWEAVE, string.concat(_cut(txid, 1), ".")), // outside base64url
            Locator(LocatorKind.ARWEAVE, string.concat(_cut(txid, 1), "%")),
            Locator(LocatorKind.ARWEAVE, string.concat(txid, "/index.html")), // a path
            Locator(LocatorKind.IPFS, string.concat(cid, "/../../ipns/artist.eth")),
            Locator(LocatorKind.IPFS, string.concat(cid, "?x=1")),
            Locator(LocatorKind.IPFS, string.concat(cid, "#x")),
            Locator(LocatorKind.IPFS, "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"), // v0
            Locator(LocatorKind.IPFS, _upper(cid)), // base32 upper case
            // An identity multihash (`bafkqaa`) or a dag-cbor root (`bafyrei`): not the profile
            Locator(LocatorKind.IPFS, _over(cid, "ipfs://bafkqaa")),
            Locator(LocatorKind.IPFS, _over(cid, "ipfs://bafyrei")),
            Locator(LocatorKind.IPFS, string.concat(_cut(cid, 1), "1")), // outside base32
            Locator(LocatorKind.ARWEAVE, cid) // the wrong kind for the scheme
        ];
        for (uint256 i; i < bad.length; ++i) {
            _refused(artist, tokenId, file, bad[i]);
            _refused(platform, tokenId, file, bad[i]);
        }
        vm.startPrank(artist);
        records.addLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, txid));
        records.addLocator(tokenId, file, Locator(LocatorKind.IPFS, cid));
        vm.stopPrank();
        vm.prank(platform);
        records.addLocator(tokenId, file, Locator(LocatorKind.IPFS, CA.ipfsRoot("work")));
        assertEq(records.locators(tokenId, file).length, 3);
    }

    // ------------------------- LIFECYCLE-3: an artist locator after finalize waits for selection

    /// @dev After finalize, an artist's new locator is not served by a kind preference; the
    ///      platform's copy keeps being served until the storage operator selects the artist's.
    function test_Locator_ArtistLocatorAfterFinalizeIsNotServedByKind() public {
        (uint256 tokenId, bytes32 file) = _openWork();
        string memory platformCopy = CA.arweave("platform copy");
        vm.prank(platform);
        records.addLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, platformCopy));
        _finalize(tokenId);
        bytes32 state = records.workStateHash(tokenId);

        string memory artistCopy = CA.ipfs("artist copy");
        vm.expectEmit(address(records));
        emit IWorkRecords.LocatorAdded(tokenId, file, 1, Locator(LocatorKind.IPFS, artistCopy));
        vm.prank(artist);
        records.addLocator(tokenId, file, Locator(LocatorKind.IPFS, artistCopy));
        vm.prank(storageOperator);
        records.setPreferredKind(LocatorKind.IPFS);
        assertEq(_served(tokenId, file), platformCopy, "the IPFS preference skips it");
        assertTrue(_contains(stream.tokenURI(tokenId), platformCopy));
        vm.prank(storageOperator);
        records.setCollectionPreferredKind(collectionId, LocatorKind.IPFS);
        assertEq(_served(tokenId, file), platformCopy, "so does the collection preference");

        // The storage operator selects it: served.
        vm.prank(storageOperator);
        records.setFilePreference(tokenId, file, 1);
        assertEq(_served(tokenId, file), artistCopy);
        assertTrue(_contains(stream.tokenURI(tokenId), artistCopy));
        assertEq(records.workStateHash(tokenId), state, "locators never change the state hash");
    }

    /// @dev After finalize, an artist's locator is not the first-registered fallback either: a
    ///      file whose only locators the artist added after finalize has no served locator.
    function test_Locator_ArtistLocatorAfterFinalizeIsNotTheFallback() public {
        (uint256 tokenId, bytes32 file) = _openWork();
        _finalize(tokenId);
        vm.startPrank(artist);
        records.addLocator(tokenId, file, CA.ar("first"));
        records.addLocator(tokenId, file, CA.ipfsLocator("second"));
        vm.stopPrank();
        (Locator memory served, uint256 index) = records.preferredLocator(tokenId, file);
        assertEq(uint8(served.kind), uint8(LocatorKind.NONE));
        assertEq(index, type(uint256).max);
        assertFalse(_contains(stream.tokenURI(tokenId), "ar://"), "no URL is served");

        // A platform copy added later is the fallback.
        vm.prank(platform);
        records.addLocator(tokenId, file, CA.ar("platform"));
        assertEq(_served(tokenId, file), CA.arweave("platform"));
    }

    /// @dev Unchanged: the artist's locators added before finalize, and the platform's at any
    ///      time, are served by the kind preferences and the fallback.
    function test_Locator_ArtistBeforeAndPlatformAfterFinalizeAreServed() public {
        (uint256 tokenId, bytes32 file) = _openWork();
        vm.prank(artist);
        records.addLocator(tokenId, file, CA.ar("artist before"));
        _finalize(tokenId);
        assertEq(_served(tokenId, file), CA.arweave("artist before"), "the fallback");
        vm.prank(platform);
        records.addLocator(tokenId, file, CA.ipfsLocator("platform after"));
        vm.prank(storageOperator);
        records.setPreferredKind(LocatorKind.IPFS);
        assertEq(_served(tokenId, file), CA.ipfs("platform after"), "the kind preference");
        vm.prank(storageOperator);
        records.setPreferredKind(LocatorKind.ARWEAVE);
        assertEq(_served(tokenId, file), CA.arweave("artist before"));
    }

    // ------------------------------------------------------------------------------ helpers

    /// @dev `s` without its last `n` bytes.
    function _cut(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length - n);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[i];
        }
        return string(out);
    }

    /// @dev `s` with its first bytes replaced by `head`.
    function _over(string memory s, string memory head) internal pure returns (string memory) {
        bytes memory b = bytes(string.concat(s)); // a copy
        for (uint256 i; i < bytes(head).length; ++i) {
            b[i] = bytes(head)[i];
        }
        return string(b);
    }

    /// @dev The CID part of `ipfs://<cid>` in upper case.
    function _upper(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(string.concat(s)); // a copy
        for (uint256 i = 7; i < b.length; ++i) {
            if (b[i] >= "a" && b[i] <= "z") b[i] = bytes1(uint8(b[i]) - 32);
        }
        return string(b);
    }
}
