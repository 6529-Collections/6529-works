// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
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
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
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
    PrimaryTerms,
    SaleKind
} from "../interfaces/types/SaleTypes.sol";
import { Typehashes } from "../interfaces/types/Typehashes.sol";
import { Roles } from "../governance/Roles.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { DelegatedEOA } from "../libraries/DelegatedEOA.sol";

/// @title EnglishAuction
/// @notice The shared English auction: 6529 Stream's only primary sale (ADR 0001 sections 5 and
///         12). See {IEnglishAuction} for the behaviour; this contract adds the storage layout and
///         the bounds.
/// @dev Start gas (PR #10 review, D3 and E2). A start in steady state writes one storage word:
///      the token, its ID (at most 32 bits), the end time (32-bit seconds, so starts stop in
///      2106), the sale's state, and a 16-bit reference to a shared "terms" record. A terms record
///      holds the values every sale locks at start (currency, opening bid, increment share,
///      anti-snipe window, and a federated token's registry fee) and is written once per distinct
///      combination. The currency's increment floor is locked by the first bid (E2), which only
///      later bids need. Seller, fee recipient, fee share and the no-bid recipient are read back from
///      the token (`IMintTarget.primaryTerms`) at settlement, as `LockedTerms`. A VRF item's seed
///      is checked by the token's `mint` (`IEntropyModule.isDelivered(itemHash)`), since the mint
///      data is opaque here. A pause is recorded once (`pausedAt`) and is live through
///      `pausedAt + MAX_PAUSE` inclusive, so an upheld `cancel` scheduled with the 48-hour delay
///      exactly at day 5 still lands. After that it ends by itself: views and every mutating
///      entry point treat it as resumed with a {MAX_PAUSE} pause, and the first mutating call
///      writes the resumption down. Every bid checks that the locked currency is still active in the allowlist
///      (deprecation is an emergency stop for running auctions); settlement, refunds and claims
///      never read the allowlist.
contract EnglishAuction is
    IEnglishAuction,
    IERC721Receiver,
    AccessManaged,
    ReentrancyGuardTransient
{
    /// @notice The longest a dispute pause lasts; one pause per auction (ADR 0001 section 12).
    uint64 public constant MAX_PAUSE = 7 days;
    /// @notice Bounds of the governed duration.
    uint32 public constant MIN_DURATION = 1 hours;
    /// @notice Bounds of the governed duration.
    uint32 public constant MAX_DURATION = 7 days;
    /// @notice Bounds of the governed anti-snipe window.
    uint32 public constant MIN_EXTENSION_WINDOW = 1 minutes;
    /// @notice Bounds of the governed anti-snipe window.
    uint32 public constant MAX_EXTENSION_WINDOW = 1 days;
    /// @notice The smallest governed relative increment (1%, out of 100,000).
    uint32 public constant MIN_INCREMENT_SHARE = 1_000;
    /// @notice An opening bid is at most this many increment floors of its currency (1 ETH for
    ///         the 0.001 ETH floor), and at most `type(uint96).max`, the largest bid: the
    ///         absolute ceiling of the governed opening bid.
    uint256 public constant OPENING_BID_FLOORS = 1_000;
    /// @notice Gas forwarded to a seller or fee wallet on an ETH payout; a refusal is escrowed.
    uint256 public constant PAYOUT_GAS = 100_000;
    /// @notice Gas forwarded to the token's `safeTransferFrom` when settling; a failure leaves a
    ///         pending claim.
    uint256 public constant DELIVERY_GAS = 300_000;
    /// @notice Gas the settlement needs after the delivery attempt returns.
    uint256 public constant DELIVERY_RESERVE = 50_000;

    bytes4 private constant _SAFE_TRANSFER_FROM = 0x42842e0e;
    uint8 private constant _PAUSE_USED = 1;
    uint8 private constant _DELIVERY_PENDING = 2;
    /// @dev Slot 2 holds a recipient. With this flag and `_PAUSE_USED` clear, a bid never reads
    ///      slot 2, which a first bid for oneself would otherwise read cold.
    uint8 private constant _RECIPIENT_SET = 4;

    /// @dev One auction in three slots. Slot 0 is written at start (and its terms reference
    ///      and flags again by the first bid, which locks the increment floor). Slot 1 holds the
    ///      high bidder and the high bid (at most `uint96`). Slot 2 holds the recipient only when
    ///      it differs from the bidder (`_RECIPIENT_SET`), the artist after a no-bid settlement,
    ///      and the dispute pause (`_PAUSE_USED`). A first bid for oneself writes one fresh slot
    ///      and does not read slot 2.
    struct Sale {
        address token;
        uint32 tokenId;
        uint32 endTime;
        uint16 termsId;
        AuctionState status;
        uint8 flags;
        address bidder;
        uint96 bid;
        address recipient;
        uint32 pausedAt;
        uint24 pausedTotal;
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

    /// @inheritdoc IEnglishAuction
    address public immutable escrow;
    /// @inheritdoc IEnglishAuction
    address public immutable statementLog;
    /// @notice The economics lane's asset allowlist: currencies, defaults and increment floors.
    IAssetAllowlist public immutable allowlist;
    /// @notice The canonical Permit2, or zero when PERMIT2 payments are disabled.
    address public immutable permit2;

    /// @inheritdoc ISaleAdapter
    address public federationRegistry;
    /// @notice The code hash pinned when the federation registry was installed; a registry whose
    ///         code no longer matches serves no token.
    bytes32 public federationRegistryCodeHash;
    Settings private _settings;
    uint16 private _termsCount;
    mapping(address token => bool) private _listed;
    mapping(bytes32 key => uint16) private _termsIds;
    mapping(uint16 termsId => Terms) private _terms;
    mapping(uint256 saleId => Sale) private _sales;
    mapping(address currency => uint256) private _openingBids;
    mapping(address account => mapping(address currency => uint256)) private _credits;

    /// @notice A dependency has no code, is a delegated account, or lacks its ERC-165 interface.
    error InvalidDependency(address dependency);
    /// @notice A configuration is outside the bounds above.
    error InvalidConfig();
    /// @notice The token returned an unusable ID, terms (including the revenue escrow as seller
    ///         or fee recipient) or custody for the minted work.
    error InvalidTerms(address token, uint256 tokenId);
    /// @notice The token contract cannot be listed (no code, delegated, or not ERC-721).
    error InvalidTarget(address token);
    /// @notice The caller is not the high bidder.
    error NotHighBidder(address caller);
    /// @notice The opening bid is above its absolute ceiling.
    error OpeningBidAboveCeiling(uint256 next, uint256 ceiling);
    /// @notice The caller cannot forward {DELIVERY_GAS} in full.
    error DeliveryInsufficientGas();

    /// @param authority The AccessManager governing this adapter.
    /// @param escrow_ The revenue escrow for refused payouts.
    /// @param allowlist_ The asset allowlist read at start and on every bid.
    /// @param statementLog_ The statement log `cancel` reads.
    /// @param permit2_ The canonical Permit2, or zero to disable PERMIT2 payments.
    /// @param config_ The initial auction parameters.
    /// @param targets Token contracts listed at genesis.
    constructor(
        address authority,
        address escrow_,
        IAssetAllowlist allowlist_,
        address statementLog_,
        address permit2_,
        AuctionConfig memory config_,
        address[] memory targets
    ) AccessManaged(authority) {
        _requireContract(escrow_);
        _requireContract(address(allowlist_));
        _requireContract(statementLog_);
        if (permit2_ != address(0)) _requireContract(permit2_);
        escrow = escrow_;
        allowlist = allowlist_;
        statementLog = statementLog_;
        permit2 = permit2_;
        _setConfig(config_);
        for (uint256 i; i < targets.length; ++i) {
            _setTarget(targets[i], true);
        }
    }

    // ------------------------------------------------------------------------------- start

    /// @inheritdoc IEnglishAuction
    /// @dev Reverts with `SalePaused` while the emergency pause is on.
    function start(address token, bytes calldata mintData)
        external
        nonReentrant
        returns (uint256 saleId)
    {
        saleId = _start(token, mintData);
    }

    /// @inheritdoc IEnglishAuction
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

    /// @inheritdoc IEnglishAuction
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

    /// @inheritdoc IEnglishAuction
    function withdrawBid(uint256 saleId) external nonReentrant {
        Sale storage s = _require(saleId, AuctionState.PAUSED);
        address bidder = s.bidder;
        if (bidder == address(0) || msg.sender != bidder) revert NotHighBidder(msg.sender);
        uint256 amount = s.bid;
        _refundHighBid(saleId, s);
        emit BidWithdrawn(saleId, bidder, amount);
    }

    /// @inheritdoc IEnglishAuction
    function minimumBid(uint256 saleId) external view returns (uint256) {
        Sale storage s = _sales[saleId];
        if (s.status == AuctionState.NONE) revert UnknownSale(saleId);
        return _minimumBid(s, _terms[s.termsId]);
    }

    // -------------------------------------------------------------------------- settlement

    /// @inheritdoc IEnglishAuction
    /// @dev Reads the seller, the fee terms and the artist's active authority back from the
    ///      token. With no bids the artist is recorded as the recipient. Marks the token's primary
    ///      sale settled (`IMintTarget.markPrimarySettled`, E11) while the token is still in custody,
    ///      whether or not the delivery then succeeds, so a winner who never claims cannot hold
    ///      up the edition. With no bids and no active artist (the token reports a zero creator
    ///      while a recovery override is pending) it reverts with `InvalidRecipient(address(0))`
    ///      and moves nothing, the token staying in custody; anyone may retry once the override
    ///      executes, is vetoed or voided, or lapses.
    function settle(uint256 saleId) external nonReentrant {
        Sale storage s = _require(saleId, AuctionState.ENDED);
        s.status = AuctionState.SETTLED;
        (LockedTerms memory lt, address creator) = _lockedTerms(s);
        // With no bidder, `s.bid` is at most a withdrawn bid's reserve: nothing is paid.
        uint256 price;
        if (s.bidder == address(0)) {
            if (creator == address(0)) revert InvalidRecipient(creator);
            s.recipient = creator;
            s.flags |= _RECIPIENT_SET;
        } else {
            price = s.bid;
        }
        // Exact: a bid fits 96 bits and the share 17, so the product cannot overflow.
        uint256 fee = price * lt.feeShare / Splits.DENOMINATOR;
        _pay(lt.currency, lt.seller, price - fee);
        _pay(lt.currency, lt.feeRecipient, fee);
        IMintTarget(lt.token).markPrimarySettled(lt.id);
        _deliver(saleId, s);
        _emitSettled(saleId, s, lt, price, fee);
    }

    /// @inheritdoc IEnglishAuction
    /// @dev The pending recipient or the winning bidder (the payer of the high bid) may claim, to
    ///      any address except zero and this adapter, so a recipient contract that cannot make the
    ///      call does not strand the token. With no bids the artist may, as the authority
    ///      recorded at settlement or the active one the token reports (L-5). If neither the
    ///      recipient nor the winner can make the call, the token stays in custody: that is the
    ///      winner's choice of recipient.
    function claimDelivery(uint256 saleId, address to) external nonReentrant {
        Sale storage s = _sales[saleId];
        address pending = _recipientOf(s);
        if (s.flags & _DELIVERY_PENDING == 0) revert NoPendingDelivery(saleId);
        if (msg.sender != pending && msg.sender != s.bidder) {
            if (
                s.bidder != address(0)
                    || msg.sender != IMintTarget(s.token).primaryTerms(s.tokenId, "").creator
            ) revert NoPendingDelivery(saleId);
        }
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        s.flags &= ~_DELIVERY_PENDING;
        IERC721(s.token).safeTransferFrom(address(this), to, s.tokenId);
        emit DeliveryClaimed(saleId, pending, to);
    }

    /// @inheritdoc IEnglishAuction
    function pendingDelivery(uint256 saleId) external view returns (address) {
        Sale storage s = _sales[saleId];
        return s.flags & _DELIVERY_PENDING != 0 ? _recipientOf(s) : address(0);
    }

    // ---------------------------------------------------------------------------- disputes

    /// @inheritdoc IEnglishAuction
    function pause(uint256 saleId, bytes32 disputeRef) external restricted nonReentrant {
        Sale storage s = _require(saleId, AuctionState.ACTIVE);
        if (s.flags & _PAUSE_USED != 0) revert PauseExhausted(saleId);
        s.flags |= _PAUSE_USED;
        s.pausedAt = SafeCast.toUint32(block.timestamp);
        emit AuctionPaused(saleId, disputeRef);
    }

    /// @inheritdoc IEnglishAuction
    /// @dev Reverts with `UnpauseTooEarly` before `pausedAt + Roles.STANDARD` (GOV-5).
    function resume(uint256 saleId) external restricted nonReentrant {
        Sale storage s = _require(saleId, AuctionState.PAUSED);
        uint256 pausedAt = s.pausedAt;
        _requireUnpausable(pausedAt);
        _endPause(saleId, s, block.timestamp - pausedAt);
    }

    /// @inheritdoc IEnglishAuction
    /// @dev The statement log does not record on-chain whether an outcome upheld or rejected
    ///      the dispute. The decision to cancel is the governed 48-hour action itself
    ///      (PARAMETER_SETTER, cancellable by the guardian during its delay); the recorded
    ///      DISPUTE_OUTCOME entry is the public record it must cite, so no auction is cancelled
    ///      without one. Accepted through `pausedAt + MAX_PAUSE` inclusive.
    function cancel(uint256 saleId, bytes32 outcomeRef) external restricted nonReentrant {
        Sale storage s = _require(saleId, AuctionState.PAUSED);
        (address token, uint256 tokenId) = (s.token, s.tokenId);
        if (
            outcomeRef == bytes32(0)
                || outcomeRef != IStatementLog(statementLog).latestDisputeOutcome(token, tokenId)
        ) revert OutcomeNotRecorded(saleId, outcomeRef);
        s.status = AuctionState.CANCELLED;
        s.pausedTotal = SafeCast.toUint24(block.timestamp - s.pausedAt);
        s.pausedAt = 0;
        _refundHighBid(saleId, s);
        IMintTarget(token).burn(tokenId, 1);
        emit AuctionCancelled(saleId, outcomeRef);
    }

    // ----------------------------------------------------------------------------- credits

    /// @inheritdoc ISaleAdapter
    function claim(address currency, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert InvalidRecipient(to);
        amount = _credits[msg.sender][currency];
        if (amount == 0) revert NothingToClaim(msg.sender, currency);
        _credits[msg.sender][currency] = 0;
        emit Claimed(msg.sender, currency, to, amount);
        if (currency != CURRENCY_ETH) {
            TokenTransfer.transferExact(currency, to, amount);
        } else if (!TokenTransfer.sendETH(to, amount, gasleft())) {
            revert ClaimFailed(to);
        }
    }

    /// @inheritdoc ISaleAdapter
    function claimable(address account, address currency) external view returns (uint256) {
        return _credits[account][currency];
    }

    // -------------------------------------------------------------------------- governance

    /// @inheritdoc ISaleAdapter
    /// @dev On the auction the pause stops only `start` and `startWithBid`. Auctions already
    ///      started are untouched: bids, settlement, claims, refunds and withdrawals go on,
    ///      because stopping a live auction near its end would distort its outcome. The
    ///      per-auction dispute pause, `pause(saleId, disputeRef)`, is separate.
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
        _requireUnpausable(pausedAt);
        _settings.pausedAt = 0;
        emit Unpaused(msg.sender);
    }

    /// @inheritdoc ISaleAdapter
    function paused() external view returns (bool) {
        return _settings.pausedAt != 0;
    }

    /// @inheritdoc ISaleAdapter
    function setTarget(address token, bool listed) external restricted {
        _setTarget(token, listed);
    }

    /// @inheritdoc ISaleAdapter
    /// @dev A nonzero registry must have code, not be a delegated account, and support
    ///      `IFederationRegistry` through ERC-165 (D8); its code hash is pinned (L-6).
    function setFederationRegistry(address expected, address next) external restricted {
        if (federationRegistry != expected) revert ExpectedValueMismatch();
        if (next != address(0)) {
            _requireContract(next);
            if (!ERC165Checker.supportsInterface(next, type(IFederationRegistry).interfaceId)) {
                revert InvalidDependency(next);
            }
        }
        federationRegistry = next;
        federationRegistryCodeHash = next == address(0) ? bytes32(0) : next.codehash;
        emit FederationRegistrySet(expected, next);
    }

    /// @inheritdoc IEnglishAuction
    function setConfig(AuctionConfig calldata expected, AuctionConfig calldata next)
        external
        restricted
    {
        Settings memory c = _settings;
        if (
            c.duration != expected.duration || c.extensionWindow != expected.extensionWindow
                || c.incrementShare != expected.incrementShare
        ) revert ExpectedValueMismatch();
        _setConfig(next);
    }

    /// @inheritdoc IEnglishAuction
    /// @dev Moves either way, zero included, within an absolute ceiling of {OPENING_BID_FLOORS}
    ///      increment floors, capped at `type(uint96).max` (the largest bid) so that a bid can
    ///      always meet it. The raise-only rule of ADR 0001 section 13.9 covers gas parameters,
    ///      not prices. Applies to sales that start afterwards. The currency must be active in
    ///      the allowlist.
    function setOpeningBid(address currency, uint256 expected, uint256 next) external restricted {
        uint256 current = _openingBids[currency];
        if (current != expected) revert ExpectedValueMismatch();
        uint256 ceiling =
            Math.min(allowlist.incrementFloor(currency) * OPENING_BID_FLOORS, type(uint96).max);
        if (next > ceiling) revert OpeningBidAboveCeiling(next, ceiling);
        _openingBids[currency] = next;
        emit OpeningBidSet(currency, current, next);
    }

    // ------------------------------------------------------------------------------- views

    /// @inheritdoc IEnglishAuction
    function saleIdOf(address token, uint256 tokenId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, tokenId)));
    }

    /// @inheritdoc IEnglishAuction
    function auction(uint256 saleId) external view returns (Auction memory a) {
        Sale storage s = _sales[saleId];
        a.state = _state(s);
        if (a.state == AuctionState.NONE) revert UnknownSale(saleId);
        Terms storage t = _terms[s.termsId];
        a.token = s.token;
        a.tokenId = s.tokenId;
        a.currency = t.currency;
        a.incrementFloor = t.incrementFloor;
        a.bidder = s.bidder;
        a.recipient = _recipientOf(s);
        a.bid = s.bid;
        a.endTime = s.endTime;
        a.pausedAt = s.pausedAt;
        a.pausedTotal = s.pausedTotal;
        // The pause clock is in seconds; a validator moves it by seconds, not days.
        // forge-lint: disable-next-line(block-timestamp)
        if (a.pausedAt != 0 && block.timestamp > a.pausedAt + MAX_PAUSE) {
            a.endTime = uint64(_resumedEnd(s, MAX_PAUSE));
            a.pausedAt = 0;
            a.pausedTotal = MAX_PAUSE;
        }
    }

    /// @inheritdoc IEnglishAuction
    /// @dev `price` is zero, as for every English auction; a federated token's fee share is its
    ///      registry entry's, locked at start.
    function lockedTerms(uint256 saleId) external view returns (LockedTerms memory lt) {
        Sale storage s = _sales[saleId];
        if (s.status == AuctionState.NONE) revert UnknownSale(saleId);
        (lt,) = _lockedTerms(s);
    }

    /// @inheritdoc IEnglishAuction
    function config() external view returns (AuctionConfig memory) {
        return _currentConfig();
    }

    /// @inheritdoc IEnglishAuction
    function openingBid(address currency) external view returns (uint256) {
        return _openingBids[currency];
    }

    /// @inheritdoc ISaleAdapter
    function saleKind() external pure returns (bytes32) {
        return SaleKind.ENGLISH_AUCTION;
    }

    /// @inheritdoc ISaleAdapter
    function isTarget(address token) public view returns (bool) {
        if (_listed[token]) return true;
        address registry = federationRegistry;
        return registry != address(0) && registry.codehash == federationRegistryCodeHash
            && IFederationRegistry(registry).isActive(token);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEnglishAuction).interfaceId
            || interfaceId == type(ISaleAdapter).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Accepts only a token minted into this adapter's custody during a start, so no
    ///         other transfer can strand a token here.
    /// @dev Relies on `start` and `startWithBid` holding the reentrancy guard while they mint;
    ///      any future intake path must hold it too.
    function onERC721Received(address operator, address from, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (operator != address(this) || from != address(0) || !_reentrancyGuardEntered()) {
            revert InvalidTarget(msg.sender);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    // ---------------------------------------------------------------------------- internal

    function _start(address token, bytes calldata mintData) private returns (uint256 saleId) {
        Settings memory c = _settings;
        if (c.pausedAt != 0) revert SalePaused();
        bool listed = _listed[token];
        if (!listed && !isTarget(token)) revert TargetNotAllowed(token);
        (uint256 tokenId, PrimaryTerms memory terms) =
            IMintTarget(token).mint(address(this), 0, 1, mintData);
        if (terms.saleKind != SaleKind.ENGLISH_AUCTION) {
            revert IMintTarget.SaleKindMismatch(SaleKind.ENGLISH_AUCTION, terms.saleKind);
        }
        Terms memory t = _lockTerms(token, tokenId, listed, terms.currency, c);
        // CALLS-1: the escrow refuses to be paid as a wallet, so a work whose seller or fee
        // recipient is the escrow could never settle; it is refused while nothing is at stake.
        if (
            tokenId >> 32 != 0 || terms.seller == address(0) || terms.seller == escrow
                || terms.feeRecipient == escrow
                || (terms.feeRecipient == address(0)
                    && (t.federated ? t.registryFee : terms.feeShare) != 0)
                || terms.creator == address(0) || terms.feeShare > Splits.DENOMINATOR
                || terms.price != 0 || terms.params.length != 0
                || IERC721(token).ownerOf(tokenId) != address(this)
        ) revert InvalidTerms(token, tokenId);
        saleId = saleIdOf(token, tokenId);
        Sale storage s = _sales[saleId];
        if (s.status != AuctionState.NONE) revert InvalidAuctionState(saleId, s.status);
        uint32 endTime = SafeCast.toUint32(block.timestamp + c.duration);
        s.token = token;
        // Safe: `tokenId >> 32 == 0` was checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.tokenId = uint32(tokenId);
        s.endTime = endTime;
        s.termsId = _termsId(t);
        s.status = AuctionState.ACTIVE;
        emit SaleStarted(
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
            currency = allowlist.defaultCurrency(listed ? PRODUCT_STREAM : PRODUCT_FEDERATED);
        } else if (!allowlist.isActive(currency)) {
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
                IFederationRegistry(federationRegistry).entry(token);
            if (e.codeHash != token.codehash || e.feeShare > Splits.DENOMINATOR) {
                revert InvalidTerms(token, tokenId);
            }
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

    /// @dev The sale's terms: the locked currency, the token's seller and fee terms, and the
    ///      registry fee share for a federated token.
    function _lockedTerms(Sale storage s)
        private
        view
        returns (LockedTerms memory lt, address creator)
    {
        Terms storage t = _terms[s.termsId];
        PrimaryTerms memory p = IMintTarget(s.token).primaryTerms(s.tokenId, "");
        lt = LockedTerms(
            s.token,
            s.tokenId,
            t.currency,
            0,
            p.seller,
            p.feeRecipient,
            t.federated ? t.registryFee : p.feeShare
        );
        if (lt.feeShare > Splits.DENOMINATOR) revert InvalidTerms(s.token, s.tokenId);
        creator = p.creator;
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
        Sale storage s = _require(saleId, AuctionState.ACTIVE);
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
                uint96(Math.min(allowlist.incrementFloor(currency), type(uint96).max));
            // `t` keeps pointing at the start record: the two differ only in the floor, which
            // the first bid does not use, and rereading the new record would cost a cold slot.
            s.termsId = _termsId(locked);
        } else if (!allowlist.isActive(currency)) {
            revert IAssetAllowlist.AssetNotActive(currency);
        }
        if (recipient == address(this)) revert InvalidRecipient(recipient);
        uint256 required = _minimumBid(s, t);
        if (payment.amount < required) revert BidTooLow(required, payment.amount);
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
        // forge-lint: disable-next-line(unsafe-typecast)
        emit BidPlaced(saleId, payment.payer, recipient, payment.amount, uint64(end));
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
                revert InvalidPayment();
            }
            return;
        }
        if (msg.value != 0) revert InvalidPayment();
        if (p.method == PaymentMethod.PERMIT2) {
            if (permit2 == address(0)) revert InvalidPayment();
            uint256 held = TokenTransfer.balanceOf(currency, address(this));
            uint256 payerHeld = TokenTransfer.balanceOf(currency, p.payer);
            ISignatureTransfer(permit2)
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
        if (p.payer != msg.sender) revert InvalidPayment();
        if (p.method == PaymentMethod.PERMIT) {
            if (p.signature.length != 65) revert InvalidPayment();
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
    function _pay(address currency, address wallet, uint256 amount) private {
        if (amount == 0) return;
        if (currency == CURRENCY_ETH) {
            RevenuePayment.payETH(IRevenueEscrow(escrow), wallet, amount, PAYOUT_GAS);
        } else {
            RevenuePayment.payERC20(IRevenueEscrow(escrow), wallet, currency, amount);
        }
    }

    /// @dev Gives the token's `safeTransferFrom` to `s.recipient` exactly {DELIVERY_GAS} and
    ///      copies no return data. The token counts as delivered once it has left custody: a
    ///      recipient that rejects it, runs out of gas, or hands it back leaves it here as a
    ///      pending claim instead.
    function _deliver(uint256 saleId, Sale storage s) private {
        (address token, uint256 tokenId, address to) = (s.token, s.tokenId, _recipientOf(s));
        if (!BoundedCall.hasSufficientGas(gasleft(), DELIVERY_GAS, DELIVERY_RESERVE)) {
            revert DeliveryInsufficientGas();
        }
        bytes memory data = abi.encodeWithSelector(_SAFE_TRANSFER_FROM, address(this), to, tokenId);
        uint256 gasLimit = DELIVERY_GAS;
        assembly ("memory-safe") {
            pop(call(gasLimit, token, 0, add(data, 0x20), mload(data), 0, 0))
        }
        if (IERC721(token).ownerOf(tokenId) == address(this)) {
            s.flags |= _DELIVERY_PENDING;
            emit DeliveryPending(saleId, to);
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
        emit SaleSettled(
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
        emit Credited(account, currency, saleId, amount);
    }

    /// @dev Loads a sale after writing down an expired pause, and requires the `wanted` state.
    function _require(uint256 saleId, AuctionState wanted) private returns (Sale storage s) {
        s = _sales[saleId];
        if (s.flags & _PAUSE_USED != 0) {
            uint256 pausedAt = s.pausedAt;
            // The pause clock is in seconds; a validator moves it by seconds, not days.
            // forge-lint: disable-next-line(block-timestamp)
            if (pausedAt != 0 && block.timestamp > pausedAt + MAX_PAUSE) {
                _endPause(saleId, s, MAX_PAUSE);
            }
        }
        AuctionState state = _state(s);
        if (state == AuctionState.NONE) revert UnknownSale(saleId);
        if (state != wanted) revert InvalidAuctionState(saleId, state);
    }

    function _endPause(uint256 saleId, Sale storage s, uint256 length) private {
        uint32 end = SafeCast.toUint32(_resumedEnd(s, length));
        s.endTime = end;
        s.pausedTotal = SafeCast.toUint24(length);
        s.pausedAt = 0;
        emit AuctionResumed(saleId, end);
    }

    /// @dev The derived state: PAUSED while a pause is live (through `pausedAt + MAX_PAUSE`
    ///      inclusive), ENDED once the end has passed.
    function _state(Sale storage s) private view returns (AuctionState) {
        AuctionState status = s.status;
        if (status != AuctionState.ACTIVE) return status;
        uint256 end = s.endTime;
        uint256 pausedAt = s.flags & _PAUSE_USED == 0 ? 0 : s.pausedAt;
        if (pausedAt != 0) {
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp <= pausedAt + MAX_PAUSE) return AuctionState.PAUSED;
            end = _resumedEnd(s, MAX_PAUSE);
        }
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp < end ? AuctionState.ACTIVE : AuctionState.ENDED;
    }

    /// @dev The end after a pause of `length` seconds: the remaining time at the pause, but at
    ///      least {_reopening} from the resumption (L-2, LIFECYCLE-1).
    function _resumedEnd(Sale storage s, uint256 length) private view returns (uint256) {
        uint256 pausedAt = s.pausedAt;
        return pausedAt + length + Math.max(s.endTime - pausedAt, _reopening(s));
    }

    /// @dev The least time a halted auction gets back when it resumes: the anti-snipe window, or
    ///      the governed duration when its high bid was withdrawn (LIFECYCLE-1: the reserve is
    ///      set and no bidder stands), so the refunded bidders can re-form the market.
    function _reopening(Sale storage s) private view returns (uint256) {
        return s.bidder == address(0) && s.bid != 0
            ? _settings.duration
            : _terms[s.termsId].extensionWindow;
    }

    /// @dev GOV-5: a pause that began at `pausedAt` ends no earlier than `Roles.STANDARD` later.
    function _requireUnpausable(uint256 pausedAt) private view {
        uint256 allowedAt = pausedAt + Roles.STANDARD;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < allowedAt) revert UnpauseTooEarly(allowedAt);
    }

    /// @dev The token's recipient: the stored one, or the bidder when none is stored.
    function _recipientOf(Sale storage s) private view returns (address) {
        return s.flags & _RECIPIENT_SET != 0 ? s.recipient : s.bidder;
    }

    function _setTarget(address token, bool listed) private {
        if (
            listed
                && (token.code.length == 0
                    || DelegatedEOA.isDelegated(token)
                    || !ERC165Checker.supportsInterface(token, type(IERC721).interfaceId))
        ) revert InvalidTarget(token);
        _listed[token] = listed;
        emit TargetSet(token, listed);
    }

    function _setConfig(AuctionConfig memory next) private {
        if (
            next.duration < MIN_DURATION || next.duration > MAX_DURATION
                || next.extensionWindow < MIN_EXTENSION_WINDOW
                || next.extensionWindow > MAX_EXTENSION_WINDOW
                || next.extensionWindow > next.duration || next.incrementShare < MIN_INCREMENT_SHARE
                || next.incrementShare > Splits.DENOMINATOR
        ) revert InvalidConfig();
        emit ConfigSet(_currentConfig(), next);
        Settings storage st = _settings;
        (st.duration, st.extensionWindow, st.incrementShare) =
        (next.duration, next.extensionWindow, next.incrementShare);
    }

    function _currentConfig() private view returns (AuctionConfig memory) {
        Settings storage st = _settings;
        return AuctionConfig(st.duration, st.extensionWindow, st.incrementShare);
    }

    function _requireContract(address dependency) private view {
        if (dependency.code.length == 0 || DelegatedEOA.isDelegated(dependency)) {
            revert InvalidDependency(dependency);
        }
    }
}
