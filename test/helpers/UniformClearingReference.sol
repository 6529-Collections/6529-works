// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The edition auction's clearing (D138) and its cut-step allocation, computed the slow,
///         obvious way, as an oracle for the contract's one-pass clearing and FIFO sweep.
/// @dev Nothing here shares code with `src/`. The clearing expands every bid into unit bids,
///      orders them by price from the highest, and scans every count `k`:
///      `revenue(k) = k x P(k)`, where `P(k)` is the k-th highest unit price; `R*` is the
///      highest revenue at any `k` up to the cap; the result is the LARGEST `k` whose revenue
///      is at least `(10,000 - marginBps) / 10,000` of `R*`, at price `P(k)`. The allocation at
///      the cut step fills the units the step wins in arrival order (lowest position first),
///      the last filled bid partly. Both are quadratic or worse and meant for small books.
library UniformClearingReference {
    uint256 internal constant BPS = 10_000;

    /// @notice The clearing of a book given as live units per step.
    /// @param units Live units at each step, lowest step first.
    /// @param prices The price of each step, strictly increasing.
    /// @param cap The creator's cap on the count; zero for none.
    /// @param marginBps The breadth margin, out of 10,000.
    /// @return k The number of editions sold (zero for an empty book).
    /// @return price The clearing price `P(k)` (zero when `k` is zero).
    /// @return best `R*`, the highest revenue at any count up to the cap.
    function clear(uint256[] memory units, uint256[] memory prices, uint256 cap, uint256 marginBps)
        internal
        pure
        returns (uint256 k, uint256 price, uint256 best)
    {
        uint256[] memory unitPrices = expand(units, prices, cap);
        uint256 n = unitPrices.length;
        for (uint256 i; i < n; ++i) {
            uint256 revenue = (i + 1) * unitPrices[i];
            if (revenue > best) best = revenue;
        }
        for (uint256 i = n; i > 0; --i) {
            if (i * unitPrices[i - 1] * BPS >= best * (BPS - marginBps)) {
                return (i, unitPrices[i - 1], best);
            }
        }
    }

    /// @notice Every unit bid's price, highest first, cut at `cap` units when `cap` is nonzero.
    function expand(uint256[] memory units, uint256[] memory prices, uint256 cap)
        internal
        pure
        returns (uint256[] memory out)
    {
        require(units.length == prices.length, "reference: lengths");
        for (uint256 i = 1; i < prices.length; ++i) {
            require(prices[i - 1] < prices[i], "reference: prices must increase");
        }
        uint256 total;
        for (uint256 i; i < units.length; ++i) {
            total += units[i];
        }
        if (cap != 0 && total > cap) total = cap;
        out = new uint256[](total);
        uint256 n;
        for (uint256 i = units.length; i > 0 && n < total; --i) {
            for (uint256 u; u < units[i - 1] && n < total; ++u) {
                out[n++] = prices[i - 1];
            }
        }
    }

    /// @notice The units each bid at the cut step wins: `won` units of the step, filled in
    ///         position order, each bid up to its quantity.
    /// @param positions Each live bid's queue position at the step (entered units before it).
    /// @param quantities Each live bid's quantity.
    /// @param won How many units the step wins.
    /// @return filled The units each bid wins, in the order given.
    function fillInArrivalOrder(
        uint256[] memory positions,
        uint256[] memory quantities,
        uint256 won
    ) internal pure returns (uint256[] memory filled) {
        uint256 n = positions.length;
        require(quantities.length == n, "reference: lengths");
        filled = new uint256[](n);
        bool[] memory done = new bool[](n);
        for (uint256 round; round < n && won != 0; ++round) {
            uint256 next = type(uint256).max;
            for (uint256 i; i < n; ++i) {
                if (!done[i] && (next == type(uint256).max || positions[i] < positions[next])) {
                    next = i;
                }
            }
            done[next] = true;
            uint256 take = quantities[next] < won ? quantities[next] : won;
            filled[next] = take;
            won -= take;
        }
    }
}
