// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { Test } from "forge-std/Test.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";

/// @notice Stateful invariants of the content store, the permissionless file storage every work's
///         on-chain copy lives in (ADR 0001 section 8).
///
///         The handler (this contract, which targets itself) writes chunks from a fixed pool,
///         again and in any order; registers manifests over them, again, with another MIME type
///         over the same chunks, and over chunks that break the layout rule; refuses malformed
///         manifests; and reads files back over random ranges. After every call:
///
///         1. Chunks are content-addressed and written once: a chunk's pointer is set by its
///            first write and never changes, and its code is exactly the chunk.
///         2. Manifests are idempotent and immutable: a file's ID is the hash of its whole
///            manifest, and its declared length, chunk list, encoding, MIME type and SHA-256
///            never change.
///         3. A file is complete exactly when every chunk it names is stored with the length the
///            layout rule gives it; `missingChunks` lists exactly the others.
///         4. A read returns exactly the bytes written, over any range whose chunks are all
///            stored with their layout lengths (so any range of a complete file); a range that
///            touches a missing or mis-sized chunk never reads.
///         Every action also predicts its outcome; any disagreement fails the campaign.
contract ContentStoreInvariantTest is Test {
    uint256 internal constant ACTIONS = 4;
    uint256 internal constant CHUNKS = 7;
    uint256 internal constant FILES = 7;

    /// @dev A file of the pool: its chunks (pool indexes), MIME type, and the manifest values
    ///      computed once in `setUp`.
    struct FileSpec {
        uint8[] chunks;
        string mime;
        uint256 length;
        bytes32 sha;
    }

    ContentStore internal store;
    bytes[CHUNKS] internal chunkData;
    bytes32[CHUNKS] internal chunkHashes;
    /// @dev The code hash of a chunk's pointer: SSTORE2 stores `0x00 || chunk`.
    bytes32[CHUNKS] internal codeHashes;
    FileSpec[FILES] internal specs;

    mapping(bytes32 hash => address) internal ghostPointer;
    mapping(uint256 file => bytes32) internal ghostFileId;
    string[] internal violations;
    mapping(bytes32 path => uint256) public hits;

    function setUp() public {
        store = new ContentStore();
        uint256 full = store.CHUNK_SIZE();
        // Two full chunks, three tails, and a short chunk that only fits last.
        uint256[CHUNKS] memory lengths = [full, full, 100, 1, 5000, 1000, 23];
        for (uint256 i; i < CHUNKS; ++i) {
            chunkData[i] = _pattern(i, lengths[i]);
            chunkHashes[i] = keccak256(chunkData[i]);
            codeHashes[i] = keccak256(bytes.concat(hex"00", chunkData[i]));
        }
        _spec(0, _list1(6), "image/png");
        _spec(1, _list1(3), "text/plain");
        _spec(2, _list2(0, 2), "image/png");
        _spec(3, _list3(0, 1, 4), "application/octet-stream");
        _spec(4, _list2(1, 0), "image/png"); // the two full chunks, reordered
        _spec(5, _list2(0, 2), "text/html"); // file 2's chunks under another MIME type
        // A short chunk where a full one belongs: the declared length is valid for two chunks,
        // but the layout rule gives chunk 0 a full chunk and chunk 1 the remaining 1,000 bytes,
        // so the file never completes and never reads.
        _spec(6, _list2(5, 0), "image/png");
        bytes4[] memory selectors = new bytes4[](ACTIONS);
        selectors[0] = this.writeChunk.selector;
        selectors[1] = this.registerManifest.selector;
        selectors[2] = this.registerMalformed.selector;
        selectors[3] = this.readBack.selector;
        targetContract(address(this));
        targetSelector(FuzzSelector(address(this), selectors));
    }

    // ------------------------------------------------------------------ actions

    /// @notice Anyone writes a chunk of the pool, maybe again: the hash is the chunk's, and a
    ///         second write returns the first pointer.
    function writeChunk(uint256 seed) external {
        uint256 i = seed % CHUNKS;
        (bytes32 hash, address pointer) = store.writeChunk(chunkData[i]);
        if (hash != chunkHashes[i]) _violation("a chunk's hash is not its keccak256");
        if (ghostPointer[hash] == address(0)) {
            ghostPointer[hash] = pointer;
            ++hits["writeChunk"];
        } else {
            if (pointer != ghostPointer[hash]) _violation("a rewrite moved a chunk");
            ++hits["rewrite"];
        }
    }

    /// @notice Anyone registers a file's manifest, maybe again: the ID is the manifest's hash,
    ///         and a second registration returns it unchanged.
    function registerManifest(uint256 seed) external {
        uint256 f = seed % FILES;
        (bytes32[] memory hashes, uint256 length, bytes32 sha) = _manifest(f);
        bytes32 id = store.registerManifest(
            hashes, length, IContentStore.Encoding.Identity, specs[f].mime, sha
        );
        if (
            id
                != store.manifestId(
                    hashes, length, IContentStore.Encoding.Identity, specs[f].mime, sha
                )
        ) {
            _violation("a file ID is not its manifest's hash");
        }
        if (ghostFileId[f] == 0) {
            ghostFileId[f] = id;
            ++hits["register"];
        } else {
            if (id != ghostFileId[f]) _violation("a re-registration changed a file ID");
            ++hits["reregister"];
        }
    }

    /// @notice Malformed manifests are refused: a length outside its chunk count, no chunk,
    ///         no SHA-256, or an invalid MIME type.
    function registerMalformed(uint256 seed) external {
        (bytes32[] memory hashes, uint256 length, bytes32 sha) = _manifest(2);
        uint256 kind = seed % 4;
        string memory mime = "image/png";
        if (kind == 0) length = length - store.CHUNK_SIZE(); // the last chunk would be empty
        if (kind == 1) hashes = new bytes32[](0);
        if (kind == 2) sha = 0;
        if (kind == 3) mime = "Image/PNG";
        try store.registerManifest(
            hashes, length, IContentStore.Encoding.Identity, mime, sha
        ) returns (
            bytes32
        ) {
            _violation("a malformed manifest registered");
        } catch (bytes memory reason) {
            bytes4[4] memory want = [
                IContentStore.ContentLengthInvalid.selector,
                IContentStore.ContentChunkCountInvalid.selector,
                IContentStore.ContentDigestMissing.selector,
                IContentStore.ContentMimeInvalid.selector
            ];
            if (bytes4(reason) != want[kind]) {
                _violation("a malformed manifest was refused for another reason");
            }
            ++hits["malformedRefused"];
        }
    }

    /// @notice Anyone reads a registered file over a random range: exactly the bytes written when
    ///         every chunk under the range is stored with its layout length, a revert otherwise.
    function readBack(uint256 seed, uint256 offsetSeed, uint256 lengthSeed) external {
        uint256 f = seed % FILES;
        bytes32 id = ghostFileId[f];
        if (id == 0) return;
        bytes memory content = _content(f);
        uint256 offset = _bound(offsetSeed, 0, content.length - 1);
        uint256 length = _bound(lengthSeed, 1, content.length - offset);
        bool readable = _readable(f, offset, length);
        try store.read(id, offset, length) returns (bytes memory out) {
            if (!readable) _violation("a range over a missing or mis-sized chunk read");
            if (keccak256(out) != _hashOf(content, offset, length)) {
                _violation("a read returned other bytes than were written");
            }
            ++hits["read"];
        } catch {
            if (readable) _violation("a stored range did not read");
            ++hits["readRefused"];
        }
    }

    // ------------------------------------------------------------------ the invariants

    /// @notice Every content store invariant (1 to 4 above). In CI the state is asserted every
    ///         fourth call and after the last call of each run (every action checks its own
    ///         outcome at once); the `deep` profile asserts it after every call.
    /// forge-config: default.invariant.check_interval = 4
    /// forge-config: deep.invariant.check_interval = 1
    function invariant_contentStore() public view {
        assertEq(violations.length, 0, violations.length == 0 ? "" : violations[0]);
        for (uint256 i; i < CHUNKS; ++i) {
            address pointer = store.chunkPointer(chunkHashes[i]);
            assertEq(pointer, ghostPointer[chunkHashes[i]], "a chunk's pointer is its first write");
            if (pointer != address(0)) {
                assertEq(pointer.codehash, codeHashes[i], "the pointer holds the chunk");
            }
        }
        for (uint256 f; f < FILES; ++f) {
            bytes32 id = ghostFileId[f];
            if (id == 0) continue;
            (bytes32[] memory hashes, uint256 length, bytes32 sha) = _manifest(f);
            IContentStore.FileInfo memory info = store.fileInfo(id);
            assertEq(info.length, length, "the declared length");
            assertEq(info.chunkCount, hashes.length, "the chunk count");
            assertEq(info.sha256Hash, sha, "the declared SHA-256");
            assertEq(info.mimeType, specs[f].mime, "the MIME type");
            for (uint256 k; k < hashes.length; ++k) {
                assertEq(store.chunkHash(id, k), hashes[k], "the chunk list");
            }
            assertEq(store.isComplete(id), _complete(f), "complete exactly when every chunk fits");
            uint256[] memory missing = store.missingChunks(id);
            uint256[] memory expected = new uint256[](hashes.length);
            uint256 n;
            for (uint256 k; k < hashes.length; ++k) {
                if (!_present(f, k)) expected[n++] = k;
            }
            assertEq(missing.length, n, "exactly the missing chunks");
            for (uint256 k; k < n; ++k) {
                assertEq(missing[k], expected[k], "the missing chunks, in order");
            }
        }
    }

    /// @notice The campaign is not vacuous: sequences of the campaign's shape replayed from fixed
    ///         seeds write, rewrite, register, re-register, refuse and read (and refuse to read).
    function test_EveryActionRuns() public {
        string[8] memory paths = [
            "writeChunk",
            "rewrite",
            "register",
            "reregister",
            "malformedRefused",
            "read",
            "readRefused",
            "brokenLayoutNeverReads"
        ];
        uint256[8] memory totals;
        for (uint256 run; run < 16; ++run) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 depth; depth < 64; ++depth) {
                uint256 seed = uint256(keccak256(abi.encode("content", run, depth)));
                uint256 which = seed % ACTIONS;
                if (which == 0) this.writeChunk(seed >> 8);
                else if (which == 1) this.registerManifest(seed >> 8);
                else if (which == 2) this.registerMalformed(seed >> 8);
                else this.readBack(seed >> 8, seed >> 64, seed >> 128);
            }
            invariant_contentStore();
            if (ghostFileId[6] != 0 && _allWritten(6)) ++hits["brokenLayoutNeverReads"];
            for (uint256 i; i < paths.length; ++i) {
                totals[i] += hits[bytes32(bytes(paths[i]))];
            }
            vm.revertToStateAndDelete(snapshot);
        }
        for (uint256 i; i < paths.length; ++i) {
            console2.log(paths[i], totals[i]);
        }
        for (uint256 i; i < paths.length; ++i) {
            assertGt(totals[i], 0, paths[i]);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _violation(string memory what) internal {
        violations.push(what);
    }

    /// @dev `length` bytes derived from `i`, each chunk distinct.
    function _pattern(uint256 i, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 k; k < length; k += 32) {
            bytes32 word = keccak256(abi.encode(i, k));
            for (uint256 j; j < 32 && k + j < length; ++j) {
                out[k + j] = word[j];
            }
        }
    }

    function _spec(uint256 f, uint8[] memory chunks, string memory mime) internal {
        FileSpec storage spec = specs[f];
        spec.mime = mime;
        for (uint256 k; k < chunks.length; ++k) {
            spec.chunks.push(chunks[k]);
            spec.length += chunkData[chunks[k]].length;
        }
        spec.sha = sha256(_content(f));
    }

    function _list1(uint8 a) internal pure returns (uint8[] memory l) {
        l = new uint8[](1);
        l[0] = a;
    }

    function _list2(uint8 a, uint8 b) internal pure returns (uint8[] memory l) {
        l = new uint8[](2);
        (l[0], l[1]) = (a, b);
    }

    function _list3(uint8 a, uint8 b, uint8 c) internal pure returns (uint8[] memory l) {
        l = new uint8[](3);
        (l[0], l[1], l[2]) = (a, b, c);
    }

    function _content(uint256 f) internal view returns (bytes memory out) {
        uint8[] storage chunks = specs[f].chunks;
        for (uint256 k; k < chunks.length; ++k) {
            out = bytes.concat(out, chunkData[chunks[k]]);
        }
    }

    /// @dev A file's chunk hashes, its declared length (the bytes of its chunks) and SHA-256.
    function _manifest(uint256 f)
        internal
        view
        returns (bytes32[] memory hashes, uint256 length, bytes32 sha)
    {
        FileSpec storage spec = specs[f];
        hashes = new bytes32[](spec.chunks.length);
        for (uint256 k; k < hashes.length; ++k) {
            hashes[k] = chunkHashes[spec.chunks[k]];
        }
        return (hashes, spec.length, spec.sha);
    }

    /// @dev Chunk `k` of file `f` is stored with the length the layout rule gives it: a full
    ///      chunk except the last, which holds the rest.
    function _present(uint256 f, uint256 k) internal view returns (bool) {
        uint8 c = specs[f].chunks[k];
        if (ghostPointer[chunkHashes[c]] == address(0)) return false;
        uint256 length = specs[f].length;
        uint256 full = store.CHUNK_SIZE();
        uint256 expected = length - k * full < full ? length - k * full : full;
        return chunkData[c].length == expected;
    }

    function _complete(uint256 f) internal view returns (bool) {
        for (uint256 k; k < specs[f].chunks.length; ++k) {
            if (!_present(f, k)) return false;
        }
        return true;
    }

    /// @dev Every chunk under `[offset, offset + length)` is stored with its layout length.
    function _readable(uint256 f, uint256 offset, uint256 length) internal view returns (bool) {
        uint256 full = store.CHUNK_SIZE();
        for (uint256 k = offset / full; k <= (offset + length - 1) / full; ++k) {
            if (!_present(f, k)) return false;
        }
        return true;
    }

    function _allWritten(uint256 f) internal view returns (bool) {
        for (uint256 k; k < specs[f].chunks.length; ++k) {
            if (ghostPointer[chunkHashes[specs[f].chunks[k]]] == address(0)) return false;
        }
        return true;
    }

    /// @dev keccak256 of `length` bytes of `data` from `from`, hashed in place.
    function _hashOf(bytes memory data, uint256 from, uint256 length)
        internal
        pure
        returns (bytes32 hash)
    {
        require(from + length <= data.length, "range");
        assembly ("memory-safe") {
            hash := keccak256(add(add(data, 0x20), from), length)
        }
    }
}
