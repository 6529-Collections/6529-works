// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISplitFactory } from "./ISplitFactory.sol";

/// @title IRevenueEscrow
/// @notice Holds payments a payer could not deliver to a wallet (ADR 0001 sections 5 and 7), keyed
///         by `(wallet, asset)`. Anyone may flush a credit to its wallet. The network may move a
///         split wallet's credit only to an equivalent replacement wallet (same factory,
///         identical payees), its own credits (the fee and museum vaults') anywhere, and any
///         other account's credit only to the replacement that account itself named (its
///         consent). Every amount credited stays its account's at least for the unclaimed period
///         from its block and may move to the network fee vault less than twice that after it
///         ({expire}); no deposit, by anyone, makes an amount expire sooner, or moves the time
///         from which an amount already a period old may expire (see `RevenueEscrow`). The
///         period is the network's setting (`IDirectory.unclaimedPeriod`, 180 days at launch),
///         read whenever the escrow ages a credit, so a change applies to every amount not yet
///         aged; it is not a fixed promise.
/// @dev Declares itself through ERC-165, so the artist registry and the economics resolver can
///      refuse the escrow as a payout or fee recipient (`ProtocolContracts`).
interface IRevenueEscrow is IERC165 {
    /// @notice `payer` credited `amount` of `asset` to `wallet`, which is now owed `owed`.
    /// @param wallet The account credited.
    /// @param asset The asset credited (ETH is `address(0)`).
    /// @param payer The account that made the deposit.
    /// @param amount The amount deposited, in the asset's base units.
    /// @param owed The wallet's whole credit in the asset after the deposit.
    event Credited(
        address indexed wallet,
        address indexed asset,
        address indexed payer,
        uint256 amount,
        uint256 owed
    );
    /// @notice `caller` flushed `amount` of `asset` to `wallet`.
    /// @param wallet The account paid.
    /// @param asset The asset paid (ETH is `address(0)`).
    /// @param caller The account that called {flush}.
    /// @param amount The amount paid: the wallet's whole credit in the asset.
    event Flushed(
        address indexed wallet, address indexed asset, address indexed caller, uint256 amount
    );
    /// @notice `amount` of `asset` owed to `wallet` moved to `replacement`, which is now owed
    ///         `owed`.
    /// @param wallet The account whose credit moved.
    /// @param replacement The account the credit moved to.
    /// @param asset The asset of the credit (ETH is `address(0)`).
    /// @param amount The amount moved: the wallet's whole credit in the asset.
    /// @param owed The replacement's whole credit in the asset after the move.
    /// @param consentUsed Whether the move used (and so cleared) the wallet's recovery consent
    ///        (`recoveryConsent` is zero after it); false for an equivalent split wallet or the
    ///        network's own credit.
    event Recovered(
        address indexed wallet,
        address indexed replacement,
        address indexed asset,
        uint256 amount,
        uint256 owed,
        bool consentUsed
    );

    /// @notice `amount` of `asset` that the escrow held beyond every credit (`totalOwed`) was
    ///         sent to `recipient`.
    /// @param asset The asset swept (ETH is `address(0)`).
    /// @param recipient The account governance named.
    /// @param amount The amount swept: the whole excess.
    event ExcessSwept(address indexed asset, address indexed recipient, uint256 amount);

    /// @notice `amount` of `asset` owed to `wallet`, every unit of it credited at least the
    ///         unclaimed period ago, moved to the network fee vault `network`, which is now owed
    ///         `owed`.
    /// @param wallet The account whose credit moved.
    /// @param asset The asset of the credit (ETH is `address(0)`).
    /// @param network The network fee vault credited.
    /// @param amount The amount moved: the wallet's expirable part (`aged`, after ageing to this
    ///        block); the rest of its credit stays.
    /// @param owed The network's whole credit in the asset after the move.
    event Expired(
        address indexed wallet,
        address indexed asset,
        address indexed network,
        uint256 amount,
        uint256 owed
    );

    /// @notice `account` named `replacement` as where governance may move its credits; zero
    ///         withdraws the consent.
    /// @param account The account that called {consentToRecovery}.
    /// @param replacement The replacement it named, or zero.
    event RecoveryConsentSet(address indexed account, address indexed replacement);

    /// @notice `wallet` is zero or the escrow itself.
    error InvalidWallet(address wallet);
    /// @notice An ERC-20 deposit named `address(0)`, which is ETH.
    error InvalidAsset(address asset);
    /// @notice Deposits must be non-zero.
    error ZeroAmount();
    /// @notice `wallet` is owed nothing in `asset`.
    error NothingOwed(address wallet, address asset);
    /// @notice Sending `amount` wei to `wallet` failed; the credit is kept.
    error ETHTransferFailed(address wallet, uint256 amount);
    /// @notice The escrow holds no more of `asset` than it owes.
    error NothingToSweep(address asset);
    /// @notice `wallet` and `replacement` are not two distinct factory wallets with identical
    ///         payee configurations.
    error NotEquivalentWallet(address wallet, address replacement);
    /// @notice `account` is not a factory wallet and has not named `replacement` with
    ///         {consentToRecovery}.
    error RecoveryNotConsented(address account, address replacement);
    /// @notice No part of `wallet`'s credit in `asset` may move to the network yet; the next part
    ///         may from `dueAt`, unless a later credit extends its window.
    error CreditNotExpired(address wallet, address asset, uint256 dueAt);

    /// @notice The split factory whose wallet configurations {recover} compares.
    /// @return The split factory, fixed at deployment.
    function factory() external view returns (ISplitFactory);

    /// @notice The amount of `asset` owed to `wallet`: `aged + maturing + recent` of {credits}.
    /// @param wallet The credited account.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @return The credit, in the asset's base units.
    function owed(address wallet, address asset) external view returns (uint256);

    /// @notice The amount of `asset` owed to all wallets.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @return The sum of every credit in the asset; funds sent here without a deposit are not
    ///        counted.
    function totalOwed(address asset) external view returns (uint256);

    /// @notice The replacement `account` consented to and no {recover} has used yet, or zero.
    /// @param account The account to look up.
    /// @return The replacement it named, or zero.
    function recoveryConsent(address account) external view returns (address);

    /// @notice `wallet`'s credit in `asset` as stored at its last change, in three parts that age
    ///         oldest first; they sum to {owed}. A deposit or a recovery to the wallet joins the
    ///         open window, or opens one at its block when there is none or it has closed.
    /// @dev The stored parts are not aged to now: {expirableAt} does that. A window closes one
    ///      unclaimed period after `openedAt`; its credits then mature one period after its
    ///      last credit, under the period in force when the escrow looks.
    /// @param wallet The credited account.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @return aged The part that may move to the network.
    /// @return maturing The last closed window's credits, which may move one period after
    ///         `maturingLastAt`.
    /// @return recent The open window's credits.
    /// @return maturingLastAt When the last closed window took its last credit.
    /// @return openedAt When the open window opened (its first credit).
    /// @return lastAt When the open window took its last credit.
    function credits(address wallet, address asset)
        external
        view
        returns (
            uint256 aged,
            uint256 maturing,
            uint256 recent,
            uint48 maturingLastAt,
            uint48 openedAt,
            uint48 lastAt
        );

    /// @notice What {expire} would move from `wallet`'s credit in `asset` at `time` if nothing
    ///         else happened first; zero for the network's own credit.
    /// @param wallet The credited account.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @param time The time to age the credit to; an earlier time than now counts as now.
    /// @return The amount, in the asset's base units.
    function expirableAt(address wallet, address asset, uint256 time)
        external
        view
        returns (uint256);

    /// @notice Whether a call holds the escrow's reentrancy guard, so its guarded functions would
    ///         revert; the English auction reads it before a settlement attempt.
    /// @return True while the guard is held.
    function locked() external view returns (bool);

    /// @notice Moves the part of `wallet`'s credit in `asset` that may expire (every unit of it
    ///         credited at least the unclaimed period in force ago, see `RevenueEscrow`) to the
    ///         network fee vault (`factory().network()`) as a credit; the rest stays. Anyone may call; anyone may
    ///         then {flush} it to the vault.
    /// @dev Reverts with {CreditNotExpired} when no part may move yet, {NothingOwed} when nothing
    ///      is owed and {InvalidWallet} for the network itself.
    /// @param wallet The credited account.
    /// @param asset The asset (ETH is `address(0)`).
    /// @return amount The amount moved.
    function expire(address wallet, address asset) external returns (uint256 amount);

    /// @notice Credits `msg.value` to `wallet`.
    /// @param wallet The account to credit; not zero or the escrow. `msg.value` must be non-zero.
    function depositETH(address wallet) external payable;

    /// @notice Pulls exactly `amount` of `asset` from the caller and credits it to `wallet`.
    /// @dev The caller approves the escrow first. Reverts unless both balances move by exactly
    ///      `amount` and the token returns `true`.
    /// @param wallet The account to credit; not zero or the escrow.
    /// @param asset The ERC-20 to pull; not `address(0)`, which is ETH.
    /// @param amount The amount to pull and credit, in the asset's base units; must be non-zero.
    function depositERC20(address wallet, address asset, uint256 amount) external;

    /// @notice Pays everything owed to `wallet` in `asset` to `wallet`. Anyone may call.
    /// @param wallet The credited account to pay.
    /// @param asset The asset to pay (ETH is `address(0)`).
    /// @return amount The amount paid.
    function flush(address wallet, address asset) external returns (uint256 amount);

    /// @notice Names `replacement` as where governance may move the caller's credit with
    ///         {recover}. Single use: the next {recover} of the caller's credit, in whichever
    ///         asset, consumes it, so the caller consents again for each further asset or later
    ///         credit. The caller can change it, or withdraw it with zero, until then.
    /// @dev For accounts that can act: the consent ADR 0001 section 7 requires for terminal
    ///      recovery. Split wallets cannot call it; their credits follow the identical-payees
    ///      rule instead, and the network's own accounts need no consent.
    ///      Reverts with {InvalidWallet} for the escrow itself or the caller.
    /// @param replacement The account to receive the caller's credit, or zero to withdraw.
    function consentToRecovery(address replacement) external;

    /// @notice Moves everything owed to `wallet` in `asset` to `replacement`. For a wallet of the
    ///         factory, `replacement` must be a distinct wallet of the same factory with an
    ///         identical payee configuration (another salt). For the network's own account (one
    ///         whose `authority()` is this escrow's, such as the fee and museum vaults),
    ///         `replacement` is any account but zero, the escrow and the account itself (C19). For
    ///         any other account, it must be the replacement that account named with
    ///         {consentToRecovery}, and the move consumes that consent.
    /// @dev Governed: `Roles.FUNDS_SETTER` (the network, 3 days). It rescues credits for an
    ///      account a token has blocked; the blocked account's own balance stays where it is.
    ///      ADR 0001 section 7 requires the affected accounts' consent: a factory wallet's is
    ///      trivially satisfied because the payees are identical (recorded in ADR 0003), the
    ///      network's own accounts are the network's to move, and any other account gives it
    ///      explicitly. Factory wallets must be deployed: a predicted
    ///      address has no configuration and can never consent. A credit the replacement already
    ///      holds is added to, never overwritten.
    /// @param wallet The account whose credit to move.
    /// @param replacement The account to credit instead.
    /// @param asset The asset of the credit (ETH is `address(0)`).
    function recover(address wallet, address replacement, address asset) external;

    /// @notice Sends everything the escrow holds of `asset` beyond `totalOwed(asset)` to
    ///         `recipient`: ETH force-sent here and tokens transferred without a deposit, which
    ///         are owed to nobody. Afterwards the escrow's balance of `asset` equals
    ///         `totalOwed(asset)` exactly, so no credit recorded under `asset` loses its backing.
    /// @dev Governed: `Roles.FUNDS_SETTER` (the network, 3 days), so the recipient is public for
    ///      the whole delay. An ERC-20 move counts a `transfer` that
    ///      returns `true` or nothing, and requires both balances to move by exactly the excess.
    ///      Limits, which no on-chain check can close: the bound is per token address, so for a
    ///      token with two addresses over one balance (a legacy proxy pair), a sweep of the
    ///      address nothing was credited under takes the credits made under the other; a
    ///      positive rebase makes creditors' growth sweepable, and a negative rebase leaves the
    ///      last flush of that token short. The network does not sweep such tokens.
    /// @param asset The asset to sweep (ETH is `address(0)`).
    /// @param recipient The account to pay; not zero or the escrow.
    /// @return amount The amount swept.
    function sweepExcess(address asset, address recipient) external returns (uint256 amount);
}
