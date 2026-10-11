// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SplitWallet } from "src/economics/SplitWallet.sol";
import { RevenuePayment } from "src/economics/RevenuePayment.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { GasBurnerMock } from "../mocks/AdversarialTargets.sol";
import { BlocklistToken, GasHungryToken, RejectingRecipient } from "../mocks/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

contract RevenuePaymentTest is EconomicsBase {
    uint256 internal constant GAS = 50_000;
    SplitWallet internal wallet;
    BlocklistToken internal usdc;

    function setUp() public override {
        super.setUp();
        wallet = _wallet(_list(_fixed(alice, 75_000), _artist(ARTIST, 25_000)));
        usdc = new BlocklistToken();
        vm.deal(address(payer), 100 ether);
        usdc.mint(address(payer), 1_000_000);
    }

    function test_PayETHGoesStraightToTheWallet() public {
        assertFalse(payer.payETH(address(wallet), 1 ether, GAS));
        assertEq(address(wallet).balance, 1 ether);
        assertEq(escrow.totalOwed(ETH), 0);
    }

    function test_PayETHToUndeployedWalletIsKeptForIt() public {
        address future = factory.walletFor(_list(_fixed(bob, D)));
        assertFalse(payer.payETH(future, 1 ether, GAS));
        SplitWallet w = _solo(bob);
        assertEq(address(w), future);
        w.release(ETH, 0);
        assertEq(bob.balance, 1 ether);
    }

    function test_PayETHFallsBackToEscrowWhenRefused() public {
        RejectingRecipient refusing = new RejectingRecipient();
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IRevenueEscrow.Credited(address(refusing), ETH, address(payer), 1 ether, 1 ether);
        assertTrue(payer.payETH(address(refusing), 1 ether, GAS));
        assertEq(escrow.owed(address(refusing), ETH), 1 ether);
        assertEq(address(escrow).balance, 1 ether);
    }

    function test_PayETHGasBurnerIsContainedAndEscrowed() public {
        GasBurnerMock burner = new GasBurnerMock();
        uint256 before = gasleft();
        assertTrue(payer.payETH(address(burner), 1 ether, GAS));
        assertLt(before - gasleft(), GAS + 150_000);
        assertEq(escrow.owed(address(burner), ETH), 1 ether);
    }

    function test_PayETHRevertsWhenTheWalletCannotGetItsFullGas() public {
        vm.expectRevert(
            abi.encodeWithSelector(RevenuePayment.PaymentInsufficientGas.selector, 1_000_000)
        );
        payer.payETH{ gas: 500_000 }(address(wallet), 1 ether, 1_000_000);
        assertEq(address(wallet).balance, 0);
    }

    function test_PayETHRejectsZeroWallet() public {
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(0)));
        payer.payETH(address(0), 1 ether, GAS);
    }

    function test_ZeroAmountsAreNoOpsEvenWhenRefused() public {
        RejectingRecipient refusing = new RejectingRecipient();
        assertFalse(payer.payETH(address(refusing), 0, GAS));
        usdc.setBlocked(address(wallet), true);
        assertFalse(payer.payERC20(address(wallet), address(usdc), 0));
        assertEq(escrow.totalOwed(ETH), 0);
        assertEq(escrow.totalOwed(address(usdc)), 0);
    }

    function test_PayERC20RejectsZeroWallet() public {
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(0)));
        payer.payERC20(address(0), address(usdc), 1);
    }

    function test_PayERC20RevertsWhenTheTokenCannotGetItsFullGas() public {
        uint256 limit = RevenuePayment.ERC20_TRANSFER_GAS;
        vm.expectRevert(abi.encodeWithSelector(TokenTransfer.TokenInsufficientGas.selector, limit));
        payer.payERC20{ gas: 250_000 }(address(wallet), address(usdc), 1);
        assertEq(escrow.totalOwed(address(usdc)), 0);
    }

    function test_GasHungryTokenIsEscrowedNotBlocking() public {
        GasHungryToken hungry = new GasHungryToken();
        hungry.mint(address(payer), 100);
        assertTrue(payer.payERC20(address(wallet), address(hungry), 100));
        assertEq(escrow.owed(address(wallet), address(hungry)), 100);
    }

    function test_PayERC20GoesStraightToTheWallet() public {
        assertFalse(payer.payERC20(address(wallet), address(usdc), 400));
        assertEq(usdc.balanceOf(address(wallet)), 400);
        assertEq(usdc.balanceOf(address(payer)), 1_000_000 - 400);
    }

    function test_PayERC20ToBlockedWalletIsEscrowedThenFlushed() public {
        usdc.setBlocked(address(wallet), true);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IRevenueEscrow.Credited(address(wallet), address(usdc), address(payer), 400, 400);
        assertTrue(payer.payERC20(address(wallet), address(usdc), 400));
        assertEq(escrow.owed(address(wallet), address(usdc)), 400);
        assertEq(usdc.balanceOf(address(escrow)), 400);
        assertEq(usdc.allowance(address(payer), address(escrow)), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, address(usdc), usdc.transfer.selector
            )
        );
        escrow.flush(address(wallet), address(usdc));
        assertEq(escrow.owed(address(wallet), address(usdc)), 400);

        usdc.setBlocked(address(wallet), false);
        escrow.flush(address(wallet), address(usdc));
        assertEq(usdc.balanceOf(address(wallet)), 400);
        wallet.release(address(usdc), _artistIndex(wallet, ARTIST));
        assertEq(usdc.balanceOf(artistPayout), 100);
    }

    function test_PayERC20FromBlockedPayerRevertsAtomically() public {
        usdc.setBlocked(address(payer), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, address(usdc), usdc.transferFrom.selector
            )
        );
        payer.payERC20(address(wallet), address(usdc), 400);
        assertEq(usdc.balanceOf(address(payer)), 1_000_000);
        assertEq(usdc.allowance(address(payer), address(escrow)), 0);
        assertEq(escrow.totalOwed(address(usdc)), 0);
    }

    function test_PayERC20RevertsWithoutFunds() public {
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.TokenBalanceMismatch.selector, address(usdc))
        );
        payer.payERC20(address(wallet), address(usdc), 1_000_001);
    }

    function testFuzz_PaymentsAlwaysReachTheWalletOrItsCredit(uint96 amount, bool blocked) public {
        amount = uint96(bound(amount, 1, 1_000_000));
        usdc.setBlocked(address(wallet), blocked);
        bool escrowed = payer.payERC20(address(wallet), address(usdc), amount);
        assertEq(escrowed, blocked);
        assertEq(
            usdc.balanceOf(address(wallet)) + escrow.owed(address(wallet), address(usdc)), amount
        );
        assertEq(usdc.balanceOf(address(payer)), 1_000_000 - uint256(amount));
    }
}
