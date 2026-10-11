// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SplitWallet } from "src/economics/SplitWallet.sol";
import { Splits } from "src/economics/Splits.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { EconomicsBase } from "./EconomicsBase.sol";

/// @notice Fuzz tests of the share maths: cumulative entitlements, the dust bound, overflow-free
///         products and path independence of release order.
contract SplitMathTest is EconomicsBase {
    /// @dev Splits the denominator into `count` positive shares derived from `seed`.
    function _shares(uint256 seed, uint256 count) internal pure returns (uint32[] memory shares) {
        shares = new uint32[](count);
        uint256 left = D;
        for (uint256 i; i < count; ++i) {
            uint256 reserve = count - 1 - i;
            uint256 share = i == count - 1
                ? left
                : 1 + uint256(keccak256(abi.encode(seed, i))) % (left - reserve);
            shares[i] = uint32(share);
            left -= share;
        }
    }

    function test_RoyaltyRateIsExact() public pure {
        assertEq(Splits.entitlement(1 ether, 6_529), 0.06529 ether);
        assertEq(Splits.entitlement(100_000, 75_000), 75_000);
    }

    function testFuzz_EntitlementsNeverExceedObservedAndDustIsBounded(
        uint256 observed,
        uint256 seed,
        uint8 count
    ) public pure {
        uint256 n = bound(count, 1, 64);
        uint32[] memory shares = _shares(seed, n);
        uint256 sum;
        uint256 total;
        for (uint256 i; i < n; ++i) {
            sum += shares[i];
            total += Splits.entitlement(observed, shares[i]);
        }
        assertEq(sum, D);
        assertLe(total, observed);
        assertLe(observed - total, n - 1);
    }

    function testFuzz_EntitlementIsTheExactFloor(uint256 observed, uint32 share) public pure {
        share = uint32(bound(share, 0, D));
        observed = bound(observed, 0, type(uint256).max / D);
        assertEq(Splits.entitlement(observed, share), observed * share / D);
    }

    function testFuzz_EntitlementIsMonotonic(uint256 a, uint256 b, uint32 share) public pure {
        share = uint32(bound(share, 0, D));
        (uint256 lo, uint256 hi) = a < b ? (a, b) : (b, a);
        assertLe(Splits.entitlement(lo, share), Splits.entitlement(hi, share));
    }

    function testFuzz_ReleaseTimingDoesNotChangeTotals(
        uint96[4] memory deposits,
        uint8 releaseMask,
        uint256 seed
    ) public {
        uint32[] memory shares = _shares(seed, 3);
        SplitWallet w = _wallet(
            _list(_fixed(alice, shares[0]), _fixed(bob, shares[1]), _fixed(artistPayout, shares[2]))
        );
        uint256 received;
        for (uint256 round; round < 4; ++round) {
            vm.deal(address(w), address(w).balance + deposits[round]);
            received += deposits[round];
            for (uint256 p; p < 3; ++p) {
                if ((releaseMask >> (round * 2 + p % 2)) & 1 == 1 && w.releasable(ETH, p) > 0) {
                    w.release(ETH, p);
                }
            }
        }
        uint256 released;
        for (uint256 p; p < 3; ++p) {
            if (w.releasable(ETH, p) > 0) w.release(ETH, p);
            assertEq(w.released(ETH, p), Splits.entitlement(received, w.payee(p).share));
            released += w.released(ETH, p);
        }
        assertEq(released + address(w).balance, received);
        assertLe(address(w).balance, 2);
    }

    function testFuzz_ValidationAcceptsExactlyCanonicalLists(uint256 seed, uint8 count) public {
        uint256 n = bound(count, 1, 12);
        uint32[] memory shares = _shares(seed, n);
        ISplitWallet.Payee[] memory payees = new ISplitWallet.Payee[](n);
        for (uint256 i; i < n; ++i) {
            payees[i] = i % 3 == 2
                ? _artist(i + 1, shares[i])
                : _fixed(address(uint160(uint256(keccak256(abi.encode(seed, "a", i))))), shares[i]);
        }
        _sorted(payees);
        address wallet = factory.createWallet(payees);
        assertEq(SplitWallet(payable(wallet)).payeeCount(), n);
        if (n > 1) {
            (payees[0], payees[n - 1]) = (payees[n - 1], payees[0]);
            vm.expectRevert(abi.encodeWithSelector(ISplitWallet.PayeesNotCanonical.selector, 1));
            factory.walletFor(payees);
        }
    }
}
