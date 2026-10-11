// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { SSTORE2 } from "src/libraries/SSTORE2.sol";

/// @dev Fixtures shared by the content tests: deterministic bytes, canonical chunking, and
///      manifest registration that mirrors what an off-chain uploader does.
abstract contract ContentBase is Test {
    uint256 internal constant CHUNK = SSTORE2.MAX_CHUNK_LENGTH;
    string internal constant HTML = "text/html";
    /// @dev A nonzero placeholder SHA-256 for manifests whose bytes the test never reads.
    bytes32 internal constant DIGEST = bytes32(uint256(1));

    ContentStore internal store;

    /// @dev Pseudo-random bytes that differ per seed (so chunks do not collide by accident).
    function _data(uint256 length, uint256 seed) internal pure returns (bytes memory out) {
        out = new bytes(length);
        // The allocation is padded to a whole word, so writing the last word in full is safe.
        for (uint256 i; i < length; i += 32) {
            bytes32 word = keccak256(abi.encode(seed, i));
            assembly ("memory-safe") {
                mstore(add(add(out, 0x20), i), word)
            }
        }
    }

    function _slice(bytes memory source, uint256 start, uint256 length)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(length);
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(source, 0x20), start), length)
        }
    }

    /// @dev Canonical chunking: full chunks, then the remainder.
    function _split(bytes memory file)
        internal
        pure
        returns (bytes[] memory chunks, bytes32[] memory hashes)
    {
        uint256 count = (file.length + CHUNK - 1) / CHUNK;
        chunks = new bytes[](count);
        hashes = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            uint256 start = i * CHUNK;
            uint256 size = file.length - start < CHUNK ? file.length - start : CHUNK;
            chunks[i] = _slice(file, start, size);
            hashes[i] = keccak256(chunks[i]);
        }
    }

    /// @dev Registers the manifest for `file` without uploading any chunk.
    function _declare(bytes memory file, IContentStore.Encoding encoding, string memory mime)
        internal
        returns (bytes32 fileId, bytes[] memory chunks, bytes32[] memory hashes)
    {
        (chunks, hashes) = _split(file);
        fileId = store.registerManifest(hashes, file.length, encoding, mime, sha256(file));
    }

    function _uploadAll(bytes[] memory chunks) internal {
        for (uint256 i; i < chunks.length; ++i) {
            store.writeChunk(chunks[i]);
        }
    }

    /// @dev Performs one call to the store and returns the gas it used, measured around the call
    ///      itself without copying return data into the test, so the figure is what the store
    ///      costs a caller and not the test's own memory expansion.
    function _gasOf(bytes memory callData) internal returns (uint256 used) {
        address target = address(store);
        bool ok;
        assembly ("memory-safe") {
            let before := gas()
            ok := call(gas(), target, 0, add(callData, 0x20), mload(callData), 0, 0)
            used := sub(before, gas())
        }
        assertTrue(ok, "measured call failed");
    }

    /// @dev Calldata gas of a transaction: 16 per non-zero byte, 4 per zero byte (EIP-2028). The
    ///      EIP-7623 floor (10 per zero byte, 40 per non-zero byte) only applies when execution
    ///      is cheaper than that, which is never the case for the calls measured here.
    function _calldataGas(bytes memory callData) internal pure returns (uint256 gas) {
        for (uint256 i; i < callData.length; ++i) {
            gas += callData[i] == 0 ? 4 : 16;
        }
    }

    /// @dev A complete, readable file.
    function _publish(bytes memory file, IContentStore.Encoding encoding, string memory mime)
        internal
        returns (bytes32 fileId)
    {
        bytes[] memory chunks;
        (fileId, chunks,) = _declare(file, encoding, mime);
        _uploadAll(chunks);
    }
}
