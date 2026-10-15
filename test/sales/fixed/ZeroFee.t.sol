// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH, PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { MintSaleBase } from "src/sales/MintSaleBase.sol";
import { MockEditionTarget, MockFederationRegistry } from "../../mocks/sales/SaleMocks.sol";
import { FixedPriceBase } from "./FixedPriceBase.sol";

/// @notice Zero-fee terms (integration finding L-1): a zero fee share with no fee recipient is
///         valid economics, so a fixed-price sale on it opens and settles, paying the seller in
///         full and paying no fee; a non-zero share still needs a recipient.
contract FixedPriceZeroFeeTest is FixedPriceBase {
    uint256 internal constant ZERO_ETH = 41;
    uint256 internal constant ZERO_USD = 42;

    function _zeroFee(address currency, uint256 price)
        internal
        view
        returns (PrimaryTerms memory t)
    {
        t = _terms(SaleKind.FIXED_PRICE, currency, price, "");
        (t.feeRecipient, t.feeShare) = (address(0), 0);
    }

    function setUp() public override {
        super.setUp();
        editions.setTerms(ZERO_ETH, _zeroFee(CURRENCY_ETH, PRICE), SIZE);
        editions.setTerms(ZERO_USD, _zeroFee(address(usd), USD_PRICE), SIZE);
    }

    function test_ZeroFee_EthSaleOpensAndSettles() public {
        uint256 saleId = _openPublic(ZERO_ETH, 0);
        assertEq(_locked(saleId).feeRecipient, address(0));
        assertEq(_locked(saleId).feeShare, 0);
        uint256 total = 2 * PRICE;
        vm.deal(alice, total);
        vm.expectEmit(address(fixedSale));
        emit ISaleAdapter.SaleSettled(
            saleId,
            address(editions),
            ZERO_ETH,
            alice,
            bob,
            2,
            CURRENCY_ETH,
            total,
            seller,
            total,
            address(0),
            0
        );
        vm.prank(alice);
        fixedSale.purchase{ value: total }(
            _p(saleId, 0, bob, 2, 0, 0), new bytes32[](0), _eth(alice, total)
        );
        assertEq(editions.balanceOf(bob, ZERO_ETH), 2);
        assertEq(seller.balance, total);
        assertEq(address(fixedSale).balance, 0);
        assertEq(escrow.totalOwed(CURRENCY_ETH), 0);
    }

    function test_ZeroFee_TokenSaleOpensAndSettles() public {
        uint256 saleId = _openPublic(ZERO_USD, 0);
        usd.mint(alice, 3 * USD_PRICE);
        vm.prank(alice);
        usd.approve(address(fixedSale), 3 * USD_PRICE);
        _purchase(
            alice, _p(saleId, 0, alice, 3, 0, 0), new bytes32[](0), _eth(alice, 3 * USD_PRICE)
        );
        assertEq(editions.balanceOf(alice, ZERO_USD), 3);
        assertEq(usd.balanceOf(seller), 3 * USD_PRICE);
        assertEq(usd.balanceOf(address(0)), 0);
        assertEq(usd.balanceOf(address(fixedSale)), 0);
    }

    function test_ZeroFee_ZeroPriceGiftOpensAndSettles() public {
        editions.setTerms(43, _zeroFee(CURRENCY_ETH, 0), SIZE);
        uint256 saleId = _openPublic(43, 1);
        vm.prank(stranger);
        fixedSale.purchase(_p(saleId, 0, bob, 1, 0, 0), new bytes32[](0), _eth(stranger, 0));
        assertEq(editions.balanceOf(bob, 43), 1);
    }

    function test_ZeroFee_NonZeroShareStillNeedsARecipient() public {
        PrimaryTerms memory t = _zeroFee(CURRENCY_ETH, PRICE);
        t.feeShare = 1;
        editions.setTerms(44, t, SIZE);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), 44)
        );
        _openPublic(44, 0);
    }

    function test_ZeroFee_FederatedZeroShareWithNoNetworkRecipient() public {
        MockFederationRegistry registry = new MockFederationRegistry();
        MockEditionTarget fed = new MockEditionTarget();
        fed.setAdmittedMinter(address(fixedSale), true);
        fed.setTerms(3, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, ""), SIZE);
        registry.setEntry(address(fed), 0, true);
        resolver.set(PRODUCT_FEDERATED, address(0), 0);
        vm.prank(admin);
        fixedSale.setFederationRegistry(address(0), address(registry));
        vm.prank(creator);
        uint256 saleId =
            fixedSale.openSale(address(fed), 3, _one(_phase(0, 0, false, false)), _noConsent());
        assertEq(_locked(saleId).feeRecipient, address(0));
        vm.deal(alice, PRICE);
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        assertEq(seller.balance, PRICE);
        assertEq(fed.balanceOf(alice, 3), 1);
    }
}
