// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { GovernedVault } from "src/economics/GovernedVault.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { IGovernedVault } from "src/economics/interfaces/IGovernedVault.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { SymHelpers, SymResolver } from "./LedgerSymbolic.t.sol";

/// @notice Halmos proofs of the escrow's and the governed vault's rules on the real
///         `RevenueEscrow`, `GovernedVault` and `SplitLedger` behind a real OpenZeppelin
///         `AccessManager` (docs/testing/README.md, "Symbolic"). ETH only: the ERC-20 paths
///         differ in the balance reads, which the unit and invariant suites cover.
/// @dev Credits go to fixed EOA-like wallets; amounts are 64-bit.
contract EscrowSymbolicTest is SymHelpers {
    uint64 internal constant FUNDS_ROLE = 3;
    uint32 internal constant FUNDS_DELAY = 3 days;
    address internal constant ETH = address(0);
    address internal constant PAYER = address(0xBA7E);
    address internal constant W1 = address(0xA001);
    address internal constant W2 = address(0xA002);
    address internal constant GOV = address(0x6060);
    address internal constant SLOW = address(0x5101);
    address internal constant FEE_SAFE = address(0xFEE5);
    address internal constant MUSEUM_SAFE = address(0x3A5E);

    AccessManager internal manager;
    SplitLedger internal ledger;
    RevenueEscrow internal escrow;
    GovernedVault internal feeVault;
    GovernedVault internal museum;

    function setUp() public {
        manager = new AccessManager(address(this));
        feeVault = new GovernedVault(address(manager), FEE_SAFE);
        museum = new GovernedVault(address(manager), MUSEUM_SAFE);
        ledger = new SplitLedger(new SymResolver(), address(feeVault));
        escrow = new RevenueEscrow(address(manager), ledger);
        _map(address(escrow), escrow.recover.selector);
        _map(address(escrow), escrow.sweepExcess.selector);
        _map(address(feeVault), feeVault.setDestination.selector);
        _map(address(museum), museum.setDestination.selector);
        manager.grantRole(FUNDS_ROLE, GOV, 0);
        // A holder with the class delay must schedule; it cannot call at once.
        manager.grantRole(FUNDS_ROLE, SLOW, FUNDS_DELAY);
    }

    // ---------------------------------------------------------------------------------------
    // Credits: ECO-27, ECO-45
    // ---------------------------------------------------------------------------------------

    /// @notice ECO-27: a flush, by anyone, pays the credited wallet exactly its credit and
    ///         nothing to the caller or another wallet; credits are isolated per wallet; the
    ///         escrow stays solvent.
    /// @dev Bounds: any caller (not the escrow or a wallet), any two 64-bit credits, either
    ///      wallet flushed, once or twice.
    function check_flush_paysOnlyTheCreditedWallet(
        address caller,
        uint64 c1,
        uint64 c2,
        bool second,
        bool twice
    ) public {
        vm.assume(caller != address(escrow) && caller != W1 && caller != W2);
        _deposit(W1, c1);
        _deposit(W2, c2);
        // W1 and W2 start empty, so their balances afterwards are what they were paid.
        (address target, uint256 credit, address other, uint256 otherCredit) =
            second ? (W2, uint256(c2), W1, uint256(c1)) : (W1, uint256(c1), W2, uint256(c2));
        uint256 callerBefore = caller.balance;

        (bool ok, bytes4 err) =
            _call(caller, address(escrow), abi.encodeCall(escrow.flush, (target, ETH)));
        assert(ok == (credit != 0));
        if (!ok) assert(err == IRevenueEscrow.NothingOwed.selector);
        assert(target.balance == _pick(ok, credit, 0) && other.balance == 0);
        assert(caller.balance == callerBefore);
        assert(escrow.owed(target, ETH) == 0 && escrow.owed(other, ETH) == otherCredit);
        assert(escrow.totalOwed(ETH) == otherCredit);
        assert(address(escrow).balance == otherCredit);
        if (twice) {
            (bool again, bytes4 err2) =
                _call(caller, address(escrow), abi.encodeCall(escrow.flush, (target, ETH)));
            assert(!again && err2 == IRevenueEscrow.NothingOwed.selector);
        }
    }

    /// @notice ECO-45: an expiry moves only money credited 180 days or more before it, always
    ///         every unit credited 360 days or more before it, keeps the rest, makes the moved
    ///         amount the vault's credit, and never touches the network's own credit. The
    ///         credits come from any payer, so this holds whoever deposits.
    /// @dev Bounds: three 64-bit credits (zero skips one) at nondecreasing times spaced by any
    ///      delays below 2**32 seconds, then an expiry by any caller after any such delay.
    function check_expiry_movesOnlyMoney180DaysOld(
        address caller,
        uint64 c1,
        uint64 c2,
        uint64 c3,
        uint32 d2,
        uint32 d3,
        uint32 de,
        bool networkCredit
    ) public {
        vm.assume(caller != address(escrow));
        address wallet = networkCredit ? address(feeVault) : W1;
        (uint256 credit, uint256 old, uint256 veryOld) =
            _threeCredits(wallet, [uint256(c1), c2, c3], [uint256(d2), d3, de]);
        (bool ok, bytes4 err) =
            _call(caller, address(escrow), abi.encodeCall(escrow.expire, (wallet, ETH)));
        if (networkCredit) {
            assert(!ok && err == IRevenueEscrow.InvalidWallet.selector);
        } else if (!ok) {
            assert(veryOld == 0);
            assert(
                err
                    == (credit == 0
                            ? IRevenueEscrow.NothingOwed.selector
                            : IRevenueEscrow.CreditNotExpired.selector)
            );
            assert(escrow.owed(wallet, ETH) == credit);
        } else {
            // The vault held no credit before, so its credit is what moved.
            uint256 moved = escrow.owed(address(feeVault), ETH);
            assert(moved != 0 && moved <= old && moved >= veryOld);
            assert(escrow.owed(wallet, ETH) == credit - moved);
            assert(escrow.totalOwed(ETH) == credit);
        }
    }

    /// @dev Credits `wallet` with `amounts` at times spaced by the first two `gaps`, then warps
    ///      by the third; returns the total and the parts credited at least 180 and 360 days
    ///      before the final time.
    function _threeCredits(address wallet, uint256[3] memory amounts, uint256[3] memory gaps)
        internal
        returns (uint256 credit, uint256 old, uint256 veryOld)
    {
        uint256[3] memory times;
        times[0] = block.timestamp;
        times[1] = times[0] + gaps[0];
        times[2] = times[1] + gaps[1];
        for (uint256 i; i < 3; ++i) {
            vm.warp(times[i]);
            _deposit(wallet, amounts[i]);
            credit += amounts[i];
        }
        uint256 te = times[2] + gaps[2];
        vm.warp(te);
        (old, veryOld) = _aged(amounts, times, te);
    }

    /// @dev The credits made at least 180 and at least 360 days before `te`.
    function _aged(uint256[3] memory amounts, uint256[3] memory times, uint256 te)
        internal
        pure
        returns (uint256 old, uint256 veryOld)
    {
        for (uint256 i; i < 3; ++i) {
            old += _pick(times[i] + 180 days <= te, amounts[i], 0);
            veryOld += _pick(times[i] + 360 days <= te, amounts[i], 0);
        }
    }

    /// @notice ECO-45: a deposit by anyone, made when a first credit is already 180 days old,
    ///         never lowers what of that credit may expire at any later time, and changes nothing
    ///         that may expire at the moment it is made. A second credit may be younger (it may
    ///         share a window with the deposit). Two escrows get the same two credits at the same
    ///         times; the first also gets the extra deposit. Fails for a rule whose window stays
    ///         open while credits keep arriving.
    /// @dev Bounds: two 64-bit credits, a 64-bit extra deposit 180 days to 2**32 seconds after
    ///      the first credit, the second credit anywhere between them, and any read time up to
    ///      2**32 seconds after the deposit.
    function check_deposit_neverPostponesMoney180DaysOld(
        uint64 c1,
        uint64 c2,
        uint64 extra,
        uint32 gap,
        uint32 late,
        uint32 read
    ) public {
        vm.assume(extra != 0 && late >= 180 days && gap <= late);
        RevenueEscrow twin = new RevenueEscrow(address(manager), ledger);
        uint256 t1 = block.timestamp;
        _depositBoth(twin, c1);
        vm.warp(t1 + gap);
        _depositBoth(twin, c2);
        uint256 t = t1 + late;
        vm.warp(t);
        uint256 atDeposit = twin.expirableAt(W1, ETH, t);
        vm.deal(PAYER, extra);
        vm.prank(PAYER);
        escrow.depositETH{ value: extra }(W1);
        assert(escrow.expirableAt(W1, ETH, t) == atDeposit);
        uint256 before = twin.expirableAt(W1, ETH, t + read);
        uint256 floor = before < c1 ? before : c1;
        assert(escrow.expirableAt(W1, ETH, t + read) >= floor);
    }

    // ---------------------------------------------------------------------------------------
    // Governed paths: ECO-28, ECO-40, ECO-5
    // ---------------------------------------------------------------------------------------

    /// @notice ECO-40, INV-ECO-13: `sweepExcess` moves exactly the balance above `totalOwed`
    ///         and nothing else: no credit changes, the escrow stays solvent, and it reverts
    ///         when there is no excess.
    /// @dev Bounds: any two 64-bit credits, any 64-bit forced ETH, any recipient but zero and
    ///      the escrow.
    function check_sweepExcess_neverTouchesOwed(
        uint64 c1,
        uint64 c2,
        uint64 forced,
        address recipient
    ) public {
        vm.assume(recipient != address(0) && recipient != address(escrow));
        vm.assume(recipient != W1 && recipient != W2 && recipient != GOV);
        _deposit(W1, c1);
        _deposit(W2, c2);
        vm.deal(address(escrow), address(escrow).balance + forced);
        uint256 total = escrow.totalOwed(ETH);
        uint256 recipientBefore = recipient.balance;

        (bool ok, bytes4 err) =
            _call(GOV, address(escrow), abi.encodeCall(escrow.sweepExcess, (ETH, recipient)));
        if (forced == 0) assert(!ok && err == IRevenueEscrow.NothingToSweep.selector);
        if (ok) {
            assert(recipient.balance == recipientBefore + forced);
            assert(address(escrow).balance == total);
        }
        assert(escrow.totalOwed(ETH) == total && total == uint256(c1) + c2);
        assert(escrow.owed(W1, ETH) == c1 && escrow.owed(W2, ETH) == c2);
    }

    /// @notice ECO-28, INV-ECO-10: `recover` moves a split wallet's credit only to a distinct
    ///         wallet with the same payees, the network's own credit to any account but zero,
    ///         the escrow or itself, and any other account's credit only to the replacement it
    ///         consented to, consuming the consent; the total owed never changes.
    /// @dev Bounds: any replacement address; the three kinds of credited account (a split
    ///      wallet, the museum vault, an EOA that consented to any address or none).
    function check_recover_onlyToTheEquivalentWallet(
        uint8 kind,
        address replacement,
        address consentTo,
        bool consented,
        uint64 credit
    ) public {
        vm.assume(credit != 0);
        _splitWallets();
        address wallet = kind == 0 ? split : kind == 1 ? address(museum) : W1;
        if (consented) {
            vm.assume(consentTo != address(escrow) && consentTo != W1);
            vm.prank(W1);
            escrow.consentToRecovery(consentTo);
        }
        _deposit(wallet, credit);
        uint256 total = escrow.totalOwed(ETH);
        uint256 before = escrow.owed(replacement, ETH);

        (bool ok,) = _call(
            GOV, address(escrow), abi.encodeCall(escrow.recover, (wallet, replacement, ETH))
        );
        if (kind == 0) {
            assert(ok == (replacement == equivalent));
            assert(replacement != different || !ok);
        } else if (kind == 1) {
            bool invalid = _or(
                _or(replacement == address(0), replacement == address(escrow)),
                replacement == wallet
            );
            assert(ok == !invalid);
        } else {
            assert(ok == _and(_and(consented, replacement == consentTo), replacement != address(0)));
            if (ok) assert(escrow.recoveryConsent(W1) == address(0));
        }
        assert(escrow.totalOwed(ETH) == total);
        if (ok) {
            assert(escrow.owed(wallet, ETH) == 0);
            assert(escrow.owed(replacement, ETH) == before + credit);
        } else {
            assert(escrow.owed(wallet, ETH) == credit);
        }
    }

    /// @notice ECO-5: every governed write of the escrow and the vaults reverts for any caller
    ///         without the role (`AccessManagedUnauthorized`) and for a holder whose role carries
    ///         the class delay and did not schedule (`AccessManagerNotScheduled`), and changes
    ///         nothing.
    /// @dev Bounds: any caller but the immediate holder; every restricted selector of
    ///      `RevenueEscrow` and `GovernedVault` (`recover`, `sweepExcess`, `setDestination` on
    ///      both vaults).
    function check_everyGovernedWrite_needsItsRole(address caller, uint8 action, address arg)
        public
    {
        vm.assume(caller != GOV && caller != address(manager));
        _deposit(W1, 1 ether);
        vm.deal(address(escrow), 2 ether);
        address target;
        bytes memory data;
        if (action == 0) {
            (target, data) = (address(escrow), abi.encodeCall(escrow.recover, (W1, arg, ETH)));
        } else if (action == 1) {
            (target, data) = (address(escrow), abi.encodeCall(escrow.sweepExcess, (ETH, arg)));
        } else if (action == 2) {
            (target, data) = (address(feeVault), abi.encodeCall(feeVault.setDestination, (1, arg)));
        } else {
            (target, data) = (address(museum), abi.encodeCall(museum.setDestination, (1, arg)));
        }
        (bool ok, bytes4 err) = _call(caller, target, data);
        // The delayed holder reaches the manager's schedule check, which finds nothing
        // scheduled; everyone else is refused by the target.
        bytes4 expected = caller == SLOW
            ? IAccessManager.AccessManagerNotScheduled.selector
            : IAccessManaged.AccessManagedUnauthorized.selector;
        assert(!ok && err == expected);
        assert(escrow.owed(W1, ETH) == 1 ether && address(escrow).balance == 2 ether);
        assert(feeVault.destination() == FEE_SAFE && museum.destination() == MUSEUM_SAFE);
    }

    /// @notice ECO-41: a governed vault moves ETH only to its destination, whoever calls
    ///         `forward`; the destination changes only by the role holder's compare-and-set on
    ///         the current revision, never to zero or the vault.
    /// @dev Bounds: any caller, any 64-bit holdings and amount, any next destination and
    ///      expected revision.
    function check_governedVault_paysOnlyItsDestination(
        address caller,
        uint64 held,
        uint256 amount,
        address next,
        uint64 expected,
        bool setFirst
    ) public {
        vm.assume(caller != address(feeVault) && caller != FEE_SAFE);
        vm.assume(next != caller && next != FEE_SAFE && uint160(next) > 0xffff);
        vm.deal(address(feeVault), held);
        address dest = FEE_SAFE;
        if (setFirst) {
            uint64 revision = feeVault.destinationRevision();
            (bool set, bytes4 err) = _call(
                GOV, address(feeVault), abi.encodeCall(feeVault.setDestination, (expected, next))
            );
            bool valid = _and(next != address(0), next != address(feeVault));
            assert(set == _and(expected == revision, valid));
            if (!set && expected != revision) {
                assert(err == IGovernedVault.RevisionMismatch.selector);
            }
            if (set) {
                dest = next;
                assert(feeVault.destinationRevision() == revision + 1);
            }
        }
        assert(feeVault.destination() == dest);
        uint256 destBefore = dest.balance;
        uint256 callerBefore = caller.balance;
        (bool ok,) =
            _call(caller, address(feeVault), abi.encodeCall(feeVault.forward, (ETH, amount)));
        uint256 sent = amount == type(uint256).max ? held : amount;
        if (ok) {
            assert(sent != 0 && sent <= held);
            assert(dest.balance == destBefore + sent);
            assert(address(feeVault).balance == held - sent);
        } else {
            assert(address(feeVault).balance == held);
        }
        assert(caller.balance == callerBefore);
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    address internal split;
    address internal equivalent;
    address internal different;

    /// @dev Deploys a split wallet, one with the same payees under another salt, and one with
    ///      other shares.
    function _splitWallets() internal {
        ISplitWallet.Payee[] memory p = new ISplitWallet.Payee[](2);
        p[0] = ISplitWallet.Payee(0, W1, 60_000);
        p[1] = ISplitWallet.Payee(0, W2, 40_000);
        split = ledger.createWallet(p, bytes32(0));
        equivalent = ledger.createWallet(p, bytes32(uint256(1)));
        p[0].share = 50_000;
        p[1].share = 50_000;
        different = ledger.createWallet(p, bytes32(0));
    }

    function _map(address target, bytes4 selector) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, FUNDS_ROLE);
    }

    /// @dev Credits W1 with `amount` wei in the escrow and in `twin`; zero credits nothing.
    function _depositBoth(RevenueEscrow twin, uint256 amount) internal {
        if (amount == 0) return;
        _deposit(W1, amount);
        vm.deal(PAYER, amount);
        vm.prank(PAYER);
        twin.depositETH{ value: amount }(W1);
    }

    /// @dev Credits `wallet` with `amount` wei from the payer; a zero amount credits nothing.
    function _deposit(address wallet, uint256 amount) internal {
        if (amount == 0) return;
        vm.deal(PAYER, amount);
        vm.prank(PAYER);
        escrow.depositETH{ value: amount }(wallet);
    }
}
