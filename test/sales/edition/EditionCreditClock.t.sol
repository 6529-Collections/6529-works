// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice The edition auction's credit clock (R12, EA-16): a bid's refund never expires while it
///         stays in the bid; `claimBidFor`, which anyone may call, turns it into a credit, and a
///         credit expires on the clock of the oldest unclaimed credit of the same account.
contract EditionCreditClockTest is EditionAuctionBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /// @dev Bob's first losing bid is credited on day 0 and left unclaimed. On day 179 a third
    ///      party claims bob's second losing bid for him: its refund joins the day-0 credit, and
    ///      both go to the network on day 180. Left in its bid, that refund would never have
    ///      expired. Passes while the finding stands; fails with "finding fixed" once a refund is
    ///      only taken after 180 days of its own.
    function test_Finding_AThirdPartyTurnsABidRefundIntoACreditThatExpiresADayLater() public {
        uint256 saleId = _open(0);
        _bid(saleId, alice, 100, 1);
        _bid(saleId, bob, 0, 1);
        _bid(saleId, bob, 0, 1);
        _settle(saleId);
        auction.claimBidFor(saleId, 2);
        uint256 clockStart = block.timestamp;
        uint256 firstRefund = ua.claimable(bob, address(0));

        vm.warp(clockStart + 179 days);
        vm.prank(makeAddr("stranger"));
        auction.claimBidFor(saleId, 3);
        uint256 total = ua.claimable(bob, address(0));
        assertGt(total, firstRefund, "the second refund is now a credit");
        assertEq(lens.creditExpiresAt(bob), clockStart + 180 days, "on the day-0 clock");

        vm.warp(clockStart + 180 days);
        uint256 taken = auction.expireCredit(bob, address(0));
        assertEq(taken, total, "finding fixed");
        refundsOut += taken;
        _assertConserved();
    }
}
