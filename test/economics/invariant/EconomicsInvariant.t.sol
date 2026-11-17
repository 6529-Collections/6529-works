// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { GovernedVault } from "src/economics/GovernedVault.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { Splits } from "src/economics/Splits.sol";
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    BlocklistToken,
    FeeOnTransferToken,
    MockArtistResolver,
    NoReturnToken,
    RebasingToken,
    ToggleRecipient
} from "../../mocks/economics/EconomicsMocks.sol";
import { PaymentHarness } from "../EconomicsBase.sol";
import { EconomicsHandler } from "./EconomicsHandler.sol";

/// @notice Stateful invariants for the split ledger and its wallets (releases, signed releases),
///         the revenue escrow (credits, recovery, the governed sweep of unowed funds), payments
///         and batch claims (ADR 0001 test plan: value conservation and split sums), the
///         network's share pushed on every release from a wallet that names it (R11), marked
///         shares forfeited to the network after 180 days and escrow credits expiring to it
///         (R12), and the network's recovery of its own credits (C19).
///         Runs and depth come from `foundry.toml` (256 x 128, `fail_on_revert`).
contract EconomicsInvariantTest is Test {
    address internal constant ETH = address(0);

    EconomicsHandler internal handler;
    RevenueEscrow internal escrow;
    ClaimRouter internal router;
    PaymentHarness internal payer;
    BlocklistToken internal usdc;
    FeeOnTransferToken internal fee;
    RebasingToken internal rebase;
    NoReturnToken internal silent;
    ToggleRecipient internal toggle;
    SplitLedger internal ledger;
    address internal network;
    address[] internal wallets;
    address[5] internal assets;

    function setUp() public {
        AccessManager manager = new AccessManager(address(this));
        MockArtistResolver resolver = new MockArtistResolver();
        network = address(new GovernedVault(address(manager), makeAddr("feeSafe")));
        ledger = new SplitLedger(resolver, network);
        escrow = new RevenueEscrow(address(manager), ledger);
        router = new ClaimRouter(ledger);
        payer = new PaymentHarness(escrow);
        usdc = new BlocklistToken();
        fee = new FeeOnTransferToken();
        fee.setFee(0);
        rebase = new RebasingToken();
        silent = new NoReturnToken();
        toggle = new ToggleRecipient();
        assets = [ETH, address(usdc), address(fee), address(rebase), address(silent)];

        uint256[] memory keys = new uint256[](7);
        for (uint256 i; i < keys.length; ++i) {
            keys[i] = 0xA000 + i;
        }
        uint256[] memory artistIds = new uint256[](2);
        artistIds[0] = 7;
        artistIds[1] = 9;
        resolver.set(7, vm.addr(keys[5]));
        resolver.set(9, vm.addr(keys[6]));

        // The last two name the network: a royalty wallet (the seller's wallet and the network)
        // and a split where the network sits beside an artist and a fixed payee.
        ISplitWallet.Payee[][5] memory configs = [
            _three(_p(vm.addr(keys[0]), 50_000), _p(vm.addr(keys[1]), 30_000), _art(7, 20_000)),
            _three(_p(vm.addr(keys[2]), 33_333), _p(vm.addr(keys[3]), 33_333), _art(9, 33_334)),
            _two(_p(vm.addr(keys[0]), 1), _p(vm.addr(keys[4]), 99_999)),
            _two(_p(vm.addr(keys[1]), 75_000), _p(network, 25_000)),
            _three(_p(vm.addr(keys[3]), 40_000), _p(network, 10_000), _art(7, 50_000))
        ];
        // Originals first (salt 0), then equivalent replacements (salt 1) for escrow recovery.
        ISplitWallet.Payee[][] memory lists = new ISplitWallet.Payee[][](2 * configs.length);
        bytes32[] memory salts = new bytes32[](2 * configs.length);
        for (uint256 salt; salt < 2; ++salt) {
            for (uint256 i; i < configs.length; ++i) {
                wallets.push(ledger.createWallet(configs[i], bytes32(salt)));
                lists[wallets.length - 1] = configs[i];
                salts[wallets.length - 1] = bytes32(salt);
            }
        }

        handler = new EconomicsHandler(
            EconomicsHandler.Setup(
                wallets,
                lists,
                salts,
                toggle,
                escrow,
                router,
                payer,
                ledger,
                usdc,
                fee,
                rebase,
                silent,
                resolver,
                keys,
                artistIds
            )
        );
        // The handler exercises governed recovery and sweeps as the admin (zero delay here).
        manager.grantRole(manager.ADMIN_ROLE(), address(handler), 0);

        bytes4[] memory selectors = new bytes4[](24);
        selectors[0] = EconomicsHandler.release.selector;
        selectors[1] = EconomicsHandler.releaseTo.selector;
        selectors[2] = EconomicsHandler.releaseSigned.selector;
        selectors[3] = EconomicsHandler.replaySigned.selector;
        selectors[4] = EconomicsHandler.claimBatch.selector;
        selectors[5] = EconomicsHandler.pay.selector;
        selectors[6] = EconomicsHandler.receiveDirect.selector;
        selectors[7] = EconomicsHandler.deposit.selector;
        selectors[8] = EconomicsHandler.flush.selector;
        selectors[9] = EconomicsHandler.recover.selector;
        selectors[10] = EconomicsHandler.setArtistPayout.selector;
        selectors[11] = EconomicsHandler.toggleBlocked.selector;
        selectors[12] = EconomicsHandler.toggleFee.selector;
        selectors[13] = EconomicsHandler.rebaseTo.selector;
        selectors[14] = EconomicsHandler.toggleOpen.selector;
        selectors[15] = EconomicsHandler.revokeNonce.selector;
        selectors[16] = EconomicsHandler.consentToggle.selector;
        selectors[17] = EconomicsHandler.strayToken.selector;
        selectors[18] = EconomicsHandler.forceETH.selector;
        selectors[19] = EconomicsHandler.sweep.selector;
        selectors[20] = EconomicsHandler.mark.selector;
        selectors[21] = EconomicsHandler.forfeit.selector;
        selectors[22] = EconomicsHandler.expire.selector;
        selectors[23] = EconomicsHandler.warp.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// @notice Per wallet and asset (rebasing excluded): released + balance == received, and the
    ///         per-payee releases add up to the wallet's total.
    function invariant_WalletConservesValue() public view {
        for (uint256 w; w < wallets.length; ++w) {
            address wallet = wallets[w];
            for (uint256 k; k < assets.length; ++k) {
                address asset = assets[k];
                uint256 sum;
                for (uint256 i; i < handler.payeesOf(wallet).length; ++i) {
                    sum += ledger.released(wallet, asset, i);
                }
                assertEq(sum, ledger.totalReleased(wallet, asset), "per-payee sum");
                if (asset == address(rebase)) continue;
                assertEq(
                    sum + _balance(asset, address(wallet)),
                    handler.received(address(wallet), asset),
                    "released + balance == received"
                );
            }
        }
    }

    /// @notice Per payee: released equals what recipients measurably received, and never exceeds
    ///         the entitlement at the receipts the last release saw: the wallet's recorded mark
    ///         for an ERC-20, the model's for ETH (which keeps no mark on-chain).
    function invariant_ReleasedWithinEntitlement() public view {
        for (uint256 w; w < wallets.length; ++w) {
            address wallet = wallets[w];
            for (uint256 k; k < assets.length; ++k) {
                address asset = assets[k];
                uint256 recorded = asset == ETH
                    ? handler.modelHigh(address(wallet), ETH)
                    : ledger.recordedObserved(wallet, asset);
                for (uint256 i; i < handler.payeesOf(wallet).length; ++i) {
                    uint256 released = ledger.released(wallet, asset, i);
                    assertEq(released, handler.ghostReleased(address(wallet), asset, i));
                    assertLe(
                        released, Splits.entitlement(recorded, handler.payeesOf(wallet)[i].share)
                    );
                }
            }
        }
    }

    /// @notice Recipient-side conservation: everything wallets released was measurably received,
    ///         and (outside the rebasing token) payees hold exactly that.
    function invariant_RecipientsReceivedEverythingReleased() public view {
        for (uint256 k; k < assets.length; ++k) {
            address asset = assets[k];
            uint256 released;
            for (uint256 w; w < wallets.length; ++w) {
                released += ledger.totalReleased(wallets[w], asset);
            }
            assertEq(released, handler.paidOut(asset), "released == paid out");
            if (asset == address(rebase)) continue;
            // The network vault holds its pushes, forfeits and releases, plus what it got
            // otherwise (payments and flushes).
            uint256 held = _balance(asset, network) - handler.networkOther(asset);
            for (uint256 i; i < handler.actorCount(); ++i) {
                held += _balance(asset, handler.actors(i));
            }
            assertEq(held, released, "payees hold what was released");
        }
    }

    /// @notice R11 and R12: in a wallet that names the network, the network's released total is
    ///         its own releases, the pushes and the forfeits, and never exceeds its entitlement;
    ///         a running mark never asks for more than the payee's entitlement at the receipts
    ///         seen so far, so a forfeit can never take money that arrived after the mark.
    function invariant_MarksWithinEntitlement() public view {
        for (uint256 w; w < wallets.length; ++w) {
            address wallet = wallets[w];
            ISplitWallet.Payee[] memory payees = handler.payeesOf(wallet);
            for (uint256 k; k < assets.length; ++k) {
                address asset = assets[k];
                uint256 seen = asset == ETH
                    ? handler.modelHigh(wallet, ETH)
                    : ledger.recordedObserved(wallet, asset);
                for (uint256 i; i < payees.length; ++i) {
                    (uint256 target, uint256 at) = ledger.markOf(wallet, asset, i);
                    assertEq(target, handler.markTarget(wallet, asset, i), "mark target model");
                    assertEq(at, handler.markAt(wallet, asset, i), "mark time model");
                    if (at == 0 || asset == address(rebase)) continue;
                    assertLe(
                        target,
                        Splits.entitlement(
                            seen > ledger.observed(wallet, asset)
                                ? seen
                                : ledger.observed(wallet, asset),
                            payees[i].share
                        ),
                        "mark within entitlement"
                    );
                }
            }
        }
    }

    /// @notice The recorded receipts follow the model's high-water mark exactly, so they never go
    ///         down; outside the rebasing token they never exceed the live receipts either. ETH
    ///         records no mark, and its live receipts never fall below the model's mark.
    function invariant_ObservedNeverDecreases() public view {
        for (uint256 w; w < wallets.length; ++w) {
            assertEq(ledger.recordedObserved(wallets[w], ETH), 0, "no ETH mark");
            assertLe(handler.modelHigh(address(wallets[w]), ETH), ledger.observed(wallets[w], ETH));
            for (uint256 k = 1; k < assets.length; ++k) {
                address asset = assets[k];
                uint256 recorded = ledger.recordedObserved(wallets[w], asset);
                assertEq(recorded, handler.modelHigh(address(wallets[w]), asset));
                if (asset != address(rebase)) {
                    assertLe(recorded, ledger.observed(wallets[w], asset));
                }
            }
        }
    }

    /// @notice Unreleasable dust stays below the number of payees.
    function invariant_DustIsBounded() public view {
        for (uint256 w; w < wallets.length; ++w) {
            address wallet = wallets[w];
            uint256 n = handler.payeesOf(wallet).length;
            for (uint256 k; k < assets.length; ++k) {
                address asset = assets[k];
                if (asset == address(rebase)) continue;
                uint256 due;
                for (uint256 i; i < n; ++i) {
                    due += _releasable(wallet, asset, i);
                }
                assertLe(_balance(asset, address(wallet)) - due, n - 1, "dust bound");
            }
        }
    }

    /// @notice Per wallet and asset (rebasing excluded): everything received is released or
    ///         releasable, up to rounding dust below the payee count. So no payee can take more
    ///         than its share (which `invariant_ReleasedWithinEntitlement` checks payee by payee)
    ///         and no unit of revenue is left without an owner beyond that dust.
    function invariant_ReleasedPlusReleasableMatchesReceived() public view {
        for (uint256 w; w < wallets.length; ++w) {
            address wallet = wallets[w];
            uint256 n = handler.payeesOf(wallet).length;
            for (uint256 k; k < assets.length; ++k) {
                address asset = assets[k];
                if (asset == address(rebase)) continue;
                uint256 accounted = ledger.totalReleased(wallet, asset);
                for (uint256 i; i < n; ++i) {
                    accounted += _releasable(wallet, asset, i);
                }
                uint256 received = handler.received(wallet, asset);
                assertLe(accounted, received, "never more than received");
                assertLe(received - accounted, n - 1, "released + releasable == received");
            }
        }
    }

    /// @notice The escrow's excess over what it owes is exactly what reached it without a
    ///         deposit and was not swept: a sweep never takes owed funds.
    function invariant_EscrowExcessIsExactlyTheUnowed() public view {
        for (uint256 k; k < 3; ++k) {
            address asset = assets[k];
            assertEq(
                _balance(asset, address(escrow)) - escrow.totalOwed(asset),
                handler.ghostExcess(asset),
                "excess == unowed arrivals - sweeps"
            );
        }
    }

    /// @notice The escrow holds at least what it owes, and every credit matches the model.
    function invariant_EscrowIsSolventAndMatchesTheModel() public view {
        for (uint256 k; k < 3; ++k) {
            address asset = assets[k];
            uint256 sum = escrow.owed(address(toggle), asset) + escrow.owed(network, asset);
            assertEq(escrow.owed(address(toggle), asset), handler.ghostOwed(address(toggle), asset));
            assertEq(escrow.owed(network, asset), handler.ghostOwed(network, asset));
            assertEq(
                escrow.creditedAt(network, asset), handler.ghostCreditedAt(network, asset), "clock"
            );
            for (uint256 w; w < wallets.length; ++w) {
                uint256 owed = escrow.owed(address(wallets[w]), asset);
                assertEq(owed, handler.ghostOwed(address(wallets[w]), asset));
                sum += owed;
            }
            assertEq(sum, escrow.totalOwed(asset), "credits sum to total owed");
            assertGe(_balance(asset, address(escrow)), escrow.totalOwed(asset), "escrow solvent");
        }
    }

    /// @notice The router and the payer never keep funds or approvals (beyond the residue of
    ///         payments the model expected to revert).
    function invariant_IntermediariesHoldNothing() public view {
        for (uint256 k; k < assets.length; ++k) {
            assertEq(_balance(assets[k], address(router)), 0);
        }
        assertEq(address(payer).balance, 0);
        assertEq(usdc.balanceOf(address(payer)), handler.payerResidue(address(usdc)));
        assertEq(fee.balanceOf(address(payer)), handler.payerResidue(address(fee)));
        assertEq(usdc.allowance(address(payer), address(escrow)), 0);
        assertEq(fee.allowance(address(payer), address(escrow)), 0);
    }

    /// @notice Drives the handler with pseudo-random inputs and checks that the value paths and
    ///         the predicted failures the invariants rely on are actually reached.
    function test_HandlerReachesEveryPath() public {
        for (uint256 i; i < 3000; ++i) {
            uint256 r = uint256(keccak256(abi.encode(i)));
            uint256 action = r % 23;
            if (action == 0) {
                handler.release(r >> 8, r >> 16, r >> 24, r >> 32);
            } else if (action == 1) {
                handler.releaseTo(r >> 8, r >> 16, r >> 24, r >> 32, r >> 40);
            } else if (action == 2) {
                handler.releaseSigned(r >> 8, r >> 16, r >> 24, r >> 32, r >> 40, r >> 48);
            } else if (action == 3) {
                handler.replaySigned();
            } else if (action == 4) {
                handler.claimBatch(r >> 8, uint8(r >> 16), (r >> 24) % 2 == 0);
            } else if (action == 5) {
                handler.pay(r >> 8, r >> 16, r >> 24);
            } else if (action == 6) {
                handler.receiveDirect(r >> 8, r >> 16, r >> 24);
            } else if (action == 7) {
                handler.deposit(r >> 8, r >> 16, r >> 24);
            } else if (action == 8) {
                handler.flush(r >> 8, r >> 16);
            } else if (action == 9) {
                handler.recover(r >> 8, r >> 16, r >> 24);
            } else if (action == 10) {
                handler.setArtistPayout(r >> 8, r >> 16);
            } else if (action == 11) {
                handler.toggleBlocked(r >> 8);
            } else if (action == 12) {
                handler.toggleFee();
            } else if (action == 13) {
                handler.rebaseTo(r >> 8);
            } else if (action == 14) {
                handler.consentToggle(r >> 8);
            } else if (action == 15) {
                handler.strayToken(r >> 8, r >> 16);
            } else if (action == 16) {
                handler.forceETH(r >> 8);
            } else if (action == 17) {
                handler.sweep(r >> 8);
            } else if (action == 18) {
                handler.mark(r >> 8, r >> 16, r >> 24);
            } else if (action == 19) {
                handler.forfeit(r >> 8, r >> 16, r >> 24);
            } else if (action == 20) {
                handler.expire(r >> 8, r >> 16);
            } else if (action == 21) {
                handler.warp(r >> 8);
            } else {
                handler.toggleOpen();
            }
        }
        bytes32[28] memory paths = [
            keccak256(abi.encode(bytes32("release"), "ok")),
            keccak256(abi.encode(bytes32("releaseTo"), "ok")),
            keccak256(abi.encode(bytes32("signed"), "ok")),
            keccak256(abi.encode(bytes32("release"), ISplitWallet.NotPayoutAddress.selector)),
            keccak256(abi.encode(bytes32("release"), ISplitWallet.NothingToRelease.selector)),
            keccak256(abi.encode(bytes32("release"), ISplitWallet.ObservedDecreased.selector)),
            bytes32("signed.replay"),
            bytes32("batch.paid"),
            bytes32("batch.signedPaid"),
            bytes32("batch.failed"),
            bytes32("pay.escrow"),
            bytes32("pay.reverted"),
            bytes32("flush.ok"),
            bytes32("recover.ok"),
            bytes32("consent.set"),
            bytes32("recover.consented"),
            // A no-return token released from a wallet (regression RFX-ECO-1).
            bytes32("release.noReturn"),
            bytes32("excess.token"),
            bytes32("excess.eth"),
            bytes32("sweep.ok"),
            bytes32("sweep.reverted"),
            bytes32("push.ok"),
            bytes32("mark.ok"),
            keccak256(abi.encode(bytes32("mark"), ISplitLedger.MarkPending.selector)),
            bytes32("forfeit.ok"),
            keccak256(abi.encode(bytes32("forfeit"), ISplitLedger.MarkNotDue.selector)),
            bytes32("expire.ok"),
            bytes32("recover.network")
        ];
        for (uint256 i; i < paths.length; ++i) {
            assertGt(handler.outcomes(paths[i]), 0, vm.toString(i));
        }
        invariant_WalletConservesValue();
        invariant_ReleasedWithinEntitlement();
        invariant_RecipientsReceivedEverythingReleased();
        invariant_ObservedNeverDecreases();
        invariant_DustIsBounded();
        invariant_EscrowIsSolventAndMatchesTheModel();
        invariant_IntermediariesHoldNothing();
        invariant_ReleasedPlusReleasableMatchesReceived();
        invariant_EscrowExcessIsExactlyTheUnowed();
        invariant_MarksWithinEntitlement();
    }

    function _releasable(address wallet, address asset, uint256 index)
        internal
        view
        returns (uint256)
    {
        return ledger.releasable(handler.payeesOf(wallet), handler.saltOf(wallet), asset, index);
    }

    function _balance(address asset, address account) internal view returns (uint256) {
        return asset == ETH ? account.balance : BlocklistToken(asset).balanceOf(account);
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

    function _three(
        ISplitWallet.Payee memory x,
        ISplitWallet.Payee memory y,
        ISplitWallet.Payee memory artist
    ) internal pure returns (ISplitWallet.Payee[] memory list) {
        list = new ISplitWallet.Payee[](3);
        (list[0], list[1]) = x.account < y.account ? (x, y) : (y, x);
        list[2] = artist;
    }

    function _two(ISplitWallet.Payee memory x, ISplitWallet.Payee memory y)
        internal
        pure
        returns (ISplitWallet.Payee[] memory list)
    {
        list = new ISplitWallet.Payee[](2);
        (list[0], list[1]) = x.account < y.account ? (x, y) : (y, x);
    }
}
