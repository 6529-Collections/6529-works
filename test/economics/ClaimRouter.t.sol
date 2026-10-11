// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { SignatureVerifier } from "src/libraries/SignatureVerifier.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IReleaseVerifier } from "src/economics/interfaces/IReleaseVerifier.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    BlocklistToken,
    ClaimReentrantRecipient,
    ClaimWalletAdversary,
    Mock1271Account
} from "../mocks/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @dev Ported from 6529Stream PR #744 `StreamClaimRouter.t.sol` (adversarial claim batches),
///      adapted to index-addressed payees and the artist-resolved payee kind.
contract ClaimRouterTest is EconomicsBase {
    bytes32 internal constant FAILED =
        keccak256("ClaimFailed(address,address,uint256,uint256,uint256,bytes)");

    struct Failure {
        address wallet;
        address asset;
        uint256 payee;
        uint256 index;
        uint256 size;
        bytes reason;
    }

    address internal caller = makeAddr("caller");

    /// @dev A one-payee wallet for `account`, made distinct per `salt` by a second payee holding a
    ///      single unit, so many wallets can pay the same account.
    function _walletFor(uint256 salt, address account) internal returns (SplitWallet w) {
        address filler = address(uint160(uint256(keccak256(abi.encode("filler", salt)))));
        w = _wallet(_list(_fixed(account, D - 1), _fixed(filler, 1)));
    }

    function _one(address wallet, address asset, uint256 payeeIndex)
        internal
        pure
        returns (IClaimRouter.Claim[] memory claims)
    {
        claims = new IClaimRouter.Claim[](1);
        claims[0] = IClaimRouter.Claim(wallet, asset, payeeIndex);
    }

    function _two(address first, uint256 firstPayee, address second, uint256 secondPayee)
        internal
        pure
        returns (IClaimRouter.Claim[] memory claims)
    {
        claims = new IClaimRouter.Claim[](2);
        claims[0] = IClaimRouter.Claim(first, ETH, firstPayee);
        claims[1] = IClaimRouter.Claim(second, ETH, secondPayee);
    }

    function test_ExactSelectorAndEmptyBatches() public {
        assertEq(
            IClaimRouter.claim.selector,
            bytes4(keccak256("claim((address,address,uint256)[],bool)"))
        );
        IClaimRouter.Claim[] memory empty = new IClaimRouter.Claim[](0);
        assertEq(router.claim(empty, false).length, 0);
        assertEq(router.claim(empty, true).length, 0);
    }

    function test_TwentyEventDiscoveredWalletsClaimETH() public {
        vm.recordLogs();
        for (uint256 i; i < 20; ++i) {
            _walletFor(i, alice);
        }
        IClaimRouter.Claim[] memory claims = _discover(vm.getRecordedLogs(), alice, ETH);
        assertEq(claims.length, 20);
        for (uint256 i; i < 20; ++i) {
            vm.deal(claims[i].wallet, (i + 1) * 1 ether);
        }
        vm.prank(caller);
        uint256 before = gasleft();
        uint256[] memory amounts = router.claim{ gas: 16_000_000 }(claims, false);
        emit log_named_uint("20-wallet ETH claim gas", before - gasleft());
        uint256 total;
        for (uint256 i; i < 20; ++i) {
            uint256 expected = _share((i + 1) * 1 ether, D - 1, D);
            assertEq(amounts[i], expected);
            assertEq(
                SplitWallet(payable(claims[i].wallet)).released(ETH, claims[i].payee), expected
            );
            total += expected;
        }
        assertEq(alice.balance, total);
        assertEq(caller.balance, 0);
        assertEq(address(router).balance, 0);
    }

    function test_TwentyWalletsClaimERC20() public {
        vm.recordLogs();
        for (uint256 i; i < 20; ++i) {
            _walletFor(i, alice);
        }
        IClaimRouter.Claim[] memory claims = _discover(vm.getRecordedLogs(), alice, address(token));
        for (uint256 i; i < 20; ++i) {
            token.mint(claims[i].wallet, (i + 1) * D);
        }
        uint256[] memory amounts = router.claim{ gas: 16_000_000 }(claims, true);
        uint256 total;
        for (uint256 i; i < 20; ++i) {
            assertEq(amounts[i], (i + 1) * (D - 1));
            total += amounts[i];
        }
        assertEq(token.balanceOf(alice), total);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function test_BatchesUpToMaxClaimsAndRejectsMore() public {
        ClaimWalletAdversary wallet = new ClaimWalletAdversary();
        uint256 max = router.MAX_CLAIMS();
        assertEq(max, 50);
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](max);
        for (uint256 i; i < max; ++i) {
            claims[i] = IClaimRouter.Claim(address(wallet), ETH, 5);
        }
        uint256[] memory amounts = router.claim(claims, false);
        assertEq(amounts.length, max);
        assertEq(wallet.releaseCalls(), max);
        assertEq(wallet.lastPayee(), 5);
        assertEq(amounts[max - 1], 77);

        IClaimRouter.Claim[] memory tooMany = new IClaimRouter.Claim[](max + 1);
        vm.expectRevert(abi.encodeWithSelector(IClaimRouter.TooManyClaims.selector, max + 1));
        router.claim(tooMany, true);
    }

    /// @dev Pins the per-item gas floors: a signed item adds the verifier's capped ERC-1271 check
    ///      on top of a plain release, so its floor covers both, and each full batch can be offered
    ///      its floors within the EIP-7825 cap.
    function test_PerItemGasFloorsAreConsistent() public view {
        assertEq(router.MIN_ITEM_GAS(), 200_000);
        assertEq(router.MIN_SIGNED_ITEM_GAS(), 450_000);
        assertGe(
            router.MIN_SIGNED_ITEM_GAS(),
            router.MIN_ITEM_GAS() + SignatureVerifier.ERC1271_GAS_LIMIT
        );
        assertLe((router.MAX_CLAIMS() + 1) * router.MIN_ITEM_GAS(), 16_777_216);
        assertLe((router.MAX_SIGNED_CLAIMS() + 1) * router.MIN_SIGNED_ITEM_GAS(), 16_777_216);
    }

    function test_ContinueModeRevertsWhenItemsWouldBeStarved() public {
        SplitWallet first = _solo(alice);
        SplitWallet second = _solo(bob);
        vm.deal(address(first), 1 ether);
        vm.deal(address(second), 1 ether);
        IClaimRouter.Claim[] memory claims = _two(address(first), 0, address(second), 0);
        // Three shares of about 100k each: below the 200k per-item floor, so the batch reverts rather
        // than "succeeding" with every item out of gas.
        (bool ok, bytes memory data) =
            address(router).call{ gas: 300_000 }(abi.encodeCall(IClaimRouter.claim, (claims, true)));
        assertFalse(ok);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 32))
        }
        assertEq(selector, IClaimRouter.ClaimInsufficientGas.selector);
        assertEq(alice.balance, 0);
        uint256[] memory amounts = router.claim{ gas: 1_000_000 }(claims, true);
        assertEq(amounts[0] + amounts[1], 2 ether);
    }

    function test_FailedItemContinuesToLaterClaimWithExactReason() public {
        BlocklistToken usdc = new BlocklistToken();
        SplitWallet first = _solo(alice);
        SplitWallet later = _solo(bob);
        usdc.mint(address(first), 500);
        vm.deal(address(later), 2 ether);
        usdc.setBlocked(alice, true);
        IClaimRouter.Claim[] memory claims = _two(address(first), 0, address(later), 0);
        claims[0].asset = address(usdc);
        bytes memory reason = abi.encodeWithSelector(
            TokenTransfer.TokenCallFailed.selector, address(usdc), usdc.transfer.selector
        );
        vm.expectEmit(true, true, true, true, address(router));
        emit IClaimRouter.ClaimFailed(address(first), address(usdc), 0, 0, reason.length, reason);
        uint256[] memory amounts = router.claim(claims, true);
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 2 ether);
        assertEq(usdc.balanceOf(address(first)), 500);
        assertEq(bob.balance, 2 ether);
    }

    function test_AtomicLateFailureRollsBackETH() public {
        SplitWallet first = _solo(alice);
        SplitWallet empty = _solo(bob);
        vm.deal(address(first), 1 ether);
        bytes memory reason =
            abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, ETH, uint256(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 1, address(empty), reason.length, reason
            )
        );
        router.claim(_two(address(first), 0, address(empty), 0), false);
        assertEq(address(first).balance, 1 ether);
        assertEq(alice.balance, 0);
        assertEq(first.totalReleased(ETH), 0);
        assertEq(first.recordedObserved(ETH), 0);
    }

    function test_AtomicLateFailureRollsBackToken() public {
        SplitWallet first = _solo(alice);
        SplitWallet empty = _solo(bob);
        token.mint(address(first), 900);
        IClaimRouter.Claim[] memory claims = _two(address(first), 0, address(empty), 0);
        claims[0].asset = address(token);
        claims[1].asset = address(token);
        bytes memory reason =
            abi.encodeWithSelector(ISplitWallet.NothingToRelease.selector, address(token), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 1, address(empty), reason.length, reason
            )
        );
        router.claim(claims, false);
        assertEq(token.balanceOf(address(first)), 900);
        assertEq(token.balanceOf(alice), 0);
        assertEq(first.totalReleased(address(token)), 0);
    }

    function test_EOAAndZeroAddressAreFailures() public {
        vm.recordLogs();
        uint256[] memory amounts = router.claim(_two(address(0), 0, caller, 0), true);
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        Failure memory f = _failure(logs[1]);
        assertEq(f.index, 1);
        assertEq(f.size, 0);
        assertEq(
            f.reason, abi.encodeWithSelector(IClaimRouter.ClaimTargetHasNoCode.selector, caller)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector,
                0,
                address(0),
                0,
                abi.encodeWithSelector(IClaimRouter.ClaimTargetHasNoCode.selector, address(0))
            )
        );
        router.claim(_one(address(0), ETH, 0), false);
    }

    function test_MalformedSuccessfulReturnsNeverCountAsRelease() public {
        for (uint8 mode = 2; mode <= 5; ++mode) {
            ClaimWalletAdversary wallet = new ClaimWalletAdversary();
            wallet.configure(mode);
            vm.recordLogs();
            uint256[] memory amounts = router.claim(_one(address(wallet), ETH, 0), true);
            assertEq(amounts[0], 0);
            Failure memory f = _onlyFailure(vm.getRecordedLogs());
            uint256 size = mode == 2 ? 0 : mode == 3 ? 31 : mode == 4 ? 64 : 65536;
            assertEq(f.size, size);
            assertEq(
                f.reason, abi.encodeWithSelector(IClaimRouter.InvalidClaimReturnData.selector, size)
            );
            // The callee's own side effect stands; only the reported amount is refused.
            assertEq(wallet.releaseCalls(), 1);
        }
    }

    function test_AtomicMalformedReturnRollsBackEarlierMoneyAndCalleeState() public {
        SplitWallet first = _solo(alice);
        vm.deal(address(first), 1 ether);
        ClaimWalletAdversary wallet = new ClaimWalletAdversary();
        wallet.configure(4);
        bytes memory reason =
            abi.encodeWithSelector(IClaimRouter.InvalidClaimReturnData.selector, 64);
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 1, address(wallet), 64, reason
            )
        );
        router.claim(_two(address(first), 0, address(wallet), 0), false);
        assertEq(address(first).balance, 1 ether);
        assertEq(alice.balance, 0);
        assertEq(wallet.releaseCalls(), 0);
    }

    function test_RevertBombReasonIsBoundedAndLaterClaimSucceeds() public {
        _hostileThenReal(6);
    }

    function test_ReturnBombIsBoundedAndLaterClaimSucceeds() public {
        _hostileThenReal(5);
    }

    function test_GasBurnerCannotStarveLaterClaim() public {
        _hostileThenReal(7);
    }

    function test_AtomicRevertBombHasBoundedErrorAndRollsBack() public {
        SplitWallet first = _solo(alice);
        vm.deal(address(first), 1 ether);
        ClaimWalletAdversary wallet = new ClaimWalletAdversary();
        wallet.configure(6);
        (bool ok, bytes memory data) = address(router)
            .call(
                abi.encodeCall(
                    IClaimRouter.claim, (_two(address(first), 0, address(wallet), 0), false)
                )
            );
        assertFalse(ok);
        // selector + index, wallet, size, offset + length + 256 bytes of reason
        assertEq(data.length, 4 + 4 * 32 + 32 + 256);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 32))
        }
        assertEq(selector, IClaimRouter.ClaimCallFailed.selector);
        assertEq(address(first).balance, 1 ether);
        assertEq(alice.balance, 0);
    }

    function test_AtomicGasBurnerRevertsTheWholeBatch() public {
        SplitWallet first = _solo(alice);
        vm.deal(address(first), 1 ether);
        ClaimWalletAdversary wallet = new ClaimWalletAdversary();
        wallet.configure(7);
        (bool ok,) = address(router).call{ gas: 2_000_000 }(
            abi.encodeCall(IClaimRouter.claim, (_two(address(first), 0, address(wallet), 0), false))
        );
        assertFalse(ok);
        assertEq(address(first).balance, 1 ether);
    }

    function test_ZeroSuccessIsNotAFailureAndRepeatPaysOnce() public {
        ClaimWalletAdversary wallet = new ClaimWalletAdversary();
        wallet.configure(8);
        vm.recordLogs();
        uint256[] memory zero = router.claim(_one(address(wallet), ETH, 0), true);
        assertEq(zero[0], 0);
        assertEq(vm.getRecordedLogs().length, 0);

        SplitWallet real = _solo(alice);
        vm.deal(address(real), 1 ether);
        vm.recordLogs();
        uint256[] memory repeated = router.claim(_two(address(real), 0, address(real), 0), true);
        assertEq(repeated[0], 1 ether);
        assertEq(repeated[1], 0);
        assertEq(_onlyFailure(vm.getRecordedLogs()).index, 1);
        assertEq(alice.balance, 1 ether);
    }

    function test_ReentrantRecipientCannotDoubleClaimOrRedirect() public {
        ClaimReentrantRecipient recipient = new ClaimReentrantRecipient(router);
        SplitWallet first = _solo(address(recipient));
        // The recipient sorts first, so it is payee 0 in both wallets.
        SplitWallet second = _wallet(
            _list(_fixed(address(recipient), D - 1), _fixed(address(type(uint160).max), 1))
        );
        recipient.configure(address(first), address(second));
        vm.deal(address(first), 1 ether);
        vm.deal(address(second), 2 ether);
        assertEq(_indexOf(second, address(recipient)), 0);
        uint256[] memory amounts = router.claim(_one(address(first), ETH, 0), false);
        assertEq(amounts[0], 1 ether);
        // The first wallet's guard refuses the nested claim; the second is an independent
        // entitlement and pays the same account.
        assertEq(recipient.nestedFirst(), 0);
        assertEq(recipient.nestedSecond(), _share(2 ether, D - 1, D));
        assertEq(address(recipient).balance, 1 ether + _share(2 ether, D - 1, D));
        assertEq(address(router).balance, 0);
        assertEq(first.totalReleased(ETH), 1 ether);
    }

    function test_RejectsValueUnknownSelectorsAndRecipientChoice() public {
        vm.deal(address(this), 1 ether);
        (bool received,) = address(router).call{ value: 1 }("");
        assertFalse(received);
        (bool owner,) = address(router).call(abi.encodeWithSignature("owner()"));
        assertFalse(owner);
        (bool redirect,) = address(router)
            .call(abi.encodeWithSignature("releaseTo(address,uint256,address)", ETH, 0, caller));
        assertFalse(redirect);
        IClaimRouter.Claim[] memory empty = new IClaimRouter.Claim[](0);
        (bool payableClaim,) =
            address(router).call{ value: 1 }(abi.encodeCall(IClaimRouter.claim, (empty, false)));
        assertFalse(payableClaim);
        assertEq(address(router).balance, 0);
    }

    function test_PlainArtistItemsFailAndContinueModeSkipsThem() public {
        SplitWallet w = _trio();
        uint256 iArtist = _artistIndex(w, ARTIST);
        vm.deal(address(w), 10 ether);
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](2);
        claims[0] = IClaimRouter.Claim(address(w), ETH, iArtist);
        claims[1] = IClaimRouter.Claim(address(w), ETH, _indexOf(w, bob));
        bytes memory reason = abi.encodeWithSelector(
            ISplitWallet.NotPayoutAddress.selector, address(router), artistPayout
        );
        vm.expectEmit(true, true, true, true, address(router));
        emit IClaimRouter.ClaimFailed(address(w), ETH, iArtist, 0, reason.length, reason);
        vm.prank(caller);
        uint256[] memory amounts = router.claim(claims, true);
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 3 ether);
        assertEq(artistPayout.balance, 0);
    }

    function test_SignedClaimsPayTheCurrentResolvedArtistAcrossWallets() public {
        address recovered = vm.addr(0xBEEF);
        resolver.set(ARTIST, recovered);
        IClaimRouter.SignedClaim[] memory claims = new IClaimRouter.SignedClaim[](3);
        for (uint256 i; i < 3; ++i) {
            SplitWallet w = _wallet(
                _list(_fixed(address(uint160(0xD00 + i)), 50_000), _artist(ARTIST, 50_000))
            );
            vm.deal(address(w), 2 ether);
            IReleaseVerifier.Authorization memory a = _auth(
                w, ETH, _artistIndex(w, ARTIST), recovered, recovered, type(uint256).max, i
            );
            claims[i] = IClaimRouter.SignedClaim(a, _sign(0xBEEF, a));
        }
        vm.prank(caller);
        uint256[] memory amounts = router.claimSigned(claims, false);
        assertEq(amounts[0] + amounts[1] + amounts[2], 3 ether);
        assertEq(recovered.balance, 3 ether);
        assertEq(caller.balance, 0);
        assertEq(address(router).balance, 0);
    }

    function test_SignedClaimFailuresFollowTheMode() public {
        SplitWallet w = _trio();
        vm.deal(address(w), 10 ether);
        IReleaseVerifier.Authorization memory a =
            _auth(w, ETH, _artistIndex(w, ARTIST), artistPayout, artistPayout, 1 ether, 1);
        IClaimRouter.SignedClaim[] memory claims = new IClaimRouter.SignedClaim[](2);
        claims[0] = IClaimRouter.SignedClaim(a, _sign(bobPk, a));
        claims[1] = IClaimRouter.SignedClaim(a, _sign(artistPk, a));
        bytes memory reason =
            abi.encodeWithSelector(IReleaseVerifier.InvalidSignature.selector, artistPayout);
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimRouter.ClaimCallFailed.selector, 0, address(w), reason.length, reason
            )
        );
        router.claimSigned(claims, false);
        vm.expectEmit(true, true, true, true, address(router));
        emit IClaimRouter.ClaimFailed(address(w), ETH, a.payee, 0, reason.length, reason);
        uint256[] memory amounts = router.claimSigned(claims, true);
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 1 ether);
    }

    function test_SignedBatchesAreCappedAndNeedTheirMinimumGas() public {
        uint256 max = router.MAX_SIGNED_CLAIMS();
        assertEq(max, 20);
        IClaimRouter.SignedClaim[] memory tooMany = new IClaimRouter.SignedClaim[](max + 1);
        vm.expectRevert(abi.encodeWithSelector(IClaimRouter.TooManyClaims.selector, max + 1));
        router.claimSigned(tooMany, true);

        SplitWallet w = _solo(alice);
        vm.deal(address(w), 1 ether);
        IReleaseVerifier.Authorization memory a = _auth(w, ETH, 0, alice, alice, 1 ether, 1);
        IClaimRouter.SignedClaim[] memory one = new IClaimRouter.SignedClaim[](1);
        one[0] = IClaimRouter.SignedClaim(a, _sign(alicePk, a));
        (bool ok, bytes memory data) = address(router).call{ gas: 600_000 }(
            abi.encodeCall(IClaimRouter.claimSigned, (one, true))
        );
        assertFalse(ok);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 32))
        }
        assertEq(selector, IClaimRouter.ClaimInsufficientGas.selector);
        assertEq(router.claimSigned{ gas: 1_200_000 }(one, true)[0], 1 ether);
    }

    /// @dev Ported from the review: a resolver answer only ever steers the artist's own index. A
    ///      gas-burning artist payout cannot block fixed payees in the same batch.
    function test_ResolverOnlyReachesTheArtistIndex() public {
        SplitWallet w = _trio();
        uint256 iArtist = _artistIndex(w, ARTIST);
        vm.deal(address(w), 10 ether);
        // Point the artist at alice: alice pulls the artist's 20% on top, never more.
        resolver.set(ARTIST, alice);
        vm.prank(alice);
        assertEq(w.release(ETH, iArtist), 2 ether);
        assertEq(w.release(ETH, _indexOf(w, alice)), 5 ether);
        assertEq(alice.balance, 7 ether);

        Mock1271Account burner = new Mock1271Account();
        burner.setBurn(10_000_000);
        resolver.set(ARTIST, address(burner));
        vm.deal(address(w), address(w).balance + 10 ether);
        IReleaseVerifier.Authorization memory a =
            _auth(w, ETH, iArtist, address(burner), address(burner), 1 ether, 1);
        IClaimRouter.SignedClaim[] memory signed = new IClaimRouter.SignedClaim[](1);
        signed[0] = IClaimRouter.SignedClaim(a, "");
        assertEq(router.claimSigned{ gas: 2_000_000 }(signed, true)[0], 0);
        assertEq(router.claim(_one(address(w), ETH, _indexOf(w, bob)), true)[0], 6 ether);
    }

    function test_UnknownPayeeFailsOnlyItsItem() public {
        SplitWallet w = _solo(alice);
        vm.deal(address(w), 1 ether);
        IClaimRouter.Claim[] memory claims = _two(address(w), 4, address(w), 0);
        bytes memory reason = abi.encodeWithSelector(ISplitWallet.UnknownPayee.selector, 4);
        vm.expectEmit(true, true, true, true, address(router));
        emit IClaimRouter.ClaimFailed(address(w), ETH, 4, 0, reason.length, reason);
        uint256[] memory amounts = router.claim(claims, true);
        assertEq(amounts[1], 1 ether);
    }

    function test_MixedAssetsAndPayeesInOneBatch() public {
        SplitWallet w = _trio();
        vm.deal(address(w), 10 ether);
        token.mint(address(w), 1000);
        IClaimRouter.Claim[] memory claims = new IClaimRouter.Claim[](4);
        claims[0] = IClaimRouter.Claim(address(w), ETH, _indexOf(w, alice));
        claims[1] = IClaimRouter.Claim(address(w), address(token), _indexOf(w, alice));
        claims[2] = IClaimRouter.Claim(address(w), ETH, _indexOf(w, bob));
        claims[3] = IClaimRouter.Claim(address(w), address(token), _indexOf(w, bob));
        uint256[] memory amounts = router.claim(claims, false);
        assertEq(amounts[0], 5 ether);
        assertEq(amounts[1], 500);
        assertEq(amounts[2], 3 ether);
        assertEq(amounts[3], 300);
        assertEq(token.balanceOf(bob), 300);
    }

    function _hostileThenReal(uint8 mode) internal {
        ClaimWalletAdversary hostile = new ClaimWalletAdversary();
        hostile.configure(mode);
        SplitWallet real = _solo(alice);
        vm.deal(address(real), 1 ether);
        bytes memory input = abi.encodeCall(
            IClaimRouter.claim, (_two(address(hostile), 0, address(real), 0), true)
        );
        vm.recordLogs();
        (bool success, bytes memory output) = address(router).call{ gas: 1_500_000 }(input);
        assertTrue(success);
        uint256[] memory amounts = abi.decode(output, (uint256[]));
        assertEq(amounts[0], 0);
        assertEq(amounts[1], 1 ether);
        assertEq(alice.balance, 1 ether);
        Failure memory f = _onlyFailure(vm.getRecordedLogs());
        assertEq(f.index, 0);
        assertEq(f.wallet, address(hostile));
        if (mode == 6) {
            assertEq(f.size, 65536);
            assertEq(f.reason.length, 256);
            uint256 firstWord;
            bytes memory reason = f.reason;
            assembly ("memory-safe") {
                firstWord := mload(add(reason, 32))
            }
            assertEq(firstWord, 77);
        }
        if (mode == 5) {
            assertEq(f.size, 65536);
            assertEq(f.reason.length, 36);
        }
        if (mode == 7) {
            assertEq(f.size, 0);
            assertEq(f.reason.length, 0);
        }
    }

    function _discover(Vm.Log[] memory logs, address account, address asset)
        internal
        view
        returns (IClaimRouter.Claim[] memory claims)
    {
        bytes32 created = ISplitFactory.WalletCreated.selector;
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == created) ++count;
        }
        claims = new IClaimRouter.Claim[](count);
        uint256 cursor;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(factory) || logs[i].topics[0] != created) continue;
            address wallet = address(uint160(uint256(logs[i].topics[1])));
            (, ISplitWallet.Payee[] memory payees) =
                abi.decode(logs[i].data, (bytes32, ISplitWallet.Payee[]));
            uint256 index = type(uint256).max;
            for (uint256 j; j < payees.length; ++j) {
                if (payees[j].account == account) index = j;
            }
            require(index != type(uint256).max, "event-discovered entitlement");
            claims[cursor++] = IClaimRouter.Claim(wallet, asset, index);
        }
    }

    function _onlyFailure(Vm.Log[] memory logs) internal view returns (Failure memory result) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == FAILED) {
                result = _failure(logs[i]);
                ++count;
            }
        }
        assertEq(count, 1, "exactly one router failure event");
    }

    function _failure(Vm.Log memory log) internal view returns (Failure memory f) {
        assertEq(log.emitter, address(router));
        assertEq(log.topics.length, 4);
        assertEq(log.topics[0], FAILED);
        f.wallet = address(uint160(uint256(log.topics[1])));
        f.asset = address(uint160(uint256(log.topics[2])));
        f.payee = uint256(log.topics[3]);
        (f.index, f.size, f.reason) = abi.decode(log.data, (uint256, uint256, bytes));
    }

    function _share(uint256 amount, uint256 share, uint256 denominator)
        internal
        pure
        returns (uint256)
    {
        return amount * share / denominator;
    }
}
