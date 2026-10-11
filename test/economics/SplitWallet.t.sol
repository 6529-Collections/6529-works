// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    BlocklistToken,
    CallbackToken,
    RebasingToken,
    RejectingRecipient,
    ReentrantRecipient
} from "../mocks/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

contract SplitWalletTest is EconomicsBase {
    SplitWallet internal wallet;
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
        assertEq(wallet.observed(ETH), 1 ether);
    }

    function test_ReleasesETHByShareToEachPayoutAddress() public {
        vm.deal(address(wallet), 10 ether);
        assertEq(wallet.releasable(ETH, iAlice), 5 ether);
        assertEq(wallet.releasable(ETH, iBob), 3 ether);
        assertEq(wallet.releasable(ETH, iArtist), 2 ether);

        vm.expectEmit(true, true, true, true, address(wallet));
        emit ISplitWallet.Released(ETH, iAlice, alice, alice, 5 ether, 10 ether);
        assertEq(wallet.release(ETH, iAlice), 5 ether);
        assertEq(wallet.release(ETH, iBob), 3 ether);
        assertEq(wallet.release(ETH, iArtist), 2 ether);

        assertEq(alice.balance, 5 ether);
        assertEq(bob.balance, 3 ether);
        assertEq(artistPayout.balance, 2 ether);
        assertEq(address(wallet).balance, 0);
        assertEq(wallet.totalReleased(ETH), 10 ether);
        assertEq(wallet.released(ETH, iArtist), 2 ether);
        assertEq(wallet.recordedObserved(ETH), 10 ether);
        assertEq(wallet.observed(ETH), 10 ether);
    }

    function test_ReleaseIsCumulativeAcrossReceiptRounds() public {
        vm.deal(address(wallet), 1 ether);
        wallet.release(ETH, iAlice);
        vm.deal(address(wallet), address(wallet).balance + 3 ether);
        assertEq(wallet.release(ETH, iAlice), 1.5 ether);
        assertEq(wallet.release(ETH, iBob), 1.2 ether);
        assertEq(alice.balance, 2 ether);
        assertEq(wallet.observed(ETH), 4 ether);
        assertEq(wallet.releasable(ETH, iArtist), 0.8 ether);
    }

    function test_ReleasesERC20ByExactShares() public {
        token.mint(address(wallet), 1000);
        vm.expectEmit(true, true, true, true, address(wallet));
        emit ISplitWallet.Released(address(token), iBob, bob, bob, 300, 1000);
        assertEq(wallet.release(address(token), iBob), 300);
        assertEq(wallet.release(address(token), iArtist), 200);
        assertEq(token.balanceOf(bob), 300);
        assertEq(token.balanceOf(artistPayout), 200);
        assertEq(token.balanceOf(address(wallet)), 500);
        assertEq(wallet.observed(address(token)), 1000);
    }

    function test_AnyoneMayReleaseButOnlyToThePayee() public {
        vm.deal(address(wallet), 1 ether);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        wallet.release(ETH, iBob);
        assertEq(bob.balance, 0.3 ether);
        assertEq(stranger.balance, 0);
    }

    function test_ArtistPayeeFollowsResolverAtReleaseTime() public {
        vm.deal(address(wallet), 10 ether);
        address recovered = makeAddr("recovered");
        resolver.set(ARTIST, recovered);
        assertEq(wallet.payoutAddress(iArtist), recovered);
        vm.expectEmit(true, true, true, true, address(wallet));
        emit ISplitWallet.Released(ETH, iArtist, recovered, recovered, 2 ether, 10 ether);
        wallet.release(ETH, iArtist);
        assertEq(recovered.balance, 2 ether);
        assertEq(artistPayout.balance, 0);
    }

    function test_UnresolvedOrFailingResolverBlocksOnlyTheArtistPayee() public {
        vm.deal(address(wallet), 1 ether);
        resolver.set(ARTIST, address(0));
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayoutUnresolved.selector, ARTIST));
        wallet.release(ETH, iArtist);
        resolver.setDown(true);
        vm.expectRevert(bytes("resolver down"));
        wallet.release(ETH, iArtist);
        wallet.release(ETH, iAlice);
        assertEq(alice.balance, 0.5 ether);
    }

    function test_ReleaseToRequiresTheCurrentPayoutAddress() public {
        vm.deal(address(wallet), 1 ether);
        address elsewhere = makeAddr("elsewhere");
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, bob, alice));
        vm.prank(bob);
        wallet.releaseTo(ETH, iAlice, elsewhere);

        vm.prank(alice);
        assertEq(wallet.releaseTo(ETH, iAlice, elsewhere), 0.5 ether);
        assertEq(elsewhere.balance, 0.5 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.NotPayoutAddress.selector, alice, artistPayout)
        );
        vm.prank(alice);
        wallet.releaseTo(ETH, iArtist, alice);
        vm.prank(artistPayout);
        wallet.releaseTo(ETH, iArtist, elsewhere);
        assertEq(elsewhere.balance, 0.7 ether);
    }

    function test_RejectsZeroAndSelfRecipients() public {
        vm.deal(address(wallet), 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.InvalidRecipient.selector, address(0)));
        wallet.releaseTo(ETH, iAlice, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.InvalidRecipient.selector, address(wallet))
        );
        wallet.releaseTo(ETH, iAlice, address(wallet));
        vm.stopPrank();
        assertEq(wallet.totalReleased(ETH), 0);
    }

    function test_ResolverPointingAtTheWalletCannotInflateReceipts() public {
        vm.deal(address(wallet), 1 ether);
        resolver.set(ARTIST, address(wallet));
        vm.expectRevert(
            abi.encodeWithSelector(ISplitWallet.InvalidRecipient.selector, address(wallet))
        );
        wallet.release(ETH, iArtist);
    }

    function test_NothingToReleaseAndUnknownPayeeRevert() public {
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, iAlice));
        wallet.release(ETH, iAlice);
        vm.deal(address(wallet), 1 ether);
        wallet.release(ETH, iAlice);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, iAlice));
        wallet.release(ETH, iAlice);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.UnknownPayee.selector, 3));
        wallet.release(ETH, 3);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.UnknownPayee.selector, 3));
        wallet.payee(3);
        vm.expectRevert(abi.encodeWithSelector(ISplitWallet.UnknownPayee.selector, 9));
        wallet.releasable(ETH, 9);
    }

    function test_DeprecatedAndNeverAdmittedAssetsStayWithdrawable() public {
        allowlist.admitAsset(address(token), 1);
        token.mint(address(wallet), 100);
        allowlist.deprecateAsset(address(token));
        assertEq(wallet.release(address(token), iAlice), 50);
        allowlist.deprecateAsset(ETH);
        vm.deal(address(wallet), 1 ether);
        assertEq(wallet.release(ETH, iAlice), 0.5 ether);
        CallbackToken unlisted = new CallbackToken();
        unlisted.mint(address(wallet), 10);
        assertEq(wallet.release(address(unlisted), iBob), 3);
    }

    function test_RoundingDustStaysBelowPayeeCount() public {
        SplitWallet thirds = _wallet(
            _list(_fixed(alice, 33_333), _fixed(bob, 33_333), _fixed(artistPayout, 33_334))
        );
        vm.deal(address(thirds), 10);
        for (uint256 i; i < 3; ++i) {
            thirds.release(ETH, i);
        }
        assertEq(address(thirds).balance, 1);
        for (uint256 i; i < 3; ++i) {
            assertEq(thirds.releasable(ETH, i), 0);
        }
        // The dust is not lost: entitlements are cumulative, so it never exceeds two units.
        vm.deal(address(thirds), address(thirds).balance + 20);
        uint256 due =
            thirds.releasable(ETH, 0) + thirds.releasable(ETH, 1) + thirds.releasable(ETH, 2);
        assertLe(address(thirds).balance - due, 2);
        assertEq(due, 19);
    }

    function test_ShrinkingBalanceFailsClosedUntilRecovered() public {
        RebasingToken rebasing = new RebasingToken();
        rebasing.mint(address(wallet), 1000);
        wallet.release(address(rebasing), iAlice);
        assertEq(wallet.recordedObserved(address(rebasing)), 1000);
        rebasing.setIndex(0.5e18);
        assertEq(wallet.releasable(address(rebasing), iBob), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISplitWallet.ObservedDecreased.selector, address(rebasing), 1000, 750
            )
        );
        wallet.release(address(rebasing), iBob);
        rebasing.setIndex(1e18);
        assertEq(wallet.release(address(rebasing), iBob), 300);
    }

    function test_RejectedETHRollsBackAndPayeeCanRedirect() public {
        ReentrantRecipient payeeContract = new ReentrantRecipient();
        RejectingRecipient rejecting = new RejectingRecipient();
        SplitWallet w = _solo(address(rejecting));
        vm.deal(address(w), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISplitWallet.ETHTransferFailed.selector, address(rejecting), 1 ether
            )
        );
        w.release(ETH, 0);
        assertEq(w.totalReleased(ETH), 0);
        assertEq(w.recordedObserved(ETH), 0);

        SplitWallet w2 = _solo(address(payeeContract));
        vm.deal(address(w2), 1 ether);
        payeeContract.execute(address(w2), abi.encodeCall(ISplitWallet.releaseTo, (ETH, 0, alice)));
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
        wallet.release(address(usdc), iAlice);
        assertEq(wallet.totalReleased(address(usdc)), 0);
        vm.prank(alice);
        wallet.releaseTo(address(usdc), iAlice, bob);
        assertEq(usdc.balanceOf(bob), 50);
    }

    function test_ReentryDuringETHReleaseIsBlocked() public {
        ReentrantRecipient hostile = new ReentrantRecipient();
        SplitWallet w = _wallet(_list(_fixed(address(hostile), 50_000), _fixed(alice, 50_000)));
        uint256 iHostile = _indexOf(w, address(hostile));
        uint256 iOther = _indexOf(w, alice);
        hostile.configure(address(w), abi.encodeCall(ISplitWallet.release, (ETH, iOther)));
        vm.deal(address(w), 2 ether);
        w.release(ETH, iHostile);
        assertFalse(hostile.lastOk());
        assertEq(
            hostile.lastResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(address(hostile).balance, 1 ether);
        assertEq(w.releasable(ETH, iOther), 1 ether);
    }

    function test_ViewsRevertDuringRelease() public {
        ReentrantRecipient hostile = new ReentrantRecipient();
        SplitWallet w = _solo(address(hostile));
        hostile.configure(address(w), abi.encodeCall(ISplitWallet.releasable, (ETH, 0)));
        vm.deal(address(w), 1 ether);
        w.release(ETH, 0);
        assertFalse(hostile.lastOk());
        assertEq(
            hostile.lastResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
    }

    function test_TokenCallbackCannotReenter() public {
        CallbackToken cb = new CallbackToken();
        cb.mint(address(wallet), 1000);
        cb.setHook(address(wallet), abi.encodeCall(ISplitWallet.release, (address(cb), iBob)));
        wallet.release(address(cb), iAlice);
        assertFalse(cb.lastHookOk());
        assertEq(cb.balanceOf(alice), 500);
        assertEq(cb.balanceOf(bob), 0);
        cb.setHook(address(wallet), abi.encodeCall(ISplitWallet.revokeNonce, (1)));
        wallet.release(address(cb), iBob);
        assertFalse(cb.lastHookOk());
    }
}
