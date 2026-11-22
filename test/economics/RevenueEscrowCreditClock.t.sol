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
    /// @dev Anyone may deposit for any wallet, so a stranger can start a wallet's clock with one
    ///      base unit while its credit is zero. A real payout escrowed for that wallet on day 179
    ///      (a USDC-style token blocks the wallet, so it cannot be flushed) then expires to the
    ///      network on day 180: one day, not 180, and less than the 3 days a consented `recover`
    ///      needs. Passes while the finding stands; fails with "finding fixed" once a later
    ///      addition keeps 180 days of its own.
    function test_Finding_AStrangersDustDepositShortensALaterPayoutsClockToOneDay() public {
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
        escrow.depositERC20(seller, address(usdb), 1); // day 0: the clock starts on dust
        uint256 clockStart = block.timestamp;

        vm.warp(clockStart + 179 days);
        vm.prank(adapter);
        escrow.depositERC20(seller, address(usdb), 5_000e6); // a failed payout, escrowed
        vm.expectRevert();
        escrow.flush(seller, address(usdb));

        vm.warp(clockStart + 180 days);
        uint256 taken = escrow.expire(seller, address(usdb));
        assertEq(taken, 5_000e6 + 1, "finding fixed");
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
