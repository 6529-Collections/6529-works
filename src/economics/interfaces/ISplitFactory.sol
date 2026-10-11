// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistPayoutResolver } from "./IArtistPayoutResolver.sol";
import { ISplitWallet } from "./ISplitWallet.sol";

/// @title ISplitFactory
/// @notice Deploys immutable split wallets at CREATE2 addresses that commit to the payee list, so
///         one canonical payee list always maps to one wallet, before or after deployment.
interface ISplitFactory {
    /// @notice A wallet for `payees` was deployed at `wallet`; `payeesHash` is
    ///         `keccak256(abi.encode(payees))`.
    event WalletCreated(
        address indexed wallet, bytes32 indexed payeesHash, ISplitWallet.Payee[] payees
    );

    /// @notice The resolver has no code.
    error InvalidResolver(address resolver);

    /// @notice The resolver every wallet from this factory uses for artist-resolved payees.
    function resolver() external view returns (IArtistPayoutResolver);

    /// @notice Returns whether this factory deployed `wallet`.
    function isWallet(address wallet) external view returns (bool);

    /// @notice Deploys the wallet for canonical `payees`, or returns it if it already exists.
    ///         Anyone may call.
    function createWallet(ISplitWallet.Payee[] calldata payees) external returns (address wallet);

    /// @notice The wallet address for canonical `payees`, whether or not it is deployed yet.
    /// @dev Reverts for a payee list no wallet would accept, so funds are never sent to an address
    ///      that can never hold a wallet.
    function walletFor(ISplitWallet.Payee[] calldata payees) external view returns (address wallet);
}
