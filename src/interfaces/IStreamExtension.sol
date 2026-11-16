// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IStreamViews } from "./IStreamViews.sol";

/// @title IStreamExtension
/// @notice 6529 Stream's read-only extension: what Stream's fallback forwards the three
///         `IStreamViews` selectors to, by STATICCALL, so the extension can never write state and
///         never shadows a native selector; Stream forwards no other selector. It serves `work`,
///         `collection` and `totalSupply`, reading Stream through `IStream.extsload` and its
///         native views with the caller (`msg.sender`, the Stream that forwarded) as the token,
///         and judges collection names for `createCollection`. Replaceable by governance
///         (`IStream.setDependency("EXTENSION")`, the 7-day class). No contract may rely on an
///         answer it serves for authorization, and nothing permanent or pinned may read it.
/// @dev Flat: the views are declared again here, so this interface's ERC-165 id covers them and
///      the collection-name rule together, and `setDependency`'s one check of it makes Stream's
///      own `IStreamViews` claim true for any extension installed.
interface IStreamExtension is IERC165, IStreamViews {
    /// @notice Whether `name` may name a collection: what the current renderers can escape
    ///         within `tokenURI`'s gas budget (for v1: 1 to 256 bytes of UTF-8 without control
    ///         characters, `<`, `"` or `\`).
    /// @param name The proposed collection name.
    /// @return True if `createCollection` may store it.
    function isValidCollectionName(string calldata name) external pure returns (bool);

    /// @inheritdoc IStreamViews
    function collection(uint256 collectionId) external view override returns (Collection memory);
    /// @inheritdoc IStreamViews
    function totalSupply() external view override returns (uint256);
    /// @inheritdoc IStreamViews
    function work(uint256 tokenId) external view override returns (WorkCore memory);
}
