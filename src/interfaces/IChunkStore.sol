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
///
///      A missing chunk: a store either reverts (as `ContentStore` does, `ContentChunkUnknown`)
///      or returns empty bytes; both are conforming and both count as missing. `WorkRecords`
///      checks an added store one chunk at a time, so a call keeps the progress it made before
///      the first missing chunk either way.
///
///      Serving duty: a store must never serve other bytes for a hash (they would fail the check
///      anyway), should answer with bounded gas and return data, and should keep serving every
///      chunk it once served, for good. Nothing on-chain enforces the last two: a file recorded
///      complete in a store stays recorded so even if the store stops serving (its
///      `MediaFileComplete` names the store), so a store's governance review must establish
///      that its bytes cannot be removed, and readers should prefer the content store's copy.
interface IChunkStore {
    /// @notice The bytes whose keccak256 hash is `chunkHash`. Reverts, or returns empty bytes,
    ///         when the store does not hold them; never returns other bytes.
    /// @param chunkHash The keccak256 hash of the chunk's bytes.
    /// @return data The chunk's bytes, or empty for a chunk the store does not hold.
    function chunkData(bytes32 chunkHash) external view returns (bytes memory data);
}
