// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SplitRecipient } from "./types/EconomicsTypes.sol";

/// @title ISplitWallet
/// @notice An immutable pull-payment split wallet (ADR 0001 sections 7 and 11).
/// @dev The wallet receives ETH and any ERC-20 by plain transfer. A recipient's releasable amount
///      is `totalReceived(currency) * share / 100,000 - released(currency, account)`, where
///      `totalReceived` is the wallet's balance plus everything released, so funds already held
///      are always accounted for. Release is permissionless and always pays the recipient's
///      payee: the account itself, or for an artist-resolved recipient the artist registry's
///      current payout of its artist ID. ERC-20 releases check the exact balance delta and reject
///      tokens that take a fee or rebase. Deprecated currencies stay releasable.
interface ISplitWallet {
    /// @notice `amount` of `currency` owed to `account` was paid to `payee`.
    event Released(
        address indexed currency, address indexed account, address indexed payee, uint256 amount
    );

    /// @notice `account` is not a recipient of this wallet.
    error NotRecipient(address account);
    /// @notice Nothing is releasable for `account` in `currency`.
    error NothingToRelease(address account, address currency);

    /// @notice Accepts ETH.
    receive() external payable;

    /// @notice This wallet's split ID.
    function splitId() external view returns (bytes32);
    /// @notice The factory that deployed it.
    function factory() external view returns (address);
    /// @notice The recipients, in split order.
    function recipients() external view returns (SplitRecipient[] memory);
    /// @notice Where `account`'s releases are paid now.
    function payeeOf(address account) external view returns (address);
    /// @notice What `account` can release in `currency` now.
    function releasable(address currency, address account) external view returns (uint256);
    /// @notice What `account` has released in `currency` so far.
    function released(address currency, address account) external view returns (uint256);
    /// @notice Pays `account`'s releasable `currency` to its payee. Permissionless.
    /// @return amount The amount paid.
    function release(address currency, address account) external returns (uint256 amount);
}
