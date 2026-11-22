// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILocators
/// @notice What a renderer asks the delivery contract (`IWorkRules.delivery()`, replaceable):
///         where a media file of a work is served from. The delivery contract serves every
///         token of its RECORDS module, so it is keyed by token contract.
/// @dev The renderer, not this contract, decides what it prints: it accepts only a URI of
///      printable ASCII without `"` and `\`, at most `Limits.MAX_URI_BYTES`, and an ONCHAIN
///      answer only for a work `IWorkFacts` records as on-chain complete; anything else, a
///      revert included, is "no locator".
interface ILocators {
    /// @notice A served location.
    /// @param kind The locator kind (`LocatorKind`: 0 none, 1 Arweave, 2 IPFS, 3 on-chain).
    /// @param uri The URI; empty for kinds 0 and 3.
    struct Location {
        uint8 kind;
        string uri;
    }

    /// @notice The preferred location of one media file of a work.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param fileId One of the work's media files.
    /// @return location The location.
    /// @return index The locator's index, or `type(uint256).max` for none or the on-chain copy.
    function preferredLocator(address token, uint256 tokenId, bytes32 fileId)
        external
        view
        returns (Location memory location, uint256 index);
}
