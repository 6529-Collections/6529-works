// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitFactory } from "src/economics/SplitFactory.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    BlocklistToken,
    MockArtistResolver,
    ToggleRecipient
} from "../../mocks/EconomicsMocks.sol";
import { PaymentHarness } from "../EconomicsBase.sol";
import { EconomicsHandler } from "./EconomicsHandler.sol";

/// @notice Stateful invariants for split wallets, the revenue escrow, payments and batch claims
///         (ADR 0001 test plan: value conservation and split sums). Runs and depth come from
///         `foundry.toml` (256 x 128, `fail_on_revert`).
contract EconomicsInvariantTest is Test {
    address internal constant ETH = address(0);

    EconomicsHandler internal handler;
    RevenueEscrow internal escrow;
    ClaimRouter internal router;
    PaymentHarness internal payer;
    BlocklistToken internal token;
    ToggleRecipient internal toggle;
    SplitWallet[] internal wallets;

    function setUp() public {
        MockArtistResolver resolver = new MockArtistResolver();
        SplitFactory factory = new SplitFactory(resolver);
        escrow = new RevenueEscrow();
        router = new ClaimRouter();
        payer = new PaymentHarness(escrow);
        token = new BlocklistToken();
        toggle = new ToggleRecipient();

        uint256[] memory keys = new uint256[](7);
        for (uint256 i; i < keys.length; ++i) {
            keys[i] = 0xA000 + i;
        }
        address a = vm.addr(keys[0]);
        address b = vm.addr(keys[1]);
        address c = vm.addr(keys[2]);
        address d = vm.addr(keys[3]);
        address e = vm.addr(keys[4]);
        uint256[] memory artistIds = new uint256[](2);
        artistIds[0] = 7;
        artistIds[1] = 9;
        resolver.set(7, vm.addr(keys[5]));
        resolver.set(9, vm.addr(keys[6]));

        wallets.push(_create(factory, _p(a, 50_000), _p(b, 30_000), _art(7, 20_000)));
        wallets.push(_create(factory, _p(c, 33_333), _p(d, 33_333), _art(9, 33_334)));
        wallets.push(_create2(factory, _p(a, 1), _p(e, 99_999)));

        handler = new EconomicsHandler(
            wallets, toggle, escrow, router, payer, token, resolver, keys, artistIds
        );

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = EconomicsHandler.payETH.selector;
        selectors[1] = EconomicsHandler.payToken.selector;
        selectors[2] = EconomicsHandler.receiveDirect.selector;
        selectors[3] = EconomicsHandler.flush.selector;
        selectors[4] = EconomicsHandler.release.selector;
        selectors[5] = EconomicsHandler.releaseTo.selector;
        selectors[6] = EconomicsHandler.releaseSigned.selector;
        selectors[7] = EconomicsHandler.claimBatch.selector;
        selectors[8] = EconomicsHandler.setArtistPayout.selector;
        selectors[9] = EconomicsHandler.toggleBlocked.selector;
        selectors[10] = EconomicsHandler.toggleOpen.selector;
        selectors[11] = EconomicsHandler.revokeNonce.selector;
        selectors[12] = EconomicsHandler.release.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// @notice Per wallet and asset: released + balance == everything received, and the
    ///         per-payee releases add up to the wallet's total.
    function invariant_WalletConservesValue() public view {
        for (uint256 w; w < wallets.length; ++w) {
            SplitWallet wallet = wallets[w];
            for (uint256 k; k < 2; ++k) {
                address asset = k == 0 ? ETH : address(token);
                uint256 sum;
                for (uint256 i; i < wallet.payeeCount(); ++i) {
                    sum += wallet.released(asset, i);
                }
                assertEq(sum, wallet.totalReleased(asset), "per-payee sum");
                assertEq(
                    sum + _balance(asset, address(wallet)),
                    handler.received(address(wallet), asset),
                    "released + balance == received"
                );
            }
        }
    }

    /// @notice Per payee: released never exceeds the cumulative entitlement, and matches what
    ///         the handler saw leave.
    function invariant_ReleasedWithinEntitlement() public view {
        for (uint256 w; w < wallets.length; ++w) {
            SplitWallet wallet = wallets[w];
            for (uint256 k; k < 2; ++k) {
                address asset = k == 0 ? ETH : address(token);
                uint256 observed = wallet.observed(asset);
                for (uint256 i; i < wallet.payeeCount(); ++i) {
                    uint256 released = wallet.released(asset, i);
                    assertLe(released, Splits.entitlement(observed, wallet.payee(i).share));
                    assertEq(released, handler.ghostReleased(address(wallet), asset, i));
                }
            }
        }
    }

    /// @notice The recorded receipts never go down and never exceed the live receipts.
    function invariant_ObservedNeverDecreases() public view {
        assertFalse(handler.observedDecreased(), "recorded receipts decreased");
        for (uint256 w; w < wallets.length; ++w) {
            assertLe(wallets[w].recordedObserved(ETH), wallets[w].observed(ETH));
            assertLe(
                wallets[w].recordedObserved(address(token)), wallets[w].observed(address(token))
            );
        }
    }

    /// @notice Unreleasable dust stays below the number of payees.
    function invariant_DustIsBounded() public view {
        for (uint256 w; w < wallets.length; ++w) {
            SplitWallet wallet = wallets[w];
            uint256 n = wallet.payeeCount();
            for (uint256 k; k < 2; ++k) {
                address asset = k == 0 ? ETH : address(token);
                uint256 due;
                for (uint256 i; i < n; ++i) {
                    due += wallet.releasable(asset, i);
                }
                assertLe(_balance(asset, address(wallet)) - due, n - 1, "dust bound");
            }
        }
    }

    /// @notice The escrow holds at least what it owes; with no passive inflows here, exactly.
    function invariant_EscrowIsSolvent() public view {
        assertGe(address(escrow).balance, escrow.totalOwed(ETH));
        assertGe(token.balanceOf(address(escrow)), escrow.totalOwed(address(token)));
        assertEq(address(escrow).balance, escrow.totalOwed(ETH));
        assertEq(token.balanceOf(address(escrow)), escrow.totalOwed(address(token)));
    }

    /// @notice The credits per (wallet, asset) key add up to the total owed per asset.
    function invariant_EscrowCreditsSumToTotal() public view {
        for (uint256 k; k < 2; ++k) {
            address asset = k == 0 ? ETH : address(token);
            uint256 sum = escrow.owed(address(toggle), asset);
            for (uint256 w; w < wallets.length; ++w) {
                sum += escrow.owed(address(wallets[w]), asset);
            }
            assertEq(sum, escrow.totalOwed(asset));
        }
    }

    /// @notice The router and the payer never keep funds or approvals.
    function invariant_IntermediariesHoldNothing() public view {
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(address(payer).balance, 0);
        assertEq(token.balanceOf(address(payer)), 0);
        assertEq(token.allowance(address(payer), address(escrow)), 0);
    }

    /// @notice Drives the handler with pseudo-random inputs and checks that every value path the
    ///         invariants rely on is actually reached, so the campaign is not vacuous.
    function test_HandlerReachesEveryPath() public {
        for (uint256 i; i < 600; ++i) {
            uint256 r = uint256(keccak256(abi.encode(i)));
            uint256 action = r % 12;
            if (action == 0) {
                handler.payETH(r >> 8, r >> 16);
            } else if (action == 1) {
                handler.payToken(r >> 8, r >> 16);
            } else if (action == 2) {
                handler.receiveDirect(r >> 8, r >> 16, (r >> 24) % 2 == 0);
            } else if (action == 3) {
                handler.flush(r >> 8, (r >> 16) % 2 == 0);
            } else if (action == 4) {
                handler.release(r >> 8, r >> 16, (r >> 24) % 2 == 0);
            } else if (action == 5) {
                handler.releaseTo(r >> 8, r >> 16, (r >> 24) % 2 == 0, r >> 32);
            } else if (action == 6) {
                handler.releaseSigned(r >> 8, r >> 16, (r >> 24) % 2 == 0, r >> 32, r >> 40);
            } else if (action == 7) {
                handler.claimBatch(r >> 8, uint8(r >> 16));
            } else if (action == 8) {
                handler.setArtistPayout(r >> 8, r >> 16);
            } else if (action == 9) {
                handler.toggleBlocked(r >> 8);
            } else if (action == 10) {
                handler.toggleOpen();
            } else {
                handler.revokeNonce(r >> 8);
            }
        }
        bytes32[10] memory paths = [
            bytes32("payETH.direct"),
            "payETH.escrow",
            "payToken.direct",
            "payToken.escrow",
            "flush",
            "release",
            "releaseTo",
            "releaseSigned",
            "claim.paid",
            "claim.failed"
        ];
        for (uint256 i; i < paths.length; ++i) {
            assertGt(handler.effective(paths[i]), 0, string(abi.encodePacked(paths[i])));
        }
        invariant_WalletConservesValue();
        invariant_ReleasedWithinEntitlement();
        invariant_ObservedNeverDecreases();
        invariant_DustIsBounded();
        invariant_EscrowIsSolvent();
        invariant_EscrowCreditsSumToTotal();
        invariant_IntermediariesHoldNothing();
    }

    function _balance(address asset, address account) internal view returns (uint256) {
        return asset == ETH ? account.balance : token.balanceOf(account);
    }

    function _p(address account, uint32 share) internal pure returns (ISplitWallet.Payee memory) {
        return ISplitWallet.Payee(0, account, share);
    }

    function _art(uint256 artistId, uint32 share)
        internal
        pure
        returns (ISplitWallet.Payee memory)
    {
        return ISplitWallet.Payee(artistId, address(0), share);
    }

    function _create(
        SplitFactory factory,
        ISplitWallet.Payee memory x,
        ISplitWallet.Payee memory y,
        ISplitWallet.Payee memory artist
    ) internal returns (SplitWallet) {
        ISplitWallet.Payee[] memory list = new ISplitWallet.Payee[](3);
        (list[0], list[1]) = x.account < y.account ? (x, y) : (y, x);
        list[2] = artist;
        return SplitWallet(payable(factory.createWallet(list)));
    }

    function _create2(
        SplitFactory factory,
        ISplitWallet.Payee memory x,
        ISplitWallet.Payee memory y
    ) internal returns (SplitWallet) {
        ISplitWallet.Payee[] memory list = new ISplitWallet.Payee[](2);
        (list[0], list[1]) = x.account < y.account ? (x, y) : (y, x);
        return SplitWallet(payable(factory.createWallet(list)));
    }
}
