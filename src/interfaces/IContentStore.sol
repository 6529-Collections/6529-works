// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { IChunkStore } from "./IChunkStore.sol";

/// @title IContentStore
/// @notice Permissionless, content-addressed file storage in SSTORE2 chunks, shared by every
///         6529 Stream contract (ADR 0001 §8).
/// @dev A file is a manifest: an ordered list of chunk hashes plus a declared length, MIME type,
///      encoding and digest. Every chunk except the last holds exactly `CHUNK_SIZE` bytes, so
///      the same bytes always produce the same chunks and the same file ID. Chunks and manifests
///      can be uploaded in any order by anyone; reads fail closed until every chunk they need
///      exists. Integrity is per chunk (keccak256, checked on every read). The declared digest
///      (SHA-256 for digest kind 0) is NOT recomputed on-chain: hashing a large file in memory
///      costs quadratic gas, so it is for off-chain verification only.
///
///      A chunk is held whole (one SSTORE2 contract, {writeChunk}) or linked ({linkChunk}): the
///      concatenation of smaller stored chunks, recorded under the hash of the concatenated
///      bytes. Either way it has the same hash, the same bytes and the same place in every
///      manifest that lists it, so a full chunk never needs one large contract creation.
///
///      Every operation can be done in pieces of the caller's size: chunks and parts one per
///      call, a large manifest's hash list as ordinary chunks ({registerManifestList}),
///      completeness by range ({firstMissing}) or attested by count ({attestComplete}), base64
///      attestation by count ({attestBase64}), reads by
///      chunk ({readChunk}) or byte range ({read}).
///
///      The file ID commits to the exact stored bytes (through the chunk hashes) and to the MIME
///      type, encoding and digest, so it is a permanent name for one encoded stream. It is NOT a
///      content-uniqueness key: the same media stored as `Identity` and as `Gzip`, or with a
///      different MIME type, has different file IDs. Uniqueness checks belong on the decoded
///      media's digest.
///
///      Encodings and digest kinds are open numeric ids: the store records any value and
///      interprets only what its own guarantees need (base64 attestation for encodings 2 and 3;
///      `sha256Of` only for digest kind 0). Readers give other values their meaning.
///
///      Stored base64 text is copied verbatim into token JSON and `data:` URIs by renderers, and
///      the store does not look at bytes while chunks are uploaded, so a file declared `Base64`
///      or `GzipBase64` is only known to be base64 after {attestBase64}. Renderers must embed
///      such a file only when {isBase64Attested} is true.
interface IContentStore is IChunkStore {
    /// @notice The encoding ids this protocol defines. An encoding is a `uint8` in every
    ///         function, event and file ID; these four keep their numbers forever, and any other
    ///         number is recorded without interpretation.
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
    /// @param sha256Hash The declared digest of the fully DECODED media (base64-decoded and then
    ///        gunzipped, as `encoding` requires): its SHA-256 when `digestKind` is 0. A work's
    ///        media list declares the same value per file (`MediaFile.sha256Hash`, committed by
    ///        the item's `mediaHash`). Off-chain only.
    /// @param length Length in bytes of the STORED data, which `read` returns.
    /// @param chunkCount Number of chunks, `ceil(length / CHUNK_SIZE)`.
    /// @param encoding How to decode the stored bytes: an {Encoding} value or another id.
    /// @param mimeType MIME type of the decoded media: lowercase `type/subtype`, no parameters.
    /// @param digestKind What `sha256Hash` is: 0 for SHA-256, any other id as readers define.
    ///        Last, so the first five words of the encoded answer keep their places.
    struct FileInfo {
        bytes32 sha256Hash;
        uint256 length;
        uint256 chunkCount;
        uint8 encoding;
        string mimeType;
        uint8 digestKind;
    }

    /// @notice A new chunk was stored whole. Not emitted when identical bytes are written again.
    /// @param chunkHash The keccak256 hash of the chunk's bytes.
    /// @param pointer The SSTORE2 contract holding the bytes.
    /// @param length The chunk's length in bytes.
    event ChunkWritten(bytes32 indexed chunkHash, address pointer, uint256 length);

    /// @notice A chunk was linked from stored parts, or relinked from fewer parts. The latest
    ///         event for a hash describes its current parts; the bytes never change.
    /// @param chunkHash The keccak256 hash of the concatenated bytes.
    /// @param parts The hashes of the whole chunks concatenated, in order.
    /// @param length The linked chunk's length in bytes.
    event ChunkLinked(bytes32 indexed chunkHash, bytes32[] parts, uint256 length);

    /// @notice A new manifest was registered. Not emitted when the same manifest is registered
    ///         again. With {ChunkWritten} and {ChunkLinked} it reconstructs the whole index.
    /// @param fileId The file ID ({manifestId}).
    /// @param length The stored length in bytes.
    /// @param encoding How the stored bytes encode the media.
    /// @param digestKind What `digest` is (0: SHA-256).
    /// @param digest The declared digest of the decoded media.
    /// @param mimeType The MIME type of the decoded media.
    /// @param chunkHashes The file's chunk hashes, in order.
    event ManifestRegistered(
        bytes32 indexed fileId,
        uint256 length,
        uint8 encoding,
        uint8 digestKind,
        bytes32 digest,
        string mimeType,
        bytes32[] chunkHashes
    );

    /// @notice The stored base64 text of `fileId` is valid so far: `chunksValidated` chunks of it
    ///         are checked, and more calls to {attestBase64} are needed.
    /// @param fileId The file being attested.
    /// @param chunksValidated The number of leading chunks checked so far.
    event Base64Progress(bytes32 indexed fileId, uint256 chunksValidated);

    /// @notice Every chunk of `fileId` is valid base64 text, once and for all. Emitted once.
    /// @param fileId The attested file.
    event Base64Attested(bytes32 indexed fileId);

    /// @notice The leading `chunksPresent` chunks of `fileId` are all stored at the lengths the
    ///         manifest requires; more calls to {attestComplete} are needed.
    /// @param fileId The file being attested.
    /// @param chunksPresent The number of leading chunks attested present so far.
    event CompletenessProgress(bytes32 indexed fileId, uint256 chunksPresent);

    /// @notice Every chunk of `fileId` is stored at the length the manifest requires, once and
    ///         for all: {isComplete} is true for good. Emitted once.
    /// @param fileId The attested file.
    event CompletenessAttested(bytes32 indexed fileId);

    /// @notice No manifest is registered under `fileId`.
    error ContentFileUnknown(bytes32 fileId);
    /// @notice A manifest needs between 1 and `MAX_CHUNKS` chunks.
    error ContentChunkCountInvalid(uint256 chunkCount);
    /// @notice `length` does not fit `chunkCount` chunks of `CHUNK_SIZE` bytes, the last one
    ///         non-empty.
    error ContentLengthInvalid(uint256 length, uint256 chunkCount);
    /// @notice The declared digest must be nonzero.
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
    /// @notice Only `Base64` and `GzipBase64` files can be attested as base64.
    error ContentNotBase64(bytes32 fileId, uint8 encoding);
    /// @notice A base64 text is a whole number of 4-byte groups, so its length is a multiple of 4.
    error ContentBase64LengthInvalid(bytes32 fileId, uint256 length);
    /// @notice Chunk `index` holds a byte outside `[A-Za-z0-9+/]`, or `=` anywhere but as the
    ///         last one or two bytes of the file.
    error ContentBase64Invalid(bytes32 fileId, uint256 index);
    /// @notice No chunk with `chunkHash` is stored (whole, or linked where a linked one counts).
    error ContentChunkUnknown(bytes32 chunkHash);
    /// @notice A link needs between 1 and `MAX_PARTS` parts.
    error ContentPartCountInvalid(uint256 parts);
    /// @notice The parts of a link add up to `length` bytes, more than `CHUNK_SIZE`.
    error ContentLinkTooLong(uint256 length);
    /// @notice List chunk `index` of a manifest list does not hold the declared number of
    ///         hashes (every list chunk but the last exactly `hashesPerList`, the last 1 to
    ///         `hashesPerList`), or `hashesPerList` is 0 or above `CHUNK_SIZE / 32`.
    error ContentListInvalid(uint256 index);
    /// @notice `sha256Of` was asked about a file whose digest is not a SHA-256.
    error ContentDigestNotSha256(bytes32 fileId, uint8 digestKind);
    /// @notice A linked chunk's parts no longer concatenate to its hash.
    error ContentLinkedChunkCorrupt(bytes32 chunkHash);

    /// @notice Stores `data` (at most 24,575 bytes) whole and returns its hash and pointer.
    ///         Anyone may call this at any time. Writing bytes that are already stored whole is a
    ///         no-op that returns the same pointer. A chunk of any size can serve as a part of a
    ///         linked chunk ({linkChunk}) or as a list chunk ({registerManifestList}).
    /// @param data The bytes of one chunk.
    /// @return hash `keccak256(data)`.
    /// @return pointer The contract holding the bytes.
    function writeChunk(bytes calldata data) external returns (bytes32 hash, address pointer);

    /// @notice Stores a chunk as the concatenation of whole chunks this store already holds,
    ///         so that a full `CHUNK_SIZE` chunk can be built from parts of any sizes the caller
    ///         chooses. Anyone may call this. The result is recorded under the keccak256 hash of
    ///         the concatenated bytes, so it is the same chunk, with the same hash and bytes, as
    ///         if it had been written whole, and every manifest that lists that hash counts it.
    ///         A no-op that returns the hash when the chunk is already held whole, or linked from
    ///         as many parts or fewer; a link from fewer parts replaces a longer one (the bytes
    ///         are identical, only the read cost drops).
    /// @param parts Hashes of whole chunks (each stored by {writeChunk}), in order: 1 to
    ///        `MAX_PARTS` of them (`ContentPartCountInvalid`), each stored
    ///        (`ContentChunkUnknown`), at most `CHUNK_SIZE` bytes together
    ///        (`ContentLinkTooLong`).
    /// @return hash The keccak256 hash of the concatenated bytes.
    function linkChunk(bytes32[] calldata parts) external returns (bytes32 hash);

    /// @notice Registers a file manifest in one call, before, during or after its chunks are
    ///         uploaded, with a SHA-256 digest (digest kind 0). Anyone may call this.
    ///         Registering a manifest again is a no-op. A manifest whose chunks cannot exist,
    ///         such as a zero chunk hash, or whose chunk lengths break the layout rule, is
    ///         accepted but never completes and never reads. It stores one slot per chunk hash,
    ///         so a large manifest is registered in pieces with {registerManifestList} instead.
    /// @param chunkHashes Ordered keccak256 hashes of the file's chunks.
    /// @param length Total stored length in bytes.
    /// @param encoding How the stored bytes encode the media (an open id, see {Encoding}).
    /// @param mimeType Lowercase `type/subtype` of the decoded media.
    /// @param sha256Hash SHA-256 of the fully decoded media, for off-chain verification.
    /// @return fileId The identifier from {manifestId}.
    function registerManifest(
        bytes32[] calldata chunkHashes,
        uint256 length,
        uint8 encoding,
        string calldata mimeType,
        bytes32 sha256Hash
    ) external returns (bytes32 fileId);

    /// @notice Registers a file manifest whose chunk-hash list is already stored as ordinary
    ///         chunks ("list chunks", each the packed hashes `abi.encodePacked(hashes[a:b])`,
    ///         written with {writeChunk} one per call), so a manifest of any size up to
    ///         `MAX_CHUNKS` is uploaded in pieces of the caller's size and registered by one
    ///         small call. The file ID is the same as {registerManifest} gives for the same
    ///         fields. Anyone may call this; registering again is a no-op.
    /// @param lists Hashes of the list chunks, in order, each stored whole
    ///        (`ContentChunkUnknown` otherwise).
    /// @param hashesPerList Hashes in every list chunk but the last, which holds 1 to that many:
    ///        1 to `CHUNK_SIZE / 32` (`ContentListInvalid` otherwise).
    /// @param length Total stored length in bytes.
    /// @param encoding How the stored bytes encode the media (an open id, see {Encoding}).
    /// @param mimeType Lowercase `type/subtype` of the decoded media.
    /// @param digest The declared digest of the fully decoded media, nonzero.
    /// @param digestKind What `digest` is: 0 for SHA-256, any other id as readers define.
    /// @return fileId The file ID: {manifestId} for digest kind 0, and
    ///         `keccak256(abi.encode(chunkHashes, length, encoding, mimeType, digest,
    ///         digestKind))` otherwise.
    function registerManifestList(
        bytes32[] calldata lists,
        uint256 hashesPerList,
        uint256 length,
        uint8 encoding,
        string calldata mimeType,
        bytes32 digest,
        uint8 digestKind
    ) external returns (bytes32 fileId);

    /// @notice The file ID of a manifest with a SHA-256 digest:
    ///         `keccak256(abi.encode(chunkHashes, length, encoding, mimeType, sha256Hash))`.
    ///         It depends on nothing but the manifest (no chain ID, no address), so it can be
    ///         computed off-chain and is identical on every chain and deployment. A manifest of
    ///         another digest kind appends `digestKind` to the encoded fields.
    /// @param chunkHashes Ordered keccak256 hashes of the file's chunks.
    /// @param length Total stored length in bytes.
    /// @param encoding How the stored bytes encode the media.
    /// @param mimeType Lowercase `type/subtype` of the decoded media.
    /// @param sha256Hash SHA-256 of the fully decoded media.
    /// @return The file ID. Nothing is validated, so a manifest `registerManifest` would refuse
    ///        still has one.
    function manifestId(
        bytes32[] calldata chunkHashes,
        uint256 length,
        uint8 encoding,
        string calldata mimeType,
        bytes32 sha256Hash
    ) external pure returns (bytes32);

    /// @notice Bytes in every chunk except a file's last: 24,575, EIP-170 minus the STOP byte.
    /// @return The chunk size in bytes.
    function CHUNK_SIZE() external view returns (uint256);

    /// @notice The most chunks one manifest may list (about 100.66 MB at 4,096). A safety bound:
    ///         it bounds every whole-file loop and the memory {registerManifestList} uses.
    /// @return The chunk limit (4,096 in `ContentStore`).
    function MAX_CHUNKS() external view returns (uint256);

    /// @notice The most parts one linked chunk may have. A safety bound on the work of reading
    ///         a linked chunk, which is one storage read and one code copy per part.
    /// @return The part limit (256 in `ContentStore`).
    function MAX_PARTS() external view returns (uint256);

    /// @notice Whether every chunk of the file is stored, whole or linked, with the length the
    ///         manifest requires, which means {read} succeeds for the whole file. Reverts for an
    ///         unknown file. It checks only the chunks past the file's attested prefix
    ///         ({completeThrough}): one storage read for an attested file, one loop over the
    ///         whole file for a file nobody attested. The loop's cost grows with the chunks it
    ///         checks, and for the largest files it exceeds one transaction's gas cap: a caller
    ///         (or a contract that calls this in a transaction) must have such a file attested
    ///         first, in pieces ({attestComplete}). Presence never goes away (chunks are immutable code and a
    ///         link is only ever replaced by the same bytes), so the answer never turns false.
    /// @param fileId A registered file ID (`ContentFileUnknown` otherwise).
    /// @return True when the whole file can be read.
    function isComplete(bytes32 fileId) external view returns (bool);

    /// @notice The most stored parts any one chunk of the file is read from, or zero when the
    ///         file is not complete ({isComplete}): one when every chunk is stored whole, else
    ///         the largest part count of a chunk held only as a link. Each part costs a reader
    ///         one storage read and one code copy, so a reader with a budget bounds it. It never
    ///         rises: a whole write of a chunk, or a link from fewer parts, replaces a link
    ///         (anyone may write either), and nothing replaces a whole chunk.
    /// @param fileId A registered file ID (`ContentFileUnknown` otherwise).
    /// @return parts The largest part count of a chunk, or zero for an incomplete file.
    function maxParts(bytes32 fileId) external view returns (uint256 parts);

    /// @notice The first chunk index in `[from, to)` that `source` does not serve, or `to` when
    ///         it serves all of them (`to` is capped at the chunk count). With `source` this
    ///         store, a chunk counts when it is stored whole or linked at the length the layout
    ///         requires. With any other `source`, each chunk is fetched by
    ///         {IChunkStore.chunkData} with all the gas the call may forward and at most one
    ///         chunk's ABI encoding of return data copied, and counts only when its keccak256
    ///         hash and length are the manifest's; a source that refuses (reverts, or answers
    ///         more or other than that encoding) does not serve the chunk, and a read that left
    ///         at most 1/8 of the gas reverts with `BoundedCall.BoundedCallShortfall`. The
    ///         caller picks the range, so a check of any file fits any budget.
    /// @param fileId A registered file ID (`ContentFileUnknown` otherwise).
    /// @param from The first chunk index to check.
    /// @param to One past the last chunk index to check.
    /// @param source This store, or another {IChunkStore} to check against the manifest.
    /// @return The first chunk index not served, or the capped `to`.
    function firstMissing(bytes32 fileId, uint256 from, uint256 to, address source)
        external
        view
        returns (uint256);

    /// @notice Indexes of the chunks still to be uploaded, in order. One loop over the whole
    ///         file: use {firstMissing} for pieces.
    /// @param fileId A registered file ID (`ContentFileUnknown` otherwise).
    /// @return The indexes of the chunks not stored at their required length, ascending; empty
    ///        for a complete file.
    function missingChunks(bytes32 fileId) external view returns (uint256[] memory);

    /// @notice What the manifest declares about `fileId`.
    /// @param fileId A registered file ID (`ContentFileUnknown` otherwise).
    /// @return The declared digest, stored length, chunk count, encoding, MIME type and digest
    ///         kind.
    function fileInfo(bytes32 fileId) external view returns (FileInfo memory);

    /// @notice The declared SHA-256 of the decoded file: `fileInfo(fileId).sha256Hash` without
    ///         the rest of the record. Products key content uniqueness on it (it does not depend
    ///         on MIME type or encoding). Reverts for an unknown file, and with
    ///         `ContentDigestNotSha256` for a file whose digest kind is not 0.
    /// @param fileId A registered file ID (`ContentFileUnknown` otherwise).
    /// @return The declared SHA-256, which is never zero.
    function sha256Of(bytes32 fileId) external view returns (bytes32);

    /// @notice The hash of chunk `index` of `fileId`.
    /// @param fileId A registered file ID (`ContentFileUnknown` otherwise).
    /// @param index The chunk index, below the file's chunk count
    ///        (`ContentChunkIndexOutOfBounds` otherwise).
    /// @return The keccak256 hash the manifest lists for that chunk.
    function chunkHash(bytes32 fileId, uint256 index) external view returns (bytes32);

    /// @notice The contract storing the chunk with `chunkHash` whole, or zero if it is not
    ///         stored whole (a linked chunk has no single pointer: read it with
    ///         {IChunkStore.chunkData}, or its parts from {ChunkLinked}).
    /// @param chunkHash The keccak256 hash of the chunk's bytes.
    /// @return The SSTORE2 pointer, or zero.
    function chunkPointer(bytes32 chunkHash) external view returns (address);

    /// @notice Chunk `index` of `fileId`, whole or linked, verified against its hash. Reverts
    ///         if missing.
    /// @param fileId A registered file ID (`ContentFileUnknown` otherwise).
    /// @param index The chunk index, below the file's chunk count
    ///        (`ContentChunkIndexOutOfBounds` otherwise).
    /// @return The chunk's bytes.
    function readChunk(bytes32 fileId, uint256 index) external view returns (bytes memory);

    /// @notice Checks that the stored bytes of a `Base64` or `GzipBase64` file are strict RFC 4648
    ///         base64 text: every byte in `[A-Za-z0-9+/]`, except that `=` may be the last one or
    ///         two bytes of the whole file, and the length is a multiple of 4. Anyone may call
    ///         this, and it is one-time: once a file is attested the call is a no-op that returns
    ///         true. Each call checks up to `maxChunks` more chunks, continuing where the last
    ///         call stopped, so a file of any size is attested in pieces of the caller's size by
    ///         repeating the call until it returns true.
    ///
    ///         Reverts with `ContentBase64Invalid(fileId, index)` for the first chunk with a bad
    ///         byte, and with `ContentNotBase64` or `ContentBase64LengthInvalid` for a file that
    ///         cannot qualify. Every chunk a call checks must exist at its required length, or it
    ///         reverts with `ContentChunkMissing` or `ContentChunkLengthMismatch`. A call that
    ///         reaches the end of the file (the last call, or the only one) also reads the file's
    ///         last one or two chunks to find the `=` padding, so those must exist before it can
    ///         succeed: the last call cannot succeed until the file is complete.
    /// @param fileId A registered `Base64` or `GzipBase64` file (`ContentFileUnknown` for an
    ///        unknown one).
    /// @param maxChunks The most chunks this call checks; 0 checks none.
    /// @return done True when the whole file is attested.
    function attestBase64(bytes32 fileId, uint256 maxChunks) external returns (bool done);

    /// @notice Whether {attestBase64} has validated the whole stored text of `fileId`. False for
    ///         an unknown file or one that was never attested. Never reverts.
    /// @param fileId Any file ID.
    /// @return True once the file's attestation is done.
    function isBase64Attested(bytes32 fileId) external view returns (bool);

    /// @notice Attests, in pieces, that every chunk of `fileId` is stored at the length the
    ///         manifest requires. Anyone may call. Each call checks up to `maxChunks` more
    ///         chunks, continuing from {completeThrough}, and advances it over them; it reverts
    ///         with `ContentChunkMissing(fileId, index, chunkHash)` at the first chunk not stored
    ///         at its required length, so the prefix never passes a missing or wrong chunk. The
    ///         call that reaches the end emits {CompletenessAttested}; from then on the call is a
    ///         no-op that returns true. Repeat it until it returns true to attest a file of any
    ///         size in pieces of the caller's size. Nothing lowers the prefix.
    /// @param fileId A registered file ID (`ContentFileUnknown` otherwise).
    /// @param maxChunks The most chunks this call checks; 0 checks none.
    /// @return done True when the whole file is attested.
    function attestComplete(bytes32 fileId, uint256 maxChunks) external returns (bool done);

    /// @notice How many leading chunks of `fileId` {attestComplete} has attested present: the
    ///         chunk count once the file is attested complete, zero for an unknown file or one
    ///         never attested. Never reverts.
    /// @param fileId Any file ID.
    /// @return The attested prefix, in chunks.
    function completeThrough(bytes32 fileId) external view returns (uint256);

    /// @notice The stored bytes `[offset, offset + length)` of `fileId`. Every chunk the range
    ///         touches is fully read and verified, so the cost is one chunk read per touched
    ///         chunk. Reverts, and never returns partial data, if a touched chunk is missing.
    /// @param fileId A registered file ID (`ContentFileUnknown` otherwise).
    /// @param offset The position of the first stored byte to return.
    /// @param length The number of bytes to return; the range must lie inside the stored data
    ///        (`ContentRangeOutOfBounds` otherwise).
    /// @return The `length` stored bytes from `offset`.
    function read(bytes32 fileId, uint256 offset, uint256 length)
        external
        view
        returns (bytes memory);
}
