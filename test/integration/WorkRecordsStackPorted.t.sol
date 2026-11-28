// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IRenderer } from "src/interfaces/IRenderer.sol";
import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { Facts } from "src/interfaces/core/CoreTypes.sol";
import { ILocators } from "src/interfaces/core/ILocators.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { Locator, LocatorKind } from "src/interfaces/types/ContentTypes.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice The record and delivery modules on the deployed stack, under the genesis roles,
///         re-ported from the retired `WorkRecordsStack` suite: locators are canonical content
///         addresses from the artist (before finalize) and the PLATFORM role (always); the
///         STORAGE_OPERATOR's preferences choose among every live locator; an approved record
///         file the store does not know renders core-only metadata instead of reverting; and a
///         CC0 work names the deployment's CC0 text, for good.
contract WorkRecordsStackPortedTest is IntegrationBase {
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
        _open(tokenId, w);
        primary = w.media[0].fileId;
    }

    function _finalize(uint256 tokenId) internal {
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        vm.prank(artist);
        rules.finalize(address(stream), tokenId, state);
    }

    function _served(uint256 tokenId, bytes32 file) internal view returns (string memory) {
        (ILocators.Location memory l,) = delivery.preferredLocator(address(stream), tokenId, file);
        return l.uri;
    }

    function _add(address caller, uint256 tokenId, bytes32 file, Locator memory l) internal {
        vm.prank(caller);
        delivery.addLocator(address(stream), tokenId, file, l);
    }

    function _refused(address caller, uint256 tokenId, bytes32 file, Locator memory l) internal {
        vm.prank(caller);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(address(stream), tokenId, file, l);
    }

    function _asOperator(bytes memory data) internal {
        vm.prank(storageOperator);
        (bool ok, bytes memory reason) = address(delivery).call(data);
        _bubble(ok, reason);
    }

    // ------------------------------------------------- locators are content addresses

    /// @dev Only `ar://` and a 43-character transaction ID, or `ipfs://` and a profile CID with
    ///      nothing after it, are accepted, from the artist and the platform alike.
    function test_Locator_OnlyContentAddressesAreAccepted() public {
        (uint256 tokenId, bytes32 file) = _openWork();
        string memory cid = CA.ipfs("work");
        string memory txid = CA.arweave("work");
        Locator[15] memory bad = [
            Locator(LocatorKind.ARWEAVE, "ar://artist-name_6529"),
            Locator(LocatorKind.ARWEAVE, string.concat(txid, "A")),
            Locator(LocatorKind.ARWEAVE, _cut(txid, 1)),
            Locator(LocatorKind.ARWEAVE, string.concat(_cut(txid, 1), ".")),
            Locator(LocatorKind.ARWEAVE, string.concat(_cut(txid, 1), "%")),
            Locator(LocatorKind.ARWEAVE, string.concat(txid, "/index.html")),
            Locator(LocatorKind.IPFS, string.concat(cid, "/../../ipns/artist.eth")),
            Locator(LocatorKind.IPFS, string.concat(cid, "?x=1")),
            Locator(LocatorKind.IPFS, string.concat(cid, "#x")),
            Locator(LocatorKind.IPFS, "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"),
            Locator(LocatorKind.IPFS, _upper(cid)),
            Locator(LocatorKind.IPFS, _over(cid, "ipfs://bafkqaa")),
            Locator(LocatorKind.IPFS, _over(cid, "ipfs://bafyrei")),
            Locator(LocatorKind.IPFS, string.concat(_cut(cid, 1), "1")),
            Locator(LocatorKind.ARWEAVE, cid)
        ];
        for (uint256 i; i < bad.length; ++i) {
            _refused(artist, tokenId, file, bad[i]);
            _refused(platform, tokenId, file, bad[i]);
        }
        _add(artist, tokenId, file, Locator(LocatorKind.ARWEAVE, txid));
        _add(artist, tokenId, file, Locator(LocatorKind.IPFS, cid));
        _add(platform, tokenId, file, Locator(LocatorKind.IPFS, CA.ipfsRoot("work")));
        assertEq(delivery.locators(address(stream), tokenId, file).length, 3);
    }

    /// @dev One copy, one URI: only the canonical spelling of a CID or transaction ID is
    ///      accepted (the last character's padding bits are zero; a CID's multihash length is 32
    ///      bytes), so the exact-bytes duplicate check holds.
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
        _refused(platform, tokenId, file, Locator(LocatorKind.IPFS, _swap(cid, 14, "z")));
        _refused(platform, tokenId, file, Locator(LocatorKind.IPFS, _swap(cid, 14, "i")));
        _add(platform, tokenId, file, Locator(LocatorKind.IPFS, string(cid)));
        _add(platform, tokenId, file, Locator(LocatorKind.ARWEAVE, string(txid)));
    }

    // ------------------------------------- after finalize only the platform adds locators

    /// @dev After finalize the artist's `addLocator` needs the PLATFORM role, so the artist can
    ///      neither serve new content under a finalized work nor take the canonical copy's URI
    ///      first; the platform adds it, the storage operator's kind preference or file pick
    ///      serves it, and locators never change the state hash.
    function test_Locator_ArtistCannotAddAfterFinalize() public {
        (uint256 tokenId, bytes32 file) = _openWork();
        string memory arweaveCopy = CA.arweave("platform arweave copy");
        _add(platform, tokenId, file, Locator(LocatorKind.ARWEAVE, arweaveCopy));
        _finalize(tokenId);
        bytes32 state = rules.workStateHash(address(stream), tokenId);

        Locator memory canonical = CA.ipfsLocator("the canonical CID of the primary");
        vm.prank(artist);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, artist)
        );
        delivery.addLocator(address(stream), tokenId, file, canonical);
        assertEq(delivery.locators(address(stream), tokenId, file).length, 1);

        vm.expectEmit(address(delivery));
        emit IWorkDelivery.LocatorAdded(
            address(stream), tokenId, file, 1, canonical, platform, false
        );
        _add(platform, tokenId, file, canonical);
        _asOperator(abi.encodeCall(delivery.setPreferredKind, (address(stream), LocatorKind.IPFS)));
        assertEq(_served(tokenId, file), canonical.uri, "the preferred kind serves it");
        _asOperator(
            abi.encodeCall(delivery.setPreferredKind, (address(stream), LocatorKind.ARWEAVE))
        );
        assertEq(_served(tokenId, file), arweaveCopy, "and the Arweave copy under its kind");
        _asOperator(abi.encodeCall(delivery.setFilePreference, (address(stream), tokenId, file, 1)));
        assertEq(_served(tokenId, file), canonical.uri, "the operator's pick serves it");
        assertTrue(_contains(stream.tokenURI(tokenId), canonical.uri));
        assertEq(rules.workStateHash(address(stream), tokenId), state, "the state hash stays");
    }

    /// @dev The artist's locators added before finalize and the platform's after are all
    ///      served: the first live one by the fallback, any by a kind preference or a pick.
    function test_Locator_ArtistBeforeAndPlatformAfterFinalizeAreServed() public {
        (uint256 tokenId, bytes32 file) = _openWork();
        _add(artist, tokenId, file, CA.ar("artist before"));
        _finalize(tokenId);
        assertEq(_served(tokenId, file), CA.arweave("artist before"), "the fallback");
        _add(platform, tokenId, file, CA.ipfsLocator("platform after"));
        assertEq(_served(tokenId, file), CA.arweave("artist before"), "the first live locator");
        _asOperator(abi.encodeCall(delivery.setPreferredKind, (address(stream), LocatorKind.IPFS)));
        assertEq(_served(tokenId, file), CA.ipfs("platform after"), "the preferred kind");
        _asOperator(abi.encodeCall(delivery.setFilePreference, (address(stream), tokenId, file, 1)));
        assertEq(_served(tokenId, file), CA.ipfs("platform after"), "the operator's pick");
        _asOperator(
            abi.encodeCall(
                delivery.setFilePreference, (address(stream), tokenId, file, type(uint256).max)
            )
        );
        _asOperator(
            abi.encodeCall(delivery.setPreferredKind, (address(stream), LocatorKind.ARWEAVE))
        );
        assertEq(_served(tokenId, file), CA.arweave("artist before"));
    }

    // ----------------------------- a record file the store does not know is incomplete

    /// @dev An approved record file whose manifest was never registered: once the record opens
    ///      the work gets core-only metadata marked `incomplete`, never a revert, until the
    ///      manifest is registered and its bytes uploaded.
    function test_Record_AnUnregisteredRecordFileRendersCoreOnly() public {
        Work memory w = _work(artist, collectionId);
        bytes memory json = '{"name":"Registered later"}';
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(json);
        bytes32 recordFile = store.manifestId(
            hashes,
            json.length,
            uint8(IContentStore.Encoding.Identity),
            "application/json",
            sha256(json)
        );
        w.item = _item(artist, collectionId, w.media[0].sha256Hash, w.media, recordFile);
        Work[] memory works = _one(w);
        (, uint256 tokenId) = _start(_publish(works), works, 0);
        assertTrue(_contains(stream.tokenURI(tokenId), '"record_status":"not_open"'));

        vm.prank(collector);
        facts.open(address(stream), tokenId, w.item, w.media);
        string memory uri = stream.tokenURI(tokenId);
        assertTrue(_contains(uri, '"record_status":"incomplete"'), "core-only, not a revert");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRenderer.RendererNotInlineable.selector, address(stream), tokenId
            )
        );
        renderer.fullTokenURI(address(stream), tokenId);

        store.registerManifest(
            hashes,
            json.length,
            uint8(IContentStore.Encoding.Identity),
            "application/json",
            sha256(json)
        );
        assertTrue(_contains(stream.tokenURI(tokenId), '"record_status":"incomplete"'));
        store.writeChunk(json);
        assertTrue(_contains(stream.tokenURI(tokenId), '"name":"Registered later"'));
    }

    // ------------------------------------- the CC0 text

    /// @dev The artist's consent to relicensing `tokenId` to `next`, as the network's call.
    function _relicense(uint256 tokenId, Work memory w, License memory next)
        internal
        view
        returns (bytes memory)
    {
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest = _typedDigest(
            address(rules),
            keccak256(
                abi.encode(
                    rules.RELICENSE_TYPEHASH(),
                    address(stream),
                    tokenId,
                    WorksHashing.licenseKey(next.spdxId),
                    next.textFileId,
                    state,
                    deadline
                )
            )
        );
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(artist, _sign(artist, digest));
        return abi.encodeCall(
            rules.relicense, (address(stream), tokenId, next, w.item, state, deadline, sigs)
        );
    }

    /// @dev Schedules the relicense as the network (FUNDS_SETTER, 3 days) and expects the
    ///      execution refused with `InvalidLicense`.
    function _expectRelicenseRefused(bytes memory call) internal {
        (, uint32 delay) = manager.canCall(network, address(rules), bytes4(call));
        assertEq(delay, 3 days, "relicense waits 3 days");
        vm.prank(network);
        manager.schedule(address(rules), call, 0);
        vm.warp(block.timestamp + delay);
        vm.prank(network);
        vm.expectRevert(IWorkFacts.InvalidLicense.selector);
        manager.execute(address(rules), call);
    }

    function _licenseOf(uint256 tokenId) internal view returns (Facts memory) {
        return facts.factsOf(address(stream), tokenId);
    }

    /// @dev A license whose key is CC0 names the deployment's CC0 text: an approved CC0 license
    ///      with another text is refused by the mint policy, so it never mints a work whose
    ///      record could not open, while the same text under another spelling of the identifier
    ///      mints and opens.
    function test_Cc0_AnApprovedCc0LicenseMustNameThePinnedText() public {
        bytes32 typo = _storeText("CC0 1.0 Universal, with a typo", "text/plain");
        Work memory w = _work(artist, collectionId);
        w.item.license = License("CC0-1.0", typo);
        Work[] memory works = _one(w);
        bytes memory data = _mintData(_publish(works), works, 0);
        uint256 mintedBefore = stream.totalMinted();
        vm.expectRevert(IPackageRegistry.InvalidLicenseId.selector);
        auction.start(address(stream), data);
        assertEq(stream.totalMinted(), mintedBefore);

        Work memory v = _work(artist, collectionId);
        v.item.license = License("cc0-1.0", cc0TextFileId);
        works = _one(v);
        (, uint256 other) = _start(_publish(works), works, 0);
        _open(other, v);
        assertEq(_licenseOf(other).licenseTextFileId, cc0TextFileId);
        assertEq(WorksHashing.licenseKey(_licenseOf(other).licenseId), WorksHashing.CC0_LICENSE_KEY);
    }

    /// @dev A CC0 work's license text never changes: no relicense, with every party's consent
    ///      and the network's call, moves it to another text, before or after finalize.
    function test_Cc0_TheTextNeverChanges() public {
        bytes32 reserved = _storeText("All rights reserved. No reuse permitted.", "text/plain");
        Work memory kept = _work(artist, collectionId);
        Work[] memory works = _one(kept);
        uint256 tokenId = _sell(_publish(works), works, 0, collector, 1 ether);
        _open(tokenId, kept);
        _expectRelicenseRefused(_relicense(tokenId, kept, License("CC0-1.0", reserved)));
        _finalize(tokenId);
        _expectRelicenseRefused(_relicense(tokenId, kept, License("CC0-1.0", reserved)));
        _expectRelicenseRefused(_relicense(tokenId, kept, License("cc0-1.0", reserved)));
        _expectRelicenseRefused(_relicense(tokenId, kept, License("MIT", reserved)));
        assertEq(_licenseOf(tokenId).licenseTextFileId, cc0TextFileId);
    }

    /// @dev A work relicensed to CC0 from another license takes the deployment's CC0 text too.
    function test_Cc0_ARelicenseToCc0TakesThePinnedText() public {
        bytes32 byText = _storeText("Creative Commons Attribution 4.0 (fixture)", "text/plain");
        bytes32 other = _storeText("CC0, as the artist wrote it", "text/plain");
        Work memory w = _work(artist, collectionId);
        w.item.license = License("CC-BY-4.0", byText);
        Work[] memory works = _one(w);
        uint256 tokenId = _sell(_publish(works), works, 0, collector, 1 ether);
        _open(tokenId, w);
        _expectRelicenseRefused(_relicense(tokenId, w, License("CC0-1.0", other)));
        _asNetwork(address(rules), _relicense(tokenId, w, License("CC0-1.0", cc0TextFileId)));
        assertEq(
            WorksHashing.licenseKey(_licenseOf(tokenId).licenseId), WorksHashing.CC0_LICENSE_KEY
        );
        assertEq(_licenseOf(tokenId).licenseTextFileId, cc0TextFileId);
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
        bytes memory b = bytes(string.concat(s));
        for (uint256 i; i < bytes(head).length; ++i) {
            b[i] = bytes(head)[i];
        }
        return string(b);
    }

    /// @dev The CID part of `ipfs://<cid>` in upper case.
    function _upper(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(string.concat(s));
        for (uint256 i = 7; i < b.length; ++i) {
            if (b[i] >= "a" && b[i] <= "z") b[i] = bytes1(uint8(b[i]) - 32);
        }
        return string(b);
    }
}
