// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ContentStore } from "src/content/ContentStore.sol";

/// @notice Gas of `ContentStore.isComplete`, which walks every chunk of a file with no range, at
///         the store's bounds: 4,096 chunks, every chunk stored at its own cold pointer. The
///         pointers are etched at the exact chunk size and the mapping written directly, so the
///         walk does exactly the reads it does on chain; every account and slot is cooled first.
///         `FederatedStream.syncOnChain` calls it once per media file (up to 32) in one call.
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

    /// @dev One file at `MAX_CHUNKS`: the walk alone exceeds the EIP-7825 cap, so no transaction
    ///      can call `isComplete` on it, and `syncOnChain` of a work holding it can never succeed.
    function test_Gas_IsCompleteAtMaxChunksExceedsTheTransactionCap() public {
        uint256 n = store.MAX_CHUNKS();
        (bytes32 fileId, address[] memory pointers) = _completeFile(n);
        uint256 used = _coldIsCompleteGas(fileId, pointers);
        emit log_named_uint("isComplete, 4,096 cold chunks, gas", used);
        emit log_named_uint("per chunk", used / n);
        emit log_named_uint("largest chunk count under the cap", TX_GAS_CAP / (used / n));
        assertGt(used, TX_GAS_CAP, "over the transaction cap");
    }
}
