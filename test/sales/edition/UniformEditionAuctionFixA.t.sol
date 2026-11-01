// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionStorage } from "src/interfaces/IUniformEditionAuctionStorage.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice Regressions of the rc.2 seven-lens review, fix pass A, on mocks.
///         F3 (markets M-1, clearing Info 1): during a 1/1 dispute pause only a bid placed (or
///         last raised) in a minute that ended before the pause began may be withdrawn: never
///         one placed during the pause, in its minute, or in the block of the withdrawal, so
///         neither demand nor a step's capacity can be faked with a pause.
///         F9 (gas M-1): a keeper pages through a long departure log with
///         `settlementOrderFor(saleId, settler, fromPosition, max)`, `O(n log max)`.
contract UniformEditionAuctionFixATest is EditionAuctionBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function _pause() internal {
        english.set(
            address(stream),
            ID,
            IEnglishAuction.AuctionState.PAUSED,
            uint64(block.timestamp + 1 days)
        );
    }

    function _expectClosed(uint256 saleId) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.WithdrawalsClosed.selector, saleId)
        );
    }

    function _placedMinute(uint256 saleId, uint256 bidId) internal view returns (uint256) {
        return auction.storageWord(IUniformEditionAuctionStorage.Space.BID, saleId, bidId) >> 240;
    }

    // ----------------------------------------------------------------------------- F3

    function test_F3_OnlyBidsPlacedBeforeThePauseLeave() public {
        uint256 saleId = _open(10);
        uint256 a = _bid(saleId, alice, 40, 3); // minute 0
        vm.warp(block.timestamp + 120);
        uint256 b = _bid(saleId, bob, 40, 2); // minute 2
        vm.warp(block.timestamp + 30);
        _pause(); // minute 2
        uint256 c = _bid(saleId, carol, 41, 1); // during the pause
        assertEq(_placedMinute(saleId, a), 0);
        assertEq(_placedMinute(saleId, b), 2);
        assertTrue(lens.canWithdraw(saleId, a));
        assertFalse(lens.canWithdraw(saleId, b), "placed in the pause's minute");
        assertFalse(lens.canWithdraw(saleId, c), "placed during the pause");
        vm.prank(bob);
        _expectClosed(saleId);
        auction.withdrawBid(saleId, b, bob);
        vm.prank(carol);
        _expectClosed(saleId);
        auction.withdrawBid(saleId, c, carol);
        uint256 amount = 3 * _price(saleId, 40);
        vm.prank(alice);
        auction.withdrawBid(saleId, a, alice);
        assertEq(alice.balance, amount);
        refundsOut += amount;
        // Not paused: no withdrawal, whatever the bid.
        english.set(
            address(stream),
            ID,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        assertFalse(lens.canWithdraw(saleId, b));
    }

    /// @dev Clearing Info 1: a flash-funded bid-and-withdraw during a pause can no longer fill a
    ///      step's position counter, and no bid leaves in the block that placed it.
    function test_F3_NoWithdrawalInTheBlockOfTheBid() public {
        uint256 saleId = _open(10);
        _bid(saleId, alice, 5, 2);
        vm.warp(block.timestamp + 120);
        _pause();
        address attacker = makeAddr("attacker");
        uint256 qty = uint256(type(uint32).max) - 2;
        uint256 amount = qty * _price(saleId, 5);
        vm.deal(attacker, amount);
        vm.startPrank(attacker);
        uint256 bidId = auction.bid{ value: amount }(saleId, 5, qty);
        _expectClosed(saleId);
        auction.withdrawBid(saleId, bidId, attacker);
        vm.stopPrank();
        escrowIn += amount;
        // A bid placed in the same block as the pause (and the withdrawal) is refused too.
        english.set(
            address(stream),
            ID + 1,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 1 days)
        );
        uint256 saleTwo = _openId(ID + 1, 10);
        uint256 same = _bid(saleTwo, bob, 9, 1);
        english.set(
            address(stream),
            ID + 1,
            IEnglishAuction.AuctionState.PAUSED,
            uint64(block.timestamp + 1 days)
        );
        vm.prank(bob);
        _expectClosed(saleTwo);
        auction.withdrawBid(saleTwo, same, bob);
    }

    function test_F3_ARaiseRestartsThePlacement() public {
        uint256 saleId = _open(10);
        uint256 a = _bid(saleId, alice, 40, 3);
        vm.warp(block.timestamp + 300);
        _pause();
        assertTrue(lens.canWithdraw(saleId, a));
        _raise(saleId, a, 41);
        assertEq(_placedMinute(saleId, a), 5, "the raise's minute");
        assertFalse(lens.canWithdraw(saleId, a));
        vm.prank(alice);
        _expectClosed(saleId);
        auction.withdrawBid(saleId, a, alice);
    }

    /// @dev The withdrawal reads the 1/1's `auctionClock` as three words (state, end and pause
    ///      start, fix pass B): a shorter answer reverts, whatever the words it did return.
    function test_F3_AShortClockAnswerReverts() public {
        uint256 saleId = _open(10);
        uint256 a = _bid(saleId, alice, 40, 1);
        vm.warp(block.timestamp + 120);
        _pause();
        english.setShortAnswer(true);
        vm.prank(alice);
        vm.expectRevert(bytes(""));
        auction.withdrawBid(saleId, a, alice);
        english.setShortAnswer(false);
        vm.prank(alice);
        auction.withdrawBid(saleId, a, alice);
        refundsOut += _price(saleId, 40);
    }

    /// @dev A sale opened while its 1/1 is already paused: every bid comes after the pause.
    function test_F3_ASaleOpenedDuringThePause() public {
        _pause();
        vm.warp(block.timestamp + 3600);
        uint256 saleId = _open(10);
        uint256 a = _bid(saleId, alice, 40, 1);
        vm.warp(block.timestamp + 3600);
        assertFalse(lens.canWithdraw(saleId, a));
        vm.prank(alice);
        _expectClosed(saleId);
        auction.withdrawBid(saleId, a, alice);
    }

    /// @dev Minutes count from the open and stop at 65,535: a bid placed that late is never
    ///      early, while an early bid stays early against a pause that late.
    function test_F3_SaturatedMinutes() public {
        english.set(
            address(stream),
            ID,
            IEnglishAuction.AuctionState.ACTIVE,
            uint64(block.timestamp + 100 days)
        );
        uint256 saleId = _open(10);
        vm.warp(block.timestamp + 100 minutes);
        uint256 early = _bid(saleId, alice, 40, 1);
        vm.warp(block.timestamp + 70_000 minutes);
        uint256 late = _bid(saleId, bob, 40, 1);
        assertEq(_placedMinute(saleId, early), 100);
        assertEq(_placedMinute(saleId, late), type(uint16).max);
        vm.warp(block.timestamp + 10 minutes);
        english.set(
            address(stream),
            ID,
            IEnglishAuction.AuctionState.PAUSED,
            uint64(block.timestamp + 1 days)
        );
        assertTrue(lens.canWithdraw(saleId, early));
        assertFalse(lens.canWithdraw(saleId, late));
        vm.prank(bob);
        _expectClosed(saleId);
        auction.withdrawBid(saleId, late, bob);
        uint256 amount = _price(saleId, 40);
        vm.prank(alice);
        auction.withdrawBid(saleId, early, alice);
        refundsOut += amount;
    }

    // ----------------------------------------------------------------------------- F9

    /// @dev Pages of `settlementOrderFor` concatenate to the full order, whatever the page size,
    ///      and follow the settler's own progress once it sweeps.
    function test_F9_PagesConcatenateToTheOrder() public {
        uint256 saleId = _open(250);
        address crowd = makeAddr("crowd");
        for (uint256 i; i < 300; ++i) {
            _bid(saleId, crowd, 10, 1);
        }
        // 200 departures logged in reverse position order.
        for (uint256 bidId = 300; bidId > 100; --bidId) {
            _raise(saleId, bidId, 11);
        }
        uint256[] memory all = ua.settlementOrder(saleId);
        assertEq(all.length, 200);
        assertEq(lens.settlementOrderFor(saleId, address(this), 0, 0).length, 0, "max zero");
        uint256[5] memory sizes = [uint256(1), 7, 64, 199, 500];
        IUniformEditionAuction.Departure[] memory log = ua.departures(saleId, 10);
        for (uint256 s; s < 5; ++s) {
            uint256 got;
            uint256 from;
            while (got < all.length) {
                uint256[] memory page =
                    lens.settlementOrderFor(saleId, address(this), from, sizes[s]);
                assertGt(page.length, 0);
                for (uint256 k; k < page.length; ++k) {
                    assertEq(page[k], all[got + k], "pages concatenate");
                }
                got += page.length;
                from = log[page[page.length - 1]].position + 1;
            }
            assertEq(lens.settlementOrderFor(saleId, address(this), from, sizes[s]).length, 0);
        }
        // Once this settler swept 16 (the clearing call), its pages start after them.
        _closeOneOfOne(saleId);
        editions.setExists(ID, true);
        uint256 balance = address(auction).balance;
        uint256[] memory first = lens.settlementOrderFor(saleId, address(this), 0, 16);
        assertFalse(auction.settle(saleId, first));
        paidOut += balance - address(auction).balance;
        uint256[] memory next = lens.settlementOrderFor(saleId, address(this), 0, 96);
        assertEq(next[0], all[16]);
        // Another settler still starts from the beginning.
        assertEq(lens.settlementOrderFor(saleId, makeAddr("other"), 0, 1)[0], all[0]);
    }

    /// @dev Gas lens M-1: the keeper's path stays well inside a 50M `eth_call` at 10,000
    ///      departures, logged in the worst order.
    function test_F9_AKeeperPagesTenThousandDepartures() public {
        uint256 saleId = _open(15_000);
        address crowd = makeAddr("crowd");
        // The book is built unmetered: only the views are measured.
        vm.pauseGasMetering();
        for (uint256 i; i < 20_000; ++i) {
            _bid(saleId, crowd, 10, 1);
        }
        for (uint256 bidId = 20_000; bidId > 10_000; --bidId) {
            _raise(saleId, bidId, 11);
        }
        vm.resumeGasMetering();
        uint256 g = gasleft();
        uint256[] memory page = lens.settlementOrderFor(saleId, address(this), 0, 96);
        uint256 used = g - gasleft();
        emit log_named_uint("settlementOrderFor page of 96, 10,000 departures", used);
        assertEq(page.length, 96);
        assertLt(used, 30_000_000, "well inside a 50M eth_call");
    }
}
