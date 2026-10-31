// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Splits } from "../economics/Splits.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
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
import { WorksHashing } from "../interfaces/types/WorksHashing.sol";
import { UniformClearing } from "./UniformClearing.sol";

/// @title UniformEditionAuctionLens
/// @notice The read side of {UniformEditionAuction}: every view of a sale, computed from the
///         adapter's storage words with the clearing code its settlement runs, and the master
///         check its `open` consults. See {IUniformEditionAuctionLens}.
/// @dev Stateless. The adapter's constructor creates it and is its `adapter`. It decodes the word
///      layouts `IStorage.Space` documents; the test suite pins every decoder
///      against the adapter's behaviour. A sale's book is frozen once it closes (claims never
///      touch live units), so the clearing it computes after the close is the settlement's.
contract UniformEditionAuctionLens is IUniformEditionAuctionLens {
    /// @inheritdoc IUniformEditionAuctionLens
    address public immutable adapter;
    address private immutable _editions;
    address private immutable _stream;
    address private immutable _englishAuction;
    address private immutable _economics;
    address private immutable _escrow;

    /// @dev Departure log entries in a step's head word; four in each word after it.
    uint256 private constant _HEAD_ENTRIES = 3;

    /// @param editions_ The adapter's 6529 Stream Editions.
    /// @param stream_ Its 6529 Stream.
    /// @param englishAuction_ The adapter's English auction.
    /// @param economics_ 6529 Stream's economics resolver.
    /// @param escrow_ The adapter's revenue escrow.
    constructor(
        address editions_,
        address stream_,
        address englishAuction_,
        address economics_,
        address escrow_
    ) {
        adapter = msg.sender;
        _editions = editions_;
        _stream = stream_;
        _englishAuction = englishAuction_;
        _economics = economics_;
        _escrow = escrow_;
    }

    // -------------------------------------------------------------------------- the master

    /// @inheritdoc IUniformEditionAuctionLens
    function masterTerms(address token, uint256 id, bytes calldata data)
        external
        view
        returns (MasterTerms memory m)
    {
        try IEnglishAuction(_englishAuction).auction(_saleIdOf(_stream, id)) returns (
            IEnglishAuction.Auction memory o
        ) {
            if (o.state == IEnglishAuction.AuctionState.CANCELLED) {
                revert IUniformEditionAuction.NoOneOfOneAuction(_stream, id);
            }
            (m.oneOfOneEnd, m.oneOfOneState) = (o.endTime, o.state);
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
        // The economics the edition records: locked when it was created or bound, or, for an
        // edition still unbound, the resolver's now, which `bindMinter` locks in this same
        // transaction. So the split this sale pays is always the one the edition reports.
        WorkTerms memory w;
        if (IEditions(_editions).exists(id)) {
            IEditions.Edition memory locked = IEditions(_editions).edition(id);
            (w.seller, w.feeRecipient, w.feeShare) =
            (locked.seller, locked.feeRecipient, locked.feeShare);
        } else {
            w = IEconomicsResolver(_economics).newWorkTerms(PRODUCT_EDITIONS, item.payees);
        }
        // CALLS-1: the escrow refuses to be paid as a wallet, so a sale paying it could never
        // settle; it is refused at open.
        if (
            w.seller == address(0) || w.seller == _escrow || w.feeShare > Splits.DENOMINATOR
                || (w.feeShare != 0 && (w.feeRecipient == address(0) || w.feeRecipient == _escrow))
        ) revert ISaleAdapter.InvalidSaleTerms(token, id);
        m.maxCount = e.maxCount;
        m.seller = w.seller;
        if (w.feeShare != 0) (m.feeRecipient, m.feeShare) = (w.feeRecipient, w.feeShare);
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
        (uint256 count, uint256 head) = _departureCount(saleId, step);
        list = new IUniformEditionAuction.Departure[](count);
        for (uint256 i; i < count; ++i) {
            uint256 entry = _departure(saleId, step, head, i);
            // Safe: 32-bit fields of the entry.
            // forge-lint: disable-next-line(unsafe-typecast)
            list[i] = IUniformEditionAuction.Departure(uint32(entry), uint32(entry >> 32));
        }
    }

    /// @inheritdoc IUniformEditionAuctionLens
    /// @dev For a SETTLING sale, the departures its sweep has not passed yet: pass the whole
    ///      list (in chunks if long) to `settle`.
    function settlementOrder(uint256 saleId) external view returns (uint256[] memory order) {
        IStorage.SaleWord memory a = _opened(saleId);
        // Before the clearing is stored (open, or a settlement scan still running), the order
        // the live clearing needs; once stored, what is left of its sweep.
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
    ///      quantity << 32`) in the same order. A heapsort of packed keys, `O(n log n)` in the
    ///      worst case: a log of thousands of departures in any order stays far inside an
    ///      `eth_call` gas cap.
    function _sorted(uint256 saleId, uint256 step, uint256 from)
        private
        view
        returns (uint256[] memory order, uint256[] memory entries)
    {
        (uint256 count, uint256 head) = _departureCount(saleId, step);
        uint256[] memory keys = new uint256[](count);
        uint256 n;
        for (uint256 i; i < count; ++i) {
            uint256 entry = _departure(saleId, step, head, i);
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
        uint256 value = a[root];
        for (uint256 child = 2 * root + 1; child < n; child = 2 * root + 1) {
            if (child + 1 < n && a[child + 1] > a[child]) ++child;
            if (a[child] <= value) break;
            a[root] = a[child];
            root = child;
        }
        a[root] = value;
    }

    /// @dev The live units ahead of `position` in `step`'s queue: the position less the departed
    ///      units before it (a departure lies wholly before or after a live bid).
    function _unitsAhead(uint256 saleId, uint256 step, uint256 position)
        private
        view
        returns (uint256 ahead)
    {
        (uint256 count, uint256 head) = _departureCount(saleId, step);
        ahead = position;
        for (uint256 i; i < count; ++i) {
            uint256 entry = _departure(saleId, step, head, i);
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

    /// @dev Departure `index` of `step`'s log: `position | quantity << 32` in the low 64 bits.
    function _departure(uint256 saleId, uint256 step, uint256 head, uint256 index)
        private
        view
        returns (uint256)
    {
        if (index < _HEAD_ENTRIES) return head >> (64 + (index << 6));
        uint256 j = index - _HEAD_ENTRIES;
        return _word(IStorage.Space.DEPARTURE, saleId, step << 32 | 1 + (j >> 2)) >> ((j & 3) << 6);
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
        return UniformClearing.price(t.basePrice, t.stepsPerDecade, step);
    }

    /// @dev The sale's locked parameters, or the current ones for a sale not opened.
    function _termsOf(uint256 saleId)
        private
        view
        returns (IUniformEditionAuction.AuctionConfig memory)
    {
        IStorage.SaleWord memory a = _sale(saleId);
        if (a.status == IUniformEditionAuction.AuctionStatus.NONE) {
            return IUniformEditionAuction(adapter).config();
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
        return IStorage(adapter).storageWord(space, saleId, key);
    }

    function _saleIdOf(address token, uint256 id) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, id)));
    }
}
