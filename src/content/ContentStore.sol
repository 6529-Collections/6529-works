// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IContentStore } from "../interfaces/IContentStore.sol";
import { SSTORE2 } from "../libraries/SSTORE2.sol";

/// @title ContentStore
/// @notice Permissionless, content-addressed file storage in SSTORE2 chunks (ADR 0001 §8). No
///         owner, no governance, no payable function: anyone can upload any chunk or manifest at
///         any time, and anyone can complete a work's on-chain copy.
/// @dev See {IContentStore} for the model. Why the file ID covers the whole manifest and not only
///      the chunk list: a permissionless first-writer-wins record would let anyone front-run an
///      artist's manifest with a wrong MIME type or digest. With the ID committing to every
///      declared field, a different claim about the same chunks is a different file and cannot
///      overwrite or block another. Chunks are shared across files by hash.
///
///      Layout rule: every chunk except the last is exactly `CHUNK_SIZE` bytes. Offsets then map
///      to chunks by division, and a manifest whose chunk lengths break the rule never completes
///      and never reads (it reverts, it does not return wrong bytes).
contract ContentStore is IContentStore {
    /// @inheritdoc IContentStore
    uint256 public constant CHUNK_SIZE = SSTORE2.MAX_CHUNK_LENGTH;
    /// @inheritdoc IContentStore
    /// @dev 512 chunks is about 12.58 MB. Registering a manifest at the limit costs about 11.8M
    ///      gas including calldata, inside the 16,777,216 cap that EIP-7825 (Fusaka) puts on every
    ///      transaction, with room for repricing. The limit also bounds every file loop.
    uint256 public constant MAX_CHUNKS = 512;
    /// @notice Longest accepted MIME type.
    uint256 public constant MAX_MIME_LENGTH = 64;

    struct File {
        bytes32 sha256Hash;
        uint64 length;
        Encoding encoding;
        string mimeType;
        bytes32[] chunks;
    }

    mapping(bytes32 fileId => File) private _files;
    /// @inheritdoc IContentStore
    mapping(bytes32 chunkHash => address) public chunkPointer;

    /// @inheritdoc IContentStore
    function writeChunk(bytes calldata data) external returns (bytes32 hash, address pointer) {
        hash = keccak256(data);
        pointer = chunkPointer[hash];
        if (pointer != address(0)) return (hash, pointer);
        pointer = SSTORE2.write(data); // reverts above 24,575 bytes
        chunkPointer[hash] = pointer;
        emit ChunkWritten(hash, pointer, data.length);
    }

    /// @inheritdoc IContentStore
    function registerManifest(
        bytes32[] calldata chunkHashes,
        uint256 length,
        Encoding encoding,
        string calldata mimeType,
        bytes32 sha256Hash
    ) external returns (bytes32 fileId) {
        fileId = manifestId(chunkHashes, length, encoding, mimeType, sha256Hash);
        File storage f = _files[fileId];
        if (f.length != 0) return fileId;

        uint256 count = chunkHashes.length;
        if (count == 0 || count > MAX_CHUNKS) revert ContentChunkCountInvalid(count);
        if (length <= (count - 1) * CHUNK_SIZE || length > count * CHUNK_SIZE) {
            revert ContentLengthInvalid(length, count);
        }
        if (sha256Hash == bytes32(0)) revert ContentDigestMissing();
        _requireMime(mimeType);

        f.sha256Hash = sha256Hash;
        // Safe: the checks above bound length by MAX_CHUNKS * CHUNK_SIZE (about 12.6 MB).
        // forge-lint: disable-next-line(unsafe-typecast)
        f.length = uint64(length);
        f.encoding = encoding;
        f.mimeType = mimeType;
        f.chunks = chunkHashes;
        emit ManifestRegistered(fileId, length, count, encoding, sha256Hash, mimeType);
    }

    /// @inheritdoc IContentStore
    function manifestId(
        bytes32[] calldata chunkHashes,
        uint256 length,
        Encoding encoding,
        string calldata mimeType,
        bytes32 sha256Hash
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(chunkHashes, length, encoding, mimeType, sha256Hash));
    }

    /// @inheritdoc IContentStore
    function isComplete(bytes32 fileId) external view returns (bool) {
        File storage f = _file(fileId);
        for (uint256 i; i < f.chunks.length; ++i) {
            if (!_present(f, i)) return false;
        }
        return true;
    }

    /// @inheritdoc IContentStore
    function missingChunks(bytes32 fileId) external view returns (uint256[] memory missing) {
        File storage f = _file(fileId);
        missing = new uint256[](f.chunks.length);
        uint256 found;
        for (uint256 i; i < missing.length; ++i) {
            if (!_present(f, i)) missing[found++] = i;
        }
        assembly ("memory-safe") {
            mstore(missing, found)
        }
    }

    /// @inheritdoc IContentStore
    function fileInfo(bytes32 fileId) external view returns (FileInfo memory) {
        File storage f = _file(fileId);
        return FileInfo(f.sha256Hash, f.length, f.chunks.length, f.encoding, f.mimeType);
    }

    /// @inheritdoc IContentStore
    function chunkHash(bytes32 fileId, uint256 index) external view returns (bytes32) {
        File storage f = _file(fileId);
        if (index >= f.chunks.length) revert ContentChunkIndexOutOfBounds(fileId, index);
        return f.chunks[index];
    }

    /// @inheritdoc IContentStore
    function readChunk(bytes32 fileId, uint256 index) external view returns (bytes memory) {
        return _readChunk(fileId, _file(fileId), index);
    }

    /// @inheritdoc IContentStore
    function read(bytes32 fileId, uint256 offset, uint256 length)
        external
        view
        returns (bytes memory out)
    {
        File storage f = _file(fileId);
        uint256 total = f.length;
        if (offset > total || length > total - offset) {
            revert ContentRangeOutOfBounds(offset, length, total);
        }
        out = new bytes(length);
        uint256 dest;
        assembly ("memory-safe") {
            dest := add(out, 0x20)
        }
        uint256 done;
        while (done < length) {
            uint256 take = _copyFromChunk(fileId, f, offset + done, length - done, dest + done);
            done += take;
        }
    }

    /// @dev Copies up to `remaining` bytes starting at file position `position` into `dest`,
    ///      stopping at the end of the chunk, and returns how many. The verified chunk buffer is
    ///      released afterwards, so reading a large file keeps memory at the output size plus
    ///      one chunk instead of doubling it (memory gas is quadratic).
    function _copyFromChunk(
        bytes32 fileId,
        File storage f,
        uint256 position,
        uint256 remaining,
        uint256 dest
    ) private view returns (uint256 take) {
        uint256 mark;
        assembly ("memory-safe") {
            mark := mload(0x40)
        }
        uint256 within = position % CHUNK_SIZE;
        bytes memory chunk = _readChunk(fileId, f, position / CHUNK_SIZE);
        take = chunk.length - within;
        if (take > remaining) take = remaining;
        assembly ("memory-safe") {
            mcopy(dest, add(add(chunk, 0x20), within), take)
            mstore(0x40, mark)
        }
    }

    function _readChunk(bytes32 fileId, File storage f, uint256 index)
        private
        view
        returns (bytes memory data)
    {
        if (index >= f.chunks.length) revert ContentChunkIndexOutOfBounds(fileId, index);
        bytes32 hash = f.chunks[index];
        address pointer = chunkPointer[hash];
        if (pointer == address(0)) revert ContentChunkMissing(fileId, index, hash);
        data = SSTORE2.readVerified(pointer, hash);
        uint256 expected = _expectedLength(f, index);
        if (data.length != expected) {
            revert ContentChunkLengthMismatch(fileId, index, expected, data.length);
        }
    }

    /// @dev Stored with the length the layout rule requires. Needs only the chunk's code size.
    function _present(File storage f, uint256 index) private view returns (bool) {
        address pointer = chunkPointer[f.chunks[index]];
        return pointer != address(0) && SSTORE2.size(pointer) == _expectedLength(f, index);
    }

    function _expectedLength(File storage f, uint256 index) private view returns (uint256) {
        uint256 remaining = f.length - index * CHUNK_SIZE;
        return remaining < CHUNK_SIZE ? remaining : CHUNK_SIZE;
    }

    function _file(bytes32 fileId) private view returns (File storage f) {
        f = _files[fileId];
        if (f.length == 0) revert ContentFileUnknown(fileId);
    }

    /// @dev Lowercase `type/subtype` from `[a-z0-9+._-]` with exactly one interior slash, so the
    ///      value is safe to embed in JSON, `data:` URIs and HTML without escaping surprises. One
    ///      interior slash already forces at least three bytes, so there is no separate minimum.
    function _requireMime(string calldata mimeType) private pure {
        bytes calldata m = bytes(mimeType);
        if (m.length > MAX_MIME_LENGTH) revert ContentMimeInvalid();
        uint256 slashes = 0;
        for (uint256 i; i < m.length; ++i) {
            bytes1 c = m[i];
            if (c == "/") {
                if (i == 0 || i == m.length - 1) revert ContentMimeInvalid();
                ++slashes;
            } else if (!((c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "+" || c == "-"
                        || c == "." || c == "_")) {
                revert ContentMimeInvalid();
            }
        }
        if (slashes != 1) revert ContentMimeInvalid();
    }
}
