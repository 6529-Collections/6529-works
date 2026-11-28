// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { IDirectory } from "../interfaces/core/IDirectory.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { SignatureVerifier } from "../libraries/SignatureVerifier.sol";
import { IArtistPayoutResolver } from "./interfaces/IArtistPayoutResolver.sol";
import { IReleaseVerifier } from "./interfaces/IReleaseVerifier.sol";
import { ISplitFactory } from "./interfaces/ISplitFactory.sol";
import { ISplitLedger } from "./interfaces/ISplitLedger.sol";
import { ISplitWallet } from "./interfaces/ISplitWallet.sol";
import { Splits } from "./Splits.sol";
import { SplitVault } from "./SplitVault.sol";
import { TokenTransfer } from "./TokenTransfer.sol";

/// @title SplitLedger
/// @notice The one permanent split contract (ADR 0001 sections 7 and 11). It deploys every split
///         wallet as a 66-byte `SplitVault` at a CREATE2 address that commits to the payee list
///         and a salt, keeps every wallet's accounting, executes every release, and verifies
///         signed releases. A wallet accepts ETH and any ERC-20 passively; each payee may release
///         `floor(observed * share / 100,000)` minus what it has already released, where
///         `observed` is the wallet's balance plus everything released from it. Because
///         entitlements are cumulative, release order never matters and rounding dust stays
///         below the number of payees.
/// @dev Permissionless, unowned and immutable: no governance, no asset allowlist, no
///      `delegatecall`; the only way money leaves a wallet other than to its payees is the
///      unclaimed-share rule ({mark}, {forfeit}), which pays the network. Funds stay in each wallet (never pooled), so a token that blocks one
///      wallet blocks only that wallet. The ledger stores one word per wallet, its payee hash
///      (`configOf`), and takes the payee list in calldata wherever it needs it, so deploying a
///      wallet writes one slot whatever its payee count.
///      Every ERC-20 release is checked by exact balance deltas on both sides, so a token that
///      charges fees, rebases with rounding or returns `false` fails closed for its own releases
///      only. A token that returns nothing from `transfer` releases normally, because the deltas
///      prove the move and a wallet has no other way out of a token a marketplace chose to pay
///      royalties in. A recorded high-water mark of each ERC-20's `observed` makes a balance
///      that shrinks (a negative rebase) fail closed too. ETH needs none: nothing but a release
///      can take ETH out of a wallet, and a release adds what it sends to `totalReleased` first.
///      Each wallet has its own transient reentrancy lock, held by every state-changing entry
///      point for that wallet; the views revert while it is held.
///      Fixed payees are push: anyone may pay them at their own account. Artist-resolved payees
///      are pull-only (only the current payout address, directly or by a signature this ledger
///      checks), so nobody can push an accrued balance to a lost key before recovery.
///      Every external call forwards all available gas and any failure reverts the release, so
///      no gas shortfall can produce a partial or success-shaped result.
///      The network: every release also pays the network fee vault ({network}) its
///      share of the same asset when the vault is a payee of the wallet, and a payee's share that
///      someone marked and that is still unreleased once the unclaimed period has passed goes to
///      the network. The period is the network's setting, read from the resolver
///      (`IDirectory.unclaimedPeriod`, 180 days at launch) when a forfeit is attempted, so a
///      change applies to marks already running; what a mark covers never changes. The ledger
///      itself gains no authority, setter or storage for it.
contract SplitLedger is ISplitLedger, EIP712 {
    /// @notice The EIP-712 type hash of {IReleaseVerifier.Authorization}.
    bytes32 public constant RELEASE_TYPEHASH = keccak256(
        "ReleaseAuthorization(address wallet,address asset,uint256 payee,address account,address recipient,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    /// @inheritdoc ISplitFactory
    IArtistPayoutResolver public immutable resolver;

    /// @inheritdoc ISplitFactory
    address public immutable network;

    /// @inheritdoc ISplitFactory
    bytes32 public immutable walletInitCodeHash;

    /// @inheritdoc ISplitFactory
    mapping(address wallet => bytes32) public configOf;

    /// @inheritdoc ISplitWallet
    mapping(address wallet => mapping(address asset => mapping(uint256 index => uint256))) public
        released;
    /// @inheritdoc ISplitWallet
    mapping(address wallet => mapping(address asset => uint256)) public totalReleased;
    /// @inheritdoc ISplitWallet
    mapping(address wallet => mapping(address asset => uint256)) public recordedObserved;

    /// @dev Bit `nonce % 256` of word `nonce / 256` is set once `account` used `nonce`.
    mapping(address account => mapping(uint256 word => uint256 bits)) private _nonceBitmap;

    /// @dev A payee's mark, one storage slot: `target` is the released level the payee must reach
    ///      to clear the mark (never zero in a mark that exists) and `markedAt` the time it was
    ///      placed.
    struct Mark {
        uint208 target;
        uint48 markedAt;
    }

    /// @dev Each payee's mark; all zero when there is none.
    mapping(address wallet => mapping(address asset => mapping(uint256 index => Mark))) private
        _marks;

    /// @param resolver_ The artist payout resolver (the `StreamDirectory6529`), which also answers
    ///        the unclaimed period (`IDirectory.unclaimedPeriod`). It must have code and not be an
    ///        EIP-7702 delegated account.
    /// @param network_ The network fee vault (a `GovernedVault`), deployed first. It must have
    ///        code and not be an EIP-7702 delegated account.
    constructor(IArtistPayoutResolver resolver_, address network_)
        EIP712("6529 Works Release Verifier", "1")
    {
        Dependency.check(address(resolver_));
        Dependency.check(network_);
        resolver = resolver_;
        network = network_;
        walletInitCodeHash = keccak256(SplitVault.INIT_CODE);
    }

    // ------------------------------------------------------------------ wallets

    /// @inheritdoc ISplitFactory
    function createWallet(Payee[] calldata payees, bytes32 salt) external returns (address wallet) {
        Splits.validate(payees);
        bytes32 configHash = keccak256(abi.encode(payees));
        bytes32 walletSalt = _walletSalt(configHash, salt);
        wallet = Create2.computeAddress(walletSalt, walletInitCodeHash);
        if (configOf[wallet] != bytes32(0)) return wallet;
        address deployed = Create2.deploy(0, walletSalt, SplitVault.INIT_CODE);
        if (deployed != wallet) revert WalletAddressMismatch(wallet, deployed);
        configOf[wallet] = configHash;
        emit WalletCreated(wallet, configHash, salt, payees);
    }

    /// @inheritdoc ISplitFactory
    function isWallet(address wallet) external view returns (bool) {
        return configOf[wallet] != bytes32(0);
    }

    /// @inheritdoc ISplitFactory
    function walletFor(Payee[] calldata payees, bytes32 salt) external view returns (address) {
        Splits.validate(payees);
        return Create2.computeAddress(
            _walletSalt(keccak256(abi.encode(payees)), salt), walletInitCodeHash
        );
    }

    // ------------------------------------------------------------------ releases

    /// @inheritdoc ISplitWallet
    function release(Payee[] calldata payees, bytes32 salt, address asset, uint256 index)
        external
        returns (uint256 amount)
    {
        address wallet = _walletOf(payees, salt);
        _lock(wallet);
        Payee calldata p = _payee(payees, index);
        (address account, bool artist) = _payout(p);
        if (artist && msg.sender != account) revert NotPayoutAddress(msg.sender, account);
        amount = _release(wallet, asset, index, p.share, account, account, type(uint256).max);
        _payNetwork(payees, wallet, asset, index);
        _unlock(wallet);
    }

    /// @inheritdoc ISplitWallet
    function releaseTo(
        Payee[] calldata payees,
        bytes32 salt,
        address asset,
        uint256 index,
        address recipient
    ) external returns (uint256 amount) {
        address wallet = _walletOf(payees, salt);
        _lock(wallet);
        Payee calldata p = _payee(payees, index);
        (address account,) = _payout(p);
        if (msg.sender != account) revert NotPayoutAddress(msg.sender, account);
        amount = _release(wallet, asset, index, p.share, account, recipient, type(uint256).max);
        _payNetwork(payees, wallet, asset, index);
        _unlock(wallet);
    }

    /// @inheritdoc ISplitLedger
    function releaseWithAuthorization(
        Payee[] calldata payees,
        bytes32 salt,
        Authorization calldata authorization,
        bytes calldata signature
    ) external returns (uint256 amount) {
        address wallet = _walletOf(payees, salt);
        if (authorization.wallet != wallet) revert WrongWallet(authorization.wallet, wallet);
        _lock(wallet);
        Payee calldata p = _payee(payees, authorization.payee);
        (address account,) = _payout(p);
        if (authorization.account != account) {
            revert NotPayoutAddress(authorization.account, account);
        }
        SignatureVerifier.checkDeadline(authorization.deadline);
        SignatureVerifier.check(account, releaseDigest(authorization), signature);
        _useNonce(account, authorization.nonce, false);
        amount = _release(
            wallet,
            authorization.asset,
            authorization.payee,
            p.share,
            account,
            authorization.recipient,
            authorization.amount
        );
        _payNetwork(payees, wallet, authorization.asset, authorization.payee);
        _unlock(wallet);
    }

    // ------------------------------------------------------------------ unclaimed shares

    /// @inheritdoc ISplitLedger
    function mark(Payee[] calldata payees, bytes32 salt, address asset, uint256 index) external {
        address wallet = _walletOf(payees, salt);
        _checkUnlocked(wallet);
        if (configOf[wallet] == bytes32(0)) revert WalletNotDeployed(wallet);
        uint32 share = _payee(payees, index).share;
        uint256 done = released[wallet][asset][index];
        uint256 due = _dueNow(wallet, asset, index, share);
        if (due == 0) revert NothingToRelease(asset, index);
        // A mark the payee has not yet released past keeps its clock: nobody can restart it.
        if (done < _marks[wallet][asset][index].target) revert MarkPending(wallet, asset, index);
        uint256 target = done + due;
        _marks[wallet][asset][index] = Mark({
            target: SafeCast.toUint208(target), markedAt: SafeCast.toUint48(block.timestamp)
        });
        emit Marked(wallet, asset, index, target, block.timestamp);
    }

    /// @inheritdoc ISplitLedger
    function forfeit(Payee[] calldata payees, bytes32 salt, address asset, uint256 index)
        external
        returns (uint256 amount)
    {
        address wallet = _walletOf(payees, salt);
        _lock(wallet);
        uint32 share = _payee(payees, index).share;
        amount = _forfeitable(wallet, asset, index, share);
        address net = network;
        amount = _release(wallet, asset, index, share, net, net, amount);
        emit Forfeited(wallet, asset, index, amount);
        _payNetwork(payees, wallet, asset, index);
        _unlock(wallet);
    }

    /// @inheritdoc ISplitLedger
    function markOf(address wallet, address asset, uint256 index)
        external
        view
        returns (uint256 target, uint256 markedAt)
    {
        Mark memory m = _marks[wallet][asset][index];
        return (m.target, m.markedAt);
    }

    // ------------------------------------------------------------------ nonces

    /// @inheritdoc IReleaseVerifier
    function revokeNonce(uint256 nonce) external {
        _useNonce(msg.sender, nonce, true);
    }

    /// @inheritdoc IReleaseVerifier
    function nonceUsed(address account, uint256 nonce) external view returns (bool) {
        return _nonceBitmap[account][nonce >> 8] & _bit(nonce) != 0;
    }

    /// @inheritdoc IReleaseVerifier
    function releaseDigest(Authorization calldata authorization) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(RELEASE_TYPEHASH, authorization)));
    }

    /// @inheritdoc IReleaseVerifier
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc ISplitWallet
    /// @dev Reverts while a release of `wallet` is in progress, so no caller reads half-updated
    ///      accounting.
    function observed(address wallet, address asset) external view returns (uint256) {
        _checkUnlocked(wallet);
        return _balance(wallet, asset) + totalReleased[wallet][asset];
    }

    /// @inheritdoc ISplitWallet
    /// @dev Reverts while a release of the wallet is in progress, and with {ObservedDecreased}
    ///      while the asset is frozen, so a frozen balance never reads as "nothing owed".
    function releasable(Payee[] calldata payees, bytes32 salt, address asset, uint256 index)
        external
        view
        returns (uint256)
    {
        address wallet = _walletOf(payees, salt);
        _checkUnlocked(wallet);
        uint32 share = _payee(payees, index).share;
        uint256 current = _balance(wallet, asset) + totalReleased[wallet][asset];
        return _due(wallet, asset, index, share, current);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Effects before the transfer; the wallet's lock blocks every reentry path into it.
    function _release(
        address wallet,
        address asset,
        uint256 index,
        uint32 share,
        address account,
        address recipient,
        uint256 requested
    ) private returns (uint256 amount) {
        if (recipient == address(0) || recipient == wallet || recipient == address(this)) {
            revert InvalidRecipient(recipient);
        }
        uint256 balance = _balance(wallet, asset);
        uint256 current = balance + totalReleased[wallet][asset];
        uint256 due = _due(wallet, asset, index, share, current);
        amount = requested == type(uint256).max ? due : requested;
        if (amount == 0) revert NothingToRelease(asset, index);
        if (amount > due) revert AmountExceedsReleasable(amount, due);

        released[wallet][asset][index] += amount;
        totalReleased[wallet][asset] += amount;
        if (asset != address(0) && current != recordedObserved[wallet][asset]) {
            recordedObserved[wallet][asset] = current;
        }
        emit Released(wallet, asset, recipient, index, account, amount, current);

        if (!_move(wallet, asset, recipient, amount, balance)) {
            if (asset == address(0)) revert ETHTransferFailed(recipient, amount);
            revert TokenTransfer.TokenCallFailed(asset, IERC20.transfer.selector);
        }
    }

    /// @dev Clears a matured mark and returns what of it is still unreleased, at most what the
    ///      payee can release now: only what was due at the mark, never money that arrived later.
    ///      Reverts with {MarkNotDue} when there is no mark or it is younger than the unclaimed
    ///      period, read from the resolver now (a plain call: if it fails, the forfeit reverts
    ///      and the money stays in the wallet).
    function _forfeitable(address wallet, address asset, uint256 index, uint32 share)
        private
        returns (uint256 amount)
    {
        Mark memory m = _marks[wallet][asset][index];
        {
            bool none = m.target == 0;
            uint256 dueAt = none ? 0 : m.markedAt + IDirectory(address(resolver)).unclaimedPeriod();
            // forge-lint: disable-next-line(block-timestamp)
            if (none || block.timestamp < dueAt) revert MarkNotDue(wallet, asset, index, dueAt);
        }
        delete _marks[wallet][asset][index];
        uint256 done = released[wallet][asset][index];
        amount = done < m.target ? m.target - done : 0;
        uint256 due = _dueNow(wallet, asset, index, share);
        if (amount > due) amount = due;
    }

    /// @dev What payee `index` can release now.
    function _dueNow(address wallet, address asset, uint256 index, uint32 share)
        private
        view
        returns (uint256)
    {
        return _due(
            wallet, asset, index, share, _balance(wallet, asset) + totalReleased[wallet][asset]
        );
    }

    /// @dev After a release of payee `paid` of `wallet`, pays the network fee vault, when it
    ///      is a fixed payee of the wallet, everything it is due in the same asset, under the
    ///      wallet's lock that the release holds. The move comes first and the accounting is
    ///      written only once it succeeded; a refusal (the token will not pay the vault) leaves the
    ///      share due and the release stands. A shortfall or a balance mismatch reverts. Only the
    ///      network is pushed: any other fixed payee could spend all the gas it is forwarded and
    ///      so block every payee's release.
    function _payNetwork(Payee[] calldata payees, address wallet, address asset, uint256 paid)
        private
    {
        address net = network;
        uint256 count = payees.length;
        // A release only gets here for a deployed wallet, whose list is canonical.
        uint256 i = Splits.lowerBound(payees, net);
        if (i == count || i == paid || payees[i].artistId != 0 || payees[i].account != net) {
            return;
        }
        uint256 balance = _balance(wallet, asset);
        uint256 current = balance + totalReleased[wallet][asset];
        uint256 due = _due(wallet, asset, i, payees[i].share, current);
        if (due == 0) return;
        if (_move(wallet, asset, net, due, balance)) {
            released[wallet][asset][i] += due;
            totalReleased[wallet][asset] += due;
            emit Released(wallet, asset, net, i, net, due, current);
        } else if (_balance(wallet, asset) != balance) {
            // A refusal that moved funds anyway cannot be accounted: fail closed.
            _revertMismatch(wallet, asset);
        }
    }

    /// @dev A move whose balances came out wrong: {WalletNotDeployed} when nothing is deployed at
    ///      `wallet`, else `TokenTransfer.TokenBalanceMismatch`. Only reached on failure, so the
    ///      code-size read costs a successful release nothing.
    function _revertMismatch(address wallet, address asset) private view {
        if (wallet.code.length == 0) revert WalletNotDeployed(wallet);
        revert TokenTransfer.TokenBalanceMismatch(asset);
    }

    /// @dev Has `wallet` send `amount` of `asset` to `recipient`; `balance` is the wallet's
    ///      balance read before the move. True when exactly `amount` moved; false when the
    ///      recipient (ETH) or the token refused. An ERC-20 `transfer` counts when it returns
    ///      `true` or nothing; a `false` or any other return is a refusal. A counted move with any
    ///      balance change other than exactly `amount` on both sides reverts (ECO-23). The
    ///      outcome, not the call, proves an ETH move: a call to an address without code
    ///      "succeeds" and moves nothing.
    function _move(
        address wallet,
        address asset,
        address recipient,
        uint256 amount,
        uint256 balance
    ) private returns (bool) {
        if (asset == address(0)) {
            (bool sent,) = _instruct(wallet, recipient, amount, "");
            if (!sent) return false;
            if (wallet.balance != balance - amount) _revertMismatch(wallet, asset);
            return true;
        }
        uint256 toBefore = TokenTransfer.balanceOf(asset, recipient);
        (bool ok, bytes memory data) =
            _instruct(wallet, asset, 0, abi.encodeCall(IERC20.transfer, (recipient, amount)));
        if (!ok || (data.length != 0 && (data.length != 32 || uint256(bytes32(data)) != 1))) {
            return false;
        }
        if (
            TokenTransfer.balanceOf(asset, wallet) != balance - amount
                || TokenTransfer.balanceOf(asset, recipient) != toBefore + amount
        ) _revertMismatch(wallet, asset);
        return true;
    }

    /// @dev Tells `wallet` to call `target` with `value` of its own wei and `data`, forwarding all
    ///      gas, and copies at most one word of the callee's return data (a longer return is a
    ///      refusal). A failure that left at most 1/8 of the gas held before the call, as an
    ///      out-of-gas two frames down (the vault, then the recipient or token) does, reverts with
    ///      `BoundedCall.BoundedCallShortfall` instead of reading as a refusal.
    function _instruct(address wallet, address target, uint256 value, bytes memory data)
        private
        returns (bool ok, bytes memory answer)
    {
        return BoundedCall.tryCallAll(
            wallet, 0, abi.encodePacked(uint256(uint160(target)), value, data), 32
        );
    }

    /// @dev Reverts if an ERC-20's receipts fell below the recorded high-water mark. Otherwise
    ///      `current` is at least the receipts every earlier release saw (for ETH always, as
    ///      its receipts never fall), so the cumulative entitlement is at least what was released
    ///      and the subtraction cannot underflow.
    function _due(address wallet, address asset, uint256 index, uint32 share, uint256 current)
        private
        view
        returns (uint256)
    {
        if (asset != address(0)) {
            uint256 recorded = recordedObserved[wallet][asset];
            if (current < recorded) revert ObservedDecreased(asset, recorded, current);
        }
        return Splits.entitlement(current, share) - released[wallet][asset][index];
    }

    function _balance(address wallet, address asset) private view returns (uint256) {
        return asset == address(0) ? wallet.balance : TokenTransfer.balanceOf(asset, wallet);
    }

    /// @dev The wallet a payee list and salt name: the CREATE2 address, deployed or not. Nothing
    ///      is read from storage; a list that is not canonical names an address where no wallet
    ///      can exist, and a release from it fails its balance checks.
    function _walletOf(Payee[] calldata payees, bytes32 salt) private view returns (address) {
        return Create2.computeAddress(
            _walletSalt(keccak256(abi.encode(payees)), salt), walletInitCodeHash
        );
    }

    function _payee(Payee[] calldata payees, uint256 index) private pure returns (Payee calldata) {
        if (index >= payees.length) revert UnknownPayee(index);
        return payees[index];
    }

    /// @dev A fixed payee's account, or an artist-resolved payee's current payout address from the
    ///      resolver; `artist` says which. The read forwards all gas: a resolver that refuses, or
    ///      answers zero or something that is not an address, leaves the payee unresolved, and one
    ///      that runs short reverts with `BoundedCall.BoundedCallShortfall`.
    function _payout(Payee calldata p) private view returns (address account, bool artist) {
        uint256 artistId = p.artistId;
        if (artistId == 0) return (p.account, false);
        (bool ok, bytes32 word) = BoundedCall.tryReadWordAll(
            address(resolver), abi.encodeCall(IArtistPayoutResolver.payoutAddress, (artistId))
        );
        if (!ok || word == 0 || uint256(word) >> 160 != 0) revert PayoutUnresolved(artistId);
        return (address(uint160(uint256(word))), true);
    }

    /// @dev The CREATE2 salt: the payee configuration hash and the caller's salt.
    function _walletSalt(bytes32 configHash, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(configHash, salt));
    }

    function _useNonce(address account, uint256 nonce, bool revoked) private {
        uint256 bit = _bit(nonce);
        uint256 bits = _nonceBitmap[account][nonce >> 8];
        if (bits & bit != 0) revert NonceAlreadyUsed(account, nonce);
        _nonceBitmap[account][nonce >> 8] = bits | bit;
        emit NonceUsed(account, nonce, revoked);
    }

    function _bit(uint256 nonce) private pure returns (uint256) {
        return uint256(1) << (nonce & 0xff);
    }

    /// @dev Each wallet's lock is the transient word at the wallet's address; the ledger keeps
    ///      nothing else in transient storage.
    function _lock(address wallet) private {
        _checkUnlocked(wallet);
        assembly ("memory-safe") {
            tstore(wallet, 1)
        }
    }

    function _unlock(address wallet) private {
        assembly ("memory-safe") {
            tstore(wallet, 0)
        }
    }

    function _checkUnlocked(address wallet) private view {
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(wallet)
        }
        if (locked != 0) revert ReentrancyGuardReentrantCall();
    }
}
