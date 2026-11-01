// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "./IEnglishAuction.sol";
import { IUniformEditionAuction } from "./IUniformEditionAuction.sol";

/// @title IUniformEditionAuctionLens
/// @notice The read side of the uniform-price edition auction: every view of a sale, computed
///         from the adapter's storage words (`IUniformEditionAuctionStorage.storageWord`) with the
///         clearing code its settlement runs (`UniformClearing`), and the master check the
///         adapter's `open` consults. Stateless and bound to no adapter: deployed in its own
///         transaction and pinned by the adapter's constructor (`IUniformEditionAuctionStorage.lens`),
///         it reads every sale from its caller, the adapter, which forwards its own views here,
///         so each view below has the signature `IUniformEditionAuction` gives it. Errors are
///         the adapter's.
/// @dev Views that depend on the 1/1 read it live: `masterTerms` (on `open`'s path) through
///      `IEnglishAuctionClock.auctionClock`, the others through `IEnglishAuction.auction`. The
///      adapter's fallback forwards every selector it does not declare, so the lens's own
///      `masterTerms`, `sweepOf` and `settlementOrderFor` are answered at the adapter's address
///      too. Every one is read-only (a `staticcall`), and the adapter's ERC-165 does not
///      advertise them. Call the views at the adapter: called directly, the lens reads its
///      caller's words.
interface IUniformEditionAuctionLens {
    /// @notice What `open` locks for a master from the lens, from its token-specific data. The
    ///         payout terms are not here: `open` pays exactly the economics 6529 Stream Editions
    ///         locks and returns (`IEditions.bindMinter`).
    /// @param maxCount The creator's cap from the edition terms, zero for none.
    /// @param oneOfOneEnd The 1/1's end now.
    /// @param oneOfOneState The 1/1's state now: never NONE or CANCELLED.
    struct MasterTerms {
        uint32 maxCount;
        uint64 oneOfOneEnd;
        IEnglishAuction.AuctionState oneOfOneState;
    }

    /// @notice The 6529 Stream Editions this lens was deployed for (immutable).
    /// @return The address its adapter must also have.
    function editions() external view returns (address);
    /// @notice The 6529 Stream this lens was deployed for (immutable).
    /// @return The address its adapter must also have.
    function stream() external view returns (address);
    /// @notice The English auction this lens was deployed for (immutable).
    /// @return The address its adapter must also have.
    function englishAuction() external view returns (address);
    /// @notice The revenue escrow this lens was deployed for (immutable).
    /// @return The address its adapter must also have.
    function escrow() external view returns (address);
    /// @notice The master check of `open`. For 6529 Stream Editions, `data` must be
    ///         `abi.encode(PackageItem)` of an EDITION_MASTER item whose `WorksHashing.itemHash`
    ///         is the one 6529 Stream stored for `id`, with edition terms naming
    ///         `SaleKind.UNIFORM_AUCTION`, `CURRENCY_ETH` and empty params; the
    ///         `PRODUCT_EDITIONS` payout terms 6529 Stream Editions will lock (an existing
    ///         edition's, or the current resolver's) must be payable; and its 1/1 auction must
    ///         exist and not be cancelled. Reverts with the adapter's `InvalidSaleTerms` or
    ///         `NoOneOfOneAuction` otherwise.
    /// @param token The edition contract.
    /// @param id The edition ID.
    /// @param data The token-specific terms `open` was given.
    /// @return The terms `open` locks and the 1/1's state.
    function masterTerms(address token, uint256 id, bytes calldata data)
        external
        view
        returns (MasterTerms memory);

    /// @notice A sale. Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return The sale, with its derived status.
    function auction(uint256 saleId) external view returns (IUniformEditionAuction.Auction memory);
    /// @notice A sale's clocks, read live from its 1/1. Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return The 1/1's end, the close, the soft end, the end, the backstop and the states.
    function endTimes(uint256 saleId) external view returns (IUniformEditionAuction.EndTimes memory);
    /// @notice The live result: what the sale would sell, and at what price, if it closed now.
    ///         After the close the book is frozen, so it equals the settlement's result.
    ///         Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return The clearing of the live book, with the cutoff its departures give.
    function clearing(uint256 saleId) external view returns (IUniformEditionAuction.Clearing memory);
    /// @notice A sale's stored settlement and sweep progress; all zero before it settles.
    /// @param saleId The sale ID.
    /// @return The stored result.
    function settlement(uint256 saleId)
        external
        view
        returns (IUniformEditionAuction.Settlement memory);
    /// @notice A live bid as stored. Reverts with `UnknownBid`.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @return The bidder, step, quantity and position.
    function bidOf(uint256 saleId, uint256 bidId)
        external
        view
        returns (IUniformEditionAuction.Bid memory);
    /// @notice Whether bid `bidId` may be withdrawn now: the sale is OPEN, its 1/1 is paused for a
    ///         dispute, and the bid was placed (or last raised) in a minute that ended before the
    ///         pause began (decision 12, as amended 1 November 2026). Reverts with `UnknownBid`.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @return Whether `withdrawBid` would accept it now.
    function canWithdraw(uint256 saleId, uint256 bidId) external view returns (bool);
    /// @notice A bid's position in the result: copies won, price, escrow, refund and units ahead
    ///         in its queue; final once the sale is SETTLED or VOID. Reverts with `UnknownBid`.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @return The outcome.
    function bidOutcome(uint256 saleId, uint256 bidId)
        external
        view
        returns (IUniformEditionAuction.BidOutcome memory);
    /// @notice Whether a new bid of `quantity` at `step` would win, how many copies, and what it
    ///         would change, if placed now and the sale then closed. `quote(saleId, s, 1)` is
    ///         "what would one more bid at step s change". Reverts with `UnknownAuction` or
    ///         `InvalidStep`.
    /// @param saleId The sale ID.
    /// @param step The step of the hypothetical bid.
    /// @param quantity Its units, from 1.
    /// @return The quote.
    function quote(uint256 saleId, uint256 step, uint256 quantity)
        external
        view
        returns (IUniformEditionAuction.Quote memory);
    /// @notice The lowest step at which a new bid of `quantity` would win at least one copy if
    ///         the sale closed now. Winning is monotone in the step (model-checked, with and
    ///         without a cap), so this may be found by binary search. Reverts with
    ///         `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @param quantity The units of the hypothetical bid, from 1.
    /// @return found Whether any step would win (false only when even the top step would not).
    /// @return step The lowest winning step, when found.
    function lowestWinningStep(uint256 saleId, uint256 quantity)
        external
        view
        returns (bool found, uint256 step);
    /// @notice A step's price under the sale's locked parameters, or under `config()` for a sale
    ///         that has not opened. Reverts with `InvalidStep` past the ladder.
    /// @param saleId The sale ID.
    /// @param step The step.
    /// @return The price per unit, in wei.
    function stepPrice(uint256 saleId, uint256 step) external view returns (uint256);
    /// @notice Every step's price under the sale's locked parameters, or under `config()` for a
    ///         sale that has not opened.
    /// @param saleId The sale ID.
    /// @return prices The price of each step, in wei, from step 0.
    function ladder(uint256 saleId) external view returns (uint256[] memory prices);
    /// @notice The live units at each used step. Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return lowStep The step of `units[0]` (zero with no bids).
    /// @return units Live units per step, from `lowStep` through the highest used step.
    function stepTotals(uint256 saleId)
        external
        view
        returns (uint256 lowStep, uint256[] memory units);
    /// @notice A step's departure log, in the order logged (capped sales; empty otherwise).
    /// @param saleId The sale ID.
    /// @param step The step.
    /// @return The departures; an index into this list is what `settle` takes.
    function departures(uint256 saleId, uint256 step)
        external
        view
        returns (IUniformEditionAuction.Departure[] memory);
    /// @notice The order `settle` needs from a settler that has not swept yet: the clearing
    ///         step's departure indexes sorted by position; empty unless the result is rationed,
    ///         and once SETTLED.
    /// @param saleId The sale ID.
    /// @return order The departure indexes in position order.
    function settlementOrder(uint256 saleId) external view returns (uint256[] memory order);
    /// @notice `settler`'s own departure sweep in progress: each settler sweeps on its own, and
    ///         the first to sweep every departure settles the sale. All zero when it has none
    ///         (it never swept, or it finished).
    /// @param saleId The sale ID.
    /// @param settler The settler (`settle`'s `msg.sender`).
    /// @return swept The departures it has swept.
    /// @return nextPosition The least position its next departure may have.
    /// @return cutoff Its cutoff so far.
    function sweepOf(uint256 saleId, address settler)
        external
        view
        returns (uint256 swept, uint256 nextPosition, uint256 cutoff);
    /// @notice What `settler` passes to its next `settle` call: the rest of the order after
    ///         its own progress (`settlementOrder` for a settler with none). Sorts and returns
    ///         the whole log: beyond about 7,000 departures at the cut step it exceeds a 50M
    ///         `eth_call`, so page with the four-argument form.
    /// @param saleId The sale ID.
    /// @param settler The settler (`settle`'s `msg.sender`).
    /// @return order The remaining departure indexes, in position order.
    function settlementOrderFor(uint256 saleId, address settler)
        external
        view
        returns (uint256[] memory order);
    /// @notice One page of `settler`'s remaining order: at most `max` departure indexes, in
    ///         position order, from the later of `fromPosition` and the settler's own next
    ///         position. `O(n log max)` over a log of `n` departures (a bounded heap), reading the
    ///         log four entries per word: a page of 96 from a log of 10,000 departures costs about
    ///         22M gas in the log's worst order. A keeper pages with `fromPosition` one past the last position it got
    ///         (`departures(saleId, step)` gives them), or passes each page to `settle` and asks
    ///         again.
    /// @param saleId The sale ID.
    /// @param settler The settler (`settle`'s `msg.sender`).
    /// @param fromPosition The least position to return.
    /// @param max The most indexes to return.
    /// @return order The departure indexes, in position order.
    function settlementOrderFor(uint256 saleId, address settler, uint256 fromPosition, uint256 max)
        external
        view
        returns (uint256[] memory order);
}
