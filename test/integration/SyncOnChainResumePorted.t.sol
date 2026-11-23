// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice A work with more chunks than one transaction can check, on the deployed stack:
///         5 media files of 1,024 chunks (about 125 MB). Re-ported from the retired
///         `SyncOnChainResume` suite: the per-work sync cursor is gone; the resumable part is
///         now each file's completeness prefix in the content store (`attestComplete`), which
///         anyone advances over chunks of their choosing, and
///         `StreamWorkFacts6529.markOnChainComplete` then checks every file in one call that walks
///         only what is not attested.
/// @dev Chunks are planted as `ContentStoreCompletenessGas` plants them: a pointer etched with
///      the code the store reads (a STOP byte, then the chunk) and `chunkPointer[hash]` written
///      at the store's slot 2. The work is built in `setUp`, and storage is cooled before each
///      measured call, so every chunk account is read cold as in its own transaction.
contract SyncOnChainResumePortedTest is IntegrationBase {
    uint256 internal constant CHUNK_POINTER_SLOT = 2; // test/snapshots/storage/ContentStore.json
    uint256 internal constant FILES = 5;
    uint256 internal constant CHUNKS = 1024;
    uint256 internal constant PIECE = 512;

    address internal artist;
    address internal keeper = makeAddr("syncKeeper");
    uint256 internal tokenId;
    bytes32[] internal fileIds;
    address[] internal pointers;
    /// @dev The last chunk of the last file, left unplanted; a test stores it when it needs it.
    bytes32 internal missingHash;
    address internal missingPointer;

    function setUp() public override {
        super.setUp();
        artist = _actor("bigWorkArtist");
        uint256 size = store.CHUNK_SIZE();
        bytes memory code = new bytes(size + 1);
        MediaFile[] memory media = new MediaFile[](FILES);
        for (uint256 f; f < FILES; ++f) {
            bytes32[] memory hashes = new bytes32[](CHUNKS);
            for (uint256 j; j < CHUNKS; ++j) {
                hashes[j] = keccak256(abi.encode("big work chunk", f, j));
                address pointer = address(uint160(0xB16000000 + f * CHUNKS + j));
                if (f + 1 == FILES && j + 1 == CHUNKS) {
                    (missingHash, missingPointer) = (hashes[j], pointer);
                    vm.etch(pointer, code);
                } else {
                    _plant(hashes[j], pointer, code);
                }
                pointers.push(pointer);
            }
            bytes32 sha = keccak256(abi.encode("media", f));
            bytes32 id = store.registerManifest(
                hashes, CHUNKS * size, uint8(IContentStore.Encoding.Identity), "video/mp4", sha
            );
            fileIds.push(id);
            media[f] =
                MediaFile(id, sha, f == 0 ? uint8(FileRole.PRIMARY) : uint8(FileRole.AUXILIARY));
        }
        Work memory w;
        w.media = media;
        w.item = _item(artist, collectionId, media[0].sha256Hash, media, _record("Big work"));
        Work[] memory works = _one(w);
        (, tokenId) = _start(_publish(works), works, 0);
        _open(tokenId, w);
    }

    function _plant(bytes32 hash, address pointer, bytes memory code) internal {
        vm.etch(pointer, code);
        vm.store(
            address(store),
            keccak256(abi.encode(hash, CHUNK_POINTER_SLOT)),
            bytes32(uint256(uint160(pointer)))
        );
    }

    function _storeMissing() internal {
        vm.store(
            address(store),
            keccak256(abi.encode(missingHash, CHUNK_POINTER_SLOT)),
            bytes32(uint256(uint160(missingPointer)))
        );
    }

    function _cool() internal {
        vm.cool(address(store));
        vm.cool(address(facts));
        for (uint256 i; i < pointers.length; ++i) {
            vm.cool(pointers[i]);
        }
    }

    /// @dev One cold call of `data` to `target` as the keeper, capped at the EIP-7825 limit;
    ///      returns whether it succeeded and the gas it used.
    function _cold(address target, bytes memory data) internal returns (bool ok, uint256 used) {
        _cool();
        uint256 before = gasleft();
        vm.prank(keeper);
        (ok,) = target.call{ gas: TX_GAS_CAP }(data);
        used = before - gasleft();
    }

    function _complete() internal view returns (bool) {
        return facts.factsOf(address(stream), tokenId).onChainComplete;
    }

    /// @dev Unattested, the one call that checks the whole work cannot fit a transaction.
    ///      Attested in pieces of 512 chunks (each well inside the cap, cold), the files become
    ///      complete across calls; the marking call then reads one word per file. A repeat is a
    ///      no-op with no event.
    function test_ALargeWorkIsAttestedInPiecesThenMarkedComplete() public {
        _storeMissing();
        bytes memory mark =
            abi.encodeCall(IWorkFacts.markOnChainComplete, (address(stream), tokenId));
        (bool ok, uint256 walk) = _cold(address(facts), mark);
        assertFalse(ok, "a whole-work walk is over the cap");
        assertGt(walk, TX_GAS_CAP * 9 / 10, "it ran out of gas, nothing else");
        assertFalse(_complete());

        for (uint256 f; f < FILES; ++f) {
            for (uint256 k; k < CHUNKS / PIECE; ++k) {
                uint256 used;
                (ok, used) = _cold(
                    address(store),
                    abi.encodeCall(IContentStore.attestComplete, (fileIds[f], PIECE))
                );
                assertTrue(ok, "a piece of 512 chunks");
                assertLt(used, TX_GAS_CAP * 3 / 10, "a piece stays under 30% of the cap");
            }
            assertEq(store.completeThrough(fileIds[f]), CHUNKS);
        }
        vm.expectEmit(address(facts));
        emit IWorkFacts.OnChainComplete(address(stream), tokenId);
        uint256 cost;
        (ok, cost) = _cold(address(facts), mark);
        assertTrue(ok);
        assertLt(cost, 200_000, "one read per file once attested");
        assertTrue(_complete());

        vm.recordLogs();
        facts.markOnChainComplete(address(stream), tokenId);
        assertEq(vm.getRecordedLogs().length, 0, "a repeat is a no-op");
    }

    /// @dev Progress is kept up to a missing chunk: the attestation stops just before it, a
    ///      piece that reaches it reverts with its index, the work cannot be marked, and once
    ///      the chunk is stored the next piece completes the file and the work is marked.
    function test_ProgressIsKeptAtAMissingChunk() public {
        for (uint256 f; f + 1 < FILES; ++f) {
            store.attestComplete(fileIds[f], CHUNKS);
        }
        bytes32 last = fileIds[FILES - 1];
        assertFalse(store.attestComplete(last, CHUNKS - 1), "all but the last chunk");
        assertEq(store.completeThrough(last), CHUNKS - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IContentStore.ContentChunkMissing.selector, last, CHUNKS - 1, missingHash
            )
        );
        store.attestComplete(last, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.NotOnChainComplete.selector, address(stream), tokenId)
        );
        facts.markOnChainComplete(address(stream), tokenId);
        assertEq(store.completeThrough(last), CHUNKS - 1, "the place is kept");

        _storeMissing();
        assertTrue(store.attestComplete(last, 1));
        facts.markOnChainComplete(address(stream), tokenId);
        assertTrue(_complete());
    }

    /// @dev Whatever the gas schedule, a file advances one chunk a call: each call costs a
    ///      constant plus one cold chunk.
    function test_OneChunkACallAlwaysProgresses() public {
        bytes32 first = fileIds[0];
        for (uint256 j; j < 5; ++j) {
            (bool ok, uint256 used) =
                _cold(address(store), abi.encodeCall(IContentStore.attestComplete, (first, 1)));
            assertTrue(ok);
            assertLt(used, 60_000, "one chunk and the bookkeeping");
            assertEq(store.completeThrough(first), j + 1);
        }
    }
}
