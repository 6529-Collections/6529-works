// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { ReleaseVerifier } from "src/economics/ReleaseVerifier.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    BlocklistToken,
    FeeOnTransferToken,
    MockArtistResolver,
    RebasingToken,
    ToggleRecipient
} from "../../mocks/EconomicsMocks.sol";
import { PaymentHarness } from "../EconomicsBase.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";

/// @notice Drives the economics contracts with valid and invalid actions against an independent
///         model. Every action is attempted: the model predicts success (and the exact amount) or
///         the exact revert, from its own ghost state (payouts, measured releases, the receipts
///         high-water mark and each token's rules), never from `releasable`. Released amounts are
///         recorded from measured balance deltas. Assets: ETH, a USDC-style blocklist token, a
///         fee-on-transfer token whose fee is toggled, and a rebasing token whose index moves.
///         `fail_on_revert` is on, so any unpredicted revert or mismatch fails the campaign.
contract EconomicsHandler is Test {
    address internal constant ETH = address(0);
    uint256 internal constant D = 100_000;

    struct Setup {
        SplitWallet[] wallets;
        ToggleRecipient toggle;
        RevenueEscrow escrow;
        ClaimRouter router;
        PaymentHarness payer;
        ReleaseVerifier verifier;
        BlocklistToken usdc;
        FeeOnTransferToken fee;
        RebasingToken rebase;
        MockArtistResolver resolver;
        uint256[] keys;
        uint256[] artistIds;
    }

    /// @dev One release attempt. Mode 0: `release`; 1: `releaseTo`; 2: signed.
    struct Attempt {
        SplitWallet w;
        uint256 index;
        address asset;
        address caller;
        address recipient;
        uint256 requested;
        uint8 mode;
        address signer;
    }

    SplitWallet[] public wallets;
    ToggleRecipient public toggle;
    RevenueEscrow public escrow;
    ClaimRouter public router;
    PaymentHarness public payer;
    ReleaseVerifier public verifier;
    BlocklistToken public usdc;
    FeeOnTransferToken public fee;
    RebasingToken public rebase;
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
    /// @notice Tokens left with the payer by payments the model expected to revert.
    mapping(address asset => uint256) public payerResidue;
    /// @notice How often each outcome occurred, to show the campaign is not vacuous.
    mapping(bytes32 => uint256) public outcomes;
    /// @notice The replacement the non-wallet target (`toggle`) consented to, or zero (MONEY-2).
    address public toggleConsent;

    uint256 internal nonce;
    IReleaseVerifier.Authorization internal lastAuth;
    bytes internal lastSig;
    bool internal hasLast;

    constructor(Setup memory s) {
        wallets = s.wallets;
        toggle = s.toggle;
        escrow = s.escrow;
        router = s.router;
        payer = s.payer;
        verifier = s.verifier;
        usdc = s.usdc;
        fee = s.fee;
        rebase = s.rebase;
        resolver = s.resolver;
        artistIds = s.artistIds;
        assets.push(ETH);
        assets.push(address(s.usdc));
        assets.push(address(s.fee));
        assets.push(address(s.rebase));
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
        Attempt memory t = _attemptFor(walletSeed, payeeSeed, assets[assetSeed % 4], 0);
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
        Attempt memory t = _attemptFor(walletSeed, payeeSeed, assets[assetSeed % 4], 1);
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
        Attempt memory t = _attemptFor(walletSeed, payeeSeed, assets[assetSeed % 4], 2);
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
        SplitWallet w = SplitWallet(payable(a.wallet));
        (address payout,) = _payoutOf(w, a.payee);
        bytes memory expected = a.account != payout
            ? abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, a.account, payout)
            : abi.encodeWithSelector(IReleaseVerifier.NonceAlreadyUsed.selector, a.account, a.nonce);
        (bool ok, bytes memory ret) =
            address(w).call(abi.encodeCall(ISplitWallet.releaseWithAuthorization, (a, lastSig)));
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

    function pay(uint256 targetSeed, uint256 assetSeed, uint256 amount) external {
        address target = _target(targetSeed);
        address asset = assets[assetSeed % 3];
        amount = amount % 7 == 0 ? 0 : bound(amount, 1, asset == ETH ? 50 ether : 1e24);
        bool expectEscrow;
        bytes memory expected;
        if (amount != 0) {
            if (asset == ETH) {
                expectEscrow = target == address(toggle) && !toggle.open();
            } else if (asset == address(usdc)) {
                expectEscrow = usdc.blocked(target);
            } else if (amount * fee.feeBps() / 10_000 != 0) {
                expected =
                    abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, asset);
            }
        }
        if (asset == ETH) vm.deal(address(payer), address(payer).balance + amount);
        else BlocklistToken(asset).mint(address(payer), amount);
        (bool ok, bytes memory ret) = address(payer)
            .call(
                asset == ETH
                    ? abi.encodeCall(PaymentHarness.payETH, (target, amount, 50_000))
                    : abi.encodeCall(PaymentHarness.payERC20, (target, asset, amount))
            );
        if (expected.length != 0) {
            assertFalse(ok, "payment should revert");
            assertEq(ret, expected, "payment error");
            payerResidue[asset] += amount;
            ++outcomes["pay.reverted"];
            return;
        }
        assertTrue(ok, "payment reverted");
        assertEq(abi.decode(ret, (bool)), expectEscrow, "payment route");
        if (amount == 0) return;
        if (expectEscrow) {
            ghostOwed[target][asset] += amount;
            ++outcomes["pay.escrow"];
        } else {
            if (target != address(toggle)) received[target][asset] += amount;
            ++outcomes["pay.direct"];
        }
    }

    function receiveDirect(uint256 walletSeed, uint256 assetSeed, uint256 amount) external {
        SplitWallet w = _wallet(walletSeed);
        address asset = assets[assetSeed % 4];
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
        ghostOwed[target][asset] += amount;
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
        if (target != address(toggle)) received[target][asset] += owed;
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
    ///         its equivalent replacement (same payees, another salt); the non-wallet target's
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
        } else if (to == address(toggle) || to == from || _equivalent(from) != to) {
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
        ghostOwed[to][asset] += ghostOwed[from][asset];
        ghostOwed[from][asset] = 0;
        if (from == address(toggle)) {
            toggleConsent = address(0); // single use
            assertEq(escrow.recoveryConsent(from), address(0));
        }
        ++outcomes[from == address(toggle) ? bytes32("recover.consented") : bytes32("recover.ok")];
    }

    // ------------------------------------------------------------------ environment

    function setArtistPayout(uint256 artistSeed, uint256 actorSeed) external {
        uint256 artistId = artistIds[artistSeed % artistIds.length];
        address account = _actor(actorSeed);
        resolver.set(artistId, account);
        artistPayout[artistId] = account;
    }

    function toggleBlocked(uint256 seed) external {
        uint256 pick = seed % (wallets.length + actors.length + 1);
        address target = pick < wallets.length
            ? address(wallets[pick])
            : pick < wallets.length + actors.length
                ? actors[pick - wallets.length]
                : address(toggle);
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
        verifier.revokeNonce(++nonce);
    }

    // ------------------------------------------------------------------ views for the invariants

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
        t.index = payeeSeed % t.w.payeeCount();
        t.asset = asset;
        (address payout,) = _payoutOf(t.w, t.index);
        t.caller = payout;
        t.recipient = payout;
        t.requested = type(uint256).max;
        t.mode = mode;
        t.signer = payout;
    }

    /// @dev Predicts an attempt: the exact revert data, or empty and the amount it pays.
    function _expect(Attempt memory t) internal view returns (bytes memory err, uint256 amount) {
        (address payout, bool artist) = _payoutOf(t.w, t.index);
        bool notPayout = (t.mode == 0 && artist) || t.mode == 1;
        if (notPayout && t.caller != payout) {
            err = abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, t.caller, payout);
            return (err, 0);
        }
        if (t.mode == 2 && t.signer != payout) {
            err = abi.encodeWithSelector(SignatureVerifier.InvalidSignature.selector, payout);
            return (err, 0);
        }
        uint256 current = _observed(t.w, t.asset);
        uint256 high = modelHigh[address(t.w)][t.asset];
        if (current < high) {
            err = abi.encodeWithSelector(
                ISplitWallet.ObservedDecreased.selector, t.asset, high, current
            );
            return (err, 0);
        }
        uint256 share = t.w.payee(t.index).share;
        uint256 due = current * share / D - ghostReleased[address(t.w)][t.asset][t.index];
        amount = t.requested == type(uint256).max ? due : t.requested;
        if (amount == 0) {
            err = abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, t.asset, t.index);
            return (err, 0);
        }
        if (amount > due) {
            err = abi.encodeWithSelector(ISplitWallet.AmountExceedsReleasable.selector, amount, due);
            return (err, 0);
        }
        err = _transferError(t.asset, address(t.w), t.recipient, amount);
        if (err.length != 0) amount = 0;
    }

    /// @dev The token-level outcome of moving `amount` from `from` to `to` under each token's rules.
    function _transferError(address asset, address from, address to, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
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
            uint256 sf = rebase.sharesOf(from);
            uint256 st = rebase.sharesOf(to);
            if (
                sf * idx / 1e18 - (sf - shares) * idx / 1e18 != amount
                    || (st + shares) * idx / 1e18 - st * idx / 1e18 != amount
            ) return abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, asset);
        }
        return "";
    }

    function _run(Attempt memory t) internal {
        (bytes memory expected, uint256 amount) = _expect(t);
        uint256 current = _observed(t.w, t.asset);
        uint256 walletBefore = _bal(t.asset, address(t.w));
        uint256 recipientBefore = _bal(t.asset, t.recipient);
        uint256 releasedBefore = t.w.totalReleased(t.asset);
        (bool ok, bytes memory ret) = _send(t);
        bytes32 kind = t.mode == 0
            ? bytes32("release")
            : t.mode == 1 ? bytes32("releaseTo") : bytes32("signed");
        if (expected.length != 0) {
            assertFalse(ok, "release should revert");
            assertEq(ret, expected, "release error");
            assertEq(t.w.totalReleased(t.asset), releasedBefore, "residue: released");
            assertEq(_bal(t.asset, address(t.w)), walletBefore, "residue: wallet");
            ++outcomes[keccak256(abi.encode(kind, bytes4(expected)))];
            return;
        }
        assertTrue(ok, "release reverted");
        assertEq(abi.decode(ret, (uint256)), amount, "release amount");
        uint256 paid = _bal(t.asset, t.recipient) - recipientBefore;
        assertEq(paid, amount, "recipient delta");
        assertEq(walletBefore - _bal(t.asset, address(t.w)), amount, "wallet delta");
        ghostReleased[address(t.w)][t.asset][t.index] += paid;
        ghostTotal[address(t.w)][t.asset] += paid;
        paidOut[t.asset] += paid;
        modelHigh[address(t.w)][t.asset] = current;
        ++outcomes[keccak256(abi.encode(kind, "ok"))];
    }

    function _send(Attempt memory t) internal returns (bool ok, bytes memory ret) {
        if (t.mode == 0) {
            vm.prank(t.caller);
            return address(t.w).call(abi.encodeCall(ISplitWallet.release, (t.asset, t.index)));
        }
        if (t.mode == 1) {
            vm.prank(t.caller);
            return address(t.w)
                .call(abi.encodeCall(ISplitWallet.releaseTo, (t.asset, t.index, t.recipient)));
        }
        (IReleaseVerifier.Authorization memory a, bytes memory sig) = _signed(t);
        (ok, ret) =
            address(t.w).call(abi.encodeCall(ISplitWallet.releaseWithAuthorization, (a, sig)));
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[t.signer], verifier.releaseDigest(a));
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
        uint256 due = _observed(t.w, t.asset) * t.w.payee(t.index).share / D
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
            claims[k] = IClaimRouter.Claim(address(items[k].w), items[k].asset, items[k].index);
        }
        return router.claim(claims, true);
    }

    function _submitSigned(Attempt[] memory items) internal returns (uint256[] memory) {
        IClaimRouter.SignedClaim[] memory claims = new IClaimRouter.SignedClaim[](items.length);
        for (uint256 k; k < items.length; ++k) {
            (IReleaseVerifier.Authorization memory a, bytes memory sig) = _signed(items[k]);
            claims[k] = IClaimRouter.SignedClaim(a, sig);
        }
        return router.claimSigned(claims, true);
    }

    function _payoutOf(SplitWallet w, uint256 index)
        internal
        view
        returns (address account, bool artist)
    {
        ISplitWallet.Payee memory p = w.payee(index);
        if (p.artistId == 0) return (p.account, false);
        return (artistPayout[p.artistId], true);
    }

    function _observed(SplitWallet w, address asset) internal view returns (uint256) {
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

    function _wallet(uint256 seed) internal view returns (SplitWallet) {
        return wallets[seed % wallets.length];
    }

    function _target(uint256 seed) internal view returns (address) {
        uint256 pick = seed % (wallets.length + 1);
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
