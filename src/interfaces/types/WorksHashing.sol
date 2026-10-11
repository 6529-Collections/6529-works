// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { PackageItem } from "./PackageTypes.sol";
import { MediaFile } from "./ContentTypes.sol";

/// @title WorksHashing
/// @notice The one definition of the hashes that identify package items, media lists and
///         licenses. Every contract and every off-chain tool must produce these exact bytes.
/// @dev Conventions (ADR 0001 section 3, as amended by the integrator):
///      - structured values are hashed as `keccak256(abi.encode(DOMAIN, value))`, each with its
///        own domain label, so a hash of one type can never be replayed as another;
///      - no chain ID and no contract address enter these hashes, so a package root is the same
///        on every chain and deployment;
///      - a package root is an OpenZeppelin `MerkleProof` root (sorted-pair keccak256) over the
///        leaves `keccak256(bytes.concat(itemHash))`. Double hashing makes a leaf's preimage 32
///        bytes, so an inner node (64 bytes) can never pass as a leaf. This is exactly the
///        OpenZeppelin merkle-tree library's `StandardMerkleTree` with leaf values
///        `[PACKAGE_ITEM_DOMAIN, item]` and leaf encoding `["bytes32", <PackageItem tuple>]`.
///        A one-item package's root is its leaf.
///      The canonical JSON package document (RFC 8785) maps field for field onto these structs;
///      the committed form is the ABI encoding. Every function is internal: nothing here is
///      linked bytecode. Callers bound array and string lengths before hashing.
library WorksHashing {
    /// @notice Domain label of `PackageItem` hashes.
    bytes32 internal constant PACKAGE_ITEM_DOMAIN = keccak256("6529WORKS_PACKAGE_ITEM_V1");
    /// @notice Domain label of media-list hashes.
    bytes32 internal constant MEDIA_DOMAIN = keccak256("6529WORKS_MEDIA_V1");
    /// @notice The canonical key of CC0 1.0, whose dedication is irrevocable.
    bytes32 internal constant CC0_LICENSE_KEY = keccak256("cc0-1.0");

    /// @notice The item hash: an item's identity, consumed at most once.
    function itemHash(PackageItem memory item) internal pure returns (bytes32) {
        return keccak256(abi.encode(PACKAGE_ITEM_DOMAIN, item));
    }

    /// @notice `itemHash` for an item in calldata, without copying it to memory first.
    function itemHashCalldata(PackageItem calldata item) internal pure returns (bytes32) {
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

    /// @notice The hash of an ordered media list, committed by `PackageItem.mediaHash`.
    function mediaHash(MediaFile[] memory media) internal pure returns (bytes32) {
        return keccak256(abi.encode(MEDIA_DOMAIN, media));
    }

    /// @notice A license's canonical key: keccak256 of its SPDX ID in ASCII lowercase.
    function licenseKey(string memory spdxId) internal pure returns (bytes32) {
        bytes memory id = bytes(spdxId);
        bytes memory lower = new bytes(id.length);
        for (uint256 i; i < id.length; ++i) {
            bytes1 c = id[i];
            lower[i] = (c >= "A" && c <= "Z") ? bytes1(uint8(c) + 32) : c;
        }
        return keccak256(lower);
    }
}
