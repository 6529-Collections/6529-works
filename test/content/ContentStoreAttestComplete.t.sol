// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ContentBase } from "./ContentBase.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";

/// @notice `attestComplete`: a permissionless per-file prefix of present chunks, advanced over a
///         caller-chosen count, that never passes a missing or wrong-length chunk, never goes
///         back, and makes `isComplete` one storage read once it reaches the end (WS-27).
contract ContentStoreAttestCompleteTest is ContentBase {
    uint8 internal constant IDENTITY = uint8(IContentStore.Encoding.Identity);
    /// @dev `chunkPointer` is slot 2.
    uint256 internal constant CHUNK_POINTER_SLOT = 2;

    address internal anyone = makeAddr("anyone");

    function setUp() public {
        store = new ContentStore();
    }

    /// @dev A file of `n` chunks (the last of `tail` bytes) whose chunks are etched pointers of
    ///      the exact layout length, so large counts stay cheap; `present` says which exist.
    function _file(uint256 n, uint256 tail, bool[] memory present)
        internal
        returns (bytes32 fileId, bytes32[] memory hashes)
    {
        hashes = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            hashes[i] = keccak256(abi.encode("chunk", n, i));
            if (present[i]) _put(hashes[i], i + 1 == n ? tail : CHUNK, i);
        }
        fileId = store.registerManifest(hashes, (n - 1) * CHUNK + tail, IDENTITY, HTML, DIGEST);
    }

    /// @dev Stores chunk `hash` at a pointer holding `length` bytes (behind the STOP byte).
    function _put(bytes32 hash, uint256 length, uint256 salt) internal {
        address pointer = address(uint160(uint256(keccak256(abi.encode("ptr", hash, salt)))));
        vm.etch(pointer, new bytes(length + 1));
        vm.store(
            address(store),
            keccak256(abi.encode(hash, CHUNK_POINTER_SLOT)),
            bytes32(uint256(uint160(pointer)))
        );
    }

    function _all(uint256 n) internal pure returns (bool[] memory p) {
        p = new bool[](n);
        for (uint256 i; i < n; ++i) {
            p[i] = true;
        }
    }

    // ------------------------------------------------------------------ unit paths

    /// @dev Real uploads: the prefix advances piece by piece with a progress event, the last
    ///      piece emits the attestation, and later calls are no-ops that return true.
    function test_AttestComplete_InPiecesWithEvents() public {
        bytes memory media = _data(3 * CHUNK + 5, 1);
        bytes32 fileId = _publish(media, IDENTITY, HTML);
        assertEq(store.completeThrough(fileId), 0);

        vm.expectEmit(address(store));
        emit IContentStore.CompletenessProgress(fileId, 2);
        vm.prank(anyone);
        assertFalse(store.attestComplete(fileId, 2));
        assertEq(store.completeThrough(fileId), 2);

        vm.expectEmit(address(store));
        emit IContentStore.CompletenessAttested(fileId);
        assertTrue(store.attestComplete(fileId, 100));
        assertEq(store.completeThrough(fileId), 4);
        assertTrue(store.isComplete(fileId));

        vm.recordLogs();
        assertTrue(store.attestComplete(fileId, 1));
        assertEq(vm.getRecordedLogs().length, 0, "a no-op after the attestation");
    }

    /// @dev Zero chunks checks nothing and reports progress where the prefix already is.
    function test_AttestComplete_ZeroChunksChecksNothing() public {
        bytes32 fileId = _publish(_data(CHUNK + 1, 2), IDENTITY, HTML);
        assertFalse(store.attestComplete(fileId, 0));
        assertEq(store.completeThrough(fileId), 0);
    }

    /// @dev A missing chunk stops the prefix: the call that reaches it reverts and changes
    ///      nothing; once the chunk is written, the attestation continues from where it was.
    function test_AttestComplete_CannotPassAMissingChunk() public {
        bytes memory media = _data(3 * CHUNK + 5, 3);
        (bytes32 fileId, bytes[] memory chunks, bytes32[] memory hashes) =
            _declare(media, IDENTITY, HTML);
        store.writeChunk(chunks[0]);
        store.writeChunk(chunks[1]);
        store.writeChunk(chunks[3]);

        assertFalse(store.attestComplete(fileId, 2));
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkMissing.selector, fileId, 2, hashes[2])
        );
        store.attestComplete(fileId, 10);
        assertEq(store.completeThrough(fileId), 2, "unchanged");
        assertFalse(store.isComplete(fileId));

        store.writeChunk(chunks[2]);
        assertTrue(store.attestComplete(fileId, 10));
        assertTrue(store.isComplete(fileId));
    }

    /// @dev A chunk stored at the wrong length (the layout rule) counts as missing: the prefix
    ///      cannot pass it, and the file is never attested.
    function test_AttestComplete_CannotPassAWrongLengthChunk() public {
        bytes memory shortChunk = _data(100, 12);
        bytes memory tail = _data(10, 13);
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256(shortChunk);
        hashes[1] = keccak256(tail);
        bytes32 fileId = store.registerManifest(hashes, CHUNK + 10, IDENTITY, HTML, DIGEST);
        store.writeChunk(shortChunk);
        store.writeChunk(tail);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentChunkMissing.selector, fileId, 0, hashes[0])
        );
        store.attestComplete(fileId, 2);
        assertEq(store.completeThrough(fileId), 0);
    }

    /// @dev A chunk held as a link of parts counts as present.
    function test_AttestComplete_CountsALinkedChunk() public {
        bytes memory media = _data(CHUNK + 9, 4);
        (bytes32 fileId, bytes[] memory chunks,) = _declare(media, IDENTITY, HTML);
        bytes32[] memory parts = new bytes32[](2);
        (parts[0],) = store.writeChunk(_slice(chunks[0], 0, 10_000));
        (parts[1],) = store.writeChunk(_slice(chunks[0], 10_000, CHUNK - 10_000));
        store.linkChunk(parts);
        store.writeChunk(chunks[1]);
        assertTrue(store.attestComplete(fileId, 2));
    }

    /// @dev Unknown files revert; the view reads zero for them.
    function test_AttestComplete_UnknownFile() public {
        bytes32 unknown = keccak256("nothing");
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, unknown));
        store.attestComplete(unknown, 1);
        assertEq(store.completeThrough(unknown), 0);
    }

    /// @dev `isComplete` walks only past the prefix: with the prefix part way, a later missing
    ///      chunk still reads as incomplete.
    function test_IsComplete_WalksOnlyThePartPastThePrefix() public {
        bool[] memory present = _all(6);
        present[4] = false;
        (bytes32 fileId, bytes32[] memory hashes) = _file(6, 77, present);
        assertFalse(store.attestComplete(fileId, 3));
        assertFalse(store.isComplete(fileId));
        _put(hashes[4], CHUNK, 99);
        assertTrue(store.isComplete(fileId));
    }

    /// @dev No caller can attest past a missing chunk, and nothing undoes an attestation: a
    ///      relink of a chunk from fewer parts (the only change a stored chunk can see) leaves the
    ///      file attested and complete.
    function test_TheAttestationCannotBeForgedOrUndone() public {
        bool[] memory present = new bool[](3);
        (bytes32 missingId,) = _file(3, 1, present);
        for (uint256 k; k < 3; ++k) {
            vm.prank(address(uint160(0xA000 + k)));
            vm.expectRevert();
            store.attestComplete(missingId, 3);
        }
        assertEq(store.completeThrough(missingId), 0);

        bytes memory media = _data(CHUNK + 9, 5);
        (bytes32 fileId, bytes[] memory chunks,) = _declare(media, IDENTITY, HTML);
        bytes32[] memory three = new bytes32[](3);
        (three[0],) = store.writeChunk(_slice(chunks[0], 0, 8000));
        (three[1],) = store.writeChunk(_slice(chunks[0], 8000, 8000));
        (three[2],) = store.writeChunk(_slice(chunks[0], 16_000, CHUNK - 16_000));
        store.linkChunk(three);
        store.writeChunk(chunks[1]);
        assertTrue(store.attestComplete(fileId, 2));
        bytes32[] memory two = new bytes32[](2);
        (two[0],) = store.writeChunk(_slice(chunks[0], 0, 16_000));
        two[1] = three[2];
        store.linkChunk(two);
        assertEq(store.completeThrough(fileId), 2);
        assertTrue(store.isComplete(fileId));
        assertEq(store.read(fileId, 0, media.length), media);
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev Any chunk count, any missing set, any sequence of step sizes and callers: the prefix
    ///      only grows, never passes the first missing chunk, a call reverts exactly when its range
    ///      holds a missing chunk, and once every chunk is written the file is attested and
    ///      `isComplete` agrees.
    function testFuzz_AttestComplete_NeverPassesAMissingChunk(
        uint16 countSeed,
        uint256 missingMask,
        uint8[8] calldata steps
    ) public {
        uint256 n = 1 + uint256(countSeed) % 300;
        bool[] memory present = new bool[](n);
        uint256 firstMissing = n;
        for (uint256 i; i < n; ++i) {
            // About one chunk in eight missing, from the mask's bits.
            present[i] = (uint256(keccak256(abi.encode(missingMask, i))) & 7) != 0;
            if (!present[i] && firstMissing == n) firstMissing = i;
        }
        (bytes32 fileId, bytes32[] memory hashes) = _file(n, 1 + n % CHUNK, present);
        uint256 prefix;
        for (uint256 s; s < steps.length; ++s) {
            uint256 step = steps[s];
            uint256 stop = prefix + step < n ? prefix + step : n;
            vm.prank(address(uint160(0xB000 + s)));
            if (firstMissing < stop) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IContentStore.ContentChunkMissing.selector,
                        fileId,
                        firstMissing,
                        hashes[firstMissing]
                    )
                );
                store.attestComplete(fileId, step);
            } else {
                assertEq(store.attestComplete(fileId, step), stop == n);
                prefix = stop;
            }
            assertEq(store.completeThrough(fileId), prefix, "prefix");
            assertLe(prefix, firstMissing, "passed a missing chunk");
            assertEq(store.isComplete(fileId), firstMissing == n, "isComplete");
        }
        // Fill every gap; then the attestation finishes in pieces of any size.
        for (uint256 i; i < n; ++i) {
            if (!present[i]) _put(hashes[i], i + 1 == n ? 1 + n % CHUNK : CHUNK, i + 7);
        }
        uint256 piece = 1 + uint256(steps[0]) % 64;
        bool done;
        for (uint256 guard; !done && guard <= n; ++guard) {
            done = store.attestComplete(fileId, piece);
        }
        assertTrue(done);
        assertEq(store.completeThrough(fileId), n);
        assertTrue(store.isComplete(fileId));
    }
}
