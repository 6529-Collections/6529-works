// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { AuctionBase } from "./AuctionBase.sol";

/// @notice The English auction's credit clock (R12, AUC-49): one clock per account and currency,
///         started when the credit goes from zero and not moved by later additions; and the cost
///         to a bidder of recovering an outbid bid, which is credited, never pushed.
contract AuctionCreditClockTest is AuctionBase {
    /// @dev An outbid refund credited on day 179 of an older, unclaimed credit is sent to the
    ///      network with it one day later: the new money was claimable for one day, not 180.
    ///      Passes while the finding stands (a later addition is taken on the older clock);
    ///      fails with "finding fixed" once only money unclaimed for 180 days can expire.
    function test_Finding_ARefundCreditedOnDay179OfAnOlderCreditExpiresWithItADayLater() public {
        uint256 first = _start();
        _bidEth(first, alice, 1 ether);
        _bidEth(first, bob, 2 ether); // alice: 1 ETH credited, clock starts now
        uint256 clockStart = block.timestamp;

        vm.warp(clockStart + 179 days);
        uint256 second = _start();
        _bidEth(second, alice, 5 ether);
        _bidEth(second, carol, 6 ether); // alice: 5 ETH more, credited on day 179
        assertEq(auction.claimable(alice, ETH), 6 ether);

        vm.warp(clockStart + 180 days); // one day after the 5 ETH was credited
        vm.prank(makeAddr("anyone"));
        uint256 taken = auction.expireCredit(alice, ETH);
        assertEq(taken, 6 ether, "finding fixed");
        assertEq(network.balance, 6 ether, "the day-old refund went to the network");
    }

    /// @dev An outbid bid is credited, never pushed: the bidder needs a second transaction of its
    ///      own to get its ETH back, and no keeper path pushes an ETH credit (`claimFor` refuses
    ///      ETH). Logs the gas of that claim (execution gas, excluding the 21,000 base).
    function test_Claim_AnOutbidBidderRecoversItsBidOnlyByItsOwnClaim() public {
        uint256 saleId = _start();
        _bidEth(saleId, alice, 1 ether);
        _bidEth(saleId, bob, 2 ether);
        assertEq(alice.balance, 0, "nothing pushed back");
        assertEq(auction.claimable(alice, ETH), 1 ether);

        vm.prank(makeAddr("keeper"));
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidAsset.selector, ETH));
        auction.claimFor(alice, ETH);

        vm.prank(alice);
        uint256 before = gasleft();
        auction.claim(ETH, alice);
        uint256 used = before - gasleft();
        emit log_named_uint("claim of one ETH credit, execution gas", used);
        assertEq(alice.balance, 1 ether);
        assertLt(used, 40_000, "a small second transaction");
        vm.expectRevert(abi.encodeWithSelector(ISaleAdapter.NothingToClaim.selector, alice, ETH));
        vm.prank(alice);
        auction.claim(ETH, alice);
    }
}
