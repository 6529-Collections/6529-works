// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SplitRecipient } from "./types/EconomicsTypes.sol";

/// @title ISplitFactory
/// @notice Deploys immutable pull-payment split wallets (ADR 0001 section 7).
/// @dev Creation is permissionless and deterministic (CREATE2 keyed by the split ID, no proxies),
///      so a wallet's address is known before it exists and creating it twice is a no-op. The
///      split ID is `WorksHashing.splitId(recipients)`. Package preparation creates the
///      artist-portion and royalty wallets before a sale starts, so the start pays no deployment.
interface ISplitFactory {
    /// @notice A split wallet was deployed.
    event SplitCreated(
        bytes32 indexed splitId, address indexed wallet, SplitRecipient[] recipients
    );

    /// @notice The recipients are empty or more than `Limits.MAX_SPLIT_RECIPIENTS`, have a zero
    ///         or duplicate account, a zero share, or shares that do not sum to 100,000.
    error InvalidSplit();
    /// @notice No wallet exists for this split ID.
    error UnknownSplit(bytes32 splitId);

    /// @notice Deploys the wallet for `recipients`, or returns the existing one.
    function createSplit(SplitRecipient[] calldata recipients)
        external
        returns (bytes32 splitId, address wallet);

    /// @notice The deployed wallet of a split ID. Reverts with `UnknownSplit`.
    function walletOf(bytes32 splitId) external view returns (address);

    /// @notice The address the wallet of a split ID has or will have.
    function predictWallet(bytes32 splitId) external view returns (address);

    /// @notice Whether `wallet` is a split wallet deployed by this factory.
    function isSplitWallet(address wallet) external view returns (bool);

    /// @notice The artist registry that artist-resolved recipients pay through (immutable).
    function artistRegistry() external view returns (address);
}
