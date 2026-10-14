// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Vm } from "forge-std/Vm.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { Roles } from "src/governance/Roles.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_EDITIONS
} from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod, PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { MintSaleBase } from "src/sales/MintSaleBase.sol";
import {
    CreatorReentrant,
    InboundShortToken,
    OverDebitToken
} from "../../mocks/sales/ReviewMocks.sol";
import {
    MockEditionTarget,
    MockFederationRegistry,
    MockPermit2
} from "../../mocks/sales/SaleMocks.sol";
import { FixedPriceBase } from "./FixedPriceBase.sol";

/// @notice Regressions from the PR #18 review: the reviewer's proofs of concept, ported (the
///         #744 recipient binding held on every route) or inverted (caps, currency, federation),
///         the six mutation killers (L4, C7, D1, D2, D6, W1), the emergency pause, closing ended
///         sales, and the event order indexers must expect.
contract ReviewRegressionsTest is FixedPriceBase {
    uint256 internal constant A_PRICE = 0.04 ether;

    bytes32[] internal _leaves0;
    bytes32[] internal _leaves1;
    uint256 internal _sale;

    // ------------------------------------------------------------------ #744 binding (held)

    /// @dev Recipient-keyed gift tree (phase 0, creator-approved, price 0) and payer-keyed tree
    ///      (phase 1), both cap 2.
    function _openTwoTrees() internal {
        _leaves0 = _leaves(USD_ED, 0, _list3(alice, bob, creator), _nums3(2, 2, 2), _nums3(0, 0, 0));
        _leaves1 = _leaves(USD_ED, 1, _list3(alice, bob, creator), _nums3(2, 2, 2), _nums3(0, 0, 0));
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](2);
        phases[0] = _phase(_root(_leaves0), 0, false, true);
        phases[1] = _phase(_root(_leaves1), 0, true, true);
        _sale = _open(creator, USD_ED, phases);
    }

    function test_PoC_NoDirectRouteMintsToSelfOnAnotherWalletsLeaf() public {
        _openTwoTrees();
        address mallory = stranger;
        bytes32[] memory proofA = _proof(_leaves0, 0);
        bytes32[] memory keyedA = _proof(_leaves1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, _sale, 0, mallory)
        );
        _purchase(mallory, _p(_sale, 0, mallory, 1, 2, 0), proofA, _eth(mallory, 0));
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, _sale, 0, mallory)
        );
        _purchase(mallory, _p(_sale, 0, address(0), 1, 2, 0), proofA, _eth(mallory, 0));
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        _purchase(mallory, _p(_sale, 0, address(0), 1, 2, 0), proofA, _eth(alice, 0));
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        _purchase(mallory, _p(_sale, 1, mallory, 1, 2, 0), keyedA, _eth(alice, 0));
        Payment memory permitAsAlice = _eth(alice, 0);
        permitAsAlice.method = PaymentMethod.PERMIT;
        permitAsAlice.deadline = block.timestamp + 1;
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        _purchase(mallory, _p(_sale, 1, mallory, 1, 2, 0), keyedA, permitAsAlice);
        assertEq(editions.balanceOf(mallory, USD_ED), 0);
    }

    function _intentFor(uint256 key, address owner, IFixedPriceSale.Purchase memory p, uint256 n)
        internal
        view
        returns (Payment memory)
    {
        uint256 deadline = block.timestamp + 1 hours;
        return _permit2Payment(
            key,
            owner,
            address(fixedSale),
            address(usd),
            0,
            n,
            deadline,
            _witness(p, 0, deadline),
            Typehashes.PURCHASE_WITNESS_TYPE
        );
    }

    function test_PoC_NoPermit2RouteMintsToSelfOnAnotherWalletsLeaf() public {
        _openTwoTrees();
        address mallory = stranger;
        (address m2, uint256 m2Key) = makeAddrAndKey("mallory2");
        IFixedPriceSale.Purchase memory p = _p(_sale, 1, m2, 1, 2, 0);
        Payment memory own = _intentFor(m2Key, m2, p, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, _sale, 1, m2)
        );
        _purchase(mallory, p, _proof(_leaves1, 0), own);

        IFixedPriceSale.Purchase memory forBob = _p(_sale, 1, bob, 1, 2, 0);
        Payment memory alicesIntent = _intentFor(aliceKey, alice, forBob, 2);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        _purchase(mallory, _p(_sale, 1, mallory, 1, 2, 0), _proof(_leaves1, 0), alicesIntent);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        _purchase(mallory, _p(_sale, 1, address(0), 1, 2, 0), _proof(_leaves1, 0), alicesIntent);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, _sale, 0, mallory)
        );
        _purchase(mallory, _p(_sale, 0, mallory, 1, 2, 0), _proof(_leaves0, 0), alicesIntent);
        // The genuine intent still works, delivering to Bob on Alice's leaf.
        _purchase(mallory, forBob, _proof(_leaves1, 0), alicesIntent);
        assertEq(editions.balanceOf(bob, USD_ED), 1);
        assertEq(editions.balanceOf(mallory, USD_ED), 0);
        assertEq(editions.balanceOf(m2, USD_ED), 0);
    }

    // ------------------------------------------------------------------ caps (inverted)

    function test_PoC_Inverted_CapsSurviveAReopenedSale_PlatformOnly() public {
        bytes32[] memory leaves = _leaves(
            ETH_ED, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(PRICE, PRICE, PRICE)
        );
        IFixedPriceSale.Phase[] memory phases = _one(_phase(_root(leaves), 0, false, true));
        uint256 first = _open(platform, ETH_ED, phases);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        fixedSale.purchase{ value: PRICE }(
            _p(first, 0, bob, 1, 1, PRICE), _proof(leaves, 1), _eth(bob, PRICE)
        );
        vm.prank(platform);
        fixedSale.closeSale(first);
        uint256 second = _open(platform, ETH_ED, phases);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.WalletCapExceeded.selector, second, 0, bob)
        );
        vm.prank(bob);
        fixedSale.purchase{ value: PRICE }(
            _p(second, 0, bob, 1, 1, PRICE), _proof(leaves, 1), _eth(bob, PRICE)
        );
        assertEq(editions.balanceOf(bob, ETH_ED), 1);
    }

    function test_PoC_Inverted_ASecondConsentDoesNotDoubleTheDiscount() public {
        bytes32[] memory leaves = _leaves(
            ETH_ED,
            0,
            _list3(alice, bob, creator),
            _nums3(1, 1, 1),
            _nums3(A_PRICE, A_PRICE, A_PRICE)
        );
        IFixedPriceSale.Phase[] memory phases = _one(_phase(_root(leaves), 0, false, true));
        uint64 deadline = uint64(block.timestamp + 1 days);
        IFixedPriceSale.ArtistConsent memory c1 = _consent(creatorKey, ETH_ED, phases, 1, deadline);
        IFixedPriceSale.ArtistConsent memory c2 = _consent(creatorKey, ETH_ED, phases, 2, deadline);
        vm.prank(platform);
        uint256 first = fixedSale.openSale(address(editions), ETH_ED, phases, c1);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        fixedSale.purchase{ value: A_PRICE }(
            _p(first, 0, alice, 1, 1, A_PRICE), _proof(leaves, 0), _eth(alice, A_PRICE)
        );
        vm.prank(platform);
        fixedSale.closeSale(first);
        vm.prank(platform);
        uint256 second = fixedSale.openSale(address(editions), ETH_ED, phases, c2);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.WalletCapExceeded.selector, second, 0, alice)
        );
        vm.prank(alice);
        fixedSale.purchase{ value: A_PRICE }(
            _p(second, 0, alice, 1, 1, A_PRICE), _proof(leaves, 0), _eth(alice, A_PRICE)
        );
        assertEq(editions.balanceOf(alice, ETH_ED), 1);
    }

    // ------------------------------------------------------------------ currency (inverted)

    function test_PoC_Inverted_APricedSaleCannotFollowTheDefaultCurrency() public {
        uint256 id = 99;
        editions.setTerms(id, _terms(SaleKind.FIXED_PRICE, CURRENCY_DEFAULT, PRICE, ""), SIZE);
        allowlist.setDefault(PRODUCT_EDITIONS, address(usd));
        vm.expectRevert(
            abi.encodeWithSelector(
                MintSaleBase.PricedDefaultCurrency.selector, address(editions), id
            )
        );
        _open(platform, id, _one(_phase(0, 0, false, false)));
    }

    function test_PoC_Inverted_ConsentBindsCurrencyAndPackagePrice() public {
        bytes32[] memory leaves = _leaves(
            USD_ED, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(1e18, 1e18, 1e18)
        );
        IFixedPriceSale.Phase[] memory phases = _one(_phase(_root(leaves), 0, false, true));
        uint64 deadline = uint64(block.timestamp + 1 days);
        // Signed for ETH at the USD price, or for USD at another package price: both refused.
        bytes32 wrongCurrency = fixedSale.phaseConfigurationDigest(
            address(editions), USD_ED, CURRENCY_ETH, USD_PRICE, phases, 1, deadline
        );
        bytes32 wrongPrice = fixedSale.phaseConfigurationDigest(
            address(editions), USD_ED, address(usd), USD_PRICE + 1, phases, 1, deadline
        );
        bytes32[2] memory digests = [wrongCurrency, wrongPrice];
        for (uint256 i; i < 2; ++i) {
            IFixedPriceSale.ArtistConsent memory c =
                IFixedPriceSale.ArtistConsent(1, deadline, _sig(creatorKey, digests[i]));
            vm.expectRevert(IFixedPriceSale.InvalidArtistConsent.selector);
            vm.prank(platform);
            fixedSale.openSale(address(editions), USD_ED, phases, c);
        }
        IFixedPriceSale.ArtistConsent memory valid =
            _consent(creatorKey, USD_ED, phases, 1, deadline);
        vm.prank(platform);
        uint256 saleId = fixedSale.openSale(address(editions), USD_ED, phases, valid);
        assertTrue(_approved(saleId));
    }

    // ------------------------------------------------------------------ federation (inverted)

    function _fedSetup(address tokenFeeRecipient)
        internal
        returns (MockFederationRegistry registry, MockEditionTarget fed)
    {
        registry = new MockFederationRegistry();
        fed = new MockEditionTarget();
        fed.setAdmittedMinter(address(fixedSale), true);
        PrimaryTerms memory t = _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, "");
        if (tokenFeeRecipient != address(0)) t.feeRecipient = tokenFeeRecipient;
        fed.setTerms(3, t, SIZE);
        registry.setEntry(address(fed), 25_000, true);
        vm.prank(admin);
        fixedSale.setFederationRegistry(address(0), address(registry));
    }

    function test_PoC_Inverted_FederatedFeeGoesToTheNetworkRecipient() public {
        (, MockEditionTarget fed) = _fedSetup(creator);
        vm.prank(creator);
        uint256 saleId =
            fixedSale.openSale(address(fed), 3, _one(_phase(0, 0, false, false)), _noConsent());
        vm.deal(alice, PRICE);
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        assertEq(creator.balance, 0);
        assertEq(federatedNetwork.balance, PRICE * 25_000 / 100_000);
    }

    function test_PoC_Inverted_DelistedFederatedTokenStopsSelling() public {
        (MockFederationRegistry registry, MockEditionTarget fed) = _fedSetup(address(0));
        vm.prank(creator);
        uint256 saleId =
            fixedSale.openSale(address(fed), 3, _one(_phase(0, 0, false, false)), _noConsent());
        registry.setEntry(address(fed), 25_000, false); // delisted by vote
        vm.deal(alice, PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fed))
        );
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        // Relisting resumes it.
        registry.setEntry(address(fed), 25_000, true);
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        assertEq(fed.balanceOf(alice, 3), 1);
    }

    function test_FederatedTokenMustRunItsRegisteredCode() public {
        (MockFederationRegistry registry, MockEditionTarget fed) = _fedSetup(address(0));
        registry.setCodeHash(address(fed), keccak256("another template"));
        vm.expectRevert(
            abi.encodeWithSelector(MintSaleBase.InvalidSaleTerms.selector, address(fed), 3)
        );
        vm.prank(creator);
        fixedSale.openSale(address(fed), 3, _one(_phase(0, 0, false, false)), _noConsent());
    }

    // ------------------------------------------------------------------ reentrancy and events

    /// @dev Also pins the event order indexers must handle: a recipient hook may close the sale
    ///      inside a purchase, so that purchase's `SaleSettled` follows `SaleClosed`.
    function test_PoC_ReceiverHookCloseReopenIsHarmless() public {
        CreatorReentrant wallet = new CreatorReentrant();
        editions.setCreator(ETH_ED, address(wallet));
        vm.prank(address(wallet));
        uint256 saleId = fixedSale.openSale(
            address(editions), ETH_ED, _one(_phase(0, 0, false, false)), _noConsent()
        );
        wallet.arm(fixedSale, address(editions), ETH_ED, saleId);
        vm.deal(alice, PRICE);
        vm.recordLogs();
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, address(wallet), 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        assertTrue(wallet.purchaseReentryBlocked());
        assertTrue(_closed(saleId));
        assertEq(fixedSale.openSaleOf(address(editions), ETH_ED), wallet.reopened());
        assertEq(seller.balance + network.balance, PRICE);
        assertEq(address(fixedSale).balance, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 closedAt = type(uint256).max;
        uint256 settledAt = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(fixedSale) || logs[i].topics.length < 2) continue;
            if (uint256(logs[i].topics[1]) != saleId) continue;
            if (logs[i].topics[0] == IFixedPriceSale.SaleClosed.selector) closedAt = i;
            if (logs[i].topics[0] == ISaleAdapter.SaleSettled.selector) settledAt = i;
        }
        assertLt(closedAt, settledAt);
        assertTrue(settledAt != type(uint256).max);
    }

    // ------------------------------------------------------------------ mutation killers

    function _intent(
        uint256 key,
        address owner,
        address token,
        IFixedPriceSale.Purchase memory p,
        uint256 amount,
        uint256 nonce
    ) internal view returns (Payment memory) {
        uint256 deadline = block.timestamp + 1 hours;
        return _permit2Payment(
            key,
            owner,
            address(fixedSale),
            token,
            amount,
            nonce,
            deadline,
            _witness(p, amount, deadline),
            Typehashes.PURCHASE_WITNESS_TYPE
        );
    }

    /// L4: a relayed intent with recipient 0 mints to the signer, never to the relayer.
    function test_Kill_L4_RelayedZeroRecipientMintsToTheSigner() public {
        uint256 saleId = _openPublic(USD_ED, 0);
        usd.mint(alice, 1000e18);
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _p(saleId, 0, address(0), 1, 0, 0);
        _purchase(
            relayer, p, new bytes32[](0), _intent(aliceKey, alice, address(usd), p, USD_PRICE, 0)
        );
        assertEq(editions.balanceOf(alice, USD_ED), 1);
        assertEq(editions.balanceOf(relayer, USD_ED), 0);
    }

    /// C7: a leaf price one wei below the package price needs approval; equal does not.
    function test_Kill_C7_DiscountBoundary() public {
        bytes32[] memory leaves = _leaves(
            ETH_ED, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(PRICE - 1, PRICE, PRICE)
        );
        uint256 saleId = _open(platform, ETH_ED, _one(_phase(_root(leaves), 0, false, true)));
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.PriceBelowPackage.selector, PRICE - 1, PRICE)
        );
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE - 1 }(
            _p(saleId, 0, alice, 1, 1, PRICE - 1), _proof(leaves, 0), _eth(alice, PRICE - 1)
        );
        vm.prank(bob);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, bob, 1, 1, PRICE), _proof(leaves, 1), _eth(bob, PRICE)
        );
    }

    function _tokenSale(address token) internal returns (uint256 saleId) {
        uint256 id = uint256(uint160(token));
        allowlist.set(token, true);
        editions.setTerms(id, _terms(SaleKind.FIXED_PRICE, token, 10e18, ""), SIZE);
        saleId = _openPublic(id, 0);
    }

    /// D1: the adapter-side Permit2 delta is checked even when a donated balance would let the
    ///     payouts succeed.
    function test_Kill_D1_Permit2InboundShortfallReverts() public {
        InboundShortToken token = new InboundShortToken();
        uint256 saleId = _tokenSale(address(token));
        token.mint(address(fixedSale), 5e18); // anyone can donate
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _p(saleId, 0, alice, 1, 0, 0);
        Payment memory pay = _intent(aliceKey, alice, address(token), p, 10e18, 0);
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(token))
        );
        _purchase(relayer, p, new bytes32[](0), pay);
    }

    /// D2: the payer-side Permit2 delta is checked.
    function test_Kill_D2_Permit2PayerOverDebitReverts() public {
        OverDebitToken token = new OverDebitToken();
        uint256 saleId = _tokenSale(address(token));
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _p(saleId, 0, alice, 1, 0, 0);
        Payment memory pay = _intent(aliceKey, alice, address(token), p, 10e18, 0);
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(token))
        );
        _purchase(relayer, p, new bytes32[](0), pay);
    }

    /// D6: fixed price rejects ETH overpayment (it would otherwise be kept, uncredited).
    function test_Kill_D6_FixedEthOverpaymentReverts() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        vm.deal(alice, 1 ether);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        vm.prank(alice);
        fixedSale.purchase{ value: 2 * PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, 2 * PRICE)
        );
        assertEq(address(fixedSale).balance, 0);
    }

    /// W1: a relayer cannot move a signed intent to another phase with the same price.
    function test_Kill_W1_IntentIsBoundToItsPhase() public {
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](2);
        phases[0] = _phase(0, 1, false, false);
        phases[1] = _phase(0, 5, false, false);
        uint256 saleId = _open(creator, USD_ED, phases);
        usd.mint(alice, 1000e18);
        vm.prank(alice);
        usd.approve(address(permit2), type(uint256).max);
        IFixedPriceSale.Purchase memory p = _p(saleId, 1, alice, 1, 0, 0);
        Payment memory pay = _intent(aliceKey, alice, address(usd), p, USD_PRICE, 0);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        _purchase(relayer, _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), pay);
        _purchase(relayer, p, new bytes32[](0), pay);
        assertEq(_bought(saleId, 1, alice), 1);
    }

    // ------------------------------------------------------------------ pause

    function test_Pause_StopsOpeningAndBuyingButNotClosingOrClaiming() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        vm.expectEmit(address(fixedSale));
        emit ISaleAdapter.Paused(pauser);
        vm.prank(pauser);
        fixedSale.pause();
        assertTrue(fixedSale.paused());
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        _openPublic(USD_ED, 0);
        vm.deal(alice, PRICE);
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
        // Claims and closing never stop.
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.NothingToClaim.selector, alice, CURRENCY_ETH)
        );
        vm.prank(alice);
        fixedSale.claim(CURRENCY_ETH, alice);
        vm.prank(creator);
        fixedSale.closeSale(saleId);
        vm.expectEmit(address(fixedSale));
        emit ISaleAdapter.Unpaused(unpauser);
        // GOV-5: not before 48 hours after the pause.
        vm.prank(unpauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.UnpauseTooEarly.selector, block.timestamp + Roles.STANDARD
            )
        );
        fixedSale.unpause();
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(unpauser);
        fixedSale.unpause();
        _openPublic(ETH_ED, 0);
    }

    function test_Pause_IsRoleGated() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unpauser)
        );
        vm.prank(unpauser);
        fixedSale.pause();
        vm.prank(pauser);
        fixedSale.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, pauser)
        );
        vm.prank(pauser);
        fixedSale.unpause();
    }

    /// @dev QUALITY-7: as in the auction, a repeated `pause` reverts with `SalePaused` and an
    ///      `unpause` while not paused with `NotPaused`; neither emits twice.
    function test_Pause_RepeatedPauseOrUnpauseReverts() public {
        vm.expectRevert(ISaleAdapter.NotPaused.selector);
        vm.prank(unpauser);
        fixedSale.unpause();
        vm.prank(pauser);
        fixedSale.pause();
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        vm.prank(pauser);
        fixedSale.pause();
        assertTrue(fixedSale.paused());
    }

    // ------------------------------------------------------------------ closing ended sales

    function test_AnyoneClosesASaleWhosePhasesEnded() public {
        uint64 t = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](2);
        phases[0] = IFixedPriceSale.Phase(t, t + 100, 0, 0, false, false);
        phases[1] = IFixedPriceSale.Phase(t, t + 200, 0, 0, false, false);
        uint256 saleId = _open(creator, ETH_ED, phases);
        vm.warp(t + 150);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, stranger));
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
        vm.warp(t + 200);
        vm.expectEmit(address(fixedSale));
        emit IFixedPriceSale.SaleClosed(saleId);
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
        assertEq(fixedSale.openSaleOf(address(editions), ETH_ED), 0);
    }
}
