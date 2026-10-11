// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IDutchSale } from "src/interfaces/IDutchSale.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { LockedTerms, Payment, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { DutchSale } from "src/sales/DutchSale.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { MintSaleBase } from "src/sales/MintSaleBase.sol";
import { RejectingRecipient, ReentrantRecipient } from "../../mocks/EconomicsMocks.sol";
import { MockPermit2 } from "../../mocks/sales/SaleMocks.sol";
import { DutchBase } from "./DutchBase.sol";

/// @notice Unit tests of the Dutch adapter: configuration, opening, the price curve, purchases
///         with excess credits and claims, ERC-20 payments, and the no-rebate clearing rule.
contract DutchSaleTest is DutchBase {
    // ------------------------------------------------------------------ configuration

    function test_Constructor_RevertsOnZeroDependency() public {
        (IRevenueEscrow e,, IEconomicsResolver r) = _deps();
        vm.expectRevert(MintSaleBase.InvalidAddress.selector);
        new DutchSale(address(manager), e, ISignatureTransfer(address(0)), r);
    }

    function test_ConstantsAndTypehashes() public view {
        assertEq(dutch.saleKind(), keccak256("DUTCH"));
        assertEq(
            Typehashes.DUTCH_PURCHASE_WITNESS,
            keccak256(
                "DutchPurchase(uint256 saleId,address recipient,uint256 quantity,uint256 maxUnitPrice,uint256 deadline)"
            )
        );
        assertEq(
            Typehashes.DUTCH_PURCHASE_WITNESS_TYPE,
            "DutchPurchase witness)DutchPurchase(uint256 saleId,address recipient,uint256 quantity,uint256 maxUnitPrice,uint256 deadline)TokenPermissions(address token,uint256 amount)"
        );
        assertTrue(dutch.supportsInterface(type(IERC165).interfaceId));
        assertTrue(dutch.supportsInterface(type(ISaleAdapter).interfaceId));
        assertTrue(dutch.supportsInterface(type(IDutchSale).interfaceId));
        assertFalse(dutch.supportsInterface(0xffffffff));
    }

    // ------------------------------------------------------------------ opening

    function test_OpenSale_LocksTermsAndEmits() public {
        uint64 startTime = uint64(block.timestamp + 60);
        vm.expectEmit(address(dutch));
        emit ISaleAdapter.SaleStarted(
            1,
            address(editions),
            STEPPED,
            SaleKind.DUTCH,
            CURRENCY_ETH,
            START,
            startTime,
            startTime + DURATION
        );
        vm.prank(platform);
        uint256 saleId = dutch.openSale(address(editions), STEPPED, startTime);
        (LockedTerms memory s, IDutchSale.Schedule memory schedule, bool closed) =
            dutch.sale(saleId);
        assertEq(s.token, address(editions));
        assertEq(s.id, STEPPED);
        assertEq(s.currency, CURRENCY_ETH);
        assertEq(s.price, START);
        assertEq(s.seller, seller);
        assertEq(s.feeRecipient, network);
        assertEq(s.feeShare, FEE_SHARE);
        assertEq(schedule.restingPrice, 0.2 ether);
        assertEq(schedule.startTime, startTime);
        assertEq(schedule.duration, DURATION);
        assertEq(schedule.stepSeconds, STEP);
        assertFalse(closed);
        assertEq(dutch.openSaleOf(address(editions), STEPPED), saleId);
    }

    function test_OpenSale_RevertsForStrangerPastStartOrSecondSale() public {
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, stranger));
        vm.prank(stranger);
        dutch.openSale(address(editions), LINEAR, uint64(block.timestamp));
        vm.expectRevert(DutchSale.InvalidSchedule.selector);
        vm.prank(creator);
        dutch.openSale(address(editions), LINEAR, uint64(block.timestamp - 1));
        uint256 saleId = _openNow(LINEAR);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.SaleAlreadyOpen.selector, address(editions), LINEAR)
        );
        _openNow(LINEAR);
        assertEq(dutch.openSaleOf(address(editions), LINEAR), saleId);
    }

    function test_OpenSale_RevertsOnInvalidCurve() public {
        _setDutch(20, CURRENCY_ETH, 1 ether, 2 ether, DURATION, 0); // rests above the start
        _setDutch(21, CURRENCY_ETH, 1 ether, 0.5 ether, 0, 0); // falls with no duration
        _setDutch(22, CURRENCY_ETH, 1 ether, 0.5 ether, 1000, 300); // uneven steps
        for (uint256 id = 20; id <= 22; ++id) {
            vm.expectRevert(DutchSale.InvalidSchedule.selector);
            vm.prank(creator);
            dutch.openSale(address(editions), id, uint64(block.timestamp));
        }
        // Malformed params fail closed.
        editions.setTerms(23, _terms(SaleKind.DUTCH, CURRENCY_ETH, 1 ether, hex"1234"), SIZE);
        vm.expectRevert();
        vm.prank(creator);
        dutch.openSale(address(editions), 23, uint64(block.timestamp));
        // A flat price with no duration is a valid schedule.
        _setDutch(24, CURRENCY_ETH, 1 ether, 1 ether, 0, 0);
        _openNow(24);
    }

    function test_OpenSale_RevertsOnKindMismatchOrInactiveCurrency() public {
        editions.setTerms(30, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, 1 ether, ""), SIZE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector, SaleKind.DUTCH, SaleKind.FIXED_PRICE
            )
        );
        _openNow(30);
        allowlist.set(address(usd), false);
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.CurrencyNotAllowed.selector, address(usd))
        );
        _openNow(USD_LINEAR);
    }

    // ------------------------------------------------------------------ price curve

    function test_CurrentPrice_FollowsTheCurve() public {
        vm.prank(creator);
        uint256 linear = dutch.openSale(address(editions), LINEAR, uint64(block.timestamp + 10));
        uint256 stepped = _openNow(STEPPED);
        uint256 t0 = block.timestamp;
        assertEq(dutch.currentPrice(linear), START); // before the start
        vm.warp(t0 + 10 + 500);
        assertEq(dutch.currentPrice(linear), START - (START - REST) / 2);
        vm.warp(t0 + 10 + 999);
        assertGt(dutch.currentPrice(linear), REST);
        vm.warp(t0 + 10 + 1000);
        assertEq(dutch.currentPrice(linear), REST);
        vm.warp(t0 + 10 + 1_000_000);
        assertEq(dutch.currentPrice(linear), REST);
        // Stepped: 8 equal drops of 0.1 ether every 100 seconds.
        vm.warp(t0 + 99);
        assertEq(dutch.currentPrice(stepped), START);
        vm.warp(t0 + 100);
        assertEq(dutch.currentPrice(stepped), 0.92 ether);
        vm.warp(t0 + 250);
        assertEq(dutch.currentPrice(stepped), 0.84 ether);
        vm.warp(t0 + 1000);
        assertEq(dutch.currentPrice(stepped), 0.2 ether);
    }

    function test_Views_RevertOnUnknownSale() public {
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, 5));
        dutch.currentPrice(5);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, 5));
        dutch.sale(5);
    }

    // ------------------------------------------------------------------ purchases

    function test_Purchase_ExactPaymentPaysAndEmits() public {
        uint256 saleId = _openNow(LINEAR);
        vm.warp(block.timestamp + 500);
        uint256 unit = dutch.currentPrice(saleId);
        uint256 total = 2 * unit;
        vm.deal(alice, total);
        vm.expectEmit(address(dutch));
        emit ISaleAdapter.SaleSettled(
            saleId,
            address(editions),
            LINEAR,
            alice,
            bob,
            2,
            CURRENCY_ETH,
            total,
            seller,
            total - _fee(total),
            network,
            _fee(total)
        );
        vm.prank(alice);
        dutch.purchase{ value: total }(saleId, bob, 2, unit, _eth(alice, total));
        assertEq(editions.balanceOf(bob, LINEAR), 2);
        assertEq(seller.balance + network.balance, total);
        assertEq(address(dutch).balance, 0);
        assertEq(dutch.claimable(alice, CURRENCY_ETH), 0);
    }

    function test_Purchase_ExcessIsCreditedAndClaimed() public {
        uint256 saleId = _openNow(LINEAR);
        vm.warp(block.timestamp + 500);
        uint256 unit = dutch.currentPrice(saleId);
        vm.deal(alice, START);
        vm.expectEmit(address(dutch));
        emit ISaleAdapter.Credited(alice, CURRENCY_ETH, saleId, START - unit);
        vm.prank(alice);
        dutch.purchase{ value: START }(saleId, address(0), 1, START, _eth(alice, START));
        assertEq(editions.balanceOf(alice, LINEAR), 1);
        assertEq(dutch.claimable(alice, CURRENCY_ETH), START - unit);
        assertEq(address(dutch).balance, START - unit);

        vm.expectEmit(address(dutch));
        emit ISaleAdapter.Claimed(alice, CURRENCY_ETH, bob, START - unit);
        vm.prank(alice);
        assertEq(dutch.claim(CURRENCY_ETH, bob), START - unit);
        assertEq(bob.balance, START - unit);
        assertEq(address(dutch).balance, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.NothingToClaim.selector, alice, CURRENCY_ETH)
        );
        vm.prank(alice);
        dutch.claim(CURRENCY_ETH, bob);
    }

    function test_Purchase_NoRebateWhenThePriceFalls() public {
        uint256 saleId = _openNow(LINEAR);
        _buy(alice, saleId, alice, 1, START, START); // pays the start price
        vm.warp(block.timestamp + DURATION);
        _buy(bob, saleId, bob, 1, REST, REST); // pays the resting price
        assertEq(dutch.claimable(alice, CURRENCY_ETH), 0);
        assertEq(dutch.claimable(bob, CURRENCY_ETH), 0);
        assertEq(seller.balance + network.balance, START + REST);
        // The price rests until the sale closes or supply runs out.
        vm.warp(block.timestamp + 365 days);
        assertEq(dutch.currentPrice(saleId), REST);
    }

    function test_Purchase_RevertsWhenNotOpen() public {
        vm.prank(creator);
        uint256 saleId = dutch.openSale(address(editions), LINEAR, uint64(block.timestamp + 10));
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDutchSale.SaleNotOpen.selector, saleId));
        dutch.purchase{ value: START }(saleId, alice, 1, START, _eth(alice, START));
        vm.expectRevert(abi.encodeWithSelector(IDutchSale.SaleNotOpen.selector, 77));
        dutch.purchase{ value: START }(77, alice, 1, START, _eth(alice, START));
        vm.stopPrank();
        vm.warp(block.timestamp + 10);
        vm.prank(platform);
        dutch.closeSale(saleId);
        vm.expectRevert(abi.encodeWithSelector(IDutchSale.SaleNotOpen.selector, saleId));
        vm.prank(alice);
        dutch.purchase{ value: START }(saleId, alice, 1, START, _eth(alice, START));
    }

    function test_Purchase_RevertsOnLimitQuantityOrUnderpayment() public {
        uint256 saleId = _openNow(LINEAR);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IDutchSale.PriceAboveLimit.selector, START, START - 1)
        );
        dutch.purchase{ value: START }(saleId, alice, 1, START - 1, _eth(alice, START));
        vm.expectRevert(MintSaleBase.InvalidQuantity.selector);
        dutch.purchase(saleId, alice, 0, START, _eth(alice, 0));
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        dutch.purchase{ value: START - 1 }(saleId, alice, 1, START, _eth(alice, START - 1));
        vm.stopPrank();
    }

    function test_CloseSale_ByCreatorOrPlatformOnly() public {
        uint256 saleId = _openNow(LINEAR);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, stranger));
        vm.prank(stranger);
        dutch.closeSale(saleId);
        vm.expectEmit(address(dutch));
        emit IDutchSale.SaleClosed(saleId);
        vm.prank(creator);
        dutch.closeSale(saleId);
        assertTrue(_closed(saleId));
        assertEq(dutch.openSaleOf(address(editions), LINEAR), 0);
        vm.expectRevert(abi.encodeWithSelector(MintSaleBase.SaleAlreadyClosed.selector, saleId));
        vm.prank(creator);
        dutch.closeSale(saleId);
    }

    // ------------------------------------------------------------------ claims

    function test_Claim_FailedDeliveryKeepsTheCredit() public {
        uint256 saleId = _openNow(LINEAR);
        _buy(alice, saleId, alice, 1, START, 2 ether);
        RejectingRecipient refusing = new RejectingRecipient();
        vm.expectRevert(
            abi.encodeWithSelector(MintSaleBase.ClaimFailed.selector, address(refusing))
        );
        vm.prank(alice);
        dutch.claim(CURRENCY_ETH, address(refusing));
        assertEq(dutch.claimable(alice, CURRENCY_ETH), 1 ether);
        vm.expectRevert(MintSaleBase.InvalidAddress.selector);
        vm.prank(alice);
        dutch.claim(CURRENCY_ETH, address(0));
    }

    function test_Claim_ReentryIsBlocked() public {
        uint256 saleId = _openNow(LINEAR);
        ReentrantRecipient reentrant = new ReentrantRecipient();
        _buy(address(reentrant), saleId, alice, 1, START, 2 ether);
        reentrant.configure(
            address(dutch), abi.encodeCall(ISaleAdapter.claim, (CURRENCY_ETH, address(reentrant)))
        );
        vm.prank(address(reentrant));
        dutch.claim(CURRENCY_ETH, address(reentrant));
        assertFalse(reentrant.lastOk());
        assertEq(
            bytes4(reentrant.lastResult()),
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(address(reentrant).balance, 1 ether);
        assertEq(dutch.claimable(address(reentrant), CURRENCY_ETH), 0);
    }

    function test_Claim_IsNeverBlockedByDeprecation() public {
        uint256 saleId = _openNow(LINEAR);
        _buy(alice, saleId, alice, 1, START, 2 ether);
        allowlist.set(CURRENCY_ETH, false);
        // New purchases halt, but the credit is still claimable.
        vm.deal(bob, START);
        vm.expectRevert(
            abi.encodeWithSelector(MintSaleBase.CurrencyNotActive.selector, CURRENCY_ETH)
        );
        vm.prank(bob);
        dutch.purchase{ value: START }(saleId, bob, 1, START, _eth(bob, START));
        vm.prank(alice);
        assertEq(dutch.claim(CURRENCY_ETH, alice), 1 ether);
    }

    function test_Pause_StopsOpeningAndBuyingButNotClaimingOrClosing() public {
        uint256 saleId = _openNow(LINEAR);
        _buy(alice, saleId, alice, 1, START, 2 ether);
        vm.prank(pauser);
        dutch.pause();
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        _openNow(STEPPED);
        vm.deal(bob, START);
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        vm.prank(bob);
        dutch.purchase{ value: START }(saleId, bob, 1, START, _eth(bob, START));
        vm.prank(alice);
        assertEq(dutch.claim(CURRENCY_ETH, alice), 1 ether);
        vm.prank(platform);
        dutch.closeSale(saleId);
        vm.prank(unpauser);
        dutch.unpause();
        _openNow(LINEAR);
    }

    // ------------------------------------------------------------------ ERC-20

    function test_Erc20_DirectPullsExactlyTheCharge() public {
        uint256 saleId = _openNow(USD_LINEAR);
        vm.warp(block.timestamp + 500);
        uint256 unit = dutch.currentPrice(saleId);
        usd.mint(alice, 1000e18);
        vm.prank(alice);
        usd.approve(address(dutch), type(uint256).max);
        // Payment.amount is the most Alice will pay; the sale takes exactly the charge.
        Payment memory pay = _eth(alice, 3 * USD_START);
        vm.prank(alice);
        dutch.purchase(saleId, alice, 3, USD_START, pay);
        assertEq(usd.balanceOf(alice), 1000e18 - 3 * unit);
        assertEq(usd.balanceOf(seller) + usd.balanceOf(network), 3 * unit);
        assertEq(usd.balanceOf(address(dutch)), 0);
        assertEq(dutch.claimable(alice, address(usd)), 0);
    }

    function test_Erc20_PermitAllowsAMaximum() public {
        uint256 saleId = _openNow(USD_LINEAR);
        vm.warp(block.timestamp + 1000);
        usd.mint(alice, 1000e18);
        Payment memory pay =
            _permitPayment(aliceKey, alice, address(dutch), USD_START, block.timestamp + 60);
        vm.prank(alice);
        dutch.purchase(saleId, alice, 1, USD_START, pay);
        assertEq(usd.balanceOf(alice), 1000e18 - USD_REST);
        // The unspent permit allowance stays with the adapter, usable only by Alice herself.
        assertEq(usd.allowance(alice, address(dutch)), USD_START - USD_REST);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        vm.prank(bob);
        dutch.purchase(saleId, bob, 1, USD_START, _eth(alice, USD_REST));
    }

    function test_Erc20_Permit2IntentTakesTheChargeOnly() public {
        uint256 saleId = _openNow(USD_LINEAR);
        vm.warp(block.timestamp + 500);
        uint256 unit = dutch.currentPrice(saleId);
        usd.mint(alice, 1000e18);
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        uint256 deadline = block.timestamp + 1 hours;
        Payment memory pay = _intent(
            aliceKey,
            alice,
            _witness(saleId, bob, 2, USD_START, deadline),
            2 * USD_START,
            0,
            deadline
        );
        vm.prank(relayer);
        dutch.purchase(saleId, bob, 2, USD_START, pay);
        assertEq(editions.balanceOf(bob, USD_LINEAR), 2);
        assertEq(usd.balanceOf(alice), 1000e18 - 2 * unit);
        // Replay, a raised limit, or a redirected recipient all fail.
        vm.expectRevert(MockPermit2.InvalidNonce.selector);
        vm.prank(relayer);
        dutch.purchase(saleId, bob, 2, USD_START, pay);
        Payment memory fresh = _intent(
            aliceKey,
            alice,
            _witness(saleId, bob, 2, USD_START, deadline),
            2 * USD_START,
            1,
            deadline
        );
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        vm.prank(relayer);
        dutch.purchase(saleId, bob, 2, USD_START + 1, fresh);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        vm.prank(relayer);
        dutch.purchase(saleId, relayer, 2, USD_START, fresh);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(MintSaleBase.PaymentExpired.selector, deadline));
        vm.prank(relayer);
        dutch.purchase(saleId, bob, 2, USD_START, fresh);
    }

    function test_Erc20_RejectsEthAndShortAmounts() public {
        uint256 saleId = _openNow(USD_LINEAR);
        usd.mint(alice, 1000e18);
        vm.prank(alice);
        usd.approve(address(dutch), type(uint256).max);
        vm.deal(alice, 1 ether);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        vm.prank(alice);
        dutch.purchase{ value: 1 }(saleId, alice, 1, USD_START, _eth(alice, USD_START));
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        vm.prank(alice);
        dutch.purchase(saleId, alice, 1, USD_START, _eth(alice, USD_START - 1));
    }
}
