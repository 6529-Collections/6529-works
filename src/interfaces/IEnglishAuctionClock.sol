// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "./IEnglishAuction.sol";

/// @title IEnglishAuctionClock
/// @notice An integration view of the English auction, for contracts that read an auction on
///         their own hot paths: its derived state and end, answered by the auction itself
///         rather than through its lens. Not part of `IEnglishAuction`, and not reported through
///         ERC-165: `IEnglishAuction`'s interface ID is unchanged by it.
interface IEnglishAuctionClock {
    /// @notice An auction's derived state and end, exactly as `IEnglishAuction.auction` reports
    ///         them. Reverts with `ISaleAdapter.UnknownSale` for a sale ID with no sale.
    /// @param saleId The auction's sale ID.
    /// @return state The derived state (`auction(saleId).state`).
    /// @return endTime The end (`auction(saleId).endTime`): for a dispute pause past
    ///         `MAX_PAUSE`, the end it resumes to.
    function auctionClock(uint256 saleId)
        external
        view
        returns (IEnglishAuction.AuctionState state, uint64 endTime);
}
