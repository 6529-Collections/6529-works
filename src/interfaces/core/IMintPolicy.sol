// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { MintFacts, MintTerms } from "./CoreTypes.sol";

/// @title IMintPolicy
/// @notice The replaceable contract that decides what may be minted. A sale contract (a minter
///         of the token) calls it, then passes the facts it answers to `IStream.mint`. The token
///         contract never calls it.
/// @dev The genesis policy is the package registry: it checks the package proof, every party's
///      consent, the lead artist's move signature, the item rules and VRF delivery, and quotes
///      the terms. It also holds the dispute rules the token does not: a burned work's content
///      mints again only once the network released it, only for the artist it was released to,
///      and never by the burned item (`IStream.tokenOfContent` names the burned token).
interface IMintPolicy {
    /// @notice A burned work's content was released for another artist's items.
    /// @param token The token contract.
    /// @param tokenId The burned token.
    /// @param contentHash Its content hash.
    /// @param beneficiary The artist it is reserved for.
    event ContentReleased(
        address indexed token, uint256 indexed tokenId, bytes32 contentHash, uint256 beneficiary
    );

    /// @notice The caller is not an active minter of the token.
    error NotSaleContract(address token, address caller);
    /// @notice The content belonged to a burned work and is not released, or the item is the
    ///         burned one.
    error ContentUsed(bytes32 contentHash, uint256 burnedTokenId);
    /// @notice The content is released for another artist.
    error ContentReserved(bytes32 contentHash, uint256 beneficiary);

    /// @notice Admits one mint: consumes the request's item (single use) and answers the facts
    ///         to mint with and the sale's terms. The caller must be an active minter of `token`.
    /// @param token The token contract the work will be minted in.
    /// @param request The policy's own request encoding (genesis: `abi.encode(StreamMintRequest)`).
    /// @return facts The facts for `IStream.mint`, royalty receiver and rate included.
    /// @return terms The sale's terms.
    function authorize(address token, bytes calldata request)
        external
        returns (MintFacts memory facts, MintTerms memory terms);

    /// @notice What `authorize` would answer, unverified and consuming nothing.
    /// @param token The token contract.
    /// @param request As for `authorize`.
    /// @return facts The facts.
    /// @return terms The terms.
    function preview(address token, bytes calldata request)
        external
        view
        returns (MintFacts memory facts, MintTerms memory terms);

    /// @notice Releases a burned token's content for `beneficiary`'s items and bars the burned
    ///         item for good. The network only.
    /// @param token The token contract.
    /// @param tokenId A burned token.
    /// @param contentHash The burned token's content hash (`tokenOfContent` must name it).
    /// @param beneficiary A registered artist.
    function releaseContent(
        address token,
        uint256 tokenId,
        bytes32 contentHash,
        uint256 beneficiary
    ) external;

    /// @notice The artist a burned work's content is released to, or zero.
    /// @param token The token contract.
    /// @param contentHash The content hash.
    /// @return The artist ID.
    function releasedTo(address token, bytes32 contentHash) external view returns (uint256);

    /// @notice Whether an item was barred by a release.
    /// @param itemHash The item hash.
    /// @return True if barred.
    function isBarred(bytes32 itemHash) external view returns (bool);
}
