// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A tagged content hash: which algorithm produced the digest, and the digest itself.
/// @dev Ported from RC1's `IStreamPreservationRecords.HashRef` with the variable-length digest
///      and the canonicalization ID dropped. Every algorithm v1 recognises yields exactly 32
///      bytes, so the digest is a fixed word and the struct hashes without a length prefix.
///      Longer identifiers (a multihash or CID) and locators such as an Arweave transaction ID
///      belong in the statement's URI, not in a digest.
struct HashRef {
    uint16 algorithm;
    bytes32 digest;
}

// `algorithm` values. They keep RC1's numbering; 4 and 5 (variable-length multihash and CID) and
// 6 (Arweave transaction ID, a locator rather than a digest) are not accepted.

// keccak256
uint16 constant HASH_KECCAK256 = 1;
// SHA-256, also the content hash of the IPFS profile
uint16 constant HASH_SHA256 = 2;
// BLAKE3
uint16 constant HASH_BLAKE3 = 3;

/// @notice Returns whether `algorithm` is one of the recognised 32-byte algorithms.
function isKnownHashAlgorithm(uint16 algorithm) pure returns (bool) {
    return algorithm == HASH_KECCAK256 || algorithm == HASH_SHA256 || algorithm == HASH_BLAKE3;
}
