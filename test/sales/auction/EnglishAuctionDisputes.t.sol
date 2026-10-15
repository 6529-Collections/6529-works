// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { Roles } from "src/governance/Roles.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { MockMintTarget } from "../../mocks/sales/AuctionMocks.sol";
import { PermitToken } from "../../mocks/sales/SaleMocks.sol";
import { AuctionBase } from "./AuctionBase.sol";
import { Dependency } from "src/libraries/Dependency.sol";

/// @dev Dispute pauses, withdrawals, upheld cancellation, resumption, and governed setters.
contract EnglishAuctionDisputesTest is AuctionBase {
    function _expectState(uint256 saleId, IEnglishAuction.AuctionState state) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidAuctionState.selector, saleId, state)
        );
    }

    // ------------------------------------------------------------------------------ pause

    function test_Pause_FreezesTheAuction() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionPaused(saleId, keccak256("dispute"));
        _pause(saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.PAUSED));
        assertEq(a.pausedAt, block.timestamp);
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        _expectState(saleId, IEnglishAuction.AuctionState.PAUSED);
        auction.bid{ value: 2 ether }(saleId, address(0), _direct(bob, 2 ether));
        vm.warp(a.endTime + 1);
        _expectState(saleId, IEnglishAuction.AuctionState.PAUSED);
        auction.settle(saleId);
    }

    function test_Pause_OnlyTheGuardian() public {
        uint256 saleId = _start();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.pause(saleId, bytes32(0));
    }

    function test_Pause_OnlyALiveAuctionOnce() public {
        uint256 saleId = _start();
        _pause(saleId);
        vm.prank(guardian);
        _expectState(saleId, IEnglishAuction.AuctionState.PAUSED);
        auction.pause(saleId, bytes32(0));
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(unpauser);
        auction.resume(saleId);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.PauseExhausted.selector, saleId));
        auction.pause(saleId, bytes32(0));

        uint256 ended = _start();
        _end(ended);
        vm.prank(guardian);
        _expectState(ended, IEnglishAuction.AuctionState.ENDED);
        auction.pause(ended, bytes32(0));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnknownSale.selector, _saleIdOf(99)));
        auction.pause(_saleIdOf(99), bytes32(0));
    }

    /// Regression: the review of #21 (inverted for the inclusive window)
    /// @dev Pause boundaries (the inclusive window): `cancel` at exactly
    ///      `pausedAt + 7 days` lands; the pause cannot be reused on another sale.
    function test_Pause_Boundaries() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - 100);
        _pause(saleId);
        uint256 p = block.timestamp;
        bytes32 outcome = _recordOutcome(1);
        vm.warp(p + 7 days);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.CANCELLED));
        assertEq(a.pausedTotal, 7 days);

        uint256 other = _start();
        _pause(other);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(unpauser);
        auction.resume(other);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.PauseExhausted.selector, other));
        auction.pause(other, bytes32("again"));
    }

    /// Regression: the review of #33
    /// @dev A bid for oneself that clears the stored recipient keeps the record that the one
    ///      dispute pause was used.
    function test_Pause_ClearingTheRecipientKeepsThePauseUsed() public {
        uint256 saleId = _start();
        _pause(saleId);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(unpauser);
        auction.resume(saleId);
        _bidFor(saleId, alice, carol, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        assertEq(auction.auction(saleId).recipient, bob);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.PauseExhausted.selector, saleId));
        auction.pause(saleId, keccak256("second dispute"));
    }

    // ------------------------------------------------------------------------ withdrawals

    function test_WithdrawBid_WhilePaused() public {
        vm.prank(setter);
        auction.setOpeningBid(ETH, 0, 0.1 ether);
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        vm.prank(bob);
        _expectState(saleId, IEnglishAuction.AuctionState.ACTIVE);
        auction.withdrawBid(saleId);
        _pause(saleId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NotHighBidder.selector, alice));
        auction.withdrawBid(saleId);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(bob, ETH, saleId, 2 ether);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.BidWithdrawn(saleId, bob, 2 ether);
        vm.prank(bob);
        auction.withdrawBid(saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.bidder, address(0));
        assertEq(a.bid, 2 ether, "kept as the reserve (LIFECYCLE-1)");
        assertEq(auction.claimable(bob, ETH), 2 ether);
        assertEq(auction.minimumBid(saleId), 2 ether, "the reserve, above the opening bid");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NotHighBidder.selector, bob));
        auction.withdrawBid(saleId);
    }

    /// Regression: the review of #33
    /// @dev Withdrawing a bid for another clears the recipient but keeps the dispute pause, so
    ///      no bid lands while it lasts.
    function test_WithdrawBid_ForAnotherKeepsThePause() public {
        uint256 saleId = _start();
        _bidFor(saleId, alice, carol, 1 ether);
        _pause(saleId);
        vm.prank(alice);
        auction.withdrawBid(saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.PAUSED), "still paused");
        assertEq(a.recipient, address(0));
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.PAUSED
            )
        );
        auction.bid{ value: 2 ether }(saleId, address(0), _direct(bob, 2 ether));
    }

    /// Regression: surviving mutant M16 in the review of #33
    /// @dev The floor locked by a withdrawn first bid still applies to the bids after the
    ///      withdrawal, even when governance changes the floor meanwhile.
    function test_WithdrawBid_TheFloorStaysForTheBidsAfterAWithdrawal() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _pause(saleId);
        vm.prank(alice);
        auction.withdrawBid(saleId);
        _setFloor(ETH, 0.5 ether);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(unpauser);
        auction.resume(saleId);
        assertEq(auction.minimumBid(saleId), 1 ether, "no bid: the withdrawn bid's reserve");
        _bidEth(saleId, bob, 1 ether);
        assertEq(auction.auction(saleId).incrementFloor, ETH_FLOOR, "kept, not relocked");
        uint256 minimum = _minimumAfter(1 ether, ETH_FLOOR);
        assertEq(auction.minimumBid(saleId), minimum);
        _bidEth(saleId, carol, minimum);
        assertEq(auction.auction(saleId).bidder, carol);
    }

    // ----------------------------------------------------------------------------- resume

    /// @dev After any dispute pause the auction runs at least the governed duration again (the
    ///      remaining time if longer), so the bidders the pause shut out can return.
    function test_Resume_GivesAtLeastTheDuration() public {
        uint256 saleId = _start();
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - 1 hours);
        _pause(saleId);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(saleId, uint64(block.timestamp + DURATION));
        vm.prank(unpauser);
        auction.resume(saleId);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.endTime, block.timestamp + DURATION);
        assertEq(a.pausedAt, 0);
        assertEq(a.pausedTotal, 2 days);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE));
    }

    function test_Resume_OnlyTheUnpauserAndOnlyWhilePaused() public {
        uint256 saleId = _start();
        vm.prank(unpauser);
        _expectState(saleId, IEnglishAuction.AuctionState.ACTIVE);
        auction.resume(saleId);
        _pause(saleId);
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian)
        );
        auction.resume(saleId);
        // GOV-5: not before 48 hours after the pause, whoever scheduled it when.
        uint256 allowedAt = block.timestamp + Roles.STANDARD;
        vm.warp(allowedAt - 1);
        vm.prank(unpauser);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.UnpauseTooEarly.selector, allowedAt));
        auction.resume(saleId);
        vm.warp(allowedAt);
        vm.prank(unpauser);
        auction.resume(saleId);
    }

    function test_Pause_EndsByItselfAfterSevenDays() public {
        uint256 saleId = _start();
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - 20 minutes);
        _pause(saleId);
        uint256 pausedAt = block.timestamp;
        vm.warp(pausedAt + 7 days);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.PAUSED), "inclusive");
        vm.warp(pausedAt + 7 days + 1);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        uint256 resumedEnd = pausedAt + 7 days + DURATION;
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE), "resumed, no call");
        assertEq(a.endTime, resumedEnd, "the duration, more than the remaining 20 minutes");
        assertEq(a.pausedAt, 0);
        assertEq(a.pausedTotal, 7 days);
        vm.prank(unpauser);
        _expectState(saleId, IEnglishAuction.AuctionState.ACTIVE);
        auction.resume(saleId);

        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(saleId, uint64(resumedEnd));
        _bidEth(saleId, alice, 1 ether);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.PauseExhausted.selector, saleId));
        auction.pause(saleId, bytes32(0));
        vm.warp(resumedEnd - 1);
        _bidEth(saleId, bob, 2 ether);
        assertEq(auction.auction(saleId).endTime, block.timestamp + WINDOW, "anti-snipe applies");
        vm.warp(block.timestamp + WINDOW);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), bob);
    }

    function test_Pause_ExpiredPauseSettlesWithoutAResumeCall() public {
        uint256 saleId = _start();
        uint256 end = auction.auction(saleId).endTime;
        _bidEth(saleId, alice, 1 ether);
        vm.warp(end - 1);
        _pause(saleId);
        uint256 resumedEnd = block.timestamp + 7 days + DURATION;
        assertEq(auction.auction(saleId).endTime, end, "frozen while paused");
        vm.warp(resumedEnd - 1);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.ACTIVE));
        vm.warp(resumedEnd);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
    }

    /// @dev L-2 (review PoC F3, inverted): a pause with seconds left, a withdrawal, and the
    ///      automatic resumption leave at least the anti-snipe window, so the returning bidders
    ///      can bid again.
    function test_Resume_LeavesAtLeastTheWindow() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 10 ether);
        uint256 end = auction.auction(saleId).endTime;
        vm.warp(end - 1);
        _pause(saleId);
        vm.prank(alice);
        auction.withdrawBid(saleId);
        vm.warp(block.timestamp + 7 days + 1);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        // LIFECYCLE-1: the bid was withdrawn, so the full duration, not one second.
        assertEq(a.endTime, end - 1 + 7 days + DURATION, "the duration, not one second");
        _bidEth(saleId, alice, 10 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice, "sold");

        uint256 other = _start();
        uint256 otherEnd = auction.auction(other).endTime;
        vm.warp(otherEnd - 5 minutes);
        _pause(other);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(other, uint64(block.timestamp + DURATION));
        vm.prank(unpauser);
        auction.resume(other);
    }

    /// Regression: LIFECYCLE-1 (docs/security/internal-review-2026-10.md); L7 in the review of #57
    /// @dev The reopening is the governed duration or the sale's locked window, whichever is
    ///      longer, with or without a withdrawal: a later, shorter duration cannot give a
    ///      halted sale less than its anti-snipe window.
    function test_Resume_ReopeningIsNeverShorterThanTheLockedWindow() public {
        IEnglishAuction.AuctionConfig memory c = auction.config();
        IEnglishAuction.AuctionConfig memory wide =
            IEnglishAuction.AuctionConfig(7 days, 1 days, SHARE);
        vm.prank(setter);
        auction.setConfig(c, wide);
        uint256 withdrawn = _start();
        uint256 standing = _start();
        _bidEth(withdrawn, alice, 1 ether);
        _bidEth(standing, bob, 1 ether);
        vm.warp(block.timestamp + 7 days - 10 minutes);
        _pause(withdrawn);
        _pause(standing);
        uint256 pausedAt = block.timestamp;
        vm.prank(alice);
        auction.withdrawBid(withdrawn);
        vm.prank(setter);
        auction.setConfig(wide, IEnglishAuction.AuctionConfig(1 hours, 1 minutes, SHARE));
        vm.warp(pausedAt + auction.MAX_PAUSE() + 1);
        uint256 resumedAt = pausedAt + auction.MAX_PAUSE();
        assertEq(auction.auction(withdrawn).endTime, resumedAt + 1 days, "withdrawn: the window");
        assertEq(auction.auction(standing).endTime, resumedAt + 1 days, "standing: the window");
    }

    // ----------------------------------------------------------------------------- cancel

    function test_Cancel_UpheldDisputeRefundsAndBurns() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        _pause(saleId);
        bytes32 outcome = _recordOutcome(1);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(bob, ETH, saleId, 2 ether);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionCancelled(saleId, outcome);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.CANCELLED));
        assertEq(stream.burned(), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        stream.ownerOf(1);
        assertEq(auction.claimable(alice, ETH), 1 ether);
        assertEq(auction.claimable(bob, ETH), 2 ether);
        vm.prank(alice);
        auction.claim(ETH, alice);
        vm.prank(bob);
        auction.claim(ETH, bob);
        assertEq(address(auction).balance, 0, "every bid refunded");
        _expectState(saleId, IEnglishAuction.AuctionState.CANCELLED);
        auction.settle(saleId);
    }

    function test_Cancel_WithNoBids() public {
        uint256 saleId = _start();
        _pause(saleId);
        bytes32 outcome = _recordOutcome(1);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        assertEq(stream.burned(), 1);
    }

    function test_Cancel_NeedsTheRecordedOutcome() public {
        uint256 saleId = _start();
        _pause(saleId);
        // L4: like `resume`, `cancel` waits for the pause's 48-hour window.
        vm.prank(setter);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.UnpauseTooEarly.selector, block.timestamp + Roles.STANDARD
            )
        );
        auction.cancel(saleId, bytes32(0));
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.startPrank(setter);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, bytes32(0))
        );
        auction.cancel(saleId, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.OutcomeNotRecorded.selector, saleId, keccak256("x")
            )
        );
        auction.cancel(saleId, keccak256("x"));
        vm.stopPrank();
        bytes32 first = _recordOutcome(1);
        bytes32 latest = _recordOutcome(1);
        vm.prank(setter);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, first)
        );
        auction.cancel(saleId, first);
        vm.prank(setter);
        auction.cancel(saleId, latest);
    }

    function test_Cancel_OnlyWhileThePauseIsLive() public {
        uint256 saleId = _start();
        bytes32 outcome = _recordOutcome(1);
        vm.prank(setter);
        _expectState(saleId, IEnglishAuction.AuctionState.ACTIVE);
        auction.cancel(saleId, outcome);
        _pause(saleId);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(setter);
        _expectState(saleId, IEnglishAuction.AuctionState.ACTIVE);
        auction.cancel(saleId, outcome);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.cancel(saleId, outcome);
    }

    /// @dev The pause window is inclusive: `cancel` lands at exactly `pausedAt + 7 days` and is
    ///      refused one second later.
    function test_Cancel_PauseWindowBoundary() public {
        uint256 inside = _start();
        uint256 outside = _start();
        _pause(inside);
        _pause(outside);
        uint256 pausedAt = block.timestamp;
        bytes32 insideOutcome = _recordOutcome(_tokenIdOf(inside));
        bytes32 outsideOutcome = _recordOutcome(_tokenIdOf(outside));
        vm.warp(pausedAt + 7 days);
        vm.prank(setter);
        auction.cancel(inside, insideOutcome);
        assertEq(uint8(_state(inside)), uint8(IEnglishAuction.AuctionState.CANCELLED));
        vm.warp(pausedAt + 7 days + 1);
        vm.prank(setter);
        _expectState(outside, IEnglishAuction.AuctionState.ACTIVE);
        auction.cancel(outside, outsideOutcome);
    }

    /// @dev The upheld outcome is a 48-hour action. Scheduled exactly at day 5 of the pause it
    ///      becomes executable at `pausedAt + 7 days`, which the inclusive window still accepts;
    ///      scheduled one second later it lands after the pause and is refused.
    function test_Cancel_ThroughTheStandardDelay() public {
        address council = makeAddr("council");
        manager.grantRole(PARAMETER_SETTER, council, 48 hours);
        uint256 saleId = _start();
        uint256 other = _start();
        _pause(saleId);
        _pause(other);
        bytes32 outcome = _recordOutcome(_tokenIdOf(saleId));
        bytes32 otherOutcome = _recordOutcome(_tokenIdOf(other));
        bytes memory onTime = abi.encodeCall(auction.cancel, (saleId, outcome));
        bytes memory late = abi.encodeCall(auction.cancel, (other, otherOutcome));

        uint256 pausedAt = block.timestamp;
        vm.warp(pausedAt + 5 days);
        vm.prank(council);
        manager.schedule(address(auction), onTime, 0);
        vm.warp(pausedAt + 5 days + 1);
        vm.prank(council);
        manager.schedule(address(auction), late, 0);

        vm.warp(pausedAt + 7 days);
        vm.prank(council);
        manager.execute(address(auction), onTime);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.CANCELLED));

        vm.warp(pausedAt + 7 days + 1);
        vm.prank(council);
        _expectState(other, IEnglishAuction.AuctionState.ACTIVE);
        manager.execute(address(auction), late);
    }

    /// Regression: L-3 (PoC F4, inverted) in the review of #21
    /// @dev An adapter that lost its mint admission while the auction was paused can still
    ///      enforce an upheld dispute, because the token accepts its minting adapter's burn.
    function test_Cancel_ADeadmittedAdapterCanStillCancel() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _pause(saleId);
        bytes32 outcome = _recordOutcome(1);
        stream.setAdmittedMinter(address(auction), false);
        vm.warp(block.timestamp + Roles.STANDARD);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        assertFalse(stream.exists(1), "burned");
        assertEq(auction.claimable(alice, ETH), 1 ether);
    }

    /// Regression: N1 (inverted) in the review of #21
    /// @dev A cancelled sale reports the pause it actually had.
    function test_Cancel_TheCancelledViewReportsTheActualPause() public {
        uint256 saleId = _start();
        uint256 end = auction.auction(saleId).endTime;
        _pause(saleId);
        bytes32 outcome = _recordOutcome(1);
        vm.warp(block.timestamp + 2 days);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        vm.warp(block.timestamp + 7 days);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.CANCELLED));
        assertEq(a.pausedTotal, 2 days);
        assertEq(a.pausedAt, 0);
        assertEq(a.endTime, end);
    }

    // ------------------------------------------------------------------------- governance

    function test_SetConfig_CompareAndSet() public {
        IEnglishAuction.AuctionConfig memory next =
            IEnglishAuction.AuctionConfig(12 hours, 10 minutes, 10_000);
        vm.prank(setter);
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setConfig(next, next);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.ConfigSet(_config(), next);
        vm.prank(setter);
        auction.setConfig(_config(), next);
        assertEq(auction.config().duration, 12 hours);
        IEnglishAuction.AuctionConfig memory current = auction.config();
        next.incrementShare = 100_001;
        vm.prank(setter);
        vm.expectRevert(IEnglishAuction.InvalidConfig.selector);
        auction.setConfig(current, next);
        uint256 saleId = _start();
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(a.endTime - block.timestamp, 12 hours, "new sales use the new config");
    }

    /// @dev The opening bid is a two-way compare-and-set price within an absolute ceiling.
    function test_SetOpeningBid_MovesBothWaysWithinTheCeiling() public {
        uint256 ceiling = ETH_FLOOR * auction.OPENING_BID_FLOORS();
        vm.startPrank(setter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.OpeningBidAboveCeiling.selector, ceiling + 1, ceiling
            )
        );
        auction.setOpeningBid(ETH, 0, ceiling + 1);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.OpeningBidSet(ETH, 0, 0.5 ether);
        auction.setOpeningBid(ETH, 0, 0.5 ether);
        vm.expectRevert(ISaleAdapter.ExpectedValueMismatch.selector);
        auction.setOpeningBid(ETH, 0, 0.2 ether);
        auction.setOpeningBid(ETH, 0.5 ether, 0.2 ether);
        auction.setOpeningBid(ETH, 0.2 ether, ceiling);
        auction.setOpeningBid(ETH, ceiling, 0);
        auction.setOpeningBid(ETH, 0, 0.2 ether);
        vm.expectRevert(abi.encodeWithSelector(IAssetAllowlist.AssetNotActive.selector, alice));
        auction.setOpeningBid(alice, 0, 1);
        vm.stopPrank();
        assertEq(auction.openingBid(ETH), 0.2 ether);
        uint256 saleId = _start();
        assertEq(auction.minimumBid(saleId), 0.2 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, 0.2 ether, 0.1 ether)
        );
        auction.bid{ value: 0.1 ether }(saleId, address(0), _direct(alice, 0.1 ether));
        vm.prank(setter);
        auction.setOpeningBid(ETH, 0.2 ether, 0);
        assertEq(auction.minimumBid(saleId), 0.2 ether, "locked for the running sale");
    }

    function testFuzz_SetOpeningBid_AnyValueUpToTheCeiling(uint256 first, uint256 next) public {
        uint256 ceiling = ETH_FLOOR * auction.OPENING_BID_FLOORS();
        first = bound(first, 0, ceiling);
        vm.prank(setter);
        auction.setOpeningBid(ETH, 0, first);
        vm.prank(setter);
        if (next > ceiling) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IEnglishAuction.OpeningBidAboveCeiling.selector, next, ceiling
                )
            );
            auction.setOpeningBid(ETH, first, next);
            assertEq(auction.openingBid(ETH), first);
        } else {
            auction.setOpeningBid(ETH, first, next);
            assertEq(auction.openingBid(ETH), next);
        }
    }

    /// Regression: a low finding in the review of #33
    /// @dev The opening bid's ceiling is the 96-bit bid cap, so every opening bid can be met.
    function test_SetOpeningBid_CappedAtTheLargestBid() public {
        PermitToken big = new PermitToken();
        allowlist.admitAsset(address(big), 0, 1e26);
        uint256 cap = type(uint96).max;
        vm.startPrank(setter);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OpeningBidAboveCeiling.selector, cap + 1, cap)
        );
        auction.setOpeningBid(address(big), 0, cap + 1);
        auction.setOpeningBid(address(big), 0, cap);
        vm.stopPrank();
        stream.setTerms(_terms(address(big)));
        uint256 saleId = auction.start(address(stream), "");
        assertEq(auction.minimumBid(saleId), cap);
        big.mint(alice, cap);
        vm.startPrank(alice);
        big.approve(address(auction), cap);
        auction.bid(saleId, address(0), _direct(alice, cap));
        vm.stopPrank();
        assertEq(auction.auction(saleId).bid, cap);
    }

    function test_SetTarget_AdmitsAndRemoves() public {
        MockMintTarget other = new MockMintTarget();
        other.setAdmittedMinter(address(auction), true);
        other.setTerms(_terms(ETH));
        vm.expectEmit(address(auction));
        emit ISaleAdapter.TargetSet(address(other), true);
        vm.prank(successor);
        auction.setTarget(address(other), true);
        assertTrue(auction.isTarget(address(other)));
        uint256 saleId = auction.start(address(other), "");
        assertEq(auction.saleIdOf(address(other), 1), saleId);
        assertTrue(saleId != auction.saleIdOf(address(stream), 1));

        vm.prank(successor);
        auction.setTarget(address(other), false);
        assertFalse(auction.isTarget(address(other)));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(other))
        );
        auction.start(address(other), "");
        _bidEth(saleId, alice, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(other.ownerOf(1), alice, "running sales finish");
    }

    function test_SetTarget_RejectsNonTokens() public {
        vm.startPrank(successor);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, alice));
        auction.setTarget(alice, true);
        vm.expectRevert(
            abi.encodeWithSelector(Dependency.InvalidDependency.selector, address(escrow))
        );
        auction.setTarget(address(escrow), true);
        vm.stopPrank();
    }

    function test_GovernedSettersAreRestricted() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setConfig(_config(), _config());
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setOpeningBid(ETH, 0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        auction.setTarget(alice, true);
        vm.stopPrank();
        assertEq(address(manager), auction.authority());
    }
}
