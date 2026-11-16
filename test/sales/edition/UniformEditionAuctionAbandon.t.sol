// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEditions } from "src/interfaces/IEditions.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { IUniformEditionAuctionStorage } from "src/interfaces/IUniformEditionAuctionStorage.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice `abandon` (R16, EA-19): from 21 days after a sale's close, once its 1/1 auction is no
///         longer in progress or ended-unsettled, anyone may call it. If the master's sale
///         settled in its token, the call creates a missing edition and the sale then settles
///         as usual, copies minted; if the master's sale never completed, the sale is void,
///         every bid refunded in full, and the edition sealed at zero.
contract UniformEditionAuctionAbandonTest is EditionAuctionBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal saleId;
    /// @dev `abi.encode(PackageItem)` of the master's item.
    bytes internal master;

    function setUp() public override {
        super.setUp();
        saleId = _open(0);
        master = abi.encode(_item(ID, 0));
        _bid(saleId, alice, 10, 2);
        _bid(saleId, bob, 20, 3);
    }

    function _oneEnd() internal view returns (uint64) {
        return english.auction(english.saleIdOf(address(stream), ID)).endTime;
    }

    function _setOneOfOne(IEnglishAuction.AuctionState state) internal {
        english.set(address(stream), ID, state, _oneEnd());
    }

    /// @dev The earliest abandonment: the sale's close (the 1/1's end plus 15 minutes) plus 21
    ///      days.
    function _deadline() internal view returns (uint256) {
        return uint256(_oneEnd()) + 15 minutes + 21 days;
    }

    function _abandon() internal {
        auction.abandon(saleId, master);
    }

    function _expectNotAbandonable() internal {
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.NotAbandonable.selector, saleId)
        );
        _abandon();
    }

    function _abandonAndRefund() internal {
        vm.expectEmit(address(auction));
        emit IUniformEditionAuction.AuctionVoided(saleId);
        vm.expectEmit(address(editions));
        emit IEditions.EditionSupplySealed(ID, 0);
        vm.prank(makeAddr("anyone"));
        _abandon();
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

    /// @dev The fixed wait: refused at 20 days after the close, accepted at 21. The 1/1 sold
    ///      (its master settled) and the edition was never created: the call creates it, and the
    ///      sale then settles with copies minted. Fails without the change: the sale was voided
    ///      and the edition sealed at zero, and only after 150 days.
    function test_Abandon_TheOneOfOneSold_CreatesTheEditionAndTheSaleCompletes() public {
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        stream.setSettled(ID, true);
        vm.warp(uint256(_oneEnd()) + 15 minutes + 20 days);
        _expectNotAbandonable();
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, _deadline());
        vm.warp(_deadline());
        (ok,) = ua.abandonable(saleId);
        assertTrue(ok);
        vm.prank(makeAddr("anyone"));
        _abandon();
        assertTrue(editions.exists(ID), "the edition was created");
        assertEq(editions.created(), 1);
        assertFalse(editions.sealed_(ID), "not sealed at zero");
        assertEq(
            uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.CLOSED)
        );
        // Now the sale settles as usual, and the winners get their copies.
        _expectNotAbandonable();
        uint256 balance = address(auction).balance;
        assertTrue(auction.settle(saleId, lens.settlementOrderFor(saleId, address(this))));
        paidOut += balance - address(auction).balance;
        assertEq(_claimAll(saleId), 5, "copies minted");
        assertEq(editions.minted(ID), 5);
        _assertConserved();
    }

    /// @dev The master's sale never completed (its 1/1 settlement refused, the token never
    ///      settled): after 21 days the sale is void, bids refunded, the edition sealed at zero.
    function test_Abandon_TheOneOfOneDidNotSell_RefundsAndSealsAtZero() public {
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        vm.warp(_deadline() - 1);
        _expectNotAbandonable();
        vm.warp(_deadline());
        _abandonAndRefund();
    }

    /// @dev A cancelled 1/1 (an upheld dispute, the work burned): `settle` voids at once;
    ///      `abandon` also may after the wait, and seals the edition at zero.
    function test_Abandon_ACancelledMaster() public {
        _setOneOfOne(IEnglishAuction.AuctionState.CANCELLED);
        _expectNotAbandonable();
        vm.warp(_deadline());
        _abandonAndRefund();
    }

    /// @dev A 1/1 not settled yet is never abandoned, however late: ACTIVE, PAUSED (a dispute)
    ///      or ENDED (anyone may settle it).
    function test_Abandon_NeverWhileTheOneOfOneIsUnsettled() public {
        vm.warp(_deadline() + 365 days);
        IEnglishAuction.AuctionState[3] memory states = [
            IEnglishAuction.AuctionState.ACTIVE,
            IEnglishAuction.AuctionState.PAUSED,
            IEnglishAuction.AuctionState.ENDED
        ];
        for (uint256 i; i < 3; ++i) {
            _setOneOfOne(states[i]);
            _expectNotAbandonable();
            (bool ok, uint256 at) = ua.abandonable(saleId);
            assertFalse(ok);
            assertEq(at, 0);
        }
    }

    /// @dev Master settled and edition created: the sale settles as usual, so it is refused.
    function test_Abandon_RefusedWhenTheSaleCanSettle() public {
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        stream.setSettled(ID, true);
        editions.setExists(ID, true);
        vm.warp(_deadline());
        _expectNotAbandonable();
        (bool ok, uint256 at) = ua.abandonable(saleId);
        assertFalse(ok);
        assertEq(at, 0);
        _settle(saleId);
        assertEq(_claimAll(saleId), 5);
    }

    /// @dev Creating the edition needs the master's own item: another one is refused by the
    ///      edition contract and the whole call reverts.
    function test_Abandon_CreatesOnlyFromTheMastersItem() public {
        _setOneOfOne(IEnglishAuction.AuctionState.SETTLED);
        stream.setSettled(ID, true);
        vm.warp(_deadline());
        PackageItem memory other = _item(ID, 0);
        other.contentHash = keccak256("another");
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, ID));
        auction.abandon(saleId, abi.encode(other));
        vm.expectRevert();
        auction.abandon(saleId, hex"00");
    }

    /// @dev A broken English auction (its clock refuses): it counts as finished with the end
    ///      last read, so the master decides. A clock that runs out of gas reverts, never
    ///      refuses.
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
        auction.abandon{ gas: 2_000_000 }(saleId, master);
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

    /// @dev A wide book's settlement stalls in its last scan call when the edition was never
    ///      created (the sale is SETTLING, nothing paid): abandoning creates the edition, and the
    ///      scan then completes.
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
        _abandon();
        uint256 balance = address(auction).balance;
        assertTrue(auction.settle(saleId, new uint256[](0)));
        paidOut += balance - address(auction).balance;
        assertEq(_claimAll(saleId), ua.settlement(saleId).count);
        assertGt(ua.settlement(saleId).count, 0, "copies minted");
        assertEq(address(auction).balance, 0);
        _assertConserved();
    }

    /// @dev The adapter enforces the time floor itself, from its own words. A lens that answers
    ///      early (here its `checkAbandon` is made to pass) cannot void a sale or seal its
    ///      edition before the stored close plus 21 days.
    function test_Abandon_TheAdapterRefusesALensThatAnswersEarly() public {
        _setOneOfOne(IEnglishAuction.AuctionState.ENDED);
        address l = IUniformEditionAuctionStorage(address(auction)).lens();
        vm.mockCall(
            l,
            abi.encodeWithSelector(IUniformEditionAuctionLens.checkAbandon.selector),
            abi.encode(false)
        );
        uint256 floor = uint256(_oneEnd()) + 15 minutes + 21 days;
        vm.warp(floor - 1);
        _expectNotAbandonable();
        assertFalse(editions.sealed_(ID), "nothing sealed");
        vm.warp(floor);
        _abandon();
        assertTrue(editions.sealed_(ID));
    }
}
