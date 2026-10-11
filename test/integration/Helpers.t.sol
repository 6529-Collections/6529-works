// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Checks the integration helpers themselves, so a flow can only fail for the contracts'
///         reasons: the package Merkle trees agree with OpenZeppelin's `MerkleProof`, the
///         verifier the package registry, Editions and the entropy module use.
contract IntegrationHelpersTest is IntegrationBase {
    /// @dev No deployment: these are pure checks.
    function setUp() public override { }

    function test_TreesAgreeWithMerkleProofForEveryLeafCount() public pure {
        for (uint256 n = 1; n <= 17; ++n) {
            bytes32[] memory leaves = new bytes32[](n);
            for (uint256 i; i < n; ++i) {
                leaves[i] = keccak256(abi.encode("leaf", n, i));
            }
            bytes32 root = _root(leaves);
            for (uint256 i; i < n; ++i) {
                bytes32[] memory proof = _proof(leaves, i);
                assertTrue(MerkleProof.verify(proof, root, leaves[i]), "every leaf verifies");
                assertLe(proof.length, 5, "depth at most ceil(log2 17)");
            }
            if (n > 1) {
                assertFalse(
                    MerkleProof.verify(_proof(leaves, 0), root, keccak256("not a leaf")),
                    "a stranger does not"
                );
            } else {
                assertEq(root, leaves[0], "a one-item package's root is its leaf");
            }
        }
    }
}
