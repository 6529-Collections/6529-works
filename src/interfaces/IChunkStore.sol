// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChunkStore
/// @notice The one function an on-chain store must offer for its copy of a content-store file
///         to be checked chunk by chunk: the bytes of a chunk, looked up by their keccak256
///         hash.
/// @dev The interface is the store-adapter contract between storage media and the records
///      contract. A store is never trusted for bytes: the checker (`ContentStore.firstMissing`
///      with the store as `source`) hashes what comes back and compares the hash and length
///      with the file's manifest, so a store can only answer correctly or fail. `ContentStore`
///      implements it for its own chunks, whole or linked.
interface IChunkStore {
    /// @notice The bytes whose keccak256 hash is `chunkHash`. Reverts when the store does not
    ///         hold them; never returns other bytes.
    /// @param chunkHash The keccak256 hash of the chunk's bytes.
    /// @return data The chunk's bytes.
    function chunkData(bytes32 chunkHash) external view returns (bytes memory data);
}
