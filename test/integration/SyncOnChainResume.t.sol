// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice `WorkRecords.syncOnChain` for a work with more chunks than one transaction can check:
///         5 media files of 512 chunks (about 63 MB). Each call checks whole files up to a chunk
///         budget and keeps its place, so the work becomes on-chain complete over several calls,
///         each inside the EIP-7825 cap from cold storage.
/// @dev Chunks are planted with `vm.etch` at the CREATE2 address `writeChunk` would use, with the
///      code `writeChunk` leaves (`0x00 || data`), and `chunkPointer[hash]` set as it sets it:
///      what `isComplete` reads is what an upload leaves, without uploading 63 MB in a test.
///      The work is built in `setUp`, a separate transaction, so every chunk account is cold.
contract SyncOnChainResumeTest is IntegrationBase {
    uint256 internal constant TX_CAP = 16_777_216;
    bytes12 internal constant PREAMBLE = 0x600B5981380380925939F300; // SSTORE2's
    uint256 internal constant CHUNK_POINTER_SLOT = 2; // ContentStore's storage layout
    uint256 internal constant FILES = 5;
    uint256 internal constant CHUNKS = 512;

    address internal artist;
    address internal keeper = makeAddr("syncKeeper");
    uint256 internal tokenId;
    /// @dev The chunk left out of the last file, uploaded by a test when it needs it.
    bytes internal missing;

    function _chunk(uint256 f, uint256 j) internal view returns (bytes memory data) {
        data = new bytes(store.CHUNK_SIZE());
        bytes32 tag = keccak256(abi.encode(f, j));
        assembly ("memory-safe") {
            mstore(add(data, 0x20), tag)
        }
    }

    function _plant(bytes memory data) internal {
        bytes32 hash = keccak256(data);
        bytes memory code = abi.encodePacked(PREAMBLE, data);
        address pointer = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(store), hash, keccak256(code)))
                )
            )
        );
        vm.etch(pointer, abi.encodePacked(bytes1(0x00), data));
        vm.store(
            address(store),
            keccak256(abi.encode(hash, CHUNK_POINTER_SLOT)),
            bytes32(uint256(uint160(pointer)))
        );
    }

    /// @dev Five files of 512 chunks; the last chunk of the last file is not planted.
    function setUp() public override {
        super.setUp();
        artist = _actor("bigWorkArtist");
        MediaFile[] memory media = new MediaFile[](FILES);
        for (uint256 f; f < FILES; ++f) {
            bytes32[] memory hashes = new bytes32[](CHUNKS);
            for (uint256 j; j < CHUNKS; ++j) {
                uint256 mark;
                assembly ("memory-safe") {
                    mark := mload(0x40)
                }
                bytes memory data = _chunk(f, j);
                hashes[j] = keccak256(data);
                if (f + 1 == FILES && j + 1 == CHUNKS) missing = data;
                else _plant(data);
                assembly ("memory-safe") {
                    mstore(0x40, mark)
                }
            }
            bytes32 sha = keccak256(abi.encode("media", f));
            bytes32 id = store.registerManifest(
                hashes,
                CHUNKS * store.CHUNK_SIZE(),
                IContentStore.Encoding.Identity,
                "video/mp4",
                sha
            );
            media[f] = MediaFile(id, sha, f == 0 ? FileRole.PRIMARY : FileRole.AUXILIARY);
        }
        Work memory w;
        w.media = media;
        w.item = _item(artist, collectionId, media[0].sha256Hash, media, _record("Big work"));
        Work[] memory works = _one(w);
        (, tokenId) = _start(_publish(works), works, 0);
        records.openRecord(tokenId, w.item, w.media);
    }

    /// @dev One `syncOnChain` as a transaction: storage cooled, plus EIP-2929's 2,500 for the
    ///      content store, the one account a real transaction reaches cold that an earlier call
    ///      in the test warmed (each call reads chunk accounts no earlier call read).
    function _sync() internal returns (uint256 total) {
        (total,) =
            _measure(keeper, address(records), abi.encodeCall(records.syncOnChain, (tokenId)), 0);
        total += COLD_ACCOUNT_SURCHARGE;
        console2.log("syncOnChain call, whole transaction:", total);
        assertLt(total, TX_CAP * 3 / 4, "a call fits the cap with a quarter to spare");
    }

    function test_SyncOnChain_ResumesAcrossCalls() public {
        store.writeChunk(missing);
        // 2,560 chunks, at most 1,024 a call, in whole files: 2, then 2, then the last.
        vm.expectEmit(address(records));
        emit IWorkRecords.OnChainSyncProgress(tokenId, 2);
        _sync();
        assertFalse(records.record(tokenId).onChainComplete);
        vm.expectEmit(address(records));
        emit IWorkRecords.OnChainSyncProgress(tokenId, 4);
        _sync();
        assertFalse(records.record(tokenId).onChainComplete);
        vm.expectEmit(address(records));
        emit IWorkRecords.WorkOnChainComplete(tokenId);
        _sync();
        assertTrue(records.record(tokenId).onChainComplete);
        // A repeat is a no-op.
        vm.recordLogs();
        records.syncOnChain(tokenId);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// @dev Progress is kept across calls; a call that reaches an incomplete file reverts, and
    ///      the next one resumes once the file is complete.
    function test_SyncOnChain_KeepsItsPlaceUntilAFileCompletes() public {
        _sync();
        _sync();
        vm.expectRevert(abi.encodeWithSelector(IWorkRecords.NotOnChainComplete.selector, tokenId));
        records.syncOnChain(tokenId);
        assertFalse(records.record(tokenId).onChainComplete);
        store.writeChunk(missing);
        vm.expectEmit(address(records));
        emit IWorkRecords.WorkOnChainComplete(tokenId);
        records.syncOnChain(tokenId);
        assertTrue(records.record(tokenId).onChainComplete);
    }
}
