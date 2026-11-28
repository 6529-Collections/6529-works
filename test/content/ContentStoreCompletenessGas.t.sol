// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ContentStore } from "src/content/ContentStore.sol";

/// @notice Gas of `ContentStore.isComplete`, which walks every chunk of a file with no range, at
///         the store's bounds: 4,096 chunks, every chunk stored at its own cold pointer. The
///         pointers are etched at the exact chunk size and the mapping written directly, so the
///         walk does exactly the reads it does on chain; every account and slot is cooled first.
///         `IndependentStream6529.syncOnChain` calls it once per media file (up to 32) in one call.
contract ContentStoreCompletenessGasTest is Test {
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    /// @dev `chunkPointer` is the store's storage slot 2 (`test/snapshots/storage/ContentStore.json`).
    uint256 internal constant CHUNK_POINTER_SLOT = 2;

    ContentStore internal store;

    function setUp() public {
        store = new ContentStore();
    }

    /// @dev A complete file of `n` chunks with distinct hashes, each at its own pointer.
    function _completeFile(uint256 n) internal returns (bytes32 fileId, address[] memory pointers) {
        uint256 chunk = store.CHUNK_SIZE();
        bytes32[] memory hashes = new bytes32[](n);
        pointers = new address[](n);
        bytes memory code = new bytes(chunk + 1); // a STOP byte, then the chunk
        for (uint256 i; i < n; ++i) {
            hashes[i] = keccak256(abi.encode("chunk", i));
            pointers[i] = address(uint160(0xC0DE0000 + i));
            vm.etch(pointers[i], code);
            vm.store(
                address(store),
                keccak256(abi.encode(hashes[i], CHUNK_POINTER_SLOT)),
                bytes32(uint256(uint160(pointers[i])))
            );
        }
        fileId = store.registerManifest(hashes, n * chunk, 0, "video/mp4", bytes32(uint256(1)));
    }

    function _coldIsCompleteGas(bytes32 fileId, address[] memory pointers)
        internal
        returns (uint256 used)
    {
        vm.cool(address(store));
        for (uint256 i; i < pointers.length; ++i) {
            vm.cool(pointers[i]);
        }
        uint256 before = gasleft();
        bool complete = store.isComplete{ gas: 200_000_000 }(fileId);
        used = before - gasleft();
        assertTrue(complete);
    }

    /// @dev One file at `MAX_CHUNKS`: a walk of all of it is over the EIP-7825 cap, so nobody
    ///      attested would leave `isComplete` uncallable in a transaction. Attested in two pieces
    ///      of 2,048 chunks, each piece fits the cap with room, and `isComplete` is then one read.
    function test_Gas_AMaxChunksFileIsAttestedInPiecesWithinTheTransactionCap() public {
        uint256 n = store.MAX_CHUNKS();
        (bytes32 fileId, address[] memory pointers) = _completeFile(n);
        uint256 walk = _coldIsCompleteGas(fileId, pointers);
        emit log_named_uint("isComplete unattested, 4,096 cold chunks, gas", walk);
        assertGt(walk, TX_GAS_CAP, "a whole walk is over the cap");

        uint256 piece = n / 2;
        for (uint256 k; k < 2; ++k) {
            vm.cool(address(store));
            for (uint256 i; i < pointers.length; ++i) {
                vm.cool(pointers[i]);
            }
            uint256 before = gasleft();
            bool done = store.attestComplete{ gas: TX_GAS_CAP }(fileId, piece);
            uint256 used = before - gasleft();
            emit log_named_uint("attestComplete, 2,048 cold chunks, gas", used);
            assertLt(used, TX_GAS_CAP * 9 / 10, "a piece fits the cap with room");
            assertEq(done, k == 1);
        }
        assertEq(store.completeThrough(fileId), n);
        uint256 attested = _coldIsCompleteGas(fileId, new address[](0));
        emit log_named_uint("isComplete attested, gas", attested);
        assertLt(attested, 20_000, "one storage read");
    }
}
