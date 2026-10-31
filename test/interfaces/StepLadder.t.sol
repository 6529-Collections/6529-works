// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StepLadder } from "../../src/interfaces/types/StepLadder.sol";

/// @dev Exposes the library's reverts as external calls.
contract StepLadderHarness {
    function mantissa(uint256 j) external pure returns (uint256) {
        return StepLadder.mantissa(j);
    }

    function price(uint256 basePrice, uint256 stepsPerDecade, uint256 step)
        external
        pure
        returns (uint256)
    {
        return StepLadder.price(basePrice, stepsPerDecade, step);
    }
}

/// @notice Pins the edition auction's step ladder (ADR 0005) to the golden vector that
///         `tools/edition_auction_ref.py` generates (`test/fixtures/edition-auction/ladder.json`),
///         and to a few explicit prices, so the contract, the reference model and every client
///         price a step identically.
contract StepLadderTest is Test {
    string internal constant VECTOR = "test/fixtures/edition-auction/ladder.json";
    uint256 internal constant BASE = 1e14;
    StepLadderHarness internal harness;
    string internal json;

    function setUp() public {
        harness = new StepLadderHarness();
        json = vm.readFile(VECTOR);
    }

    function test_MantissasMatchTheGoldenVector() public view {
        uint256[] memory expected = vm.parseJsonUintArray(json, ".mantissas");
        assertEq(expected.length, StepLadder.MANTISSAS);
        for (uint256 j; j < expected.length; ++j) {
            assertEq(StepLadder.mantissa(j), expected[j], vm.toString(j));
        }
    }

    function test_DefaultLadderMatchesTheGoldenVector() public view {
        assertEq(vm.parseJsonUint(json, ".default.basePrice"), StepLadder.DEFAULT_BASE_PRICE);
        assertEq(
            vm.parseJsonUint(json, ".default.stepsPerDecade"), StepLadder.DEFAULT_STEPS_PER_DECADE
        );
        assertEq(vm.parseJsonUint(json, ".default.stepCount"), StepLadder.DEFAULT_STEP_COUNT);
        uint256[] memory expected = vm.parseJsonUintArray(json, ".prices");
        assertEq(expected.length, StepLadder.DEFAULT_STEP_COUNT);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(StepLadder.price(BASE, 48, i), expected[i], vm.toString(i));
        }
    }

    function test_OtherLaddersMatchTheGoldenVector() public view {
        uint256[4] memory ladders = [uint256(24), 48, 96, 192];
        for (uint256 l; l < ladders.length; ++l) {
            uint256 n = ladders[l];
            string memory key = string.concat(".ladders.", vm.toString(n));
            uint256[] memory mantissas =
                vm.parseJsonUintArray(json, string.concat(key, ".mantissas"));
            assertEq(mantissas.length, n);
            for (uint256 i; i < n; ++i) {
                assertEq(StepLadder.price(100, n, i), mantissas[i]);
            }
            uint256[] memory first = vm.parseJsonUintArray(json, string.concat(key, ".first"));
            for (uint256 i; i < first.length; ++i) {
                assertEq(StepLadder.price(BASE, n, i), first[i]);
            }
            uint256 toOneEth = vm.parseJsonUint(json, string.concat(key, ".stepsToOneEth"));
            assertGe(StepLadder.price(BASE, n, toOneEth), 1 ether);
            assertLt(StepLadder.price(BASE, n, toOneEth - 1), 1 ether);
        }
    }

    function test_BoundsMatchTheGoldenVector() public view {
        uint256 i;
        for (; vm.keyExistsJson(json, string.concat(".bounds[", vm.toString(i), "]")); ++i) {
            string memory key = string.concat(".bounds[", vm.toString(i), "]");
            assertEq(
                StepLadder.isValid(
                    vm.parseJsonUint(json, string.concat(key, ".basePrice")),
                    vm.parseJsonUint(json, string.concat(key, ".stepsPerDecade")),
                    vm.parseJsonUint(json, string.concat(key, ".stepCount"))
                ),
                vm.parseJsonBool(json, string.concat(key, ".valid")),
                key
            );
        }
        assertGt(i, 0);
    }

    /// @dev The readable prices the plan and the UX brief quote, pinned in code too.
    function test_PinnedPrices() public pure {
        uint256[5] memory first =
            [uint256(0.0001 ether), 0.000105 ether, 0.00011 ether, 0.000115 ether, 0.000121 ether];
        for (uint256 i; i < first.length; ++i) {
            assertEq(StepLadder.price(BASE, 48, i), first[i]);
        }
        uint256[5] memory last = [uint256(787 ether), 825 ether, 866 ether, 909 ether, 953 ether];
        for (uint256 i; i < last.length; ++i) {
            assertEq(StepLadder.price(BASE, 48, 331 + i), last[i]);
        }
        assertEq(StepLadder.price(BASE, 48, 96), 0.01 ether);
        assertEq(StepLadder.price(BASE, 48, 127), 0.0442 ether);
        assertEq(StepLadder.price(BASE, 48, 128), 0.0464 ether);
        assertEq(StepLadder.price(BASE, 48, 129), 0.0487 ether);
        assertEq(StepLadder.price(BASE, 48, 130), 0.0511 ether);
        assertEq(StepLadder.price(BASE, 48, 144), 0.1 ether);
        assertEq(StepLadder.price(BASE, 48, 158), 0.196 ether);
        assertEq(StepLadder.price(BASE, 48, 192), 1 ether);
    }

    /// @dev Every allowed ladder strictly rises over the longest ladder allowed, and every
    ///      coarser ladder is a subset of every finer one.
    function test_EveryLadderRisesAndNests() public pure {
        uint256[4] memory ladders = [uint256(24), 48, 96, 192];
        for (uint256 l; l < ladders.length; ++l) {
            uint256 n = ladders[l];
            uint256 previous;
            for (uint256 i; i < StepLadder.MAX_STEP_COUNT; ++i) {
                uint256 p = StepLadder.price(BASE, n, i);
                assertGt(p, previous);
                previous = p;
                assertEq(p, StepLadder.price(BASE, 192, i * (192 / n)));
            }
        }
    }

    function test_DefaultsAreValid() public pure {
        assertTrue(
            StepLadder.isValid(
                StepLadder.DEFAULT_BASE_PRICE,
                StepLadder.DEFAULT_STEPS_PER_DECADE,
                StepLadder.DEFAULT_STEP_COUNT
            )
        );
        assertTrue(StepLadder.isStepsPerDecade(24));
        assertFalse(StepLadder.isStepsPerDecade(12));
        assertFalse(StepLadder.isStepsPerDecade(0));
        assertFalse(StepLadder.isStepsPerDecade(384));
    }

    /// @dev Every power of ten from 10^12 to 10^17 wei is a base price governance may set, on
    ///      the 512-step default ladder (whose top step is at least 10 ETH from 10^12 up); the
    ///      powers of ten just outside are not.
    function test_IsValid_AcceptsEveryPowerOfTen() public pure {
        uint256 p = StepLadder.MIN_BASE_PRICE;
        for (uint256 k; k < 6; ++k) {
            assertTrue(StepLadder.isBasePrice(p));
            assertTrue(StepLadder.isValid(p, 48, StepLadder.MAX_STEP_COUNT));
            p *= 10;
        }
        assertEq(p, StepLadder.MAX_BASE_PRICE * 10);
        assertFalse(StepLadder.isBasePrice(1e11));
        assertFalse(StepLadder.isValid(1e11, 24, StepLadder.MAX_STEP_COUNT));
        assertFalse(StepLadder.isBasePrice(1e18));
        assertFalse(StepLadder.isValid(1e18, 48, StepLadder.DEFAULT_STEP_COUNT));
    }

    /// @dev A base price in range that is not a power of ten is refused, though its ladder
    ///      passes every other bound (ADR 0005 decision 3: readable prices from a fixed table).
    function test_IsValid_RefusesABaseThatIsNotAPowerOfTen() public pure {
        uint256[8] memory bases =
            [uint256(1e12 + 1), 2e12, 15e13, 1e14 + 1, 1e14 + 100, 5e14, 3e16, 1e17 - 1];
        for (uint256 i; i < bases.length; ++i) {
            assertGe(StepLadder.price(bases[i], 48, StepLadder.MAX_STEP_COUNT - 1), 10 ether);
            assertFalse(StepLadder.isBasePrice(bases[i]));
            assertFalse(StepLadder.isValid(bases[i], 48, StepLadder.MAX_STEP_COUNT));
        }
    }

    /// @dev `isBasePrice` against its definition: a power of ten, 10^12 to 10^17.
    function testFuzz_IsBasePrice_IsAPowerOfTenInRange(uint256 base) public pure {
        uint256 rest = base;
        uint256 k;
        while (rest != 0 && rest % 10 == 0) {
            rest /= 10;
            ++k;
        }
        assertEq(StepLadder.isBasePrice(base), rest == 1 && k >= 12 && k <= 17);
    }

    function test_MantissaIndexOutOfRangeReverts() public {
        assertEq(harness.mantissa(191), 988);
        vm.expectRevert(abi.encodeWithSelector(StepLadder.MantissaIndexOutOfRange.selector, 192));
        harness.mantissa(192);
    }

    /// @dev A decade up is exactly ten times the price, a step up is 4% to 26% more (the
    ///      coarsest ladder's widest gap), and step 0 is the base price.
    function testFuzz_DecadesAndSteps(uint256 base, uint8 ladder, uint16 step) public pure {
        base = bound(base, StepLadder.MIN_BASE_PRICE, StepLadder.MAX_BASE_PRICE);
        base -= base % 100;
        uint256 n = [uint256(24), 48, 96, 192][ladder % 4];
        uint256 i = bound(step, 0, StepLadder.MAX_STEP_COUNT - 1);
        uint256 p = StepLadder.price(base, n, i);
        assertEq(StepLadder.price(base, n, i + n), 10 * p);
        assertGt(StepLadder.price(base, n, i + 1), p);
        assertLe(StepLadder.price(base, n, i + 1) * 100, p * 126);
        assertEq(StepLadder.price(base, n, 0), base);
    }
}
