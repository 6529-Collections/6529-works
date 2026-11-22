// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFederationGate
/// @notice What a federated token asks the federation module (replaceable, found through
///         `IDirectory`, slot `FEDERATION`): which sale contracts may mint for it. The module
///         also holds the directory of federated contracts, delisting and each contract's
///         network fee share (its own, wider interface).
/// @dev A federated token has no minter list of its own, so the network changes sale contracts
///      for every federated token at once and a delisted artist's contracts stop minting at
///      once. The network's waiting period applies to installing a federation module in the directory.
interface IFederationGate {
    /// @notice Whether `minter` may mint for `token` now: the token is listed and not delisted
    ///         and `minter` is one of the network's federated sale contracts.
    /// @param token The federated token contract.
    /// @param minter The sale contract.
    /// @return True if it may mint.
    function canMint(address token, address minter) external view returns (bool);

    /// @notice Whether `minter` is or ever was a federated sale contract (a removed one still
    ///         records the sales it started).
    /// @param minter The sale contract.
    /// @return True if it is or was.
    function wasMinter(address minter) external view returns (bool);

    /// @notice When the network removed `minter` from the federated sale contracts; zero if it
    ///         is not removed.
    /// @param minter The sale contract.
    /// @return The removal time.
    function minterRemovedAt(address minter) external view returns (uint256);

    /// @notice The network's share of a federated token's sales now, out of 100,000: recorded
    ///         at listing, only ever lowered by the network.
    /// @param token The federated token contract.
    /// @return The share.
    function feeShareOf(address token) external view returns (uint32);
}
