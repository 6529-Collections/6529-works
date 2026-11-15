// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IMintTarget } from "./IMintTarget.sol";

/// @title IFederatedToken
/// @notice What both 6529 Stream Federated templates (`IFederatedStream`, `IFederatedEditions`)
///         share: the terms each locks at deployment, joining and leaving the federation, and
///         the artist's marketplace metadata (ADR 0008; spec `docs/spec/federation.md`).
/// @dev A template carries no immutable, so every deployment of one version has one runtime code
///      hash, and the federation registry recognises a genuine copy by that hash alone. Every
///      power is the artist's, checked against the artist registry's active authority of the
///      locked artist ID (so lost-key recovery works); the network holds none over a deployed
///      contract. Before the artist has an identity, the account whose address is the artist ID
///      acts for it (it can then only join, which creates the identity, or leave). Minting
///      (`IMintTarget.isAdmittedMinter`): before the exit, the federation registry's `canMint`
///      for this contract, once joined; after it, the artist's own list
///      (`IMintTarget.setAdmittedMinter`, the artist only, refused before the exit).
interface IFederatedToken is IMintTarget {
    /// @notice The terms fixed at deployment, for good (constructor).
    /// @param artistId The artist the contract belongs to.
    /// @param artistRegistry The artist registry whose active authority acts for the artist.
    /// @param splitLedger The split ledger that derives and deploys every payout vault.
    /// @param feeShare The network's share of primary sales and royalties, out of 100,000.
    /// @param feeRecipient The network's fee recipient (the governed fee vault).
    /// @param partner The other half of a linked pair, zero until linked (the 1/1 template) or
    ///        fixed at deployment (the editions template).
    event FederationTermsLocked(
        uint256 indexed artistId,
        address artistRegistry,
        address splitLedger,
        uint32 feeShare,
        address feeRecipient,
        address partner
    );
    /// @notice The contract joined the federation: the artist registry listed it, in this
    ///         transaction, with the facts below. A listing the token never confirmed this way is
    ///         not its own.
    /// @param artistId The artist it is listed under.
    /// @param registry The federation registry that listed it.
    /// @param feeShare The locked network share.
    /// @param feeRecipient The locked network fee recipient.
    /// @param partner The other half of a linked pair, or zero.
    event FederationJoined(
        uint256 indexed artistId,
        address registry,
        uint32 feeShare,
        address feeRecipient,
        address partner
    );
    /// @notice The contract left the federation, for good: no network adapter mints for it any
    ///         more, and the artist admits its own minters. Works minted before keep their terms.
    event FederationLeft();
    /// @notice After its exit, the artist admitted or removed a minter.
    /// @param adapter The minter.
    /// @param admitted Whether it may now mint.
    event MinterSet(address indexed adapter, bool admitted);
    /// @notice ERC-4906: one token's metadata changed.
    /// @param _tokenId The token.
    event MetadataUpdate(uint256 _tokenId);
    /// @notice ERC-4906: a range of tokens' metadata changed.
    /// @param _fromTokenId The first token.
    /// @param _toTokenId The last token.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    /// @notice ERC-7572: the contract-level metadata changed.
    event ContractURIUpdated();
    /// @notice The marketplace owner changed (no on-chain power).
    /// @param previousOwner The owner before.
    /// @param newOwner The owner after.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice The caller is not the artist's active authority.
    error NotArtist(address caller);
    /// @notice The action is not allowed in the contract's federation state (joined, left).
    error FederationStateInvalid();
    /// @notice A constructor argument is invalid.
    error InvalidConfig();

    /// @notice The terms locked at deployment, and the partner.
    /// @return artistRegistry The artist registry.
    /// @return splitLedger The split ledger.
    /// @return artistId The artist.
    /// @return feeShare The network's share, out of 100,000.
    /// @return feeRecipient The network's fee recipient.
    /// @return partner The other half of a linked pair, or zero.
    function federationTerms()
        external
        view
        returns (
            address artistRegistry,
            address splitLedger,
            uint256 artistId,
            uint32 feeShare,
            address feeRecipient,
            address partner
        );
    /// @notice Whether the contract joined (`FederationJoined`) and whether it left.
    /// @return joined True once joined.
    /// @return left True once left (for good).
    function federationState() external view returns (bool joined, bool left);
    /// @notice Joins the federation through the artist registry's current federation registry
    ///         (`IFederationRegistry.register`), once. The artist only (before its identity
    ///         exists, the account whose address is the artist ID, whose signature then creates
    ///         it). Reverts unless the artist registry lists this contract under its artist in
    ///         this transaction (`FederationStateInvalid`): a listing made by anyone else first
    ///         can never be confirmed, so the token never sells under it.
    /// @param profileId The artist's claimed 6529 profile ID (for a new identity).
    /// @param profileDocHash The profile document's hash (for a new identity).
    /// @param deadline The signature's expiry (for a new identity).
    /// @param signature The account's `ArtistRegistration` signature, or empty.
    function joinFederation(
        bytes32 profileId,
        bytes32 profileDocHash,
        uint64 deadline,
        bytes calldata signature
    ) external;
    /// @notice Leaves the federation, for good. The artist only. Records `LEFT` in the artist
    ///         registry if the contract was listed (the token itself writes it, so the exit
    ///         needs no replaceable contract). Running sales finish; tokens, ownership, records,
    ///         payout vaults and the terms of works minted before are untouched.
    function leaveFederation() external;
    /// @notice The artist sets the ERC-7572 contract URI.
    /// @param uri The new URI.
    function setContractURI(string calldata uri) external;
    /// @notice The artist sets the marketplace owner (no on-chain power).
    /// @param next The new owner.
    function setOwner(address next) external;
    /// @notice ERC-7572 contract metadata URI.
    /// @return The URI.
    function contractURI() external view returns (string memory);
    /// @notice The marketplace owner.
    /// @return The owner.
    function owner() external view returns (address);
}
