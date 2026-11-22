// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEconomicsResolver } from "./IEconomicsResolver.sol";

/// @title IEnglishAuction
/// @notice The network's English auction for 1/1 works: 6529 Stream's primary sale, and the sale
///         of federated artists' works. ETH only.
/// @dev Starting is permissionless: the start asks the token's mint policy to admit the item
///      (`IMintPolicy.authorize`), mints the work into this auction's custody (`IStream.mint`)
///      and starts the clock. The policy is the package registry for 6529 Stream (governed,
///      `streamPolicy`) and the federation module of the directory for any other token. A sale
///      keeps the seller and the network's fee share the policy answered at its start. Sale IDs
///      are derived: `saleIdOf(token, tokenId)`.
///
///      Bidding: the first bid must reach the opening bid (`AssetAllowlist.openingBid(ETH)`,
///      read when the bid is placed), a withdrawn bid's reserve, and 1 wei; later bids must
///      reach the high bid plus `max(incrementShare of it, rounded up; the ETH increment floor)`.
///      A bid in the last `extensionWindow` seconds moves the end to `extensionWindow` seconds
///      after it. Outbid bidders are credited (pull, `claim`).
///
///      Settlement is permissionless after the end. A sold work: the outcome is recorded in the
///      token (`IStream.recordPrimarySale`), the seller and the network are paid (a wallet that
///      refuses is paid through the revenue escrow), and the work is delivered; a recipient that
///      cannot take it leaves a pending delivery (`claimDelivery`). An unsold 6529 Stream work is
///      recorded UNSOLD and sent to the 6529 Network Museum (`IEconomicsResolver.museum()`, read
///      then). An unsold federated work stays in this auction's custody with no outcome, and
///      anyone may offer it again here (`restart`); its artist cannot take it out without a sale.
///      A federated sale is closed with refunds only when its token is no longer served by the
///      federation module (delisted, or its version revoked); removing this auction as a sale
///      contract or suspending a version lets running sales finish and unsold works be offered
///      again here, since the token lets the account that minted a work record its sale for good.
///      A work the network rescued (`IStream.rescue`, outcome RESCUED) closes its sale with the
///      standing bid credited back.
///
///      Disputes: the network may pause a live auction once, for at most 3 days (`MAX_PAUSE`);
///      the high bidder may withdraw while it is paused; the network may cancel it (an upheld
///      dispute: the bid is credited back and the token burned) or resume it; with no call
///      within the 3 days it resumes by itself.
///
///      Money: the seller receives `floor(price * (100,000 - feeShare) / 100,000)` and the
///      network the rest, paid to the 6529 Stream (or federated) fee recipient the economics
///      resolver names at settlement. Credits age: a credit's money that has itself waited the
///      directory's `unclaimedPeriod` may be sent to the network's fee recipient by anyone
///      (`expireCredit`); money credited later starts its own wait, and nobody can shorten or
///      postpone a clock.
interface IEnglishAuction {
    /// @notice An auction's lifecycle. ENDED is derived: ACTIVE with the end passed. PAUSED is
    ///         derived while a dispute pause is live.
    enum AuctionState {
        NONE,
        ACTIVE,
        PAUSED,
        ENDED,
        SETTLED,
        CANCELLED
    }

    /// @notice Governed auction parameters.
    /// @param duration Seconds from start to end.
    /// @param extensionWindow The anti-snipe window and extension, in seconds.
    /// @param incrementShare The minimum relative increment, out of 100,000.
    /// @param refusalGas The gas a federated settlement attempt is given, and must be given in
    ///        full, for its failure to count as the token's refusal: raise-only, at most doubled
    ///        per step.
    struct AuctionConfig {
        uint32 duration;
        uint32 extensionWindow;
        uint32 incrementShare;
        uint32 refusalGas;
    }

    /// @notice One auction, with its derived state.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param seller The wallet the artist side is paid to.
    /// @param feeShare The network's share, out of 100,000.
    /// @param bidder The high bidder, or zero.
    /// @param recipient Who receives the token if the high bid wins.
    /// @param bid The high bid in wei; with no bidder, the reserve a withdrawn bid left, or zero.
    /// @param endTime The end, in Unix seconds (for a pause past `MAX_PAUSE`, the end it resumes
    ///        to).
    /// @param pausedAt When the live dispute pause began, or zero.
    /// @param state The derived state.
    struct Auction {
        address token;
        uint256 tokenId;
        address seller;
        uint256 feeShare;
        address bidder;
        address recipient;
        uint256 bid;
        uint64 endTime;
        uint64 pausedAt;
        AuctionState state;
    }

    /// @notice A sale started (also when an unsold federated work is offered again).
    /// @param saleId The sale ID.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param saleKind `SaleKind.ENGLISH_AUCTION`.
    /// @param currency Always zero (ETH).
    /// @param price The opening bid when the sale started.
    /// @param startTime When it started.
    /// @param endTime Its first end.
    event SaleStarted(
        uint256 indexed saleId,
        address indexed token,
        uint256 indexed tokenId,
        bytes32 saleKind,
        address currency,
        uint256 price,
        uint64 startTime,
        uint64 endTime
    );
    /// @notice A sale settled.
    /// @param saleId The sale ID.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param buyer The winning bidder, or zero when no bid won.
    /// @param recipient Who receives the work: the winner's recipient, the museum for an
    ///        unsold 6529 Stream work, or this auction for an unsold federated work.
    /// @param quantity Always 1.
    /// @param currency Always zero (ETH).
    /// @param price The price, `sellerProceeds + fee`.
    /// @param seller The seller wallet.
    /// @param sellerProceeds The seller's part.
    /// @param feeRecipient The network fee recipient, or zero when nothing was paid.
    /// @param fee The network's part, rounded so the seller's part rounds down.
    event SaleSettled(
        uint256 indexed saleId,
        address indexed token,
        uint256 indexed tokenId,
        address buyer,
        address recipient,
        uint256 quantity,
        address currency,
        uint256 price,
        address seller,
        uint256 sellerProceeds,
        address feeRecipient,
        uint256 fee
    );
    /// @notice ETH was credited to `account`: an outbid bid, a withdrawn bid, or a standing bid
    ///         refunded by a cancel, a rescue, a delisting or a refused settlement.
    /// @param account The account.
    /// @param currency Always zero (ETH).
    /// @param saleId The sale.
    /// @param amount The amount in wei.
    event Credited(
        address indexed account, address indexed currency, uint256 indexed saleId, uint256 amount
    );
    /// @notice Credits were paid out: by their account to `to`, or expired to the network.
    /// @param account The credited account.
    /// @param currency Always zero (ETH).
    /// @param to Where the ETH went.
    /// @param amount The amount in wei.
    event Claimed(
        address indexed account, address indexed currency, address indexed to, uint256 amount
    );
    /// @notice A bid was placed; `endTime` includes any extension.
    /// @param saleId The sale.
    /// @param bidder The payer, credited back if outbid.
    /// @param recipient Who receives the token if this bid wins.
    /// @param amount The bid in wei.
    /// @param endTime The end after this bid.
    event BidPlaced(
        uint256 indexed saleId,
        address indexed bidder,
        address recipient,
        uint256 amount,
        uint64 endTime
    );
    /// @notice The network paused an auction for a dispute.
    /// @param saleId The sale.
    /// @param disputeRef The dispute reference passed; not checked.
    event AuctionPaused(uint256 indexed saleId, bytes32 disputeRef);
    /// @notice A paused auction resumed and now ends at `endTime`.
    /// @param saleId The sale.
    /// @param endTime The new end.
    event AuctionResumed(uint256 indexed saleId, uint64 endTime);
    /// @notice An upheld dispute cancelled an auction: the bid was credited back and the token
    ///         burned.
    /// @param saleId The sale.
    /// @param outcomeRef The statement-log entry the cancel cited.
    event AuctionCancelled(uint256 indexed saleId, bytes32 outcomeRef);
    /// @notice The high bidder withdrew its bid while the auction was paused.
    /// @param saleId The sale.
    /// @param bidder The bidder.
    /// @param amount The bid, credited back.
    event BidWithdrawn(uint256 indexed saleId, address indexed bidder, uint256 amount);
    /// @notice Delivery to `recipient` failed at settlement; the token waits for a claim.
    /// @param saleId The sale.
    /// @param recipient The winning bid's recipient.
    event DeliveryPending(uint256 indexed saleId, address indexed recipient);
    /// @notice A pending token was claimed.
    /// @param saleId The sale.
    /// @param recipient The recipient the token was pending for.
    /// @param to Where it was sent.
    event DeliveryClaimed(uint256 indexed saleId, address indexed recipient, address to);
    /// @notice The sale of a work the network rescued ended: nothing was recorded, paid or
    ///         delivered, and the standing bid, if any, was credited back.
    /// @param saleId The sale.
    event RescuedSaleClosed(uint256 indexed saleId);
    /// @notice The governed parameters changed.
    /// @param previous The parameters before (all zero in the constructor).
    /// @param next The parameters now.
    event ConfigSet(AuctionConfig previous, AuctionConfig next);
    /// @notice The mint policy of 6529 Stream changed.
    /// @param previous The policy before.
    /// @param next The policy now (zero: no 6529 Stream starts).
    event StreamPolicySet(address previous, address next);
    /// @notice New starts were paused.
    /// @param account The caller.
    event Paused(address account);
    /// @notice New starts were unpaused.
    /// @param account The caller.
    event Unpaused(address account);

    /// @notice The auction is not in a state that allows this action.
    error InvalidAuctionState(uint256 saleId, AuctionState state);
    /// @notice No sale has this ID.
    error UnknownSale(uint256 saleId);
    /// @notice The bid is below `minimumBid`, or above `type(uint96).max`.
    error BidTooLow(uint256 required, uint256 offered);
    /// @notice The auction's one dispute pause was already used.
    error PauseExhausted(uint256 saleId);
    /// @notice `outcomeRef` is not the token's latest DISPUTE_OUTCOME, recorded after the pause.
    error OutcomeNotRecorded(uint256 saleId, bytes32 outcomeRef);
    /// @notice Nothing is pending delivery for the caller.
    error NoPendingDelivery(uint256 saleId);
    /// @notice A configuration is outside the bounds `setConfig` documents.
    error InvalidConfig();
    /// @notice A token arrived other than by this auction's own mint during a start.
    error InvalidTarget(address token);
    /// @notice The caller is not the high bidder.
    error NotHighBidder(address caller);
    /// @notice The caller cannot forward the delivery allowance in full.
    error DeliveryInsufficientGas();
    /// @notice The token has no mint policy here, or the work is no longer offered by it.
    error TargetNotAllowed(address token);
    /// @notice The policy answered terms this auction cannot sell by.
    error InvalidSaleTerms(address token, uint256 tokenId);
    /// @notice The address cannot receive the token or the credit.
    error InvalidRecipient(address recipient);
    /// @notice The account has no credit.
    error NothingToClaim(address account);
    /// @notice An ETH claim could not be delivered to `to`; the credit is kept.
    error ClaimFailed(address to);
    /// @notice No money of the credit has waited the unclaimed period yet.
    error CreditNotExpired(address account, uint256 expiresAt);
    /// @notice New starts are paused, or `pause` was called while paused.
    error SalePaused();
    /// @notice `unpause` was called while not paused.
    error NotPaused();
    /// @notice A compare-and-set setter's expected value is stale.
    error ExpectedValueMismatch();
    /// @notice The bid's value does not match `msg.value`.
    error InvalidPayment();

    /// @notice Admits an item through the token's mint policy, mints it into this auction's
    ///         custody and opens its auction. Permissionless. Refused while starts are paused.
    /// @param token The token contract.
    /// @param request The policy's request (for 6529 Stream, `abi.encode(StreamMintRequest)`).
    /// @return saleId `saleIdOf(token, tokenId)`.
    function start(address token, bytes calldata request) external returns (uint256 saleId);

    /// @notice `start` plus a first bid of `msg.value` by the caller.
    /// @param token The token contract.
    /// @param request The policy's request.
    /// @param recipient Who receives the token if the bid wins, or zero for the caller.
    /// @return saleId The sale ID.
    function startWithBid(address token, bytes calldata request, address recipient)
        external
        payable
        returns (uint256 saleId);

    /// @notice Offers an unsold federated work in this auction's custody again, with the seller
    ///         its first start locked and the network's share in force now for the token
    ///         (`IFederationGate.feeShareOf`). Permissionless, while starts are not paused and the
    ///         federation module still serves the token, whether or not this auction may still
    ///         mint new works.
    /// @param saleId A settled sale of a federated work still in custody with no outcome.
    function restart(uint256 saleId) external;

    /// @notice Bids `msg.value` for `recipient` (the caller when zero).
    /// @param saleId The sale.
    /// @param recipient Who receives the token if the bid wins, or zero for the caller.
    function bid(uint256 saleId, address recipient) external payable;

    /// @notice The high bidder withdraws while the auction is paused for a dispute; its bid is
    ///         credited back and stays as a reserve the next bid must reach.
    /// @param saleId The sale.
    function withdrawBid(uint256 saleId) external;

    /// @notice Settles an ended auction. Permissionless.
    /// @param saleId The sale.
    function settle(uint256 saleId) external;

    /// @notice Delivers a pending token to `to`. The winning bidder names any `to` at any time;
    ///         the recipient it named claims to itself at any time, and to another address only
    ///         from 14 days after the auction's end.
    /// @param saleId The sale.
    /// @param to Where the token goes: neither zero nor this auction.
    function claimDelivery(uint256 saleId, address to) external;

    /// @notice Sends all of the caller's credit to `to`.
    /// @param to Where the ETH goes; not zero.
    /// @return amount The amount sent.
    function claim(address to) external returns (uint256 amount);

    /// @notice Sends the part of `account`'s credit that has itself waited the unclaimed period
    ///         (`IDirectory.unclaimedPeriod`, read now) to the network's fee recipient.
    ///         Permissionless. The rest of the credit then starts a new wait.
    /// @param account The credited account.
    /// @return amount The amount sent.
    function expireCredit(address account) external returns (uint256 amount);

    /// @notice Pauses a live auction for a dispute, once, for at most 3 days. Governed.
    /// @param saleId The sale.
    /// @param disputeRef A reference to the dispute, emitted; not checked.
    function pause(uint256 saleId, bytes32 disputeRef) external;

    /// @notice Resumes a paused auction for its remaining time or the governed duration,
    ///         whichever is longer (the anti-snipe window if longer still). Governed.
    /// @param saleId The sale.
    function resume(uint256 saleId) external;

    /// @notice Cancels a paused auction after an upheld dispute: credits the high bid back and
    ///         burns the token. Governed. `outcomeRef` must be the token's own latest dispute
    ///         outcome in the statement log, recorded after the pause.
    /// @param saleId The sale.
    /// @param outcomeRef The statement-log entry hash.
    function cancel(uint256 saleId, bytes32 outcomeRef) external;

    /// @notice Stops new starts and restarts. Bids, settlements and claims continue. Governed.
    function pause() external;

    /// @notice Lifts the start pause. Governed.
    function unpause() external;

    /// @notice Sets the auction parameters within the bounds: a duration of 1 hour to 7 days,
    ///         an anti-snipe window of 1 minute to 1 day and at most the duration, an increment
    ///         share of 1,000 to 100,000, and a refusal gas kept or raised, at most doubled,
    ///         between 3,000,000 and 15,000,000. Governed, compare-and-set.
    /// @param expected The parameters the caller expects now.
    /// @param next The new parameters.
    function setConfig(AuctionConfig calldata expected, AuctionConfig calldata next) external;

    /// @notice Sets 6529 Stream's mint policy. Governed, compare-and-set. A nonzero policy must
    ///         support `IMintPolicy` (ERC-165).
    /// @param expected The policy the caller expects now.
    /// @param next The new policy, or zero to stop 6529 Stream starts.
    function setStreamPolicy(address expected, address next) external;

    /// @notice The derived sale ID: `uint256(keccak256(abi.encode(token, tokenId)))`.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @return The sale ID.
    function saleIdOf(address token, uint256 tokenId) external pure returns (uint256);

    /// @notice The economics resolver: the museum, the fee recipients, the split factory.
    /// @return The resolver.
    function economics() external view returns (IEconomicsResolver);

    /// @notice The mint policy a token's works are admitted by here: `streamPolicy` for 6529
    ///         Stream, the directory's federation module for any other token.
    /// @param token The token contract.
    /// @return The policy, or zero.
    function policyOf(address token) external view returns (address);

    /// @notice An auction. Reverts for an unknown sale.
    /// @param saleId The sale.
    /// @return The auction.
    function auction(uint256 saleId) external view returns (Auction memory);

    /// @notice The smallest bid accepted now.
    /// @param saleId The sale.
    /// @return The amount in wei.
    function minimumBid(uint256 saleId) external view returns (uint256);

    /// @notice The recipient whose delivery is pending, or zero.
    /// @param saleId The sale.
    /// @return The recipient.
    function pendingDelivery(uint256 saleId) external view returns (address);

    /// @notice What `account` may claim.
    /// @param account The account.
    /// @return The credit in wei.
    function claimable(address account) external view returns (uint256);

    /// @notice When the aged part of `account`'s credit may expire, or zero with no credit.
    /// @param account The account.
    /// @return The time.
    function expiresAt(address account) external view returns (uint256);

    /// @notice The governed parameters.
    /// @return The configuration.
    function config() external view returns (AuctionConfig memory);

    /// @notice Whether new starts are paused.
    /// @return True while paused.
    function paused() external view returns (bool);
}
