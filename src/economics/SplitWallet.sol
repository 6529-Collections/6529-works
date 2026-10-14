// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IArtistPayoutResolver } from "./interfaces/IArtistPayoutResolver.sol";
import { IReleaseVerifier } from "./interfaces/IReleaseVerifier.sol";
import { ISplitFactory } from "./interfaces/ISplitFactory.sol";
import { ISplitWallet } from "./interfaces/ISplitWallet.sol";
import { Splits } from "./Splits.sol";
import { TokenTransfer } from "./TokenTransfer.sol";

/// @title SplitWallet
/// @notice An immutable pull-payment split wallet (ADR 0001 sections 7 and 11). It accepts ETH and
///         any ERC-20 passively. Each payee may release `floor(observed * share / 100,000)` minus
///         what it has already released, where `observed` is the balance plus everything released.
///         Because entitlements are cumulative, release order never matters and rounding dust
///         stays below the number of payees.
/// @dev No owner, no governance and no asset allowlist: an asset that governance deprecates, or
///      never admitted, stays withdrawable (fixes RC1 Medium M-3). Every ERC-20 move is checked by
///      exact balance deltas on both sides, so a token that charges fees, rebases with rounding,
///      returns nothing or returns `false` fails closed for its own releases only. A recorded
///      high-water mark of each ERC-20's `observed` makes a balance that shrinks (a negative
///      rebase) fail closed too. ETH needs none: nothing but a release can take ETH out of the
///      wallet, and a release adds what it sends to `totalReleased` first, so ETH receipts never
///      fall, and a first ETH release writes one slot fewer. All state-changing entry points
///      share one transient reentrancy guard.
///      Fixed payees are push: anyone may pay them at their own account. Artist-resolved payees
///      are pull-only (only the current payout address, directly or by a signature checked by the
///      pinned verifier), so nobody can push an accrued balance to a lost key before recovery.
contract SplitWallet is ISplitWallet, ReentrancyGuardTransient {
    /// @inheritdoc ISplitWallet
    address public immutable factory;
    /// @inheritdoc ISplitWallet
    IArtistPayoutResolver public immutable resolver;
    /// @inheritdoc ISplitWallet
    bytes32 public immutable resolverCodeHash;
    /// @inheritdoc ISplitWallet
    IReleaseVerifier public immutable verifier;

    Payee[] private _payees;

    /// @inheritdoc ISplitWallet
    mapping(address asset => mapping(uint256 index => uint256)) public released;
    /// @inheritdoc ISplitWallet
    mapping(address asset => uint256) public totalReleased;
    /// @inheritdoc ISplitWallet
    mapping(address asset => uint256) public recordedObserved;

    /// @notice Deployed only by the split factory, which supplies the canonical payee list
    ///         (see {Splits.validate}) through `pendingPayees`, its resolver (whose code hash is
    ///         pinned here) and its verifier. The constructor takes no arguments, so every wallet
    ///         has the same init code and the factory predicts addresses cheaply.
    constructor() {
        ISplitFactory factory_ = ISplitFactory(msg.sender);
        Payee[] memory payees_ = factory_.pendingPayees();
        Splits.validate(payees_);
        factory = msg.sender;
        IArtistPayoutResolver resolver_ = factory_.resolver();
        resolver = resolver_;
        resolverCodeHash = address(resolver_).codehash;
        verifier = factory_.verifier();
        for (uint256 i; i < payees_.length; ++i) {
            _payees.push(payees_[i]);
        }
    }

    /// @notice Accepts ETH from anyone; it is split like any other receipt.
    receive() external payable { }

    /// @inheritdoc ISplitWallet
    function release(address asset, uint256 index) external nonReentrant returns (uint256) {
        (address account, bool artist) = _payout(index);
        if (artist && msg.sender != account) revert NotPayoutAddress(msg.sender, account);
        return _release(asset, index, account, account, type(uint256).max);
    }

    /// @inheritdoc ISplitWallet
    function releaseTo(address asset, uint256 index, address recipient)
        external
        nonReentrant
        returns (uint256)
    {
        address account = payoutAddress(index);
        if (msg.sender != account) revert NotPayoutAddress(msg.sender, account);
        return _release(asset, index, account, recipient, type(uint256).max);
    }

    /// @inheritdoc ISplitWallet
    function releaseWithAuthorization(
        IReleaseVerifier.Authorization calldata authorization,
        bytes calldata signature
    ) external nonReentrant returns (uint256) {
        address account = payoutAddress(authorization.payee);
        if (authorization.account != account) {
            revert NotPayoutAddress(authorization.account, account);
        }
        // The verifier only lets the wallet an authorization names consume it.
        verifier.consume(authorization, signature);
        return _release(
            authorization.asset,
            authorization.payee,
            account,
            authorization.recipient,
            authorization.amount
        );
    }

    /// @inheritdoc ISplitWallet
    function payeeCount() external view returns (uint256) {
        return _payees.length;
    }

    /// @inheritdoc ISplitWallet
    function payee(uint256 index) external view returns (Payee memory) {
        return _payee(index);
    }

    /// @inheritdoc ISplitWallet
    function payees() external view returns (Payee[] memory) {
        return _payees;
    }

    /// @inheritdoc ISplitWallet
    function payoutAddress(uint256 index) public view returns (address account) {
        (account,) = _payout(index);
    }

    /// @inheritdoc ISplitWallet
    /// @dev Reverts while a release is in progress, so no caller reads half-updated accounting.
    function observed(address asset) external view nonReentrantView returns (uint256) {
        return _observed(asset);
    }

    /// @inheritdoc ISplitWallet
    /// @dev Reverts while a release is in progress, so no caller reads half-updated accounting,
    ///      and reverts with {ObservedDecreased} while the asset is frozen, so a frozen balance
    ///      never reads as "nothing owed".
    function releasable(address asset, uint256 index)
        external
        view
        nonReentrantView
        returns (uint256)
    {
        return _due(asset, index, _observed(asset));
    }

    /// @dev Effects before the transfer; the shared guard blocks every reentry path.
    function _release(
        address asset,
        uint256 index,
        address account,
        address recipient,
        uint256 requested
    ) private returns (uint256 amount) {
        if (recipient == address(0) || recipient == address(this)) {
            revert InvalidRecipient(recipient);
        }
        uint256 current = _observed(asset);
        uint256 due = _due(asset, index, current);
        amount = requested == type(uint256).max ? due : requested;
        if (amount == 0) revert NothingToRelease(asset, index);
        if (amount > due) revert AmountExceedsReleasable(amount, due);

        released[asset][index] += amount;
        totalReleased[asset] += amount;
        if (asset != address(0) && current != recordedObserved[asset]) {
            recordedObserved[asset] = current;
        }
        emit Released(asset, index, recipient, account, amount, current);

        if (asset == address(0)) {
            if (!TokenTransfer.sendETH(recipient, amount, gasleft())) {
                revert ETHTransferFailed(recipient, amount);
            }
        } else {
            TokenTransfer.transferExact(asset, recipient, amount);
        }
    }

    /// @dev Reverts if an ERC-20's receipts fell below the recorded high-water mark. Otherwise
    ///      `current` is at least the receipts every earlier release saw (for ETH always, as
    ///      its receipts never fall), so the cumulative entitlement is at least what was released
    ///      and the subtraction cannot underflow.
    function _due(address asset, uint256 index, uint256 current) private view returns (uint256) {
        if (asset != address(0)) {
            uint256 recorded = recordedObserved[asset];
            if (current < recorded) revert ObservedDecreased(asset, recorded, current);
        }
        return Splits.entitlement(current, _payee(index).share) - released[asset][index];
    }

    function _observed(address asset) private view returns (uint256) {
        uint256 balance = asset == address(0)
            ? address(this).balance
            : TokenTransfer.balanceOf(asset, address(this));
        return balance + totalReleased[asset];
    }

    /// @dev A fixed payee's account, or an artist-resolved payee's current payout address from the
    ///      pinned resolver; `artist` says which.
    function _payout(uint256 index) private view returns (address account, bool artist) {
        Payee storage p = _payee(index);
        if (p.artistId == 0) return (p.account, false);
        if (address(resolver).codehash != resolverCodeHash) revert ResolverCodeChanged();
        account = resolver.payoutAddress(p.artistId);
        if (account == address(0)) revert PayoutUnresolved(p.artistId);
        return (account, true);
    }

    function _payee(uint256 index) private view returns (Payee storage) {
        if (index >= _payees.length) revert UnknownPayee(index);
        return _payees[index];
    }
}
