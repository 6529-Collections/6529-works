// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { EconomicsBase } from "./EconomicsBase.sol";
import { EscrowLots } from "./EscrowLots.sol";

/// @notice The escrow's expiry windows (R12, ECO-45): every amount stays its account's for at
///         least 180 days from its block and may move to the network less than 360 days after
///         it; no deposit, by anyone, shortens any amount's wait or moves the time from which an
///         amount already 180 days old may expire. Unit tests for each path, then a fuzzed
///         interleaving checked against the per-lot reference model (`EscrowLots`).
contract RevenueEscrowExpiryTest is EconomicsBase {
    using EscrowLots for EscrowLots.Book;

    uint256 internal constant PERIOD = 180 days;

    address internal stranger = makeAddr("stranger");
    address internal carol = makeAddr("carol");
    uint256 internal start;

    function setUp() public override {
        super.setUp();
        start = block.timestamp;
    }

    function _deposit(address from, address wallet, uint256 amount) internal {
        vm.deal(from, amount);
        vm.prank(from);
        escrow.depositETH{ value: amount }(wallet);
    }

    function _parts(address wallet)
        internal
        view
        returns (uint256 aged, uint256 maturing, uint256 recent)
    {
        (aged, maturing, recent,,,) = escrow.credits(wallet, ETH);
    }

    function _expectNotDue(address wallet, uint256 dueAt) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.CreditNotExpired.selector, wallet, ETH, dueAt)
        );
        escrow.expire(wallet, ETH);
    }

    // ------------------------------------------------------------------ unit paths

    /// @dev A lone credit may move exactly 180 days after its block, not a second sooner.
    function test_ALoneCreditExpiresAfterExactly180Days() public {
        _deposit(stranger, alice, 3 ether);
        vm.warp(start + PERIOD - 1);
        assertEq(escrow.expirableAt(alice, ETH, block.timestamp), 0);
        assertEq(escrow.expirableAt(alice, ETH, start + PERIOD), 3 ether, "projected");
        _expectNotDue(alice, start + PERIOD);
        vm.warp(start + PERIOD);
        assertEq(escrow.expire(alice, ETH), 3 ether);
        (uint256 aged, uint256 maturing, uint256 recent) = _parts(alice);
        assertEq(aged + maturing + recent, 0);
    }

    /// @dev A credit after the window closed opens a new window; the old window's credits move
    ///      on their own schedule and the new credit stays.
    function test_ACreditAfterTheWindowClosedOpensANewWindow() public {
        _deposit(stranger, alice, 1 ether);
        vm.warp(start + 100 days);
        _deposit(stranger, alice, 2 ether); // joins: the window opened on day 0
        vm.warp(start + 200 days);
        _deposit(stranger, alice, 4 ether); // the window closed on day 180: a new one
        (uint256 aged, uint256 maturing, uint256 recent) = _parts(alice);
        assertEq(aged, 0);
        assertEq(maturing, 3 ether, "the first window, due on day 280");
        assertEq(recent, 4 ether);
        (,,, uint48 maturesAt, uint48 openedAt, uint48 lastAt) = escrow.credits(alice, ETH);
        assertEq(maturesAt, start + 280 days);
        assertEq(openedAt, start + 200 days);
        assertEq(lastAt, start + 200 days);

        _expectNotDue(alice, start + 280 days);
        vm.warp(start + 280 days);
        vm.expectEmit(address(escrow));
        emit IRevenueEscrow.Expired(alice, ETH, address(feeVault), 3 ether, 3 ether);
        assertEq(escrow.expire(alice, ETH), 3 ether);
        assertEq(escrow.owed(alice, ETH), 4 ether, "the new window stays");
        _expectNotDue(alice, start + 380 days);
        vm.warp(start + 380 days);
        assertEq(escrow.expire(alice, ETH), 4 ether);
        assertEq(escrow.owed(address(feeVault), ETH), 7 ether);
        assertEq(escrow.totalOwed(ETH), 7 ether, "nothing left the escrow");
    }

    /// @dev An amount already 180 days old whose window is still maturing (a later credit
    ///      extended it) keeps its due time when a stranger deposits: the deposit opens a new
    ///      window and never joins the old one.
    function test_ADepositNeverPostponesAnAmountAlready180DaysOld() public {
        _deposit(stranger, alice, 1 ether);
        vm.warp(start + 179 days);
        _deposit(stranger, alice, 1); // extends the window: due on day 359
        vm.warp(start + 200 days); // the 1 ether is 200 days old
        assertEq(escrow.expirableAt(alice, ETH, start + 359 days), 1 ether + 1);
        _deposit(stranger, alice, 1);
        assertEq(escrow.expirableAt(alice, ETH, start + 359 days), 1 ether + 1, "unchanged");
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 15 days);
            _deposit(stranger, alice, 1);
        }
        vm.warp(start + 359 days);
        assertEq(escrow.expire(alice, ETH), 1 ether + 1, "on the day it was due");
        assertEq(escrow.owed(alice, ETH), 11, "the later dust stays");
    }

    /// @dev Worst case: a credit on the day its window opens, then one more credit every day of
    ///      the window: it moves on day 359, under 360 days, and never before day 180 + its own.
    function test_TheWorstCaseWaitIsUnder360Days() public {
        _deposit(alice, alice, 5 ether);
        for (uint256 d = 1; d < 180; ++d) {
            vm.warp(start + d * 1 days);
            _deposit(stranger, alice, 1);
        }
        vm.warp(start + 180 days);
        _expectNotDue(alice, start + 359 days);
        vm.warp(start + 359 days);
        assertEq(escrow.expire(alice, ETH), 5 ether + 179);
    }

    /// @dev Three generations at once: a matured window (aged once rolled), a maturing one and
    ///      the open one; each moves only when due, and `CreditNotExpired` names the next due.
    function test_ThreeGenerationsAgeInOrder() public {
        _deposit(stranger, alice, 1); // window 1: day 0..180, last credit day 0
        vm.warp(start + 190 days);
        _deposit(stranger, alice, 10); // window 2 opens; window 1 already due (day 180)
        (uint256 aged, uint256 maturing, uint256 recent) = _parts(alice);
        assertEq(aged, 1);
        assertEq(maturing, 0);
        assertEq(recent, 10);
        vm.warp(start + 300 days);
        _deposit(stranger, alice, 100); // window 2 last credit day 300 (window open to day 370)
        vm.warp(start + 375 days);
        _deposit(stranger, alice, 1000); // window 3 opens; window 2 due on day 480
        (aged, maturing, recent) = _parts(alice);
        assertEq(aged, 1);
        assertEq(maturing, 110);
        assertEq(recent, 1000);
        assertEq(escrow.expire(alice, ETH), 1, "only the matured window");
        _expectNotDue(alice, start + 480 days);
        vm.warp(start + 480 days);
        assertEq(escrow.expire(alice, ETH), 110);
        _expectNotDue(alice, start + 555 days);
        vm.warp(start + 555 days);
        assertEq(escrow.expire(alice, ETH), 1000);
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, alice, ETH));
        escrow.expire(alice, ETH);
    }

    /// @dev A flush pays every part, matured or not, and a later credit opens a fresh window.
    function test_FlushTakesEveryPart() public {
        _deposit(stranger, alice, 1);
        vm.warp(start + 100 days);
        _deposit(stranger, alice, 2);
        vm.warp(start + 200 days);
        _deposit(stranger, alice, 4);
        uint256 before = alice.balance;
        assertEq(escrow.flush(alice, ETH), 7);
        assertEq(alice.balance, before + 7);
        (uint256 aged, uint256 maturing, uint256 recent) = _parts(alice);
        assertEq(aged + maturing + recent, 0);
        (,,, uint48 maturesAt, uint48 openedAt, uint48 lastAt) = escrow.credits(alice, ETH);
        assertEq(uint256(maturesAt) + openedAt + lastAt, 0, "the record is cleared");
        assertEq(escrow.totalOwed(ETH), 0);
    }

    /// @dev A recovery takes every part and is a new credit to the replacement, which joins the
    ///      replacement's open window or opens one.
    function test_RecoveryIsANewCreditToTheReplacement() public {
        _deposit(stranger, alice, 1 ether);
        vm.warp(start + 170 days);
        vm.prank(alice);
        escrow.consentToRecovery(carol);
        escrow.recover(alice, carol, ETH);
        assertEq(escrow.owed(alice, ETH), 0);
        assertEq(escrow.owed(carol, ETH), 1 ether);
        vm.warp(start + PERIOD);
        assertEq(escrow.expirableAt(carol, ETH, block.timestamp), 0, "a new 180 days for carol");
        assertEq(escrow.expirableAt(carol, ETH, start + 350 days), 1 ether);
    }

    /// @dev The network's own credit never expires, however old, and `expirableAt` reads zero
    ///      for it; a past time reads as now.
    function test_TheNetworksCreditNeverExpiresAndViewsClamp() public {
        _deposit(stranger, address(feeVault), 1 ether);
        vm.warp(start + 1000 days);
        assertEq(escrow.expirableAt(address(feeVault), ETH, block.timestamp), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, address(feeVault))
        );
        escrow.expire(address(feeVault), ETH);

        _deposit(stranger, alice, 2 ether);
        assertEq(escrow.expirableAt(alice, ETH, 0), 0, "a past time is now");
        assertEq(escrow.expirableAt(alice, ETH, block.timestamp + PERIOD), 2 ether);
    }

    // ------------------------------------------------------------------ fuzzed interleavings

    EscrowLots.Book internal _aliceBook;
    EscrowLots.Book internal _carolBook;
    EscrowLots.Book internal _networkBook;
    uint256 internal _deposited;
    uint256 internal _paidOut;

    function _book(address wallet) internal view returns (EscrowLots.Book storage) {
        if (wallet == alice) return _aliceBook;
        if (wallet == carol) return _carolBook;
        return _networkBook;
    }

    /// @dev Arbitrary interleavings of deposits (by the owner and by strangers, dust and large),
    ///      flushes, recoveries, expiries and time moves, over two accounts and the network's
    ///      own. After every step: the credits match the per-lot model now and at future times;
    ///      no amount younger than 180 days is expirable; every amount 360 days old is; a deposit
    ///      never lowers what an already-180-day-old amount can expire at any future time; value
    ///      is conserved.
    function testFuzz_ExpiryGuaranteesUnderAnyInterleaving(uint256[32] calldata steps) public {
        for (uint256 s; s < steps.length; ++s) {
            uint256 r = steps[s];
            uint256 kind = r % 8;
            address wallet =
                (r >> 8) % 3 == 0 ? carol : (r >> 8) % 3 == 1 ? alice : address(feeVault);
            if (kind <= 2) {
                uint256 amount = kind == 0 ? 1 + (r >> 16) % 10 : 1 + (r >> 16) % 1e24;
                address from = kind == 1 ? wallet : stranger;
                _depositChecked(from, wallet, amount);
            } else if (kind == 3) {
                _flushChecked(wallet);
            } else if (kind == 4) {
                _recoverChecked(r >> 16);
            } else if (kind == 5) {
                _expireChecked(wallet);
            } else {
                // Time moves: up to 400 days, often around the window edges.
                uint256 step =
                    (r >> 16) % 4 == 0 ? PERIOD - 1 + (r >> 24) % 3 : (r >> 16) % 400 days;
                vm.warp(block.timestamp + step);
            }
            _checkAll();
        }
    }

    function _depositChecked(address from, address wallet, uint256 amount) internal {
        EscrowLots.Book storage b = _book(wallet);
        uint256 old = b.olderThan(block.timestamp, PERIOD);
        uint256[6] memory at = _horizons();
        uint256[6] memory before;
        for (uint256 i; i < 6; ++i) {
            before[i] = escrow.expirableAt(wallet, ETH, at[i]);
        }
        _deposit(from, wallet, amount);
        b.credit(amount, block.timestamp);
        _deposited += amount;
        for (uint256 i; i < 6; ++i) {
            uint256 floor = before[i] < old ? before[i] : old;
            assertGe(escrow.expirableAt(wallet, ETH, at[i]), floor, "a deposit postponed old money");
        }
        assertEq(escrow.expirableAt(wallet, ETH, block.timestamp), before[0], "nothing new is due");
    }

    function _flushChecked(address wallet) internal {
        EscrowLots.Book storage b = _book(wallet);
        uint256 held = b.total();
        if (held == 0) {
            vm.expectRevert(
                abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, wallet, ETH)
            );
            escrow.flush(wallet, ETH);
            return;
        }
        vm.prank(stranger);
        assertEq(escrow.flush(wallet, ETH), held);
        b.takeAll();
        _paidOut += held;
    }

    function _recoverChecked(uint256 seed) internal {
        // Alice's credit to carol with consent, or the network's own to carol without.
        address from = seed % 2 == 0 ? alice : address(feeVault);
        EscrowLots.Book storage b = _book(from);
        uint256 held = b.total();
        if (from == alice) {
            vm.prank(alice);
            escrow.consentToRecovery(carol);
        }
        if (held == 0) {
            vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, from, ETH));
            escrow.recover(from, carol, ETH);
            return;
        }
        escrow.recover(from, carol, ETH);
        b.takeAll();
        _carolBook.credit(held, block.timestamp);
    }

    function _expireChecked(address wallet) internal {
        EscrowLots.Book storage b = _book(wallet);
        if (wallet == address(feeVault)) {
            vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, wallet));
            escrow.expire(wallet, ETH);
            return;
        }
        uint256 due = b.expirable(block.timestamp);
        if (b.total() == 0) {
            vm.expectRevert(
                abi.encodeWithSelector(IRevenueEscrow.NothingOwed.selector, wallet, ETH)
            );
            escrow.expire(wallet, ETH);
            return;
        }
        if (due == 0) {
            _expectNotDue(wallet, b.nextDue());
            return;
        }
        assertLe(due, b.olderThan(block.timestamp, PERIOD), "model: young money due");
        vm.prank(stranger);
        assertEq(escrow.expire(wallet, ETH), due, "expired amount");
        b.expire(block.timestamp);
        _networkBook.credit(due, block.timestamp);
    }

    function _horizons() internal view returns (uint256[6] memory at) {
        uint256 t = block.timestamp;
        at = [t, t + 1 days, t + 179 days, t + PERIOD, t + 359 days, t + 360 days];
    }

    function _checkAll() internal view {
        address[3] memory wallets = [alice, carol, address(feeVault)];
        uint256 sum;
        uint256[6] memory at = _horizons();
        for (uint256 w; w < 3; ++w) {
            address wallet = wallets[w];
            EscrowLots.Book storage b = _book(wallet);
            assertEq(escrow.owed(wallet, ETH), b.total(), "owed");
            sum += b.total();
            if (wallet == address(feeVault)) continue;
            for (uint256 i; i < 6; ++i) {
                uint256 e = escrow.expirableAt(wallet, ETH, at[i]);
                assertEq(e, b.expirable(at[i]), "expirable matches the model");
                assertLe(e, b.olderThan(at[i], PERIOD), "never before 180 days");
                assertGe(e, b.olderThan(at[i], 2 * PERIOD), "always by 360 days");
            }
        }
        assertEq(sum, escrow.totalOwed(ETH), "credits sum to the total");
        assertEq(address(escrow).balance, escrow.totalOwed(ETH), "fully backed");
        assertEq(_deposited, sum + _paidOut, "value conserved");
    }
}
