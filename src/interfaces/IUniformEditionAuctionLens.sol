// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import { IEnglishAuction } from "./IEnglishAuction.sol";
import { IUniformEditionAuction } from "./IUniformEditionAuction.sol";
import { IUniformEditionAuctionStorage } from "./IUniformEditionAuctionStorage.sol";

/// @title IUniformEditionAuctionLens
/// @notice The read side of the uniform-price edition auction: every view of a sale, computed
///         from the adapter's storage words (`IUniformEditionAuctionStorage.storageWord`) with the
///         clearing code its settlement runs (`UniformClearing`), the adapter's own views (its
///         settings, credits, sale kind and ERC-165), and the master and abandonment checks the
///         adapter's `open` and `abandon` consult. Stateless and bound to no adapter: deployed in its own
///         transaction and pinned by the adapter's constructor (`IUniformEditionAuctionStorage.lens`),
///         it reads every sale from its caller, the adapter, which forwards its own views here,
///         so each view below has the signature `IUniformEditionAuction` gives it. Errors are
///         the adapter's.
/// @dev Views that depend on the 1/1 read it live, through `IEnglishAuctionClock.auctionClock`
///      (an adopted sale that runs on its own does not read it). The adapter's fallback forwards every selector it does not declare, so the lens's own
///      `masterTerms`, `sweepOf` and `settlementOrderFor` are answered at the adapter's address
///      too. Every forwarded call is read-only (a `staticcall`), and the adapter's ERC-165 does
///      not advertise the lens's own views. `masterTerms` is the one call that writes: it
///      deploys the sale's split wallets, so the adapter calls it directly, and through the
///      fallback it answers only when they exist. Call the views at the adapter: called
///      directly, the lens reads its caller's words.
interface IUniformEditionAuctionLens {
    /// @notice What `open` and `adopt` lock for a master from the lens, from its token-specific
    ///         data, and what `open` creates the edition with.
    /// @param maxCount The creator's cap from the edition terms, zero for none.
    /// @param oneOfOneEnd The 1/1's end now; for an adopted sale that runs on its own, the time
    ///        its close is counted from (the adoption plus `ADOPTED_RUN`).
    /// @param oneOfOneState The 1/1's state now: never NONE or CANCELLED (SETTLED for an adopted
    ///        sale that runs on its own).
    /// @param seller The artist-portion split wallet the sale pays.
    /// @param feeShare The network's share of the revenue, out of 100,000.
    /// @param feeRecipient The network fee recipient now (settlement reads it again).
    /// @param royaltyReceiver The royalty receiver the edition is created with.
    /// @param royaltyRate The master's royalty rate, which the edition is created with.
    /// @param runsOnItsOwn True for an adopted sale whose master's sale already has an outcome.
    struct MasterTerms {
        uint32 maxCount;
        uint64 oneOfOneEnd;
        IEnglishAuction.AuctionState oneOfOneState;
        address seller;
        uint32 feeShare;
        address feeRecipient;
        address royaltyReceiver;
        uint24 royaltyRate;
        bool runsOnItsOwn;
    }

    /// @notice How long after its 1/1's final end every edition sale closes: 15 minutes, a fixed
    ///         value.
    /// @return 900.
    function CLOSE_OFFSET() external view returns (uint32);
    /// @notice How long after its scheduled close (its 1/1's final end plus {CLOSE_OFFSET}; a
    ///         soft-close extension does not move it) a sale may be abandoned: 21 days, a
    ///         fixed value.
    /// @return 1,814,400.
    function ABANDON_DELAY() external view returns (uint32);
    /// @notice How long an adopted sale whose master's sale already has an outcome runs before
    ///         its close is counted (`IUniformEditionAuction.adopt`): one day, a value of this
    ///         replaceable adapter. The sale closes 15 minutes after that, with the usual soft
    ///         close.
    /// @return 86,400.
    function ADOPTED_RUN() external view returns (uint32);

    /// @notice The 6529 Stream Editions this lens was deployed for (immutable; zero for the
    ///         Independent Stream deployment, which sells many).
    /// @return The address its adapter must also have.
    function editions() external view returns (address);
    /// @notice The 6529 Stream this lens was deployed for (immutable; zero for the Independent
    ///         Stream deployment).
    /// @return The address its adapter must also have.
    function stream() external view returns (address);
    /// @notice The directory whose `unclaimedPeriod` decides when a credit may expire, and
    ///         whose INDEPENDENT_STREAM module serves the Independent Stream deployment
    ///         (immutable).
    /// @return The address its adapter must also have.
    function directory() external view returns (address);
    /// @notice The economics resolver: seller wallets, fee terms and the network fee recipient
    ///         (immutable).
    /// @return The resolver.
    function economics() external view returns (address);
    /// @notice The English auction this lens was deployed for (immutable).
    /// @return The address its adapter must also have.
    function englishAuction() external view returns (address);
    /// @notice The revenue escrow this lens was deployed for (immutable).
    /// @return The address its adapter must also have.
    function escrow() external view returns (address);
    /// @notice The master check of `open` and `adopt`. The master is `IEditions(token).stream()`;
    ///         `IStream.workOf(id)` must be an edition master (kind 1) whose item hash is
    ///         `WorksHashing.itemHash` of the item in `data`. For 6529 Stream Editions, `data`
    ///         must be `abi.encode(PackageItem item, bytes32 packageRoot, bytes32[] proof)`, an
    ///         item the package registry still approves in `packageRoot`
    ///         (`IItemApprovals.isApprovedItem`); for an Independent Stream pair
    ///         `abi.encode(item)`, whose contract the Independent Stream module lets this adapter
    ///         mint (`canMint`). The edition terms must name `SaleKind.UNIFORM_AUCTION` and
    ///         `CURRENCY_ETH`, with empty params; the payout terms (6529 Stream Editions: the
    ///         resolver's `newWorkTerms(PRODUCT_EDITIONS, payees)`; Independent Stream: the
    ///         seller's wallet and the Independent Stream module's fee share for the token) must be
    ///         payable. For `open`, the 1/1 auction must exist and not be cancelled; for `adopt`,
    ///         the edition must be the caller's with no copies and no seal, and the 1/1 is read
    ///         only while the master's sale has no outcome. Reverts with the adapter's
    ///         `InvalidSaleTerms` or `NoOneOfOneAuction` otherwise (a 1/1 auction that runs out of
    ///         gas answering reverts with `BoundedCallShortfall`). Then deploys the seller's split
    ///         wallet and, for `open` when it differs, the royalty receiver's, each only if the
    ///         ledger has not deployed it, through the resolver's split factory, and requires each
    ///         deployed address to be the one the terms name (`InvalidSaleTerms`).
    /// @param token The edition contract.
    /// @param id The edition ID.
    /// @param data The token-specific terms `open` or `adopt` was given.
    /// @param adopting True for `adopt`.
    /// @return The terms the sale locks and the 1/1's state.
    function masterTerms(address token, uint256 id, bytes calldata data, bool adopting)
        external
        returns (MasterTerms memory);

    /// @notice Whether the caller's sale can be abandoned now, and from when
    ///         (`IUniformEditionAuction.abandonable`): OPEN (or SETTLING with its scan in
    ///         progress), not adopted to run on its own, its 1/1 auction answering neither ACTIVE,
    ///         PAUSED, ENDED nor SETTLED (one that refuses to answer counts, with the end last
    ///         read), and its scheduled close (its 1/1's final end plus 15 minutes, not moved by
    ///         a soft-close extension) plus 21 days passed. A shortfall in any read reverts with
    ///         `BoundedCallShortfall`.
    /// @param saleId The sale ID.
    /// @return ok Whether it can be abandoned now.
    /// @return abandonAt The earliest time, or zero when it cannot be from what is known now.
    function abandonable(uint256 saleId) external view returns (bool ok, uint256 abandonAt);

    /// @notice The check `abandon` makes: reverts with `NotAbandonable(saleId)` unless
    ///         `abandonable(saleId)` is true for the caller (`UnknownAuction` for a sale never
    ///         opened).
    /// @param saleId The sale ID.
    function checkAbandon(uint256 saleId) external view;

    /// @notice The network fee recipient a payout of the caller pays now: the economics
    ///         resolver's for the deployment's product (6529 Stream Editions or Independent
    ///         Stream), or, when it names none or the escrow and `token` is nonzero, the recipient
    ///         the caller's sale of edition `id` of `token` recorded at open (zero when it has
    ///         none).
    /// @param token The edition contract, or zero for the resolver's answer alone.
    /// @param id The edition ID.
    /// @return The recipient.
    function feeRecipient(address token, uint256 id) external view returns (address);

    /// @notice When the waiting batch of `account`'s credit may be sent to the network's fee
    ///         recipient (`expireCredit`): the unclaimed period in force now
    ///         (`IDirectory.unclaimedPeriod()`) after the batch started waiting; zero with no
    ///         credit. A change of the period moves this answer.
    /// @param account The credited account.
    /// @return The first second `expireCredit` succeeds under the period in force, or zero.
    function creditExpiresAt(address account) external view returns (uint256);

    /// @notice An account's credit: its total, the batch that is waiting (all of which arrived
    ///         no later than `since`) and when that batch started waiting.
    /// @param account The credited account.
    /// @return total Its whole claimable ETH.
    /// @return aged The batch `expireCredit` may move once the period has passed since `since`.
    /// @return since When the batch started waiting; zero with no credit.
    function creditOf(address account)
        external
        view
        returns (uint256 total, uint256 aged, uint256 since);

    /// @notice One of the caller's storage words, from which every other view is computed: the
    ///         lens finds its slot from the adapter's layout and reads it with
    ///         `IUniformEditionAuctionStorage.storageAt`. `IUniformEditionAuctionStorage.Space`
    ///         documents each family's key and packing.
    /// @param space The word's family.
    /// @param saleId The sale ID, for the per-sale families; ignored for TERMS, CREDIT and
    ///        SETTINGS.
    /// @param key The key within the family.
    /// @return The stored word; zero when unset.
    function storageWord(IUniformEditionAuctionStorage.Space space, uint256 saleId, uint256 key)
        external
        view
        returns (uint256);

    /// @notice The caller's current configuration (`IUniformEditionAuction.config`).
    /// @return The parameters new sales lock.
    function config() external view returns (IUniformEditionAuction.AuctionConfig memory);
    /// @notice The caller's governed limit (`IUniformEditionAuction.limits`): the payout gas.
    /// @return The current limits.
    function limits() external view returns (IUniformEditionAuction.Limits memory);
    /// @notice The caller's claimable credits (`ISaleAdapter.claimable`): ETH only, without the
    ///         time packed beside them.
    /// @param account The account.
    /// @param currency The currency; anything but `CURRENCY_ETH` has none.
    /// @return The amount claimable.
    function claimable(address account, address currency) external view returns (uint256);
    /// @notice Whether the caller's new opens are paused (`ISaleAdapter.paused`).
    /// @return True while paused.
    function paused() external view returns (bool);
    /// @notice Whether the caller serves `token` (`ISaleAdapter.isTarget`): only 6529 Stream
    ///         Editions, while listed.
    /// @param token The token contract.
    /// @return True if served.
    function isTarget(address token) external view returns (bool);
    /// @notice The edition auction's sale kind (`ISaleAdapter.saleKind`).
    /// @return `SaleKind.UNIFORM_AUCTION`.
    function saleKind() external pure returns (bytes32);
    /// @notice The adapter's ERC-165: `IUniformEditionAuction`, `ISaleAdapter` and `IERC165`.
    /// @param interfaceId The interface ID.
    /// @return True for those three.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
    /// @notice The derived sale ID (`IUniformEditionAuction.saleIdOf`).
    /// @param token The edition contract.
    /// @param id The edition ID.
    /// @return `uint256(keccak256(abi.encode(token, id)))`.
    function saleIdOf(address token, uint256 id) external pure returns (uint256);
    /// @notice The Independent Stream registry (`ISaleAdapter.independentStreamRegistry`): zero for
    ///         6529 Stream Editions' deployment, which serves no Independent Stream token; the
    ///         pinned registry for the Independent Stream deployment (ADR 0008).
    /// @return The registry, or zero.
    function independentStreamRegistry() external view returns (address);
    /// @notice Refused by the lens (`ISaleAdapter.TargetNotAllowed(next)`): 6529 Stream Editions'
    ///         deployment serves no Independent Stream token, and the Independent Stream deployment
    ///         declares its own `setIndependentStreamRegistry`, which never reaches its lens.
    /// @param expected Ignored.
    /// @param next The registry asked for.
    function setIndependentStreamRegistry(address expected, address next) external pure;

    /// @notice A sale. Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return The sale, with its derived status.
    function auction(uint256 saleId) external view returns (IUniformEditionAuction.Auction memory);
    /// @notice A sale's clocks, read live from its 1/1. Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return The 1/1's end, the close, the soft end, the end, the backstop and the states.
    function endTimes(uint256 saleId) external view returns (IUniformEditionAuction.EndTimes memory);
    /// @notice The live result: what the sale would sell, and at what price, if it closed now.
    ///         After the close the book is frozen, so it equals the settlement's result.
    ///         Reverts with `UnknownAuction`.
    /// @param saleId The sale ID.
    /// @return The clearing of the live book, with the cutoff its departures give.
    function clearing(uint256 saleId) external view returns (IUniformEditionAuction.Clearing memory);
    /// @notice A sale's stored settlement and sweep progress; all zero before it settles.
    /// @param saleId The sale ID.
    /// @return The stored result.
    function settlement(uint256 saleId)
        external
        view
        returns (IUniformEditionAuction.Settlement memory);
    /// @notice A live bid as stored. Reverts with `UnknownBid`.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @return The bidder, step, quantity and position.
    function bidOf(uint256 saleId, uint256 bidId)
        external
        view
        returns (IUniformEditionAuction.Bid memory);
    /// @notice A bid's position in the result: copies won, price, escrow, refund and units ahead
    ///         in its queue; final once the sale is SETTLED or VOID. Reverts with `UnknownBid`.
    /// @param saleId The sale ID.
    /// @param bidId The bid's ID.
    /// @return The outcome.
    function bidOutcome(uint256 saleId, uint256 bidId)
        external
        view
        returns (IUniformEditionAuction.BidOutcome memory);
    /// @notice Whether a new bid of `quantity` at `step` would win, how many copies, and what it
    ///         would change, if placed now and the sale then closed. `quote(saleId, s, 1)` is
    ///         "what would one more bid at step s change". Reverts with `UnknownAuction` or
    ///         `InvalidStep`.
    /// @param saleId The sale ID.
    /// @param step The step of the hypothetical bid.
    /// @param quantity Its units, from 1.
    /// @return The quote.
    function quote(uint256 saleId, uint256 step, uint256 quantity)
        external
        view
        returns (IUniformEditionAuction.Quote memory);
    /// @notice The lowest step at which a new bid of `quantity` would win at least one copy if
    ///         the sale closed now. Winning is monotone in the step (model-checked, with and
    ///         without a cap), so this may be found by binary search. Reverts with
    ///         `UnknownAuction`.
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
    function departures(uint256 saleId, uint256 step)
        external
        view
        returns (IUniformEditionAuction.Departure[] memory);
    /// @notice The order `settle` needs from a settler that has not swept yet: the clearing
    ///         step's departure indexes sorted by position; empty unless the result is rationed,
    ///         and once SETTLED.
    /// @param saleId The sale ID.
    /// @return order The departure indexes in position order.
    function settlementOrder(uint256 saleId) external view returns (uint256[] memory order);
    /// @notice `settler`'s own departure sweep in progress: each settler sweeps on its own, and
    ///         the first to sweep every departure settles the sale. All zero when it has none
    ///         (it never swept, or it finished).
    /// @param saleId The sale ID.
    /// @param settler The settler (`settle`'s `msg.sender`).
    /// @return swept The departures it has swept.
    /// @return nextPosition The least position its next departure may have.
    /// @return cutoff Its cutoff so far.
    function sweepOf(uint256 saleId, address settler)
        external
        view
        returns (uint256 swept, uint256 nextPosition, uint256 cutoff);
    /// @notice What `settler` passes to its next `settle` call: the rest of the order after
    ///         its own progress (`settlementOrder` for a settler with none). Sorts and returns
    ///         the whole log: beyond about 7,000 departures at the cut step it exceeds a 50M
    ///         `eth_call`, so page with the four-argument form.
    /// @param saleId The sale ID.
    /// @param settler The settler (`settle`'s `msg.sender`).
    /// @return order The remaining departure indexes, in position order.
    function settlementOrderFor(uint256 saleId, address settler)
        external
        view
        returns (uint256[] memory order);
    /// @notice One page of `settler`'s remaining order: at most `max` departure indexes, in
    ///         position order, from the later of `fromPosition` and the settler's own next
    ///         position. `O(n log max)` over a log of `n` departures (a bounded heap), reading the
    ///         log four entries per word: a page of 96 from a log of 10,000 departures costs about
    ///         22M gas in the log's worst order. Before the clearing is stored (an open sale, or
    ///         a settlement scan still running), each page also computes the live clearing, as
    ///         `clearing` does. A keeper pages with `fromPosition` one past the last position it
    ///         got (`departures(saleId, step)` gives them), or passes each page to `settle` and
    ///         asks again.
    /// @param saleId The sale ID.
    /// @param settler The settler (`settle`'s `msg.sender`).
    /// @param fromPosition The least position to return.
    /// @param max The most indexes to return.
    /// @return order The departure indexes, in position order.
    function settlementOrderFor(uint256 saleId, address settler, uint256 fromPosition, uint256 max)
        external
        view
        returns (uint256[] memory order);
}
