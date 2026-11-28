// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IndependentEditionAuctionTest } from "./IndependentEditionAuction.t.sol";

/// @notice The Independent Stream edition auction voids an edition's sale when only its master
///         contract is delisted (review C L-5), as the English auction refunds the master's 1/1.
///         Runs the Independent Stream edition auction suite again with this case added.
contract IndependentEditionAuctionFixesTest is IndependentEditionAuctionTest {
    function test_DelistedMaster_VoidsTheEditionSale() public {
        uint256 saleId = _open();
        _bid(saleId, alice, 100, 1);
        gate.setActive(address(master), false);
        uint256 amount = ua.stepPrice(saleId, 10);
        vm.deal(bob, amount);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.BiddingClosed.selector, saleId, 0)
        );
        auction.bid{ value: amount }(saleId, 10, 1);
        assertTrue(auction.settle(saleId, new uint256[](0)));
        assertEq(uint8(ua.auction(saleId).status), uint8(IUniformEditionAuction.AuctionStatus.VOID));
        vm.prank(alice);
        (, uint256 refund) = auction.claimBid(saleId, 1, alice);
        assertEq(refund, ua.stepPrice(saleId, 100));
    }
}
