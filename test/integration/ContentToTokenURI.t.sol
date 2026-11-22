// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkDelivery } from "src/interfaces/IWorkDelivery.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { RecordFlowsBase } from "./RecordFlowsBase.sol";

/// @notice Content through to `tokenURI` on the real stack: a base64 primary uploaded chunk by
///         chunk, `attestComplete` (refused at a missing chunk), `markOnChainComplete` (refused
///         until every media file is complete), `attestBase64`, then `tokenURI` inline; and
///         locator mode through `WorkDelivery` (the artist's and the platform's copies, the
///         storage operator's preferences, a dead locator passed over, the artist's door closed
///         at finalize).
contract ContentToTokenURITest is RecordFlowsBase {
    address internal lead;
    address internal collector = makeAddr("contentCollector");
    address internal stranger = makeAddr("contentStranger");

    function setUp() public override {
        super.setUp();
        lead = _actor("contentLead");
    }

    /// @dev A base64 PNG primary of two chunks, registered, with only its first chunk written.
    function _halfUploaded() internal returns (Work memory w, bytes memory stored) {
        bytes memory png = _bytes(30_000, 0xC0);
        stored = bytes(Base64.encode(png));
        uint256 size = store.CHUNK_SIZE();
        assertGt(stored.length, size, "two chunks");
        bytes32 sha = sha256(png);
        bytes32 fileId = store.registerManifest(
            _chunkHashes(stored),
            stored.length,
            uint8(IContentStore.Encoding.Base64),
            "image/png",
            sha
        );
        store.writeChunk(_slice(stored, 0, size));
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(fileId, sha, uint8(FileRole.PRIMARY));
        w.item = _item(lead, collectionId, sha, w.media, _record("Base64 Work"));
    }

    // ------------------------------------------------------------------ before the record

    /// @dev Before the record opens: core-only metadata, never a revert; then the record renders.
    function test_Content_CoreOnlyUntilTheRecordOpens() public {
        Work[] memory works = _one(_work(lead, collectionId));
        (, uint256 tokenId) = _start(_publish(works), works, 0);
        string memory uri = stream.tokenURI(tokenId);
        assertTrue(_contains(uri, '"record_status":"not_open"'), "core-only until open");
        _open(tokenId, works[0]);
        uri = stream.tokenURI(tokenId);
        assertFalse(_contains(uri, "record_status"), "the record renders");
        assertTrue(_contains(uri, '"name":"Work '));
        assertTrue(_contains(uri, "CC0-1.0"));
    }

    // ------------------------------------------------------------------ on-chain to inline

    function test_Content_AttestCompleteMarkOnChainAttestBase64ThenInline() public {
        (Work memory w, bytes memory stored) = _halfUploaded();
        bytes32 fileId = w.media[0].fileId;
        Work[] memory works = _one(w);
        (uint256 saleId, uint256 tokenId) = _startAndOpen(_publish(works), works, 0);
        _ethBid(saleId, collector, 1 ether);

        string memory uri = stream.tokenURI(tokenId);
        assertTrue(_contains(uri, '"name":"Base64 Work"'));
        assertFalse(_contains(uri, '"image"'), "no copy anywhere yet");

        // Nothing is on-chain complete while a chunk is missing.
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.NotOnChainComplete.selector, address(stream), tokenId)
        );
        facts.markOnChainComplete(address(stream), tokenId);
        // The ranged completeness attestation keeps its place and stops at the missing chunk.
        assertFalse(store.attestComplete(fileId, 1));
        bytes32 missingHash = store.chunkHash(fileId, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IContentStore.ContentChunkMissing.selector, fileId, 1, missingHash
            )
        );
        store.attestComplete(fileId, 1);

        // Anyone writes the chunk; the attestation finishes, and the work is on-chain complete.
        uint256 size = store.CHUNK_SIZE();
        vm.prank(stranger);
        store.writeChunk(_slice(stored, size, size));
        vm.expectEmit(address(store));
        emit IContentStore.CompletenessAttested(fileId);
        assertTrue(store.attestComplete(fileId, 1));
        vm.expectEmit(address(facts));
        emit IWorkFacts.OnChainComplete(address(stream), tokenId);
        vm.prank(stranger);
        facts.markOnChainComplete(address(stream), tokenId);
        assertTrue(facts.factsOf(address(stream), tokenId).onChainComplete);
        // Again: a no-op.
        vm.recordLogs();
        facts.markOnChainComplete(address(stream), tokenId);
        assertEq(vm.getRecordedLogs().length, 0);

        // Base64 text is concatenated only once the store has checked it.
        assertFalse(_contains(stream.tokenURI(tokenId), "data:image/png;base64,"), "not attested");
        assertFalse(store.attestBase64(fileId, 1), "one chunk of two");
        assertTrue(store.attestBase64(fileId, 1));
        assertTrue(store.isBase64Attested(fileId));
        uri = stream.tokenURI(tokenId);
        assertTrue(
            _contains(
                uri, string.concat('"image":"data:image/png;base64,', string(_slice(stored, 0, 96)))
            ),
            "inline: the stored base64 text"
        );
        assertEq(bytes(uri).length > stored.length, true);

        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), collector);
        assertEq(stream.tokenURI(tokenId), uri, "settlement does not change the metadata");
    }

    /// @dev An unattested base64 primary is never inlined, even on-chain complete: its locator
    ///      serves instead.
    function test_Content_UnattestedBase64IsServedByItsLocator() public {
        (Work memory w, bytes memory stored) = _halfUploaded();
        uint256 size = store.CHUNK_SIZE();
        store.writeChunk(_slice(stored, size, size));
        Work[] memory works = _one(w);
        (, uint256 tokenId) = _startAndOpen(_publish(works), works, 0);
        facts.markOnChainComplete(address(stream), tokenId);
        vm.prank(lead);
        delivery.addLocator(address(stream), tokenId, w.media[0].fileId, CA.ar("fallback"));
        string memory uri = stream.tokenURI(tokenId);
        assertFalse(_contains(uri, "base64,"), "not attested: not inlined");
        assertTrue(_contains(uri, string.concat('"image":"', CA.arweave("fallback"), '"')));
    }

    // ------------------------------------------------------------------ locator mode

    function test_Content_LocatorModeThroughWorkDelivery() public {
        Work[] memory works = _one(_work(lead, collectionId));
        uint256 tokenId = _soldAndOpen(_publish(works), works, 0, collector, 1 ether);
        bytes32 fileId = works[0].media[0].fileId;
        assertEq(rules.delivery(), address(delivery));

        // The artist and the platform register copies; nobody else may.
        vm.prank(lead);
        delivery.addLocator(address(stream), tokenId, fileId, CA.ar("artist copy"));
        vm.prank(platform);
        delivery.addLocator(address(stream), tokenId, fileId, CA.ipfsLocator("platform copy"));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        delivery.addLocator(address(stream), tokenId, fileId, CA.ar("stranger copy"));
        // A URI that is not a canonical content address is refused.
        vm.prank(lead);
        vm.expectRevert(IWorkDelivery.InvalidLocator.selector);
        delivery.addLocator(
            address(stream), tokenId, fileId, Locator(LocatorKind.ARWEAVE, "ar://not-a-txid")
        );

        string memory arUri = CA.arweave("artist copy");
        string memory ipfsUri = CA.ipfs("platform copy");
        // The first live locator serves by default.
        assertTrue(_contains(stream.tokenURI(tokenId), string.concat('"image":"', arUri, '"')));
        // The storage operator's preferences: the token's kind, then a file's own pick.
        vm.prank(storageOperator);
        delivery.setPreferredKind(address(stream), LocatorKind.IPFS);
        assertTrue(_contains(stream.tokenURI(tokenId), string.concat('"image":"', ipfsUri, '"')));
        vm.prank(storageOperator);
        delivery.setFilePreference(address(stream), tokenId, fileId, 0);
        assertTrue(_contains(stream.tokenURI(tokenId), string.concat('"image":"', arUri, '"')));
        // A dead locator is never served, even when a preference names it.
        vm.prank(storageOperator);
        delivery.markLocatorDead(address(stream), tokenId, fileId, 0);
        assertTrue(_contains(stream.tokenURI(tokenId), string.concat('"image":"', ipfsUri, '"')));

        // After finalize the artist adds none; the platform still may.
        bytes32 state = _state(tokenId);
        vm.prank(lead);
        rules.finalize(address(stream), tokenId, state);
        vm.prank(lead);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, lead)
        );
        delivery.addLocator(address(stream), tokenId, fileId, CA.ar("late artist copy"));
        vm.prank(platform);
        delivery.addLocator(address(stream), tokenId, fileId, CA.ar("late platform copy"));
        assertEq(delivery.locators(address(stream), tokenId, fileId).length, 3);
    }
}
