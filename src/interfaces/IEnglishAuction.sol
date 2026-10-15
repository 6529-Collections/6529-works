// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISaleAdapter } from "./ISaleAdapter.sol";
import { LockedTerms, Payment } from "./types/SaleTypes.sol";

/// @title IEnglishAuction
/// @notice The shared English auction: 6529 Stream's only primary sale (ADR 0001 sections 5 and
///         12).
/// @dev Starting is permissionless: anyone submits the start, which mints the token into this
///      adapter's custody through `IMintTarget.mint` and starts the clock. A VRF work's seed is
///      requested beforehand (`IEntropyModule.requestSeed`), so the start never waits on
///      randomness and nothing is ever in custody without a clock. The start never deploys a
///      split wallet. Sale IDs are derived: `saleIdOf(token, tokenId)`. Per sale the adapter
///      keeps at most three storage words (one from the start, one more from the first bid, and
///      a third only for a recipient other than the bidder or a dispute pause); the seller and
///      fee terms are read back from the token (`IMintTarget.primaryTerms`) at settlement.
///
///      Bidding: the start locks the currency, its opening bid (`openingBid(currency)` then),
///      the increment share and the anti-snipe window. The first bid must be at least the
///      locked opening bid, a withdrawn bid's reserve (`withdrawBid`), and 1; later bids must
///      reach the high bid plus `max(the increment share of it, rounded up; the currency's
///      increment floor)`, the floor read from the asset allowlist and locked at the first bid.
///      A bid in the last `extensionWindow` seconds moves the end to `extensionWindow` seconds
///      after it. Outbid bidders are credited (pull). Settlement is permissionless after the end
///      and never depends on the winner accepting the token: a failed delivery leaves a pending
///      claim. With no bids the token goes to the artist's active authority, resolved at
///      settlement; while a recovery override is pending there is none, and settlement waits
///      for its outcome.
///
///      Disputes: the guardian may pause a live auction once, for at most 7 days (`MAX_PAUSE`);
///      bidders may withdraw while it is paused; an upheld dispute cancels it, refunds the bid
///      and burns the token; a rejected dispute, or no outcome within the 7 days, resumes it.
///      `saleKind()` is `SaleKind.ENGLISH_AUCTION`. PERMIT2 bids use the `Typehashes.BID_WITNESS`
///      and `Typehashes.START_BID_WITNESS` witnesses.
interface IEnglishAuction is ISaleAdapter {
    /// @notice An auction's lifecycle. ENDED is derived: ACTIVE with the end passed.
    enum AuctionState {
        NONE,
        ACTIVE,
        PAUSED,
        ENDED,
        SETTLED,
        CANCELLED
    }

    /// @notice Governed auction parameters (ADR 0001 section 5).
    /// @param duration Seconds from start to end (24 hours at launch).
    /// @param extensionWindow The anti-snipe window and extension, in seconds.
    /// @param incrementShare The minimum relative increment, out of 100,000 (5,000 at launch).
    struct AuctionConfig {
        uint32 duration;
        uint32 extensionWindow;
        uint32 incrementShare;
    }

    /// @notice One auction, as stored; `currency` is locked at start and `incrementFloor` at the
    ///         first bid (zero before).
    /// @param bidder The high bidder (the payer of the high bid), or zero.
    /// @param recipient Who receives the token if the high bid wins.
    /// @param bid The high bid; with no bidder, the reserve a withdrawn (or refunded) bid left,
    ///        which the next bid must reach, or zero. A settled or cancelled sale keeps the last
    ///        amount here even when no bid won: read `bidder` (and the `SaleSettled` price).
    /// @param pausedAt When the current pause began, or zero.
    /// @param pausedTotal Seconds paused so far, at most 7 days.
    struct Auction {
        address token;
        uint256 tokenId;
        address currency;
        uint256 incrementFloor;
        address bidder;
        address recipient;
        uint256 bid;
        uint64 endTime;
        uint64 pausedAt;
        uint64 pausedTotal;
        AuctionState state;
    }

    /// @notice A bid was placed; `endTime` includes any anti-snipe extension.
    event BidPlaced(
        uint256 indexed saleId,
        address indexed bidder,
        address recipient,
        uint256 amount,
        uint64 endTime
    );
    /// @notice The guardian paused an auction for a dispute.
    event AuctionPaused(uint256 indexed saleId, bytes32 disputeRef);
    /// @notice A halted auction resumed and ends at `endTime`: after a dispute pause, its
    ///         remaining time at the pause, the governed duration or the sale's anti-snipe window,
    ///         whichever is longest; reopened after a currency freeze, the governed duration or
    ///         the anti-snipe window, whichever is longer.
    /// @param saleId The auction's sale ID.
    /// @param endTime The new end, in Unix seconds.
    event AuctionResumed(uint256 indexed saleId, uint64 endTime);
    /// @notice An upheld dispute cancelled an auction: the bid was refunded, the token burned.
    event AuctionCancelled(uint256 indexed saleId, bytes32 outcomeRef);
    /// @notice The high bidder withdrew its bid while the auction was paused, or while its
    ///         currency was deprecated before settlement.
    /// @param saleId The auction's sale ID.
    /// @param bidder The high bidder that withdrew.
    /// @param amount The withdrawn bid, credited back to the bidder, in base units.
    event BidWithdrawn(uint256 indexed saleId, address indexed bidder, uint256 amount);
    /// @notice Delivery to `recipient` failed at settlement; it may claim the token.
    event DeliveryPending(uint256 indexed saleId, address indexed recipient);
    /// @notice A pending token was claimed.
    event DeliveryClaimed(uint256 indexed saleId, address indexed recipient, address to);
    /// @notice The governed auction parameters changed.
    event ConfigSet(AuctionConfig previous, AuctionConfig next);
    /// @notice A currency's opening bid changed.
    event OpeningBidSet(address indexed currency, uint256 previous, uint256 next);

    /// @notice The auction is not in a state that allows this action.
    error InvalidAuctionState(uint256 saleId, AuctionState state);
    /// @notice The bid is below `minimumBid`.
    error BidTooLow(uint256 required, uint256 offered);
    /// @notice The auction's one dispute pause was already used.
    error PauseExhausted(uint256 saleId);
    /// @notice `outcomeRef` is not the token's latest DISPUTE_OUTCOME statement.
    error OutcomeNotRecorded(uint256 saleId, bytes32 outcomeRef);
    /// @notice Nothing is pending delivery for the caller.
    error NoPendingDelivery(uint256 saleId);
    /// @notice An auction configuration is outside the bounds `setConfig` documents.
    error InvalidConfig();
    /// @notice A token arrived other than by this adapter's own mint during a start: the
    ///         ERC-721 receiver hook refuses every other safe transfer.
    error InvalidTarget(address token);
    /// @notice The caller is not the high bidder.
    error NotHighBidder(address caller);
    /// @notice The opening bid is above its absolute ceiling.
    error OpeningBidAboveCeiling(uint256 next, uint256 ceiling);
    /// @notice The caller cannot forward the 300,000-gas delivery allowance (`DELIVERY_GAS`) in
    ///         full.
    error DeliveryInsufficientGas();

    /// @notice Mints a work into custody and opens its auction. Permissionless.
    /// @param token A served token contract.
    /// @param mintData The token-specific mint request (for 6529 Stream,
    ///        `abi.encode(StreamMintRequest)`).
    /// @return saleId `saleIdOf(token, tokenId)`.
    function start(address token, bytes calldata mintData) external returns (uint256 saleId);
    /// @notice `start` plus a first bid in one transaction. The bid is at most
    ///         `type(uint96).max` base units (about 7.9e28), like every bid.
    function startWithBid(
        address token,
        bytes calldata mintData,
        address recipient,
        Payment calldata payment
    ) external payable returns (uint256 saleId);
    /// @notice Bids `payment.amount` for `recipient` (the payer when zero). A bid is at most
    ///         `type(uint96).max` base units (about 7.9e28); a larger one reverts.
    function bid(uint256 saleId, address recipient, Payment calldata payment) external payable;
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
    ///         credited back and the work goes to the artist (MARKET-2). A sale of a federated
    ///         contract the registry has since delisted settles the same way (MARKET-5).
    /// @param saleId The ended auction's sale ID.
    function settle(uint256 saleId) external;
    /// @notice The winner whose delivery is pending names the recipient `to` and receives the
    ///         token there.
    function claimDelivery(uint256 saleId, address to) external;
    /// @notice Sends all of `account`'s credits in ERC-20 `currency` to `account` itself.
    ///         Permissionless: a seller split wallet or fee wallet whose ERC-20 payout failed at
    ///         settlement and was credited here (MONEY-1) cannot call `claim`. The funds only ever
    ///         go to `account`; a transfer that fails reverts and keeps the credit. ETH is refused
    ///         (`IRevenueEscrow.InvalidAsset`): ETH credits are bidders' refunds, which only the
    ///         bidder claims, to the address it chooses.
    function claimFor(address account, address currency) external returns (uint256 amount);

    /// @notice Pauses a live auction for a dispute, once per auction. GUARDIAN role (immediate).
    /// @param saleId The live auction's sale ID.
    /// @param disputeRef A reference to the dispute, emitted in `AuctionPaused`; not checked.
    function pause(uint256 saleId, bytes32 disputeRef) external;
    /// @notice Resumes a paused auction after a rejected dispute, for its remaining time or the
    ///         governed duration, whichever is longer (the anti-snipe window if longer still),
    ///         even with a standing bid. UNPAUSER role (pause and unpause have separate holders).
    ///         Refused until 48 hours (`Roles.STANDARD`) after the pause, so the guardians can
    ///         always cancel a resume, even one scheduled before the pause. A pause also ends by
    ///         itself 7 days (`MAX_PAUSE`) after it began, without any call.
    /// @param saleId The paused auction's sale ID.
    function resume(uint256 saleId) external;
    /// @notice Cancels a paused auction after an upheld dispute: credits the high bid back and
    ///         burns the token. PARAMETER_SETTER role, while paused, and like `resume` no earlier
    ///         than 48 hours after the pause (`UnpauseTooEarly`), and no later than
    ///         `pausedAt + MAX_PAUSE` inclusive. `outcomeRef` must be nonzero and be the token's
    ///         own latest outcome, `IStatementLog.disputeOutcomeOf(token, tokenId)` (no item
    ///         fallback), recorded after the pause: an outcome recorded before the pause, or one
    ///         about the package item, cannot cancel.
    function cancel(uint256 saleId, bytes32 outcomeRef) external;
    /// @notice The high bidder withdraws its bid while the auction is paused, or while its
    ///         currency is deprecated and it has not settled (MARKET-2); it is credited back
    ///         and the auction has no bid. The withdrawn amount stays as a reserve the next bid
    ///         must reach, and the resumed auction runs at least the governed duration, so the
    ///         refunded bidders can return (LIFECYCLE-1).
    function withdrawBid(uint256 saleId) external;

    /// @notice Sets the auction parameters, within the implementation's bounds: a duration of 1
    ///         hour to 7 days, an anti-snipe window of 1 minute to 1 day and at most the
    ///         duration, and an increment share of 1,000 to 100,000 (1% to 100%).
    ///         PARAMETER_SETTER role, compare-and-set.
    function setConfig(AuctionConfig calldata expected, AuctionConfig calldata next) external;
    /// @notice Sets a currency's opening bid, raising or lowering it up to the implementation's
    ///         ceiling (zero at launch; the first bid is still at least 1). PARAMETER_SETTER role,
    ///         compare-and-set.
    function setOpeningBid(address currency, uint256 expected, uint256 next) external;

    /// @notice The derived sale ID: `uint256(keccak256(abi.encode(token, tokenId)))`.
    function saleIdOf(address token, uint256 tokenId) external pure returns (uint256);
    /// @notice An auction. Reverts for an unknown sale ID.
    function auction(uint256 saleId) external view returns (Auction memory);
    /// @notice A sale's locked terms: token, token ID and currency from the auction, seller and
    ///         fee terms read back from the token.
    function lockedTerms(uint256 saleId) external view returns (LockedTerms memory);
    /// @notice The smallest bid accepted now.
    function minimumBid(uint256 saleId) external view returns (uint256);
    /// @notice The governed auction parameters.
    function config() external view returns (AuctionConfig memory);
    /// @notice A currency's opening bid.
    function openingBid(address currency) external view returns (uint256);
    /// @notice The recipient whose delivery is pending, or zero.
    function pendingDelivery(uint256 saleId) external view returns (address);
    /// @notice The revenue escrow that receives failed payouts (immutable).
    function escrow() external view returns (address);
    /// @notice The statement log whose DISPUTE_OUTCOME entries `cancel` cites (immutable).
    function statementLog() external view returns (address);
}
