// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { RevenuePayment } from "src/economics/RevenuePayment.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { GasBurnerMock } from "../mocks/libraries/AdversarialTargets.sol";
import { GasCheckingWallet, RejectingRecipient } from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

contract RevenuePaymentTest is EconomicsBase {
    uint256 internal constant GAS = 50_000;
    address internal wallet;

    function setUp() public override {
        super.setUp();
        wallet = _wallet(_list(_fixed(alice, 75_000), _artist(ARTIST, 25_000)));
        vm.deal(address(payer), 100 ether);
    }

    function test_PayETHGoesStraightToTheWallet() public {
        assertFalse(payer.payETH(address(wallet), 1 ether, GAS));
        assertEq(address(wallet).balance, 1 ether);
        assertEq(escrow.totalOwed(ETH), 0);
    }

    function test_PayETHToUndeployedWalletIsKeptForIt() public {
        address future = factory.walletFor(_list(_fixed(bob, D)), bytes32(0));
        assertFalse(payer.payETH(future, 1 ether, GAS));
        address w = _solo(bob);
        assertEq(address(w), future);
        _release(w, ETH, 0);
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
        assertEq(escrow.totalOwed(ETH), 0);
    }

    /// @dev Review nit, ported inverted from `test_PoC_PaymentToTheEscrowAddressIsStranded`: a
    ///      payment aimed at the escrow's own address would sit there with no credit.
    function test_PaymentsRejectTheEscrowAsAWallet() public {
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(escrow))
        );
        payer.payETH(address(escrow), 1 ether, GAS);
        assertEq(address(escrow).balance, 0);
    }

    /// @dev Review L-3, ported from `test_PoC_CallerCannotStarveETHPaymentIntoEscrow` (kills an
    ///      `ETH_CALL_RESERVE` mutant): at every caller gas level the payment either reverts or
    ///      reaches the wallet with its full allowance; it is never escrowed by starvation.
    function test_CallerCannotStarveETHPaymentIntoEscrow() public {
        uint256 gasLimit = 100_000;
        GasCheckingWallet w = new GasCheckingWallet(gasLimit - 5_000);
        uint256 escrowedCount;
        uint256 okCount;
        for (uint256 g = 100_000; g < 200_000; g += 250) {
            uint256 snap = vm.snapshotState();
            vm.cool(address(w));
            try payer.payETH{ gas: g }(address(w), 1, gasLimit) returns (bool escrowed) {
                ++okCount;
                if (escrowed) ++escrowedCount;
            } catch { }
            vm.revertToState(snap);
        }
        assertGt(okCount, 0);
        assertEq(escrowedCount, 0, "caller forced the escrow route");
    }
}
