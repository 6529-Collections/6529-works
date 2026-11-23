// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IArtistPayoutResolver } from "./IArtistPayoutResolver.sol";
import { ISplitWallet } from "./ISplitWallet.sol";

/// @title ISplitFactory
/// @notice Predicts and deploys split wallets at CREATE2 addresses that commit to the payee list
///         and a salt. Sale adapters use salt zero, so a payee list maps to one wallet, before or
///         after deployment. Another salt gives an equivalent replacement wallet, which the
///         revenue escrow can recover credits to when a token blocks the original. The split
///         ledger implements it: the wallets it deploys are its vaults.
/// @dev A wallet's address is `CREATE2(ledger, keccak256(abi.encode(configHash, salt)),
///      walletInitCodeHash)`, with `configHash = keccak256(abi.encode(payees))`: every wallet has
///      the same init code (`SplitVault.INIT_CODE`), which embeds no payee data.
interface ISplitFactory {
    /// @notice A wallet for `payees` was deployed at `wallet` with `salt`; `configHash` is
    ///         `keccak256(abi.encode(payees))` and is the same for every salt. The only record of
    ///         the payee list: a reader rebuilds every wallet's configuration from these events.
    /// @param wallet The deployed wallet.
    /// @param configHash The hash of the wallet's payee list.
    /// @param salt The caller's salt (zero for the wallets sale adapters use).
    /// @param payees The wallet's canonical payee list (fixed payees by account, artist-resolved
    ///        payees by artist ID, each with its share).
    event WalletCreated(
        address indexed wallet,
        bytes32 indexed configHash,
        bytes32 salt,
        ISplitWallet.Payee[] payees
    );

    /// @notice The wallet CREATE2 deployed is not at the `predicted` address. (A creation that
    ///         itself fails reverts with OpenZeppelin's `Errors.FailedDeployment`.)
    error WalletAddressMismatch(address predicted, address deployed);

    /// @notice The resolver every wallet uses for artist-resolved payees.
    /// @return The artist payout resolver (the artist registry).
    function resolver() external view returns (IArtistPayoutResolver);

    /// @notice The network fee vault: the payee every release also pays when it is in the wallet,
    ///         and where unclaimed shares and unclaimed escrow credits go.
    /// @return The network fee vault, fixed at deployment.
    function network() external view returns (address);

    /// @notice The keccak256 of the wallets' init code, the same for every wallet.
    /// @return The init code hash used in every wallet's CREATE2 address.
    function walletInitCodeHash() external view returns (bytes32);

    /// @notice The payee configuration hash of a wallet this ledger deployed, or zero.
    /// @param wallet The address to look up.
    /// @return `keccak256(abi.encode(payees))` of the wallet's payee list; zero if this ledger
    ///        did not deploy `wallet`.
    function configOf(address wallet) external view returns (bytes32);

    /// @notice Returns whether this ledger deployed `wallet`.
    /// @param wallet The address to check.
    /// @return True if `configOf(wallet)` is non-zero.
    function isWallet(address wallet) external view returns (bool);

    /// @notice Deploys the wallet for canonical `payees` and `salt`, or returns it if it already
    ///         exists. Anyone may call, for any canonical list.
    /// @param payees The canonical payee list.
    /// @param salt The caller's salt; zero gives the wallet sale adapters use.
    /// @return wallet The wallet's address.
    function createWallet(ISplitWallet.Payee[] calldata payees, bytes32 salt)
        external
        returns (address wallet);

    /// @notice The wallet address for canonical `payees` and `salt`, deployed or not.
    /// @dev Reverts for a payee list no wallet would accept, so funds are never sent to an address
    ///      that can never hold a wallet.
    /// @param payees The canonical payee list.
    /// @param salt The caller's salt; zero gives the wallet sale adapters use.
    /// @return wallet The wallet's CREATE2 address.
    function walletFor(ISplitWallet.Payee[] calldata payees, bytes32 salt)
        external
        view
        returns (address wallet);
}
