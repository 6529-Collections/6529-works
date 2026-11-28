// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionAuctionBase } from "./EditionAuctionBase.sol";

/// @notice What the edition auction holds (EA-14): at every stage of a sale its ETH balance is
///         exactly the escrow of the bids not yet claimed plus the credits it owes, each figure
///         worked out here from the step prices, not read back from the auction.
contract UniformEditionAuctionHoldingsTest is EditionAuctionBase {
    address internal alice = makeAddr("holdingsAlice");
    address internal bob = makeAddr("holdingsBob");
    address internal carol = makeAddr("holdingsCarol");

    function _held() internal view returns (uint256) {
        return address(auction).balance;
    }

    /// EA-14: while bids are taken the balance is the sum of the bids' escrow (a raise adds its
    /// difference); after settlement it is what the unclaimed bids are still owed; a refund
    /// kept as a credit stays in the balance until its owner takes it; and once every bid is
    /// claimed and every credit paid the auction holds nothing.
    function test_Holdings_AreTheUnclaimedEscrowPlusTheCredits() public {
        uint256 saleId = _open(0);
        assertEq(_held(), 0);
        // Alice bids one copy and raises it; Bob fifty copies; Carol a hundred at a low step.
        uint256 aliceBid = _bid(saleId, alice, 190, 1);
        assertEq(_held(), _price(saleId, 190));
        _raise(saleId, aliceBid, 192);
        uint256 aliceEscrow = _price(saleId, 192);
        assertEq(_held(), aliceEscrow);
        uint256 bobBid = _bid(saleId, bob, 130, 50);
        uint256 carolBid = _bid(saleId, carol, 96, 100);
        uint256 carolEscrow = 100 * _price(saleId, 96);
        assertEq(_held(), aliceEscrow + 50 * _price(saleId, 130) + carolEscrow);

        // Settlement pays the revenue out: 51 copies at Bob's step. Alice is owed the
        // difference, Bob nothing, Carol her whole escrow.
        _settle(saleId);
        uint256 price = _price(saleId, 130);
        IUniformEditionAuction.Settlement memory result = ua.settlement(saleId);
        assertEq(result.count, 51);
        assertEq(result.price, price);
        assertEq(_held(), (aliceEscrow - price) + carolEscrow);

        // Anyone claims Carol's bid for her: the refund becomes a credit and stays held.
        vm.prank(bob);
        (uint256 won, uint256 refund) = auction.claimBidFor(saleId, carolBid);
        assertEq(won, 0);
        assertEq(refund, carolEscrow);
        assertEq(ua.claimable(carol, CURRENCY_ETH), carolEscrow);
        assertEq(_held(), (aliceEscrow - price) + carolEscrow);

        // Alice and Bob claim: only the credit is left.
        vm.prank(alice);
        (won, refund) = auction.claimBid(saleId, aliceBid, alice);
        assertEq(won, 1);
        assertEq(refund, aliceEscrow - price);
        assertEq(_held(), carolEscrow);
        vm.prank(bob);
        (won, refund) = auction.claimBid(saleId, bobBid, bob);
        assertEq(won, 50);
        assertEq(refund, 0);
        assertEq(_held(), carolEscrow);

        // Carol takes her credit: nothing is left.
        vm.prank(carol);
        assertEq(auction.claim(CURRENCY_ETH, carol), carolEscrow);
        assertEq(ua.claimable(carol, CURRENCY_ETH), 0);
        assertEq(_held(), 0);
        assertEq(carol.balance, carolEscrow);
    }
}
