// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
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
