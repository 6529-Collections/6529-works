// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { Roles } from "src/governance/Roles.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { TokenTransfer } from "src/economics/TokenTransfer.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IClaimRouter } from "src/economics/interfaces/IClaimRouter.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    BlocklistToken,
    ForceSender,
    ReentrantRecipient,
    ToggleRecipient
} from "../mocks/economics/EconomicsMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";
import { Dependency } from "src/libraries/Dependency.sol";

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
        allowlist.admitAsset(address(token), 0, 1);
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

    // ------------------------------------------------------------------ recovery (review M-1)

    function test_ConstructorRejectsFactoryWithoutCodeOrDelegated() public {
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, alice));
        new RevenueEscrow(address(manager), ISplitFactory(alice));
        address eoa = makeAddr("delegated");
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(factory)));
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new RevenueEscrow(address(manager), ISplitFactory(eoa));
        assertEq(address(escrow.factory()), address(factory));
        assertEq(escrow.authority(), address(manager));
    }

    /// @dev A token blocklists the original wallet: its sales land in escrow and cannot flush.
    ///      Governance moves those credits to a replacement wallet with identical payees; the
    ///      original wallet's own balance stays stuck.
    function test_RecoverMovesCreditsToAnEquivalentReplacement() public {
        BlocklistToken usdc = new BlocklistToken();
        ISplitWallet.Payee[] memory payees = wallet.payees();
        usdc.mint(address(wallet), 100);
        usdc.setBlocked(address(wallet), true);
        usdc.mint(address(payer), 1000);
        assertTrue(payer.payERC20(address(wallet), address(usdc), 1000));
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransfer.TokenCallFailed.selector, address(usdc), usdc.transfer.selector
            )
        );
        escrow.flush(address(wallet), address(usdc));

        address replacement = factory.createWallet(payees, bytes32(uint256(1)));
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IRevenueEscrow.Recovered(address(wallet), replacement, address(usdc), 1000, 1000);
        escrow.recover(address(wallet), replacement, address(usdc));
        assertEq(escrow.owed(address(wallet), address(usdc)), 0);
        assertEq(escrow.owed(replacement, address(usdc)), 1000);
        assertEq(escrow.totalOwed(address(usdc)), 1000);

        vm.prank(keeper);
        escrow.flush(replacement, address(usdc));
        SplitWallet r = SplitWallet(payable(replacement));
        r.release(address(usdc), _indexOf(r, alice));
        assertEq(usdc.balanceOf(alice), 600);
        assertEq(usdc.balanceOf(address(wallet)), 100, "the blocked wallet's own balance stays");
    }

    function test_RecoverRejectsWalletsThatAreNotEquivalent() public {
        vm.prank(depositor);
        escrow.depositETH{ value: 1 ether }(address(wallet));
        SplitWallet different = _wallet(_list(_fixed(alice, 50_000), _fixed(bob, 50_000)));
        address undeployed = factory.walletFor(wallet.payees(), bytes32(uint256(2)));
        address[4] memory bad = [address(different), address(wallet), undeployed, alice];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRevenueEscrow.NotEquivalentWallet.selector, address(wallet), bad[i]
                )
            );
            escrow.recover(address(wallet), bad[i], ETH);
        }
        // An account that is not a factory wallet needs its own consent (MONEY-2).
        vm.prank(depositor);
        escrow.depositETH{ value: 1 ether }(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.RecoveryNotConsented.selector, alice, address(wallet)
            )
        );
        escrow.recover(alice, address(wallet), ETH);
        assertEq(escrow.owed(address(wallet), ETH), 1 ether);
    }

    // ------------------------------------------------------------------ consented recovery (MONEY-2)

    function test_ConsentToRecoveryRecordsChangesAndWithdraws() public {
        vm.expectEmit(true, true, false, false, address(escrow));
        emit IRevenueEscrow.RecoveryConsentSet(alice, bob);
        vm.prank(alice);
        escrow.consentToRecovery(bob);
        assertEq(escrow.recoveryConsent(alice), bob);

        vm.prank(alice);
        escrow.consentToRecovery(keeper);
        assertEq(escrow.recoveryConsent(alice), keeper);

        vm.expectEmit(true, true, false, false, address(escrow));
        emit IRevenueEscrow.RecoveryConsentSet(alice, address(0));
        vm.prank(alice);
        escrow.consentToRecovery(address(0));
        assertEq(escrow.recoveryConsent(alice), address(0));
        assertEq(escrow.recoveryConsent(bob), address(0), "consent is per account");
    }

    function test_ConsentToRecoveryRejectsTheEscrowAndTheCaller() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(escrow))
        );
        escrow.consentToRecovery(address(escrow));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, alice));
        escrow.consentToRecovery(alice);
        assertEq(escrow.recoveryConsent(alice), address(0));
    }

    /// @dev A blocked account that is not a split wallet (a fee recipient's Safe) names its
    ///      replacement, and governance moves its credit there, one consent per recovery,
    ///      adding to any credit the replacement already holds.
    function test_RecoverMovesAnAccountsCreditToTheReplacementItNamed() public {
        BlocklistToken usdc = new BlocklistToken();
        usdc.setBlocked(alice, true);
        usdc.mint(address(payer), 1000);
        assertTrue(payer.payERC20(alice, address(usdc), 1000));
        vm.startPrank(depositor);
        escrow.depositETH{ value: 1 ether }(alice);
        escrow.depositETH{ value: 2 ether }(bob);
        vm.stopPrank();

        vm.prank(alice);
        escrow.consentToRecovery(bob);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IRevenueEscrow.Recovered(alice, bob, address(usdc), 1000, 1000);
        escrow.recover(alice, bob, address(usdc));
        // Single use: the recovery consumed the consent, so the next asset needs a new one.
        assertEq(escrow.recoveryConsent(alice), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.RecoveryNotConsented.selector, alice, bob)
        );
        escrow.recover(alice, bob, ETH);
        vm.prank(alice);
        escrow.consentToRecovery(bob);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IRevenueEscrow.Recovered(alice, bob, ETH, 1 ether, 3 ether);
        escrow.recover(alice, bob, ETH);
        assertEq(escrow.recoveryConsent(alice), address(0));

        assertEq(escrow.owed(alice, address(usdc)), 0);
        assertEq(escrow.owed(alice, ETH), 0);
        assertEq(escrow.owed(bob, address(usdc)), 1000);
        assertEq(escrow.owed(bob, ETH), 3 ether);
        assertEq(escrow.totalOwed(ETH), 3 ether);
        assertEq(escrow.totalOwed(address(usdc)), 1000);
        vm.prank(keeper);
        escrow.flush(bob, address(usdc));
        assertEq(usdc.balanceOf(bob), 1000);
    }

    function test_RecoverRefusesAnAccountsCreditWithoutMatchingConsent() public {
        vm.prank(depositor);
        escrow.depositETH{ value: 1 ether }(alice);
        address replacement = factory.createWallet(wallet.payees(), bytes32(uint256(1)));
        address[3] memory targets = [bob, replacement, address(0)];
        for (uint256 i; i < targets.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRevenueEscrow.RecoveryNotConsented.selector, alice, targets[i]
                )
            );
            escrow.recover(alice, targets[i], ETH);
        }
        vm.prank(alice);
        escrow.consentToRecovery(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.RecoveryNotConsented.selector, alice, bob)
        );
        escrow.recover(alice, bob, ETH);
        // A withdrawn consent moves nothing.
        vm.prank(alice);
        escrow.consentToRecovery(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.RecoveryNotConsented.selector, alice, address(0))
        );
        escrow.recover(alice, address(0), ETH);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.RecoveryNotConsented.selector, alice, keeper)
        );
        escrow.recover(alice, keeper, ETH);
        assertEq(escrow.owed(alice, ETH), 1 ether);
    }

    /// @dev A failed recovery (nothing owed) leaves the consent in place: only a move uses it.
    function test_ConsentSurvivesARecoveryThatMovesNothing() public {
        vm.prank(alice);
        escrow.consentToRecovery(bob);
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, alice, ETH));
        escrow.recover(alice, bob, ETH);
        assertEq(escrow.recoveryConsent(alice), bob);
    }

    /// @dev A split wallet's credit follows the identical-payees rule whatever consent is
    ///      recorded for its address (a wallet cannot call `consentToRecovery`; the prank only
    ///      proves the rule), and a predicted wallet's credit cannot move at all until the wallet
    ///      is deployed, since no key controls its address.
    function test_WalletCreditsIgnoreConsent() public {
        vm.prank(depositor);
        escrow.depositETH{ value: 1 ether }(address(wallet));
        vm.prank(address(wallet));
        escrow.consentToRecovery(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.NotEquivalentWallet.selector, address(wallet), keeper
            )
        );
        escrow.recover(address(wallet), keeper, ETH);

        address predicted = factory.walletFor(wallet.payees(), bytes32(uint256(9)));
        vm.prank(depositor);
        escrow.depositETH{ value: 1 ether }(predicted);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.RecoveryNotConsented.selector, predicted, address(wallet)
            )
        );
        escrow.recover(predicted, address(wallet), ETH);
    }

    function test_ConsentToRecoveryIsNonPayable() public {
        (bool ok,) = address(escrow).call{ value: 1 }(
            abi.encodeCall(IRevenueEscrow.consentToRecovery, (bob))
        );
        assertFalse(ok);
    }

    /// @dev A replacement with no factory configuration (a contract or an address the factory
    ///      never deployed a wallet to) is never equivalent.
    function test_RecoverRejectsAZeroConfigReplacement() public {
        vm.prank(depositor);
        escrow.depositETH{ value: 1 ether }(address(wallet));
        address[3] memory zeroConfig = [
            address(new ToggleRecipient()),
            factory.walletFor(wallet.payees(), bytes32(uint256(5))),
            address(0)
        ];
        for (uint256 i; i < zeroConfig.length; ++i) {
            assertEq(factory.configOf(zeroConfig[i]), bytes32(0));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRevenueEscrow.NotEquivalentWallet.selector, address(wallet), zeroConfig[i]
                )
            );
            escrow.recover(address(wallet), zeroConfig[i], ETH);
        }
        assertEq(escrow.owed(address(wallet), ETH), 1 ether);
    }

    function test_RecoverAddsToTheReplacementsExistingCredit() public {
        address replacement = factory.createWallet(wallet.payees(), bytes32(uint256(1)));
        vm.startPrank(depositor);
        escrow.depositETH{ value: 1 ether }(address(wallet));
        escrow.depositETH{ value: 2 ether }(replacement);
        vm.stopPrank();
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IRevenueEscrow.Recovered(address(wallet), replacement, ETH, 1 ether, 3 ether);
        escrow.recover(address(wallet), replacement, ETH);
        assertEq(escrow.owed(replacement, ETH), 3 ether);
        assertEq(escrow.owed(address(wallet), ETH), 0);
        assertEq(escrow.totalOwed(ETH), 3 ether);
        escrow.flush(replacement, ETH);
        assertEq(replacement.balance, 3 ether);
    }

    function test_RecoverWithNothingOwedReverts() public {
        address replacement = factory.createWallet(wallet.payees(), bytes32(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, address(wallet), ETH)
        );
        escrow.recover(address(wallet), replacement, ETH);
    }

    function test_RecoverIsGovernedInTheFundsClass() public {
        address replacement = factory.createWallet(wallet.payees(), bytes32(uint256(1)));
        vm.prank(depositor);
        escrow.depositETH{ value: 1 ether }(address(wallet));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper)
        );
        vm.prank(keeper);
        escrow.recover(address(wallet), replacement, ETH);

        uint64 funds = Roles.FUNDS_SETTER;
        uint32 delay = Roles.FUNDS;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IRevenueEscrow.recover.selector;
        manager.setTargetFunctionRole(address(escrow), selectors, funds);
        manager.grantRole(funds, keeper, delay);
        bytes memory call =
            abi.encodeCall(IRevenueEscrow.recover, (address(wallet), replacement, ETH));
        vm.startPrank(keeper);
        manager.schedule(address(escrow), call, 0);
        vm.warp(block.timestamp + delay - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerNotReady.selector,
                manager.hashOperation(keeper, address(escrow), call)
            )
        );
        manager.execute(address(escrow), call);
        vm.warp(block.timestamp + 1);
        manager.execute(address(escrow), call);
        vm.stopPrank();
        assertEq(escrow.owed(replacement, ETH), 1 ether);
    }

    function test_RecoverIsNonPayable() public {
        (bool ok,) = address(escrow).call{ value: 1 }(
            abi.encodeCall(IRevenueEscrow.recover, (address(wallet), address(wallet), ETH))
        );
        assertFalse(ok);
    }

    /// Regression: MONEY-4, CALLS-1 (docs/security/internal-review-2026-10.md)
    /// @dev The escrow declares itself (ERC-165), so the registry and the resolver can refuse it
    ///      as a payout or fee recipient (MONEY-4, CALLS-1).
    function test_SupportsInterface() public view {
        assertTrue(escrow.supportsInterface(type(IRevenueEscrow).interfaceId));
        assertTrue(escrow.supportsInterface(type(IERC165).interfaceId));
        assertFalse(escrow.supportsInterface(0xffffffff));
        assertFalse(escrow.supportsInterface(type(IClaimRouter).interfaceId));
    }

    /// @dev Ported from the review: force-sent ETH (or tokens sent without a deposit) is never
    ///      owed to anyone, so no flush or recovery can reach it.
    function test_ForceSentETHIsNeverOwed() public {
        new ForceSender{ value: 1 ether }(payable(address(escrow)));
        assertEq(address(escrow).balance, 1 ether);
        assertEq(escrow.totalOwed(ETH), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, address(this), ETH)
        );
        escrow.flush(address(this), ETH);
    }
}
