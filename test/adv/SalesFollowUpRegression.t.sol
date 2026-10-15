// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { Roles } from "src/governance/Roles.sol";
import { IDutchSale } from "src/interfaces/IDutchSale.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { EditionFormat, EditionTerms } from "src/interfaces/types/PackageTypes.sol";
import { DutchParams, Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { MarketPoCBase } from "./MarketPoCBase.sol";
import { IMintSale } from "src/interfaces/IMintSale.sol";

/// @notice Follow-ups from the review of the sales fixes, on the real stack: the halt clock's
///         documented double count, the 48-hour floor on `cancel` and on re-admission, and the
///         schedule moves the earlier regressions did not pin down (a running deprecation in
///         views and in the anyone-may-close rule, and a Dutch start not yet reached).
contract SalesFollowUpRegressionTest is MarketPoCBase {
    function _deprecateEth() internal {
        _govern(
            guardian1, address(allowlist), abi.encodeCall(allowlist.deprecateAsset, (CURRENCY_ETH))
        );
    }

    function _readmitEth() internal {
        (,, uint64 revision) = allowlist.assetConfig(CURRENCY_ETH);
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (CURRENCY_ETH, revision, 0.001 ether))
        );
    }

    // ------------------------------------------- MARKET-1: documented double count (L1)

    /// @dev Documents a known limit: an adapter pause during a deprecation of the sale's
    ///      currency counts twice, so the Dutch curve does not resume where it stopped but rewinds
    ///      by the overlap (here back to the start price, and the sale is "not open" again for a
    ///      while). The guardian runbook says not to pause an adapter during a deprecation, or to
    ///      close and reopen the affected sales afterwards.
    function test_MARKET1_OverlappingHaltsCountTwice_DutchCurveRewinds() public {
        uint256 workId = _masterAndEdition(0);
        vm.prank(artist);
        uint256 saleId = dutchSale.openSale(address(editions), workId, uint64(block.timestamp));
        vm.warp(block.timestamp + 20 hours);
        _dutchBuy(saleId, makeAddr("earlyBuyer"), 1);

        _deprecateEth();
        _govern(guardian1, address(dutchSale), abi.encodeCall(dutchSale.pause, ()));
        uint256 haltStart = block.timestamp;
        _govern(hotAdmin, address(dutchSale), abi.encodeCall(dutchSale.unpause, ()));
        _readmitEth();
        uint256 realHalt = block.timestamp - haltStart;
        assertEq(realHalt, Roles.STANDARD + Roles.FUNDS);
        assertEq(dutchSale.scheduleDelay(saleId), realHalt + Roles.STANDARD, "counted twice");
        assertEq(dutchSale.currentPrice(saleId), DUTCH_START, "rewound to the start price");
        vm.deal(bot, 1 ether);
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IDutchSale.SaleNotOpen.selector, saleId));
        dutchSale.purchase{ value: 1 ether }(
            saleId, address(0), 1, 1 ether, Payment(PaymentMethod.DIRECT, bot, 1 ether, 0, 0, "")
        );
    }

    /// @dev Documents the same limit for fixed price: the overlap reopens an allowlist phase that
    ///      had ended, and closes the public phase that was running when trading stopped.
    function test_MARKET1_OverlappingHaltsCountTwice_EndedAllowlistPhaseReopens() public {
        uint256 workId = _masterAndEdition(1);
        bytes32 leaf = fixedSale.allowlistLeaf(address(editions), workId, 0, fan, 5, FIXED_PRICE);
        uint64 t0 = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](2);
        phases[0] = IFixedPriceSale.Phase(t0, t0 + 3 days, leaf, 0, false, false);
        phases[1] = IFixedPriceSale.Phase(t0 + 3 days, t0 + 30 days, bytes32(0), 0, false, false);
        vm.prank(artist);
        uint256 saleId = fixedSale.openSale(
            address(editions), workId, phases, IFixedPriceSale.ArtistConsent(0, 0, "")
        );
        vm.warp(t0 + 3 days + 1 hours);
        _deprecateEth();
        _govern(guardian1, address(fixedSale), abi.encodeCall(fixedSale.pause, ()));
        _govern(hotAdmin, address(fixedSale), abi.encodeCall(fixedSale.unpause, ()));
        _readmitEth();

        vm.deal(bot, FIXED_PRICE);
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IFixedPriceSale.PhaseNotOpen.selector, saleId, 1));
        fixedSale.purchase{ value: FIXED_PRICE }(
            IFixedPriceSale.Purchase(saleId, 1, bot, 1, 0, 0),
            new bytes32[](0),
            Payment(PaymentMethod.DIRECT, bot, FIXED_PRICE, 0, 0, "")
        );
        vm.deal(fan, FIXED_PRICE);
        vm.prank(fan);
        fixedSale.purchase{ value: FIXED_PRICE }(
            IFixedPriceSale.Purchase(saleId, 0, fan, 1, 5, FIXED_PRICE),
            new bytes32[](0),
            Payment(PaymentMethod.DIRECT, fan, FIXED_PRICE, 0, 0, "")
        );
        assertEq(editions.balanceOf(fan, workId), 1, "the ended allowlist phase sold again");
    }

    // ------------------------------------------- MARKET-1: schedule moves (mutants M5, M42)

    /// @dev A deprecation still running moves the schedule in the views and in the
    ///      anyone-may-close rule, not only once it ends.
    function test_MARKET1_ARunningDeprecationMovesViewsAndTheCloseRule() public {
        uint256 dutchId = _masterAndEdition(0);
        vm.prank(artist);
        uint256 dutch = dutchSale.openSale(address(editions), dutchId, uint64(block.timestamp));
        uint256 fixedId = _masterAndEdition(1);
        uint64 t0 = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(t0, t0 + 1 days, bytes32(0), 0, false, false);
        vm.prank(artist);
        uint256 fixedId2 = fixedSale.openSale(
            address(editions), fixedId, phases, IFixedPriceSale.ArtistConsent(0, 0, "")
        );

        vm.warp(t0 + 1 hours);
        uint256 priceAtFreeze = dutchSale.currentPrice(dutch);
        _deprecateEth();
        vm.warp(t0 + 2 days);
        assertEq(dutchSale.scheduleDelay(dutch), 2 days - 1 hours);
        assertEq(fixedSale.scheduleDelay(fixedId2), 2 days - 1 hours);
        assertEq(dutchSale.currentPrice(dutch), priceAtFreeze, "the curve waits");
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, stranger));
        fixedSale.closeSale(fixedId2);
    }

    /// @dev A halt before a Dutch sale's start moves its start too.
    function test_MARKET1_AHaltBeforeTheStartMovesTheDutchStart() public {
        uint256 workId = _masterAndEdition(0);
        uint64 startTime = uint64(block.timestamp + 1 days);
        vm.prank(artist);
        uint256 saleId = dutchSale.openSale(address(editions), workId, startTime);
        _govern(guardian1, address(dutchSale), abi.encodeCall(dutchSale.pause, ()));
        _govern(hotAdmin, address(dutchSale), abi.encodeCall(dutchSale.unpause, ()));
        assertGt(block.timestamp, startTime, "the configured start has passed");
        vm.deal(bot, DUTCH_START);
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IDutchSale.SaleNotOpen.selector, saleId));
        dutchSale.purchase{ value: DUTCH_START }(
            saleId,
            address(0),
            1,
            DUTCH_START,
            Payment(PaymentMethod.DIRECT, bot, DUTCH_START, 0, 0, "")
        );
        vm.warp(startTime + Roles.STANDARD);
        assertEq(dutchSale.currentPrice(saleId), DUTCH_START);
        assertEq(_dutchBuy(saleId, bot, 1), DUTCH_START, "opens at the start price");
    }

    // ------------------------------------------- 48-hour floors (L4, re-admission)

    /// @dev LIFECYCLE-4 follow-up (L4): a cancel scheduled before the pause, for a predictable
    ///      sale and outcome, cannot land in the pause's own block; the guardians keep the
    ///      48-hour window to cancel it.
    function test_LIFECYCLE4_ACancelScheduledBeforeThePauseWaitsForItsWindow() public {
        uint256 t0 = block.timestamp;
        uint256 snap = vm.snapshotState();
        (uint256 saleId, uint256 tokenId) = _disputedNextWork(t0);
        bytes32 predicted = _platformStatement(
            address(stream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
        );
        vm.revertToState(snap);

        bytes memory cancel = abi.encodeCall(auction.cancel, (saleId, predicted));
        _schedule(hotAdmin, address(auction), cancel);
        (uint256 again, uint256 sameToken) = _disputedNextWork(t0);
        assertEq(again, saleId);
        assertEq(
            _platformStatement(
                address(stream), sameToken, StatementKinds.DISPUTE_OUTCOME, "ar://upheld"
            ),
            predicted
        );
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.UnpauseTooEarly.selector, block.timestamp + Roles.STANDARD
            )
        );
        manager.execute(address(auction), cancel);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.PAUSED));
        vm.prank(guardian2);
        manager.cancel(hotAdmin, address(auction), cancel);
    }

    function _disputedNextWork(uint256 t0) internal returns (uint256 saleId, uint256 tokenId) {
        vm.warp(t0 + 47 hours);
        Work[] memory works = _package(root);
        (saleId, tokenId) = _start(root, works, 2);
        _ethBid(saleId, makeAddr("bidder"), 1 ether);
        vm.warp(t0 + 49 hours);
        vm.prank(guardian1);
        auction.pause(saleId, keccak256("dispute"));
    }

    /// @dev Re-pausing after an unpause restarts the 48 hours (GOV-5).
    function test_GOV5_PauseUnpausePauseRestartsTheClock() public {
        _govern(guardian1, address(fixedSale), abi.encodeCall(fixedSale.pause, ()));
        bytes memory unpause = abi.encodeCall(fixedSale.unpause, ());
        _govern(hotAdmin, address(fixedSale), unpause);
        _schedule(hotAdmin, address(fixedSale), unpause);
        vm.warp(block.timestamp + Roles.STANDARD);
        _govern(guardian1, address(fixedSale), abi.encodeCall(fixedSale.pause, ()));
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.UnpauseTooEarly.selector, block.timestamp + Roles.STANDARD
            )
        );
        manager.execute(address(fixedSale), unpause);
        assertTrue(fixedSale.paused());
    }

    /// @dev A re-admission scheduled before a deprecation, for its predictable revision, cannot
    ///      undo it in the same block: re-admission waits 14 days from the deprecation.
    function test_MARKET2_AReadmissionScheduledAheadCannotUndoADeprecation() public {
        (,, uint64 revision) = allowlist.assetConfig(CURRENCY_ETH);
        bytes memory admit =
            abi.encodeCall(allowlist.admitAsset, (CURRENCY_ETH, revision + 1, 0.001 ether));
        _schedule(hotAdmin, address(allowlist), admit);
        vm.warp(block.timestamp + Roles.FUNDS);
        _deprecateEth();
        vm.prank(hotAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetAllowlist.ReadmissionTooEarly.selector,
                CURRENCY_ETH,
                block.timestamp + Roles.FUNDS
            )
        );
        manager.execute(address(allowlist), admit);
        assertFalse(allowlist.isActive(CURRENCY_ETH));
        // The guardians veto it; a fresh re-admission lands 14 days after the deprecation.
        vm.prank(guardian2);
        manager.cancel(hotAdmin, address(allowlist), admit);
        _readmitEth();
        assertTrue(allowlist.isActive(CURRENCY_ETH));
    }

    // ------------------------------------------- MARKET-6: closing Dutch sales (L-a)

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

    /// @dev A Dutch sale the creator opened is the artist's, as on fixed price: PLATFORM cannot
    ///      close it mid-window; the artist can. PLATFORM still closes a sale it opened alone.
    function test_MARKET6_PlatformCannotCloseTheArtistsOwnDutchSale() public {
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
