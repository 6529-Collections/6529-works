// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    BlocklistToken,
    MockArtistResolver,
    ToggleRecipient
} from "../../mocks/EconomicsMocks.sol";
import { PaymentHarness } from "../EconomicsBase.sol";

/// @notice Drives payments, direct receipts, releases (plain, redirected, signed and batched),
///         escrow credits and flushes, artist payout changes and USDC-style blocklisting against
///         a fixed set of wallets, and keeps ghost totals for the invariants. Every action is
///         bounded so it never reverts (`fail_on_revert` is on).
contract EconomicsHandler is Test {
    address internal constant ETH = address(0);

    SplitWallet[] public wallets;
    ToggleRecipient public toggle;
    RevenueEscrow public escrow;
    ClaimRouter public router;
    PaymentHarness public payer;
    BlocklistToken public token;
    MockArtistResolver public resolver;

    address[] public actors;
    mapping(address => uint256) internal keyOf;
    uint256[] public artistIds;

    /// @notice Everything that ever reached each wallet, per asset.
    mapping(address wallet => mapping(address asset => uint256)) public received;
    /// @notice Everything released per payee, as the handler observed it.
    mapping(address wallet => mapping(address asset => mapping(uint256 index => uint256))) public
        ghostReleased;
    /// @notice The highest recorded receipts seen per wallet and asset.
    mapping(address wallet => mapping(address asset => uint256)) public highWater;
    /// @notice Set if a wallet's recorded receipts ever went down.
    bool public observedDecreased;

    uint256 internal nonce;
    /// @notice How often each path actually moved value, to show the campaign is not vacuous.
    mapping(bytes32 => uint256) public effective;

    constructor(
        SplitWallet[] memory wallets_,
        ToggleRecipient toggle_,
        RevenueEscrow escrow_,
        ClaimRouter router_,
        PaymentHarness payer_,
        BlocklistToken token_,
        MockArtistResolver resolver_,
        uint256[] memory keys,
        uint256[] memory artistIds_
    ) {
        wallets = wallets_;
        toggle = toggle_;
        escrow = escrow_;
        router = router_;
        payer = payer_;
        token = token_;
        resolver = resolver_;
        artistIds = artistIds_;
        for (uint256 i; i < keys.length; ++i) {
            address actor = vm.addr(keys[i]);
            actors.push(actor);
            keyOf[actor] = keys[i];
        }
    }

    // ------------------------------------------------------------------ money in

    function payETH(uint256 targetSeed, uint256 amount) external checkpoint {
        address target = _target(targetSeed);
        amount = bound(amount, 1, 50 ether);
        vm.deal(address(payer), address(payer).balance + amount);
        bool escrowed = payer.payETH(target, amount, 50_000);
        ++effective[escrowed ? bytes32("payETH.escrow") : bytes32("payETH.direct")];
        if (!escrowed && target != address(toggle)) received[target][ETH] += amount;
    }

    function payToken(uint256 targetSeed, uint256 amount) external checkpoint {
        address target = _target(targetSeed);
        amount = bound(amount, 1, 1e24);
        token.mint(address(payer), amount);
        bool escrowed = payer.payERC20(target, address(token), amount);
        ++effective[escrowed ? bytes32("payToken.escrow") : bytes32("payToken.direct")];
        if (!escrowed && target != address(toggle)) received[target][address(token)] += amount;
    }

    function receiveDirect(uint256 walletSeed, uint256 amount, bool inToken) external checkpoint {
        SplitWallet w = _wallet(walletSeed);
        amount = bound(amount, 1, inToken ? 1e24 : 50 ether);
        if (inToken) {
            if (token.blocked(address(w))) return;
            token.mint(address(w), amount);
            received[address(w)][address(token)] += amount;
        } else {
            vm.deal(address(w), address(w).balance + amount);
            received[address(w)][ETH] += amount;
        }
    }

    function flush(uint256 targetSeed, bool inToken) external checkpoint {
        address target = _target(targetSeed);
        address asset = inToken ? address(token) : ETH;
        uint256 owed = escrow.owed(target, asset);
        if (owed == 0) return;
        if (inToken && token.blocked(target)) return;
        if (!inToken && target == address(toggle) && !toggle.open()) return;
        assertEq(escrow.flush(target, asset), owed);
        ++effective["flush"];
        if (target != address(toggle)) received[target][asset] += owed;
    }

    // ------------------------------------------------------------------ money out

    function release(uint256 walletSeed, uint256 payeeSeed, bool inToken) external checkpoint {
        (SplitWallet w, uint256 index, address asset, address account, uint256 due) =
            _pick(walletSeed, payeeSeed, inToken);
        if (due == 0 || !_canPay(w, asset, account)) return;
        assertEq(w.release(asset, index), due);
        ++effective["release"];
        ghostReleased[address(w)][asset][index] += due;
    }

    function releaseTo(uint256 walletSeed, uint256 payeeSeed, bool inToken, uint256 recipientSeed)
        external
        checkpoint
    {
        (SplitWallet w, uint256 index, address asset, address account, uint256 due) =
            _pick(walletSeed, payeeSeed, inToken);
        address recipient = actors[recipientSeed % actors.length];
        if (due == 0 || !_canPay(w, asset, recipient)) return;
        vm.prank(account);
        assertEq(w.releaseTo(asset, index, recipient), due);
        ++effective["releaseTo"];
        ghostReleased[address(w)][asset][index] += due;
    }

    function releaseSigned(
        uint256 walletSeed,
        uint256 payeeSeed,
        bool inToken,
        uint256 amount,
        uint256 recipientSeed
    ) external checkpoint {
        (SplitWallet w, uint256 index, address asset, address account, uint256 due) =
            _pick(walletSeed, payeeSeed, inToken);
        address recipient = actors[recipientSeed % actors.length];
        if (due == 0 || !_canPay(w, asset, recipient)) return;
        ISplitWallet.Authorization memory a = ISplitWallet.Authorization(
            asset, index, account, recipient, bound(amount, 1, due), ++nonce, block.timestamp + 1
        );
        _submitSigned(w, a);
    }

    function _submitSigned(SplitWallet w, ISplitWallet.Authorization memory a) internal {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyOf[a.account], w.releaseDigest(a));
        vm.prank(actors[a.nonce % actors.length]);
        assertEq(w.releaseWithAuthorization(a, abi.encodePacked(r, s, v)), a.amount);
        ++effective["releaseSigned"];
        ghostReleased[address(w)][a.asset][a.payee] += a.amount;
    }

    function claimBatch(uint256 seed, uint8 count) external checkpoint {
        uint256 n = bound(count, 1, 4);
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](n);
        for (uint256 i; i < n; ++i) {
            uint256 itemSeed = uint256(keccak256(abi.encode(seed, i)));
            SplitWallet w = _wallet(itemSeed);
            claims[i] = IClaimRouter.Claim(
                address(w),
                (itemSeed >> 8) % 2 == 0 ? ETH : address(token),
                (itemSeed >> 16) % w.payeeCount()
            );
        }
        uint256[] memory amounts = router.claim(claims, true);
        for (uint256 i; i < n; ++i) {
            ghostReleased[claims[i].wallet][claims[i].asset][claims[i].payee] += amounts[i];
            ++effective[amounts[i] == 0 ? bytes32("claim.failed") : bytes32("claim.paid")];
        }
    }

    // ------------------------------------------------------------------ environment

    function setArtistPayout(uint256 artistSeed, uint256 actorSeed) external checkpoint {
        resolver.set(artistIds[artistSeed % artistIds.length], actors[actorSeed % actors.length]);
    }

    function toggleBlocked(uint256 seed) external checkpoint {
        uint256 pick = seed % (wallets.length + actors.length + 1);
        address target = pick < wallets.length
            ? address(wallets[pick])
            : pick < wallets.length + actors.length
                ? actors[pick - wallets.length]
                : address(toggle);
        token.setBlocked(target, !token.blocked(target));
    }

    function toggleOpen() external checkpoint {
        toggle.setOpen(!toggle.open());
    }

    function revokeNonce(uint256 actorSeed) external checkpoint {
        vm.prank(actors[actorSeed % actors.length]);
        _wallet(actorSeed >> 8).revokeNonce(++nonce);
    }

    // ------------------------------------------------------------------ helpers

    function walletCount() external view returns (uint256) {
        return wallets.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    modifier checkpoint() {
        _;
        for (uint256 i; i < wallets.length; ++i) {
            _mark(address(wallets[i]), ETH);
            _mark(address(wallets[i]), address(token));
        }
    }

    function _mark(address w, address asset) internal {
        uint256 recorded = SplitWallet(payable(w)).recordedObserved(asset);
        if (recorded < highWater[w][asset]) observedDecreased = true;
        highWater[w][asset] = recorded;
    }

    function _target(uint256 seed) internal view returns (address) {
        uint256 pick = seed % (wallets.length + 1);
        return pick == wallets.length ? address(toggle) : address(wallets[pick]);
    }

    function _wallet(uint256 seed) internal view returns (SplitWallet) {
        return wallets[seed % wallets.length];
    }

    function _pick(uint256 walletSeed, uint256 payeeSeed, bool inToken)
        internal
        view
        returns (SplitWallet w, uint256 index, address asset, address account, uint256 due)
    {
        w = _wallet(walletSeed);
        index = payeeSeed % w.payeeCount();
        asset = inToken ? address(token) : ETH;
        account = w.payoutAddress(index);
        due = w.releasable(asset, index);
    }

    function _canPay(SplitWallet w, address asset, address recipient) internal view returns (bool) {
        return asset == ETH || (!token.blocked(address(w)) && !token.blocked(recipient));
    }
}
