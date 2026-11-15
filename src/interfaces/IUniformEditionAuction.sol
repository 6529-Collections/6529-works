// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEnglishAuction } from "./IEnglishAuction.sol";
import { ISaleAdapter } from "./ISaleAdapter.sol";

/// @title IUniformEditionAuction
/// @notice The uniform-price edition auction: how 6529 Stream Editions sells an edition (ADR
///         0005; 6529chain D138-D141). One auction per edition decides both how many copies
///         exist and their one price, so the number is never fixed in advance and nothing is
///         left unsold. It runs alongside the edition master's 1/1 English auction and closes a
///         close offset after the 1/1 finally closes: the artist's own, signed in the edition
///         terms, or else the governed default (15 minutes at launch). Anyone bids a quantity at a price
///         step; bids are public, fully escrowed in ETH, and can be raised but not lowered or
///         withdrawn (except while the 1/1 is paused for a dispute). At the close, revenue(k) is
///         k times the k-th highest unit bid; the result is the largest k whose revenue is at
///         least (100% - margin) of the highest, at most the creator's optional cap. Every winner
///         pays the lowest winning step's price, every other unit is refunded in full, and
///         exactly k copies are minted, as winners claim. The network fee (25% at launch) is the
///         share the edition's economics locked at open.
/// @dev Sales are keyed like the English auction's: `saleId = saleIdOf(token, id)`, the edition
///      contract and edition ID (for 6529 Stream Editions, the master's 6529 Stream token ID), so
///      one adapter can serve every listed token and, from v1.1, federated linked pairs. The
///      adapter is one admitted minter among any others governance admits (owner decision 14):
///      nothing in the tokens makes it the only one. `saleKind()` is `SaleKind.UNIFORM_AUCTION`.
///
///      Ladder. Steps are 0-based indices into `StepLadder`'s prices under the sale's locked
///      `AuctionConfig`. A step's live units are the units of the bids sitting on it now.
///
///      Timing (D140, D141). `open` is permissionless from the 1/1 auction's start (the keeper
///      batches it with the start) until the edition close. The 1/1 is the English auction sale
///      `IEnglishAuction.saleIdOf(master, id)`, where `master` is the token's
///      `IEditions.stream()`. Bids are accepted while `block.timestamp < endTime`, where
///      `closeAt` is the 1/1's current `endTime` (anti-snipe extensions and resumptions
///      included) plus the sale's close offset, locked at open, and
///      `endTime = max(closeAt, softEnd)`. A bid or raise
///      strictly inside the last `softWindow` (`block.timestamp + softWindow > endTime`; one
///      exactly `softWindow` before the end does not extend) sets `softEnd =
///      min(block.timestamp + softWindow, backstop)` with `backstop = closeAt + maxExtension`,
///      a hard close. While the 1/1 is PAUSED for a dispute, bids and raises are accepted
///      whatever the time and do not move `softEnd`; a resumed 1/1 runs at least its governed
///      duration, and the edition close follows it. During the pause a bid may be withdrawn
///      only if it was placed (or last raised) in a minute, counted from the sale's open, that
///      ended before the pause began (decision 12, as amended 1 November 2026): demand added
///      during a pause is as firm as any other, so a pause cannot be used to spoof it. A CANCELLED 1/1 voids the sale: nothing is minted or paid, and every bid
///      is refunded in full. A bid reads the 1/1 live only within `softWindow` of the close (or
///      later), so a bid placed earlier, after the cancel but before the sale is voided, can
///      still be accepted; it is refunded in full with every other, and `EndTimes.biddingOpen`
///      (read live) is already false. Any `settle` call voids the sale at once. Editions sell
///      whether or not the 1/1 drew bids; no edition bids means no copies.
///
///      Clearing (D138). Scanning used steps from the top, step s is a candidate of
///      `k_s = min(D_s, cap)` copies at `price(s)`, `D_s` being the live units at or above s;
///      the scan stops once the units strictly above a step reach the cap. `bestRevenue` (R*)
///      is the highest candidate revenue; the result is the lowest-priced candidate with
///      `revenue * 100,000 >= bestRevenue * (100,000 - marginShare)`. This equals the per-unit
///      definition (golden vectors in `test/fixtures/edition-auction/clearing.json`).
///
///      The cut step (owner decision 1). Without a cap no step is split. When a cap binds
///      inside the clearing step, its units fill in arrival order (price-time priority): a bid's
///      `position` there is the step's entered units before it, counted in units that only
///      increase; a raise rejoins at the back of its new step; a raise out of a step, or a
///      dispute withdrawal, leaves a departure (its old position and quantity) in that step's
///      log. Settlement starts the cutoff at the units the step wins and sweeps the step's
///      departures in position order, adding each whose position is below the cutoff; a bid at
///      the step then wins `clamp(cutoff - position, 0, quantity)`, the marginal bid partly.
///      Positions and departures exist only when a cap is set.
interface IUniformEditionAuction is ISaleAdapter {
    /// @notice A sale's lifecycle. CLOSED is derived: OPEN with its end passed (it can reopen
    ///         if the 1/1's end moves later). SETTLING: settlement under way, in calls of bounded
    ///         gas: the book still being scanned, or cleared and paid with the departure sweep not
    ///         yet complete. SETTLED: claims are open. VOID: the 1/1 was cancelled, or the sale
    ///         was abandoned because its master could not be settled (`abandon`); claims refund.
    enum AuctionStatus {
        NONE,
        OPEN,
        CLOSED,
        SETTLING,
        SETTLED,
        VOID
    }

    /// @notice The governed parameters (D86), locked into each sale when it opens (ADR 0005). A
    ///         sale whose edition terms carry their own close offset locks a record of these
    ///         with that offset in `closeOffset`.
    /// @param basePrice The price of step 0, in wei (0.0001 ETH at launch).
    /// @param stepsPerDecade Steps per tenfold rise: 24, 48, 96 or 192 (48 at launch).
    /// @param stepCount Steps on the ladder (336 at launch, up to 953 ETH).
    /// @param marginShare The breadth margin, out of 100,000 (10,000 at launch): the result is
    ///        the largest count whose revenue is within this share of the best.
    /// @param closeOffset Seconds the edition close follows the 1/1's final end, for a sale whose
    ///        edition terms name none (15 minutes at launch); at most `Limits.maxCloseOffset`.
    /// @param softWindow The soft-close window and extension, in seconds (5 minutes).
    /// @param maxExtension The most the soft close may move the end past `closeAt`, in seconds
    ///        (24 hours).
    struct AuctionConfig {
        uint96 basePrice;
        uint16 stepsPerDecade;
        uint16 stepCount;
        uint32 marginShare;
        uint32 closeOffset;
        uint32 softWindow;
        uint32 maxExtension;
    }

    /// @notice The governed limits (ADR 0005 section 4, as amended 15 November 2026), set by
    ///         `setLimits`. Read at open (the close offset's maximum and the abandonment delay,
    ///         which the sale locks) and at payout (the payout gas). `setLimits` and `LimitsSet`
    ///         carry them packed in one word: `maxCloseOffset | voidDelayDays << 32 |
    ///         payoutGas << 48`, nothing past bit 80.
    /// @param maxCloseOffset The longest close offset an edition's terms may name, in seconds
    ///        (30 days at launch; bounds 1 day to 3,650 days). The only cap on an edition's open
    ///        period: a parameter of this adapter, not a rule of the token.
    /// @param voidDelayDays Whole days after a sale's end before it may be abandoned when its
    ///        master cannot be settled or its edition created (150 at launch; bounds 120 to
    ///        730), locked at open.
    /// @param payoutGas Gas forwarded with each settlement payout; a wallet that refuses, or
    ///        needs more, is paid in the revenue escrow instead (100,000 at launch; bounds 30,000
    ///        to 3,000,000).
    struct Limits {
        uint32 maxCloseOffset;
        uint16 voidDelayDays;
        uint32 payoutGas;
    }

    /// @notice One sale, as stored and derived now.
    /// @param token The edition contract (6529 Stream Editions).
    /// @param id The edition ID: the master's token ID on `master`.
    /// @param master The 1/1's token contract (`IEditions(token).stream()`).
    /// @param oneOfOneSaleId The 1/1's English auction sale ID.
    /// @param status The derived status.
    /// @param maxCount The creator's cap, locked at open; zero for none.
    /// @param terms The parameters locked at open, with the sale's own close offset.
    /// @param seller The artist-portion split wallet, locked at open.
    /// @param feeRecipient The network fee recipient, locked at open.
    /// @param feeShare The network share of revenue, out of 100,000, locked at open.
    /// @param openedAt When the sale opened.
    /// @param bidCount Bids placed so far; bid IDs run from 1 to `bidCount`.
    /// @param liveUnits Units of the bids live now.
    /// @param lowStep The lowest step any bid has used (zero with no bids).
    /// @param highStep The highest step any bid has used (zero with no bids).
    struct Auction {
        address token;
        uint256 id;
        address master;
        uint256 oneOfOneSaleId;
        AuctionStatus status;
        uint32 maxCount;
        AuctionConfig terms;
        address seller;
        address feeRecipient;
        uint32 feeShare;
        uint64 openedAt;
        uint32 bidCount;
        uint32 liveUnits;
        uint16 lowStep;
        uint16 highStep;
    }

    /// @notice A sale's clocks, read live from the 1/1.
    /// @param oneOfOneEnd The 1/1's end as the English auction reports it now.
    /// @param closeAt `oneOfOneEnd` plus the sale's close offset: the earliest it can close.
    /// @param softEnd The soft-close end, or zero before any bid in the window.
    /// @param endTime `max(closeAt, softEnd)`: bids are accepted before it.
    /// @param backstop `closeAt + maxExtension`: the soft close never moves past it.
    /// @param oneOfOneState The 1/1's state.
    /// @param biddingOpen Whether a bid would be accepted now.
    /// @param withdrawalsOpen Whether the 1/1 is paused, so that bids placed before the pause may
    ///        be withdrawn now (the lens's `canWithdraw` answers for one bid).
    struct EndTimes {
        uint64 oneOfOneEnd;
        uint64 closeAt;
        uint64 softEnd;
        uint64 endTime;
        uint64 backstop;
        IEnglishAuction.AuctionState oneOfOneState;
        bool biddingOpen;
        bool withdrawalsOpen;
    }

    /// @notice One bid, as stored; deleted when claimed or withdrawn.
    /// @param bidder Who placed it, and who claims it.
    /// @param step Its step; its escrow is `quantity * price(step)`.
    /// @param quantity Its units.
    /// @param position Units entered at its step before it (capped sales; zero otherwise).
    struct Bid {
        address bidder;
        uint16 step;
        uint32 quantity;
        uint32 position;
    }

    /// @notice A hole a bid left at a step of a capped sale, by a raise or a dispute withdrawal.
    /// @param position The bid's position at that step.
    /// @param quantity The bid's units.
    struct Departure {
        uint32 position;
        uint32 quantity;
    }

    /// @notice The clearing result of a book.
    /// @param count Copies sold: k.
    /// @param step The clearing step (meaningful when `count` is nonzero).
    /// @param price The clearing step's price, which every winner pays per copy; zero when
    ///        `count` is zero.
    /// @param revenue `count * price`.
    /// @param networkFee `revenue * feeShare / 100,000`, rounded down; the rest is the seller's.
    /// @param bestRevenue R*, the highest candidate revenue.
    /// @param rationed Whether the cap binds inside the clearing step.
    /// @param cutUnits The clearing step's winning units (all of them unless rationed).
    /// @param unitsAtStep The clearing step's live units.
    /// @param cutoff When rationed, the cutoff after the departure sweep; otherwise zero.
    struct Clearing {
        uint256 count;
        uint256 step;
        uint256 price;
        uint256 revenue;
        uint256 networkFee;
        uint256 bestRevenue;
        bool rationed;
        uint256 cutUnits;
        uint256 unitsAtStep;
        uint256 cutoff;
    }

    /// @notice A settlement's stored result and sweep progress.
    /// @param count Copies sold.
    /// @param step The clearing step.
    /// @param price The price every winner pays.
    /// @param rationed Whether the cap binds inside the clearing step.
    /// @param cutUnits The clearing step's winning units.
    /// @param cutoff `cutUnits` until a settler's sweep completes, then the final cutoff.
    /// @param departuresSwept Zero until a settler's sweep completes, then `departures`. A
    ///        settler's own progress is in its `DeparturesSwept` events.
    /// @param departures Departures logged at the clearing step (zero unless rationed).
    struct Settlement {
        uint256 count;
        uint256 step;
        uint256 price;
        bool rationed;
        uint256 cutUnits;
        uint256 cutoff;
        uint256 departuresSwept;
        uint256 departures;
    }

    /// @notice A bid's outcome: final once the sale is SETTLED or VOID, otherwise what it would
    ///         be if the sale closed now.
    /// @param unitsWon Copies the bid wins.
    /// @param price The price per copy it pays (the clearing price; zero if it wins none).
    /// @param escrow What it holds: `quantity * price(step)`.
    /// @param refund `escrow - unitsWon * price`.
    /// @param unitsAhead Live units ahead of it in its step's queue (capped sales; zero
    ///        otherwise).
    /// @param isFinal Whether the sale is SETTLED or VOID, so a claim pays exactly this.
    struct BidOutcome {
        uint256 unitsWon;
        uint256 price;
        uint256 escrow;
        uint256 refund;
        uint256 unitsAhead;
        bool isFinal;
    }

    /// @notice What a new bid would do if it were placed now and the sale then closed.
    /// @param unitsWon Copies the new bid would win (it joins the back of its step's queue).
    /// @param escrow What it would pay now: `quantity * price(step)`.
    /// @param unitsPushedOut Net existing winning units it would push out.
    /// @param unitsPulledIn Net existing units it would pull in (the breadth rule); at most one
    ///        of the two is nonzero.
    /// @param result The clearing with the new bid.
    struct Quote {
        uint256 unitsWon;
        uint256 escrow;
        uint256 unitsPushedOut;
        uint256 unitsPulledIn;
        Clearing result;
    }

    /// @notice A sale opened.
    /// @param saleId The sale ID.
    /// @param token The edition contract.
    /// @param id The edition ID.
    /// @param master The 1/1's token contract.
    /// @param maxCount The creator's cap; zero for none.
    /// @param terms The parameters it locked, with its own close offset in `closeOffset`.
    /// @param closeAt Its earliest close at opening: the 1/1's end then, plus its close offset.
    event AuctionOpened(
        uint256 indexed saleId,
        address indexed token,
        uint256 indexed id,
        address master,
        uint32 maxCount,
        AuctionConfig terms,
        uint64 closeAt
    );
    /// @notice A bid was placed.
    /// @param saleId The sale ID.
    /// @param bidId The new bid's ID, from 1 in each sale.
    /// @param bidder The bidder.
    /// @param step The bid's step.
    /// @param quantity Its units.
    /// @param position Its position at the step (capped sales; zero otherwise).
    /// @param endTime The sale's end after this bid, as the bid saw it: `type(uint64).max`
    ///        while the 1/1 is paused (no end), and stale if the 1/1's end moved since the
    ///        adapter last read it (it reads the 1/1 only near the close); `endTimes` reads it
    ///        live.
    event BidPlaced(
        uint256 indexed saleId,
        uint256 indexed bidId,
        address indexed bidder,
        uint256 step,
        uint256 quantity,
        uint256 position,
        uint64 endTime
    );
    /// @notice A bid moved up to a higher step, paying exactly the difference.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @param bidder The bidder.
    /// @param fromStep The step it left (a departure there in a capped sale).
    /// @param toStep The step it joined, at the back of its queue.
    /// @param position Its new position (capped sales; zero otherwise).
    /// @param paid The top-up, `quantity * (price(toStep) - price(fromStep))`, in wei.
    /// @param endTime The sale's end after this raise, as `BidPlaced.endTime`: `type(uint64).max`
    ///        while the 1/1 is paused, and possibly stale.
    event BidRaised(
        uint256 indexed saleId,
        uint256 indexed bidId,
        address indexed bidder,
        uint256 fromStep,
        uint256 toStep,
        uint256 position,
        uint256 paid,
        uint64 endTime
    );
    /// @notice A bidder withdrew a bid while the 1/1 was paused for a dispute.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @param bidder The bidder.
    /// @param to Where its escrow was sent.
    /// @param amount The escrow returned, in wei.
    event BidWithdrawn(
        uint256 indexed saleId,
        uint256 indexed bidId,
        address indexed bidder,
        address to,
        uint256 amount
    );
    /// @notice A sale was cleared and its revenue paid (beside `ISaleAdapter.SaleSettled`).
    /// @param saleId The sale ID.
    /// @param count Copies sold.
    /// @param step The clearing step.
    /// @param price The price per copy.
    /// @param revenue `count * price`, in wei.
    /// @param rationed Whether the cap binds inside the clearing step.
    /// @param cutUnits The clearing step's winning units.
    event AuctionCleared(
        uint256 indexed saleId,
        uint256 count,
        uint256 step,
        uint256 price,
        uint256 revenue,
        bool rationed,
        uint256 cutUnits
    );
    /// @notice A settle call swept part of the clearing step's departures, for its caller.
    ///         Progress is per caller, so `swept` can go down from one event to the next when
    ///         settlers interleave.
    /// @param saleId The sale ID.
    /// @param swept Departures the caller has swept so far.
    /// @param total Departures to sweep.
    /// @param cutoff The caller's cutoff so far.
    event DeparturesSwept(uint256 indexed saleId, uint256 swept, uint256 total, uint256 cutoff);
    /// @notice A sale settled; its bids may be claimed.
    /// @param saleId The sale ID.
    /// @param count Copies sold.
    /// @param cutoff The final cutoff (rationed sales; zero otherwise).
    event AuctionSettled(uint256 indexed saleId, uint256 count, uint256 cutoff);
    /// @notice The sale is void: nothing is minted or paid, and every bid is refunded in full.
    ///         Either the 1/1 was cancelled after an upheld dispute (`settle`), or the sale was
    ///         abandoned because its master could not be settled (`abandon`, which also seals the
    ///         edition at zero: `IEditions.EditionSupplySealed(id, 0)`).
    /// @param saleId The sale ID.
    event AuctionVoided(uint256 indexed saleId);
    /// @notice A bid was claimed: its copies minted and its refund paid or credited.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @param bidder The bidder.
    /// @param to Who received the copies (the bidder for `claimBidFor`).
    /// @param unitsWon Copies minted.
    /// @param refund The refund, in wei: sent to `to` by `claimBid`, credited to the bidder by
    ///        `claimBidFor`.
    event BidClaimed(
        uint256 indexed saleId,
        uint256 indexed bidId,
        address indexed bidder,
        address to,
        uint256 unitsWon,
        uint256 refund
    );
    /// @notice The governed parameters changed; open sales keep theirs.
    /// @param previous The parameters before the change (all zero in the constructor).
    /// @param next The parameters after the change.
    event ConfigSet(AuctionConfig previous, AuctionConfig next);
    /// @notice The governed limits changed. Open sales keep the close offset and abandonment
    ///         delay they locked.
    /// @param previous The limits before the change, packed as `Limits` documents (zero in the
    ///        constructor).
    /// @param next The limits after the change, packed.
    event LimitsSet(uint256 previous, uint256 next);

    /// @notice No sale has this ID.
    error UnknownAuction(uint256 saleId);
    /// @notice A sale for this token and ID already exists.
    error AuctionExists(uint256 saleId);
    /// @notice The sale is not in a state that allows this action.
    error InvalidAuctionState(uint256 saleId, AuctionStatus status);
    /// @notice The edition's 1/1 auction does not exist, or was cancelled.
    error NoOneOfOneAuction(address master, uint256 id);
    /// @notice Bidding has closed: the end passed, or the 1/1 was cancelled.
    error BiddingClosed(uint256 saleId, uint64 endTime);
    /// @notice A step at or past the sale's `stepCount`, or a raise not above the bid's step.
    error InvalidStep(uint256 step);
    /// @notice A quantity of zero, or one that would take a step's live units or the sale's live
    ///         units past 2^32 - 1, or, in a capped sale only (where units hold queue positions),
    ///         a step's entered units.
    error InvalidQuantity(uint256 quantity);
    /// @notice `msg.value` is not exactly the escrow or the top-up due.
    error IncorrectPayment(uint256 expected, uint256 paid);
    /// @notice No live bid has this ID in this sale (never placed, claimed or withdrawn).
    error UnknownBid(uint256 saleId, uint256 bidId);
    /// @notice The caller is not the bid's bidder.
    error NotBidder(address caller);
    /// @notice Withdrawals are open only while the 1/1 is paused for a dispute.
    error WithdrawalsClosed(uint256 saleId);
    /// @notice The sale cannot settle yet: its end has not passed, or the 1/1 is neither
    ///         SETTLED nor CANCELLED.
    error SettlementNotReady(uint256 saleId);
    /// @notice Copies were sold but the edition does not exist yet (`IEditions.createEdition`
    ///         is permissionless once the master has settled).
    error EditionNotCreated(address token, uint256 id);
    /// @notice The settlement order is wrong at `index`: a departure index out of range, or a
    ///         position not above the previous one.
    error InvalidSettlementOrder(uint256 index);
    /// @notice A configuration or limits outside the bounds `setConfig` and `setLimits` document.
    error InvalidConfig();
    /// @notice The sale cannot be abandoned: it has paid or settled, its 1/1 is still in
    ///         progress or has settled with its master and edition, or its abandonment delay has
    ///         not passed.
    error NotAbandonable(uint256 saleId);
    /// @notice A time that does not fit the 32-bit clocks the sale stores: a soft end or a 1/1
    ///         end at or past 2^32 seconds (7 February 2106). The adapter must be replaced before
    ///         then; until then no stored time wraps.
    error ClockOverflow(uint256 time);

    /// @notice The derived sale ID: `uint256(keccak256(abi.encode(token, id)))`, as
    ///         `IEnglishAuction.saleIdOf` derives it.
    /// @param token The edition contract.
    /// @param id The edition ID.
    /// @return The sale ID, whether or not that sale exists.
    function saleIdOf(address token, uint256 id) external pure returns (uint256);

    /// @notice Opens the sale of edition `id` on `token`. Permissionless, from the 1/1
    ///         auction's start until the edition close; refused while the adapter is paused
    ///         (`SalePaused`). Locks the creator's cap, the current `config()`, and the economics:
    ///         for 6529 Stream Editions, `IEconomicsResolver.newWorkTerms(PRODUCT_EDITIONS,
    ///         item.payees)`, or the economics an existing edition recorded. Binds the edition
    ///         to this adapter first (`IEditions.bindMinter`, ADR 0005 section 6), so an edition
    ///         another adapter sells refuses the open with that token's `MinterMismatch`. Emits
    ///         `AuctionOpened` and `ISaleAdapter.SaleStarted` (price: step 0's; end time:
    ///         `closeAt`). Reverts with `TargetNotAllowed` for a token that is not served,
    ///         `NoOneOfOneAuction`, `AuctionExists`, `BiddingClosed` after the close, and
    ///         `InvalidSaleTerms` when the terms do not match or are not this kind's.
    /// @param token A served edition contract.
    /// @param id The edition ID (the master's token ID).
    /// @param data Token-specific terms. For 6529 Stream Editions: `abi.encode(PackageItem)`
    ///        of the master's EDITION_MASTER item, whose `WorksHashing.itemHash` must equal the
    ///        item hash 6529 Stream stored for `id` (`IStreamCore.coreOf`), so no proof is needed;
    ///        its edition terms must name `SaleKind.UNIFORM_AUCTION` and `CURRENCY_ETH`, their
    ///        `maxCount` is the cap, and their params are empty (the governed default close
    ///        offset) or exactly `abi.encode(uint256 closeOffset)`, the artist's close offset in
    ///        seconds, at most `limits().maxCloseOffset`. Before locking anything, `open`
    ///        deploys the seller's and the royalty receiver's split wallets if they have no code
    ///        (`ISplitFactory.createWallet`), so no payment from this sale, and no royalty on its
    ///        copies, can reach an undeployed wallet.
    /// @return saleId `saleIdOf(token, id)`.
    function open(address token, uint256 id, bytes calldata data) external returns (uint256 saleId);

    /// @notice Places a bid of `quantity` units at `step`, paying exactly
    ///         `quantity * stepPrice(saleId, step)` as `msg.value`. Anyone, while bidding is open
    ///         (`EndTimes.biddingOpen`); at least one unit, at least the base step.
    /// @param saleId The sale ID.
    /// @param step A step below the sale's `stepCount`.
    /// @param quantity Units, from 1; the step's and the sale's units stay below 2^32.
    /// @return bidId The new bid's ID.
    function bid(uint256 saleId, uint256 step, uint256 quantity)
        external
        payable
        returns (uint256 bidId);

    /// @notice Moves a whole bid up to `newStep`, paying exactly
    ///         `quantity * (price(newStep) - price(step))`. The bidder only, while bidding is
    ///         open. In a capped sale it rejoins at the back of `newStep`'s queue and leaves a
    ///         departure at its old step. Bids are never lowered; more units means another bid.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @param newStep A step above the bid's step and below `stepCount`.
    function raise(uint256 saleId, uint256 bidId, uint256 newStep) external payable;

    /// @notice Withdraws a bid and sends its whole escrow to `to`. The bidder only, only while
    ///         the 1/1 is PAUSED for a dispute (owner decision 12), and only for a bid placed or
    ///         last raised in a minute, counted from the sale's open, that ended before the
    ///         pause began (amended 1 November 2026): a bid placed during the pause, in its
    ///         minute, or in the withdrawal's own block stays (`WithdrawalsClosed`). Leaves a
    ///         departure in a capped sale.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @param to The address that receives the escrow; zero reverts, and a failed transfer
    ///        reverts with `ClaimFailed`.
    function withdrawBid(uint256 saleId, uint256 bidId, address to) external;

    /// @notice Settles a closed sale. Permissionless; once the end has passed and the 1/1 is
    ///         SETTLED or CANCELLED. A cancelled 1/1 makes the sale VOID. Otherwise settlement
    ///         runs in calls of bounded gas, each advancing it: a call scans a bounded number of
    ///         the book's words (a wide book takes several calls), and the call that finishes the
    ///         scan clears the book, stores the result and pays the revenue: the network fee to
    ///         the fee recipient and the rest to the seller, each through the revenue escrow if
    ///         refused; it emits `AuctionCleared` and `ISaleAdapter.SaleSettled` (buyer and
    ///         recipient zero, quantity the count). Copies sold need the edition to exist
    ///         (`EditionNotCreated`). When the cap binds inside the clearing step, that call and
    ///         the next ones sweep a bounded number of the step's departures each. Each settler
    ///         (`msg.sender`) sweeps on its own: `order` is the rest of the caller's sweep,
    ///         departure indexes (`departures(saleId, step)`) whose positions strictly increase
    ///         from its own progress (`settlementOrder` for a settler that has not swept; the
    ///         lens's `settlementOrderFor(saleId, settler)` after), of which a call takes at most
    ///         one chunk. The first settler to sweep every departure fixes the cutoff; the sale
    ///         is then SETTLED and claims open. An order that skips or reorders a departure can
    ///         never finish its caller's sweep, and leaves every other settler's untouched: a
    ///         keeper that strands its own sweep settles from another address. A call on a
    ///         SETTLED sale returns `true` and changes nothing; on a VOID sale it reverts with
    ///         `InvalidAuctionState`.
    /// @param saleId The sale ID.
    /// @param order The next departure indexes of the caller's own sweep, in position order;
    ///        empty when not rationed.
    /// @return settled Whether the sale is now SETTLED or VOID.
    function settle(uint256 saleId, uint256[] calldata order) external returns (bool settled);

    /// @notice Claims a bid: mints its copies to `to` (`IMintTarget.mint`) and sends its refund
    ///         to `to`, then deletes it. The bidder only, once the sale is SETTLED or VOID (a
    ///         void sale refunds the whole escrow and mints nothing).
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @param to The address that receives the copies and the refund; zero reverts, and a failed
    ///        refund reverts with `ClaimFailed`.
    /// @return unitsWon Copies minted.
    /// @return refund Wei sent to `to`.
    function claimBid(uint256 saleId, uint256 bidId, address to)
        external
        returns (uint256 unitsWon, uint256 refund);

    /// @notice Claims a bid for its bidder: mints its copies to the bidder and credits its
    ///         refund to the bidder's `claimable` ETH (`ISaleAdapter.Credited`). Permissionless,
    ///         once the sale is SETTLED or VOID. A bidder whose ERC-1155 hook refuses the copies
    ///         claims with `claimBid` to another address.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @return unitsWon Copies minted to the bidder.
    /// @return refund Wei credited to the bidder.
    function claimBidFor(uint256 saleId, uint256 bidId)
        external
        returns (uint256 unitsWon, uint256 refund);

    /// @notice Sets the governed parameters for sales that open afterwards. PARAMETER_SETTER role
    ///         (48 hours), compare-and-set. Bounds: a ladder `StepLadder.isValid` accepts (24,
    ///         48, 96 or 192 steps per decade; a base price that is a power of ten from 10^12 to
    ///         10^17 wei, `StepLadder.isBasePrice`; 64 to 512 steps; a top step of at least 10
    ///         ETH), a margin of at most 50,000, a default close offset of at most
    ///         `limits().maxCloseOffset`, a soft-close window of 1 minute to 1 hour, and a maximum
    ///         extension of 1 hour to 7 days.
    /// @param expected The parameters the caller expects are current; a stale value reverts with
    ///        `ExpectedValueMismatch`.
    /// @param next The new parameters, within the bounds above (`InvalidConfig`).
    function setConfig(AuctionConfig calldata expected, AuctionConfig calldata next) external;

    /// @notice Sets the governed limits. PARAMETER_SETTER role (48 hours), compare-and-set.
    ///         Bounds, fixed in code: a maximum close offset of 1 day to 3,650 days, and at least
    ///         the current default close offset; an abandonment delay of 120 to 730 days (at
    ///         least governance's 30-day replacement of a dependency of the master's settlement
    ///         plus 6529 Stream's 90-day rescue floor); a payout gas of 30,000 to 3,000,000.
    ///         Open sales keep the close
    ///         offset and the abandonment delay they locked; the payout gas applies to every
    ///         later payout.
    /// @param expected The limits the caller expects are current, packed as `Limits` documents;
    ///        a stale value reverts with `ExpectedValueMismatch`.
    /// @param next The new limits, packed, within the bounds above and with nothing past bit 80
    ///        (`InvalidConfig`).
    function setLimits(uint256 expected, uint256 next) external;

    /// @notice Voids a sale that has paid nothing and can never settle, so its bidders are
    ///         refunded in full: nothing is minted or paid, and the edition is sealed at zero
    ///         (`IEditions.sealSupply(id, 0)`), so no copy of it can ever exist. Permissionless,
    ///         once `abandonable(saleId)` is true: the sale is OPEN (or SETTLING with its scan
    ///         still in progress), its end plus its locked abandonment delay has passed, and its
    ///         1/1 is neither in progress (ACTIVE or PAUSED) nor settled with its master settled
    ///         in 6529 Stream and the edition created; a 1/1 auction that does not answer counts
    ///         as stuck, and the end is then the one last read. Emits `AuctionVoided`. Reverts
    ///         with `UnknownAuction`, `NotAbandonable`, or `InvalidAuctionState` for a sale that
    ///         has paid.
    /// @param saleId The sale ID.
    function abandon(uint256 saleId) external;

    /// @notice Whether `abandon(saleId)` would void the sale now, and from when (answered by
    ///         the lens). Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return ok Whether the sale can be abandoned now.
    /// @return abandonAt The earliest time it can be, from what is known now: its end plus its
    ///         abandonment delay; zero while its 1/1 is in progress, settled with its master, or
    ///         the sale is not OPEN.
    function abandonable(uint256 saleId) external view returns (bool ok, uint256 abandonAt);

    /// @notice The governed parameters new sales lock.
    /// @return The current parameters.
    function config() external view returns (AuctionConfig memory);
    /// @notice The governed limits.
    /// @return The current limits.
    function limits() external view returns (Limits memory);
    /// @notice The English auction whose 1/1 sales anchor the edition sales (immutable).
    /// @return The English auction's address.
    function englishAuction() external view returns (address);
    /// @notice The revenue escrow that receives refused payouts (immutable).
    /// @return The revenue escrow's address.
    function escrow() external view returns (address);

    /// @notice A sale. Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return The sale, with its derived status.
    function auction(uint256 saleId) external view returns (Auction memory);
    /// @notice A sale's clocks, read live from its 1/1. Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return The 1/1's end, the close, the soft end, the end, the backstop and the states.
    function endTimes(uint256 saleId) external view returns (EndTimes memory);
    /// @notice The live result: what the sale would sell, and at what price, if it closed now.
    ///         After the close the book is frozen, so it equals the settlement's result.
    ///         Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return The clearing of the live book, with the cutoff its departures give.
    function clearing(uint256 saleId) external view returns (Clearing memory);
    /// @notice A sale's stored settlement and sweep progress; all zero before it settles.
    /// @param saleId The sale ID.
    /// @return The stored result.
    function settlement(uint256 saleId) external view returns (Settlement memory);
    /// @notice A live bid as stored. Reverts with `UnknownBid`.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @return The bidder, step, quantity and position.
    function bidOf(uint256 saleId, uint256 bidId) external view returns (Bid memory);
    /// @notice A bid's position in the result: copies won, price, escrow, refund and units ahead
    ///         in its queue; final once the sale is SETTLED or VOID. Reverts with `UnknownBid`.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @return The outcome.
    function bidOutcome(uint256 saleId, uint256 bidId) external view returns (BidOutcome memory);
    /// @notice Whether a new bid of `quantity` at `step` would win, how many copies, and what it
    ///         would change, if placed now and the sale then closed. `quote(saleId, s, 1)` is
    ///         "what would one more bid at step s change". It adds a new bid: for a raise it
    ///         counts the raised units twice (at their old step and the new one), so it is not
    ///         a quote of a raise. It ignores a step's queue capacity (2^32 - 1 units ever
    ///         entered in a capped sale), so a bid it quotes can still revert with
    ///         `InvalidQuantity` at a full step. Reverts with `UnknownAuction` or `InvalidStep`.
    /// @param saleId The sale ID.
    /// @param step The step of the hypothetical bid.
    /// @param quantity Its units, from 1.
    /// @return The quote.
    function quote(uint256 saleId, uint256 step, uint256 quantity)
        external
        view
        returns (Quote memory);
    /// @notice The lowest step at which a new bid of `quantity` would win at least one copy if
    ///         the sale closed now: "wins at least one unit", not all `quantity` (at a split
    ///         cut step it may win fewer). Winning is monotone in the step (model-checked, with
    ///         and without a cap), so this may be found by binary search. Like `quote`, it adds
    ///         a new bid and ignores a step's queue capacity. Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @param quantity The units of the hypothetical bid, from 1.
    /// @return found Whether any step would win (false only when even the top step would not).
    /// @return step The lowest winning step, when found.
    function lowestWinningStep(uint256 saleId, uint256 quantity)
        external
        view
        returns (bool found, uint256 step);
    /// @notice A step's price under the sale's locked parameters, or under `config()` for a sale
    ///         that has not opened. Reverts with `InvalidStep` past the ladder.
    /// @param saleId The sale ID.
    /// @param step The step.
    /// @return The price per unit, in wei.
    function stepPrice(uint256 saleId, uint256 step) external view returns (uint256);
    /// @notice Every step's price under the sale's locked parameters, or under `config()` for a
    ///         sale that has not opened.
    /// @param saleId The sale ID.
    /// @return prices The price of each step, in wei, from step 0.
    function ladder(uint256 saleId) external view returns (uint256[] memory prices);
    /// @notice The live units at each used step. Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return lowStep The step of `units[0]` (zero with no bids).
    /// @return units Live units per step, from `lowStep` through the highest used step.
    function stepTotals(uint256 saleId)
        external
        view
        returns (uint256 lowStep, uint256[] memory units);
    /// @notice A step's departure log, in the order logged (capped sales; empty otherwise).
    /// @param saleId The sale ID.
    /// @param step The step.
    /// @return The departures; an index into this list is what `settle` takes.
    function departures(uint256 saleId, uint256 step) external view returns (Departure[] memory);
    /// @notice The order `settle` needs: the clearing step's departure indexes sorted by
    ///         position: the order a settler that has not swept yet passes (each settler
    ///         sweeps on its own; the lens's `settlementOrderFor` gives a settler's rest); empty
    ///         unless the result is rationed, and once SETTLED.
    /// @param saleId The sale ID.
    /// @return order The departure indexes in position order.
    function settlementOrder(uint256 saleId) external view returns (uint256[] memory order);
}
