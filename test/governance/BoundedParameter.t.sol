// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { BoundedParameter } from "src/governance/BoundedParameter.sol";

contract BoundedParameterHarness {
    function initial(uint256 value, uint256 ceiling) external pure returns (uint256) {
        return BoundedParameter.initial(value, ceiling);
    }

    function raise(uint256 current, uint256 proposed, uint256 ceiling)
        external
        pure
        returns (uint256)
    {
        return BoundedParameter.raise(current, proposed, ceiling);
    }
}

/// @notice ADR 0001 §13.9: raise-only, at most 2x per step, absolute ceiling.
contract BoundedParameterTest is Test {
    uint256 internal constant CEILING = 1_000_000;

    BoundedParameterHarness internal harness = new BoundedParameterHarness();

    function test_InitialAcceptsValueWithinCeiling() public view {
        assertEq(harness.initial(1, CEILING), 1);
        assertEq(harness.initial(CEILING, CEILING), CEILING);
    }

    function test_InitialRejectsZero() public {
        vm.expectRevert(BoundedParameter.ParameterZero.selector);
        harness.initial(0, CEILING);
        vm.expectRevert(BoundedParameter.ParameterZero.selector);
        harness.initial(1, 0);
    }

    function test_InitialRejectsAboveCeiling() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BoundedParameter.ParameterAboveCeiling.selector, CEILING + 1, CEILING
            )
        );
        harness.initial(CEILING + 1, CEILING);
    }

    function test_RaiseAcceptsExactDoubleAndExactCeiling() public view {
        assertEq(harness.raise(100, 200, CEILING), 200);
        assertEq(harness.raise(100, 101, CEILING), 101);
        assertEq(harness.raise(CEILING - 1, CEILING, CEILING), CEILING);
    }

    function test_RaiseRejectsEqualOrLower() public {
        vm.expectRevert(
            abi.encodeWithSelector(BoundedParameter.ParameterNotRaised.selector, 100, 100)
        );
        harness.raise(100, 100, CEILING);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedParameter.ParameterNotRaised.selector, 100, 99)
        );
        harness.raise(100, 99, CEILING);
    }

    function test_RaiseRejectsMoreThanDouble() public {
        vm.expectRevert(
            abi.encodeWithSelector(BoundedParameter.ParameterStepTooLarge.selector, 100, 201)
        );
        harness.raise(100, 201, CEILING);
    }

    function test_RaiseFromZeroIsImpossible() public {
        vm.expectRevert(
            abi.encodeWithSelector(BoundedParameter.ParameterStepTooLarge.selector, 0, 1)
        );
        harness.raise(0, 1, CEILING);
    }

    function test_RaiseRejectsAboveCeiling() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BoundedParameter.ParameterAboveCeiling.selector, CEILING + 1, CEILING
            )
        );
        harness.raise(CEILING, CEILING + 1, CEILING);
    }

    function test_RaiseNearUint256MaxDoesNotOverflow() public view {
        uint256 max = type(uint256).max;
        assertEq(harness.raise(max - 1, max, max), max);
        assertEq(harness.raise(max / 2 + 1, max, max), max);
    }

    /// The rule is exactly: current < proposed <= min(2 * current, ceiling).
    function testFuzz_RaiseMatchesSpecification(uint256 current, uint256 proposed, uint256 ceiling)
        public
        view
    {
        bool ok = proposed > current && proposed <= ceiling && proposed - current <= current;
        try harness.raise(current, proposed, ceiling) returns (uint256 result) {
            assertTrue(ok, "accepted an invalid raise");
            assertEq(result, proposed);
        } catch {
            assertFalse(ok, "rejected a valid raise");
        }
    }

    /// Any sequence of accepted raises stays within the ceiling and at most doubles per step.
    function testFuzz_RaiseSequenceStaysBounded(uint64 start, uint256[8] memory steps) public view {
        uint256 value = harness.initial(bound(start, 1, CEILING), CEILING);
        for (uint256 i; i < steps.length; ++i) {
            uint256 proposed = bound(steps[i], value, 3 * value);
            try harness.raise(value, proposed, CEILING) returns (uint256 next) {
                assertLe(next, CEILING);
                assertLe(next, 2 * value);
                assertGt(next, value);
                value = next;
            } catch { }
        }
        assertLe(value, CEILING);
    }
}
