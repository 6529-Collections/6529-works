// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IAssetAllowlist } from "../economics/interfaces/IAssetAllowlist.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { RevenuePayment } from "../economics/RevenuePayment.sol";
import { Splits } from "../economics/Splits.sol";
import { TokenTransfer } from "../economics/TokenTransfer.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IEnglishAuctionClock } from "../interfaces/IEnglishAuctionClock.sol";
import { IFederationRegistry } from "../interfaces/IFederationRegistry.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IStatementLog } from "../interfaces/IStatementLog.sol";
import { ISignatureTransfer } from "../interfaces/external/ISignatureTransfer.sol";
import {
    CURRENCY_DEFAULT,
    CURRENCY_ETH,
    PRODUCT_FEDERATED,
    PRODUCT_STREAM
} from "../interfaces/types/EconomicsTypes.sol";
import {
    LockedTerms,
    Payment,
    PaymentMethod,
    PrimaryOutcome,
    PrimarySettlement,
    PrimaryTerms,
    SaleKind
} from "../interfaces/types/SaleTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { Roles } from "../governance/Roles.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { Dependency } from "../libraries/Dependency.sol";
import { EnglishAuctionLens } from "./EnglishAuctionLens.sol";

/// @title EnglishAuction
/// @notice The shared English auction: 6529 Stream's only primary sale (ADR 0001 sections 5 and
///         12). See {IEnglishAuction} for the behaviour; this contract adds the storage layout and
///         the bounds.
/// @dev Start gas (PR #10 review, D3 and E2). A start in steady state writes one storage word: the
///      token, its ID (at most 32 bits), the end time (32-bit seconds, so starts stop in 2106), the
///      sale's state, and a 16-bit reference to a shared "terms" record. A terms record holds the
///      values every sale locks at start (currency, opening bid, increment share, anti-snipe
///      window, and a federated token's registry fee) and is written once per distinct combination.
///      The currency's increment floor is locked by the first bid (E2), which only later bids need.
///      Seller, fee recipient and fee share are read back from the token
///      at settlement, as `LockedTerms`, by the call that reports the sale's outcome
///      (`IMintTarget.settlePrimary`, owner decision 17). An unsold 6529 Stream work is moved to
///      the museum by Stream itself in that call; any other token's unsold work goes to the
///      artist's active authority the token reports (D140, owner decision 9). A VRF item's
///      seed is checked
///      by the token's `mint` (`IEntropyModule.isDelivered(itemHash)`), since the mint data is
///      opaque here. A pause is recorded once (`pausedAt`) and is live through `pausedAt +
///      MAX_PAUSE` inclusive, so an upheld `cancel` scheduled with the 48-hour delay exactly at day
///      5 still lands. After that it ends by itself: views and every mutating entry point treat it
///      as resumed with a {MAX_PAUSE} pause, and the first mutating call writes the resumption
///      down. Every bid checks that the locked currency is still active in the allowlist.
///      Deprecation freezes a running auction (MARKET-2): a standing bid settles only once the
///      currency is re-admitted (its bidder may withdraw meanwhile), and the first settle after a
///      re-admission in the auction's last window or after its end reopens it instead
///      (`AuctionResumed`). Refunds and claims never read the allowlist.
contract EnglishAuction is
    IERC721Receiver,
    IEnglishAuctionClock,
    AccessManaged,
    ReentrancyGuardTransient
{
    /// @dev The longest a dispute pause lasts; one pause per auction (ADR 0001 section 12). The
    ///      lens answers `MAX_PAUSE()` with the same value.
    uint64 private constant _MAX_PAUSE = 7 days;
    /// @notice Bounds of the governed duration.
    uint32 internal constant MIN_DURATION = 1 hours;
    /// @notice Bounds of the governed duration.
    uint32 internal constant MAX_DURATION = 7 days;
    /// @notice Bounds of the governed anti-snipe window.
    uint32 internal constant MIN_EXTENSION_WINDOW = 1 minutes;
    /// @notice Bounds of the governed anti-snipe window.
    uint32 internal constant MAX_EXTENSION_WINDOW = 1 days;
    /// @notice The smallest governed relative increment (1%, out of 100,000).
    uint32 internal constant MIN_INCREMENT_SHARE = 1_000;
    /// @dev An opening bid is at most this many increment floors of its currency (1 ETH for
    ///      the 0.001 ETH floor), and at most `type(uint96).max`, the largest bid: the absolute
    ///      ceiling of the governed opening bid. The lens answers `OPENING_BID_FLOORS()`.
    uint256 private constant _OPENING_BID_FLOORS = 1_000;
    /// @dev Gas forwarded to a seller or fee wallet on an ETH payout; a refusal is escrowed.
    ///      Under the EIP-8037 draft it caps regular gas only: a wallet that writes new state draws
    ///      state gas from the settler's EIP-8037 reservoir, so whether it is paid or escrowed can
    ///      depend on the settler's gas limit (CALLS-3, LIM-GAS-2). Settlers should send at most
    ///      2^24 gas. The lens answers `PAYOUT_GAS()`.
    uint256 private constant _PAYOUT_GAS = 100_000;
    /// @notice Gas forwarded to the token's `safeTransferFrom` when settling; a failure leaves a
    ///         pending claim. Under the EIP-8037 draft it caps regular gas only: a recipient whose
    ///         `onERC721Received` writes new state draws state gas from the settler's EIP-8037
    ///         reservoir, so whether delivery succeeds or stays pending can depend on the settler's
    ///         gas limit (CALLS-3, LIM-GAS-2). Settlers should send at most 2^24 gas.
    uint256 internal constant DELIVERY_GAS = 300_000;
    /// @notice Gas the settlement needs after the delivery attempt returns.
    uint256 internal constant DELIVERY_RESERVE = 50_000;
    /// @dev Gas given to an ERC-20 payout's own call frame (MONEY-1): the token's 300,000, the
    ///      escrow fallback and new-slot costs under Glamsterdam fit with room to spare. A payout
    ///      that fails in it is credited to the wallet instead; the caller must forward it in full.
    uint256 private constant _ERC20_PAYOUT_GAS = 1_000_000;
    /// @dev How long a sale's currency must have been deprecated before anyone may end the
    ///      frozen sale unsold (MARKET-2): the standing bid is credited back and the work goes
    ///      where an unbid work goes (D140: the museum for 6529 Stream, else the artist).
    uint256 private constant _FREEZE_EXIT = 30 days;

    bytes4 private constant _SAFE_TRANSFER_FROM = 0x42842e0e;
    uint8 private constant _PAUSE_USED = 1;
    uint8 private constant _DELIVERY_PENDING = 2;
    /// @dev Slot 2 holds a recipient. With this flag and `_PAUSE_USED` clear, a bid never reads
    ///      slot 2, which a first bid for oneself would otherwise read cold.
    uint8 private constant _RECIPIENT_SET = 4;

    /// @dev One auction in three slots. Slot 0 is written at start (and its terms reference
    ///      and flags again by the first bid, which locks the increment floor). Slot 1 holds the
    ///      high bidder and the high bid (at most `uint96`). Slot 2 holds the recipient only when
    ///      it differs from the bidder (`_RECIPIENT_SET`), or after an unsold settlement the
    ///      museum 6529 Stream moved the work to or the artist, and the dispute pause (`_PAUSE_USED`), with the lowest
    ///      statement-log chain position an outcome recorded after the pause has
    ///      (`outcomeFrom`). A first bid for oneself writes one fresh slot and does not read
    ///      slot 2.
    struct Sale {
        address token;
        uint32 tokenId;
        uint32 endTime;
        uint16 termsId;
        IEnglishAuction.AuctionState status;
        uint8 flags;
        address bidder;
        uint96 bid;
        address recipient;
        uint32 pausedAt;
        uint24 pausedTotal;
        uint40 outcomeFrom;
    }

    /// @dev The governed parameters and the emergency start pause (when it began, zero while
    ///      not paused): one slot, read once per start.
    struct Settings {
        uint32 duration;
        uint32 extensionWindow;
        uint32 incrementShare;
        uint40 pausedAt;
    }

    /// @dev The values a sale locks, shared by every sale that locked the same ones. A start
    ///      locks every field but the increment floor (zero); the first bid moves the sale to the
    ///      record with the floor it reads (E2).
    struct Terms {
        address currency;
        uint96 incrementFloor;
        uint96 openingBid;
        uint24 incrementShare;
        uint24 extensionWindow;
        uint32 registryFee;
        bool federated;
    }

    /// @notice The lens, deployed before this contract and pinned by its constructor: it answers
    ///         every view of `IEnglishAuction` and `ISaleAdapter` this contract does not declare,
    ///         through {fallback}. Stateless and fixed: nothing can replace it.
    address public immutable lens;
    /// @dev The revenue escrow for refused payouts (`escrow()`, answered by the lens).
    address private immutable _escrow;
    /// @dev The statement log `cancel` reads (`statementLog()`, answered by the lens).
    address private immutable _statementLog;
    /// @dev The asset allowlist: currencies, defaults and increment floors (`allowlist()`).
    IAssetAllowlist private immutable _allowlist;
    /// @dev The economics resolver: the network fee recipient of federated sales (MARKET-3)
    ///      (`economicsResolver()`).
    IEconomicsResolver private immutable _economicsResolver;
    /// @dev The canonical Permit2, or zero when PERMIT2 payments are disabled (`permit2()`).
    address private immutable _permit2;

    /// @dev Storage slot 1 (the lens reads it): the federation registry (`federationRegistry()`).
    address private _federationRegistry;
    /// @dev Storage slot 2: the code hash pinned when the federation registry was installed; a
    ///      registry whose code no longer matches serves no token (`federationRegistryCodeHash()`).
    bytes32 private _federationRegistryCodeHash;
    Settings private _settings;
    uint16 private _termsCount;
    mapping(address token => bool) private _listed;
    mapping(bytes32 key => uint16) private _termsIds;
    mapping(uint16 termsId => Terms) private _terms;
    mapping(uint256 saleId => Sale) private _sales;
    mapping(address currency => uint256) private _openingBids;
    mapping(address account => mapping(address currency => uint256)) private _credits;

    /// @param authority The AccessManager governing this adapter.
    /// @param escrow_ The revenue escrow for refused payouts.
    /// @param economicsResolver_ The economics resolver (ERC-165, not EIP-7702 delegated): the
    ///        federated network fee recipient, and its asset allowlist, read at start, on every
    ///        bid and at settlement.
    /// @param statementLog_ The statement log `cancel` reads.
    /// @param permit2_ The canonical Permit2, or zero to disable PERMIT2 payments.
    /// @param lens_ The lens, deployed beforehand in its own transaction (the rc.2 review's GAS
    ///        M-2: so each deployment fits a block under Glamsterdam): it must have code, no
    ///        EIP-7702 delegation, the code hash `lensCodeHash` and this contract's escrow,
    ///        statement log, asset allowlist, economics resolver and Permit2
    ///        (`Dependency.InvalidDependency` otherwise).
    /// @param lensCodeHash The lens's reviewed code hash.
    /// @param config_ The initial auction parameters.
    /// @param targets Token contracts listed at genesis.
    constructor(
        address authority,
        address escrow_,
        IEconomicsResolver economicsResolver_,
        address statementLog_,
        address permit2_,
        address lens_,
        bytes32 lensCodeHash,
        IEnglishAuction.AuctionConfig memory config_,
        address[] memory targets
    ) AccessManaged(authority) {
        Dependency.check(escrow_);
        Dependency.check(address(economicsResolver_), type(IEconomicsResolver).interfaceId);
        IAssetAllowlist allowlist_ = IAssetAllowlist(economicsResolver_.assetAllowlist());
        Dependency.check(address(allowlist_));
        Dependency.check(statementLog_);
        if (permit2_ != address(0)) Dependency.check(permit2_);
        Dependency.checkPinned(lens_, lensCodeHash);
        EnglishAuctionLens l = EnglishAuctionLens(lens_);
        if (
            l.escrow() != escrow_ || l.statementLog() != statementLog_
                || address(l.allowlist()) != address(allowlist_)
                || address(l.economicsResolver()) != address(economicsResolver_)
                || l.permit2() != permit2_
        ) revert Dependency.InvalidDependency(lens_);
        _escrow = escrow_;
        _economicsResolver = economicsResolver_;
        _allowlist = allowlist_;
        _statementLog = statementLog_;
        _permit2 = permit2_;
        lens = lens_;
        _setConfig(config_);
        for (uint256 i; i < targets.length; ++i) {
            _setTarget(targets[i], true);
        }
    }

    // ------------------------------------------------------------------------------- start

    /// @notice Mints a work into custody and opens its auction. Permissionless.
    /// @param token A served token contract.
    /// @param mintData The token-specific mint request (for 6529 Stream,
    ///        `abi.encode(StreamMintRequest)`).
    /// @return saleId `saleIdOf(token, tokenId)`.
    /// @dev Reverts with `SalePaused` while the emergency pause is on.
    function start(address token, bytes calldata mintData)
        external
        nonReentrant
        returns (uint256 saleId)
    {
        saleId = _start(token, mintData);
    }

    /// @notice `start` plus a first bid in one transaction. The bid is at most
    ///         `type(uint96).max` base units (about 7.9e28), like every bid.
    /// @param token A served token contract.
    /// @param mintData The token-specific mint request (for 6529 Stream,
    ///        `abi.encode(StreamMintRequest)`).
    /// @param recipient Who receives the token if the bid wins, or zero for the payer.
    /// @param payment The first bid's payment: `payment.amount` is the bid in the locked
    ///        currency's base units; a PERMIT2 signature covers `Typehashes.START_BID_WITNESS`.
    /// @return saleId `saleIdOf(token, tokenId)`.
    /// @dev A PERMIT2 payment signs `Typehashes.START_BID_WITNESS` over the token, the hash of
    ///      `mintData`, the resolved recipient (the payer when zero), the amount and the deadline.
    function startWithBid(
        address token,
        bytes calldata mintData,
        address recipient,
        Payment calldata payment
    ) external payable nonReentrant returns (uint256 saleId) {
        saleId = _start(token, mintData);
        if (recipient == address(0)) recipient = payment.payer;
        bytes32 witness = payment.method != PaymentMethod.PERMIT2
            ? bytes32(0)
            : keccak256(
                abi.encode(
                    Typehashes.START_BID_WITNESS,
                    token,
                    keccak256(mintData),
                    recipient,
                    payment.amount,
                    payment.deadline
                )
            );
        _bid(saleId, recipient, payment, witness, true);
    }

    // ----------------------------------------------------------------------------- bidding

    /// @notice Bids `payment.amount` for `recipient` (the payer when zero). A bid is at most
    ///         `type(uint96).max` base units (about 7.9e28); a larger one reverts.
    /// @param saleId The auction's sale ID.
    /// @param recipient Who receives the token if the bid wins, or zero for the payer.
    /// @param payment The bid's payment: `payment.amount` is the bid in the locked currency's
    ///        base units; a PERMIT2 signature covers `Typehashes.BID_WITNESS`.
    /// @dev A PERMIT2 payment signs `Typehashes.BID_WITNESS` over the sale, the resolved recipient
    ///      (the payer when zero), the amount and the deadline.
    function bid(uint256 saleId, address recipient, Payment calldata payment)
        external
        payable
        nonReentrant
    {
        if (recipient == address(0)) recipient = payment.payer;
        bytes32 witness = payment.method != PaymentMethod.PERMIT2
            ? bytes32(0)
            : keccak256(
                abi.encode(
                    Typehashes.BID_WITNESS, saleId, recipient, payment.amount, payment.deadline
                )
            );
        _bid(saleId, recipient, payment, witness, false);
    }

    /// @notice The high bidder withdraws its bid while the auction is paused, or while its
    ///         currency is deprecated and it has not settled (MARKET-2); it is credited back
    ///         and the auction has no bid. The withdrawn amount stays as a reserve the next bid
    ///         must reach, and the resumed auction runs at least the governed duration, so the
    ///         refunded bidders can return (LIFECYCLE-1).
    /// @param saleId The auction's sale ID; the caller must be its high bidder.
    /// @dev Also while the locked currency is deprecated (MARKET-2: the auction is frozen), so a
    ///      currency that never returns cannot hold the bid.
    function withdrawBid(uint256 saleId) external nonReentrant {
        Sale storage s = _sales[saleId];
        // MARKET-2: a live (or ended, unsettled) auction whose currency is deprecated is frozen.
        (bool active,,) = _currencyClock(s);
        if (s.status != IEnglishAuction.AuctionState.ACTIVE || active) {
            s = _require(saleId, IEnglishAuction.AuctionState.PAUSED);
        }
        address bidder = s.bidder;
        // With no bidder this reverts too: the caller is never the zero address.
        if (msg.sender != bidder) revert IEnglishAuction.NotHighBidder(msg.sender);
        uint256 amount = s.bid;
        _refundHighBid(saleId, s);
        emit IEnglishAuction.BidWithdrawn(saleId, bidder, amount);
    }

    // -------------------------------------------------------------------------- settlement

    /// @notice Settles an ended auction: delivers the token (or records a pending claim) and pays
    ///         the seller and the network fee. Permissionless. An ERC-20 payout runs in its own
    ///         1,000,000-gas frame, which the caller must be able to forward in full (a call gas
    ///         limit of about 1.11M); if it fails, even through the escrow, it is credited to its
    ///         wallet (`Credited`, paid out later with `claimFor`), so delivery never depends on it
    ///         (MONEY-1). While the locked currency is deprecated nothing settles
    ///         (`AssetNotActive`; a standing bidder may withdraw). If it was re-admitted after
    ///         the end, or within the sale's last anti-snipe window before it, the first call
    ///         reopens the auction for the governed duration (or the anti-snipe window if longer)
    ///         and emits `AuctionResumed` instead of settling. Once the currency has been
    ///         deprecated for 30 days, the call ends the sale unsold: the standing bid is
    ///         credited back and the work goes where an unbid work goes, the museum for 6529
    ///         Stream and the artist for any other token (MARKET-2; ADR 0005, owner decision 10).
    ///         A sale of a federated contract the registry has since delisted settles the same
    ///         way, to its artist (MARKET-5).
    /// @param saleId The ended auction's sale ID.
    /// @dev Reports the outcome to the token first (`IMintTarget.settlePrimary`, owner decision
    ///      17, E11): SOLD with the bidder, the locked currency and the price; FROZEN_OUT when
    ///      the freeze exit or a delisting ended the sale; UNBID otherwise. The token returns the
    ///      seller and fee terms, while the work is still in custody, whether or not a delivery
    ///      then succeeds, so a winner who never claims cannot hold up the edition. 6529 Stream
    ///      moves an unsold work to the museum its economics resolver names now, whether or not
    ///      the artist is restrained, and the auction records the museum as the recipient and
    ///      delivers nothing; for any other token, listed or federated, the unsold work goes to
    ///      the artist's active authority the token reports (owner decision 9). With no bids on
    ///      another token and no active artist
    ///      (the token reports a zero creator while a recovery override is pending) it reverts
    ///      with `InvalidRecipient(address(0))` and moves nothing, the token staying in custody;
    ///      anyone may retry once the override executes, is vetoed or voided, or lapses.
    function settle(uint256 saleId) external nonReentrant {
        Sale storage s = _require(saleId, IEnglishAuction.AuctionState.ENDED);
        (bool reopened, bool frozenOut) = _reopenedAfterFreeze(saleId, s);
        if (reopened) return;
        // MARKET-5: a delisted federated contract cannot sell; its high bid is credited back and
        // the sale ends unsold, as with no bid. Nothing is confiscated.
        if (_delisted(s)) {
            _refundHighBid(saleId, s);
            frozenOut = true;
        }
        s.status = IEnglishAuction.AuctionState.SETTLED;
        address bidder = s.bidder;
        // With no bidder, `s.bid` is at most a withdrawn bid's reserve: nothing is paid.
        uint256 price = bidder == address(0) ? 0 : s.bid;
        (LockedTerms memory lt, bool taken) = _settleWithToken(s, bidder, price, frozenOut);
        // Exact: a bid fits 96 bits and the share 17, so the product cannot overflow.
        uint256 fee = price * lt.feeShare / Splits.DENOMINATOR;
        _pay(lt.currency, lt.seller, price - fee, saleId);
        _pay(lt.currency, lt.feeRecipient, fee, saleId);
        // 6529 Stream moved an unsold work to the museum itself (owner decision 17).
        if (!taken) _deliver(saleId, s);
        _emitSettled(saleId, s, lt, price, fee);
    }

    /// @notice The winner whose delivery is pending names the recipient `to` and receives the
    ///         token there. For an unsold work of a token other than 6529 Stream, the artist
    ///         recorded at settlement claims it, or the artist the token reports now (L-5). An
    ///         unsold 6529 Stream work is never pending: Stream moved it to the museum.
    /// @param saleId The auction's sale ID.
    /// @param to The address that receives the token; neither zero nor this adapter.
    /// @dev The pending recipient or the winning bidder (the payer of the high bid) may claim, to
    ///      any address except zero and this adapter, so a recipient contract that cannot make the
    ///      call does not strand the token. With no bids the artist may, as the authority
    ///      recorded at settlement or the active one the token reports (L-5). If neither the recipient nor the winner can make the call, the token
    ///      stays in custody: that is the winner's choice of recipient.
    function claimDelivery(uint256 saleId, address to) external nonReentrant {
        Sale storage s = _sales[saleId];
        address pending = _recipientOf(s);
        address bidder = s.bidder;
        if (
            s.flags & _DELIVERY_PENDING == 0
                || (msg.sender != pending
                    && msg.sender != bidder
                    && (bidder != address(0) || msg.sender != _unbidClaimant(s)))
        ) revert IEnglishAuction.NoPendingDelivery(saleId);
        if (to == address(0) || to == address(this)) revert ISaleAdapter.InvalidRecipient(to);
        s.flags &= ~_DELIVERY_PENDING;
        IERC721(s.token).safeTransferFrom(address(this), to, s.tokenId);
        emit IEnglishAuction.DeliveryClaimed(saleId, pending, to);
    }

    // ---------------------------------------------------------------------------- disputes

    /// @notice Pauses a live auction for a dispute, once per auction. GUARDIAN role (immediate).
    /// @param saleId The live auction's sale ID.
    /// @param disputeRef A reference to the dispute, emitted in `AuctionPaused`; not checked.
    function pause(uint256 saleId, bytes32 disputeRef) external restricted nonReentrant {
        Sale storage s = _require(saleId, IEnglishAuction.AuctionState.ACTIVE);
        if (s.flags & _PAUSE_USED != 0) revert IEnglishAuction.PauseExhausted(saleId);
        s.flags |= _PAUSE_USED;
        s.pausedAt = SafeCast.toUint32(block.timestamp);
        // LIFECYCLE-4: `cancel` must cite an outcome recorded after this pause, so one past the
        // position of the token's own latest outcome now (none: any position).
        (bytes32 entry, uint64 index) = _ownOutcome(s);
        // Safe: a statement-log position is far below 2^40.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (entry != 0) s.outcomeFrom = uint40(index + 1);
        emit IEnglishAuction.AuctionPaused(saleId, disputeRef);
    }

    /// @notice Resumes a paused auction after a rejected dispute, for its remaining time or the
    ///         governed duration, whichever is longer (the anti-snipe window if longer still),
    ///         even with a standing bid. UNPAUSER role (pause and unpause have separate holders).
    ///         Refused until 48 hours (`Roles.STANDARD`) after the pause, so the guardians can
    ///         always cancel a resume, even one scheduled before the pause. A pause also ends by
    ///         itself 7 days (`MAX_PAUSE`) after it began, without any call.
    /// @param saleId The paused auction's sale ID.
    /// @dev Reverts with `UnpauseTooEarly` before `pausedAt + Roles.STANDARD` (GOV-5).
    function resume(uint256 saleId) external restricted nonReentrant {
        Sale storage s = _require(saleId, IEnglishAuction.AuctionState.PAUSED);
        uint256 pausedAt = s.pausedAt;
        _requireUnpausable(pausedAt);
        _endPause(saleId, s, block.timestamp - pausedAt);
    }

    /// @notice Cancels a paused auction after an upheld dispute: credits the high bid back and
    ///         burns the token. PARAMETER_SETTER role, while paused, and like `resume` no earlier
    ///         than 48 hours after the pause (`UnpauseTooEarly`), and no later than
    ///         `pausedAt + MAX_PAUSE` inclusive. `outcomeRef` must be nonzero and be the token's
    ///         own latest outcome, `IStatementLog.disputeOutcomeOf(token, tokenId)` (no item
    ///         fallback), recorded after the pause: an outcome recorded before the pause, or one
    ///         about the package item, cannot cancel.
    /// @param saleId The paused auction's sale ID.
    /// @param outcomeRef The statement-log entry hash of the token's latest DISPUTE_OUTCOME.
    /// @dev The statement log does not record on-chain whether an outcome upheld or rejected
    ///      the dispute. The decision to cancel is the governed 48-hour action itself
    ///      (PARAMETER_SETTER, cancellable by the guardian during its delay); the recorded
    ///      DISPUTE_OUTCOME entry is the public record it must cite, so no auction is cancelled
    ///      without one. Accepted through `pausedAt + MAX_PAUSE` inclusive.
    function cancel(uint256 saleId, bytes32 outcomeRef) external restricted nonReentrant {
        Sale storage s = _require(saleId, IEnglishAuction.AuctionState.PAUSED);
        // As `resume`: not in the pause's own window, even when scheduled before the pause.
        _requireUnpausable(s.pausedAt);
        // LIFECYCLE-4: the cited outcome is the token's own latest one (no item fallback) and
        // was recorded after the pause, so neither an outcome recorded before the pause nor one
        // about the package item can cancel.
        (bytes32 entry, uint64 index) = _ownOutcome(s);
        if (outcomeRef == bytes32(0) || outcomeRef != entry || index < s.outcomeFrom) {
            revert IEnglishAuction.OutcomeNotRecorded(saleId, outcomeRef);
        }
        s.status = IEnglishAuction.AuctionState.CANCELLED;
        // Safe: a live pause is at most MAX_PAUSE (7 days) long, far below 2^24 seconds.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.pausedTotal = uint24(block.timestamp - s.pausedAt);
        s.pausedAt = 0;
        _refundHighBid(saleId, s);
        IMintTarget(s.token).burn(s.tokenId, 1);
        emit IEnglishAuction.AuctionCancelled(saleId, outcomeRef);
    }

    // ----------------------------------------------------------------------------- credits

    /// @notice Sends all of the caller's credits in `currency` to `to`.
    /// @param currency The currency to claim, zero for ETH.
    /// @param to The address that receives the credits; zero reverts.
    /// @return amount The amount sent, in the currency's base units.
    function claim(address currency, address to) external nonReentrant returns (uint256) {
        return _claim(msg.sender, currency, to);
    }

    /// @notice Sends all of `account`'s credits in ERC-20 `currency` to `account` itself.
    ///         Permissionless: a seller split wallet or fee wallet whose ERC-20 payout failed at
    ///         settlement and was credited here (MONEY-1) cannot call `claim`. The funds only ever
    ///         go to `account`; a transfer that fails reverts and keeps the credit. ETH is refused
    ///         (`IRevenueEscrow.InvalidAsset`): ETH credits are bidders' refunds, which only the
    ///         bidder claims, to the address it chooses.
    /// @param account The credited account, which also receives the funds.
    /// @param currency The ERC-20 currency; zero (ETH) reverts.
    /// @return amount The amount sent, in the currency's base units.
    function claimFor(address account, address currency) external nonReentrant returns (uint256) {
        // MONEY-1 credits only ERC-20 payouts; ETH credits are claimed by their account.
        if (currency == CURRENCY_ETH) revert IRevenueEscrow.InvalidAsset(currency);
        return _claim(account, currency, account);
    }

    /// @notice Pays one ERC-20 settlement payout in its own call frame, so that `settle` can
    ///         catch its failure (MONEY-1). Only this contract may call it.
    /// @param currency The sale's ERC-20 currency.
    /// @param wallet The seller or fee wallet; a failed transfer is deposited in the revenue
    ///        escrow for it.
    /// @param amount The payout, in the currency's base units.
    function settlePayout(address currency, address wallet, uint256 amount) external {
        if (msg.sender != address(this)) revert ISaleAdapter.InvalidRecipient(msg.sender);
        RevenuePayment.payERC20(IRevenueEscrow(_escrow), wallet, currency, amount);
    }

    // -------------------------------------------------------------------------- governance

    /// @notice Pauses the adapter: no new opens or purchases, and for the auction no new `start`.
    ///         Bids on live auctions, settlements, claims and closes continue. PAUSER role
    ///         (immediate).
    /// @dev On the auction the pause stops only `start` and `startWithBid`. Auctions already
    ///      started are untouched: bids, settlement, claims, refunds and withdrawals go on,
    ///      because stopping a live auction near its end would distort its outcome. The
    ///      per-auction dispute pause, `pause(saleId, disputeRef)`, is separate.
    function pause() external restricted {
        if (_settings.pausedAt != 0) revert ISaleAdapter.SalePaused();
        _settings.pausedAt = uint40(block.timestamp);
        emit ISaleAdapter.Paused(msg.sender);
    }

    /// @notice Unpauses the adapter. UNPAUSER role. Refused until 48 hours (`Roles.STANDARD`)
    ///         after the pause, so the guardians always have the standard delay to cancel an
    ///         unpause, even one scheduled before the pause.
    /// @dev Reverts with `UnpauseTooEarly` before `pausedAt + Roles.STANDARD` (GOV-5).
    function unpause() external restricted {
        uint256 pausedAt = _settings.pausedAt;
        if (pausedAt == 0) revert ISaleAdapter.NotPaused();
        _requireUnpausable(pausedAt);
        _settings.pausedAt = 0;
        emit ISaleAdapter.Unpaused(msg.sender);
    }

    /// @notice Lists or unlists a token contract for new sales. SUCCESSOR_SETTER role. Running
    ///         sales finish. Listing checks the token like any dependency
    ///         (`Dependency.InvalidDependency`): code, not an EIP-7702 delegated account, and
    ///         ERC-165 support for the surface the adapter calls.
    /// @param token The token contract: an ERC-721 (checked through ERC-165 when listing).
    /// @param listed True to list the token, false to unlist it.
    function setTarget(address token, bool listed) external restricted {
        _setTarget(token, listed);
    }

    /// @notice Sets the federation registry. SUCCESSOR_SETTER role, compare-and-set.
    /// @param expected The registry the caller expects is installed now; a stale value reverts.
    /// @param next The new registry, or zero to remove it; a nonzero one must support
    ///        `IFederationRegistry` through ERC-165.
    /// @dev A nonzero registry must have code, not be a delegated account, and support
    ///      `IFederationRegistry` through ERC-165 (D8); its code hash is pinned (L-6).
    function setFederationRegistry(address expected, address next) external restricted {
        if (_federationRegistry != expected) revert ISaleAdapter.ExpectedValueMismatch();
        if (next != address(0)) Dependency.check(next, type(IFederationRegistry).interfaceId);
        _federationRegistry = next;
        _federationRegistryCodeHash = next == address(0) ? bytes32(0) : next.codehash;
        emit ISaleAdapter.FederationRegistrySet(expected, next);
    }

    /// @notice Sets the auction parameters, within the implementation's bounds: a duration of 1
    ///         hour to 7 days, an anti-snipe window of 1 minute to 1 day and at most the
    ///         duration, and an increment share of 1,000 to 100,000 (1% to 100%).
    ///         PARAMETER_SETTER role, compare-and-set.
    /// @param expected The parameters the caller expects are current; a stale value reverts.
    /// @param next The new parameters, within the bounds above.
    function setConfig(
        IEnglishAuction.AuctionConfig calldata expected,
        IEnglishAuction.AuctionConfig calldata next
    ) external restricted {
        Settings memory c = _settings;
        if (
            c.duration != expected.duration || c.extensionWindow != expected.extensionWindow
                || c.incrementShare != expected.incrementShare
        ) revert ISaleAdapter.ExpectedValueMismatch();
        _setConfig(next);
    }

    /// @notice Sets a currency's opening bid, raising or lowering it up to the implementation's
    ///         ceiling (zero at launch; the first bid is still at least 1). PARAMETER_SETTER role,
    ///         compare-and-set.
    /// @param currency The currency, zero for ETH; it must be active on the asset allowlist.
    /// @param expected The opening bid the caller expects is current; a stale value reverts.
    /// @param next The new opening bid, in the currency's base units.
    /// @dev Moves either way, zero included, within an absolute ceiling of {OPENING_BID_FLOORS}
    ///      increment floors, capped at `type(uint96).max` (the largest bid) so that a bid can
    ///      always meet it. The raise-only rule of ADR 0001 section 13.9 covers gas parameters,
    ///      not prices. Applies to sales that start afterwards. The currency must be active in
    ///      the allowlist.
    function setOpeningBid(address currency, uint256 expected, uint256 next) external restricted {
        uint256 current = _openingBids[currency];
        if (current != expected) revert ISaleAdapter.ExpectedValueMismatch();
        uint256 ceiling =
            Math.min(_allowlist.incrementFloor(currency) * _OPENING_BID_FLOORS, type(uint96).max);
        if (next > ceiling) revert IEnglishAuction.OpeningBidAboveCeiling(next, ceiling);
        _openingBids[currency] = next;
        emit IEnglishAuction.OpeningBidSet(currency, current, next);
    }

    // ------------------------------------------------------------------------------- views

    /// @notice This adapter's `SaleKind` label: a token mints only for an admitted adapter whose
    ///         label equals its terms' kind. A new sale method claims a new label (ADR 0005,
    ///         owner decision 14).
    /// @return `SaleKind.ENGLISH_AUCTION`, `SaleKind.UNIFORM_AUCTION`, rc.1's
    ///         `SaleKind.FIXED_PRICE` or `SaleKind.DUTCH`, or a later adapter's own label.
    function saleKind() external pure returns (bytes32) {
        return SaleKind.ENGLISH_AUCTION;
    }

    /// @inheritdoc IEnglishAuctionClock
    /// @dev Answered here, not through the lens, for contracts that read an auction on their own
    ///      hot paths (the edition auction reads its 1/1 in `open`, `bid`, `settle` and
    ///      `withdrawBid`, which needs the pause start): one cold slot for a sale never paused,
    ///      against the lens's extra account and round trips.
    function auctionClock(uint256 saleId)
        external
        view
        returns (IEnglishAuction.AuctionState state, uint64 endTime, uint64 pausedAt)
    {
        Sale storage s = _sales[saleId];
        state = _state(s);
        if (state == IEnglishAuction.AuctionState.NONE) revert ISaleAdapter.UnknownSale(saleId);
        endTime = s.endTime;
        // Only a dispute pause sets `pausedAt`, and it sets `_PAUSE_USED` with it: an unpaused
        // sale's slot 2 is not read.
        if (s.flags & _PAUSE_USED != 0) {
            pausedAt = s.pausedAt;
            // forge-lint: disable-next-line(block-timestamp)
            if (pausedAt != 0 && block.timestamp > pausedAt + _MAX_PAUSE) {
                // Shown resumed, as `auction` shows it. Truncating as `auction` does: the end
                // fits 32 bits.
                // forge-lint: disable-next-line(unsafe-typecast)
                (endTime, pausedAt) = (uint64(_resumedEnd(s, _MAX_PAUSE)), 0);
            }
        }
    }

    /// @notice Accepts only a token minted into this adapter's custody during a start, so no
    ///         other safe transfer can strand a token here. A plain `transferFrom` runs no hook
    ///         and cannot be refused: a token sent to this adapter that way is stranded, since
    ///         nothing records who sent it (CALLS-5). Never send a token here.
    /// @dev Relies on `start` and `startWithBid` holding the reentrancy guard while they mint;
    ///      any future intake path must hold it too.
    /// @param operator The address that made the transfer; it must be this adapter.
    /// @param from The previous owner; it must be zero (a mint).
    /// @return The `onERC721Received` selector, which accepts the token.
    function onERC721Received(address operator, address from, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (operator != address(this) || from != address(0) || !_reentrancyGuardEntered()) {
            revert IEnglishAuction.InvalidTarget(msg.sender);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Raw storage words, for the lens: `words[i]` is the word at slot `slots[i]`. Every
    ///         word is public state already; the lens decodes them with this contract's layout.
    /// @param slots The storage slots to read.
    /// @return The words, in the order of `slots`.
    function storageWords(bytes32[] calldata slots) external view returns (bytes32[] memory) {
        // The ABI encoding of the words, written from memory offset 0 and returned at once: not
        // memory-safe and need not be, since no Solidity code runs after the `return`.
        assembly {
            let n := slots.length
            mstore(0x00, 0x20)
            mstore(0x20, n)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                mstore(add(0x40, shl(5, i)), sload(calldataload(add(slots.offset, shl(5, i)))))
            }
            return(0x00, add(0x40, shl(5, n)))
        }
    }

    /// @notice Answers every view of `IEnglishAuction` and `ISaleAdapter` this contract does not
    ///         declare (`auction`, `lockedTerms`, `minimumBid`, `pendingDelivery`, `config`,
    ///         `openingBid`, `claimable`, `paused`, `isTarget`, `saleIdOf`, `federationRegistry`,
    ///         `escrow`, `statementLog`, `supportsInterface`), and the getters `MAX_PAUSE`,
    ///         `OPENING_BID_FLOORS`, `PAYOUT_GAS`, `allowlist`, `economicsResolver`, `permit2` and
    ///         `federationRegistryCodeHash`: it sends this call's calldata unchanged to the lens,
    ///         which declares each with the same signature, and returns or reverts with its
    ///         answer, byte for byte. Any other call reverts there. ETH is refused.
    /// @dev A read-only `staticcall` to the fixed, stateless lens this contract pinned; the lens
    ///      reads its caller, this contract. No delegatecall. The views live there because this
    ///      contract's write path alone nearly fills EIP-170.
    fallback() external {
        address target = lens;
        // `target` is the immutable lens and `staticcall` cannot change state, so the answer is
        // exactly the lens's. Calldata and returndata are copied over memory from offset 0,
        // which is not memory-safe and need not be: the frame ends in `return` or `revert` at
        // once, and no Solidity code reads memory again.
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := staticcall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if ok { return(0, returndatasize()) }
            revert(0, returndatasize())
        }
    }

    // ---------------------------------------------------------------------------- internal

    /// @dev The derived sale ID (`IEnglishAuction.saleIdOf`, which the lens answers).
    function _saleIdOf(address token, uint256 tokenId) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, tokenId)));
    }

    /// @dev Whether the token may sell here (`ISaleAdapter.isTarget`, which the lens answers):
    ///      listed, or active in the federation registry whose code hash was pinned.
    function _isTarget(address token) private view returns (bool) {
        if (_listed[token]) return true;
        address registry = _federationRegistry;
        return registry != address(0) && registry.codehash == _federationRegistryCodeHash
            && IFederationRegistry(registry).isActive(token);
    }

    function _start(address token, bytes calldata mintData) private returns (uint256 saleId) {
        Settings memory c = _settings;
        if (c.pausedAt != 0) revert ISaleAdapter.SalePaused();
        bool listed = _listed[token];
        if (!listed && !_isTarget(token)) revert ISaleAdapter.TargetNotAllowed(token);
        (uint256 tokenId, PrimaryTerms memory terms) =
            IMintTarget(token).mint(address(this), 0, 1, mintData);
        if (terms.saleKind != SaleKind.ENGLISH_AUCTION) {
            revert IMintTarget.SaleKindMismatch(SaleKind.ENGLISH_AUCTION, terms.saleKind);
        }
        Terms memory t = _lockTerms(token, tokenId, listed, terms.currency, c);
        // CALLS-1: the escrow refuses to be paid as a wallet, so a work whose seller or fee
        // recipient is the escrow could never settle; it is refused while nothing is at stake.
        // A federated token's own fee recipient is never paid ({_lockTerms} checks the network's).
        if (
            tokenId >> 32 != 0 || terms.seller == address(0) || terms.seller == _escrow
                || (!t.federated
                    && (terms.feeRecipient == _escrow
                        || (terms.feeRecipient == address(0) && terms.feeShare != 0)))
                || terms.creator == address(0) || terms.feeShare > Splits.DENOMINATOR
                || terms.price != 0 || terms.params.length != 0
                || IERC721(token).ownerOf(tokenId) != address(this)
        ) revert ISaleAdapter.InvalidSaleTerms(token, tokenId);
        saleId = _saleIdOf(token, tokenId);
        Sale storage s = _sales[saleId];
        if (s.status != IEnglishAuction.AuctionState.NONE) {
            revert IEnglishAuction.InvalidAuctionState(saleId, s.status);
        }
        uint32 endTime = SafeCast.toUint32(block.timestamp + c.duration);
        s.token = token;
        // Safe: `tokenId >> 32 == 0` was checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.tokenId = uint32(tokenId);
        s.endTime = endTime;
        s.termsId = _termsId(t);
        s.status = IEnglishAuction.AuctionState.ACTIVE;
        emit ISaleAdapter.SaleStarted(
            saleId,
            token,
            tokenId,
            SaleKind.ENGLISH_AUCTION,
            t.currency,
            t.openingBid,
            uint64(block.timestamp),
            endTime
        );
    }

    /// @dev The values a sale locks: `CURRENCY_DEFAULT` resolved once to the product's default
    ///      (6529 Stream for listed tokens, Federated for registry tokens), which must be active,
    ///      the governed parameters, and a federated token's fee from its registry entry, whose
    ///      code hash must match the token's.
    function _lockTerms(
        address token,
        uint256 tokenId,
        bool listed,
        address currency,
        Settings memory c
    ) private view returns (Terms memory t) {
        if (currency == CURRENCY_DEFAULT) {
            currency = _allowlist.defaultCurrency(listed ? PRODUCT_STREAM : PRODUCT_FEDERATED);
        } else if (!_allowlist.isActive(currency)) {
            revert IAssetAllowlist.AssetNotActive(currency);
        }
        t.currency = currency;
        // Safe: `setOpeningBid` caps every opening bid at `type(uint96).max`, the largest bid.
        // forge-lint: disable-next-line(unsafe-typecast)
        t.openingBid = uint96(_openingBids[currency]);
        // Safe: `_setConfig` bounds both by 100,000.
        // forge-lint: disable-next-line(unsafe-typecast)
        t.incrementShare = uint24(c.incrementShare);
        // forge-lint: disable-next-line(unsafe-typecast)
        t.extensionWindow = uint24(c.extensionWindow);
        if (!listed) {
            IFederationRegistry.Entry memory e =
                IFederationRegistry(_federationRegistry).entry(token);
            // MARKET-3: the registry's fee goes to the network's federated recipient, which must
            // be payable when the fee is nonzero.
            address recipient = _federatedFeeRecipient();
            if (
                e.codeHash != token.codehash || e.feeShare > Splits.DENOMINATOR
                    || recipient == _escrow || (recipient == address(0) && e.feeShare != 0)
            ) revert ISaleAdapter.InvalidSaleTerms(token, tokenId);
            t.federated = true;
            t.registryFee = e.feeShare;
        }
    }

    /// @dev The ID of an identical terms record, created the first time it is needed.
    function _termsId(Terms memory t) private returns (uint16 id) {
        bytes32 key = keccak256(abi.encode(t));
        id = _termsIds[key];
        if (id == 0) {
            id = ++_termsCount;
            _termsIds[key] = id;
            _terms[id] = t;
        }
    }

    /// @dev The sale's terms: the locked currency, the token's seller and fee terms, and for a
    ///      federated token the registry fee share, locked at start, paid to the resolver's
    ///      federated network fee recipient, never to a recipient the token reports (MARKET-3).
    ///      `creator` is the artist's active authority the token reports now, zero while it is
    ///      restrained.
    function _lock(Sale storage s, address seller, address feeRecipient, uint32 feeShare)
        private
        view
        returns (LockedTerms memory lt)
    {
        Terms storage t = _terms[s.termsId];
        bool federated = t.federated;
        lt = LockedTerms(
            s.token,
            s.tokenId,
            t.currency,
            0,
            seller,
            federated ? _federatedFeeRecipient() : feeRecipient,
            federated ? t.registryFee : feeShare
        );
        if (lt.feeShare > Splits.DENOMINATOR) {
            revert ISaleAdapter.InvalidSaleTerms(s.token, s.tokenId);
        }
    }

    /// @dev Records the bid, then takes its payment: the whole bid reverts if the payment does
    ///      not arrive. `recipient` is already resolved.
    function _bid(
        uint256 saleId,
        address recipient,
        Payment calldata payment,
        bytes32 witness,
        bool starting
    ) private {
        Sale storage s = _require(saleId, IEnglishAuction.AuctionState.ACTIVE);
        // MARKET-5: a federated contract delisted since the start takes no more bids.
        if (_delisted(s)) revert ISaleAdapter.TargetNotAllowed(s.token);
        Terms storage t = _terms[s.termsId];
        address currency = t.currency;
        if (t.incrementFloor == 0) {
            Terms memory locked = t;
            // A floor at or above the 96-bit bid cap (7.9e28 base units) is stored as the cap:
            // no later bid can then outbid, but an absurd allowlist value does not revert the
            // first bid. The floor is at least 1 (the allowlist refuses zero), so this branch
            // runs once per sale, on its first bid.
            // forge-lint: disable-next-line(unsafe-typecast)
            locked.incrementFloor =
                uint96(Math.min(_allowlist.incrementFloor(currency), type(uint96).max));
            // `t` keeps pointing at the start record: the two differ only in the floor, which
            // the first bid does not use, and rereading the new record would cost a cold slot.
            s.termsId = _termsId(locked);
        } else if (!_allowlist.isActive(currency)) {
            revert IAssetAllowlist.AssetNotActive(currency);
        }
        if (recipient == address(this)) revert ISaleAdapter.InvalidRecipient(recipient);
        uint256 required = _minimumBid(s, t);
        if (payment.amount < required) revert IEnglishAuction.BidTooLow(required, payment.amount);
        address previous = s.bidder;
        if (previous != address(0)) _credit(previous, currency, saleId, s.bid);
        s.bidder = payment.payer;
        if (recipient != payment.payer) {
            if (s.flags & _RECIPIENT_SET == 0) {
                s.flags |= _RECIPIENT_SET;
                s.recipient = recipient;
            } else if (s.recipient != recipient) {
                s.recipient = recipient;
            }
        } else if (s.flags & _RECIPIENT_SET != 0) {
            s.flags &= ~_RECIPIENT_SET;
            s.recipient = address(0);
        }
        s.bid = SafeCast.toUint96(payment.amount);
        uint256 end = s.endTime;
        uint256 window = t.extensionWindow;
        // Anti-snipe compares seconds; validator drift only shifts the window edge.
        // forge-lint: disable-next-line(block-timestamp)
        if (end - block.timestamp < window) {
            end = block.timestamp + window;
            s.endTime = SafeCast.toUint32(end);
        }
        // Safe: `end` fits 32 bits (checked when stored, or already stored).
        emit IEnglishAuction.BidPlaced(
            saleId,
            payment.payer,
            recipient,
            payment.amount,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64(end)
        );
        _collect(currency, payment, witness, starting);
    }

    /// @dev Takes exactly `p.amount` from `p.payer`. ERC-20 moves are checked by exact balance
    ///      delta on both sides. An EIP-2612 permit that fails (for example because it was
    ///      front-run) is ignored, and the pull then needs the allowance it would have set.
    function _collect(address currency, Payment calldata p, bytes32 witness, bool starting)
        private
    {
        if (currency == CURRENCY_ETH) {
            if (p.method != PaymentMethod.DIRECT || p.payer != msg.sender || msg.value != p.amount)
            {
                revert ISaleAdapter.InvalidPayment();
            }
            return;
        }
        if (msg.value != 0) revert ISaleAdapter.InvalidPayment();
        // As in the fixed-price and Dutch adapters: an expired permit never pays, even where an
        // allowance would.
        // forge-lint: disable-next-line(block-timestamp)
        if (p.method != PaymentMethod.DIRECT && block.timestamp > p.deadline) {
            revert ISaleAdapter.PaymentExpired(p.deadline);
        }
        if (p.method == PaymentMethod.PERMIT2) {
            if (_permit2 == address(0)) revert ISaleAdapter.InvalidPayment();
            uint256 held = TokenTransfer.balanceOf(currency, address(this));
            uint256 payerHeld = TokenTransfer.balanceOf(currency, p.payer);
            ISignatureTransfer(_permit2)
                .permitWitnessTransferFrom(
                    ISignatureTransfer.PermitTransferFrom(
                        ISignatureTransfer.TokenPermissions(currency, p.amount), p.nonce, p.deadline
                    ),
                    ISignatureTransfer.SignatureTransferDetails(address(this), p.amount),
                    p.payer,
                    witness,
                    starting ? Typehashes.START_BID_WITNESS_TYPE : Typehashes.BID_WITNESS_TYPE,
                    p.signature
                );
            if (
                TokenTransfer.balanceOf(currency, address(this)) != held + p.amount
                    || payerHeld < p.amount
                    || TokenTransfer.balanceOf(currency, p.payer) != payerHeld - p.amount
            ) revert TokenTransfer.TokenBalanceMismatch(currency);
            return;
        }
        if (p.payer != msg.sender) revert ISaleAdapter.InvalidPayment();
        if (p.method == PaymentMethod.PERMIT) {
            if (p.signature.length != 65) revert ISaleAdapter.InvalidPayment();
            try IERC20Permit(currency)
                .permit(
                    p.payer,
                    address(this),
                    p.amount,
                    p.deadline,
                    uint8(p.signature[64]),
                    bytes32(p.signature[0:32]),
                    bytes32(p.signature[32:64])
                ) { }
                catch { }
        }
        TokenTransfer.pullExact(currency, p.payer, p.amount);
    }

    /// @dev D12: the first bid is at least `max(openingBid, 1 wei)`; later bids add
    ///      `max(incrementShare of the high bid, rounded up; the increment floor locked by the
    ///      first bid)`. With no bidder after a withdrawal, the withdrawn bid is a reserve: a bid
    ///      must reach it (LIFECYCLE-1).
    function _minimumBid(Sale storage s, Terms storage t) private view returns (uint256) {
        if (s.bidder == address(0)) return Math.max(Math.max(t.openingBid, s.bid), 1);
        uint256 high = s.bid;
        // Rounded up, exactly: the high bid fits 96 bits and the share 17.
        uint256 step = (high * t.incrementShare + Splits.DENOMINATOR - 1) / Splits.DENOMINATOR;
        return high + Math.max(step, t.incrementFloor);
    }

    /// @dev Pays nothing for a zero amount, so a zero-fee configuration may name no fee
    ///      recipient (`RevenuePayment` rejects a zero wallet before it looks at the amount).
    ///      MONEY-1: an ERC-20 payout runs in its own frame ({settlePayout}); if it fails for
    ///      any reason (the token changed behaviour, or blocks this adapter so even the escrow
    ///      route fails), the amount is credited to the wallet here, and anyone may later pay it
    ///      out with `claimFor`. Delivery never waits on a payout. ETH payouts cannot fail but
    ///      by gas, which reverts.
    function _pay(address currency, address wallet, uint256 amount, uint256 saleId) private {
        if (amount == 0) return;
        if (currency == CURRENCY_ETH) {
            RevenuePayment.payETH(IRevenueEscrow(_escrow), wallet, amount, _PAYOUT_GAS);
            return;
        }
        // The frame gets its gas in full, so a caller cannot force the credit route.
        if (!BoundedCall.hasSufficientGas(gasleft(), _ERC20_PAYOUT_GAS, DELIVERY_RESERVE)) {
            revert RevenuePayment.PaymentInsufficientGas(_ERC20_PAYOUT_GAS);
        }
        try this.settlePayout{ gas: _ERC20_PAYOUT_GAS }(currency, wallet, amount) { }
        catch {
            _credit(wallet, currency, saleId, amount);
        }
    }

    /// @dev Sends all of `account`'s credits in `currency` to `to`.
    function _claim(address account, address currency, address to)
        private
        returns (uint256 amount)
    {
        if (to == address(0)) revert ISaleAdapter.InvalidRecipient(to);
        amount = _credits[account][currency];
        if (amount == 0) revert ISaleAdapter.NothingToClaim(account, currency);
        _credits[account][currency] = 0;
        emit ISaleAdapter.Claimed(account, currency, to, amount);
        if (currency != CURRENCY_ETH) {
            TokenTransfer.transferExact(currency, to, amount);
        } else if (!TokenTransfer.sendETH(to, amount, gasleft())) {
            revert ISaleAdapter.ClaimFailed(to);
        }
    }

    /// @dev Gives the token's `safeTransferFrom` to `s.recipient` exactly {DELIVERY_GAS} and
    ///      copies no return data. The token counts as delivered once it has left custody: a
    ///      recipient that rejects it, runs out of gas, or hands it back leaves it here as a
    ///      pending claim instead.
    function _deliver(uint256 saleId, Sale storage s) private {
        (address token, uint256 tokenId, address to) = (s.token, s.tokenId, _recipientOf(s));
        if (!BoundedCall.hasSufficientGas(gasleft(), DELIVERY_GAS, DELIVERY_RESERVE)) {
            revert IEnglishAuction.DeliveryInsufficientGas();
        }
        bytes memory data = abi.encodeWithSelector(_SAFE_TRANSFER_FROM, address(this), to, tokenId);
        uint256 gasLimit = DELIVERY_GAS;
        assembly ("memory-safe") {
            pop(call(gasLimit, token, 0, add(data, 0x20), mload(data), 0, 0))
        }
        if (IERC721(token).ownerOf(tokenId) == address(this)) {
            s.flags |= _DELIVERY_PENDING;
            emit IEnglishAuction.DeliveryPending(saleId, to);
        }
    }

    /// @dev Reports the outcome to the token (`IMintTarget.settlePrimary`, owner decision 17) and
    ///      returns the terms to pay by. An unsold work's recipient is recorded: where the token
    ///      moved it out of custody itself (`taken`; 6529 Stream's museum), read with `ownerOf`
    ///      rather than trusted from the reported `holder` (the rc.2 review's CALLS I-2), else,
    ///      for a work still in custody, the creator the token reports now (`primaryTerms`),
    ///      which must not be zero (`InvalidRecipient`, while a recovery override is pending).
    function _settleWithToken(Sale storage s, address bidder, uint256 price, bool frozenOut)
        private
        returns (LockedTerms memory lt, bool taken)
    {
        PrimaryOutcome outcome = bidder != address(0)
            ? PrimaryOutcome.SOLD
            : frozenOut ? PrimaryOutcome.FROZEN_OUT : PrimaryOutcome.UNBID;
        PrimarySettlement memory p = IMintTarget(s.token)
            .settlePrimary(s.tokenId, outcome, bidder, _terms[s.termsId].currency, price);
        lt = _lock(s, p.seller, p.feeRecipient, p.feeShare);
        if (bidder == address(0)) {
            address owner = IERC721(s.token).ownerOf(s.tokenId);
            taken = owner != address(this);
            address to = taken ? owner : _unbidClaimant(s);
            if (to == address(0)) revert ISaleAdapter.InvalidRecipient(to);
            s.recipient = to;
            s.flags |= _RECIPIENT_SET;
        }
    }

    /// @dev Emitted from its own frame to stay within the legacy code generator's stack. The
    ///      price is zero when no bid stands, so the fee is too.
    function _emitSettled(
        uint256 saleId,
        Sale storage s,
        LockedTerms memory lt,
        uint256 price,
        uint256 fee
    ) private {
        emit ISaleAdapter.SaleSettled(
            saleId,
            lt.token,
            lt.id,
            s.bidder,
            _recipientOf(s),
            1,
            lt.currency,
            price,
            lt.seller,
            price - fee,
            lt.feeRecipient,
            fee
        );
    }

    function _refundHighBid(uint256 saleId, Sale storage s) private {
        address bidder = s.bidder;
        if (bidder == address(0)) return;
        _credit(bidder, _terms[s.termsId].currency, saleId, s.bid);
        s.bidder = address(0);
        if (s.flags & _RECIPIENT_SET != 0) {
            s.flags &= ~_RECIPIENT_SET;
            s.recipient = address(0);
        }
        // `s.bid` stays as the reserve the next bid must reach (LIFECYCLE-1).
    }

    function _credit(address account, address currency, uint256 saleId, uint256 amount) private {
        _credits[account][currency] += amount;
        emit ISaleAdapter.Credited(account, currency, saleId, amount);
    }

    /// @dev MARKET-2: a currency freeze (deprecation) stops the auction, not just its bids. While
    ///      frozen, nothing settles, sold or unsold (a standing bidder may withdraw), until the
    ///      currency has been deprecated for {_FREEZE_EXIT}: then anyone may end the sale, the
    ///      standing bid is credited back and the work goes where an unbid work goes (the museum
    ///      for 6529 Stream, else the artist; owner decision 10). If the currency came back in the
    ///      auction's last window or after its end, the first settle reopens the auction instead,
    ///      for {_reopening}, so the bidders the freeze shut out can bid.
    function _reopenedAfterFreeze(uint256 saleId, Sale storage s)
        private
        returns (bool reopened, bool frozenOut)
    {
        (bool active, uint256 since, address currency) = _currencyClock(s);
        if (!active) {
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < since + _FREEZE_EXIT) {
                revert IAssetAllowlist.AssetNotActive(currency);
            }
            _refundHighBid(saleId, s);
            return (false, true);
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (since + _terms[s.termsId].extensionWindow <= s.endTime) return (false, false);
        uint32 end = SafeCast.toUint32(block.timestamp + _reopening(s));
        s.endTime = end;
        emit IEnglishAuction.AuctionResumed(saleId, end);
        return (true, false);
    }

    /// @dev Whether the sale's locked currency is active on the allowlist, since when its status
    ///      last changed, and the currency.
    function _currencyClock(Sale storage s)
        private
        view
        returns (bool active, uint256 since, address currency)
    {
        currency = _terms[s.termsId].currency;
        IAssetAllowlist.Status status;
        (status, since,) = _allowlist.statusClock(currency);
        active = status == IAssetAllowlist.Status.Active;
    }

    /// @dev Whether the sale is of a federated contract the registry no longer serves (ADR 0001
    ///      section 16: a delisted contract cannot sell through the network's adapters).
    function _delisted(Sale storage s) private view returns (bool) {
        return _terms[s.termsId].federated && !_isTarget(s.token);
    }

    /// @dev The network fee recipient of federated sales (MARKET-3).
    function _federatedFeeRecipient() private view returns (address) {
        return _economicsResolver.networkFeeRecipient(PRODUCT_FEDERATED);
    }

    /// @dev L-5: who besides the recorded recipient may claim an unbid work's pending delivery:
    ///      the artist, as the token reports it now. Never a 6529 Stream work: Stream moves an
    ///      unsold work to the museum itself, so none is ever pending (D140, ADR 0005).
    function _unbidClaimant(Sale storage s) private view returns (address) {
        return IMintTarget(s.token).primaryTerms(s.tokenId, "").creator;
    }

    /// @dev The token's own latest dispute outcome in the statement log, and its position in
    ///      the token's chain.
    function _ownOutcome(Sale storage s) private view returns (bytes32 entry, uint64 index) {
        (entry, index) = IStatementLog(_statementLog).disputeOutcomeOf(s.token, s.tokenId);
    }

    /// @dev Loads a sale after writing down an expired pause, and requires the `wanted` state.
    function _require(uint256 saleId, IEnglishAuction.AuctionState wanted)
        private
        returns (Sale storage s)
    {
        s = _sales[saleId];
        if (s.flags & _PAUSE_USED != 0) {
            uint256 pausedAt = s.pausedAt;
            // The pause clock is in seconds; a validator moves it by seconds, not days.
            // forge-lint: disable-next-line(block-timestamp)
            if (pausedAt != 0 && block.timestamp > pausedAt + _MAX_PAUSE) {
                _endPause(saleId, s, _MAX_PAUSE);
            }
        }
        IEnglishAuction.AuctionState state = _state(s);
        if (state == IEnglishAuction.AuctionState.NONE) revert ISaleAdapter.UnknownSale(saleId);
        if (state != wanted) revert IEnglishAuction.InvalidAuctionState(saleId, state);
    }

    function _endPause(uint256 saleId, Sale storage s, uint256 length) private {
        uint32 end = SafeCast.toUint32(_resumedEnd(s, length));
        s.endTime = end;
        // Safe: `length` is at most MAX_PAUSE (7 days), far below 2^24 seconds.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.pausedTotal = uint24(length);
        s.pausedAt = 0;
        emit IEnglishAuction.AuctionResumed(saleId, end);
    }

    /// @dev The derived state: PAUSED while a pause is live (through `pausedAt + MAX_PAUSE`
    ///      inclusive), ENDED once the end has passed.
    function _state(Sale storage s) private view returns (IEnglishAuction.AuctionState) {
        IEnglishAuction.AuctionState status = s.status;
        if (status != IEnglishAuction.AuctionState.ACTIVE) return status;
        uint256 end = s.endTime;
        uint256 pausedAt = s.flags & _PAUSE_USED == 0 ? 0 : s.pausedAt;
        if (pausedAt != 0) {
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp <= pausedAt + _MAX_PAUSE) {
                return IEnglishAuction.AuctionState.PAUSED;
            }
            end = _resumedEnd(s, _MAX_PAUSE);
        }
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp < end
            ? IEnglishAuction.AuctionState.ACTIVE
            : IEnglishAuction.AuctionState.ENDED;
    }

    /// @dev The end after a pause of `length` seconds: the remaining time at the pause, but at
    ///      least {_reopening} from the resumption (L-2, LIFECYCLE-1).
    function _resumedEnd(Sale storage s, uint256 length) private view returns (uint256) {
        uint256 pausedAt = s.pausedAt;
        return pausedAt + length + Math.max(s.endTime - pausedAt, _reopening(s));
    }

    /// @dev The least time a halted auction gets back when it resumes after a dispute pause or a
    ///      currency freeze: the governed duration, or the sale's anti-snipe window if longer
    ///      (LIFECYCLE-1, MARKET-2), so the bidders the halt shut out, or refunded, can re-form
    ///      the market.
    function _reopening(Sale storage s) private view returns (uint256) {
        return Math.max(_settings.duration, _terms[s.termsId].extensionWindow);
    }

    /// @dev GOV-5: a pause that began at `pausedAt` ends no earlier than `Roles.STANDARD` later.
    function _requireUnpausable(uint256 pausedAt) private view {
        uint256 allowedAt = pausedAt + Roles.STANDARD;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < allowedAt) revert ISaleAdapter.UnpauseTooEarly(allowedAt);
    }

    /// @dev The token's recipient: the stored one, or the bidder when none is stored.
    function _recipientOf(Sale storage s) private view returns (address) {
        return s.flags & _RECIPIENT_SET != 0 ? s.recipient : s.bidder;
    }

    function _setTarget(address token, bool listed) private {
        if (listed) Dependency.check(token, type(IERC721).interfaceId);
        _listed[token] = listed;
        emit ISaleAdapter.TargetSet(token, listed);
    }

    function _setConfig(IEnglishAuction.AuctionConfig memory next) private {
        if (
            next.duration < MIN_DURATION || next.duration > MAX_DURATION
                || next.extensionWindow < MIN_EXTENSION_WINDOW
                || next.extensionWindow > MAX_EXTENSION_WINDOW
                || next.extensionWindow > next.duration || next.incrementShare < MIN_INCREMENT_SHARE
                || next.incrementShare > Splits.DENOMINATOR
        ) revert IEnglishAuction.InvalidConfig();
        emit IEnglishAuction.ConfigSet(_currentConfig(), next);
        Settings storage st = _settings;
        (st.duration, st.extensionWindow, st.incrementShare) =
        (next.duration, next.extensionWindow, next.incrementShare);
    }

    function _currentConfig() private view returns (IEnglishAuction.AuctionConfig memory) {
        Settings storage st = _settings;
        return IEnglishAuction.AuctionConfig(st.duration, st.extensionWindow, st.incrementShare);
    }
}
