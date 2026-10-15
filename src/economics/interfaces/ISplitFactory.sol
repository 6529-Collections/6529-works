// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistPayoutResolver } from "./IArtistPayoutResolver.sol";
import { IReleaseVerifier } from "./IReleaseVerifier.sol";
import { ISplitWallet } from "./ISplitWallet.sol";

/// @title ISplitFactory
/// @notice Deploys immutable split wallets at CREATE2 addresses that commit to the payee list and a
///         salt. Sale adapters use salt zero, so a payee list maps to one wallet, before or after
///         deployment. Another salt gives an equivalent replacement wallet, which the revenue
///         escrow can recover credits to when a token blocks the original.
/// @dev A wallet's address is `CREATE2(factory, keccak256(abi.encode(configHash, salt)),
///      walletInitCodeHash)`, with `configHash = keccak256(abi.encode(payees))`: every wallet has
///      the same init code, and its constructor reads the payee list back from the factory.
interface ISplitFactory {
    /// @notice A wallet for `payees` was deployed at `wallet` with `salt`; `configHash` is
    ///         `keccak256(abi.encode(payees))` and is the same for every salt.
    event WalletCreated(
        address indexed wallet,
        bytes32 indexed configHash,
        bytes32 salt,
        ISplitWallet.Payee[] payees
    );

    /// @notice The wallet CREATE2 deployed is not at the `predicted` address
    ///         (`walletInitCodeHash` would no longer match the wallet's init code).
    error WalletAddressMismatch(address predicted, address deployed);

    /// @notice The resolver every wallet from this factory uses for artist-resolved payees.
    function resolver() external view returns (IArtistPayoutResolver);

    /// @notice The resolver's code hash, pinned at installation.
    function resolverCodeHash() external view returns (bytes32);

    /// @notice The verifier every wallet from this factory uses for signed releases.
    function verifier() external view returns (IReleaseVerifier);

    /// @notice The verifier's code hash, pinned at installation.
    function verifierCodeHash() external view returns (bytes32);

    /// @notice The keccak256 of the split wallets' init code, the same for every wallet.
    function walletInitCodeHash() external view returns (bytes32);

    /// @notice The payee list of the wallet {createWallet} is deploying, which the wallet's
    ///         constructor reads; empty at any other time.
    function pendingPayees() external view returns (ISplitWallet.Payee[] memory);

    /// @notice The payee configuration hash of a wallet this factory deployed, or zero.
    function configOf(address wallet) external view returns (bytes32);

    /// @notice Returns whether this factory deployed `wallet`.
    function isWallet(address wallet) external view returns (bool);

    /// @notice Deploys the wallet for canonical `payees` and `salt`, or returns it if it already
    ///         exists. Anyone may call.
    function createWallet(ISplitWallet.Payee[] calldata payees, bytes32 salt)
        external
        returns (address wallet);

    /// @notice The wallet address for canonical `payees` and `salt`, deployed or not.
    /// @dev Reverts for a payee list no wallet would accept, so funds are never sent to an address
    ///      that can never hold a wallet.
    function walletFor(ISplitWallet.Payee[] calldata payees, bytes32 salt)
        external
        view
        returns (address wallet);
}
