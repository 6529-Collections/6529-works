// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @title ITerms
/// @notice The TERMS module (replaceable): the royalty policy of existing works. It is the only
///         caller of `IStream.setRoyalty`, `IStream.lockRoyaltyRate` and `IEditions.setRoyalty`.
/// @dev Rules it holds: the royalty rate changes only through the token's RECORDS module, which
///      checked every party's consent and the network's approval. The network's share of an
///      existing work's royalties can only be lowered; a rate rises only with the artist's and
///      the network's agreement; renouncing the royalty power needs the network's approval
///      (ADR 0010). The receiver is always the split vault of (seller, fee
///      recipient) at the share in force, or the seller at a zero share, deployed before it is
///      set. A master's edition follows its master.
interface ITerms {
    /// @notice The network's share of a work's royalties was lowered.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param previous The share before.
    /// @param share The share now.
    /// @param receiver The royalty receiver now.
    event FeeShareLowered(
        address indexed token,
        uint256 indexed tokenId,
        uint32 previous,
        uint32 share,
        address receiver
    );

    /// @notice The caller is not the token's RECORDS module.
    error NotRecordsModule(address token, address caller);
    /// @notice The stated seller, fee recipient and current share do not derive the token's
    ///         stored royalty receiver, the new share is not lower, or the fee recipient is not
    ///         the network's fee vault.
    error InvalidFeeShare();

    /// @notice Sets the royalty rate of a work and of its edition, if one exists. The token's
    ///         RECORDS module only.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param rate The rate, out of 100,000.
    function setRoyaltyRate(address token, uint256 tokenId, uint24 rate) external;

    /// @notice Fixes a work's royalty rate for good. The token's RECORDS module only.
    /// @param token The token contract.
    /// @param tokenId The token.
    function lockRoyaltyRate(address token, uint256 tokenId) external;

    /// @notice Lowers the network's share of a work's (and its edition's) royalties. The network
    ///         only. The caller states the seller, fee recipient and current share; they must
    ///         derive the stored receiver, so the module stores nothing per work.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param seller The work's seller wallet.
    /// @param feeRecipient The fee recipient in the current royalty vault: the network's fee
    ///        vault.
    /// @param currentShare The share in force.
    /// @param newShare The lower share.
    function lowerFeeShare(
        address token,
        uint256 tokenId,
        address seller,
        address feeRecipient,
        uint32 currentShare,
        uint32 newShare
    ) external;

    /// @notice The editions contract paired with a token contract, or zero.
    /// @param token The ERC-721 token contract.
    /// @return The editions contract.
    function editionsOf(address token) external view returns (address);
}
