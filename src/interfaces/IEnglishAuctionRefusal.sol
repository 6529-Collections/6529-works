// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEnglishAuctionRefusal
/// @notice The English auction's exit for a sale whose token will not let it settle (AUC-45 to
///         AUC-48). The settlement is attempted in full, in a frame given exactly the governed
///         refusal gas (`IEnglishAuction.AuctionConfig.refusalGas`); only if that attempt fails,
///         and no earlier than the sale's end plus its refusal delay, does the sale close with the
///         standing bid credited back and the work left for its artist to claim. Federated sales
///         only: a listed token's sale, 6529 Stream's included, settles only through `settle`. A
///         token that settles is never affected: the attempt then settles the sale exactly as
///         `IEnglishAuction.settle` does. Not part of `IEnglishAuction`, and not reported through
///         ERC-165: `IEnglishAuction`'s interface ID is unchanged by it.
interface IEnglishAuctionRefusal {
    /// @notice A sale's settlement failed although it was given the refusal gas in full, at
    ///         least the refusal delay after its end. Every effect of the attempt was undone, the
    ///         token's included: nothing was reported to the token, paid or delivered; the
    ///         standing bid, if any, was credited back to its bidder (`Credited`); and the work
    ///         stays in the auction's custody as a pending delivery that its artist, the creator
    ///         the token reports (`IMintTarget.primaryTerms`), may claim to any address with
    ///         `claimDelivery`. The auction is SETTLED.
    /// @param saleId The auction's sale ID.
    event SettlementRefused(uint256 indexed saleId);

    /// @notice Only a federated sale may close as refused: a listed token's sale, 6529 Stream's
    ///         included, settles only through `IEnglishAuction.settle`.
    /// @param saleId The auction's sale ID.
    error SaleNotRefusable(uint256 saleId);
    /// @notice A refused settlement may not close the sale before `allowedAt`.
    /// @param saleId The auction's sale ID.
    /// @param allowedAt The sale's end plus its refusal delay.
    error RefusalTooEarly(uint256 saleId, uint256 allowedAt);

    /// @notice Settles an ended federated sale, or closes it with refunds if its token refuses.
    ///         A listed token's sale is refused (`SaleNotRefusable`). Permissionless, from the
    ///         sale's end plus the refusal delay it locked at start (`RefusalTooEarly` before),
    ///         and not while its currency is frozen short of the freeze exit
    ///         (`AssetNotActive`), nor inside a guarded call of the auction or of its escrow
    ///         (`ReentrancyGuardReentrantCall`). It calls `IEnglishAuction.settle` on the auction
    ///         itself with exactly the refusal gas, which the caller must be able to forward in
    ///         full (`BoundedCall.BoundedCallInsufficientGas`). If that call succeeds, the sale
    ///         settled, or reopened after a late re-admission, exactly as `settle` would have. If
    ///         it fails for any reason, the sale closes as refused (`SettlementRefused`).
    /// @param saleId The ended auction's sale ID.
    function settleOrRefund(uint256 saleId) external;

    /// @notice When a refused settlement may first close a federated sale: its end plus the
    ///         refusal delay it locked at start (answered by the auction's lens; a listed token's
    ///         sale reverts with `SaleNotRefusable`). A dispute pause that ran its course moves
    ///         the end as `IEnglishAuction.auction` reports it.
    /// @param saleId The auction's sale ID; reverts with `ISaleAdapter.UnknownSale` for none.
    /// @return The first second at which `settleOrRefund` may close the sale as refused.
    function refusableAt(uint256 saleId) external view returns (uint256);
}
