# ADR 0005: The edition auction and 6529 Stream Editions

Status: Accepted by the owner, 31 October 2026, who approved every recommended default
("defaults") and added decision 14 the same day. Recorded by the delivery owner (Claude Code,
acting for the repository owner). Amends [ADR 0001](0001-v1-scope.md),
[ADR 0003](0003-build-time-decisions.md) and [ADR 0004](0004-gas-budgets-under-glamsterdam.md).

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
  and the `PRODUCT_EDITIONS` economics.
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
resumable; claims open when the sweep completes. `claimBid` mints a winner's copies and sends
its refund to an address it names; `claimBidFor` lets anyone push a claim, crediting the
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
  sale another one ran.
- `formatOf` and the OPEN window (`EditionWindowOpened`, `windowStart`) go with the fixed-price
  and Dutch adapters. Once they and the terms change land, and if nothing else in it changes,
  the `IEditions` interface ID is `0xa41d86b8`. The item hash's golden values change with the
  terms (`test_itemHash_golden`).

**The museum.** `IEconomicsResolver.museum()` names the 6529 Network Museum; `setMuseum`
(compare-and-set on its own revision, as the resolver's other setters are) changes it. A 6529
Stream work whose 1/1 settles with no bid, or ends unsold after its currency stayed deprecated
for 30 days, goes to the museum. The English auction takes 6529 Stream as a constructor
argument and gates the museum branch on it, so decision 9 holds in code: any other token's
unbid work, federated or listed later by governance, goes to its artist. A delivery pending for
the museum is claimed only by the museum recorded at settlement; for any other token the artist
may also claim in the recipient's place (L-5), so no artist can take the museum's. The museum
is a recipient chosen by the auction adapter and the resolver, not a hook in Core (ADR 0001
§15).

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
   auction are untouched: each edition stays with its first minter.

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
| Base price | 0.0001 ETH | 10^12 to 10^17 wei | PARAMETER_SETTER, 48 hours |
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
  departure at the cut step, chunked across calls.
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
- **LIM-EA-10: claims need the adapter admitted.** Copies are minted at claim, and 6529 Stream
  Editions refuses mints from a removed adapter (ED-5). Governance therefore removes an edition
  auction only once its settled sales are claimed; `claimBidFor` lets anyone push the remaining
  claims first. The removal is a 30-day operation, visible in advance.

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
  adapter that honours it.

  **Not enforced on-chain.** Stream never learns whether a sale had a buyer; a Stream-only
  settle call declaring the buyer would not stop an adapter that names its artist as one; and a
  transfer rule refusing the artist would block an artist buying their own work. The 30-day
  review, with the guardians' veto, is the control.
