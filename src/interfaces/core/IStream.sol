// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { Collection, MintFacts, Outcome, Work } from "./CoreTypes.sol";

/// @title IStream
/// @notice A permanent ERC-721 of works: 6529 Stream, and each Independent Stream artist's own
///         token. It holds who owns each token, the facts fixed at mint and how the first sale
///         ended.
/// @dev The seam (ADR 0010). A minter may mint, and while it still holds a token whose sale
///      has no outcome it may record the outcome, once, or burn the token. The TERMS module may
///      set a token's royalty receiver and rate. The RENDERER module draws works that are not
///      finalized. No module can move a token or change a fact fixed at mint. Transfers and
///      `ownerOf` call nothing outside the contract. `royaltyInfo` reads only this contract's
///      storage. The contract compiles no gas number and catches no failed call.
interface IStream is IERC4906, IERC2981 {
    /// @notice A work was minted. Carries every fact the minter stated.
    /// @param tokenId The new token.
    /// @param collectionId Its collection.
    /// @param artistId Its lead artist.
    /// @param minter The minter (sale contract) that minted it.
    /// @param serial Its number in the collection.
    /// @param facts The facts as stated.
    event WorkMinted(
        uint256 indexed tokenId,
        uint256 indexed collectionId,
        uint256 indexed artistId,
        address minter,
        uint32 serial,
        MintFacts facts
    );
    /// @notice A token's first sale ended. The price is logged here and not stored.
    /// @param tokenId The token.
    /// @param outcome SOLD, UNSOLD or RESCUED.
    /// @param buyer The buyer; zero unless SOLD.
    /// @param price The price paid in wei; zero unless SOLD.
    event PrimarySale(
        uint256 indexed tokenId, Outcome outcome, address indexed buyer, uint256 price
    );
    /// @notice The network moved a token a removed minter still held unsold.
    /// @param tokenId The token.
    /// @param from The removed minter.
    /// @param to Where the token went.
    event WorkRescued(uint256 indexed tokenId, address indexed from, address to);
    /// @notice A token's royalty receiver or rate was set by the TERMS module.
    /// @param tokenId The token.
    /// @param receiver The receiver now.
    /// @param rate The rate now, out of 100,000.
    event RoyaltySet(uint256 indexed tokenId, address receiver, uint24 rate);
    /// @notice A token's royalty rate was fixed for good.
    /// @param tokenId The token.
    event RoyaltyRateLocked(uint256 indexed tokenId);
    /// @notice A collection was created.
    /// @param collectionId The collection.
    /// @param name Its name.
    /// @param metadataHash The hash of its metadata document.
    event CollectionCreated(uint256 indexed collectionId, string name, bytes32 metadataHash);
    /// @notice The marketplace owner changed.
    /// @param previousOwner The owner before.
    /// @param newOwner The owner now.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice ERC-7572: the contract-level metadata changed.
    event ContractURIUpdated();
    /// @notice The contract-level metadata URI was set; carries the value, which ERC-7572's
    ///         `ContractURIUpdated` does not, so the URI can be rebuilt from logs alone.
    /// @param uri The URI now.
    event ContractURISet(string uri);
    /// @notice The wait before a rescue was set: by the network, or at deployment with its
    ///         launch value (`previous` zero).
    /// @param previous The wait before.
    /// @param next The wait now.
    event RescueDelaySet(uint48 previous, uint48 next);

    /// @notice The mint facts are malformed (a zero item hash, content hash or artist ID, an
    ///         artist ID over 160 bits, a rate over 100,000, a nonzero rate with a zero
    ///         royalty receiver), or name an artist this token does not take (an Independent Stream
    ///         token takes only its own artist).
    error InvalidMint();
    /// @notice A live token already has this content hash.
    error ContentAlreadyMinted(bytes32 contentHash, uint256 tokenId);
    /// @notice The collection does not exist.
    error UnknownCollection(uint256 collectionId);
    /// @notice The caller is not a minter holding this token with no sale outcome recorded.
    error NotInPrimarySale(uint256 tokenId);
    /// @notice The token is not held unsold by a minter removed at least `rescueDelay` ago.
    error NotRescuable(uint256 tokenId);
    /// @notice The rate is over 100,000, the rate is nonzero with a zero receiver, or the rate
    ///         is locked and would change.
    error InvalidRoyalty();
    /// @notice The caller may not emit metadata updates.
    error NotMetadataSource(address caller);

    /// @notice How long after a minter's removal the network may move a token it still holds
    ///         unsold. A setting of the network, 14 days at deployment; not a fixed promise.
    ///         Read when a rescue is attempted.
    /// @return The wait, in seconds.
    function rescueDelay() external view returns (uint48);

    /// @notice Sets `rescueDelay`, at once. The network only. Zero is allowed.
    /// @param next The new wait, in seconds.
    function setRescueDelay(uint48 next) external;

    /// @notice The permanent record contract (`IWorkFacts`) that holds each work's pinned
    ///         renderer.
    /// @return The record contract.
    function facts() external view returns (address);

    // ------------------------------------------------------------------------------ minters

    /// @notice Mints the next token to `to`. An active minter only.
    /// @dev Checks, whatever the minter states: nonzero item hash, content hash and artist ID;
    ///      artist ID within 160 bits; rate at most 100,000; a nonzero royalty receiver unless
    ///      the rate is zero (royalties paid to the zero address would be lost); an existing
    ///      collection; no live
    ///      token with this content hash (a burned token's content may be minted again); an
    ///      artist the token takes (an Independent Stream token: its own artist only). A minter
    ///      mints to itself and records the outcome before the token leaves it: a token minted to
    ///      anyone else is left with no outcome, so any minter that later holds it may record or
    ///      burn it, and the network may rescue it from a removed minter.
    /// @param to The first holder (the sale contract itself, while the sale runs).
    /// @param f The work's facts.
    /// @return tokenId The new token ID: the next in one sequence from 1, never reused.
    function mint(address to, MintFacts calldata f) external returns (uint256 tokenId);

    /// @notice Records how a token's first sale ended, once. Only a minter (active or removed)
    ///         that holds the token, while no outcome is recorded.
    /// @param tokenId The token.
    /// @param sold True for SOLD, false for UNSOLD.
    /// @param buyer The buyer (logged).
    /// @param price The price in wei (logged).
    function recordPrimarySale(uint256 tokenId, bool sold, address buyer, uint256 price) external;

    /// @notice Burns a token. Only a minter that holds it, while no outcome is recorded. The
    ///         token's content hash can then be minted again.
    /// @param tokenId The token.
    function burn(uint256 tokenId) external;

    // ------------------------------------------------------------------------------ network

    /// @notice Moves a token that a removed minter still holds with no outcome recorded,
    ///         `rescueDelay` after the removal. The network only. The only way anyone but its
    ///         owner moves a token; it can never reach a token whose sale was recorded.
    ///         Refuses this token contract itself and the zero address as `to`
    ///         (`ERC721InvalidReceiver`).
    /// @param tokenId The token.
    /// @param to Where it goes.
    function rescue(uint256 tokenId, address to) external;

    /// @notice Creates a collection. The contract's admin only.
    /// @param name The name.
    /// @param metadataHash The hash of the collection's metadata document.
    /// @return collectionId The new collection's ID, from 1.
    function createCollection(string calldata name, bytes32 metadataHash)
        external
        returns (uint256 collectionId);

    /// @notice Sets the marketplace owner. The contract's admin only.
    /// @param next The new owner.
    function setOwner(address next) external;

    /// @notice Sets the contract-level metadata URI. The contract's admin only.
    /// @param uri The URI.
    function setContractURI(string calldata uri) external;

    // -------------------------------------------------------------------------- terms module

    /// @notice Sets a token's royalty receiver and rate. The TERMS module only. A locked rate
    ///         cannot change; the receiver still can. A nonzero rate needs a nonzero receiver.
    /// @param tokenId A live token.
    /// @param receiver The receiver.
    /// @param rate The rate, out of 100,000.
    function setRoyalty(uint256 tokenId, address receiver, uint24 rate) external;

    /// @notice Fixes a token's royalty rate for good. The TERMS module only.
    /// @param tokenId A live token.
    function lockRoyaltyRate(uint256 tokenId) external;

    /// @notice Emits ERC-4906 for a token or a range. Only `facts()`, the RECORDS module and the
    ///         TERMS module.
    /// @param fromTokenId The first token.
    /// @param toTokenId The last token (equal to the first for one token).
    function emitMetadataUpdate(uint256 fromTokenId, uint256 toTokenId) external;

    // --------------------------------------------------------------------------------- views

    /// @notice A token's stored work. A burned token keeps its record; an unminted ID is empty.
    /// @dev Its `outcome` is the `Outcome` enum of `CoreTypes.sol`: NONE (0) until the first
    ///      sale is recorded, then SOLD (1), UNSOLD (2) or RESCUED (3).
    /// @param tokenId The token.
    /// @return The work.
    function workOf(uint256 tokenId) external view returns (Work memory);

    /// @notice A live token's item hash. Reverts for a burned or unminted token with
    ///         OpenZeppelin's `ERC721NonexistentToken(tokenId)` (`IERC721Errors`, ERC-6093), and
    ///         with no other error; readers such as `StatementLog` rely on that.
    /// @param tokenId The token.
    /// @return The item hash.
    function itemHashOf(uint256 tokenId) external view returns (bytes32);

    /// @notice A collection (empty if it does not exist).
    /// @param collectionId The collection.
    /// @return The collection.
    function collectionOf(uint256 collectionId) external view returns (Collection memory);

    /// @notice The token last minted with a content hash (it may since be burned), or zero.
    /// @param contentHash The content hash.
    /// @return The token ID.
    function tokenOfContent(bytes32 contentHash) external view returns (uint256);

    /// @notice Tokens ever minted (also the last token ID).
    /// @return The count.
    function totalMinted() external view returns (uint256);

    /// @notice Tokens burned.
    /// @return The count.
    function totalBurned() external view returns (uint256);

    /// @notice Live tokens.
    /// @return The count.
    function totalSupply() external view returns (uint256);

    /// @notice Collections created.
    /// @return The count.
    function collectionCount() external view returns (uint256);

    /// @notice The renderer that draws a work: the one pinned in `facts()` once the work is
    ///         finalized, else the RENDERER module. Reverts if the pinned renderer's code
    ///         changed; never falls back to another renderer. Answers for a burned token too
    ///         (its record stays), so the editions of a burned master are still drawn; the burned
    ///         token itself has no `tokenURI`. Reverts for an ID that was never minted.
    /// @param tokenId A token that was minted, live or burned.
    /// @return The renderer.
    function rendererOf(uint256 tokenId) external view returns (address);

    /// @notice The marketplace owner.
    /// @return The owner.
    function owner() external view returns (address);

    /// @notice ERC-7572 contract-level metadata URI.
    /// @return The URI.
    function contractURI() external view returns (string memory);
}
