// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUniformEditionAuction } from "./IUniformEditionAuction.sol";

/// @title IUniformEditionAuctionStorage
/// @notice The edition auction adapter's raw storage words and its lens: what
///         `UniformEditionAuction` adds to `IUniformEditionAuction`. Every view of the adapter,
///         its sales and its settings is computed by the lens (`IUniformEditionAuctionLens`)
///         from these words, and the adapter answers its own views by asking the lens, because
///         its write path alone nearly fills EIP-170.
interface IUniformEditionAuctionStorage {
    /// @notice A sale's state word, as stored (`Space.SALE`): written at open and by every bid,
    ///         raise and withdrawal.
    /// @param status The stored status: never CLOSED, which is derived.
    /// @param termsId The locked parameters' interned ID (`Space.TERMS`): the configuration
    ///        current at open, or a record of it with the edition's own close offset.
    /// @param maxCount The creator's cap; zero for none.
    /// @param oneOfOneEnd The 1/1's end as last read (it only moves later).
    /// @param softEnd The soft-close end; zero before any bid in the window.
    /// @param openedAt When the sale opened.
    /// @param lowStep The lowest step live bids used since the book was last empty.
    /// @param highStep The highest step live bids used since the book was last empty.
    /// @param liveUnits Units of the bids live now.
    /// @param bidCount Bids placed so far.
    struct SaleWord {
        IUniformEditionAuction.AuctionStatus status;
        uint24 termsId;
        uint32 maxCount;
        uint32 oneOfOneEnd;
        uint32 softEnd;
        uint32 openedAt;
        uint16 lowStep;
        uint16 highStep;
        uint32 liveUnits;
        uint32 bidCount;
    }

    /// @notice One bid as stored (`Space.BID`): `IUniformEditionAuction.Bid`'s fields, then the
    ///         minute it was placed or last raised, counted from the sale's `openedAt` and
    ///         capped at 65,535. A withdrawal during a 1/1 dispute pause is open only to a bid
    ///         placed in a minute that ended before the pause began (ADR 0005, amended
    ///         1 November 2026).
    /// @param bidder Who placed it.
    /// @param step Its step.
    /// @param quantity Its units.
    /// @param position Units entered at its step before it.
    /// @param placedMinute `(placed or raised - openedAt) / 60`, at most 65,535.
    struct BidWord {
        address bidder;
        uint16 step;
        uint32 quantity;
        uint32 position;
        uint16 placedMinute;
    }

    /// @notice A sale's payout terms, locked at open (`Space.PAYOUT`).
    /// @param seller The artist-portion split wallet.
    /// @param feeShare The network fee share, out of 100,000.
    /// @param feeRecipientId The interned fee recipient (`Space.FEE_RECIPIENT`); zero for none.
    /// @param id The edition ID.
    /// @param voidDelayDays The abandonment delay locked at open (`Limits.voidDelayDays`).
    struct PayoutWord {
        address seller;
        uint32 feeShare;
        uint16 feeRecipientId;
        uint32 id;
        uint16 voidDelayDays;
    }

    /// @notice A sale's result, written at settlement (`Space.RESULT`). Each settler's sweep
    ///      progress is kept apart, per sender; `cutoff`, `swept` and `nextPosition` are written
    ///      here once a settler's sweep completes.
    /// @param count Copies sold.
    /// @param step The clearing step.
    /// @param rationed Whether the cap binds inside the clearing step.
    /// @param cutUnits The clearing step's winning units.
    /// @param cutoff `cutUnits` until the sweep completes, then the final cutoff.
    /// @param swept Zero until the sweep completes, then the clearing step's departures.
    /// @param nextPosition Zero until the sweep completes, then one past the last swept
    ///        position.
    /// @param id The edition ID, so a claim reads one word for its mint.
    struct ResultWord {
        uint32 count;
        uint16 step;
        bool rationed;
        uint32 cutUnits;
        uint32 cutoff;
        uint32 swept;
        uint32 nextPosition;
        uint32 id;
    }

    /// @notice A settlement scan in progress (`Space.SCAN`): written by a settle call that could
    ///      not scan the whole book within its word budget, deleted when the scan completes.
    /// @param cursor One past the next live word to scan (the scan runs downward); zero when no
    ///        scan is in progress.
    /// @param demand The live units at or above the words scanned so far.
    /// @param bestCount The count of the best candidate so far.
    /// @param bestStep The step of the best candidate so far (its revenue is `bestCount` times
    ///        its price).
    /// @param pickStep The step of the last candidate within the margin of the best so far.
    /// @param pickAbove The live units above `pickStep`.
    /// @param pickDemand The live units at or above `pickStep`.
    struct ScanWord {
        uint8 cursor;
        uint32 demand;
        uint32 bestCount;
        uint16 bestStep;
        uint16 pickStep;
        uint32 pickAbove;
        uint32 pickDemand;
    }

    /// @notice The storage word families `storageWord` reads.
    /// @dev Struct words pack their fields from the least significant bit, in declaration order.
    ///      SALE (`SaleWord`), PAYOUT (`PayoutWord`), RESULT (`ResultWord`), SCAN (`ScanWord`):
    ///      `key` ignored. BID:
    ///      `key` the bid ID (`BidWord`). LIVE: `key` a word index `w`; eight 32-bit live-unit
    ///      counters, step `8w + j` in bits `32j`. DEPARTURE: `key` is `step << 32 | w`; word 0
    ///      holds the step's departure count (bits 0-31), its departed units (32-63) and entries
    ///      0-2 (64 bits each from bit 64), and word `w >= 1` entries `4w - 1` to `4w + 2` (64
    ///      bits each from bit 0); an entry is `position | quantity << 32`. TERMS: `key` a terms
    ///      ID (`IUniformEditionAuction.AuctionConfig`). FEE_RECIPIENT: `key` an interned index; the address.
    ///      SWEEP: `key` a settler's address; its own departure sweep in progress, `swept |
    ///      nextPosition << 32 | cutoff << 64`, zero when it has none (never swept, or
    ///      finished). CREDIT: `key` an account; its claimable ETH. SETTINGS: `saleId` and
    ///      `key` ignored; `termsId` (the current configuration's ID, bits 0-23), `termsCount`
    ///      (24-47), the fee recipients interned (48-63), `pausedAt` (64-103, zero while not
    ///      paused), `listed` (104-111), then `IUniformEditionAuction.Limits`:
    ///      `maxCloseOffset` (112-143), `voidDelayDays` (144-159), `payoutGas` (160-191) and
    ///      `rescueCapDays` (192-207).
    enum Space {
        SALE,
        PAYOUT,
        RESULT,
        BID,
        LIVE,
        DEPARTURE,
        TERMS,
        FEE_RECIPIENT,
        SCAN,
        SWEEP,
        CREDIT,
        SETTINGS
    }

    /// @notice A settle call scanned part of a sale's book and stopped at its gas bound; the
    ///         next settle call continues the scan (`ScanWord`).
    /// @param saleId The sale ID.
    /// @param wordsLeft The live words still to scan.
    event SettlementScanned(uint256 indexed saleId, uint256 wordsLeft);

    /// @notice The read-only lens this adapter pinned in its constructor: deployed beforehand in
    ///         its own transaction, with the code hash and the wiring (Editions, Stream, English
    ///         auction, escrow) the constructor checked. It computes every view of
    ///         `IUniformEditionAuction` from its caller's words, which the adapter forwards to
    ///         it, and the master check `open` consults.
    /// @return The lens's address (immutable).
    function lens() external view returns (address);
    /// @notice One raw storage slot of the adapter: the lens computes where each word of
    ///         `Space` lives (as Solidity places mapping values) and reads it here, and answers
    ///         `storageWord(space, saleId, key)` at the adapter's address
    ///         (`IUniformEditionAuctionLens.storageWord`).
    /// @param slot The storage slot.
    /// @return The stored word; zero when unset.
    function storageAt(uint256 slot) external view returns (uint256);
}
