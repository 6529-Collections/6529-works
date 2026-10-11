// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IContentStore
/// @notice Permissionless, content-addressed file storage in SSTORE2 chunks, shared by every
///         6529 Works contract (ADR 0001 §8).
/// @dev A file is a manifest: an ordered list of chunk hashes plus a declared length, MIME type,
///      encoding and SHA-256. Every chunk except the last holds exactly `CHUNK_SIZE` bytes, so
///      the same bytes always produce the same chunks and the same file ID. Chunks and manifests
///      can be uploaded in any order by anyone; reads fail closed until every chunk they need
///      exists. Integrity is per chunk (keccak256, checked on every read). The declared SHA-256 is
///      NOT recomputed on-chain: hashing a large file in memory costs quadratic gas, so it is
///      for off-chain verification only.
///
///      The file ID commits to the exact stored bytes (through the chunk hashes) and to the MIME
///      type and encoding, so it is a permanent name for one encoded stream. It is NOT a
///      content-uniqueness key: the same media stored as `Identity` and as `Gzip`, or with a
///      different MIME type, has different file IDs. Uniqueness checks belong on the decoded
///      media's SHA-256.
interface IContentStore {
    /// @notice How the stored bytes relate to the original media. The values are part of the file
    ///         ID, so they are permanent.
    /// @dev `Identity`: the stored bytes are the media. `Gzip`: an RFC 1952 gzip stream of the
    ///      media. `Base64`: RFC 4648 section 4 base64 text of the media (standard alphabet, `=`
    ///      padding, no line breaks), so a renderer can concatenate the stored bytes into a
    ///      `data:<mime>;base64,` URI without encoding anything on-chain. `GzipBase64`: that
    ///      base64 text of a gzip stream. Base64 storage costs about 33% more to upload than the
    ///      raw bytes and makes inline rendering cheap, because on-chain base64 encoding
    ///      dominates `tokenURI` gas.
    enum Encoding {
        Identity,
        Gzip,
        Base64,
        GzipBase64
    }

    /// @notice What a manifest declares about a file.
    /// @param sha256Hash SHA-256 of the fully DECODED media: base64-decoded and then gunzipped, as
    ///        `encoding` requires. This is the hash a work record commits to as the media hash.
    ///        Off-chain only.
    /// @param length Length in bytes of the STORED data, which `read` returns.
    /// @param chunkCount Number of chunks, `ceil(length / CHUNK_SIZE)`.
    /// @param encoding How to decode the stored bytes.
    /// @param mimeType MIME type of the decoded media: lowercase `type/subtype`, no parameters.
    struct FileInfo {
        bytes32 sha256Hash;
        uint256 length;
        uint256 chunkCount;
        Encoding encoding;
        string mimeType;
    }

    /// @notice A new chunk was stored. Not emitted when identical bytes are written again.
    event ChunkWritten(bytes32 indexed chunkHash, address pointer, uint256 length);

    /// @notice A new manifest was registered. Not emitted when the same manifest is registered
    ///         again.
    event ManifestRegistered(
        bytes32 indexed fileId,
        uint256 length,
        uint256 chunkCount,
        Encoding encoding,
        bytes32 sha256Hash,
        string mimeType
    );

    /// @notice No manifest is registered under `fileId`.
    error ContentFileUnknown(bytes32 fileId);
    /// @notice A manifest needs between 1 and `MAX_CHUNKS` chunks.
    error ContentChunkCountInvalid(uint256 chunkCount);
    /// @notice `length` does not fit `chunkCount` chunks of `CHUNK_SIZE` bytes, the last one
    ///         non-empty.
    error ContentLengthInvalid(uint256 length, uint256 chunkCount);
    /// @notice The declared SHA-256 must be nonzero.
    error ContentDigestMissing();
    /// @notice The MIME type is not a lowercase `type/subtype` of at most `MAX_MIME_LENGTH`
    ///         bytes.
    error ContentMimeInvalid();
    /// @notice `index` is not a chunk of the file.
    error ContentChunkIndexOutOfBounds(bytes32 fileId, uint256 index);
    /// @notice The range `[offset, offset + length)` is not inside the file.
    error ContentRangeOutOfBounds(uint256 offset, uint256 length, uint256 total);
    /// @notice Chunk `index` has not been uploaded, so the read cannot be served.
    error ContentChunkMissing(bytes32 fileId, uint256 index, bytes32 chunkHash);
    /// @notice The stored chunk has a different length than the manifest layout requires.
    error ContentChunkLengthMismatch(
        bytes32 fileId, uint256 index, uint256 expected, uint256 actual
    );

    /// @notice Stores `data` (at most 24,575 bytes) and returns its hash and pointer. Anyone
    ///         may call this at any time. Writing bytes that are already stored is a no-op that
    ///         returns the same pointer.
    /// @return hash `keccak256(data)`.
    /// @return pointer The contract holding the bytes.
    function writeChunk(bytes calldata data) external returns (bytes32 hash, address pointer);

    /// @notice Registers a file manifest, before, during or after its chunks are uploaded.
    ///         Anyone may call this. Registering a manifest again is a no-op.
    /// @param chunkHashes Ordered keccak256 hashes of the file's chunks.
    /// @param length Total stored length in bytes.
    /// @param encoding How the stored bytes encode the media.
    /// @param mimeType Lowercase `type/subtype` of the decoded media.
    /// @param sha256Hash SHA-256 of the fully decoded media, for off-chain verification.
    /// @return fileId The identifier from {manifestId}.
    function registerManifest(
        bytes32[] calldata chunkHashes,
        uint256 length,
        Encoding encoding,
        string calldata mimeType,
        bytes32 sha256Hash
    ) external returns (bytes32 fileId);

    /// @notice The file ID of a manifest (`encoding` is its enum value as a `uint8`):
    ///         `keccak256(abi.encode(chunkHashes, length, encoding, mimeType, sha256Hash))`.
    ///         It depends on nothing but the manifest (no chain ID, no address), so it can be
    ///         computed off-chain and is identical on every chain and deployment.
    function manifestId(
        bytes32[] calldata chunkHashes,
        uint256 length,
        Encoding encoding,
        string calldata mimeType,
        bytes32 sha256Hash
    ) external pure returns (bytes32);

    /// @notice Bytes in every chunk except a file's last: 24,575, EIP-170 minus the STOP byte.
    function CHUNK_SIZE() external view returns (uint256);

    /// @notice The most chunks one manifest may list. Chosen so that registering a manifest at
    ///         the limit fits the EIP-7825 transaction gas cap of 16,777,216 with margin.
    function MAX_CHUNKS() external view returns (uint256);

    /// @notice Whether every chunk of the file is stored with the length the manifest requires,
    ///         which means {read} succeeds for the whole file. Reverts for an unknown file.
    function isComplete(bytes32 fileId) external view returns (bool);

    /// @notice Indexes of the chunks still to be uploaded, in order. Bounded by `MAX_CHUNKS`.
    function missingChunks(bytes32 fileId) external view returns (uint256[] memory);

    /// @notice What the manifest declares about `fileId`.
    function fileInfo(bytes32 fileId) external view returns (FileInfo memory);

    /// @notice The hash of chunk `index` of `fileId`.
    function chunkHash(bytes32 fileId, uint256 index) external view returns (bytes32);

    /// @notice The contract storing the chunk with `chunkHash`, or zero if not stored.
    function chunkPointer(bytes32 chunkHash) external view returns (address);

    /// @notice Chunk `index` of `fileId`, verified against its hash. Reverts if missing.
    function readChunk(bytes32 fileId, uint256 index) external view returns (bytes memory);

    /// @notice The stored bytes `[offset, offset + length)` of `fileId`. Every chunk the range
    ///         touches is fully read and verified, so the cost is one chunk read per touched
    ///         chunk. Reverts, and never returns partial data, if a touched chunk is missing.
    function read(bytes32 fileId, uint256 offset, uint256 length)
        external
        view
        returns (bytes memory);
}
