// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { StreamDirectory6529 } from "src/core/StreamDirectory6529.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { MockAccounts } from "../mocks/core/CoreMocks.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @notice The escrow's unclaimed period is the network's setting in `StreamDirectory6529`
///         (`IDirectory.unclaimedPeriod`), read through its split factory's resolver whenever it
///         ages a credit. The escrow here sits on a ledger deployed with the real
///         `StreamDirectory6529`.
/// @dev Each test fails against the escrow with a compiled 180 days: a period other than 180
///      days, zero, or a change after the credit would decide the expiry differently.
contract RevenueEscrowUnclaimedPeriodTest is EconomicsBase {
    StreamDirectory6529 internal directory;

    function setUp() public override {
        super.setUp();
        MockAccounts accounts = new MockAccounts();
        directory = new StreamDirectory6529(
            address(manager),
            address(accounts),
            address(accounts),
            address(accounts),
            address(accounts)
        );
        ledger = new SplitLedger(IArtistPayoutResolver(address(directory)), address(feeVault));
        factory = ledger;
        verifier = ledger;
        escrow = new RevenueEscrow(address(manager), ledger);
    }

    function _deposit(address wallet, uint256 amount) internal {
        vm.deal(address(this), amount);
        escrow.depositETH{ value: amount }(wallet);
    }

    /// @dev A lone credit may expire exactly when the period in force has passed since its
    ///      block, for any period and any elapsed time; before, the money stays.
    function testFuzz_ACreditWaitsForThePeriodInForce(uint48 period, uint48 elapsed) public {
        period = uint48(bound(period, 0, 3650 days));
        elapsed = uint48(bound(elapsed, 0, 3650 days));
        directory.setUnclaimedPeriod(period);
        uint256 creditedAt = block.timestamp;
        _deposit(alice, 1 ether);
        vm.warp(creditedAt + elapsed);
        assertEq(escrow.expirableAt(alice, ETH, block.timestamp), elapsed >= period ? 1 ether : 0);
        if (elapsed < period) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRevenueEscrow.CreditNotExpired.selector, alice, ETH, creditedAt + period
                )
            );
            escrow.expire(alice, ETH);
            assertEq(escrow.owed(alice, ETH), 1 ether, "the money stays");
        } else {
            assertEq(escrow.expire(alice, ETH), 1 ether);
        }
    }

    /// @dev Zero lets a credit expire at once.
    function test_ZeroAllowsAnExpiryAtOnce() public {
        directory.setUnclaimedPeriod(0);
        _deposit(alice, 1 ether);
        assertEq(escrow.expire(alice, ETH), 1 ether);
        assertEq(escrow.owed(address(feeVault), ETH), 1 ether);
    }

    /// @dev The period is read when the escrow looks: a change after the credit applies to it,
    ///      shorter or longer, and the amount is never more than was credited before.
    function testFuzz_AChangeAppliesToACreditAlreadyWaiting(uint48 later, uint48 elapsed) public {
        later = uint48(bound(later, 0, 3650 days));
        elapsed = uint48(bound(elapsed, 0, 3650 days));
        uint256 creditedAt = block.timestamp;
        _deposit(alice, 1 ether);
        vm.warp(creditedAt + elapsed);
        vm.expectEmit(address(directory));
        emit IDirectory.UnclaimedPeriodSet(180 days, later);
        directory.setUnclaimedPeriod(later);
        if (elapsed < later) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRevenueEscrow.CreditNotExpired.selector, alice, ETH, creditedAt + later
                )
            );
            escrow.expire(alice, ETH);
        } else {
            assertEq(escrow.expire(alice, ETH), 1 ether);
        }
    }

    /// @dev A closed window still maturing takes its due time from its last credit and the period
    ///      in force when the escrow looks, so a shorter period applies to it too; the open
    ///      window's credits stay.
    function test_AChangeAppliesToAClosedWindowStillMaturing() public {
        uint256 start = block.timestamp;
        _deposit(alice, 1 ether);
        vm.warp(start + 100 days);
        _deposit(alice, 2 ether); // joins the window opened on day 0
        vm.warp(start + 200 days);
        _deposit(alice, 4 ether); // the window closed on day 180: due on day 280 at 180 days
        (,,, uint48 maturingLastAt,,) = escrow.credits(alice, ETH);
        assertEq(maturingLastAt, start + 100 days, "the closed window's last credit");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRevenueEscrow.CreditNotExpired.selector, alice, ETH, start + 280 days
            )
        );
        escrow.expire(alice, ETH);
        directory.setUnclaimedPeriod(90 days); // due on day 190 now: already passed
        assertEq(escrow.expire(alice, ETH), 3 ether, "the closed window only");
        assertEq(escrow.owed(alice, ETH), 4 ether, "the open window stays");
    }

    /// @dev Only the network sets the period, in `StreamDirectory6529`.
    function testFuzz_OnlyTheNetworkSetsThePeriod(address stranger, uint48 next) public {
        vm.assume(stranger != address(this));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        directory.setUnclaimedPeriod(next);
        assertEq(directory.unclaimedPeriod(), 180 days);
    }
}
