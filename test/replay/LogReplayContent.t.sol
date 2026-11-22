// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { ReplayBase } from "./ReplayBase.sol";

/// @notice Log replay of the content store (WS-27, WS-44, WS-50 to WS-52, WS-54): a history that
///         emits every one of its events rebuilds, from those logs alone, the same chunk index,
///         manifests, completeness and attestations as the contract's views.
contract LogReplayContentTest is ReplayBase {
    function test_EveryContentEventReplaysToTheSameState() public {
        uint256 size = store.CHUNK_SIZE();
        // Two whole chunks and a short tail, written.
        bytes memory media = _bytes(2 * size + 100, 1);
        bytes32 complete =
            _upload(media, IContentStore.Encoding.Identity, "image/png", sha256(media));
        _linkedFile(size);
        _listFile();
        _base64File(size);
        assertTrue(store.isComplete(complete));
        _assertEveryEventReplayed("ContentStore", contentIdx, new string[](0));
    }

    /// @dev A file registered before its upload, whose first chunk arrives as three linked parts
    ///      and is relinked from two (WS-50: the latest link names the parts).
    function _linkedFile(uint256 size) private {
        bytes memory later = _bytes(size + 7, 2);
        bytes32 pending =
            _registerOnly(later, IContentStore.Encoding.Identity, "image/png", sha256(later));
        _sync();
        assertFalse(store.isComplete(pending));

        // The pending file's first chunk arrives as three linked parts, then is relinked from
        // two (WS-50: the latest link names the parts); its tail is written whole.
        bytes memory first = _slice(later, 0, size);
        (bytes32 a,) = store.writeChunk(_slice(first, 0, 8192));
        (bytes32 b,) = store.writeChunk(_slice(first, 8192, 8192));
        (bytes32 c,) = store.writeChunk(_slice(first, 16_384, size - 16_384));
        (bytes32 ab,) = store.writeChunk(_slice(first, 0, 16_384));
        store.linkChunk(_three(a, b, c));
        _sync();
        assertEq(store.maxParts(pending), 0, "the tail is still missing");
        store.linkChunk(_two(ab, c));
        store.writeChunk(_slice(later, size, 7));
        _sync();
        assertTrue(store.isComplete(pending));
        assertEq(store.maxParts(pending), 2);
        // Attested complete in two pieces: progress, then the attestation.
        assertFalse(store.attestComplete(pending, 1));
        _sync();
        assertTrue(store.attestComplete(pending, 5));
        _sync();
        assertEq(store.completeThrough(pending), 2);
    }

    /// @dev A manifest registered from a list chunk, with a digest kind other than SHA-256.
    function _listFile() private {
        bytes memory other = _bytes(300, 3);
        bytes32[] memory hashes = new bytes32[](1);
        (hashes[0],) = store.writeChunk(other);
        (bytes32 list,) = store.writeChunk(abi.encodePacked(hashes));
        bytes32[] memory lists = new bytes32[](1);
        lists[0] = list;
        store.registerManifestList(
            lists, 1, 300, 0, "application/octet-stream", keccak256(other), 1
        );
        _sync();
    }

    /// @dev A base64 file attested in two calls: progress, then the attestation.
    function _base64File(uint256 size) private {
        bytes memory decoded = _bytes((2 * size + 10) / 4 * 3, 4);
        bytes32 b64 = _upload(
            bytes(Base64.encode(decoded)),
            IContentStore.Encoding.Base64,
            "image/png",
            sha256(decoded)
        );
        store.attestBase64(b64, 1);
        _sync();
        store.attestBase64(b64, 10);
        _sync();
        assertTrue(store.isBase64Attested(b64));
    }

    /// @dev Negative control: the comparison fails when state and logs disagree. Slot 1 holds the
    ///      attestations; a write marks a file attested that no log attested.
    function test_IndexerDetectsStateThatLogsDoNotExplain() public {
        bytes32 fileId = cc0TextFileId;
        contentIdx.assertMatches();
        vm.store(
            address(store), keccak256(abi.encode(fileId, uint256(1))), bytes32(uint256(1 << 64))
        );
        vm.expectRevert();
        contentIdx.assertMatches();
    }

    /// @dev Negative control: slot 5 holds `completeThrough`; a prefix no log attested makes the
    ///      comparison fail.
    function test_IndexerDetectsACompletenessPrefixLogsDoNotExplain() public {
        bytes32 fileId = cc0TextFileId;
        contentIdx.assertMatches();
        vm.store(address(store), keccak256(abi.encode(fileId, uint256(5))), bytes32(uint256(1)));
        vm.expectRevert(bytes("completeThrough: 1 != 0"));
        contentIdx.assertMatches();
    }

    function _two(bytes32 x, bytes32 y) private pure returns (bytes32[] memory l) {
        l = new bytes32[](2);
        (l[0], l[1]) = (x, y);
    }

    function _three(bytes32 x, bytes32 y, bytes32 z) private pure returns (bytes32[] memory l) {
        l = new bytes32[](3);
        (l[0], l[1], l[2]) = (x, y, z);
    }
}
