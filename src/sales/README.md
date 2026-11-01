# sales

The shared sale adapters. Each knows a token only through
[`IMintTarget`](../interfaces/IMintTarget.sol), so the same adapters serve 6529 Stream, 6529
Stream Editions and, from v1.1, federated contracts. The English auction sells 6529 Stream's
1/1s; the uniform-price edition auction sells 6529 Stream Editions beside them
([ADR 0005](../../docs/adr/0005-stream-editions-auction.md), which removed rc.1's fixed-price
and Dutch adapters). A token admits each adapter with its own governed `setAdmittedMinter` (30
days), so a new sale method is a new adapter. The rules are in
[Stream and auctions](../../docs/spec/stream-and-auctions.md) (`AUC-*`),
[Disputes and statements](../../docs/spec/disputes-and-statements.md) (`DSP-13` to `DSP-23`, the
dispute pause) and [Editions and sales](../../docs/spec/editions-and-sales.md) (`EA-*`).

## Files

| File | What it is |
| --- | --- |
| `EnglishAuction.sol` | [`IEnglishAuction`](../interfaces/IEnglishAuction.sol): permissionless start into its own custody, anti-snipe bids, pull credits, settlement with pending delivery and escrow fallback, the outcome reported to the token (`settlePrimary`), the dispute pause, the currency freeze, the emergency pause. |
| `EnglishAuctionLens.sol` | The English auction's read side, deployed before it and pinned by its constructor: every view the auction does not declare, decoded from its caller's storage words (`storageWords`). |
| `UniformEditionAuction.sol` | [`IUniformEditionAuction`](../interfaces/IUniformEditionAuction.sol)'s writes and [`IUniformEditionAuctionStorage`](../interfaces/IUniformEditionAuctionStorage.sol): the bid book (step totals, bids, FIFO departure logs), the coupling with the 1/1's end, settlement in calls of bounded gas, claims through `IMintTarget.mint`, governance. |
| `UniformEditionAuctionLens.sol` | [`IUniformEditionAuctionLens`](../interfaces/IUniformEditionAuctionLens.sol): every view, computed from the adapter's storage words, and the package-item check `open` consults. Stateless and bound to no adapter (it reads its caller): deployed in its own transaction, then pinned by the adapter's constructor (code hash and wiring) and forwards its views to it. |
| `UniformClearing.sol` | Internal library, pure: the D138 clearing on [`StepLadder`](../interfaces/types/StepLadder.sol)'s prices, the FIFO split of the cut step and the what-if quote, shared by the lens, the adapter's sweep and the Halmos proofs. |

Edition bids are ETH; only the English auction calls Permit2
([`ISignatureTransfer`](../interfaces/external/ISignatureTransfer.sol)).

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone | `start`, `startWithBid`, `bid`, `settle`, `claimFor` | AUC-14 to AUC-25, AUC-29 |
| A bidder | `claim` of its credits; `withdrawBid` (the high bidder, while paused or frozen); `claimDelivery` | AUC-18, AUC-21, DSP-15 |
| Guardians and governance | The dispute `pause(saleId, …)`, `resume`, `cancel`; `pause()`, `unpause()`; `setConfig`, `setOpeningBid`, `setTarget`, `setFederationRegistry` | AUC-13, AUC-26, AUC-30, DSP-13 to DSP-19; [role matrix](../../docs/audit/roles.md#englishauction) |
| Anyone (edition auction) | `open`, `bid`, `settle`, `claimBidFor`, every view | EA-1, EA-4, EA-8 to EA-13 |
| An edition bidder | `raise`, `claimBid`; `withdrawBid` while the 1/1 is paused for a dispute; `claim` of its credits | EA-5, EA-9, EA-16 |
| Governance (edition auction) | `pause()`, `unpause()`, `setConfig`, `setTarget`, `setFederationRegistry` | EA-15; [role matrix](../../docs/audit/roles.md#uniformeditionauction) |

Call sequences and errors: [Buying, bidding and settling](../../docs/integrators/buying-bidding-settling.md);
events and their ordering: [Events and indexing](../../docs/integrators/events-and-indexing.md#englishauction).

## Developer notes

- **Bytecode and the lenses.** Both auctions' write paths nearly fill EIP-170
  ([audit scope](../../docs/audit/scope.md#products-and-sales)), so each answers its views from
  a lens deployed in its own transaction before it and pinned by its constructor (`lens()`;
  address, code hash and dependencies), through a fallback that `staticcall`s it: one address,
  one interface, about 7,000 more gas a view. A lens is stateless and reads its caller. A change to `EnglishAuction`'s storage layout or view
  rules must change its lens too (`EnglishAuctionLensDifferential.t.sol`,
  `EnglishAuctionLens.t.sol`). Hot-path views stay on the auction: `saleKind`, and
  `auctionClock` (`IEnglishAuctionClock`), which the edition auction reads and any new on-chain
  consumer should. A rescue for tokens sent by plain `transferFrom` was declined for its size
  (LIM-SAL-10).
- **English auction storage.** A steady-state start writes one `Sale` word and shares a terms
  record per distinct combination; seller and fee terms come back from the token at settlement,
  from the call that reports the outcome (`IMintTarget.settlePrimary`, owner decision 17).
- **The no-bid recipient (D140, owner decision 17).** `settle` reports SOLD, UNBID or
  FROZEN_OUT to the token; 6529 Stream moves an unsold work to the museum itself and returns it
  as `holder`, so a 6529 Stream work is never pending (AUC-33). Any other token's unsold work
  goes to the creator the token reports. Where the work went is read with `ownerOf` after the
  call, not taken from the reported `holder`. The auction has no museum branch of its own.
- **Edition auction storage.** Per sale, a state word (written by every bid), a payout word at
  open and a result word at settlement; live units eight steps to a word; one word per bid;
  departure logs only in capped sales.
- **Settlement in bounded calls.** A call scans at most 24 live words (a scan word keeps its
  place) and sweeps at most 16 departures in the call that clears, 96 in each later one. Each
  settler's progress is its own slot: a call continues its caller's sweep
  (`settlementOrderFor`), the first settler to sweep every departure settles the sale, and an
  order that skips a departure strands only its sender. A differential fuzz holds the Yul scan
  equal to `UniformClearing.clear` (10,000 runs nightly).
- **The edition is bound at open.** `open` calls `Editions.bindMinter(id, item)` before it
  records the sale (ADR 0005 §6), which also snapshots the edition's economics, so the split
  paid is the split the edition reports.
- **Long departure logs.** The lens reads a log four entries per storage word and sorts with a
  heap in Yul, `O(n log n)` in any log order. A keeper pages with
  `settlementOrderFor(saleId, settler, fromPosition, max)`, `O(n log max)`: 21.9M gas for a page
  of 96 at 10,000 departures (`test_F9_AKeeperPagesTenThousandDepartures`). `clearing` and
  `quote` cost about 5,000 gas a departure at the cut step, within a 50M `eth_call` up to about
  9,000; `settlementOrder` up to about 7,000.
- **Withdrawals during a dispute pause** are open only to a bid placed or last raised in a
  minute (from the sale's open) that ended before the pause began: the bid word keeps that
  minute in its 16 spare bits, and `withdrawBid` reads the 1/1's `pausedAt` (ADR 0005 §12).
- **The 1/1's end is cached.** It only moves later, so a bid reads `auctionClock` only within the
  soft-close window of the cached close; settlement and withdrawals always do.
- **Delays counted from the pause.** `unpause`, `resume` and the dispute `cancel` check 48 hours
  from the pause in code, because AccessManager counts a delay from scheduling (GV-23).
- **ERC-20 transfers.** The English auction's Permit2 pull checks only balance deltas, not the
  return word, so admitting only standard ERC-20s is the guard (ECO-23, LIM-SAL-7). It reads the
  federated fee recipient at start and again at settlement
  ([federated](../federated/README.md#before-installing-a-registry)).
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
