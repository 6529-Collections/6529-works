// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { Burner, GasRuleAssertions } from "test/helpers/GasRule.sol";

import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice A store adapter (`IChunkStore`) for tests: serves the chunks put into it, honestly
///         (mode 0), with a flipped first byte (1), or reverts (2); burns all the gas it gets
///         (3); returns 4 MB of data (4); or serves honestly and reverts for a chunk it does not
///         hold (5). In modes 0 and 1 a chunk it does not hold is served as empty bytes; both
///         that and a revert count as missing.
contract ChunkSourceMock {
    mapping(bytes32 hash => bytes) internal _chunks;
    uint8 public mode;

    function put(bytes calldata data) external {
        _chunks[keccak256(data)] = data;
    }

    function drop(bytes32 hash) external {
        delete _chunks[hash];
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    function chunkData(bytes32 hash) external view returns (bytes memory data) {
        uint8 m = mode;
        if (m == 2) revert("source down");
        if (m == 3) {
            while (true) { }
        }
        if (m == 4) return new bytes(4_000_000);
        data = _chunks[hash];
        if (m == 5 && data.length == 0) revert("not held");
        if (mode == 1 && data.length != 0) data[0] = data[0] ^ 0x01;
    }
}

/// @notice Store adapters (owner decision, 15 November 2026; study G A.4.3) and the chunk
///         cursor of `syncOnChain`: a governed, append-only set of stores; every chunk an
///         adapter serves verified against the manifest's hash and length; a file's store fixed
///         once it completes and switched while in progress only away from a store that lacks
///         its next chunk; and the gas rule on adapter reads.
contract WorkStoresTest is RecordsFixture, GasRuleAssertions {
    ChunkSourceMock internal source;
    /// @dev Store IDs in use, the content store included (from `StoreAdded`).
    uint256 internal stores = 1;

    function setUp() public override(RecordsFixture) {
        RecordsFixture.setUp();
        source = new ChunkSourceMock();
    }

    function _addStore(address s) internal returns (uint256 id) {
        id = stores++;
        vm.expectEmit(address(records));
        emit IWorkRecords.StoreAdded(id, s, s.codehash);
        vm.prank(governor);
        records.addStore(s, s.codehash);
    }

    function _chunkData(uint256 salt, uint256 j, uint256 length)
        internal
        pure
        returns (bytes memory data)
    {
        data = new bytes(length);
        bytes32 tag = keccak256(abi.encode(salt, j));
        assembly ("memory-safe") {
            mstore(add(data, 0x20), tag)
        }
    }

    /// @dev A registered file of `count` chunks (the last of 100 bytes), stored nowhere; its
    ///      chunks are returned so a test can put them where it wants.
    function _bigFile(uint256 salt, uint256 count)
        internal
        returns (bytes32 fileId, bytes[] memory chunks)
    {
        uint256 size = store.CHUNK_SIZE();
        chunks = new bytes[](count);
        bytes32[] memory hashes = new bytes32[](count);
        for (uint256 j; j < count; ++j) {
            chunks[j] = _chunkData(salt, j, j + 1 == count ? 100 : size);
            hashes[j] = keccak256(chunks[j]);
        }
        fileId = store.registerManifest(
            hashes,
            (count - 1) * size + 100,
            uint8(IContentStore.Encoding.Identity),
            "video/mp4",
            keccak256(abi.encode("big", salt))
        );
    }

    /// @dev An opened work whose media are `files` (each one file ID), the first PRIMARY.
    function _workOf(uint256 salt, bytes32[] memory files) internal returns (uint256 tokenId) {
        MediaFile[] memory media = new MediaFile[](files.length);
        for (uint256 i; i < files.length; ++i) {
            media[i] = MediaFile(
                files[i],
                store.sha256Of(files[i]),
                i == 0 ? uint8(FileRole.PRIMARY) : uint8(FileRole.AUXILIARY)
            );
        }
        PackageItem memory item = _recordsItem(salt, media);
        tokenId = _mint(item);
        records.openRecord(tokenId, item, media);
    }

    function _one(bytes32 file) internal pure returns (bytes32[] memory files) {
        files = new bytes32[](1);
        files[0] = file;
    }

    // ------------------------------------------------------------------------- the store set

    function test_addStore_isGovernedAppendOnlyAndPinned() public {
        assertEq(records.store(0), address(store));
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownStore.selector, 1));
        records.store(1);
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        records.addStore(address(source), address(source).codehash);

        vm.startPrank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(source))
        );
        records.addStore(address(source), keccak256("other code"));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, outsider));
        records.addStore(outsider, outsider.codehash);
        vm.expectEmit(address(records));
        emit IWorkRecords.StoreAdded(1, address(source), address(source).codehash);
        records.addStore(address(source), address(source).codehash);
        for (uint256 i = 2; i < 16; ++i) {
            ChunkSourceMock s = new ChunkSourceMock();
            records.addStore(address(s), address(s).codehash);
        }
        ChunkSourceMock extra = new ChunkSourceMock();
        vm.expectRevert(IWorkRecords.StoreLimitReached.selector);
        records.addStore(address(extra), address(extra).codehash);
        vm.stopPrank();
        assertEq(records.store(1), address(source));
        assertTrue(records.store(15) != address(0));
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownStore.selector, 16));
        records.store(16);
    }

    // ----------------------------------------------------------------------- adapter sync

    function _syncAs(address who, uint256 tokenId, uint256 storeId, uint256 maxChunks) internal {
        vm.prank(who);
        records.syncOnChain(tokenId, storeId, maxChunks);
    }

    /// @dev Media held only by an adapter becomes on-chain complete through it, at the artist's
    ///      choice, and the file records the adapter's store ID (`MediaFileComplete`).
    function test_syncOnChain_throughAnAdapter() public {
        uint256 id = _addStore(address(source));
        (bytes32 file, bytes[] memory chunks) = _bigFile(1, 3);
        for (uint256 j; j < 3; ++j) {
            source.put(chunks[j]);
        }
        uint256 tokenId = _workOf(1, _one(file));
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId));
        records.syncOnChain(tokenId, 0, 10);
        vm.expectEmit(address(records));
        emit IWorkRecords.MediaFileComplete(tokenId, 0, id);
        vm.expectEmit(address(records));
        emit IWorkRecords.OnChainSyncProgress(tokenId, 1, 0, id);
        vm.expectEmit(address(records));
        emit IWorkRecords.WorkOnChainComplete(tokenId);
        _syncAs(artist, tokenId, id, 10);
        assertTrue(records.record(tokenId).onChainComplete);
        (uint256 storeId, bool complete) = records.mediaStore(tokenId, 0);
        assertEq(storeId, id);
        assertTrue(complete);
        // On-chain complete: the artist's added-store walk is over (a no-op).
        _syncAs(artist, tokenId, id, 10);
    }

    /// @dev Only the work's artist may choose an added store (governance review L-3): a third
    ///      party cannot make a work complete in a store of its choosing. The content store stays
    ///      open to anyone.
    function test_syncOnChain_anAddedStoreIsTheArtistsChoice() public {
        uint256 id = _addStore(address(source));
        (bytes32 file, bytes[] memory chunks) = _bigFile(11, 1);
        source.put(chunks[0]);
        uint256 tokenId = _workOf(11, _one(file));
        vm.expectRevert(
            abi.encodeWithSelector(IWorkRecords.NotWorkArtist.selector, tokenId, outsider)
        );
        _syncAs(outsider, tokenId, id, 10);
        store.writeChunk(chunks[0]);
        _syncAs(outsider, tokenId, 0, 10);
        (uint256 storeId, bool complete) = records.mediaStore(tokenId, 0);
        assertEq(storeId, 0);
        assertTrue(complete);
    }

    /// @dev Bytes that do not hash to the manifest's chunk, bytes of a length the layout rule does
    ///      not allow, and an adapter's refusal are all a missing chunk (review B L2): the call
    ///      verifies nothing and reverts `NotOnChainComplete`.
    function test_syncOnChain_adapterBytesAreVerified() public {
        uint256 id = _addStore(address(source));
        (bytes32 file, bytes[] memory chunks) = _bigFile(2, 2);
        source.put(chunks[0]);
        source.put(chunks[1]);
        uint256 tokenId = _workOf(2, _one(file));
        source.setMode(1);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId));
        _syncAs(artist, tokenId, id, 10);
        source.setMode(2);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId));
        _syncAs(artist, tokenId, id, 10);

        // A one-chunk manifest declaring 100 bytes for a 50-byte chunk: the hash matches, the
        // length does not, so it never completes (WS-27), through an adapter as in the store.
        source.setMode(0);
        bytes memory half = _chunkData(3, 0, 50);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(half);
        bytes32 odd = store.registerManifest(
            hashes, 100, uint8(IContentStore.Encoding.Identity), "image/png", keccak256("odd")
        );
        source.put(half);
        uint256 oddId = _workOf(3, _one(odd));
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, oddId));
        _syncAs(artist, oddId, id, 10);
    }

    /// @dev Review B L2: an adapter that reverts for a chunk it does not hold (as `ContentStore`
    ///      does) keeps the progress a call made before that chunk; the next call resumes there.
    function test_syncOnChain_aStoreThatRevertsForAMissingChunkKeepsProgress() public {
        uint256 id = _addStore(address(source));
        source.setMode(5);
        (bytes32 file, bytes[] memory chunks) = _bigFile(12, 3);
        source.put(chunks[0]);
        source.put(chunks[1]);
        uint256 tokenId = _workOf(12, _one(file));
        vm.expectEmit(address(records));
        emit IWorkRecords.OnChainSyncProgress(tokenId, 0, 2, id);
        _syncAs(artist, tokenId, id, 10);
        source.put(chunks[2]);
        vm.expectEmit(address(records));
        emit IWorkRecords.MediaFileComplete(tokenId, 0, id);
        _syncAs(artist, tokenId, id, 10);
        assertTrue(records.record(tokenId).onChainComplete);
    }

    /// @dev Review B M1: a file the artist's walk left in progress in an added store that then
    ///      burns all its gas, or returns megabytes, still completes in the content store once
    ///      every chunk is there, at any gas limit that covers the content store's own checks:
    ///      the content store's walk never calls an added store.
    function test_syncOnChain_aStoreThatGoesBadNeverHoldsAFile() public {
        uint256 id = _addStore(address(source));
        (bytes32 file, bytes[] memory chunks) = _bigFile(13, 3);
        source.put(chunks[0]);
        source.put(chunks[1]);
        uint256 tokenId = _workOf(13, _one(file));
        _syncAs(artist, tokenId, id, 1);
        for (uint256 j; j < 3; ++j) {
            store.writeChunk(chunks[j]);
        }
        bytes memory data = abi.encodeCall(records.syncOnChain, (tokenId, 0, 10));
        bytes memory viaStore = abi.encodeCall(records.syncOnChain, (tokenId, id, 10));
        uint256[4] memory limits = [uint256(1_000_000), 10_000_000, 16_777_216, 30_000_000];
        for (uint8 m = 3; m <= 4; ++m) {
            source.setMode(m);
            for (uint256 k; k < limits.length; ++k) {
                Outcome memory o = _try(outsider, address(records), data, limits[k]);
                assertTrue(o.ok, "the content store completes the file");
            }
            // The artist's walk with the bad store fails, and changes nothing.
            assertFalse(_try(artist, address(records), viaStore, 16_777_216).ok);
        }
        _syncAs(outsider, tokenId, 0, 10);
        assertTrue(records.record(tokenId).onChainComplete);
        (uint256 storeId,) = records.mediaStore(tokenId, 0);
        assertEq(storeId, 0);
    }

    /// @dev The two walks never touch each other: the artist naming an added store, or another
    ///      one, never moves the content store's cursor, so no caller can undo progress there.
    function test_syncOnChain_walksNeverTouchEachOther() public {
        uint256 id = _addStore(address(source));
        uint256 id2 = _addStore(address(new ChunkSourceMock()));
        (bytes32 file, bytes[] memory chunks) = _bigFile(14, 3);
        store.writeChunk(chunks[0]);
        store.writeChunk(chunks[1]);
        source.put(chunks[0]);
        source.put(chunks[1]);
        source.put(chunks[2]);
        uint256 tokenId = _workOf(14, _one(file));
        vm.expectEmit(address(records));
        emit IWorkRecords.OnChainSyncProgress(tokenId, 0, 2, 0);
        _syncAs(outsider, tokenId, 0, 10);
        vm.expectEmit(address(records));
        emit IWorkRecords.OnChainSyncProgress(tokenId, 0, 1, id);
        _syncAs(artist, tokenId, id, 1);
        // Naming another store restarts the artist's walk, at chunk 0 of that store.
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId));
        _syncAs(artist, tokenId, id2, 10);
        // Back on the first store: the walk resumes where it stood, then runs to the end.
        vm.expectEmit(address(records));
        emit IWorkRecords.MediaFileComplete(tokenId, 0, id);
        _syncAs(artist, tokenId, id, 10);
        // The content store's cursor is where it was: one chunk completes the file there.
        store.writeChunk(chunks[2]);
        vm.expectEmit(address(records));
        emit IWorkRecords.MediaFileComplete(tokenId, 0, 0);
        vm.expectEmit(address(records));
        emit IWorkRecords.OnChainSyncProgress(tokenId, 1, 0, 0);
        _syncAs(outsider, tokenId, 0, 1);
    }

    /// @dev Governance review L-3: a work complete in an added store that later stops serving can
    ///      still be completed in the content store by anyone (an upgrade, never a downgrade);
    ///      the file's store becomes 0 for good and the work stays on-chain complete.
    function test_syncOnChain_upgradeToTheContentStore() public {
        uint256 id = _addStore(address(source));
        (bytes32 a, bytes[] memory ca) = _bigFile(15, 1);
        (bytes32 b, bytes[] memory cb) = _bigFile(16, 2);
        source.put(ca[0]);
        source.put(cb[0]);
        source.put(cb[1]);
        store.writeChunk(ca[0]);
        bytes32[] memory files = new bytes32[](2);
        (files[0], files[1]) = (a, b);
        uint256 tokenId = _workOf(15, files);
        // File 0 completes in the content store; the artist's walk skips it and completes file 1.
        _syncAs(outsider, tokenId, 0, 10);
        vm.expectEmit(address(records));
        emit IWorkRecords.MediaFileComplete(tokenId, 1, id);
        _syncAs(artist, tokenId, id, 10);
        assertTrue(records.record(tokenId).onChainComplete);
        (uint256 s1, bool c1) = records.mediaStore(tokenId, 1);
        assertEq(s1, id);
        assertTrue(c1);
        source.drop(keccak256(cb[0]));
        store.writeChunk(cb[0]);
        store.writeChunk(cb[1]);
        vm.expectEmit(address(records));
        emit IWorkRecords.MediaFileComplete(tokenId, 1, 0);
        _syncAs(outsider, tokenId, 0, 10);
        (s1, c1) = records.mediaStore(tokenId, 1);
        assertEq(s1, 0);
        assertTrue(c1);
        assertTrue(records.record(tokenId).onChainComplete);
        // Complete in the content store: every walk is a no-op from now on.
        _syncAs(outsider, tokenId, 0, 10);
        _syncAs(artist, tokenId, id, 10);
        (s1,) = records.mediaStore(tokenId, 1);
        assertEq(s1, 0);
    }

    /// @dev A store whose code changed since it was added cannot be used; the content store's
    ///      walk is unaffected.
    function test_syncOnChain_aStoreWhoseCodeChanged() public {
        uint256 id = _addStore(address(source));
        (bytes32 file, bytes[] memory chunks) = _bigFile(5, 2);
        source.put(chunks[0]);
        source.put(chunks[1]);
        store.writeChunk(chunks[0]);
        store.writeChunk(chunks[1]);
        uint256 tokenId = _workOf(5, _one(file));
        _syncAs(artist, tokenId, id, 1);
        vm.etch(address(source), address(store).code);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownStore.selector, id));
        _syncAs(artist, tokenId, id, 10);
        records.syncOnChain(tokenId, 0, 10);
        assertTrue(records.record(tokenId).onChainComplete);
    }

    /// @dev A file complete in the content store never moves to an added store, whatever store
    ///      later files use, and the work stays on-chain complete.
    function test_syncOnChain_aContentStoreFileNeverMoves() public {
        uint256 id = _addStore(address(source));
        (bytes32 a, bytes[] memory ca) = _bigFile(6, 1);
        (bytes32 b, bytes[] memory cb) = _bigFile(7, 1);
        store.writeChunk(ca[0]);
        source.put(ca[0]);
        source.put(cb[0]);
        bytes32[] memory files = new bytes32[](2);
        (files[0], files[1]) = (a, b);
        uint256 tokenId = _workOf(6, files);
        records.syncOnChain(tokenId, 0, 10);
        vm.expectEmit(address(records));
        emit IWorkRecords.MediaFileComplete(tokenId, 1, id);
        _syncAs(artist, tokenId, id, 10);
        (uint256 s0,) = records.mediaStore(tokenId, 0);
        (uint256 s1,) = records.mediaStore(tokenId, 1);
        assertEq(s0, 0);
        assertEq(s1, id);
        assertTrue(records.record(tokenId).onChainComplete);
        source.drop(keccak256(cb[0]));
        _addStore(address(new ChunkSourceMock()));
        (s0,) = records.mediaStore(tokenId, 0);
        assertEq(s0, 0);
        assertTrue(records.record(tokenId).onChainComplete);
    }

    /// @dev Gas rule: with the adapter costing 1x to 100x its base, verification gives the same
    ///      result; with too little gas the call reverts (the adapter's out-of-gas reaches the
    ///      records contract as a shortfall), never succeeds with less progress and never reads
    ///      as a missing chunk.
    function test_GasRule_adapterReads() public {
        Burner burner = new Burner(address(source), 30_000);
        uint256 id = _addStore(address(burner));
        (bytes32 file, bytes[] memory chunks) = _bigFile(8, 2);
        source.put(chunks[0]);
        source.put(chunks[1]);
        uint256 tokenId = _workOf(8, _one(file));
        bytes memory data = abi.encodeCall(records.syncOnChain, (tokenId, id, 10));
        Outcome memory full = _assertSameAtEveryMultiple(burner, artist, address(records), data);
        assertTrue(full.ok);
        bytes memory missing =
            abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId);
        for (uint256 m; m < 4; ++m) {
            burner.burnerSetMultiple(m == 0 ? 1 : m == 1 ? 2 : m == 2 ? 4 : 10);
            for (uint256 g = 100_000; g < 3_000_000; g += 47_000) {
                Outcome memory o = _try(artist, address(records), data, g);
                if (o.ok) {
                    assertEq(o.data, full.data, "a cheaper success must be the same success");
                    continue;
                }
                assertTrue(keccak256(o.data) != keccak256(missing), "shortfall read as missing");
            }
        }
        // The progress a success leaves is the whole file.
        _syncAs(artist, tokenId, id, 10);
        assertTrue(records.record(tokenId).onChainComplete);
    }
}
