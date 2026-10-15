// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionFormat, EditionTerms } from "src/interfaces/types/PackageTypes.sol";
import { DutchParams, Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { FixedPriceSale } from "src/sales/FixedPriceSale.sol";
import { MintSaleBase } from "src/sales/MintSaleBase.sol";
import { SalesStackBase } from "./SalesStackBase.sol";
import { IMintSale } from "src/interfaces/IMintSale.sol";

/// @notice Who may open and close an edition's sale, on the real stack (ADR 0001 section 6: the
///         artist chooses an edition's format and price within the package). Alone, PLATFORM
///         opens a sale only at the package price and only for an edition of FIXED size; a leaf
///         price (above or below the package price) or an OPEN edition's one-time window needs
///         the artist, who opens the sale or signs the phase configuration PLATFORM relays. A
///         sale the artist opened is the artist's to close.
contract EditionSaleAuthorityTest is SalesStackBase {
    function _consent(uint256 workId, IFixedPriceSale.Phase[] memory phases, uint256 price)
        internal
        view
        returns (IFixedPriceSale.ArtistConsent memory)
    {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes32 digest = fixedSale.phaseConfigurationDigest(
            address(editions), workId, CURRENCY_ETH, price, phases, 1, deadline
        );
        return IFixedPriceSale.ArtistConsent(1, deadline, _sign(artist, digest));
    }

    function _buy(uint256 saleId, uint256 phase, address buyer, uint256 cap, uint256 price)
        internal
    {
        vm.deal(buyer, price);
        vm.prank(buyer);
        fixedSale.purchase{ value: price }(
            IFixedPriceSale.Purchase(saleId, phase, buyer, 1, cap, price),
            new bytes32[](0),
            Payment(PaymentMethod.DIRECT, buyer, price, 0, 0, "")
        );
    }

    /// Regression: MARKET-6 (docs/security/internal-review-2026-10.md)
    function test_OpenSale_PlatformAloneCannotPriceAboveThePackage() public {
        uint256 workId = _masterAndEdition(1);
        uint256 premium = 3 * FIXED_PRICE;
        bytes32 leaf = fixedSale.allowlistLeaf(address(editions), workId, 0, fan, 10, premium);
        uint64 t0 = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(t0, t0 + 30 days, leaf, 0, false, true);
        vm.prank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFixedPriceSale.PricedLeavesNeedApproval.selector, address(editions), workId
            )
        );
        fixedSale.openSale(
            address(editions), workId, phases, IFixedPriceSale.ArtistConsent(0, 0, "")
        );

        // With the artist's signed configuration PLATFORM may relay the premium phase.
        IFixedPriceSale.ArtistConsent memory consent = _consent(workId, phases, FIXED_PRICE);
        vm.prank(platform);
        uint256 saleId = fixedSale.openSale(address(editions), workId, phases, consent);
        (, bool approved,) = fixedSale.sale(saleId);
        assertTrue(approved);
        _buy(saleId, 0, fan, 10, premium);
        assertEq(editions.balanceOf(fan, workId), 1);
    }

    /// Regression: MARKET-6 (docs/security/internal-review-2026-10.md)
    function test_OpenSale_PlatformAloneStillOpensAtThePackagePrice() public {
        uint256 workId = _masterAndEdition(1);
        uint64 t0 = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(t0, t0 + 30 days, bytes32(0), 1, false, false);
        vm.prank(platform);
        uint256 saleId = fixedSale.openSale(
            address(editions), workId, phases, IFixedPriceSale.ArtistConsent(0, 0, "")
        );
        _buy(saleId, 0, fan, 0, FIXED_PRICE);
        assertEq(editions.balanceOf(fan, workId), 1);
    }

    /// Regression: MARKET-6 (docs/security/internal-review-2026-10.md)
    function test_OpenSale_PlatformAloneCannotSpendAnOpenWindow() public {
        uint256 workId = _masterAndEdition(3);
        uint64 t0 = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(t0, t0 + 365 days, bytes32(0), 1, false, false);
        vm.prank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintSale.ArtistApprovalRequired.selector, address(editions), workId
            )
        );
        fixedSale.openSale(
            address(editions), workId, phases, IFixedPriceSale.ArtistConsent(0, 0, "")
        );

        // The artist's planned drop three days later gets the whole window.
        vm.warp(block.timestamp + 3 days);
        t0 = uint64(block.timestamp);
        phases[0] = IFixedPriceSale.Phase(t0, t0 + 2 days, bytes32(0), 0, false, false);
        vm.prank(artist);
        uint256 planned = fixedSale.openSale(
            address(editions), workId, phases, IFixedPriceSale.ArtistConsent(0, 0, "")
        );
        _buy(planned, 0, fan, 0, FIXED_PRICE);
        vm.warp(block.timestamp + 47 hours);
        _buy(planned, 0, makeAddr("lateFan"), 0, FIXED_PRICE);
        assertEq(editions.balanceOf(fan, workId), 1);
    }

    /// Regression: MARKET-6 (docs/security/internal-review-2026-10.md)
    function test_OpenSale_PlatformMayRelayTheArtistsOpenEditionDrop() public {
        uint256 workId = _masterAndEdition(3);
        uint64 t0 = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(t0, t0 + 2 days, bytes32(0), 0, false, false);
        IFixedPriceSale.ArtistConsent memory consent = _consent(workId, phases, FIXED_PRICE);
        vm.prank(platform);
        uint256 saleId = fixedSale.openSale(address(editions), workId, phases, consent);
        _buy(saleId, 0, fan, 0, FIXED_PRICE);
        assertEq(editions.balanceOf(fan, workId), 1);
    }

    /// Regression: MARKET-6 (docs/security/internal-review-2026-10.md)
    /// @dev Dutch has no phase configuration to sign: PLATFORM may open a FIXED edition's curve,
    ///      and only the artist opens an OPEN one.
    function test_OpenSale_PlatformAloneCannotOpenAnOpenDutchEdition() public {
        uint256 fixedId = _masterAndEdition(0);
        vm.prank(platform);
        dutchSale.openSale(address(editions), fixedId, uint64(block.timestamp));

        Work[] memory works = new Work[](1);
        works[0] = _master(
            _work(artist, collectionId),
            EditionTerms(
                EditionFormat.OPEN,
                0,
                48 hours,
                DUTCH_START,
                CURRENCY_ETH,
                SaleKind.DUTCH,
                abi.encode(DutchParams(DUTCH_REST, DUTCH_DECAY, 0))
            )
        );
        bytes32 openRoot = _publish(works);
        (uint256 saleId, uint256 openId) = _start(openRoot, works, 0);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
        editions.createEdition(openId, works[0].item, openRoot, _proofOf(works, 0));

        vm.prank(platform);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintSale.ArtistApprovalRequired.selector, address(editions), openId
            )
        );
        dutchSale.openSale(address(editions), openId, uint64(block.timestamp));
        vm.prank(artist);
        dutchSale.openSale(address(editions), openId, uint64(block.timestamp));
    }

    function _openDutchEdition() internal returns (uint256 openId) {
        Work[] memory works = new Work[](1);
        works[0] = _master(
            _work(artist, collectionId),
            EditionTerms(
                EditionFormat.OPEN,
                0,
                48 hours,
                DUTCH_START,
                CURRENCY_ETH,
                SaleKind.DUTCH,
                abi.encode(DutchParams(DUTCH_REST, DUTCH_DECAY, 0))
            )
        );
        bytes32 openRoot = _publish(works);
        uint256 saleId;
        (saleId, openId) = _start(openRoot, works, 0);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
        editions.createEdition(openId, works[0].item, openRoot, _proofOf(works, 0));
    }

    /// Regression: MARKET-6 (docs/security/internal-review-2026-10.md); L-a in the review of #57
    /// @dev A Dutch sale the creator opened is the artist's, as on fixed price: PLATFORM cannot
    ///      close it mid-window; the artist can. PLATFORM still closes a sale it opened alone.
    function test_CloseSale_PlatformCannotCloseTheArtistsOwnDutchSale() public {
        uint256 openId = _openDutchEdition();
        vm.prank(artist);
        uint256 saleId = dutchSale.openSale(address(editions), openId, uint64(block.timestamp));
        _dutchBuy(saleId, fan, 1);
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, platform));
        dutchSale.closeSale(saleId);
        assertEq(dutchSale.openSaleOf(address(editions), openId), saleId);
        vm.prank(artist);
        dutchSale.closeSale(saleId);

        uint256 fixedId = _masterAndEdition(0);
        vm.prank(platform);
        uint256 platformSale =
            dutchSale.openSale(address(editions), fixedId, uint64(block.timestamp));
        vm.prank(platform);
        dutchSale.closeSale(platformSale);
        assertEq(dutchSale.openSaleOf(address(editions), fixedId), 0);
    }
}
