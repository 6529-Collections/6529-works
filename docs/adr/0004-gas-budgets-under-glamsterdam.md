# ADR 0004: Gas budgets under Glamsterdam

Status: Accepted by the owner, 13 October 2026. Amends the gas budgets of
[ADR 0001](0001-v1-scope.md) and [ADR 0003](0003-build-time-decisions.md).
[ADR 0005](0005-stream-editions-auction.md) adds the edition auction's budgets (`bid`, `claimBid`
and `settle`) and its rows, and removes the fixed-price and Dutch rows, when that code lands.

## Problem

Every gas budget in ADR 0001, ADR 0003 and the tests was set in Prague gas,
because that is what Foundry measures. Sepolia activated Glamsterdam on
6 October 2026, and Glamsterdam reprices state creation. Measured on Sepolia
([deployments README](../../deployments/11155111/README.md#glamsterdam-gas-on-sepolia),
[flows](../../deployments/11155111/flows.md)):

| Operation | Prague | Sepolia (Glamsterdam) |
| --- | ---: | ---: |
| New storage slot (`SSTORE` from zero) | 22,100 | about 111,000 |
| Contract code, per byte | 200 | about 1,542 |
| Contract creation (`CREATE`), empty | about 53,000 | about 210,000 |
| ETH transfer to a fresh account, as a transaction | 21,000 | about 205,000 |

The start budget breaks.
- **Measured.** On the r2 rehearsal, a steady-state `start` costs **846,963**
  gas and `startWithBid` **982,312**. Replayed with Prague costs, the same
  transactions cost 293,243 and 334,572.
- **Where the difference goes.** A steady-state start writes 6 new slots, and
  `startWithBid` writes 7. At about 89,000 more per slot than on Prague, those
  slots are most of the difference.
- **350K is out of reach.** Any `start` that mints writes at least 3 new slots:
  the owner, the consumed-content record and the sale. That is about 333,000
  gas before any execution.

Foundry 1.7.1 has no Amsterdam EVM, so CI cannot measure Glamsterdam gas at
all.

## Decision

**1. The gas budgets are in Prague gas.**
- **Prague gas** is a whole transaction's gas (intrinsic, calldata and
  execution, before refunds) priced with Prague's schedule, state creation
  included at Prague's prices, with storage and accounts cold at the start as
  in a real transaction. CI measures it with Foundry.
- Every existing ceiling keeps its number, now as Prague gas:
  - a steady-state `start` and `startWithBid` in ETH, at most **350K**, for
    one artist and for the two-party variants (decision 6 covers ERC-20
    starts), with Stream's genesis dependencies; after governance replaced
    them (owner decision 16) the rarest combination may exceed it by about
    3K (LIM-GAS-11);
  - the first start in a new collection, and `settle`: 400K test ceilings;
  - `tokenURI`: 8M.
- Every other measured operation gets a **regression ceiling**: its Prague gas
  when this ADR was accepted, plus about 2%, rounded up to the thousand. A
  regression ceiling is not a budget. A change that crosses one says why in
  its pull request and moves it.

**2. Exact counts of new state per operation.** CI counts what each
transaction creates:
- **A new slot** is a storage slot that is zero before the transaction and
  non-zero after it, read from the state itself. A slot counts once however
  often it is written. A write that a revert or a halt undid does not count.
- **A new account** is an account that is empty before the transaction (no
  code, nonce zero, balance zero) and not empty after it: a contract creation,
  or ETH sent to an empty address.

Each measured operation asserts its exact counts, so a slot one change saves
cannot be spent again unnoticed. A steady-state `start` is also held to a
maximum of **6** new slots, and `startWithBid` to **7**, in ETH: for one or
two parties, and for VRF and edition-master works.
- Since the state-growth diet (see the table's commentary): 6 (7 with a bid) at
  steady state; an artist's first start under new terms writes one more on a
  hashed-position collision, which a curated artist can force by grinding an
  address. The 350K budget is for steady-state starts. First starts are
  measured and gated separately, and a forced collision can push one first
  start over 350K: an accepted limitation.
- When a change lowers a count, the same pull request lowers the test's
  figure, this ADR's table and the figure in `AGENTS.md`. Lowering needs no
  new ADR.
- Raising a count needs a stated reason in the pull request.
- Raising the `start` or `startWithBid` maximum needs an ADR.

**3. Publish the Glamsterdam totals next to the budgets.** The table below
gives each operation's Sepolia gas from the r2 rehearsal. Mainnet's Glamsterdam
parameters may differ. Every figure will be re-measured when they are final.
(Amendment note, 16 October 2026: the table's Sepolia column now gives the r3
rehearsal's receipts, from `e5fe78c`, the code of release candidate v1.0.0-rc.1.
Rows r3 has not yet run keep r2's receipt or show r3's simulation, each marked; r2's
column as accepted is kept below the table.)

**4. Restate the per-transaction cap.** EIP-7825's limit of 16,777,216 gas
applies to regular gas.
- On Sepolia, transactions whose state-creation gas took them above it were
  accepted. The largest observed used 38.4M: a `writeChunk` of 24,572 bytes.
- That is an observation of Sepolia's behaviour, not a reading of the final
  EIP mechanics.
- CI keeps testing worst-case transactions against 16,777,216 in Prague gas,
  the measure Foundry has. Whether that matches the regular gas Glamsterdam
  counts against the cap will be checked when Foundry supports Amsterdam and
  against mainnet's final parameters.

**5. Assume that payees exist.** The network fee recipient, and any royalty
payee, is an existing account (a Safe, or an address with a balance or a
nonce).
- A payout to an empty address creates it, which on Sepolia costs about 184K
  more gas, paid by whoever settles or buys.
- Off anvil, the deploy refuses a `NETWORK_FEE_RECIPIENT` that does not exist.
  The runbook asks the same of a later `setFeeTerms`
  ([script README](../../script/README.md#the-network-fee-recipient-must-exist)).
- A new payee configuration's split wallet still costs one account creation
  on its first payout. This happens once per configuration, and the table
  shows it.

**6. The start budget is for ETH, Stream's launch currency.** The 350K Prague
budget and the 6 and 7 slot maxima apply to starts in ETH. ADR 0001 §5 says
Stream launches with ETH and makes ERC-20 payment a governed configuration. It
also lets a package's sale terms name any currency on the asset allowlist.
- An ERC-20 start paid by Permit2 is a supported path, not the default. It has
  a Prague regression ceiling (388,000; 365,000 since the state-growth diet) and
  exact counts (7 new slots, 6 since the diet, no new account), but no budget.
- The allowlist is global, so ERC-20 Stream starts can happen without any
  change to the default currency.
- Admitting the first ERC-20 to the allowlist, or curation approving a Stream
  package that names an ERC-20, must be accompanied by a re-measurement of the
  ERC-20 start's cost, in Prague gas and on the target chain, and by its
  publication.

### The table

Prague gas, counts and ceilings are from `test/integration/GasReport.t.sol`
(`forge test --match-test test_Gas_Table -vv`) at the head of this ADR's pull
request. Prague figures move by a few dozen gas whenever a source file changes:
metadata hashes change CREATE2 addresses, and with them the calldata. Sepolia
gas is the receipt on the r3 rehearsal (`e5fe78c`,
[flows](../../deployments/11155111/flows.md#r3-the-release-candidate-15-october-2026)).
A figure marked "sim." is r3's `eth_simulateV1` of a call that waits for its
auction to end (on r2 the same method reproduced every later receipt exactly);
one marked "r2" or "r1" is that rehearsal's receipt, for a row r3 has not run.
"—" means no ceiling, or not run on Sepolia.

**Scope.** The start rows measure packages of at most two parties with empty or short edition
params. A package may name up to 16 parties and 1,024 bytes of edition params; such starts cost
more than the 350K budget (about 453K for 16 parties, about 361K for 1,024-byte params) and are
outside it (LIM-GAS-12). The edition auction's worst `bid` and its scattered-sweep `settle` call
are from the rc.2 review's measurements of 1 November 2026.

Re-measured for ADR 0005's edition terms and the museum rule (rc.2): `EditionTerms` shrank
from seven fields to four, so every row that carries a package item lost calldata and hashing
(about 1,300 gas for a start), and `createEdition` writes 6 new slots, one fewer, now that no
price is stored.
The fixed-price and Dutch rows left with their adapters. The edition auction's rows follow
the table's last row ([ADR 0005](0005-stream-editions-auction.md) §5 and §6), measured on the
wired stack by `EditionAuctionGasReport.t.sol`; they have no Sepolia receipt yet. Since ADR 0005
§6 the auction binds an edition when its sale opens, so `open` writes the edition's seller,
royalty and fee words and `createEdition` of that edition writes 2 new slots, not 6. The
Sepolia column stays r3's receipts.

Re-measured for owner decision 15 (6529 Stream's pluggable 1/1 sale): every `start` row rose by
about 230 gas (the item's sale kind is compared with the adapter's and its params returned) and
each `settle` by 2,169 (`primaryTerms` reads the minting adapter's kind, one cold word); `bid`,
`consume`, `createEdition` and `royaltyInfo` moved by at most 12 gas; no row writes a new slot. The binding row keeps 10,449 gas of margin.

Re-measured for owner decision 16 (Stream's governed dependencies) with the #80 review's fix
(`mint` compares the adapter's kind recorded at admission, one cold word, about 1,530 gas).
The four dependencies stay immutables, the genesis contracts, with one bit each in the counter
word every mint already reads; only a replaced one is read from storage. Every `start` row rose
by about 2,350 gas (the recorded kind, and about 820 for three warm reads of the bits; a VRF
start about 2,900, with the entropy module's), each `settle` by 2,281 (`primaryTerms` reads the
artist registry's bit, a cold word), `createEdition` by 5,032 (6529 Stream Editions reads the
three pointers from Stream) and a re-rate by 2,991 (the records satellite reads the artist
registry from Stream). No row writes a new slot. `tokenURI` fell by about 630 (one read of the
records satellite instead of two).

The review of #81 measured the binding row with a VRF seed, which no row covered: 350,126 Prague
gas, over 350K, since a VRF start read the entropy module twice. `mint` now reads it once, and
the row is gated (`test_Gas_StartWithBid_ArtistsFirstWork_TwoParty_Vrf`): 349,668 after the
merge of the edition auction (#77), 332 under 350K, the row with the smallest margin. With #77,
6529 Stream Editions reads the package registry and economics resolver from Stream in the edition
auction's `open` (281,104) and in `createEdition` of a bound edition (144,169, over its 144,000
regression ceiling, which moves to 148,000). The same change records each work's entropy module
(`entropyModuleOf`, ENT-18) without touching the start path. A VRF start fell by 426 gas; with
the code added, the other rows moved by at most 337 (the plain binding row 341,781).

The review of #81 then asked for 5,000 gas of margin on every start row. Two changes in Stream,
with no change of design: the kind each admitted adapter had at its first admission is also kept,
as 232 bits of its hash, in the minter word `mint` reads anyway, so the #80 fix no longer costs
a cold word (every `start` row −2,016; Stream +114 bytes); and `mint` resolves its four
dependencies from one read of the counter word (−223, −478 on a VRF start; +355 bytes). The
plain binding row is 339,511, 10,489 under 350K; with a VRF seed 347,186, **2,814 under**, still
short of 5,000 (with the English auction's lens merged, below: 339,361 and 347,036, 2,964
under). A VRF start's delivery check is about 7,600 of it (a cold call to the entropy
module, which reads two cold words: the item's content hash, then that content's seed); the
rest of the gap needs a change of design, which the owner decides (an option list is with the
integrator). Writing a token's two words in one assignment cost 86 more and was not kept.
`setPackageRegistry` moved `refreshStanding` by +22.

The integrator then chose two changes of interface, both pre-launch, so that every start row
with Stream's genesis dependencies keeps at least 5,000 gas of margin (now gated:
`START_MARGIN` in `GasReport.t.sol`). `PackageRegistry.consume` also returns the lead artist's
active authority, which it resolved to check the move signature, so `mint` makes no second
artist-registry call for the creator (every start −1,161). The entropy module answers
`isDeliveredContent(contentHash)` from one word, the content's seed record, and `mint` asks it
with the item's content hash (a VRF start −2,135 more); `openRecord` stores
`seedOfContent(contentHash)`. A seed belongs to its content, and a content hash is consumed by
one item only (CUR-12), so the check is the same one. `mint` also resolves the entropy module
only for a VRF item. On the tree with the English auction's lens: the binding row 338,200
(11,800 under 350K), with a VRF seed 343,760 (**6,240 under**), the steady `start` 267,819.

After governance replaces Stream's dependencies (owner decision 16), each replaced dependency a
mint uses costs about 2,100 more (a storage read instead of an immutable). With all four
replaced, the binding row is 344,596 and the VRF binding row 352,272, 2,272 over the 350K
budget. The integrator accepted this as a documented limit (LIM-GAS-11): replacements are rare
governed actions, the transaction stays far under the block gas limit, and an artist can
`start` and bid separately. The two rows have their own regression ceilings; the 350K rule and
its 5,000 margin stay on the rows with the genesis dependencies.

With decision 16 the edition auction's
`open` reads the package registry and economics resolver from Stream: on the merged tree 271,920
and 317,645 for the adapter's first, under the lens's lower ceilings.

Re-measured for the English auction's lens (EIP-170 headroom): the auction's views moved to
`EnglishAuctionLens`, answered through a read-only `staticcall` fallback. A cold `auction` or
`minimumBid` costs about 7,000 more (one more cold account and the lens's reads), so the read
other contracts make on their hot paths stays on the auction: `auctionClock`, `auction`'s
state and end from one cold slot (24,207). The edition auction reads its 1/1 through it, so
its `open` (−9,184), a bid near the close (−9,048), the first call of each `settle` (about
−9,050) and `withdrawBid` while the 1/1 is paused (−6,926) cost less than before and their
ceilings came down. The auction's own rows moved with its smaller dispatch: each `start` −63,
each `startWithBid` −151, `bid` +66, each `settle` +21; no row writes a new slot or account.
The binding row kept 10,588 gas of margin on `main`; with decision 16 and the review of #81 merged, 10,639 (339,361), and with a VRF seed 2,964 (347,036).

Re-measured for owner decision 17 (Stream records each 1/1's primary-sale outcome), on `main`
with decision 16 and the English auction's lens. `settle` with a bid writes **one more new
slot**, the sale's currency and price in Stream, and rose by 11,287 gas to 157,140: the new
slot, less the `primaryTerms` call it replaces, which read the minting adapter's kind (the #80
review's Low) and the artist registry's replacement bit. `settle` with no bid fell by 14,786 to
121,508: Stream moves the work to the museum itself, with no receiver callback, and records
UNBID in a word it rewrites. The `start` rows moved by at most 32 with Stream's code; every
row stays under its ceiling, and every start row with the genesis dependencies keeps its 5,000
of margin: the binding row 338,212 (11,788 under 350K), with a VRF seed 343,740 (6,260 under).

| Operation | Prague gas | Prague ceiling | New slots | New accounts | Sepolia gas |
| --- | ---: | ---: | ---: | ---: | ---: |
| `start`, steady state | 267,787 | 350,000 | **5** | 0 | 735,859 |
| `startWithBid`, steady state | 309,796 | 350,000 | **6** | 0 | 871,980 |
| `start`, two-party work | 276,132 | 350,000 | **5** | 0 | — |
| `startWithBid`, two-party work | 318,128 | 350,000 | **6** | 0 | — |
| `start`, VRF work | 273,371 | 350,000 | **5** | 0 | 852,868 (r2) |
| `start`, edition master | 267,854 | 350,000 | **5** | 0 | 736,477 |
| `start`, an artist's first work | 287,911 | 350,000 | **6** | 0 | — |
| `startWithBid`, an artist's first work | 329,920 | 350,000 | **7** | 0 | — |
| `startWithBid`, an artist's first work, two-party | 338,212 | 350,000 | **7** | 0 | — |
| `startWithBid`, an artist's first work, two-party, VRF | 343,740 | 350,000 | **7** | 0 | — |
| `startWithBid`, an artist's first work, two-party, all four dependencies replaced | 344,596 | 346,000 (regression; LIM-GAS-11) | 7 | 0 | — |
| `startWithBid`, an artist's first work, two-party, VRF, all four dependencies replaced | 352,252 | 354,000 (regression; LIM-GAS-11) | 7 | 0 | — |
| `startWithBid`, ERC-20 by relayed Permit2 | 354,902 | 365,000 (regression) | 6 | 0 | — |
| `start`, first work in a new collection | 267,830 | 400,000 | 5 | 0 | 846,977 (r2) |
| `start`, first work ever (one-time) | 436,994 | 449,000 (regression) | 13 | 0 | 1,601,871 |
| `startWithBid`, first bid under new sale terms (one-time) | 379,945 | 390,000 (regression) | 9 | 0 | 1,213,250 |
| `bid` that outbids | 73,530 | 75,000 (regression) | 1 | 0 | 169,060 |
| `settle`, first payout to a seller wallet | 182,140 | 400,000 | 2 | 1 | 449,934 (sim.) |
| `settle`, with a bid | 157,140 | 400,000 | 2 | 0 | 257,763 (r2) |
| `settle`, no bid (to the museum, D140) | 121,508 | 400,000 | 1 | 0 | — |
| `auction` (view, cold, answered by the auction's lens) | 39,342 | 41,000 (regression) | 0 | 0 | — |
| `minimumBid` (view, cold, answered by the auction's lens) | 38,194 | 39,000 (regression) | 0 | 0 | — |
| `auctionClock` (view, cold, answered by the auction itself) | 24,207 | 25,000 (regression) | 0 | 0 | — |
| `consume`, as Stream calls it | 93,098 | 97,000 (regression) | 1 | 0 | part of `start` |
| `createEdition` | 246,427 | 275,000 (regression) | 6 | 0 | 887,954 (sim.) |
| `createEdition`, an edition its sale bound at open | 144,169 | 148,000 (regression) | 2 | 0 | — |
| re-rate a work (governed `execute`) | 189,631 | 192,000 (regression) | 1 | 0 | — |
| `refreshStanding`, a first wallet | 129,730 | 131,000 (regression) | 2 | 0 | 299,112 (r1) |
| `refreshStanding`, a further wallet | 159,127 | 161,000 (regression) | 1 | 0 | 247,970 (r2) |
| `royaltyInfo` (view) | 41,644 | 50,000 of execution | 0 | 0 | 36,426 |
| `tokenURI` (view, the size matrix) | at most 2,734,739 | 8,000,000 | 0 | 0 | unchanged |
| `createWallet`, a seller wallet (one artist payee) | 1,241,422 | 1,262,000 (regression) | 4 | 1 | — |
| `release`, the artist's first ETH release | 93,402 | 96,000 (regression) | 2 | 0 | — |
| `claimSigned`, the artist's first signed release | 141,464 | 145,000 (regression) | 3 | 0 | — |
| `claimSigned`, a later signed release (next nonce) | 90,196 | 92,000 (regression) | 0 | 0 | — |
| Edition auction `open`, steady state (binds the edition) | 271,920 | 275,000 (regression) | 6 | 0 | — |
| Edition auction `open`, the adapter's first (one-time) | 317,645 | 322,000 (regression) | 8 | 0 | — |
| Edition `bid`, its 8-step word exists | 69,257 | 110,000 | 1 | 0 | — |
| Edition `bid`, opens an 8-step word | 86,327 | 110,000 | 2 | 0 | — |
| Edition `bid`, capped sale | 71,674 | 110,000 | 1 | 0 | — |
| Edition `bid` near the close (1/1 read, soft close) | 78,593 | 110,000 | 1 | 0 | — |
| Edition `bid`, worst path (capped, opens an 8-step word, the 1/1 read live after its dispute pause lapsed, soft close) | 107,004 | 110,000 | 2 | 0 | — |
| Edition `raise`, same 8-step word | 53,770 | 56,000 (regression) | 0 | 0 | — |
| Edition `raise`, capped (departure logged) | 78,996 | 81,000 (regression) | 1 | 0 | — |
| Edition `withdrawBid`, capped, 1/1 paused | 87,761 | 90,000 (regression) | 1 | 0 | — |
| Edition `settle`, 40 used steps | 151,701 | 400,000 | 1 | 0 | — |
| Edition `settle`, capped, one departure swept | 149,787 | 153,000 (regression) | 1 | 0 | — |
| Edition `settle`, every step used (512 steps), or a 96-departure chunk with departures scattered over the log's words (336 steps), each call | at most 307,070 of execution | 350,000 of execution | 0 to 2 (the call that clears and leaves its sweep unfinished writes the result and its settler's progress) | 0 | — |
| Edition `claimBid`, a winner and new holder | 94,286 | 100,000 | 1 | 0 | — |
| Edition `claimBid`, refund only | 47,546 | 49,000 (regression) | 0 | 0 | — |
| Edition `claimBidFor`, refund credited | 64,591 | 67,000 (regression) | 1 | 0 | — |

r2's Sepolia column, as accepted (receipts on `400f96d`, before the review fixes
and the state-growth diet; the flows file compares the two rehearsals row by
row): `start` 846,963 at steady state, 852,868 for a VRF work, 847,598 for an
edition master, 846,977 for the first work in a new collection and 1,604,862
for the first work ever; `startWithBid` 982,312; a `bid` that outbids 168,932;
`settle` 441,363 for the first payout to a seller wallet and 257,763 with a bid;
`createEdition` 1,118,699; `openSale` 993,668 (the adapter's first sale, then 8
new slots); `purchase` 468,086 for the first copy and 370,142 for a later one;
`refreshStanding` 247,970 for a further wallet (299,112 on r1 for a first
wallet); `royaltyInfo` 40,667.

r3 also checks the table. Its receipts, replayed with Prague costs
(`cast run --evm-version prague`), agree with the Prague column within 50 gas:
270,159 for the steady-state `start`, 312,260 for `startWithBid`, 270,777 for an
edition master, 439,311 for the first work ever, 382,370 for the first bid under
new sale terms and 73,440 for an outbid. The Sepolia estimates the state-growth
diet derived from r2 (below) hold: about 736K and 872K for the steady-state
starts, against 735,859 and 871,980 measured. The comparison of CI with the
replays further down is r2's.

- **Re-measured after the review of 14 October 2026.** The split-wallet rows
  were added then, on the same harness; a wallet's deployment is mostly code
  (about 5,350 bytes, which Glamsterdam prices at about 1,542 gas each on
  Sepolia). Split wallets also got a constant init code, so predicting a
  wallet's address no longer hashes its creation code: the `start`,
  `startWithBid`, `createEdition` and `royaltyInfo` rows are re-measured with
  it (about 4,500 less per start, 9,000 per `createEdition`, 4,500 per
  `royaltyInfo`). The `refreshStanding` rows were re-measured with the
  identity fixes; the other rows are as accepted, and moved by a few dozen gas
  at most. The Sepolia column and the replay comparison below are the r2
  deployment, which predates the change. (Amendment note, 16 October 2026: the
  Sepolia column is now r3's, which includes it; see decision 3.)
- **The VRF start row** also includes, since the same review, the read of
  the item's content link in `isDelivered` (DEPS-1, about 2,200 gas).
- **Re-measured again with the restrained authority (IDENTITY-1, ADR 0003
  owner decision 6).** Every path that resolves the artist's creator or signer
  now reads its pending-change slot: about 2.4K more per creator read
  (`settle`, `openSale`, `purchase`) and about 2.8K per `start`, which reads it
  twice. Re-checking the consolidation source's pinned code hash (DEPS-6) adds
  about 2.2K to each `refreshStanding`. Slot and account counts are unchanged;
  the `consume` regression ceiling moved from 96,000 to 99,000. (Amendment note,
  15 October 2026: the state-growth diet below lowered this and the next bullet's
  ceilings again; the table holds the current ones.)
- **Two regression ceilings moved with the sales fixes**, for security fixes:
  the active-authority creator read (#53) and the currency status read
  (MARKET-1/2). `openSale` (292,853) moved from 293,000 to 299,000 and the
  later `purchase` (176,871) from 177,000 to 181,000: each measured figure plus
  2%, rounded up to the thousand. Slot and account counts stay exact.
- **The state-growth diet (lane F8)** lowered these counts. The table is
  re-measured at its head; each item's figure below is its own saving, measured
  on this harness when it landed:
  - QUALITY-1: an uncapped public phase (no root, no wallet cap) records no
    purchase count, so a new buyer in one writes one slot fewer: `purchase` 3 → 2
    new slots for the first copy and 2 → 1 for a later copy, about 23K less Prague
    gas each.
  - QUALITY-2: `Editions.mint` returns only the sale kind of its terms, which the
    adapters never read (they apply the terms locked at `openSale`). A purchase
    no longer reads the rest of the edition record or calls the artist registry:
    about 21.9K less Prague gas per `purchase`, with no change in slots.
  - QUALITY-4: a fixed-price or Dutch listing is five words, of which an ETH
    sale writes four. The fee recipient is stored once per adapter and
    referenced by a 2-byte index, which shares the seller's word with the phase
    count. A phase is one word (window, cap and flags), plus its root for an
    allowlist phase, in place of an array whose length was a slot of its own.
    `openSale` with one public phase writes 6 new slots instead of 8 (about 46K
    less Prague gas); an allowlist or capped phase one fewer than before; a Dutch
    `openSale` 7 instead of 8. The adapter's first sale registers the fee
    recipient, both directions of its index, with the counter in `nextSaleId`'s
    word: 8 slots, once per adapter. A purchase reads its phase in one word
    instead of four (about 6.1K less).
  - QUALITY-5: the Editions record keeps the `Edition` view but packs its words:
    the seller with the size, format and kind; the royalty receiver with the
    window and rate; the artist ID with the minted count and fee share; the fee
    recipient with the window start; the currency (zero for ETH); the content
    hash and the price; a Dutch curve decoded into two words instead of `bytes`.
    `createEdition` writes 7 new slots instead of 9 (about 46K less Prague gas),
    a Dutch edition 9 instead of 13 with a stepped curve, and an edition's first
    copy no longer opens the minted counter's word: the first `purchase` writes
    only the holder's balance, 1 slot instead of 2, the same as a later copy.
  - QUALITY-6, Stream's token record from four words to three: a token keeps
    two words, the seller with the serial, collection, flags and a terms ID, and
    the item hash. The terms (the lead artist ID, royalty rate, fee share,
    fee-recipient index and minting adapter's index) are one word that every
    work under the same terms shares. A start under existing terms writes 5 new
    slots, 6 with a bid, about 19.3K less Prague gas.
    - The quality review's design looked the terms up through a key-to-ID map:
      one slot more on each payee list's first start. That start is steady state
      today, since the artist's acceptance pre-writes the move-nonce word, so it
      would have raised the maximum. The terms word sits instead at the position
      its hash names (23 bits), or, when other terms already hold that position,
      in an overflow range keyed by the full hash. Nothing loops.
    - A first start under new terms writes the terms word in place of the old
      per-token word: 6 slots, 7 with a bid, as every start wrote before. It is
      an artist's first start, and every artist's first after an economics
      change or through a newly admitted adapter (the terms include the minter
      index). Terms are per lead artist, so a new collaboration of an artist who
      has started before is not a first. The maxima stay 6 and 7; the exact
      counts of the other start rows are 5 and 6. The binding row of the 350K
      budget is now an artist's first start of a two-party work with a bid.
    - **Accepted limitation: collisions.** Two terms collide when their 23-bit
      hashed positions are equal. That is rare per pair (one in about 8.4
      million) but expected at scale: a few thousand distinct terms make one
      likely (even odds at about 3,400). A curated artist can also force one on
      another artist by grinding an address (about 89,000 tries offline). When
      the colliding terms are interned first, the other artist's first start
      under its terms writes the overflow word and its index: one slot more, 7,
      or 8 with a bid (the two-party first start with a bid is then about 365K
      Prague, over 350K). Each later start under those terms reads the overflow
      index cold, about 2.1K more. Correctness is unaffected
      (`test/stream/StreamTermsInvariant.t.sol` runs 36 real collisions;
      `test/stream/StreamTermsGrind.t.sol` reproduces a ground one).
    - A re-rate (governed, with every party's consent) moves the token to the
      terms with its new rate, which writes a word if no work has them yet; it
      overwrote the token's own word before.
    - Net: one slot less on every start except a first under new terms, which
      is unchanged unless its position collides.
  - The restrained flag: the artist registry keeps, in the authority's storage
    word, whether the pending change is an override that moves the authority.
    Every staging sets it and every end of a change clears it, so
    `activeAuthorityOf` reads the pending change only while the flag is set. That
    takes back the IDENTITY-1 read: about 2.2K to 2.4K less per `start`,
    `settle`, `openSale`, `consume` and re-rate, with no change in slots. The
    identity invariants check the flag against the pending change.
  - New rows: an artist's first start, with and without a bid and as a
    two-party work with a bid, a re-rate, `openSale` at steady state (the
    adapter's fee recipient registered) and on the adapter's first sale, and a
    Dutch `createEdition`, `openSale` and `purchase`. The artist's first starts
    are gated by the 350K budget and the 6 and 7 maxima, with exact counts.
    Regression ceilings of the rows the diet changed are the new figure plus
    about 2%, rounded up to the thousand.

  **Glamsterdam, re-derived.** Each slot saved is about 89,000 gas on Sepolia
  on top of its Prague saving (about 111,000 against 22,100). The saving below
  is the Prague saving plus 89,000 per slot saved; the estimate is the r2
  receipt minus that saving, so it carries r2's own differences (a Safe as fee
  recipient, the changes listed above since r2). "Before" is `main` at
  `46941d6`, measured with the same rows.

  | Operation | Prague before → after | New slots | Sepolia saving | Sepolia estimate (r2) |
  | --- | ---: | ---: | ---: | ---: |
  | `start`, steady state | 291,808 → 270,108 | 6 → 5 | about 111K | about 736K (846,963) |
  | `startWithBid`, steady state | 333,883 → 312,183 | 7 → 6 | about 111K | about 872K (982,312) |
  | `start`, an artist's first work | 291,821 → 290,202 | 6 → 6 | about 2K | — |
  | `startWithBid`, first bid under new sale terms | 404,032 → 382,332 | 10 → 9 | about 111K | — |
  | `consume`, as Stream calls it | 96,456 → 94,252 | 1 → 1 | about 2K | part of `start` |
  | `settle`, with a bid | 143,063 → 141,585 | 1 → 1 | about 1.5K | about 256K (257,763) |
  | `createEdition` | 314,734 → 268,938 | 9 → 7 | about 224K | about 895K (1,118,699) |
  | `createEdition`, a Dutch edition | 404,296 → 317,127 | 13 → 9 | about 443K | — |
  | `openSale` (one public phase) | 295,361 → 241,730 | 8 → 6 | about 232K | about 762K (993,668) |
  | `openSale`, the adapter's first sale (once) | 295,361 → 284,847 | 8 → 8 | about 11K | — |
  | `openSale`, Dutch | 289,068 → 259,642 | 8 → 7 | about 118K | — |
  | `purchase`, the first copy, new holder | 193,971 → 123,933 | 3 → 1 | about 248K | about 220K (468,086) |
  | `purchase`, a later copy, new holder | 176,871 → 123,933 | 2 → 1 | about 142K | about 228K (370,142) |
  | `purchase`, Dutch, the first copy | 171,646 → 124,486 | 2 → 1 | about 136K | — |
  | re-rate a work (governed) | 162,697 → 187,673 | 0 → 1 | about −114K | — |

  The two-party and VRF starts, the edition-master start, the Permit2 start and
  the first start in a new collection move as the steady-state `start` does.
  The first work ever keeps its 13 slots (about 2K less). An artist's first start
  and the re-rate are where the shared terms word is written (one word more on a
  collision); the adapter's first `openSale` is where its fee recipient is
  registered.
- **Re-measured with the source-quality pass (lane F7a).** The shared install
  check, the split mint-request errors, and the metadata hashes (and so the
  CREATE2 addresses) they change move the starts by 18 to 82 gas and the other
  rows by at most 134. The split wallet's code is 25 bytes longer (its
  code-hash check now reverts with the resolver's address): its deployment costs
  5,083 more Prague gas, and about 39K more under Glamsterdam (about 1,574 gas a
  code byte). Slot and account counts are unchanged.
- **The binding row is an artist's first start of a two-party work with a
  bid:** the table's row with the smallest margin under 350K. The steady-state
  two-party `startWithBid` row has about three times that margin. A forced
  collision can push that first start over 350K (above).
- **An ERC-20 `startWithBid` paid by Permit2 costs about 45K more than in
  ETH** (the table's Permit2 row against the steady-state `startWithBid`),
  because of the Permit2 transfer path. That path adds:
  - the signed permit and its witness in the calldata;
  - Permit2's signature check and nonce update;
  - the token transfer, with the balance checks around it;
  - two more accounts, Permit2 and the token.

  It is not the launch currency, so the row has a regression ceiling, not the
  350K budget (decision 6). The row uses the test suite's reproduction of
  Permit2, not the canonical deployment.
- **A rule of thumb on Sepolia's parameters:** a transaction's Glamsterdam gas
  is about its Prague gas, plus about 89,000 per new slot, plus about 184,000
  per new account. It is not a gate.
- **Where a steady-state start's 5 slots go:**
  - Stream's two-word token record and the ERC-721 owner;
  - the package registry's consumed-content record;
  - the auction's sale.

  `startWithBid` adds the bid, and a first start under new terms adds Stream's
  shared terms word (and, on a hashed-position collision, the overflow index).

### CI against the Sepolia replays

The same operations, as CI measures them and as the r2 receipts replay with
Prague costs (`cast run --evm-version prague`):

| Operation | CI | Sepolia r2 at Prague | CI minus Sepolia |
| --- | ---: | ---: | ---: |
| `start`, steady state | 293,230 | 293,243 | −13 |
| `startWithBid`, steady state | 334,584 | 334,572 | +12 |
| `start`, VRF work | 298,736 | 298,748 | −12 |
| `start`, edition master | 293,890 | 293,878 | +12 |
| `start`, first work in a new collection | 293,244 | 293,257 | −13 |
| `start`, first work ever | 442,314 | 442,302 | +12 |
| `bid` that outbids | 73,348 | 73,312 | +36 |
| `createEdition` | 323,833 | 323,819 | +14 |
| `openSale` | 286,584 | 286,608 | −24 |
| `refreshStanding`, a further wallet | 157,132 | 157,250 | −118 |
| `settle`, first payout to a seller wallet | 158,414 | 164,743 | −6,329 |
| `settle`, with a bid | 133,414 | 139,743 | −6,329 |
| `purchase`, the first copy | 190,597 | 196,926 | −6,329 |
| `purchase`, a later copy | 173,497 | 179,802 | −6,305 |

- **The starts, `bid` and the Editions calls agree within 40 gas, and
  `refreshStanding` within 120.** The inputs differ: the packages' calldata,
  and the consolidations a refresh walks.
- **The four payout rows differ by about 6,300.** On Sepolia the network fee
  recipient is the hot admin Safe, and ETH paid to a Safe runs its receive
  code. CI's fee recipient is a plain funded account.

## Consequences

**What CI checks.**
- `test/integration/GasReport.t.sol` measures every row above on the real,
  wired contracts.
  - It gates the Prague budgets and ceilings.
  - It asserts the exact counts of new slots and accounts, and the `start`
    maxima.
  - It also checks that `tokenURI` creates no state.
- `test/helpers/StateGrowth.sol` does the counting. It takes each candidate
  slot and account from the state-diff recording, and reads its value before
  and after the call from the state itself. Its tests on a toy contract cover:
  - overwrites, zero to zero and non-zero to zero;
  - reverted writes, and writes in frames that ran out of gas or hit
    `INVALID`;
  - re-entrancy, a parent writing between two child calls, `delegatecall` and
    transient storage;
  - `CREATE`, and ETH sent to a fresh account or an empty precompile.
- Module gas tests, such as `EnglishAuctionGas.t.sol`, keep their Prague gates.

**How CI measures Prague gas.** Foundry 1.7.1 does not model a transaction's
cold start fully. The harness works around three quirks:
- **`vm.cool` cools storage but not accounts.** The harness probes which
  accounts the test had already touched before each measurement. It then adds
  2,500 gas (EIP-2929: 2,600 cold against 100 warm) for each of those that a
  real transaction would reach cold. Without this, a steady-state start read
  about 17,500 low.
- **Recording a state diff warms what it reads.**
- **After a recording, nothing in that test is cold again**, even after a
  state revert.

So each row is probed and measured first, and recorded last, all from one
snapshot. A probe fails any measurement whose cooling did not work, and another
check fails if a measured call reached storage the harness does not cool.

`test/integration/GasHarness.t.sol` checks the correction against the truth.
A steady-state `start` measured at the very start of a test, where every
account and slot is cold, must equal the corrected figure measured after the
test has warmed every account the call reaches. Today they are both 269,325,
against 251,825 uncorrected: seven accounts at 2,500 each.

**What CI cannot check.**
- **Glamsterdam totals.** The Sepolia column is measured by hand on a
  deployment. CI gates the count of new slots and accounts, which is the part
  of the Glamsterdam cost it can see. It does not see the price of code bytes
  in a contract creation, beyond counting the account.
- **Receive code of real payees.** A Safe or a contract payee costs more to pay
  than the plain accounts CI uses (about 6,300 for a Safe, above).

**What happens next.**
- **Re-measure on mainnet.** When mainnet's Glamsterdam parameters are final,
  re-measure the Sepolia column on a deployment that uses them. Do the same
  for the per-byte storage costs.
- **When Foundry supports Amsterdam,** consider gating Glamsterdam gas
  directly. `vm.lastCallGas` already declares a `gasStateUsed` field that
  Foundry 1.7.1 does not return.
- **Content storage costs** about 1,548 gas per byte on Sepolia, against 218 on
  Prague: about 1.65 ETH per MiB at 1 gwei. The
  [uploader](../../tools/content/README.md#glamsterdam) restates its
  guidance; this ADR only records the measurement.

## Security impact

Fixed gas allowances inside the protocol now absorb Glamsterdam's state
pricing.
- **`DELIVERY_GAS` (300K).** `settle` forwards it to the token's
  `safeTransferFrom`. Delivering to a new holder writes that holder's balance
  slot from zero; on Sepolia those deliveries succeeded. A recipient contract
  whose `onERC721Received` also writes new state has less room than on Prague
  and may run out. The token then stays as a pending claim: nothing is lost,
  but the winner claims it later and pays for that.
- **`PAYOUT_GAS` (100K).** A seller or fee wallet gets this much for an ETH
  payout. A wallet whose receive code writes new state may need more under
  Glamsterdam; its payout is then refused and goes to the escrow, to be
  flushed later. Split wallets receive with an empty `receive` and are
  unaffected.
- **The auction's ERC-20 payout frame (1,000,000).** Each ERC-20 settlement
  payout runs in its own call frame with this allowance (MONEY-1), and the
  settler must be able to forward it in full: an ERC-20 `settle` needs a call
  gas limit of about 1.11M although it uses about 140K (an ETH `settle` about
  460K). If a payout fails in the frame, it is credited to its wallet, to be
  paid with `claimFor`. Under Glamsterdam, if a token burns the whole frame,
  the credit's new storage slot (about 111K of state gas) may not fit in what
  remains: the settlement then reverts and is retried with a higher limit.
- **Settlement reads the currency's status** (MARKET-2: a deprecated currency
  freezes the auction), about 7K more Prague gas per `settle` than before.
- **The VRF callback** used about 62% of its 200,000-gas limit on Sepolia (one
  new slot). Raising the limit is a PARAMETER_SETTER operation (48 hours);
  lowering it, never below the floor, a SUCCESSOR_SETTER one (30 days). The
  callback now creates no slot (the seed overwrites the request
  ID, DEPS-2): about 34,000 under Glamsterdam, about a third of the 100,000
  floor.
- **The claim router's continue-mode minimums** (200,000 per plain item,
  450,000 per signed item) are Prague-sized floors. A first release needs more
  under Glamsterdam: new slots, and possibly the payee's account (about 716,000
  for a first signed release on Sepolia). While an item is offered less than
  `SHORTFALL_REVERT_CEILING` (1,500,000), continue mode reverts when it fails
  after spending its share, so gas estimation raises the limit until it is
  paid; an item that fails despite the ceiling is skipped. Re-check the ceiling
  (about twice the Sepolia figure) and the batch sizes: a full batch of first
  releases may not fit one transaction, and then reverts for the caller to
  split.

Re-check each of these allowances against mainnet's Glamsterdam parameters before
mainnet.

## Alternatives considered

- **A: keep 350K as a Glamsterdam total.** This is unreachable, because any
  minting start writes at least 3 new slots.
- **B: a slot diet.** This is deferred, not rejected: it is an optimisation
  candidate.
  - Stream's per-token words could go from four to three, by storing the
    economics fields as a deduplicated terms ID, as the auction already does.
    A steady-state start would then cost about 760K on Sepolia. Done by the
    state-growth diet (QUALITY-6, above).
  - The Editions record and the fixed-price listing with its phase (8 new
    slots each) could be halved, saving about 350K each on `createEdition` and
    `openSale`. The diet took each down by two slots (QUALITY-4 and -5).
  - The exact counts make any such saving visible and keep it.
- **C: a redesign for minimal state.** This is rejected. Any design keeps the
  essential records: the owner, the consumed content and the sale. A redesign
  could remove little more than B does, and it would reopen modules that have
  been reviewed and integrated.

## Superseded or amended

- **ADR 0001.** The 300K start budget (Intended behavior) was already amended
  to 350K by ADR 0003. It is now Prague gas plus the slot maximum. The storage
  figures in §8 (0.23 ETH per MB per gwei, 72 KB per transaction) predate
  Glamsterdam.
- **ADR 0003.** The 350K steady-state start gate and its measured table are
  Prague gas. The "two full chunks per transaction" figure predates
  Glamsterdam: one full chunk per transaction under Glamsterdam (uploader
  README).
