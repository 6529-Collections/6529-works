// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

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

// `algorithm` values: the statement log records any non-zero ID and never interprets it. These
// keep RC1's numbering; 4 and 5 (variable-length multihash and CID) and 6 (Arweave transaction
// ID) keep RC1's names, which a 32-byte digest cannot carry, so conventions do not assign them.

// keccak256
uint16 constant HASH_KECCAK256 = 1;
// SHA-256, also the content hash of the IPFS profile
uint16 constant HASH_SHA256 = 2;
// BLAKE3
uint16 constant HASH_BLAKE3 = 3;
