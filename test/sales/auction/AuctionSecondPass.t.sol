// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { AuctionBase } from "./AuctionBase.sol";

/// @notice The English auction's second-pass rules: the fixed 3-day dispute pause and the
///         network's cancel inside it with no wait (C30), the network fee paid to the recipient
///         current at settlement with the leftover wei (R18), and credits that go to the network
///         after 180 days (R12).
contract AuctionSecondPassTest is AuctionBase {
    function _tokenOf(uint256 saleId) internal view returns (uint256) {
        return auction.auction(saleId).tokenId;
    }

    /// @dev C30: a pause is live through 3 days and ends by itself one second later, resumed
    ///      for at least the governed duration; once it lapsed, it cannot be cancelled. Fails
    ///      without the change: the pause held for 7 days.
    function test_C30_APauseEndsByItselfAtThreeDays() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _pause(saleId);
        uint256 pausedAt = block.timestamp;
        assertEq(auction.MAX_PAUSE(), 3 days);
        vm.warp(pausedAt + 3 days);
        assertEq(
            uint8(auction.auction(saleId).state),
            uint8(IEnglishAuction.AuctionState.PAUSED),
            "live through 3 days, inclusive"
        );
        bytes32 outcome = _recordOutcome(_tokenOf(saleId));
        vm.warp(pausedAt + 3 days + 1);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        assertEq(uint8(a.state), uint8(IEnglishAuction.AuctionState.ACTIVE), "resumed by itself");
        assertEq(a.pausedAt, 0);
        assertEq(a.pausedTotal, 3 days);
        assertGe(a.endTime, block.timestamp - 1 + DURATION - 1, "at least the duration again");
        vm.prank(setter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.cancel(saleId, outcome);
    }

    /// @dev C30: the network cancels in the pause's own block, with no wait, citing an outcome
    ///      recorded after the pause: the bid is credited back and the work burned. Fails without
    ///      the change: `UnpauseTooEarly` until 48 hours after the pause.
    function test_C30_TheNetworkCancelsInsideThePauseWithNoWait() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _pause(saleId);
        bytes32 outcome = _recordOutcome(_tokenOf(saleId));
        vm.expectEmit(address(auction));
        emit IEnglishAuction.AuctionCancelled(saleId, outcome);
        vm.prank(setter);
        auction.cancel(saleId, outcome);
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        assertEq(auction.claimable(alice, ETH), 1 ether, "the bid is credited back");
        assertEq(stream.burned(), 1, "the work is burned");
    }

    /// @dev C30: the network resumes in the pause's own block too.
    function test_C30_TheNetworkResumesWithNoWait() public {
        uint256 saleId = _start();
        _pause(saleId);
        vm.prank(unpauser);
        auction.resume(saleId);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ACTIVE));
    }

    /// @dev R18: settlement pays the network's fee to the recipient the economics resolver names
    ///      at settlement, even when it changed after the start, and the fee is the remainder
    ///      after the seller's part rounds down: on a price that does not divide, the leftover
    ///      wei is the network's. Fails without the change: the token's recipient was paid and
    ///      the fee rounded down.
    function test_R18_SettlementPaysTheCurrentRecipientAndTheLeftoverWei() public {
        uint256 saleId = _start();
        uint256 price = 1 ether + 7;
        _bidEth(saleId, alice, price);
        address moved = makeAddr("movedFeeVault");
        resolver.set(PRODUCT_STREAM, moved, FEE);
        _end(saleId);
        auction.settle(saleId);
        uint256 sellerPart = price * (100_000 - FEE) / 100_000;
        assertGt(price * FEE % 100_000, 0, "a price that does not divide");
        assertEq(seller.balance, sellerPart, "the seller's part rounds down");
        assertEq(moved.balance, price - sellerPart, "the current recipient is paid");
        assertEq(price - sellerPart, price * FEE / 100_000 + 1, "the leftover wei");
        assertEq(network.balance, 0, "the token's recipient is not");
    }

    /// @dev R18: when the resolver names no recipient (or the escrow), the token's is paid.
    function test_R18_TheTokensRecipientWhenTheResolverNamesNone() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        resolver.set(PRODUCT_STREAM, address(0), FEE);
        assertEq(auction.lockedTerms(saleId).feeRecipient, network);
        _end(saleId);
        auction.settle(saleId);
        assertEq(network.balance, 0.25 ether);
        resolver.set(PRODUCT_STREAM, address(escrow), FEE);
        uint256 second = _start();
        _bidEth(second, bob, 1 ether);
        _end(second);
        auction.settle(second);
        assertEq(network.balance, 0.5 ether);
    }

    /// @dev R12: a credit not claimed 180 days after it was last added to goes to the network's
    ///      fee recipient, sent by anyone, and not a second earlier; a new credit restarts the
    ///      clock. Fails without the change: credits never expire.
    function test_R12_ACreditGoesToTheNetworkAfter180Days() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        uint256 expiresAt = block.timestamp + 180 days;
        assertEq(auction.creditExpiresAt(alice, ETH), expiresAt);
        // A new credit restarts the clock.
        vm.warp(block.timestamp + 1 hours);
        _bidEth(saleId, alice, 3 ether);
        _bidEth(saleId, carol, 4 ether);
        expiresAt = block.timestamp + 180 days;
        assertEq(auction.creditExpiresAt(alice, ETH), expiresAt);
        assertEq(auction.claimable(alice, ETH), 4 ether);
        vm.warp(expiresAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.CreditNotExpired.selector, alice, expiresAt)
        );
        auction.expireCredit(alice, ETH);
        vm.warp(expiresAt);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Claimed(alice, ETH, network, 4 ether);
        vm.prank(makeAddr("anyone"));
        assertEq(auction.expireCredit(alice, ETH), 4 ether);
        assertEq(network.balance, 4 ether);
        assertEq(auction.claimable(alice, ETH), 0);
        assertEq(auction.creditExpiresAt(alice, ETH), 0);
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NothingToClaim.selector, alice, ETH));
        auction.expireCredit(alice, ETH);
    }
}
