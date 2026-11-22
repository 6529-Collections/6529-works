// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Directory } from "src/core/Directory.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { ISplitLedger } from "src/economics/interfaces/ISplitLedger.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { MockAccounts } from "../mocks/core/CoreMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @dev A payout resolver that answers payout addresses and nothing else: no unclaimed period.
contract PayoutOnlyResolver is IArtistPayoutResolver {
    function payoutAddress(uint256) external pure returns (address) {
        return address(0xA27);
    }
}

/// @notice The unclaimed period of the split ledger is the network's setting in `Directory`
///         (`IDirectory.unclaimedPeriod`), read when a forfeit is attempted. The ledger here is
///         deployed with the real `Directory` as its resolver, as the deployment does.
/// @dev Each test fails against the ledger with a compiled 180 days: a period other than 180
///      days, zero, or a change after the mark would decide the forfeit differently.
contract SplitLedgerUnclaimedPeriodTest is EconomicsBase {
    Directory internal directory;
    MockAccounts internal accounts;

    function setUp() public override {
        super.setUp();
        accounts = new MockAccounts();
        accounts.setPayout(ARTIST, artistPayout);
        // The other three slots only need code; the ledger reads ACCOUNTS alone.
        directory = new Directory(
            address(manager),
            address(accounts),
            address(accounts),
            address(accounts),
            address(accounts)
        );
        ledger = new SplitLedger(IArtistPayoutResolver(address(directory)), address(feeVault));
        factory = ledger;
        verifier = ledger;
    }

    /// @dev A wallet with alice at 80% and the artist at 20%, holding 10 ether; marks the artist.
    function _marked()
        internal
        returns (address wallet, ISplitWallet.Payee[] memory payees, uint256 index)
    {
        wallet = _wallet(_list(_fixed(alice, 80_000), _artist(ARTIST, 20_000)));
        vm.deal(wallet, 10 ether);
        index = _artistIndex(wallet, ARTIST);
        payees = _payeesOf(wallet);
        ledger.mark(payees, bytes32(0), ETH, index);
    }

    function test_TheLedgerReadsThePeriodFromTheDirectory() public {
        assertEq(directory.unclaimedPeriod(), 180 days, "launch value");
        (address wallet, ISplitWallet.Payee[] memory payees, uint256 index) = _marked();
        uint256 dueAt = block.timestamp + 180 days;
        vm.warp(dueAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ISplitLedger.MarkNotDue.selector, wallet, ETH, index, dueAt)
        );
        ledger.forfeit(payees, bytes32(0), ETH, index);
        vm.warp(dueAt);
        assertEq(ledger.forfeit(payees, bytes32(0), ETH, index), 2 ether);
        assertEq(address(feeVault).balance, 2 ether);
    }

    /// @dev A forfeit is refused before the period in force has elapsed since the mark, and
    ///      allowed from then on, for any period and any elapsed time.
    function testFuzz_AForfeitWaitsForThePeriodInForce(uint48 period, uint48 elapsed) public {
        period = uint48(bound(period, 0, 3650 days));
        elapsed = uint48(bound(elapsed, 0, 3650 days));
        directory.setUnclaimedPeriod(period);
        (address wallet, ISplitWallet.Payee[] memory payees, uint256 index) = _marked();
        uint256 markedAt = block.timestamp;
        vm.warp(markedAt + elapsed);
        if (elapsed < period) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ISplitLedger.MarkNotDue.selector, wallet, ETH, index, markedAt + period
                )
            );
            ledger.forfeit(payees, bytes32(0), ETH, index);
            assertEq(wallet.balance, 10 ether, "the money stays");
        } else {
            assertEq(ledger.forfeit(payees, bytes32(0), ETH, index), 2 ether);
        }
    }

    /// @dev Zero lets a mark be forfeited at once, in the block it was placed.
    function test_ZeroAllowsAForfeitAtOnce() public {
        directory.setUnclaimedPeriod(0);
        (, ISplitWallet.Payee[] memory payees, uint256 index) = _marked();
        assertEq(ledger.forfeit(payees, bytes32(0), ETH, index), 2 ether);
        assertEq(address(feeVault).balance, 2 ether);
    }

    /// @dev The period is read when the forfeit is attempted: a change applies to a mark already
    ///      running, shorter or longer, and the amount the mark covers is unchanged (never money
    ///      that arrived after it).
    function testFuzz_AChangeAppliesToARunningMark(uint48 later, uint48 elapsed, uint96 extra)
        public
    {
        later = uint48(bound(later, 0, 3650 days));
        elapsed = uint48(bound(elapsed, 0, 3650 days));
        (address wallet, ISplitWallet.Payee[] memory payees, uint256 index) = _marked();
        uint256 markedAt = block.timestamp;
        vm.deal(wallet, 10 ether + uint256(extra));
        vm.warp(markedAt + elapsed);
        vm.expectEmit(address(directory));
        emit IDirectory.UnclaimedPeriodSet(180 days, later);
        directory.setUnclaimedPeriod(later);
        if (elapsed < later) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ISplitLedger.MarkNotDue.selector, wallet, ETH, index, markedAt + later
                )
            );
            ledger.forfeit(payees, bytes32(0), ETH, index);
        } else {
            assertEq(ledger.forfeit(payees, bytes32(0), ETH, index), 2 ether, "only the mark");
            assertEq(
                _releasable(wallet, ETH, index), (uint256(extra) * 20_000) / 100_000, "later money"
            );
        }
    }

    /// @dev Only the network sets the period, in `Directory`; the event carries old and new.
    function testFuzz_OnlyTheNetworkSetsThePeriod(address stranger, uint48 next) public {
        vm.assume(stranger != address(this));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        directory.setUnclaimedPeriod(next);
        vm.expectEmit(address(directory));
        emit IDirectory.UnclaimedPeriodSet(180 days, next);
        directory.setUnclaimedPeriod(next);
        assertEq(directory.unclaimedPeriod(), next);
    }

    /// @dev A resolver that does not answer the period makes the forfeit revert; the money stays
    ///      in the wallet. Releases still work.
    function test_AResolverWithoutThePeriodRefusesTheForfeit() public {
        ledger = new SplitLedger(new PayoutOnlyResolver(), address(feeVault));
        (address wallet, ISplitWallet.Payee[] memory payees, uint256 index) = _marked();
        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert();
        ledger.forfeit(payees, bytes32(0), ETH, index);
        assertEq(wallet.balance, 10 ether, "the money stays");
        assertEq(_release(wallet, ETH, _indexOf(wallet, alice)), 8 ether);
    }
}
