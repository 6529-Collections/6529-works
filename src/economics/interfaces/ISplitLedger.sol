// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IReleaseVerifier } from "./IReleaseVerifier.sol";
import { ISplitFactory } from "./ISplitFactory.sol";
import { ISplitWallet } from "./ISplitWallet.sol";

/// @title ISplitLedger
/// @notice The one permanent split contract (ADR 0001 section 7): it predicts and deploys every
///         split wallet ({ISplitFactory}), keeps every wallet's accounting and executes its
///         releases ({ISplitWallet}), and verifies signed releases ({IReleaseVerifier}). A wallet
///         is a minimal vault that only the ledger can command, so withdrawing depends on no
///         deployment beyond the vault's 66 bytes of code, once per wallet.
///         Every release also pays the network fee vault ({ISplitFactory.network}) its share of
///         the same asset when the vault is a fixed payee of the wallet (a royalty wallet). A
///         payee's share that anyone marked and that is still unreleased once the unclaimed
///         period has passed goes to the network ({mark}, {forfeit}). The period is the
///         network's setting (`IDirectory.unclaimedPeriod`, 180 days at launch), read when a
///         forfeit is attempted, so a change applies to marks already running; it is not a
///         fixed promise. What a mark covers never changes.
interface ISplitLedger is ISplitFactory, ISplitWallet, IReleaseVerifier {
    /// @notice Anyone marked payee `payee`'s share of `asset` in `wallet`: unless the payee's
    ///         released total reaches `target` before the unclaimed period in force has passed
    ///         since `markedAt`, the rest of it may go to the network.
    /// @param wallet The split wallet.
    /// @param asset The asset (ETH is `address(0)`).
    /// @param payee The payee's index.
    /// @param target The released total the payee must reach: its entitlement when marked.
    /// @param markedAt When the mark was placed.
    event Marked(
        address indexed wallet,
        address indexed asset,
        uint256 indexed payee,
        uint256 target,
        uint256 markedAt
    );
    /// @notice `amount` of payee `payee`'s marked share of `asset` in `wallet` went to the network
    ///         (also reported, as for any release, by a `Released` event naming the network).
    /// @param wallet The split wallet.
    /// @param asset The asset (ETH is `address(0)`).
    /// @param payee The payee's index.
    /// @param amount The amount paid to the network, counted as released for the payee.
    event Forfeited(
        address indexed wallet, address indexed asset, uint256 indexed payee, uint256 amount
    );

    /// @notice The payee's earlier mark still runs (it has not released up to it), so it is not
    ///         replaced.
    error MarkPending(address wallet, address asset, uint256 payee);
    /// @notice The payee has no mark, or its mark is younger than the unclaimed period in
    ///         force; `dueAt` is when it matures under that period (zero when there is no mark).
    error MarkNotDue(address wallet, address asset, uint256 payee, uint256 dueAt);

    /// @notice Executes a payee's signed release from `authorization.wallet`. Anyone may submit
    ///         it; it works for fixed and artist-resolved payees alike.
    /// @param payees The payee list of `authorization.wallet`.
    /// @param salt The salt of `authorization.wallet`.
    /// @param authorization The signed release; its `account` must be the payee's current payout
    ///        address.
    /// @param signature The signature of `authorization.account` over
    ///        {IReleaseVerifier.releaseDigest}: 65 or 64 (ERC-2098) bytes for an EOA, or an
    ///        ERC-1271 signature for a contract account.
    /// @return amount The amount released.
    function releaseWithAuthorization(
        Payee[] calldata payees,
        bytes32 salt,
        Authorization calldata authorization,
        bytes calldata signature
    ) external returns (uint256 amount);

    /// @notice Marks payee `index`'s share of `asset` in the wallet for `payees` and `salt`: what it
    ///         can release now. Anyone may call. If the payee's released total has not reached
    ///         that level once the unclaimed period has passed, {forfeit} sends the rest of it to
    ///         the network. Money that
    ///         arrives after the mark is never part of it. A mark the payee has not yet released
    ///         past cannot be replaced, so nobody can restart its clock.
    /// @dev Reverts with `WalletNotDeployed` for a wallet not deployed, `NothingToRelease` when the
    ///      payee has nothing releasable, and {MarkPending} while its earlier mark runs.
    /// @param payees The wallet's payee list.
    /// @param salt The wallet's salt.
    /// @param asset The asset (ETH is `address(0)`).
    /// @param index The payee's index.
    function mark(Payee[] calldata payees, bytes32 salt, address asset, uint256 index) external;

    /// @notice Sends to the network what is still unreleased of payee `index`'s marked share, at
    ///         once the unclaimed period in force (`IDirectory.unclaimedPeriod`, read now) has
    ///         passed since the mark: the marked level minus what the payee has released,
    ///         at most what it can release now. Anyone may call. The amount counts as released
    ///         for the payee, and the mark is cleared.
    /// @dev Reverts with {MarkNotDue} before the mark matures and `NothingToRelease` when the
    ///      payee reached its mark; it also reverts, and the money stays, if the resolver does
    ///      not answer the period. Like a release, it also pays the network its own share.
    /// @param payees The wallet's payee list.
    /// @param salt The wallet's salt.
    /// @param asset The asset (ETH is `address(0)`).
    /// @param index The payee's index.
    /// @return amount The amount paid to the network.
    function forfeit(Payee[] calldata payees, bytes32 salt, address asset, uint256 index)
        external
        returns (uint256 amount);

    /// @notice Payee `index`'s mark in `wallet` for `asset`.
    /// @param wallet The split wallet.
    /// @param asset The asset (ETH is `address(0)`).
    /// @param index The payee's index.
    /// @return target The released total the payee must reach; zero when there is no mark.
    /// @return markedAt When the mark was placed; zero when there is none.
    function markOf(address wallet, address asset, uint256 index)
        external
        view
        returns (uint256 target, uint256 markedAt);
}
