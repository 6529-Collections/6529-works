// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { Burner, GasRuleAssertions } from "test/helpers/GasRule.sol";
import { toWorkItem, toWorkMedia } from "test/helpers/WorkItems.sol";
import { RecordsFixture } from "./RecordsFixture.sol";

/// @notice A store adapter (`IChunkSource`) for tests: serves the chunks put into it, honestly
///         (mode 0), with a flipped first byte (1), or not at all (2).
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

    function readChunk(bytes32 hash) external view returns (bytes memory data) {
        if (mode == 2) revert("source down");
        data = _chunks[hash];
        if (data.length == 0) revert("not held");
        if (mode == 1) data[0] = data[0] ^ 0x01;
    }
}

/// @notice Store adapters (owner decision, 15 November 2026; study G A.4.3) and the chunk
///         cursor of `syncOnChain`: a governed, append-only set of stores; every chunk an
///         adapter serves verified against the manifest's hash and length; a file's store fixed
///         once it completes and switched while in progress only away from a store that lacks
///         its next chunk; and the gas rule on adapter reads.
contract WorkStoresTest is RecordsFixture, GasRuleAssertions {
    ChunkSourceMock internal source;

    function setUp() public override(RecordsFixture) {
        RecordsFixture.setUp();
        source = new ChunkSourceMock();
    }

    function _addStore(address s) internal returns (uint256 id) {
        id = records.storeCount();
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
            IContentStore.Encoding.Identity,
            "video/mp4",
            keccak256(abi.encode("big", salt))
        );
    }

    /// @dev An opened work whose media are `files` (each one file ID), the first PRIMARY.
    function _workOf(uint256 salt, bytes32[] memory files) internal returns (uint256 tokenId) {
        MediaFile[] memory media = new MediaFile[](files.length);
        for (uint256 i; i < files.length; ++i) {
            media[i] = MediaFile(
                files[i], store.sha256Of(files[i]), i == 0 ? FileRole.PRIMARY : FileRole.AUXILIARY
            );
        }
        PackageItem memory item = _recordsItem(salt, media);
        tokenId = _mint(item);
        records.openRecord(tokenId, toWorkItem(item), toWorkMedia(media));
    }

    function _one(bytes32 file) internal pure returns (bytes32[] memory files) {
        files = new bytes32[](1);
        files[0] = file;
    }

    // ------------------------------------------------------------------------- the store set

    function test_addStore_isGovernedAppendOnlyAndPinned() public {
        assertEq(records.storeCount(), 1);
        assertEq(records.store(0), address(store));
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider)
        );
        records.addStore(address(source), address(source).codehash);

        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(source)));
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
        assertEq(records.storeCount(), 16);
        assertEq(records.store(1), address(source));
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownStore.selector, 16));
        records.store(16);
    }

    // ----------------------------------------------------------------------- adapter sync

    /// @dev Media held only by an adapter becomes on-chain complete through it, and the file
    ///      records the adapter's store ID for good.
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
        emit IWorkRecords.OnChainSyncProgress(tokenId, 1, 0, id);
        vm.expectEmit(address(records));
        emit IWorkRecords.WorkOnChainComplete(tokenId);
        records.syncOnChain(tokenId, id, 10);
        assertTrue(records.record(tokenId).onChainComplete);
        (uint256 storeId, bool complete) = records.mediaStore(tokenId, 0);
        assertEq(storeId, id);
        assertTrue(complete);
    }

    /// @dev Bytes that do not hash to the manifest's chunk, a refusing adapter, and bytes of a
    ///      length the layout rule does not allow are all missing chunks.
    function test_syncOnChain_adapterBytesAreVerified() public {
        uint256 id = _addStore(address(source));
        (bytes32 file, bytes[] memory chunks) = _bigFile(2, 2);
        source.put(chunks[0]);
        source.put(chunks[1]);
        uint256 tokenId = _workOf(2, _one(file));
        source.setMode(1);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId));
        records.syncOnChain(tokenId, id, 10);
        source.setMode(2);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId));
        records.syncOnChain(tokenId, id, 10);

        // A one-chunk manifest declaring 100 bytes for a 50-byte chunk: the hash matches, the
        // length does not, so it never completes (WS-27), through an adapter as in the store.
        source.setMode(0);
        bytes memory half = _chunkData(3, 0, 50);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(half);
        bytes32 odd = store.registerManifest(
            hashes, 100, IContentStore.Encoding.Identity, "image/png", keccak256("odd")
        );
        source.put(half);
        uint256 oddId = _workOf(3, _one(odd));
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, oddId));
        records.syncOnChain(oddId, id, 10);
    }

    /// @dev A file in progress stays with its store while that store holds the next chunk; once
    ///      it lacks it, a call may switch the file to another store, which restarts it at chunk 0.
    function test_syncOnChain_switchesStoreOnlyAwayFromAMissingChunk() public {
        uint256 id = _addStore(address(source));
        (bytes32 file, bytes[] memory chunks) = _bigFile(4, 3);
        source.put(chunks[0]);
        source.put(chunks[1]);
        uint256 tokenId = _workOf(4, _one(file));
        records.syncOnChain(tokenId, id, 1);
        (uint256 files, uint256 chunk) = records.syncCursor(tokenId);
        assertEq(files, 0);
        assertEq(chunk, 1);
        for (uint256 j; j < 3; ++j) {
            store.writeChunk(chunks[j]);
        }
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.StoreInUse.selector, tokenId, id));
        records.syncOnChain(tokenId, 0, 10);
        vm.expectEmit(address(records));
        emit IWorkRecords.OnChainSyncProgress(tokenId, 0, 2, id);
        records.syncOnChain(tokenId, id, 10);
        // The adapter lacks chunk 2: the content store takes the file over from chunk 0.
        vm.expectEmit(address(records));
        emit IWorkRecords.OnChainSyncProgress(tokenId, 1, 0, 0);
        records.syncOnChain(tokenId, 0, 10);
        (uint256 storeId, bool complete) = records.mediaStore(tokenId, 0);
        assertEq(storeId, 0);
        assertTrue(complete);
    }

    /// @dev A store whose code changed since it was added cannot be used, and holds nothing, so
    ///      a file in progress with it may move to another store.
    function test_syncOnChain_aStoreWhoseCodeChanged() public {
        uint256 id = _addStore(address(source));
        (bytes32 file, bytes[] memory chunks) = _bigFile(5, 2);
        source.put(chunks[0]);
        source.put(chunks[1]);
        store.writeChunk(chunks[0]);
        store.writeChunk(chunks[1]);
        uint256 tokenId = _workOf(5, _one(file));
        records.syncOnChain(tokenId, id, 1);
        vm.etch(address(source), address(store).code);
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.UnknownStore.selector, id));
        records.syncOnChain(tokenId, id, 10);
        records.syncOnChain(tokenId, 0, 10);
        assertTrue(records.record(tokenId).onChainComplete);
    }

    /// @dev A complete file's store never changes, whatever store later files use, and the work
    ///      stays on-chain complete.
    function test_syncOnChain_aCompleteFilesStoreNeverChanges() public {
        uint256 id = _addStore(address(source));
        (bytes32 a, bytes[] memory ca) = _bigFile(6, 1);
        (bytes32 b, bytes[] memory cb) = _bigFile(7, 1);
        source.put(ca[0]);
        store.writeChunk(cb[0]);
        bytes32[] memory files = new bytes32[](2);
        (files[0], files[1]) = (a, b);
        uint256 tokenId = _workOf(6, files);
        records.syncOnChain(tokenId, id, 10);
        records.syncOnChain(tokenId, 0, 10);
        (uint256 s0,) = records.mediaStore(tokenId, 0);
        (uint256 s1,) = records.mediaStore(tokenId, 1);
        assertEq(s0, id);
        assertEq(s1, 0);
        assertTrue(records.record(tokenId).onChainComplete);
        // Dropping the bytes or adding stores changes nothing recorded.
        source.drop(keccak256(ca[0]));
        _addStore(address(new ChunkSourceMock()));
        records.syncOnChain(tokenId, 0, 10);
        (s0,) = records.mediaStore(tokenId, 0);
        assertEq(s0, id);
        assertTrue(records.record(tokenId).onChainComplete);
    }

    /// @dev Gas rule: with the adapter costing 1x to 100x its base, verification gives the same
    ///      result; with too little gas it reverts with the shortfall error, never as a missing
    ///      chunk (which would let a caller switch the file's store).
    function test_GasRule_adapterReads() public {
        Burner burner = new Burner(address(source), 30_000);
        uint256 id = _addStore(address(burner));
        (bytes32 file, bytes[] memory chunks) = _bigFile(8, 2);
        source.put(chunks[0]);
        source.put(chunks[1]);
        uint256 tokenId = _workOf(8, _one(file));
        bytes memory data = abi.encodeCall(records.syncOnChain, (tokenId, id, 10));
        Outcome memory o = _assertSameAtEveryMultiple(burner, outsider, address(records), data);
        assertTrue(o.ok);
        for (uint256 i; i < 3; ++i) {
            burner.burnerSetMultiple(i == 0 ? 1 : i == 1 ? 4 : 10);
            _assertShortfallNeverAnswers(burner, outsider, address(records), data);
        }
    }
}
