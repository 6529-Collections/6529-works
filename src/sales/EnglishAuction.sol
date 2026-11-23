// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IAssetAllowlist } from "../economics/interfaces/IAssetAllowlist.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { RevenuePayment } from "../economics/RevenuePayment.sol";
import { MintFacts, MintTerms, Outcome, Slots } from "../interfaces/core/CoreTypes.sol";
import { IDirectory } from "../interfaces/core/IDirectory.sol";
import { IIndependentStreamGate } from "../interfaces/core/IIndependentStreamGate.sol";
import { IMintPolicy } from "../interfaces/core/IMintPolicy.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { IEconomicsResolver } from "../interfaces/IEconomicsResolver.sol";
import { IIndependentStreamRegistry } from "../interfaces/IIndependentStreamRegistry.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IEnglishAuctionClock } from "../interfaces/IEnglishAuctionClock.sol";
import { IEnglishAuctionRefusal } from "../interfaces/IEnglishAuctionRefusal.sol";
import { IStatementLog } from "../interfaces/IStatementLog.sol";
import {
    CURRENCY_ETH,
    PRODUCT_INDEPENDENT,
    PRODUCT_STREAM
} from "../interfaces/types/EconomicsTypes.sol";
import { SaleKind } from "../interfaces/types/SaleTypes.sol";
import { AgedCredits } from "../libraries/AgedCredits.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { Dependency } from "../libraries/Dependency.sol";

/// @title EnglishAuction
/// @notice The network's English auction for 1/1 works, in ETH. See {IEnglishAuction} for the
///         behaviour; this contract adds the storage and the bounds.
/// @dev Replaceable: it holds bidders' money while their sales run, and its rules for that money
///      are fixed in this code. One sale is one `Sale` struct (two slots from the start, a third
///      from the first bid, a fourth only for a recipient other than the bidder or a dispute
///      pause). Credits are one `Credit` struct per account.
///
///      What the auction trusts. 6529 Stream (immutable) and its genesis token code; the
///      directory (immutable), whose Independent Stream module is the mint policy of every other
///      token and answers which tokens this auction may mint for; the economics resolver
///      (immutable) for the museum and the fee recipients; the escrow for refused payouts; the
///      statement log for dispute outcomes. A token this auction sells is either Stream or a token
///      the Independent Stream module admits, so its code is reviewed code.
///
///      ETH balance. The contract's balance always equals the standing bids of sales that are
///      not settled or cancelled plus every account's credit: a bid adds both, an outbid moves a
///      bid to a credit, a settlement pays a bid out, a claim or expiry pays a credit out.
///
///      Independent Stream works and replacement. Whether an Independent Stream sale goes on is
///      whether the Independent Stream module still serves its token
///      (`IIndependentStreamRegistry.isActive`: listed, not delisted, its version not revoked),
///      never whether this auction may still mint new works. An Independent Stream token lets the
///      account that minted a work record that work's sale for good
///      (`IIndependentStream.hasMinted`), so an auction the network removed or replaced stays the
///      venue of the works it minted: its running sales finish, and its unsold works can be offered
///      again here (`restart`) for as long as the token is served. The network's other path is
///      `IStream.rescue`, once the token's `rescueDelay` has passed since the removal: it ends the
///      work's primary sale as RESCUED and moves the work where the network says.
contract EnglishAuction is
    IEnglishAuction,
    IEnglishAuctionClock,
    IEnglishAuctionRefusal,
    IERC721Receiver,
    IERC165,
    AccessManaged,
    ReentrancyGuardTransient
{
    /// @notice The longest a dispute pause lasts; one pause per sale.
    uint64 public constant MAX_PAUSE = 3 days;
    /// @notice Gas forwarded to a seller or fee wallet; a wallet that refuses is paid through
    ///         the revenue escrow.
    uint256 public constant PAYOUT_GAS = 100_000;
    /// @notice Gas forwarded to the token's `safeTransferFrom` when settling; a failure leaves a
    ///         pending delivery.
    uint256 public constant DELIVERY_GAS = 300_000;
    /// @notice Gas the settlement needs after the delivery attempt returns.
    uint256 public constant DELIVERY_RESERVE = 50_000;
    /// @notice How long after a sale's end only the winning bidder may send a pending delivery to
    ///         an address other than the recipient it named.
    uint256 public constant REDIRECT_DELAY = 14 days;
    /// @notice How long after an Independent Stream sale's end a refused settlement may close it.
    uint256 public constant REFUSAL_DELAY = 2 days;

    uint32 private constant MIN_DURATION = 1 hours;
    uint32 private constant MAX_DURATION = 7 days;
    uint32 private constant MIN_EXTENSION_WINDOW = 1 minutes;
    uint32 private constant MAX_EXTENSION_WINDOW = 1 days;
    uint32 private constant MIN_INCREMENT_SHARE = 1_000;
    uint32 private constant MIN_REFUSAL_GAS = 3_000_000;
    uint32 private constant MAX_REFUSAL_GAS = 15_000_000;
    uint256 private constant DENOMINATOR = 100_000;

    /// @dev One sale. Slot one: the token. Slot two, written at start: the seller and fee share
    ///      the policy answered, the end, the status and three flags. Slot three, from the
    ///      first bid: the high bidder and bid (with no bidder, a withdrawn bid's reserve). Slot
    ///      four, only for a recipient other than the bidder or a dispute pause. Slot five, only
    ///      for a work offered again: when its latest `restart` was.
    struct Sale {
        address token;
        uint96 tokenId;
        address seller;
        uint24 feeShare;
        uint40 endTime;
        AuctionState status;
        bool pauseUsed;
        bool deliveryPending;
        bool recipientSet;
        address bidder;
        uint96 bid;
        address recipient;
        uint40 pausedAt;
        uint40 outcomeFrom;
        uint40 restartedAt;
    }

    /// @dev The governed parameters and the start pause, one slot.
    struct Settings {
        uint32 duration;
        uint32 extensionWindow;
        uint32 incrementShare;
        uint32 refusalGas;
        bool paused;
    }

    /// @notice 6529 Stream.
    address public immutable stream;
    /// @notice The directory: the Independent Stream module and the unclaimed period.
    IDirectory public immutable directory;
    /// @notice The economics resolver: the museum, the fee recipients, the asset allowlist.
    IEconomicsResolver public immutable economics;
    /// @notice The asset allowlist: the ETH opening bid and increment floor.
    IAssetAllowlist public immutable allowlist;
    /// @notice The revenue escrow for refused payouts.
    IRevenueEscrow public immutable escrow;
    /// @notice The statement log `cancel` reads.
    IStatementLog public immutable statementLog;

    /// @notice 6529 Stream's mint policy (the package registry).
    address public streamPolicy;
    Settings private _settings;
    mapping(uint256 saleId => Sale) private _sales;
    mapping(address account => AgedCredits.Credit) private _credits;

    /// @param authority The AccessManager.
    /// @param stream_ 6529 Stream.
    /// @param directory_ The directory.
    /// @param economics_ The economics resolver.
    /// @param escrow_ The revenue escrow.
    /// @param statementLog_ The statement log.
    /// @param streamPolicy_ 6529 Stream's mint policy, or zero.
    /// @param config_ The initial parameters.
    constructor(
        address authority,
        address stream_,
        IDirectory directory_,
        IEconomicsResolver economics_,
        IRevenueEscrow escrow_,
        IStatementLog statementLog_,
        address streamPolicy_,
        AuctionConfig memory config_
    ) AccessManaged(authority) {
        Dependency.check(stream_, type(IStream).interfaceId);
        Dependency.check(address(directory_), type(IDirectory).interfaceId);
        Dependency.check(address(economics_), type(IEconomicsResolver).interfaceId);
        Dependency.check(address(escrow_));
        Dependency.check(address(statementLog_));
        IAssetAllowlist allowlist_ = IAssetAllowlist(economics_.assetAllowlist());
        Dependency.check(address(allowlist_));
        stream = stream_;
        directory = directory_;
        economics = economics_;
        allowlist = allowlist_;
        escrow = escrow_;
        statementLog = statementLog_;
        _setStreamPolicy(streamPolicy_);
        _setConfig(config_);
    }

    // ------------------------------------------------------------------------------- start

    /// @inheritdoc IEnglishAuction
    function start(address token, bytes calldata request)
        external
        nonReentrant
        returns (uint256 saleId)
    {
        saleId = _start(token, request);
    }

    /// @inheritdoc IEnglishAuction
    function startWithBid(address token, bytes calldata request, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 saleId)
    {
        saleId = _start(token, request);
        _bid(saleId, recipient);
    }

    /// @inheritdoc IEnglishAuction
    function restart(uint256 saleId) external nonReentrant {
        Settings memory c = _settings;
        if (c.paused) revert SalePaused();
        Sale storage s = _sales[saleId];
        address token = s.token;
        if (
            s.status != AuctionState.SETTLED || token == stream || s.deliveryPending
                || IERC721(token).ownerOf(s.tokenId) != address(this)
                || IStream(token).workOf(s.tokenId).outcome != Outcome.NONE
        ) revert InvalidAuctionState(saleId, _state(s));
        if (!_served(token)) revert TargetNotAllowed(token);
        // The network's share only goes down: a restart takes the share in force now.
        uint256 share = IIndependentStreamGate(policyOf(token)).feeShareOf(token);
        if (share > DENOMINATOR) revert InvalidSaleTerms(token, s.tokenId);
        uint40 end = SafeCast.toUint40(block.timestamp + c.duration);
        // Checked above: at most 100,000.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.feeShare = uint24(share);
        (s.endTime, s.status, s.pauseUsed, s.recipientSet) =
        (end, AuctionState.ACTIVE, false, false);
        (s.bidder, s.bid) = (address(0), 0);
        (s.recipient, s.pausedAt, s.outcomeFrom) = (address(0), 0, 0);
        // A sale that follows this one (an edition sale) reads this to learn that the sale it
        // followed was settled unsold before the work was offered again.
        s.restartedAt = uint40(block.timestamp);
        emit SaleStarted(
            saleId,
            token,
            s.tokenId,
            SaleKind.ENGLISH_AUCTION,
            CURRENCY_ETH,
            allowlist.openingBid(CURRENCY_ETH),
            uint64(block.timestamp),
            end
        );
    }

    // ----------------------------------------------------------------------------- bidding

    /// @inheritdoc IEnglishAuction
    function bid(uint256 saleId, address recipient) external payable nonReentrant {
        _bid(saleId, recipient);
    }

    /// @inheritdoc IEnglishAuction
    function withdrawBid(uint256 saleId) external nonReentrant {
        Sale storage s = _require(saleId, AuctionState.PAUSED);
        address bidder = s.bidder;
        // With no bidder this reverts too: the caller is never the zero address.
        if (msg.sender != bidder) revert NotHighBidder(msg.sender);
        uint256 amount = s.bid;
        _refundHighBid(saleId, s);
        emit BidWithdrawn(saleId, bidder, amount);
    }

    // -------------------------------------------------------------------------- settlement

    /// @inheritdoc IEnglishAuction
    /// @dev In order: a work no longer in custody (only the network's `IStream.rescue` can move
    ///      it) closes with refunds; an Independent Stream work whose token the Independent Stream
    ///      module no longer serves (delisted, or its version revoked) has its standing bid
    ///      credited back and ends unsold, while a removed auction or a suspended version settles
    ///      as usual; with no bid, a 6529 Stream work is recorded UNSOLD and sent to the museum, an
    ///      Independent Stream work stays in custody for `restart`; with a bid, the outcome is
    ///      recorded SOLD, the seller and the network are paid and the work is delivered (or left
    ///      pending).
    function settle(uint256 saleId) external nonReentrant {
        Sale storage s = _require(saleId, AuctionState.ENDED);
        s.status = AuctionState.SETTLED;
        (address token, uint256 tokenId) = (s.token, s.tokenId);
        if (IERC721(token).ownerOf(tokenId) != address(this)) {
            _refundHighBid(saleId, s);
            emit RescuedSaleClosed(saleId);
            return;
        }
        bool independent = token != stream;
        if (independent && !_served(token)) _refundHighBid(saleId, s);
        if (s.bidder == address(0)) {
            address holder = address(this);
            if (!independent) {
                holder = economics.museum();
                if (holder == address(0)) revert InvalidRecipient(holder);
                IStream(token).recordPrimarySale(tokenId, false, address(0), 0);
                IERC721(token).transferFrom(address(this), holder, tokenId);
            }
            _emitSettled(saleId, s, holder, 0, address(0), 0);
            return;
        }
        _settleSold(saleId, s, token, tokenId, independent);
    }

    /// @dev Records the sale, pays the seller and the network, and delivers the work.
    function _settleSold(
        uint256 saleId,
        Sale storage s,
        address token,
        uint256 tokenId,
        bool independent
    ) private {
        uint256 price = s.bid;
        IStream(token).recordPrimarySale(tokenId, true, s.bidder, price);
        // The seller's part rounds down, so the leftover wei is the network's.
        uint256 fee = price - price * (DENOMINATOR - s.feeShare) / DENOMINATOR;
        address feeRecipient;
        if (fee != 0) {
            feeRecipient =
                economics.networkFeeRecipient(independent ? PRODUCT_INDEPENDENT : PRODUCT_STREAM);
        }
        _pay(s.seller, price - fee);
        _pay(feeRecipient, fee);
        address to = _recipientOf(s);
        _deliver(saleId, s, token, tokenId, to);
        _emitSettled(saleId, s, to, price, feeRecipient, fee);
    }

    /// @dev Emits `SaleSettled` from the stored sale (its own frame keeps the stack shallow).
    function _emitSettled(
        uint256 saleId,
        Sale storage s,
        address to,
        uint256 price,
        address feeRecipient,
        uint256 fee
    ) private {
        emit SaleSettled(
            saleId,
            s.token,
            s.tokenId,
            s.bidder,
            to,
            1,
            CURRENCY_ETH,
            price,
            s.seller,
            price - fee,
            feeRecipient,
            fee
        );
    }

    /// @inheritdoc IEnglishAuctionRefusal
    /// @dev Independent Stream sales only, from the end plus {REFUSAL_DELAY}. The attempt is
    ///      {settle} itself, called on this contract with exactly the refusal gas, which the caller
    ///      must be able to forward in full, so a shortfall is never taken for a refusal. If it
    ///      fails, every effect is undone, the standing bid is credited back and the work stays in
    ///      custody, where anyone may offer it again (`restart`). Refused inside a guarded call of
    ///      this contract or of the escrow, so neither a token from inside its own settlement nor a
    ///      caller inside the escrow can make an attempt fail on a guard. The escrow is asked
    ///      through its `locked()` view, a plain call: if that read fails, this reverts.
    function settleOrRefund(uint256 saleId) external {
        Sale storage s = _require(saleId, AuctionState.ENDED);
        if (s.token == stream) revert SaleNotRefusable(saleId);
        uint256 allowedAt = uint256(s.endTime) + REFUSAL_DELAY;
        if (block.timestamp < allowedAt) revert RefusalTooEarly(saleId, allowedAt);
        if (escrow.locked() || _reentrancyGuardEntered()) revert ReentrancyGuardReentrantCall();
        uint256 gasLimit = _settings.refusalGas;
        if (!BoundedCall.hasSufficientGas(gasleft(), gasLimit, 1_000)) {
            revert BoundedCall.BoundedCallInsufficientGas(gasLimit);
        }
        (bool settled,) = address(this).call{ gas: gasLimit }(abi.encodeCall(this.settle, (saleId)));
        if (settled) return;
        s.status = AuctionState.SETTLED;
        _refundHighBid(saleId, s);
        emit SettlementRefused(saleId);
    }

    /// @inheritdoc IEnglishAuction
    function claimDelivery(uint256 saleId, address to) external nonReentrant {
        Sale storage s = _sales[saleId];
        address pending = _recipientOf(s);
        address bidder = s.bidder;
        if (!s.deliveryPending || (msg.sender != pending && msg.sender != bidder)) {
            revert NoPendingDelivery(saleId);
        }
        if (
            to == address(0) || to == address(this)
                || (msg.sender != bidder
                    && to != pending
                    && block.timestamp < uint256(s.endTime) + REDIRECT_DELAY)
        ) revert InvalidRecipient(to);
        s.deliveryPending = false;
        IERC721(s.token).safeTransferFrom(address(this), to, s.tokenId);
        emit DeliveryClaimed(saleId, pending, to);
    }

    // ---------------------------------------------------------------------------- disputes

    /// @inheritdoc IEnglishAuction
    function pause(uint256 saleId, bytes32 disputeRef) external restricted nonReentrant {
        Sale storage s = _require(saleId, AuctionState.ACTIVE);
        if (s.pauseUsed) revert PauseExhausted(saleId);
        s.pauseUsed = true;
        s.pausedAt = uint40(block.timestamp);
        // `cancel` must cite an outcome recorded after this pause: one past the position of
        // the token's latest outcome now (none: any position).
        (bytes32 entry, uint64 index) = statementLog.disputeOutcomeOf(s.token, s.tokenId);
        if (entry != 0) s.outcomeFrom = SafeCast.toUint40(uint256(index) + 1);
        emit AuctionPaused(saleId, disputeRef);
    }

    /// @inheritdoc IEnglishAuction
    function resume(uint256 saleId) external restricted nonReentrant {
        Sale storage s = _require(saleId, AuctionState.PAUSED);
        _endPause(saleId, s, block.timestamp - s.pausedAt);
    }

    /// @inheritdoc IEnglishAuction
    function cancel(uint256 saleId, bytes32 outcomeRef) external restricted nonReentrant {
        Sale storage s = _require(saleId, AuctionState.PAUSED);
        (bytes32 entry, uint64 index) = statementLog.disputeOutcomeOf(s.token, s.tokenId);
        if (outcomeRef == bytes32(0) || outcomeRef != entry || index < s.outcomeFrom) {
            revert OutcomeNotRecorded(saleId, outcomeRef);
        }
        s.status = AuctionState.CANCELLED;
        s.pausedAt = 0;
        _refundHighBid(saleId, s);
        IStream(s.token).burn(s.tokenId);
        emit AuctionCancelled(saleId, outcomeRef);
    }

    // ----------------------------------------------------------------------------- credits

    /// @inheritdoc IEnglishAuction
    function claim(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert InvalidRecipient(to);
        amount = AgedCredits.takeAll(_credits[msg.sender]);
        if (amount == 0) revert NothingToClaim(msg.sender);
        emit Claimed(msg.sender, CURRENCY_ETH, to, amount);
        _send(to, amount);
    }

    /// @inheritdoc IEnglishAuction
    function expireCredit(address account) external nonReentrant returns (uint256 amount) {
        AgedCredits.Credit storage c = _credits[account];
        uint256 dueAt = AgedCredits.dueAt(c, directory.unclaimedPeriod());
        if (dueAt == 0) revert NothingToClaim(account);
        if (block.timestamp < dueAt) revert CreditNotExpired(account, dueAt);
        address to = economics.networkFeeRecipient(PRODUCT_STREAM);
        if (to == address(0)) revert InvalidRecipient(to);
        amount = AgedCredits.expireAged(c);
        emit CreditExpired(account, CURRENCY_ETH, to, amount);
        _send(to, amount);
    }

    // -------------------------------------------------------------------------- governance

    /// @inheritdoc IEnglishAuction
    function pause() external restricted {
        if (_settings.paused) revert SalePaused();
        _settings.paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IEnglishAuction
    function unpause() external restricted {
        if (!_settings.paused) revert NotPaused();
        _settings.paused = false;
        emit Unpaused(msg.sender);
    }

    /// @inheritdoc IEnglishAuction
    function setConfig(AuctionConfig calldata expected, AuctionConfig calldata next)
        external
        restricted
    {
        AuctionConfig memory current = config();
        if (
            current.duration != expected.duration
                || current.extensionWindow != expected.extensionWindow
                || current.incrementShare != expected.incrementShare
                || current.refusalGas != expected.refusalGas
        ) revert ExpectedValueMismatch();
        _setConfig(next);
    }

    /// @inheritdoc IEnglishAuction
    function setStreamPolicy(address expected, address next) external restricted {
        if (streamPolicy != expected) revert ExpectedValueMismatch();
        _setStreamPolicy(next);
    }

    // ------------------------------------------------------------------------------- views

    /// @inheritdoc IEnglishAuction
    function saleIdOf(address token, uint256 tokenId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(token, tokenId)));
    }

    /// @inheritdoc IEnglishAuction
    function policyOf(address token) public view returns (address) {
        if (token == stream) return streamPolicy;
        return directory.moduleOf(Slots.INDEPENDENT_STREAM);
    }

    /// @inheritdoc IEnglishAuction
    function auction(uint256 saleId) external view returns (Auction memory a) {
        Sale storage s = _sales[saleId];
        AuctionState state = _state(s);
        if (state == AuctionState.NONE) revert UnknownSale(saleId);
        (uint64 endTime, uint64 pausedAt) = _clock(s);
        a = Auction(
            s.token,
            s.tokenId,
            s.seller,
            s.feeShare,
            s.bidder,
            _recipientOf(s),
            s.bid,
            endTime,
            pausedAt,
            state
        );
    }

    /// @inheritdoc IEnglishAuctionClock
    function auctionClock(uint256 saleId)
        external
        view
        returns (AuctionState state, uint64 endTime, uint64 pausedAt, uint64 restartedAt)
    {
        Sale storage s = _sales[saleId];
        state = _state(s);
        if (state == AuctionState.NONE) revert UnknownSale(saleId);
        (endTime, pausedAt) = _clock(s);
        restartedAt = s.restartedAt;
    }

    /// @inheritdoc IEnglishAuctionRefusal
    function refusableAt(uint256 saleId) external view returns (uint256) {
        Sale storage s = _sales[saleId];
        if (_state(s) == AuctionState.NONE) revert UnknownSale(saleId);
        if (s.token == stream) revert SaleNotRefusable(saleId);
        (uint64 endTime,) = _clock(s);
        return uint256(endTime) + REFUSAL_DELAY;
    }

    /// @inheritdoc IEnglishAuction
    function minimumBid(uint256 saleId) external view returns (uint256) {
        Sale storage s = _sales[saleId];
        if (_state(s) == AuctionState.NONE) revert UnknownSale(saleId);
        return _minimumBid(s);
    }

    /// @inheritdoc IEnglishAuction
    function pendingDelivery(uint256 saleId) external view returns (address) {
        Sale storage s = _sales[saleId];
        return s.deliveryPending ? _recipientOf(s) : address(0);
    }

    /// @inheritdoc IEnglishAuction
    function claimable(address account) external view returns (uint256) {
        return _credits[account].total;
    }

    /// @inheritdoc IEnglishAuction
    function expiresAt(address account) external view returns (uint256) {
        return AgedCredits.dueAt(_credits[account], directory.unclaimedPeriod());
    }

    /// @inheritdoc IEnglishAuction
    function config() public view returns (AuctionConfig memory) {
        Settings storage st = _settings;
        return AuctionConfig(st.duration, st.extensionWindow, st.incrementShare, st.refusalGas);
    }

    /// @inheritdoc IEnglishAuction
    function paused() external view returns (bool) {
        return _settings.paused;
    }

    /// @notice Accepts only a token minted into custody during a start; refuses every other safe
    ///         transfer. A plain `transferFrom` to this contract cannot be refused: never send a
    ///         token here.
    /// @param operator The address that made the transfer; it must be this contract.
    /// @param from The previous owner; it must be zero (a mint).
    /// @return The `onERC721Received` selector.
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

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IEnglishAuction).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId;
    }

    // ---------------------------------------------------------------------------- internal

    /// @dev Admits and mints the work, checks the terms and opens the sale.
    function _start(address token, bytes calldata request) private returns (uint256 saleId) {
        Settings memory c = _settings;
        if (c.paused) revert SalePaused();
        address policy = policyOf(token);
        if (policy == address(0)) revert TargetNotAllowed(token);
        (MintFacts memory f, MintTerms memory t) = IMintPolicy(policy).authorize(token, request);
        // The escrow refuses to be paid as a wallet, so a seller that is the escrow (or this
        // contract) could never settle; it is refused while nothing is at stake.
        if (
            t.saleKind != SaleKind.ENGLISH_AUCTION || t.params.length != 0 || t.seller == address(0)
                || t.seller == address(escrow) || t.seller == address(this)
                || t.feeShare > DENOMINATOR
        ) revert InvalidSaleTerms(token, 0);
        uint256 tokenId = IStream(token).mint(address(this), f);
        if (IERC721(token).ownerOf(tokenId) != address(this)) {
            revert InvalidSaleTerms(token, tokenId);
        }
        saleId = saleIdOf(token, tokenId);
        Sale storage s = _sales[saleId];
        if (s.status != AuctionState.NONE) revert InvalidAuctionState(saleId, _state(s));
        uint40 end = SafeCast.toUint40(block.timestamp + c.duration);
        (s.token, s.tokenId) = (token, SafeCast.toUint96(tokenId));
        // Checked above: at most 100,000.
        // forge-lint: disable-next-line(unsafe-typecast)
        (s.seller, s.feeShare, s.endTime, s.status) =
        (t.seller, uint24(t.feeShare), end, AuctionState.ACTIVE);
        emit SaleStarted(
            saleId,
            token,
            tokenId,
            SaleKind.ENGLISH_AUCTION,
            CURRENCY_ETH,
            allowlist.openingBid(CURRENCY_ETH),
            uint64(block.timestamp),
            end
        );
    }

    /// @dev Records a bid of `msg.value` by the caller for `recipient` (the caller when zero).
    function _bid(uint256 saleId, address recipient) private {
        Sale storage s = _require(saleId, AuctionState.ACTIVE);
        // An Independent Stream token the Independent Stream module no longer serves (delisted)
        // takes no bids.
        if (s.token != stream && !_served(s.token)) revert TargetNotAllowed(s.token);
        if (recipient == address(0)) recipient = msg.sender;
        if (recipient == address(this)) revert InvalidRecipient(recipient);
        uint256 required = _minimumBid(s);
        if (msg.value < required || msg.value > type(uint96).max) {
            revert BidTooLow(required, msg.value);
        }
        address previous = s.bidder;
        if (previous != address(0)) _credit(previous, saleId, s.bid);
        s.bidder = msg.sender;
        // Checked above: at most 96 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.bid = uint96(msg.value);
        if (recipient != msg.sender) {
            s.recipientSet = true;
            s.recipient = recipient;
        } else if (s.recipientSet) {
            s.recipientSet = false;
            s.recipient = address(0);
        }
        uint256 end = s.endTime;
        uint256 window = _settings.extensionWindow;
        if (end - block.timestamp < window) {
            end = block.timestamp + window;
            s.endTime = SafeCast.toUint40(end);
        }
        emit BidPlaced(saleId, msg.sender, recipient, msg.value, uint64(end));
    }

    /// @dev The first bid reaches `max(opening bid, reserve, 1 wei)`; a later bid adds
    ///      `max(incrementShare of the high bid, rounded up; the increment floor)`.
    function _minimumBid(Sale storage s) private view returns (uint256) {
        if (s.bidder == address(0)) {
            return Math.max(Math.max(allowlist.openingBid(CURRENCY_ETH), s.bid), 1);
        }
        uint256 high = s.bid;
        uint256 step = Math.mulDiv(high, _settings.incrementShare, DENOMINATOR, Math.Rounding.Ceil);
        return high + Math.max(step, allowlist.incrementFloor(CURRENCY_ETH));
    }

    /// @dev Pays `amount` wei to `wallet` with {PAYOUT_GAS}; a refusal goes to the escrow for
    ///      the wallet. Nothing for zero. Never to zero, the escrow or this contract.
    function _pay(address wallet, uint256 amount) private {
        if (amount == 0) return;
        if (wallet == address(0) || wallet == address(escrow) || wallet == address(this)) {
            revert InvalidRecipient(wallet);
        }
        RevenuePayment.payETH(escrow, wallet, amount, PAYOUT_GAS);
    }

    /// @dev Sends ETH with all gas; a refusal reverts.
    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert ClaimFailed(to);
    }

    /// @dev Gives the token's `safeTransferFrom` to `to` exactly {DELIVERY_GAS}. The work counts
    ///      as delivered once it has left custody; a recipient that rejects it, runs out of gas
    ///      or hands it back leaves it here as a pending delivery.
    function _deliver(uint256 saleId, Sale storage s, address token, uint256 tokenId, address to)
        private
    {
        if (!BoundedCall.hasSufficientGas(gasleft(), DELIVERY_GAS, DELIVERY_RESERVE)) {
            revert DeliveryInsufficientGas();
        }
        (bool ok,) = token.call{ gas: DELIVERY_GAS }(
            abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256)", address(this), to, tokenId
            )
        );
        ok;
        if (IERC721(token).ownerOf(tokenId) == address(this)) {
            s.deliveryPending = true;
            emit DeliveryPending(saleId, to);
        }
    }

    /// @dev Credits a standing bid back to its bidder; the amount stays as the reserve.
    function _refundHighBid(uint256 saleId, Sale storage s) private {
        address bidder = s.bidder;
        if (bidder == address(0)) return;
        _credit(bidder, saleId, s.bid);
        s.bidder = address(0);
        if (s.recipientSet) {
            s.recipientSet = false;
            s.recipient = address(0);
        }
    }

    /// @dev Adds to a credit under the shared rule (`AgedCredits`): nobody can shorten or
    ///      postpone a running wait.
    function _credit(address account, uint256 saleId, uint256 amount) private {
        AgedCredits.add(_credits[account], amount);
        emit Credited(account, CURRENCY_ETH, saleId, amount);
    }

    /// @dev Loads a sale after writing down a pause past `MAX_PAUSE`, and requires `wanted`.
    function _require(uint256 saleId, AuctionState wanted) private returns (Sale storage s) {
        s = _sales[saleId];
        if (s.pauseUsed && s.pausedAt != 0 && block.timestamp > s.pausedAt + MAX_PAUSE) {
            _endPause(saleId, s, MAX_PAUSE);
        }
        AuctionState state = _state(s);
        if (state == AuctionState.NONE) revert UnknownSale(saleId);
        if (state != wanted) revert InvalidAuctionState(saleId, state);
    }

    function _endPause(uint256 saleId, Sale storage s, uint256 length) private {
        uint40 end = SafeCast.toUint40(_resumedEnd(s, length));
        s.endTime = end;
        s.pausedAt = 0;
        emit AuctionResumed(saleId, end);
    }

    /// @dev The derived state: PAUSED while a pause is live (through `pausedAt + MAX_PAUSE`
    ///      inclusive), ENDED once the end has passed.
    function _state(Sale storage s) private view returns (AuctionState) {
        AuctionState status = s.status;
        if (status != AuctionState.ACTIVE) return status;
        uint256 end = s.endTime;
        uint256 pausedAt = s.pausedAt;
        if (s.pauseUsed && pausedAt != 0) {
            if (block.timestamp <= pausedAt + MAX_PAUSE) return AuctionState.PAUSED;
            end = _resumedEnd(s, MAX_PAUSE);
        }
        return block.timestamp < end ? AuctionState.ACTIVE : AuctionState.ENDED;
    }

    /// @dev The end and live pause start as views report them: a pause past `MAX_PAUSE` shows
    ///      resumed, with the end it resumes to.
    function _clock(Sale storage s) private view returns (uint64 endTime, uint64 pausedAt) {
        (endTime, pausedAt) = (s.endTime, s.pausedAt);
        if (pausedAt != 0 && block.timestamp > pausedAt + MAX_PAUSE) {
            (endTime, pausedAt) = (uint64(_resumedEnd(s, MAX_PAUSE)), 0);
        }
    }

    /// @dev The end after a pause of `length` seconds: the remaining time at the pause, but at
    ///      least `max(duration, extensionWindow)` from the resumption.
    function _resumedEnd(Sale storage s, uint256 length) private view returns (uint256) {
        uint256 pausedAt = s.pausedAt;
        Settings storage st = _settings;
        uint256 reopening = Math.max(st.duration, st.extensionWindow);
        return pausedAt + length + Math.max(s.endTime - pausedAt, reopening);
    }

    /// @dev Whether the Independent Stream module the directory names now still serves the
    ///      Independent Stream `token` (`IIndependentStreamRegistry.isActive`); false while the
    ///      INDEPENDENT_STREAM slot is empty.
    function _served(address token) private view returns (bool) {
        address gate = directory.moduleOf(Slots.INDEPENDENT_STREAM);
        return gate != address(0) && IIndependentStreamRegistry(gate).isActive(token);
    }

    /// @dev The token's recipient: the stored one, or the bidder.
    function _recipientOf(Sale storage s) private view returns (address) {
        return s.recipientSet ? s.recipient : s.bidder;
    }

    function _setStreamPolicy(address next) private {
        if (next != address(0)) Dependency.check(next, type(IMintPolicy).interfaceId);
        emit StreamPolicySet(streamPolicy, next);
        streamPolicy = next;
    }

    function _setConfig(AuctionConfig memory next) private {
        Settings storage st = _settings;
        uint256 gasNow = st.refusalGas;
        uint256 gasNext = next.refusalGas;
        if (
            next.duration < MIN_DURATION || next.duration > MAX_DURATION
                || next.extensionWindow < MIN_EXTENSION_WINDOW
                || next.extensionWindow > MAX_EXTENSION_WINDOW
                || next.extensionWindow > next.duration || next.incrementShare < MIN_INCREMENT_SHARE
                || next.incrementShare > DENOMINATOR || gasNext < MIN_REFUSAL_GAS
                || gasNext > MAX_REFUSAL_GAS || gasNext < gasNow
                || (gasNow != 0 && gasNext > gasNow << 1)
        ) revert InvalidConfig();
        emit ConfigSet(config(), next);
        (st.duration, st.extensionWindow, st.incrementShare, st.refusalGas) =
        (next.duration, next.extensionWindow, next.incrementShare, next.refusalGas);
    }
}
