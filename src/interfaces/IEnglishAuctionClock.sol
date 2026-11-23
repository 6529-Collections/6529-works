// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IEnglishAuction } from "./IEnglishAuction.sol";

/// @title IEnglishAuctionClock
/// @notice An integration view of the English auction, for contracts that read an auction on
///         their own hot paths: its derived state, end and dispute-pause start, and when the work
///         was last offered again, answered by the auction itself rather than through its lens.
///         Not part of `IEnglishAuction`, and not reported through ERC-165: `IEnglishAuction`'s
///         interface ID is unchanged by it. This interface's own ID is `auctionClock(uint256)`'s
///         selector, which return values do not change.
interface IEnglishAuctionClock {
    /// @notice An auction's derived state, end and pause start, exactly as
    ///         `IEnglishAuction.auction` reports them, and when its work was last offered again.
    ///         Reverts with `IEnglishAuction.UnknownSale` for a sale ID with no sale.
    /// @dev A sale ID names a work, so a work offered again (`IEnglishAuction.restart`) answers
    ///      under the same ID with a new end. `restartedAt` lets a contract that followed the
    ///      earlier sale tell: a restart is accepted only from 15 minutes after that sale's end,
    ///      once it is settled without a sale or closed after a refused settlement. So a
    ///      `restartedAt` later than the moment the follower began to follow means the sale it
    ///      followed is over, whatever the state and end read now.
    /// @param saleId The auction's sale ID.
    /// @return state The derived state (`auction(saleId).state`).
    /// @return endTime The end (`auction(saleId).endTime`): for a dispute pause past
    ///         `MAX_PAUSE`, the end it resumes to.
    /// @return pausedAt When its dispute pause began (`auction(saleId).pausedAt`): zero if it
    ///         was never paused, after `resume`, and once a pause has run past `MAX_PAUSE`.
    /// @return restartedAt When the work was last offered again (`IEnglishAuction.restart`):
    ///         zero if it never was.
    function auctionClock(uint256 saleId)
        external
        view
        returns (
            IEnglishAuction.AuctionState state,
            uint64 endTime,
            uint64 pausedAt,
            uint64 restartedAt
        );
}
