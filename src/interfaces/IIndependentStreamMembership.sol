// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @title IIndependentStreamMembership
/// @notice What both Independent Stream token contracts (`IndependentStream6529`,
///         `IndependentStreamEditions6529`) share: the artist they belong to and the permanent
///         directory they ask everything else.
/// @dev An Independent Stream token keeps no minter list, no fee and no record: its sale contracts
///      are the Independent Stream module's answer (`IIndependentStreamGate.canMint`), its TERMS
///      and RECORDS modules the directory's `INDEPENDENT_TERMS` and `INDEPENDENT_RECORDS` slots,
///      its admin any wallet of the artist's account (`IAccounts.isWallet`), and the network
///      whoever the directory's AccessManager lets call the same function on the directory at once.
interface IIndependentStreamMembership {
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

    /// @notice Whether `account` may mint now, as the Independent Stream module answers
    ///         (`IIndependentStreamGate.canMint` for this token); false while the directory names
    ///         no Independent Stream module.
    /// @param account The account.
    /// @return True if it may mint.
    function isMinter(address account) external view returns (bool);
}
