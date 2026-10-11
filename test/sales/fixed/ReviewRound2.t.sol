// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_EDITIONS
} from "src/interfaces/types/EconomicsTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { FixedPriceSale } from "src/sales/FixedPriceSale.sol";
import { MintSaleBase } from "src/sales/MintSaleBase.sol";
import { MockFederationRegistry } from "../../mocks/sales/SaleMocks.sol";
import { FixedPriceBase } from "./FixedPriceBase.sol";

/// @notice Regressions from the PR #18 re-review: the typed `PhaseConfiguration` digest against
///         Foundry's independent EIP-712 encoder, consent non-reuse, priced leaves in zero-price
///         sales (inverted finding), the permissionless-close window, the resolver kept off the
///         purchase path and unable to substitute a named currency, and the allowlist install
///         checks.
contract ReviewRound2Test is FixedPriceBase {
    // ------------------------------------------------------------------ EIP-712 typed array

    function _json(
        address token,
        uint256 id,
        address currency,
        uint256 packagePrice,
        uint256 nonce,
        uint64 deadline
    ) internal view returns (string memory) {
        string memory types = string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},',
            '{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],',
            '"PhaseConfiguration":[{"name":"token","type":"address"},{"name":"id","type":"uint256"},',
            '{"name":"currency","type":"address"},{"name":"packagePrice","type":"uint256"},',
            '{"name":"phases","type":"Phase[]"},{"name":"nonce","type":"uint256"},',
            '{"name":"deadline","type":"uint64"}],',
            '"Phase":[{"name":"start","type":"uint64"},{"name":"end","type":"uint64"},',
            '{"name":"root","type":"bytes32"},{"name":"walletCap","type":"uint32"},',
            '{"name":"payerKeyed","type":"bool"},{"name":"leafPriced","type":"bool"}]},'
        );
        string memory domain = string.concat(
            '"primaryType":"PhaseConfiguration","domain":{"name":"6529 Works Fixed Price Sale",',
            '"version":"1","chainId":',
            vm.toString(block.chainid),
            ',"verifyingContract":"',
            vm.toString(address(fixedSale)),
            '"},'
        );
        string memory message = string.concat(
            '"message":{"token":"',
            vm.toString(token),
            '","id":',
            vm.toString(id),
            ',"currency":"',
            vm.toString(currency),
            '","packagePrice":',
            vm.toString(packagePrice),
            ',"phases":[',
            '{"start":1,"end":18446744073709551615,"root":"0x',
            "6100000000000000000000000000000000000000000000000000000000000000",
            '","walletCap":4294967295,"payerKeyed":true,"leafPriced":true},',
            '{"start":4,"end":5,"root":"0x0000000000000000000000000000000000000000000000000000000000000000",',
            '"walletCap":6,"payerKeyed":false,"leafPriced":false},',
            '{"start":7,"end":8,"root":"0x',
            "ff00000000000000000000000000000000000000000000000000000000000001",
            '","walletCap":0,"payerKeyed":false,"leafPriced":true}',
            '],"nonce":',
            vm.toString(nonce),
            ',"deadline":',
            vm.toString(uint256(deadline)),
            "}}"
        );
        return string.concat(types, domain, message);
    }

    /// @dev The typed `Phase[]` digest matches Foundry's independent EIP-712 encoder (three
    ///      phases, maximum-width fields, every flag combination).
    function test_R2_PhaseConfigurationDigest_MatchesCheatcode() public view {
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](3);
        phases[0] = IFixedPriceSale.Phase(
            1, type(uint64).max, bytes32("a"), type(uint32).max, true, true
        );
        phases[1] = IFixedPriceSale.Phase(4, 5, 0, 6, false, false);
        phases[2] = IFixedPriceSale.Phase(
            7,
            8,
            bytes32(0xff00000000000000000000000000000000000000000000000000000000000001),
            0,
            false,
            true
        );
        bytes32 expected = vm.eip712HashTypedData(
            _json(address(editions), ETH_ED, address(usd), 7e18, 5, type(uint64).max)
        );
        assertEq(
            fixedSale.phaseConfigurationDigest(
                address(editions), ETH_ED, address(usd), 7e18, phases, 5, type(uint64).max
            ),
            expected
        );
    }

    // ------------------------------------------------------------------ consent reuse

    function _discountTree(uint256 id) internal view returns (bytes32[] memory) {
        return _leaves(id, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(1, 1, 1));
    }

    function test_R2_ConsentNotReusableUnderAnotherCurrencyOrPrice() public {
        IFixedPriceSale.Phase[] memory phases =
            _one(_phase(_root(_discountTree(ETH_ED)), 0, false, true));
        uint64 deadline = uint64(block.timestamp + 1 days);
        IFixedPriceSale.ArtistConsent memory c = _consent(creatorKey, ETH_ED, phases, 1, deadline);

        // Currency switched to USD at the same nominal price.
        editions.setCurrency(ETH_ED, address(usd));
        vm.expectRevert(IFixedPriceSale.InvalidArtistConsent.selector);
        vm.prank(platform);
        fixedSale.openSale(address(editions), ETH_ED, phases, c);

        // Price changed, currency back.
        editions.setTerms(ETH_ED, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE * 2, ""), SIZE);
        vm.expectRevert(IFixedPriceSale.InvalidArtistConsent.selector);
        vm.prank(platform);
        fixedSale.openSale(address(editions), ETH_ED, phases, c);

        // Another ID with identical terms.
        editions.setTerms(77, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, ""), SIZE);
        vm.expectRevert(IFixedPriceSale.InvalidArtistConsent.selector);
        vm.prank(platform);
        fixedSale.openSale(address(editions), 77, phases, c);

        // Restored terms: the original consent works once.
        editions.setTerms(ETH_ED, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, ""), SIZE);
        vm.prank(platform);
        fixedSale.openSale(address(editions), ETH_ED, phases, c);
    }

    function test_R2_GiftConsentBindsTheResolvedDefault() public {
        uint256 id = 90;
        editions.setTerms(id, _terms(SaleKind.FIXED_PRICE, CURRENCY_DEFAULT, 0, ""), SIZE);
        allowlist.setDefault(PRODUCT_EDITIONS, CURRENCY_ETH);
        IFixedPriceSale.Phase[] memory phases = _one(_phase(bytes32("r"), 0, false, true));
        IFixedPriceSale.ArtistConsent memory c =
            _consent(creatorKey, id, phases, 1, uint64(block.timestamp + 1 days));
        allowlist.setDefault(PRODUCT_EDITIONS, address(usd));
        vm.expectRevert(IFixedPriceSale.InvalidArtistConsent.selector);
        vm.prank(platform);
        fixedSale.openSale(address(editions), id, phases, c);
    }

    // ------------------------------------------------------------------ priced leaves, gift sale

    /// @dev Inverted finding: PLATFORM alone cannot price the leaves of a zero-price (default
    ///      currency) sale; the creator, or the creator's signed consent, can.
    function test_R2_Inverted_PricedLeavesInAZeroPriceSaleNeedTheArtist() public {
        uint256 id = 91;
        editions.setTerms(id, _terms(SaleKind.FIXED_PRICE, CURRENCY_DEFAULT, 0, ""), SIZE);
        bytes32[] memory leaves = _leaves(
            id, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(0.05e18, 0.05e18, 0.05e18)
        );
        allowlist.setDefault(PRODUCT_EDITIONS, address(usd));
        IFixedPriceSale.Phase[] memory phases = _one(_phase(_root(leaves), 0, false, true));
        vm.expectRevert(
            abi.encodeWithSelector(
                FixedPriceSale.PricedLeavesNeedApproval.selector, address(editions), id
            )
        );
        _open(platform, id, phases);

        // With the creator's consent, signed at the resolved currency, the sale opens approved.
        IFixedPriceSale.ArtistConsent memory c =
            _consent(creatorKey, id, phases, 1, uint64(block.timestamp + 1 days));
        vm.prank(platform);
        uint256 saleId = fixedSale.openSale(address(editions), id, phases, c);
        assertTrue(_approved(saleId));
        assertEq(_locked(saleId).currency, address(usd));
        usd.mint(alice, 1e18);
        vm.prank(alice);
        usd.approve(address(fixedSale), type(uint256).max);
        _purchase(
            alice, _p(saleId, 0, alice, 1, 1, 0.05e18), _proof(leaves, 0), _eth(alice, 0.05e18)
        );
        assertEq(usd.balanceOf(seller) + usd.balanceOf(network), 0.05e18);

        // The creator opening it directly is approval too.
        vm.prank(creator);
        fixedSale.closeSale(saleId);
        uint256 again = _open(creator, id, phases);
        assertTrue(_approved(again));
    }

    function test_R2_UnpricedLeavesInAZeroPriceSaleNeedNoApproval() public {
        uint256 id = 92;
        editions.setTerms(id, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, 0, ""), SIZE);
        bytes32[] memory leaves =
            _leaves(id, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(0, 0, 0));
        uint256 saleId = _open(platform, id, _one(_phase(_root(leaves), 0, false, false)));
        assertFalse(_approved(saleId));
        _purchase(alice, _p(saleId, 0, alice, 1, 1, 0), _proof(leaves, 0), _eth(alice, 0));
        assertEq(editions.balanceOf(alice, id), 1);
    }

    // ------------------------------------------------------------------ permissionless close

    function test_R2_Close_OpenEndedAndFuturePhasesBlockStrangers() public {
        uint64 t = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](2);
        phases[0] = IFixedPriceSale.Phase(t, t + 10, 0, 0, false, false);
        phases[1] = IFixedPriceSale.Phase(t + 1000, type(uint64).max, 0, 0, false, false);
        uint256 saleId = _open(creator, ETH_ED, phases);
        vm.warp(t + 500); // between phases: phase 1 has not started
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, stranger));
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
        vm.warp(type(uint64).max - 1); // an open-ended phase never ends
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, stranger));
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
    }

    /// @dev At exactly `end`, purchases stop and anyone may close: the two predicates agree.
    function test_R2_Close_BoundaryAgreesWithPurchaseWindow() public {
        uint64 t = uint64(block.timestamp);
        uint256 saleId =
            _open(creator, ETH_ED, _one(IFixedPriceSale.Phase(t, t + 10, 0, 0, false, false)));
        vm.warp(t + 9);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, stranger));
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
        _buyEth(alice, saleId, 0, alice, 1, PRICE);
        vm.warp(t + 10);
        vm.deal(alice, PRICE);
        vm.expectRevert(abi.encodeWithSelector(IFixedPriceSale.PhaseNotOpen.selector, saleId, 0));
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
        vm.expectRevert(abi.encodeWithSelector(MintSaleBase.SaleAlreadyClosed.selector, saleId));
        vm.prank(platform);
        fixedSale.closeSale(saleId);
        // A stranger cannot reopen, and caps carry over.
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, stranger));
        _open(stranger, ETH_ED, _one(_phase(0, 0, false, false)));
        assertEq(_bought(saleId, 0, alice), 1);
    }

    // ------------------------------------------------------------------ resolver

    /// @dev The resolver is read only at open: a resolver that reverts afterwards blocks no
    ///      purchase.
    function test_R2_Resolver_NotOnPurchasePath() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        vm.mockCallRevert(
            address(resolver),
            abi.encodeWithSelector(IEconomicsResolver.resolveCurrency.selector),
            "x"
        );
        vm.mockCallRevert(
            address(resolver),
            abi.encodeWithSelector(IEconomicsResolver.networkFeeRecipient.selector),
            "x"
        );
        _buyEth(alice, saleId, 0, alice, 1, PRICE);
        assertEq(editions.balanceOf(alice, ETH_ED), 1);
    }

    /// @dev Inverted nit: a resolver that substitutes an explicitly named currency is refused.
    function test_R2_Inverted_ResolverCannotSubstituteANamedCurrency() public {
        vm.mockCall(
            address(resolver),
            abi.encodeCall(IEconomicsResolver.resolveCurrency, (PRODUCT_EDITIONS, CURRENCY_ETH)),
            abi.encode(address(usd))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                MintSaleBase.CurrencyMismatch.selector, CURRENCY_ETH, address(usd)
            )
        );
        _openPublic(ETH_ED, 0);
    }

    // ------------------------------------------------------------------ allowlist install checks

    function test_R2_Constructor_ChecksTheResolversAllowlist() public {
        (IRevenueEscrow e, ISignatureTransfer p, IEconomicsResolver r) = _deps();
        address delegated = makeAddr("delegatedAllowlist");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(allowlist)));
        // No code, an EIP-7702 account, and an ERC-165 contract that is not an allowlist.
        address[3] memory unfit =
            [makeAddr("eoaAllowlist"), delegated, address(new MockFederationRegistry())];
        for (uint256 i; i < unfit.length; ++i) {
            resolver.setAllowlistOverride(unfit[i]);
            vm.expectRevert(
                abi.encodeWithSelector(MintSaleBase.InvalidDependency.selector, unfit[i])
            );
            new FixedPriceSale(address(manager), e, p, r);
        }
        // The economics lane's allowlist answers no ERC-165 and is accepted on code alone.
        resolver.setAllowlistOverride(address(0));
        assertEq(
            address(new FixedPriceSale(address(manager), e, p, r).assets()), address(allowlist)
        );
    }
}
