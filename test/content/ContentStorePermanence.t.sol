// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { ContentBase } from "./ContentBase.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { IChunkStore } from "src/interfaces/IChunkStore.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { SSTORE2 } from "src/libraries/SSTORE2.sol";

/// @dev Helpers for linked chunks and list manifests.
abstract contract PermanenceBase is ContentBase {
    uint8 internal constant IDENTITY = uint8(IContentStore.Encoding.Identity);
    uint256 internal constant PER_LIST = CHUNK / 32; // 767 hashes, the most per list chunk
    /// @dev EIP-7825 (Fusaka): no transaction may use more gas than this.
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    /// @dev Writes `chunk` as parts cut at `size` bytes and returns their hashes.
    function _writeParts(bytes memory chunk, uint256 size)
        internal
        returns (bytes32[] memory parts)
    {
        uint256 n = (chunk.length + size - 1) / size;
        parts = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            uint256 start = i * size;
            uint256 len = chunk.length - start < size ? chunk.length - start : size;
            (parts[i],) = store.writeChunk(_slice(chunk, start, len));
        }
    }

    function _fakeHashes(uint256 count, uint256 seed) internal pure returns (bytes32[] memory h) {
        h = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            h[i] = keccak256(abi.encode("chunk", seed, i));
        }
    }
}

/// @dev Linked chunks: a full chunk assembled from smaller stored parts is the same chunk.
contract ContentStoreLinkTest is PermanenceBase {
    function setUp() public {
        store = new ContentStore();
    }

    function test_Link_IsTheSameChunkAsAWholeWrite() public {
        bytes memory file = _data(2 * CHUNK + 300, 1);
        (bytes32 fileId, bytes[] memory chunks, bytes32[] memory hashes) =
            _declare(file, IDENTITY, HTML);
        // Chunk 0 from three 8,192-byte parts, chunk 1 written whole, the tail linked from two.
        bytes32[] memory parts = _writeParts(chunks[0], 8192);
        assertEq(parts.length, 3);
        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.ChunkLinked(hashes[0], parts, CHUNK);
        assertEq(store.linkChunk(parts), hashes[0], "keyed by the hash of the bytes");
        store.writeChunk(chunks[1]);
        assertFalse(store.isComplete(fileId));
        assertEq(store.firstMissing(fileId, 0, 3, address(store)), 2);
        assertEq(store.linkChunk(_writeParts(chunks[2], 150)), hashes[2]);

        assertTrue(store.isComplete(fileId));
        assertEq(store.missingChunks(fileId).length, 0);
        assertEq(store.chunkPointer(hashes[0]), address(0), "a linked chunk has no pointer");
        assertEq(store.readChunk(fileId, 0), chunks[0]);
        assertEq(store.chunkData(hashes[0]), chunks[0]);
        assertEq(store.read(fileId, 0, file.length), file);
        // Ranges that cross part and chunk boundaries.
        assertEq(store.read(fileId, 8190, 10), _slice(file, 8190, 10));
        assertEq(store.read(fileId, CHUNK - 3, 6), _slice(file, CHUNK - 3, 6));
        assertEq(store.read(fileId, 2 * CHUNK + 149, 2), _slice(file, 2 * CHUNK + 149, 2));

        // A second store holding every chunk whole gives the same file ID and the same bytes.
        ContentStore whole = new ContentStore();
        bytes32 wholeId = whole.registerManifest(hashes, file.length, IDENTITY, HTML, sha256(file));
        for (uint256 i; i < chunks.length; ++i) {
            whole.writeChunk(chunks[i]);
        }
        assertEq(wholeId, fileId);
        assertEq(whole.read(wholeId, 0, file.length), store.read(fileId, 0, file.length));
    }

    function testFuzz_Link_AnySplitGivesTheSameChunk(uint256 length, uint256 seed, uint8 cuts)
        public
    {
        length = bound(length, 1, CHUNK);
        bytes memory chunk = _data(length, seed);
        uint256 n = bound(cuts, 1, length < 8 ? length : 8);
        // Cut points from the seed, strictly increasing, so no part is empty.
        bytes32[] memory parts = new bytes32[](n);
        uint256 start;
        for (uint256 i; i < n; ++i) {
            uint256 room = length - start - (n - 1 - i);
            uint256 len =
                i + 1 == n ? length - start : 1 + uint256(keccak256(abi.encode(seed, i))) % room;
            (parts[i],) = store.writeChunk(_slice(chunk, start, len));
            start += len;
        }
        bytes32 hash = store.linkChunk(parts);
        assertEq(hash, keccak256(chunk));
        assertEq(store.chunkData(hash), chunk);
    }

    function test_Link_IsANoOpWhenTheChunkIsHeldWhole() public {
        bytes memory chunk = _data(CHUNK, 2);
        (bytes32 hash, address pointer) = store.writeChunk(chunk);
        bytes32[] memory parts = _writeParts(chunk, 10_000);
        vm.recordLogs();
        assertEq(store.linkChunk(parts), hash);
        assertEq(vm.getRecordedLogs().length, 0, "no link recorded");
        assertEq(store.chunkPointer(hash), pointer, "the whole copy stays the pointer");
        assertEq(store.chunkData(hash), chunk);
    }

    function test_Link_AWholeWriteAfterALinkServesTheSameBytes() public {
        bytes memory chunk = _data(CHUNK, 3);
        bytes32 hash = store.linkChunk(_writeParts(chunk, 5000));
        (bytes32 written, address pointer) = store.writeChunk(chunk);
        assertEq(written, hash);
        assertTrue(pointer != address(0));
        assertEq(store.chunkData(hash), chunk);
    }

    /// @dev `maxParts`: zero while a chunk is missing, the largest part count of a linked chunk,
    ///      and only falling: a link from fewer parts, then a whole write, lower it, whoever
    ///      makes them; a link from more parts never raises it.
    function test_MaxParts_TheLargestLinkAndOnlyFalling() public {
        bytes memory file = _data(2 * CHUNK + 50, 9);
        (bytes32 fileId, bytes[] memory chunks,) = _declare(file, IDENTITY, HTML);
        store.writeChunk(chunks[0]);
        assertEq(store.maxParts(fileId), 0, "incomplete");
        store.linkChunk(_writeParts(chunks[1], 6200)); // 4 parts
        store.linkChunk(_writeParts(chunks[2], 10)); // 5 parts
        assertEq(store.maxParts(fileId), 5);
        vm.prank(makeAddr("anyone"));
        store.linkChunk(_writeParts(chunks[2], 25)); // 2 parts replace 5
        assertEq(store.maxParts(fileId), 4);
        store.linkChunk(_writeParts(chunks[1], 100)); // more parts: no change
        assertEq(store.maxParts(fileId), 4);
        vm.prank(makeAddr("anyone"));
        store.writeChunk(chunks[1]);
        store.writeChunk(chunks[2]);
        assertEq(store.maxParts(fileId), 1, "every chunk whole");
        assertTrue(store.isComplete(fileId));
    }

    /// @dev A link from fewer parts replaces a longer one (cheaper reads, same bytes); a link
    ///      from as many parts or more changes nothing.
    function test_Link_OnlyFewerPartsReplaceALink() public {
        bytes memory chunk = _data(CHUNK, 4);
        bytes32[] memory four = _writeParts(chunk, 6200);
        bytes32[] memory two = _writeParts(chunk, 12_300);
        bytes32[] memory three = _writeParts(chunk, 8200);
        assertEq(four.length, 4);
        assertEq(two.length, 2);
        assertEq(three.length, 3);
        bytes32 hash = store.linkChunk(four);

        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.ChunkLinked(hash, two, CHUNK);
        store.linkChunk(two);
        assertEq(store.chunkData(hash), chunk);

        vm.recordLogs();
        store.linkChunk(three);
        store.linkChunk(two);
        assertEq(vm.getRecordedLogs().length, 0, "as many or more parts: no-op");
        assertEq(store.chunkData(hash), chunk);
    }

    function test_Link_Reverts() public {
        bytes32[] memory none = new bytes32[](0);
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentPartCountInvalid.selector, 0));
        store.linkChunk(none);

        bytes32[] memory tooMany = new bytes32[](257);
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentPartCountInvalid.selector, 257));
        store.linkChunk(tooMany);

        bytes32[] memory unknown = new bytes32[](1);
        unknown[0] = keccak256("never written");
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkUnknown.selector, unknown[0])
        );
        store.linkChunk(unknown);

        // One byte over a chunk.
        bytes32[] memory over = new bytes32[](2);
        (over[0],) = store.writeChunk(_data(CHUNK, 5));
        (over[1],) = store.writeChunk(hex"01");
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentLinkTooLong.selector, CHUNK + 1)
        );
        store.linkChunk(over);

        // A linked chunk is not a part: parts are whole chunks only.
        bytes32 linked = store.linkChunk(_writeParts(_data(300, 6), 100));
        bytes32[] memory nested = new bytes32[](2);
        nested[0] = linked;
        nested[1] = over[1];
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentChunkUnknown.selector, linked));
        store.linkChunk(nested);
    }

    /// @dev The part bound: 256 parts of 96 bytes (the last 95) make a full chunk, and its read
    ///      stays a bounded view.
    function test_Link_MaxPartsBuildAFullChunk() public {
        bytes memory chunk = _data(CHUNK, 7);
        bytes32[] memory parts = _writeParts(chunk, 96);
        assertEq(parts.length, store.MAX_PARTS());
        bytes32 hash = store.linkChunk(parts);
        bytes32[] memory one = new bytes32[](1);
        one[0] = hash;
        bytes32 fileId = store.registerManifest(one, CHUNK, IDENTITY, HTML, DIGEST);
        assertTrue(store.isComplete(fileId));
        assertEq(store.readChunk(fileId, 0), chunk);
    }

    /// @dev A linked chunk that breaks the layout rule never counts, like a whole one.
    function test_Link_WrongLengthNeverCompletes() public {
        bytes memory short = _data(100, 8);
        bytes32 hash = store.linkChunk(_writeParts(short, 30));
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = hash;
        (hashes[1],) = store.writeChunk(hex"0102");
        bytes32 fileId = store.registerManifest(hashes, CHUNK + 2, IDENTITY, HTML, DIGEST);
        assertFalse(store.isComplete(fileId));
        assertEq(store.firstMissing(fileId, 0, 2, address(store)), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IContentStore.ContentChunkLengthMismatch.selector, fileId, 0, CHUNK, 100
            )
        );
        store.readChunk(fileId, 0);
    }

    /// @dev Reads re-check a linked chunk's hash (part code cannot change on a real chain; the
    ///      etch proves the check exists).
    function test_Link_ReadsDetectTamperedParts() public {
        bytes memory chunk = _data(1000, 9);
        bytes32[] memory parts = _writeParts(chunk, 400);
        bytes32 hash = store.linkChunk(parts);
        address part = store.chunkPointer(parts[1]);
        vm.etch(part, bytes.concat(hex"00", _data(400, 10)));
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentLinkedChunkCorrupt.selector, hash)
        );
        store.chunkData(hash);
        // A part that shrank leaves the buffer short: still refused.
        vm.etch(part, bytes.concat(hex"00", _slice(chunk, 400, 399)));
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentLinkedChunkCorrupt.selector, hash)
        );
        store.chunkData(hash);
    }

    function test_ChunkData_RevertsForAnUnknownChunk() public {
        bytes32 hash = keccak256("nothing");
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentChunkUnknown.selector, hash));
        store.chunkData(hash);
    }

    /// @dev The store's whole index can be rebuilt from its logs alone: every write, link and
    ///      registration carries what it recorded.
    function test_EveryWriteEmitsWhatItRecorded() public {
        bytes memory chunk = _data(500, 11);
        bytes memory head = _slice(chunk, 0, 200);
        bytes32[] memory parts = new bytes32[](2);
        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.ChunkWritten(
            keccak256(head), SSTORE2.pointerOf(address(store), head), 200
        );
        (parts[0],) = store.writeChunk(head);
        (parts[1],) = store.writeChunk(_slice(chunk, 200, 300));
        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.ChunkLinked(keccak256(chunk), parts, 500);
        bytes32 hash = store.linkChunk(parts);
        bytes32[] memory one = new bytes32[](1);
        one[0] = hash;
        bytes32[] memory lists = _writeList(one, 1);
        bytes32 id = store.manifestId(one, 500, 9, "a/b", DIGEST);
        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.ManifestRegistered(id, 500, 9, 0, DIGEST, "a/b", one);
        store.registerManifestList(lists, 1, 500, 9, "a/b", DIGEST, 0);
    }
}

/// @dev Manifests registered from list chunks, digest kinds, and the ranged completeness check.
contract ContentStoreListTest is PermanenceBase {
    function setUp() public {
        store = new ContentStore();
    }

    function test_List_GivesTheSameFileAsOneCall() public {
        bytes memory file = _data(4 * CHUNK + 77, 20);
        (bytes[] memory chunks, bytes32[] memory hashes) = _split(file);
        bytes32 digest = sha256(file);
        bytes32[] memory lists = _writeList(hashes, 2); // 2, 2 and 1 hashes
        assertEq(lists.length, 3);
        bytes32 expected = store.manifestId(hashes, file.length, IDENTITY, HTML, digest);

        vm.expectEmit(true, false, false, true, address(store));
        emit IContentStore.ManifestRegistered(
            expected, file.length, IDENTITY, 0, digest, HTML, hashes
        );
        bytes32 fileId =
            store.registerManifestList(lists, 2, file.length, IDENTITY, HTML, digest, 0);
        assertEq(fileId, expected);

        IContentStore.FileInfo memory info = store.fileInfo(fileId);
        assertEq(info.chunkCount, 5);
        assertEq(info.length, file.length);
        assertEq(info.sha256Hash, digest);
        assertEq(store.sha256Of(fileId), digest);
        for (uint256 i; i < hashes.length; ++i) {
            assertEq(store.chunkHash(fileId, i), hashes[i]);
        }
        assertEq(store.firstMissing(fileId, 0, 5, address(store)), 0);
        _uploadAll(chunks);
        assertTrue(store.isComplete(fileId));
        assertEq(store.read(fileId, 0, file.length), file);

        // The one-call registration of the same manifest is the same file: a no-op.
        vm.recordLogs();
        assertEq(store.registerManifest(hashes, file.length, IDENTITY, HTML, digest), fileId);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_List_AfterOneCallIsANoOp() public {
        bytes32[] memory hashes = _fakeHashes(3, 1);
        bytes32 fileId = store.registerManifest(hashes, 3 * CHUNK, IDENTITY, HTML, DIGEST);
        bytes32[] memory lists = _writeList(hashes, 3);
        vm.recordLogs();
        assertEq(store.registerManifestList(lists, 3, 3 * CHUNK, IDENTITY, HTML, DIGEST, 0), fileId);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testFuzz_List_AnyStrideGivesTheSameFileId(uint256 count, uint256 per, uint256 seed)
        public
    {
        count = bound(count, 1, 40);
        per = bound(per, 1, PER_LIST);
        bytes32[] memory hashes = _fakeHashes(count, seed);
        uint256 length = (count - 1) * CHUNK + 1 + seed % CHUNK;
        bytes32 fileId = store.registerManifestList(
            _writeList(hashes, per), per, length, IDENTITY, HTML, DIGEST, 0
        );
        assertEq(fileId, store.manifestId(hashes, length, IDENTITY, HTML, DIGEST));
        for (uint256 i; i < count; ++i) {
            assertEq(store.chunkHash(fileId, i), hashes[i]);
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                IContentStore.ContentChunkIndexOutOfBounds.selector, fileId, count
            )
        );
        store.chunkHash(fileId, count);
    }

    function test_List_Reverts() public {
        bytes32[] memory hashes = _fakeHashes(5, 2);
        bytes32[] memory lists = _writeList(hashes, 2);
        bytes32[] memory none = new bytes32[](0);
        bytes memory listInvalid0 =
            abi.encodeWithSelector(IContentStore.ContentListInvalid.selector, 0);
        vm.expectRevert(listInvalid0);
        store.registerManifestList(lists, 0, 5 * CHUNK, IDENTITY, HTML, DIGEST, 0);
        vm.expectRevert(listInvalid0);
        store.registerManifestList(lists, PER_LIST + 1, 5 * CHUNK, IDENTITY, HTML, DIGEST, 0);
        vm.expectRevert(listInvalid0);
        store.registerManifestList(none, 2, 5 * CHUNK, IDENTITY, HTML, DIGEST, 0);
        // A stride that does not match the list chunks: the first (2 hashes) is not 3.
        vm.expectRevert(listInvalid0);
        store.registerManifestList(lists, 3, 5 * CHUNK, IDENTITY, HTML, DIGEST, 0);
        // A middle list chunk that is short.
        bytes32[] memory shortMiddle = new bytes32[](2);
        (shortMiddle[0],) = store.writeChunk(_packed(hashes, 0, 1));
        shortMiddle[1] = lists[1];
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentListInvalid.selector, 0));
        store.registerManifestList(shortMiddle, 2, 3 * CHUNK, IDENTITY, HTML, DIGEST, 0);
        // A last list chunk that is not whole hashes, or longer than the stride.
        bytes32[] memory badLast = new bytes32[](2);
        badLast[0] = lists[0];
        (badLast[1],) = store.writeChunk(_data(33, 3));
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentListInvalid.selector, 1));
        store.registerManifestList(badLast, 2, 3 * CHUNK, IDENTITY, HTML, DIGEST, 0);
        (badLast[1],) = store.writeChunk(_packed(hashes, 0, 3));
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentListInvalid.selector, 1));
        store.registerManifestList(badLast, 2, 5 * CHUNK, IDENTITY, HTML, DIGEST, 0);
        // Unknown list chunk, and the checks every manifest passes.
        bytes32[] memory unknown = new bytes32[](1);
        unknown[0] = keccak256("no list");
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkUnknown.selector, unknown[0])
        );
        store.registerManifestList(unknown, 2, CHUNK, IDENTITY, HTML, DIGEST, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentLengthInvalid.selector, 4 * CHUNK, 5)
        );
        store.registerManifestList(lists, 2, 4 * CHUNK, IDENTITY, HTML, DIGEST, 0);
        vm.expectRevert(IContentStore.ContentDigestMissing.selector);
        store.registerManifestList(lists, 2, 5 * CHUNK, IDENTITY, HTML, bytes32(0), 0);
        vm.expectRevert(IContentStore.ContentMimeInvalid.selector);
        store.registerManifestList(lists, 2, 5 * CHUNK, IDENTITY, "HTML", DIGEST, 0);
    }

    /// @dev More list chunks than `MAX_CHUNKS` hashes could fill (every list but the last full,
    ///      the last not empty) are refused before any is read or anything is allocated: here
    ///      one valid 32-byte list chunk repeated 4,097 times with a stride of one.
    function test_List_RefusesTooManyListsBeforeReadingThem() public {
        uint256 max = store.MAX_CHUNKS();
        bytes32[] memory hashes = _fakeHashes(1, 6);
        (bytes32 one,) = store.writeChunk(_packed(hashes, 0, 1));
        bytes32[] memory lists = new bytes32[](max + 1);
        for (uint256 i; i < lists.length; ++i) {
            lists[i] = one;
        }
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentListInvalid.selector, 0));
        store.registerManifestList(lists, 1, (max + 1) * CHUNK, IDENTITY, HTML, DIGEST, 0);
        // At the bound the same lists register: 4,096 chunks of one hash each.
        assembly ("memory-safe") {
            mstore(lists, max)
        }
        bytes32 fileId =
            store.registerManifestList(lists, 1, max * CHUNK, IDENTITY, HTML, DIGEST, 0);
        assertEq(store.fileInfo(fileId).chunkCount, max);
    }

    /// @dev A partly filled last list chunk: hashes in it are read at their place, and the file
    ///      reads whole, chunk by chunk (7 chunks with a stride of 3: lists of 3, 3 and 1).
    function test_List_APartlyFilledLastListChunk() public {
        bytes memory file = _data(6 * CHUNK + 5, 22);
        (bytes[] memory chunks, bytes32[] memory hashes) = _split(file);
        bytes32[] memory lists = _writeList(hashes, 3);
        assertEq(lists.length, 3);
        assertEq(SSTORE2.size(store.chunkPointer(lists[2])), 32, "one hash in the last list");
        bytes32 fileId =
            store.registerManifestList(lists, 3, file.length, IDENTITY, HTML, sha256(file), 0);
        assertEq(fileId, store.manifestId(hashes, file.length, IDENTITY, HTML, sha256(file)));
        _uploadAll(chunks);
        for (uint256 i; i < 7; ++i) {
            assertEq(store.chunkHash(fileId, i), hashes[i]);
            assertEq(store.readChunk(fileId, i), chunks[i]);
        }
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkIndexOutOfBounds.selector, fileId, 7)
        );
        store.readChunk(fileId, 7);
        assertEq(
            store.read(fileId, 5 * CHUNK + 3, CHUNK + 2), _slice(file, 5 * CHUNK + 3, CHUNK + 2)
        );
    }

    function test_List_RefusesMoreThanMaxChunksBeforeCopying() public {
        uint256 max = store.MAX_CHUNKS();
        bytes32[] memory hashes = _fakeHashes(max + 1, 4);
        bytes32[] memory lists = _writeList(hashes, PER_LIST);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkCountInvalid.selector, max + 1)
        );
        store.registerManifestList(lists, PER_LIST, (max + 1) * CHUNK, IDENTITY, HTML, DIGEST, 0);
    }

    /// @dev Digest kinds are open ids. Kind 0 is SHA-256 and keeps the original file ID formula;
    ///      any other kind is recorded, appended to the ID's preimage, and refused by `sha256Of`.
    function testFuzz_List_DigestKinds(uint8 kind) public {
        bytes32[] memory hashes = _fakeHashes(2, 5);
        bytes32[] memory lists = _writeList(hashes, PER_LIST);
        bytes32 fileId =
            store.registerManifestList(lists, PER_LIST, 2 * CHUNK, 7, HTML, DIGEST, kind);
        IContentStore.FileInfo memory info = store.fileInfo(fileId);
        assertEq(info.digestKind, kind);
        assertEq(info.encoding, 7);
        assertEq(info.sha256Hash, DIGEST);
        if (kind == 0) {
            assertEq(fileId, store.manifestId(hashes, 2 * CHUNK, 7, HTML, DIGEST));
            assertEq(store.sha256Of(fileId), DIGEST);
        } else {
            assertEq(
                fileId,
                keccak256(
                    abi.encode(hashes, uint256(2 * CHUNK), uint256(7), HTML, DIGEST, uint256(kind))
                )
            );
            assertTrue(fileId != store.manifestId(hashes, 2 * CHUNK, 7, HTML, DIGEST));
            vm.expectRevert(
                abi.encodeWithSelector(IContentStore.ContentDigestNotSha256.selector, fileId, kind)
            );
            store.sha256Of(fileId);
        }
    }

    /// @dev `firstMissing` checks a caller-chosen range, caps `to` at the chunk count, and walks
    ///      a whole file in pieces with a cursor.
    function test_FirstMissing_RangesAndCursor() public {
        bytes memory file = _data(6 * CHUNK + 1, 21);
        (bytes32 fileId, bytes[] memory chunks,) = _declare(file, IDENTITY, HTML);
        for (uint256 i; i < chunks.length; ++i) {
            if (i != 4) store.writeChunk(chunks[i]);
        }
        assertEq(store.firstMissing(fileId, 0, 4, address(store)), 4, "all of [0, 4)");
        assertEq(store.firstMissing(fileId, 0, 7, address(store)), 4);
        assertEq(store.firstMissing(fileId, 5, 100, address(store)), 7, "to is capped");
        assertEq(store.firstMissing(fileId, 3, 3, address(store)), 3, "empty range");
        store.writeChunk(chunks[4]);
        uint256 cursor;
        uint256 calls;
        while (cursor < 7) {
            uint256 to = cursor + 2;
            assertEq(store.firstMissing(fileId, cursor, to, address(store)), to < 7 ? to : 7);
            cursor = to;
            ++calls;
        }
        assertEq(calls, 4);
    }
}

/// @dev Another chunk store as a source: `firstMissing` checks what it serves against the
///      manifest, chunk by chunk, and never trusts it.
contract MockChunkStore is IChunkStore {
    mapping(bytes32 => bytes) internal _data;
    mapping(bytes32 => bool) internal _held;
    uint256 public burn;
    bool public bomb;

    function setBomb(bool on) external {
        bomb = on;
    }

    function put(bytes32 hash, bytes memory data) external {
        _data[hash] = data;
        _held[hash] = true;
    }

    function setBurn(uint256 iterations) external {
        burn = iterations;
    }

    function chunkData(bytes32 chunkHash) external view returns (bytes memory) {
        uint256 x;
        for (uint256 i; i < burn; ++i) {
            x = uint256(keccak256(abi.encode(x, i)));
        }
        if (bomb) {
            assembly ("memory-safe") {
                return(0, 0x100000)
            }
        }
        if (!_held[chunkHash]) revert IContentStore.ContentChunkUnknown(chunkHash);
        return _data[chunkHash];
    }
}

contract ContentStoreSourceTest is PermanenceBase {
    bytes internal file;
    bytes32 internal fileId;
    bytes[] internal chunks;
    bytes32[] internal hashes;

    function setUp() public {
        store = new ContentStore();
        file = _data(3 * CHUNK + 10, 30);
        (fileId, chunks, hashes) = _declare(file, IDENTITY, HTML);
    }

    function test_Source_AnotherContentStoreServesTheFile() public {
        ContentStore other = new ContentStore();
        for (uint256 i; i < chunks.length; ++i) {
            other.writeChunk(chunks[i]);
        }
        assertEq(store.firstMissing(fileId, 0, 4, address(other)), 4);
        assertFalse(store.isComplete(fileId), "this store still lacks them");
        // A source that refuses a chunk (here, one it lacks) does not serve it.
        ContentStore someChunks = new ContentStore();
        someChunks.writeChunk(chunks[0]);
        assertEq(store.firstMissing(fileId, 0, 4, address(someChunks)), 1);
        assertEq(store.firstMissing(fileId, 0, 1, address(someChunks)), 1);
    }

    function test_Source_WrongBytesAreFoundNotTrusted() public {
        MockChunkStore mock = new MockChunkStore();
        for (uint256 i; i < chunks.length; ++i) {
            mock.put(hashes[i], chunks[i]);
        }
        assertEq(store.firstMissing(fileId, 0, 4, address(mock)), 4);
        mock.put(hashes[2], _data(CHUNK, 99)); // other bytes under the hash
        assertEq(store.firstMissing(fileId, 0, 4, address(mock)), 2);
        mock.put(hashes[2], _slice(chunks[2], 0, CHUNK - 1)); // a prefix
        assertEq(store.firstMissing(fileId, 0, 4, address(mock)), 2);
        mock.put(hashes[2], bytes.concat(chunks[2], hex"00")); // one byte too many
        assertEq(store.firstMissing(fileId, 0, 4, address(mock)), 2);
        mock.put(hashes[2], chunks[2]);
        assertEq(store.firstMissing(fileId, 2, 4, address(mock)), 4);
    }

    /// @dev The store copies at most one chunk's ABI encoding of a source's answer: a source
    ///      that answers with a megabyte serves nothing, and the check costs the copy of no more
    ///      than that bound (without the bound it would copy the whole answer).
    function test_Source_AnOversizedAnswerIsNotServedAndNotCopied() public {
        MockChunkStore mock = new MockChunkStore();
        mock.setBomb(true);
        uint256 before = gasleft();
        assertEq(store.firstMissing(fileId, 0, 4, address(mock)), 0, "not served");
        uint256 used = before - gasleft();
        assertLt(used, 3_000_000, "the megabyte was never copied");
    }

    /// @dev Gas rule: the source gets all available gas. A source that burns 2x, 4x or 10x its
    ///      base cost still gets the right answer, and a caller that runs it out of gas gets a
    ///      revert, never an index that would read as "missing" or "present".
    function test_Source_ForwardsAllGasAndNeverAnswersOnShortfall() public {
        MockChunkStore mock = new MockChunkStore();
        for (uint256 i; i < chunks.length; ++i) {
            mock.put(hashes[i], chunks[i]);
        }
        uint256 base = 200;
        uint256[3] memory factors = [uint256(2), 4, 10];
        for (uint256 f; f < factors.length; ++f) {
            mock.setBurn(base * factors[f]);
            assertEq(store.firstMissing(fileId, 0, 4, address(mock)), 4, "right at every factor");
        }
        mock.setBurn(base * 10);
        (bool ok, bytes memory ret) = address(store).call{ gas: 300_000 }(
            abi.encodeCall(store.firstMissing, (fileId, 0, 4, address(mock)))
        );
        assertFalse(ok, "a shortfall reverts");
        assertEq(
            ret,
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(mock)),
            "a shortfall, not an answer"
        );
    }
}

/// @dev Gas of the piecewise paths, every measured call cold (fixtures in `setUp`).
contract ContentStorePermanenceGasTest is PermanenceBase {
    bytes internal full;
    bytes32[] internal parts;
    bytes32[] internal lists512;
    bytes32[] internal lists4096;

    function setUp() public {
        store = new ContentStore();
        full = _data(CHUNK, 40);
        parts = _writeParts(full, 8192);
        lists512 = _writeList(_fakeHashes(512, 41), PER_LIST);
        lists4096 = _writeList(_fakeHashes(4096, 42), PER_LIST);
    }

    function _txGas(bytes memory callData) internal returns (uint256 execution, uint256 txGas) {
        execution = _gasOf(callData);
        txGas = 21_000 + _calldataGas(callData) + execution;
    }

    /// @dev One 8,192-byte part, new: what each of the three part writes costs.
    function test_Gas_WritePart8192() public {
        (uint256 execution, uint256 txGas) =
            _txGas(abi.encodeCall(store.writeChunk, (_data(8192, 43))));
        console2.log("gas writeChunk, 8,192-byte part, execution", execution);
        console2.log("gas writeChunk, 8,192-byte part, transaction", txGas);
        assertLt(txGas, 2_000_000);
    }

    /// @dev Linking three 8,192-byte parts into a full chunk, cold.
    function test_Gas_LinkThreeParts() public {
        (uint256 execution, uint256 txGas) = _txGas(abi.encodeCall(store.linkChunk, (parts)));
        console2.log("gas linkChunk, 3 parts (24,575 bytes), execution", execution);
        console2.log("gas linkChunk, 3 parts (24,575 bytes), transaction", txGas);
        assertEq(store.chunkData(keccak256(full)), full);
        assertLt(txGas, 300_000);
    }

    function test_Gas_RegisterListOf512() public {
        bytes32[] memory h = _fakeHashes(512, 41);
        (uint256 execution, uint256 txGas) = _txGas(
            abi.encodeCall(
                store.registerManifestList,
                (lists512, PER_LIST, 512 * CHUNK, IDENTITY, HTML, DIGEST, uint8(0))
            )
        );
        console2.log("gas registerManifestList, 512 chunks (1 list chunk), execution", execution);
        console2.log("gas registerManifestList, 512 chunks, transaction", txGas);
        assertEq(
            store.chunkHash(store.manifestId(h, 512 * CHUNK, IDENTITY, HTML, DIGEST), 511), h[511]
        );
        assertLt(txGas, TX_GAS_CAP * 3 / 4);
    }

    function test_Gas_RegisterListOf4096() public {
        bytes32[] memory h = _fakeHashes(4096, 42);
        (uint256 execution, uint256 txGas) = _txGas(
            abi.encodeCall(
                store.registerManifestList,
                (lists4096, PER_LIST, 4096 * CHUNK, IDENTITY, HTML, DIGEST, uint8(0))
            )
        );
        console2.log("gas registerManifestList, 4,096 chunks (6 list chunks), execution", execution);
        console2.log("gas registerManifestList, 4,096 chunks, transaction", txGas);
        bytes32 id = store.manifestId(h, 4096 * CHUNK, IDENTITY, HTML, DIGEST);
        assertEq(store.chunkHash(id, 4095), h[4095]);
        assertEq(store.fileInfo(id).chunkCount, 4096);
        assertLt(txGas, TX_GAS_CAP * 3 / 4);
    }

    /// @dev A full list chunk (767 hashes, 24,544 bytes), new: each piece of a 4,096 list.
    function test_Gas_WriteFullListChunk() public {
        bytes memory list = _packed(_fakeHashes(PER_LIST, 44), 0, PER_LIST);
        (uint256 execution, uint256 txGas) = _txGas(abi.encodeCall(store.writeChunk, (list)));
        console2.log("gas writeChunk, full list chunk (767 hashes), execution", execution);
        console2.log("gas writeChunk, full list chunk, transaction", txGas);
        assertLt(txGas, TX_GAS_CAP * 3 / 4);
    }

    /// @dev Reading a linked chunk of 3 parts, and of 256 parts, cold.
    function test_Gas_ReadLinked() public {
        bytes32 hash = store.linkChunk(parts);
        vm.cool(address(store));
        for (uint256 i; i < parts.length; ++i) {
            vm.cool(store.chunkPointer(parts[i]));
        }
        uint256 used = _gasOf(abi.encodeCall(store.chunkData, (hash)));
        console2.log("gas chunkData, linked from 3 parts, cold", used);
        assertLt(used, 150_000);
    }

    function test_Gas_ReadLinkedFromMaxParts() public {
        bytes memory chunk = _data(CHUNK, 45);
        bytes32[] memory many = _writeParts(chunk, 96);
        bytes32 hash = store.linkChunk(many);
        vm.cool(address(store));
        for (uint256 i; i < many.length; ++i) {
            vm.cool(store.chunkPointer(many[i]));
        }
        uint256 used = _gasOf(abi.encodeCall(store.chunkData, (hash)));
        console2.log("gas chunkData, linked from 256 parts, cold", used);
        assertLt(used, 2_000_000);
    }
}
