// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @dev A chunk source whose answer to `chunkData` is a raw byte string the test sets, returned
///      exactly as set (no ABI padding added) or used as revert data. It lets a test hand the
///      store answers a well-formed `IChunkStore` never gives: a short or unpadded encoding, or
///      the right encoding carried by a revert.
contract RawChunkSource {
    bytes internal _answer;
    bool internal _reverts;

    function set(bytes memory answer, bool reverts) external {
        _answer = answer;
        _reverts = reverts;
    }

    function chunkData(bytes32) external view returns (bytes memory) {
        bytes memory answer = _answer;
        bool reverts = _reverts;
        assembly ("memory-safe") {
            if reverts { revert(add(answer, 0x20), mload(answer)) }
            return(add(answer, 0x20), mload(answer))
        }
    }
}
