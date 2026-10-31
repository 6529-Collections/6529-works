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
| `EnglishAuction.sol` | [`IEnglishAuction`](../interfaces/IEnglishAuction.sol): permissionless start (mints into its own custody), bids with an anti-snipe window, pull credits, settlement with pending delivery and escrow fallback, the dispute pause, the currency freeze, the emergency pause. |
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

- **Bytecode: `EnglishAuction` is the tightest contract in the repository**, barely under
  EIP-170 (current margin in the [audit scope](../../docs/audit/scope.md#products-and-sales)).
  Any addition needs a matching cut; the governed rescue for tokens sent with a plain
  `transferFrom` was declined for its size (LIM-SAL-10). The museum rule (D140) took about 200
  bytes, partly paid back by two equivalent rewrites (`claimDelivery`'s single revert site,
  `withdrawBid`'s redundant zero check).
- **Auction storage.** A steady-state start writes one `Sale` word: the token, a 32-bit token
  ID, a 32-bit end time, a 16-bit reference to a shared terms record, the status and flags.
  A terms record (currency, opening bid, increment share, anti-snipe window, a federated
  token's registry fee) is written once per distinct combination; its increment floor is
  written by the first bid. Seller and fee terms are read back from the token at settlement.
- **The no-bid recipient (D140).** `settle` sends an unbid work of 6529 Stream (the immutable
  `_stream`, a constructor argument) to the resolver's `museum()`, read only on that branch, and
  records `_MUSEUM` beside `_RECIPIENT_SET`. Any other token's unbid work, listed or federated,
  goes to the creator `_lockedTerms` reads from the token. `claimDelivery`'s no-bid claimant
  (`_unbidClaimant`, L-5) is that creator unless `_MUSEUM` is set: a delivery pending for the
  museum is the recorded museum's alone (AUC-33).
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
