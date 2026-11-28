// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title AgedCredits
/// @notice The one rule both auctions (the English auction and the edition auctions) use for
///         credits nobody claims: only money that has itself waited the unclaimed period can go
///         to the network, and nobody but the account's own claim changes when that happens.
/// @dev One storage word per account. `total` is everything the account may claim. `aged` is
///      the part that has been waiting since `since`; every wei of it arrived no later than
///      `since`. The rule, in full:
///      - a credit to an account with nothing starts a wait for that amount (`aged = total`,
///        `since` = now);
///      - a credit while a wait runs joins `total` only: it neither shortens nor postpones the
///        running wait, and it is never part of the amount that wait covers;
///      - once the period has passed since `since`, anyone may send `aged` (and nothing else)
///        to the network; what is left starts a new wait from that moment, so it too waits at
///        least the period from its own arrival;
///      - the account's own claim takes `total` and clears the word.
///      The period is passed in by the caller and read when the expiry is attempted (the
///      directory's `unclaimedPeriod`, a setting of the network), so a change of the period
///      applies to waits already running. Internal functions only: each auction keeps its own
///      errors and events.
library AgedCredits {
    /// @notice An account's credit, one storage word.
    /// @param total Everything the account may claim, in wei.
    /// @param aged The part that has been waiting since `since`.
    /// @param since When the waiting part started to wait; zero when `total` is zero.
    struct Credit {
        uint104 total;
        uint104 aged;
        uint48 since;
    }

    /// @notice Adds `amount` to `c` under the rule above.
    /// @param c The account's credit.
    /// @param amount The amount credited, in wei.
    function add(Credit storage c, uint256 amount) internal {
        if (c.total == 0) {
            uint104 a = SafeCast.toUint104(amount);
            (c.total, c.aged, c.since) = (a, a, SafeCast.toUint48(block.timestamp));
        } else {
            c.total = SafeCast.toUint104(uint256(c.total) + amount);
        }
    }

    /// @notice Clears `c` for the account's own claim.
    /// @param c The account's credit.
    /// @return amount Everything the account could claim.
    function takeAll(Credit storage c) internal returns (uint256 amount) {
        amount = c.total;
        delete c.total;
        delete c.aged;
        delete c.since;
    }

    /// @notice When the waiting part of `c` may go to the network under `period`; zero when
    ///         nothing is credited.
    /// @param c The account's credit.
    /// @param period The unclaimed period in force, in seconds.
    /// @return The time, in seconds since the epoch.
    function dueAt(Credit storage c, uint256 period) internal view returns (uint256) {
        return c.total == 0 ? 0 : uint256(c.since) + period;
    }

    /// @notice Removes the waiting part of `c`, which must be due (`dueAt` not after now, with a
    ///         nonzero total: the caller checks and reverts with its own error); what is left
    ///         starts a new wait now.
    /// @param c The account's credit.
    /// @return amount The amount that waited the period, in wei.
    function expireAged(Credit storage c) internal returns (uint256 amount) {
        amount = c.aged;
        uint104 rest = c.total - c.aged;
        (c.total, c.aged, c.since) =
        (rest, rest, rest == 0 ? 0 : SafeCast.toUint48(block.timestamp));
    }
}
