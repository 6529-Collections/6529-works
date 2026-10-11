// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { ContentBase } from "./ContentBase.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { SSTORE2 } from "src/libraries/SSTORE2.sol";

/// @dev The store's selectors typed so the compiler lets a test send value to `writeChunk` and an
///      out-of-range encoding (an enum is `uint8` in the ABI, so the selectors match).
interface IUncheckedStore {
    function writeChunk(bytes calldata data) external payable returns (bytes32, address);
    function registerManifest(
        bytes32[] calldata chunkHashes,
        uint256 length,
        uint8 encoding,
        string calldata mimeType,
        bytes32 sha256Hash
    ) external returns (bytes32);
}

/// @dev Uploads, manifests, completeness and failure modes of the content store.
contract ContentStoreTest is ContentBase {
    IContentStore.Encoding internal constant IDENTITY = IContentStore.Encoding.Identity;
    IContentStore.Encoding internal constant GZIP = IContentStore.Encoding.Gzip;
    IContentStore.Encoding internal constant BASE64 = IContentStore.Encoding.Base64;
    IContentStore.Encoding internal constant GZIP_BASE64 = IContentStore.Encoding.GzipBase64;

    /// @dev EIP-7825 (Fusaka): no transaction may use more gas than this.
    uint256 internal constant TX_GAS_CAP = 16_777_216;

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
        vm.deal(address(this), 3 ether);
        // Non-payable functions and no receive or fallback: value is refused every way it can
        // arrive.
        vm.expectRevert();
        IUncheckedStore(address(store)).writeChunk{ value: 1 }(hex"01");
        vm.expectRevert();
        payable(address(store)).transfer(1);
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

        // Claims that differ in any field are different files, so none can overwrite another.
        bytes32[8] memory ids = [
            store.registerManifest(hashes, length, IDENTITY, HTML, digest),
            store.registerManifest(hashes, length, IDENTITY, "text/plain", digest),
            store.registerManifest(hashes, length, GZIP, HTML, digest),
            store.registerManifest(hashes, length, BASE64, HTML, digest),
            store.registerManifest(hashes, length, GZIP_BASE64, HTML, digest),
            store.registerManifest(hashes, length, IDENTITY, HTML, DIGEST),
            store.registerManifest(hashes, length - 1, IDENTITY, HTML, digest),
            store.registerManifest(hashes, length + 1, IDENTITY, HTML, digest)
        ];
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j = i + 1; j < ids.length; ++j) {
                assertTrue(ids[i] != ids[j]);
            }
        }
        assertEq(store.fileInfo(ids[0]).mimeType, HTML);
        assertEq(store.fileInfo(ids[0]).sha256Hash, digest);
        assertTrue(store.fileInfo(ids[3]).encoding == BASE64);
        assertTrue(store.fileInfo(ids[4]).encoding == GZIP_BASE64);

        // The documented formula, reproducible off-chain (the encoding is its uint8 value).
        assertEq(ids[0], keccak256(abi.encode(hashes, length, IDENTITY, HTML, digest)));
        assertEq(ids[4], keccak256(abi.encode(hashes, length, uint8(3), HTML, digest)));

        // Chunks are shared: one upload serves every claim whose layout fits the chunks, and
        // each of those reads exactly the stored bytes, with exactly the declared length.
        _uploadAll(chunks);
        for (uint256 i; i < 6; ++i) {
            assertTrue(store.isComplete(ids[i]));
            bytes memory got = store.read(ids[i], 0, length);
            assertEq(got.length, length, "returned length");
            assertEq(got, file);
        }

        // A claim that is one byte too short or too long does not fit the honest chunks: it can
        // never complete, and reads revert instead of returning truncated or padded bytes.
        bytes32[2] memory misfits = [ids[6], ids[7]];
        uint256[2] memory expected = [length - 1 - CHUNK, length + 1 - CHUNK];
        for (uint256 i; i < 2; ++i) {
            assertFalse(store.isComplete(misfits[i]));
            _assertMissing(misfits[i], 1, 1);
            bytes memory mismatch = abi.encodeWithSelector(
                IContentStore.ContentChunkLengthMismatch.selector, misfits[i], 1, expected[i], 5
            );
            vm.expectRevert(mismatch);
            store.readChunk(misfits[i], 1);
            vm.expectRevert(mismatch);
            store.read(misfits[i], 0, i == 0 ? length - 1 : length + 1);
            // The first chunk is fine, and is returned in full and exactly.
            assertEq(store.read(misfits[i], 0, CHUNK), _slice(file, 0, CHUNK));
        }
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

    function test_Constants_ArePinned() public view {
        // File IDs and uploaded chunks are permanent, so these must never drift.
        assertEq(CHUNK, 24_575);
        assertEq(store.CHUNK_SIZE(), 24_575);
        assertEq(store.MAX_CHUNKS(), 512);
        assertEq(store.MAX_MIME_LENGTH(), 64);
        // Encoding values are part of every file ID.
        assertEq(uint8(IContentStore.Encoding.Identity), 0);
        assertEq(uint8(IContentStore.Encoding.Gzip), 1);
        assertEq(uint8(IContentStore.Encoding.Base64), 2);
        assertEq(uint8(IContentStore.Encoding.GzipBase64), 3);
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
        store.registerManifest(tooMany, (max + 1) * CHUNK, IDENTITY, HTML, DIGEST);

        bytes32[] memory limit = new bytes32[](max);
        for (uint256 i; i < max; ++i) {
            limit[i] = bytes32(i + 1);
        }
        bytes32 fileId = store.registerManifest(limit, max * CHUNK, IDENTITY, HTML, DIGEST);
        assertEq(store.fileInfo(fileId).chunkCount, max);
        assertEq(store.fileInfo(fileId).length, max * CHUNK);
    }

    /// @dev EIP-7825 caps every transaction at 16,777,216 gas. A manifest at `MAX_CHUNKS`, with
    ///      the longest MIME type, fresh storage for every chunk hash and incompressible hashes,
    ///      must fit with room to spare: execution, plus 21,000, plus calldata at 16 gas per
    ///      non-zero byte and 4 per zero byte.
    function test_RegisterManifest_AtMaxChunksFitsTheTransactionGasCap() public {
        uint256 max = store.MAX_CHUNKS();
        bytes32[] memory limit = new bytes32[](max);
        for (uint256 i; i < max; ++i) {
            limit[i] = keccak256(abi.encode("chunk", i));
        }
        string memory longestMime = string.concat("a/", _repeat("b", store.MAX_MIME_LENGTH() - 2));
        assertEq(bytes(longestMime).length, store.MAX_MIME_LENGTH());
        bytes memory callData = abi.encodeCall(
            store.registerManifest, (limit, max * CHUNK, GZIP_BASE64, longestMime, sha256("x"))
        );

        uint256 execution = _gasOf(callData);
        uint256 txGas = 21_000 + _calldataGas(callData) + execution;
        console2.log("registerManifest at MAX_CHUNKS: execution", execution);
        console2.log("registerManifest at MAX_CHUNKS: transaction gas", txGas);
        assertLe(txGas, TX_GAS_CAP, "fits the EIP-7825 cap");
        assertLe(txGas, TX_GAS_CAP * 3 / 4, "keeps a quarter of the cap as margin");
        bytes32 fileId = store.manifestId(limit, max * CHUNK, GZIP_BASE64, longestMime, sha256("x"));
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

    function test_RegisterManifest_RejectsZeroDigest() public {
        bytes32[] memory one = new bytes32[](1);
        vm.expectRevert(IContentStore.ContentDigestMissing.selector);
        store.registerManifest(one, 10, IDENTITY, HTML, bytes32(0));
    }

    function test_RegisterManifest_AcceptsExactlyTheFourEncodings() public {
        bytes32[] memory one = new bytes32[](1);
        for (uint8 e; e < 4; ++e) {
            bytes32 id = IUncheckedStore(address(store)).registerManifest(one, 10, e, HTML, DIGEST);
            assertEq(uint8(store.fileInfo(id).encoding), e);
        }
    }

    function testFuzz_RegisterManifest_RejectsUnknownEncoding(uint8 encoding) public {
        encoding = uint8(bound(encoding, 4, type(uint8).max));
        bytes32[] memory one = new bytes32[](1);
        // An encoding outside the enum cannot be decoded, so the call reverts.
        vm.expectRevert();
        IUncheckedStore(address(store)).registerManifest(one, 10, encoding, HTML, DIGEST);
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

    function test_OverLongFinalChunkNeverCompletesOrReads() public {
        // The honest chunks of a CHUNK + 100 byte file, registered with a declared length one
        // byte short: the final chunk is one byte longer than the layout allows.
        bytes memory file = _data(CHUNK + 100, 40);
        (bytes[] memory chunks, bytes32[] memory hashes) = _split(file);
        bytes32 fileId =
            store.registerManifest(hashes, file.length - 1, IDENTITY, HTML, sha256(file));
        _uploadAll(chunks);

        assertFalse(store.isComplete(fileId));
        _assertMissing(fileId, 1, 1); // exactly [1]
        bytes memory mismatch = abi.encodeWithSelector(
            IContentStore.ContentChunkLengthMismatch.selector, fileId, 1, 99, 100
        );
        vm.expectRevert(mismatch);
        store.readChunk(fileId, 1);
        vm.expectRevert(mismatch);
        store.read(fileId, CHUNK, 5);
        vm.expectRevert(mismatch);
        store.read(fileId, 0, file.length - 1);
        // The intact chunk is unaffected and comes back exactly as asked.
        assertEq(store.read(fileId, 0, CHUNK), _slice(file, 0, CHUNK));
        assertEq(store.readChunk(fileId, 0), chunks[0]);
    }

    function test_ZeroChunkHashIsAcceptedButNeverCompletes() public {
        // A zero hash is keccak256 of nothing that exists, so no chunk can ever satisfy it:
        // the manifest is inert, fails closed, and the registry would refuse it.
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256(_data(CHUNK, 41));
        bytes32 fileId = store.registerManifest(hashes, CHUNK + 5, IDENTITY, HTML, DIGEST);
        store.writeChunk(_data(CHUNK, 41));

        assertFalse(store.isComplete(fileId));
        _assertMissing(fileId, 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IContentStore.ContentChunkMissing.selector, fileId, 1, bytes32(0)
            )
        );
        store.readChunk(fileId, 1);
        // The satisfiable chunk still reads.
        assertEq(store.readChunk(fileId, 0), _data(CHUNK, 41));
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
///      Fixtures are built in `setUp`, a separate transaction, so every measured call starts
///      cold: the store, its storage and the chunk contracts are all first touches, as in a fresh
///      `eth_call`. Execution gas only, unless a test says it adds calldata and the 21,000 base.
contract ContentStoreGasTest is ContentBase {
    IContentStore.Encoding internal constant IDENTITY = IContentStore.Encoding.Identity;
    uint256 internal constant LEN_100K = 100 * 1024;
    uint256 internal constant LEN_256K = 256 * 1024;
    uint256 internal constant LEN_1M = 1024 * 1024;

    bytes32 internal id100k;
    bytes32 internal id256k;
    bytes32 internal id1m;

    function setUp() public {
        store = new ContentStore();
        id100k = _publish(_data(LEN_100K, 31), IDENTITY, HTML);
        id256k = _publish(_data(LEN_256K, 33), IDENTITY, HTML);
        id1m = _publish(_data(LEN_1M, 32), IDENTITY, HTML);
    }

    /// @dev Upload cost per MB: execution plus calldata (incompressible bytes, 16 gas each)
    ///      plus the 21,000 base, per chunk. At 1 gwei, gas / 1e9 is ETH.
    function test_Gas_WriteMaxChunk() public {
        bytes memory callData = abi.encodeCall(store.writeChunk, (_data(CHUNK, 30)));
        uint256 execution = _gasOf(callData);
        uint256 txGas = 21_000 + _calldataGas(callData) + execution;
        uint256 perMB = txGas * LEN_1M / CHUNK;
        console2.log("gas writeChunk, 24,575 bytes, execution", execution);
        console2.log("gas writeChunk, 24,575 bytes, transaction", txGas);
        console2.log("gas per MB uploaded, transaction", perMB);
        assertLt(execution, 5_400_000);
        // About 0.23 ETH per MB at 1 gwei.
        assertGt(perMB, 225_000_000);
        assertLt(perMB, 240_000_000);
    }

    function test_Gas_WriteChunkAlreadyStored() public {
        // The first chunk of the 100 KB fixture from `setUp`, uploaded again.
        (bytes[] memory chunks,) = _split(_data(LEN_100K, 31));
        uint256 used = _gasOf(abi.encodeCall(store.writeChunk, (chunks[0])));
        console2.log("gas writeChunk, bytes already stored", used);
        assertLt(used, 40_000);
    }

    function test_Gas_RegisterManifest100KB() public {
        (, bytes32[] memory hashes) = _split(_data(LEN_100K, 34));
        uint256 used = _gasOf(
            abi.encodeCall(store.registerManifest, (hashes, LEN_100K, IDENTITY, HTML, DIGEST))
        );
        console2.log("gas registerManifest, 100 KB (5 chunks)", used);
        assertLt(used, 300_000);
    }

    function test_Gas_RegisterManifest1MB() public {
        (, bytes32[] memory hashes) = _split(_data(LEN_1M, 35));
        uint256 used = _gasOf(
            abi.encodeCall(store.registerManifest, (hashes, LEN_1M, IDENTITY, HTML, DIGEST))
        );
        console2.log("gas registerManifest, 1 MB (43 chunks)", used);
        assertLt(used, 1_300_000);
    }

    function test_Gas_Read100KB() public {
        uint256 used = _gasOf(abi.encodeCall(store.read, (id100k, 0, LEN_100K)));
        console2.log("gas read, 100 KB (5 chunks)", used);
        assertLt(used, 1_000_000);
    }

    /// @dev 256 KB is the planned `tokenURI` inline threshold (ADR 0001 section 8).
    function test_Gas_Read256KB() public {
        uint256 used = _gasOf(abi.encodeCall(store.read, (id256k, 0, LEN_256K)));
        console2.log("gas read, 256 KB (11 chunks)", used);
        assertLt(used, 1_500_000);
    }

    function test_Gas_ReadOneChunk() public {
        uint256 used = _gasOf(abi.encodeCall(store.readChunk, (id256k, 3)));
        console2.log("gas readChunk, one full chunk", used);
        assertLt(used, 150_000);
    }

    function test_Gas_ReadInsideOneChunk() public {
        uint256 used = _gasOf(abi.encodeCall(store.read, (id1m, 500_000, 100)));
        console2.log("gas read, 100 bytes inside one chunk", used);
        assertLt(used, 100_000);
    }

    function test_Gas_IsComplete1MB() public {
        uint256 used = _gasOf(abi.encodeCall(store.isComplete, (id1m)));
        console2.log("gas isComplete, 1 MB (43 chunks)", used);
        assertLt(used, 500_000);
    }

    function test_Gas_Read1MB() public {
        uint256 used = _gasOf(abi.encodeCall(store.read, (id1m, 0, LEN_1M)));
        console2.log("gas read, 1 MB (43 chunks)", used);
        // The returned bytes are ABI-encoded into a second buffer, so the memory (and its quadratic
        // cost) is twice the file size. Callers that only need a part should read a range.
        assertLt(used, 10_000_000);
    }
}
