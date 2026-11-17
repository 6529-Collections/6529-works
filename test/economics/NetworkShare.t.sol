// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { GovernedVault } from "src/economics/GovernedVault.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Burner, GasRuleAssertions } from "../helpers/GasRule.sol";
import { BlocklistToken, FeeOnTransferToken } from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @dev Calls a release and returns what it released and what `watched` holds afterwards, so a
///      release that skipped the network's push reads as a different answer. Bubbles reverts.
contract ReleaseProbe {
    function run(ISplitLedger ledger, bytes calldata data, address watched)
        external
        returns (uint256 amount, uint256 held)
    {
        (bool ok, bytes memory ret) = address(ledger).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return (abi.decode(ret, (uint256)), watched.balance);
    }
}

/// @notice The network's share of split wallets and escrow credits (R11, R12, C19):
///         - every release from a wallet that names the network fee vault also pays the vault
///           its due share of the same asset, by every release path; a token that refuses the
///           vault does not block the release, and no other fixed payee is pushed;
///         - a share anyone marked and its payee left unreleased for 180 days goes to the
///           network, never more than was due at the mark;
///         - an escrow credit nobody claimed for 180 days moves to the network;
///         - the network moves its own escrow credits without consent, and nobody else's.
/// @dev Each test fails without the change: before it, a release moved one payee only, the
///      ledger had no `mark`/`forfeit`, the escrow no `expire`/`creditedAt`, and `recover` needed
///      the fee vault's recorded consent.
contract NetworkShareTest is EconomicsBase, GasRuleAssertions {
    uint256 internal constant PERIOD = 180 days;
    address internal seller = makeAddr("sellerWallet");

    /// @dev A royalty wallet: the seller 75%, the network fee vault 25%.
    function _royalty() internal returns (address wallet) {
        return _wallet(_list(_fixed(seller, 75_000), _fixed(address(feeVault), 25_000)));
    }

    /// @dev Artist 60%, bob 15%, the network 25%.
    function _mixed() internal returns (address wallet) {
        return _wallet(
            _list(_artist(ARTIST, 60_000), _fixed(bob, 15_000), _fixed(address(feeVault), 25_000))
        );
    }

    // ------------------------------------------------------------------ R11

    function test_ReleaseFromARoyaltyWalletAlsoPaysTheFeeVault() public {
        address wallet = _royalty();
        vm.deal(wallet, 4 ether);
        uint256 sellerIndex = _indexOf(wallet, seller);
        uint256 feeIndex = _indexOf(wallet, address(feeVault));
        vm.expectEmit(address(ledger));
        emit ISplitWallet.Released(wallet, ETH, seller, sellerIndex, seller, 3 ether, 4 ether);
        vm.expectEmit(address(ledger));
        emit ISplitWallet.Released(
            wallet, ETH, address(feeVault), feeIndex, address(feeVault), 1 ether, 4 ether
        );
        vm.prank(alice);
        assertEq(_release(wallet, ETH, sellerIndex), 3 ether);
        assertEq(seller.balance, 3 ether);
        assertEq(address(feeVault).balance, 1 ether, "the network is paid in the same call");
        assertEq(ledger.released(wallet, ETH, feeIndex), 1 ether);
        assertEq(wallet.balance, 0);
    }

    /// @dev The claim router over a royalty wallet that pays the network: the seller's item also
    ///      pays the network its share, so a batch that leaves out the network's index pays
    ///      both; an atomic batch that also names it fails on that item (nothing left to
    ///      release), and continue mode reports it and releases zero (B L-2).
    function test_ClaimRouterWithAWalletThatPaysTheNetwork() public {
        address wallet = _royalty();
        uint256 sellerIndex = _indexOf(wallet, seller);
        uint256 feeIndex = _indexOf(wallet, address(feeVault));
        ISplitWallet.Payee[] memory payees = _payeesOf(wallet);
        IClaimRouter.Claim[] memory one = new IClaimRouter.Claim[](1);
        one[0] = IClaimRouter.Claim(payees, _salts[wallet], ETH, sellerIndex);
        vm.deal(wallet, 4 ether);
        uint256[] memory amounts = router.claim(one, false);
        assertEq(amounts[0], 3 ether);
        assertEq(address(feeVault).balance, 1 ether, "the network paid in the same item");

        vm.deal(wallet, 4 ether);
        IClaimRouter.Claim[] memory both = new IClaimRouter.Claim[](2);
        both[0] = one[0];
        both[1] = IClaimRouter.Claim(payees, _salts[wallet], ETH, feeIndex);
        vm.expectRevert();
        router.claim(both, false);
        amounts = router.claim(both, true);
        assertEq(amounts[0], 3 ether);
        assertEq(amounts[1], 0, "nothing left for the network's own item");
        assertEq(address(feeVault).balance, 2 ether);
    }

    /// @dev Every release path (the artist's pull, `releaseTo`, a signed release) pays the
    ///      network, in ETH and in a token, for any receipts; a fixed payee other than the
    ///      network is never pushed.
    function testFuzz_EveryReleasePathPaysTheNetwork(uint256 amount, uint8 path, bool inToken)
        public
    {
        amount = bound(amount, 1, 1e30);
        address wallet = _mixed();
        address asset = inToken ? address(token) : ETH;
        if (inToken) token.mint(wallet, amount);
        else vm.deal(wallet, amount);
        uint256 artistIndex = _artistIndex(wallet, ARTIST);
        uint256 feeIndex = _indexOf(wallet, address(feeVault));
        uint256 bobIndex = _indexOf(wallet, bob);
        uint256 artistDue = amount / D * 60_000 + (amount % D) * 60_000 / D;
        uint256 feeDue = amount / D * 25_000 + (amount % D) * 25_000 / D;
        address recipient = makeAddr("artistRecipient");
        path = path % 3;
        if (artistDue == 0) return;
        if (path == 0) {
            vm.prank(artistPayout);
            _release(wallet, asset, artistIndex);
            recipient = artistPayout;
        } else if (path == 1) {
            vm.prank(artistPayout);
            _releaseTo(wallet, asset, artistIndex, recipient);
        } else {
            IReleaseVerifier.Authorization memory a =
                _auth(wallet, asset, artistIndex, artistPayout, recipient, type(uint256).max, 1);
            _releaseSigned(a, _sign(artistPk, a));
        }
        assertEq(_bal(asset, recipient), artistDue, "the artist");
        assertEq(_bal(asset, address(feeVault)), feeDue, "the network");
        assertEq(ledger.released(wallet, asset, feeIndex), feeDue);
        assertEq(ledger.released(wallet, asset, bobIndex), 0, "no other fixed payee is pushed");
        assertEq(_releasable(wallet, asset, feeIndex), 0);
    }

    /// @dev A token that refuses the vault does not block the artist; the share stays due and
    ///      the next release, once the token accepts the vault again, pushes it.
    function test_ATokenRefusingTheVaultDoesNotBlockTheRelease() public {
        BlocklistToken usdc = new BlocklistToken();
        address wallet = _mixed();
        usdc.mint(wallet, 1_000);
        usdc.setBlocked(address(feeVault), true);
        uint256 artistIndex = _artistIndex(wallet, ARTIST);
        uint256 feeIndex = _indexOf(wallet, address(feeVault));
        vm.prank(artistPayout);
        assertEq(_release(wallet, address(usdc), artistIndex), 600);
        assertEq(usdc.balanceOf(address(feeVault)), 0);
        assertEq(_releasable(wallet, address(usdc), feeIndex), 250, "still due");

        usdc.setBlocked(address(feeVault), false);
        usdc.mint(wallet, 1_000);
        vm.prank(bob);
        assertEq(_release(wallet, address(usdc), _indexOf(wallet, bob)), 300);
        assertEq(usdc.balanceOf(address(feeVault)), 500, "the whole due share, then and now");
    }

    /// @dev A push whose balances come out wrong (a token taking a fee) reverts the release.
    function test_APushWithABalanceMismatchRevertsTheRelease() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        address wallet = _mixed();
        fee.mint(wallet, 1e6);
        fee.setFee(0);
        uint256 bobIndex = _indexOf(wallet, bob);
        // The first move is exact; then the token starts charging and the push is short.
        vm.prank(bob);
        _release(wallet, address(fee), bobIndex);
        fee.mint(wallet, 1e6);
        fee.setFee(100);
        vm.expectRevert();
        vm.prank(artistPayout);
        _release(wallet, address(fee), _artistIndex(wallet, ARTIST));
    }

    /// @dev Gas rule (R11's push): the network vault costing 1x to 100x more is paid the same,
    ///      and running short reverts with the shortfall error at the wallet; no gas limit makes
    ///      the release succeed without paying the network.
    function test_GasRule_ThePushToTheNetworkIsNeverSkippedForGas() public {
        address sink = makeAddr("networkSink");
        Burner net = new Burner(sink, 6_300);
        net.burnerSetMutating(true);
        SplitLedger l = new SplitLedger(resolver, address(net));
        ISplitWallet.Payee[] memory payees =
            _list(_fixed(seller, 75_000), _fixed(address(net), 25_000));
        address wallet = l.createWallet(payees, bytes32(0));
        vm.deal(wallet, 4 ether);
        uint256 sellerIndex = payees[0].account == seller ? 0 : 1;
        ReleaseProbe probe = new ReleaseProbe();
        bytes memory data = abi.encodeCall(
            ReleaseProbe.run,
            (l, abi.encodeCall(ISplitWallet.release, (payees, bytes32(0), ETH, sellerIndex)), sink)
        );
        Outcome memory first = _assertSameAtEveryMultiple(net, alice, address(probe), data);
        assertTrue(first.ok);
        (uint256 amount, uint256 held) = abi.decode(first.data, (uint256, uint256));
        assertEq(amount, 3 ether);
        assertEq(held, 1 ether, "the network is paid");

        net.burnerSetMultiple(10);
        Outcome memory full = _try(alice, address(probe), data, 0);
        assertTrue(full.ok);
        uint256 low;
        uint256 high = 30_000_000;
        while (low + 1 < high) {
            uint256 mid = (low + high) / 2;
            if (_try(alice, address(probe), data, mid).ok) high = mid;
            else low = mid;
        }
        bytes memory shortfall = _shortfall(wallet);
        uint256 shortfalls;
        for (uint256 i = 1; i <= GAS_RULE_SAMPLES; ++i) {
            uint256 g = high - (high * i * i) / (GAS_RULE_SAMPLES * GAS_RULE_SAMPLES * 8 / 7);
            if (g >= high) g = high - 1;
            Outcome memory o = _try(alice, address(probe), data, g);
            if (o.ok) {
                assertEq(o.data, full.data, "paid without the network's push");
                continue;
            }
            if (keccak256(o.data) == keccak256(shortfall)) ++shortfalls;
            else assertEq(o.data.length, 0, string.concat("a refusal at gas ", vm.toString(g)));
        }
        assertGt(shortfalls, 0, "no gas limit produced the shortfall error");
    }

    // ------------------------------------------------------------------ R12: marks

    function test_AMarkedShareUnclaimedFor180DaysGoesToTheNetwork() public {
        address wallet = _wallet(_list(_fixed(alice, 80_000), _artist(ARTIST, 20_000)));
        vm.deal(wallet, 10 ether);
        uint256 artistIndex = _artistIndex(wallet, ARTIST);
        ISplitWallet.Payee[] memory payees = _payeesOf(wallet);
        vm.expectEmit(address(ledger));
        emit ISplitLedger.Marked(wallet, ETH, artistIndex, 2 ether, block.timestamp);
        vm.prank(bob);
        ledger.mark(payees, bytes32(0), ETH, artistIndex);
        (uint256 target, uint256 at) = ledger.markOf(wallet, ETH, artistIndex);
        assertEq(target, 2 ether);
        assertEq(at, block.timestamp);

        uint256 dueAt = block.timestamp + PERIOD;
        vm.warp(dueAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISplitLedger.MarkNotDue.selector, wallet, ETH, artistIndex, dueAt
            )
        );
        ledger.forfeit(payees, bytes32(0), ETH, artistIndex);

        vm.warp(dueAt);
        vm.expectEmit(address(ledger));
        emit ISplitWallet.Released(
            wallet, ETH, address(feeVault), artistIndex, address(feeVault), 2 ether, 10 ether
        );
        vm.expectEmit(address(ledger));
        emit ISplitLedger.Forfeited(wallet, ETH, artistIndex, 2 ether);
        vm.prank(bob);
        assertEq(ledger.forfeit(payees, bytes32(0), ETH, artistIndex), 2 ether);
        assertEq(address(feeVault).balance, 2 ether);
        assertEq(_releasable(wallet, ETH, artistIndex), 0);
        (target, at) = ledger.markOf(wallet, ETH, artistIndex);
        assertEq(target + at, 0, "the mark is cleared");
        assertEq(_releasable(wallet, ETH, _indexOf(wallet, alice)), 8 ether, "alice untouched");
    }

    function test_AShareClaimedInTimeIsNotForfeited() public {
        address wallet = _wallet(_list(_fixed(alice, 80_000), _artist(ARTIST, 20_000)));
        vm.deal(wallet, 10 ether);
        uint256 artistIndex = _artistIndex(wallet, ARTIST);
        ISplitWallet.Payee[] memory payees = _payeesOf(wallet);
        ledger.mark(payees, bytes32(0), ETH, artistIndex);
        vm.warp(block.timestamp + PERIOD - 1);
        vm.prank(artistPayout);
        _release(wallet, ETH, artistIndex);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, artistIndex)
        );
        ledger.forfeit(payees, bytes32(0), ETH, artistIndex);
        assertEq(artistPayout.balance, 2 ether);
        assertEq(address(feeVault).balance, 0);
    }

    /// @dev A mark covers only what was due when it was placed: money that arrives later, and
    ///      what the payee released in part, are never forfeited.
    function testFuzz_AMarkNeverTakesLaterMoney(uint96 before, uint96 later, uint96 taken) public {
        before = uint96(bound(before, 1 ether, 1e27));
        address wallet = _wallet(_list(_fixed(alice, 50_000), _artist(ARTIST, 50_000)));
        uint256 artistIndex = _artistIndex(wallet, ARTIST);
        ISplitWallet.Payee[] memory payees = _payeesOf(wallet);
        vm.deal(wallet, before);
        uint256 marked = uint256(before) / 2;
        ledger.mark(payees, bytes32(0), ETH, artistIndex);
        vm.deal(wallet, uint256(before) + later);
        uint256 part = bound(taken, 0, marked + uint256(later) / 2);
        if (part != 0) {
            IReleaseVerifier.Authorization memory a =
                _auth(wallet, ETH, artistIndex, artistPayout, artistPayout, part, 1);
            _releaseSigned(a, _sign(artistPk, a));
        }
        vm.warp(block.timestamp + PERIOD);
        uint256 expected = part >= marked ? 0 : marked - part;
        if (expected == 0) {
            vm.expectRevert(
                abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, artistIndex)
            );
            ledger.forfeit(payees, bytes32(0), ETH, artistIndex);
        } else {
            assertEq(ledger.forfeit(payees, bytes32(0), ETH, artistIndex), expected);
        }
        assertEq(address(feeVault).balance, expected, "only the marked, unreleased rest");
        // The artist keeps everything that arrived after the mark.
        uint256 entitled = (uint256(before) + later) / 2;
        assertEq(
            artistPayout.balance + _releasable(wallet, ETH, artistIndex),
            entitled - expected,
            "the artist keeps the rest"
        );
    }

    /// @dev A running mark keeps its clock: nobody can restart it. Once the payee released past
    ///      it, anyone may place a new one.
    function test_ARunningMarkCannotBeRestarted() public {
        address wallet = _wallet(_list(_fixed(alice, 50_000), _artist(ARTIST, 50_000)));
        uint256 artistIndex = _artistIndex(wallet, ARTIST);
        ISplitWallet.Payee[] memory payees = _payeesOf(wallet);
        vm.deal(wallet, 2 ether);
        ledger.mark(payees, bytes32(0), ETH, artistIndex);
        vm.warp(block.timestamp + 100 days);
        vm.deal(wallet, 4 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitLedger.MarkPending.selector, wallet, ETH, artistIndex)
        );
        ledger.mark(payees, bytes32(0), ETH, artistIndex);
        vm.prank(artistPayout);
        _release(wallet, ETH, artistIndex);
        vm.deal(wallet, wallet.balance + 2 ether);
        ledger.mark(payees, bytes32(0), ETH, artistIndex);
        (uint256 target, uint256 at) = ledger.markOf(wallet, ETH, artistIndex);
        assertEq(target, 3 ether);
        assertEq(at, block.timestamp);
    }

    function test_MarkAndForfeitRefusals() public {
        ISplitWallet.Payee[] memory payees = _list(_fixed(alice, 50_000), _artist(ARTIST, 50_000));
        address predicted = ledger.walletFor(payees, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.WalletNotDeployed.selector, predicted));
        ledger.mark(payees, bytes32(0), ETH, 0);
        address wallet = _wallet(payees);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, 1));
        ledger.mark(payees, bytes32(0), ETH, 1);
        vm.expectRevert(abi.encodeWithSelector(ISplitLedger.MarkNotDue.selector, wallet, ETH, 1, 0));
        ledger.forfeit(payees, bytes32(0), ETH, 1);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.UnknownPayee.selector, 2));
        ledger.mark(payees, bytes32(0), ETH, 2);
    }

    /// @dev A forfeit of a payee's share also pushes the network its own share of the wallet.
    function test_AForfeitAlsoPaysTheNetworksOwnShare() public {
        address wallet = _mixed();
        vm.deal(wallet, 10 ether);
        uint256 artistIndex = _artistIndex(wallet, ARTIST);
        ISplitWallet.Payee[] memory payees = _payeesOf(wallet);
        ledger.mark(payees, bytes32(0), ETH, artistIndex);
        vm.warp(block.timestamp + PERIOD);
        assertEq(ledger.forfeit(payees, bytes32(0), ETH, artistIndex), 6 ether);
        assertEq(address(feeVault).balance, 8.5 ether, "the forfeit and the network's share");
        assertEq(_releasable(wallet, ETH, _indexOf(wallet, bob)), 1.5 ether);
    }

    // ------------------------------------------------------------------ R12: escrow

    function test_AnEscrowCreditExpiresToTheNetworkAfter180Days() public {
        vm.deal(address(this), 1 ether);
        escrow.depositETH{ value: 1 ether }(alice);
        assertEq(escrow.creditedAt(alice, ETH), block.timestamp);
        uint256 dueAt = block.timestamp + PERIOD;
        vm.warp(dueAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.CreditNotExpired.selector, alice, ETH, dueAt)
        );
        escrow.expire(alice, ETH);
        vm.warp(dueAt);
        vm.expectEmit(address(escrow));
        emit IRevenueEscrow.Expired(alice, ETH, address(feeVault), 1 ether, 1 ether);
        vm.prank(bob);
        assertEq(escrow.expire(alice, ETH), 1 ether);
        assertEq(escrow.owed(alice, ETH), 0);
        assertEq(escrow.owed(address(feeVault), ETH), 1 ether);
        assertEq(escrow.totalOwed(ETH), 1 ether, "nothing left the escrow");
        escrow.flush(address(feeVault), ETH);
        assertEq(address(feeVault).balance, 1 ether);
    }

    /// @dev Later additions, by anyone, never move a credit's clock: it expires 180 days after it
    ///      went from zero; once emptied, the next credit starts a new clock.
    function test_LaterCreditsDoNotMoveTheClock() public {
        uint256 start = block.timestamp;
        vm.deal(address(this), 1 ether);
        escrow.depositETH{ value: 1 ether }(alice);
        address other = makeAddr("depositor");
        vm.deal(other, 5);
        for (uint256 i; i < 5; ++i) {
            vm.warp(block.timestamp + 30 days);
            vm.prank(other);
            escrow.depositETH{ value: 1 }(alice);
        }
        assertEq(escrow.creditedAt(alice, ETH), start, "clock unchanged");
        vm.warp(start + PERIOD);
        vm.expectEmit(address(escrow));
        emit IRevenueEscrow.Expired(alice, ETH, address(feeVault), 1 ether + 5, 1 ether + 5);
        assertEq(escrow.expire(alice, ETH), 1 ether + 5);
        // Emptied: the next credit starts a new clock.
        vm.deal(address(this), 1);
        escrow.depositETH{ value: 1 }(alice);
        assertEq(escrow.creditedAt(alice, ETH), block.timestamp, "new clock");
    }

    function test_ExpireRefusals() public {
        vm.deal(address(this), 1 ether);
        escrow.depositETH{ value: 1 ether }(address(feeVault));
        vm.warp(block.timestamp + PERIOD);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(feeVault))
        );
        escrow.expire(address(feeVault), ETH);
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, bob, ETH));
        escrow.expire(bob, ETH);
    }

    // ------------------------------------------------------------------ C19

    function test_TheNetworkMovesItsOwnCreditWithoutConsent() public {
        vm.deal(address(this), 1 ether);
        escrow.depositETH{ value: 1 ether }(address(feeVault));
        address next = makeAddr("nextSafe");
        vm.expectEmit(address(escrow));
        emit IRevenueEscrow.Recovered(address(feeVault), next, ETH, 1 ether, 1 ether);
        escrow.recover(address(feeVault), next, ETH);
        assertEq(escrow.owed(next, ETH), 1 ether);
        assertEq(escrow.creditedAt(next, ETH), block.timestamp);
    }

    function test_TheNetworkCannotMoveAnotherAccountsCredit() public {
        // An account answering to another authority, and a plain account.
        GovernedVault foreign =
            new GovernedVault(address(new AccessManager(address(this))), makeAddr("foreignSafe"));
        vm.deal(address(this), 2 ether + 1);
        escrow.depositETH{ value: 1 ether }(address(foreign));
        escrow.depositETH{ value: 1 ether }(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.RecoveryNotConsented.selector, address(foreign), bob
            )
        );
        escrow.recover(address(foreign), bob, ETH);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.RecoveryNotConsented.selector, alice, bob)
        );
        escrow.recover(alice, bob, ETH);
        // The network's own credit still cannot go to zero, the escrow or itself.
        escrow.depositETH{ value: 1 }(address(feeVault));
        address[3] memory bad = [address(0), address(escrow), address(feeVault)];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, bad[i]));
            escrow.recover(address(feeVault), bad[i], ETH);
        }
    }

    function test_TheLedgerNamesTheNetwork() public view {
        assertEq(ledger.network(), address(feeVault));
        assertEq(ledger.UNCLAIMED_PERIOD(), PERIOD);
        assertEq(escrow.UNCLAIMED_PERIOD(), PERIOD);
    }

    function _bal(address asset, address account) internal view returns (uint256) {
        return asset == ETH ? account.balance : token.balanceOf(account);
    }
}
