// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { ClaimRouter } from "src/economics/ClaimRouter.sol";
import { ReleaseVerifier } from "src/economics/ReleaseVerifier.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitFactory } from "src/economics/SplitFactory.sol";
import { SplitWallet } from "src/economics/SplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import {
    BlocklistToken,
    FeeOnTransferToken,
    MockArtistResolver,
    RebasingToken,
    ToggleRecipient
} from "../../mocks/EconomicsMocks.sol";
import { PaymentHarness } from "../EconomicsBase.sol";
import { EconomicsHandler } from "./EconomicsHandler.sol";

/// @notice Stateful invariants for split wallets, the release verifier, the revenue escrow,
///         payments and batch claims (ADR 0001 test plan: value conservation and split sums).
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
    ToggleRecipient internal toggle;
    SplitWallet[] internal wallets;
    address[4] internal assets;

    function setUp() public {
        AccessManager manager = new AccessManager(address(this));
        MockArtistResolver resolver = new MockArtistResolver();
        ReleaseVerifier verifier = new ReleaseVerifier();
        SplitFactory factory = new SplitFactory(resolver, verifier);
        escrow = new RevenueEscrow(address(manager), factory);
        router = new ClaimRouter();
        payer = new PaymentHarness(escrow);
        usdc = new BlocklistToken();
        fee = new FeeOnTransferToken();
        fee.setFee(0);
        rebase = new RebasingToken();
        toggle = new ToggleRecipient();
        assets = [ETH, address(usdc), address(fee), address(rebase)];

        uint256[] memory keys = new uint256[](7);
        for (uint256 i; i < keys.length; ++i) {
            keys[i] = 0xA000 + i;
        }
        uint256[] memory artistIds = new uint256[](2);
        artistIds[0] = 7;
        artistIds[1] = 9;
        resolver.set(7, vm.addr(keys[5]));
        resolver.set(9, vm.addr(keys[6]));

        ISplitWallet.Payee[][3] memory configs = [
            _three(_p(vm.addr(keys[0]), 50_000), _p(vm.addr(keys[1]), 30_000), _art(7, 20_000)),
            _three(_p(vm.addr(keys[2]), 33_333), _p(vm.addr(keys[3]), 33_333), _art(9, 33_334)),
            _two(_p(vm.addr(keys[0]), 1), _p(vm.addr(keys[4]), 99_999))
        ];
        // Originals first (salt 0), then equivalent replacements (salt 1) for escrow recovery.
        for (uint256 salt; salt < 2; ++salt) {
            for (uint256 i; i < configs.length; ++i) {
                wallets.push(SplitWallet(payable(factory.createWallet(configs[i], bytes32(salt)))));
            }
        }

        handler = new EconomicsHandler(
            EconomicsHandler.Setup(
                wallets,
                toggle,
                escrow,
                router,
                payer,
                verifier,
                usdc,
                fee,
                rebase,
                resolver,
                keys,
                artistIds
            )
        );
        // The handler exercises governed recovery as the admin (zero delay in this campaign).
        manager.grantRole(manager.ADMIN_ROLE(), address(handler), 0);

        bytes4[] memory selectors = new bytes4[](16);
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
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// @notice Per wallet and asset (rebasing excluded): released + balance == received, and the
    ///         per-payee releases add up to the wallet's total.
    function invariant_WalletConservesValue() public view {
        for (uint256 w; w < wallets.length; ++w) {
            SplitWallet wallet = wallets[w];
            for (uint256 k; k < 4; ++k) {
                address asset = assets[k];
                uint256 sum;
                for (uint256 i; i < wallet.payeeCount(); ++i) {
                    sum += wallet.released(asset, i);
                }
                assertEq(sum, wallet.totalReleased(asset), "per-payee sum");
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
    ///         the entitlement at the recorded receipts.
    function invariant_ReleasedWithinEntitlement() public view {
        for (uint256 w; w < wallets.length; ++w) {
            SplitWallet wallet = wallets[w];
            for (uint256 k; k < 4; ++k) {
                address asset = assets[k];
                uint256 recorded = wallet.recordedObserved(asset);
                for (uint256 i; i < wallet.payeeCount(); ++i) {
                    uint256 released = wallet.released(asset, i);
                    assertEq(released, handler.ghostReleased(address(wallet), asset, i));
                    assertLe(released, Splits.entitlement(recorded, wallet.payee(i).share));
                }
            }
        }
    }

    /// @notice Recipient-side conservation: everything wallets released was measurably received,
    ///         and (outside the rebasing token) payees hold exactly that.
    function invariant_RecipientsReceivedEverythingReleased() public view {
        for (uint256 k; k < 4; ++k) {
            address asset = assets[k];
            uint256 released;
            for (uint256 w; w < wallets.length; ++w) {
                released += wallets[w].totalReleased(asset);
            }
            assertEq(released, handler.paidOut(asset), "released == paid out");
            if (asset == address(rebase)) continue;
            uint256 held;
            for (uint256 i; i < handler.actorCount(); ++i) {
                held += _balance(asset, handler.actors(i));
            }
            assertEq(held, released, "payees hold what was released");
        }
    }

    /// @notice The recorded receipts follow the model's high-water mark exactly, so they never go
    ///         down; outside the rebasing token they never exceed the live receipts either.
    function invariant_ObservedNeverDecreases() public view {
        for (uint256 w; w < wallets.length; ++w) {
            for (uint256 k; k < 4; ++k) {
                address asset = assets[k];
                uint256 recorded = wallets[w].recordedObserved(asset);
                assertEq(recorded, handler.modelHigh(address(wallets[w]), asset));
                if (asset != address(rebase)) {
                    assertLe(recorded, wallets[w].observed(asset));
                }
            }
        }
    }

    /// @notice Unreleasable dust stays below the number of payees.
    function invariant_DustIsBounded() public view {
        for (uint256 w; w < wallets.length; ++w) {
            SplitWallet wallet = wallets[w];
            uint256 n = wallet.payeeCount();
            for (uint256 k; k < 3; ++k) {
                address asset = assets[k];
                uint256 due;
                for (uint256 i; i < n; ++i) {
                    due += wallet.releasable(asset, i);
                }
                assertLe(_balance(asset, address(wallet)) - due, n - 1, "dust bound");
            }
        }
    }

    /// @notice The escrow holds at least what it owes, and every credit matches the model.
    function invariant_EscrowIsSolventAndMatchesTheModel() public view {
        for (uint256 k; k < 3; ++k) {
            address asset = assets[k];
            uint256 sum = escrow.owed(address(toggle), asset);
            assertEq(sum, handler.ghostOwed(address(toggle), asset));
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
        for (uint256 k; k < 4; ++k) {
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
        for (uint256 i; i < 1500; ++i) {
            uint256 r = uint256(keccak256(abi.encode(i)));
            uint256 action = r % 15;
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
            } else {
                handler.toggleOpen();
            }
        }
        bytes32[14] memory paths = [
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
            bytes32("recover.ok")
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
