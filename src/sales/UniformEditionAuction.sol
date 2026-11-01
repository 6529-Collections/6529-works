// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { RevenuePayment } from "../economics/RevenuePayment.sol";
import { Splits } from "../economics/Splits.sol";
import { TokenTransfer } from "../economics/TokenTransfer.sol";
import { Roles } from "../governance/Roles.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEditions } from "../interfaces/IEditions.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IEnglishAuctionClock } from "../interfaces/IEnglishAuctionClock.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
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
import { UniformClearing } from "./UniformClearing.sol";
import { UniformEditionAuctionLens } from "./UniformEditionAuctionLens.sol";

/// @title UniformEditionAuction
/// @notice The uniform-price edition auction (ADR 0005; D138-D141), the one sale of 6529 Stream
///         Editions. See {IUniformEditionAuction} for the rules; this contract adds the storage
///         layout and the bounds. Every view of a sale lives on its lens
///         ({UniformEditionAuctionLens}), which the constructor creates.
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
///      one record per change and a sale stores its 16-bit ID; fee recipients likewise.
///
///      The 1/1's end only ever moves later, so the sale caches it and reads it live
///      (`IEnglishAuctionClock.auctionClock`, the state and end the English auction answers
///      itself, not through its lens) only when a bid or raise lands within `softWindow` of the
///      cached close, or later. Settlement and withdrawals always read it live. A cancelled 1/1
///      is therefore seen by the next settlement (anyone may void the sale at once) or by a bid
///      near the close; a bid placed far from the close after the cancel is refunded in full with
///      every other.
///
///      `open` hands its token-specific data to the lens (`masterTerms`), which checks the
///      package item against 6529 Stream and the 1/1, and returns what to lock, so no
///      package-item codec is compiled here (EIP-170). The lens is this contract's own creation.
///      For the same reason every view of `IUniformEditionAuction` is answered by the lens: the
///      adapter forwards the call's own calldata to it ({answeredByLens}) and returns its answer
///      unchanged, so callers use one address and one interface.
///
///      v1 serves one token, 6529 Stream Editions (`editions`), whose master contract is
///      `stream`: `setTarget` lists nothing else. Every entry point that moves value is
///      non-reentrant; claims delete the bid before they mint (an ERC-1155 acceptance call) or
///      send ETH.
contract UniformEditionAuction is
    ISaleAdapter,
    IUniformEditionAuctionStorage,
    AccessManaged,
    ReentrancyGuardTransient
{
    /// @notice Gas forwarded with a settlement payout; a wallet that refuses, or needs more, is
    ///         paid in the revenue escrow instead. Under the EIP-8037 draft it caps regular gas
    ///         only (CALLS-3, LIM-GAS-2).
    uint256 public constant PAYOUT_GAS = 100_000;

    /// @dev `setConfig` bounds besides the ladder's (`StepLadder`; ADR 0005 section 4).
    uint256 private constant _MAX_MARGIN_SHARE = 50_000;
    uint256 private constant _MAX_CLOSE_OFFSET = 1 days;
    uint256 private constant _MIN_SOFT_WINDOW = 1 minutes;
    uint256 private constant _MAX_SOFT_WINDOW = 1 hours;
    uint256 private constant _MIN_MAX_EXTENSION = 1 hours;
    uint256 private constant _MAX_MAX_EXTENSION = 7 days;
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
    ///      zero while not paused) and whether `editions` is listed: read once per open.
    struct Settings {
        uint16 termsId;
        uint16 termsCount;
        uint16 feeRecipientCount;
        uint40 pausedAt;
        bool listed;
    }

    /// @notice The revenue escrow that receives refused payouts (immutable).
    address public immutable escrow;
    /// @notice The English auction whose 1/1 sales anchor the edition sales (immutable).
    address public immutable englishAuction;
    /// @inheritdoc IUniformEditionAuctionStorage
    address public immutable lens;
    /// @notice 6529 Stream Editions, the one token this adapter sells.
    address public immutable editions;
    /// @notice 6529 Stream, the master contract of `editions`, whose 1/1s the English auction
    ///         sells.
    address public immutable stream;

    /// @inheritdoc ISaleAdapter
    address public federationRegistry;
    /// @notice The code hash pinned when the federation registry was installed.
    bytes32 public federationRegistryCodeHash;
    Settings private _settings;
    mapping(uint256 termsId => IUniformEditionAuction.AuctionConfig) private _terms;
    mapping(address recipient => uint16) private _feeRecipientIds;
    mapping(uint256 index => address) private _feeRecipients;
    mapping(uint256 saleId => SaleWord) private _sales;
    mapping(uint256 saleId => PayoutWord) private _payouts;
    mapping(uint256 saleId => ResultWord) private _results;
    /// @dev A scan in progress, packed as `ScanWord` is (from the least significant bit).
    mapping(uint256 saleId => uint256) private _scans;
    mapping(uint256 saleId => mapping(uint256 bidId => IUniformEditionAuction.Bid)) private _bids;
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
    ///        6529 Stream and that Stream's economics resolver are read from it.
    /// @param englishAuction_ The English auction (ERC-165 `IEnglishAuction`) that sells the 1/1s.
    /// @param config_ The initial governed parameters.
    constructor(
        address authority_,
        address escrow_,
        address editions_,
        address englishAuction_,
        IUniformEditionAuction.AuctionConfig memory config_
    ) AccessManaged(authority_) {
        Dependency.check(escrow_);
        Dependency.check(editions_, type(IEditions).interfaceId);
        Dependency.check(englishAuction_, type(IEnglishAuction).interfaceId);
        address stream_ = IEditions(editions_).stream();
        Dependency.check(stream_, type(IStream).interfaceId);
        address economics_ = IStream(stream_).economics();
        Dependency.check(economics_, type(IEconomicsResolver).interfaceId);
        escrow = escrow_;
        englishAuction = englishAuction_;
        editions = editions_;
        stream = stream_;
        lens = address(
            new UniformEditionAuctionLens(editions_, stream_, englishAuction_, economics_, escrow_)
        );
        _setConfig(config_);
    }

    // ------------------------------------------------------------------------------- open

    /// @notice Opens the sale of edition `id` on `token` (`IUniformEditionAuction.open`).
    /// @dev Binds the edition to this adapter first (`IEditions.bindMinter`, which may precede
    ///      the edition), so an edition another adapter sells refuses the open, and only this
    ///      adapter can ever mint the copies this sale clears.
    /// @param token The edition contract: `editions`.
    /// @param id The edition ID, the master's 6529 Stream token ID.
    /// @param data `abi.encode(PackageItem)` of the master's EDITION_MASTER item.
    /// @return saleId `saleIdOf(token, id)`.
    function open(address token, uint256 id, bytes calldata data)
        external
        nonReentrant
        returns (uint256 saleId)
    {
        Settings memory st = _settings;
        if (st.pausedAt != 0) revert SalePaused();
        if (token != editions || !st.listed) revert TargetNotAllowed(token);
        if (id >> 32 != 0) revert InvalidSaleTerms(token, id);
        saleId = saleIdOf(token, id);
        SaleWord storage a = _sales[saleId];
        if (a.status != IUniformEditionAuction.AuctionStatus.NONE) {
            revert IUniformEditionAuction.AuctionExists(saleId);
        }
        IUniformEditionAuctionLens.MasterTerms memory m =
            IUniformEditionAuctionLens(lens).masterTerms(token, id, data);
        IUniformEditionAuction.AuctionConfig memory t = _terms[st.termsId];
        uint256 closeAt = uint256(m.oneOfOneEnd) + t.closeOffset;
        // forge-lint: disable-next-line(block-timestamp)
        if (m.oneOfOneState != IEnglishAuction.AuctionState.PAUSED && block.timestamp >= closeAt) {
            // Safe: a 32-bit end plus at most a day.
            // forge-lint: disable-next-line(unsafe-typecast)
            revert IUniformEditionAuction.BiddingClosed(saleId, uint64(closeAt));
        }
        _bindEdition(id, data);
        // Safe: the 1/1 stores its end in 32 bits, and ids are below 2^32 (checked above).
        // forge-lint: disable-start(unsafe-typecast)
        a.status = IUniformEditionAuction.AuctionStatus.OPEN;
        a.termsId = st.termsId;
        a.maxCount = m.maxCount;
        a.oneOfOneEnd = uint32(m.oneOfOneEnd);
        a.openedAt = uint32(block.timestamp);
        uint16 feeRecipientId = m.feeShare == 0 ? 0 : _feeRecipientId(token, id, m.feeRecipient);
        _payouts[saleId] = PayoutWord(m.seller, m.feeShare, feeRecipientId, uint32(id));
        emit SaleStarted(
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
            saleId, token, id, stream, m.maxCount, t, uint64(closeAt)
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
        _bids[saleId][bidId] =
            IUniformEditionAuction.Bid(msg.sender, uint16(step), uint32(quantity), position);
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
        IUniformEditionAuction.Bid memory b = _bidOf(saleId, bidId);
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
        IUniformEditionAuction.Bid storage stored = _bids[saleId][bidId];
        // forge-lint: disable-next-line(unsafe-typecast)
        (stored.step, stored.position) = (uint16(newStep), position);
        emit IUniformEditionAuction.BidRaised(
            saleId, bidId, msg.sender, b.step, newStep, position, paid, endTime
        );
    }

    /// @notice Withdraws the caller's bid while the 1/1 is paused for a dispute, sending its
    ///         escrow to `to` (`IUniformEditionAuction.withdrawBid`).
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @param to The address that receives the escrow.
    function withdrawBid(uint256 saleId, uint256 bidId, address to) external nonReentrant {
        if (to == address(0)) revert InvalidRecipient(to);
        SaleWord storage a = _sales[saleId];
        _requireStatus(saleId, a.status, IUniformEditionAuction.AuctionStatus.OPEN);
        IUniformEditionAuction.Bid memory b = _bidOf(saleId, bidId);
        if (b.bidder != msg.sender) revert IUniformEditionAuction.NotBidder(msg.sender);
        if (_oneOfOne(saleId).state != IEnglishAuction.AuctionState.PAUSED) {
            revert IUniformEditionAuction.WithdrawalsClosed(saleId);
        }
        a.liveUnits -= b.quantity;
        _leave(saleId, a.maxCount != 0, b.step, b.position, b.quantity);
        delete _bids[saleId][bidId];
        uint256 amount = uint256(b.quantity) * _price(_terms[a.termsId], b.step);
        emit IUniformEditionAuction.BidWithdrawn(saleId, bidId, msg.sender, to, amount);
        if (!TokenTransfer.sendETH(to, amount, gasleft())) revert ClaimFailed(to);
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
    /// @dev Pays with `RevenuePayment.payETH`, {PAYOUT_GAS} per wallet: a refusal is escrowed for
    ///      that wallet and never blocks settlement.
    function settle(uint256 saleId, uint256[] calldata order) external nonReentrant returns (bool) {
        SaleWord storage a = _sales[saleId];
        IUniformEditionAuction.AuctionStatus status = a.status;
        if (status == IUniformEditionAuction.AuctionStatus.OPEN) {
            if (_begin(saleId, a)) return true;
        } else {
            // Another settler finished first: nothing left to do.
            if (status == IUniformEditionAuction.AuctionStatus.SETTLED) return true;
            _requireStatus(saleId, status, IUniformEditionAuction.AuctionStatus.SETTLING);
            // Cleared already: sweep the clearing step's departures.
            if (_scans[saleId] == 0) return _sweep(saleId, a, order, _SWEEP_CHUNK);
        }
        (bool cleared, uint256 count, uint256 price) = _scanChunk(saleId, a);
        if (!cleared) return false;
        bool settled = a.status == IUniformEditionAuction.AuctionStatus.SETTLED
            || _sweep(saleId, a, order, _SWEEP_FIRST);
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
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        IUniformEditionAuction.Bid memory b = _bidOf(saleId, bidId);
        if (b.bidder != msg.sender) revert IUniformEditionAuction.NotBidder(msg.sender);
        (unitsWon, refund) = _claim(saleId, bidId, b, to);
        if (refund != 0 && !TokenTransfer.sendETH(to, refund, gasleft())) revert ClaimFailed(to);
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
        IUniformEditionAuction.Bid memory b = _bidOf(saleId, bidId);
        (unitsWon, refund) = _claim(saleId, bidId, b, b.bidder);
        if (refund != 0) {
            _credits[b.bidder] += refund;
            emit Credited(b.bidder, CURRENCY_ETH, saleId, refund);
        }
    }

    /// @inheritdoc ISaleAdapter
    /// @dev Only ETH is ever credited; any other currency has nothing to claim.
    function claim(address currency, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert InvalidRecipient(to);
        amount = currency == CURRENCY_ETH ? _credits[msg.sender] : 0;
        if (amount == 0) revert NothingToClaim(msg.sender, currency);
        _credits[msg.sender] = 0;
        emit Claimed(msg.sender, currency, to, amount);
        if (!TokenTransfer.sendETH(to, amount, gasleft())) revert ClaimFailed(to);
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
        IUniformEditionAuction.AuctionConfig memory c = _terms[_settings.termsId];
        if (
            expected.basePrice != c.basePrice || expected.stepsPerDecade != c.stepsPerDecade
                || expected.stepCount != c.stepCount || expected.marginShare != c.marginShare
                || expected.closeOffset != c.closeOffset || expected.softWindow != c.softWindow
                || expected.maxExtension != c.maxExtension
        ) revert ExpectedValueMismatch();
        _setConfig(next);
    }

    /// @inheritdoc ISaleAdapter
    /// @dev Stops new opens only: running sales bid, settle and claim as usual.
    function pause() external restricted {
        if (_settings.pausedAt != 0) revert SalePaused();
        // Safe: a timestamp, far below 2^40.
        // forge-lint: disable-next-line(unsafe-typecast)
        _settings.pausedAt = uint40(block.timestamp);
        emit Paused(msg.sender);
    }

    /// @inheritdoc ISaleAdapter
    /// @dev Reverts with `UnpauseTooEarly` before `pausedAt + Roles.STANDARD` (GOV-5).
    function unpause() external restricted {
        uint256 pausedAt = _settings.pausedAt;
        if (pausedAt == 0) revert NotPaused();
        uint256 allowedAt = pausedAt + Roles.STANDARD;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < allowedAt) revert UnpauseTooEarly(allowedAt);
        _settings.pausedAt = 0;
        emit Unpaused(msg.sender);
    }

    /// @inheritdoc ISaleAdapter
    /// @dev Only `editions` can be listed in v1. Unlisting stops new opens; running sales finish.
    function setTarget(address token, bool listed) external restricted {
        if (token != editions) revert TargetNotAllowed(token);
        _settings.listed = listed;
        emit TargetSet(token, listed);
    }

    /// @inheritdoc ISaleAdapter
    /// @dev Recorded and checked like every dependency (ADR 0005, decision 14); no federated token
    ///      is sold in v1, so it serves no sale yet.
    function setFederationRegistry(address expected, address next) external restricted {
        if (federationRegistry != expected) revert ExpectedValueMismatch();
        if (next != address(0)) Dependency.check(next, type(IFederationRegistry).interfaceId);
        federationRegistry = next;
        federationRegistryCodeHash = next == address(0) ? bytes32(0) : next.codehash;
        emit FederationRegistrySet(expected, next);
    }

    // ------------------------------------------------------------------------------ views

    /// @notice Answers every view of `IUniformEditionAuction` this contract does not declare
    ///         (`auction`, `endTimes`, `clearing`, `settlement`, `bidOf`, `bidOutcome`, `quote`,
    ///         `lowestWinningStep`, `stepPrice`, `ladder`, `stepTotals`, `departures`,
    ///         `settlementOrder`): it sends this call's calldata unchanged to the lens, which
    ///         declares each with the same signature, and returns or reverts with its answer.
    ///         Any other call reverts there. ETH is refused.
    /// @dev A read-only `staticcall` to a fixed, stateless lens this contract created; no
    ///      delegatecall. The views live there because this contract's write path alone nearly
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

    /// @notice The derived sale ID, `uint256(keccak256(abi.encode(token, id)))`
    ///         (`IUniformEditionAuction.saleIdOf`).
    /// @param token The edition contract.
    /// @param id The edition ID.
    /// @return The sale ID, whether or not that sale exists.
    function saleIdOf(address token, uint256 id) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, id)));
    }

    /// @notice The governed parameters new sales lock (`IUniformEditionAuction.config`).
    /// @return The current parameters.
    function config() external view returns (IUniformEditionAuction.AuctionConfig memory) {
        return _terms[_settings.termsId];
    }

    /// @inheritdoc IUniformEditionAuctionStorage
    function storageWord(Space space, uint256 saleId, uint256 key)
        external
        view
        returns (uint256 word)
    {
        if (space == Space.LIVE) return _live[saleId][key];
        if (space == Space.DEPARTURE) return _departures[saleId][key];
        if (space == Space.FEE_RECIPIENT) return uint160(_feeRecipients[key]);
        if (space == Space.SCAN) return _scans[saleId];
        // Safe: a SWEEP key is a settler's address.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (space == Space.SWEEP) return _sweeps[saleId][address(uint160(key))];
        // Invariant: each block below only reads the slot Solidity computed for a storage pointer
        // (`.slot`), and the last loads that slot: no memory is touched.
        bytes32 slot;
        if (space == Space.SALE) {
            SaleWord storage s = _sales[saleId];
            assembly ("memory-safe") {
                slot := s.slot
            }
        } else if (space == Space.PAYOUT) {
            PayoutWord storage s = _payouts[saleId];
            assembly ("memory-safe") {
                slot := s.slot
            }
        } else if (space == Space.RESULT) {
            ResultWord storage s = _results[saleId];
            assembly ("memory-safe") {
                slot := s.slot
            }
        } else if (space == Space.BID) {
            IUniformEditionAuction.Bid storage s = _bids[saleId][key];
            assembly ("memory-safe") {
                slot := s.slot
            }
        } else {
            IUniformEditionAuction.AuctionConfig storage s = _terms[key];
            assembly ("memory-safe") {
                slot := s.slot
            }
        }
        assembly ("memory-safe") {
            word := sload(slot)
        }
    }

    /// @inheritdoc ISaleAdapter
    function claimable(address account, address currency) external view returns (uint256) {
        return currency == CURRENCY_ETH ? _credits[account] : 0;
    }

    /// @inheritdoc ISaleAdapter
    function saleKind() external pure returns (bytes32) {
        return SaleKind.UNIFORM_AUCTION;
    }

    /// @inheritdoc ISaleAdapter
    function paused() external view returns (bool) {
        return _settings.pausedAt != 0;
    }

    /// @inheritdoc ISaleAdapter
    /// @dev True only for `editions` while listed: the one token this adapter sells in v1.
    function isTarget(address token) external view returns (bool) {
        return token == editions && _settings.listed;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IUniformEditionAuction).interfaceId
            || interfaceId == type(ISaleAdapter).interfaceId
            || interfaceId == type(IERC165).interfaceId;
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
            if (count == type(uint16).max) revert InvalidSaleTerms(token, id);
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
            // Safe: a 32-bit time plus at most 8 days.
            // forge-lint: disable-next-line(unsafe-typecast)
            revert IUniformEditionAuction.BiddingClosed(saleId, uint64(endTime));
        }
        uint256 extended = block.timestamp + t.softWindow;
        if (extended > endTime) {
            uint256 backstop = closeAt + t.maxExtension;
            endTime = extended < backstop ? extended : backstop;
            // forge-lint: disable-next-line(unsafe-typecast)
            a.softEnd = uint32(endTime);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(endTime);
    }

    /// @dev The end of OPEN sale `a`: `max(closeAt, softEnd)`, the soft end held within
    ///      `maxExtension` of `closeAt = oneOfOneEnd + closeOffset`. Reads the 1/1 when `fresh`,
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
            IEnglishAuction.Auction memory o = _oneOfOne(saleId);
            one = o.state;
            if (o.endTime > a.oneOfOneEnd) {
                // Safe: the 1/1 stores its end in 32 bits.
                // forge-lint: disable-next-line(unsafe-typecast)
                a.oneOfOneEnd = uint32(o.endTime);
                closeAt = uint256(o.endTime) + t.closeOffset;
            }
        }
        uint256 soft = a.softEnd;
        uint256 backstop = closeAt + t.maxExtension;
        if (soft > backstop) soft = backstop;
        endTime = soft > closeAt ? soft : closeAt;
    }

    /// @dev The first settle call's checks: voids the sale if the 1/1 was cancelled (returns
    ///      true), or requires the close passed and the 1/1 settled and moves the sale to
    ///      SETTLING, its book frozen for the scan.
    function _begin(uint256 saleId, SaleWord storage stored) private returns (bool voided) {
        SaleWord memory a = stored;
        IUniformEditionAuction.AuctionConfig memory t = _terms[a.termsId];
        (uint256 endTime,, IEnglishAuction.AuctionState one) = _end(saleId, a, t, true);
        if (one == IEnglishAuction.AuctionState.CANCELLED) {
            stored.status = IUniformEditionAuction.AuctionStatus.VOID;
            emit IUniformEditionAuction.AuctionVoided(saleId);
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
    ///      true with the count and price `settle` pays last.
    function _scanChunk(uint256 saleId, SaleWord storage stored)
        private
        returns (bool cleared, uint256 count, uint256 price)
    {
        SaleWord memory a = stored;
        IUniformEditionAuction.AuctionConfig memory t = _terms[a.termsId];
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
        if (count != 0 && !IEditions(editions).exists(p.id)) {
            revert IUniformEditionAuction.EditionNotCreated(editions, p.id);
        }
        // Safe: counts below 2^32 and steps below 512.
        // forge-lint: disable-start(unsafe-typecast)
        _results[saleId] = ResultWord(
            uint32(count), uint16(step), rationed, uint32(cutUnits), uint32(cutUnits), 0, 0, p.id
        );
        // forge-lint: disable-end(unsafe-typecast)
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
        if (fee != 0) RevenuePayment.payETH(IRevenueEscrow(escrow), feeRecipient, fee, PAYOUT_GAS);
        if (revenue != fee) {
            RevenuePayment.payETH(IRevenueEscrow(escrow), p.seller, revenue - fee, PAYOUT_GAS);
        }
        emit SaleSettled(
            saleId,
            editions,
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
    function _claim(uint256 saleId, uint256 bidId, IUniformEditionAuction.Bid memory b, address to)
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
        if (status == IUniformEditionAuction.AuctionStatus.SETTLED) {
            ResultWord memory r = _results[saleId];
            id = r.id;
            if (r.count != 0 && b.step >= r.step) {
                unitsWon = b.step > r.step || !r.rationed
                    ? b.quantity
                    : UniformClearing.wonAtCut(r.cutoff, b.position, b.quantity);
                refund -= unitsWon * _price(t, r.step);
            }
        }
        delete _bids[saleId][bidId];
        emit IUniformEditionAuction.BidClaimed(saleId, bidId, b.bidder, to, unitsWon, refund);
        if (unitsWon != 0) {
            (uint256 minted,) = IMintTarget(editions).mint(to, id, unitsWon, "");
            if (minted != id) revert InvalidSaleTerms(editions, id);
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
        if (
            !StepLadder.isStepsPerDecade(next.stepsPerDecade)
                || !StepLadder.isBasePrice(next.basePrice)
                || next.stepCount < StepLadder.MIN_STEP_COUNT
                || next.stepCount > StepLadder.MAX_STEP_COUNT
                || _price(next, next.stepCount - 1) < StepLadder.MIN_TOP_PRICE
                || next.marginShare > _MAX_MARGIN_SHARE || next.closeOffset > _MAX_CLOSE_OFFSET
                || next.softWindow < _MIN_SOFT_WINDOW || next.softWindow > _MAX_SOFT_WINDOW
                || next.maxExtension < _MIN_MAX_EXTENSION || next.maxExtension > _MAX_MAX_EXTENSION
        ) revert IUniformEditionAuction.InvalidConfig();
        Settings storage st = _settings;
        uint16 id = st.termsCount;
        if (id == type(uint16).max) revert IUniformEditionAuction.InvalidConfig();
        ++id;
        emit IUniformEditionAuction.ConfigSet(_terms[st.termsId], next);
        _terms[id] = next;
        (st.termsId, st.termsCount) = (id, id);
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

    /// @dev The 1/1 auction of sale `saleId` (its edition ID is in the payout word): its state
    ///      and end, the only fields read, from `auctionClock` (the rest stay zero).
    function _oneOfOne(uint256 saleId) private view returns (IEnglishAuction.Auction memory o) {
        uint256 id = _payouts[saleId].id;
        (o.state, o.endTime) =
            IEnglishAuctionClock(englishAuction).auctionClock(saleIdOf(stream, id));
    }

    /// @dev Sale `saleId`'s state word, required OPEN.
    function _open(uint256 saleId) private view returns (SaleWord memory a) {
        a = _sales[saleId];
        _requireStatus(saleId, a.status, IUniformEditionAuction.AuctionStatus.OPEN);
    }

    /// @dev `IEditions.bindMinter(id, item)` with the item `open` received, bubbling a revert.
    ///      `data` is `abi.encode(item)`: the tuple's offset word, then the tuple, whose inner
    ///      offsets are relative to its start. So the call's arguments are `id`, the tuple's new
    ///      offset (0x40) and `data` past its first word, and this contract needs no item codec.
    ///      A `data` the lens decoded through another offset hands Editions a different item,
    ///      whose hash is not the master's: the open reverts (`NotEditionMaster`).
    function _bindEdition(uint256 id, bytes calldata data) private {
        address target = editions;
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
    function _bidOf(uint256 saleId, uint256 bidId)
        private
        view
        returns (IUniformEditionAuction.Bid memory b)
    {
        b = _bids[saleId][bidId];
        if (b.bidder == address(0)) revert IUniformEditionAuction.UnknownBid(saleId, bidId);
    }
}
