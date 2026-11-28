// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStatementLog, Role, Statement } from "src/interfaces/IStatementLog.sol";
import { Facts } from "src/interfaces/core/CoreTypes.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { HashRef } from "src/interfaces/types/HashRef.sol";
import { ReplayBase } from "./ReplayBase.sol";

/// @notice A real work end to end on the deployed stack: the 6529 Network Museum's record of Vera
///         Molnár and Martin Grasser, *Themes and Variations #210* (6529NM-W-0029), at a pinned
///         Museum commit (`test/fixtures/real/museum-work.json`, written by `tools/make_vectors.py`
///         from the Museum's own CC0 records). Its record goes into the content store with the
///         uploader's layout, its display image is registered by the digests the Museum's file
///         gives, the work is minted through a curated sale, its record opened in
///         `StreamWorkFacts6529` and finalized through the rules module, and `tokenURI` shows the
///         record; a curator's catalogue statement cites the Museum record by its own envelope
///         digest. Every ID and hash is checked against the value Python computed independently,
///         and every permanent contract's indexer replays the whole run.
contract RealVectorsTest is ReplayBase {
    string internal constant PATH = "test/fixtures/real/museum-work.json";
    bytes32 internal constant ENTRY_DOMAIN = keccak256("6529.works.StatementLog.entry.v1");

    string internal json;
    address internal artist;
    address internal collector = makeAddr("museumCollector");

    function setUp() public override {
        super.setUp();
        json = vm.readFile(PATH);
        artist = _actor("museumWorkArtist");
    }

    /// @dev The record file, uploaded as one `Identity` chunk, has the file ID, SHA-256 and chunk
    ///      hash the uploader's rules give (WS-51).
    function _uploadRecord() internal returns (bytes32 fileId) {
        bytes memory record = vm.parseJsonBytes(json, ".record.bytes");
        assertEq(record.length, vm.parseJsonUint(json, ".record.length"), "record length");
        assertEq(sha256(record), vm.parseJsonBytes32(json, ".record.sha256"), "record sha256");
        bytes32[] memory chunks = vm.parseJsonBytes32Array(json, ".record.chunkHashes");
        assertEq(chunks.length, 1, "one chunk");
        assertEq(keccak256(record), chunks[0], "record chunk hash");
        assertEq(keccak256(bytes(vm.parseJsonString(json, ".record.json"))), keccak256(record));
        fileId = _storeText(record, vm.parseJsonString(json, ".record.mimeType"));
        assertEq(fileId, vm.parseJsonBytes32(json, ".record.fileId"), "record file ID");
        assertTrue(store.isComplete(fileId));
    }

    /// @dev The display image's manifest, registered from the Museum file's digests (its bytes
    ///      stay off-chain, the default): the same file ID as Python's.
    function _registerMedia() internal returns (bytes32 fileId, bytes32 sha) {
        bytes32[] memory chunks = vm.parseJsonBytes32Array(json, ".media.chunkHashes");
        uint256 length = vm.parseJsonUint(json, ".media.length");
        sha = vm.parseJsonBytes32(json, ".media.sha256");
        string memory mime = vm.parseJsonString(json, ".media.mimeType");
        assertEq(chunks.length, (length + store.CHUNK_SIZE() - 1) / store.CHUNK_SIZE(), "chunks");
        fileId = store.registerManifest(
            chunks, length, uint8(IContentStore.Encoding.Identity), mime, sha
        );
        assertEq(fileId, vm.parseJsonBytes32(json, ".media.fileId"), "media file ID");
        assertEq(store.sha256Of(fileId), sha, "media sha256");
        assertFalse(store.isComplete(fileId), "off-chain until uploaded");
    }

    function test_RealVectors_MuseumWorkMintsOpensFinalizesAndRenders() public {
        bytes32 recordId = _uploadRecord();
        (bytes32 mediaId, bytes32 sha) = _registerMedia();
        Work memory w;
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(mediaId, sha, uint8(FileRole.PRIMARY));
        w.item = _item(artist, collectionId, sha, w.media, recordId);
        Work[] memory works = _one(w);
        bytes32 root = _publish(works);
        uint256 tokenId = _sell(root, works, 0, collector, 1 ether);
        _open(tokenId, w);
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        vm.prank(artist);
        rules.finalize(address(stream), tokenId, state);

        Facts memory f = facts.factsOf(address(stream), tokenId);
        assertEq(f.recordFileId, recordId, "the Museum record");
        assertTrue(f.finalized, "finalized");
        assertEq(f.renderer, address(renderer), "the renderer pinned");
        assertEq(f.media[0].fileId, mediaId, "the Museum image");
        assertEq(store.sha256Of(f.media[0].fileId), sha, "the Museum image's digest");
        assertGt(stream.workOf(tokenId).royaltyRate, 0);
        string memory uri = stream.tokenURI(tokenId);
        string[] memory fragments = vm.parseJsonStringArray(json, ".tokenUriFragments");
        assertEq(fragments.length, 6);
        for (uint256 i; i < fragments.length; ++i) {
            assertTrue(_contains(uri, fragments[i]), string.concat("tokenURI lacks ", fragments[i]));
        }
        _sync();
    }

    /// @dev A curator's catalogue entry about the Museum subject, citing the Museum record by its
    ///      own envelope digest (keccak256 of the canonical payload, checked by the generator).
    ///      The entry hash the log emits is rebuilt from the event's fields and Python's
    ///      statement hash, so the generator and the contract hash the same statement.
    function test_RealVectors_CatalogueStatementMatchesTheGoldenHash() public {
        Statement memory s = Statement(
            address(0),
            uint256(vm.parseJsonBytes32(json, ".museumRecord.subjectId")),
            vm.parseJsonBytes32(json, ".statement.kind"),
            vm.parseJsonBytes32(json, ".statement.schema"),
            HashRef(
                // forge-lint: disable-next-line(unsafe-typecast)
                uint16(vm.parseJsonUint(json, ".statement.contentAlgorithm")),
                vm.parseJsonBytes32(json, ".statement.contentDigest")
            ),
            vm.parseJsonString(json, ".statement.uri"),
            bytes32(0),
            bytes32(0)
        );
        assertEq(s.content.digest, vm.parseJsonBytes32(json, ".museumRecord.contentDigest"));
        _sync();
        vm.prank(curator);
        bytes32 entryHash = statements.appendCurator(s);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 subjectKey = keccak256(abi.encode(s.token, s.id));
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IStatementLog.StatementAppended.selector) continue;
            assertEq(logs[i].topics[1], subjectKey, "subject key");
            (Role role, address resolver, uint64 index, uint64 recordedAt, bytes32 logged,,) = abi.decode(
                logs[i].data, (Role, address, uint64, uint64, bytes32, bytes32, Statement)
            );
            bytes32 golden = keccak256(
                abi.encode(
                    ENTRY_DOMAIN,
                    block.chainid,
                    address(statements),
                    subjectKey,
                    index,
                    uint8(role),
                    curator,
                    resolver,
                    recordedAt,
                    vm.parseJsonBytes32(json, ".statement.statementHash")
                )
            );
            assertEq(logged, golden, "entry hash from the golden statement hash");
            assertEq(entryHash, golden);
            found = true;
        }
        assertTrue(found, "no StatementAppended");
        (uint64 count,) = statements.chainOf(address(0), s.id);
        assertEq(count, 1);
        // The statement log's indexer recomputes the same entry hash from the log.
        _apply(logs);
        statementsIdx.assertMatches();
    }
}
