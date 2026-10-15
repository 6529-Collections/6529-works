// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH, PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { MockFederationRegistry, MockMintTarget } from "../mocks/auction/AuctionMocks.sol";
import { MarketPoCBase } from "./MarketPoCBase.sol";

/// @notice MARKET-5 regression, on the real stack with a mock federated token and registry
///         (ADR 0001 section 16: a delisted contract cannot sell through the network's adapters).
///         A federated auction whose contract is delisted mid-auction takes no more bids, and
///         its settlement credits the high bid back and gives the work to its artist.
contract Market5RegressionTest is MarketPoCBase {
    function test_MARKET5_DelistedFederatedAuctionStopsSelling() public {
        (MockFederationRegistry reg, MockMintTarget fed) =
            _federated(makeAddr("fedSeller"), economics.networkFeeRecipient(PRODUCT_FEDERATED));
        uint256 saleId = auction.start(address(fed), "");
        _ethBid(saleId, collector, 0.5 ether);

        reg.setStatus(address(fed), IFederationRegistry.Status.DELISTED, keccak256("vote"));
        assertFalse(auction.isTarget(address(fed)));

        address late = makeAddr("lateBidder");
        vm.deal(late, 2 ether);
        vm.prank(late);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fed))
        );
        auction.bid{ value: 2 ether }(
            saleId, address(0), Payment(PaymentMethod.DIRECT, late, 2 ether, 0, 0, "")
        );

        vm.warp(auction.auction(saleId).endTime);
        vm.expectEmit(address(auction));
        emit ISaleAdapter.Credited(collector, CURRENCY_ETH, saleId, 0.5 ether);
        auction.settle(saleId);
        assertEq(fed.ownerOf(1), artist, "the work goes to its artist, nothing confiscated");
        assertEq(auction.claimable(collector, CURRENCY_ETH), 0.5 ether, "the bid is credited");
        assertEq(address(auction).balance, 0.5 ether, "nothing was paid out");
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));
    }

    function test_MARKET5_RelistedContractSellsAgain() public {
        (MockFederationRegistry reg, MockMintTarget fed) =
            _federated(makeAddr("fedSeller"), economics.networkFeeRecipient(PRODUCT_FEDERATED));
        uint256 saleId = auction.start(address(fed), "");
        reg.setStatus(address(fed), IFederationRegistry.Status.DELISTED, keccak256("vote"));
        reg.setStatus(address(fed), IFederationRegistry.Status.ACTIVE, keccak256("appeal"));
        _ethBid(saleId, collector, 0.5 ether);
        _settleAtEnd(saleId);
        assertEq(fed.ownerOf(1), collector);
    }
}
