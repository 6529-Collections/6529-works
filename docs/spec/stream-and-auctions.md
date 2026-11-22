# Stream and auctions

6529 Stream is one shared ERC-721, `Stream`, holding every curated 1/1. It is permanent and
plain ([ADR 0010](../adr/0010-plain-permanent-core.md)): it keeps who owns each token, the
facts fixed at mint and how the first sale ended. Everything else is a replaceable module. The
1/1s sell through `EnglishAuction`, a replaceable sale contract that Stream lists as a minter.
Payments are in ETH only.

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| [`Stream`](../../src/core/Stream.sol) on [`StreamBase`](../../src/core/StreamBase.sol) | permanent | ERC-721, ERC-2981, ERC-4906. Mints for an active minter, records the outcome of the first sale, `royaltyInfo`, `tokenURI`, `rescue`, module slots and minters ([`Modules`](../../src/core/Modules.sol)). Interface: [`IStream`](../../src/interfaces/core/IStream.sol), [`IModules`](../../src/interfaces/core/IModules.sol). |
| [`EnglishAuction`](../../src/sales/EnglishAuction.sol) | module (minter) | Starts a sale by asking the mint policy and minting into its own custody; bids, pull credits, settlement, the dispute pause, the emergency pause, the federated refusal exit. Stores each sale's seller and fee share. |
| Mint policy: [`PackageRegistry`](../../src/curation/PackageRegistry.sol) | module | Decides what may be minted and answers the mint facts and sale terms ([`IMintPolicy`](../../src/interfaces/core/IMintPolicy.sol), [Curation](curation.md)). Holds content release and tombstones. |
| `TERMS` module: `StreamTerms` | module | Sets a token's royalty receiver and rate, locks the rate, lowers the network's fee share ([Economics and payouts](economics-and-payouts.md)). |
| `RENDERER` module: [`Renderer`](../../src/content/Renderer.sol) | module | Draws a work that is not finalized ([Rendering](rendering-and-tokenuri.md)). |
| `RECORDS` module: `WorkRules` | module | Edits a work's record within what `WorkFacts` allows ([Works and storage](works-and-storage.md)). |

## The seam

Stream accepts four things from modules and nothing else:

1. An active **minter** mints a new token and states its facts. While it still holds a token
   whose sale has no outcome, it may record the outcome once, or burn the token.
2. The **TERMS** module sets a token's royalty receiver and rate, and may lock the rate for good.
3. The **RENDERER** module draws a work that is not finalized. A finalized work is drawn by the
   renderer pinned in `WorkFacts`.
4. The **RECORDS** module changes a work's record within what `WorkFacts` allows.

No module can move a token, change a fact fixed at mint, or touch money in a vault or the escrow.
The one move by anyone but the owner is `rescue` (below).

## Settings and fixed numbers

Stream holds no fixed waiting period. Its two waits are the network's settings, changed at once
(no floor, zero allowed), each with an event carrying the old and new value:

| Setting | Launch value | What it governs |
| --- | --- | --- |
| `moduleDelay` | 7 days | Between announcing a module or adding a minter and its first use. An addition already announced keeps the time it was given. Removal is immediate. |
| `rescueDelay` | 14 days | Between a minter's removal and a `rescue` of a token it still holds unsold. Read when the rescue is attempted. |

The auction is replaceable, so its timers are compiled constants or governed values of that
contract, not promises of the token:

| Auction value | Launch value | Kind |
| --- | --- | --- |
| Duration | 24 hours (1 hour to 7 days) | governed |
| Anti-snipe window | 15 minutes (1 minute to 1 day) | governed |
| Increment | 5% of the high bid, at least 0.001 ETH | governed |
| Opening bid | 0.05 ETH | governed |
| Dispute pause | at most 3 days, once per auction | compiled |
| Federated refusal exit | 2 days after the end | compiled |
| Recipient's redirect of a pending delivery | 14 days after the end | compiled |
| Unclaimed credit | the unclaimed period in force (180 days at launch), counted from when that money itself started waiting | network setting read by the auction |
| Delivery gas; ETH payout gas | 300,000; 100,000 per wallet | compiled |

## How a sale flows

1. **Start** (anyone). The auction calls `policy.authorize(token, request)`. The policy checks
   the approved item, the artist's signature and the content rules, consumes the item and
   answers `MintFacts` (with the royalty receiver and rate) and `MintTerms` (seller, fee
   recipient, fee share). The auction checks the terms, calls `Stream.mint(address(this),
   facts)`, stores the seller and fee share in the sale, and opens the clock. `startWithBid`
   also places the first bid.
2. **Bid** (anyone). A bid must reach the minimum; a bid in the last window extends the end. An
   outbid bid is credited to its payer, never pushed.
3. **Settle** (anyone, after the end). With a bid, the auction calls
   `Stream.recordPrimarySale(tokenId, true, buyer, price)`, delivers the token and pays the
   seller and the network; a refused payout goes to the escrow, a failed delivery waits as a
   pending delivery. With no bid, it records `UNSOLD`; a 6529 Stream work is then transferred by
   the auction to the museum the economics resolver names at that moment; an unsold federated
   work stays in the auction and can be started again there for the same item.
4. **Cancel after an upheld dispute** (network). The auction calls `Stream.burn(tokenId)`.

Stream stores only the outcome. The price is in the `PrimarySale` log.

### Unclaimed credits: one rule for both auctions

The English auction and both edition auctions keep credits by one shared rule,
[`AgedCredits`](../../src/libraries/AgedCredits.sol). Each account has a total, a waiting part
and the time that part started waiting. A credit to an account with nothing starts a wait for
that amount; a credit while a wait runs joins the total only. Once the unclaimed period in force
(`Directory.unclaimedPeriod()`, read when the expiry is attempted) has passed since the wait
started, anyone may send the waiting part, and nothing else, to the network; the rest starts a
new wait at that moment. The account's own claim takes everything. So no money goes to the
network before it has itself waited the period, and no deposit or call by anyone else can
shorten or postpone a running wait. The revenue escrow's rule
([Economics and payouts](economics-and-payouts.md)) gives the same guarantee differently: it
groups credits in windows that stay open for one period and expire a period after their last
credit, so an amount waits at least one period and, while the period stays the same, less
than two; its due time can be
computed without anyone calling `expire`. The auctions use the simpler rule because their
credits are short-lived refunds that their owners usually claim at once, so a batch that waits
longer until someone calls `expireCredit` costs nobody anything, and one storage word with
three fields is easier to prove than four words of windows. The escrow, which is permanent and
was reviewed on its own, is left as it is.

### A token that will not settle

A federated token may fail a call `settle` makes into it. From 2 days after the sale's end
(compiled in the auction), anyone may call `settleOrRefund(saleId)`. It attempts the whole
settlement in a frame of fixed, governed gas; if the attempt fails, the sale closes with the
standing bid credited back and the work left in the auction. 6529 Stream's sales are never
refused (`SaleNotRefusable`).

#### Why this is sound

A token that settles is never affected: the exit only opens after the end plus the delay, and a
cooperating settlement inside the refusal gas always succeeds. The bidder's money comes back in
full; the network's fee is paid exactly on completed sales.

### What a federated template must guarantee

A federated token is the same token code as Stream (`StreamBase`), so it inherits every rule of
this page; its minters are the federation module's answer. It must settle within the refusal gas
and must not depend on a reentrancy guard a third party can hold.

**Rescue.** If the network removes a minter that still holds a token with no outcome, the
network may `rescue(tokenId, to)` once `rescueDelay` has passed since the removal. The outcome
becomes `RESCUED`. Re-adding the minter clears its removal. A rescue can never reach a token
whose outcome is set, or one held by anyone but that removed minter. A sale whose token was
rescued closes with refunds only.

**Royalties.** `royaltyInfo` is two storage reads of the token's receiver and rate; no module is
asked. The receiver at mint is the split wallet for the seller and the network's fee share, or
the seller when the share is zero.

## Rules and invariants

| ID | Rule | Tests |
| --- | --- | --- |
| AUC-1 | Only an active minter mints: added, past the `moduleDelay` it was given, and not removed. Genesis minters are active at once. | `test_Mint_OnlyAMinterAndOneLiveTokenPerContent`, `testFuzz_AddMinter_NeverActiveBeforeTheWait`, `test_Genesis_ModuleAndMinterAreActiveAtOnce` |
| AUC-2 | A mint needs a nonzero item hash, content hash and artist ID, a rate of at most 100,000 and an existing collection. | `test_Mint_StoresFactsAndCountsSerial`, `test_Mint_OnlyAMinterAndOneLiveTokenPerContent` |
| AUC-3 | Every start asks the mint policy in the same call; a policy revert reverts the start and mints nothing. | |
| AUC-4 | A VRF work mints only once its seed is delivered; the seed is stored in the token at mint and never changes. | |
| AUC-5 | Token IDs are one sequence from 1, never reused; serials count per collection from 1; `totalSupply` is minted minus burned. | `test_Mint_StoresFactsAndCountsSerial` |
| AUC-6 | A token's royalty receiver and rate change only through the TERMS module; a locked rate never changes again. | `test_Hostile_NoSeamPositionReachesACollectorsToken` |
| AUC-7 | `royaltyInfo` returns the stored receiver and exactly `floor(price × rate / 100,000)` for any price, asking no module. | |
| AUC-8 | Only the minter holding a token records its outcome, once: SOLD with a buyer, or UNSOLD. An outcome never changes. | `test_Sold_TheMinterCanDoNothingMore` |
| AUC-9 | Only the minter holding a token burns it, and only before an outcome, even after its removal. | `test_Sold_TheMinterCanDoNothingMore` |
| AUC-10 | Retired: content release moved to the mint policy (CUR rules). | |
| AUC-11 | Retired: Stream has no satellites to bind and no edition link. | |
| AUC-12 | Retired: collection names are checked by the keeper; the renderer tolerates any name. | |
| AUC-13 | The emergency pause stops only new starts. | |
| AUC-14 | A start refuses unusable terms: the escrow as seller or fee recipient, a zero seller or creator, a fee share above 100,000, or a token not in the auction's custody. | |
| AUC-15 | A sale locks its opening bid, increment share and window at start, and its increment floor at the first bid. | |
| AUC-16 | The first bid is at least the opening bid (and 1 wei); a later bid adds at least the larger of the increment share and the floor. | |
| AUC-17 | A bid in the last window moves the end to the bid's time plus the window; no bid is accepted at or after the end. | |
| AUC-18 | Outbid bids are credited to their payer, never pushed; only that account claims them. | |
| AUC-19 | Retired: ETH only; no ERC-20 payments. | |
| AUC-20 | The auction holds exactly its live high bids plus its credits; every sale ends at most once. | |
| AUC-21 | Settlement never depends on the recipient accepting the token: a failed delivery leaves a pending delivery. | |
| AUC-22 | A settler that does not forward the delivery and payout gas is refused. | |
| AUC-23 | A refused payout goes to the escrow for that wallet. | |
| AUC-24 | With no bid, a 6529 Stream work goes to the museum the economics resolver names at settlement; the auction transfers it. | |
| AUC-25 | Retired: no currency freeze (ETH only). | |
| AUC-26 | A dispute pause is once per live auction and lasts at most 3 days (a compiled value of the auction). | |
| AUC-27 | A resumed auction runs at least the longer of the governed duration and its locked window. | |
| AUC-28 | A federated token sells only while the federation module reports it active; an unsold federated work stays in the auction and can be started again there for the same item. | |
| AUC-29 | The auction refuses every safe transfer into it except its own mint. | |
| AUC-30 | Governed auction parameters stay within bounds and are compare-and-set. | |
| AUC-31 | No reentrant call reaches a value-moving function. | |
| AUC-32 | Gas: every start row, with or without a bid, costs at most 370,000 Prague gas and writes at most 8 new slots. | |
| AUC-33 | An unsold 6529 Stream work is never a pending delivery: the auction moves it with a plain transfer, no receiver callback. | |
| AUC-34 | Retired: the auction's views are its own. | |
| AUC-35 | The network may `rescue` a token only while a removed minter holds it with no outcome, once `rescueDelay` has passed since the removal; re-adding the minter clears the removal. | `test_Rescue_AfterFourteenDaysOnlyTheNetworkOnlyUnsold`, `testFuzz_Rescue_RefusedBeforeThePeriodInForce` |
| AUC-36 | A sale whose token was rescued closes with refunds only. | |
| AUC-37 | An outcome is NONE until recorded, then SOLD, UNSOLD or RESCUED for good. | `test_Sold_TheMinterCanDoNothingMore` |
| AUC-38 | The mint policy decides new mints only; Stream never calls it, and no answer of it changes an existing token. | |
| AUC-39 | Retired: Stream holds no dependencies. | |
| AUC-40 | `supportsInterface` answers ERC-165, ERC-721, ERC-2981, ERC-4906, `IStream` and `IModules`. | |
| AUC-41 | `rescueDelay` is the network's setting (14 days at launch), changed at once, zero allowed, with old and new in `RescueDelaySet`. | `test_RescueDelay_FourteenDaysAtDeploymentOnlyTheNetworkSetsIt`, `testFuzz_Rescue_RefusedBeforeThePeriodInForce` |
| AUC-42 | `tokenURI` of a finalized work uses the renderer pinned in `WorkFacts`; otherwise the RENDERER module. A missing, failing or changed renderer reverts; there is no fallback. | |
| AUC-43 | `WorkMinted` carries the whole `MintFacts`; Stream's state is rebuilt from its logs alone. | |
| AUC-44 | One live token per content hash: a content mints again only after the token it names is burned, and then only as the mint policy allows. | `test_Mint_OnlyAMinterAndOneLiveTokenPerContent` |
| AUC-45 | `settleOrRefund` is for federated sales only, from 2 days after the end; a failed attempt closes the sale with the bid credited back. | |
| AUC-46 | The refusal delay is 2 days, compiled in the auction. | |
| AUC-47 | The refusal gas is governed, raise-only, at most doubled per step, between bounds in code. | |
| AUC-48 | A federated sale's fee share is the federation module's, stored in the sale at start; the fee goes to the recipient the economics resolver names. | |
| AUC-49 | Retired: there is no view extension. | |
| AUC-50 | The TERMS module may lower a work's fee share, never raise it, and deploys the new split wallet before naming it. | |
| AUC-51 | Only money that has itself waited the unclaimed period in force goes from a credit to the network; a later credit starts no earlier clock and no third party can shorten or postpone one. | |
| AUC-52 | Retired: ETH only; no permit payments. | |
| AUC-53 | Removing a minter is immediate: it mints nothing new but still records outcomes and burns for tokens it holds. | `test_RemoveMinter_AtOnceKeepsItsRecord` |
| AUC-54 | `moduleDelay` is the network's setting (7 days at launch), changed at once, zero allowed; a pending addition keeps its time. | `test_SetDelay_OnlyTheNetworkAtOnceWithOldAndNew`, `test_SetDelay_PendingAdditionsKeepTheirTime`, `test_SetDelay_ZeroIsAllowed` |

## Events

Signatures and topics are on the [events page](../integrators/events-and-indexing.md). Stream:
`WorkMinted`, `PrimarySale` (outcome, buyer, price), `WorkRescued`, `RoyaltySet`,
`RoyaltyRateLocked`, `CollectionCreated`, `MinterAdded`, `MinterRemoved`, `ModuleProposed`,
`ModuleSet`, `ModuleDelaySet`, `RescueDelaySet`, `OwnershipTransferred`, `ContractURIUpdated`,
ERC-721 and ERC-4906.

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| Start while paused | `SalePaused` | Wait for `unpause`. |
| The policy refuses | The policy's error; nothing mints | Fix the item or wait (a frozen account, an undelivered seed). |
| Bid too low or late | `BidTooLow(required, offered)`, `InvalidAuctionState` | Read `minimumBid(saleId)`. |
| Recipient refuses the token | `DeliveryPending`; settlement completes | The winner calls `claimDelivery` to any address. |
| A payout wallet refuses ETH | Credited in the escrow | Anyone flushes the escrow to the wallet. |
| A federated token will not settle | `settle` reverts | `settleOrRefund` from 2 days after the end. |
| The minter holding a work was removed | The work waits | The network re-adds the minter, or rescues after `rescueDelay`. |
| `tokenURI`'s renderer is missing or fails | Reverts | Install a RENDERER module, or finalize to pin one. |
