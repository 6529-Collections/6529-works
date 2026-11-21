// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Example: settle a 1/1 sale and see what each party receives.
//
// Settlement is permissionless once the auction is ENDED. One call pays the seller split
// wallet and the network fee recipient, and delivers the token to the winner. With no bid,
// the work goes to the 6529 Network Museum instead.

import { Vm } from "forge-std/Vm.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { PrimaryOutcome, PrimaryTerms } from "src/interfaces/types/SaleTypes.sol";
import { IntegrationBase } from "test/integration/IntegrationBase.sol";

contract ExampleSettleASale is IntegrationBase {
    address internal winner = makeAddr("winner");
    address internal settler = makeAddr("settler");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        address artist = _actor("artist");
        Work[] memory works = new Work[](2);
        works[0] = _work(artist, collectionId);
        works[1] = _work(artist, collectionId);
        root = _publish(works);
        _keep(root, works);
    }

    function test_SettleWithAWinner() public {
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 0);
        _ethBid(saleId, winner, 2 ether);

        // The terms the sale pays by: the seller split wallet, the network fee recipient and
        // its share (out of 100,000).
        PrimaryTerms memory t = stream.primaryTerms(tokenId, "");
        uint256 fee = uint256(2 ether) * t.feeShare / 100_000;
        uint256 sellerBefore = t.seller.balance;
        uint256 feeBefore = t.feeRecipient.balance;

        // Wait for the end, then anyone settles. Use eth_estimateGas for the limit: settle
        // refuses to run without enough gas to give each payout and the delivery their full
        // allowance (about 460K for ETH), although it uses much less.
        vm.warp(auction.auction(saleId).endTime);
        vm.recordLogs();
        vm.prank(settler);
        auction.settle(saleId);

        // The winner has the token; the seller wallet has the price less the fee; the network
        // fee recipient has the fee (rounding goes to the network).
        assertEq(stream.ownerOf(tokenId), winner);
        assertEq(t.seller.balance - sellerBefore, 2 ether - fee, "seller split wallet");
        assertEq(t.feeRecipient.balance - feeBefore, fee, "network fee recipient");
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.SETTLED));

        // SaleSettled carries the whole outcome in one event.
        Vm.Log memory settled = _last(vm.getRecordedLogs(), ISaleAdapter.SaleSettled.selector);
        (address buyer,,, address currency, uint256 price,, uint256 proceeds,, uint256 paidFee) = abi.decode(
            settled.data,
            (address, address, uint256, address, uint256, address, uint256, address, uint256)
        );
        assertEq(buyer, winner);
        assertEq(currency, address(0));
        assertEq(price, 2 ether);
        assertEq(proceeds + paidFee, price);

        // The seller wallet is a split wallet: its payees release their shares from it (see
        // ReleaseFromASplit.t.sol). The fee recipient is a governed vault that forwards to the
        // network's destination.
    }

    function test_SettleWithNoBid() public {
        (uint256 saleId, uint256 tokenId) = _start(root, _package(root), 1);
        vm.warp(auction.auction(saleId).endTime);
        auction.settle(saleId);
        // No bid: the work goes to the museum the economics resolver names at settlement.
        assertEq(stream.ownerOf(tokenId), economics.museum());
        (PrimaryOutcome outcome,,) = stream.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.UNBID));
    }

    function _last(Vm.Log[] memory logs, bytes32 topic) internal pure returns (Vm.Log memory) {
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == topic) return logs[i - 1];
        }
        revert("event not found");
    }
}
