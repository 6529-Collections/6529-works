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
///      (`IEnglishAuction.auction`) only when a bid or raise lands within `softWindow` of the
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
    /// @dev Departure log entries in a step's head word; four in each word after it.
    uint256 private constant _HEAD_ENTRIES = 3;

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
    mapping(uint256 saleId => mapping(uint256 bidId => IUniformEditionAuction.Bid)) private _bids;
    mapping(uint256 saleId => mapping(uint256 word => uint256)) private _live;
    mapping(uint256 saleId => mapping(uint256 key => uint256)) private _departures;
    mapping(address account => uint256) private _credits;

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

    /// @notice Settles a closed sale, or voids it after a 1/1 cancel; resumes a departure sweep
    ///         (`IUniformEditionAuction.settle`).
    /// @param saleId The sale ID.
    /// @param order The next departure indexes of the clearing step, in position order.
    /// @return Whether the sale is now SETTLED or VOID.
    /// @dev Pays with `RevenuePayment.payETH`, {PAYOUT_GAS} per wallet: a refusal is escrowed for
    ///      that wallet and never blocks settlement.
    function settle(uint256 saleId, uint256[] calldata order) external nonReentrant returns (bool) {
        SaleWord storage a = _sales[saleId];
        IUniformEditionAuction.AuctionStatus status = a.status;
        if (status == IUniformEditionAuction.AuctionStatus.OPEN) {
            if (_clearAtClose(saleId, a)) return true;
        } else {
            _requireStatus(saleId, status, IUniformEditionAuction.AuctionStatus.SETTLING);
        }
        return _sweep(saleId, a, order);
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

    /// @dev The first settle call: voids the sale if the 1/1 was cancelled (returns true), or
    ///      requires the end passed and the 1/1 settled, stores the clearing and pays it, and
    ///      returns whether the sale is SETTLED (false: a departure sweep must run first).
    function _clearAtClose(uint256 saleId, SaleWord storage stored) private returns (bool) {
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
        PayoutWord memory p = _payouts[saleId];
        UniformClearing.Result memory c = UniformClearing.clear(
            _book(saleId, a),
            UniformClearing.Rules(t.basePrice, t.stepsPerDecade, a.maxCount, t.marginShare)
        );
        if (c.count != 0 && !IEditions(editions).exists(p.id)) {
            revert IUniformEditionAuction.EditionNotCreated(editions, p.id);
        }
        uint256 logged = c.rationed ? uint32(_departures[saleId][c.step << 32]) : 0;
        // Safe: counts below 2^32 and steps below 512.
        // forge-lint: disable-next-line(unsafe-typecast)
        _results[saleId] = ResultWord(
            uint32(c.count),
            uint16(c.step),
            c.rationed,
            uint32(c.cutUnits),
            uint32(c.cutUnits),
            0,
            0,
            p.id
        );
        stored.oneOfOneEnd = a.oneOfOneEnd;
        stored.status = logged == 0
            ? IUniformEditionAuction.AuctionStatus.SETTLED
            : IUniformEditionAuction.AuctionStatus.SETTLING;
        emit IUniformEditionAuction.AuctionCleared(
            saleId, c.count, c.step, c.price, c.count * c.price, c.rationed, c.cutUnits
        );
        _pay(saleId, p, c.count, c.price);
        if (logged != 0) return false;
        emit IUniformEditionAuction.AuctionSettled(saleId, c.count, c.rationed ? c.cutUnits : 0);
        return true;
    }

    /// @dev Runs one chunk of the departure sweep of a SETTLING sale (ADR 0005; PLAN section
    ///      1.6): each departure from the clearing step, in strictly increasing position, moves
    ///      the cutoff past its units when it starts below the cutoff. Once every departure is
    ///      swept the cutoff is exact, the sale is SETTLED and claims open.
    function _sweep(uint256 saleId, SaleWord storage a, uint256[] calldata order)
        private
        returns (bool)
    {
        ResultWord memory r = _results[saleId];
        uint256 head = _departures[saleId][uint256(r.step) << 32];
        uint256 total = uint32(head);
        uint256 swept = r.swept;
        uint256 cutoff = r.cutoff;
        uint256 next = r.nextPosition;
        for (uint256 i; i < order.length && swept < total; ++i) {
            if (order[i] >= total) revert IUniformEditionAuction.InvalidSettlementOrder(i);
            uint256 entry = _departure(saleId, r.step, head, order[i]);
            (cutoff, next) =
                UniformClearing.sweep(cutoff, next, uint32(entry), uint32(entry >> 32), i);
            ++swept;
        }
        // Safe: the cutoff is at most the step's entered units, and positions fit 32 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        (r.swept, r.cutoff, r.nextPosition) = (uint32(swept), uint32(cutoff), uint32(next));
        _results[saleId] = r;
        emit IUniformEditionAuction.DeparturesSwept(saleId, swept, total, cutoff);
        if (swept < total) return false;
        a.status = IUniformEditionAuction.AuctionStatus.SETTLED;
        emit IUniformEditionAuction.AuctionSettled(saleId, r.count, cutoff);
        return true;
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
        ResultWord memory r;
        if (status == IUniformEditionAuction.AuctionStatus.SETTLED) {
            r = _results[saleId];
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
            (uint256 minted,) = IMintTarget(editions).mint(to, r.id, unitsWon, "");
            if (minted != r.id) revert InvalidSaleTerms(editions, r.id);
        }
    }

    /// @dev The live words of sale `a` up to its highest step: `UniformClearing`'s book.
    function _book(uint256 saleId, SaleWord memory a) private view returns (uint256[] memory live) {
        if (a.liveUnits == 0) return live;
        live = new uint256[]((uint256(a.highStep) >> 3) + 1);
        for (uint256 w = uint256(a.lowStep) >> 3; w < live.length; ++w) {
            live[w] = _live[saleId][w];
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
        uint256 position = uint32(word >> shift) + uint32(_departures[saleId][step << 32] >> 32);
        if (position + quantity > type(uint32).max) {
            revert IUniformEditionAuction.InvalidQuantity(quantity);
        }
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
        uint256 count = uint32(head);
        // The departed units stay at most the step's entered units, which fit 32 bits.
        head = (head >> 64 << 64) | (count + 1) | (uint256(uint32(head >> 32)) + quantity) << 32;
        uint256 entry = position | quantity << 32;
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
                || next.basePrice < StepLadder.MIN_BASE_PRICE
                || next.basePrice > StepLadder.MAX_BASE_PRICE
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

    /// @dev Step `step`'s price under `t`: `UniformClearing.price`, which equals `StepLadder.price`
    ///      (one mantissa table in the bytecode, not two; the tests check every step).
    function _price(IUniformEditionAuction.AuctionConfig memory t, uint256 step)
        private
        pure
        returns (uint256)
    {
        return UniformClearing.price(t.basePrice, t.stepsPerDecade, step);
    }

    /// @dev The 1/1 auction of sale `saleId` (its edition ID is in the payout word).
    function _oneOfOne(uint256 saleId) private view returns (IEnglishAuction.Auction memory) {
        uint256 id = _payouts[saleId].id;
        return IEnglishAuction(englishAuction).auction(saleIdOf(stream, id));
    }

    /// @dev Sale `saleId`'s state word, required OPEN.
    function _open(uint256 saleId) private view returns (SaleWord memory a) {
        a = _sales[saleId];
        _requireStatus(saleId, a.status, IUniformEditionAuction.AuctionStatus.OPEN);
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
