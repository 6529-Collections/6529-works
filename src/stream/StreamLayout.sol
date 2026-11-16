// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StreamLayout
/// @notice Where 6529 Stream keeps the facts of its works, for readers that use
///         `IStream.extsload` instead of a view: part of Stream's permanent interface. Stream is
///         never redeployed and has no proxy, so these slots never move; a test pins each one to
///         `forge inspect Stream storageLayout`. A pinned renderer reads a work through
///         `IStream.coreOf` and these slots, never through the replaceable view extension.
/// @dev Packing, from the least significant bit:
///      - token word, `tokenSlot(id)`: seller (0-159), serial (160-191), collection ID (192-223),
///        flags (224-231: item kind bits 0-1, seed policy bits 2-3, settled 16, linked 32, sold
///        64, frozen out 128), terms ID (232-255); the next slot holds the item hash. Zero for an
///        ID never minted; a burned token keeps its words.
///      - collection, `collectionSlot(id)`: `exists` (0-7, nonzero once created) and `minted`
///        (8-39); `+ 1` the metadata hash; `+ 2` the name, a Solidity storage `string` (short:
///        the bytes in place and twice the length in the low byte; long: `2 * length + 1`, the
///        bytes from `keccak256(abi.encode(collectionSlot(id) + 2))`). A name never changes.
///      - `COUNTS_SLOT`: minted (0-63), burned (64-127), collections (128-159).
///      - `OWNER_SLOT`: the marketplace owner; `CONTRACT_URI_SLOT`: the contract URI string.
///      - sale adapter, `minterSlot(adapter)`: admitted (0-7), index (8-31), `removedAt` (32-71,
///        when governance removed it, zero while admitted), the rescue delay locked at that
///        removal for its works (72-103, seconds; stale while `removedAt` is zero), kind key
///        (104-255).
library StreamLayout {
    uint256 internal constant COUNTS_SLOT = 11;
    uint256 internal constant OWNER_SLOT = 12;
    uint256 internal constant CONTRACT_URI_SLOT = 13;
    uint256 internal constant MINTERS_SLOT = 16;
    uint256 internal constant COLLECTIONS_SLOT = 17;
    uint256 internal constant TOKENS_SLOT = 18;

    /// @notice The token word of `tokenId`; its item hash is in the next slot.
    /// @param tokenId A token ID.
    /// @return The slot.
    function tokenSlot(uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenId, TOKENS_SLOT));
    }

    /// @notice The admission word of sale adapter `adapter`.
    /// @param adapter A sale adapter.
    /// @return The slot.
    function minterSlot(address adapter) internal pure returns (bytes32) {
        return keccak256(abi.encode(adapter, MINTERS_SLOT));
    }

    /// @notice The counter word of collection `collectionId`; its metadata hash and name follow.
    /// @param collectionId A collection ID.
    /// @return The slot.
    function collectionSlot(uint256 collectionId) internal pure returns (bytes32) {
        return keccak256(abi.encode(collectionId, COLLECTIONS_SLOT));
    }
}
