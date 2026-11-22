// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Example: settle a 1/1 sale and see what each party receives.
//
// Settling is permissionless once the auction has ended. The winner gets the token, the seller
// split wallet the price less the network's fee, and the network's fee recipient the fee. With
// no bid, the work goes to the museum. Either way Stream records the outcome; the price is only
// logged (`PrimarySale`).

import { Vm } from "forge-std/Vm.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { PRODUCT_STREAM } from "src/interfaces/types/EconomicsTypes.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ExampleBase } from "./ExampleBase.sol";

contract ExampleSettleASale is ExampleBase {
    /// @dev SaleSettled's data: every field after the three indexed ones.
    struct Settled {
        address buyer;
        address recipient;
        uint256 quantity;
        address currency;
        uint256 price;
        address seller;
        uint256 sellerProceeds;
        address feeRecipient;
        uint256 fee;
    }

    address internal collector = makeAddr("collector");
    address internal keeper = makeAddr("keeper");

    function test_SettleASoldWork() public {
        (uint256 saleId, uint256 tokenId) = _start(_original());
        _bid(saleId, collector, 1 ether);
        IEnglishAuction.Auction memory a = auction.auction(saleId);
        address fee = IEconomicsResolver(d.economicsResolver).networkFeeRecipient(PRODUCT_STREAM);
        uint256 feeBefore = fee.balance;

        // Settle at the end; anyone may.
        vm.warp(a.endTime);
        vm.recordLogs();
        vm.prank(keeper);
        auction.settle(saleId);

        assertEq(stream.ownerOf(tokenId), collector, "the winner holds the token");
        uint256 feeAmount = 1 ether * a.feeShare / 100_000;
        assertEq(a.seller.balance, 1 ether - feeAmount, "the seller split wallet");
        assertEq(fee.balance - feeBefore, feeAmount, "the network's fee recipient");
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.SOLD));

        // SaleSettled names every party and amount, so an indexer needs no other read.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(auction)
                    || logs[i].topics[0] != IEnglishAuction.SaleSettled.selector
            ) continue;
            // The non-indexed fields, all static, decode as one struct.
            Settled memory e = abi.decode(logs[i].data, (Settled));
            assertEq(e.buyer, collector);
            assertEq(e.recipient, collector);
            assertEq(e.quantity, 1);
            assertEq(e.currency, address(0), "ETH");
            assertEq(e.price, 1 ether);
            assertEq(e.seller, a.seller);
            assertEq(e.sellerProceeds, 1 ether - feeAmount);
            assertEq(e.feeRecipient, fee);
            assertEq(e.fee, feeAmount);
            seen = true;
        }
        assertTrue(seen);
    }

    function test_AnUnsoldWorkGoesToTheMuseum() public {
        (uint256 saleId, uint256 tokenId) = _start(_original());
        _settleAtEnd(saleId);
        assertEq(stream.ownerOf(tokenId), IEconomicsResolver(d.economicsResolver).museum());
        assertEq(uint8(stream.workOf(tokenId).outcome), uint8(Outcome.UNSOLD));
    }
}
