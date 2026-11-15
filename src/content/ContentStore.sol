// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IChunkStore } from "../interfaces/IChunkStore.sol";
import { IContentStore } from "../interfaces/IContentStore.sol";
import { SSTORE2 } from "../libraries/SSTORE2.sol";
import { Base64Validator } from "./Base64Validator.sol";

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
///
///      Linked chunks: a chunk can also be held as the concatenation of whole chunks (parts) of
///      any size, so the layout never needs one large contract creation; if a future fork
///      raises the price of code or caps it per transaction, full chunks are still built from
///      parts the chain allows. A link is keyed by the keccak256 of the bytes it concatenates,
///      checked when linking and again on every read, and its parts are immutable code this
///      store created, so a link is the same chunk as a whole write, never another one.
///
///      Manifest storage: a manifest registered in one call keeps its chunk hashes in storage
///      (one slot each); one registered from list chunks keeps only the list chunks' pointers
///      and reads hash `i` from list chunk `i / hashesPerList`. Either way the file ID is the
///      same keccak256 over the same fields.
///
///      Base64 attestation: uploads are never inspected, so a file declared `Base64` could hold
///      anything, and renderers copy such text verbatim into JSON. {attestBase64} reads the chunks
///      once, checks them against the strict alphabet and records the result; renderers embed
///      the file only when it is attested.
contract ContentStore is IContentStore {
    /// @inheritdoc IContentStore
    uint256 public constant CHUNK_SIZE = SSTORE2.MAX_CHUNK_LENGTH;
    /// @inheritdoc IContentStore
    /// @dev A safety bound, not a gas figure: it bounds the whole-file view loops and the memory
    ///      {registerManifestList} uses (the list, the ID preimage and the event, about 400 KB at
    ///      4,096). Registration from list chunks is piecewise, so no transaction grows with it.
    uint256 public constant MAX_CHUNKS = 4096;
    /// @notice Longest accepted MIME type. A safety bound on the MIME check loop.
    uint256 public constant MAX_MIME_LENGTH = 64;
    /// @inheritdoc IContentStore
    /// @dev 256 parts lets a full chunk be built from parts of 96 bytes, if a future fork ever
    ///      allowed no larger contract per transaction; reading a linked chunk costs one storage
    ///      read and one code copy per part, so the bound keeps every chunk read a bounded view.
    uint256 public constant MAX_PARTS = 256;
    /// @dev The most 32-byte hashes in one list chunk: `CHUNK_SIZE / 32` (767).
    uint256 private constant MAX_HASHES_PER_LIST = SSTORE2.MAX_CHUNK_LENGTH / 32;

    /// @dev `hashesPerList` 0: `entries` holds the chunk hashes. Otherwise `entries` holds the
    ///      pointers of the list chunks, `hashesPerList` hashes in each but the last. The digest
    ///      of digest kind 0 is `sha256`, alone in the first slot, so `sha256Of` is one read;
    ///      any other kind leaves `sha256` zero and keeps its digest in `otherDigest`.
    struct File {
        bytes32 sha256;
        uint64 length;
        uint32 chunkCount;
        uint16 hashesPerList;
        uint8 encoding;
        uint8 digestKind;
        string mimeType;
        bytes32[] entries;
        bytes32 otherDigest;
    }

    /// @dev `validated` counts the leading chunks already checked; `done` is the attestation.
    struct Attestation {
        uint64 validated;
        bool done;
    }

    mapping(bytes32 fileId => File) private _files;
    mapping(bytes32 fileId => Attestation) private _attestation;
    /// @inheritdoc IContentStore
    mapping(bytes32 chunkHash => address) public chunkPointer;
    /// @dev A linked chunk: its length in the low 64 bits, its part count above them.
    mapping(bytes32 chunkHash => uint256) private _linked;
    /// @dev The pointers of a linked chunk's parts, in order.
    mapping(bytes32 chunkHash => mapping(uint256 index => address)) private _partAt;

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
    function linkChunk(bytes32[] calldata parts) external returns (bytes32 hash) {
        uint256 n = parts.length;
        if (n == 0 || n > MAX_PARTS) revert ContentPartCountInvalid(n);
        address[] memory pointers = new address[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            address pointer = chunkPointer[parts[i]];
            if (pointer == address(0)) revert ContentChunkUnknown(parts[i]);
            pointers[i] = pointer;
            total += SSTORE2.size(pointer);
        }
        if (total > CHUNK_SIZE) revert ContentLinkTooLong(total);
        bytes memory data = new bytes(total);
        uint256 filled;
        for (uint256 i; i < n; ++i) {
            filled += SSTORE2.copyInto(pointers[i], data, filled);
        }
        hash = keccak256(data);
        if (chunkPointer[hash] != address(0)) return hash;
        uint256 held = _linked[hash] >> 64;
        if (held != 0 && held <= n) return hash;
        _linked[hash] = (n << 64) | total;
        for (uint256 i; i < n; ++i) {
            _partAt[hash][i] = pointers[i];
        }
        emit ChunkLinked(hash, parts, total);
    }

    /// @inheritdoc IContentStore
    function registerManifest(
        bytes32[] calldata chunkHashes,
        uint256 length,
        uint8 encoding,
        string calldata mimeType,
        bytes32 sha256Hash
    ) external returns (bytes32 fileId) {
        fileId = manifestId(chunkHashes, length, encoding, mimeType, sha256Hash);
        File storage f = _files[fileId];
        if (f.length != 0) return fileId;
        _record(f, chunkHashes.length, length, encoding, mimeType, sha256Hash, 0);
        f.entries = chunkHashes;
        _announce(fileId, f, chunkHashes);
    }

    /// @inheritdoc IContentStore
    function registerManifestList(
        bytes32[] calldata lists,
        uint256 hashesPerList,
        uint256 length,
        uint8 encoding,
        string calldata mimeType,
        bytes32 digest,
        uint8 digestKind
    ) external returns (bytes32 fileId) {
        (bytes32[] memory hashes, address[] memory pointers) = _loadList(lists, hashesPerList);
        fileId = digestKind == 0
            ? keccak256(abi.encode(hashes, length, encoding, mimeType, digest))
            : keccak256(abi.encode(hashes, length, encoding, mimeType, digest, digestKind));
        File storage f = _files[fileId];
        if (f.length != 0) return fileId;
        _record(f, hashes.length, length, encoding, mimeType, digest, digestKind);
        // Safe: `_loadList` bounds it by MAX_HASHES_PER_LIST (767).
        // forge-lint: disable-next-line(unsafe-typecast)
        f.hashesPerList = uint16(hashesPerList);
        for (uint256 j; j < pointers.length; ++j) {
            f.entries.push(bytes32(uint256(uint160(pointers[j]))));
        }
        _announce(fileId, f, hashes);
    }

    /// @inheritdoc IContentStore
    function manifestId(
        bytes32[] calldata chunkHashes,
        uint256 length,
        uint8 encoding,
        string calldata mimeType,
        bytes32 sha256Hash
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(chunkHashes, length, encoding, mimeType, sha256Hash));
    }

    /// @inheritdoc IContentStore
    function isComplete(bytes32 fileId) external view returns (bool) {
        File storage f = _file(fileId);
        for (uint256 i; i < f.chunkCount; ++i) {
            if (!_present(f, i)) return false;
        }
        return true;
    }

    /// @inheritdoc IContentStore
    function firstMissing(bytes32 fileId, uint256 from, uint256 to, address source)
        external
        view
        returns (uint256)
    {
        File storage f = _file(fileId);
        if (to > f.chunkCount) to = f.chunkCount;
        for (uint256 i = from; i < to; ++i) {
            if (source == address(this) ? !_present(f, i) : !_served(source, f, i)) return i;
        }
        return to;
    }

    /// @inheritdoc IContentStore
    function missingChunks(bytes32 fileId) external view returns (uint256[] memory missing) {
        File storage f = _file(fileId);
        missing = new uint256[](f.chunkCount);
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
        return FileInfo(_digest(f), f.length, f.chunkCount, f.encoding, f.mimeType, f.digestKind);
    }

    /// @inheritdoc IContentStore
    /// @dev One storage read for a SHA-256 file: registration requires a nonzero digest, so a
    ///      zero `sha256` is an unknown file or another digest kind (the length word tells).
    function sha256Of(bytes32 fileId) external view returns (bytes32 sha) {
        File storage f = _files[fileId];
        sha = f.sha256;
        if (sha == 0) {
            if (f.length == 0) revert ContentFileUnknown(fileId);
            revert ContentDigestNotSha256(fileId, f.digestKind);
        }
    }

    /// @inheritdoc IContentStore
    function chunkHash(bytes32 fileId, uint256 index) external view returns (bytes32) {
        File storage f = _file(fileId);
        if (index >= f.chunkCount) revert ContentChunkIndexOutOfBounds(fileId, index);
        return _hashAt(f, index);
    }

    /// @inheritdoc IContentStore
    function readChunk(bytes32 fileId, uint256 index) external view returns (bytes memory) {
        return _readChunk(fileId, _file(fileId), index);
    }

    /// @inheritdoc IChunkStore
    function chunkData(bytes32 chunkHash_) external view returns (bytes memory data) {
        bool found;
        (found, data) = _load(chunkHash_);
        if (!found) revert ContentChunkUnknown(chunkHash_);
    }

    /// @inheritdoc IContentStore
    function attestBase64(bytes32 fileId, uint256 maxChunks) external returns (bool done) {
        File storage f = _file(fileId);
        Attestation memory a = _attestation[fileId];
        if (a.done) return true;
        uint8 encoding = f.encoding;
        if (encoding != uint8(Encoding.Base64) && encoding != uint8(Encoding.GzipBase64)) {
            revert ContentNotBase64(fileId, encoding);
        }
        if (f.length % 4 != 0) revert ContentBase64LengthInvalid(fileId, f.length);

        uint256 count = f.chunkCount;
        uint256 stop = count - a.validated > maxChunks ? a.validated + maxChunks : count;
        _validateBase64(fileId, f, a.validated, stop);

        done = stop == count;
        // Safe: stop is at most MAX_CHUNKS.
        // forge-lint: disable-next-line(unsafe-typecast)
        _attestation[fileId] = Attestation(uint64(stop), done);
        if (done) emit Base64Attested(fileId);
        else emit Base64Progress(fileId, stop);
    }

    /// @inheritdoc IContentStore
    function isBase64Attested(bytes32 fileId) external view returns (bool) {
        return _attestation[fileId].done;
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

    /// @dev Records the declared fields after the checks every manifest must pass: 1 to
    ///      `MAX_CHUNKS` chunks, a length that fits them, a nonzero digest and a valid MIME type.
    function _record(
        File storage f,
        uint256 count,
        uint256 length,
        uint8 encoding,
        string calldata mimeType,
        bytes32 digest,
        uint8 digestKind
    ) private {
        if (count == 0 || count > MAX_CHUNKS) {
            revert ContentChunkCountInvalid(count);
        }
        if (length <= (count - 1) * CHUNK_SIZE || length > count * CHUNK_SIZE) {
            revert ContentLengthInvalid(length, count);
        }
        if (digest == bytes32(0)) revert ContentDigestMissing();
        _requireMime(mimeType);
        if (digestKind == 0) f.sha256 = digest;
        else f.otherDigest = digest;
        // Safe: the checks above bound length by MAX_CHUNKS * CHUNK_SIZE (about 100.7 MB) and
        // count by MAX_CHUNKS.
        // forge-lint: disable-next-line(unsafe-typecast)
        f.length = uint64(length);
        // forge-lint: disable-next-line(unsafe-typecast)
        f.chunkCount = uint32(count);
        f.encoding = encoding;
        f.digestKind = digestKind;
        f.mimeType = mimeType;
    }

    /// @dev Emits {ManifestRegistered} from the recorded fields (kept out of the registering
    ///      functions, whose arguments fill the stack).
    function _announce(bytes32 fileId, File storage f, bytes32[] memory hashes) private {
        emit ManifestRegistered(
            fileId, f.length, f.encoding, f.digestKind, _digest(f), f.mimeType, hashes
        );
    }

    function _digest(File storage f) private view returns (bytes32) {
        return f.digestKind == 0 ? f.sha256 : f.otherDigest;
    }

    /// @dev Reads the list chunks into one hash array and returns it with their pointers. Every
    ///      list chunk must be stored whole and hold exactly `per` hashes, the last 1 to `per`;
    ///      the total is checked against `MAX_CHUNKS` before any copy.
    function _loadList(bytes32[] calldata lists, uint256 per)
        private
        view
        returns (bytes32[] memory hashes, address[] memory pointers)
    {
        uint256 k = lists.length;
        if (per == 0 || per > MAX_HASHES_PER_LIST || k == 0) revert ContentListInvalid(0);
        pointers = new address[](k);
        uint256 bytesTotal;
        for (uint256 j; j < k; ++j) {
            address pointer = chunkPointer[lists[j]];
            if (pointer == address(0)) revert ContentChunkUnknown(lists[j]);
            uint256 n = SSTORE2.size(pointer);
            if (j + 1 < k ? n != per * 32 : n == 0 || n > per * 32 || n % 32 != 0) {
                revert ContentListInvalid(j);
            }
            pointers[j] = pointer;
            bytesTotal += n;
        }
        if (bytesTotal / 32 > MAX_CHUNKS) revert ContentChunkCountInvalid(bytesTotal / 32);
        bytes memory raw = new bytes(bytesTotal);
        uint256 filled;
        for (uint256 j; j < k; ++j) {
            filled += SSTORE2.copyInto(pointers[j], raw, filled);
        }
        // The packed hashes become a `bytes32[]` by rewriting the length word in words.
        assembly ("memory-safe") {
            hashes := raw
            mstore(hashes, div(bytesTotal, 32))
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

    /// @dev Checks chunks `[from, to)`. Everything before the `=` padding at the end of the file
    ///      must be in the alphabet; the padding bytes themselves are accepted by {_padding}. Only
    ///      the last one or two chunks can hold padding, so a call that stops before them does not
    ///      look for it. Each verified chunk buffer is released afterwards, so memory stays at one
    ///      chunk.
    function _validateBase64(bytes32 fileId, File storage f, uint256 from, uint256 to)
        private
        view
    {
        uint256 strictEnd = f.length;
        if (to + 1 >= f.chunkCount) strictEnd -= _padding(fileId, f);
        for (uint256 i = from; i < to; ++i) {
            uint256 mark;
            assembly ("memory-safe") {
                mark := mload(0x40)
            }
            bytes memory chunk = _readChunk(fileId, f, i);
            uint256 start = i * CHUNK_SIZE;
            uint256 strict = strictEnd > start ? strictEnd - start : 0;
            if (strict > chunk.length) strict = chunk.length;
            if (!Base64Validator.isAlphabet(chunk, strict)) revert ContentBase64Invalid(fileId, i);
            assembly ("memory-safe") {
                mstore(0x40, mark)
            }
        }
    }

    /// @dev How many of the file's last two bytes are `=`: 0, 1 or 2. Padding is only `=`, `==`
    ///      at the very end, so one trailing `=` means a second one needs the byte before it,
    ///      which is in the previous chunk when the last chunk holds a single byte. A `=` that is
    ///      not counted here is not in the alphabet and fails the check in {_validateBase64}.
    function _padding(bytes32 fileId, File storage f) private view returns (uint256 pad) {
        uint256 mark;
        assembly ("memory-safe") {
            mark := mload(0x40)
        }
        uint256 last = f.chunkCount - 1;
        bytes memory tail = _readChunk(fileId, f, last);
        uint256 n = tail.length;
        if (tail[n - 1] == "=") {
            // The length is a multiple of 4, so a one-byte last chunk has a full chunk before it.
            bytes1 before = n > 1 ? tail[n - 2] : _readChunk(fileId, f, last - 1)[CHUNK_SIZE - 1];
            pad = before == "=" ? 2 : 1;
        }
        assembly ("memory-safe") {
            mstore(0x40, mark)
        }
    }

    function _readChunk(bytes32 fileId, File storage f, uint256 index)
        private
        view
        returns (bytes memory data)
    {
        if (index >= f.chunkCount) revert ContentChunkIndexOutOfBounds(fileId, index);
        bytes32 hash = _hashAt(f, index);
        bool found;
        (found, data) = _load(hash);
        if (!found) revert ContentChunkMissing(fileId, index, hash);
        uint256 expected = _expectedLength(f, index);
        if (data.length != expected) {
            revert ContentChunkLengthMismatch(fileId, index, expected, data.length);
        }
    }

    /// @dev The bytes of the chunk with `hash`, whole or linked, checked against the hash, and
    ///      whether it is stored at all. A linked chunk is assembled in one buffer of its
    ///      recorded length, one code copy per part.
    function _load(bytes32 hash) private view returns (bool found, bytes memory data) {
        address pointer = chunkPointer[hash];
        if (pointer != address(0)) return (true, SSTORE2.readVerified(pointer, hash));
        uint256 linked = _linked[hash];
        uint256 n = linked >> 64;
        if (n == 0) return (false, data);
        // The low 64 bits are the length; it is at most CHUNK_SIZE.
        // forge-lint: disable-next-line(unsafe-typecast)
        data = new bytes(uint64(linked));
        uint256 filled;
        for (uint256 i; i < n; ++i) {
            filled += SSTORE2.copyInto(_partAt[hash][i], data, filled);
        }
        if (filled != data.length || keccak256(data) != hash) {
            revert ContentLinkedChunkCorrupt(hash);
        }
        found = true;
    }

    /// @dev Stored, whole or linked, with the length the layout rule requires. A whole chunk
    ///      needs only its code size; a linked one its recorded length, checked when it was
    ///      linked from immutable parts. A file chunk is never empty, so an absent link (length
    ///      0) never matches.
    function _present(File storage f, uint256 index) private view returns (bool) {
        bytes32 hash = _hashAt(f, index);
        uint256 expected = _expectedLength(f, index);
        address pointer = chunkPointer[hash];
        // The low 64 bits are the length.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (pointer == address(0)) return uint64(_linked[hash]) == expected;
        return SSTORE2.size(pointer) == expected;
    }

    /// @dev Whether `source` returns chunk `index` with the manifest's hash and length. The
    ///      returned buffer is released afterwards, so a range check keeps memory at one chunk.
    function _served(address source, File storage f, uint256 index) private view returns (bool ok) {
        uint256 mark;
        assembly ("memory-safe") {
            mark := mload(0x40)
        }
        bytes32 hash = _hashAt(f, index);
        bytes memory data = IChunkStore(source).chunkData(hash);
        ok = data.length == _expectedLength(f, index) && keccak256(data) == hash;
        assembly ("memory-safe") {
            mstore(0x40, mark)
        }
    }

    /// @dev Hash `index` of the manifest, from storage or from its list chunk's code.
    function _hashAt(File storage f, uint256 index) private view returns (bytes32 hash) {
        uint256 per = f.hashesPerList;
        if (per == 0) return f.entries[index];
        address list = address(uint160(uint256(f.entries[index / per])));
        uint256 offset = (index % per) * 32 + 1;
        assembly ("memory-safe") {
            extcodecopy(list, 0, offset, 32)
            hash := mload(0)
        }
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
