// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_FEDERATED
} from "src/interfaces/types/EconomicsTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { MintSaleBase } from "src/sales/MintSaleBase.sol";
import { MockERC20 } from "../../mocks/EconomicsMocks.sol";
import { MockEditionTarget, MockFederationRegistry } from "../../mocks/sales/SaleMocks.sol";
import { FixedPriceBase } from "./FixedPriceBase.sol";

/// @notice Federation readiness (integrator decision D21), through the fixed-price adapter: the
///         governed compare-and-set registry with ERC-165, EIP-7702 and code-hash pinning, targets
///         served through the registry, and the registry entry's network fee share.
contract FederationRegistryTest is FixedPriceBase {
    uint256 internal constant FED_ID = 3;
    uint32 internal constant FED_FEE = 10_000;

    MockFederationRegistry internal registry;
    MockEditionTarget internal fed;

    function setUp() public override {
        super.setUp();
        registry = new MockFederationRegistry();
        fed = new MockEditionTarget();
        fed.setAdmittedMinter(address(fixedSale), true);
        fed.setTerms(FED_ID, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, ""), SIZE);
    }

    function _install() internal {
        vm.prank(admin);
        fixedSale.setFederationRegistry(address(0), address(registry));
    }

    function test_SetFederationRegistry_InstallsPinsAndEmits() public {
        vm.expectEmit(address(fixedSale));
        emit ISaleAdapter.FederationRegistrySet(address(0), address(registry));
        _install();
        assertEq(fixedSale.federationRegistry(), address(registry));
        assertEq(fixedSale.federationRegistryCodeHash(), address(registry).codehash);
        // Removal is the same compare-and-set.
        vm.prank(admin);
        fixedSale.setFederationRegistry(address(registry), address(0));
        assertEq(fixedSale.federationRegistry(), address(0));
        assertEq(fixedSale.federationRegistryCodeHash(), bytes32(0));
    }

    function test_SetFederationRegistry_IsGovernedAndCompareAndSet() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, platform)
        );
        vm.prank(platform);
        fixedSale.setFederationRegistry(address(0), address(registry));
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        vm.prank(admin);
        fixedSale.setFederationRegistry(address(1), address(registry));
    }

    function test_SetFederationRegistry_RejectsUnfitRegistries() public {
        address delegated = makeAddr("delegatedEoa");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(registry)));
        address[3] memory unfit = [makeAddr("eoa"), address(new MockERC20("X", "X")), delegated];
        for (uint256 i; i < unfit.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(MintSaleBase.InvalidDependency.selector, unfit[i])
            );
            vm.prank(admin);
            fixedSale.setFederationRegistry(address(0), unfit[i]);
        }
    }

    function test_IsTarget_FollowsTheRegistry() public {
        assertFalse(fixedSale.isTarget(address(fed)));
        registry.setEntry(address(fed), FED_FEE, true);
        assertFalse(fixedSale.isTarget(address(fed)));
        _install();
        assertTrue(fixedSale.isTarget(address(fed)));
        assertFalse(fixedSale.isListed(address(fed)));
        registry.setEntry(address(fed), FED_FEE, false);
        assertFalse(fixedSale.isTarget(address(fed)));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fed))
        );
        vm.prank(creator);
        fixedSale.openSale(address(fed), FED_ID, _one(_phase(0, 0, false, false)), _noConsent());
    }

    function test_IsTarget_IgnoresARegistryWhoseCodeChanged() public {
        registry.setEntry(address(fed), FED_FEE, true);
        _install();
        assertTrue(fixedSale.isTarget(address(fed)));
        // Same behaviour, different code: the pinned hash no longer matches.
        vm.etch(address(registry), bytes.concat(address(registry).code, hex"00"));
        assertTrue(registry.isActive(address(fed)));
        assertFalse(fixedSale.isTarget(address(fed)));
    }

    function test_FederatedSale_PaysTheRegistryFeeShare() public {
        registry.setEntry(address(fed), FED_FEE, true);
        _install();
        vm.prank(creator);
        uint256 saleId = fixedSale.openSale(
            address(fed), FED_ID, _one(_phase(0, 0, false, false)), _noConsent()
        );
        assertEq(_locked(saleId).feeShare, FED_FEE);
        vm.deal(alice, PRICE);
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        // The registry sets the share; the economics resolver names the network recipient.
        assertEq(_locked(saleId).feeRecipient, federatedNetwork);
        assertEq(federatedNetwork.balance, PRICE * FED_FEE / 100_000);
        assertEq(network.balance, 0);
        assertEq(seller.balance, PRICE - PRICE * FED_FEE / 100_000);
        assertEq(fed.balanceOf(alice, FED_ID), 1);
    }

    function test_FederatedSale_ResolvesTheFederatedDefaultCurrency() public {
        // A federated gift (zero price) may leave its currency to the federated default.
        fed.setTerms(FED_ID, _terms(SaleKind.FIXED_PRICE, CURRENCY_DEFAULT, 0, ""), SIZE);
        registry.setEntry(address(fed), FED_FEE, true);
        _install();
        allowlist.setDefault(PRODUCT_FEDERATED, address(usd));
        vm.prank(creator);
        uint256 saleId = fixedSale.openSale(
            address(fed), FED_ID, _one(_phase(0, 0, false, false)), _noConsent()
        );
        assertEq(_locked(saleId).currency, address(usd));
    }

    function test_FederatedSale_FailsClosedWithoutResolverEconomics() public {
        registry.setEntry(address(fed), FED_FEE, true);
        _install();
        resolver.unset(PRODUCT_FEDERATED);
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.UnknownProduct.selector, PRODUCT_FEDERATED)
        );
        vm.prank(creator);
        fixedSale.openSale(address(fed), FED_ID, _one(_phase(0, 0, false, false)), _noConsent());
    }

    function test_ListedTokenKeepsItsOwnFee() public {
        registry.setEntry(address(editions), FED_FEE, true);
        _install();
        uint256 saleId = _openPublic(ETH_ED, 0);
        assertEq(_locked(saleId).feeShare, FEE_SHARE);
        assertEq(_locked(saleId).feeRecipient, network);
    }
}
