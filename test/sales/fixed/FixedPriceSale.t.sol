// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_EDITIONS
} from "src/interfaces/types/EconomicsTypes.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import {
    DutchParams,
    LockedTerms,
    PrimaryTerms,
    SaleKind
} from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { FixedPriceSale } from "src/sales/FixedPriceSale.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { MintSaleBase } from "src/sales/MintSaleBase.sol";
import { Mock1271Account } from "../../mocks/EconomicsMocks.sol";
import { MockAssetAllowlist, MockEditionTarget } from "../../mocks/sales/SaleMocks.sol";
import { FixedPriceBase } from "./FixedPriceBase.sol";

/// @notice Unit tests of the fixed-price adapter: configuration, opening, artist approval,
///         closing, purchases, allowlists (including the PR #744 recipient-binding regression)
///         and caps.
contract FixedPriceSaleTest is FixedPriceBase {
    uint256 internal constant A_PRICE = 0.04 ether;
    uint256 internal constant B_PRICE = 0.02 ether;

    // ------------------------------------------------------------------ configuration

    function test_Constructor_RevertsOnMissingOrUnfitDependency() public {
        (IRevenueEscrow e, ISignatureTransfer p, IEconomicsResolver r) = _deps();
        vm.expectRevert(MintSaleBase.InvalidAddress.selector);
        new FixedPriceSale(address(manager), IRevenueEscrow(address(0)), p, r);
        vm.expectRevert(MintSaleBase.InvalidAddress.selector);
        new FixedPriceSale(address(manager), e, ISignatureTransfer(address(0)), r);
        // The resolver must be a contract supporting IEconomicsResolver through ERC-165.
        address[3] memory unfit = [address(0), makeAddr("eoa"), address(usd)];
        for (uint256 i; i < unfit.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(MintSaleBase.InvalidDependency.selector, unfit[i])
            );
            new FixedPriceSale(address(manager), e, p, IEconomicsResolver(unfit[i]));
        }
    }

    function test_ConstantsAndTypehashes() public view {
        assertEq(fixedSale.saleKind(), keccak256("FIXED_PRICE"));
        assertEq(fixedSale.ALLOWLIST_LEAF_DOMAIN(), keccak256("6529WORKS_ALLOWLIST_LEAF_V1"));
        assertEq(
            Typehashes.PHASE,
            keccak256(
                "Phase(uint64 start,uint64 end,bytes32 root,uint32 walletCap,bool payerKeyed,bool leafPriced)"
            )
        );
        assertEq(
            Typehashes.PHASE_CONFIGURATION,
            keccak256(
                "PhaseConfiguration(address token,uint256 id,address currency,uint256 packagePrice,Phase[] phases,uint256 nonce,uint64 deadline)Phase(uint64 start,uint64 end,bytes32 root,uint32 walletCap,bool payerKeyed,bool leafPriced)"
            )
        );
        assertEq(
            Typehashes.PURCHASE_WITNESS,
            keccak256(
                "Purchase(uint256 saleId,uint256 phase,address recipient,uint256 quantity,uint256 amount,uint256 deadline)"
            )
        );
        assertEq(
            Typehashes.PURCHASE_WITNESS_TYPE,
            "Purchase witness)Purchase(uint256 saleId,uint256 phase,address recipient,uint256 quantity,uint256 amount,uint256 deadline)TokenPermissions(address token,uint256 amount)"
        );
        (, string memory name, string memory version, uint256 chainId, address verifying,,) =
            fixedSale.eip712Domain();
        assertEq(name, "6529 Works Fixed Price Sale");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(fixedSale));
        assertEq(fixedSale.ETH_PAYOUT_GAS(), 100_000);
        assertEq(address(fixedSale.escrow()), address(escrow));
        assertEq(address(fixedSale.assets()), address(allowlist));
        assertFalse(fixedSale.paused());
        assertEq(address(fixedSale.permit2()), address(permit2));
        assertEq(address(fixedSale.economicsResolver()), address(resolver));
        assertEq(fixedSale.nextSaleId(), 1);
        assertEq(fixedSale.federationRegistry(), address(0));
        assertTrue(fixedSale.isTarget(address(editions)));
        assertTrue(fixedSale.isListed(address(editions)));
    }

    function test_SupportsInterface() public view {
        assertTrue(fixedSale.supportsInterface(type(IERC165).interfaceId));
        assertTrue(fixedSale.supportsInterface(type(ISaleAdapter).interfaceId));
        assertTrue(fixedSale.supportsInterface(type(IFixedPriceSale).interfaceId));
        assertFalse(fixedSale.supportsInterface(0xffffffff));
    }

    function test_SetTarget_GovernedAndEmits() public {
        address other = makeAddr("otherToken");
        vm.expectEmit(address(fixedSale));
        emit ISaleAdapter.TargetSet(other, true);
        vm.prank(admin);
        fixedSale.setTarget(other, true);
        assertTrue(fixedSale.isTarget(other));
        vm.prank(admin);
        fixedSale.setTarget(other, false);
        assertFalse(fixedSale.isTarget(other));
    }

    function test_SetTarget_RevertsForUnauthorizedOrZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, platform)
        );
        vm.prank(platform);
        fixedSale.setTarget(address(1), true);
        vm.expectRevert(MintSaleBase.InvalidAddress.selector);
        vm.prank(admin);
        fixedSale.setTarget(address(0), true);
    }

    // ------------------------------------------------------------------ opening

    function test_OpenSale_ByCreatorLocksTermsAndEmits() public {
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](2);
        uint64 t = uint64(block.timestamp);
        phases[0] = IFixedPriceSale.Phase(t + 10, t + 100, bytes32(uint256(1)), 0, false, true);
        phases[1] = IFixedPriceSale.Phase(t + 50, t + 500, 0, 3, false, false);
        vm.expectEmit(address(fixedSale));
        emit ISaleAdapter.SaleStarted(
            1, address(editions), ETH_ED, SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, t + 10, t + 500
        );
        vm.expectEmit(address(fixedSale));
        emit IFixedPriceSale.PhasesSet(1, phases, true);
        uint256 saleId = _open(creator, ETH_ED, phases);

        assertEq(saleId, 1);
        assertEq(fixedSale.nextSaleId(), 2);
        assertEq(fixedSale.openSaleOf(address(editions), ETH_ED), 1);
        (LockedTerms memory s, bool approved, bool closed) = fixedSale.sale(saleId);
        assertEq(s.token, address(editions));
        assertEq(s.id, ETH_ED);
        assertEq(s.currency, CURRENCY_ETH);
        assertEq(s.price, PRICE);
        assertEq(s.seller, seller);
        assertEq(s.feeRecipient, network);
        assertEq(s.feeShare, FEE_SHARE);
        assertTrue(approved);
        assertFalse(closed);
        assertEq(keccak256(abi.encode(fixedSale.phases(saleId))), keccak256(abi.encode(phases)));
    }

    function test_OpenSale_ByPlatformIsNotArtistApproved() public {
        uint256 saleId = _open(platform, ETH_ED, _one(_phase(0, 2, false, false)));
        assertFalse(_approved(saleId));
    }

    function test_OpenSale_RevertsForStrangerAndDelayedPlatform() public {
        IFixedPriceSale.Phase[] memory phases = _one(_phase(0, 0, false, false));
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, stranger));
        _open(stranger, ETH_ED, phases);

        // A PLATFORM member with an execution delay may not act immediately.
        address slow = makeAddr("slowPlatform");
        vm.prank(admin);
        manager.grantRole(PLATFORM_ROLE, slow, 1 days);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, slow));
        _open(slow, ETH_ED, phases);
    }

    function test_OpenSale_OneOpenSalePerEdition() public {
        uint256 first = _openPublic(ETH_ED, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.SaleAlreadyOpen.selector, address(editions), ETH_ED)
        );
        _openPublic(ETH_ED, 0);
        // Another edition is independent; closing frees the edition.
        _openPublic(USD_ED, 0);
        vm.prank(creator);
        fixedSale.closeSale(first);
        assertEq(fixedSale.openSaleOf(address(editions), ETH_ED), 0);
        uint256 second = _openPublic(ETH_ED, 0);
        assertEq(fixedSale.openSaleOf(address(editions), ETH_ED), second);
    }

    function test_OpenSale_RevertsOnUnadmittedTarget() public {
        vm.prank(admin);
        fixedSale.setTarget(address(editions), false);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(editions))
        );
        _openPublic(ETH_ED, 0);
    }

    function test_OpenSale_RevertsOnSaleKindMismatch() public {
        editions.setTerms(
            9, _terms(SaleKind.DUTCH, CURRENCY_ETH, PRICE, abi.encode(DutchParams(0, 100, 0))), SIZE
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector, SaleKind.FIXED_PRICE, SaleKind.DUTCH
            )
        );
        _openPublic(9, 0);
    }

    function test_OpenSale_RevertsOnInactiveCurrency() public {
        allowlist.set(address(usd), false);
        vm.expectRevert(
            abi.encodeWithSelector(IEconomicsResolver.CurrencyNotAllowed.selector, address(usd))
        );
        _openPublic(USD_ED, 0);
    }

    function test_OpenSale_RevertsOnUnusableTerms() public {
        for (uint256 i; i < 3; ++i) {
            PrimaryTerms memory t = _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, "");
            if (i == 0) t.seller = address(0);
            if (i == 1) t.feeRecipient = address(0);
            if (i == 2) t.feeShare = 100_001;
            editions.setTerms(20 + i, t, SIZE);
            vm.expectRevert(
                abi.encodeWithSelector(
                    MintSaleBase.InvalidSaleTerms.selector, address(editions), 20 + i
                )
            );
            _openPublic(20 + i, 0);
        }
    }

    function test_OpenSale_RevertsOnInvalidPhases() public {
        IFixedPriceSale.Phase[] memory tooMany = new IFixedPriceSale.Phase[](17);
        IFixedPriceSale.Phase[] memory sixteen = new IFixedPriceSale.Phase[](16);
        for (uint256 i; i < 17; ++i) {
            tooMany[i] = _phase(0, 0, false, false);
            if (i < 16) sixteen[i] = tooMany[i];
        }
        IFixedPriceSale.Phase memory empty = _phase(0, 0, false, false);
        empty.end = empty.start;
        IFixedPriceSale.Phase[4] memory bad = [
            empty, _phase(0, 0, true, false), _phase(0, 0, false, true), _phase(0, 0, true, true)
        ];
        vm.expectRevert(FixedPriceSale.InvalidPhases.selector);
        _open(creator, ETH_ED, new IFixedPriceSale.Phase[](0));
        vm.expectRevert(FixedPriceSale.InvalidPhases.selector);
        _open(creator, ETH_ED, tooMany);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(FixedPriceSale.InvalidPhases.selector);
            _open(creator, ETH_ED, _one(bad[i]));
        }
        // Sixteen phases are accepted.
        _open(creator, ETH_ED, sixteen);
    }

    // ------------------------------------------------------------------ artist approval

    /// @dev Priced leaves for alice (cap 2, 0.04 ether, below the package price) and bob (cap 1,
    ///      0.2 ether, above it).
    function _pricedLeaves() internal view returns (bytes32[] memory) {
        return _leaves(
            ETH_ED, 0, _list3(alice, bob, creator), _nums3(2, 1, 1), _nums3(A_PRICE, 0.2 ether, 0)
        );
    }

    /// @dev The PLATFORM role opens one priced phase over `leaves` (no external call before it).
    function _platformPriced(bytes32[] memory leaves, IFixedPriceSale.ArtistConsent memory consent)
        internal
        returns (uint256 saleId)
    {
        vm.prank(platform);
        saleId = fixedSale.openSale(
            address(editions), ETH_ED, _one(_phase(_root(leaves), 0, false, true)), consent
        );
    }

    function test_Approval_PlatformSaleRejectsDiscountsButNotPremiums() public {
        bytes32[] memory leaves = _pricedLeaves();
        uint256 saleId = _platformPriced(leaves, _noConsent());
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.PriceBelowPackage.selector, A_PRICE, PRICE)
        );
        _purchaseEth(alice, _p(saleId, 0, alice, 1, 2, A_PRICE), _proof(leaves, 0), A_PRICE);
        _purchaseEth(bob, _p(saleId, 0, bob, 1, 1, 0.2 ether), _proof(leaves, 1), 0.2 ether);
        assertEq(editions.balanceOf(bob, ETH_ED), 1);
    }

    function test_Approval_CreatorSignatureAllowsDiscounts() public {
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        bytes32[] memory leaves = _pricedLeaves();
        phases[0] = _phase(_root(leaves), 0, false, true);
        IFixedPriceSale.ArtistConsent memory consent =
            _consent(creatorKey, ETH_ED, phases, 7, uint64(block.timestamp + 1 hours));
        vm.expectEmit(address(fixedSale));
        emit IFixedPriceSale.PhasesSet(1, phases, true);
        uint256 saleId = _platformPriced(leaves, consent);
        assertTrue(_approved(saleId));
        assertTrue(fixedSale.isConsentNonceUsed(creator, 7));
        vm.deal(alice, 1 ether);
        _purchaseEth(alice, _p(saleId, 0, alice, 2, 2, A_PRICE), _proof(leaves, 0), 2 * A_PRICE);
        assertEq(seller.balance + network.balance, 2 * A_PRICE);
    }

    function test_Approval_RevertsOnInvalidConsent() public {
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        bytes32[] memory leaves = _pricedLeaves();
        phases[0] = _phase(_root(leaves), 0, false, true);
        IFixedPriceSale.Phase[] memory other = _one(_phase(bytes32("other"), 0, false, true));
        uint64 deadline = uint64(block.timestamp + 1 hours);
        IFixedPriceSale.ArtistConsent[4] memory bad = [
            _consent(aliceKey, ETH_ED, phases, 1, deadline), // not the creator
            _consent(creatorKey, ETH_ED, other, 1, deadline), // other phases
            _consent(creatorKey, USD_ED, phases, 1, deadline), // other edition
            _consent(creatorKey, ETH_ED, phases, 1, deadline - 1) // signed for another deadline
        ];
        bad[3].deadline = deadline;
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IFixedPriceSale.InvalidArtistConsent.selector);
            _platformPriced(leaves, bad[i]);
        }
        // Expired.
        IFixedPriceSale.ArtistConsent memory valid =
            _consent(creatorKey, ETH_ED, phases, 1, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(IFixedPriceSale.InvalidArtistConsent.selector);
        vm.prank(platform);
        fixedSale.openSale(address(editions), ETH_ED, phases, valid);
    }

    function test_Approval_NonceIsSingleUseAndRevocable() public {
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        bytes32[] memory leaves = _pricedLeaves();
        phases[0] = _phase(_root(leaves), 0, false, true);
        uint64 deadline = uint64(block.timestamp + 1 hours);
        IFixedPriceSale.ArtistConsent memory consent =
            _consent(creatorKey, ETH_ED, phases, 1, deadline);
        uint256 saleId = _platformPriced(leaves, consent);
        vm.prank(platform);
        fixedSale.closeSale(saleId);
        // Replaying the same approval for a new sale fails: the nonce is spent.
        vm.expectRevert(IFixedPriceSale.InvalidArtistConsent.selector);
        _platformPriced(leaves, consent);

        // A revoked nonce can never be used.
        IFixedPriceSale.ArtistConsent memory second =
            _consent(creatorKey, ETH_ED, phases, 2, deadline);
        vm.expectEmit(address(fixedSale));
        emit IFixedPriceSale.ConsentNonceRevoked(creator, 2);
        vm.prank(creator);
        fixedSale.revokeConsentNonce(2);
        assertTrue(fixedSale.isConsentNonceUsed(creator, 2));
        vm.expectRevert(IFixedPriceSale.InvalidArtistConsent.selector);
        vm.prank(creator);
        fixedSale.revokeConsentNonce(2);
        vm.expectRevert(IFixedPriceSale.InvalidArtistConsent.selector);
        _platformPriced(leaves, second);
    }

    function test_Approval_ContractCreatorSignsByErc1271() public {
        Mock1271Account safe = new Mock1271Account();
        editions.setCreator(ETH_ED, address(safe));
        IFixedPriceSale.Phase[] memory phases = _one(_phase(bytes32("r"), 0, false, true));
        uint64 deadline = uint64(block.timestamp + 1 hours);
        safe.accept(
            fixedSale.phaseConfigurationDigest(
                address(editions), ETH_ED, CURRENCY_ETH, PRICE, phases, 3, deadline
            )
        );
        vm.prank(platform);
        uint256 saleId = fixedSale.openSale(
            address(editions), ETH_ED, phases, IFixedPriceSale.ArtistConsent(3, deadline, hex"01")
        );
        assertTrue(_approved(saleId));
        assertTrue(fixedSale.isConsentNonceUsed(address(safe), 3));
    }

    // ------------------------------------------------------------------ closing

    function test_CloseSale_ByCreatorOrPlatformStopsPurchases() public {
        uint256 first = _openPublic(ETH_ED, 0);
        uint256 second = _openPublic(USD_ED, 0);
        vm.expectEmit(address(fixedSale));
        emit IFixedPriceSale.SaleClosed(first);
        vm.prank(creator);
        fixedSale.closeSale(first);
        vm.prank(platform);
        fixedSale.closeSale(second);
        assertTrue(_closed(first));
        assertTrue(_closed(second));
        vm.deal(alice, PRICE);
        vm.expectRevert(abi.encodeWithSelector(IFixedPriceSale.PhaseNotOpen.selector, first, 0));
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(first, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
    }

    function test_CloseSale_FollowsTheCurrentCreator() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        editions.setCreator(ETH_ED, bob);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, creator));
        vm.prank(creator);
        fixedSale.closeSale(saleId);
        vm.prank(bob);
        fixedSale.closeSale(saleId);
        assertTrue(_closed(saleId));
    }

    function test_CloseSale_RevertsWhenAlreadyClosed() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        vm.prank(creator);
        fixedSale.closeSale(saleId);
        vm.expectRevert(abi.encodeWithSelector(MintSaleBase.SaleAlreadyClosed.selector, saleId));
        vm.prank(platform);
        fixedSale.closeSale(saleId);
    }

    function test_CloseSale_RevertsForStrangerOrUnknown() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, stranger));
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, 99));
        vm.prank(platform);
        fixedSale.closeSale(99);
    }

    function test_Views_RevertOnUnknownSale() public {
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, 1));
        fixedSale.sale(1);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, 1));
        fixedSale.phases(1);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, 1));
        _bought(1, 0, alice);
    }

    // ------------------------------------------------------------------ purchases

    function test_Purchase_PaysSellerAndNetworkAndEmits() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        uint256 total = 3 * PRICE;
        vm.deal(alice, total);
        vm.expectEmit(address(fixedSale));
        emit ISaleAdapter.SaleSettled(
            saleId,
            address(editions),
            ETH_ED,
            alice,
            bob,
            3,
            CURRENCY_ETH,
            total,
            seller,
            total - _fee(total),
            network,
            _fee(total)
        );
        vm.prank(alice);
        fixedSale.purchase{ value: total }(
            _p(saleId, 0, bob, 3, 0, 0), new bytes32[](0), _eth(alice, total)
        );
        assertEq(editions.balanceOf(bob, ETH_ED), 3);
        assertEq(seller.balance, total - _fee(total));
        assertEq(network.balance, _fee(total));
        assertEq(address(fixedSale).balance, 0);
        assertEq(_bought(saleId, 0, bob), 3);
    }

    function test_Purchase_RecipientDefaultsToPayer() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        _buyEth(alice, saleId, 0, address(0), 2, PRICE);
        assertEq(editions.balanceOf(alice, ETH_ED), 2);
        assertEq(_bought(saleId, 0, alice), 2);
    }

    function test_Purchase_PhaseWindowIsHalfOpen() public {
        uint64 t = uint64(block.timestamp);
        uint256 saleId = _open(
            creator, ETH_ED, _one(IFixedPriceSale.Phase(t + 100, t + 200, 0, 0, false, false))
        );
        vm.deal(alice, 10 ether);
        vm.warp(t + 99);
        vm.expectRevert(abi.encodeWithSelector(IFixedPriceSale.PhaseNotOpen.selector, saleId, 0));
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        vm.warp(t + 100);
        _buyEth(alice, saleId, 0, alice, 1, PRICE);
        vm.warp(t + 199);
        _buyEth(alice, saleId, 0, alice, 1, PRICE);
        vm.warp(t + 200);
        vm.expectRevert(abi.encodeWithSelector(IFixedPriceSale.PhaseNotOpen.selector, saleId, 0));
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
    }

    function test_Purchase_RevertsOnUnknownSaleOrPhaseOrZeroQuantity() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFixedPriceSale.PhaseNotOpen.selector, 9, 0));
        fixedSale.purchase{ value: PRICE }(
            _p(9, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        vm.expectRevert(abi.encodeWithSelector(IFixedPriceSale.PhaseNotOpen.selector, saleId, 1));
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 1, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        vm.expectRevert(MintSaleBase.InvalidQuantity.selector);
        fixedSale.purchase(_p(saleId, 0, alice, 0, 0, 0), new bytes32[](0), _eth(alice, 0));
        vm.stopPrank();
    }

    function test_Purchase_RevertsOnPaymentMismatch() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        IFixedPriceSale.Purchase memory p = _p(saleId, 0, alice, 2, 0, 0);
        bytes32[] memory proof = new bytes32[](0);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        // The amount is not quantity times price.
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        fixedSale.purchase{ value: PRICE }(p, proof, _eth(alice, PRICE));
        // msg.value differs from the amount.
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        fixedSale.purchase{ value: PRICE }(p, proof, _eth(alice, 2 * PRICE));
        // The payer must be the sender for ETH.
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        fixedSale.purchase{ value: 2 * PRICE }(p, proof, _eth(bob, 2 * PRICE));
        vm.stopPrank();
    }

    function test_Purchase_SupplyComesFromTheToken() public {
        editions.setTerms(9, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, ""), 2);
        uint256 saleId = _openPublic(9, 0);
        _buyEth(alice, saleId, 0, alice, 2, PRICE);
        vm.deal(bob, PRICE);
        vm.expectRevert(abi.encodeWithSelector(MockEditionTarget.EditionUnavailable.selector, 9));
        vm.prank(bob);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, bob, 1, 0, 0), new bytes32[](0), _eth(bob, PRICE)
        );
    }

    function test_Purchase_RevertsWhenTheTokenMintsAnotherId() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        editions.setIdOffset(1);
        vm.deal(alice, PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MintSaleBase.InvalidSaleTerms.selector, address(editions), ETH_ED
            )
        );
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
    }

    function test_Purchase_CurrencyIsLockedAtOpen() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        // The token's currency changes after the sale opened: this sale still settles in ETH.
        editions.setCurrency(ETH_ED, address(usd));
        _buyEth(alice, saleId, 0, alice, 1, PRICE);
        assertEq(_locked(saleId).currency, CURRENCY_ETH);
        assertEq(seller.balance + network.balance, PRICE);
    }

    function test_Purchase_DeprecatingTheLockedCurrencyHaltsTheSale() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        allowlist.set(CURRENCY_ETH, false);
        vm.deal(alice, PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(MintSaleBase.CurrencyNotActive.selector, CURRENCY_ETH)
        );
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        // Re-admission resumes it.
        allowlist.set(CURRENCY_ETH, true);
        _buyEth(alice, saleId, 0, alice, 1, PRICE);
    }

    function test_OpenSale_PricedSalesMustNameTheirCurrency() public {
        editions.setTerms(9, _terms(SaleKind.FIXED_PRICE, CURRENCY_DEFAULT, USD_PRICE, ""), SIZE);
        allowlist.setDefault(PRODUCT_EDITIONS, address(usd));
        vm.expectRevert(
            abi.encodeWithSelector(
                MintSaleBase.PricedDefaultCurrency.selector, address(editions), 9
            )
        );
        _openPublic(9, 0);
    }

    function test_OpenSale_GiftResolvesTheDefaultCurrencyOnce() public {
        editions.setTerms(9, _terms(SaleKind.FIXED_PRICE, CURRENCY_DEFAULT, 0, ""), SIZE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockAssetAllowlist.CurrencyNotConfigured.selector, PRODUCT_EDITIONS
            )
        );
        _openPublic(9, 0);
        allowlist.setDefault(PRODUCT_EDITIONS, address(usd));
        vm.expectEmit(address(fixedSale));
        emit ISaleAdapter.SaleStarted(
            1,
            address(editions),
            9,
            SaleKind.FIXED_PRICE,
            address(usd),
            0,
            uint64(block.timestamp),
            uint64(block.timestamp) + DAY
        );
        uint256 saleId = _openPublic(9, 0);
        assertEq(_locked(saleId).currency, address(usd));
        // A later default change does not move the open sale.
        allowlist.setDefault(PRODUCT_EDITIONS, CURRENCY_ETH);
        vm.prank(alice);
        fixedSale.purchase(_p(saleId, 0, bob, 2, 0, 0), new bytes32[](0), _eth(alice, 0));
        assertEq(editions.balanceOf(bob, 9), 2);
    }

    function test_Purchase_ZeroPriceGift() public {
        editions.setTerms(9, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, 0, ""), SIZE);
        uint256 saleId = _openPublic(9, 2);
        vm.prank(stranger);
        fixedSale.purchase(_p(saleId, 0, bob, 2, 0, 0), new bytes32[](0), _eth(stranger, 0));
        assertEq(editions.balanceOf(bob, 9), 2);
        assertEq(seller.balance + network.balance + escrow.totalOwed(CURRENCY_ETH), 0);
    }

    function test_Purchase_FeeRoundsDownAndConserves() public {
        editions.setTerms(9, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, 3, ""), SIZE);
        uint256 saleId = _openPublic(9, 0);
        _buyEth(alice, saleId, 0, alice, 1, 3);
        assertEq(network.balance, 0);
        assertEq(seller.balance, 3);
        _buyEth(alice, saleId, 0, alice, 3, 3);
        assertEq(network.balance, 2);
        assertEq(seller.balance, 10);
    }

    function test_Claim_NothingToClaimOnFixedPrice() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.NothingToClaim.selector, alice, CURRENCY_ETH)
        );
        vm.prank(alice);
        fixedSale.claim(CURRENCY_ETH, alice);
        assertEq(fixedSale.claimable(alice, CURRENCY_ETH), 0);
        vm.expectRevert(MintSaleBase.InvalidAddress.selector);
        vm.prank(alice);
        fixedSale.claim(CURRENCY_ETH, address(0));
    }

    // ------------------------------------------------------------------ allowlists

    /// @dev Opens a creator-approved one-phase allowlist sale of the ETH edition: alice (cap 2,
    ///      0.04), bob (cap 1, 0.02), creator (cap 5, 0.1).
    function _openAllowlist(bool payerKeyed, bool leafPriced)
        internal
        returns (uint256 saleId, bytes32[] memory leaves)
    {
        leaves = _leaves(
            ETH_ED, 0, _list3(alice, bob, creator), _nums3(2, 1, 5), _nums3(A_PRICE, B_PRICE, PRICE)
        );
        saleId = _open(creator, ETH_ED, _one(_phase(_root(leaves), 0, payerKeyed, leafPriced)));
    }

    function test_AllowlistLeaf_MatchesTheDefinition() public view {
        bytes32 inner = keccak256(
            abi.encode(
                keccak256("6529WORKS_ALLOWLIST_LEAF_V1"),
                block.chainid,
                address(fixedSale),
                address(editions),
                ETH_ED,
                uint256(1),
                alice,
                uint256(2),
                A_PRICE
            )
        );
        assertEq(
            fixedSale.allowlistLeaf(address(editions), ETH_ED, 1, alice, 2, A_PRICE),
            keccak256(bytes.concat(inner))
        );
    }

    function test_Allowlist_RecipientKeyedAtLeafPrice() public {
        (uint256 saleId, bytes32[] memory leaves) = _openAllowlist(false, true);
        uint256 total = 2 * A_PRICE;
        vm.deal(alice, total);
        _purchaseEth(alice, _p(saleId, 0, alice, 2, 2, A_PRICE), _proof(leaves, 0), total);
        assertEq(editions.balanceOf(alice, ETH_ED), 2);
        assertEq(seller.balance + network.balance, total);
        assertEq(_bought(saleId, 0, alice), 2);
    }

    /// @notice Regression for PR #744's verified High finding: a recipient-keyed leaf was
    ///         checked against one address while the tokens were minted to another, so anyone
    ///         could spend another wallet's allowlist entry for themselves. Here the leaf is
    ///         checked against the wallet that receives the tokens.
    function test_Regression_PR744High_LeafBindsTheReceivingWallet() public {
        (uint256 saleId, bytes32[] memory leaves) = _openAllowlist(false, true);
        bytes32[] memory aliceProof = _proof(leaves, 0);
        uint256 total = 2 * A_PRICE;
        vm.deal(stranger, 10 ether);

        // Alice's leaf cannot mint to the attacker, explicitly or by the payer default.
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, saleId, 0, stranger)
        );
        _purchaseEth(stranger, _p(saleId, 0, stranger, 2, 2, A_PRICE), aliceProof, total);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, saleId, 0, stranger)
        );
        _purchaseEth(stranger, _p(saleId, 0, address(0), 2, 2, A_PRICE), aliceProof, total);

        // Paying for Alice delivers to Alice, and only Alice's allowance moves.
        _purchaseEth(stranger, _p(saleId, 0, alice, 2, 2, A_PRICE), aliceProof, total);
        assertEq(editions.balanceOf(alice, ETH_ED), 2);
        assertEq(editions.balanceOf(stranger, ETH_ED), 0);
        assertEq(_bought(saleId, 0, alice), 2);
        assertEq(_bought(saleId, 0, stranger), 0);
    }

    function test_Allowlist_PayerKeyedBindsThePayer() public {
        (uint256 saleId, bytes32[] memory leaves) = _openAllowlist(true, true);
        bytes32[] memory aliceProof = _proof(leaves, 0);
        uint256 total = A_PRICE;
        vm.deal(alice, total);
        // Alice's allowance pays for a gift to Bob.
        _purchaseEth(alice, _p(saleId, 0, bob, 1, 2, A_PRICE), aliceProof, total);
        assertEq(editions.balanceOf(bob, ETH_ED), 1);
        assertEq(_bought(saleId, 0, alice), 1);
        assertEq(_bought(saleId, 0, bob), 0);

        // Nobody else can pay as Alice, or use her leaf as themselves.
        vm.deal(stranger, 1 ether);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        vm.prank(stranger);
        fixedSale.purchase{ value: total }(
            _p(saleId, 0, stranger, 1, 2, A_PRICE), aliceProof, _eth(alice, total)
        );
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, saleId, 0, stranger)
        );
        _purchaseEth(stranger, _p(saleId, 0, alice, 1, 2, A_PRICE), aliceProof, total);
    }

    function test_Allowlist_RejectsForgedCapOrPriceAndLongProofs() public {
        (uint256 saleId, bytes32[] memory leaves) = _openAllowlist(false, true);
        bytes32[] memory proof = _proof(leaves, 1);
        vm.deal(bob, 10 ether);
        // A higher cap or a lower price than the leaf commits.
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, saleId, 0, bob)
        );
        _purchaseEth(bob, _p(saleId, 0, bob, 2, 2, B_PRICE), proof, 2 * B_PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, saleId, 0, bob)
        );
        _purchaseEth(bob, _p(saleId, 0, bob, 1, 1, 1), proof, 1);
        // A proof longer than 32 nodes is refused.
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, saleId, 0, bob)
        );
        _purchaseEth(bob, _p(saleId, 0, bob, 1, 1, B_PRICE), new bytes32[](33), B_PRICE);
        // The genuine leaf works.
        _purchaseEth(bob, _p(saleId, 0, bob, 1, 1, B_PRICE), proof, B_PRICE);
    }

    function test_Allowlist_LeafBindsEditionPhaseAdapterAndChain() public {
        bytes32[] memory leaves =
            _leaves(ETH_ED, 0, _list3(alice, bob, creator), _nums3(2, 1, 5), _nums3(0, 0, 0));
        bytes32 root = _root(leaves);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](2);
        phases[0] = _phase(root, 0, false, false);
        phases[1] = _phase(root, 0, false, false);
        uint256 saleId = _open(creator, ETH_ED, phases);
        // The same tree on another edition.
        uint256 usdSale = _open(creator, USD_ED, phases);
        bytes32[] memory proof = _proof(leaves, 0);
        vm.deal(alice, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, saleId, 1, alice)
        );
        _purchaseEth(alice, _p(saleId, 1, alice, 1, 2, 0), proof, PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, usdSale, 0, alice)
        );
        vm.prank(alice);
        fixedSale.purchase(_p(usdSale, 0, alice, 1, 2, 0), proof, _eth(alice, USD_PRICE));
        // Another chain ID changes every leaf.
        uint256 chain = block.chainid;
        vm.chainId(chain + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, saleId, 0, alice)
        );
        _purchaseEth(alice, _p(saleId, 0, alice, 1, 2, 0), proof, PRICE);
        vm.chainId(chain);
        // Another adapter computes other leaves.
        (IRevenueEscrow e, ISignatureTransfer p2, IEconomicsResolver r) = _deps();
        FixedPriceSale twin = new FixedPriceSale(address(manager), e, p2, r);
        assertNotEq(
            twin.allowlistLeaf(address(editions), ETH_ED, 0, alice, 2, 0),
            fixedSale.allowlistLeaf(address(editions), ETH_ED, 0, alice, 2, 0)
        );
        // An unpriced allowlist phase charges the package price.
        _purchaseEth(alice, _p(saleId, 0, alice, 1, 2, 0), proof, PRICE);
        assertEq(seller.balance + network.balance, PRICE);
    }

    function test_Allowlist_CapsPersistAcrossReopenedSales() public {
        (uint256 saleId, bytes32[] memory leaves) = _openAllowlist(false, true);
        vm.deal(bob, 1 ether);
        _purchaseEth(bob, _p(saleId, 0, bob, 1, 1, B_PRICE), _proof(leaves, 1), B_PRICE);
        vm.prank(creator);
        fixedSale.closeSale(saleId);
        // Rerunning the same tree in a new sale does not reset Bob's cap.
        IFixedPriceSale.Phase[] memory again = fixedSale.phases(saleId);
        uint256 next = _open(creator, ETH_ED, again);
        assertEq(_bought(next, 0, bob), 1);
        assertEq(fixedSale.purchased(address(editions), ETH_ED, 0, bob), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.WalletCapExceeded.selector, next, 0, bob)
        );
        _purchaseEth(bob, _p(next, 0, bob, 1, 1, B_PRICE), _proof(leaves, 1), B_PRICE);
        // A deliberately fresh drop uses a new phase index.
        vm.prank(creator);
        fixedSale.closeSale(next);
        bytes32[] memory fresh = _leaves(
            ETH_ED, 1, _list3(alice, bob, creator), _nums3(2, 1, 5), _nums3(A_PRICE, B_PRICE, PRICE)
        );
        IFixedPriceSale.Phase[] memory drop = new IFixedPriceSale.Phase[](2);
        drop[0] = again[0];
        drop[1] = _phase(_root(fresh), 0, false, true);
        uint256 third = _open(creator, ETH_ED, drop);
        _purchaseEth(bob, _p(third, 1, bob, 1, 1, B_PRICE), _proof(fresh, 1), B_PRICE);
        assertEq(editions.balanceOf(bob, ETH_ED), 2);
    }

    function test_Caps_PerWalletAcrossPhases() public {
        bytes32[] memory l0 = _leaves(
            ETH_ED, 0, _list3(alice, bob, creator), _nums3(2, 1, 1), _nums3(A_PRICE, 0, 0)
        );
        bytes32[] memory l1 = _leaves(
            ETH_ED, 1, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(B_PRICE, 0, 0)
        );
        bytes32[] memory l3 = _leaves(
            ETH_ED, 3, _list3(alice, bob, creator), _nums3(2, 1, 1), _nums3(A_PRICE, 0, 0)
        );
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](4);
        phases[0] = _phase(_root(l0), 0, false, true);
        phases[1] = _phase(_root(l1), 0, false, true); // overlaps phase 0
        phases[2] = _phase(0, 1, false, false); // public, one per recipient
        phases[3] = _phase(_root(l3), 1, false, true); // leaf cap 2, phase cap 1
        uint256 saleId = _open(creator, ETH_ED, phases);
        vm.deal(alice, 10 ether);

        _purchaseEth(alice, _p(saleId, 0, alice, 2, 2, A_PRICE), _proof(l0, 0), 2 * A_PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.WalletCapExceeded.selector, saleId, 0, alice)
        );
        _purchaseEth(alice, _p(saleId, 0, alice, 1, 2, A_PRICE), _proof(l0, 0), A_PRICE);

        _purchaseEth(alice, _p(saleId, 1, alice, 1, 1, B_PRICE), _proof(l1, 0), B_PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.WalletCapExceeded.selector, saleId, 1, alice)
        );
        _purchaseEth(alice, _p(saleId, 1, alice, 1, 1, B_PRICE), _proof(l1, 0), B_PRICE);

        _purchaseEth(alice, _p(saleId, 2, alice, 1, 0, 0), new bytes32[](0), PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.WalletCapExceeded.selector, saleId, 2, alice)
        );
        _purchaseEth(alice, _p(saleId, 2, alice, 1, 0, 0), new bytes32[](0), PRICE);

        // The phase's wallet cap also bounds an allowlist leaf with a larger cap.
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.WalletCapExceeded.selector, saleId, 3, alice)
        );
        _purchaseEth(alice, _p(saleId, 3, alice, 2, 2, A_PRICE), _proof(l3, 0), 2 * A_PRICE);

        assertEq(_bought(saleId, 0, alice), 2);
        assertEq(_bought(saleId, 1, alice), 1);
        assertEq(_bought(saleId, 2, alice), 1);
        assertEq(_bought(saleId, 3, alice), 0);
        assertEq(editions.balanceOf(alice, ETH_ED), 4);
    }

    function testFuzz_PublicWalletCapIsNeverExceeded(uint8 capSeed, uint8[8] calldata buys) public {
        uint32 cap = uint32(bound(capSeed, 1, 20));
        uint256 saleId = _openPublic(ETH_ED, cap);
        for (uint256 i; i < buys.length; ++i) {
            uint256 quantity = bound(buys[i], 1, 8);
            uint256 before = _bought(saleId, 0, bob);
            uint256 total = quantity * PRICE;
            vm.deal(alice, total);
            if (before + quantity > cap) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IFixedPriceSale.WalletCapExceeded.selector, saleId, 0, bob
                    )
                );
            }
            vm.prank(alice);
            fixedSale.purchase{ value: total }(
                _p(saleId, 0, bob, quantity, 0, 0), new bytes32[](0), _eth(alice, total)
            );
            assertLe(_bought(saleId, 0, bob), cap);
        }
        assertEq(editions.balanceOf(bob, ETH_ED), _bought(saleId, 0, bob));
    }

    function test_Gift_ZeroLeafPriceIsPushedToTheRecipient() public {
        bytes32[] memory leaves =
            _leaves(ETH_ED, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(0, 0, 0));
        uint256 saleId = _open(creator, ETH_ED, _one(_phase(_root(leaves), 0, false, true)));
        // The creator pushes Bob's gift; Bob pays nothing.
        vm.prank(creator);
        fixedSale.purchase(_p(saleId, 0, bob, 1, 1, 0), _proof(leaves, 1), _eth(creator, 0));
        assertEq(editions.balanceOf(bob, ETH_ED), 1);
        assertEq(seller.balance + network.balance, 0);
    }

    function _purchaseEth(
        address buyer,
        IFixedPriceSale.Purchase memory p,
        bytes32[] memory proof,
        uint256 total
    ) internal {
        vm.prank(buyer);
        fixedSale.purchase{ value: total }(p, proof, _eth(buyer, total));
    }
}
