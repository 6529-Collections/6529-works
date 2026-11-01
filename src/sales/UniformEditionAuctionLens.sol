// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Splits } from "../economics/Splits.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IEnglishAuctionClock } from "../interfaces/IEnglishAuctionClock.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IUniformEditionAuction } from "../interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "../interfaces/IUniformEditionAuctionLens.sol";
import {
    IUniformEditionAuctionStorage as IStorage
} from "../interfaces/IUniformEditionAuctionStorage.sol";
import { CURRENCY_ETH, PRODUCT_EDITIONS, WorkTerms } from "../interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind, PackageItem } from "../interfaces/types/PackageTypes.sol";
import { SaleKind } from "../interfaces/types/SaleTypes.sol";
import { StepLadder } from "../interfaces/types/StepLadder.sol";
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { UniformClearing } from "./UniformClearing.sol";

/// @title UniformEditionAuctionLens
/// @notice The read side of {UniformEditionAuction}: every view of a sale, computed from the
///         adapter's storage words with the clearing code its settlement runs, and the master
///         check its `open` consults. See {IUniformEditionAuctionLens}.
/// @dev Stateless, and bound to no adapter: deployed in its own transaction (so the adapter's
///      deployment fits a block), it reads every sale from `msg.sender`, the adapter forwarding
///      its views through its read-only fallback or calling `masterTerms` from `open`. Called
///      from anywhere else, it reads the caller's own words, which is harmless. The adapter's
///      constructor pins its code hash and checks that its immutables (`editions`, `stream`,
///      `englishAuction`, `escrow`) are the adapter's own. It decodes the word
///      layouts `IStorage.Space` documents; the test suite pins every decoder
///      against the adapter's behaviour. A sale's book is frozen once it closes (claims never
///      touch live units), so the clearing it computes after the close is the settlement's.
contract UniformEditionAuctionLens is IUniformEditionAuctionLens {
    address private immutable _editions;
    address private immutable _stream;
    address private immutable _englishAuction;
    address private immutable _escrow;

    /// @dev Departure log entries in a step's head word; four in each word after it.
    uint256 private constant _HEAD_ENTRIES = 3;

    /// @param editions_ The adapter's 6529 Stream Editions.
    /// @param stream_ Its 6529 Stream.
    /// @param englishAuction_ The adapter's English auction.
    /// @param escrow_ The adapter's revenue escrow.
    constructor(address editions_, address stream_, address englishAuction_, address escrow_) {
        _editions = editions_;
        _stream = stream_;
        _englishAuction = englishAuction_;
        _escrow = escrow_;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function editions() external view returns (address) {
        return _editions;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function stream() external view returns (address) {
        return _stream;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function englishAuction() external view returns (address) {
        return _englishAuction;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function escrow() external view returns (address) {
        return _escrow;
    }

    // -------------------------------------------------------------------------- the master

    /// @inheritdoc IUniformEditionAuctionLens
    function masterTerms(address token, uint256 id, bytes calldata data)
        external
        view
        returns (MasterTerms memory m)
    {
        try IEnglishAuctionClock(_englishAuction).auctionClock(_saleIdOf(_stream, id)) returns (
            IEnglishAuction.AuctionState state, uint64 endTime, uint64
        ) {
            if (state == IEnglishAuction.AuctionState.CANCELLED) {
                revert IUniformEditionAuction.NoOneOfOneAuction(_stream, id);
            }
            (m.oneOfOneEnd, m.oneOfOneState) = (endTime, state);
        } catch {
            revert IUniformEditionAuction.NoOneOfOneAuction(_stream, id);
        }
        PackageItem memory item = abi.decode(data, (PackageItem));
        EditionTerms memory e = item.edition;
        (bytes32 itemHash,,, ItemKind kind,,) = IStream(_stream).coreOf(id);
        if (
            token != _editions || kind != ItemKind.EDITION_MASTER
                || WorksHashing.itemHash(item) != itemHash || e.saleKind != SaleKind.UNIFORM_AUCTION
                || e.currency != CURRENCY_ETH || e.params.length != 0
        ) revert ISaleAdapter.InvalidSaleTerms(token, id);
        // A preview of the economics `bindMinter` locks and returns in this same transaction,
        // which the adapter pays (F1: 6529 Stream Editions is their one source): the ones an
        // existing edition recorded, or else the current resolver's (6529 Stream's, read live,
        // as Editions reads it). CALLS-1: the escrow refuses to be paid as a wallet, so a sale
        // paying it could never settle; it is refused at open.
        WorkTerms memory w;
        if (IEditions(_editions).exists(id)) {
            IEditions.Edition memory locked = IEditions(_editions).edition(id);
            w = WorkTerms(
                locked.seller,
                locked.feeRecipient,
                locked.feeShare,
                locked.royaltyReceiver,
                locked.royaltyRate
            );
        } else {
            w = IEconomicsResolver(IStream(_stream).economics())
                .newWorkTerms(PRODUCT_EDITIONS, item.payees);
        }
        if (
            w.seller == address(0) || w.seller == _escrow || w.feeShare > Splits.DENOMINATOR
                || (w.feeShare != 0 && (w.feeRecipient == address(0) || w.feeRecipient == _escrow))
        ) revert ISaleAdapter.InvalidSaleTerms(token, id);
        m.maxCount = e.maxCount;
    }

    // ----------------------------------------------------------------------------- a sale

    /// @inheritdoc IUniformEditionAuctionLens
    function auction(uint256 saleId)
        external
        view
        returns (IUniformEditionAuction.Auction memory v)
    {
        IStorage.SaleWord memory a = _opened(saleId);
        IStorage.PayoutWord memory p = _payout(saleId);
        v.token = _editions;
        v.id = p.id;
        v.master = _stream;
        v.oneOfOneSaleId = _saleIdOf(_stream, p.id);
        v.status = _status(a, endTimes(saleId));
        v.maxCount = a.maxCount;
        v.terms = _config(a.termsId);
        v.seller = p.seller;
        v.feeRecipient = _feeRecipient(p.feeRecipientId);
        v.feeShare = p.feeShare;
        v.openedAt = a.openedAt;
        v.bidCount = a.bidCount;
        v.liveUnits = a.liveUnits;
        v.lowStep = a.lowStep;
        v.highStep = a.highStep;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function endTimes(uint256 saleId)
        public
        view
        returns (IUniformEditionAuction.EndTimes memory e)
    {
        IStorage.SaleWord memory a = _opened(saleId);
        IEnglishAuction.Auction memory o =
            IEnglishAuction(_englishAuction).auction(_saleIdOf(_stream, _payout(saleId).id));
        _clocks(e, a, _config(a.termsId), o.endTime);
        e.oneOfOneState = o.state;
        bool open = a.status == IUniformEditionAuction.AuctionStatus.OPEN;
        e.withdrawalsOpen = open && o.state == IEnglishAuction.AuctionState.PAUSED;
        // forge-lint: disable-start(block-timestamp)
        e.biddingOpen = e.withdrawalsOpen
            || (open
                && o.state != IEnglishAuction.AuctionState.CANCELLED
                && block.timestamp < e.endTime);
        // forge-lint: disable-end(block-timestamp)
    }

    /// @dev Fills `e`'s clocks from the 1/1's end now (`oneOfOneEnd`, at least the cached one).
    function _clocks(
        IUniformEditionAuction.EndTimes memory e,
        IStorage.SaleWord memory a,
        IUniformEditionAuction.AuctionConfig memory t,
        uint256 oneOfOneEnd
    ) private pure {
        if (a.oneOfOneEnd > oneOfOneEnd) {
            oneOfOneEnd = a.oneOfOneEnd;
        }
        uint256 closeAt = oneOfOneEnd + t.closeOffset;
        uint256 backstop = closeAt + t.maxExtension;
        uint256 soft = a.softEnd > backstop ? backstop : a.softEnd;
        // Safe: 32-bit times plus at most 8 days.
        // forge-lint: disable-start(unsafe-typecast)
        e.oneOfOneEnd = uint64(oneOfOneEnd);
        e.closeAt = uint64(closeAt);
        e.softEnd = a.softEnd;
        e.endTime = uint64(soft > closeAt ? soft : closeAt);
        e.backstop = uint64(backstop);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function clearing(uint256 saleId)
        external
        view
        returns (IUniformEditionAuction.Clearing memory c)
    {
        IStorage.SaleWord memory a = _opened(saleId);
        if (a.status == IUniformEditionAuction.AuctionStatus.VOID) return c;
        IUniformEditionAuction.AuctionConfig memory t = _config(a.termsId);
        UniformClearing.Result memory r = UniformClearing.clear(_book(saleId, a, 0), _rules(a, t));
        return _clearing(saleId, r, _fullCutoff(saleId, r));
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function settlement(uint256 saleId)
        external
        view
        returns (IUniformEditionAuction.Settlement memory s)
    {
        IStorage.SaleWord memory a = _sale(saleId);
        if (
            a.status != IUniformEditionAuction.AuctionStatus.SETTLING
                && a.status != IUniformEditionAuction.AuctionStatus.SETTLED
        ) return s;
        IStorage.ResultWord memory r = _result(saleId);
        s.count = r.count;
        s.step = r.step;
        s.price = r.count == 0 ? 0 : _price(_config(a.termsId), r.step);
        s.rationed = r.rationed;
        s.cutUnits = r.cutUnits;
        s.cutoff = r.cutoff;
        s.departuresSwept = r.swept;
        if (r.rationed) (s.departures,) = _departureCount(saleId, r.step);
    }

    // ------------------------------------------------------------------------------ bids

    /// @inheritdoc IUniformEditionAuctionLens
    function bidOf(uint256 saleId, uint256 bidId)
        public
        view
        returns (IUniformEditionAuction.Bid memory b)
    {
        uint256 w = _word(IStorage.Space.BID, saleId, bidId);
        // Safe: the adapter's `Bid` packing, field by field.
        // forge-lint: disable-start(unsafe-typecast)
        b.bidder = address(uint160(w));
        b.step = uint16(w >> 160);
        b.quantity = uint32(w >> 176);
        b.position = uint32(w >> 208);
        // forge-lint: disable-end(unsafe-typecast)
        if (b.bidder == address(0)) revert IUniformEditionAuction.UnknownBid(saleId, bidId);
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function canWithdraw(uint256 saleId, uint256 bidId) external view returns (bool) {
        IStorage.SaleWord memory a = _opened(saleId);
        uint256 w = _word(IStorage.Space.BID, saleId, bidId);
        // Safe: the bidder is the word's low 160 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(uint160(w)) == address(0)) {
            revert IUniformEditionAuction.UnknownBid(saleId, bidId);
        }
        if (a.status != IUniformEditionAuction.AuctionStatus.OPEN) return false;
        IEnglishAuction.Auction memory o =
            IEnglishAuction(_englishAuction).auction(_saleIdOf(_stream, _payout(saleId).id));
        if (o.state != IEnglishAuction.AuctionState.PAUSED) return false;
        // The adapter's rule: the bid's minute (bits 240-255) ended before the pause began.
        uint256 placed = w >> 240;
        uint256 paused = o.pausedAt > a.openedAt ? (o.pausedAt - a.openedAt) / 60 : 0;
        if (paused > type(uint16).max) paused = type(uint16).max;
        return placed < paused;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function bidOutcome(uint256 saleId, uint256 bidId)
        external
        view
        returns (IUniformEditionAuction.BidOutcome memory o)
    {
        IUniformEditionAuction.Bid memory b = bidOf(saleId, bidId);
        IStorage.SaleWord memory a = _sale(saleId);
        IUniformEditionAuction.AuctionConfig memory t = _config(a.termsId);
        o.escrow = uint256(b.quantity) * _price(t, b.step);
        if (a.maxCount != 0) o.unitsAhead = _unitsAhead(saleId, b.step, b.position);
        o.isFinal = a.status == IUniformEditionAuction.AuctionStatus.SETTLED
            || a.status == IUniformEditionAuction.AuctionStatus.VOID;
        if (a.status != IUniformEditionAuction.AuctionStatus.VOID) {
            UniformClearing.Result memory r =
                UniformClearing.clear(_book(saleId, a, 0), _rules(a, t));
            if (r.count != 0 && b.step >= r.step) {
                // At a rationed clearing step the queue fills in order: the units ahead are the
                // live units before this bid, so this equals `wonAtCut` with the swept cutoff.
                uint256 left = r.cutUnits > o.unitsAhead ? r.cutUnits - o.unitsAhead : 0;
                o.unitsWon =
                    b.step > r.step || !r.rationed || left >= b.quantity ? b.quantity : left;
            }
            if (o.unitsWon != 0) o.price = r.price;
        }
        o.refund = o.escrow - o.unitsWon * o.price;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function quote(uint256 saleId, uint256 step, uint256 quantity)
        external
        view
        returns (IUniformEditionAuction.Quote memory q)
    {
        IStorage.SaleWord memory a = _opened(saleId);
        IUniformEditionAuction.AuctionConfig memory t = _config(a.termsId);
        if (step >= t.stepCount) revert IUniformEditionAuction.InvalidStep(step);
        if (quantity == 0 || a.liveUnits + quantity > type(uint32).max) {
            revert IUniformEditionAuction.InvalidQuantity(quantity);
        }
        uint256[] memory live = _book(saleId, a, step);
        UniformClearing.Rules memory rules = _rules(a, t);
        uint256 before = UniformClearing.clear(live, rules).count;
        UniformClearing.Result memory r;
        (r, q.unitsWon) = UniformClearing.quote(live, rules, step, quantity);
        q.escrow = quantity * _price(t, step);
        uint256 existing = r.count - q.unitsWon;
        if (before > existing) q.unitsPushedOut = before - existing;
        else q.unitsPulledIn = existing - before;
        q.result = _clearing(saleId, r, _fullCutoff(saleId, r));
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function lowestWinningStep(uint256 saleId, uint256 quantity)
        external
        view
        returns (bool found, uint256 step)
    {
        IStorage.SaleWord memory a = _opened(saleId);
        IUniformEditionAuction.AuctionConfig memory t = _config(a.termsId);
        if (quantity == 0 || a.liveUnits + quantity > type(uint32).max) {
            revert IUniformEditionAuction.InvalidQuantity(quantity);
        }
        uint256 hi = t.stepCount;
        uint256[] memory live = _book(saleId, a, hi - 1);
        UniformClearing.Rules memory rules = _rules(a, t);
        while (step < hi) {
            uint256 mid = (step + hi) / 2;
            (, uint256 won) = UniformClearing.quote(live, rules, mid, quantity);
            if (won != 0) hi = mid;
            else step = mid + 1;
        }
        found = step < t.stepCount;
        if (!found) step = 0;
    }

    // ----------------------------------------------------------------------- the ladder

    /// @inheritdoc IUniformEditionAuctionLens
    function stepPrice(uint256 saleId, uint256 step) external view returns (uint256) {
        IUniformEditionAuction.AuctionConfig memory t = _termsOf(saleId);
        if (step >= t.stepCount) revert IUniformEditionAuction.InvalidStep(step);
        return _price(t, step);
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function ladder(uint256 saleId) external view returns (uint256[] memory prices) {
        IUniformEditionAuction.AuctionConfig memory t = _termsOf(saleId);
        prices = new uint256[](t.stepCount);
        for (uint256 i; i < prices.length; ++i) {
            prices[i] = _price(t, i);
        }
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function stepTotals(uint256 saleId)
        external
        view
        returns (uint256 lowStep, uint256[] memory units)
    {
        IStorage.SaleWord memory a = _opened(saleId);
        if (a.liveUnits == 0) return (0, units);
        lowStep = a.lowStep;
        uint256[] memory live = _book(saleId, a, 0);
        units = new uint256[](uint256(a.highStep) + 1 - lowStep);
        for (uint256 i; i < units.length; ++i) {
            units[i] = _unitsIn(live, lowStep + i);
        }
    }

    // ------------------------------------------------------------------------ departures

    /// @inheritdoc IUniformEditionAuctionLens
    function departures(uint256 saleId, uint256 step)
        external
        view
        returns (IUniformEditionAuction.Departure[] memory list)
    {
        uint256[] memory entries = _entries(saleId, step);
        list = new IUniformEditionAuction.Departure[](entries.length);
        for (uint256 i; i < entries.length; ++i) {
            uint256 entry = entries[i];
            // Safe: 32-bit fields of the entry.
            // forge-lint: disable-next-line(unsafe-typecast)
            list[i] = IUniformEditionAuction.Departure(uint32(entry), uint32(entry >> 32));
        }
    }

    /// @inheritdoc IUniformEditionAuctionLens
    /// @dev For a SETTLING sale, the departures its sweep has not passed yet: pass the whole
    ///      list (in chunks if long) to `settle`.
    function settlementOrder(uint256 saleId) public view returns (uint256[] memory order) {
        IStorage.SaleWord memory a = _opened(saleId);
        // Before the clearing is stored (open, or a settlement scan still running), the order
        // the live clearing needs; once stored, the whole sweep order, for a settler that has
        // not swept yet (`settlementOrderFor` gives a settler's rest).
        if (
            a.status == IUniformEditionAuction.AuctionStatus.OPEN
                || (a.status == IUniformEditionAuction.AuctionStatus.SETTLING
                    && _word(IStorage.Space.SCAN, saleId, 0) != 0)
        ) {
            UniformClearing.Result memory r = UniformClearing.clear(
                _book(saleId, a, 0), _rules(a, _config(a.termsId))
            );
            if (!r.rationed) return order;
            (order,) = _sorted(saleId, r.step, 0);
        } else if (a.status == IUniformEditionAuction.AuctionStatus.SETTLING) {
            IStorage.ResultWord memory r = _result(saleId);
            (order,) = _sorted(saleId, r.step, r.nextPosition);
        }
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function sweepOf(uint256 saleId, address settler)
        public
        view
        returns (uint256 swept, uint256 nextPosition, uint256 cutoff)
    {
        uint256 w = _word(IStorage.Space.SWEEP, saleId, uint160(settler));
        // Safe: three 32-bit fields of the packed progress word.
        // forge-lint: disable-next-line(unsafe-typecast)
        (swept, nextPosition, cutoff) = (uint32(w), uint32(w >> 32), uint32(w >> 64));
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function settlementOrderFor(uint256 saleId, address settler)
        external
        view
        returns (uint256[] memory)
    {
        return settlementOrderFor(saleId, settler, 0, type(uint256).max);
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function settlementOrderFor(uint256 saleId, address settler, uint256 fromPosition, uint256 max)
        public
        view
        returns (uint256[] memory order)
    {
        IStorage.SaleWord memory a = _opened(saleId);
        uint256 step;
        if (
            a.status == IUniformEditionAuction.AuctionStatus.SETTLING
                && _word(IStorage.Space.SCAN, saleId, 0) == 0
        ) {
            // Cleared and sweeping: from the settler's next position on.
            step = _result(saleId).step;
            (, uint256 next,) = sweepOf(saleId, settler);
            if (next > fromPosition) fromPosition = next;
        } else if (
            a.status == IUniformEditionAuction.AuctionStatus.OPEN
                || a.status == IUniformEditionAuction.AuctionStatus.SETTLING
        ) {
            // Not cleared yet: the order the live clearing needs.
            UniformClearing.Result memory r =
                UniformClearing.clear(_book(saleId, a, 0), _rules(a, _config(a.termsId)));
            if (!r.rationed) return order;
            step = r.step;
        } else {
            return order;
        }
        order = _smallest(_entries(saleId, step), fromPosition, max);
    }

    // --------------------------------------------------------------------------- internal

    /// @dev The status, CLOSED derived: an OPEN sale whose bidding is closed (its end passed or
    ///      its 1/1 cancelled).
    function _status(IStorage.SaleWord memory a, IUniformEditionAuction.EndTimes memory e)
        private
        pure
        returns (IUniformEditionAuction.AuctionStatus)
    {
        if (a.status == IUniformEditionAuction.AuctionStatus.OPEN && !e.biddingOpen) {
            return IUniformEditionAuction.AuctionStatus.CLOSED;
        }
        return a.status;
    }

    /// @dev `r` as a `Clearing`, with its revenue, the sale's network fee and the cutoff.
    function _clearing(uint256 saleId, UniformClearing.Result memory r, uint256 cutoff)
        private
        view
        returns (IUniformEditionAuction.Clearing memory c)
    {
        c.count = r.count;
        c.step = r.step;
        c.price = r.price;
        c.revenue = r.count * r.price;
        c.networkFee = c.revenue * _payout(saleId).feeShare / Splits.DENOMINATOR;
        c.bestRevenue = r.bestRevenue;
        c.rationed = r.rationed;
        c.cutUnits = r.cutUnits;
        c.unitsAtStep = r.unitsAtStep;
        c.cutoff = cutoff;
    }

    // Safe: the departure helpers below read the 32-bit position and quantity fields of 64-bit
    // log entries, and the 32-bit count of a log's head word.
    // forge-lint: disable-start(unsafe-typecast)

    /// @dev The cutoff a complete departure sweep of `r`'s clearing step gives; zero unless `r`
    ///      is rationed.
    function _fullCutoff(uint256 saleId, UniformClearing.Result memory r)
        private
        view
        returns (uint256 cutoff)
    {
        if (!r.rationed) return 0;
        (uint256[] memory order, uint256[] memory entries) = _sorted(saleId, r.step, 0);
        cutoff = r.cutUnits;
        uint256 next = 0;
        for (uint256 i; i < order.length; ++i) {
            (cutoff, next) = UniformClearing.sweep(
                cutoff, next, uint32(entries[i]), uint32(entries[i] >> 32), i
            );
        }
    }

    /// @dev `step`'s departure indexes whose position is at least `from`, sorted by position
    ///      (ties, which a log never holds, by index), with their entries (`position |
    ///      quantity << 32`) in the same order. A heapsort of packed keys, `O(n log n)`
    ///      whatever the order; the log is read four entries per storage word. Measured through
    ///      the adapter with the log in its worst order: `clearing` and `quote` cost about 5,000
    ///      gas a departure at the cut step (50.6M at 10,000), so they stay within a 50M
    ///      `eth_call` up to about 9,000; `settlementOrder` up to about 7,000 and `departures`
    ///      up to about 8,000 (both return the whole log). A keeper pages with
    ///      `settlementOrderFor(saleId, settler, fromPosition, max)`: 21.9M for a page of 96 at
    ///      10,000 departures.
    function _sorted(uint256 saleId, uint256 step, uint256 from)
        private
        view
        returns (uint256[] memory order, uint256[] memory entries)
    {
        uint256[] memory log = _entries(saleId, step);
        uint256 count = log.length;
        uint256[] memory keys = new uint256[](count);
        uint256 n;
        for (uint256 i; i < count; ++i) {
            uint256 entry = log[i];
            if (uint32(entry) < from) continue;
            // The key orders by position, then index; its low 64 bits are the entry.
            keys[n++] = uint256(uint32(entry)) << 128 | i << 64 | uint64(entry);
        }
        // Invariant: `n` is at most the length `keys` was allocated with, so shortening it in
        // place keeps every element inside its allocation.
        assembly ("memory-safe") {
            mstore(keys, n)
        }
        _heapSort(keys);
        order = new uint256[](n);
        entries = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            (order[k], entries[k]) = (uint64(keys[k] >> 64), uint64(keys[k]));
        }
    }

    /// @dev The indexes of the `max` departures of `log` with the lowest positions at least
    ///      `from`, in position order: a bounded max-heap of packed keys (position, index),
    ///      `O(n log max)`, then sorted. A keeper pages through a long log with `from` one past
    ///      the last position it got.
    function _smallest(uint256[] memory log, uint256 from, uint256 max)
        private
        pure
        returns (uint256[] memory order)
    {
        uint256 count = log.length;
        if (max > count) max = count;
        uint256[] memory heap = new uint256[](max);
        // Invariants: `n <= max`, the length `heap` was allocated with, so every index read or
        // written (`k`, a parent or a child, each below `n`) is inside it; `i < count` indexes
        // `log`. A key is `position << 128 | i`: positions below 2^32, indexes below 2^64, so
        // keys order by position, then index. Only `heap`'s own words are written.
        assembly ("memory-safe") {
            let h := add(heap, 0x20)
            let src := add(log, 0x20)
            let n := 0
            for { let i := 0 } lt(i, count) { i := add(i, 1) } {
                let position := and(mload(add(src, shl(5, i))), 0xffffffff)
                if iszero(lt(position, from)) {
                    let key := or(shl(128, position), i)
                    switch lt(n, max)
                    case 1 {
                        // Sift the new key up from the end.
                        let k := n
                        n := add(n, 1)
                        for { } k { } {
                            let parent := shr(1, sub(k, 1))
                            let pv := mload(add(h, shl(5, parent)))
                            if iszero(lt(pv, key)) { break }
                            mstore(add(h, shl(5, k)), pv)
                            k := parent
                        }
                        mstore(add(h, shl(5, k)), key)
                    }
                    default {
                        // Full: a key below the largest kept replaces it and sifts down.
                        if and(gt(n, 0), lt(key, mload(h))) {
                            let k := 0
                            for { } 1 { } {
                                let child := add(shl(1, k), 1)
                                if iszero(lt(child, n)) { break }
                                let cv := mload(add(h, shl(5, child)))
                                let right := add(child, 1)
                                if lt(right, n) {
                                    let rv := mload(add(h, shl(5, right)))
                                    if gt(rv, cv) {
                                        child := right
                                        cv := rv
                                    }
                                }
                                if iszero(gt(cv, key)) { break }
                                mstore(add(h, shl(5, k)), cv)
                                k := child
                            }
                            mstore(add(h, shl(5, k)), key)
                        }
                    }
                }
            }
            mstore(heap, n)
        }
        uint256 n = heap.length;
        _heapSort(heap);
        order = heap;
        for (uint256 k; k < n; ++k) {
            order[k] = uint64(heap[k]);
        }
    }

    /// @dev Sorts `a` ascending in place: heapsort, `O(n log n)` comparisons whatever the order.
    function _heapSort(uint256[] memory a) private pure {
        uint256 n = a.length;
        for (uint256 i = n >> 1; i != 0;) {
            --i;
            _siftDown(a, i, n);
        }
        for (uint256 end = n; end > 1;) {
            --end;
            (a[0], a[end]) = (a[end], a[0]);
            _siftDown(a, 0, end);
        }
    }

    /// @dev Restores the max-heap below `root` within the first `n` elements of `a`.
    function _siftDown(uint256[] memory a, uint256 root, uint256 n) private pure {
        // Invariants: callers pass `root < n <= a.length`, so every index read or written (the
        // root and each child below `n`) is inside `a`; only `a`'s words are written.
        assembly ("memory-safe") {
            let p := add(a, 0x20)
            let value := mload(add(p, shl(5, root)))
            for { } 1 { } {
                let child := add(shl(1, root), 1)
                if iszero(lt(child, n)) { break }
                let cv := mload(add(p, shl(5, child)))
                let right := add(child, 1)
                if lt(right, n) {
                    let rv := mload(add(p, shl(5, right)))
                    if gt(rv, cv) {
                        child := right
                        cv := rv
                    }
                }
                if iszero(gt(cv, value)) { break }
                mstore(add(p, shl(5, root)), cv)
                root := child
            }
            mstore(add(p, shl(5, root)), value)
        }
    }

    /// @dev The live units ahead of `position` in `step`'s queue: the position less the departed
    ///      units before it (a departure lies wholly before or after a live bid).
    function _unitsAhead(uint256 saleId, uint256 step, uint256 position)
        private
        view
        returns (uint256 ahead)
    {
        uint256[] memory log = _entries(saleId, step);
        ahead = position;
        for (uint256 i; i < log.length; ++i) {
            uint256 entry = log[i];
            if (uint32(entry) < position) ahead -= uint32(entry >> 32);
        }
    }

    /// @dev A step's departure count and its log's head word.
    function _departureCount(uint256 saleId, uint256 step)
        private
        view
        returns (uint256 count, uint256 head)
    {
        head = _word(IStorage.Space.DEPARTURE, saleId, step << 32);
        count = uint32(head);
    }

    /// @dev `step`'s departure log, entry `i` (`position | quantity << 32`) at index `i`: the
    ///      head word holds the first three, each later word four, so every word is read once.
    function _entries(uint256 saleId, uint256 step) private view returns (uint256[] memory log) {
        (uint256 count, uint256 head) = _departureCount(saleId, step);
        log = new uint256[](count);
        uint256 word = head >> 64;
        for (uint256 i; i < count; ++i) {
            if (i >= _HEAD_ENTRIES && (i - _HEAD_ENTRIES) & 3 == 0) {
                word = _word(
                    IStorage.Space.DEPARTURE, saleId, step << 32 | 1 + ((i - _HEAD_ENTRIES) >> 2)
                );
            }
            log[i] = uint64(word);
            word >>= 64;
        }
    }

    // forge-lint: disable-end(unsafe-typecast)

    /// @dev The live words of sale `a`, covering at least step `minStep` (zero words past its
    ///      highest step): `UniformClearing`'s book.
    function _book(uint256 saleId, IStorage.SaleWord memory a, uint256 minStep)
        private
        view
        returns (uint256[] memory live)
    {
        uint256 top = a.liveUnits == 0 || minStep > a.highStep ? minStep : a.highStep;
        live = new uint256[]((top >> 3) + 1);
        if (a.liveUnits == 0) return live;
        for (uint256 w = uint256(a.lowStep) >> 3; w <= uint256(a.highStep) >> 3; ++w) {
            live[w] = _word(IStorage.Space.LIVE, saleId, w);
        }
    }

    /// @dev The units of `step` in book `live`.
    function _unitsIn(uint256[] memory live, uint256 step) private pure returns (uint256) {
        return uint32(live[step >> 3] >> ((step & 7) << 5));
    }

    function _rules(IStorage.SaleWord memory a, IUniformEditionAuction.AuctionConfig memory t)
        private
        pure
        returns (UniformClearing.Rules memory)
    {
        return UniformClearing.Rules(t.basePrice, t.stepsPerDecade, a.maxCount, t.marginShare);
    }

    function _price(IUniformEditionAuction.AuctionConfig memory t, uint256 step)
        private
        pure
        returns (uint256)
    {
        return StepLadder.price(t.basePrice, t.stepsPerDecade, step);
    }

    /// @dev The sale's locked parameters, or the current ones for a sale not opened.
    function _termsOf(uint256 saleId)
        private
        view
        returns (IUniformEditionAuction.AuctionConfig memory)
    {
        IStorage.SaleWord memory a = _sale(saleId);
        if (a.status == IUniformEditionAuction.AuctionStatus.NONE) {
            return IUniformEditionAuction(msg.sender).config();
        }
        return _config(a.termsId);
    }

    /// @dev An opened sale's state word.
    function _opened(uint256 saleId) private view returns (IStorage.SaleWord memory a) {
        a = _sale(saleId);
        if (a.status == IUniformEditionAuction.AuctionStatus.NONE) {
            revert IUniformEditionAuction.UnknownAuction(saleId);
        }
    }

    // Safe: every decoder below reads the adapter's packing, field by field.
    // forge-lint: disable-start(unsafe-typecast)

    function _sale(uint256 saleId) private view returns (IStorage.SaleWord memory a) {
        uint256 w = _word(IStorage.Space.SALE, saleId, 0);
        a.status = IUniformEditionAuction.AuctionStatus(uint8(w));
        a.termsId = uint16(w >> 8);
        a.maxCount = uint32(w >> 24);
        a.oneOfOneEnd = uint32(w >> 56);
        a.softEnd = uint32(w >> 88);
        a.openedAt = uint32(w >> 120);
        a.lowStep = uint16(w >> 152);
        a.highStep = uint16(w >> 168);
        a.liveUnits = uint32(w >> 184);
        a.bidCount = uint32(w >> 216);
    }

    function _payout(uint256 saleId) private view returns (IStorage.PayoutWord memory p) {
        uint256 w = _word(IStorage.Space.PAYOUT, saleId, 0);
        p.seller = address(uint160(w));
        p.feeShare = uint32(w >> 160);
        p.feeRecipientId = uint16(w >> 192);
        p.id = uint32(w >> 208);
    }

    function _result(uint256 saleId) private view returns (IStorage.ResultWord memory r) {
        uint256 w = _word(IStorage.Space.RESULT, saleId, 0);
        r.count = uint32(w);
        r.step = uint16(w >> 32);
        r.rationed = uint8(w >> 48) != 0;
        r.cutUnits = uint32(w >> 56);
        r.cutoff = uint32(w >> 88);
        r.swept = uint32(w >> 120);
        r.nextPosition = uint32(w >> 152);
        r.id = uint32(w >> 184);
    }

    function _config(uint256 termsId)
        private
        view
        returns (IUniformEditionAuction.AuctionConfig memory t)
    {
        uint256 w = _word(IStorage.Space.TERMS, 0, termsId);
        t.basePrice = uint96(w);
        t.stepsPerDecade = uint16(w >> 96);
        t.stepCount = uint16(w >> 112);
        t.marginShare = uint32(w >> 128);
        t.closeOffset = uint32(w >> 160);
        t.softWindow = uint32(w >> 192);
        t.maxExtension = uint32(w >> 224);
    }

    function _feeRecipient(uint256 index) private view returns (address) {
        return address(uint160(_word(IStorage.Space.FEE_RECIPIENT, 0, index)));
    }

    // forge-lint: disable-end(unsafe-typecast)

    function _word(IStorage.Space space, uint256 saleId, uint256 key)
        private
        view
        returns (uint256)
    {
        return IStorage(msg.sender).storageWord(space, saleId, key);
    }

    function _saleIdOf(address token, uint256 id) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, id)));
    }
}
