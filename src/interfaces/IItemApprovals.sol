// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IItemApprovals
/// @notice The approval check an edition sale makes at open: whether a curated package is
///         approved now and contains a given item. The package registry implements it.
interface IItemApprovals {
    /// @notice Whether `packageRoot` is approved now (not revoked, signer not killed) and
    ///         contains the item.
    /// @param packageRoot The package Merkle root.
    /// @param itemHash The item hash.
    /// @param proof The Merkle proof that `itemHash` is in the package.
    /// @return Whether the package is approved now and contains the item.
    function isApprovedItem(bytes32 packageRoot, bytes32 itemHash, bytes32[] calldata proof)
        external
        view
        returns (bool);
}
