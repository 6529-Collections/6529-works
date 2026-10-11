// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { ContentBase } from "./ContentBase.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { IContentStore } from "src/content/IContentStore.sol";
import { SSTORE2 } from "src/libraries/SSTORE2.sol";

/// @dev Uploads, manifests, completeness and failure modes of the content store.
contract ContentStoreTest is ContentBase {
    IContentStore.Encoding internal constant IDENTITY = IContentStore.Encoding.Identity;
    IContentStore.Encoding internal constant GZIP = IContentStore.Encoding.Gzip;

    function setUp() public {
        store = new ContentStore();
    }

    // ---------------------------------------------------------------- writeChunk

    function test_WriteChunk_StoresBytesAndEmits() public {
        bytes memory data = _data(1000, 1);
        bytes32 expectedHash = keccak256(data);
        address expectedPointer = SSTORE2.pointerOf(address(store), data);

        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.ChunkWritten(expectedHash, expectedPointer, 1000);
        (bytes32 hash, address pointer) = store.writeChunk(data);

        assertEq(hash, expectedHash);
        assertEq(pointer, expectedPointer);
        assertEq(store.chunkPointer(hash), pointer);
        assertEq(pointer.code, bytes.concat(hex"00", data), "STOP byte then data");
    }

    function test_WriteChunk_IsIdempotent() public {
        bytes memory data = _data(5000, 2);
        (, address first) = store.writeChunk(data);

        vm.recordLogs();
        (bytes32 hash, address second) = store.writeChunk(data);

        assertEq(second, first, "same pointer");
        assertEq(hash, keccak256(data));
        assertEq(vm.getRecordedLogs().length, 0, "no event on a repeat upload");
        // A repeat deploys nothing: the cost is a hash and a lookup.
        assertLt(_gasOf(abi.encodeCall(store.writeChunk, (data))), 20_000);
    }

    function test_WriteChunk_AcceptsMaxAndRejectsOneMore() public {
        store.writeChunk(_data(CHUNK, 3));
        vm.expectRevert(abi.encodeWithSelector(SSTORE2.SSTORE2ChunkTooLarge.selector, CHUNK + 1));
        store.writeChunk(_data(CHUNK + 1, 3));
    }

    function testFuzz_WriteChunk_RejectsOversize(uint256 length, uint256 seed) public {
        length = bound(length, CHUNK + 1, 3 * CHUNK);
        vm.expectRevert(abi.encodeWithSelector(SSTORE2.SSTORE2ChunkTooLarge.selector, length));
        store.writeChunk(_data(length, seed));
    }

    function testFuzz_WriteChunk_IsCallerIndependent(
        uint256 length,
        uint256 seed,
        address first,
        address second
    ) public {
        bytes memory data = _data(bound(length, 0, CHUNK), seed);
        vm.prank(first);
        (bytes32 hash, address pointer) = store.writeChunk(data);
        vm.prank(second);
        (, address again) = store.writeChunk(data);

        assertEq(pointer, SSTORE2.pointerOf(address(store), data));
        assertEq(again, pointer);
        assertEq(SSTORE2.readVerified(pointer, hash), data);
    }

    function test_NothingAcceptsValue() public {
        vm.deal(address(this), 2 ether);
        // The functions are non-payable (the compiler refuses `{value:}` on them), so value sent
        // through a raw call reverts, and there is no receive or fallback to take it either.
        (bool ok,) = address(store).call{ value: 1 }(abi.encodeCall(store.writeChunk, (hex"01")));
        assertFalse(ok, "writeChunk takes no value");
        (ok,) = address(store).call{ value: 1 }("");
        assertFalse(ok, "no receive or fallback");
        assertEq(address(store).balance, 0);
    }

    // ---------------------------------------------------------------- manifests

    function test_RegisterManifest_BeforeChunksExist() public {
        bytes memory file = _data(2 * CHUNK + 100, 4);
        (bytes[] memory chunks, bytes32[] memory hashes) = _split(file);
        bytes32 digest = sha256(file);
        bytes32 expectedId = store.manifestId(hashes, file.length, GZIP, "text/javascript", digest);

        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.ManifestRegistered(
            expectedId, file.length, 3, GZIP, digest, "text/javascript"
        );
        bytes32 fileId =
            store.registerManifest(hashes, file.length, GZIP, "text/javascript", digest);

        assertEq(fileId, expectedId);
        IContentStore.FileInfo memory info = store.fileInfo(fileId);
        assertEq(info.sha256Hash, digest);
        assertEq(info.length, file.length);
        assertEq(info.chunkCount, 3);
        assertTrue(info.encoding == GZIP);
        assertEq(info.mimeType, "text/javascript");
        assertEq(store.chunkHash(fileId, 1), hashes[1]);

        assertFalse(store.isComplete(fileId));
        assertEq(store.missingChunks(fileId).length, 3);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkMissing.selector, fileId, 0, hashes[0])
        );
        store.readChunk(fileId, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkMissing.selector, fileId, 0, hashes[0])
        );
        store.read(fileId, 0, 10);

        // The upload can be finished later, by anyone.
        vm.prank(makeAddr("collector"));
        _uploadAll(chunks);
        assertTrue(store.isComplete(fileId));
        assertEq(store.read(fileId, 0, file.length), file);
    }

    function test_RegisterManifest_AfterChunksExist() public {
        bytes memory file = _data(CHUNK + 1, 5);
        (bytes[] memory chunks, bytes32[] memory hashes) = _split(file);
        _uploadAll(chunks);
        bytes32 fileId = store.registerManifest(hashes, file.length, IDENTITY, HTML, sha256(file));
        assertTrue(store.isComplete(fileId), "complete on registration");
        assertEq(store.missingChunks(fileId).length, 0);
    }

    function test_RegisterManifest_IsIdempotent() public {
        bytes memory file = _data(CHUNK + 5, 6);
        (bytes32 first,,) = _declare(file, IDENTITY, HTML);
        vm.recordLogs();
        (bytes32 second,,) = _declare(file, IDENTITY, HTML);
        assertEq(second, first);
        assertEq(vm.getRecordedLogs().length, 0, "no event on a repeat registration");
    }

    function test_FileId_CommitsToWholeManifest() public {
        bytes memory file = _data(CHUNK + 5, 7);
        (bytes[] memory chunks, bytes32[] memory hashes) = _split(file);
        bytes32 digest = sha256(file);
        uint256 length = file.length;

        bytes32 honest = store.registerManifest(hashes, length, IDENTITY, HTML, digest);
        // Claims that differ in any field are different files, so none can overwrite another.
        bytes32 otherMime = store.registerManifest(hashes, length, IDENTITY, "text/plain", digest);
        bytes32 otherEncoding = store.registerManifest(hashes, length, GZIP, HTML, digest);
        bytes32 otherDigest = store.registerManifest(hashes, length, IDENTITY, HTML, DIGEST);
        bytes32 otherLength = store.registerManifest(hashes, length - 1, IDENTITY, HTML, digest);

        bytes32[5] memory ids = [honest, otherMime, otherEncoding, otherDigest, otherLength];
        for (uint256 i; i < 5; ++i) {
            for (uint256 j = i + 1; j < 5; ++j) {
                assertTrue(ids[i] != ids[j]);
            }
        }
        assertEq(store.fileInfo(honest).mimeType, HTML);
        assertEq(store.fileInfo(honest).sha256Hash, digest);

        // The documented formula, reproducible off-chain.
        assertEq(honest, keccak256(abi.encode(hashes, length, IDENTITY, HTML, digest)));
        // Chunks are shared: one upload serves every claim.
        _uploadAll(chunks);
        assertTrue(store.isComplete(honest));
        assertTrue(store.isComplete(otherMime));
    }

    function test_FileId_IsChainAndDeploymentIndependent() public {
        bytes memory file = _data(CHUNK + 5, 8);
        (, bytes32[] memory hashes) = _split(file);
        bytes32 id = store.manifestId(hashes, file.length, IDENTITY, HTML, sha256(file));

        vm.chainId(31_337 + 1);
        ContentStore other = new ContentStore();
        assertTrue(address(other) != address(store));
        assertEq(other.manifestId(hashes, file.length, IDENTITY, HTML, sha256(file)), id);
    }

    function test_RegisterManifest_ChunkCountBounds() public {
        bytes32[] memory none = new bytes32[](0);
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentChunkCountInvalid.selector, 0));
        store.registerManifest(none, 1, IDENTITY, HTML, DIGEST);

        uint256 max = store.MAX_CHUNKS();
        bytes32[] memory tooMany = new bytes32[](max + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkCountInvalid.selector, max + 1)
        );
        store.registerManifest(tooMany, max * CHUNK, IDENTITY, HTML, DIGEST);

        bytes32[] memory limit = new bytes32[](max);
        for (uint256 i; i < max; ++i) {
            limit[i] = bytes32(i + 1);
        }
        uint256 used = _gasOf(
            abi.encodeCall(store.registerManifest, (limit, max * CHUNK, IDENTITY, HTML, DIGEST))
        );
        console2.log("gas registerManifest, 1024 chunks (about 25 MB)", used);
        bytes32 fileId = store.manifestId(limit, max * CHUNK, IDENTITY, HTML, DIGEST);
        assertEq(store.fileInfo(fileId).chunkCount, max);
    }

    function test_RegisterManifest_LengthMustFitChunkCount() public {
        bytes32[] memory two = new bytes32[](2);
        two[0] = bytes32(uint256(1));
        two[1] = bytes32(uint256(2));
        // The last chunk may not be empty, and the count may not be exceeded.
        _expectBadLength(0, 2);
        store.registerManifest(two, 0, IDENTITY, HTML, DIGEST);
        _expectBadLength(CHUNK, 2);
        store.registerManifest(two, CHUNK, IDENTITY, HTML, DIGEST);
        _expectBadLength(2 * CHUNK + 1, 2);
        store.registerManifest(two, 2 * CHUNK + 1, IDENTITY, HTML, DIGEST);
        _expectBadLength(type(uint256).max, 2);
        store.registerManifest(two, type(uint256).max, IDENTITY, HTML, DIGEST);
        store.registerManifest(two, CHUNK + 1, IDENTITY, HTML, DIGEST);
        store.registerManifest(two, 2 * CHUNK, IDENTITY, HTML, DIGEST);
    }

    function testFuzz_RegisterManifest_LengthFitsIffInRange(uint256 count, uint256 length) public {
        count = bound(count, 1, 8);
        bytes32[] memory hashes = new bytes32[](count);
        bool fits = length > (count - 1) * CHUNK && length <= count * CHUNK;
        if (!fits) _expectBadLength(length, count);
        bytes32 fileId = store.registerManifest(hashes, length, IDENTITY, HTML, DIGEST);
        if (fits) assertEq(store.fileInfo(fileId).length, length);
    }

    function test_RegisterManifest_RejectsZeroDigestAndBadEncoding() public {
        bytes32[] memory one = new bytes32[](1);
        vm.expectRevert(IContentStore.ContentDigestMissing.selector);
        store.registerManifest(one, 10, IDENTITY, HTML, bytes32(0));

        // An encoding outside {Identity, Gzip} cannot be decoded, so the call fails.
        (bool ok,) = address(store)
            .call(
                abi.encodeWithSelector(
                    IContentStore.registerManifest.selector, one, 10, uint256(2), HTML, DIGEST
                )
            );
        assertFalse(ok);
    }

    function test_RegisterManifest_MimeValidation() public {
        bytes32[] memory one = new bytes32[](1);
        string[10] memory bad = [
            "",
            "ab",
            "text",
            "/html",
            "text/",
            "text/html/x",
            "Text/html",
            "text/html; charset=utf-8",
            "text/ht ml",
            "text/h\"tml"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IContentStore.ContentMimeInvalid.selector);
            store.registerManifest(one, 10, IDENTITY, bad[i], DIGEST);
        }
        // 65 bytes is one too many; 64 is the limit.
        vm.expectRevert(IContentStore.ContentMimeInvalid.selector);
        store.registerManifest(one, 10, IDENTITY, string.concat("a/", _repeat("b", 63)), DIGEST);
        store.registerManifest(one, 10, IDENTITY, string.concat("a/", _repeat("b", 62)), DIGEST);

        string[6] memory good = [
            "a/b",
            "text/html",
            "image/svg+xml",
            "application/vnd.api+json",
            "font/woff2",
            "model/gltf-binary"
        ];
        for (uint256 i; i < good.length; ++i) {
            bytes32 id = store.registerManifest(one, 10, IDENTITY, good[i], DIGEST);
            assertEq(store.fileInfo(id).mimeType, good[i]);
        }
    }

    function testFuzz_RegisterManifest_RejectsMimeWithForbiddenByte(uint8 bad, uint8 position)
        public
    {
        // Every byte outside [a-z0-9+._-/] is refused wherever it sits.
        bytes memory allowed = "abcdefghijklmnopqrstuvwxyz0123456789+._-/";
        for (uint256 i; i < allowed.length; ++i) {
            vm.assume(bad != uint8(allowed[i]));
        }
        bytes memory mime = "text/html";
        mime[position % mime.length] = bytes1(bad);
        bytes32[] memory one = new bytes32[](1);
        vm.expectRevert(IContentStore.ContentMimeInvalid.selector);
        store.registerManifest(one, 10, IDENTITY, string(mime), DIGEST);
    }

    // ---------------------------------------------------------------- uploads

    function test_OutOfOrderUploads_CompleteTheFile() public {
        bytes memory file = _data(3 * CHUNK - 7, 9);
        (bytes32 fileId, bytes[] memory chunks, bytes32[] memory hashes) =
            _declare(file, IDENTITY, "image/png");

        store.writeChunk(chunks[2]); // last chunk first
        _assertMissing(fileId, 0, 2);

        store.writeChunk(chunks[0]);
        _assertMissing(fileId, 1, 1);
        assertFalse(store.isComplete(fileId));
        // A range that stays inside present chunks reads fine; one touching chunk 1 reverts.
        assertEq(store.read(fileId, 10, 20), _slice(file, 10, 20));
        assertEq(store.read(fileId, 2 * CHUNK + 1, 5), _slice(file, 2 * CHUNK + 1, 5));
        bytes memory missingChunkError = abi.encodeWithSelector(
            IContentStore.ContentChunkMissing.selector, fileId, 1, hashes[1]
        );
        vm.expectRevert(missingChunkError);
        store.read(fileId, CHUNK - 5, 10);
        vm.expectRevert(missingChunkError);
        store.read(fileId, 0, file.length);
        vm.expectRevert(missingChunkError);
        store.readChunk(fileId, 1);

        store.writeChunk(chunks[1]);
        assertTrue(store.isComplete(fileId));
        assertEq(store.missingChunks(fileId).length, 0);
        assertEq(store.read(fileId, 0, file.length), file);
    }

    function test_SharedChunksServeEveryFileThatListsThem() public {
        bytes memory head = _data(CHUNK, 10);
        bytes memory tail = _data(100, 11);
        bytes memory longFile = bytes.concat(head, tail);
        (bytes32 longId,, bytes32[] memory longHashes) = _declare(longFile, IDENTITY, HTML);
        (bytes32 shortId,,) = _declare(head, IDENTITY, "text/plain");

        store.writeChunk(head);
        assertTrue(store.isComplete(shortId));
        assertFalse(store.isComplete(longId));
        _assertMissing(longId, 1, 1);
        assertEq(store.chunkHash(longId, 0), longHashes[0]);
        store.writeChunk(tail);
        assertTrue(store.isComplete(longId));
    }

    function test_WrongLengthChunkNeverCompletesOrReads() public {
        // Layout rule: all chunks but the last are exactly CHUNK bytes. This manifest lists a
        // short first chunk, so it can never read as a coherent file.
        bytes memory shortChunk = _data(100, 12);
        bytes memory tail = _data(10, 13);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256(shortChunk);
        hashes[1] = keccak256(tail);
        bytes32 fileId = store.registerManifest(hashes, CHUNK + 10, IDENTITY, HTML, DIGEST);
        store.writeChunk(shortChunk);
        store.writeChunk(tail);

        assertFalse(store.isComplete(fileId));
        _assertMissing(fileId, 0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IContentStore.ContentChunkLengthMismatch.selector, fileId, 0, CHUNK, 100
            )
        );
        store.readChunk(fileId, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IContentStore.ContentChunkLengthMismatch.selector, fileId, 0, CHUNK, 100
            )
        );
        store.read(fileId, 0, 5);
    }

    function test_ReadsDetectTamperedChunkCode() public {
        bytes memory file = _data(500, 14);
        bytes32 fileId = _publish(file, IDENTITY, HTML);
        address pointer = store.chunkPointer(keccak256(file));
        // Not reachable on a real chain (CREATE2 code cannot change); proves reads re-check.
        vm.etch(pointer, bytes.concat(hex"00", _data(500, 15)));
        vm.expectRevert(abi.encodeWithSelector(SSTORE2.SSTORE2HashMismatch.selector, pointer));
        store.readChunk(fileId, 0);
        vm.expectRevert(abi.encodeWithSelector(SSTORE2.SSTORE2HashMismatch.selector, pointer));
        store.read(fileId, 0, 1);
    }

    // ---------------------------------------------------------------- unknown files

    function test_UnknownFileRevertsEverywhere() public {
        bytes32 id = keccak256("nothing here");
        bytes memory err = abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, id);
        vm.expectRevert(err);
        store.fileInfo(id);
        vm.expectRevert(err);
        store.isComplete(id);
        vm.expectRevert(err);
        store.missingChunks(id);
        vm.expectRevert(err);
        store.chunkHash(id, 0);
        vm.expectRevert(err);
        store.readChunk(id, 0);
        vm.expectRevert(err);
        store.read(id, 0, 0);
    }

    function test_ChunkIndexOutOfBoundsReverts() public {
        bytes32 fileId = _publish(_data(CHUNK + 1, 16), IDENTITY, HTML);
        bytes memory err =
            abi.encodeWithSelector(IContentStore.ContentChunkIndexOutOfBounds.selector, fileId, 2);
        vm.expectRevert(err);
        store.chunkHash(fileId, 2);
        vm.expectRevert(err);
        store.readChunk(fileId, 2);
        assertEq(store.readChunk(fileId, 1).length, 1);
    }

    function testFuzz_RoundTrip(uint256 length, uint256 seed) public {
        // 0 to 3 chunks and a bit: every boundary case of the layout is reachable.
        length = bound(length, 1, 3 * CHUNK + 50);
        bytes memory file = _data(length, seed);
        bytes32 fileId = _publish(file, IDENTITY, HTML);
        assertTrue(store.isComplete(fileId));
        assertEq(store.fileInfo(fileId).chunkCount, (length + CHUNK - 1) / CHUNK);
        assertEq(store.read(fileId, 0, length), file);
    }

    // ---------------------------------------------------------------- helpers

    function _expectBadLength(uint256 length, uint256 count) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentLengthInvalid.selector, length, count)
        );
    }

    function _assertMissing(bytes32 fileId, uint256 first, uint256 count) internal view {
        uint256[] memory missing = store.missingChunks(fileId);
        assertEq(missing.length, count, "missing count");
        assertEq(missing[0], first, "first missing");
    }

    function _repeat(string memory unit, uint256 times) internal pure returns (string memory out) {
        for (uint256 i; i < times; ++i) {
            out = string.concat(out, unit);
        }
    }
}

/// @dev Range reads against a fixed fixture of three chunks (the last one partial).
contract ContentStoreRangeTest is ContentBase {
    bytes internal file;
    bytes32 internal fileId;

    function setUp() public {
        store = new ContentStore();
        file = _data(2 * CHUNK + 1234, 20);
        fileId = _publish(file, IContentStore.Encoding.Identity, HTML);
    }

    function test_Read_AcrossChunkBoundaries() public view {
        uint256 total = file.length;
        uint256[2][12] memory cases = [
            [uint256(0), total], // whole file
            [uint256(0), 0], // empty at the start
            [total, uint256(0)], // empty at the end
            [CHUNK - 1, uint256(2)], // straddles the first boundary
            [CHUNK - 1, uint256(1)], // last byte of chunk 0
            [CHUNK, uint256(1)], // first byte of chunk 1
            [CHUNK, CHUNK], // exactly chunk 1
            [CHUNK - 5, CHUNK + 10], // chunk 0 tail, all of chunk 1, chunk 2 head
            [2 * CHUNK - 1, uint256(2)], // straddles the second boundary
            [2 * CHUNK, uint256(1234)], // exactly the last chunk
            [total - 1, uint256(1)], // final byte
            [uint256(1), total - 1] // everything but the first byte
        ];
        for (uint256 i; i < cases.length; ++i) {
            bytes memory got = store.read(fileId, cases[i][0], cases[i][1]);
            assertEq(got, _slice(file, cases[i][0], cases[i][1]), "range");
        }
    }

    function test_Read_ChunksMatchFixture() public view {
        assertEq(store.readChunk(fileId, 0), _slice(file, 0, CHUNK));
        assertEq(store.readChunk(fileId, 1), _slice(file, CHUNK, CHUNK));
        assertEq(store.readChunk(fileId, 2), _slice(file, 2 * CHUNK, 1234));
    }

    function testFuzz_Read_MatchesReference(uint256 offset, uint256 length) public view {
        offset = bound(offset, 0, file.length);
        length = bound(length, 0, file.length - offset);
        assertEq(store.read(fileId, offset, length), _slice(file, offset, length));
    }

    function testFuzz_Read_OutOfBoundsReverts(uint256 offset, uint256 length) public {
        uint256 total = file.length;
        vm.assume(offset > total || length > total - offset);
        vm.expectRevert(
            abi.encodeWithSelector(
                IContentStore.ContentRangeOutOfBounds.selector, offset, length, total
            )
        );
        store.read(fileId, offset, length);
    }

    function test_Read_OneByteOutOfBounds() public {
        uint256 total = file.length;
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentRangeOutOfBounds.selector, total, 1, total)
        );
        store.read(fileId, total, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IContentStore.ContentRangeOutOfBounds.selector, 0, total + 1, total
            )
        );
        store.read(fileId, 0, total + 1);
    }
}

/// @dev Gas measurements for the numbers quoted in the README. Ceilings are loose regression
///      guards; the logged figures are the reference (`forge test --match-contract Gas -vv`).
contract ContentStoreGasTest is ContentBase {
    function setUp() public {
        store = new ContentStore();
    }

    function test_Gas_WriteMaxChunk() public {
        uint256 used = _gasOf(abi.encodeCall(store.writeChunk, (_data(CHUNK, 30))));
        console2.log("gas writeChunk, 24,575 bytes", used);
        assertLt(used, 5_400_000);
    }

    function test_Gas_Read100KB() public {
        uint256 length = 100 * 1024;
        (bytes[] memory chunks, bytes32[] memory hashes) = _split(_data(length, 31));
        uint256 declared = _gasOf(
            abi.encodeCall(
                store.registerManifest,
                (hashes, length, IContentStore.Encoding.Identity, HTML, DIGEST)
            )
        );
        console2.log("gas registerManifest, 100 KB (5 chunks)", declared);
        bytes32 fileId =
            store.manifestId(hashes, length, IContentStore.Encoding.Identity, HTML, DIGEST);
        _uploadAll(chunks);
        uint256 used = _gasOf(abi.encodeCall(store.read, (fileId, 0, length)));
        console2.log("gas read, 100 KB (5 chunks)", used);
        assertLt(used, 1_000_000);
    }

    /// @dev 256 KB is the planned `tokenURI` inline threshold (ADR 0001 §8).
    function test_Gas_Read256KB() public {
        uint256 length = 256 * 1024;
        bytes32 fileId = _publish(_data(length, 33), IContentStore.Encoding.Identity, HTML);
        uint256 used = _gasOf(abi.encodeCall(store.read, (fileId, 0, length)));
        console2.log("gas read, 256 KB (11 chunks)", used);
        assertLt(used, 1_500_000);
        used = _gasOf(abi.encodeCall(store.readChunk, (fileId, 3)));
        console2.log("gas readChunk, one full chunk", used);
        assertLt(used, 150_000);
    }

    function test_Gas_Read1MB() public {
        uint256 length = 1024 * 1024;
        (bytes[] memory chunks, bytes32[] memory hashes) = _split(_data(length, 32));
        uint256 declared = _gasOf(
            abi.encodeCall(
                store.registerManifest,
                (hashes, length, IContentStore.Encoding.Identity, HTML, DIGEST)
            )
        );
        console2.log("gas registerManifest, 1 MB (43 chunks)", declared);
        bytes32 fileId =
            store.manifestId(hashes, length, IContentStore.Encoding.Identity, HTML, DIGEST);
        _uploadAll(chunks);

        console2.log("gas isComplete, 1 MB", _gasOf(abi.encodeCall(store.isComplete, (fileId))));

        uint256 used = _gasOf(abi.encodeCall(store.read, (fileId, 0, length)));
        console2.log("gas read, 1 MB (43 chunks)", used);
        // The returned bytes are ABI-encoded into a second buffer, so the memory (and its quadratic
        // cost) is twice the file size. Callers that only need a part should read a range.
        assertLt(used, 10_000_000);

        used = _gasOf(abi.encodeCall(store.read, (fileId, 500_000, 100)));
        console2.log("gas read, 100 bytes inside one chunk", used);
    }
}
