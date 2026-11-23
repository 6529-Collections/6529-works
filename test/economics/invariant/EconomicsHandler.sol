// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { EscrowLots } from "../EscrowLots.sol";
import {
    BlocklistToken,
    FeeOnTransferToken,
    ForceSender,
    MockArtistResolver,
    NoReturnToken,
    RebasingToken,
    ToggleRecipient
} from "../../mocks/economics/EconomicsMocks.sol";
import { PaymentHarness } from "../EconomicsBase.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";

/// @notice Drives the economics contracts with valid and invalid actions against an independent
///         model. Every action is attempted: the model predicts success (and the exact amount) or
///         the exact revert, from its own ghost state (payouts, measured releases, the receipts
///         high-water mark and each token's rules), never from `releasable`. Released amounts are
///         recorded from measured balance deltas. Assets: ETH, a USDC-style blocklist token, a
///         fee-on-transfer token whose fee is toggled, a rebasing token whose index moves, and a
///         token whose `transfer` returns nothing (wallets only: it is never a sale currency, so
///         payments, deposits and flushes do not use it).
///         The network (R11, R12, C19): some wallets name the network fee vault as a payee, and
///         every release from them also pushes the vault its due share, which the model predicts
///         (paid, refused by the token, or reverting the whole release). Marks, forfeits after
///         180 days, escrow expiry after 180 days and the network's recovery of its own credits
///         are modelled the same way; `warp` moves the clock.
///         `fail_on_revert` is on, so any unpredicted revert or mismatch fails the campaign.
contract EconomicsHandler is Test {
    address internal constant ETH = address(0);
    uint256 internal constant D = 100_000;

    struct Setup {
        address[] wallets;
        ISplitWallet.Payee[][] payeeLists;
        bytes32[] salts;
        ToggleRecipient toggle;
        RevenueEscrow escrow;
        ClaimRouter router;
        PaymentHarness payer;
        SplitLedger ledger;
        BlocklistToken usdc;
        FeeOnTransferToken fee;
        RebasingToken rebase;
        NoReturnToken silent;
        MockArtistResolver resolver;
        uint256[] keys;
        uint256[] artistIds;
    }

    /// @dev One release attempt. Mode 0: `release`; 1: `releaseTo`; 2: signed.
    struct Attempt {
        address w;
        uint256 index;
        address asset;
        address caller;
        address recipient;
        uint256 requested;
        uint8 mode;
        address signer;
    }

    address[] public wallets;
    ToggleRecipient public toggle;
    RevenueEscrow public escrow;
    ClaimRouter public router;
    PaymentHarness public payer;
    SplitLedger public ledger;
    BlocklistToken public usdc;
    FeeOnTransferToken public fee;
    RebasingToken public rebase;
    NoReturnToken public silent;
    MockArtistResolver public resolver;
    address[] public assets;
    address[] public actors;
    uint256[] public artistIds;
    mapping(address => uint256) internal keyOf;
    mapping(uint256 => address) public artistPayout;

    /// @notice Everything that reached each wallet, per asset (rebasing excluded: it drifts).
    mapping(address wallet => mapping(address asset => uint256)) public received;
    /// @notice Released per payee, measured from the recipient's balance change.
    mapping(address wallet => mapping(address asset => mapping(uint256 index => uint256))) public
        ghostReleased;
    mapping(address wallet => mapping(address asset => uint256)) public ghostTotal;
    /// @notice The model's receipts high-water mark per wallet and asset.
    mapping(address wallet => mapping(address asset => uint256)) public modelHigh;
    /// @notice Everything recipients measurably received from releases, per asset.
    mapping(address asset => uint256) public paidOut;
    /// @notice The model's escrow credits per key.
    mapping(address target => mapping(address asset => uint256)) public ghostOwed;
    /// @notice How often each outcome occurred, to show the campaign is not vacuous.
    mapping(bytes32 => uint256) public outcomes;
    /// @notice The replacement the non-wallet target (`toggle`) consented to, or zero (MONEY-2).
    address public toggleConsent;
    /// @notice What the escrow holds beyond every credit, per asset: tokens transferred to it
    ///         and ETH force-sent to it without a deposit, less what `sweepExcess` took.
    mapping(address asset => uint256) public ghostExcess;
    /// @notice Where governed sweeps send the excess: never an actor or a target.
    address public beneficiary = makeAddr("sweepBeneficiary");
    /// @notice Each wallet's payee list and salt: the ledger stores neither.
    mapping(address wallet => ISplitWallet.Payee[]) internal _payees;
    mapping(address wallet => bytes32) public saltOf;

    /// @notice The network fee vault the ledger names.
    address public network;
    /// @notice Whether a wallet names the network as a payee.
    mapping(address wallet => bool) public isNetworkWallet;
    /// @notice The model's marks: the released level to reach and when it was placed.
    mapping(address wallet => mapping(address asset => mapping(uint256 index => uint256))) public
        markTarget;
    mapping(address wallet => mapping(address asset => mapping(uint256 index => uint256))) public
        markAt;
    /// @notice What the network vault received other than from wallets (payments, flushes).
    mapping(address asset => uint256) public networkOther;
    /// @notice The model's escrow credits lot by lot, with their windows (R12, ECO-45).
    mapping(address target => mapping(address asset => EscrowLots.Book)) internal _books;

    uint256 internal constant UNCLAIMED = 180 days;

    uint256 internal nonce;
    IReleaseVerifier.Authorization internal lastAuth;
    bytes internal lastSig;
    bool internal hasLast;

    constructor(Setup memory s) {
        wallets = s.wallets;
        network = s.ledger.network();
        for (uint256 i; i < s.wallets.length; ++i) {
            saltOf[s.wallets[i]] = s.salts[i];
            for (uint256 j; j < s.payeeLists[i].length; ++j) {
                _payees[s.wallets[i]].push(s.payeeLists[i][j]);
                if (s.payeeLists[i][j].account == network) isNetworkWallet[s.wallets[i]] = true;
            }
        }
        toggle = s.toggle;
        escrow = s.escrow;
        router = s.router;
        payer = s.payer;
        ledger = s.ledger;
        usdc = s.usdc;
        fee = s.fee;
        rebase = s.rebase;
        silent = s.silent;
        resolver = s.resolver;
        artistIds = s.artistIds;
        assets.push(ETH);
        assets.push(address(s.usdc));
        assets.push(address(s.fee));
        assets.push(address(s.rebase));
        assets.push(address(s.silent));
        for (uint256 i; i < s.keys.length; ++i) {
            address actor = vm.addr(s.keys[i]);
            actors.push(actor);
            keyOf[actor] = s.keys[i];
        }
        for (uint256 i; i < s.artistIds.length; ++i) {
            artistPayout[s.artistIds[i]] = resolver.payoutAddress(s.artistIds[i]);
        }
        usdc.approve(address(escrow), type(uint256).max);
        fee.approve(address(escrow), type(uint256).max);
    }

    // ------------------------------------------------------------------ releases

    function release(uint256 walletSeed, uint256 payeeSeed, uint256 assetSeed, uint256 callerSeed)
        external
    {
        Attempt memory t = _attemptFor(walletSeed, payeeSeed, assets[assetSeed % 5], 0);
        if (callerSeed % 3 == 0) t.caller = _actor(callerSeed);
        _run(t);
    }

    function releaseTo(
        uint256 walletSeed,
        uint256 payeeSeed,
        uint256 assetSeed,
        uint256 callerSeed,
        uint256 recipientSeed
    ) external {
        Attempt memory t = _attemptFor(walletSeed, payeeSeed, assets[assetSeed % 5], 1);
        if (callerSeed % 3 == 0) t.caller = _actor(callerSeed);
        t.recipient = _actor(recipientSeed);
        _run(t);
    }

    function releaseSigned(
        uint256 walletSeed,
        uint256 payeeSeed,
        uint256 assetSeed,
        uint256 amountSeed,
        uint256 signerSeed,
        uint256 recipientSeed
    ) external {
        Attempt memory t = _attemptFor(walletSeed, payeeSeed, assets[assetSeed % 5], 2);
        if (signerSeed % 4 == 0) t.signer = _actor(signerSeed);
        t.recipient = _actor(recipientSeed);
        // Mostly the whole amount; sometimes an exact amount that may exceed what is due.
        if (amountSeed % 3 == 0) t.requested = bound(amountSeed, 1, 1e25);
        _run(t);
    }

    /// @notice Replays the last signed authorization: it must fail on its spent nonce, or on a
    ///         payout change if the artist's key was replaced since.
    function replaySigned() external {
        if (!hasLast) return;
        IReleaseVerifier.Authorization memory a = lastAuth;
        address w = a.wallet;
        (address payout,) = _payoutOf(w, a.payee);
        bytes memory expected = a.account != payout
            ? abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, a.account, payout)
            : block.timestamp > a.deadline
                ? abi.encodeWithSelector(SignatureVerifier.SignatureExpired.selector, a.deadline)
                : abi.encodeWithSelector(
                    IReleaseVerifier.NonceAlreadyUsed.selector, a.account, a.nonce
                );
        (bool ok, bytes memory ret) = address(ledger)
            .call(
                abi.encodeCall(
                    ISplitLedger.releaseWithAuthorization, (_payees[w], saltOf[w], a, lastSig)
                )
            );
        assertFalse(ok, "replay succeeded");
        assertEq(ret, expected, "replay error");
        ++outcomes["signed.replay"];
    }

    function claimBatch(uint256 seed, uint8 count, bool signed) external {
        uint256 n = bound(count, 1, 4);
        Attempt[] memory items = new Attempt[](n);
        uint256[] memory predicted = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            // Batches use wallets without the network: the router is unchanged, and the network
            // push is modelled on the single-release paths.
            if (isNetworkWallet[_wallet(r)]) r -= r % wallets.length;
            items[k] = _attemptFor(r, r >> 16, (r >> 32) % 2 == 0 ? ETH : address(usdc), 2);
            items[k].caller = address(router);
            if (signed) {
                if ((r >> 48) % 5 == 0) items[k].signer = _actor(r >> 56);
                items[k].recipient = _actor(r >> 64);
            }
            predicted[k] = _predictBatchItem(items, predicted, k, signed);
        }
        uint256[2] memory before = [_actorSum(ETH), _actorSum(address(usdc))];
        uint256[] memory amounts = signed ? _submitSigned(items) : _submitPlain(items);
        uint256[2] memory paid;
        for (uint256 k; k < n; ++k) {
            assertEq(amounts[k], predicted[k], "batch item amount");
            if (amounts[k] == 0) {
                ++outcomes["batch.failed"];
                continue;
            }
            ++outcomes[signed ? bytes32("batch.signedPaid") : bytes32("batch.paid")];
            Attempt memory t = items[k];
            paid[t.asset == ETH ? 0 : 1] += amounts[k];
            ghostReleased[address(t.w)][t.asset][t.index] += amounts[k];
            ghostTotal[address(t.w)][t.asset] += amounts[k];
            modelHigh[address(t.w)][t.asset] = _observed(t.w, t.asset);
        }
        // Recipient side: actors' balances grew by exactly what the batch reported.
        assertEq(_actorSum(ETH) - before[0], paid[0], "batch ETH paid out");
        assertEq(_actorSum(address(usdc)) - before[1], paid[1], "batch token paid out");
        paidOut[ETH] += paid[0];
        paidOut[address(usdc)] += paid[1];
    }

    // ------------------------------------------------------------------ money in

    /// @dev A sale payment: ETH to the wallet, or to its escrow credit when the wallet refuses.
    function pay(uint256 targetSeed, uint256 amount) external {
        address target = _target(targetSeed);
        amount = amount % 7 == 0 ? 0 : bound(amount, 1, 50 ether);
        bool expectEscrow = amount != 0 && target == address(toggle) && !toggle.open();
        vm.deal(address(payer), address(payer).balance + amount);
        assertEq(payer.payETH(target, amount, 50_000), expectEscrow, "payment route");
        if (amount == 0) return;
        if (expectEscrow) {
            _ghostCredit(target, ETH, amount);
            ++outcomes["pay.escrow"];
        } else {
            if (target == network) networkOther[ETH] += amount;
            else if (target != address(toggle)) received[target][ETH] += amount;
            ++outcomes["pay.direct"];
        }
    }

    function receiveDirect(uint256 walletSeed, uint256 assetSeed, uint256 amount) external {
        address w = _wallet(walletSeed);
        address asset = assets[assetSeed % 5];
        amount = bound(amount, 1, asset == ETH ? 50 ether : 1e24);
        if (asset == ETH) vm.deal(address(w), address(w).balance + amount);
        else BlocklistToken(asset).mint(address(w), amount);
        if (asset != address(rebase)) received[address(w)][asset] += amount;
    }

    function deposit(uint256 targetSeed, uint256 assetSeed, uint256 amount) external {
        address target = _target(targetSeed);
        address asset = assets[assetSeed % 3];
        amount = amount % 9 == 0 ? 0 : bound(amount, 1, asset == ETH ? 50 ether : 1e24);
        bytes memory expected;
        if (amount == 0) {
            expected = abi.encodeWithSelector(IRevenueEscrow.ZeroAmount.selector);
        } else if (asset == address(fee) && amount * fee.feeBps() / 10_000 != 0) {
            expected = abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, asset);
        }
        bool ok;
        bytes memory ret;
        if (asset == ETH) {
            vm.deal(address(this), amount);
            (ok, ret) = address(escrow).call{ value: amount }(
                abi.encodeCall(IRevenueEscrow.depositETH, (target))
            );
        } else {
            BlocklistToken(asset).mint(address(this), amount);
            (ok, ret) = address(escrow)
                .call(abi.encodeCall(IRevenueEscrow.depositERC20, (target, asset, amount)));
        }
        if (expected.length != 0) {
            assertFalse(ok, "deposit should revert");
            assertEq(ret, expected, "deposit error");
            ++outcomes["deposit.reverted"];
            return;
        }
        assertTrue(ok, "deposit reverted");
        _ghostCredit(target, asset, amount);
        ++outcomes["deposit.ok"];
    }

    function flush(uint256 targetSeed, uint256 assetSeed) external {
        address target = _target(targetSeed);
        address asset = assets[assetSeed % 3];
        uint256 owed = ghostOwed[target][asset];
        bytes memory expected;
        if (owed == 0) {
            expected = abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, target, asset);
        } else if (asset == ETH && target == address(toggle) && !toggle.open()) {
            expected =
                abi.encodeWithSelector(IRevenueEscrow.ETHTransferFailed.selector, target, owed);
        } else if (asset == address(usdc) && usdc.blocked(target)) {
            expected = abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, asset, usdc.transfer.selector
            );
        } else if (asset == address(fee) && owed * fee.feeBps() / 10_000 != 0) {
            expected = abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, asset);
        }
        (bool ok, bytes memory ret) =
            address(escrow).call(abi.encodeCall(IRevenueEscrow.flush, (target, asset)));
        if (expected.length != 0) {
            assertFalse(ok, "flush should revert");
            assertEq(ret, expected, "flush error");
            ++outcomes["flush.reverted"];
            return;
        }
        assertTrue(ok, "flush reverted");
        assertEq(abi.decode(ret, (uint256)), owed);
        ghostOwed[target][asset] = 0;
        EscrowLots.takeAll(_books[target][asset]);
        if (target == network) networkOther[asset] += owed;
        else if (target != address(toggle)) received[target][asset] += owed;
        ++outcomes["flush.ok"];
    }

    /// @notice The non-wallet target (`toggle`) names, changes or withdraws its recovery
    ///         replacement; naming the escrow or itself reverts.
    function consentToggle(uint256 seed) external {
        address to = seed % 4 == 0 ? address(0) : _target(seed >> 2);
        vm.prank(address(toggle));
        (bool ok, bytes memory ret) =
            address(escrow).call(abi.encodeCall(IRevenueEscrow.consentToRecovery, (to)));
        if (to == address(toggle)) {
            assertFalse(ok, "self-consent should revert");
            assertEq(ret, abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, to));
            return;
        }
        assertTrue(ok, "consent reverted");
        toggleConsent = to;
        assertEq(escrow.recoveryConsent(address(toggle)), to);
        ++outcomes["consent.set"];
    }

    /// @notice Governed recovery between any two targets. A wallet's credit may move only to
    ///         its equivalent replacement (same payees, another salt); the network's own credit
    ///         anywhere but zero or itself, without consent (C19); the other non-wallet target's
    ///         only to the replacement it consented to.
    function recover(uint256 fromSeed, uint256 toSeed, uint256 assetSeed) external {
        address from = _target(fromSeed);
        uint256 pick = toSeed % 3;
        address to =
            pick == 0 ? _equivalent(from) : pick == 1 ? toggleConsent : _target(toSeed >> 2);
        address asset = assets[assetSeed % 3];
        bytes memory expected;
        if (from == address(toggle)) {
            if (to == address(0) || to != toggleConsent) {
                expected =
                    abi.encodeWithSelector(IRevenueEscrow.RecoveryNotConsented.selector, from, to);
            }
        } else if (from == network) {
            if (to == address(0) || to == from) {
                expected = abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, to);
            }
        } else if (to == address(toggle) || to == network || to == from || _equivalent(from) != to)
        {
            expected = abi.encodeWithSelector(IRevenueEscrow.NotEquivalentWallet.selector, from, to);
        }
        if (expected.length == 0 && ghostOwed[from][asset] == 0) {
            expected = abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, from, asset);
        }
        (bool ok, bytes memory ret) =
            address(escrow).call(abi.encodeCall(IRevenueEscrow.recover, (from, to, asset)));
        if (expected.length != 0) {
            assertFalse(ok, "recover should revert");
            assertEq(ret, expected, "recover error");
            ++outcomes["recover.rejected"];
            return;
        }
        assertTrue(ok, "recover reverted");
        uint256 moved = ghostOwed[from][asset];
        ghostOwed[from][asset] = 0;
        EscrowLots.takeAll(_books[from][asset]);
        _ghostCredit(to, asset, moved);
        if (from == address(toggle)) {
            toggleConsent = address(0); // single use
            assertEq(escrow.recoveryConsent(from), address(0));
        }
        ++outcomes[
            from == address(toggle)
                ? bytes32("recover.consented")
                : from == network ? bytes32("recover.network") : bytes32("recover.ok")
        ];
    }

    /// @notice Anyone moves the part of a credit whose window matured (every unit at least 180
    ///         days old) to the network (R12); the rest stays. Refused for the network's own
    ///         credit, with nothing owed, and while no window has matured.
    function expire(uint256 targetSeed, uint256 assetSeed) external {
        address target = _target(targetSeed);
        address asset = assets[assetSeed % 3];
        EscrowLots.Book storage book = _books[target][asset];
        uint256 owed = ghostOwed[target][asset];
        uint256 due = EscrowLots.expirable(book, block.timestamp);
        bytes memory expected;
        if (target == network) {
            expected = abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, target);
        } else if (owed == 0) {
            expected = abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, target, asset);
        } else if (due == 0) {
            expected = abi.encodeWithSelector(
                IRevenueEscrow.CreditNotExpired.selector, target, asset, EscrowLots.nextDue(book)
            );
        }
        (bool ok, bytes memory ret) =
            address(escrow).call(abi.encodeCall(IRevenueEscrow.expire, (target, asset)));
        if (expected.length != 0) {
            assertFalse(ok, "expire should revert");
            assertEq(ret, expected, "expire error");
            ++outcomes[keccak256(abi.encode(bytes32("expire"), bytes4(expected)))];
            return;
        }
        assertTrue(ok, "expire reverted");
        assertEq(abi.decode(ret, (uint256)), due, "expire amount");
        assertLe(due, EscrowLots.olderThan(book, block.timestamp, UNCLAIMED), "young money");
        EscrowLots.expire(book, block.timestamp);
        ghostOwed[target][asset] = owed - due;
        _ghostCredit(network, asset, due);
        ++outcomes[due == owed ? bytes32("expire.ok") : bytes32("expire.partial")];
    }

    /// @notice The model's expirable amount of `target`'s credit in `asset` at `time`.
    function modelExpirable(address target, address asset, uint256 time)
        external
        view
        returns (uint256)
    {
        return EscrowLots.expirable(_books[target][asset], time);
    }

    /// @notice The model's credits of `target` in `asset` made at least `age` before `time`.
    function modelOlder(address target, address asset, uint256 time, uint256 age)
        external
        view
        returns (uint256)
    {
        return EscrowLots.olderThan(_books[target][asset], time, age);
    }

    function _ghostCredit(address target, address asset, uint256 amount) internal {
        ghostOwed[target][asset] += amount;
        EscrowLots.credit(_books[target][asset], amount, block.timestamp);
    }

    // ------------------------------------------------------------------ unclaimed shares

    /// @notice Anyone marks a payee's releasable share; a running mark cannot be replaced.
    function mark(uint256 walletSeed, uint256 payeeSeed, uint256 assetSeed) external {
        address w = _wallet(walletSeed);
        uint256 i = payeeSeed % _payees[w].length;
        address asset = assets[assetSeed % 5];
        uint256 current = _observed(w, asset);
        uint256 rel = ghostReleased[w][asset][i];
        uint256 due;
        bytes memory expected;
        if (current < modelHigh[w][asset]) {
            expected = abi.encodeWithSelector(
                ISplitWallet.ObservedDecreased.selector, asset, modelHigh[w][asset], current
            );
        } else {
            due = current * _payees[w][i].share / D - rel;
            if (due == 0) {
                expected = abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, asset, i);
            } else if (markAt[w][asset][i] != 0 && rel < markTarget[w][asset][i]) {
                expected = abi.encodeWithSelector(ISplitLedger.MarkPending.selector, w, asset, i);
            }
        }
        (bool ok, bytes memory ret) = address(ledger)
            .call(abi.encodeCall(ISplitLedger.mark, (_payees[w], saltOf[w], asset, i)));
        if (expected.length != 0) {
            assertFalse(ok, "mark should revert");
            assertEq(ret, expected, "mark error");
            ++outcomes[keccak256(abi.encode(bytes32("mark"), bytes4(expected)))];
            return;
        }
        assertTrue(ok, "mark reverted");
        markTarget[w][asset][i] = rel + due;
        markAt[w][asset][i] = block.timestamp;
        (uint256 target, uint256 at) = ledger.markOf(w, asset, i);
        assertEq(target, rel + due, "mark target");
        assertEq(at, block.timestamp, "mark time");
        ++outcomes["mark.ok"];
    }

    /// @notice Anyone sends a matured mark's unreleased rest to the network: never more than was
    ///         due at the mark and is still unreleased, never money that arrived after it.
    function forfeit(uint256 walletSeed, uint256 payeeSeed, uint256 assetSeed) external {
        address w = _wallet(walletSeed);
        uint256 i = payeeSeed % _payees[w].length;
        address asset = assets[assetSeed % 5];
        (bytes memory expected, uint256 amount, uint256 push) = _expectForfeit(w, i, asset);
        uint256 current = _observed(w, asset);
        uint256 walletBefore = _bal(asset, w);
        uint256 networkBefore = _bal(asset, network);
        (bool ok, bytes memory ret) = address(ledger)
            .call(abi.encodeCall(ISplitLedger.forfeit, (_payees[w], saltOf[w], asset, i)));
        if (expected.length != 0) {
            assertFalse(ok, "forfeit should revert");
            assertEq(ret, expected, "forfeit error");
            assertEq(_bal(asset, w), walletBefore, "residue: wallet");
            ++outcomes[keccak256(abi.encode(bytes32("forfeit"), bytes4(expected)))];
            return;
        }
        assertTrue(ok, "forfeit reverted");
        assertEq(abi.decode(ret, (uint256)), amount, "forfeit amount");
        assertEq(_bal(asset, network) - networkBefore, amount + push, "network delta");
        assertEq(walletBefore - _bal(asset, w), amount + push, "wallet delta");
        ghostReleased[w][asset][i] += amount;
        ghostTotal[w][asset] += amount;
        paidOut[asset] += amount;
        _recordPush(w, asset, push);
        modelHigh[w][asset] = current;
        delete markTarget[w][asset][i];
        delete markAt[w][asset][i];
        (uint256 target,) = ledger.markOf(w, asset, i);
        assertEq(target, 0, "mark cleared");
        ++outcomes["forfeit.ok"];
    }

    function _expectForfeit(address w, uint256 i, address asset)
        internal
        view
        returns (bytes memory err, uint256 amount, uint256 push)
    {
        uint256 at = markAt[w][asset][i];
        uint256 dueAt = at == 0 ? 0 : at + UNCLAIMED;
        if (at == 0 || block.timestamp < dueAt) {
            return
                (abi.encodeWithSelector(ISplitLedger.MarkNotDue.selector, w, asset, i, dueAt), 0, 0);
        }
        uint256 current = _observed(w, asset);
        if (current < modelHigh[w][asset]) {
            return (
                abi.encodeWithSelector(
                    ISplitWallet.ObservedDecreased.selector, asset, modelHigh[w][asset], current
                ),
                0,
                0
            );
        }
        uint256 rel = ghostReleased[w][asset][i];
        uint256 target = markTarget[w][asset][i];
        uint256 due = current * _payees[w][i].share / D - rel;
        amount = rel < target ? target - rel : 0;
        if (amount > due) amount = due;
        if (amount == 0) {
            return (abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, asset, i), 0, 0);
        }
        err = _transferError(asset, w, network, amount, 0, 0);
        if (err.length != 0) return (err, 0, 0);
        (err, push) = _expectPush(w, asset, i, amount, network);
        if (err.length != 0) return (err, 0, 0);
    }

    /// @notice Moves the clock forward, so marks and escrow credits can mature.
    function warp(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1 hours, 200 days));
    }

    // ------------------------------------------------------------------ escrow excess

    /// @notice Transfers ERC-20s straight to the escrow, without a deposit: owed to nobody.
    function strayToken(uint256 assetSeed, uint256 amount) external {
        address asset = assets[1 + assetSeed % 2];
        amount = bound(amount, 1, 1e24);
        BlocklistToken(asset).mint(address(escrow), amount);
        ghostExcess[asset] += amount;
        ++outcomes["excess.token"];
    }

    /// @notice Force-sends ETH to the escrow, which has no `receive`.
    function forceETH(uint256 amount) external {
        amount = bound(amount, 1, 50 ether);
        vm.deal(address(this), amount);
        new ForceSender{ value: amount }(payable(address(escrow)));
        ghostExcess[ETH] += amount;
        ++outcomes["excess.eth"];
    }

    /// @notice Governed sweep of the excess (the handler is admin with zero delay here). It must
    ///         take exactly the excess and leave every credit, and the total owed, untouched.
    function sweep(uint256 assetSeed) external {
        address asset = assets[assetSeed % 3];
        uint256 excess = ghostExcess[asset];
        uint256 totalBefore = escrow.totalOwed(asset);
        uint256[] memory owedBefore = _credits(asset);
        bytes memory expected;
        if (excess == 0) {
            expected = abi.encodeWithSelector(IRevenueEscrow.NothingToSweep.selector, asset);
        } else if (asset == address(fee) && excess * fee.feeBps() / 10_000 != 0) {
            expected = abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, asset);
        }
        uint256 beneficiaryBefore = _bal(asset, beneficiary);
        (bool ok, bytes memory ret) =
            address(escrow).call(abi.encodeCall(IRevenueEscrow.sweepExcess, (asset, beneficiary)));
        if (expected.length != 0) {
            assertFalse(ok, "sweep should revert");
            assertEq(ret, expected, "sweep error");
            ++outcomes["sweep.reverted"];
        } else {
            assertTrue(ok, "sweep reverted");
            assertEq(abi.decode(ret, (uint256)), excess, "sweep takes exactly the excess");
            assertEq(_bal(asset, beneficiary) - beneficiaryBefore, excess, "beneficiary delta");
            ghostExcess[asset] = 0;
            assertEq(_bal(asset, address(escrow)), escrow.totalOwed(asset), "nothing left over");
            ++outcomes["sweep.ok"];
        }
        assertEq(escrow.totalOwed(asset), totalBefore, "sweep moved the total owed");
        uint256[] memory owedAfter = _credits(asset);
        for (uint256 i; i < owedAfter.length; ++i) {
            assertEq(owedAfter[i], owedBefore[i], "sweep moved a credit");
        }
    }

    /// @dev Every target's credit in `asset`, wallets first, then the non-wallet target and the
    ///      network.
    function _credits(address asset) internal view returns (uint256[] memory owed) {
        owed = new uint256[](wallets.length + 2);
        for (uint256 i; i < wallets.length; ++i) {
            owed[i] = escrow.owed(wallets[i], asset);
        }
        owed[wallets.length] = escrow.owed(address(toggle), asset);
        owed[wallets.length + 1] = escrow.owed(network, asset);
    }

    // ------------------------------------------------------------------ environment

    function setArtistPayout(uint256 artistSeed, uint256 actorSeed) external {
        uint256 artistId = artistIds[artistSeed % artistIds.length];
        address account = _actor(actorSeed);
        resolver.set(artistId, account);
        artistPayout[artistId] = account;
    }

    function toggleBlocked(uint256 seed) external {
        uint256 pick = seed % (wallets.length + actors.length + 2);
        address target = pick < wallets.length
            ? address(wallets[pick])
            : pick < wallets.length + actors.length
                ? actors[pick - wallets.length]
                : pick == wallets.length + actors.length ? address(toggle) : network;
        usdc.setBlocked(target, !usdc.blocked(target));
    }

    function toggleOpen() external {
        toggle.setOpen(!toggle.open());
    }

    function toggleFee() external {
        fee.setFee(fee.feeBps() == 0 ? 100 : 0);
    }

    function rebaseTo(uint256 seed) external {
        uint256[6] memory indexes = [uint256(1e18), 1e18, 0.5e18, 0.75e18, 1.25e18, 3e18];
        rebase.setIndex(indexes[seed % indexes.length]);
    }

    function revokeNonce(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        ledger.revokeNonce(++nonce);
    }

    // ------------------------------------------------------------------ views for the invariants

    /// @notice `wallet`'s payee list.
    function payeesOf(address wallet) external view returns (ISplitWallet.Payee[] memory) {
        return _payees[wallet];
    }

    function walletCount() external view returns (uint256) {
        return wallets.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------ model

    function _attemptFor(uint256 walletSeed, uint256 payeeSeed, address asset, uint8 mode)
        internal
        view
        returns (Attempt memory t)
    {
        t.w = _wallet(walletSeed);
        t.index = payeeSeed % _payees[t.w].length;
        t.asset = asset;
        (address payout,) = _payoutOf(t.w, t.index);
        t.caller = payout;
        t.recipient = payout;
        t.requested = type(uint256).max;
        t.mode = mode;
        // The network vault holds no key: an actor signs for it, which the ledger refuses.
        t.signer = keyOf[payout] == 0 ? actors[0] : payout;
    }

    /// @dev Predicts an attempt: the exact revert data, or empty, the amount it pays and the
    ///      network's push that follows it.
    function _expect(Attempt memory t)
        internal
        view
        returns (bytes memory err, uint256 amount, uint256 push)
    {
        (address payout, bool artist) = _payoutOf(t.w, t.index);
        bool notPayout = (t.mode == 0 && artist) || t.mode == 1;
        if (notPayout && t.caller != payout) {
            err = abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, t.caller, payout);
            return (err, 0, 0);
        }
        if (t.mode == 2 && t.signer != payout) {
            err = abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, payout);
            return (err, 0, 0);
        }
        uint256 current = _observed(t.w, t.asset);
        uint256 high = modelHigh[address(t.w)][t.asset];
        if (current < high) {
            err = abi.encodeWithSelector(
                ISplitWallet.ObservedDecreased.selector, t.asset, high, current
            );
            return (err, 0, 0);
        }
        uint256 share = _payees[t.w][t.index].share;
        uint256 due = current * share / D - ghostReleased[address(t.w)][t.asset][t.index];
        amount = t.requested == type(uint256).max ? due : t.requested;
        if (amount == 0) {
            err = abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, t.asset, t.index);
            return (err, 0, 0);
        }
        if (amount > due) {
            err = abi.encodeWithSelector(ISplitWallet.AmountExceedsReleasable.selector, amount, due);
            return (err, 0, 0);
        }
        err = _transferError(t.asset, address(t.w), t.recipient, amount, 0, 0);
        if (err.length != 0) return (err, 0, 0);
        (err, push) = _expectPush(t.w, t.asset, t.index, amount, t.recipient);
        if (err.length != 0) return (err, 0, 0);
    }

    /// @dev R11: after payee `paid` of `w` was paid `amount` (to `recipient`), what the ledger
    ///      pushes to the network: its due share, zero when the network is not another payee of
    ///      `w`, is owed nothing, or the token refuses it; or the error that reverts the release.
    function _expectPush(address w, address asset, uint256 paid, uint256 amount, address recipient)
        internal
        view
        returns (bytes memory err, uint256 push)
    {
        uint256 j = _networkIndex(w);
        if (j == type(uint256).max || j == paid) return ("", 0);
        push = _observed(w, asset) * _payees[w][j].share / D - ghostReleased[w][asset][j];
        if (push == 0) return ("", 0);
        // The rebasing token after the first move: the wallet holds fewer shares, and the
        // network more when it was the first move's recipient.
        uint256 moved = asset == address(rebase) ? amount * 1e18 / rebase.index() : 0;
        err = _transferError(asset, w, network, push, moved, recipient == network ? moved : 0);
        // A token that refuses the network leaves its share due; any other failure reverts.
        if (err.length != 0 && bytes4(err) == TokenTransfer.TokenCallFailed.selector) {
            return ("", 0);
        }
        if (err.length != 0) push = 0;
    }

    function _networkIndex(address w) internal view returns (uint256) {
        for (uint256 j; j < _payees[w].length; ++j) {
            if (_payees[w][j].account == network) return j;
        }
        return type(uint256).max;
    }

    /// @dev Records a push the network received from `w`.
    function _recordPush(address w, address asset, uint256 push) internal {
        if (push == 0) {
            if (isNetworkWallet[w]) ++outcomes["push.none"];
            return;
        }
        uint256 j = _networkIndex(w);
        ghostReleased[w][asset][j] += push;
        ghostTotal[w][asset] += push;
        paidOut[asset] += push;
        ++outcomes["push.ok"];
    }

    /// @dev The token-level outcome of moving `amount` from `from` to `to` under each token's
    ///      rules. For the rebasing token, `fromLess` shares are taken from `from` and `toMore`
    ///      added to `to` first (a move earlier in the same call).
    function _transferError(
        address asset,
        address from,
        address to,
        uint256 amount,
        uint256 fromLess,
        uint256 toMore
    ) internal view returns (bytes memory) {
        if (asset == address(usdc) && (usdc.blocked(from) || usdc.blocked(to))) {
            return abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, asset, usdc.transfer.selector
            );
        }
        if (asset == address(fee) && amount * fee.feeBps() / 10_000 != 0) {
            return abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, asset);
        }
        if (asset == address(rebase)) {
            uint256 idx = rebase.index();
            uint256 shares = amount * 1e18 / idx;
            uint256 sf = rebase.sharesOf(from) - fromLess;
            uint256 st = rebase.sharesOf(to) + toMore;
            if (
                sf * idx / 1e18 - (sf - shares) * idx / 1e18 != amount
                    || (st + shares) * idx / 1e18 - st * idx / 1e18 != amount
            ) return abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, asset);
        }
        return "";
    }

    function _run(Attempt memory t) internal {
        (bytes memory expected, uint256 amount, uint256 push) = _expect(t);
        uint256 current = _observed(t.w, t.asset);
        uint256 walletBefore = _bal(t.asset, address(t.w));
        uint256 recipientBefore = _bal(t.asset, t.recipient);
        uint256 releasedBefore = ledger.totalReleased(t.w, t.asset);
        (bool ok, bytes memory ret) = _send(t);
        bytes32 kind = t.mode == 0
            ? bytes32("release")
            : t.mode == 1 ? bytes32("releaseTo") : bytes32("signed");
        if (expected.length != 0) {
            assertFalse(ok, "release should revert");
            assertEq(ret, expected, "release error");
            assertEq(ledger.totalReleased(t.w, t.asset), releasedBefore, "residue: released");
            assertEq(_bal(t.asset, address(t.w)), walletBefore, "residue: wallet");
            ++outcomes[keccak256(abi.encode(kind, bytes4(expected)))];
            return;
        }
        assertTrue(ok, "release reverted");
        assertEq(abi.decode(ret, (uint256)), amount, "release amount");
        uint256 paid = _bal(t.asset, t.recipient) - recipientBefore;
        assertEq(paid, t.recipient == network ? amount + push : amount, "recipient delta");
        assertEq(walletBefore - _bal(t.asset, address(t.w)), amount + push, "wallet delta");
        ghostReleased[address(t.w)][t.asset][t.index] += amount;
        ghostTotal[address(t.w)][t.asset] += amount;
        paidOut[t.asset] += amount;
        _recordPush(t.w, t.asset, push);
        modelHigh[address(t.w)][t.asset] = current;
        ++outcomes[keccak256(abi.encode(kind, "ok"))];
        if (t.asset == address(silent)) ++outcomes["release.noReturn"];
    }

    function _send(Attempt memory t) internal returns (bool ok, bytes memory ret) {
        if (t.mode == 0) {
            bytes memory data =
                abi.encodeCall(ISplitWallet.release, (_payees[t.w], saltOf[t.w], t.asset, t.index));
            vm.prank(t.caller);
            return address(ledger).call(data);
        }
        if (t.mode == 1) {
            bytes memory data = abi.encodeCall(
                ISplitWallet.releaseTo, (_payees[t.w], saltOf[t.w], t.asset, t.index, t.recipient)
            );
            vm.prank(t.caller);
            return address(ledger).call(data);
        }
        (IReleaseVerifier.Authorization memory a, bytes memory sig) = _signed(t);
        (ok, ret) = address(ledger)
            .call(
                abi.encodeCall(
                    ISplitLedger.releaseWithAuthorization, (_payees[t.w], saltOf[t.w], a, sig)
                )
            );
        if (ok) {
            lastAuth = a;
            lastSig = sig;
            hasLast = true;
        }
    }

    function _signed(Attempt memory t)
        internal
        returns (IReleaseVerifier.Authorization memory a, bytes memory sig)
    {
        (address payout,) = _payoutOf(t.w, t.index);
        a = IReleaseVerifier.Authorization(
            address(t.w),
            t.asset,
            t.index,
            payout,
            t.recipient,
            t.requested,
            ++nonce,
            block.timestamp + 1 days
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[t.signer], ledger.releaseDigest(a));
        sig = abi.encodePacked(r, s, v);
    }

    function _predictBatchItem(
        Attempt[] memory items,
        uint256[] memory predicted,
        uint256 k,
        bool signed
    ) internal view returns (uint256) {
        Attempt memory t = items[k];
        (address payout, bool artist) = _payoutOf(t.w, t.index);
        if (!signed && artist) return 0;
        if (signed && t.signer != payout) return 0;
        address recipient = signed ? t.recipient : payout;
        uint256 due = _observed(t.w, t.asset) * _payees[t.w][t.index].share / D
            - ghostReleased[address(t.w)][t.asset][t.index];
        for (uint256 j; j < k; ++j) {
            if (items[j].w == t.w && items[j].asset == t.asset && items[j].index == t.index) {
                due -= predicted[j];
            }
        }
        if (due == 0) return 0;
        if (t.asset == address(usdc) && (usdc.blocked(address(t.w)) || usdc.blocked(recipient))) {
            return 0;
        }
        return due;
    }

    function _submitPlain(Attempt[] memory items) internal returns (uint256[] memory) {
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](items.length);
        for (uint256 k; k < items.length; ++k) {
            claims[k] = IClaimRouter.Claim(
                _payees[items[k].w], saltOf[items[k].w], items[k].asset, items[k].index
            );
        }
        return router.claim(claims, true);
    }

    function _submitSigned(Attempt[] memory items) internal returns (uint256[] memory) {
        IClaimRouter.SignedClaim[] memory claims = new IClaimRouter.SignedClaim[](items.length);
        for (uint256 k; k < items.length; ++k) {
            (IReleaseVerifier.Authorization memory a, bytes memory sig) = _signed(items[k]);
            claims[k] = IClaimRouter.SignedClaim(a, sig, _payees[items[k].w], saltOf[items[k].w]);
        }
        return router.claimSigned(claims, true);
    }

    function _payoutOf(address w, uint256 index)
        internal
        view
        returns (address account, bool artist)
    {
        ISplitWallet.Payee memory p = _payees[w][index];
        if (p.artistId == 0) return (p.account, false);
        return (artistPayout[p.artistId], true);
    }

    function _observed(address w, address asset) internal view returns (uint256) {
        return _bal(asset, address(w)) + ghostTotal[address(w)][asset];
    }

    function _bal(address asset, address account) internal view returns (uint256) {
        return asset == ETH ? account.balance : BlocklistToken(asset).balanceOf(account);
    }

    function _actorSum(address asset) internal view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) {
            sum += _bal(asset, actors[i]);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _wallet(uint256 seed) internal view returns (address) {
        return wallets[seed % wallets.length];
    }

    function _target(uint256 seed) internal view returns (address) {
        uint256 pick = seed % (wallets.length + 2);
        if (pick == wallets.length + 1) return network;
        return pick == wallets.length ? address(toggle) : address(wallets[pick]);
    }

    /// @dev Wallets come in pairs: originals first, then their salt-1 replacements.
    function _equivalent(address wallet) internal view returns (address) {
        uint256 half = wallets.length / 2;
        for (uint256 i; i < wallets.length; ++i) {
            if (address(wallets[i]) == wallet) {
                return address(wallets[i < half ? i + half : i - half]);
            }
        }
        return address(0);
    }
}
