// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { AuctionFixture } from "./AuctionFixture.sol";

/// @notice Aged credits: only money that has itself waited the unclaimed period (the
///         directory's setting, read when expiry is attempted) may go to the network, and no
///         third party can shorten or postpone a credit's wait.
contract EnglishAuctionCreditsTest is AuctionFixture {
    uint256 internal saleCount;

    /// @dev Credits `amount` to alice: she bids it on a fresh sale and carol outbids her.
    function _creditAlice(uint256 amount) internal {
        uint256 saleId = _start(++saleCount);
        _bid(alice, saleId, amount);
        _bid(carol, saleId, auction.minimumBid(saleId));
    }

    function _period() internal view returns (uint256) {
        return directory.unclaimedPeriod();
    }

    function test_Expire_TakesOnlyTheMoneyThatWaitedThePeriod() public {
        uint256 t0 = block.timestamp;
        _creditAlice(1 ether);
        vm.warp(t0 + 100 days);
        _creditAlice(2 ether);
        assertEq(auction.claimable(alice), 3 ether);
        assertEq(auction.expiresAt(alice), t0 + _period());
        vm.warp(t0 + _period() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.CreditNotExpired.selector, alice, t0 + _period())
        );
        auction.expireCredit(alice);
        vm.warp(t0 + _period());
        uint256 before = feeRecipient.balance;
        vm.expectEmit(address(auction));
        emit IEnglishAuction.Claimed(alice, address(0), feeRecipient, 1 ether);
        assertEq(auction.expireCredit(alice), 1 ether);
        assertEq(feeRecipient.balance, before + 1 ether);
        // The later 2 ether start their own wait now.
        assertEq(auction.claimable(alice), 2 ether);
        assertEq(auction.expiresAt(alice), block.timestamp + _period());
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.CreditNotExpired.selector, alice, block.timestamp + _period()
            )
        );
        auction.expireCredit(alice);
        vm.warp(block.timestamp + _period());
        assertEq(auction.expireCredit(alice), 2 ether);
        assertEq(auction.claimable(alice), 0);
        assertEq(auction.expiresAt(alice), 0);
    }

    function test_Expire_NothingToExpire() public {
        vm.expectRevert(abi.encodeWithSelector(IEnglishAuction.NothingToClaim.selector, alice));
        auction.expireCredit(alice);
    }

    function test_AThirdPartyCanNeitherShortenNorPostponeAWait() public {
        uint256 t0 = block.timestamp;
        _creditAlice(1 ether);
        uint256 due = auction.expiresAt(alice);
        // Others' actions that add to alice's credit (outbidding her again) move nothing.
        vm.warp(t0 + 10 days);
        _creditAlice(5 ether);
        assertEq(auction.expiresAt(alice), due, "not postponed");
        vm.warp(due - 1);
        _creditAlice(1 ether);
        assertEq(auction.expiresAt(alice), due, "not shortened or moved");
        vm.warp(due);
        assertEq(auction.expireCredit(alice), 1 ether, "only the first, aged credit");
    }

    function test_AClaimEndsTheWait() public {
        _creditAlice(1 ether);
        vm.prank(alice);
        auction.claim(alice);
        vm.warp(block.timestamp + 100 days);
        _creditAlice(1 ether);
        assertEq(auction.expiresAt(alice), block.timestamp + _period(), "a fresh wait");
    }

    function testFuzz_NeverTakesMoneyYoungerThanThePeriod(
        uint8 deposits,
        uint256 seed,
        uint256 expireAt
    ) public {
        deposits = uint8(bound(deposits, 1, 6));
        uint256 t0 = block.timestamp;
        uint256[] memory times = new uint256[](deposits);
        uint256[] memory amounts = new uint256[](deposits);
        uint256 t = t0;
        for (uint256 i; i < deposits; ++i) {
            t += bound(uint256(keccak256(abi.encode(seed, i))), 0, 120 days);
            vm.warp(t);
            amounts[i] = 0.01 ether * (1 + (uint256(keccak256(abi.encode(seed, i, 1))) % 50));
            times[i] = t;
            _creditAlice(amounts[i]);
        }
        expireAt = bound(expireAt, t, t + 400 days);
        vm.warp(expireAt);
        uint256 aged;
        for (uint256 i; i < deposits; ++i) {
            if (times[i] + _period() <= expireAt) aged += amounts[i];
        }
        if (block.timestamp < auction.expiresAt(alice)) {
            vm.expectRevert();
            auction.expireCredit(alice);
            return;
        }
        uint256 taken = auction.expireCredit(alice);
        assertLe(taken, aged, "took money younger than the period");
        assertGt(taken, 0);
    }

    function testFuzz_ThePeriodInForceIsReadWhenExpiryIsAttempted(uint48 period, uint256 wait)
        public
    {
        period = uint48(bound(period, 0, 400 days));
        _creditAlice(1 ether);
        uint256 credited = block.timestamp;
        vm.expectEmit(address(directory));
        emit IDirectory.UnclaimedPeriodSet(180 days, period);
        directory.setUnclaimedPeriod(period);
        wait = bound(wait, 0, 500 days);
        vm.warp(credited + wait);
        if (wait < period) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IEnglishAuction.CreditNotExpired.selector, alice, credited + period
                )
            );
            auction.expireCredit(alice);
        } else {
            assertEq(auction.expireCredit(alice), 1 ether);
        }
    }

    function test_ZeroPeriodExpiresAtOnce() public {
        directory.setUnclaimedPeriod(0);
        _creditAlice(1 ether);
        assertEq(auction.expireCredit(alice), 1 ether);
    }

    function test_OnlyTheNetworkSetsThePeriod() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice)
        );
        directory.setUnclaimedPeriod(0);
    }

    function test_AShorterPeriodAppliesToAWaitAlreadyRunning() public {
        _creditAlice(1 ether);
        uint256 credited = block.timestamp;
        vm.warp(credited + 30 days);
        vm.expectRevert();
        auction.expireCredit(alice);
        directory.setUnclaimedPeriod(30 days);
        assertEq(auction.expireCredit(alice), 1 ether);
    }

    function test_Expire_ToNoRecipientReverts() public {
        _creditAlice(1 ether);
        vm.warp(block.timestamp + _period());
        vm.mockCall(
            address(economics),
            abi.encodeWithSignature("networkFeeRecipient(bytes32)", keccak256("PRODUCT_STREAM")),
            abi.encode(address(0))
        );
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidRecipient.selector, address(0))
        );
        auction.expireCredit(alice);
        assertEq(auction.claimable(alice), 1 ether);
    }
}
