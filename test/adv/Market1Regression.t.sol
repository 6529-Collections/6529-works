// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { Roles } from "src/governance/Roles.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { MarketPoCBase } from "./MarketPoCBase.sol";

/// @notice MARKET-1 regression, on the real stack: an emergency pause of the fixed-price or Dutch
///         adapter, or a deprecation of a sale's currency, stops the sale's schedule as well as
///         its purchases. On resumption the Dutch curve and the phase windows continue from
///         where they stopped (`scheduleDelay`).
contract Market1RegressionTest is MarketPoCBase {
    function _openDutchNow() internal returns (uint256 saleId, uint256 workId) {
        workId = _masterAndEdition(0);
        vm.prank(artist);
        saleId = dutchSale.openSale(address(editions), workId, uint64(block.timestamp));
    }

    function test_MARKET1_PauseStopsTheDutchCurve() public {
        (uint256 saleId, uint256 workId) = _openDutchNow();
        uint256 opened = block.timestamp;
        vm.warp(block.timestamp + 1 hours);
        uint256 priceAtPause = dutchSale.currentPrice(saleId);
        assertEq(priceAtPause, 0.9625 ether);
        _dutchBuy(saleId, makeAddr("earlyCollector"), 1);

        _govern(guardian1, address(dutchSale), abi.encodeCall(dutchSale.pause, ()));
        uint256 pausedAt = block.timestamp;
        bytes memory unpause = abi.encodeCall(dutchSale.unpause, ());
        _schedule(hotAdmin, address(dutchSale), unpause);
        vm.warp(block.timestamp + 1 days);
        assertEq(dutchSale.currentPrice(saleId), priceAtPause, "frozen while paused");
        assertEq(dutchSale.scheduleDelay(saleId), 1 days);
        vm.deal(fan, priceAtPause);
        vm.prank(fan);
        vm.expectRevert(ISaleAdapter.SalePaused.selector);
        dutchSale.purchase{ value: priceAtPause }(
            saleId,
            address(0),
            1,
            priceAtPause,
            Payment(PaymentMethod.DIRECT, fan, priceAtPause, 0, 0, "")
        );

        // The hot admin unpauses at the earliest, 48 hours after the pause.
        vm.warp(pausedAt + Roles.STANDARD);
        vm.prank(hotAdmin);
        manager.execute(address(dutchSale), unpause);
        assertEq(dutchSale.pausedTotal(), Roles.STANDARD);
        assertEq(dutchSale.scheduleDelay(saleId), Roles.STANDARD);
        assertEq(dutchSale.currentPrice(saleId), priceAtPause, "resumes at the pause price");

        // The first buyer after the unpause pays the price at which trading stopped.
        uint256 paid = _dutchBuy(saleId, bot, DUTCH_SIZE - 1);
        assertEq(paid, (DUTCH_SIZE - 1) * priceAtPause);
        assertEq(editions.balanceOf(bot, workId), DUTCH_SIZE - 1);

        // The curve's end moved by the paused time.
        uint256 restsAt = opened + DUTCH_DECAY + Roles.STANDARD;
        vm.warp(restsAt - 1);
        assertGt(dutchSale.currentPrice(saleId), DUTCH_REST);
        vm.warp(restsAt);
        assertEq(dutchSale.currentPrice(saleId), DUTCH_REST);
    }

    function test_MARKET1_PauseKeepsAnAllowlistPhaseOpenForItsRemainingLength() public {
        uint256 workId = _masterAndEdition(1);
        bytes32 leaf = fixedSale.allowlistLeaf(address(editions), workId, 0, fan, 5, FIXED_PRICE);
        uint64 t0 = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](2);
        phases[0] = IFixedPriceSale.Phase(t0, t0 + 24 hours, leaf, 0, false, false);
        phases[1] = IFixedPriceSale.Phase(t0 + 24 hours, t0 + 30 days, bytes32(0), 0, false, false);
        vm.prank(artist);
        uint256 saleId = fixedSale.openSale(
            address(editions), workId, phases, IFixedPriceSale.ArtistConsent(0, 0, "")
        );

        _govern(guardian1, address(fixedSale), abi.encodeCall(fixedSale.pause, ()));
        _govern(hotAdmin, address(fixedSale), abi.encodeCall(fixedSale.unpause, ()));
        assertEq(fixedSale.scheduleDelay(saleId), Roles.STANDARD);

        // The public phase has not started yet: it moved by the paused time too.
        uint256 total = FIXED_PRICE * FIXED_SIZE;
        vm.deal(bot, total);
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(IFixedPriceSale.PhaseNotOpen.selector, saleId, 1));
        fixedSale.purchase{ value: total }(
            IFixedPriceSale.Purchase(saleId, 1, bot, FIXED_SIZE, 0, 0),
            new bytes32[](0),
            Payment(PaymentMethod.DIRECT, bot, total, 0, 0, "")
        );

        // The allowlisted fan keeps the whole reserved window.
        vm.warp(t0 + Roles.STANDARD + 24 hours - 1);
        vm.deal(fan, FIXED_PRICE);
        vm.prank(fan);
        fixedSale.purchase{ value: FIXED_PRICE }(
            IFixedPriceSale.Purchase(saleId, 0, fan, 1, 5, FIXED_PRICE),
            new bytes32[](0),
            Payment(PaymentMethod.DIRECT, fan, FIXED_PRICE, 0, 0, "")
        );
        assertEq(editions.balanceOf(fan, workId), 1);
    }

    function test_MARKET1_AnyoneClosesOnlyOnceTheMovedPhasesEnded() public {
        uint256 workId = _masterAndEdition(1);
        uint64 t0 = uint64(block.timestamp);
        IFixedPriceSale.Phase[] memory phases = new IFixedPriceSale.Phase[](1);
        phases[0] = IFixedPriceSale.Phase(t0, t0 + 1 days, bytes32(0), 0, false, false);
        vm.prank(artist);
        uint256 saleId = fixedSale.openSale(
            address(editions), workId, phases, IFixedPriceSale.ArtistConsent(0, 0, "")
        );
        vm.prank(guardian1);
        fixedSale.pause();
        vm.warp(t0 + 1 days);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, stranger));
        fixedSale.closeSale(saleId);
        vm.warp(t0 + Roles.STANDARD);
        vm.prank(hotAdmin);
        manager.schedule(address(fixedSale), abi.encodeCall(fixedSale.unpause, ()), 0);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(hotAdmin);
        manager.execute(address(fixedSale), abi.encodeCall(fixedSale.unpause, ()));
        // Paused for four days: the one-day phase now ends at t0 + 5 days.
        vm.warp(t0 + 5 days - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NotSaleManager.selector, stranger));
        fixedSale.closeSale(saleId);
        vm.warp(t0 + 5 days);
        vm.expectEmit(address(fixedSale));
        emit IFixedPriceSale.SaleClosed(saleId);
        vm.prank(stranger);
        fixedSale.closeSale(saleId);
    }

    function test_MARKET1_CurrencyDeprecationStopsTheDutchCurve() public {
        (uint256 saleId,) = _openDutchNow();
        vm.warp(block.timestamp + 1 hours);
        uint256 priceAtFreeze = dutchSale.currentPrice(saleId);

        _govern(
            guardian1, address(allowlist), abi.encodeCall(allowlist.deprecateAsset, (CURRENCY_ETH))
        );
        uint256 frozenAt = block.timestamp;
        (IAssetAllowlist.Status status, uint256 since, uint256 inactive) =
            allowlist.statusClock(CURRENCY_ETH);
        assertEq(uint8(status), uint8(IAssetAllowlist.Status.Deprecated));
        assertEq(since, frozenAt);
        assertEq(inactive, 0);

        // Re-admission is a 14-day FUNDS_SETTER operation; the curve waits for it.
        (,, uint64 revision) = allowlist.assetConfig(CURRENCY_ETH);
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (CURRENCY_ETH, revision, 0.001 ether))
        );
        (status, since, inactive) = allowlist.statusClock(CURRENCY_ETH);
        assertEq(uint8(status), uint8(IAssetAllowlist.Status.Active));
        assertEq(since, block.timestamp);
        assertEq(inactive, block.timestamp - frozenAt);
        assertEq(dutchSale.scheduleDelay(saleId), Roles.FUNDS);
        assertEq(dutchSale.currentPrice(saleId), priceAtFreeze, "resumes at the freeze price");
        uint256 paid = _dutchBuy(saleId, bot, 1);
        assertEq(paid, priceAtFreeze);
    }

    /// @dev The allowlist's status clock: the time of the latest status change, and the sum of
    ///      closed deprecations, kept in the asset's status word.
    function test_MARKET1_AllowlistStatusClockSumsDeprecations() public {
        (IAssetAllowlist.Status status, uint256 since, uint256 inactive) =
            allowlist.statusClock(makeAddr("neverAdmitted"));
        assertEq(uint8(status), uint8(IAssetAllowlist.Status.None));
        assertEq(since + inactive, 0);
        uint256 total;
        for (uint256 i; i < 2; ++i) {
            vm.prank(guardian1);
            allowlist.deprecateAsset(CURRENCY_ETH);
            uint256 deprecatedAt = block.timestamp;
            (status, since, inactive) = allowlist.statusClock(CURRENCY_ETH);
            assertEq(since, deprecatedAt);
            assertEq(inactive, total, "a running deprecation is not in the total");
            (,, uint64 revision) = allowlist.assetConfig(CURRENCY_ETH);
            _govern(
                hotAdmin,
                address(allowlist),
                abi.encodeCall(allowlist.admitAsset, (CURRENCY_ETH, revision, 0.001 ether))
            );
            total += block.timestamp - deprecatedAt;
            (status, since, inactive) = allowlist.statusClock(CURRENCY_ETH);
            assertEq(uint8(status), uint8(IAssetAllowlist.Status.Active));
            assertEq(since, block.timestamp);
            assertEq(inactive, total);
            vm.warp(block.timestamp + 1 days);
        }
        assertEq(total, 2 * Roles.FUNDS);
    }

    function test_MARKET1_SaleOpenedAfterAHaltStartsWithNoDelay() public {
        _govern(guardian1, address(dutchSale), abi.encodeCall(dutchSale.pause, ()));
        _govern(hotAdmin, address(dutchSale), abi.encodeCall(dutchSale.unpause, ()));
        (uint256 saleId,) = _openDutchNow();
        assertEq(dutchSale.scheduleDelay(saleId), 0, "earlier halts do not move a later sale");
        assertEq(dutchSale.currentPrice(saleId), DUTCH_START);
    }
}
