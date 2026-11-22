// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFederatedMembership
/// @notice What both federated token contracts (`FederatedStream`, `FederatedEditions`) share:
///         the artist they belong to and the permanent directory they ask everything else.
/// @dev A federated token keeps no minter list, no fee and no record: its sale contracts are the
///      federation module's answer (`IFederationGate.canMint`), its TERMS and RECORDS modules the
///      directory's `FEDERATED_TERMS` and `FEDERATED_RECORDS` slots, its admin any wallet of the
///      artist's account (`IAccounts.isWallet`), and the network whoever the directory's
///      AccessManager lets call the same function on the directory at once.
interface IFederatedMembership {
    /// @notice The caller is not a wallet of the artist's account now.
    /// @param caller The caller.
    error NotArtist(address caller);
    /// @notice The caller may not act for the network on this function now: the directory's
    ///         AccessManager does not let it call the same function on the directory at once.
    /// @param caller The caller.
    error NotNetwork(address caller);
    /// @notice A constructor argument is unusable: a zero directory, a zero artist ID or one
    ///         over 160 bits, or (editions) a zero partner.
    error InvalidConfig();

    /// @notice The permanent directory this token asks for its gate, its modules and accounts.
    /// @return The directory.
    function directory() external view returns (address);

    /// @notice The artist this token belongs to: an account ID of the accounts module (the
    ///         address the artist first registered with, as a number). Fixed at deployment.
    /// @return The artist ID.
    function artistId() external view returns (uint256);

    /// @notice Whether `account` may mint now, as the federation module answers
    ///         (`IFederationGate.canMint` for this token); false while the directory names no
    ///         federation module.
    /// @param account The account.
    /// @return True if it may mint.
    function isMinter(address account) external view returns (bool);
}
