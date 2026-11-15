// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IStreamExtension
/// @notice 6529 Stream's read-only extension: what Stream's fallback forwards any selector it
///         does not implement to, by STATICCALL, so the extension can never write state and
///         never shadows a native selector. It serves the informational views of `IStream`
///         (`work`, `collection`, `collectionCount`, `totalMinted`, `totalSupply`, `contractURI`,
///         `owner`), reading Stream through `IStream.extsload` and its native views with the
///         caller (`msg.sender`, the Stream that forwarded) as the token, and judges collection
///         names for `createCollection`. Replaceable by governance
///         (`IStream.setDependency("EXTENSION")`, the 30-day class). No contract may rely on an
///         answer it serves for authorization.
interface IStreamExtension is IERC165 {
    /// @notice Whether `name` may name a collection: what the current renderers can escape
    ///         within `tokenURI`'s gas budget (for v1: 1 to 256 bytes of UTF-8 without control
    ///         characters, `<`, `"` or `\`).
    /// @param name The proposed collection name.
    /// @return True if `createCollection` may store it.
    function isValidCollectionName(string calldata name) external pure returns (bool);
}
