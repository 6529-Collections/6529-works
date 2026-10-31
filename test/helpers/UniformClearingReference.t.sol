// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { UniformClearingReference as Ref } from "./UniformClearingReference.sol";

/// @notice The oracle itself, against the worked examples of the edition auction's design
///         (the owner's figures, the same bids on the default ladder, a cap of 60 with a raise
///         hole at the cut step) and small hand-checked books.
contract UniformClearingReferenceTest is Test {
    /// @dev The owner's figures, in milli-ETH: 200 units at 10, 50 at 50, 20 at 100, 9 at 200
    ///      and 1 at 1,000, so 1, 10, 30, 80 and 280 units at or above each price.
    function _ownerBook() internal pure returns (uint256[] memory units, uint256[] memory prices) {
        units = new uint256[](5);
        prices = new uint256[](5);
        (units[0], units[1], units[2], units[3], units[4]) = (200, 50, 20, 9, 1);
        (prices[0], prices[1], prices[2], prices[3], prices[4]) = (10, 50, 100, 200, 1000);
    }

    function test_Clear_TheOwnersExampleSells80AtTheFifthStep() public pure {
        (uint256[] memory units, uint256[] memory prices) = _ownerBook();
        (uint256 k, uint256 price, uint256 best) = Ref.clear(units, prices, 0, 10_000);
        assertEq(k, 80);
        assertEq(price, 50);
        assertEq(best, 4000);
    }

    function test_Clear_AWiderMarginTakesMoreEditionsAtALowerPrice() public pure {
        (uint256[] memory units, uint256[] memory prices) = _ownerBook();
        (uint256 k, uint256 price,) = Ref.clear(units, prices, 0, 30_000);
        assertEq(k, 280);
        assertEq(price, 10);
        (k, price,) = Ref.clear(units, prices, 0, 0);
        assertEq(k, 80);
        assertEq(price, 50);
    }

    /// @dev The same bids snapped to the default ladder (steps 96, 130, 144, 158 and 192).
    function _ladderBook(uint256 extraAt0464)
        internal
        pure
        returns (uint256[] memory units, uint256[] memory prices)
    {
        units = new uint256[](6);
        prices = new uint256[](6);
        (units[0], units[1], units[2], units[3], units[4], units[5]) =
            (200, extraAt0464, 50, 20, 9, 1);
        (prices[0], prices[1], prices[2], prices[3], prices[4], prices[5]) = (
            0.01 ether,
            0.0464 ether,
            0.0511 ether,
            0.1 ether,
            0.196 ether,
            1 ether
        );
    }

    function test_Clear_OnTheLadderSells80At0511AndOneMoreUnitTiltsTo81At0464() public pure {
        (uint256[] memory units, uint256[] memory prices) = _ladderBook(0);
        (uint256 k, uint256 price, uint256 best) = Ref.clear(units, prices, 0, 10_000);
        assertEq(k, 80);
        assertEq(price, 0.0511 ether);
        assertEq(best, 4.088 ether);
        (units, prices) = _ladderBook(1);
        (k, price,) = Ref.clear(units, prices, 0, 10_000);
        assertEq(k, 81);
        assertEq(price, 0.0464 ether);
    }

    function test_Clear_ACapOf60StopsInsideTheStep() public pure {
        (uint256[] memory units, uint256[] memory prices) = _ladderBook(0);
        (uint256 k, uint256 price, uint256 best) = Ref.clear(units, prices, 60, 10_000);
        assertEq(k, 60);
        assertEq(price, 0.0511 ether);
        assertEq(best, 3.066 ether);
    }

    function test_Clear_AnEmptyBookSellsNothing() public pure {
        uint256[] memory units = new uint256[](2);
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (1, 2);
        (uint256 k, uint256 price, uint256 best) = Ref.clear(units, prices, 0, 10_000);
        assertEq(k, 0);
        assertEq(price, 0);
        assertEq(best, 0);
    }

    /// @dev Trace 3: B1 20 at position 0, B2's 15 raised away (a hole at 20), B3 10 at 35 and
    ///      B4 20 at 45; the step wins 30 units: B1 20, B3 10, B4 0.
    function test_FillInArrivalOrder_ARaiseHoleDoesNotStrandUnits() public pure {
        uint256[] memory positions = new uint256[](3);
        uint256[] memory quantities = new uint256[](3);
        (positions[0], positions[1], positions[2]) = (45, 0, 35);
        (quantities[0], quantities[1], quantities[2]) = (20, 20, 10);
        uint256[] memory filled = Ref.fillInArrivalOrder(positions, quantities, 30);
        assertEq(filled[0], 0);
        assertEq(filled[1], 20);
        assertEq(filled[2], 10);
        filled = Ref.fillInArrivalOrder(positions, quantities, 35);
        assertEq(filled[0], 5);
        assertEq(filled[1], 20);
        assertEq(filled[2], 10);
    }
}
