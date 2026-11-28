// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @title IEnglishAuctionRefusal
/// @notice The English auction's exit for an Independent Stream sale whose token will not let it
///         settle. The settlement is attempted in full, in a frame given exactly the governed
///         refusal gas (`IEnglishAuction.AuctionConfig.refusalGas`); only if that attempt fails,
///         and no earlier than 2 days after the sale's end, does the sale close with the standing
///         bid credited back and the work left in the auction's custody, where anyone may offer it
///         again (`IEnglishAuction.restart`). 6529 Stream's sales settle only through `settle`. Not
///         part of `IEnglishAuction`, and not reported through ERC-165.
interface IEnglishAuctionRefusal {
    /// @notice A sale's settlement failed although it was given the refusal gas in full, at
    ///         least 2 days after its end. Every effect of the attempt was undone, the token's
    ///         included: nothing was recorded, paid or delivered; the standing bid, if any, was
    ///         credited back to its bidder (`Credited`); the work stays in the auction's custody
    ///         with no outcome, and may be offered again. The auction is SETTLED.
    /// @param saleId The auction's sale ID.
    event SettlementRefused(uint256 indexed saleId);

    /// @notice Only an Independent Stream sale may close as refused.
    /// @param saleId The auction's sale ID.
    error SaleNotRefusable(uint256 saleId);
    /// @notice A refused settlement may not close the sale before `allowedAt`.
    /// @param saleId The auction's sale ID.
    /// @param allowedAt The sale's end plus 2 days.
    error RefusalTooEarly(uint256 saleId, uint256 allowedAt);

    /// @notice Settles an ended Independent Stream sale, or closes it with refunds if its token
    ///         refuses. A 6529 Stream sale is refused (`SaleNotRefusable`). Permissionless, from
    ///         the sale's end plus 2 days (`RefusalTooEarly` before), and not inside a guarded call
    ///         of the auction or of its escrow (`ReentrancyGuardReentrantCall`). It calls
    ///         `IEnglishAuction.settle` on the auction itself with exactly the refusal gas, which
    ///         the caller must be able to forward in full
    ///         (`BoundedCall.BoundedCallInsufficientGas`). If that call succeeds, the sale settled
    ///         exactly as `settle` would have. If it fails for any reason, the sale closes as
    ///         refused (`SettlementRefused`).
    /// @param saleId The ended auction's sale ID.
    function settleOrRefund(uint256 saleId) external;

    /// @notice When a refused settlement may first close an Independent Stream sale: its end plus 2
    ///         days. A 6529 Stream sale reverts with `SaleNotRefusable`. A dispute pause that ran
    ///         its course moves the end as `IEnglishAuction.auction` reports it.
    /// @param saleId The auction's sale ID; reverts with `IEnglishAuction.UnknownSale` for none.
    /// @return The first second at which `settleOrRefund` may close the sale as refused.
    function refusableAt(uint256 saleId) external view returns (uint256);
}
