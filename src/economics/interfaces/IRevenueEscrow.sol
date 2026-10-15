// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISplitFactory } from "./ISplitFactory.sol";

/// @title IRevenueEscrow
/// @notice Holds payments a payer could not deliver to a wallet (ADR 0001 sections 5 and 7), keyed
///         by `(wallet, asset)`. Anyone may flush a credit to its wallet. Governance may move a
///         split wallet's credit only to an equivalent replacement wallet (same factory,
///         identical payees), and any other account's credit (the network fee recipient's, for
///         example) only to the replacement that account itself named (its consent).
/// @dev Declares itself through ERC-165, so the artist registry and the economics resolver can
///      refuse the escrow as a payout or fee recipient (`ProtocolContracts`).
interface IRevenueEscrow is IERC165 {
    /// @notice `payer` credited `amount` of `asset` to `wallet`, which is now owed `owed`.
    event Credited(
        address indexed wallet,
        address indexed asset,
        address indexed payer,
        uint256 amount,
        uint256 owed
    );
    /// @notice `caller` flushed `amount` of `asset` to `wallet`.
    event Flushed(
        address indexed wallet, address indexed asset, address indexed caller, uint256 amount
    );
    /// @notice `amount` of `asset` owed to `wallet` moved to `replacement`, which is now owed
    ///         `owed`.
    event Recovered(
        address indexed wallet,
        address indexed replacement,
        address indexed asset,
        uint256 amount,
        uint256 owed
    );

    /// @notice `account` named `replacement` as where governance may move its credits; zero
    ///         withdraws the consent.
    event RecoveryConsentSet(address indexed account, address indexed replacement);

    /// @notice The factory has no code or is an EIP-7702 delegated account.
    error InvalidFactory(address factory);
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
    /// @notice `wallet` and `replacement` are not two distinct factory wallets with identical
    ///         payee configurations.
    error NotEquivalentWallet(address wallet, address replacement);
    /// @notice `account` is not a factory wallet and has not named `replacement` with
    ///         {consentToRecovery}.
    error RecoveryNotConsented(address account, address replacement);

    /// @notice The split factory whose wallet configurations {recover} compares.
    function factory() external view returns (ISplitFactory);

    /// @notice The amount of `asset` owed to `wallet`.
    function owed(address wallet, address asset) external view returns (uint256);

    /// @notice The amount of `asset` owed to all wallets.
    function totalOwed(address asset) external view returns (uint256);

    /// @notice The replacement `account` consented to and no {recover} has used yet, or zero.
    function recoveryConsent(address account) external view returns (address);

    /// @notice Credits `msg.value` to `wallet`.
    function depositETH(address wallet) external payable;

    /// @notice Pulls exactly `amount` of `asset` from the caller and credits it to `wallet`.
    /// @dev The caller approves the escrow first. Reverts unless both balances move by exactly
    ///      `amount` and the token returns `true`.
    function depositERC20(address wallet, address asset, uint256 amount) external;

    /// @notice Pays everything owed to `wallet` in `asset` to `wallet`. Anyone may call.
    /// @return amount The amount paid.
    function flush(address wallet, address asset) external returns (uint256 amount);

    /// @notice Names `replacement` as where governance may move the caller's credit with
    ///         {recover}. Single use: the next {recover} of the caller's credit, in whichever
    ///         asset, consumes it, so the caller consents again for each further asset or later
    ///         credit. The caller can change it, or withdraw it with zero, until then.
    /// @dev For accounts that can act, such as the network fee recipient's Safe when a token
    ///      blocks it: the consent ADR 0001 section 7 requires for terminal recovery. Split
    ///      wallets cannot call it; their credits follow the identical-payees rule instead.
    ///      Reverts with {InvalidWallet} for the escrow itself or the caller.
    function consentToRecovery(address replacement) external;

    /// @notice Moves everything owed to `wallet` in `asset` to `replacement`. For a wallet of the
    ///         factory, `replacement` must be a distinct wallet of the same factory with an
    ///         identical payee configuration (another salt). For any other account, it must be the
    ///         replacement that account named with {consentToRecovery}, and the move consumes
    ///         that consent.
    /// @dev Governed: `Roles.FUNDS_SETTER` (`Roles.FUNDS`, 14 days). It rescues credits for an
    ///      account a token has blocked; the blocked account's own balance stays where it is.
    ///      ADR 0001 section 7 requires the affected accounts' consent: a factory wallet's is
    ///      trivially satisfied because the payees are identical (recorded in ADR 0003), and
    ///      any other account gives it explicitly. Factory wallets must be deployed: a predicted
    ///      address has no configuration and can never consent. A credit the replacement already
    ///      holds is added to, never overwritten.
    function recover(address wallet, address replacement, address asset) external;
}
