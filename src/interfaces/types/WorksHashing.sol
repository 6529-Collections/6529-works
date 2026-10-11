// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { PackageItem, Party } from "./PackageTypes.sol";
import { Work } from "./ContentTypes.sol";
import { SplitRecipient } from "./EconomicsTypes.sol";

/// @title WorksHashing
/// @notice The one definition of the hashes that package items, work records and splits are
///         identified by. Every contract and every off-chain tool must produce these exact bytes.
/// @dev Conventions (ADR 0001 section 3):
///      - structured values are hashed as `keccak256(abi.encode(DOMAIN, value))`, each with its
///        own domain label, so a hash of one type can never be replayed as another;
///      - no chain ID and no contract address enter these hashes, so a package root, a work
///        record hash and a split ID are the same on every chain and deployment;
///      - a package root is an OpenZeppelin `MerkleProof` root (sorted-pair keccak256) over the
///        leaves `keccak256(bytes.concat(itemHash))`. Double hashing makes a leaf's preimage 32
///        bytes, so an inner node (64 bytes) can never pass as a leaf. This is exactly the
///        OpenZeppelin merkle-tree library's `StandardMerkleTree` with leaf values
///        `[PACKAGE_ITEM_DOMAIN, item]` and leaf encoding `["bytes32", <PackageItem tuple>]`.
///        A one-item package's root is its leaf.
///      ADR 0001 section 3 names RFC 8785 canonical JSON for package items. Contracts cannot
///      canonicalize JSON within the start-gas budget, so the committed form is the ABI
///      encoding above; the canonical JSON package document maps field for field onto these
///      structs (integers as decimal strings) and tools derive the ABI value from it.
///      Every function is internal: nothing here is linked bytecode. Callers bound array
///      lengths before hashing (for example the package registry's party limit).
library WorksHashing {
    /// @notice Domain label of `PackageItem` hashes.
    bytes32 internal constant PACKAGE_ITEM_DOMAIN = keccak256("6529WORKS_PACKAGE_ITEM_V1");
    /// @notice Domain label of `Work` record hashes.
    bytes32 internal constant WORK_RECORD_DOMAIN = keccak256("6529WORKS_WORK_RECORD_V1");
    /// @notice Domain label of split IDs.
    bytes32 internal constant SPLIT_DOMAIN = keccak256("6529WORKS_SPLIT_V1");

    /// @notice The item hash: an item's identity, consumed at most once.
    function itemHash(PackageItem memory item) internal pure returns (bytes32) {
        return keccak256(abi.encode(PACKAGE_ITEM_DOMAIN, item));
    }

    /// @notice The Merkle leaf of an item hash.
    function leaf(bytes32 itemHash_) internal pure returns (bytes32) {
        return keccak256(bytes.concat(itemHash_));
    }

    /// @notice Whether `itemHash_` is an item of the package with root `packageRoot`.
    function isItem(bytes32[] memory proof, bytes32 packageRoot, bytes32 itemHash_)
        internal
        pure
        returns (bool)
    {
        return MerkleProof.verify(proof, packageRoot, leaf(itemHash_));
    }

    /// @notice The hash of a work record, committed by `PackageItem.metadataHash`.
    function workRecordHash(Work memory work) internal pure returns (bytes32) {
        return keccak256(abi.encode(WORK_RECORD_DOMAIN, work));
    }

    /// @notice The ID of a split wallet with `recipients`, in the given order.
    function splitId(SplitRecipient[] memory recipients) internal pure returns (bytes32) {
        return keccak256(abi.encode(SPLIT_DOMAIN, recipients));
    }

    /// @notice The ID of the artist-portion split an item must name: every party, in item
    ///         order, artist-resolved, with its share.
    /// @dev Derives only; it does not validate. Callers check the parties (count, distinct
    ///      nonzero accounts, nonzero shares summing to 100,000) before relying on the ID,
    ///      because malformed parties still yield a deterministic ID.
    function partySplitId(Party[] memory parties) internal pure returns (bytes32) {
        SplitRecipient[] memory recipients = new SplitRecipient[](parties.length);
        for (uint256 i; i < parties.length; ++i) {
            recipients[i] = SplitRecipient(parties[i].account, parties[i].share, true);
        }
        return splitId(recipients);
    }
}
