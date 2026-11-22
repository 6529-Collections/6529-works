// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { RecordFlowsBase } from "./RecordFlowsBase.sol";

/// @notice Money nobody claims, on the real stack: the English auction's outbid credits
///         (`claimable`, `claim`, `expireCredit`) and the revenue escrow's credit windows
///         (`expire`, `expirableAt`, `credits`), under the network's `Directory.unclaimedPeriod`,
///         which it changes at once (zero allowed). Only money that has itself waited the period
///         goes to the network; a change of the period applies to waits already running; nobody
///         but the account's own claim moves an auction clock; the account's claim takes all.
contract CreditsTest is RecordFlowsBase {
    address internal lead;
    address internal bidder = makeAddr("creditBidder");
    address internal rival = makeAddr("creditRival");
    address internal stranger = makeAddr("creditStranger");

    function setUp() public override {
        super.setUp();
        lead = _actor("creditLead");
    }

    function _setPeriod(uint48 next) internal {
        _asNetwork(address(directory), abi.encodeCall(directory.setUnclaimedPeriod, (next)));
        assertEq(directory.unclaimedPeriod(), next);
    }

    /// @dev `bidder` bids the minimum and `rival` outbids it: `bidder` is credited its bid.
    function _outbid(uint256 saleId) internal returns (uint256 credited) {
        credited = auction.minimumBid(saleId);
        _ethBid(saleId, bidder, credited);
        _ethBid(saleId, rival, auction.minimumBid(saleId));
    }

    function _startedSales(uint256 count) internal returns (bytes32 root, Work[] memory works) {
        works = new Work[](count);
        for (uint256 i; i < count; ++i) {
            works[i] = _work(lead, collectionId);
        }
        root = _publish(works);
        _keep(root, works);
    }

    // ------------------------------------------------------------------ the auction's credits

    /// @dev Outbid credits add up; the account's own claim takes everything and clears the clock;
    ///      nobody else claims them.
    function test_Credits_OwnClaimTakesEverything() public {
        (bytes32 root, Work[] memory works) = _startedSales(1);
        (uint256 saleId,) = _start(root, works, 0);
        uint256 a = _outbid(saleId);
        uint256 b = _outbid(saleId);
        assertEq(auction.claimable(bidder), a + b);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NothingToClaim.selector, stranger));
        auction.claim(stranger);

        uint256 before = bidder.balance;
        vm.expectEmit(address(auction));
        emit IEnglishAuction.Claimed(bidder, CURRENCY_ETH, bidder, a + b);
        vm.prank(bidder);
        assertEq(auction.claim(bidder), a + b);
        assertEq(bidder.balance - before, a + b);
        assertEq(auction.claimable(bidder), 0);
        assertEq(auction.expiresAt(bidder), 0);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NothingToClaim.selector, bidder));
        auction.claim(bidder);
    }

    /// @dev Credit A, then credit B an hour later; the network shortens the period mid-wait,
    ///      lengthens it, then sets zero. Each expiry takes only the money that has waited the
    ///      period in force (A first, B after its own wait), refused one second early.
    function test_Credits_ExpiryTakesOnlyAgedMoneyUnderAChangingPeriod() public {
        (bytes32 root, Work[] memory works) = _startedSales(1);
        (uint256 saleId,) = _start(root, works, 0);
        uint256 t0 = block.timestamp;
        uint256 a = _outbid(saleId);
        assertEq(auction.expiresAt(bidder), t0 + 180 days);
        _wait(1 hours);
        uint256 b = _outbid(saleId);
        assertEq(auction.claimable(bidder), a + b);
        assertEq(auction.expiresAt(bidder), t0 + 180 days, "B does not postpone A");

        // Shorter, at once: the running wait is measured against it.
        _wait(1 hours);
        _setPeriod(1 days);
        assertEq(auction.expiresAt(bidder), t0 + 1 days, "B does not shorten or join A");
        vm.warp(t0 + 1 days - 1);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.CreditNotExpired.selector, bidder, t0 + 1 days)
        );
        auction.expireCredit(bidder);

        vm.warp(t0 + 1 days);
        uint256 vault = networkFee.balance;
        vm.expectEmit(address(auction));
        emit IEnglishAuction.Claimed(bidder, CURRENCY_ETH, networkFee, a);
        vm.prank(stranger);
        assertEq(auction.expireCredit(bidder), a, "only A, which waited the period");
        assertEq(networkFee.balance - vault, a);
        assertEq(auction.claimable(bidder), b);
        assertEq(auction.expiresAt(bidder), t0 + 2 days, "B waits a whole period from now");

        // Longer, at once.
        _setPeriod(30 days);
        assertEq(auction.expiresAt(bidder), t0 + 31 days);
        vm.warp(t0 + 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.CreditNotExpired.selector, bidder, t0 + 31 days)
        );
        auction.expireCredit(bidder);

        // Zero: everything waiting is due now.
        _setPeriod(0);
        assertEq(auction.expireCredit(bidder), b);
        assertEq(auction.claimable(bidder), 0);
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NothingToClaim.selector, bidder));
        auction.expireCredit(bidder);
    }

    /// @dev Under the launch period, a third party's later credit to the account (outbidding it
    ///      on another sale 100 days on) neither postpones nor joins the running wait: at 180
    ///      days exactly A expires, and B waits its own 180 days from then. Only the network
    ///      changes the period.
    function test_Credits_AThirdPartyCannotShortenOrPostponeTheClock() public {
        (bytes32 root, Work[] memory works) = _startedSales(2);
        (uint256 first,) = _start(root, works, 0);
        uint256 t0 = block.timestamp;
        uint256 a = _outbid(first);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        directory.setUnclaimedPeriod(0);

        vm.warp(t0 + 100 days);
        (uint256 second,) = _start(root, works, 1);
        uint256 b = _outbid(second);
        assertEq(auction.expiresAt(bidder), t0 + 180 days, "not postponed");

        vm.warp(t0 + 180 days - 1);
        vm.prank(rival);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.CreditNotExpired.selector, bidder, t0 + 180 days)
        );
        auction.expireCredit(bidder);
        vm.warp(t0 + 180 days);
        vm.prank(rival);
        assertEq(auction.expireCredit(bidder), a, "not the later credit");
        assertEq(auction.claimable(bidder), b);
        assertEq(auction.expiresAt(bidder), t0 + 360 days);
        // The account's own claim still takes what is left.
        vm.prank(bidder);
        assertEq(auction.claim(bidder), b);
    }

    // ------------------------------------------------------------------ the escrow's windows

    function _deposit(address wallet, uint256 amount) internal {
        vm.deal(stranger, stranger.balance + amount);
        vm.prank(stranger);
        escrow.depositETH{ value: amount }(wallet);
    }

    function _credit(address wallet)
        internal
        view
        returns (
            uint256 aged,
            uint256 maturing,
            uint256 recent,
            uint48 maturingLastAt,
            uint48 openedAt,
            uint48 lastAt
        )
    {
        return escrow.credits(wallet, address(0));
    }

    /// @dev Credit A opens a window; credit B joins it four days later; the window's money is due
    ///      one period after its last credit. The network lengthens the period mid-wait (the due
    ///      time moves out), then shortens it (the window is due at once): expiry takes the
    ///      window and nothing credited after it.
    function test_Credits_EscrowWindowsFollowAChangedPeriod() public {
        address wallet = makeAddr("escrowedWallet");
        _setPeriod(10 days);
        uint256 t0 = block.timestamp;
        _deposit(wallet, 1 ether);
        vm.warp(t0 + 4 days);
        _deposit(wallet, 2 ether);
        (,,, uint48 maturingLastAt, uint48 openedAt, uint48 lastAt) = _credit(wallet);
        assertEq(openedAt, t0);
        assertEq(lastAt, t0 + 4 days);
        assertEq(maturingLastAt, 0);
        assertEq(escrow.expirableAt(wallet, address(0), t0 + 14 days - 1), 0);
        assertEq(escrow.expirableAt(wallet, address(0), t0 + 14 days), 3 ether);

        vm.warp(t0 + 10 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.CreditNotExpired.selector, wallet, address(0), t0 + 14 days
            )
        );
        escrow.expire(wallet, address(0));

        // Longer: the window now closes at 20 days and is due at 24.
        _setPeriod(20 days);
        assertEq(escrow.expirableAt(wallet, address(0), t0 + 24 days - 1), 0);
        assertEq(escrow.expirableAt(wallet, address(0), t0 + 24 days), 3 ether);
        // A credit now joins the still-open window, never past 2P from A.
        vm.warp(t0 + 12 days);
        _deposit(wallet, 4 ether);
        assertEq(escrow.expirableAt(wallet, address(0), t0 + 32 days - 1), 0);
        assertEq(escrow.expirableAt(wallet, address(0), t0 + 32 days), 7 ether);
        assertLe(t0 + 32 days, t0 + 2 * 20 days);

        // Shorter: the window closed and has waited the period since its last credit.
        vm.warp(t0 + 18 days);
        _setPeriod(5 days);
        assertEq(escrow.expirableAt(wallet, address(0), block.timestamp), 7 ether);
        uint256 vault = networkFee.balance;
        vm.prank(stranger);
        assertEq(escrow.expire(wallet, address(0)), 7 ether);
        assertEq(escrow.owed(wallet, address(0)), 0);
        assertEq(escrow.owed(networkFee, address(0)), 7 ether, "credited to the network");
        assertEq(networkFee.balance, vault, "as a credit, flushed by anyone");
    }

    /// @dev A credit made once an amount is a period old never joins it: A expires on time and
    ///      alone, and the late credit waits its own window. Zero allowed: then nothing waits.
    function test_Credits_EscrowALateCreditNeverJoinsAnAgedAmount() public {
        address wallet = makeAddr("lateWallet");
        _setPeriod(10 days);
        uint256 t0 = block.timestamp;
        _deposit(wallet, 1 ether);
        vm.warp(t0 + 10 days);
        _deposit(wallet, 5 ether);
        (uint256 aged,, uint256 recent, uint48 maturingLastAt, uint48 openedAt,) = _credit(wallet);
        assertEq(aged, 1 ether, "A aged before B arrived");
        assertEq(recent, 5 ether);
        assertEq(maturingLastAt, t0);
        assertEq(openedAt, t0 + 10 days);
        vm.prank(stranger);
        assertEq(escrow.expire(wallet, address(0)), 1 ether, "A alone");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.CreditNotExpired.selector, wallet, address(0), t0 + 20 days
            )
        );
        escrow.expire(wallet, address(0));
        _setPeriod(0);
        assertEq(escrow.expire(wallet, address(0)), 5 ether);
    }

    /// @dev Credits arriving every six days cannot hold a window open: it closes one period after
    ///      it opened, so its money is due at most two periods after its first credit, and the
    ///      credit after the close waits in a window of its own.
    function test_Credits_EscrowAStreamOfCreditsCannotHoldAWindowOpen() public {
        address wallet = makeAddr("streamedWallet");
        _setPeriod(10 days);
        uint256 t0 = block.timestamp;
        _deposit(wallet, 1 ether);
        vm.warp(t0 + 6 days);
        _deposit(wallet, 2 ether);
        vm.warp(t0 + 12 days);
        _deposit(wallet, 4 ether);
        (, uint256 maturing, uint256 recent, uint48 maturingLastAt, uint48 openedAt,) =
            _credit(wallet);
        assertEq(maturing, 3 ether, "the first window closed at 10 days");
        assertEq(maturingLastAt, t0 + 6 days);
        assertEq(recent, 4 ether);
        assertEq(openedAt, t0 + 12 days);
        vm.warp(t0 + 16 days);
        vm.prank(stranger);
        assertEq(escrow.expire(wallet, address(0)), 3 ether, "due 10 days after its last credit");
        assertEq(escrow.owed(wallet, address(0)), 4 ether);
        assertEq(escrow.expirableAt(wallet, address(0), t0 + 22 days - 1), 0);
        assertEq(escrow.expirableAt(wallet, address(0), t0 + 22 days), 4 ether);
    }

    /// @dev The network fee vault's credit never expires; any other credit is flushed whole to
    ///      its wallet by anyone, its clock with it.
    function test_Credits_EscrowFlushTakesEverythingAndTheFeeVaultNeverExpires() public {
        address wallet = makeAddr("flushedWallet");
        _deposit(wallet, 1 ether);
        _wait(1 days);
        _deposit(wallet, 2 ether);
        vm.prank(stranger);
        assertEq(escrow.flush(wallet, address(0)), 3 ether);
        assertEq(wallet.balance, 3 ether);
        (uint256 aged, uint256 maturing, uint256 recent,, uint48 openedAt,) = _credit(wallet);
        assertEq(aged + maturing + recent + openedAt, 0);

        _deposit(networkFee, 1 ether);
        _setPeriod(0);
        assertEq(escrow.expirableAt(networkFee, address(0), block.timestamp), 0);
        vm.expectRevert(abi.encodeWithSelector(IRevenueEscrow.InvalidWallet.selector, networkFee));
        escrow.expire(networkFee, address(0));
    }
}
