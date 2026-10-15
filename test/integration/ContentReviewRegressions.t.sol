// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
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

    /// @dev One copy, one URI: only the canonical spelling of a CID or transaction ID is
    ///      accepted, so the exact-bytes duplicate check holds. The last character carries two
    ///      padding bits, and a CID's eighth character holds the multihash length.
    function test_Locator_OneSpellingPerAddress() public {
        (uint256 tokenId, bytes32 file) = _openWork();
        bytes memory cid = bytes(CA.ipfs("x"));
        bytes memory txid = bytes(CA.arweave("x"));
        bytes memory b32 = "abcdefghijklmnopqrstuvwxyz234567";
        bytes memory b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        uint256 v = _index(b32, cid[cid.length - 1]);
        assertEq(v & 3, 0, "canonical CID");
        for (uint256 bits = 1; bits < 4; ++bits) {
            _refused(
                platform, tokenId, file, Locator(LocatorKind.IPFS, _swap(cid, 65, b32[v | bits]))
            );
        }
        uint256 w = _index(b64, txid[txid.length - 1]);
        assertEq(w & 3, 0, "canonical ID");
        for (uint256 bits = 1; bits < 4; ++bits) {
            _refused(
                platform,
                tokenId,
                file,
                Locator(LocatorKind.ARWEAVE, _swap(txid, 47, b64[w | bits]))
            );
        }
        // A multihash length other than 32 bytes.
        _refused(platform, tokenId, file, Locator(LocatorKind.IPFS, _swap(cid, 14, "z")));
        _refused(platform, tokenId, file, Locator(LocatorKind.IPFS, _swap(cid, 14, "i")));
        vm.startPrank(platform);
        records.addLocator(tokenId, file, Locator(LocatorKind.IPFS, string(cid)));
        records.addLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, string(txid)));
        vm.stopPrank();
    }

    // ------------------------------------- LIFECYCLE-3: after finalize only the platform adds locators

    /// @dev After finalize the artist's `addLocator` is refused, so the artist can neither serve
    ///      new content under a finalized work nor register the work's canonical copy ahead of the
    ///      platform; the platform registers it and an IPFS failover serves it.
    function test_Locator_ArtistCannotAddAfterFinalize() public {
        (uint256 tokenId, bytes32 file) = _openWork();
        string memory arweaveCopy = CA.arweave("platform arweave copy");
        vm.prank(platform);
        records.addLocator(tokenId, file, Locator(LocatorKind.ARWEAVE, arweaveCopy));
        _finalize(tokenId);
        bytes32 state = records.workStateHash(tokenId);

        Locator memory canonical = CA.ipfsLocator("the canonical CID of the primary");
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        records.addLocator(tokenId, file, canonical);
        assertEq(records.locators(tokenId, file).length, 1);

        vm.expectEmit(address(records));
        emit IWorkRecords.LocatorAdded(tokenId, file, 1, canonical);
        vm.prank(platform);
        records.addLocator(tokenId, file, canonical);
        vm.prank(storageOperator);
        records.setPreferredKind(LocatorKind.IPFS);
        assertEq(_served(tokenId, file), canonical.uri, "the IPFS failover serves it");
        assertTrue(_contains(stream.tokenURI(tokenId), canonical.uri));
        assertEq(records.workStateHash(tokenId), state, "locators never change the state hash");
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

    // ----------------------------- CONTENT-2: a record file the store does not know is incomplete

    /// @dev An approved record file whose manifest was never registered: once the record opens
    ///      the work gets core-only metadata marked `incomplete`, never a revert, until the
    ///      manifest is registered (and uploaded) or the artist sets another record.
    function test_Record_AnUnregisteredRecordFileRendersCoreOnly() public {
        Work memory w = _work(artist, collectionId);
        bytes memory json = '{"name":"Registered later"}';
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(json);
        bytes32 recordFile = store.manifestId(
            hashes, json.length, IContentStore.Encoding.Identity, "application/json", sha256(json)
        );
        w.item = _item(artist, collectionId, w.media[0].sha256Hash, w.media, recordFile);
        Work[] memory works = _one(w);
        (, uint256 tokenId) = _start(_publish(works), works, 0);
        assertTrue(_contains(stream.tokenURI(tokenId), '"record_status":"not_open"'));

        vm.prank(collector);
        records.openRecord(tokenId, w.item, w.media);
        string memory uri = stream.tokenURI(tokenId);
        assertTrue(_contains(uri, '"record_status":"incomplete"'), "core-only, not a revert");
        assertTrue(_contains(uri, '"name":"Genesis %23'));
        vm.expectRevert(
            abi.encodeWithSelector(
                Renderer.RendererNotInlineable.selector, address(stream), tokenId
            )
        );
        renderer.fullTokenURI(address(stream), tokenId);

        // Registered: still incomplete until the bytes are there; then the record renders.
        store.registerManifest(
            hashes, json.length, IContentStore.Encoding.Identity, "application/json", sha256(json)
        );
        assertTrue(_contains(stream.tokenURI(tokenId), '"record_status":"incomplete"'));
        store.writeChunk(json);
        assertTrue(_contains(stream.tokenURI(tokenId), '"name":"Registered later"'));
    }

    // ------------------------------------- the CC0 text: a correction restores the pinned text

    /// @dev The governed relicense of `tokenId` to `next`, with the artist's consent.
    function _relicense(uint256 tokenId, Work memory w, License memory next)
        internal
        view
        returns (bytes memory)
    {
        bytes32 state = records.workStateHash(tokenId);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest = _typedDigest(
            address(records),
            keccak256(
                abi.encode(
                    Typehashes.RELICENSE,
                    tokenId,
                    WorksHashing.licenseKey(next.spdxId),
                    next.textFileId,
                    state,
                    deadline
                )
            )
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(artist, digest);
        return abi.encodeCall(records.relicense, (tokenId, next, w.item, state, deadline, sigs));
    }

    function _expectRelicenseRefused(bytes memory call) internal {
        _schedule(hotAdmin, address(records), call);
        vm.warp(block.timestamp + 2 days);
        vm.prank(hotAdmin);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        manager.execute(address(records), call);
    }

    /// @dev A license whose key is CC0 names the deployment's pinned CC0 text: an approved CC0
    ///      license with another text cannot open (curation's simulation of `openRecord` catches
    ///      it), while the same text under another spelling of the identifier can.
    function test_Cc0_AnApprovedCc0LicenseMustNameThePinnedText() public {
        bytes32 typo = _storeText("CC0 1.0 Universal, with a typo", "text/plain");
        Work memory w = _work(artist, collectionId);
        w.item.license = License("CC0-1.0", typo);
        Work[] memory works = _one(w);
        (, uint256 tokenId) = _start(_publish(works), works, 0);
        vm.expectRevert(IWorkRecords.InvalidLicense.selector);
        records.openRecord(tokenId, w.item, w.media);
        assertFalse(records.isOpen(tokenId));

        Work memory v = _work(artist, collectionId);
        v.item.license = License("cc0-1.0", cc0TextFileId);
        works = _one(v);
        (, uint256 other) = _start(_publish(works), works, 0);
        records.openRecord(other, v.item, v.media);
        assertEq(records.licenseOf(other).textFileId, cc0TextFileId);
        assertEq(records.record(other).licenseKey, WorksHashing.CC0_LICENSE_KEY);
    }

    /// @dev A CC0 work's license never changes: no relicense moves it to another text, with
    ///      every party's consent and the governed action, before or after finalize, so a work
    ///      that reads `CC0-1.0` keeps the CC0 legal code.
    function test_Cc0_TheTextNeverChanges() public {
        bytes32 reserved = _storeText("All rights reserved. No reuse permitted.", "text/plain");
        Work memory w = _work(artist, collectionId);
        Work[] memory works = _one(w);
        uint256 tokenId = _sell(_publish(works), works, 0, collector, 1 ether);
        records.openRecord(tokenId, w.item, w.media);
        _expectRelicenseRefused(_relicense(tokenId, w, License("CC0-1.0", reserved)));
        _finalize(tokenId);
        _expectRelicenseRefused(_relicense(tokenId, w, License("CC0-1.0", reserved)));
        _expectRelicenseRefused(_relicense(tokenId, w, License("cc0-1.0", reserved)));
        assertEq(records.licenseOf(tokenId).textFileId, cc0TextFileId);
    }

    /// @dev A work relicensed to CC0 from another license takes the pinned CC0 text too.
    function test_Cc0_ARelicenseToCc0TakesThePinnedText() public {
        bytes32 byText = _storeText("Creative Commons Attribution 4.0 (fixture)", "text/plain");
        bytes32 other = _storeText("CC0, as the artist wrote it", "text/plain");
        Work memory w = _work(artist, collectionId);
        w.item.license = License("CC-BY-4.0", byText);
        Work[] memory works = _one(w);
        uint256 tokenId = _sell(_publish(works), works, 0, collector, 1 ether);
        records.openRecord(tokenId, w.item, w.media);
        _expectRelicenseRefused(_relicense(tokenId, w, License("CC0-1.0", other)));
        _govern(
            hotAdmin, address(records), _relicense(tokenId, w, License("CC0-1.0", cc0TextFileId))
        );
        assertEq(records.record(tokenId).licenseKey, WorksHashing.CC0_LICENSE_KEY);
    }

    // ------------------------------------------------------------------------------ helpers

    function _index(bytes memory alphabet, bytes1 c) internal pure returns (uint256 i) {
        while (alphabet[i] != c) ++i;
    }

    /// @dev A copy of `s` with byte `i` replaced by `b`.
    function _swap(bytes memory s, uint256 i, bytes1 b) internal pure returns (string memory) {
        bytes memory out = bytes(string.concat(string(s)));
        out[i] = b;
        return string(out);
    }

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
