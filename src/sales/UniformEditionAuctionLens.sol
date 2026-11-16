// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ISplitFactory } from "../economics/interfaces/ISplitFactory.sol";
import { ISplitWallet } from "../economics/interfaces/ISplitWallet.sol";
import { Splits } from "../economics/Splits.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IEnglishAuctionClock } from "../interfaces/IEnglishAuctionClock.sol";
import { IItemApprovals } from "../interfaces/IItemApprovals.sol";
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
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { UniformClearing } from "./UniformClearing.sol";

/// @title UniformEditionAuctionLensBase
/// @notice The read side of {UniformEditionAuctionBase}, shared by the lens of each deployment
///         ({UniformEditionAuctionLens}, {FederatedEditionAuctionLens}): every view of a sale and of the adapter's
///         settings, computed from the adapter's storage words with the clearing code its
///         settlement runs, and the master and abandonment checks its `open` and `abandon`
///         consult. See {IUniformEditionAuctionLens}.
/// @dev Stateless, and bound to no adapter: deployed in its own transaction (so the adapter's
///      deployment fits a block), it reads every sale from `msg.sender`, the adapter forwarding
///      its views through its read-only fallback or calling `masterTerms` from `open`. Called
///      from anywhere else, it reads the caller's own words, which is harmless. The adapter's
///      constructor pins its code hash and checks that its immutables (`editions`, `stream`,
///      `englishAuction`, `escrow`) are the adapter's own. It computes where each word lives
///      from the adapter's storage layout (the `_SLOT_*` constants) and reads it with
///      `IStorage.storageAt`, and decodes the word layouts `IStorage.Space` documents; the test
///      suite pins every slot and decoder against the adapter's behaviour. A sale's book is
///      frozen once it closes (claims never touch live units), so the clearing it computes after
///      the close is the settlement's.
///
///      Gas rule. Every call to another contract forwards all the gas EIP-150 allows; a high-level
///      call reverts on any failure, and the two reads whose refusal has a meaning (the 1/1's
///      clock, and 6529 Stream's settlement record in the abandonment check) use
///      `BoundedCall`'s forward-all reads, which revert with `BoundedCallShortfall` when a
///      failure left at most 1/8 of the gas: a shortfall is never read as a refusal.
abstract contract UniformEditionAuctionLensBase is IUniformEditionAuctionLens {
    address internal immutable _englishAuction;
    address private immutable _escrow;

    /// @dev Departure log entries in a step's head word; four in each word after it.
    uint256 private constant _HEAD_ENTRIES = 3;
    /// @dev The adapter's storage layout (`forge inspect UniformEditionAuction storageLayout`):
    ///      the settings struct's slot and each mapping's base slot. Slot 0 is AccessManaged's.
    uint256 private constant _SLOT_SETTINGS = 1;
    uint256 private constant _SLOT_TERMS = 2;
    uint256 private constant _SLOT_SALES = 3;
    uint256 private constant _SLOT_PAYOUTS = 4;
    uint256 private constant _SLOT_RESULTS = 5;
    uint256 private constant _SLOT_SCANS = 6;
    uint256 private constant _SLOT_BIDS = 7;
    uint256 private constant _SLOT_LIVE = 8;
    uint256 private constant _SLOT_DEPARTURES = 9;
    uint256 private constant _SLOT_CREDITS = 10;
    uint256 private constant _SLOT_SWEEPS = 11;
    /// @inheritdoc IUniformEditionAuctionLens
    uint32 public constant CLOSE_OFFSET = 15 minutes;
    /// @inheritdoc IUniformEditionAuctionLens
    uint32 public constant ABANDON_DELAY = 21 days;

    /// @param englishAuction_ The adapter's English auction.
    /// @param escrow_ The adapter's revenue escrow.
    constructor(address englishAuction_, address escrow_) {
        _englishAuction = englishAuction_;
        _escrow = escrow_;
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
    /// @dev The 32-bit bounds keep the adapter's stored ID and clocks exact: an ID, a 1/1 end or
    ///      a time of 2^32 or more (7 February 2106) is refused, so no stored value wraps.
    function masterTerms(address token, uint256 id, bytes calldata data)
        external
        returns (MasterTerms memory m)
    {
        if (id > type(uint32).max || !_sells(token)) {
            revert ISaleAdapter.InvalidSaleTerms(token, id);
        }
        address master = _masterFor(token);
        (m.oneOfOneEnd, m.oneOfOneState) = _oneOfOne(token, master, id);
        (bytes32 itemHash,,, uint8 kind,,) = IStream(master).coreOf(id);
        PackageItem memory item = _item(token, id, itemHash, data);
        EditionTerms memory e = item.edition;
        if (
            kind != uint8(ItemKind.EDITION_MASTER) || WorksHashing.itemHash(item) != itemHash
                || e.saleKind != SaleKind.UNIFORM_AUCTION || e.currency != CURRENCY_ETH
                || e.params.length != 0
        ) revert ISaleAdapter.InvalidSaleTerms(token, id);
        m.maxCount = e.maxCount;
        WorkTerms memory w = _previewTerms(token, id, item.payees);
        // No payment from this sale may reach an undeployed wallet (rule 4: no fund movement
        // depends on the future price of deploying code): deploy the seller's split wallet now,
        // before anything is owed to it, and the royalty receiver's, before any copy can trade.
        // A wallet the ledger already deployed is confirmed, not deployed again.
        address factory = _factory(token);
        _deployWallet(factory, item.payees, w.seller, token, id);
        if (w.royaltyReceiver != w.seller) {
            _deployWallet(
                factory,
                Splits.royaltyPayees(w.seller, w.feeRecipient, w.feeShare),
                w.royaltyReceiver,
                token,
                id
            );
        }
    }

    /// @dev Edition `id`'s 1/1, read with the forward-all clock read: its end and state, never
    ///      NONE or CANCELLED (`NoOneOfOneAuction`), and the 32-bit bounds of an open: a 1/1 end
    ///      or a time of 2^32 or more is refused (`InvalidSaleTerms`), as is an ID (checked
    ///      first by `masterTerms`).
    function _oneOfOne(address token, address master, uint256 id)
        private
        view
        returns (uint64, IEnglishAuction.AuctionState)
    {
        (bool answered, bytes memory clock) = BoundedCall.tryReadAll(
            _englishAuction,
            abi.encodeCall(IEnglishAuctionClock.auctionClock, (_saleIdOf(master, id))),
            96
        );
        if (!answered || clock.length != 96) {
            revert IUniformEditionAuction.NoOneOfOneAuction(master, id);
        }
        (uint256 state, uint256 endTime,) = abi.decode(clock, (uint256, uint256, uint256));
        if (state == uint256(IEnglishAuction.AuctionState.CANCELLED) || state > 5) {
            revert IUniformEditionAuction.NoOneOfOneAuction(master, id);
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (endTime > type(uint32).max || block.timestamp > type(uint32).max) {
            revert ISaleAdapter.InvalidSaleTerms(token, id);
        }
        // Safe: checked above to fit 32 bits; the state is a valid `AuctionState`.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint64(endTime), IEnglishAuction.AuctionState(state));
    }

    /// @dev A preview of the economics `bindMinter` locks and returns in this same transaction,
    ///      which the adapter pays (F1: 6529 Stream Editions is their one source): the ones an
    ///      existing edition recorded, or else the current resolver's (6529 Stream's, read live,
    ///      as Editions reads it). CALLS-1: the escrow refuses to be paid as a wallet, so a sale
    ///      paying it could never settle; it is refused at open.
    function _previewTerms(address token, uint256 id, ISplitWallet.Payee[] memory payees)
        private
        view
        returns (WorkTerms memory w)
    {
        if (IEditions(token).exists(id)) {
            IEditions.Edition memory locked = IEditions(token).edition(id);
            w = WorkTerms(
                locked.seller,
                locked.feeRecipient,
                locked.feeShare,
                locked.royaltyReceiver,
                locked.royaltyRate
            );
        } else {
            w = _newTerms(token, payees);
        }
        if (
            w.seller == address(0) || w.seller == _escrow || w.feeShare > Splits.DENOMINATOR
                || (w.feeShare != 0 && (w.feeRecipient == address(0) || w.feeRecipient == _escrow))
        ) revert ISaleAdapter.InvalidSaleTerms(token, id);
    }

    /// @dev Deploys (or confirms) the split wallet of `payees` (salt zero) through `factory`,
    ///      requiring the address to be `wallet` (`InvalidSaleTerms`): the terms name a wallet the
    ///      payees and the factory do not derive otherwise. A deployed wallet is recognised by the
    ///      ledger's `configOf` (`createWallet` is idempotent for it), never by code at the
    ///      address, so code planted at a predicted address is never accepted (review C, F16).
    function _deployWallet(
        address factory,
        ISplitWallet.Payee[] memory payees,
        address wallet,
        address token,
        uint256 id
    ) private {
        if (ISplitFactory(factory).createWallet(payees, bytes32(0)) != wallet) {
            revert ISaleAdapter.InvalidSaleTerms(token, id);
        }
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function abandonable(uint256 saleId) external view returns (bool ok, uint256 abandonAt) {
        (ok, abandonAt,) = _abandon(saleId);
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function checkAbandon(uint256 saleId) external view returns (bool createEdition) {
        bool ok;
        (ok,, createEdition) = _abandon(saleId);
        if (!ok) revert IUniformEditionAuction.NotAbandonable(saleId);
    }

    /// @dev The abandonment rule (R16). A 1/1 auction that refuses to answer (reverts, or
    ///      answers malformed) counts as finished: the sale's end is then the one the adapter last
    ///      read. A shortfall in any read reverts with `BoundedCallShortfall`. A SETTLING sale
    ///      qualifies only while its scan is in progress (nothing paid): its clearing call can
    ///      only have failed for want of the edition. `create` is whether the master's sale is
    ///      settled in its token, so the edition can be created and the sale completed.
    function _abandon(uint256 saleId)
        private
        view
        returns (bool ok, uint256 abandonAt, bool create)
    {
        IStorage.SaleWord memory a = _opened(saleId);
        if (
            a.status != IUniformEditionAuction.AuctionStatus.OPEN
                && (a.status != IUniformEditionAuction.AuctionStatus.SETTLING
                    || _word(IStorage.Space.SCAN, saleId, 0) == 0)
        ) return (false, 0, false);
        uint256 id = _payout(saleId).id;
        uint256 oneEnd = a.oneOfOneEnd;
        address token = _tokenOfSale(saleId);
        address master = _masterFor(token);
        (bool answered, bytes memory clock) = BoundedCall.tryReadAll(
            _englishAuction,
            abi.encodeCall(IEnglishAuctionClock.auctionClock, (_saleIdOf(master, id))),
            96
        );
        if (answered && clock.length == 96) {
            (uint256 state, uint256 end,) = abi.decode(clock, (uint256, uint256, uint256));
            // Not settled yet (anyone may settle an ended 1/1): the sale's end may still move.
            if (
                state == uint256(IEnglishAuction.AuctionState.ACTIVE)
                    || state == uint256(IEnglishAuction.AuctionState.PAUSED)
                    || state == uint256(IEnglishAuction.AuctionState.ENDED)
            ) return (false, 0, false);
            if (end > oneEnd && end <= type(uint32).max) oneEnd = end;
        }
        // Settled with its master and the edition created: the sale settles as usual.
        create = _masterSettled(master, id);
        if (create && _editionExists(token, id)) return (false, 0, false);
        abandonAt = oneEnd + CLOSE_OFFSET + ABANDON_DELAY;
        // forge-lint: disable-next-line(block-timestamp)
        ok = block.timestamp >= abandonAt;
    }

    /// @dev Whether 6529 Stream records master `id`'s primary sale as settled; a refusal reads as
    ///      not settled, a shortfall reverts.
    function _masterSettled(address master, uint256 id) private view returns (bool) {
        (bool answered, bytes32 word) =
            BoundedCall.tryReadWordAll(master, abi.encodeCall(IStream.primarySaleSettled, (id)));
        return answered && word != 0;
    }

    // ------------------------------------------------------------------- the adapter's own

    /// @inheritdoc IUniformEditionAuctionLens
    function storageWord(IStorage.Space space, uint256 saleId, uint256 key)
        public
        view
        returns (uint256)
    {
        return IStorage(msg.sender).storageAt(_slotOf(space, saleId, key));
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function config() public view returns (IUniformEditionAuction.AuctionConfig memory) {
        // Safe: the 24-bit current terms ID.
        // forge-lint: disable-next-line(unsafe-typecast)
        return _config(uint24(storageWord(IStorage.Space.SETTINGS, 0, 0)));
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function limits() external view returns (IUniformEditionAuction.Limits memory l) {
        // Safe: the settings word's 32-bit payout gas.
        // forge-lint: disable-next-line(unsafe-typecast)
        l.payoutGas = uint32(storageWord(IStorage.Space.SETTINGS, 0, 0) >> 96);
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function claimable(address account, address currency) external view returns (uint256) {
        if (currency != CURRENCY_ETH) return 0;
        return uint208(storageWord(IStorage.Space.CREDIT, 0, uint160(account)));
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function creditExpiresAt(address account) external view returns (uint256) {
        uint256 w = storageWord(IStorage.Space.CREDIT, 0, uint160(account));
        return uint208(w) == 0 ? 0 : (w >> 208) + 180 days;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function feeRecipient(address token, uint256 id) public view returns (address recipient) {
        (IEconomicsResolver resolver, bytes32 product) = _feeSource();
        recipient = resolver.networkFeeRecipient(product);
        if ((recipient == address(0) || recipient == _escrow) && token != address(0)) {
            recipient =
                _editionExists(token, id) ? IEditions(token).edition(id).feeRecipient : address(0);
        }
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function paused() external view returns (bool) {
        return uint40(storageWord(IStorage.Space.SETTINGS, 0, 0) >> 48) != 0;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function saleKind() external pure returns (bytes32) {
        return SaleKind.UNIFORM_AUCTION;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IUniformEditionAuction).interfaceId
            || interfaceId == type(ISaleAdapter).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function saleIdOf(address token, uint256 id) external pure returns (uint256) {
        return _saleIdOf(token, id);
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
        v.token = _tokenOfSale(saleId);
        v.id = p.id;
        v.master = _masterFor(v.token);
        v.oneOfOneSaleId = _saleIdOf(v.master, p.id);
        v.status = _status(a, endTimes(saleId));
        v.maxCount = a.maxCount;
        v.terms = _config(a.termsId);
        v.seller = p.seller;
        v.feeRecipient = feeRecipient(v.token, p.id);
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
        IEnglishAuction.Auction memory o = IEnglishAuction(_englishAuction)
            .auction(_saleIdOf(_masterOfSale(saleId), _payout(saleId).id));
        _clocks(e, a, _config(a.termsId), o.endTime);
        e.oneOfOneState = o.state;
        // Open while the 1/1 is paused, whatever the time; else until the end, unless cancelled.
        // forge-lint: disable-start(block-timestamp)
        e.biddingOpen = a.status == IUniformEditionAuction.AuctionStatus.OPEN
            && (o.state == IEnglishAuction.AuctionState.PAUSED
                || (o.state != IEnglishAuction.AuctionState.CANCELLED
                    && block.timestamp < e.endTime));
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
        uint256 closeAt = oneOfOneEnd + CLOSE_OFFSET;
        uint256 backstop = closeAt + t.maxExtension;
        uint256 soft = a.softEnd > backstop ? backstop : a.softEnd;
        // Safe: 32-bit times plus a 32-bit offset and at most 7 days.
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
        if (a.status == IUniformEditionAuction.AuctionStatus.NONE) return config();
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
        a.termsId = uint24(w >> 8);
        a.maxCount = uint32(w >> 32);
        a.oneOfOneEnd = uint32(w >> 64);
        a.softEnd = uint32(w >> 96);
        a.openedAt = uint32(w >> 128);
        a.lowStep = uint16(w >> 160);
        a.highStep = uint16(w >> 176);
        a.liveUnits = uint32(w >> 192);
        a.bidCount = uint32(w >> 224);
    }

    function _payout(uint256 saleId) private view returns (IStorage.PayoutWord memory p) {
        uint256 w = _word(IStorage.Space.PAYOUT, saleId, 0);
        p.seller = address(uint160(w));
        p.feeShare = uint32(w >> 160);
        p.id = uint32(w >> 192);
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
        t.softWindow = uint32(w >> 160);
        t.maxExtension = uint32(w >> 192);
    }

    // forge-lint: disable-end(unsafe-typecast)

    function _word(IStorage.Space space, uint256 saleId, uint256 key)
        private
        view
        returns (uint256)
    {
        return storageWord(space, saleId, key);
    }

    /// @dev Where word `key` of family `space` of sale `saleId` lives in the adapter, as
    ///      Solidity places mapping values: `keccak256(abi.encode(k, base))` for the mapping at
    ///      `base` (`k` the sale ID, or the key for TERMS and CREDIT), hashed
    ///      again with `key` for the nested families (BID, LIVE, DEPARTURE, SWEEP); SETTINGS is
    ///      the settings slot. An address key (SWEEP, CREDIT) is the address as a number.
    function _slotOf(IStorage.Space space, uint256 saleId, uint256 key)
        private
        pure
        returns (uint256 slot)
    {
        if (space == IStorage.Space.SETTINGS) return _SLOT_SETTINGS;
        uint256 base;
        uint256 k = saleId;
        bool nested;
        if (space == IStorage.Space.SALE) {
            base = _SLOT_SALES;
        } else if (space == IStorage.Space.PAYOUT) {
            base = _SLOT_PAYOUTS;
        } else if (space == IStorage.Space.RESULT) {
            base = _SLOT_RESULTS;
        } else if (space == IStorage.Space.SCAN) {
            base = _SLOT_SCANS;
        } else if (space == IStorage.Space.TERMS) {
            (base, k) = (_SLOT_TERMS, key);
        } else if (space == IStorage.Space.CREDIT) {
            (base, k) = (_SLOT_CREDITS, key);
        } else {
            nested = true;
            if (space == IStorage.Space.BID) base = _SLOT_BIDS;
            else if (space == IStorage.Space.LIVE) base = _SLOT_LIVE;
            else if (space == IStorage.Space.DEPARTURE) base = _SLOT_DEPARTURES;
            else base = _SLOT_SWEEPS;
        }
        slot = uint256(keccak256(abi.encode(k, base)));
        if (nested) slot = uint256(keccak256(abi.encode(key, slot)));
    }

    function _saleIdOf(address token, uint256 id) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, id)));
    }

    // ------------------------------------------------------------------ the deployment

    /// @dev The contract whose 1/1 anchors sale `saleId`.
    function _masterOfSale(uint256 saleId) private view returns (address) {
        return _masterFor(_tokenOfSale(saleId));
    }

    /// @dev The edition contract sale `saleId` sells (the calling adapter's record).
    function _tokenOfSale(uint256 saleId) internal view virtual returns (address);

    /// @dev The contract whose 1/1s anchor `token`'s editions.
    function _masterFor(address token) internal view virtual returns (address);

    /// @dev Whether `masterTerms` may open a sale of `token`.
    function _sells(address token) internal view virtual returns (bool);

    /// @dev The terms a new edition of `payees` on `token` would lock now.
    function _newTerms(address token, ISplitWallet.Payee[] memory payees)
        internal
        view
        virtual
        returns (WorkTerms memory);

    /// @dev The split factory that deploys `token`'s wallets.
    function _factory(address token) internal view virtual returns (address);

    /// @dev Whether `token`'s edition `id` exists, for the abandonment check.
    function _editionExists(address token, uint256 id) internal view virtual returns (bool);

    /// @dev The master's item from `open`'s `data`, checked as the deployment requires;
    ///      `itemHash` is the hash the master stored for edition `id`.
    function _item(address token, uint256 id, bytes32 itemHash, bytes calldata data)
        internal
        view
        virtual
        returns (PackageItem memory);

    /// @dev The economics resolver whose network fee recipient this deployment pays, and the
    ///      product it asks for (R18).
    function _feeSource() internal view virtual returns (IEconomicsResolver, bytes32);
}

/// @title UniformEditionAuctionLens
/// @notice The lens of {UniformEditionAuction}, 6529 Stream Editions' deployment: its one edition
///         contract and 6529 Stream, the economics 6529 Stream's resolver gives new editions.
contract UniformEditionAuctionLens is UniformEditionAuctionLensBase {
    address private immutable _editions;
    address private immutable _stream;

    /// @param editions_ The adapter's 6529 Stream Editions.
    /// @param stream_ Its 6529 Stream.
    /// @param englishAuction_ The adapter's English auction.
    /// @param escrow_ The adapter's revenue escrow.
    constructor(address editions_, address stream_, address englishAuction_, address escrow_)
        UniformEditionAuctionLensBase(englishAuction_, escrow_)
    {
        _editions = editions_;
        _stream = stream_;
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
    function isTarget(address token) external view returns (bool) {
        return token == _editions && uint8(storageWord(IStorage.Space.SETTINGS, 0, 0) >> 88) != 0;
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function federationRegistry() external pure returns (address) {
        return address(0);
    }

    /// @inheritdoc IUniformEditionAuctionLens
    function setFederationRegistry(address, address next) external pure {
        revert ISaleAdapter.TargetNotAllowed(next);
    }

    function _tokenOfSale(uint256) internal view override returns (address) {
        return _editions;
    }

    function _masterFor(address) internal view override returns (address) {
        return _stream;
    }

    function _sells(address token) internal view override returns (bool) {
        return token == _editions;
    }

    function _newTerms(address, ISplitWallet.Payee[] memory payees)
        internal
        view
        override
        returns (WorkTerms memory)
    {
        return IEconomicsResolver(IStream(_stream).economics())
            .newWorkTerms(PRODUCT_EDITIONS, payees);
    }

    /// @dev The resolver's factory is 6529 Stream's own: Stream refuses a replacement resolver
    ///      that names another.
    function _factory(address) internal view override returns (address) {
        return IEconomicsResolver(IStream(_stream).economics()).splitFactory();
    }

    function _editionExists(address token, uint256 id) internal view override returns (bool) {
        return IEditions(token).exists(id);
    }

    /// @dev `data` is `abi.encode(PackageItem item, bytes32 packageRoot, bytes32[] proof)`; the
    ///      item must be in a package 6529 Stream's package registry still approves (C23,
    ///      `IItemApprovals.isApprovedItem`: not revoked, its signer not disabled). The call
    ///      forwards all gas and reverts on any failure, so a shortfall is never a refusal.
    function _item(address token, uint256 id, bytes32 itemHash, bytes calldata data)
        internal
        view
        override
        returns (PackageItem memory item)
    {
        bytes32 root;
        bytes32[] memory proof;
        (item, root, proof) = abi.decode(data, (PackageItem, bytes32, bytes32[]));
        if (!IItemApprovals(IStream(_stream).packageRegistry())
                .isApprovedItem(root, itemHash, proof)) {
            revert ISaleAdapter.InvalidSaleTerms(token, id);
        }
    }

    /// @dev 6529 Stream's resolver, read now, and the Editions product.
    function _feeSource() internal view override returns (IEconomicsResolver, bytes32) {
        return (IEconomicsResolver(IStream(_stream).economics()), PRODUCT_EDITIONS);
    }
}
