// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { AuctionFixture } from "./AuctionFixture.sol";

/// @notice The dispute pause at its edges: the first and the last second of the live pause for
///         `resume` and `cancel` (DSP-16), the clock a resumed or lapsed sale gets when more
///         time remained than the governed duration (DSP-17), and the auction's balance and
///         custody through a pause, a withdrawal, a resumption and a cancel (DSP-23).
contract EnglishAuctionDisputeRulesTest is AuctionFixture {
    bytes32 internal constant REF = keccak256("dispute");
    bytes32 internal constant OUTCOME = keccak256("outcome");

    function _invalidState(uint256 saleId, IEnglishAuction.AuctionState state)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(IEnglishAuction.InvalidAuctionState.selector, saleId, state);
    }

    function _assertState(uint256 saleId, IEnglishAuction.AuctionState state) internal view {
        assertEq(uint256(_state(saleId)), uint256(state));
    }

    /// @dev What the auction must hold for `saleIds` and the three bidders.
    function _owedFor(uint256[] memory saleIds) internal view returns (uint256) {
        address[] memory bidders = new address[](3);
        (bidders[0], bidders[1], bidders[2]) = (alice, bob, carol);
        return _owed(saleIds, bidders);
    }

    // ------------------------------------------------------------------ resume, cancel

    /// DSP-16: `resume` has no wait of its own. It lands in the second of the pause and in the
    /// last second of the live pause (`pausedAt + MAX_PAUSE`); one second later the pause has
    /// ended by itself and there is nothing left to resume.
    function test_Resume_LandsInTheFirstAndTheLastSecondOfTheLivePause() public {
        uint256 first = _start(1);
        uint256 last = _start(2);
        uint256 late = _start(3);
        uint256 pausedAt = block.timestamp;
        auction.pause(first, REF);
        auction.pause(last, REF);
        auction.pause(late, REF);

        auction.resume(first);
        _assertState(first, IEnglishAuction.AuctionState.ACTIVE);

        vm.warp(pausedAt + auction.MAX_PAUSE());
        _assertState(last, IEnglishAuction.AuctionState.PAUSED);
        auction.resume(last);
        _assertState(last, IEnglishAuction.AuctionState.ACTIVE);

        vm.warp(pausedAt + auction.MAX_PAUSE() + 1);
        vm.expectRevert(_invalidState(late, IEnglishAuction.AuctionState.ACTIVE));
        auction.resume(late);
    }

    /// DSP-16: `cancel` has no wait of its own either. With the token's outcome recorded it
    /// lands in the second of the pause and in the last second of the live pause; one second
    /// later it is refused.
    function test_Cancel_LandsInTheFirstAndTheLastSecondOfTheLivePause() public {
        uint256 first = _start(1);
        uint256 last = _start(2);
        uint256 late = _start(3);
        uint256 pausedAt = block.timestamp;
        uint256[3] memory saleIds = [first, last, late];
        for (uint256 i; i < saleIds.length; ++i) {
            auction.pause(saleIds[i], REF);
            statements.setOutcome(address(stream), _tokenId(saleIds[i]), OUTCOME, 0);
        }

        auction.cancel(first, OUTCOME);
        _assertState(first, IEnglishAuction.AuctionState.CANCELLED);

        vm.warp(pausedAt + auction.MAX_PAUSE());
        auction.cancel(last, OUTCOME);
        _assertState(last, IEnglishAuction.AuctionState.CANCELLED);

        vm.warp(pausedAt + auction.MAX_PAUSE() + 1);
        vm.expectRevert(_invalidState(late, IEnglishAuction.AuctionState.ACTIVE));
        auction.cancel(late, OUTCOME);
        assertEq(stream.totalBurned(), 2);
        assertEq(stream.ownerOf(_tokenId(late)), address(auction));
    }

    // ------------------------------------------------------------------ the resumed clock

    /// DSP-17: when more time remained at the pause than the governed duration in force at the
    /// resumption, the resumed sale keeps its remaining time; it is not cut to the duration.
    function test_Resume_KeepsTheRemainingTimeWhenItIsLongerThanTheDuration() public {
        uint256 saleId = _start(1);
        IEnglishAuction.AuctionConfig memory c = auction.config();
        IEnglishAuction.AuctionConfig memory shorter = c;
        shorter.duration = c.duration / 4;
        auction.setConfig(c, shorter);

        vm.warp(block.timestamp + 1 hours);
        auction.pause(saleId, REF);
        IEnglishAuction.Auction memory paused = auction.auction(saleId);
        uint256 remaining = paused.endTime - paused.pausedAt;
        assertGt(remaining, auction.config().duration, "more remained than the duration");

        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionResumed(saleId, uint64(block.timestamp + remaining));
        auction.resume(saleId);
        assertEq(auction.auction(saleId).endTime, block.timestamp + remaining);
        _assertState(saleId, IEnglishAuction.AuctionState.ACTIVE);
    }

    /// DSP-17: a pause that lapses gives the same clock: the remaining time from the end of the
    /// pause when it is longer than the duration, else the duration.
    function test_Pause_ALapsedPauseKeepsTheRemainingTimeOrTheDuration() public {
        uint256 longSale = _start(1);
        IEnglishAuction.AuctionConfig memory c = auction.config();
        IEnglishAuction.AuctionConfig memory shorter = c;
        shorter.duration = c.duration / 4;
        auction.setConfig(c, shorter);
        uint256 shortSale = _start(2);

        // Late enough that the second sale has less left than its duration.
        vm.warp(block.timestamp + shorter.duration / 2);
        uint256 pausedAt = block.timestamp;
        auction.pause(longSale, REF);
        auction.pause(shortSale, REF);
        uint256 remainingLong = auction.auction(longSale).endTime - pausedAt;
        uint256 remainingShort = auction.auction(shortSale).endTime - pausedAt;
        assertGt(remainingLong, shorter.duration);
        assertLt(remainingShort, shorter.duration);

        uint256 lapsedAt = pausedAt + auction.MAX_PAUSE();
        vm.warp(lapsedAt + 1);
        (, uint64 endLong,) = auction.auctionClock(longSale);
        (, uint64 endShort,) = auction.auctionClock(shortSale);
        assertEq(endLong, lapsedAt + remainingLong, "the remaining time");
        assertEq(endShort, lapsedAt + shorter.duration, "at least the duration");
        _assertState(longSale, IEnglishAuction.AuctionState.ACTIVE);
        _assertState(shortSale, IEnglishAuction.AuctionState.ACTIVE);
    }

    // ------------------------------------------------------------------ money and custody

    /// DSP-23: through a pause, a withdrawal, a resumption, a new bid and a cancel, the
    /// auction's balance is exactly its standing bids plus its credits, every token is where
    /// its sale says, and once everything is settled and claimed nothing is left and every
    /// wei that came in went back out.
    function test_Dispute_BalanceCoversBidsAndCreditsAndCustodyIsExactAtEveryStep() public {
        address[5] memory wallets = [alice, bob, carol, seller, feeRecipient];
        uint256 totalBefore;
        for (uint256 i; i < wallets.length; ++i) {
            totalBefore += wallets[i].balance;
        }
        uint256[] memory saleIds = new uint256[](2);
        saleIds[0] = _start(1);
        saleIds[1] = _start(2);
        (uint256 kept, uint256 cancelled) = (saleIds[0], saleIds[1]);
        _bid(alice, kept, 1 ether);
        _bid(bob, cancelled, 2 ether);
        _bid(carol, cancelled, 3 ether);
        assertEq(address(auction).balance, 6 ether);
        assertEq(address(auction).balance, _owedFor(saleIds));

        auction.pause(kept, REF);
        auction.pause(cancelled, REF);
        assertEq(address(auction).balance, _owedFor(saleIds), "paused");

        vm.prank(alice);
        auction.withdrawBid(kept);
        assertEq(auction.claimable(alice), 1 ether);
        assertEq(address(auction).balance, 6 ether, "a withdrawal moves a bid to a credit");
        assertEq(address(auction).balance, _owedFor(saleIds), "withdrawn");

        auction.resume(kept);
        _bid(bob, kept, 1 ether);
        assertEq(address(auction).balance, _owedFor(saleIds), "resumed and bid on");

        statements.setOutcome(address(stream), _tokenId(cancelled), OUTCOME, 0);
        auction.cancel(cancelled, OUTCOME);
        assertEq(auction.claimable(carol), 3 ether);
        assertEq(address(auction).balance, 7 ether, "a cancel pays nothing out");
        assertEq(address(auction).balance, _owedFor(saleIds), "cancelled");

        // Custody: the kept work is still the auction's, the cancelled one is burned.
        assertEq(stream.ownerOf(_tokenId(kept)), address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC721Errors.ERC721NonexistentToken.selector, _tokenId(cancelled)
            )
        );
        stream.ownerOf(_tokenId(cancelled));
        assertEq(stream.balanceOf(address(auction)), 1);

        _end(kept);
        auction.settle(kept);
        assertEq(stream.ownerOf(_tokenId(kept)), bob);
        assertEq(stream.balanceOf(address(auction)), 0);
        assertEq(address(auction).balance, _owedFor(saleIds), "settled");

        address[3] memory bidders = [alice, bob, carol];
        for (uint256 i; i < bidders.length; ++i) {
            vm.prank(bidders[i]);
            auction.claim(bidders[i]);
        }
        assertEq(address(auction).balance, 0, "nothing is left");
        assertEq(address(escrow).balance, 0, "nothing was refused");
        uint256 totalAfter;
        for (uint256 i; i < wallets.length; ++i) {
            totalAfter += wallets[i].balance;
        }
        assertEq(totalAfter, totalBefore, "value is conserved");
        assertEq(seller.balance + feeRecipient.balance, 1 ether, "the one sale's price");
    }
}
