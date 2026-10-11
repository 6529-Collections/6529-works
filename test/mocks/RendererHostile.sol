// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IContentStore } from "src/interfaces/IContentStore.sol";

/// @dev A content store that answers `fileInfo`, `isComplete` and `readChunk` for a work record
///      (`RECORD`, always honest) and for one base64 file of `'A'` bytes (every other ID), and
///      misbehaves for that file in the way `mode` says.
contract HostileStore {
    enum Mode {
        Honest,
        EmptyChunk,
        LongChunk,
        ShortChunk,
        RevertChunk,
        BurnChunk,
        BombChunk,
        NonBoolComplete,
        BurnComplete,
        BombInfo
    }

    uint256 internal constant CHUNK = 24_575;
    bytes32 public constant RECORD = keccak256("record");
    uint256 public length;
    Mode public mode;
    bytes public json;

    constructor(uint256 length_, Mode mode_, bytes memory json_) {
        (length, mode, json) = (length_, mode_, json_);
    }

    function fileInfo(bytes32 id) external view returns (IContentStore.FileInfo memory) {
        if (id == RECORD) {
            return IContentStore.FileInfo(
                bytes32(uint256(1)),
                json.length,
                1,
                IContentStore.Encoding.Identity,
                "application/json"
            );
        }
        if (mode == Mode.BombInfo) {
            return IContentStore.FileInfo(
                bytes32(uint256(1)), length, 1, IContentStore.Encoding.Base64, string(_a(4_000))
            );
        }
        return IContentStore.FileInfo(
            bytes32(uint256(1)),
            length,
            (length + CHUNK - 1) / CHUNK,
            IContentStore.Encoding.Base64,
            "image/png"
        );
    }

    function isComplete(bytes32 id) external view returns (bool) {
        if (id == RECORD) return true;
        if (mode == Mode.NonBoolComplete) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (mode == Mode.BurnComplete) {
            for (;;) { }
        }
        return true;
    }

    function readChunk(bytes32 id, uint256 index) external view returns (bytes memory) {
        if (id == RECORD) return json;
        if (mode == Mode.RevertChunk) revert("no");
        if (mode == Mode.BurnChunk) {
            for (;;) { }
        }
        uint256 expected = length - index * CHUNK < CHUNK ? length - index * CHUNK : CHUNK;
        if (mode == Mode.EmptyChunk) return "";
        if (mode == Mode.LongChunk) return _a(expected + 1);
        if (mode == Mode.ShortChunk) return _a(expected - 1);
        if (mode == Mode.BombChunk) return _a(200_000);
        return _a(expected);
    }

    /// @dev `n` bytes of `A`, written a word at a time so an honest read stays far below the
    ///      renderer's per-chunk gas cap.
    function _a(uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, n) { i := add(i, 32) } {
                mstore(
                    add(add(out, 0x20), i),
                    0x4141414141414141414141414141414141414141414141414141414141414141
                )
            }
        }
    }
}
