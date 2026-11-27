# sales

The sale contracts. Each is a replaceable module: a token lets it mint only while it is an
active minter (`addMinter`, active after the token's `moduleDelay`; `removeMinter` at once), so
a new sale method is a new contract. The English auction sells 6529 Stream's 1/1s and Independent
Stream 1/1s; the uniform-price edition auction sells 6529 Stream Editions beside them
([ADR 0005](../../docs/adr/0005-stream-editions-auction.md),
[ADR 0010](../../docs/adr/0010-plain-permanent-core.md)). The rules are in
[Stream and auctions](../../docs/spec/stream-and-auctions.md) (`AUC-*`),
[Disputes and statements](../../docs/spec/disputes-and-statements.md) (`DSP-13` to `DSP-23`, the
dispute pause) and [Editions and sales](../../docs/spec/editions-and-sales.md) (`EA-*`).

## Files

| File | What it is |
| --- | --- |
| `EnglishAuction.sol` | [`IEnglishAuction`](../interfaces/IEnglishAuction.sol), ETH only: a permissionless start that asks the token's mint policy ([`IMintPolicy`](../interfaces/core/IMintPolicy.sol); the package registry for 6529 Stream, the directory's Independent Stream module for any other token) and mints into its own custody (`IStream.mint`), anti-snipe bids, aged pull credits, settlement that records the outcome in the token (`recordPrimarySale`), pays with escrow fallback and delivers (or leaves a pending delivery); an unsold 6529 Stream work goes to the museum, an unsold Independent Stream work waits in custody for `restart`; the exit for an Independent Stream token that will not settle ([`IEnglishAuctionRefusal`](../interfaces/IEnglishAuctionRefusal.sol)), the dispute pause, the start pause. Its views are native (no lens). |
| `UniformEditionAuction.sol` | The shared base `UniformEditionAuctionBase` (the Independent Stream deployment is in [`src/independent`](../independent/README.md)) and 6529 Stream Editions' deployment: [`IUniformEditionAuction`](../interfaces/IUniformEditionAuction.sol)'s writes and [`IUniformEditionAuctionStorage`](../interfaces/IUniformEditionAuctionStorage.sol): the bid book (step totals, bids, FIFO departure logs), the coupling with the 1/1's end (the sale closes 15 minutes after it, fixed), settlement in calls of bounded gas, claims through `IMintTarget.mint`, credits that expire to the network after the directory's `unclaimedPeriod` (the network's setting; 180 days at launch), the abandonment exit (21 days after the close), governance (configuration and payout gas). |
| `UniformEditionAuctionLens.sol` | [`IUniformEditionAuctionLens`](../interfaces/IUniformEditionAuctionLens.sol): every view (the adapter's own settings included), computed from the adapter's storage words, which it locates from the adapter's layout; the package-item check `open` consults (with the package registry's approval, C23, for 6529 Stream Editions), which also deploys the sale's split wallets; the abandonment check; and the network fee recipient settlement pays (R18). Stateless and bound to no adapter (it reads its caller): deployed in its own transaction, then pinned by the adapter's constructor (code hash and wiring) and forwards its views to it. |
| `SaleStarter.sol` | A stateless helper with no roles: starts a 6529 Stream sale, deploys the work's seller and royalty vaults and opens its record in `StreamWorkFacts6529` in one transaction, all or nothing. `start` and `startWithBid` on the auction stay permissionless. |
| `UniformClearing.sol` | Internal library, pure: the uniform-price clearing on [`StepLadder`](../interfaces/types/StepLadder.sol)'s prices, the FIFO split of the cut step and the what-if quote, shared by the lens, the adapter's sweep and the Halmos proofs. |

Every bid is ETH.

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone | `start`, `startWithBid`, `bid`, `settle`, `settleOrRefund` (Independent Stream only), `restart` (an unsold Independent Stream work), `expireCredit` (the aged part of a credit, once it has waited the directory's `unclaimedPeriod`) | AUC-14 to AUC-25, AUC-29, AUC-45 to AUC-48 |
| A bidder | `claim` of its credits; `withdrawBid` (the high bidder, while paused); `claimDelivery` (the winning bidder to any address; the recipient it named to itself, or anywhere from 14 days after the end) | AUC-18, AUC-21, DSP-15 |
| The pauser and the network | The dispute `pause(saleId, …)` (the pauser, at most 3 days), `resume`, `cancel` (the network, no wait); `pause()`, `unpause()`; `setConfig`, `setStreamPolicy` (the opening bid and increment floor are the asset allowlist's) | AUC-13, AUC-26, AUC-30, DSP-13 to DSP-19; [role matrix](../../docs/audit/roles.md#englishauction) |
| Anyone (edition auction) | `open`, `bid`, `settle`, `claimBidFor`, `abandon`, `expireCredit`, every view | EA-1, EA-4, EA-8 to EA-13, EA-17, EA-19, EA-20 |
| An edition bidder | `raise`, `claimBid`, `claim` of its credits (bids are firm: no withdrawal) | EA-5, EA-9, EA-16 |
| Governance (edition auction) | `pause()`, `unpause()`, `setConfig`, `setLimits`, `setTarget` (no Independent Stream registry) | EA-15, EA-18; [role matrix](../../docs/audit/roles.md#uniformeditionauction) |

Call sequences and errors: [Buying, bidding and settling](../../docs/integrators/buying-bidding-settling.md);
events and their ordering: [Events and indexing](../../docs/integrators/events-and-indexing.md#englishauction).

## Developer notes

- **Bytecode and the lenses.** The English auction answers its views natively (no lens, no
  fallback); it keeps more than 3,000 bytes of EIP-170 margin. The edition auction's write path
  nearly fills EIP-170, so it answers its views from a lens deployed before it and pinned by its
  constructor, through a fallback that `staticcall`s it. `auctionClock`
  (`IEnglishAuctionClock`) is what the edition auction reads of the English auction.
- **Edition auction storage and the lens.** The lens reads the adapter's words with
  `storageAt(slot)`, computing each slot from the adapter's layout (its `_SLOT_*` constants),
  so a change to the adapter's state variables must change the lens too
  (`test_StorageWord_TheLensFollowsTheAdaptersLayout`). Every sale locks the current terms
  record (24-bit IDs); the payout gas shares the settings word; a credit word packs the amount
  (208 bits) with the time it went from zero. Stored times are 32 bits, checked (EA-18).
- **English auction storage.** One `Sale` struct per sale: the token and token ID; the seller
  and fee share the policy answered, the end, the status and flags (both written at start); the
  bidder and bid (from the first bid); the recipient and dispute pause (only when used). Credits
  are one `Credit { total, aged, since }` per account: only the aged part, which has waited the
  directory's `unclaimedPeriod` (read when expiry is attempted), may expire; money credited while
  a wait runs starts its own wait when the aged part leaves.
- **A token that will not settle.** For Independent Stream sales only, from 2 days after the end,
  `settleOrRefund` calls `settle` on the auction itself with exactly `refusalGas` (the one
  governed gas bound, raise-only) and, if that fails, closes the sale with refunds; the work
  stays in custody for `restart`. It takes no guard but refuses to run inside the auction's or
  the escrow's (it asks the escrow's `locked()` view).
- **Money.** At settlement the seller gets `floor(price × (100,000 − share) / 100,000)` (the
  share the policy answered at the start) and the network the rest, paid to the recipient the
  economics resolver names then (`networkFeeRecipient(product)`). A wallet that refuses ETH is
  paid through the revenue escrow.
- **The no-bid outcome.** An unsold 6529 Stream work is recorded UNSOLD and sent to the museum
  the resolver names then. An unsold Independent Stream work gets no outcome and stays in custody;
  anyone may offer it again (`restart`) while the Independent Stream module still serves the
  token (`isActive`), whether or not the auction may still mint new works. A work the
  network rescued (`IStream.rescue`) closes its sale with the standing bid credited back: the
  sale ends CANCELLED, an edition sale that followed it is void, and a rescued work that is in
  the auction's custody at that moment goes to the museum.
- **Edition auction storage.** Per sale, a state word (written by every bid), a payout word at
  open and a result word at settlement; live units eight steps to a word; one word per bid;
  departure logs only in capped sales.
- **Settlement in bounded calls.** A call scans at most 24 live words (a scan word keeps its
  place) and sweeps at most 16 departures in the call that clears, 96 in each later one. Each
  settler's progress is its own slot: a call continues its caller's sweep
  (`settlementOrderFor`), the first settler to sweep every departure settles the sale, and an
  order that skips a departure strands only its sender. A differential fuzz holds the Yul scan
  equal to `UniformClearing.clear` (10,000 runs nightly).
- **The edition is created at open.** `open` calls `StreamEditions6529.create` once, with the
  maximum and royalty from the master's terms, so the edition's minter is this sale contract;
  `adopt` (the network) takes over an edition a removed sale contract left with no copies and no
  seal, after `StreamEditions6529.rebind`.
- **Long departure logs.** The lens reads a log four entries per storage word and sorts with a
  heap in Yul, `O(n log n)` in any log order. A keeper pages with
  `settlementOrderFor(saleId, settler, fromPosition, max)`, `O(n log max)`: 21.9M gas for a page
  of 96 at 10,000 departures (`test_F9_AKeeperPagesTenThousandDepartures`). `clearing` and
  `quote` cost about 5,000 gas a departure at the cut step, within a 50M `eth_call` up to about
  9,000; `settlementOrder` up to about 7,000.
- **Firm edition bids.** There is no withdrawal; an upheld dispute voids the sale and
  every bid comes back in full at its claim.
- **The 1/1's end is cached.** It only moves later, so a bid reads `auctionClock` only within the
  soft-close window of the cached close; settlement always does.
- **A 1/1 offered again.** `restart` is accepted from 15 minutes after the last sale's end
  (`RESTART_DELAY`, the edition auctions' `CLOSE_OFFSET`), reuses the sale ID, and
  `auctionClock` answers when it happened. An edition sale opened before the restart has reached
  its close by then; it reads its 1/1 as settled and keeps the end it recorded, and a later sale
  of the work moves nothing in it (EA-17, IND-56).
- **No wait after a pause.** `unpause`, `resume` and the dispute `cancel` add no wait of
  their own; the network acts at any moment of the 3-day pause.
- **Gas.** Per-operation Prague gas and slots are in
  [ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table);
  `UniformClearingGas.t.sol` measures a full 336-step clearing.
- **Tests:** `forge test --match-path 'test/sales/**'` (the English auction with its invariant
  suites, `PauseWindow.t.sol`, the edition auction on mocks in `edition/` with its golden
  vectors, `UniformClearing` in `uniform/`); on the real stack, the suites in
  [`test/integration/`](../../test/integration/README.md); coverage and mutation testing:
  [Testing](../../docs/testing/README.md).

## See also

[ADR 0001 §5](../../docs/adr/0001-v1-scope.md#5-sales-and-auctions) (with §6, §12 and §16),
[ADR 0003, sales and auctions](../../docs/adr/0003-build-time-decisions.md#sales-and-auctions-amends-adr-0001-5-6-and-9),
[ADR 0005](../../docs/adr/0005-stream-editions-auction.md);
[known limitations](../../docs/audit/known-limitations.md#sales-and-auctions) (and
[the edition auction's](../../docs/audit/known-limitations.md#the-edition-auction));
[trust assumptions](../../docs/audit/trust-assumptions.md#admitted-sale-adapters).
