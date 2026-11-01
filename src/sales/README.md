# sales

The shared sale adapters. Each knows a token only through
[`IMintTarget`](../interfaces/IMintTarget.sol), so the same adapters serve 6529 Stream, 6529
Stream Editions and, from v1.1, federated contracts. The English auction is 6529 Stream's only
primary sale. Editions are sold by rc.2's uniform-price edition auction
([ADR 0005](../../docs/adr/0005-stream-editions-auction.md)), which is not in this folder yet;
ADR 0005 removed the fixed-price and Dutch adapters, which remain at the `v1.0.0-rc.1` tag. A
token admits each adapter one by one with its own governed `setAdmittedMinter` (30 days), so a
new sale type is a new adapter. The rules are in
[Stream and auctions](../../docs/spec/stream-and-auctions.md) (`AUC-*`) and
[Disputes and statements](../../docs/spec/disputes-and-statements.md) (`DSP-13` to `DSP-23`, the
dispute pause); how editions mint is in [Editions and sales](../../docs/spec/editions-and-sales.md).

## Files

| File | What it is |
| --- | --- |
| `EnglishAuction.sol` | [`IEnglishAuction`](../interfaces/IEnglishAuction.sol): permissionless start (mints into its own custody), bids with an anti-snipe window, pull credits, settlement with pending delivery and escrow fallback, the dispute pause, the currency freeze, the emergency pause. Its views are answered by its lens, through a read-only `staticcall` fallback, except `saleKind` and the integration view [`auctionClock`](../interfaces/IEnglishAuctionClock.sol) (an auction's state and end), which contracts read on their hot paths. |
| `EnglishAuctionLens.sol` | The auction's read side, created by its constructor: every view of `IEnglishAuction` and `ISaleAdapter` the auction does not declare (`auction`, `lockedTerms`, `minimumBid`, `pendingDelivery`, `config`, `openingBid`, `claimable`, `paused`, `isTarget`, `saleIdOf`, `federationRegistry`, `escrow`, `statementLog`, `supportsInterface`) and the constants and dependency getters, computed from the auction's storage words (`storageWords`). |
| `UniformClearing.sol` | The pure core of the uniform-price edition auction (D138, ADR 0005), as an internal library: the one-pass clearing rule on [`StepLadder`](../interfaces/types/StepLadder.sol)'s prices, the first-in-first-out split of the cut step and the what-if quote. No adapter uses it yet; the auction adapter is being built on it. |

Permit2 is called through [`ISignatureTransfer`](../interfaces/external/ISignatureTransfer.sol).

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone | `start`, `startWithBid`, `bid`, `settle`, `claimFor` | AUC-14 to AUC-25, AUC-29 |
| A bidder | `claim` of its credits; `withdrawBid` (the high bidder, while paused or frozen); `claimDelivery` | AUC-18, AUC-21, DSP-15 |
| Guardians and governance | The dispute `pause(saleId, …)`, `resume`, `cancel`; `pause()`, `unpause()`; `setConfig`, `setOpeningBid`, `setTarget`, `setFederationRegistry` | AUC-13, AUC-26, AUC-30, DSP-13 to DSP-19; [role matrix](../../docs/audit/roles.md#englishauction) |

Call sequences and errors: [Buying, bidding and settling](../../docs/integrators/buying-bidding-settling.md);
events and their ordering: [Events and indexing](../../docs/integrators/events-and-indexing.md#englishauction).

## Developer notes

- **Bytecode and the lens.** `EnglishAuction`'s write path alone nearly fills EIP-170, so its
  views moved to `EnglishAuctionLens` (about 1,800 bytes of headroom; current margin in the
  [audit scope](../../docs/audit/scope.md#products-and-sales)). The auction creates the lens
  in its constructor and keeps it in an immutable (`lens()`, never replaced); its non-payable
  fallback copies the calldata to the lens with a `staticcall` and returns or reverts with the
  answer unchanged, so a selector neither contract knows still reverts with no data, and ETH
  is refused. The lens reads the auction's storage through `storageWords` and decodes it with
  the auction's layout, so **a change to `EnglishAuction`'s storage layout or to a view's rules
  must change the lens with it**: `EnglishAuctionLensDifferential.t.sol` compares every moved
  view with the pre-lens build (`test/sales/auction/legacy/`), and `EnglishAuctionLens.t.sol`
  pins the layout. A view through the lens costs about 7,000 more gas on chain than before
  (one more cold account and two calls back for storage); nothing the auction does itself
  calls one. **The views other contracts read on their hot paths stay on the auction**:
  `saleKind`, which 6529 Stream and 6529 Stream Editions read in every mint, and
  `auctionClock` (`IEnglishAuctionClock`, outside `IEnglishAuction` and ERC-165), which
  answers `auction`'s state and end from one cold slot and which the edition auction reads in
  `open`, `bid`, `settle` and `withdrawBid`. A new on-chain consumer of an auction view should
  read `auctionClock`, or justify bytes for a new integration view here.
- **The museum rule (D140)** took about 200 bytes before the lens, partly paid back by two
  equivalent rewrites (`claimDelivery`'s single revert site, `withdrawBid`'s redundant zero
  check).
- **Auction storage.** A steady-state start writes one `Sale` word: the token, a 32-bit token
  ID, a 32-bit end time, a 16-bit reference to a shared terms record, the status and flags.
  A terms record (currency, opening bid, increment share, anti-snipe window, a federated
  token's registry fee) is written once per distinct combination; its increment floor is
  written by the first bid. Seller and fee terms come back from the token at settlement, from
  the call that reports the outcome (`IMintTarget.settlePrimary`, owner decision 17).
- **The no-bid recipient (D140, owner decision 17).** `settle` reports SOLD, UNBID or
  FROZEN_OUT to the token; 6529 Stream moves an unsold work to the museum itself and returns it
  as `holder`, which the auction records as the recipient, delivering nothing. Any other
  token's unsold work, listed or federated, goes to the creator the token reports
  (`primaryTerms`). `claimDelivery`'s no-bid claimant (`_unbidClaimant`, L-5) is that creator;
  a 6529 Stream work is never pending (AUC-33). The auction has no museum branch, no `_MUSEUM`
  flag and no Stream constructor argument.
- **Delays counted from the pause.** `unpause`, `resume` and the dispute `cancel` check 48 hours
  from the pause in code, because AccessManager counts a delay from scheduling (GV-23).
- **ERC-20 transfers.** `TokenTransfer` requires exact balance deltas and exactly one `true`
  return word; the Permit2 pull (`EnglishAuction._collect`) checks balance deltas only, so a
  token that returns nothing can pass it. Admitting only standard ERC-20s is the guard
  (ECO-23, LIM-SAL-7).
- **Federated fee recipient.** The auction checks the network's `PRODUCT_FEDERATED` fee
  recipient at start and reads it again at settlement
  ([federated](../federated/README.md#before-installing-a-registry)).
- **Transaction cap and gas.** `EnglishAuctionGas.t.sol` keeps the auction's own gates;
  per-operation gas is in [ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table).
- **Uniform clearing.** `UniformClearing` takes a book as packed words (8 steps of 32-bit live
  units a word, at most 512 steps) and is pure, so the settlement, the views and the Halmos
  proofs share one implementation. Its domain (`isValidLadder`: a base from 100 to 2**96 - 1
  wei, 24, 48, 96 or 192 steps a decade) contains every ladder `StepLadder.isValid` accepts,
  so a book on locked terms always clears. Clearing every one of 336 steps costs about 188K
  Prague gas, plus about 100K to read the 42 words cold (`UniformClearingGas.t.sol`).
- **Tests:** `forge test --match-path 'test/sales/**'` (the auction with its invariant suites;
  `PauseWindow.t.sol` for the 48-hour floors); end to end, `CuratedSale.t.sol`,
  `Dispute.t.sol` and `MasterEdition.t.sol` in [`test/integration/`](../../test/integration/);
  coverage and mutation testing: [Testing](../../docs/testing/README.md).

## See also

[ADR 0001 §5](../../docs/adr/0001-v1-scope.md#5-sales-and-auctions) (with §6, §12 and §16),
[ADR 0003, sales and auctions](../../docs/adr/0003-build-time-decisions.md#sales-and-auctions-amends-adr-0001-5-6-and-9);
[known limitations](../../docs/audit/known-limitations.md#sales-and-auctions);
[trust assumptions](../../docs/audit/trust-assumptions.md#admitted-sale-adapters).
