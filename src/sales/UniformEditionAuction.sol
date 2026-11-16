// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { RevenuePayment } from "../economics/RevenuePayment.sol";
import { Splits } from "../economics/Splits.sol";
import { TokenTransfer } from "../economics/TokenTransfer.sol";
import { Roles } from "../governance/Roles.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IEnglishAuctionClock } from "../interfaces/IEnglishAuctionClock.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IStream } from "../interfaces/IStream.sol";
import { IUniformEditionAuction } from "../interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "../interfaces/IUniformEditionAuctionLens.sol";
import { IUniformEditionAuctionStorage } from "../interfaces/IUniformEditionAuctionStorage.sol";
import { CURRENCY_ETH } from "../interfaces/types/EconomicsTypes.sol";
import { SaleKind } from "../interfaces/types/SaleTypes.sol";
import { StepLadder } from "../interfaces/types/StepLadder.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { StreamLayout } from "../stream/StreamLayout.sol";
import { UniformClearing } from "./UniformClearing.sol";

/// @title UniformEditionAuction
/// @notice The uniform-price edition auction (ADR 0005; D138-D141), the one sale of 6529 Stream
///         Editions. See {IUniformEditionAuction} for the rules; this contract adds the storage
///         layout and the bounds. Every view, of a sale or of the adapter's own settings, lives
///         on its lens ({UniformEditionAuctionLens}), deployed on its own and pinned by the
///         constructor.
/// @dev Storage (`IUniformEditionAuctionStorage.Space` documents every word). Per sale: a state word
///      written at open and updated by every bid, raise and withdrawal (`SaleWord`), a payout word
///      written at open (`PayoutWord`) and a result word written at settlement (`ResultWord`).
///      Live units per step, eight 32-bit counters per word, so a bid writes a new word only when
///      it opens a group of eight steps, and settlement reads only the words up to the highest
///      step used. One word per bid, deleted when it is claimed or withdrawn; its escrow,
///      `quantity × price(step)`, is never stored. Capped sales only: each step keeps a departure
///      log (a head word with the count, the departed units and three entries, then four entries
///      per word), and a bid's position is its step's live plus departed units when it enters, so
///      no per-step counter is written. The governed parameters are interned: `setConfig` writes
///      one record per change, a sale whose edition terms name their own close offset writes one
///      record of the current parameters with that offset, and a sale stores its record's 24-bit
///      ID; fee recipients likewise. The governed limits (`Limits`) share the settings word.
///
///      The 1/1's end only ever moves later, so the sale caches it and reads it live
///      (`IEnglishAuctionClock.auctionClock`, the state, end and pause start the English
///      auction answers itself, not through its lens) only when a bid or raise lands within
///      `softWindow` of the cached close, or later. Settlement and withdrawals always read it
///      live, and so does the lens's abandonment check. A cancelled 1/1
///      is therefore seen by the next settlement (anyone may void the sale at once) or by a bid
///      near the close; a bid placed far from the close after the cancel is refunded in full with
///      every other.
///
///      `open` hands its token-specific data to the lens (`masterTerms`), which checks the
///      package item against 6529 Stream and the 1/1, and returns what to lock, so no
///      package-item codec is compiled here (EIP-170); it pays the economics 6529 Stream
///      Editions returns from `bindMinter` (F1). The lens also resolves the sale's close offset
///      and deploys the seller's and royalty receiver's split wallets before any money is owed
///      to them, which is why `open` calls it rather than reading it. The lens is deployed in its own transaction,
///      so this contract's deployment fits a block (F8), and pinned here: code hash and wiring.
///      For the same reason every view of `IUniformEditionAuction` and `ISaleAdapter` is
///      answered by the lens: the adapter forwards the call's own calldata to it (its fallback)
///      and returns its answer unchanged, so callers use one address and one interface.
///
///      Gas rule. Every call out reverts the transaction when it fails: high-level calls and
///      the binding's call forward all gas EIP-150 allows and bubble any failure, so a call
///      that runs out of gas is never read as an answer. The one fixed figure is the payout
///      gas (`Limits.payoutGas`, governed): it bounds what a payee can cost the settler, so a
///      payee that refuses or needs more is paid through the revenue escrow and never blocks
///      settlement; `RevenuePayment.payETH` requires the full figure to be available first.
///
///      v1 serves one token, 6529 Stream Editions (`editions`), whose master contract is
///      `stream`: `setTarget` lists nothing else. Every entry point that moves value is
///      non-reentrant; claims delete the bid before they mint (an ERC-1155 acceptance call) or
///      send ETH.
contract UniformEditionAuction is
    IUniformEditionAuctionStorage,
    AccessManaged,
    ReentrancyGuardTransient
{
    /// @dev `setConfig` bounds besides the ladder's (`StepLadder`; ADR 0005 section 4). The
    ///      default close offset is bounded by `Limits.maxCloseOffset`.
    uint256 private constant _MAX_MARGIN_SHARE = 50_000;
    uint256 private constant _MIN_SOFT_WINDOW = 1 minutes;
    uint256 private constant _MAX_SOFT_WINDOW = 1 hours;
    uint256 private constant _MIN_MAX_EXTENSION = 1 hours;
    uint256 private constant _MAX_MAX_EXTENSION = 7 days;
    /// @dev `setLimits` bounds (ADR 0005 section 4, as amended 15 November 2026). The close
    ///      offset's maximum is the only cap on an edition's open period, and these bounds only
    ///      keep it sane: at least a day, at most about ten years. The abandonment delay is at
    ///      least 120 days: governance's 30-day replacement of a dependency of the master's
    ///      settlement (or of its 1/1 adapter) plus 6529 Stream's 90-day rescue floor, so a sale
    ///      whose master waits on a repair or a rescue is never abandoned before either can land;
    ///      when governance lengthens Stream's rescue delay, `abandon` (and the lens) wait the
    ///      difference too, up to the governed rescue cap (90 to 730 days): the cap is the
    ///      bound on how long a governance lever can hold bidders' ETH.
    ///      The payout gas fits a split wallet's or a Safe's receive at its floor, and keeps a
    ///      settle call's two payouts far inside the 16,777,216 transaction cap at its ceiling.
    uint256 private constant _MIN_MAX_CLOSE_OFFSET = 1 days;
    uint256 private constant _MAX_MAX_CLOSE_OFFSET = 3650 days;
    uint256 private constant _MIN_VOID_DELAY_DAYS = 120;
    /// @dev 6529 Stream's permanent `RESCUE_DELAY_FLOOR` (90 days), which the 120-day minimum
    ///      assumes; `abandon` adds what Stream's current `rescueDelay` adds to it.
    uint256 private constant _RESCUE_FLOOR = 90 days;
    uint256 private constant _MAX_VOID_DELAY_DAYS = 730;
    uint256 private constant _MIN_RESCUE_CAP_DAYS = 90;
    uint256 private constant _MAX_RESCUE_CAP_DAYS = 730;
    uint256 private constant _MIN_PAYOUT_GAS = 30_000;
    uint256 private constant _MAX_PAYOUT_GAS = 3_000_000;
    /// @dev The end while the 1/1 is paused for a dispute: undetermined.
    uint64 private constant _NO_END = type(uint64).max;
    /// @dev The ladder's E192 mantissas, `round(100·10^(j/192))` for j = 0..191, two bytes
    ///      each, exactly as `StepLadder.mantissa` gives them (the tests check every step's
    ///      price against `StepLadder.price`). A byte table rather than `StepLadder`'s
    ///      branches, so the settlement scan reads a mantissa in a few gas. Padded with 32
    ///      zero bytes, so the 32-byte load that reads any entry stays inside the table.
    bytes private constant _MANTISSAS = hex"00640065006600680069006a006b006d006e006f007100720073007500760078"
        hex"0079007b007c007e007f008100820084008500870089008a008c008e008f0091"
        hex"0093009500960098009a009c009e00a000a200a400a500a700a900ac00ae00b0"
        hex"00b200b400b600b800bb00bd00bf00c100c400c600c800cb00cd00d000d200d5"
        hex"00d700da00dd00df00e200e500e800ea00ed00f000f300f600f900fc00ff0102"
        hex"01050108010b010f011201150118011c011f01230126012a012d013101350138"
        hex"013c014001440148014c015001540158015c016001650169016d01720176017b"
        hex"017f01840188018d01920197019c01a101a601ab01b001b501ba01c001c501cb"
        hex"01d001d601db01e101e701ed01f301f901ff0205020b02120218021e0225022c"
        hex"0232023902400247024e0255025c0264026b0272027a028202890291029902a1"
        hex"02a902b202ba02c202cb02d302dc02e502ee02f7030003090313031c03260330"
        hex"03390343034d03580362036c03770382038d039703a303ae03b903c503d003dc"
        hex"0000000000000000000000000000000000000000000000000000000000000000";
    /// @dev Departure log entries in a step's head word; four in each word after it.
    uint256 private constant _HEAD_ENTRIES = 3;
    /// @dev Settlement runs in calls of bounded gas, each permissionless and each advancing it, so
    ///      every call fits the settlement budget whatever the book and its departure logs (ADR
    ///      0004): a call scans at most {_SCAN_WORDS} live words (eight steps each), the call
    ///      that finishes the scan sweeps at most {_SWEEP_FIRST} departures, and each later call
    ///      at most {_SWEEP_CHUNK}.
    uint256 private constant _SCAN_WORDS = 24;
    uint256 private constant _SWEEP_FIRST = 16;
    uint256 private constant _SWEEP_CHUNK = 96;

    /// @dev The current parameters' ID, the interning counters, the open pause (when it began,
    ///      zero while not paused), whether `_editions` is listed, and the governed limits
    ///      (`IUniformEditionAuction.Limits`): read once per open (`Space.SETTINGS` documents
    ///      the packing).
    struct Settings {
        uint24 termsId;
        uint24 termsCount;
        uint16 feeRecipientCount;
        uint40 pausedAt;
        bool listed;
        uint32 maxCloseOffset;
        uint16 voidDelayDays;
        uint32 payoutGas;
        uint16 rescueCapDays;
    }

    /// @dev The revenue escrow that receives refused payouts.
    address private immutable _escrow;
    /// @dev The English auction whose 1/1 sales anchor the edition sales.
    address private immutable _englishAuction;
    /// @inheritdoc IUniformEditionAuctionStorage
    address public immutable lens;
    /// @dev 6529 Stream Editions, the one token this adapter sells.
    address private immutable _editions;
    /// @dev 6529 Stream, the master contract of `_editions`, whose 1/1s the English auction
    ///      sells.
    address private immutable _stream;

    Settings private _settings;
    mapping(uint256 termsId => IUniformEditionAuction.AuctionConfig) private _terms;
    mapping(address recipient => uint16) private _feeRecipientIds;
    mapping(uint256 index => address) private _feeRecipients;
    mapping(uint256 saleId => SaleWord) private _sales;
    mapping(uint256 saleId => PayoutWord) private _payouts;
    mapping(uint256 saleId => ResultWord) private _results;
    /// @dev A scan in progress, packed as `ScanWord` is (from the least significant bit).
    mapping(uint256 saleId => uint256) private _scans;
    mapping(uint256 saleId => mapping(uint256 bidId => BidWord)) private _bids;
    mapping(uint256 saleId => mapping(uint256 word => uint256)) private _live;
    mapping(uint256 saleId => mapping(uint256 key => uint256)) private _departures;
    mapping(address account => uint256) private _credits;
    /// @dev Each settler's own sweep in progress (`Space.SWEEP`), packed `swept | nextPosition
    ///      << 32 | cutoff << 64`: written only by a call that sweeps without finishing, deleted
    ///      when that settler finishes. Per settler, so an order that skips a departure strands only its own
    ///      sender's progress, never the sale.
    mapping(uint256 saleId => mapping(address settler => uint256)) private _sweeps;

    /// @param authority_ The AccessManager governing the setters and the pause.
    /// @param escrow_ The revenue escrow for refused payouts.
    /// @param editions_ 6529 Stream Editions (ERC-165 `IEditions`, not EIP-7702 delegated); its
    ///        6529 Stream is read from it.
    /// @param englishAuction_ The English auction (ERC-165 `IEnglishAuction`) that sells the 1/1s.
    /// @param lens_ The lens, deployed beforehand in its own transaction (so this contract's
    ///        deployment fits a block): it must have code, no EIP-7702 delegation, the code hash
    ///        `lensCodeHash` and this adapter's Editions, Stream, English auction and escrow.
    /// @param lensCodeHash The lens's reviewed code hash.
    /// @param config_ The initial governed parameters.
    /// @param limits_ The initial governed limits.
    constructor(
        address authority_,
        address escrow_,
        address editions_,
        address englishAuction_,
        address lens_,
        bytes32 lensCodeHash,
        IUniformEditionAuction.AuctionConfig memory config_,
        IUniformEditionAuction.Limits memory limits_
    ) AccessManaged(authority_) {
        Dependency.check(escrow_);
        Dependency.check(editions_, type(IEditions).interfaceId);
        Dependency.check(englishAuction_, type(IEnglishAuction).interfaceId);
        address stream_ = IEditions(editions_).stream();
        Dependency.check(stream_, type(IStream).interfaceId);
        Dependency.checkPinned(lens_, lensCodeHash);
        IUniformEditionAuctionLens l = IUniformEditionAuctionLens(lens_);
        if (
            l.editions() != editions_ || l.stream() != stream_
                || l.englishAuction() != englishAuction_ || l.escrow() != escrow_
        ) revert Dependency.InvalidDependency(lens_);
        _escrow = escrow_;
        _englishAuction = englishAuction_;
        _editions = editions_;
        _stream = stream_;
        lens = lens_;
        _setLimits(
            uint256(limits_.maxCloseOffset) | uint256(limits_.voidDelayDays) << 32
                | uint256(limits_.payoutGas) << 48 | uint256(limits_.rescueCapDays) << 80
        );
        _setConfig(config_);
    }

    // ------------------------------------------------------------------------------- open

    /// @notice Opens the sale of edition `id` on `token` (`IUniformEditionAuction.open`).
    /// @dev Binds the edition to this adapter first (`IEditions.bindMinter`, which may precede
    ///      the edition), so an edition another adapter sells refuses the open, and only this
    ///      adapter can ever mint the copies this sale clears. The lens's `masterTerms` checks
    ///      the item, resolves the close offset and deploys the split wallets; a close offset
    ///      other than the current default interns one terms record for this sale.
    /// @param token The edition contract: `_editions`.
    /// @param id The edition ID, the master's 6529 Stream token ID.
    /// @param data `abi.encode(PackageItem)` of the master's EDITION_MASTER item.
    /// @return saleId `saleIdOf(token, id)`.
    function open(address token, uint256 id, bytes calldata data)
        external
        nonReentrant
        returns (uint256 saleId)
    {
        Settings memory st = _settings;
        if (st.pausedAt != 0) revert ISaleAdapter.SalePaused();
        if (token != _editions || !st.listed) revert ISaleAdapter.TargetNotAllowed(token);
        saleId = _saleIdOf(token, id);
        SaleWord storage a = _sales[saleId];
        if (a.status != IUniformEditionAuction.AuctionStatus.NONE) {
            revert IUniformEditionAuction.AuctionExists(saleId);
        }
        IUniformEditionAuctionLens.MasterTerms memory m =
            IUniformEditionAuctionLens(lens).masterTerms(token, id, data);
        IUniformEditionAuction.AuctionConfig memory t = _terms[st.termsId];
        uint24 termsId = st.termsId;
        if (m.closeOffset != type(uint32).max && m.closeOffset != t.closeOffset) {
            // The edition's own close offset (`DEFAULT_CLOSE_OFFSET` names none), which the lens
            // checked against the maximum: this sale locks a record of the current parameters
            // with it.
            t.closeOffset = m.closeOffset;
            termsId = _intern(t);
        }
        uint256 closeAt = uint256(m.oneOfOneEnd) + t.closeOffset;
        // forge-lint: disable-next-line(block-timestamp)
        if (m.oneOfOneState != IEnglishAuction.AuctionState.PAUSED && block.timestamp >= closeAt) {
            // Safe: a 32-bit end plus a 32-bit offset.
            // forge-lint: disable-next-line(unsafe-typecast)
            revert IUniformEditionAuction.BiddingClosed(saleId, uint64(closeAt));
        }
        // F1: the sale pays exactly the economics 6529 Stream Editions locks for the edition and
        // returns, their one source (the lens checked a preview of them above, and deployed the
        // wallets it names).
        (address seller, address feeRecipient, uint256 feeShare) = _bindEdition(id, data);
        uint16 feeRecipientId = feeShare == 0 ? 0 : _feeRecipientId(token, id, feeRecipient);
        // Safe: the lens's `masterTerms` refuses an ID, a 1/1 end or a time of 2^32 or more
        // (`InvalidSaleTerms`), so a sale never opens past 2106 rather than wrapping; a fee share
        // is at most 100,000 (checked by the lens); `closeAt` is below 2^33.
        // forge-lint: disable-start(unsafe-typecast)
        a.status = IUniformEditionAuction.AuctionStatus.OPEN;
        a.termsId = termsId;
        a.maxCount = m.maxCount;
        a.oneOfOneEnd = uint32(m.oneOfOneEnd);
        a.openedAt = uint32(block.timestamp);
        _payouts[saleId] =
            PayoutWord(seller, uint32(feeShare), feeRecipientId, uint32(id), st.voidDelayDays);
        emit ISaleAdapter.SaleStarted(
            saleId,
            token,
            id,
            SaleKind.UNIFORM_AUCTION,
            CURRENCY_ETH,
            _price(t, 0),
            uint64(block.timestamp),
            uint64(closeAt)
        );
        emit IUniformEditionAuction.AuctionOpened(
            saleId, token, id, _stream, m.maxCount, t, uint64(closeAt)
        );
        // forge-lint: disable-end(unsafe-typecast)
    }

    // ---------------------------------------------------------------------------- bidding

    /// @notice Bids `quantity` units at `step`, paying exactly their escrow
    ///         (`IUniformEditionAuction.bid`).
    /// @param saleId The sale ID.
    /// @param step A step below the sale's `stepCount`.
    /// @param quantity Units, from 1.
    /// @return bidId The new bid's ID.
    function bid(uint256 saleId, uint256 step, uint256 quantity)
        external
        payable
        nonReentrant
        returns (uint256 bidId)
    {
        SaleWord memory a = _open(saleId);
        IUniformEditionAuction.AuctionConfig memory t = _terms[a.termsId];
        if (step >= t.stepCount) revert IUniformEditionAuction.InvalidStep(step);
        uint256 units = uint256(a.liveUnits) + quantity;
        bidId = uint256(a.bidCount) + 1;
        if (quantity == 0 || units > type(uint32).max || bidId > type(uint32).max) {
            revert IUniformEditionAuction.InvalidQuantity(quantity);
        }
        uint256 amount = quantity * _price(t, step);
        if (msg.value != amount) revert IUniformEditionAuction.IncorrectPayment(amount, msg.value);
        uint64 endTime = _extend(saleId, a, t);
        // Safe: steps are below 512, and the units and the bid ID were checked above.
        // forge-lint: disable-start(unsafe-typecast)
        if (a.liveUnits == 0) {
            (a.lowStep, a.highStep) = (uint16(step), uint16(step));
        } else if (step < a.lowStep) {
            a.lowStep = uint16(step);
        } else if (step > a.highStep) {
            a.highStep = uint16(step);
        }
        (a.liveUnits, a.bidCount) = (uint32(units), uint32(bidId));
        uint32 position = _enter(saleId, a.maxCount != 0, step, quantity);
        _sales[saleId] = a;
        _bids[saleId][bidId] = BidWord(
            msg.sender,
            uint16(step),
            uint32(quantity),
            position,
            _minutes(a.openedAt, block.timestamp)
        );
        // forge-lint: disable-end(unsafe-typecast)
        emit IUniformEditionAuction.BidPlaced(
            saleId, bidId, msg.sender, step, quantity, position, endTime
        );
    }

    /// @notice Moves the caller's bid up to `newStep`, paying exactly the difference
    ///         (`IUniformEditionAuction.raise`).
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @param newStep A step above the bid's and below `stepCount`.
    function raise(uint256 saleId, uint256 bidId, uint256 newStep) external payable nonReentrant {
        SaleWord memory a = _open(saleId);
        BidWord memory b = _bidOf(saleId, bidId);
        if (b.bidder != msg.sender) revert IUniformEditionAuction.NotBidder(msg.sender);
        IUniformEditionAuction.AuctionConfig memory t = _terms[a.termsId];
        if (newStep <= b.step || newStep >= t.stepCount) {
            revert IUniformEditionAuction.InvalidStep(newStep);
        }
        uint256 paid = uint256(b.quantity) * (_price(t, newStep) - _price(t, b.step));
        if (msg.value != paid) revert IUniformEditionAuction.IncorrectPayment(paid, msg.value);
        uint64 endTime = _extend(saleId, a, t);
        // Safe: below `stepCount`, at most 512.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (newStep > a.highStep) a.highStep = uint16(newStep);
        bool capped = a.maxCount != 0;
        _leave(saleId, capped, b.step, b.position, b.quantity);
        uint32 position = _enter(saleId, capped, newStep, b.quantity);
        _sales[saleId] = a;
        BidWord storage stored = _bids[saleId][bidId];
        // A raise is new demand: it restarts the bid's placement minute. Safe: below
        // `stepCount`, at most 512.
        // forge-lint: disable-start(unsafe-typecast)
        (stored.step, stored.position, stored.placedMinute) =
        (uint16(newStep), position, _minutes(a.openedAt, block.timestamp));
        // forge-lint: disable-end(unsafe-typecast)
        emit IUniformEditionAuction.BidRaised(
            saleId, bidId, msg.sender, b.step, newStep, position, paid, endTime
        );
    }

    /// @notice Withdraws the caller's bid while the 1/1 is paused for a dispute, if the bid was
    ///         placed (or last raised) before the pause, sending its escrow to `to`
    ///         (`IUniformEditionAuction.withdrawBid`).
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @param to The address that receives the escrow.
    function withdrawBid(uint256 saleId, uint256 bidId, address to) external nonReentrant {
        if (to == address(0)) revert ISaleAdapter.InvalidRecipient(to);
        SaleWord storage a = _sales[saleId];
        _requireStatus(saleId, a.status, IUniformEditionAuction.AuctionStatus.OPEN);
        BidWord memory b = _bidOf(saleId, bidId);
        if (b.bidder != msg.sender) revert IUniformEditionAuction.NotBidder(msg.sender);
        // Only a bid placed (or last raised) in a minute that ended before the 1/1's dispute
        // pause began may leave (decision 12, as amended): demand added during the pause, or in
        // the pause's own minute, is firm, so a pause cannot be used to fake demand, and a bid
        // is never withdrawn in the block that placed it. A saturated minute is never early.
        (IEnglishAuction.AuctionState state,, uint64 pausedAt) = _oneOfOneClock(saleId);
        if (
            state != IEnglishAuction.AuctionState.PAUSED
                || b.placedMinute >= _minutes(a.openedAt, pausedAt)
        ) revert IUniformEditionAuction.WithdrawalsClosed(saleId);
        a.liveUnits -= b.quantity;
        _leave(saleId, a.maxCount != 0, b.step, b.position, b.quantity);
        delete _bids[saleId][bidId];
        uint256 amount = uint256(b.quantity) * _price(_terms[a.termsId], b.step);
        emit IUniformEditionAuction.BidWithdrawn(saleId, bidId, msg.sender, to, amount);
        if (!TokenTransfer.sendETH(to, amount, gasleft())) revert ISaleAdapter.ClaimFailed(to);
    }

    // ------------------------------------------------------------------------- settlement

    /// @notice Settles a closed sale, or voids it after a 1/1 cancel, in calls of bounded gas
    ///         (`IUniformEditionAuction.settle`): the first checks the close and the 1/1 and
    ///         starts scanning the book; each call scans up to 24 words of it; the call that
    ///         finishes the scan stores the result, pays it and starts its caller's departure
    ///         sweep; later calls continue their caller's sweep. Every call is permissionless.
    ///         Each settler sweeps on its own (`_sweeps`): `order` is the caller's remaining
    ///         slice (`settlementOrderFor`), and the first settler to sweep every departure
    ///         settles the sale. A call on a SETTLED sale returns `true`; on a VOID one it
    ///         reverts.
    /// @param saleId The sale ID.
    /// @param order The next departure indexes of the caller's own sweep, in position order.
    /// @return Whether the sale is now SETTLED or VOID.
    /// @dev Pays with `RevenuePayment.payETH`, `Limits.payoutGas` per wallet: a refusal is
    ///      escrowed for that wallet and never blocks settlement.
    function settle(uint256 saleId, uint256[] calldata order) external nonReentrant returns (bool) {
        SaleWord storage stored = _sales[saleId];
        IUniformEditionAuction.AuctionStatus status = stored.status;
        if (status != IUniformEditionAuction.AuctionStatus.OPEN) {
            // Another settler finished first: nothing left to do.
            if (status == IUniformEditionAuction.AuctionStatus.SETTLED) return true;
            _requireStatus(saleId, status, IUniformEditionAuction.AuctionStatus.SETTLING);
            // Cleared already: sweep the clearing step's departures.
            if (_scans[saleId] == 0) return _sweep(saleId, stored, order, _SWEEP_CHUNK);
        }
        // The sale word and its terms, read once for the whole call (I-1).
        SaleWord memory a = _saleWord(stored);
        IUniformEditionAuction.AuctionConfig memory t = _config(a.termsId);
        if (status == IUniformEditionAuction.AuctionStatus.OPEN && _begin(saleId, stored, a, t)) {
            return true;
        }
        (bool cleared, uint256 count, uint256 price) = _scanChunk(saleId, stored, a, t);
        if (!cleared) return false;
        bool settled = stored.status == IUniformEditionAuction.AuctionStatus.SETTLED
            || _sweep(saleId, stored, order, _SWEEP_FIRST);
        // The payout comes last, after every write of this call.
        _pay(saleId, _payouts[saleId], count, price);
        return settled;
    }

    /// @notice Claims the caller's bid: its copies and its refund to `to`
    ///         (`IUniformEditionAuction.claimBid`).
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @param to The address that receives the copies and the refund.
    /// @return unitsWon Copies minted.
    /// @return refund Wei sent to `to`.
    function claimBid(uint256 saleId, uint256 bidId, address to)
        external
        nonReentrant
        returns (uint256 unitsWon, uint256 refund)
    {
        if (to == address(0) || to == address(this)) {
            revert ISaleAdapter.InvalidRecipient(to);
        }
        BidWord memory b = _bidOf(saleId, bidId);
        if (b.bidder != msg.sender) revert IUniformEditionAuction.NotBidder(msg.sender);
        (unitsWon, refund) = _claim(saleId, bidId, b, to);
        if (refund != 0 && !TokenTransfer.sendETH(to, refund, gasleft())) {
            revert ISaleAdapter.ClaimFailed(to);
        }
    }

    /// @notice Claims a bid for its bidder: copies to the bidder, refund credited
    ///         (`IUniformEditionAuction.claimBidFor`).
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @return unitsWon Copies minted to the bidder.
    /// @return refund Wei credited to the bidder.
    function claimBidFor(uint256 saleId, uint256 bidId)
        external
        nonReentrant
        returns (uint256 unitsWon, uint256 refund)
    {
        BidWord memory b = _bidOf(saleId, bidId);
        (unitsWon, refund) = _claim(saleId, bidId, b, b.bidder);
        if (refund != 0) {
            _credits[b.bidder] += refund;
            emit ISaleAdapter.Credited(b.bidder, CURRENCY_ETH, saleId, refund);
        }
    }

    /// @notice Pays the caller's claimable credits in `currency` to `to` (`ISaleAdapter.claim`).
    /// @dev Only ETH is ever credited; any other currency has nothing to claim.
    /// @param currency The currency; only `CURRENCY_ETH` has credits.
    /// @param to The recipient.
    /// @return amount The amount paid.
    function claim(address currency, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ISaleAdapter.InvalidRecipient(to);
        amount = currency == CURRENCY_ETH ? _credits[msg.sender] : 0;
        if (amount == 0) revert ISaleAdapter.NothingToClaim(msg.sender, currency);
        _credits[msg.sender] = 0;
        emit ISaleAdapter.Claimed(msg.sender, currency, to, amount);
        if (!TokenTransfer.sendETH(to, amount, gasleft())) revert ISaleAdapter.ClaimFailed(to);
    }

    /// @notice Voids an OPEN sale whose master cannot be settled, refunding every bid and sealing
    ///         the edition at zero (`IUniformEditionAuction.abandon`).
    /// @dev The lens decides (`checkAbandon`, which reverts with `NotAbandonable`): it reads the
    ///      1/1 and 6529 Stream, forwarding all gas and reverting on a shortfall. This adapter
    ///      then enforces the state rule and the time floor itself (`NotAbandonable` before the
    ///      stored end plus the delay plus Stream's capped rescue lengthening), so a lens that
    ///      answers early cannot void a sale or seal its edition early. The seal makes
    ///      the supply question final: the edition is bound to this adapter, which never mints a
    ///      void sale's copies, so no copy of it can ever exist (Editions accepts a seal at zero
    ///      before or after `createEdition`, since nothing was minted).
    /// @param saleId The sale ID.
    function abandon(uint256 saleId) external nonReentrant {
        IUniformEditionAuctionLens(lens).checkAbandon(saleId);
        // Only a sale that has paid nothing: OPEN, or SETTLING with its scan still in progress
        // (the clearing call, which pays, never completed). The lens refuses every other state
        // too; this guard keeps a paid sale from ever being voided whatever the lens answers.
        SaleWord storage a = _sales[saleId];
        IUniformEditionAuction.AuctionStatus status = a.status;
        if (
            status != IUniformEditionAuction.AuctionStatus.OPEN
                && (status != IUniformEditionAuction.AuctionStatus.SETTLING || _scans[saleId] == 0)
        ) revert IUniformEditionAuction.InvalidAuctionState(saleId, status);
        // L-3, L-4 and review N-2: the time floor from this adapter's own words, whatever the
        // lens answers. The stored close (`closeAt`; the 1/1's end only moves later, so the
        // stored one is never late, and a soft end is at most `maxExtension`, 7 days, past it)
        // plus the locked abandonment delay (at least 120 days), plus the rescue addition
        // ({_rescueAddition}): how much later than the close plus the 90-day floor 6529 Stream
        // lets the master be rescued, at most the rescue cap. So a sale is never voided while it
        // takes bids, and never voided, nor its edition sealed at zero, before a master waiting
        // on a rescue could be rescued, with the delay's 30 days or more past that to do it;
        // the cap takes precedence, so its bidders always have an exit at most the cap later.
        PayoutWord storage p = _payouts[saleId];
        uint256 close;
        // Safe: a 32-bit time and a 32-bit offset cannot overflow.
        unchecked {
            close = uint256(a.oneOfOneEnd) + _terms[a.termsId].closeOffset;
        }
        if (
            // forge-lint: disable-next-line(block-timestamp)
            block.timestamp
                < close + uint256(p.voidDelayDays) * 1 days
                    + _rescueAddition(close, _settings.rescueCapDays)
        ) {
            revert IUniformEditionAuction.NotAbandonable(saleId);
        }
        _void(saleId, a);
        _seal(p.id, 0);
    }

    // ------------------------------------------------------------------------- governance

    /// @notice Sets the governed parameters for sales opened afterwards; PARAMETER_SETTER,
    ///         compare-and-set (`IUniformEditionAuction.setConfig`).
    /// @param expected The parameters the caller expects are current.
    /// @param next The new parameters.
    function setConfig(
        IUniformEditionAuction.AuctionConfig calldata expected,
        IUniformEditionAuction.AuctionConfig calldata next
    ) external restricted {
        if (keccak256(abi.encode(expected)) != keccak256(abi.encode(_terms[_settings.termsId]))) {
            revert ISaleAdapter.ExpectedValueMismatch();
        }
        _setConfig(next);
    }

    /// @notice Sets the governed limits; PARAMETER_SETTER, compare-and-set
    ///         (`IUniformEditionAuction.setLimits`).
    /// @param expected The packed limits the caller expects are current.
    /// @param next The new packed limits.
    function setLimits(uint256 expected, uint256 next) external restricted {
        if (expected != _limits()) revert ISaleAdapter.ExpectedValueMismatch();
        _setLimits(next);
    }

    /// @notice Stops new opens (`ISaleAdapter.pause`); PAUSER.
    /// @dev Stops new opens only: running sales bid, settle and claim as usual.
    function pause() external restricted {
        if (_settings.pausedAt != 0) revert ISaleAdapter.SalePaused();
        // Safe: a timestamp, far below 2^40.
        // forge-lint: disable-next-line(unsafe-typecast)
        _settings.pausedAt = uint40(block.timestamp);
        emit ISaleAdapter.Paused(msg.sender);
    }

    /// @notice Lifts the pause (`ISaleAdapter.unpause`); UNPAUSER.
    /// @dev Reverts with `UnpauseTooEarly` before `pausedAt + Roles.STANDARD` (GOV-5).
    function unpause() external restricted {
        uint256 pausedAt = _settings.pausedAt;
        if (pausedAt == 0) revert ISaleAdapter.NotPaused();
        uint256 allowedAt = pausedAt + Roles.STANDARD;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < allowedAt) revert ISaleAdapter.UnpauseTooEarly(allowedAt);
        _settings.pausedAt = 0;
        emit ISaleAdapter.Unpaused(msg.sender);
    }

    /// @notice Lists or unlists `token` (`ISaleAdapter.setTarget`); SUCCESSOR_SETTER.
    /// @dev Only `_editions` can be listed in v1. Unlisting stops new opens; running sales finish.
    ///      This adapter serves no federated token, so it keeps no federation registry: the
    ///      lens answers `federationRegistry` with zero and refuses `setFederationRegistry`.
    /// @param token The token: 6529 Stream Editions.
    /// @param listed Whether it is served.
    function setTarget(address token, bool listed) external restricted {
        if (token != _editions) revert ISaleAdapter.TargetNotAllowed(token);
        _settings.listed = listed;
        emit ISaleAdapter.TargetSet(token, listed);
    }

    // ------------------------------------------------------------------------------ views

    /// @notice Answers every view of `IUniformEditionAuction` and `ISaleAdapter` this contract
    ///         does not declare (`auction`, `endTimes`, `clearing`, `settlement`, `bidOf`,
    ///         `bidOutcome`, `quote`, `lowestWinningStep`, `stepPrice`, `ladder`, `stepTotals`,
    ///         `departures`, `settlementOrder`, `abandonable`, `config`, `limits`, `saleIdOf`,
    ///         `englishAuction`, `escrow`, `saleKind`, `paused`, `isTarget`, `claimable`,
    ///         `federationRegistry`, `supportsInterface`): it sends this call's calldata
    ///         unchanged to the lens, which declares each with the same signature, and returns or
    ///         reverts with its answer. Any other call reverts there. ETH is refused.
    /// @dev A read-only `staticcall` to the fixed, stateless lens this contract pinned; no
    ///      delegatecall. The lens reads its caller, this contract. The views live there because this contract's write path alone nearly
    ///      fills EIP-170.
    fallback() external {
        address target = lens;
        // Invariants: `target` is the immutable lens; `staticcall` cannot change any state, so
        // a view answered here is exactly the lens's answer. The calldata and the returndata are
        // copied over memory from offset 0, which is not memory-safe and need not be: the frame
        // ends in `return` or `revert` right after, and no Solidity code reads memory again.
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := staticcall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if ok { return(0, returndatasize()) }
            revert(0, returndatasize())
        }
    }

    /// @inheritdoc IUniformEditionAuctionStorage
    function storageAt(uint256 slot) external view returns (uint256 word) {
        // Invariant: loads one slot and touches no memory.
        assembly ("memory-safe") {
            word := sload(slot)
        }
    }

    // --------------------------------------------------------------------------- internal

    /// @dev The index of `recipient`, registered on first use.
    function _feeRecipientId(address token, uint256 id, address recipient)
        private
        returns (uint16 index)
    {
        index = _feeRecipientIds[recipient];
        if (index == 0) {
            uint16 count = _settings.feeRecipientCount;
            if (count == type(uint16).max) revert ISaleAdapter.InvalidSaleTerms(token, id);
            index = count + 1;
            _settings.feeRecipientCount = index;
            _feeRecipientIds[recipient] = index;
            _feeRecipients[index] = recipient;
        }
    }

    /// @dev For a bid or raise on OPEN sale `a`: requires bidding open (the end not passed, the
    ///      1/1 not cancelled when read), applies the soft close to `a` (D141) and returns the end
    ///      after it, or {_NO_END} while the 1/1 is paused (which never extends).
    function _extend(
        uint256 saleId,
        SaleWord memory a,
        IUniformEditionAuction.AuctionConfig memory t
    ) private view returns (uint64) {
        (uint256 endTime, uint256 closeAt, IEnglishAuction.AuctionState one) =
            _end(saleId, a, t, false);
        if (one == IEnglishAuction.AuctionState.PAUSED) return _NO_END;
        // forge-lint: disable-next-line(block-timestamp)
        if (one == IEnglishAuction.AuctionState.CANCELLED || block.timestamp >= endTime) {
            // Safe: a 32-bit time plus two 32-bit durations.
            // forge-lint: disable-next-line(unsafe-typecast)
            revert IUniformEditionAuction.BiddingClosed(saleId, uint64(endTime));
        }
        uint256 extended = block.timestamp + t.softWindow;
        if (extended > endTime) {
            uint256 backstop = closeAt + t.maxExtension;
            endTime = extended < backstop ? extended : backstop;
            // Checked: a soft end past 2106 reverts the bid instead of wrapping.
            a.softEnd = _u32(endTime);
        }
        // Safe: below 2^34, as above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(endTime);
    }

    /// @dev The end of OPEN sale `a`: `max(closeAt, softEnd)`, the soft end held within
    ///      `maxExtension` of `closeAt = oneOfOneEnd + closeOffset` (the sale's own offset, in its
    ///      locked terms). Reads the 1/1 when `fresh`,
    ///      or when the cached close is within `softWindow` of now or past (the 1/1's end only
    ///      moves later, so nothing earlier can change), recording a later end in `a`. Returns
    ///      the 1/1's state when read, ACTIVE when not; while it is PAUSED the end is meaningless.
    function _end(
        uint256 saleId,
        SaleWord memory a,
        IUniformEditionAuction.AuctionConfig memory t,
        bool fresh
    ) private view returns (uint256 endTime, uint256 closeAt, IEnglishAuction.AuctionState one) {
        closeAt = uint256(a.oneOfOneEnd) + t.closeOffset;
        one = IEnglishAuction.AuctionState.ACTIVE;
        // forge-lint: disable-next-line(block-timestamp)
        if (fresh || block.timestamp + t.softWindow >= closeAt) {
            uint64 oneEnd;
            (one, oneEnd,) = _oneOfOneClock(saleId);
            if (oneEnd > a.oneOfOneEnd) {
                // The 1/1 stores its end in 32 bits; checked all the same.
                a.oneOfOneEnd = _u32(oneEnd);
                closeAt = uint256(oneEnd) + t.closeOffset;
            }
        }
        uint256 soft = a.softEnd;
        uint256 backstop = closeAt + t.maxExtension;
        if (soft > backstop) soft = backstop;
        endTime = soft > closeAt ? soft : closeAt;
    }

    /// @dev The first settle call's checks: voids the sale if the 1/1 was cancelled (returns
    ///      true), or requires the close passed and the 1/1 settled and moves the sale to
    ///      SETTLING, its book frozen for the scan. `a` and `t` are `stored` and its terms as
    ///      `settle` read them; `a.oneOfOneEnd` is refreshed here.
    function _begin(
        uint256 saleId,
        SaleWord storage stored,
        SaleWord memory a,
        IUniformEditionAuction.AuctionConfig memory t
    ) private returns (bool voided) {
        (uint256 endTime,, IEnglishAuction.AuctionState one) = _end(saleId, a, t, true);
        if (one == IEnglishAuction.AuctionState.CANCELLED) {
            _void(saleId, stored);
            return true;
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (one != IEnglishAuction.AuctionState.SETTLED || block.timestamp < endTime) {
            revert IUniformEditionAuction.SettlementNotReady(saleId);
        }
        stored.oneOfOneEnd = a.oneOfOneEnd;
        stored.status = IUniformEditionAuction.AuctionStatus.SETTLING;
    }

    /// @dev Scans the next words of SETTLING sale `stored`'s book ({_scan}); returns false and
    ///      records where it stopped when words remain, otherwise clears ({_finish}) and returns
    ///      true with the count and price `settle` pays last. `a` and `t` are `stored` and its
    ///      terms as `settle` read them (the book fields the scan uses are frozen).
    function _scanChunk(
        uint256 saleId,
        SaleWord storage stored,
        SaleWord memory a,
        IUniformEditionAuction.AuctionConfig memory t
    ) private returns (bool cleared, uint256 count, uint256 price) {
        // Safe: reads of 32- and 64-bit fields of packed words, and writes of values that fit them.
        // forge-lint: disable-start(unsafe-typecast)
        uint256 left = _scans[saleId];
        uint256[15] memory scan = _scan(saleId, a, t, left);
        uint256 low = uint256(a.lowStep) >> 3;
        if (scan[14] == 0 && scan[7] > low) {
            // `ScanWord`: cursor, demand, best count and step, and the last passing candidate.
            uint256 pick = scan[8];
            _scans[saleId] = scan[7] | scan[10] << 8 | scan[12] << 40 | scan[13] << 72
                | (pick >> 128) << 88 | uint256(uint64(pick >> 64)) << 104 | uint256(uint64(pick))
                << 136;
            emit SettlementScanned(saleId, scan[7] - low);
            return (false, 0, 0);
        }
        if (left != 0) delete _scans[saleId];
        // forge-lint: disable-end(unsafe-typecast)
        (count, price) = _finish(saleId, stored, a, t, scan[8]);
        cleared = true;
    }

    /// @dev Stores the clearing whose last passing candidate is `pick` (`step << 128 |
    ///      unitsAbove << 64 | demand`; zero for an empty book): SETTLED, or SETTLING while the
    ///      clearing step's departures wait to be swept. Returns the count and the price, which
    ///      `settle` pays after its last write.
    function _finish(
        uint256 saleId,
        SaleWord storage stored,
        SaleWord memory a,
        IUniformEditionAuction.AuctionConfig memory t,
        uint256 pick
    ) private returns (uint256 count, uint256 price) {
        // Safe: reads of 32- and 64-bit fields of packed words, and writes of values that fit them.
        // forge-lint: disable-start(unsafe-typecast)
        uint256 demand = uint64(pick);
        count = a.maxCount != 0 && demand > a.maxCount ? a.maxCount : demand;
        uint256 step = pick >> 128;
        uint256 cutUnits = count - uint64(pick >> 64);
        bool rationed = count < demand;
        // forge-lint: disable-end(unsafe-typecast)
        PayoutWord memory p = _payouts[saleId];
        if (count != 0 && !IEditions(_editions).exists(p.id)) {
            revert IUniformEditionAuction.EditionNotCreated(_editions, p.id);
        }
        // Safe: counts below 2^32 and steps below 512.
        // forge-lint: disable-start(unsafe-typecast)
        _results[saleId] = ResultWord(
            uint32(count), uint16(step), rationed, uint32(cutUnits), uint32(cutUnits), 0, 0, p.id
        );
        // forge-lint: disable-end(unsafe-typecast)
        // The count is final here (rationing picks winners, not the count): seal the edition at
        // it, so no copy past what the winners are owed can ever be minted (ED-12).
        _seal(p.id, count);
        price = count == 0 ? 0 : _price(t, step);
        emit IUniformEditionAuction.AuctionCleared(
            saleId, count, step, price, count * price, rationed, cutUnits
        );
        if (rationed && uint32(_departures[saleId][step << 32]) != 0) return (count, price);
        stored.status = IUniformEditionAuction.AuctionStatus.SETTLED;
        emit IUniformEditionAuction.AuctionSettled(saleId, count, rationed ? cutUnits : 0);
    }

    /// @dev Runs one chunk of the caller's departure sweep of a SETTLING sale (ADR 0005; PLAN
    ///      section 1.6): each departure from the clearing step, in strictly increasing
    ///      position, moves the cutoff past its units when it starts below the cutoff. `order`
    ///      is the caller's remaining slice: the departures after the ones it swept before
    ///      (`settlementOrderFor`); the call sweeps at most `limit` of them.
    ///
    ///      Invariants. Positions strictly increase across a settler's calls (its `nextPosition`
    ///      persists), so its swept departures are distinct, and `swept == total` means it swept
    ///      every one: only then is its cutoff exact, written to the result, and the sale
    ///      SETTLED. An order that skips a departure strands only its caller's progress: any
    ///      other settler starts from scratch. A call that finishes writes no progress slot,
    ///      and deletes its caller's.
    function _sweep(uint256 saleId, SaleWord storage a, uint256[] calldata order, uint256 limit)
        private
        returns (bool)
    {
        ResultWord memory r = _results[saleId];
        // The clearing call (`limit == _SWEEP_FIRST`) starts every sweep, so no settler has
        // progress yet and its slot is not read.
        uint256 progress = limit == _SWEEP_FIRST ? 0 : _sweeps[saleId][msg.sender];
        // Safe: reads of 32-bit fields of packed words, and writes of values that fit them.
        // forge-lint: disable-start(unsafe-typecast)
        uint256 total = uint32(_departures[saleId][uint256(r.step) << 32]);
        uint256 swept = uint32(progress);
        // This call sweeps the first `n` entries of `order`.
        uint256 n = order.length < limit ? order.length : limit;
        if (n > total - swept) n = total - swept;
        // The sweep state `next | cutoff << 32`: the caller's, or the start (0, cutUnits).
        uint256 state = _sweepRange(
            saleId, r.step, order, n, progress == 0 ? uint256(r.cutUnits) << 32 : progress >> 32
        );
        swept += n;
        emit IUniformEditionAuction.DeparturesSwept(saleId, swept, total, state >> 32);
        if (swept < total) {
            // A call that swept nothing leaves no slot behind.
            if (n != 0) _sweeps[saleId][msg.sender] = swept | state << 32;
            return false;
        }
        if (progress != 0) delete _sweeps[saleId][msg.sender];
        (r.swept, r.cutoff, r.nextPosition) = (uint32(swept), uint32(state >> 32), uint32(state));
        // forge-lint: disable-end(unsafe-typecast)
        _results[saleId] = r;
        a.status = IUniformEditionAuction.AuctionStatus.SETTLED;
        emit IUniformEditionAuction.AuctionSettled(saleId, r.count, r.cutoff);
        return true;
    }

    /// @dev Sweeps `order[:n]` from the state `next | cutoff << 32` with `UniformClearing.sweep`
    ///      and returns the new state: each index must name a departure of `step`, at a
    ///      position of at least `next`.
    function _sweepRange(
        uint256 saleId,
        uint256 step,
        uint256[] calldata order,
        uint256 n,
        uint256 state
    ) private view returns (uint256) {
        uint256 head = _departures[saleId][step << 32];
        uint256 cutoff = state >> 32;
        // Safe: reads of 32-bit fields of packed words.
        // forge-lint: disable-start(unsafe-typecast)
        uint256 total = uint32(head);
        uint256 next = uint32(state);
        for (uint256 i; i < n; ++i) {
            uint256 index = order[i];
            if (index >= total) revert IUniformEditionAuction.InvalidSettlementOrder(i);
            uint256 entry = _departure(saleId, step, head, index);
            (cutoff, next) =
                UniformClearing.sweep(cutoff, next, uint32(entry), uint32(entry >> 32), i);
        }
        // forge-lint: disable-end(unsafe-typecast)
        return next | cutoff << 32;
    }

    /// @dev Pays `count × price` of sale `saleId`: the network fee to the fee recipient, then
    ///      the rest to the seller, each escrowed on refusal, and emits `SaleSettled` (the event
    ///      the TDH pipeline weights, P29 section 1.2).
    function _pay(uint256 saleId, PayoutWord memory p, uint256 count, uint256 price) private {
        address feeRecipient = _feeRecipients[p.feeRecipientId];
        uint256 revenue = count * price;
        uint256 fee = revenue * p.feeShare / Splits.DENOMINATOR;
        uint256 gasLimit = _settings.payoutGas;
        if (fee != 0) RevenuePayment.payETH(IRevenueEscrow(_escrow), feeRecipient, fee, gasLimit);
        if (revenue != fee) {
            RevenuePayment.payETH(IRevenueEscrow(_escrow), p.seller, revenue - fee, gasLimit);
        }
        emit ISaleAdapter.SaleSettled(
            saleId,
            _editions,
            p.id,
            address(0),
            address(0),
            count,
            CURRENCY_ETH,
            revenue,
            p.seller,
            revenue - fee,
            feeRecipient,
            fee
        );
    }

    /// @dev Claims bid `b` of a SETTLED or VOID sale: deletes it, then mints its copies to `to`.
    ///      The caller sends or credits the refund.
    function _claim(uint256 saleId, uint256 bidId, BidWord memory b, address to)
        private
        returns (uint256 unitsWon, uint256 refund)
    {
        SaleWord storage a = _sales[saleId];
        IUniformEditionAuction.AuctionStatus status = a.status;
        if (
            status != IUniformEditionAuction.AuctionStatus.SETTLED
                && status != IUniformEditionAuction.AuctionStatus.VOID
        ) {
            revert IUniformEditionAuction.InvalidAuctionState(saleId, status);
        }
        IUniformEditionAuction.AuctionConfig memory t = _terms[a.termsId];
        refund = uint256(b.quantity) * _price(t, b.step);
        uint256 id = 0;
        uint256 unitPrice;
        if (status == IUniformEditionAuction.AuctionStatus.SETTLED) {
            ResultWord memory r = _results[saleId];
            id = r.id;
            if (r.count != 0 && b.step >= r.step) {
                unitsWon = b.step > r.step || !r.rationed
                    ? b.quantity
                    : UniformClearing.wonAtCut(r.cutoff, b.position, b.quantity);
                unitPrice = _price(t, r.step);
                refund -= unitsWon * unitPrice;
            }
        }
        delete _bids[saleId][bidId];
        emit IUniformEditionAuction.BidClaimed(saleId, bidId, b.bidder, to, unitsWon, refund);
        if (unitsWon != 0) {
            (uint256 minted,) =
                IMintTarget(_editions).mint(to, id, unitsWon, abi.encode(CURRENCY_ETH, unitPrice));
            if (minted != id) revert ISaleAdapter.InvalidSaleTerms(_editions, id);
        }
    }

    /// @dev One chunk of the D138 clearing of sale `a`'s live book (ADR 0005): a downward pass
    ///      over at most {_SCAN_WORDS} of its words, resuming from `left` (a scan in progress) or
    ///      from its highest word. It gives exactly `UniformClearing.clear`'s result, which the
    ///      lens runs: the tests replay the golden vectors through both and fuzz one against the
    ///      other. Each used step is a candidate of `min(demand at or above it, cap)` copies at
    ///      its price; the pass stops below the step where the demand reaches the cap, keeps the
    ///      best revenue so far, and records a candidate whenever its revenue is within the
    ///      margin of that best (itself included). The best only grows, so the last candidate
    ///      recorded is the lowest within the margin of the final best: the result. Prices are
    ///      `StepLadder.price`'s, computed decade by decade from one scale.
    ///
    ///      Returns the scan's memory block, read and written by {_scanWords}: [0] the cap (or
    ///      `type(uint256).max`), [1] `100,000 - marginShare`, [2] steps per decade, [3] the
    ///      mantissa table, [4] the current decade's first step and [5] its scale, [6] one past
    ///      the next word to scan, [7] the lowest word this chunk scans (where it stops), [8] the
    ///      last passing candidate (`step << 128 | unitsAbove << 64 | demand`), [9] the table
    ///      stride `192 / stepsPerDecade`, [10] the demand so far, [11] the best revenue so far,
    ///      [12] and [13] its count and step, [14] nonzero once the cap ended the scan.
    function _scan(
        uint256 saleId,
        SaleWord memory a,
        IUniformEditionAuction.AuctionConfig memory t,
        uint256 left
    ) private view returns (uint256[15] memory scan) {
        uint256 perDecade = t.stepsPerDecade;
        // Safe: reads of 32- and 64-bit fields of packed words, and writes of values that fit them.
        // forge-lint: disable-start(unsafe-typecast)
        uint256 cursor = uint8(left) == 0 ? (uint256(a.highStep) >> 3) + 1 : uint8(left);
        uint256 low = uint256(a.lowStep) >> 3;
        scan[0] = a.maxCount == 0 ? type(uint256).max : a.maxCount;
        scan[1] = Splits.DENOMINATOR - t.marginShare;
        scan[2] = perDecade;
        uint256 decade = ((cursor << 3) - 1) / perDecade;
        scan[4] = decade * perDecade;
        scan[5] = uint256(t.basePrice) * 10 ** decade;
        scan[6] = cursor;
        scan[7] = cursor > low + _SCAN_WORDS ? cursor - _SCAN_WORDS : low;
        scan[8] = uint256(uint16(left >> 88)) << 128 | uint256(uint32(left >> 104)) << 64
            | uint32(left >> 136);
        scan[9] = StepLadder.MANTISSAS / perDecade;
        scan[10] = uint32(left >> 8);
        uint256 bestCount = uint32(left >> 40);
        if (bestCount != 0) {
            uint256 bestStep = uint16(left >> 72);
            (scan[11], scan[12], scan[13]) = (bestCount * _price(t, bestStep), bestCount, bestStep);
        }
        // forge-lint: disable-end(unsafe-typecast)
        if (a.liveUnits == 0) {
            scan[7] = low;
            return scan;
        }
        bytes memory table = _MANTISSAS;
        mapping(uint256 word => uint256) storage live = _live[saleId];
        bytes32 base;
        // Invariants: writes element 3 of the fixed block `scan` (inside its allocation): the
        // address of the table's first byte; `base` is the slot of `_live[saleId]`, whose word
        // `w` lives at `keccak256(abi.encode(w, base))`, as Solidity places mapping values.
        assembly ("memory-safe") {
            mstore(add(scan, 0x60), add(table, 0x20))
            base := live.slot
        }
        _scanWords(base, scan);
    }

    /// @dev The pass of {_scan} over the live words of the mapping at `base`, with `scan` laid
    ///      out as {_scan} documents. In Yul because it runs once per used step of the book (up
    ///      to 512), and a settlement call must fit its budget.
    ///
    ///      Invariants, each relied on by the arithmetic below (no checked arithmetic in Yul):
    ///      - the loop reads words `scan[6] - 1` down to `scan[7]` (at most {_SCAN_WORDS}) and,
    ///        within each, lanes 7 down to 0: steps strictly decreasing, as the D138 pass needs;
    ///      - `demand` is a sum of live units of one sale, below 2^32, so `demand + units` and
    ///        `demand - units` never wrap, and the packed `pick` fields (64 bits each) hold them;
    ///      - `start` (the current decade's first step) stays at most `step`: the inner loop
    ///        lowers it a decade at a time, and a step below `start` implies `start >= N`, so
    ///        `start - N` and `step - start` never wrap, and `(step - start) * stride < 192`
    ///        indexes the padded table;
    ///      - `scale` is `basePrice × 10^decade`, at most 10^17 × 10^21 < 2^127, and a mantissa
    ///        is below 2^10, so a price is below 2^137, a revenue (times at most 2^32 copies)
    ///        below 2^169, and a revenue or the best times 100,000 below 2^186: no product wraps;
    ///      - the best revenue only grows, so the last `pick` written is the lowest step within
    ///        the margin of the final best;
    ///      - memory: only `scan`'s own fifteen words and the scratch words 0x00-0x3f (the
    ///        mapping key hash) are written, and the table is only read.
    function _scanWords(bytes32 base, uint256[15] memory scan) private view {
        assembly ("memory-safe") {
            // p[0] cap, p[1] keep, p[2] steps per decade, p[3] table, p[4] decade start, p[5]
            // scale, p[6] cursor, p[7] stop word, p[8] pick, p[9] stride, p[10] demand, p[11]
            // best, p[12] best count, p[13] best step, p[14] cap reached (byte offsets `32i`).
            let p := scan
            let demand := mload(add(p, 0x140))
            let best := mload(add(p, 0x160))
            let pick := mload(add(p, 0x100))
            let w := mload(add(p, 0xc0))
            for { } gt(w, mload(add(p, 0xe0))) { } {
                w := sub(w, 1)
                mstore(0x00, w)
                mstore(0x20, base)
                let word := sload(keccak256(0x00, 0x40))
                for { let j := 8 } j { } {
                    j := sub(j, 1)
                    let units := and(shr(shl(5, j), word), 0xffffffff)
                    if iszero(units) { continue }
                    // Once the demand above a used step reaches the cap, no lower step counts.
                    if iszero(lt(demand, mload(p))) {
                        mstore(add(p, 0x1c0), 1)
                        w := 0
                        break
                    }
                    let step := or(shl(3, w), j)
                    let start := mload(add(p, 0x80))
                    if lt(step, start) {
                        let scale := mload(add(p, 0xa0))
                        for { } lt(step, start) { } {
                            start := sub(start, mload(add(p, 0x40)))
                            scale := div(scale, 10)
                        }
                        mstore(add(p, 0x80), start)
                        mstore(add(p, 0xa0), scale)
                    }
                    demand := add(demand, units)
                    let count := demand
                    if gt(count, mload(p)) { count := mload(p) }
                    let revenue :=
                        mul(
                            count,
                            div(
                                mul(
                                    mload(add(p, 0xa0)),
                                    shr(
                                        240,
                                        mload(
                                            add(
                                                mload(add(p, 0x60)),
                                                shl(1, mul(sub(step, start), mload(add(p, 0x120))))
                                            )
                                        )
                                    )
                                ),
                                100
                            )
                        )
                    if gt(revenue, best) {
                        best := revenue
                        mstore(add(p, 0x180), count)
                        mstore(add(p, 0x1a0), step)
                    }
                    if iszero(lt(mul(revenue, 100000), mul(best, mload(add(p, 0x20))))) {
                        pick := or(or(shl(128, step), shl(64, sub(demand, units))), demand)
                    }
                }
            }
            mstore(add(p, 0x100), pick)
            mstore(add(p, 0x140), demand)
            mstore(add(p, 0x160), best)
        }
    }

    /// @dev Adds `quantity` live units at `step` and returns the new bid's position: in a capped
    ///      sale the units that ever entered the step (live plus departed), else zero.
    function _enter(uint256 saleId, bool capped, uint256 step, uint256 quantity)
        private
        returns (uint32)
    {
        uint256 shift = (step & 7) << 5;
        uint256 word = _live[saleId][step >> 3];
        // No carry into the next counter: a step's live units are at most the sale's, which stay
        // below 2^32.
        _live[saleId][step >> 3] = word + (quantity << shift);
        if (!capped) return 0;
        // Safe: reads of 32- and 64-bit fields of packed words, and writes of values that fit them.
        // forge-lint: disable-start(unsafe-typecast)
        uint256 position = uint32(word >> shift) + uint32(_departures[saleId][step << 32] >> 32);
        if (position + quantity > type(uint32).max) {
            revert IUniformEditionAuction.InvalidQuantity(quantity);
        }
        // forge-lint: disable-end(unsafe-typecast)
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(position);
    }

    /// @dev Removes a bid's `quantity` live units from `step`, logging the departure (its
    ///      position and units) in a capped sale.
    function _leave(uint256 saleId, bool capped, uint256 step, uint256 position, uint256 quantity)
        private
    {
        _live[saleId][step >> 3] -= quantity << ((step & 7) << 5);
        if (!capped) return;
        uint256 head = _departures[saleId][step << 32];
        // Safe: reads of 32- and 64-bit fields of packed words, and writes of values that fit them.
        // forge-lint: disable-start(unsafe-typecast)
        uint256 count = uint32(head);
        // The departed units stay at most the step's entered units, which fit 32 bits.
        head = (head >> 64 << 64) | (count + 1) | (uint256(uint32(head >> 32)) + quantity) << 32;
        uint256 entry = position | quantity << 32;
        // forge-lint: disable-end(unsafe-typecast)
        if (count < _HEAD_ENTRIES) {
            _departures[saleId][step << 32] = head | entry << (64 + (count << 6));
        } else {
            _departures[saleId][step << 32] = head;
            uint256 j = count - _HEAD_ENTRIES;
            _departures[saleId][step << 32 | 1 + (j >> 2)] |= entry << ((j & 3) << 6);
        }
    }

    /// @dev Departure `index` of `step`'s log, whose head word is `head`: `position | quantity <<
    ///      32` in the low 64 bits.
    function _departure(uint256 saleId, uint256 step, uint256 head, uint256 index)
        private
        view
        returns (uint256)
    {
        if (index < _HEAD_ENTRIES) return head >> (64 + (index << 6));
        uint256 j = index - _HEAD_ENTRIES;
        return _departures[saleId][step << 32 | 1 + (j >> 2)] >> ((j & 3) << 6);
    }

    /// @dev Validates, interns and makes current a configuration (ADR 0005 section 4).
    function _setConfig(IUniformEditionAuction.AuctionConfig memory next) private {
        Settings storage st = _settings;
        if (
            !StepLadder.isStepsPerDecade(next.stepsPerDecade)
                || !StepLadder.isBasePrice(next.basePrice)
                || next.stepCount < StepLadder.MIN_STEP_COUNT
                || next.stepCount > StepLadder.MAX_STEP_COUNT
                || _price(next, next.stepCount - 1) < StepLadder.MIN_TOP_PRICE
                || next.marginShare > _MAX_MARGIN_SHARE || next.closeOffset > st.maxCloseOffset
                || next.softWindow < _MIN_SOFT_WINDOW || next.softWindow > _MAX_SOFT_WINDOW
                || next.maxExtension < _MIN_MAX_EXTENSION || next.maxExtension > _MAX_MAX_EXTENSION
        ) revert IUniformEditionAuction.InvalidConfig();
        emit IUniformEditionAuction.ConfigSet(_terms[st.termsId], next);
        st.termsId = _intern(next);
    }

    /// @dev Stores `t` as a new terms record and returns its ID: a configuration, or a sale's
    ///      parameters with its own close offset.
    function _intern(IUniformEditionAuction.AuctionConfig memory t) private returns (uint24 id) {
        Settings storage st = _settings;
        id = st.termsCount;
        if (id == type(uint24).max) revert IUniformEditionAuction.InvalidConfig();
        st.termsCount = ++id;
        _terms[id] = t;
    }

    /// @dev How much later than `close` plus the 90-day floor (which the abandonment delay's
    ///      minimum assumes) 6529 Stream lets the master's works be rescued, at most `capDays`
    ///      days. Stream rescues a work at its adapter's removal time plus the delay it locked
    ///      then (read natively through `IStream.extsload` at `StreamLayout.minterSlot`; a later
    ///      lengthening never reaches them): so, once governance removed the English auction,
    ///      the locked delay's excess over the floor plus however long after `close` the removal
    ///      came; before, the delay in force, as if it were removed at the close. Both reads
    ///      forward all gas and revert on any failure (Stream's permanent views never refuse).
    function _rescueAddition(uint256 close, uint256 capDays) private view returns (uint256 added) {
        uint256 word =
            uint256(IStream(_stream).extsload(StreamLayout.minterSlot(_englishAuction), 1)[0]);
        // Safe: the removal time and the locked delay, field by field (`StreamLayout`).
        // forge-lint: disable-start(unsafe-typecast)
        uint256 removedAt = uint40(word >> 32);
        added = removedAt != 0 ? uint32(word >> 72) : IStream(_stream).rescueDelay();
        // forge-lint: disable-end(unsafe-typecast)
        // Stream's delay never goes below its floor; checked arithmetic refuses anything else.
        added -= _RESCUE_FLOOR;
        if (removedAt > close) added += removedAt - close;
        if (added > capDays * 1 days) added = capDays * 1 days;
    }

    /// @dev The governed limits, packed as `setLimits` takes them: `maxCloseOffset |
    ///      voidDelayDays << 32 | payoutGas << 48 | rescueCapDays << 80`.
    function _limits() private view returns (uint256) {
        Settings memory st = _settings;
        return uint256(st.maxCloseOffset) | uint256(st.voidDelayDays) << 32 | uint256(st.payoutGas)
            << 48 | uint256(st.rescueCapDays) << 80;
    }

    /// @dev Validates and stores packed limits (`setLimits`): nothing past bit 96, every bound,
    ///      and a maximum close offset of at least the current default.
    function _setLimits(uint256 next) private {
        Settings storage st = _settings;
        // Safe: each field is masked to its width.
        // forge-lint: disable-start(unsafe-typecast)
        uint32 maxCloseOffset = uint32(next);
        uint16 voidDelayDays = uint16(next >> 32);
        uint32 payoutGas = uint32(next >> 48);
        uint16 rescueCapDays = uint16(next >> 80);
        // forge-lint: disable-end(unsafe-typecast)
        if (
            next >> 96 != 0 || maxCloseOffset < _MIN_MAX_CLOSE_OFFSET
                || maxCloseOffset > _MAX_MAX_CLOSE_OFFSET
                || maxCloseOffset < _terms[st.termsId].closeOffset
                || voidDelayDays < _MIN_VOID_DELAY_DAYS || voidDelayDays > _MAX_VOID_DELAY_DAYS
                || payoutGas < _MIN_PAYOUT_GAS || payoutGas > _MAX_PAYOUT_GAS
                || rescueCapDays < _MIN_RESCUE_CAP_DAYS || rescueCapDays > _MAX_RESCUE_CAP_DAYS
        ) revert IUniformEditionAuction.InvalidConfig();
        emit IUniformEditionAuction.LimitsSet(_limits(), next);
        (st.maxCloseOffset, st.voidDelayDays, st.payoutGas, st.rescueCapDays) =
        (maxCloseOffset, voidDelayDays, payoutGas, rescueCapDays);
    }

    /// @dev `x` as a clock: reverts with `ClockOverflow` from 2^32 (7 February 2106) instead of
    ///      wrapping. Every stored time is 32 bits; the lens refuses an open whose times do not
    ///      fit, so only a later bid's soft end or a 1/1 end read later can reach the bound.
    function _u32(uint256 x) private pure returns (uint32) {
        if (x > type(uint32).max) revert IUniformEditionAuction.ClockOverflow(x);
        // Safe: checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(x);
    }

    /// @dev Marks a sale VOID: every bid is refunded in full at its claim.
    function _void(uint256 saleId, SaleWord storage stored) private {
        stored.status = IUniformEditionAuction.AuctionStatus.VOID;
        emit IUniformEditionAuction.AuctionVoided(saleId);
    }

    /// @dev Seals edition `id` at `count` copies (`IEditions.sealSupply`): the count a settlement
    ///      sold, or zero for an abandoned sale.
    function _seal(uint256 id, uint256 count) private {
        IEditions(_editions).sealSupply(id, count);
    }

    /// @dev Step `step`'s price under `t`: `basePrice × M[(step mod N)·192/N] × 10^(step div N) /
    ///      100`, `StepLadder.price` from {_MANTISSAS}.
    function _price(IUniformEditionAuction.AuctionConfig memory t, uint256 step)
        private
        pure
        returns (uint256)
    {
        uint256 n = t.stepsPerDecade;
        bytes memory table = _MANTISSAS;
        uint256 j = (step % n) * (StepLadder.MANTISSAS / n);
        uint256 m;
        // Invariant: `j` is below 192, so the 32-byte load at offset `2j` stays inside the padded
        // table, and its top two bytes are entry `j`.
        assembly ("memory-safe") {
            m := shr(240, mload(add(add(table, 0x20), shl(1, j))))
        }
        return uint256(t.basePrice) * m * 10 ** (step / n) / StepLadder.MANTISSA_SCALE;
    }

    /// @dev Whole minutes from `from` to `to`, zero if `to` is earlier, capped at 65,535. A bid
    ///      placed in minute `m` is before a pause in minute `p` exactly when `m < p`: the pause
    ///      began after minute `m` ended. A capped minute is never before another, and a pause
    ///      before the sale opened is minute zero, before which nothing was placed.
    function _minutes(uint256 from, uint256 to) private pure returns (uint16) {
        uint256 m = to > from ? (to - from) / 60 : 0;
        // Safe: capped below 2^16.
        // forge-lint: disable-next-line(unsafe-typecast)
        return m < type(uint16).max ? uint16(m) : type(uint16).max;
    }

    /// @dev Sale `saleId`'s 1/1, read live from the English auction itself
    ///      (`IEnglishAuctionClock.auctionClock`): its state, end and dispute-pause start.
    function _oneOfOneClock(uint256 saleId)
        private
        view
        returns (IEnglishAuction.AuctionState state, uint64 endTime, uint64 pausedAt)
    {
        (state, endTime, pausedAt) = IEnglishAuctionClock(_englishAuction)
            .auctionClock(_saleIdOf(_stream, _payouts[saleId].id));
    }

    /// @dev The derived sale ID, `uint256(keccak256(abi.encode(token, id)))`
    ///      (`IUniformEditionAuction.saleIdOf`, which the lens answers).
    function _saleIdOf(address token, uint256 id) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, id)));
    }

    /// @dev Sale `saleId`'s state word, required OPEN.
    function _open(uint256 saleId) private view returns (SaleWord memory a) {
        a = _sales[saleId];
        _requireStatus(saleId, a.status, IUniformEditionAuction.AuctionStatus.OPEN);
    }

    /// @dev A sale word read with one SLOAD and decoded, for the settlement path (I-1 of review
    ///      A: there the compiler's member-by-member copy reads the slot once per field; the
    ///      bid and claim paths keep the compiler's copy, which is cheaper for them). The packing is `SaleWord`'s, from the
    ///      least significant bit, as `IUniformEditionAuctionStorage.Space` documents and the lens
    ///      decodes.
    function _saleWord(SaleWord storage stored) private view returns (SaleWord memory a) {
        uint256 w;
        assembly ("memory-safe") {
            w := sload(stored.slot)
        }
        // Safe: each cast takes its field's own bits of the packed word.
        // forge-lint: disable-start(unsafe-typecast)
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
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev Terms record `termsId` read with one SLOAD and decoded (I-1), `AuctionConfig`'s
    ///      packing from the least significant bit.
    function _config(uint256 termsId)
        private
        view
        returns (IUniformEditionAuction.AuctionConfig memory t)
    {
        IUniformEditionAuction.AuctionConfig storage stored = _terms[termsId];
        uint256 w;
        assembly ("memory-safe") {
            w := sload(stored.slot)
        }
        // Safe: each cast takes its field's own bits of the packed word.
        // forge-lint: disable-start(unsafe-typecast)
        t.basePrice = uint96(w);
        t.stepsPerDecade = uint16(w >> 96);
        t.stepCount = uint16(w >> 112);
        t.marginShare = uint32(w >> 128);
        t.closeOffset = uint32(w >> 160);
        t.softWindow = uint32(w >> 192);
        t.maxExtension = uint32(w >> 224);
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev `IEditions.bindMinter(id, item)` with the item `open` received, bubbling a revert;
    ///      returns the seller, fee recipient and fee share of the `WorkTerms` it returns.
    ///      `data` is `abi.encode(item)`: the tuple's offset word, then the tuple, whose inner
    ///      offsets are relative to its start. So the call's arguments are `id`, the tuple's new
    ///      offset (0x40) and `data` past its first word, and this contract needs no item codec.
    ///      A `data` the lens decoded through another offset hands Editions a different item,
    ///      whose hash is not the master's: the open reverts (`NotEditionMaster`).
    function _bindEdition(uint256 id, bytes calldata data)
        private
        returns (address seller, address feeRecipient, uint256 feeShare)
    {
        address target = _editions;
        bytes4 selector = IEditions.bindMinter.selector;
        // Invariants: `data` is at least one word long (the lens decoded an item from it before
        // this runs), so `n` does not wrap. The call is built in memory from the free memory
        // pointer on without moving it: temporary memory nothing else reads. A failed call's
        // returndata is copied over the same memory and the frame ends in `revert`.
        assembly ("memory-safe") {
            let p := mload(0x40)
            let n := sub(data.length, 0x20)
            mstore(p, selector)
            mstore(add(p, 0x04), id)
            mstore(add(p, 0x24), 0x40)
            calldatacopy(add(p, 0x44), add(data.offset, 0x20), n)
            if iszero(call(gas(), target, 0, p, add(n, 0x44), 0, 0)) {
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
            // The first three words of the returned `WorkTerms` (a static struct of five);
            // `returndatacopy` reverts if Editions returned fewer.
            returndatacopy(p, 0, 0x60)
            seller := mload(p)
            feeRecipient := mload(add(p, 0x20))
            feeShare := mload(add(p, 0x40))
        }
    }

    /// @dev Reverts with `UnknownAuction` for a sale never opened, and `InvalidAuctionState`
    ///      unless `status` is `wanted`.
    function _requireStatus(
        uint256 saleId,
        IUniformEditionAuction.AuctionStatus status,
        IUniformEditionAuction.AuctionStatus wanted
    ) private pure {
        if (status == IUniformEditionAuction.AuctionStatus.NONE) {
            revert IUniformEditionAuction.UnknownAuction(saleId);
        }
        if (status != wanted) revert IUniformEditionAuction.InvalidAuctionState(saleId, status);
    }

    /// @dev A live bid.
    function _bidOf(uint256 saleId, uint256 bidId) private view returns (BidWord memory b) {
        b = _bids[saleId][bidId];
        if (b.bidder == address(0)) revert IUniformEditionAuction.UnknownBid(saleId, bidId);
    }
}
