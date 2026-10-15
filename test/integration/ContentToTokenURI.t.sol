// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, Locator, LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { ContentAddresses as CA } from "../helpers/ContentAddresses.sol";
import { IntegrationBase } from "./IntegrationBase.sol";
import { UploaderGoldenData as Golden } from "../content/tooling/UploaderGoldenData.sol";

/// @notice Flow 3 (integration brief, lane B): content through to `tokenURI` on the real
///         contracts. The primary file is uploaded with the uploader tooling's golden calldata;
///         the work then goes through `attestBase64`, `openRecord`, `finalize` and `syncOnChain`,
///         and `tokenURI` is read in locator mode and inline mode. The gas matrix measures
///         `Stream.tokenURI` (the whole path: Stream, WorkRecords, the renderer, the store and
///         the statement log) for 32, 64, 128 and 256 KiB of base64-stored media and for
///         identity media, against the 8M budget.
contract ContentToTokenURIFlowTest is IntegrationBase {
    address internal artist;
    address internal collector = makeAddr("collector");

    function setUp() public override {
        super.setUp();
        artist = _actor("contentArtist");
    }

    /// @dev The golden "base64" PNG vector, uploaded with the tooling's own calldata.
    function _goldenWork() internal returns (Work memory w, Golden.Vector memory v) {
        v = Golden.samples()[2];
        assertEq(v.encoding, uint8(IContentStore.Encoding.Base64), "the base64 vector");
        (bool ok, bytes memory ret) = address(store).call(v.registerCalldata);
        assertTrue(ok, "golden registerManifest");
        assertEq(abi.decode(ret, (bytes32)), v.fileId, "golden file ID");
        (ok,) = address(store).call(v.writeCalldata[0]);
        assertTrue(ok, "golden writeChunk");
        assertTrue(store.isComplete(v.fileId));
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(v.fileId, v.mediaSha256, FileRole.PRIMARY);
        w.item = _item(artist, collectionId, v.mediaSha256, w.media, _record("Golden Work"));
    }

    function test_AttestOpenFinalizeSyncThenInline() public {
        (Work memory w, Golden.Vector memory v) = _goldenWork();
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        (uint256 saleId, uint256 tokenId) = _start(root, works, 0);
        _ethBid(saleId, collector, 1 ether);

        // Before the record is open: core-only metadata, never a revert.
        string memory uri = stream.tokenURI(tokenId);
        assertTrue(_contains(uri, '"record_status":"not_open"'), "core-only until open");
        assertTrue(_contains(uri, '"name":"Genesis %23'), "collection and serial name");

        // attestBase64 is permissionless and one-time.
        assertFalse(store.isBase64Attested(v.fileId));
        assertTrue(store.attestBase64(v.fileId), "one chunk: done in one call");
        assertTrue(store.isBase64Attested(v.fileId));

        // openRecord is permissionless and checks the committed media.
        vm.prank(collector);
        records.openRecord(tokenId, w.item, w.media);
        uri = stream.tokenURI(tokenId);
        assertFalse(_contains(uri, "record_status"), "the record renders");
        assertTrue(_contains(uri, '"name":"Golden Work"'));
        assertTrue(_contains(uri, '"license":"CC0-1.0"'));
        assertFalse(_contains(uri, "data:image/png;base64,"), "not inline before on-chain complete");

        // Locator mode: the artist and the platform register copies; the storage operator
        // chooses among them.
        vm.prank(artist);
        records.addLocator(tokenId, v.fileId, CA.ar("golden arweave"));
        vm.prank(platform);
        records.addLocator(tokenId, v.fileId, CA.ipfsLocator("golden ipfs"));
        assertTrue(
            _contains(
                stream.tokenURI(tokenId),
                string.concat('"image":"', CA.arweave("golden arweave"), '"')
            )
        );
        vm.prank(storageOperator);
        records.setPreferredKind(LocatorKind.IPFS);
        assertTrue(
            _contains(
                stream.tokenURI(tokenId), string.concat('"image":"', CA.ipfs("golden ipfs"), '"')
            )
        );

        // finalize pins the default renderer; the record must be complete on-chain.
        bytes32 state = records.workStateHash(tokenId);
        vm.prank(artist);
        records.finalize(tokenId, state);
        IWorkRecords.RecordInfo memory info = records.record(tokenId);
        assertTrue(info.finalized);
        assertEq(info.renderer, address(renderer), "pinned");
        assertEq(stream.rendererOf(tokenId), address(renderer));

        // syncOnChain: every media file is complete, so the work is on-chain complete and the
        // attested base64 text is inlined as stored.
        records.syncOnChain(tokenId);
        assertTrue(records.record(tokenId).onChainComplete);
        uri = stream.tokenURI(tokenId);
        assertTrue(
            _contains(uri, string.concat('"image":"data:image/png;base64,', string(v.stored), '"')),
            "inline: the stored base64 text"
        );
        assertTrue(_contains(renderer.fullTokenURI(address(stream), tokenId), string(v.stored)));

        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), collector);
        assertEq(stream.tokenURI(tokenId), uri, "settlement does not change the metadata");
    }

    /// @dev Without attestation a base64 file is never concatenated into the JSON: the renderer
    ///      serves its locator instead, even once the work is on-chain complete.
    function test_UnattestedBase64IsNotInlined() public {
        (Work memory w, Golden.Vector memory v) = _goldenWork();
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        (, uint256 tokenId) = _start(root, works, 0);
        records.openRecord(tokenId, w.item, w.media);
        records.syncOnChain(tokenId);
        vm.prank(artist);
        records.addLocator(tokenId, v.fileId, CA.ar("fallback"));
        string memory uri = stream.tokenURI(tokenId);
        assertFalse(_contains(uri, "base64,"), "not attested: not inlined");
        assertTrue(_contains(uri, string.concat('"image":"', CA.arweave("fallback"), '"')));
    }

    // ------------------------------------------------------------------ the gas matrix

    /// @dev Builds, sells and syncs one work per row, then measures `Stream.tokenURI` cold.
    function test_TokenURIGasMatrix() public {
        _tokenUriMatrix(artist, collector);
    }
}
