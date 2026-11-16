// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { IUniformEditionAuctionStorage } from "src/interfaces/IUniformEditionAuctionStorage.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice The exit for a sale whose master can never be settled (`abandon`, EA-19): after its
///         end plus its locked abandonment delay, with the 1/1 neither in progress nor settled
///         with its master and edition, anyone voids it; every bid is refunded in full, nothing
///         is minted or paid, and the edition is sealed at zero.
contract UniformEditionAuctionAbandonTest is EditionAuctionBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal saleId;

    function setUp() public override {
        super.setUp();
        saleId = _open(0);
        _bid(saleId, alice, 10, 2);
        _bid(saleId, bob, 20, 3);
    }

    function _oneEnd() internal view returns (uint64) {
        return english.auction(english.saleIdOf(address(stream), ID)).endTime;
    }

    function _setOneOfOne(IEnglishAuction.AuctionState state) internal {
        english.set(address(stream), ID, state, _oneEnd());
    }

    /// @dev The earliest abandonment: the sale's end plus 150 days.
    function _deadline() internal view returns (uint256) {
        return ua.endTimes(saleId).endTime + 150 days;
    }

    function _expectNotAbandonable() internal {
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        auction.abandon(saleId);
    }

    function _abandonAndRefund() internal {
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionVoided(saleId);
        vm.expectEmit(address(editions));
        emit IEditions.EditionSupplySealed(ID, 0);
        vm.prank(makeAddr("anyone"));
        auction.abandon(saleId);
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertTrue(editions.sealed_(ID));
        assertEq(editions.sealedCount(ID), 0, "sealed at zero");
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        assertEq(_claimAll(saleId), 0, "nothing minted");
        assertEq(alice.balance - aliceBefore, 2 * _price(saleId, 10), "alice in full");
        assertEq(bob.balance - bobBefore, 3 * _price(saleId, 20), "bob in full");
        assertEq(address(auction).balance, 0);
        _assertConserved();
        // Final: the sale cannot be abandoned or settled again.
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        auction.abandon(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.VOID
            )
        );
        auction.settle(saleId, new uint256[](0));
    }

    /// @dev The master never settles: the 1/1 ended, its settlement failing for good. Refused
    ///      until the end plus the delay, then anyone voids it.
    function test_Abandon_AMasterNeverSettled() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, _deadline());
        vm.warp(_deadline() - 1);
        _expectNotAbandonable();
        vm.warp(_deadline());
        (ok,) = ua.abandonable(saleId);
        assertTrue(ok);
        _abandonAndRefund();
    }

    /// @dev Merely slow: the master settles late, before anyone abandons; the sale then
    ///      settles as usual and can no longer be abandoned.
    function test_Abandon_AMasterSettledLateSettlesInstead() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        vm.warp(_deadline() + 10 days);
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        stream.setSettled(ID, true);
        editions.setExists(ID, true);
        _expectNotAbandonable();
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, 0);
        _settle(saleId);
        assertEq(_claimAll(saleId), 5);
        _assertConserved();
    }

    /// @dev A master settled after the sale was abandoned changes nothing: the sale stays void
    ///      and the edition sealed at zero.
    function test_Abandon_AMasterSettledAfterTheVoidStaysVoid() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        vm.warp(_deadline());
        _abandonAndRefund();
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        stream.setSettled(ID, true);
        editions.setExists(ID, true);
        assertEq(editions.sealedCount(ID), 0);
    }

    /// @dev A 1/1 in progress is never abandoned, however late: ACTIVE or PAUSED (a dispute).
    function test_Abandon_NeverWhileTheOneOfOneIsInProgress() public {
        vm.warp(_deadline() + 365 days);
        _setOneOfOne(IEnglishAuction.AuctionState.ACTIVE);
        _expectNotAbandonable();
        _setOneOfOne(IEnglishAuction.AuctionState.PAUSED);
        _expectNotAbandonable();
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, 0);
    }

    /// @dev A cancelled 1/1: `settle` voids at once; `abandon` also may after the delay.
    function test_Abandon_ACancelledMaster() public {
        _setOneOfOne(IEnglishAuction.AuctionState.CANCELLED);
        _expectNotAbandonable();
        vm.warp(_deadline());
        _abandonAndRefund();
    }

    /// @dev A rescued master (6529 Stream records it settled, RESCUED) whose 1/1 the English
    ///      auction closed: the sale settles as usual once the edition exists, so it is refused.
    function test_Abandon_ARescuedMasterSettlesInstead() public {
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        stream.setSettled(ID, true);
        editions.setExists(ID, true);
        vm.warp(_deadline());
        _expectNotAbandonable();
    }

    /// @dev A rescued master whose 1/1 the English auction can never close (still ENDED): the
    ///      sale could never begin settling, so it is abandoned after the delay.
    function test_Abandon_ARescuedMasterWhoseAuctionNeverCloses() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        stream.setSettled(ID, true);
        vm.warp(_deadline());
        _abandonAndRefund();
    }

    /// @dev Settled with its master, but the edition was never created: a sale with winners can
    ///      never clear, so it is abandoned after the delay.
    function test_Abandon_AnEditionNeverCreated() public {
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        stream.setSettled(ID, true);
        vm.warp(ua.endTimes(saleId).endTime);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.EditionNotCreated.selector, address(editions), ID
            )
        );
        auction.settle(saleId, new uint256[](0));
        vm.warp(_deadline());
        _abandonAndRefund();
    }

    /// @dev The 1/1 reported SETTLED but 6529 Stream's record unsettled: the edition can never
    ///      be created, so it is abandoned after the delay.
    function test_Abandon_ASettledAuctionWithAnUnsettledMaster() public {
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        vm.warp(_deadline());
        _abandonAndRefund();
    }

    /// @dev A broken English auction (its clock refuses): the end last read counts, and the sale
    ///      is abandoned after the delay. A clock that runs out of gas reverts, never refuses.
    function test_Abandon_ABrokenEnglishAuction() public {
        uint256 deadline = _deadline();
        english.setRefuseClock(true);
        vm.warp(deadline - 1);
        _expectNotAbandonable();
        vm.warp(deadline);
        english.setBurnClock(true);
        english.setRefuseClock(false);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(english))
        );
        auction.abandon{ gas: 2_000_000 }(saleId);
        english.setBurnClock(false);
        english.setRefuseClock(true);
        _abandonAndRefund();
    }

    /// @dev The delay is the one locked at open: governance changing it changes nothing.
    function test_Abandon_TheDelayIsLockedAtOpen() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        uint256 deadline = _deadline();
        IUniformEditionAuction.Limits memory l = defaultLimits();
        l.voidDelayDays = 730;
        _setLimits(l);
        assertEq(_deadline(), deadline);
        vm.warp(deadline);
        _abandonAndRefund();
    }

    /// @dev A sale that has paid is never abandoned: SETTLED, or SETTLING after its clearing.
    function test_Abandon_NeverAPaidSale() public {
        _settle(saleId);
        vm.warp(block.timestamp + 1000 days);
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        _expectNotAbandonable();
    }

    /// @dev A wide book's settlement stalls in its last scan call when the edition was never
    ///      created (the sale is SETTLING, nothing paid): it can still be abandoned.
    function test_Abandon_AScanStalledForWantOfTheEdition() public {
        _bid(saleId, alice, 335, 1); // the book spans more than 24 words
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        stream.setSettled(ID, true);
        vm.warp(ua.endTimes(saleId).endTime);
        assertFalse(auction.settle(saleId, new uint256[](0)), "the first scan call");
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.EditionNotCreated.selector, address(editions), ID
            )
        );
        auction.settle(saleId, new uint256[](0));
        vm.warp(_deadline());
        vm.expectEmit(address(editions));
        emit IEditions.EditionSupplySealed(ID, 0);
        auction.abandon(saleId);
        _claimAll(saleId);
        assertEq(address(auction).balance, 0);
        _assertConserved();
    }

    /// @dev L-3 (review A): the adapter enforces the time floor itself, from its own words. A
    ///      lens that answers early (here its `checkAbandon` is made to pass) cannot void a sale
    ///      or seal its edition before the stored close plus the locked delay.
    function test_Abandon_TheAdapterRefusesALensThatAnswersEarly() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        address l = IUniformEditionAuctionStorage(address(auction)).lens();
        vm.mockCall(l, abi.encodeWithSelector(IUniformEditionAuctionLens.checkAbandon.selector), "");
        uint256 floor = uint256(_oneEnd()) + 15 minutes + 150 days;
        vm.warp(floor - 1);
        _expectNotAbandonable();
        assertFalse(editions.sealed_(ID), "nothing sealed");
        vm.warp(floor);
        auction.abandon(saleId);
        assertTrue(editions.sealed_(ID));
    }

    /// @dev L-4 (review A): the 120-day minimum assumed Stream's 90-day rescue floor. When
    ///      Stream's rescue delay is longer, the lens and the adapter both wait the difference.
    function test_Abandon_WaitsForALongerRescueDelay() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        uint256 deadline = _deadline();
        stream.setRescueDelay(200 days);
        (, uint256 at) = ua.abandonable(saleId);
        assertEq(at, deadline + 110 days);
        vm.warp(deadline);
        _expectNotAbandonable();
        // Even a lens that answers early cannot shorten it.
        address l = IUniformEditionAuctionStorage(address(auction)).lens();
        vm.mockCall(l, abi.encodeWithSelector(IUniformEditionAuctionLens.checkAbandon.selector), "");
        vm.warp(deadline + 110 days - 1);
        _expectNotAbandonable();
        vm.clearMockedCalls();
        vm.warp(deadline + 110 days);
        _abandonAndRefund();
    }

    /// @dev Review E, N-2: a rescue delay lengthened far past the abandonment delay (about 136
    ///      years, Stream's 32-bit bound) adds at most the governed rescue cap (730 days at
    ///      launch), in the lens and in the adapter, so the bidders always have an exit. Fails
    ///      without the cap: the abandonment is a century away.
    function test_N2_AFarLongerRescueDelayAddsAtMostTheCap() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        uint256 deadline = _deadline();
        stream.setRescueDelay(type(uint32).max);
        (, uint256 at) = ua.abandonable(saleId);
        assertEq(at, deadline + 730 days, "capped");
        address l = IUniformEditionAuctionStorage(address(auction)).lens();
        vm.mockCall(l, abi.encodeWithSelector(IUniformEditionAuctionLens.checkAbandon.selector), "");
        vm.warp(deadline + 730 days - 1);
        _expectNotAbandonable();
        vm.clearMockedCalls();
        vm.warp(deadline + 730 days);
        _abandonAndRefund();
    }

    /// @dev Review E, N-2: the cap is a governed limit (90 to 730 days, `setLimits`), applied at
    ///      abandonment. Fails without the change: the full 310-day lengthening is waited.
    function test_N2_TheRescueCapIsGoverned() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        uint256 deadline = _deadline();
        stream.setRescueDelay(400 days);
        (, uint256 at) = ua.abandonable(saleId);
        assertEq(at, deadline + 310 days, "under the cap: the whole lengthening");
        _setLimits(IUniformEditionAuction.Limits(30 days, 150, 100_000, 90));
        (, at) = ua.abandonable(saleId);
        assertEq(at, deadline + 90 days, "the lowered cap");
        vm.warp(deadline + 90 days - 1);
        _expectNotAbandonable();
        vm.warp(deadline + 90 days);
        _abandonAndRefund();
    }

    /// @dev Review E, N-2: once governance removed the English auction, its works keep the
    ///      rescue delay Stream locked at that removal, so a later lengthening does not lengthen
    ///      their sales' abandonment; while it is admitted, the delay in force applies. Fails
    ///      without the change: the live 400-day delay is waited.
    function test_N2_ARemovedAdapterUsesTheDelayStreamLocked() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        uint256 deadline = _deadline();
        stream.setRemoval(address(english), uint40(block.timestamp), 200 days);
        stream.setRescueDelay(400 days);
        (, uint256 at) = ua.abandonable(saleId);
        assertEq(at, deadline + 110 days, "the locked 200 days");
        stream.setRemoval(address(english), 0, 200 days); // admitted again: the delay in force
        (, at) = ua.abandonable(saleId);
        assertEq(at, deadline + 310 days, "the live 400 days");
        stream.setRemoval(address(english), uint40(block.timestamp), 90 days);
        (, at) = ua.abandonable(saleId);
        assertEq(at, deadline, "the floor: nothing added");
        address l = IUniformEditionAuctionStorage(address(auction)).lens();
        vm.mockCall(l, abi.encodeWithSelector(IUniformEditionAuctionLens.checkAbandon.selector), "");
        vm.warp(deadline - 1);
        _expectNotAbandonable();
        vm.clearMockedCalls();
        vm.warp(deadline);
        _abandonAndRefund();
    }

    /// @dev Review E, N-2 (automated review, 16 November 2026): Stream rescues a removed
    ///      adapter's works from its removal time plus the locked delay, so a removal after the
    ///      sale's end moves the floor with it: removed 100 days after the end with the 90-day
    ///      floor locked, the master can be rescued at the end plus 190 days, and the sale is not
    ///      voided before the end plus 250 days (the rescue plus the delay's 60 days past the
    ///      floor). Fails without the change: the floor stays at the end plus 150 days, before the
    ///      rescue opens.
    function test_N2_ARemovalAfterTheEndMovesTheFloorWithIt() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        uint256 deadline = _deadline();
        uint256 end = ua.endTimes(saleId).endTime;
        vm.warp(end + 100 days);
        stream.setRemoval(address(english), uint40(block.timestamp), 90 days);
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, deadline + 100 days, "from the removal");
        address l = IUniformEditionAuctionStorage(address(auction)).lens();
        vm.mockCall(l, abi.encodeWithSelector(IUniformEditionAuctionLens.checkAbandon.selector), "");
        vm.warp(deadline);
        _expectNotAbandonable();
        vm.warp(deadline + 100 days - 1);
        _expectNotAbandonable();
        vm.clearMockedCalls();
        vm.warp(deadline + 100 days);
        _abandonAndRefund();
    }

    /// @dev The cap takes precedence over a late removal: removed 1,000 days after the end, the
    ///      floor is the end plus the delay plus the governed cap (730 days), so the bidders'
    ///      exit stays bounded however late governance acts.
    function test_N2_ALateRemovalAddsAtMostTheCap() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        uint256 deadline = _deadline();
        vm.warp(ua.endTimes(saleId).endTime + 1000 days);
        stream.setRemoval(address(english), uint40(block.timestamp), 90 days);
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertEq(at, deadline + 730 days, "capped");
        assertTrue(ok, "already past the capped floor");
        _abandonAndRefund();
    }

    function test_Abandon_UnknownSale() public {
        vm.expectRevert(abi.encodeWithSelector(IUniformEditionAuction.UnknownAuction.selector, 99));
        auction.abandon(99);
    }

    /// @dev Fuzz over the time and the 1/1's state: `abandon` succeeds exactly when the view
    ///      says so, and the money is conserved either way.
    function testFuzz_Abandon_MatchesTheViewAndConserves(uint256 dt, uint8 state, bool settled)
        public
    {
        state = uint8(bound(state, 1, 5));
        _setOneOfOne(IEnglishAuction.AuctionState(state));
        stream.setSettled(ID, settled);
        vm.warp(block.timestamp + bound(dt, 0, 600 days));
        (bool ok,) = ua.abandonable(saleId);
        if (ok) {
            auction.abandon(saleId);
            _claimAll(saleId);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
            );
            auction.abandon(saleId);
        }
        _assertConserved();
    }
}
