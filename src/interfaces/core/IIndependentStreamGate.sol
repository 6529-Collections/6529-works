// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IIndependentStreamGate
/// @notice What an Independent Stream token asks the Independent Stream module (replaceable, found
///         through `IDirectory`, slot `INDEPENDENT_STREAM`): which sale contracts may mint for it.
///         The module also holds the directory of Independent Stream contracts, delisting and each
///         contract's network fee share (its own, wider interface).
/// @dev An Independent Stream token has no minter list of its own, so the network changes sale
///      contracts for every Independent Stream token at once and a delisted artist's contracts stop
///      minting at once. The network's waiting period applies to installing an Independent Stream
///      module in the directory.
interface IIndependentStreamGate {
    /// @notice Whether `minter` may mint for `token` now: the token is listed and not delisted
    ///         and `minter` is one of the network's Independent Stream sale contracts for tokens of
    ///         its form. Who may record a sale is the token's own answer (the account that minted
    ///         the work), not the module's.
    /// @param token The Independent Stream token contract.
    /// @param minter The sale contract.
    /// @return True if it may mint.
    function canMint(address token, address minter) external view returns (bool);

    /// @notice When the network removed `minter` from the Independent Stream sale contracts; zero
    ///         if it is not removed.
    /// @param minter The sale contract.
    /// @return The removal time.
    function minterRemovedAt(address minter) external view returns (uint256);

    /// @notice The network's share of an Independent Stream token's sales now, out of 100,000:
    ///         recorded at listing, only ever lowered by the network.
    /// @param token The Independent Stream token contract.
    /// @return The share.
    function feeShareOf(address token) external view returns (uint32);
}
