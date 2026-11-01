# ADR 0005: The edition auction and 6529 Stream Editions

Status: Accepted by the owner, 31 October 2026, who approved every recommended default
("defaults") and added decision 14 the same day. Recorded by the delivery owner (Claude Code,
acting for the repository owner). Amends [ADR 0001](0001-v1-scope.md),
[ADR 0003](0003-build-time-decisions.md) and [ADR 0004](0004-gas-budgets-under-glamsterdam.md).
The text below is the record as accepted; changes made during the rc.2 delivery are dated
amendments (§6 to §12), and each amended passage points to its amendment.

This is this repository's ADR 0005. The "ADR 0005 (randomness)" that ADR 0001 cites under
"Superseded or amended" is the 6529Stream repository's, a different record.

## Context

v1.0.0-rc.1 sells each 6529 Editions edition through one of two shared mint-sale adapters: a
fixed-price sale with allowlist phases, or a descending-price (Dutch) sale. The artist fixes
the size, format and price in the package. A 6529 Stream 1/1 whose auction draws no bids goes
back to its artist.

On 18 October 2026 the owner replaced both rules. The decisions are recorded in the 6529chain
design log (`design/README.md`, the decision table, D138 to D141, `main` at `3d5fe78`):

- **D138, a uniform-price edition auction.** "6529 Stream Editions are sold by one
  uniform-price auction that decides both how many editions exist and their price, so the
  number is never fixed and nothing is ever unsold." Anyone bids from 0, a price per edition on
  fixed steps about 5% apart, and a quantity; bids are public. At the close, revenue(k) is k
  times the k-th highest bid; the auction takes the count with the highest revenue, then the
  largest count whose revenue is at least 90% of that maximum. Every winner pays the lowest
  winning bid, every other bid is refunded in full, and exactly that many editions are minted.
  A creator may set an optional maximum count. It replaces the fixed-price and Dutch sales; the
  margin, the step size and the length are operational parameters (D86). The owner: "I think
  this is amazing and ideal, we aim for max revenue"; on the 10% margin, "I guess that is
  right"; "these should mint after the 1/1 closes"; "the fixed steps are right too, people
  should see if they would get cards or not at any point in time"; "I think optional cap".
- **D139, the name.** "6529 Editions becomes 6529 Stream Editions"; the program name 6529 Works
  is unchanged. The owner: "I think we should change it from 6529 Editions to 6529 Stream
  Editions".
- **D140, timing and unbid works.** The edition auction runs alongside the piece's 1/1 auction
  and closes 15 minutes after the 1/1 finally closes; the 1/1 keeps its anti-snipe extensions
  and the edition close moves with it. Editions mint after the edition close. A 1/1 with no
  bids goes to the 6529 Network Museum instead of back to its artist. The owner: "it runs 24
  hours but closes I dunno 15 minutes after the 1/1 so people who don't get the 1/1 have a
  chance with editions. and 1/1 can extend beyond 24 hours"; "for zero bids, the correct way is
  to transfer to the 6529 network museum vs back to the artists, it is better incentive
  management". D140 amends D138's "it opens when the 1/1 auction closes".
- **D141, three more rules.** The editions sell whether or not the 1/1 draws bids; an edition
  auction with no bids mints no editions; and the edition auction has its own soft close: a bid
  in its last 5 minutes extends the close to 5 minutes after that bid, and it never closes
  earlier than 15 minutes after the 1/1 finally closes. The window is an operational parameter (D86). The owner: "YES"
  to editions selling without 1/1 bids; "it is OK to not mint the edition if no bids"; "YES" to
  the soft close.

Related chain decisions: D84 (one sale system for The Memes, Stream and Stream Editions), D86
(operational parameters are governed, with terms locked per sale), D67 and D98 (no 6529 entity
holds a privileged role from 2027-01-01), D103 (no TDH-pool caps; it does not conflict with a
creator's edition cap) and D148 (the 6529 Network Museum is a network-held account).

The design was planned on 18 October 2026 against `main` at `02d9f7c`, with a reference model
checked against brute force and a gas prototype. The model is now
[`tools/edition_auction_ref.py`](../../tools/edition_auction_ref.py).

## Decision

### 1. The owner's decisions (31 October 2026)

| # | Decision | Why |
| --- | --- | --- |
| 1 | When a cap binds inside the cut step, units fill in price-time priority (FIFO): a raise rejoins at the back of its new step, the marginal bid is partly filled, and settlement closes the holes with a sorted departure sweep the settler supplies. | It rewards early commitment, never rounds a 1-unit bid away, and sells exactly k. |
| 2 | Bids are never lowered or withdrawn before the close, except that withdrawals open while the 1/1 is paused for a dispute. | Firm bids keep the public live result honest: no spoofing, every shill bid is a real purchase, and R* only rises. |
| 3 | 48 steps per decade (about 4.9%), 336 steps from 0.0001 ETH to 953 ETH, at readable prices from a fixed table; the step size is governed. | Bidders see exactly where they stand, and every client prices a step identically. |
| 4 | The minimum bid is one edition at the base step (0.0001 ETH). | A zero step would let zero bids mint unlimited free editions. |
| 5 | The soft close's total extension is capped at 24 hours (governed); the rule that only winning bids extend is not adopted. | It bounds griefing without the cost and complexity of judging each bid. |
| 6 | Edition auctions take ETH only. | Only ETH sales count for TDH (P29 §5), and hundreds of ERC-20 refunds multiply token risk. |
| 7 | Anyone opens the edition auction, from the 1/1's start; the keeper batches it with the start. | No role is needed, and opening early gives the full bidding window. |
| 8 | `FixedPriceSale`, `DutchSale`, `MintSaleBase` and `DutchPricing` are deleted; `FixedPriceSale` can be restored from v1.0.0-rc.1 if The Memes needs it (D84). | One sale method for editions, about 1,000 fewer audited lines. |
| 9 | An unbid federated 1/1 stays with its artist; the museum rule covers 6529 Stream only. | Federated works are the artist's own contract, outside network curation. |
| 10 | The 30-day currency-freeze exit sends the work to the museum, the same branch as no bids, with the bid refunded. | One unsold outcome, whatever made the work unsold. |
| 11 | The museum's address lives in `EconomicsResolver`, set by FUNDS_SETTER in the 14-day class, wired at genesis. | It is a network-level recipient, the class ADR 0001 §13 reserves for them. |
| 12 | While the 1/1 is disputed, edition bidding continues and withdrawals open; a cancel of the 1/1 voids the edition auction, with full refunds. | A contested work keeps selling, and an upheld dispute leaves nothing minted or paid. |
| 13 | The symbol is `STREAMEDITIONS` and the name "6529 Stream Editions". | D139. |
| 14 | Sale methods stay extensible: a new method is a new adapter that governance admits, with no redeployment of 6529 Stream, 6529 Stream Editions or any federated contract. Federated contracts (v1.1) start with the same two auctions. | The network can add a fixed-price or other sale later without migrating tokens. |

### 2. Design summary

**The adapter.** `UniformEditionAuction`, an `ISaleAdapter` admitted on 6529 Stream Editions,
holds the bid book, the clearing, settlement and claims. Its frozen interface is
[`IUniformEditionAuction`](../../src/interfaces/IUniformEditionAuction.sol).
- Sales are keyed like the English auction's: `saleIdOf(token, id)`, the edition contract and
  the edition ID (the master's 6529 Stream token ID). One adapter can therefore serve every
  listed token and, from v1.1, federated linked pairs (decision 14).
- `open(token, id, data)` is permissionless from the 1/1's start until the edition close. For
  6529 Stream Editions, `data` is the master's package item, checked against the item hash 6529
  Stream stored, so no proof is needed. It locks the creator's cap, the governed parameters
  and the `PRODUCT_EDITIONS` economics. (Amended by [§6](#6-amendment-31-october-2026-the-edition-is-bound-when-its-sale-opens): it also binds the edition to the
  adapter, which records the same economics in 6529 Stream Editions.)
- Bids are ETH, exactly `quantity * price(step)`, from one unit at the base step. `raise` moves
  a whole bid up for exactly the difference. `withdrawBid` works only while the 1/1 is paused.

**The ladder** ([`StepLadder`](../../src/interfaces/types/StepLadder.sol)). Step `i` costs
`basePrice * mantissa((i % N) * (192 / N)) * 10^(i / N) / 100`, the mantissa table rounding
`100 * 10^(j / 192)` half up. `N` is 24, 48, 96 or 192. The defaults run from 0.0001 ETH
through 0.0464, 0.0487 and 0.0511 ETH to 953 ETH. The table is computed by this formula; it is
not copied from a published E-series table.

**The clearing.** One pass over the used steps from the top: each step is a candidate of
`min(D_s, cap)` copies at its price; the scan stops once the demand above a step reaches the
cap; the result is the lowest-priced candidate within the margin of the best. It equals the
per-unit definition of D138, and without a cap no step is ever split. Shares and the margin
use the repository's 100,000 denominator, so the default margin is 10,000.

**Timing.** The edition close is `max(1/1 end + closeOffset, softEnd)`, the 1/1's end read live
from `IEnglishAuction.auction`. A bid in the last `softWindow` sets `softEnd` to
`softWindow` after it, never past `closeAt + maxExtension`.

| The 1/1 is | The edition auction |
| --- | --- |
| ACTIVE, ENDED or SETTLED | Bidding open until the edition close |
| PAUSED (dispute) | Bidding continues whatever the time, without extending; bidders may withdraw. The resumed 1/1 runs at least its governed duration, and the close follows it |
| CANCELLED | VOID: no bids, nothing minted or paid, every bid refunded in full |

**Settlement and claims.** `settle` is permissionless once the edition close has passed and
the 1/1 is SETTLED or CANCELLED. It stores the result, pays `k * price` (the network fee, then
the seller, each through the revenue escrow if refused) and emits `SaleSettled` once, the event
the TDH pipeline weights (P29 §1.2). Copies sold need the edition, which `createEdition`
(unchanged) creates once the master settles. When the cap binds inside the cut step, `settle`
sweeps that step's departures in the position order the settler supplies, chunked and
resumable; claims open when the sweep completes. (Amended by [§9](#9-amendment-1-november-2026-each-settler-sweeps-on-its-own): each settler sweeps on its
own, and claims open when the first sweep completes.) `claimBid` mints a winner's copies and
sends its refund to an address it names; `claimBidFor` lets anyone push a claim, crediting the
refund. Supply reaches exactly k once every winner has claimed.

**6529 Stream Editions** ([`IEditions`](../../src/interfaces/IEditions.sol)).
- `name()` is "6529 Stream Editions" and `symbol()` `STREAMEDITIONS` (D139, decision 13). The
  identifiers `Editions`, `IEditions`, `PRODUCT_EDITIONS` and the `"EDITIONS"` binding label
  stay: renaming them would change genesis keys, tools, selectors and events for nothing a
  collector sees.
- `EditionTerms` becomes `{uint32 maxCount; address currency; bytes32 saleKind; bytes params;}`.
  `maxCount` is the creator's cap (0 for none), and 6529 Stream Editions enforces it for every
  minter. `saleKind`, `currency` and `params` belong to the sale method and are opaque to the
  token and the package registry, which check only a nonzero kind and a bounded `params`
  length (decision 14). The edition auction requires `SaleKind.UNIFORM_AUCTION`, ETH and empty
  `params`. No EIP-712 type changes; the item hash's encoding, package tooling and fixtures do.
  With `price` gone from the terms, `createEdition`'s selector becomes `0x26c8844c`.
- The first adapter to mint an edition is the only one that may mint it again
  (`MinterMismatch`), so a second admitted adapter of the same kind cannot add copies to a
  sale another one ran. (Amended by [§6](#6-amendment-31-october-2026-the-edition-is-bound-when-its-sale-opens): the edition is bound to the adapter whose sale opened
  it, or else to the first to mint it, and that adapter keeps minting it after removal.)
- `formatOf` and the OPEN window (`EditionWindowOpened`, `windowStart`) go with the fixed-price
  and Dutch adapters. Once they and the terms change land, and if nothing else in it changes,
  the `IEditions` interface ID is `0xa41d86b8`. The item hash's golden values change with the
  terms (`test_itemHash_golden`). (Amended by [§6](#6-amendment-31-october-2026-the-edition-is-bound-when-its-sale-opens): with `bindMinter` it is `0xe183b26f`.)

**The museum.** `IEconomicsResolver.museum()` names the 6529 Network Museum; `setMuseum`
(compare-and-set on its own revision, as the resolver's other setters are) changes it. A
canonical work, any token governance listed, whose 1/1 settles with no bid, or ends unsold
after its currency stayed deprecated for 30 days, goes to the museum. A federated work goes to
its artist. Governance lists 6529 Stream alone on the English auction (`setTarget` at genesis),
so this is decision 9's rule; listing another token there would send its unbid works to the
museum too. Only a federated work's artist may claim a pending delivery in the recipient's
place (L-5), so no artist can take the museum's. The museum is a recipient chosen by the
auction adapter and the resolver, not a hook in Core (ADR 0001 §15). (Amended by [§7](#7-amendment-31-october-2026-the-museum-branch-is-gated-on-6529-stream-in-code), then
[§11](#11-amendment-31-october-2026-stream-records-each-11s-primary-sale-outcome-owner-decision-17): 6529 Stream itself moves an unsold work to the museum.)

### 3. Adding a sale method (decision 14)

Sale methods are adapters, and a token mints for any admitted adapter whose kind its terms
name. No token contract hard-wires a minter.
- **Kinds are claimed, not enumerated.** A kind is `keccak256` of its name
  ([`SaleKind`](../../src/interfaces/types/SaleTypes.sol)); an adapter reports its own from
  `saleKind()`. A token mints only for an admitted adapter whose kind equals the edition's
  terms. Labels are never reused for a different method.
- **Terms are opaque to the token.** The package registry and 6529 Stream Editions check only
  the generic shape of `EditionTerms`. The adapter validates its own `currency` and `params`
  when it opens a sale, and refuses unusable terms (`InvalidSaleTerms`).
- **Admission is governed.** `setAdmittedMinter(adapter, true)` on each token, SUCCESSOR_SETTER
  in the 30-day class, as today. The adapter's own settings (`setTarget`,
  `setFederationRegistry`, pause) are mapped at the same time.

**Worked example: restoring a fixed-price sale.**
1. Port `FixedPriceSale` and the parts of `MintSaleBase` it needs from the `v1.0.0-rc.1` tag.
   It keeps its label, `SaleKind.FIXED_PRICE`, and reads its unit price, phases and caps from
   `EditionTerms.params` (for example `abi.encode(price, phases)`), since `price` is no longer
   a field. The OPEN window does not return.
2. Review it, deploy it, and schedule `Editions.setAdmittedMinter(fixedPriceSale, true)` and its
   `setTarget(editions, true)` (both 30 days), with its selectors in the governance manifest.
3. Packages approved afterwards may name `FIXED_PRICE` with those params. Editions sold by the
   auction are untouched: each edition stays with its first minter. (Amended by [§6](#6-amendment-31-october-2026-the-edition-is-bound-when-its-sale-opens): the
   adapter calls `Editions.bindMinter(editionId, item)` when a sale opens, and each edition
   stays with the adapter that opened its sale.)

Nothing in 6529 Stream, 6529 Stream Editions or a federated contract is redeployed. The cost is
a guarantee rc.1 had: the token no longer knows every valid kind, so a master whose edition
terms name a kind no admitted adapter serves still mints. The curation signer's tooling must
therefore check that the named kind has an admitted adapter that would open the item, as it
already simulates `openRecord` (LIM-EA-8).

### 4. Governed parameters and delay classes

The edition auction's parameters are one `AuctionConfig`, set by `setConfig(expected, next)`
(compare-and-set, bounds in code) and locked into each sale when it opens (D86).

| Parameter | Default | Bounds | Role and class |
| --- | --- | --- | --- |
| Breadth margin (D138) | 10% (10,000 of 100,000) | 0 to 50% | PARAMETER_SETTER, 48 hours |
| Steps per decade (the step size) | 48 | 24, 48, 96 or 192 | PARAMETER_SETTER, 48 hours |
| Base price | 0.0001 ETH | 10^12 to 10^17 wei; a power of ten since [§8](#8-amendment-31-october-2026-base-prices-are-powers-of-ten) | PARAMETER_SETTER, 48 hours |
| Steps | 336 | 64 to 512, with a top step of at least 10 ETH | PARAMETER_SETTER, 48 hours |
| Close offset after the 1/1 (D140) | 15 minutes | 0 to 1 day | PARAMETER_SETTER, 48 hours |
| Soft-close window (D141) | 5 minutes | 1 minute to 1 hour | PARAMETER_SETTER, 48 hours |
| Extension backstop (decision 5) | 24 hours | 1 hour to 7 days | PARAMETER_SETTER, 48 hours |
| The museum (decision 11) | The 6529 Network Museum Safe | Nonzero, not a protocol contract | FUNDS_SETTER, 14 days |

- **Fixed in code**, changed only by a new adapter: the clearing rule, firm bids, ETH, FIFO at
  the cut step, the mantissa table and the bounds.
- **Other selectors.** The edition auction's `pause` is PAUSER (immediate) and blocks new opens
  only; `unpause` is UNPAUSER (48 hours, and no earlier than 48 hours after the pause);
  `setTarget` and `setFederationRegistry` are SUCCESSOR_SETTER (30 days). Admitting it on 6529
  Stream Editions is `setAdmittedMinter`, SUCCESSOR_SETTER (30 days). Every other function is
  permissionless.
- **PLATFORM loses its sale selectors**: no adapter has `openSale` or `closeSale`.
- The top-step floor is the integrator's: it stops a configuration that would cap every
  edition's price below plausible demand (a 1.2% ladder from 0.0001 ETH over 512 steps tops
  out at 0.046 ETH).
- (Note, 1 November 2026, from the rc.2 review, with [§8](#8-amendment-31-october-2026-base-prices-are-powers-of-ten)'s
  power-of-ten bases.) The 10 ETH top-step rule leaves these ladders reachable, each from the
  fewest steps shown up to 512:

  | Base | 24 per decade | 48 per decade | 96 per decade | 192 per decade |
  | --- | --- | --- | --- | --- |
  | 0.000001 ETH (10^12 wei) | 169 steps | 337 | no (top 0.21 ETH) | no |
  | 0.00001 ETH | 145 | 289 | no (top 2.1 ETH) | no |
  | 0.0001 ETH (the default) | 121 | 241 | 481 | no (top 0.046 ETH) |
  | 0.001 ETH | 97 | 193 | 385 | no (top 0.46 ETH) |
  | 0.01 ETH | 73 | 145 | 289 | no (top 4.6 ETH) |
  | 0.1 ETH (10^17 wei) | 64 | 97 | 193 | 385 |

  So 192 steps per decade works only from a 0.1 ETH base, and 96 per decade needs a base of at
  least 0.0001 ETH.

### 5. Gas budgets (ADR 0004)

From the prototype and the reference model (planning figures; the implementation re-measures
them), in Prague gas for a whole transaction:

| Operation | Budget or ceiling | New slots |
| --- | --- | --- |
| `bid` | at most 110,000 | 1 (the bid), plus 1 when it opens an 8-step word of totals, and in a capped sale 1 more for that word's queue counters |
| `claimBid`, a winner and new holder | at most 100,000 | at most 1 |
| `settle`, 40 or fewer used steps | at most 400,000 | 1 (and 1 new account on a seller wallet's first payout) |
| `settle`, every step used (adversarial, up to 512 steps) | at most 1,000,000 | 1 |
| `open`, `raise`, `withdrawBid`, `claimBidFor`, a refund-only claim | regression ceilings when first measured | exact counts |
| An unbid 1/1's `settle`, to the museum | within the existing 400,000 `settle` ceiling (the museum read adds about 5,000) | exact counts |

A winner's bid and claim together cost about 165,000 to 195,000 Prague gas and 2 new slots,
about 345,000 to 375,000 on Glamsterdam: about 1.5 times rc.1's fixed-price purchase. The
`start` budgets are unchanged.

### 6. Amendment (31 October 2026): the edition is bound when its sale opens

An integrator amendment of the frozen interface, made before the adapter shipped. As first
frozen, 6529 Stream Editions bound an edition to the first adapter that minted it, and the
edition auction mints at claim time. Two admitted adapters of one kind (an old and a new
uniform auction during an upgrade) could then both open sales of the same edition: the first
claim bound it to one of them, and the other sale's winners could never claim, though its
seller had been paid.

- **`IEditions.bindMinter(editionId, item)`.** The caller must be admitted, and its
  `saleKind()` (since [§12](#12-amendment-1-november-2026-fix-pass-a-of-the-rc2-review), the
  kind recorded at its first admission) must be the edition's: the stored kind once the
  edition exists, and before
  that the kind in `item`, which must be the master's EDITION_MASTER item (its hash equal to
  the item hash 6529 Stream stored). An unbound edition is bound to the caller
  (`EditionMinterBound`); a call by the bound adapter is a no-op; any other reverts with
  `MinterMismatch`. The binding lives in the edition's record and survives `createEdition`.
  `mint` keeps its own check, and still binds an edition no sale bound.
- **The edition auction binds at open**, before it records the sale, passing the item it
  received. A second adapter's open of a bound edition reverts, so only one sale ever sells
  an edition. `open` is permissionless, but it can bind only the adapter whose kind the
  master's stored item names, and only governance admits adapters. There is no re-open: a
  sale ever opened, voided ones included, refuses `open` (`AuctionExists`).
- **The economics are snapshotted at the binding.** Binding an edition that does not exist yet
  locks its `PRODUCT_EDITIONS` economics (seller, network fee, royalty receiver) in the
  transaction in which the sale locks its own, and `createEdition` keeps them; for an edition
  that already exists, the sale reads the economics it recorded. So `edition(id)` always
  reports the split its sale paid, whatever governance changes in between.
- **Removal does not strand winners.** A bound adapter keeps minting its own edition after
  governance removes it, within the creator's cap, because its sale has already paid the
  seller. Removal stops new sales: `bindMinter`, and a mint of an unbound edition, need an
  admitted caller (LIM-EA-10).
- **Interface and gas.** `IEditions` gains `bindMinter` (selector `0x459e34d7`), and its
  interface ID becomes `0xe183b26f`. The binding's and the snapshot's slots move from
  `createEdition` to `open`: on the wired stack, `open` writes 6 new slots instead of 2
  (278,235 Prague gas at steady state) and `createEdition` of a bound edition 2 instead of 6
  (140,201), about 20,000 more for the pair, the item hashed and checked a second time.
  An edition created unbound still writes 6.

### 7. Amendment (31 October 2026): the museum branch is gated on 6529 Stream in code

Superseded by [§11](#11-amendment-31-october-2026-stream-records-each-11s-primary-sale-outcome-owner-decision-17): Stream now moves an unsold work to the museum itself, and the English
auction has no museum branch. Kept as history.

Made by the museum lane (PR #75). As accepted, §2 sent the unbid work of any token governance
listed on the English auction to the museum, and relied on governance listing 6529 Stream alone
for decision 9. The English auction now takes 6529 Stream as a constructor argument and gates
the museum branch on it, so decision 9 holds in code:

- A 6529 Stream work whose 1/1 settles with no bid, or ends unsold after its currency stayed
  deprecated for 30 days, goes to the museum the resolver names at settlement.
- Any other token's unbid work, federated or listed later by governance, goes to its artist.
- A delivery pending for the museum is claimed only by the museum recorded at settlement; for
  any other token the artist may also claim in the recipient's place (L-5), so no artist can
  take the museum's.

### 8. Amendment (31 October 2026): base prices are powers of ten

Made by the clearing lane (PR #78). §4 bounded the base price to 10^12 to 10^17 wei.
`StepLadder.isBasePrice` also requires a power of ten, so every price is a table mantissa times
a power of ten and reads as the table does (decision 3, readable prices from a fixed table): a
base of 0.00015 ETH would price the next steps at 0.0001575 and 0.000165 ETH instead of 0.000105
and 0.00011. The default, 0.0001 ETH, is one.

### 9. Amendment (1 November 2026): each settler sweeps on its own

Made by the adapter lane (PR #77), after a review finding of 31 October. As designed in §2, the
cut step's departure sweep was one resumable sweep that any settler continued. A settle call
whose order skipped a departure (positions still strictly increasing) was accepted and moved the
shared sweep past it, so the sweep could never finish: the sale stayed SETTLING and no bid could
be claimed.

- Each settler (`msg.sender`) keeps its own progress and passes the rest of its own sweep on
  each call (`settlementOrderFor`); the first to sweep every departure fixes the cutoff, and
  claims open. An order that skips a departure strands only its own sender, who settles from
  another address; nobody's progress touches another's or the result.
- A call sweeps at most 16 departures in the call that clears and 96 after.
  `DeparturesSwept` reports the caller's progress, so interleaved settlers' events can show
  `swept` going down. A call on a settled sale returns `true`.
- A shared public relayer such as Multicall3 is one settler for all its callers, who would
  share one sweep: keepers settle directly or through their own contract
  ([runbook](../../script/README.md#the-edition-auction-keeper)).
- LIM-EA-4 now reads: a dense book's settlement costs more calls, each of bounded gas, and a
  griefer's sweep never blocks a keeper's.

### 10. Amendment (31 October 2026): Stream's dependency pointers are governed (owner decision 16)

Made by PR #81, with the review fixes of #80 and #81.

- **The pointers.** Stream's package registry, artist registry, economics resolver and entropy
  module are replaceable by governance (`setDependency`, SUCCESSOR_SETTER, the 30-day class,
  compare-and-set); Stream's code and address stay immutable, with no proxy, and the split
  factory stays fixed. Existing tokens are unaffected: ownership, the terms and royalty receiver
  locked at mint, a finalized work's pinned renderer and a VRF work's seed, which always comes
  from the entropy module the work minted under (`entropyModuleOf`; the review of #81 found that
  the renderer and `openRecord` read the current module, so a replacement could change or break
  the seed of a work whose record was not open yet).
- **Who follows.** 6529 Stream Editions and `WorkRecords` read the pointers from Stream instead
  of copying them, so a replacement reaches them at once. Contracts wired to the same
  dependencies on their own (one-shot binds, pinned code hashes, the auctions' economics
  resolver: the edition auction's lens copies it at construction) do not follow, so a
  replacement is a set planned with them
  ([the procedure](../../script/README.md#replacing-one-of-streams-dependencies)). Stream's
  immutable split factory keeps the genesis artist registry as the payout resolver of every
  Stream work, so that registry is only partly replaceable (LIM-GV-16). The artist registry's
  one `register` caller is governed (`setPackageRegistry`, 30 days), so a successor package
  registry onboards new artists.
- **Cost.** The genesis contracts stay immutables, with a replacement bit each in the counter
  word every mint already reads, so a start with no replacement reads no extra slot: about +820
  Prague gas. An artist's first two-party start with a bid is 339,511, and with a VRF seed
  347,186, 2,814 under 350K ([ADR 0004's table](0004-gas-budgets-under-glamsterdam.md#the-table)).
- **The kind recorded at admission (the review of #80).** `mint` compares an item's sale kind
  with the adapter's kind recorded at its first admission, the kind `primaryTerms` reports,
  instead of the adapter's live `saleKind()` (about +1,530 Prague gas, the kind kept in the
  minter word `mint` reads), so a later change of an adapter's `saleKind()` changes nothing for
  Stream. This amends the decision 15 note under [Open items](#open-items).
- **Metadata survives a faulty records satellite.** Stream is permanent and `WorkRecords` is
  bound once, so `rendererOf` reads `pinnedRenderer` with a fixed gas cap and one word back, and
  serves the default renderer on any fault but a changed pinned renderer's
  `DependencyCodeChanged`, which still fails closed (WS-16, RND-28). Cost: Stream +224 bytes.

### 11. Amendment (31 October 2026): Stream records each 1/1's primary-sale outcome (owner decision 17)

Made by PR #82. It supersedes [§7](#7-amendment-31-october-2026-the-museum-branch-is-gated-on-6529-stream-in-code)
and amends the decision 15 note under [Open items](#open-items).

- **The outcome.** The minting adapter's settlement call carries it:
  `IMintTarget.settlePrimary(id, outcome, buyer, currency, price)` replaces
  `markPrimarySettled(id)`. Stream stores SOLD, UNBID or FROZEN_OUT in two bits of the token's
  flags word, and for SOLD the currency and the price (96 bits, saturated) in one new word;
  `primarySale(id)` answers them, and `PrimarySaleSettled` names the outcome, the buyer, the
  currency and the exact price. The same call returns the seller and fee terms the adapter pays
  by (`PrimarySettlement`), so the English auction's `settle` no longer reads `primaryTerms`.
- **Stream moves unsold works to the museum.** For UNBID and FROZEN_OUT Stream itself moves the
  work out of the adapter's custody to `IEconomicsResolver.museum()`, read at that moment, with
  no receiver callback, and never to the artist. The English auction no longer has a museum
  branch, a `_MUSEUM` flag or a Stream constructor argument: it reports the outcome (FROZEN_OUT
  for the freeze exit and a delisting) and delivers only what it sold, or another token's
  unsold work to its creator. 6529 Stream Editions answers `settlePrimary` as a no-op (copies
  are sold at mint); a token other than Stream returns `holder` zero.
- **Enforced on-chain.** The museum rule (D140, decisions 9 and 10) holds for every sale an
  admitted adapter settles, except a deliberately false SOLD report, for example one naming the
  artist as the buyer of a work nobody bought: Stream cannot tell a false sale from a true one,
  and refusing the artist as a buyer would block an artist buying their own work. An adapter
  can also bypass the call: Stream lets a holder transfer an unsettled work
  (`test_transfersDoNotSettle`) and the minting adapter burn one, so an adapter that never
  settles can hand an unsold work to anyone; such a work stays NONE in `primarySale` and its
  edition can never be created. Refusing transfers of unsettled works would cost about 2,100 gas
  on every later transfer of every work, so it is left to the admission review.
  *Amended 1 November 2026 (owner decision 20):* a work an adapter minted and still holds,
  unsettled, 90 days after governance removed that adapter, can be moved to the museum by
  `Stream.rescueToMuseum` (SUCCESSOR_SETTER, 30 days), which settles it as UNBID. A work the
  adapter handed to anyone else is not touched ([AUC-35](../spec/stream-and-auctions.md#rules-and-invariants)).
- **The admission requirement** (decisions 9, 10, 15 and 17). Any 1/1 sale adapter admitted for
  6529 Stream must settle each sale with Stream (`settlePrimary`) and report its true outcome:
  SOLD with the buyer who paid, the currency and the price; UNBID when the sale ended with no
  bid; FROZEN_OUT when it ended unsold because its currency stayed frozen. Governance checks this
  in the 30-day review before `Stream.setAdmittedMinter(adapter, true)` executes, with the three
  cases on-chain enforcement leaves to it (a false SOLD, a work moved without settling, a burn
  outside a cancel); a guardian vetoes an admission that does not hold it.
  `StreamSaleMethods.t.sol` (`test_ASecondAdapterSendsAnUnbidWorkToTheMuseum`) shows a second
  adapter's unbid work landing in the museum without the adapter moving it.
- **Cost** ([ADR 0004's table](0004-gas-budgets-under-glamsterdam.md#the-table)): the English
  `settle` with a bid writes one new slot (the sale record) and costs more; with no bid it costs
  less. Also useful for TDH: P29 shares the Works pool by realized ETH price.
- (Note, 1 November 2026, owner decision 22.) Every unsold canonical 6529 Stream 1/1 goes to
  the museum whatever its sale method, with no exceptions: no 1/1 adapter admitted for 6529
  Stream may return an unsold work to its creator. A sale that returns unsold works to their
  creators belongs in its own collection, outside 6529 Stream.

### 12. Amendment (1 November 2026): fix pass A of the rc.2 review

Made by fix pass A (the edition auction, its lens, 6529 Stream Editions and `EditionRules`)
after the rc.2 seven-lens review.

- **Withdrawals during a dispute pause (markets M-1; amends decision 12 and §2).** Decision 12
  opened withdrawals while the 1/1 is paused so that bidders already committed to a contested
  work can leave it. As built, any bid could leave, including one placed during the pause, so a
  pause let anyone post demand, induce firm raises, and withdraw in the pause's last second at
  no cost (decision 2's "no spoofing" lapsed), and a flash-funded bid-and-withdraw could fill a
  step's 32-bit position counter for good (clearing Info 1). Now a bid may be withdrawn only if
  it was placed, or last raised (a raise is new demand), in a minute, counted from the sale's
  open, that ended before the pause began. Each bid word keeps that minute in its 16 spare bits
  (capped at 65,535, which never counts as early); the adapter reads the 1/1's `pausedAt` when a
  withdrawal is asked. A bid placed during the pause, in the pause's own minute, or in the
  withdrawal's block stays, so decision 12's purpose holds and spoofing does not. The lens's
  `canWithdraw(saleId, bidId)` answers for one bid; `EndTimes.withdrawalsOpen` still means "the
  1/1 is paused". `withdrawBid` reads the 1/1 through `auction()`, about 10,000 more gas (the
  regression ceiling is 103,000).
  *Amended 1 November 2026 (PR #89, fix pass B):* `IEnglishAuctionClock.auctionClock` also
  returns the 1/1's `pausedAt`, and `withdrawBid` reads it there, from the English auction
  itself rather than through its lens. The withdrawal costs about what it did before F3
  (88,019; regression ceiling 90,000).
- **One source of truth for edition economics (LC-1, MONEY-L1, G-1).** The lens held a copy of
  the economics resolver taken at construction, while Editions reads 6529 Stream's current
  one, so after a resolver replacement (owner decision 16) a sale paid the old split and its
  edition reported the new one. `IEditions.bindMinter` now returns the `WorkTerms` it locks
  (an existing edition's as recorded, `royaltyRate` zero until the edition exists), and the
  adapter pays exactly those; the lens keeps only a preview of them to refuse unpayable terms
  at open (CALLS-1), read from Stream's current resolver. The selector, and so the `IEditions`
  interface ID, is unchanged.
- **The kind recorded at admission (governance L-3).** Editions now compares the kind an
  adapter reported at its first admission (kept through removal and re-admission, as 6529
  Stream does since decision 15), not its live `saleKind()`, and refuses to admit an adapter
  that reports none.
- **The lens in its own transaction (gas M-2).** The adapter's single deployment carried the
  lens's creation (42,006 code bytes), about 68M gas under Glamsterdam: over a 60M block. The
  lens is now deployed first, in its own CREATE2 entry of `DeployV1`, and is bound to no
  adapter: it reads every sale from its caller. The adapter's constructor takes the lens and its
  expected code hash and checks the code hash, the code and that the lens's immutables
  (Editions, Stream, English auction, escrow) are its own.
- **Long departure logs (gas M-1).** The lens reads a log four entries per storage word and
  sorts with a heap in Yul. A keeper pages with `settlementOrderFor(saleId, settler,
  fromPosition, max)`, `O(n log max)`: 21.9M gas for a page of 96 at 10,000 departures. Measured
  through the adapter with the log in its worst order, `clearing` and `quote` cost about 5,000
  gas a departure at the cut step and stay within a 50M `eth_call` up to about 9,000;
  `settlementOrder` up to about 7,000 and `departures` up to about 8,000.
- **Edition params are at most two words (gas L-1).** `EditionRules.MAX_PARAMS_BYTES` is 64,
  down from 1,024: the master's 1/1 `start` carries the item, and at 1,024 bytes the binding
  start row (an artist's first two-party work with a bid and a VRF seed) was 361,211 Prague
  gas, over its budget; at 256, 348,132 and at 128, 345,988, both over the row's 5,000 margin.
  At 64 every start row stays inside 350,000 less the margin: that row is 344,887 for a master
  at the bound, and the steady-state master start 268,959. The design rule: a sale method
  whose parameters do not fit two words commits to a hash of them in `params` and takes the
  full data when its sale opens, checking it against that hash, for example
  `params = abi.encode(keccak256(extra))` with `open`'s `data = abi.encode(item, extra)`.
  Once the edition exists, the hash is the one it records (`edition(id).terms.params`), never
  the caller's copy of the item: `bindMinter` checks a caller's item against 6529 Stream only
  before the edition exists. `test_F10_AnAdapterTakesLongParamsByHash` and
  `test_F10_TheRecordedHashGovernsOnceTheEditionExists` prove the path with a mock adapter.

## What this amends

ADRs stay as written; each gets a pointer to this record.

**[ADR 0001](0001-v1-scope.md)**
- **§1, §2, §6: the name.** 6529 Editions is 6529 Stream Editions (D139).
- **§3: the package.** An edition master commits an optional maximum count and a sale kind
  with its currency and params, not a size, format and price.
- **§5: sales.** v1 ships two shared adapters, the English auction and the uniform-price
  edition auction; fixed price and Dutch are removed (decision 8). Editions sell only by the
  edition auction, until governance admits another method (decision 14). Edition auctions take
  ETH only (decision 6). "If there are no bids, the NFT goes to the artist" becomes: to the 6529
  Network Museum for 6529 Stream, and to the artist for a federated work (D140, decision 9).
- **§6: editions.** The artist chooses only an optional cap; the auction decides the count and
  the price. No allowlist phases and no ERC-20 or permit payments for editions. The edition's
  sale opens from the 1/1's start; `createEdition` still follows the master's settlement.
- **§12: disputes.** While the 1/1 is paused, its edition auction keeps taking bids and its
  bidders may withdraw; an upheld dispute's cancel voids it. The 30-day freeze exit that ADR
  0003 added sends a 6529 Stream work to the museum (decision 10).
- **§16: federation.** Federated contracts start with the same two auctions, and further
  methods are adapters governance admits (decision 14). "Gifting is a zero-price adapter sale"
  has no adapter in v1. An unbid federated 1/1 stays with its artist.
- **§17: reuse.** The ported allowlist phases, ERC-20 permits for editions and Dutch pricing
  leave v1; they remain at `v1.0.0-rc.1`.
- **Non-goals.** "Editions keep fixed-price and Dutch sales" no longer holds: editions sell by
  the uniform-price auction. Clearing sales stay a non-goal for 6529 Stream's 1/1s.

**[ADR 0003](0003-build-time-decisions.md)**
- **Sales and auctions.** The fixed-price allowlist bullets and "Dutch sales have no clearing
  price" leave with the adapters. "An edition opens only after its master's sale settles" now
  covers `createEdition` only. The no-bid outcome is the museum for 6529 Stream. The emergency
  pause of the edition auction blocks only new opens.
- **MARKET-6 is retired.** No sale is configured by its seller any more: the edition auction
  opens permissionlessly at the package's terms, and the cap is the creator's only input, signed
  with the package. Artist approval of a sale has nothing left to approve.
- **Owner decision 6 (the restraint).** PLATFORM no longer runs edition sales during a
  restraint, and an unbid 6529 Stream work's settlement no longer waits for one; a federated
  work's still does.
- **The selector table.** "Sale adapters `openSale`, `closeSale`: zero-delay PLATFORM" is
  removed. The `setTarget`, `setFederationRegistry` and `pause`/`unpause` rows cover the edition
  auction. New: `UniformEditionAuction.setConfig`, standard (48 hours), compare-and-set with
  bounds; `EconomicsResolver.setMuseum`, funds and recipients (14 days), compare-and-set.

**[ADR 0004](0004-gas-budgets-under-glamsterdam.md)**
- The table gains the edition auction's rows with the budgets in §5, each with exact counts of
  new slots and accounts. The `openSale`, `purchase` and Dutch `createEdition` rows leave with
  their adapters; `createEdition` stays.

## Known limitations

These are accepted; the [known limitations](../audit/known-limitations.md) page takes them
over as the edition auction lands.

- **LIM-EA-1: soft-close griefing up to the backstop.** Under D141 any bid extends the close, so
  a 0.0001 ETH bid every 5 minutes keeps the auction open for the cost of gas alone, until the
  24-hour backstop. Only winning bids extending was considered and not adopted (decision 5).
- **LIM-EA-2: the breadth-rule tilt.** Volume at a lower step can lower the price within the
  margin: on the default ladder one unit at 0.0464 turns 80 at 0.0511 into 81 at 0.0464, and
  revenue falls 8%. A large winner can use this to cut its own price. It is D138's intent;
  revenue stays at least (100% - margin) of R*, and R* never falls.
- **LIM-EA-3: shill bidding.** A creator, or anyone, bidding from unlinked wallets sets a
  de facto reserve or inflates the count. Bids are firm and public, so every shill bid is a real
  purchase that pays the network fee; bids from unlinked wallets cannot be stopped on-chain.
- **LIM-EA-4: a dense book's settlement cost.** Filling every step raises `settle` to about
  700,000 Prague gas (at most 1,000,000 with 512 steps), paid by the settler; it costs an
  attacker far more in bids. A capped auction's departure sweep adds about 2,500 gas per
  departure at the cut step, chunked across calls. (Amended by [§9](#9-amendment-1-november-2026-each-settler-sweeps-on-its-own): 16 departures in the
  clearing call and 96 after, each settler sweeping on its own.)
- **LIM-EA-5: demand reduction.** Marginal bidders bid the lowest step that gets in. It is
  inherent to a uniform price, and visible on the public ladder.
- **LIM-EA-6: last-block ordering.** A block builder can reorder or censor bids in the final
  blocks. The soft close restarts 5 minutes (about 25 blocks); exact step payments leave no
  slippage to exploit.
- **LIM-EA-7: supply follows claims.** Copies exist only once winners claim; `totalSupply`
  reaches k when every winner has. Unclaimed refunds stay in the adapter, claimable forever.
- **LIM-EA-8: a kind with no adapter.** Because kinds are opaque to the tokens (decision 14),
  a master whose edition terms name a kind no admitted adapter serves still mints; its edition
  then cannot be sold until such an adapter is admitted. The curation signer must check this
  before attesting.
- **LIM-EA-9: a frozen 1/1 delays editions.** An ERC-20 1/1 frozen by a currency deprecation
  (MARKET-2) delays the edition settlement until the 1/1 settles, up to 30 days. 6529 Stream
  launches in ETH, which is never deprecated in practice.
  *Amended 1 November 2026 (PR #89, the rc.2 review's MONEY-M1 and G-2):* ETH can no longer
  be deprecated at all. `AssetAllowlist.deprecateAsset` refuses it (`EthNotDeprecable`,
  [ECO-38](../spec/economics-and-payouts.md#rules-and-invariants)), so an ETH 1/1 never
  freezes.
- **LIM-EA-10: claims need the adapter admitted.** Copies are minted at claim, and 6529 Stream
  Editions refuses mints from a removed adapter (ED-5). Governance therefore removes an edition
  auction only once its settled sales are claimed; `claimBidFor` lets anyone push the remaining
  claims first. The removal is a 30-day operation, visible in advance. (Amended by [§6](#6-amendment-31-october-2026-the-edition-is-bound-when-its-sale-opens): it now
  reads "a removed adapter still mints the editions it sold". Copies are minted at claim, after
  the seller was paid, so Editions lets an edition's bound adapter mint it after removal and
  governance cannot stop a removed adapter's claims on editions it already sold; the creator's
  cap still bounds them, removal stops every new sale, and an adapter is admitted only after a
  30-day review.)
- **LIM-EA-11: an edition auction nobody opens in time.** (Added with [§6](#6-amendment-31-october-2026-the-edition-is-bound-when-its-sale-opens).) `open` is accepted until the 1/1's
  end plus the close offset. If nobody opens it by then, this adapter can never sell that
  work's editions. The edition is still unbound, so a later admitted adapter of its kind can
  open it (decision 14). The keeper opens the edition auction in the same batch as the 1/1's
  start (decision 7; [runbook](../../script/README.md#the-edition-auction-keeper)).
- **LIM-EA-12: settlement waits for `createEdition`.** (Added 1 November 2026 with the adapter, PR #77.) A sale with winners settles only once
  the edition exists (`EditionNotCreated`). `createEdition` is permissionless and
  deterministic once the 1/1 settles, but it takes the master's item, its package root and a
  Merkle proof, which the frozen `settle(saleId, order)` and `claimBid` cannot carry, and the
  adapter has no bytecode to store them. So a keeper or any participant creates the edition
  first ([runbook](../../script/README.md#the-edition-auction-keeper)).

## Alternatives considered

- **Keep fixed price and Dutch beside the auction.** Rejected (decision 8): two methods to audit
  and explain, and neither finds the count. Restorable as adapters (decision 14).
- **Pro-rata or all-or-nothing at a capped step.** Pro-rata rounds small bids to zero or needs
  the same prefix machinery; all-or-nothing mints below the cap, and one large order can block
  a step. A lottery needs a VRF round trip.
- **A geometric `ratio^i` ladder.** It costs O(i) per lookup or rounds differently at the bid and
  at settlement.
- **Only winning bids extend the soft close.** About 100,000 more gas per bid in the window, for
  a griefing the 24-hour backstop already bounds.
- **An enumerated `SaleKind` in the tokens.** Adding a value would redeploy the tokens; claimed
  labels need nothing (decision 14).
- **A `StreamEditions` contract name.** It shows only on Etherscan, and would rename genesis
  keys, tools and events.

## Security impact

- **Money.** Every bid is fully escrowed and refunded by pull; the adapter must hold exactly the
  live escrow plus credits. Payouts keep the escrow fallback. Claims are never blocked by a
  pause.
- **Removed surface.** About 1,000 lines of fixed-price and Dutch code, their Permit2 and
  allowlist paths and PLATFORM's sale selectors leave the audit scope.
- **New surface.** The clearing arithmetic, the settler-supplied departure order (checked
  strictly increasing and complete), the live coupling to the English auction's end, and the
  museum branch in `EnglishAuction`, which has about 215 bytes of EIP-170 headroom.
- **Review.** A focused adversarial review with seven lenses follows the build: money,
  markets and MEV, calls, governance, lifecycle, clearing math, and gas and denial of service.

## Delivery plan

1. **L0 (this record):** this ADR, the frozen interfaces (`IUniformEditionAuction`,
   `StepLadder`, `SaleKind.UNIFORM_AUCTION`, the museum on `IEconomicsResolver`, `name` and
   `symbol` and `MinterMismatch` on `IEditions`, the museum behaviour on `IEnglishAuction`), and
   the golden vectors in `test/fixtures/edition-auction/` from the reference model.
2. **In parallel:**
   - L1: the clearing library and its Halmos proofs, against the reference model;
   - L2: `UniformEditionAuction`, with a stateless lens if it outgrows EIP-170;
   - L3: `Editions`, `EditionRules` and the `EditionTerms` change, deleting the fixed-price and
     Dutch adapters, genesis, Deploy and Verify, the role matrix and the rename; it lands the
     terms change that L2 reads (`maxCount`);
   - L4: the museum in `EnglishAuction` and `EconomicsResolver`, within the bytecode;
   - L5: invariants, differential fuzzing against brute force, integration flows and the gas
     rows;
   - L6: the specification (EA-* rules), integrator docs, glossary, threat model and known
     limitations.
3. **Then:** the seven-lens adversarial review, fixes and a fix review; the Sepolia r4
   rehearsal (bids from several wallets beside a 1/1, a raise, an anti-snipe move, a soft-close
   extension, a capped auction with a hole, an unbid 1/1 to the museum, a voided edition
   auction, claims and Sourcify); then `v1.0.0-rc.2`. `v1.0.0-rc.1` stays tagged.

The usual gates hold throughout: fresh worktrees from `origin/main`, Solidity 0.8.37 on Prague,
exact slot and account counts, `check_docs_facts.py --update` after source changes, complete
NatSpec, coverage and mutation floors, no delegatecall, EIP-170, and an independent review
before each merge.

## Open items

- **6529 Stream's own 1/1 sale method.** Decision 14 covers editions and federated contracts.
  6529 Stream still accepts only `SaleKind.ENGLISH_AUCTION`, both for its items and for its
  minter, so a new 1/1 sale method on 6529 Stream would need a new Stream. Whether decision 14
  should reach 6529 Stream's 1/1s too, before rc.2, is the owner's call.

  **Closed, 31 October 2026 (owner decision 15).** Decision 14 covers 6529 Stream's own 1/1s
  too, before rc.2 ("once this contract goes live we are never going to change it"). Stream
  mints an item only for an admitted adapter whose `saleKind()` is the item's sale kind, and
  checks only that the item names one; the adapter checks the sale's currency and params. The
  English auction is admitted at genesis; a later 1/1 method is an adapter governance admits
  (`Stream.setAdmittedMinter`, SUCCESSOR_SETTER, the 30-day class), with no new Stream.
  `primaryTerms` reports, for a minted work, the kind its adapter had at its first admission.
  Removing an adapter stops its new mints only: it keeps its index, so it still settles,
  delivers and cancels every sale it started (AUC-8, AUC-9). As for editions, an item naming a
  kind no admitted adapter serves cannot start until one is admitted; the curation signer
  checks this (LIM-EA-8). Cost: Stream's runtime grows by 181 bytes, `start` by about 230
  Prague gas with no new slot, and the English auction's `settle` by about 2,200 (one more cold
  read, the minting adapter's kind) ([ADR 0004's table](0004-gas-budgets-under-glamsterdam.md#the-table)).

  **Admission requirement for a 1/1 sale adapter (decisions 9, 10 and 15).** The museum rule
  is enforced inside the English auction, for 6529 Stream's tokens; nothing in Stream makes
  another adapter follow it. Any 1/1 sale adapter admitted for 6529 Stream must therefore:
  - send a work that ends its sale unbid, and a work that leaves the 30-day currency-freeze
    exit unsold, to `IEconomicsResolver.museum()`, read at settlement;
  - never send either to the work's artist (decision 9's artist branch is for federated works
    only);
  - and governance checks both in the 30-day review before `Stream.setAdmittedMinter(adapter,
    true)` executes; a guardian vetoes an admission that does not hold them.

  `StreamSaleMethods.t.sol` (`test_ASecondAdapterSendsAnUnbidWorkToTheMuseum`) shows a second
  adapter sending a work that ends unbid to the museum; its mock has no currency-freeze exit,
  so the test does not show that branch.

  **Not enforced on-chain.** Stream never learns whether a sale had a buyer; a Stream-only
  settle call declaring the buyer would not stop an adapter that names its artist as one; and a
  transfer rule refusing the artist would block an artist buying their own work. The 30-day
  review, with the guardians' veto, is the control.

  (Amended by [§11](#11-amendment-31-october-2026-stream-records-each-11s-primary-sale-outcome-owner-decision-17): Stream now records each sale's outcome and moves an unsold work to the
  museum itself, so the rule is enforced on chain for every sale an admitted adapter settles,
  except a deliberately false SOLD report; the requirement becomes reporting the true outcome.)

  **The rest of the 1/1 adapter review.** Stream trusts an admitted adapter, unchecked, for the
  works it mints, so the same review also confirms that the adapter:
  - burns a work (`IMintTarget.burn`) only to cancel a sale after an upheld dispute, through a
    governed action like the English auction's `cancel` (48 hours): Stream lets the minting
    adapter burn any work it holds before the sale settles;
  - marks the primary sale settled (`markPrimarySettled`) when the sale is final, and only then:
    an edition of a master waits for it, and a settled work can no longer be burned. (Amended by
    [§11](#11-amendment-31-october-2026-stream-records-each-11s-primary-sale-outcome-owner-decision-17): `settlePrimary`, with the true outcome, which Stream records for good.)
  - pays the fee recipient and the seller wallet the shares `primaryTerms` reports;
  - reports a constant `saleKind()`: `mint` compares the live value with the item's, while
    `primaryTerms` reports the value recorded at the first admission, so an adapter whose kind
    could change (an upgradeable one, for example) could mint another kind's items under its
    recorded label. (Amended by [§10](#10-amendment-31-october-2026-streams-dependency-pointers-are-governed-owner-decision-16): `mint` compares the kind recorded at the first
    admission, so a later change of `saleKind()` changes nothing for Stream.)
  - claims a kind no other admitted adapter serves, unless it replaces that adapter, which is
    then removed in the same governance batch: the move signature names no adapter, so two
    admitted adapters of one kind can each start the same item.

  An edition master sold by a method other than the English auction gets no edition auction
  from the genesis edition auction, which reads the 1/1's clock from the English auction
  (`IEnglishAuctionClock.auctionClock`); its editions need an edition sale method that reads the new
  method's clock (a new adapter, with no new Stream or Editions). The edition auction
  hard-wires one immutable English auction (`englishAuction`), from which it reads the 1/1's
  end and state, so for such a master its `open` reverts with `NoOneOfOneAuction`. Adding a
  1/1 sale method therefore also means deploying and admitting a matching edition adapter;
  until then, that method's masters sell no editions by auction.
