// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IFederationRegistry } from "./IFederationRegistry.sol";
import { IMintTarget } from "./IMintTarget.sol";

/// @title IFederatedToken
/// @notice What both 6529 Stream Federated templates (`IFederatedStream`, `IFederatedEditions`)
///         share: the terms fixed at deployment, joining the federation, and the artist's
///         marketplace metadata (ADR 0008; spec `docs/spec/federation.md`).
/// @dev A template carries no immutable, so every deployment of one version has one runtime code
///      hash; the federation registry recognises a genuine copy by that hash and by its
///      version's approved deployer (`IFederatedDeployer`) having recorded it. Every artist
///      power is checked with the artist registry (`IAccounts.isWallet`): any wallet of the
///      artist's consolidated account acts, none while the account is frozen, and before the
///      artist has an identity the address that is the artist ID acts (it can then only join,
///      which creates the identity). Joining is for good: a joined contract has no way out of
///      the federation. Minting (`IMintTarget.isAdmittedMinter`): never before joining; after
///      it, only as the current federation registry's `canMint` answers, so a contract that is
///      delisted, or whose template is suspended or revoked, mints nothing.
///      `IMintTarget.setAdmittedMinter` always reverts: there are no minters of the artist's own.
interface IFederatedToken is IMintTarget {
    /// @notice The terms fixed at deployment (constructor). The network share can later only be
    ///         lowered, by the artist registry's record for this contract.
    /// @param artistId The artist the contract belongs to.
    /// @param artistRegistry The artist registry that answers who acts for the artist.
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

    /// @notice The caller is not a wallet of the artist's account.
    error NotArtist(address caller);
    /// @notice The action is not allowed in the contract's federation state (joined or not).
    error FederationStateInvalid();
    /// @notice A constructor argument is invalid.
    error InvalidConfig();

    /// @notice The terms fixed at deployment, and the partner. `feeShare` is the deployed share;
    ///         the share in force is the smaller of it and the artist registry's record
    ///         (`IAccounts.federatedFeeShare`).
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
    /// @notice Whether the contract joined (`FederationJoined`), which is for good.
    /// @return joined True once joined.
    function federationState() external view returns (bool joined);
    /// @notice Joins the federation through the artist registry's current federation registry
    ///         (`IFederationRegistry.register`), once. The artist only (before its identity
    ///         exists, the account whose address is the artist ID, whose signature then creates
    ///         it). Reverts unless the artist registry lists this contract under its artist in
    ///         this transaction (`FederationStateInvalid`): a listing made by anyone else first
    ///         can never be confirmed, so the token never sells under it. An editions contract
    ///         joins before its partner. Joining is for good.
    /// @param j The identity fields and the artist's signatures (`IFederationRegistry.Join`).
    function joinFederation(IFederationRegistry.Join calldata j) external;
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
