// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title EscrowLots
/// @notice A reference model of the escrow's expiry rule (R12, ECO-45), written per credited lot
///         instead of in the escrow's three parts, so a test compares two independent
///         formulations. A lot is one credit (a deposit, or a recovery to the account), with its
///         amount, its block time and its window. A credit joins the latest window while that
///         window still holds lots and is younger than 180 days, and opens a new one otherwise.
///         A window's lots may expire from 180 days after its last lot. Flushes and recoveries
///         take every lot; an expiry takes the matured windows, which are always the oldest.
library EscrowLots {
    uint256 internal constant PERIOD = 180 days;

    struct Book {
        uint256[] amount;
        uint256[] at;
        uint256[] window;
        uint256[] openedAt;
        uint256[] lastAt;
        uint256 head;
    }

    /// @dev Records a credit of `amount` at `nowAt`.
    function credit(Book storage b, uint256 amount, uint256 nowAt) internal {
        uint256 w = b.openedAt.length;
        bool open = b.head < b.amount.length && nowAt < b.openedAt[w - 1] + PERIOD;
        if (open) {
            b.lastAt[w - 1] = nowAt;
        } else {
            b.openedAt.push(nowAt);
            b.lastAt.push(nowAt);
            ++w;
        }
        b.amount.push(amount);
        b.at.push(nowAt);
        b.window.push(w - 1);
    }

    /// @dev Every lot still held.
    function total(Book storage b) internal view returns (uint256 sum) {
        for (uint256 i = b.head; i < b.amount.length; ++i) {
            sum += b.amount[i];
        }
    }

    /// @dev What may expire at `t` if nothing else happens first.
    function expirable(Book storage b, uint256 t) internal view returns (uint256 sum) {
        for (uint256 i = b.head; i < b.amount.length; ++i) {
            if (b.lastAt[b.window[i]] + PERIOD <= t) sum += b.amount[i];
        }
    }

    /// @dev When the oldest held lot may expire, or zero when nothing is held.
    function nextDue(Book storage b) internal view returns (uint256) {
        if (b.head == b.amount.length) return 0;
        return b.lastAt[b.window[b.head]] + PERIOD;
    }

    /// @dev Takes what may expire at `t`; it must be a prefix of the held lots.
    function expire(Book storage b, uint256 t) internal returns (uint256 amount) {
        uint256 i = b.head;
        while (i < b.amount.length && b.lastAt[b.window[i]] + PERIOD <= t) {
            amount += b.amount[i];
            ++i;
        }
        b.head = i;
        require(expirable(b, t) == 0, "model: matured lots are not the oldest");
    }

    /// @dev Takes every held lot (a flush or a recovery).
    function takeAll(Book storage b) internal returns (uint256 amount) {
        amount = total(b);
        b.head = b.amount.length;
    }

    /// @dev The held lots credited at least `age` before `t`.
    function olderThan(Book storage b, uint256 t, uint256 age) internal view returns (uint256 sum) {
        for (uint256 i = b.head; i < b.amount.length; ++i) {
            if (b.at[i] + age <= t) sum += b.amount[i];
        }
    }
}
