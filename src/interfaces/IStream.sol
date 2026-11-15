// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IStreamCore } from "./IStreamCore.sol";

/// @title IStream
/// @notice 6529 Stream's whole surface: the native core (`IStreamCore`) and the informational
///         views its read-only extension serves through Stream's fallback (a STATICCALL, so the
///         extension can write nothing and can never shadow a native selector). No contract may
///         use an extension-served view for authorization: those views (`coreOf`, `artistOf`,
///         `primarySale`, `primarySaleSettled`, `editionOf`, `entropyModuleOf`, `rendererOf`,
///         `artistRegistry`, `workRecords`, `editions`) are native and permanent. Callers keep
///         calling `IStream(stream).work(id)` unchanged.
interface IStream is IStreamCore {
    /// @notice A collection: a named grouping of works, possibly by several artists.
    /// @param name The display name.
    /// @param metadataHash The hash of the collection's metadata document, or zero.
    /// @param minted Works minted into it so far; also the last serial assigned.
    struct Collection {
        string name;
        bytes32 metadataHash;
        uint64 minted;
    }

    /// @notice What 6529 Stream stores for a work.
    /// @dev Nothing changes after mint except `royaltyRate` (by agreement, through
    ///      `IWorkRecords`). `artistId` is the lead artist. `seller` is a predicted split-wallet
    ///      address; `royaltyReceiver` is derived from it and the stored fee terms.
    struct WorkCore {
        bytes32 itemHash;
        uint256 artistId;
        uint256 collectionId;
        uint64 serial;
        uint8 kind;
        uint8 seedPolicy;
        address seller;
        address royaltyReceiver;
        uint32 royaltyRate;
    }

    /// @notice A collection. Reverts with `UnknownCollection`.
    /// @param collectionId A collection ID, from 1 to `collectionCount()`.
    /// @return The collection's name, metadata hash and minted count.
    function collection(uint256 collectionId) external view returns (Collection memory);
    /// @notice The number of collections created.
    /// @return The count, which is also the highest collection ID.
    function collectionCount() external view returns (uint256);
    /// @notice The number of tokens ever minted, which is also the highest token ID.
    /// @return The count, burned tokens included.
    function totalMinted() external view returns (uint256);
    /// @notice The number of live tokens (minted minus burned).
    /// @return The count of live tokens.
    function totalSupply() external view returns (uint256);
    /// @notice What Stream stores for a work, with the derived royalty receiver. Reverts with
    ///         `UnknownWork`.
    /// @param tokenId A live token ID.
    /// @return The work's stored fields and its royalty receiver.
    function work(uint256 tokenId) external view returns (WorkCore memory);
    /// @notice ERC-7572 contract-level metadata URI.
    /// @return The URI, empty until set.
    function contractURI() external view returns (string memory);
    /// @notice The marketplace owner (held by 6529); it has no on-chain powers.
    /// @return The marketplace owner.
    function owner() external view returns (address);
}
