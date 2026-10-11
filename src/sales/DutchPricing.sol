// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title DutchPricing
/// @notice The descending-price schedule of the shared Dutch adapter (ADR 0001 section 5), ported
///         from PR #744's `StreamDutchPricing` and reduced to the `DutchParams` shape: the price
///         starts at the package price and falls to `restingPrice` over `duration` seconds,
///         linearly or in equal drops every `stepSeconds`, then rests there.
/// @dev Internal functions only, so nothing here is linked. The reduction is rounded down, so a
///      price is never below the exact curve, and `mulDiv` keeps every input overflow-free.
///      The schedule is non-increasing in time, never above the start or below the resting price.
library DutchPricing {
    /// @notice Whether a schedule can be sold: the resting price is at most the start, a price
    ///         that falls needs a duration, and stepped drops divide the duration evenly.
    function isValid(uint256 startPrice, uint256 restingPrice, uint64 duration, uint64 stepSeconds)
        internal
        pure
        returns (bool)
    {
        if (restingPrice > startPrice) return false;
        if (restingPrice != startPrice && duration == 0) return false;
        return stepSeconds == 0 || duration % stepSeconds == 0;
    }

    /// @notice The unit price at `timestamp` of a schedule accepted by {isValid}.
    /// @dev The start price until `startTime`, the resting price from `startTime + duration`.
    function priceAt(
        uint256 startPrice,
        uint256 restingPrice,
        uint256 startTime,
        uint256 duration,
        uint256 stepSeconds,
        uint256 timestamp
    ) internal pure returns (uint256) {
        if (timestamp <= startTime) return startPrice;
        uint256 elapsed = timestamp - startTime;
        if (elapsed >= duration) return restingPrice;
        if (stepSeconds != 0) elapsed -= elapsed % stepSeconds;
        return startPrice - Math.mulDiv(startPrice - restingPrice, elapsed, duration);
    }
}
