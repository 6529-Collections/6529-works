// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFederationRegistry
/// @notice Placeholder for v1.1: the public on-chain directory of 6529 Stream Federated
///         contracts (ADR 0001 section 16). v1 ships no implementation; the interface fixes
///         what the shared sale adapters and indexers will read.
/// @dev Only the federation factory adds entries, so only genuine template deployments are
///      listed. Shared adapters accept federated sales only while `isActive`, and settle the
///      fee recorded in the entry. A TDH vote delists a contract or a whole artist identity;
///      tokens, content and ownership are never touched.
interface IFederationRegistry {
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
        uint64 artistId;
        uint32 templateVersion;
        bytes32 codeHash;
        uint32 feeShare;
        Status status;
    }

    /// @notice The factory registered a deployment.
    event Registered(address indexed token, uint64 indexed artistId, Entry entry);
    /// @notice A vote changed a contract's status.
    event StatusSet(address indexed token, Status status, bytes32 voteRef);
    /// @notice A vote delisted or relisted every contract of an artist identity.
    event ArtistDelistingSet(uint64 indexed artistId, bool delisted, bytes32 voteRef);

    /// @notice Registers a deployment. Callable only by the federation factory.
    function register(address token, Entry calldata entry) external;
    /// @notice Sets a contract's status after a vote. PARAMETER_SETTER role.
    function setStatus(address token, Status status, bytes32 voteRef) external;
    /// @notice Delists or relists an artist identity after a vote. PARAMETER_SETTER role.
    function setArtistDelisted(uint64 artistId, bool delisted, bytes32 voteRef) external;
    /// @notice A contract's entry.
    function entry(address token) external view returns (Entry memory);
    /// @notice Whether the contract and its artist identity are both listed.
    function isActive(address token) external view returns (bool);
    /// @notice How many contracts an artist identity registered.
    function contractCountOf(uint64 artistId) external view returns (uint256);
    /// @notice The `index`-th contract an artist identity registered.
    function contractOfAt(uint64 artistId, uint256 index) external view returns (address);
}
