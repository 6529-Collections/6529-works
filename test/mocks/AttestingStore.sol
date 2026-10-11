// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ContentStore } from "src/content/ContentStore.sol";

/// @dev The content store as the renderer expects it to be (decision H1): the `ContentStore` plus
///      a permissionless, one-time, strict check of a `Base64` file, `attestBase64`, and its
///      result, `isBase64Attested`. The real function lands with the content-store PR; this is the
///      interface the renderer is written against. The check reads every chunk and accepts only
///      the RFC 4648 section 4 alphabet, with `=` padding at the very end (no whitespace, no
///      `-_`), a length that is a multiple of four, and records a pass for good.
contract AttestingStore is ContentStore {
    /// @dev `A-Z a-z 0-9 + /` as a bit set over ASCII.
    uint256 private constant ALPHABET = 0x07fffffe07fffffe03ff880000000000;
    mapping(bytes32 => bool) private _attested;

    error NotBase64(bytes32 fileId);

    function attestBase64(bytes32 fileId) external {
        FileInfo memory info = this.fileInfo(fileId);
        require(info.encoding == Encoding.Base64 && this.isComplete(fileId), "not a base64 file");
        if (info.length % 4 != 0) revert NotBase64(fileId);
        uint256 seen;
        bool padded;
        for (uint256 i; i < info.chunkCount; ++i) {
            bytes memory chunk = this.readChunk(fileId, i);
            bool ok;
            (ok, padded) = _strict(chunk, seen, info.length, padded);
            if (!ok) revert NotBase64(fileId);
            seen += chunk.length;
        }
        _attested[fileId] = true;
    }

    function isBase64Attested(bytes32 fileId) external view returns (bool) {
        return _attested[fileId];
    }

    /// @dev Whether `chunk`, which starts at `offset` of a file of `total` bytes, is in the
    ///      alphabet, with `=` only as one of the last two bytes of the file and nothing but `=`
    ///      after the first one (`padded` says one came before this chunk).
    function _strict(bytes memory chunk, uint256 offset, uint256 total, bool padded)
        private
        pure
        returns (bool ok, bool paddedAfter)
    {
        ok = true;
        paddedAfter = padded;
        assembly ("memory-safe") {
            let p := add(chunk, 0x20)
            let end := add(p, mload(chunk))
            for { let at := offset } lt(p, end) {
                p := add(p, 1)
                at := add(at, 1)
            } {
                let c := byte(0, mload(p))
                // A 128-bit set of the alphabet, indexed by the byte.
                let plain := and(lt(c, 128), and(shr(c, ALPHABET), 1))
                if eq(c, 61) {
                    paddedAfter := 1
                    if lt(add(at, 2), total) { ok := 0 }
                }
                if iszero(or(plain, eq(c, 61))) { ok := 0 }
                if and(plain, paddedAfter) { ok := 0 }
                if iszero(ok) { break }
            }
        }
    }
}
