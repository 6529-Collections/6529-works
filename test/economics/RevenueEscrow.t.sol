// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ReentrantRecipient, ToggleRecipient } from "../mocks/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

contract RevenueEscrowTest is EconomicsBase {
    address internal depositor = makeAddr("depositor");
    address internal keeper = makeAddr("keeper");
    SplitWallet internal wallet;

    function setUp() public override {
        super.setUp();
        wallet = _wallet(_list(_fixed(alice, 60_000), _fixed(bob, 40_000)));
        vm.deal(depositor, 100 ether);
        token.mint(depositor, 1_000_000);
        vm.prank(depositor);
        token.approve(address(escrow), type(uint256).max);
    }

    function test_DepositETHCreditsTheWallet() public {
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IRevenueEscrow.Credited(address(wallet), ETH, depositor, 1 ether, 1 ether);
        vm.prank(depositor);
        escrow.depositETH{ value: 1 ether }(address(wallet));
        vm.prank(depositor);
        escrow.depositETH{ value: 2 ether }(address(wallet));
        assertEq(escrow.owed(address(wallet), ETH), 3 ether);
        assertEq(escrow.totalOwed(ETH), 3 ether);
        assertEq(address(escrow).balance, 3 ether);
    }

    function test_DepositERC20PullsExactlyAndCredits() public {
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IRevenueEscrow.Credited(address(wallet), address(token), depositor, 500, 500);
        vm.prank(depositor);
        escrow.depositERC20(address(wallet), address(token), 500);
        assertEq(escrow.owed(address(wallet), address(token)), 500);
        assertEq(escrow.totalOwed(address(token)), 500);
        assertEq(token.balanceOf(address(escrow)), 500);
        assertEq(token.balanceOf(depositor), 1_000_000 - 500);
    }

    function test_DepositsRejectInvalidInputs() public {
        vm.startPrank(depositor);
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(0)));
        escrow.depositETH{ value: 1 }(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(escrow))
        );
        escrow.depositETH{ value: 1 }(address(escrow));
        vm.expectRevert(IRevenueEscrow.ZeroAmount.selector);
        escrow.depositETH(address(wallet));
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidAsset.selector, address(0)));
        escrow.depositERC20(address(wallet), address(0), 1);
        vm.expectRevert(IRevenueEscrow.ZeroAmount.selector);
        escrow.depositERC20(address(wallet), address(token), 0);
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(0)));
        escrow.depositERC20(address(0), address(token), 1);
        vm.expectRevert(abi.encodeWithSelector(TokenTransfer.TokenReadFailed.selector, bob));
        escrow.depositERC20(address(wallet), bob, 1);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(token))
        );
        escrow.depositERC20(address(wallet), address(token), 1);
        token.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, address(token), token.transferFrom.selector
            )
        );
        escrow.depositERC20(address(wallet), address(token), 1);
        assertEq(escrow.totalOwed(address(token)), 0);
    }

    function test_AnyoneFlushesETHOnlyToTheCapturedWallet() public {
        vm.prank(depositor);
        escrow.depositETH{ value: 5 ether }(address(wallet));
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IRevenueEscrow.Flushed(address(wallet), ETH, keeper, 5 ether);
        vm.prank(keeper);
        assertEq(escrow.flush(address(wallet), ETH), 5 ether);
        assertEq(address(wallet).balance, 5 ether);
        assertEq(keeper.balance, 0);
        assertEq(escrow.owed(address(wallet), ETH), 0);
        assertEq(escrow.totalOwed(ETH), 0);
        wallet.release(ETH, _indexOf(wallet, alice));
        assertEq(alice.balance, 3 ether);
    }

    function test_FlushERC20ByExactDelta() public {
        vm.prank(depositor);
        escrow.depositERC20(address(wallet), address(token), 700);
        vm.prank(keeper);
        assertEq(escrow.flush(address(wallet), address(token)), 700);
        assertEq(token.balanceOf(address(wallet)), 700);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_FlushWithNothingOwedReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, address(wallet), ETH)
        );
        escrow.flush(address(wallet), ETH);
        vm.prank(depositor);
        escrow.depositETH{ value: 1 }(address(wallet));
        escrow.flush(address(wallet), ETH);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, address(wallet), ETH)
        );
        escrow.flush(address(wallet), ETH);
    }

    function test_FailedFlushKeepsTheCredit() public {
        ToggleRecipient closed = new ToggleRecipient();
        vm.prank(depositor);
        escrow.depositETH{ value: 1 ether }(address(closed));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.ETHTransferFailed.selector, address(closed), 1 ether
            )
        );
        escrow.flush(address(closed), ETH);
        assertEq(escrow.owed(address(closed), ETH), 1 ether);
        assertEq(escrow.totalOwed(ETH), 1 ether);
        closed.setOpen(true);
        escrow.flush(address(closed), ETH);
        assertEq(address(closed).balance, 1 ether);
    }

    function test_CreditsAreIsolatedPerWalletAndAsset() public {
        SplitWallet other = _solo(bob);
        vm.startPrank(depositor);
        escrow.depositETH{ value: 1 ether }(address(wallet));
        escrow.depositETH{ value: 2 ether }(address(other));
        escrow.depositERC20(address(wallet), address(token), 30);
        vm.stopPrank();
        escrow.flush(address(other), ETH);
        assertEq(escrow.owed(address(wallet), ETH), 1 ether);
        assertEq(escrow.owed(address(wallet), address(token)), 30);
        assertEq(escrow.owed(address(other), ETH), 0);
        assertEq(escrow.totalOwed(ETH), 1 ether);
        assertEq(address(other).balance, 2 ether);
    }

    function test_PlainTransfersAreRejectedOrIgnored() public {
        vm.prank(depositor);
        (bool ok,) = address(escrow).call{ value: 1 ether }("");
        assertFalse(ok);
        vm.prank(depositor);
        token.transfer(address(escrow), 99);
        assertEq(escrow.totalOwed(address(token)), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.NothingOwed.selector, address(wallet), address(token)
            )
        );
        escrow.flush(address(wallet), address(token));
    }

    function test_FlushReentryIsBlocked() public {
        ReentrantRecipient hostile = new ReentrantRecipient();
        vm.startPrank(depositor);
        escrow.depositETH{ value: 1 ether }(address(hostile));
        escrow.depositETH{ value: 1 ether }(address(wallet));
        vm.stopPrank();
        hostile.configure(
            address(escrow), abi.encodeCall(IRevenueEscrow.flush, (address(wallet), ETH))
        );
        escrow.flush(address(hostile), ETH);
        assertFalse(hostile.lastOk());
        assertEq(
            hostile.lastResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(escrow.owed(address(wallet), ETH), 1 ether);
    }

    function test_DeprecatedAssetCreditsStillFlush() public {
        allowlist.admitAsset(address(token), 1);
        vm.prank(depositor);
        escrow.depositERC20(address(wallet), address(token), 10);
        allowlist.deprecateAsset(address(token));
        escrow.flush(address(wallet), address(token));
        assertEq(token.balanceOf(address(wallet)), 10);
    }

    function testFuzz_CreditsAndFlushesConserve(uint96 a, uint96 b, bool flushFirst) public {
        vm.assume(a > 0 && b > 0);
        SplitWallet other = _solo(bob);
        vm.deal(depositor, uint256(a) + b);
        vm.startPrank(depositor);
        escrow.depositETH{ value: a }(address(wallet));
        escrow.depositETH{ value: b }(address(other));
        vm.stopPrank();
        assertEq(escrow.totalOwed(ETH), uint256(a) + b);
        escrow.flush(flushFirst ? address(wallet) : address(other), ETH);
        assertEq(
            escrow.owed(address(wallet), ETH) + escrow.owed(address(other), ETH),
            escrow.totalOwed(ETH)
        );
        assertEq(address(escrow).balance, escrow.totalOwed(ETH));
    }
}
