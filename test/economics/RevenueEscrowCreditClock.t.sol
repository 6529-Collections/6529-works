// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { EconomicsBase } from "./EconomicsBase.sol";
import { BlocklistToken, ReentrantRecipient } from "../mocks/economics/EconomicsMocks.sol";

/// @notice The escrow's credit clock (R12, ECO-45) and the order of its deposit checks, which the
///         English auction's `settleOrRefund` reads as a lock probe.
contract RevenueEscrowCreditClockTest is EconomicsBase {
    /// @dev Anyone may deposit for any wallet. A stranger's one-unit deposit opens the wallet's
    ///      window; a real payout escrowed for that wallet on day 179 (a USDC-style token blocks
    ///      the wallet, so it cannot be flushed) joins the window and keeps its own 180 days: the
    ///      window's credits move together from day 359, 180 days after the payout, never on day
    ///      180. (Before the windows, the payout expired with the dust's clock on day 180.)
    function test_AStrangersDustDepositDoesNotShortenALaterPayoutsClock() public {
        BlocklistToken usdb = new BlocklistToken();
        address seller = makeAddr("blockedSeller");
        usdb.setBlocked(seller, true);
        address stranger = makeAddr("stranger");
        address adapter = makeAddr("saleAdapter");
        usdb.mint(stranger, 1);
        usdb.mint(adapter, 5_000e6);
        vm.prank(stranger);
        usdb.approve(address(escrow), 1);
        vm.prank(adapter);
        usdb.approve(address(escrow), 5_000e6);

        vm.prank(stranger);
        escrow.depositERC20(seller, address(usdb), 1); // day 0: dust opens the window
        uint256 start = block.timestamp;

        vm.warp(start + 179 days);
        vm.prank(adapter);
        escrow.depositERC20(seller, address(usdb), 5_000e6); // a failed payout, escrowed
        vm.expectRevert();
        escrow.flush(seller, address(usdb));

        vm.warp(start + 180 days);
        uint256 dueAt = start + 179 days + 180 days;
        assertEq(escrow.expirableAt(seller, address(usdb), block.timestamp), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.CreditNotExpired.selector, seller, address(usdb), dueAt
            )
        );
        escrow.expire(seller, address(usdb));

        vm.warp(dueAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.CreditNotExpired.selector, seller, address(usdb), dueAt
            )
        );
        escrow.expire(seller, address(usdb));

        vm.warp(dueAt);
        assertEq(escrow.expire(seller, address(usdb)), 5_000e6 + 1, "180 days after the payout");
        assertEq(escrow.owed(address(feeVault), address(usdb)), 5_000e6 + 1, "now the network's");
    }

    /// @dev Pins the order `settleOrRefund` relies on: a zero deposit reverts with `ZeroAmount`
    ///      when the escrow's guard is free, and with `ReentrancyGuardReentrantCall` (not
    ///      `ZeroAmount`) while a call holds it. If the amount check ran before the guard, the
    ///      auction would read a held guard as free.
    function test_DepositETH_AZeroDepositRevertsOnTheGuardBeforeTheAmount() public {
        vm.expectRevert(IRevenueEscrow.ZeroAmount.selector);
        escrow.depositETH(alice);

        ReentrantRecipient inside = new ReentrantRecipient();
        inside.configure(address(escrow), abi.encodeCall(IRevenueEscrow.depositETH, (alice)));
        vm.deal(address(this), 1);
        escrow.depositETH{ value: 1 }(address(inside));
        escrow.flush(address(inside), ETH); // pays `inside`, which probes from within the guard
        assertFalse(inside.lastOk());
        assertEq(
            inside.lastResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "the guard is checked first"
        );
    }
}
