// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { DutchParams, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { DutchBase } from "./DutchBase.sol";

/// @notice Zero-fee terms (integration finding L-1): a Dutch sale with a zero fee share and no fee
///         recipient opens and settles, paying the seller the whole charge and crediting any ETH
///         excess as usual.
contract DutchZeroFeeTest is DutchBase {
    uint256 internal constant ZERO_ETH = 61;
    uint256 internal constant ZERO_USD = 62;

    function _zeroFee(address currency, uint256 start, uint256 rest)
        internal
        view
        returns (PrimaryTerms memory t)
    {
        t = _terms(SaleKind.DUTCH, currency, start, abi.encode(DutchParams(rest, DURATION, 0)));
        (t.feeRecipient, t.feeShare) = (address(0), 0);
    }

    function setUp() public override {
        super.setUp();
        editions.setTerms(ZERO_ETH, _zeroFee(CURRENCY_ETH, START, REST), SIZE);
        editions.setTerms(ZERO_USD, _zeroFee(address(usd), USD_START, USD_REST), SIZE);
    }

    function test_ZeroFee_EthSaleOpensAndSettles() public {
        uint256 saleId = _openNow(ZERO_ETH);
        vm.warp(block.timestamp + DURATION / 2);
        uint256 unit = dutch.currentPrice(saleId);
        vm.deal(alice, START);
        vm.expectEmit(address(dutch));
        emit ISaleAdapter.SaleSettled(
            saleId,
            address(editions),
            ZERO_ETH,
            alice,
            alice,
            1,
            CURRENCY_ETH,
            unit,
            seller,
            unit,
            address(0),
            0
        );
        vm.prank(alice);
        dutch.purchase{ value: START }(saleId, alice, 1, START, _eth(alice, START));
        assertEq(seller.balance, unit);
        assertEq(dutch.claimable(alice, CURRENCY_ETH), START - unit);
        assertEq(address(dutch).balance, START - unit);
        assertEq(escrow.totalOwed(CURRENCY_ETH), 0);
        assertEq(editions.balanceOf(alice, ZERO_ETH), 1);
    }

    function test_ZeroFee_TokenSaleOpensAndSettles() public {
        uint256 saleId = _openNow(ZERO_USD);
        vm.warp(block.timestamp + DURATION);
        usd.mint(alice, USD_START);
        vm.prank(alice);
        usd.approve(address(dutch), USD_START);
        vm.prank(alice);
        dutch.purchase(saleId, alice, 1, USD_START, _eth(alice, USD_START));
        assertEq(usd.balanceOf(seller), USD_REST);
        assertEq(usd.balanceOf(alice), USD_START - USD_REST);
        assertEq(usd.balanceOf(address(dutch)), 0);
    }
}
