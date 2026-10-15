// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Vm } from "forge-std/Vm.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { Roles } from "src/governance/Roles.sol";
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
    Payment,
    PaymentMethod,
    PrimaryTerms,
    SaleKind
} from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { FixedPriceSale } from "src/sales/FixedPriceSale.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { MintSaleBase } from "src/sales/MintSaleBase.sol";
import { Mock1271Account } from "../../mocks/economics/EconomicsMocks.sol";
import {
    CreatorReentrant,
    InboundShortToken,
    OverDebitToken
} from "../../mocks/sales/HostileSaleMocks.sol";
import {
    MockAssetAllowlist,
    MockEditionTarget,
    MockFederationRegistry,
    MockPermit2
} from "../../mocks/sales/SaleMocks.sol";
import { FixedPriceBase } from "./FixedPriceBase.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { SignatureReverts } from "test/helpers/SignatureReverts.sol";
import { IMintSale } from "src/interfaces/IMintSale.sol";

/// @notice Unit tests of the fixed-price adapter: configuration, opening, artist approval,
///         closing, purchases, allowlists (including the PR #744 recipient-binding regression)
///         and caps.
contract FixedPriceSaleTest is FixedPriceBase {
    uint256 internal constant A_PRICE = 0.04 ether;
    uint256 internal constant B_PRICE = 0.02 ether;

    /// @dev Two allowlist trees for the recipient-binding tests: recipient-keyed (phase 0) and
    ///      payer-keyed (phase 1).
    bytes32[] internal _leaves0;
    bytes32[] internal _leaves1;
    uint256 internal _sale;

    // ------------------------------------------------------------------ configuration

    function test_Constructor_RevertsOnMissingOrUnfitDependency() public {
        (IRevenueEscrow e, ISignatureTransfer p, IEconomicsResolver r) = _deps();
        vm.expectRevert(IMintSale.InvalidAddress.selector);
        new FixedPriceSale(address(manager), IRevenueEscrow(address(0)), p, r);
        vm.expectRevert(IMintSale.InvalidAddress.selector);
        new FixedPriceSale(address(manager), e, ISignatureTransfer(address(0)), r);
        // The resolver must be a contract supporting IEconomicsResolver through ERC-165.
        address[3] memory unfit = [address(0), makeAddr("eoa"), address(usd)];
        for (uint256 i; i < unfit.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, unfit[i]));
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
        assertEq(fixedSale.PAYOUT_GAS(), 100_000);
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
        address other = address(new MockEditionTarget());
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
        vm.expectRevert(IMintSale.InvalidAddress.selector);
        vm.prank(admin);
        fixedSale.setTarget(address(0), true);
    }

    /// @dev Review of #66 (L-2): a listed token gets the install check, for `IMintTarget`, as
    ///      the auction's targets do for ERC-721; unlisting is unchecked.
    function test_SetTarget_ChecksTheTokenLikeADependency() public {
        address eoa = makeAddr("eoa");
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(editions)));
        address notATarget = address(allowlist); // code, but no `IMintTarget` through ERC-165
        address[3] memory refused = [eoa, delegated, notATarget];
        vm.startPrank(admin);
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(Dependency.InvalidDependency.selector, refused[i])
            );
            fixedSale.setTarget(refused[i], true);
            fixedSale.setTarget(refused[i], false);
        }
        vm.stopPrank();
        assertFalse(fixedSale.isListed(delegated));
    }

    /// Regression: the second review of #18
    function test_Constructor_ChecksTheResolversAllowlist() public {
        (IRevenueEscrow e, ISignatureTransfer p, IEconomicsResolver r) = _deps();
        address delegated = makeAddr("delegatedAllowlist");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(allowlist)));
        // No code, an EIP-7702 account, and an ERC-165 contract that is not an allowlist.
        address[3] memory unfit =
            [makeAddr("eoaAllowlist"), delegated, address(new MockFederationRegistry())];
        for (uint256 i; i < unfit.length; ++i) {
            resolver.setAllowlistOverride(unfit[i]);
            vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, unfit[i]));
            new FixedPriceSale(address(manager), e, p, r);
        }
        // The economics lane's allowlist answers no ERC-165 and is accepted on code alone.
        resolver.setAllowlistOverride(address(0));
        assertEq(
            address(new FixedPriceSale(address(manager), e, p, r).assets()), address(allowlist)
        );
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

    /// @dev QUALITY-4: fee recipients are stored once per adapter and referenced by index. Each
    ///      sale keeps the recipient it locked, a repeated recipient reuses its index (opening
    ///      writes no registry slot), and purchases pay the locked recipient.
    function test_OpenSale_FeeRecipientsStoredOnceByIndex() public {
        address other = makeAddr("otherNetwork");
        PrimaryTerms memory t = _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, "");
        t.feeRecipient = other;
        editions.setTerms(40, t, SIZE);
        editions.setTerms(41, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, ""), SIZE);
        uint256 first = _openPublic(ETH_ED, 0);
        vm.record();
        uint256 second = _openPublic(40, 0);
        (, bytes32[] memory registering) = vm.accesses(address(fixedSale));
        vm.record();
        uint256 third = _openPublic(41, 0);
        (, bytes32[] memory registered) = vm.accesses(address(fixedSale));
        // A new recipient adds the counter and both directions of its index; a registered one
        // adds no write.
        assertEq(registering.length, registered.length + 3);
        assertEq(_locked(first).feeRecipient, network);
        assertEq(_locked(second).feeRecipient, other);
        assertEq(_locked(third).feeRecipient, network);
        _buyEth(alice, second, 0, alice, 1, PRICE);
        assertEq(other.balance, _fee(PRICE));
        assertEq(network.balance, 0);
        _buyEth(alice, third, 0, alice, 1, PRICE);
        assertEq(network.balance, _fee(PRICE));
    }

    /// @dev QUALITY-4: the fee-recipient counter shares slot 0 with the AccessManaged authority
    ///      and `nextSaleId` (bytes 29 and 30). At 65,535 recipients a sale that would register
    ///      another fails closed with `InvalidSaleTerms`, as Stream's index does, while a
    ///      registered recipient still opens sales.
    function test_OpenSale_FeeRecipientLimitFailsClosed() public {
        uint256 first = _openPublic(ETH_ED, 0); // registers `network` as index 1
        vm.prank(creator);
        fixedSale.closeSale(first);
        uint256 word = uint256(vm.load(address(fixedSale), bytes32(0)));
        assertEq(address(uint160(word)), address(manager), "slot 0 holds the authority");
        assertEq(uint64(word >> 168), fixedSale.nextSaleId(), "then nextSaleId");
        assertEq(uint16(word >> 232), 1, "then the fee-recipient count");
        vm.store(address(fixedSale), bytes32(0), bytes32(word | uint256(type(uint16).max) << 232));
        _openPublic(ETH_ED, 0);
        PrimaryTerms memory t = _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, "");
        t.feeRecipient = makeAddr("oneTooMany");
        editions.setTerms(42, t, SIZE);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), 42)
        );
        _openPublic(42, 0);
    }

    /// @dev QUALITY-4: a phase is stored in one word, plus its root for an allowlist phase; the
    ///      view rebuilds every field, for every phase up to `Limits.MAX_PHASES`.
    function test_OpenSale_PackedPhasesRoundTrip() public {
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](16);
        uint64 t = uint64(block.timestamp);
        for (uint256 i; i < phases.length; ++i) {
            bytes32 root = i % 2 == 0 ? keccak256(abi.encode(i)) : bytes32(0);
            phases[i] = IFixedPriceSale.Phase(
                t + uint64(i),
                type(uint64).max - uint64(i),
                root,
                i % 3 == 0 ? type(uint32).max : uint32(i),
                root != 0 && i % 4 == 0,
                root != 0 && i % 4 == 2
            );
        }
        uint256 saleId = _open(creator, ETH_ED, phases);
        assertEq(keccak256(abi.encode(fixedSale.phases(saleId))), keccak256(abi.encode(phases)));
    }

    function test_OpenSale_ByPlatformIsNotArtistApproved() public {
        uint256 saleId = _open(platform, ETH_ED, _one(_phase(0, 2, false, false)));
        assertFalse(_approved(saleId));
    }

    function test_OpenSale_RevertsForStrangerAndDelayedPlatform() public {
        IFixedPriceSale.Phase[] memory phases = _one(_phase(0, 0, false, false));
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, stranger));
        _open(stranger, ETH_ED, phases);

        // A PLATFORM member with an execution delay may not act immediately.
        address slow = makeAddr("slowPlatform");
        vm.prank(admin);
        manager.grantRole(PLATFORM_ROLE, slow, 1 days);
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, slow));
        _open(slow, ETH_ED, phases);
    }

    function test_OpenSale_OneOpenSalePerEdition() public {
        uint256 first = _openPublic(ETH_ED, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintSale.SaleAlreadyOpen.selector, address(editions), ETH_ED)
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
                    ISaleAdapter.InvalidSaleTerms.selector, address(editions), 20 + i
                )
            );
            _openPublic(20 + i, 0);
        }
    }

    /// Regression: CALLS-1 (docs/security/internal-review-2026-10.md)
    /// @dev Terms that pay the revenue escrow as seller or fee recipient are refused at
    ///      open, since the escrow refuses to be paid as a wallet and no purchase could pay.
    function test_OpenSale_RefusesTheEscrowAsSellerOrFeeRecipient() public {
        for (uint256 i; i < 2; ++i) {
            PrimaryTerms memory t = _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, "");
            if (i == 0) t.feeRecipient = address(escrow);
            else t.seller = address(escrow);
            editions.setTerms(30 + i, t, SIZE);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ISaleAdapter.InvalidSaleTerms.selector, address(editions), 30 + i
                )
            );
            _openPublic(30 + i, 0);
        }
        // Valid wallets open and sell as usual.
        uint256 saleId = _openPublic(ETH_ED, 0);
        _buyEth(alice, saleId, 0, alice, 1, PRICE);
        assertEq(editions.balanceOf(alice, ETH_ED), 1);
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
        vm.expectRevert(IFixedPriceSale.InvalidPhases.selector);
        _open(creator, ETH_ED, new IFixedPriceSale.Phase[](0));
        vm.expectRevert(IFixedPriceSale.InvalidPhases.selector);
        _open(creator, ETH_ED, tooMany);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IFixedPriceSale.InvalidPhases.selector);
            _open(creator, ETH_ED, _one(bad[i]));
        }
        // Sixteen phases are accepted.
        _open(creator, ETH_ED, sixteen);
    }

    /// Regression: a proof of concept (inverted) in the review of #18
    function test_OpenSale_APricedSaleCannotFollowTheDefaultCurrency() public {
        uint256 id = 99;
        editions.setTerms(id, _terms(SaleKind.FIXED_PRICE, CURRENCY_DEFAULT, PRICE, ""), SIZE);
        allowlist.setDefault(PRODUCT_EDITIONS, address(usd));
        vm.expectRevert(
            abi.encodeWithSelector(IMintSale.PricedDefaultCurrency.selector, address(editions), id)
        );
        _open(platform, id, _one(_phase(0, 0, false, false)));
    }

    /// Regression: a nit (inverted) in the second review of #18
    /// @dev A resolver that substitutes an explicitly named currency is refused.
    function test_OpenSale_TheResolverCannotSubstituteANamedCurrency() public {
        vm.mockCall(
            address(resolver),
            abi.encodeCall(IEconomicsResolver.resolveCurrency, (PRODUCT_EDITIONS, CURRENCY_ETH)),
            abi.encode(address(usd))
        );
        vm.expectRevert(
            abi.encodeWithSelector(IMintSale.CurrencyMismatch.selector, CURRENCY_ETH, address(usd))
        );
        _openPublic(ETH_ED, 0);
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

    /// Regression: MARKET-6 (docs/security/internal-review-2026-10.md)
    /// @dev MARKET-6: alone, PLATFORM sells at the package price only: discounts and premiums
    ///      alike need the artist.
    function test_Approval_PlatformAloneCannotPriceLeaves() public {
        bytes32[] memory leaves = _pricedLeaves();
        vm.expectRevert(
            abi.encodeWithSelector(
                IFixedPriceSale.PricedLeavesNeedApproval.selector, address(editions), ETH_ED
            )
        );
        _platformPriced(leaves, _noConsent());
        // The creator prices leaves both ways.
        uint256 saleId = _open(creator, ETH_ED, _one(_phase(_root(leaves), 0, false, true)));
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        _purchaseEth(alice, _p(saleId, 0, alice, 1, 2, A_PRICE), _proof(leaves, 0), A_PRICE);
        _purchaseEth(bob, _p(saleId, 0, bob, 1, 1, 0.2 ether), _proof(leaves, 1), 0.2 ether);
        assertEq(editions.balanceOf(alice, ETH_ED), 1);
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
            vm.expectRevert(SignatureReverts.invalid(creator));
            _platformPriced(leaves, bad[i]);
        }
        // Expired.
        IFixedPriceSale.ArtistConsent memory valid =
            _consent(creatorKey, ETH_ED, phases, 1, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(SignatureReverts.expired(deadline));
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
        // An approved sale closes by its artist (MARKET-6), not by PLATFORM.
        vm.prank(creator);
        fixedSale.closeSale(saleId);
        // Replaying the same approval for a new sale fails: the nonce is spent.
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.ConsentNonceUsed.selector, creator, 1)
        );
        _platformPriced(leaves, consent);

        // A revoked nonce can never be used.
        IFixedPriceSale.ArtistConsent memory second =
            _consent(creatorKey, ETH_ED, phases, 2, deadline);
        vm.expectEmit(address(fixedSale));
        emit IFixedPriceSale.ConsentNonceRevoked(creator, 2);
        vm.prank(creator);
        fixedSale.revokeConsentNonce(2);
        assertTrue(fixedSale.isConsentNonceUsed(creator, 2));
        bytes memory used =
            abi.encodeWithSelector(IFixedPriceSale.ConsentNonceUsed.selector, creator, 2);
        vm.expectRevert(used);
        vm.prank(creator);
        fixedSale.revokeConsentNonce(2);
        vm.expectRevert(used);
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

    /// Regression: the second review of #18
    /// @dev The typed `Phase[]` digest matches Foundry's independent EIP-712 encoder (three
    ///      phases, maximum-width fields, every flag combination).
    function test_Approval_PhaseConfigurationDigestMatchesTheCheatcode() public view {
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

    function _discountTree(uint256 id) internal view returns (bytes32[] memory) {
        return _leaves(id, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(1, 1, 1));
    }

    /// Regression: the second review of #18
    function test_Approval_ConsentNotReusableUnderAnotherCurrencyOrPrice() public {
        IFixedPriceSale.Phase[] memory phases =
            _one(_phase(_root(_discountTree(ETH_ED)), 0, false, true));
        uint64 deadline = uint64(block.timestamp + 1 days);
        IFixedPriceSale.ArtistConsent memory c = _consent(creatorKey, ETH_ED, phases, 1, deadline);

        // Currency switched to USD at the same nominal price.
        editions.setCurrency(ETH_ED, address(usd));
        vm.expectRevert(SignatureReverts.invalid(creator));
        vm.prank(platform);
        fixedSale.openSale(address(editions), ETH_ED, phases, c);

        // Price changed, currency back.
        editions.setTerms(ETH_ED, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE * 2, ""), SIZE);
        vm.expectRevert(SignatureReverts.invalid(creator));
        vm.prank(platform);
        fixedSale.openSale(address(editions), ETH_ED, phases, c);

        // Another ID with identical terms.
        editions.setTerms(77, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, ""), SIZE);
        vm.expectRevert(SignatureReverts.invalid(creator));
        vm.prank(platform);
        fixedSale.openSale(address(editions), 77, phases, c);

        // Restored terms: the original consent works once.
        editions.setTerms(ETH_ED, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, PRICE, ""), SIZE);
        vm.prank(platform);
        fixedSale.openSale(address(editions), ETH_ED, phases, c);
    }

    /// Regression: the second review of #18
    function test_Approval_AGiftConsentBindsTheResolvedDefault() public {
        uint256 id = 90;
        editions.setTerms(id, _terms(SaleKind.FIXED_PRICE, CURRENCY_DEFAULT, 0, ""), SIZE);
        allowlist.setDefault(PRODUCT_EDITIONS, CURRENCY_ETH);
        IFixedPriceSale.Phase[] memory phases = _one(_phase(bytes32("r"), 0, false, true));
        IFixedPriceSale.ArtistConsent memory c =
            _consent(creatorKey, id, phases, 1, uint64(block.timestamp + 1 days));
        allowlist.setDefault(PRODUCT_EDITIONS, address(usd));
        vm.expectRevert(SignatureReverts.invalid(creator));
        vm.prank(platform);
        fixedSale.openSale(address(editions), id, phases, c);
    }

    /// Regression: a proof of concept (inverted) in the review of #18
    function test_Approval_ASecondConsentDoesNotDoubleTheDiscount() public {
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
        vm.prank(creator);
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

    /// Regression: a proof of concept (inverted) in the review of #18
    function test_Approval_ConsentBindsCurrencyAndPackagePrice() public {
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
            vm.expectRevert(SignatureReverts.invalid(creator));
            vm.prank(platform);
            fixedSale.openSale(address(editions), USD_ED, phases, c);
        }
        IFixedPriceSale.ArtistConsent memory valid =
            _consent(creatorKey, USD_ED, phases, 1, deadline);
        vm.prank(platform);
        uint256 saleId = fixedSale.openSale(address(editions), USD_ED, phases, valid);
        assertTrue(_approved(saleId));
    }

    /// Regression: a finding (inverted) in the second review of #18
    /// @dev PLATFORM alone cannot price the leaves of a zero-price (default currency) sale; the
    ///      creator, or the creator's signed consent, can.
    function test_Approval_PricedLeavesInAZeroPriceSaleNeedTheArtist() public {
        uint256 id = 91;
        editions.setTerms(id, _terms(SaleKind.FIXED_PRICE, CURRENCY_DEFAULT, 0, ""), SIZE);
        bytes32[] memory leaves = _leaves(
            id, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(0.05e18, 0.05e18, 0.05e18)
        );
        allowlist.setDefault(PRODUCT_EDITIONS, address(usd));
        IFixedPriceSale.Phase[] memory phases = _one(_phase(_root(leaves), 0, false, true));
        vm.expectRevert(
            abi.encodeWithSelector(
                IFixedPriceSale.PricedLeavesNeedApproval.selector, address(editions), id
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

    /// Regression: the second review of #18
    function test_Approval_UnpricedLeavesInAZeroPriceSaleNeedNoApproval() public {
        uint256 id = 92;
        editions.setTerms(id, _terms(SaleKind.FIXED_PRICE, CURRENCY_ETH, 0, ""), SIZE);
        bytes32[] memory leaves =
            _leaves(id, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(0, 0, 0));
        uint256 saleId = _open(platform, id, _one(_phase(_root(leaves), 0, false, false)));
        assertFalse(_approved(saleId));
        _purchase(alice, _p(saleId, 0, alice, 1, 1, 0), _proof(leaves, 0), _eth(alice, 0));
        assertEq(editions.balanceOf(alice, id), 1);
    }

    /// Regression: MARKET-6 (docs/security/internal-review-2026-10.md); mutant C7 in the review of
    ///             #18
    /// @dev Leaf prices need the artist's approval whatever their level, so PLATFORM cannot open
    ///      a leaf-priced phase alone; in the creator's sale each leaf pays its price.
    function test_Approval_LeafPricesNeedTheArtistAtAnyLevel() public {
        bytes32[] memory leaves = _leaves(
            ETH_ED, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(PRICE - 1, PRICE, PRICE)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IFixedPriceSale.PricedLeavesNeedApproval.selector, address(editions), ETH_ED
            )
        );
        _open(platform, ETH_ED, _one(_phase(_root(leaves), 0, false, true)));
        uint256 saleId = _open(creator, ETH_ED, _one(_phase(_root(leaves), 0, false, true)));
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE - 1 }(
            _p(saleId, 0, alice, 1, 1, PRICE - 1), _proof(leaves, 0), _eth(alice, PRICE - 1)
        );
        vm.prank(bob);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, bob, 1, 1, PRICE), _proof(leaves, 1), _eth(bob, PRICE)
        );
        assertEq(editions.balanceOf(alice, ETH_ED) + editions.balanceOf(bob, ETH_ED), 2);
    }

    // ------------------------------------------------------------------ emergency pause

    /// Regression: the review of #18
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

    /// Regression: the review of #18
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

    /// Regression: QUALITY-7 (docs/security/internal-review-2026-10.md)
    /// @dev As in the auction, a repeated `pause` reverts with `SalePaused` and an
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

    // ------------------------------------------------------------------ closing

    /// Regression: MARKET-6 (docs/security/internal-review-2026-10.md)
    /// @dev The creator closes any sale of its edition; PLATFORM closes only a sale it opened
    ///      without the artist's approval (MARKET-6).
    function test_CloseSale_ByCreatorOrPlatformStopsPurchases() public {
        uint256 first = _openPublic(ETH_ED, 0);
        uint256 second = _open(platform, USD_ED, _one(_phase(0, 0, false, false)));
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, platform));
        fixedSale.closeSale(first);
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
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, creator));
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
        vm.expectRevert(abi.encodeWithSelector(IMintSale.SaleAlreadyClosed.selector, saleId));
        vm.prank(platform);
        fixedSale.closeSale(saleId);
    }

    function test_CloseSale_RevertsForStrangerOrUnknown() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, stranger));
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

    /// Regression: the review of #18
    function test_CloseSale_AnyoneClosesASaleWhosePhasesEnded() public {
        uint64 t = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](2);
        phases[0] = IFixedPriceSale.Phase(t, t + 100, 0, 0, false, false);
        phases[1] = IFixedPriceSale.Phase(t, t + 200, 0, 0, false, false);
        uint256 saleId = _open(creator, ETH_ED, phases);
        vm.warp(t + 150);
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, stranger));
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
        vm.warp(t + 200);
        vm.expectEmit(address(fixedSale));
        emit IFixedPriceSale.SaleClosed(saleId);
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
        assertEq(fixedSale.openSaleOf(address(editions), ETH_ED), 0);
    }

    /// Regression: the second review of #18
    function test_CloseSale_OpenEndedAndFuturePhasesBlockStrangers() public {
        uint64 t = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](2);
        phases[0] = IFixedPriceSale.Phase(t, t + 10, 0, 0, false, false);
        phases[1] = IFixedPriceSale.Phase(t + 1000, type(uint64).max, 0, 0, false, false);
        uint256 saleId = _open(creator, ETH_ED, phases);
        vm.warp(t + 500); // between phases: phase 1 has not started
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, stranger));
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
        vm.warp(type(uint64).max - 1); // an open-ended phase never ends
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, stranger));
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
    }

    /// Regression: the second review of #18
    /// @dev At exactly `end`, purchases stop and anyone may close: the two predicates agree.
    function test_CloseSale_TheBoundaryAgreesWithThePurchaseWindow() public {
        uint64 t = uint64(block.timestamp);
        uint256 saleId =
            _open(creator, ETH_ED, _one(IFixedPriceSale.Phase(t, t + 10, 0, 0, false, false)));
        vm.warp(t + 9);
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, stranger));
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
        vm.expectRevert(abi.encodeWithSelector(IMintSale.SaleAlreadyClosed.selector, saleId));
        vm.prank(platform);
        fixedSale.closeSale(saleId);
        // A stranger cannot reopen. The phase is an uncapped public one, which counts nothing
        // (QUALITY-1).
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, stranger));
        _open(stranger, ETH_ED, _one(_phase(0, 0, false, false)));
        assertEq(_bought(saleId, 0, alice), 0);
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
        // An uncapped public phase counts nothing (QUALITY-1).
        assertEq(_bought(saleId, 0, bob), 0);
    }

    function test_Purchase_RecipientDefaultsToPayer() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        _buyEth(alice, saleId, 0, address(0), 2, PRICE);
        assertEq(editions.balanceOf(alice, ETH_ED), 2);
        assertEq(_bought(saleId, 0, alice), 0, "an uncapped public phase counts nothing");
    }

    /// @dev QUALITY-1 (integrator decision): an uncapped public phase checks no count, so a
    ///      purchase in it writes no adapter storage at all (the reentrancy guard is transient)
    ///      and `purchased` stays zero.
    function test_Purchase_UncappedPublicPhaseRecordsNothing() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        _buyEth(alice, saleId, 0, alice, 1, PRICE);
        vm.deal(bob, PRICE);
        vm.record();
        vm.prank(bob);
        fixedSale.purchase{ value: PRICE }(
            _p(saleId, 0, bob, 1, 0, 0), new bytes32[](0), _eth(bob, PRICE)
        );
        (, bytes32[] memory writes) = vm.accesses(address(fixedSale));
        assertEq(writes.length, 0, "no adapter storage written");
        assertEq(editions.balanceOf(bob, ETH_ED), 1);
        assertEq(_bought(saleId, 0, bob), 0);
    }

    /// @dev QUALITY-1: a capped public phase still counts, and its cap holds across reopened
    ///      sales; purchases made earlier in an uncapped phase at the same index do not count
    ///      against it.
    function test_Purchase_CappedPublicPhaseCountsAcrossSales() public {
        uint256 uncapped = _openPublic(ETH_ED, 0);
        _buyEth(alice, uncapped, 0, alice, 3, PRICE);
        vm.prank(creator);
        fixedSale.closeSale(uncapped);
        uint256 capped = _openPublic(ETH_ED, 2);
        _buyEth(alice, capped, 0, alice, 2, PRICE);
        assertEq(_bought(capped, 0, alice), 2, "only the capped phase's purchases count");
        vm.prank(creator);
        fixedSale.closeSale(capped);
        uint256 again = _openPublic(ETH_ED, 2);
        vm.deal(alice, PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.WalletCapExceeded.selector, again, 0, alice)
        );
        vm.prank(alice);
        fixedSale.purchase{ value: PRICE }(
            _p(again, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, PRICE)
        );
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
        vm.expectRevert(IMintSale.InvalidQuantity.selector);
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
                ISaleAdapter.InvalidSaleTerms.selector, address(editions), ETH_ED
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
        vm.expectRevert(abi.encodeWithSelector(IMintSale.CurrencyNotActive.selector, CURRENCY_ETH));
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
            abi.encodeWithSelector(IMintSale.PricedDefaultCurrency.selector, address(editions), 9)
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
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.InvalidRecipient.selector, address(0)));
        vm.prank(alice);
        fixedSale.claim(CURRENCY_ETH, address(0));
    }

    /// Regression: a proof of concept in the review of #18
    /// @dev Also pins the event order indexers must handle: a recipient hook may close the sale
    ///      inside a purchase, so that purchase's `SaleSettled` follows `SaleClosed`.
    function test_Purchase_AReceiverHookThatClosesAndReopensIsHarmless() public {
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

    /// Regression: mutant L4 in the review of #18
    /// @dev A relayed intent with recipient 0 mints to the signer, never to the relayer.
    function test_Purchase_ARelayedZeroRecipientMintsToTheSigner() public {
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

    function _tokenSale(address token) internal returns (uint256 saleId) {
        uint256 id = uint256(uint160(token));
        allowlist.set(token, true);
        editions.setTerms(id, _terms(SaleKind.FIXED_PRICE, token, 10e18, ""), SIZE);
        saleId = _openPublic(id, 0);
    }

    /// Regression: mutant D1 in the review of #18
    /// @dev The adapter-side Permit2 delta is checked even when a donated balance would let the
    ///      payouts succeed.
    function test_Purchase_APermit2InboundShortfallReverts() public {
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

    /// Regression: mutant D2 in the review of #18
    /// @dev The payer-side Permit2 delta is checked.
    function test_Purchase_APermit2PayerOverDebitReverts() public {
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

    /// Regression: mutant D6 in the review of #18
    /// @dev Fixed price rejects ETH overpayment (it would otherwise be kept, uncredited).
    function test_Purchase_EthOverpaymentReverts() public {
        uint256 saleId = _openPublic(ETH_ED, 0);
        vm.deal(alice, 1 ether);
        vm.expectRevert(ISaleAdapter.InvalidPayment.selector);
        vm.prank(alice);
        fixedSale.purchase{ value: 2 * PRICE }(
            _p(saleId, 0, alice, 1, 0, 0), new bytes32[](0), _eth(alice, 2 * PRICE)
        );
        assertEq(address(fixedSale).balance, 0);
    }

    /// Regression: mutant W1 in the review of #18
    /// @dev A relayer cannot move a signed intent to another phase with the same price.
    function test_Purchase_AnIntentIsBoundToItsPhase() public {
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

    /// Regression: the second review of #18
    /// @dev The resolver is read only at open: a resolver that reverts afterwards blocks no
    ///      purchase.
    function test_Purchase_TheResolverIsNotOnThePurchasePath() public {
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

    /// Regression: the verified High finding in 6529Stream PR #744
    /// @dev In 6529Stream PR #744 a recipient-keyed leaf was checked against one address while
    ///      the tokens were minted to another, so anyone could spend another wallet's allowlist
    ///      entry for themselves. Here the leaf is checked against the wallet that receives the
    ///      tokens.
    function test_Allowlist_LeafBindsTheReceivingWallet() public {
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

    /// Regression: the PR #744 High finding, a proof of concept in the review of #18
    function test_Allowlist_NoDirectRouteMintsToSelfOnAnotherWalletsLeaf() public {
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

    /// Regression: the PR #744 High finding, a proof of concept in the review of #18
    function test_Allowlist_NoPermit2RouteMintsToSelfOnAnotherWalletsLeaf() public {
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

    /// Regression: a proof of concept (inverted) in the review of #18
    function test_Allowlist_CapsSurviveAReopenedSale_PlatformOnly() public {
        bytes32[] memory leaves = _leaves(
            ETH_ED, 0, _list3(alice, bob, creator), _nums3(1, 1, 1), _nums3(PRICE, PRICE, PRICE)
        );
        // Unpriced: alone, PLATFORM sells at the package price (MARKET-6).
        IFixedPriceSale.Phase[] memory phases = _one(_phase(_root(leaves), 0, false, false));
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
