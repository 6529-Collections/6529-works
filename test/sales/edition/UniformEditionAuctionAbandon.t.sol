// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { IUniformEditionAuctionStorage } from "src/interfaces/IUniformEditionAuctionStorage.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice `abandon` (R16): from 21 days after a sale's close, once its 1/1 auction no longer
///         gives settlement a usable answer (it refuses, answers malformed, or reports the 1/1
///         cancelled), anyone may void the sale: every bid refunded in full and the edition,
///         created at open, sealed at zero. A 1/1 that is active, paused, ended or settled lets
///         the sale settle as usual, so it is never abandoned.
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
        (, uint64 end) = english.clockOf(address(stream), ID);
        return end;
    }

    function _setOneOfOne(IEnglishAuction.AuctionState state) internal {
        english.set(address(stream), ID, state, _oneEnd());
    }

    /// @dev The earliest abandonment: the sale's close (the 1/1's end plus 15 minutes) plus 21
    ///      days.
    function _deadline() internal view returns (uint256) {
        return uint256(_oneEnd()) + 15 minutes + 21 days;
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
        _assertVoidAndRefunded();
        // Final: the sale cannot be abandoned or settled again.
        _expectNotAbandonable();
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniformEditionAuction.InvalidAuctionState.selector,
                saleId,
                IUniformEditionAuction.AuctionStatus.VOID
            )
        );
        auction.settle(saleId, new uint256[](0));
    }

    function _assertVoidAndRefunded() internal {
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertTrue(editions.editionOf(ID).supplySealed);
        assertEq(editions.editionOf(ID).maxSupply, 0, "sealed at zero");
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        assertEq(_claimAll(saleId), 0, "nothing minted");
        assertEq(alice.balance - aliceBefore, 2 * _price(saleId, 10), "alice in full");
        assertEq(bob.balance - bobBefore, 3 * _price(saleId, 20), "bob in full");
        assertEq(address(auction).balance, 0);
        _assertConserved();
    }

    /// @dev The fixed wait: a 1/1 auction that stopped answering. Refused one second before the
    ///      close plus 21 days, accepted at it.
    function test_Abandon_TheFixedWaitThenVoidAndSealAtZero() public {
        english.setRefuseClock(true);
        vm.warp(_deadline() - 1);
        _expectNotAbandonable();
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, _deadline());
        vm.warp(_deadline());
        (ok,) = ua.abandonable(saleId);
        assertTrue(ok);
        _abandonAndRefund();
    }

    /// @dev A cancelled 1/1 (an upheld dispute, the master burned): `abandon` may void after the
    ///      wait, and the edition stays created with a zero seal.
    function test_Abandon_ACancelledMaster() public {
        _setOneOfOne(IEnglishAuction.AuctionState.CANCELLED);
        _expectNotAbandonable();
        vm.warp(_deadline());
        stream.burn(ID);
        _abandonAndRefund();
        assertEq(editions.editionOf(ID).minter, address(auction), "the edition stays created");
    }

    /// @dev `settle` voids a sale with a cancelled 1/1 at once, and seals the edition at zero.
    function test_Settle_ACancelledOneOfOneVoidsAndSealsAtZero() public {
        _setOneOfOne(IEnglishAuction.AuctionState.CANCELLED);
        vm.expectEmit(address(editions));
        emit IEditions.EditionSupplySealed(ID, 0);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        _assertVoidAndRefunded();
    }

    /// @dev A 1/1 auction that answers malformed (too short) counts as one that refuses.
    function test_Abandon_AMalformedAnswerCountsAsARefusal() public {
        english.setShortAnswer(true);
        vm.warp(_deadline());
        _abandonAndRefund();
    }

    /// @dev A 1/1 whose auction answers ACTIVE, PAUSED, ENDED or SETTLED is never abandoned,
    ///      however late: the sale settles as usual.
    function test_Abandon_NeverWhileTheOneOfOneAnswersUsably() public {
        vm.warp(_deadline() + 365 days);
        IEnglishAuction.AuctionState[4] memory states = [
            IEnglishAuction.AuctionState.ACTIVE,
            IEnglishAuction.AuctionState.PAUSED,
            IEnglishAuction.AuctionState.ENDED,
            IEnglishAuction.AuctionState.SETTLED
        ];
        for (uint256 i; i < 4; ++i) {
            _setOneOfOne(states[i]);
            _expectNotAbandonable();
            (bool ok, uint256 at) = ua.abandonable(saleId);
            assertFalse(ok);
            assertEq(at, 0);
        }
        _settle(saleId);
        assertEq(_claimAll(saleId), 5);
        _assertConserved();
    }

    /// @dev A broken English auction: a clock that refuses counts as finished with the end last
    ///      read; a clock that runs out of gas reverts, never refuses.
    function test_Abandon_ABrokenEnglishAuction() public {
        uint256 deadline = _deadline();
        vm.warp(deadline);
        english.setBurnClock(true);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(english))
        );
        auction.abandon{ gas: 2_000_000 }(saleId);
        english.setBurnClock(false);
        english.setRefuseClock(true);
        _abandonAndRefund();
    }

    /// @dev A sale that has paid is never abandoned: SETTLED, or SETTLING after its clearing.
    function test_Abandon_NeverAPaidSale() public {
        _settle(saleId);
        vm.warp(block.timestamp + 1000 days);
        _setOneOfOne(IEnglishAuction.AuctionState.CANCELLED);
        _expectNotAbandonable();
    }

    /// @dev A wide book whose scan is in progress (SETTLING, nothing paid) when the 1/1 auction
    ///      stops answering can still be voided after the wait.
    function test_Abandon_AScanInProgressWhoseOneOfOneStoppedAnswering() public {
        _bid(saleId, alice, 335, 1); // the book spans more than 24 words
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        vm.warp(ua.endTimes(saleId).endTime);
        assertFalse(auction.settle(saleId, new uint256[](0)), "the first scan call");
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.SETTLING)
        );
        _expectNotAbandonable();
        english.setRefuseClock(true);
        vm.warp(_deadline());
        auction.abandon(saleId);
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        assertEq(editions.editionOf(ID).maxSupply, 0);
    }

    /// @dev The adapter enforces the time floor itself, from its own words. A lens that answers
    ///      early (here its `checkAbandon` is made to pass) cannot void a sale or seal its
    ///      edition before the stored close plus 21 days.
    function test_Abandon_TheAdapterRefusesALensThatAnswersEarly() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        address l = IUniformEditionAuctionStorage(address(auction)).lens();
        vm.mockCall(l, abi.encodeWithSelector(IUniformEditionAuctionLens.checkAbandon.selector), "");
        uint256 floor = uint256(_oneEnd()) + 15 minutes + 21 days;
        vm.warp(floor - 1);
        _expectNotAbandonable();
        assertFalse(editions.editionOf(ID).supplySealed, "nothing sealed");
        vm.warp(floor);
        auction.abandon(saleId);
        assertTrue(editions.editionOf(ID).supplySealed);
    }

    /// @dev The copy bound is exact (found by mutation testing): a refusal of exactly 1,024
    ///      bytes from the edition contract is passed on whole, one of 1,025 bytes is not.
    function test_Abandon_ARefusalOfExactly1024BytesIsPassedOn() public {
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        stream.setSettled(ID, true);
        vm.warp(_deadline());
        bytes memory reason = new bytes(1024);
        reason[0] = 0x5a;
        reason[1023] = 0xa5;
        vm.mockCallRevert(
            address(editions), abi.encodePacked(IEditions.createEdition.selector), reason
        );
        vm.expectRevert(reason);
        auction.abandon(saleId, master);
        vm.mockCallRevert(
            address(editions),
            abi.encodePacked(IEditions.createEdition.selector),
            abi.encodePacked(reason, bytes1(0))
        );
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallFailed.selector, address(editions))
        );
        auction.abandon(saleId, master);
        vm.clearMockedCalls();
        _abandon();
        assertTrue(editions.exists(ID));
    }
}
