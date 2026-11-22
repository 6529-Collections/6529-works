// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { ReplayIndexer } from "./ReplayIndexer.sol";

/// @notice Rebuilds the content store's index from its own logs (WS-27, WS-50 to WS-52, WS-54):
///         every chunk written or linked (with its parts), every manifest (its chunk hashes,
///         length, encoding, digest kind, digest and MIME type), each file's completeness and
///         largest part count derived as the docs describe, each base64 attestation and each file's
///         attested prefix of present chunks.
/// @dev The chunk bytes themselves live in SSTORE2 data contracts, not in the logs; the index
///      the logs rebuild names them by `keccak256`, so `chunkData` is checked against the hash
///      and length the logs give, not copied.
contract ContentIndexer is ReplayIndexer {
    struct Linked {
        uint256 parts;
        uint256 length;
    }

    struct File {
        uint256 length;
        uint8 encoding;
        uint8 digestKind;
        bytes32 digest;
        string mimeType;
        bytes32[] chunkHashes;
        uint256 validated;
        bool attested;
        uint256 present;
    }

    uint256 private constant CHUNK_SIZE = 24_575;

    bytes32[] internal _chunks;
    mapping(bytes32 chunkHash => bool) internal _knownChunk;
    mapping(bytes32 chunkHash => address) internal _pointer;
    mapping(bytes32 chunkHash => uint256) internal _writtenLength;
    mapping(bytes32 chunkHash => Linked) internal _linked;
    bytes32[] internal _fileIds;
    mapping(bytes32 fileId => File) internal _files;

    constructor(address store_) ReplayIndexer(store_) { }

    function fileCount() external view returns (uint256) {
        return _fileIds.length;
    }

    function _apply(Vm.Log memory log) internal override {
        bytes32 sig = log.topics[0];
        bytes32 key = log.topics[1];
        if (sig == IContentStore.ChunkWritten.selector) {
            _chunk(key);
            assertEq(_pointer[key], address(0), "indexer: chunk written twice");
            (_pointer[key], _writtenLength[key]) = abi.decode(log.data, (address, uint256));
        } else if (sig == IContentStore.ChunkLinked.selector) {
            _chunk(key);
            (bytes32[] memory parts, uint256 length) = abi.decode(log.data, (bytes32[], uint256));
            uint256 total;
            for (uint256 i; i < parts.length; ++i) {
                require(_pointer[parts[i]] != address(0), "indexer: link of an unwritten part");
                total += _writtenLength[parts[i]];
            }
            assertEq(total, length, "indexer: linked length");
            // The latest link of a hash names its current parts (WS-50).
            _linked[key] = Linked(parts.length, length);
        } else if (sig == IContentStore.ManifestRegistered.selector) {
            _manifest(key, log.data);
        } else if (sig == IContentStore.Base64Progress.selector) {
            _files[key].validated = abi.decode(log.data, (uint256));
        } else if (sig == IContentStore.Base64Attested.selector) {
            File storage f = _files[key];
            (f.validated, f.attested) = (f.chunkHashes.length, true);
        } else if (sig == IContentStore.CompletenessProgress.selector) {
            uint256 present = abi.decode(log.data, (uint256));
            assertGe(present, _files[key].present, "indexer: the prefix went back");
            _files[key].present = present;
        } else if (sig == IContentStore.CompletenessAttested.selector) {
            _files[key].present = _files[key].chunkHashes.length;
        } else {
            _unknown(sig);
        }
    }

    function _manifest(bytes32 fileId, bytes memory data) private {
        File storage f = _files[fileId];
        assertEq(f.length, 0, "indexer: manifest registered twice");
        _fileIds.push(fileId);
        File memory m;
        (m.length, m.encoding, m.digestKind, m.digest, m.mimeType, m.chunkHashes) =
            abi.decode(data, (uint256, uint8, uint8, bytes32, string, bytes32[]));
        f.length = m.length;
        f.encoding = m.encoding;
        f.digestKind = m.digestKind;
        f.digest = m.digest;
        f.mimeType = m.mimeType;
        f.chunkHashes = m.chunkHashes;
        _checkFileId(fileId, f);
    }

    function _chunk(bytes32 chunkHash) private {
        if (_knownChunk[chunkHash]) return;
        _knownChunk[chunkHash] = true;
        _chunks.push(chunkHash);
    }

    /// @dev The file ID commits to the manifest's fields (WS-51, WS-54): the same formula for a
    ///      manifest registered in one call or from list chunks.
    function _checkFileId(bytes32 fileId, File storage f) private view {
        bytes32 expected = f.digestKind == 0
            ? keccak256(abi.encode(f.chunkHashes, f.length, f.encoding, f.mimeType, f.digest))
            : keccak256(
                abi.encode(f.chunkHashes, f.length, f.encoding, f.mimeType, f.digest, f.digestKind)
            );
        assertEq(fileId, expected, "indexer: file ID");
    }

    /// @dev How many parts hold chunk `index` of `f` at the length the layout requires: one for a
    ///      chunk written whole, the link's part count for a linked one, zero when missing (a
    ///      written chunk of the wrong length is not replaced by a link of the same hash).
    function _parts(File storage f, uint256 index) private view returns (uint256) {
        bytes32 h = f.chunkHashes[index];
        uint256 remaining = f.length - index * CHUNK_SIZE;
        uint256 expected = remaining < CHUNK_SIZE ? remaining : CHUNK_SIZE;
        if (_pointer[h] != address(0)) return _writtenLength[h] == expected ? 1 : 0;
        return _linked[h].length == expected ? _linked[h].parts : 0;
    }

    function assertMatches() external view override {
        IContentStore s = IContentStore(target);
        for (uint256 i; i < _chunks.length; ++i) {
            bytes32 h = _chunks[i];
            assertEq(s.chunkPointer(h), _pointer[h], "chunkPointer");
            bytes memory data = s.chunkData(h);
            assertEq(keccak256(data), h, "chunkData hash");
            uint256 length = _pointer[h] != address(0) ? _writtenLength[h] : _linked[h].length;
            assertEq(data.length, length, "chunkData length");
        }
        for (uint256 i; i < _fileIds.length; ++i) {
            _checkFile(s, _fileIds[i], _files[_fileIds[i]]);
        }
    }

    function _checkFile(IContentStore s, bytes32 id, File storage f) private view {
        IContentStore.FileInfo memory info = s.fileInfo(id);
        uint256 count = f.chunkHashes.length;
        assertEq(info.sha256Hash, f.digest, "fileInfo digest");
        assertEq(info.length, f.length, "fileInfo length");
        assertEq(info.chunkCount, count, "fileInfo chunkCount");
        assertEq(info.encoding, f.encoding, "fileInfo encoding");
        assertEq(info.mimeType, f.mimeType, "fileInfo mimeType");
        assertEq(info.digestKind, f.digestKind, "fileInfo digestKind");
        if (f.digestKind == 0) {
            assertEq(s.sha256Of(id), f.digest, "sha256Of");
        } else {
            try s.sha256Of(id) returns (bytes32) {
                revert("sha256Of answered for another digest kind");
            } catch { }
        }
        uint256 missing;
        uint256 maxParts;
        uint256 firstMissing = count;
        for (uint256 i; i < count; ++i) {
            assertEq(s.chunkHash(id, i), f.chunkHashes[i], "chunkHash");
            uint256 n = _parts(f, i);
            if (n == 0) {
                if (firstMissing == count) firstMissing = i;
                ++missing;
            } else if (n > maxParts) {
                maxParts = n;
            }
        }
        assertEq(s.isComplete(id), missing == 0, "isComplete");
        assertEq(s.completeThrough(id), f.present, "completeThrough");
        assertLe(f.present, firstMissing, "the prefix passed a missing chunk");
        assertEq(s.maxParts(id), missing == 0 ? maxParts : 0, "maxParts");
        assertEq(s.firstMissing(id, 0, count, target), firstMissing, "firstMissing");
        assertEq(s.missingChunks(id).length, missing, "missingChunks");
        assertEq(s.isBase64Attested(id), f.attested, "isBase64Attested");
    }
}
