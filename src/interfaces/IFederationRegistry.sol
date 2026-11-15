// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IFederationRegistry
/// @notice The replaceable admission layer for 6529 Stream Federated contracts (ADR 0001
///         section 16): which contracts are genuine template deployments, which adapters serve
///         them, and delisting by vote. The permanent, logs-only directory is the artist
///         registry's (`IArtistRegistry.federatedListing` and its events), which this registry
///         writes and which outlives any replacement of it.
/// @dev The artist registry's pointer to this registry is replaceable (`setFederationRegistry`,
///      SUCCESSOR_SETTER, 30 days). Through the artist registry it may only: create an identity
///      for an account that signed its own consent (`IArtistRegistry.registerFederated`); list a
///      non-canonical contract under an artist, with the code hash read by the artist registry
///      (`listFederatedContract`); and set a listed contract ACTIVE or DELISTED
///      (`setFederatedStatus`). It has no authority over any artist's authority, payout or
///      standing, or over any canonical token, work or fund. A token records its own exit
///      (`IArtistRegistry.recordFederationExit`, LEFT, terminal) without this registry. Shared
///      adapters accept federated sales only while `isActive`, and settle the fee recorded in
///      the entry. A TDH vote delists a contract or a whole artist identity; tokens, content and
///      ownership are never touched. The implementation (and any change to this interface
///      before launch) belongs to the federation package.
interface IFederationRegistry is IERC165 {
    /// @notice What a federated deployment is.
    enum Form {
        ERC721,
        ERC1155,
        PAIR
    }

    /// @notice A contract's listing status.
    enum Status {
        NONE,
        ACTIVE,
        DELISTED
    }

    /// @notice A registry entry, fixed at deployment except `status`.
    /// @param partner The other half of a linked pair, or zero.
    /// @param feeShare The network share of primary sales and royalties, out of 100,000.
    struct Entry {
        Form form;
        address partner;
        uint256 artistId;
        uint32 templateVersion;
        bytes32 codeHash;
        uint32 feeShare;
        Status status;
    }

    /// @notice The factory registered a deployment.
    /// @param token The federated contract.
    /// @param artistId The artist identity it is listed under, as in `entry.artistId`.
    /// @param entry The registered entry.
    event Registered(address indexed token, uint256 indexed artistId, Entry entry);
    /// @notice A vote changed a contract's status.
    /// @param token The federated contract.
    /// @param status Its new status.
    /// @param voteRef A reference to the vote that decided the change.
    event StatusSet(address indexed token, Status status, bytes32 voteRef);
    /// @notice A vote delisted or relisted every contract of an artist identity.
    /// @param artistId The artist identity.
    /// @param delisted True when the identity was delisted, false when that was lifted.
    /// @param voteRef A reference to the vote that decided the change.
    event ArtistDelistingSet(uint256 indexed artistId, bool delisted, bytes32 voteRef);

    /// @notice Registers a deployment. Callable only by the federation factory.
    /// @param token The deployed contract.
    /// @param entry Its entry, fixed from now on except `status`.
    function register(address token, Entry calldata entry) external;
    /// @notice Sets a contract's status after a vote. PARAMETER_SETTER role.
    /// @param token The federated contract.
    /// @param status The new status.
    /// @param voteRef A reference to the vote that decided the change.
    function setStatus(address token, Status status, bytes32 voteRef) external;
    /// @notice Delists or relists an artist identity after a vote. PARAMETER_SETTER role.
    /// @param artistId The artist identity.
    /// @param delisted True to delist the identity, and so all its contracts; false to lift it.
    /// @param voteRef A reference to the vote that decided the change.
    function setArtistDelisted(uint256 artistId, bool delisted, bytes32 voteRef) external;
    /// @notice A contract's entry.
    /// @param token The federated contract.
    /// @return The contract's registry entry.
    function entry(address token) external view returns (Entry memory);
    /// @notice Whether the contract and its artist identity are both listed.
    /// @param token The federated contract.
    /// @return True only when both are listed.
    function isActive(address token) external view returns (bool);
}
