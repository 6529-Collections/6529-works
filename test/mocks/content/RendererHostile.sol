// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IWorkRecords } from "src/interfaces/IWorkRecords.sol";

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
        BombInfo,
        NonBoolAttest,
        BurnAttest
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

    /// @dev Every file is attested (so the reads after it are what the tests exercise), unless
    ///      the mode says the answer is broken.
    function isBase64Attested(bytes32) external view returns (bool) {
        if (mode == Mode.NonBoolAttest) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (mode == Mode.BurnAttest) {
            for (;;) { }
        }
        return true;
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

/// @dev A records satellite whose `preferredLocator` burns gas, like a stream lane that walks a
///      large file to answer it.
contract BurningRecords {
    address internal immutable inner;
    uint256 internal immutable burn;

    constructor(address inner_, uint256 burn_) {
        inner = inner_;
        burn = burn_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        if (bytes4(data) == IWorkRecords.preferredLocator.selector) {
            uint256 start = gasleft();
            while (start - gasleft() < burn) { }
        }
        (bool ok, bytes memory ret) = inner.staticcall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}
