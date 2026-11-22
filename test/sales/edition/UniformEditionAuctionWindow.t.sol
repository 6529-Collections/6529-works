// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { UniformEditionAuction } from "src/sales/UniformEditionAuction.sol";
import { UniformEditionAuctionLens } from "src/sales/UniformEditionAuctionLens.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice The edition's open period (R20: every sale closes exactly 15 minutes after its 1/1),
///         the governed payout gas, and the 32-bit clocks at their bound (EA-17, EA-18).
contract UniformEditionAuctionWindowTest is EditionAuctionBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _oneEnd() internal view returns (uint256) {
        return english.auction(english.saleIdOf(address(stream), ID)).endTime;
    }

    // ------------------------------------------------------------------ the window

    /// @dev The close is the 1/1's end plus 15 minutes, whatever the governed parameters; a
    ///      bid at the close is refused, one a second before is taken.
    function test_Window_FifteenMinutesAfterTheOneOfOne() public {
        uint256 saleId = _open(0);
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(e.closeAt, _oneEnd() + 15 minutes);
        assertEq(e.backstop, _oneEnd() + 15 minutes + 1 days);
        // A governance change after the open changes nothing about the close.
        IUniformEditionAuction.AuctionConfig memory c = defaultConfig();
        c.marginShare = 20_000;
        _setConfig(c);
        assertEq(ua.endTimes(saleId).closeAt, e.closeAt);
        vm.warp(e.closeAt - 5 minutes - 1);
        _bid(saleId, alice, 3, 1);
        vm.warp(e.closeAt);
        uint256 price = _price(saleId, 3);
        vm.deal(bob, price);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.BiddingClosed.selector, saleId, uint64(e.closeAt)
            )
        );
        auction.bid{ value: price }(saleId, 3, 1);
    }

    /// @dev Fuzz: whatever the 1/1's end, the close is exactly 15 minutes after it.
    function testFuzz_Window_TheCloseIsTheOneOfOneEndPlusFifteenMinutes(uint32 extra) public {
        uint256 end = block.timestamp + 1 hours + uint256(extra) % 30 days;
        english.set(address(stream), ID, IEnglishAuction.AuctionState.ACTIVE, uint64(end));
        uint256 saleId = _open(0);
        IUniformEditionAuction.EndTimes memory e = ua.endTimes(saleId);
        assertEq(e.closeAt, end + 15 minutes);
        assertEq(e.backstop, end + 15 minutes + 1 days);
    }

    // ------------------------------------------------------------------ the limits

    function test_SetLimits_CompareAndSetBoundsAndEvent() public {
        IUniformEditionAuction.Limits memory next = IUniformEditionAuction.Limits(200_000);
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.LimitsSet(100_000, 200_000);
        _setLimits(next);
        assertEq(ua.limits().payoutGas, 200_000);
        // A stale expectation.
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setLimits(100_000, 200_000);
        // Each bound, one past it; the payout gas only rises, at most doubling per change.
        uint256[4] memory bad = [uint256(29_999), 3_000_001, 199_999, 400_001];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
            auction.setLimits(200_000, bad[i]);
        }
        // The edges; the payout gas doubles to its ceiling and stays there.
        _setLimits(IUniformEditionAuction.Limits(400_000));
        _setLimits(IUniformEditionAuction.Limits(800_000));
        _setLimits(IUniformEditionAuction.Limits(1_600_000));
        _setLimits(IUniformEditionAuction.Limits(3_000_000));
        // Restricted.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setLimits(0, 0);
    }

    // ------------------------------------------------------------------ the clocks

    /// @dev Every stored time is 32 bits. An open at or past 2^32 seconds is refused; a soft end
    ///      that would pass 2^32 reverts the bid (`ClockOverflow`) instead of wrapping.
    function test_Clocks_RevertAtTheBoundInsteadOfWrapping() public {
        uint256 limit = type(uint32).max;
        // A sale opened just before the bound, closing a few seconds before it.
        vm.warp(limit - 2 hours);
        english.set(
            address(stream),
            ID,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(limit - 15 minutes - 10)
        );
        uint256 saleId = _open(0);
        // A bid in the window would push the soft end past 2^32 - 1.
        vm.warp(limit - 60);
        uint256 price = ua.stepPrice(saleId, 1);
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.ClockOverflow.selector, limit - 60 + 5 minutes
            )
        );
        auction.bid{ value: price }(saleId, 1, 1);
        // An open past the bound.
        vm.warp(limit + 1);
        english.set(address(stream), 9, IEnglishAuction.AuctionState.ACTIVE, uint64(limit + 1 days));
        PackageItem memory item = _item(9, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(editions), 9)
        );
        auction.open(address(editions), 9, _openData(item));
    }

    // ------------------------------------------------------------------ the gas rule (see also
    //                                                                     the GasRule suite)

    /// @dev The 1/1's clock is read forwarding all gas: one that runs out reverts the open with
    ///      `BoundedCallShortfall`, never reads as a missing 1/1; one that refuses is a missing 1/1.
    function test_GasRule_ARefusedOrStarvedClockAtOpen() public {
        PackageItem memory item = _item(ID, 0);
        english.setRefuseClock(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.NoOneOfOneAuction.selector, address(stream), ID
            )
        );
        auction.open(address(editions), ID, _openData(item));
        english.setRefuseClock(false);
        english.setBurnClock(true);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(english))
        );
        auction.open{ gas: 2_000_000 }(address(editions), ID, _openData(item));
    }

    /// @dev The clearing call seals the edition at the count sold (ED-25), with Editions' event.
    function test_Settle_SealsTheEditionAtTheCount() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 10, 2);
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        vm.expectEmit(address(editions));
        emit IEditions.EditionSupplySealed(ID, 2);
        auction.settle(saleId, new uint256[](0));
    }

    /// @dev The payout gas's bounds are exact (found by mutation testing): a new auction takes
    ///      exactly 30,000 and refuses one gas less; from 1,600,000 the governed figure reaches
    ///      exactly 3,000,000 and is refused one gas above it, though that is below double.
    function test_SetLimits_TheBoundsAreExact() public {
        address l = address(
            new UniformEditionAuctionLens(
                address(editions), address(stream), address(english), address(escrow)
            )
        );
        vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
        new UniformEditionAuction(
            address(manager),
            address(escrow),
            address(editions),
            address(english),
            l,
            l.codehash,
            defaultConfig(),
            IUniformEditionAuction.Limits(29_999)
        );
        UniformEditionAuction low = new UniformEditionAuction(
            address(manager),
            address(escrow),
            address(editions),
            address(english),
            l,
            l.codehash,
            defaultConfig(),
            IUniformEditionAuction.Limits(30_000)
        );
        assertEq(IUniformEditionAuction(address(low)).limits().payoutGas, 30_000);
        _setLimits(IUniformEditionAuction.Limits(200_000));
        _setLimits(IUniformEditionAuction.Limits(400_000));
        _setLimits(IUniformEditionAuction.Limits(800_000));
        _setLimits(IUniformEditionAuction.Limits(1_600_000));
        vm.expectRevert(IUniformEditionAuction.InvalidConfig.selector);
        auction.setLimits(1_600_000, 3_000_001);
        _setLimits(IUniformEditionAuction.Limits(3_000_000));
        assertEq(ua.limits().payoutGas, 3_000_000);
    }
}
