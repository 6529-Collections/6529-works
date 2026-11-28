// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    BlocklistToken,
    CallbackToken,
    ForceSender,
    Mock1271Account,
    RebasingToken,
    RejectingRecipient,
    ReentrantRecipient
} from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

contract SplitWalletTest is EconomicsBase {
    address internal wallet;
    uint256 internal iAlice;
    uint256 internal iBob;
    uint256 internal iArtist;

    function setUp() public override {
        super.setUp();
        wallet = _trio();
        iAlice = _indexOf(wallet, alice);
        iBob = _indexOf(wallet, bob);
        iArtist = _artistIndex(wallet, ARTIST);
    }

    function test_ReceiveAcceptsETHFromAnyone() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok,) = address(wallet).call{ value: 1 ether }("");
        assertTrue(ok);
        assertEq(ledger.observed(wallet, ETH), 1 ether);
    }

    function test_ReleasesETHByShareToEachPayoutAddress() public {
        vm.deal(address(wallet), 10 ether);
        assertEq(_releasable(wallet, ETH, iAlice), 5 ether);
        assertEq(_releasable(wallet, ETH, iBob), 3 ether);
        assertEq(_releasable(wallet, ETH, iArtist), 2 ether);

        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISplitWallet.Released(wallet, ETH, alice, iAlice, alice, 5 ether, 10 ether);
        assertEq(_release(wallet, ETH, iAlice), 5 ether);
        assertEq(_release(wallet, ETH, iBob), 3 ether);
        vm.prank(artistPayout);
        assertEq(_release(wallet, ETH, iArtist), 2 ether);

        assertEq(alice.balance, 5 ether);
        assertEq(bob.balance, 3 ether);
        assertEq(artistPayout.balance, 2 ether);
        assertEq(address(wallet).balance, 0);
        assertEq(ledger.totalReleased(wallet, ETH), 10 ether);
        assertEq(ledger.released(wallet, ETH, iArtist), 2 ether);
        assertEq(ledger.recordedObserved(wallet, ETH), 0, "ETH keeps no high-water mark");
        assertEq(ledger.observed(wallet, ETH), 10 ether);
    }

    /// @dev ETH receipts never fall: a release counts what it sends as released before sending,
    ///      and nothing else takes ETH out (forced ETH only adds). So releases need no recorded
    ///      mark for ETH, and a first ETH release writes the payee's and the wallet's totals only.
    function test_ETHReceiptsNeverFallAndNeedNoMark() public {
        vm.deal(address(wallet), 10 ether);
        uint256 before = ledger.observed(wallet, ETH);
        assertEq(_release(wallet, ETH, iAlice), 5 ether);
        assertGe(ledger.observed(wallet, ETH), before);
        new ForceSender{ value: 1 ether }(payable(address(wallet)));
        assertEq(ledger.observed(wallet, ETH), 11 ether);
        assertEq(_release(wallet, ETH, iBob), 3.3 ether);
        vm.prank(artistPayout);
        assertEq(_release(wallet, ETH, iArtist), 2.2 ether);
        assertEq(_release(wallet, ETH, iAlice), 0.5 ether);
        assertEq(ledger.observed(wallet, ETH), 11 ether);
        assertEq(address(wallet).balance, 0);
        assertEq(ledger.recordedObserved(wallet, ETH), 0);
    }

    /// @dev Ported from the review: force-sent ETH (no receive hook) is split like any receipt
    ///      and never freezes the asset.
    function test_ForceSentETHIsSplitAndNeverFreezes() public {
        vm.deal(address(wallet), 1 ether);
        assertEq(_release(wallet, ETH, iAlice), 0.5 ether);
        new ForceSender{ value: 1 ether }(payable(address(wallet)));
        assertEq(_release(wallet, ETH, iAlice), 0.5 ether);
        assertEq(_release(wallet, ETH, iBob), 0.6 ether);
        vm.prank(artistPayout);
        assertEq(_release(wallet, ETH, iArtist), 0.4 ether);
        assertEq(address(wallet).balance, 0);
    }

    function test_ReleaseIsCumulativeAcrossReceiptRounds() public {
        vm.deal(address(wallet), 1 ether);
        _release(wallet, ETH, iAlice);
        vm.deal(address(wallet), address(wallet).balance + 3 ether);
        assertEq(_release(wallet, ETH, iAlice), 1.5 ether);
        assertEq(_release(wallet, ETH, iBob), 1.2 ether);
        assertEq(alice.balance, 2 ether);
        assertEq(ledger.observed(wallet, ETH), 4 ether);
        assertEq(_releasable(wallet, ETH, iArtist), 0.8 ether);
    }

    function test_ReleasesERC20ByExactShares() public {
        token.mint(address(wallet), 1000);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISplitWallet.Released(wallet, address(token), bob, iBob, bob, 300, 1000);
        assertEq(_release(wallet, address(token), iBob), 300);
        vm.prank(artistPayout);
        assertEq(_release(wallet, address(token), iArtist), 200);
        assertEq(token.balanceOf(bob), 300);
        assertEq(token.balanceOf(artistPayout), 200);
        assertEq(token.balanceOf(address(wallet)), 500);
        assertEq(ledger.observed(wallet, address(token)), 1000);
    }

    function test_AnyoneMayReleaseAFixedPayeeButOnlyToItsAccount() public {
        vm.deal(address(wallet), 1 ether);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        _release(wallet, ETH, iBob);
        assertEq(bob.balance, 0.3 ether);
        assertEq(stranger.balance, 0);
    }

    function test_ArtistPayeeFollowsResolverAtReleaseTime() public {
        vm.deal(address(wallet), 10 ether);
        address recovered = makeAddr("recovered");
        resolver.set(ARTIST, recovered);
        assertEq(_payoutAddress(wallet, iArtist), recovered);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit ISplitWallet.Released(wallet, ETH, recovered, iArtist, recovered, 2 ether, 10 ether);
        vm.prank(recovered);
        _release(wallet, ETH, iArtist);
        assertEq(recovered.balance, 2 ether);
        assertEq(artistPayout.balance, 0);
    }

    function test_ArtistPayeeIsPullOnly() public {
        vm.deal(address(wallet), 10 ether);
        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, stranger, artistPayout)
        );
        vm.prank(stranger);
        _release(wallet, ETH, iArtist);
        vm.prank(artistPayout);
        assertEq(_release(wallet, ETH, iArtist), 2 ether);
    }

    /// @dev Regression for review H-1, ported from `test_PoC_F1_AnyonePushesAccruedArtistBalance
    ///      ToLostKey` and inverted: before the fix, anyone (a griefer or a keeper batch) could
    ///      push an artist's accrued balance to a lost payout key ahead of recovery.
    function test_LostArtistKeyCannotBePushedBeforeRecovery() public {
        vm.deal(address(wallet), 10 ether);
        token.mint(address(wallet), 1000);
        address griefer = makeAddr("griefer");
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](2);
        claims[0] = IClaimRouter.Claim(_payeesOf(wallet), bytes32(0), ETH, iArtist);
        claims[1] = IClaimRouter.Claim(_payeesOf(wallet), bytes32(0), address(token), iArtist);

        bytes memory reason = abi.encodeWithSelector(
            ISplitWallet.NotPayoutAddress.selector, address(router), artistPayout
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 0, address(wallet), reason.length, reason
            )
        );
        vm.prank(griefer);
        router.claim(claims, false);
        vm.prank(griefer);
        uint256[] memory amounts = router.claim(claims, true);
        assertEq(amounts[0] + amounts[1], 0);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, griefer, artistPayout)
        );
        vm.prank(griefer);
        _release(wallet, ETH, iArtist);
        assertEq(artistPayout.balance, 0, "nothing pushed to the lost key");
        assertEq(token.balanceOf(artistPayout), 0, "no tokens pushed to the lost key");

        // Recovery completes in the registry: the recovered address pulls everything accrued.
        address recovered = makeAddr("recovered");
        resolver.set(ARTIST, recovered);
        vm.startPrank(recovered);
        assertEq(_release(wallet, ETH, iArtist), 2 ether);
        assertEq(_release(wallet, address(token), iArtist), 200);
        vm.stopPrank();
        assertEq(recovered.balance, 2 ether);
        assertEq(token.balanceOf(recovered), 200);
    }

    function test_ArtistSmartAccountPullsDirectlyOrBySignature() public {
        Mock1271Account safe = new Mock1271Account();
        resolver.set(ARTIST, address(safe));
        vm.deal(address(wallet), 10 ether);
        safe.execute(
            address(ledger),
            abi.encodeCall(ISplitWallet.release, (_payeesOf(wallet), bytes32(0), ETH, iArtist))
        );
        assertEq(address(safe).balance, 2 ether);

        vm.deal(address(wallet), address(wallet).balance + 10 ether);
        address relayer = makeAddr("relayer");
        IReleaseVerifier.Authorization memory a =
            _auth(wallet, ETH, iArtist, address(safe), relayer, 1 ether, 1);
        safe.accept(verifier.releaseDigest(a));
        vm.prank(relayer);
        assertEq(_releaseSigned(a, ""), 1 ether);
        assertEq(relayer.balance, 1 ether);
    }

    /// @dev Documents the H-1 consequence: a split wallet cannot pull, so it cannot serve as an
    ///      artist's payout address. Nest it as a fixed payee instead, which anyone may push to.
    function test_NestedWalletCannotBeAnArtistPayoutAddress() public {
        address nested = _solo(bob);
        resolver.set(ARTIST, address(nested));
        vm.deal(address(wallet), 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, bob, address(nested))
        );
        vm.prank(bob);
        _release(wallet, ETH, iArtist);

        address outer = _wallet(_list(_fixed(address(nested), 40_000), _fixed(alice, 60_000)));
        vm.deal(address(outer), 1 ether);
        _release(outer, ETH, _indexOf(outer, address(nested)));
        _release(nested, ETH, 0);
        assertEq(bob.balance, 0.4 ether);
    }

    /// @dev No code-hash pin: the resolver is read as it answers now. A pin protected nothing
    ///      after EIP-6780 and would have frozen every artist share if code-hash semantics ever
    ///      changed; the old wallet reverted here with `DependencyCodeChanged`.
    function test_ResolverCodeChangeDoesNotFreezeArtistPayees() public {
        vm.deal(address(wallet), 10 ether);
        vm.etch(address(resolver), address(new AnsweringResolver()).code);
        assertEq(_payoutAddress(wallet, iArtist), artistPayout);
        vm.prank(artistPayout);
        assertEq(_release(wallet, ETH, iArtist), 2 ether);
        assertEq(_release(wallet, ETH, iAlice), 5 ether);
    }

    function test_UnresolvedOrFailingResolverBlocksOnlyTheArtistPayee() public {
        vm.deal(address(wallet), 1 ether);
        resolver.set(ARTIST, address(0));
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, ARTIST));
        _release(wallet, ETH, iArtist);
        // A resolver that refuses (here with gas to spare) leaves the payee unresolved.
        resolver.setDown(true);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, ARTIST));
        _release(wallet, ETH, iArtist);
        _release(wallet, ETH, iAlice);
        assertEq(alice.balance, 0.5 ether);
    }

    function test_ReleaseToRequiresTheCurrentPayoutAddress() public {
        vm.deal(address(wallet), 1 ether);
        address elsewhere = makeAddr("elsewhere");
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, bob, alice));
        vm.prank(bob);
        _releaseTo(wallet, ETH, iAlice, elsewhere);

        vm.prank(alice);
        assertEq(_releaseTo(wallet, ETH, iAlice, elsewhere), 0.5 ether);
        assertEq(elsewhere.balance, 0.5 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, alice, artistPayout)
        );
        vm.prank(alice);
        _releaseTo(wallet, ETH, iArtist, alice);
        vm.prank(artistPayout);
        _releaseTo(wallet, ETH, iArtist, elsewhere);
        assertEq(elsewhere.balance, 0.7 ether);
    }

    function test_RejectsZeroAndSelfRecipients() public {
        vm.deal(address(wallet), 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidRecipient.selector, address(0)));
        _releaseTo(wallet, ETH, iAlice, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.InvalidRecipient.selector, address(wallet))
        );
        _releaseTo(wallet, ETH, iAlice, address(wallet));
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.InvalidRecipient.selector, address(ledger))
        );
        _releaseTo(wallet, ETH, iAlice, address(ledger));
        vm.stopPrank();
        assertEq(ledger.totalReleased(wallet, ETH), 0);
    }

    function test_ResolverPointingAtTheWalletCannotInflateReceipts() public {
        vm.deal(address(wallet), 1 ether);
        resolver.set(ARTIST, address(wallet));
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.InvalidRecipient.selector, address(wallet))
        );
        vm.prank(address(wallet));
        _release(wallet, ETH, iArtist);
    }

    function test_NothingToReleaseAndUnknownPayeeRevert() public {
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, iAlice));
        _release(wallet, ETH, iAlice);
        vm.deal(address(wallet), 1 ether);
        _release(wallet, ETH, iAlice);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, iAlice));
        _release(wallet, ETH, iAlice);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.UnknownPayee.selector, 3));
        _release(wallet, ETH, 3);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.UnknownPayee.selector, 9));
        _releasable(wallet, ETH, 9);
    }

    function test_NeverAdmittedAssetsStayWithdrawable() public {
        token.mint(address(wallet), 100);
        assertEq(_release(wallet, address(token), iAlice), 50);
        vm.deal(address(wallet), 1 ether);
        assertEq(_release(wallet, ETH, iAlice), 0.5 ether);
        CallbackToken unlisted = new CallbackToken();
        unlisted.mint(address(wallet), 10);
        assertEq(_release(wallet, address(unlisted), iBob), 3);
    }

    function test_RoundingDustStaysBelowPayeeCount() public {
        address thirds = _wallet(
            _list(_fixed(alice, 33_333), _fixed(bob, 33_333), _fixed(artistPayout, 33_334))
        );
        vm.deal(address(thirds), 10);
        for (uint256 i; i < 3; ++i) {
            _release(thirds, ETH, i);
        }
        assertEq(address(thirds).balance, 1);
        for (uint256 i; i < 3; ++i) {
            assertEq(_releasable(thirds, ETH, i), 0);
        }
        // The dust is not lost: entitlements are cumulative, so it never exceeds two units.
        vm.deal(address(thirds), address(thirds).balance + 20);
        uint256 due =
            _releasable(thirds, ETH, 0) + _releasable(thirds, ETH, 1) + _releasable(thirds, ETH, 2);
        assertLe(address(thirds).balance - due, 2);
        assertEq(due, 19);
    }

    function test_ShrinkingBalanceFailsClosedUntilRecovered() public {
        RebasingToken rebasing = new RebasingToken();
        rebasing.mint(address(wallet), 1000);
        _release(wallet, address(rebasing), iAlice);
        assertEq(ledger.recordedObserved(wallet, address(rebasing)), 1000);
        rebasing.setIndex(0.5e18);
        bytes memory frozen = abi.encodeWithSelector(
            ISplitWallet.ObservedDecreased.selector, address(rebasing), 1000, 750
        );
        // The read fails closed too: a frozen balance never reads as "nothing owed".
        vm.expectRevert(frozen);
        _releasable(wallet, address(rebasing), iBob);
        vm.expectRevert(frozen);
        _release(wallet, address(rebasing), iBob);
        rebasing.setIndex(1e18);
        assertEq(_release(wallet, address(rebasing), iBob), 300);
    }

    function test_RejectedETHRollsBackAndPayeeCanRedirect() public {
        ReentrantRecipient payeeContract = new ReentrantRecipient();
        RejectingRecipient rejecting = new RejectingRecipient();
        address w = _solo(address(rejecting));
        vm.deal(address(w), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISplitWallet.ETHTransferFailed.selector, address(rejecting), 1 ether
            )
        );
        _release(w, ETH, 0);
        assertEq(ledger.totalReleased(w, ETH), 0);
        assertEq(ledger.recordedObserved(w, ETH), 0);

        address w2 = _solo(address(payeeContract));
        vm.deal(address(w2), 1 ether);
        payeeContract.execute(
            address(ledger),
            abi.encodeCall(ISplitWallet.releaseTo, (_payeesOf(w2), bytes32(0), ETH, 0, alice))
        );
        assertEq(alice.balance, 1 ether);
    }

    function test_BlocklistedRecipientRollsBackAndPayeeCanRedirect() public {
        BlocklistToken usdc = new BlocklistToken();
        usdc.mint(address(wallet), 100);
        usdc.setBlocked(alice, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, address(usdc), usdc.transfer.selector
            )
        );
        _release(wallet, address(usdc), iAlice);
        assertEq(ledger.totalReleased(wallet, address(usdc)), 0);
        vm.prank(alice);
        _releaseTo(wallet, address(usdc), iAlice, bob);
        assertEq(usdc.balanceOf(bob), 50);
    }

    function test_ReentryDuringETHReleaseIsBlocked() public {
        ReentrantRecipient hostile = new ReentrantRecipient();
        address w = _wallet(_list(_fixed(address(hostile), 50_000), _fixed(alice, 50_000)));
        uint256 iHostile = _indexOf(w, address(hostile));
        uint256 iOther = _indexOf(w, alice);
        hostile.configure(
            address(ledger),
            abi.encodeCall(ISplitWallet.release, (_payeesOf(w), bytes32(0), ETH, iOther))
        );
        vm.deal(address(w), 2 ether);
        _release(w, ETH, iHostile);
        assertFalse(hostile.lastOk());
        assertEq(
            hostile.lastResult(),
            abi.encodeWithSelector(ISplitWallet.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(address(hostile).balance, 1 ether);
        assertEq(_releasable(w, ETH, iOther), 1 ether);
    }

    function test_ReentryThroughReleaseToIsBlocked() public {
        ReentrantRecipient hostile = new ReentrantRecipient();
        address w = _wallet(_list(_fixed(address(hostile), 50_000), _fixed(alice, 50_000)));
        uint256 iHostile = _indexOf(w, address(hostile));
        hostile.configure(
            address(ledger),
            abi.encodeCall(
                ISplitWallet.releaseTo, (_payeesOf(w), bytes32(0), ETH, iHostile, address(hostile))
            )
        );
        vm.deal(address(w), 2 ether);
        _release(w, ETH, iHostile);
        assertFalse(hostile.lastOk());
        assertEq(
            hostile.lastResult(),
            abi.encodeWithSelector(ISplitWallet.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(address(hostile).balance, 1 ether);
    }

    /// @dev A signed release holds the wallet's lock too: its recipient cannot re-enter.
    function test_ReentryDuringASignedReleaseIsBlocked() public {
        ReentrantRecipient hostile = new ReentrantRecipient();
        address w = _wallet(_list(_fixed(alice, 50_000), _fixed(bob, 50_000)));
        uint256 iA = _indexOf(w, alice);
        uint256 iB = _indexOf(w, bob);
        hostile.configure(
            address(ledger),
            abi.encodeCall(ISplitWallet.release, (_payeesOf(w), bytes32(0), ETH, iB))
        );
        vm.deal(w, 2 ether);
        IReleaseVerifier.Authorization memory a =
            _auth(w, ETH, iA, alice, address(hostile), type(uint256).max, 1);
        assertEq(_releaseSigned(a, _sign(alicePk, a)), 1 ether);
        assertTrue(hostile.entered());
        assertFalse(hostile.lastOk());
        assertEq(
            hostile.lastResult(),
            abi.encodeWithSelector(ISplitWallet.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(bob.balance, 0);
        assertEq(_releasable(w, ETH, iB), 1 ether);
    }

    /// @dev Nobody can mark a share of a wallet while one of its releases is in progress.
    function test_MarkDuringReleaseIsBlocked() public {
        ReentrantRecipient hostile = new ReentrantRecipient();
        address w = _wallet(_list(_fixed(address(hostile), 50_000), _fixed(alice, 50_000)));
        uint256 iOther = _indexOf(w, alice);
        hostile.configure(
            address(ledger), abi.encodeCall(ledger.mark, (_payeesOf(w), bytes32(0), ETH, iOther))
        );
        vm.deal(w, 2 ether);
        _release(w, ETH, _indexOf(w, address(hostile)));
        assertFalse(hostile.lastOk());
        assertEq(
            hostile.lastResult(),
            abi.encodeWithSelector(ISplitWallet.ReentrancyGuardReentrantCall.selector)
        );
        (uint256 target, uint256 at) = ledger.markOf(w, ETH, iOther);
        assertEq(target + at, 0, "no mark");
    }

    /// @dev `observed` reverts mid-release, as `releasable` does.
    function test_ObservedRevertsDuringRelease() public {
        ReentrantRecipient hostile = new ReentrantRecipient();
        address w = _solo(address(hostile));
        hostile.configure(address(ledger), abi.encodeCall(ISplitWallet.observed, (w, ETH)));
        vm.deal(w, 1 ether);
        _release(w, ETH, 0);
        assertFalse(hostile.lastOk());
        assertEq(
            hostile.lastResult(),
            abi.encodeWithSelector(ISplitWallet.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(ledger.observed(w, ETH), 1 ether);
    }

    /// @dev A forfeit holds the wallet's lock: a token that calls back during the transfer to
    ///      the network cannot release from the same wallet.
    function test_ReentryDuringAForfeitIsBlocked() public {
        CallbackToken cb = new CallbackToken();
        address w = _wallet(_list(_fixed(alice, 50_000), _fixed(bob, 50_000)));
        uint256 iA = _indexOf(w, alice);
        uint256 iB = _indexOf(w, bob);
        cb.mint(w, 1000);
        ledger.mark(_payeesOf(w), bytes32(0), address(cb), iA);
        vm.warp(block.timestamp + resolver.unclaimedPeriod());
        cb.setHook(
            address(ledger),
            abi.encodeCall(ISplitWallet.release, (_payeesOf(w), bytes32(0), address(cb), iB))
        );
        assertEq(ledger.forfeit(_payeesOf(w), bytes32(0), address(cb), iA), 500);
        assertFalse(cb.lastHookOk());
        assertEq(
            cb.lastHookResult(),
            abi.encodeWithSelector(ISplitWallet.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(cb.balanceOf(bob), 0);
    }

    function test_ViewsRevertDuringRelease() public {
        ReentrantRecipient hostile = new ReentrantRecipient();
        address w = _solo(address(hostile));
        hostile.configure(
            address(ledger),
            abi.encodeCall(ISplitWallet.releasable, (_payeesOf(w), bytes32(0), ETH, 0))
        );
        vm.deal(address(w), 1 ether);
        _release(w, ETH, 0);
        assertFalse(hostile.lastOk());
        assertEq(
            hostile.lastResult(),
            abi.encodeWithSelector(ISplitWallet.ReentrancyGuardReentrantCall.selector)
        );
    }

    function test_TokenCallbackCannotReenter() public {
        CallbackToken cb = new CallbackToken();
        cb.mint(address(wallet), 1000);
        cb.setHook(
            address(ledger),
            abi.encodeCall(ISplitWallet.release, (_payeesOf(wallet), bytes32(0), address(cb), iBob))
        );
        _release(wallet, address(cb), iAlice);
        assertFalse(cb.lastHookOk());
        assertEq(cb.balanceOf(alice), 500);
        assertEq(cb.balanceOf(bob), 0);
        cb.setHook(
            address(ledger),
            abi.encodeCall(
                ISplitWallet.releaseTo, (_payeesOf(wallet), bytes32(0), address(cb), iAlice, alice)
            )
        );
        _release(wallet, address(cb), iBob);
        assertFalse(cb.lastHookOk());
    }

    /// @dev Each wallet has its own lock: a payee paid from one wallet may release from another
    ///      during that payment (a single global lock would refuse it), while the paying wallet
    ///      stays locked.
    function test_ReentryIntoAnotherWalletIsAllowed() public {
        ReentrantRecipient hostile = new ReentrantRecipient();
        address w = _solo(address(hostile));
        vm.deal(address(wallet), 1 ether);
        hostile.configure(
            address(ledger),
            abi.encodeCall(ISplitWallet.release, (_payeesOf(wallet), bytes32(0), ETH, iBob))
        );
        vm.deal(address(w), 1 ether);
        _release(w, ETH, 0);
        assertTrue(hostile.lastOk());
        assertEq(bob.balance, 0.3 ether);
        assertEq(address(hostile).balance, 1 ether);
    }

    /// @dev A fixed payee that can neither receive ETH nor call blocks only its own share: every
    ///      other payee of the wallet releases in full.
    function test_MutePayeeBlocksOnlyItsOwnShare() public {
        RejectingRecipient mute = new RejectingRecipient();
        address w = _wallet(
            _list(_fixed(address(mute), 50_000), _fixed(alice, 25_000), _artist(ARTIST, 25_000))
        );
        vm.deal(address(w), 4 ether);
        uint256 iMute = _indexOf(w, address(mute));
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.ETHTransferFailed.selector, address(mute), 2 ether)
        );
        _release(w, ETH, iMute);
        assertEq(_release(w, ETH, _indexOf(w, alice)), 1 ether);
        vm.prank(artistPayout);
        assertEq(_release(w, ETH, _artistIndex(w, ARTIST)), 1 ether);
        assertEq(address(w).balance, 2 ether);
        assertEq(_releasable(w, ETH, iMute), 2 ether);
    }
}

/// @dev Answers `payoutAddress` from the same storage layout as `MockArtistResolver`, with
///      different code (and so a different code hash).
contract AnsweringResolver {
    mapping(uint256 => address) public payout;
    bool public down;

    function payoutAddress(uint256 artistId) external view returns (address) {
        require(!down, "resolver down");
        return payout[artistId];
    }

    function differentCode() external pure returns (uint256) {
        return 42;
    }
}
