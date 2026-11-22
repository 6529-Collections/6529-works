// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { AuctionFixture } from "./AuctionFixture.sol";

/// @notice The dispute pause, resume, cancel and withdrawal.
contract EnglishAuctionDisputesTest is AuctionFixture {
    bytes32 internal constant REF = keccak256("dispute");
    bytes32 internal constant OUTCOME = keccak256("outcome");

    function _paused() internal returns (uint256 saleId) {
        saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        vm.warp(block.timestamp + 1 hours);
        auction.pause(saleId, REF);
    }

    function test_Pause_OncePerSale() public {
        uint256 saleId = _start(1);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionPaused(saleId, REF);
        auction.pause(saleId, REF);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.PAUSED));
        auction.resume(saleId);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.PauseExhausted.selector, saleId));
        auction.pause(saleId, REF);
    }

    function test_Pause_OnlyALiveSale() public {
        uint256 saleId = _start(1);
        _end(saleId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ENDED
            )
        );
        auction.pause(saleId, REF);
    }

    function test_Paused_RefusesBidsAndSettlement() public {
        uint256 saleId = _paused();
        bytes memory paused = abi.encodeWithSelector(
            IEnglishAuction.InvalidAuctionState.selector,
            saleId,
            IEnglishAuction.AuctionState.PAUSED
        );
        vm.prank(bob);
        vm.expectRevert(paused);
        auction.bid{ value: 2 ether }(saleId, address(0));
        vm.expectRevert(paused);
        auction.settle(saleId);
    }

    function test_WithdrawBid_OnlyTheHighBidderWhilePaused() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.withdrawBid(saleId);
        auction.pause(saleId, REF);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NotHighBidder.selector, bob));
        auction.withdrawBid(saleId);
        vm.prank(alice);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.BidWithdrawn(saleId, alice, 1 ether);
        auction.withdrawBid(saleId);
        assertEq(auction.claimable(alice), 1 ether);
        assertEq(auction.auction(saleId).bidder, address(0));
        assertEq(auction.auction(saleId).bid, 1 ether, "the reserve stays");
        auction.resume(saleId);
        assertEq(auction.minimumBid(saleId), 1 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.BidTooLow.selector, 1 ether, 0.5 ether)
        );
        auction.bid{ value: 0.5 ether }(saleId, address(0));
    }

    function test_Resume_GivesBackAtLeastTheDuration() public {
        uint256 saleId = _paused();
        uint256 endBefore = auction.auction(saleId).endTime;
        vm.warp(block.timestamp + 1 days);
        auction.resume(saleId);
        // Paused one hour into a one-day sale: 23 hours remained, less than the duration.
        assertEq(auction.auction(saleId).endTime, block.timestamp + DURATION);
        assertGt(auction.auction(saleId).endTime, endBefore);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.ACTIVE));
    }

    function test_Pause_EndsByItselfAfterMaxPause() public {
        uint256 saleId = _paused();
        uint256 pausedAt = block.timestamp;
        vm.warp(pausedAt + 3 days);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.PAUSED));
        vm.warp(pausedAt + 3 days + 1);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.ACTIVE));
        (, uint64 end, uint64 at) = auction.auctionClock(saleId);
        assertEq(end, pausedAt + 3 days + DURATION);
        assertEq(at, 0);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(saleId, uint64(pausedAt + 3 days + DURATION));
        _bid(bob, saleId, 2 ether);
    }

    function test_Cancel_BurnsAndCreditsAfterARecordedOutcome() public {
        uint256 saleId = _paused();
        statements.setOutcome(address(stream), 1, OUTCOME, 0);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionCancelled(saleId, OUTCOME);
        auction.cancel(saleId, OUTCOME);
        assertEq(uint256(_state(saleId)), uint256(IEnglishAuction.AuctionState.CANCELLED));
        assertEq(auction.claimable(alice), 1 ether);
        assertEq(stream.totalBurned(), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        stream.ownerOf(1);
        assertEq(stream.tokenOfContent(policy.factsOf(1).contentHash), 1);
    }

    function test_Cancel_NeedsTheTokensOwnOutcomeRecordedAfterThePause() public {
        uint256 saleId = _start(1);
        statements.setOutcome(address(stream), 1, OUTCOME, 4);
        auction.pause(saleId, REF);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, OUTCOME)
        );
        auction.cancel(saleId, OUTCOME);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, bytes32(0))
        );
        auction.cancel(saleId, bytes32(0));
        bytes32 later = keccak256("later");
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, later)
        );
        auction.cancel(saleId, later);
        statements.setOutcome(address(stream), 1, later, 5);
        auction.cancel(saleId, later);
        assertEq(stream.totalBurned(), 1);
    }

    function test_Cancel_RefusedOnceThePauseRanOut() public {
        uint256 saleId = _paused();
        statements.setOutcome(address(stream), 1, OUTCOME, 0);
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.cancel(saleId, OUTCOME);
    }

    function test_Cancel_ThenNothingSettles() public {
        uint256 saleId = _paused();
        statements.setOutcome(address(stream), 1, OUTCOME, 0);
        auction.cancel(saleId, OUTCOME);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.CANCELLED
            )
        );
        auction.settle(saleId);
        assertEq(address(auction).balance, 1 ether);
        vm.prank(alice);
        auction.claim(alice);
        assertEq(address(auction).balance, 0);
    }

    /// @dev An outcome recorded before the pause cannot cancel the sale even while it is still
    ///      the token's latest outcome (LIFECYCLE-4, found by mutation testing): the pause
    ///      requires a position after the latest one at the pause.
    function test_Cancel_RefusesTheLatestOutcomeWhenItPredatesThePause() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _recordOutcome(1);
        bytes32 early = _recordOutcome(1);
        _pause(saleId);
        vm.prank(setter);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.OutcomeNotRecorded.selector, saleId, early)
        );
        auction.cancel(saleId, early);
        bytes32 fresh = _recordOutcome(1);
        vm.prank(setter);
        auction.cancel(saleId, fresh);
        assertEq(uint8(_state(saleId)), uint8(IEnglishAuction.AuctionState.CANCELLED));
        assertEq(auction.claimable(alice, ETH), 1 ether);
    }

    /// @dev Delisting checks nothing about the token (found by mutation testing): an account
    ///      with no code, which could never be listed, is delisted with its event.
    function test_SetTarget_DelistingChecksNothing() public {
        vm.expectEmit(address(auction));
        emit ISaleAdapter.TargetSet(alice, false);
        vm.prank(successor);
        auction.setTarget(alice, false);
        assertFalse(auction.isTarget(alice));
    }
}
