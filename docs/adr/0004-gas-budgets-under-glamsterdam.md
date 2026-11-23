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
- (Amendment note, 15 November 2026, [ADR 0007](0007-permanence.md).) **Permanent contracts
  hold no gas numbers.** A call from a permanent contract into another contract forwards all
  the gas EIP-150 allows, and a failure that left at most 1/8 of the gas held before it reverts
  the transaction (`BoundedCallShortfall`), never answering. The budgets in this ADR are test
  policy: CI gates of Prague gas, not values compiled into any contract. The margin every
  steady-state start row keeps under 350K is 5,000 after that integration (2,500 between its
  two rounds).

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
  ([script README](../../script/README.md#1-accounts-and-inputs)).
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

**Amendment, 23 November 2026 (the table re-measured on the plain core; Sepolia r6 and r7).**
The table below replaces the earlier one, which is kept further down as history: its start rows
carried the 370,000 ceiling of [ADR 0010](0010-plain-permanent-core.md) over gas and slot counts
measured before the plain core, so no row of it could be compared with a transaction of the
plain core. Every Prague figure, count and ceiling below is `test/integration/GasReport.t.sol`
(`forge test --match-test test_Gas_Table -vv`) on `main` at `5de6abaa`, the source Sepolia r6 and
r7 run. Sepolia
gas is the receipt on the r7 rehearsal (`5de6abaa`,
[flows](../../deployments/11155111/flows-r7.md)), given only where r7 ran the row's own scenario
(its replay at Prague prices is within 1% of the row); "—" means r7 did not run that scenario.

What each ceiling applies to (all are test gates in Prague gas, not chain code):

- **370,000 and 8 new slots** (`START_BUDGET`, `START_MAX_SLOTS`): every English-auction start
  of a 6529 Stream work that is not a one-time row, with or without a bid. That includes an
  artist's first work, the first work in a new collection, an edition master, a two-party work,
  a VRF work started without a bid and a move signed by a consolidated wallet.
- **395,000 and 9 new slots** (`VRF_START_BUDGET`, `VRF_START_MAX_SLOTS`): a start *with a bid*
  of a VRF work, which writes the bid and the seed. Three rows.
- **The one-time rows** have regression ceilings, not budgets: the deployment's first start
  (357,000) and the auction's first bid (353,000). Each happens once per deployment.
- **400,000** is the settlement rows' test ceiling. Decision 1 above also names 400K for the
  first start in a new collection; since ADR 0010 CI holds that row to the start budget
  (370,000), the stricter gate, and it measures 320,947.
- Every other ceiling is a regression ceiling (the figure when set plus about 2%).

| Operation | Prague gas | Prague ceiling | New slots | New accounts | Sepolia gas |
| --- | ---: | ---: | ---: | ---: | ---: |
| `start`, steady state | 320,904 | 370,000 | **7** | 0 | 963,757 |
| `startWithBid`, steady state | 351,143 | 370,000 | **8** | 0 | 1,087,996 |
| `start`, steady state, move signed by a consolidated (non-root) wallet | 368,117 | 370,000 | **7** | 0 | 1,011,745 |
| `start`, two-party work | 329,634 | 370,000 | **7** | 0 | — |
| `startWithBid`, two-party work | 359,873 | 370,000 | **8** | 0 | — |
| `start`, VRF work | 353,855 | 370,000 | **8** | 0 | — |
| `startWithBid`, VRF work | 384,094 | 395,000 | **9** | 0 | 1,209,264 |
| `start`, edition master | 320,995 | 370,000 | **7** | 0 | — |
| `start`, edition master with 64 bytes of params (the bound) | 322,097 | 370,000 | **7** | 0 | — |
| `start`, first work in a new collection | 320,947 | 370,000 | **7** | 0 | 963,747 |
| `start`, an artist's first work | 320,915 | 370,000 | **7** | 0 | — |
| `startWithBid`, an artist's first work | 351,154 | 370,000 | **8** | 0 | — |
| `startWithBid`, an artist's first work, two-party | 359,861 | 370,000 | **8** | 0 | — |
| `startWithBid`, an artist's first work, two-party, VRF | 392,818 | 395,000 | **9** | 0 | — |
| `startWithBid`, an artist's first work, two-party, VRF, edition master with 64 bytes of params (the bound) | 393,933 | 395,000 | **9** | 0 | — |
| `start`, first work ever (one-time) | 355,116 | 357,000 (regression) | 9 | 0 | 1,159,577 |
| `startWithBid`, the auction's first bid (one-time) | 351,143 | 353,000 (regression) | 8 | 0 | 1,087,971 |
| `SaleStarter.start`, steady state (start, vaults confirmed, record opened) | 575,413 | 579,000 (regression) | 13 | 0 | 1,745,955 |
| `bid` that outbids | 74,192 | 76,000 (regression) | 1 | 0 | 169,824 |
| `settle`, first payout to a seller vault | 152,306 | 400,000 | 1 | 1 | — |
| `settle`, with a bid | 127,306 | 400,000 | 1 | 0 | 244,974 |
| `settle`, no bid (to the museum, D140) | 81,436 | 400,000 | 0 | 0 | 112,448 |
| `auction` (view, cold) | 32,425 | 34,000 (regression) | 0 | 0 | — |
| `minimumBid` (view, cold) | 39,086 | 40,000 (regression) | 0 | 0 | — |
| `auctionClock` (view, cold) | 28,787 | 30,000 (regression) | 0 | 0 | — |
| `royaltyInfo` (view, cold; its ceiling is 21,000 plus the 50,000 execution budget of `RoyaltyInfoGas.t.sol`) | 23,937 | 71,000 | 0 | 0 | — |
| `authorize`, the mint policy's share of a start, as a call | 115,937 | 119,000 (regression) | 0 | 0 | — |
| Edition auction `open`, steady state (creates the edition) | 257,207 | 260,000 (regression) | 5 | 0 | 693,657 |
| Edition auction `open`, an artist's first sale (deploys both vaults) | 396,779 | 402,000 (regression) | 7 | 2 | — |
| Edition `bid`, opens an 8-step word | 86,353 | 89,000 (regression) | 2 | 0 | 269,355 |
| Edition `bid`, its 8-step word exists | 69,283 | 71,000 (regression) | 1 | 0 | — |
| Edition `settle`, 5 used steps | 180,817 | 185,000 (regression) | 1 | 0 | — |
| Edition `claimBid`, a winner, the edition's first mint | 111,227 | 114,000 (regression) | 1 | 0 | — |
| Edition `claimBid`, refund only | 72,540 | 74,000 (regression) | 0 | 0 | — |
| re-rate a work (governed `execute`) | 225,603 | 231,000 (regression) | 1 | 0 | — |
| `createWallet`, a seller vault (one artist payee) | 96,160 | 98,000 (regression) | 1 | 1 | — |
| `release`, the artist's first ETH release | 101,456 | 104,000 (regression) | 2 | 0 | 274,996 |
| `claimSigned`, the artist's first signed release (relayed) | 146,964 | 150,000 (regression) | 3 | 0 | — |
| `claimSigned`, a later signed release (next nonce) | 95,696 | 98,000 (regression) | 0 | 0 | — |
| Independent Stream `restart`, a work's first (records when it was offered again) | 110,904 | 114,000 (regression) | 1 | 0 | — |
| Independent Stream `restart`, a later one | 93,804 | 96,000 (regression) | 0 | 0 | — |

**Amendment note, 23 November 2026 (the clock answers when a work was offered again).**
`auctionClock` now also answers when a work was last offered again, one more storage word that
the view reads, and with it the edition auction's `open` and the first call of its `settle`. Four
rows above were re-measured for it (`auctionClock`, the two edition `open` rows and edition
`settle`), and two of their regression ceilings moved (28,000 to 30,000; 179,000 to 185,000). The
Sepolia figure of the edition `open` row is still r7's receipt, taken before this change. The two
`restart` rows are new and measured by `test/integration/IndependentRestartGas.t.sol` in the same
way as the rows of `test_Gas_Table`; the `restart` row of the earlier table below was measured
before the plain core and is not comparable.

The other Independent Stream rows, the edition auction's worst-case rows and `tokenURI` are measured by
their own tests (`IndependentStreamGas.t.sol`, `EditionAuctionGasReport.t.sol`,
`TokenUriBudget.t.sol`) and were not re-measured for this amendment; their last figures are in
the earlier table below.

**The Sepolia starts against their rows.** Each start of r6 and r7, replayed on its parent
block's state at Prague prices (`cast run --quick --evm-version prague`), beside the row it is
an instance of:

| Start on Sepolia | Replay at Prague prices | Row | CI | Ceiling | Under the ceiling |
| --- | ---: | --- | ---: | ---: | ---: |
| [r7](https://sepolia.etherscan.io/tx/0xb377f4ed0f0d7a63f255209f416c18e247d781b7ae1c3ddda73cc5d2291a9734): `start`, the deployment's first | 355,897 | `start`, first work ever (one-time) | 355,116 | 357,000 | 1,103 |
| [r7](https://sepolia.etherscan.io/tx/0x3ccf05576943e60e2833caf6ff7730cbaa6ac0b30253a399a04bb67109716dce): `startWithBid`, the auction's first bid | 351,911 | `startWithBid`, the auction's first bid (one-time) | 351,143 | 353,000 | 1,089 |
| [r7](https://sepolia.etherscan.io/tx/0x2ebef972fa182740e0f5200ebcabf5bd37231e77aeb6fbc0d105d61dc3741a9d): `start` | 321,717 | `start`, steady state | 320,904 | 370,000 | 48,283 |
| [r7](https://sepolia.etherscan.io/tx/0xddccbf4ed74652491cf62175fc27f180fa238129d0df119a9777504049b1c04b): `startWithBid` | 351,936 | `startWithBid`, steady state | 351,143 | 370,000 | 18,064 |
| [r7](https://sepolia.etherscan.io/tx/0x11233120001342d2da2b27a5e5920520b3bd537b6d32dd98fcf4b1f031005360): `start`, move signed by a consolidated wallet | 368,905 | `start`, steady state, move signed by a consolidated (non-root) wallet | 368,117 | 370,000 | 1,095 |
| [r7](https://sepolia.etherscan.io/tx/0xf34c270720ecf32304930d60db47789edef8d2371a8149df9d65c91db63a5b89): `start`, first work in a new collection | 321,707 | `start`, first work in a new collection | 320,947 | 370,000 | 48,293 |
| [r7](https://sepolia.etherscan.io/tx/0xedd3c2e3f4f7934950257a8f734f8d304b399d2e25bff6a12ccc7e035f9ba51c): `startWithBid`, VRF work | 384,884 | `startWithBid`, VRF work | 384,094 | 395,000 | 10,116 |
| [r7](https://sepolia.etherscan.io/tx/0x32c11bbf3d1b8f2a3c33aa4c2b440289f0da66981745fa7edc4e21f5f22393fa): `SaleStarter.start`, vaults exist | 574,695 | `SaleStarter.start`, steady state (start, vaults confirmed, record opened) | 575,413 | 579,000 | 4,305 |
| [r7](https://sepolia.etherscan.io/tx/0xd25a0ee2b0d8c8b161ccebfa4d58907deb565fa2e41c9b6d9219612eb6090567): `SaleStarter.start`, vaults exist | 574,690 | `SaleStarter.start`, steady state (start, vaults confirmed, record opened) | 575,413 | 579,000 | 4,310 |
| [r7](https://sepolia.etherscan.io/tx/0x2045fdfbe90e83a17d15bb7166bedc52f919162becac182cb0c749ed2748f958): `SaleStarter.start`, the artist's first (deploys both vaults) | 715,901 | none | — | — | — |
| [r6](https://sepolia.etherscan.io/tx/0xb8298fb46e6520496b693c5b11961548e3d02ca8e5ae797e3ccbc1e5c5596c1e): `startWithBid`, the deployment's first start and the auction's first bid at once | 386,146 | none | — | — | — |
| [r6](https://sepolia.etherscan.io/tx/0xfdd6aeb53b84155097b66d397f29b02c00b20cc47b3dbb57b72f5599a2f54cc5): `startWithBid`, VRF work | 384,842 | `startWithBid`, VRF work | 384,094 | 395,000 | 10,158 |
| [r6](https://sepolia.etherscan.io/tx/0x897f2a38a6b1a875c9559818997fead8290f739a3a9dec3ba66fdafebee921f5): `SaleStarter.start`, the artist's first (deploys both vaults) | 715,851 | none | — | — | — |

- **Every r7 start is within its own row's ceiling.** The replays are 760 to 813 gas above CI
  for a direct start and 718 below it for `SaleStarter.start`. The rehearsal's package has ten
  items where CI's has eight, so the Merkle proof of an item among the first eight is one word
  longer than CI's and the proof of item 8, started through `SaleStarter`, one word shorter;
  the addresses in the calldata differ too. No cold-account effect appears: a replay runs on
  the live chain's own state.
- **r6's 386,146 has no row, and the 370,000 budget does not apply to it.** It was the
  deployment's first start and the auction's first bid in one transaction: `startWithBid` of the
  first work ever. CI measures those two one-time effects apart (355,116 and 351,143); together
  they come to the first start plus a bid, about 386,000. r7 ran them apart, as the rows do:
  355,897 and 351,911. r6's record called it a
  first start in a new collection; that row is a later collection's first work at steady state,
  which r7 ran (321,707).
- **r6's 384,842 is a start with a bid of a VRF work**: the row at 384,094, ceiling 395,000.
  r7's is 384,884.
- The tightest live margin is the start whose move a consolidated wallet signed:
  368,905, 1,095 under 370,000 (CI: 368,117, 1,883 under).

**Amendment, 22 November 2026 ([ADR 0010](0010-plain-permanent-core.md)).** The 350,000 start
budget and its 6- and 7-slot maxima are replaced by one gate: **every start row, with or without
a bid, at most 370,000 Prague gas and 8 new storage slots** (`START_BUDGET` and
`START_MAX_SLOTS` in the integration base). The start rows of the earlier table (further down)
carry the new ceiling; their measured gas and slot counts are from before the plain core (the
study measured the tightest row at 363,899 gas and 8 slots, and a steady `start` at 311,906).
The table above is the re-measurement on the built stack. The history below is unchanged.

**The earlier table and its history** (measured before the plain core; kept as written).

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

(Note, 1 November 2026, from the rc.2 review.) **Scope.** The start rows measure packages of
at most two parties. A package may name up to 16
parties; such starts cost more than the 350K budget (about 453K for 16 parties) and are outside
it (LIM-GAS-12). Edition params are at most 64 bytes since
[ADR 0005 §12](0005-stream-editions-auction.md#12-amendment-1-november-2026-fix-pass-a-of-the-rc2-review),
and the start rows include a master at that bound. The edition auction's worst `bid` and its scattered-sweep `settle` call
come from the rc.2 review's proofs of concept, re-measured on `main` after fix passes A and B
(1 November 2026); no CI test gates those two rows yet.

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

Re-measured for fix pass B of the rc.2 review, on `main` with fix pass A:
- **`settle` with no bid** rose by 1,157 to 122,665. The English auction now reads `ownerOf`
  after `settlePrimary` to learn where an unsold work went, instead of trusting the `holder` the
  token reports (CALLS I-2): one warm call to the token.
- **`auctionClock`** also returns the 1/1's dispute-pause start, `auction`'s `pausedAt`, which
  costs 53 more (24,260).
- **The edition auction's `withdrawBid`** reads that start from `auctionClock` rather than
  through the lens's `auction`. It fell by 12,492 to 88,019, and its ceiling is back at 90,000.
- **The edition rows that read the 1/1** rose by at most 224: `open`, a bid near the close and
  a settlement's first call.
- **The lens views** fell by up to 48. The English auction's lens is now deployed on its own
  and reads its caller (GAS M-2).
- **`setDependency`** now also reads a replacement's `authority()` (G I-1), which is on no
  measured path.
- **Every other row** moved by at most 32 with the new code and deployment addresses, and no
  row writes a new slot or account.

Every start row with the genesis dependencies keeps its 5,000 of margin:

| Start row | Gas | Under 350K |
| --- | --- | --- |
| The binding row | 338,212 | 11,788 |
| With a VRF seed | 343,740 | 6,260 |
| VRF seed, edition master with 64 bytes of params (the tightest) | 344,907 | 5,093 |

Re-measured for owner decisions 18 to 24, on `main` with fix passes A to C:
- **Stream's minter word** now also keeps an adapter's removal time, for the rescue of stranded
  works (owner decision 20; its sale-kind key is 192 bits), and Stream gained
  `rescueToMuseum`. Every `start` row rose by at most 62, and `settle` with no bid by 45
  (122,710).
- **The genesis ETH opening bid** of 0.05 ETH (owner decision 19) changes no measured row: the
  rows bid at least that.
- **The rescue** is a governed 30-day action, outside the table: about 65,000 gas through the
  manager's `execute`.
- **Every other row** moved by at most 315 (the governed re-rate) with the new code and
  deployment addresses, and no row writes a new slot or account.

Every start row with the genesis dependencies keeps its 5,000 of margin:

| Start row | Gas | Under 350K |
| --- | --- | --- |
| The binding row | 338,261 | 11,739 |
| With a VRF seed | 343,790 | 6,210 |
| VRF seed, edition master with 64 bytes of params (the tightest) | 344,929 | 5,071 |

Re-measured for the rescued-sale close (owner decision 20). The English auction's `settle`
first asks the token whether it already records the work as settled (`primarySale`), which only
a rescue does. Every `settle` row rose by 1,173: the call, and Stream's read of the token's
flags word. That word is then warm for `settlePrimary`, so the cold account and slot are not
paid twice. The start rows moved by at most 32 with the new deployment addresses, and keep
their 5,000 of margin:

| Start row | Gas | Under 350K |
| --- | --- | --- |
| The binding row | 338,253 | 11,747 |
| With a VRF seed | 343,782 | 6,218 |
| VRF seed, edition master with 64 bytes of params (the tightest) | 344,929 | 5,071 |

Re-measured for the explicit Stream state machines (owner decision 28, rc.3). `settlePrimary`
refuses a RESCUED report and `primarySale` decodes it: `settle` with a bid costs 52 more and
with no bid 106 more (the extra outcome check and its decoding, and the new deployment
addresses). The start rows moved by at most 32 with the new deployment addresses and keep
their 5,000 of margin:

| Start row | Gas | Under 350K |
| --- | --- | --- |
| The binding row | 338,273 | 11,727 |
| With a VRF seed | 343,782 | 6,218 |
| VRF seed, edition master with 64 bytes of params (the tightest) | 344,917 | 5,083 |

Re-measured for the review-fix pass of November 2026, on the merged tree:
- **The `settle` rows** are where they were (183,365 with the first payout to a seller wallet,
  158,365 with a bid, 123,989 with no bid): `settle` calls the token's `settlePrimary` as before.
- **`createWallet`** fell by 55,787 to 1,185,635: the split wallet's code changed for
  releases of tokens that return nothing (RFX-ECO-1), and its init code with it.
- **`tokenURI`**'s worst case in the size matrix is 2,736,626, 1,887 more: the changed records
  satellite (the locator fallback of RFX-REC-1) and deployment addresses took 321 off, and the
  statement log's check that the token declares `IStream`, now made before its item read
  (RFX-REC-2), adds 2,208.
- **`royaltyInfo`** is unchanged; `RoyaltyInfoGas.t.sol`
  now also calls it with exactly its 50,000-gas budget, cold, and requires every lower limit
  to revert rather than answer a zero royalty.
- **Every other row** moved by at most 32 with the new code and deployment addresses (the
  re-rate by 20, the edition auction's `open` rows by 12), and no row writes a new slot or
  account.

The start rows keep their 5,000 of margin:

| Start row | Gas | Under 350K |
| --- | --- | --- |
| The binding row | 338,253 | 11,747 |
| With a VRF seed | 343,802 | 6,198 |
| VRF seed, edition master with 64 bytes of params (the tightest) | 344,949 | 5,051 |

Re-measured for [ADR 0006](0006-work-powers-and-conventions.md) (lower-only royalty changes and
renounceable work powers), on the merged tree:
- **The re-rate** rose by 248 to 190,150, under its 192,000 regression ceiling: it now lowers
  the rate, and `setRoyaltyRate` checks the renounced powers (one more read of the record's
  first word, warm) and refuses a higher rate. Its slot and account counts are unchanged.
- **`tokenURI`**'s worst case in the size matrix is 2,736,559, 67 less, with the changed records
  satellite and deployment addresses.
- **The start rows** moved by at most 20 either way with the new deployment addresses (no start
  code changed), and `claimSigned`'s first release by 20; every other row, the edition auction's
  included, is unchanged. No row writes a new slot or account, and no maximum is raised.

The start rows keep their 5,000 of margin:

| Start row | Gas | Under 350K |
| --- | --- | --- |
| The binding row | 338,273 | 11,727 |
| With a VRF seed | 343,782 | 6,218 |
| VRF seed, edition master with 64 bytes of params (the tightest) | 344,937 | 5,063 |

Re-measured for the English auction's refusal exit (on its lane, before the permanence integration's other lanes; the integrated figures follow) (`settleOrRefund`, AUC-45 to AUC-48, which
solves LIM-SAL-16 for Independent Stream sales), on the tree with the gas-rule helpers merged and
the review's fixes applied:
- **The start rows** fell by about 820 to 900: a start now writes its `Sale` word in one `sstore`
  instead of five field writes to the same slot, which pays for the new code on the path (an
  Independent Stream terms record's locked fee recipient and refusal delay, hashed into its key only
  for an Independent Stream record, and the refusal of terms naming the auction itself as a payee).
  The refusal parameters sit in their own slot, which no start reads.
- **The settle rows** rose by 42 to 342, within their 400,000 ceilings: each payout now refuses a
  wallet that is zero, the escrow or the auction in any currency. `settleOrRefund` is not a row:
  for a cooperating Independent Stream token it is `settle` plus the escrow check and one self-call.
- **Every other row** moved by at most 32 with the new code and deployment addresses. No row
  writes a new slot or account, and no maximum is raised.

Re-measured for [ADR 0007](0007-permanence.md) (permanence; both integration rounds,
15 November 2026). Eleven lanes merged (the forward-all gas helper, Stream's permanent core with
a replaceable mint policy and its consumed-content record, 6529 Stream Editions' sealed supply
and priced mints, the permanent artist registry, the split ledger, the content store, the
hardened manager, WorkRecords with its delivery contract, the English auction's refusal exit and
the edition auction's per-sale window), the fee recipient and the museum are governed vaults at
genesis, and the English auction's opening bids moved into the asset allowlist's status word.
Against `main` at `59c1d1c1`:
- **The start rows fell** by 2,466 to 2,756 at steady state and by 120 to 309 on an artist's
  first start (+1,277 for the first work ever). The mint policy's call and the locked-terms
  events (`WorkMinted`, `TermsInterned`) cost about +1.4K at steady state and +3.8K on a first
  start; dropping the policy's redundant `ItemConsumed` (about −2.2K), the split ledger's
  calldata `validate` (about −430), the English auction's single-`sstore` sale word (about
  −900) and the opening bid read with the currency's status (one cold slot fewer, about −2.6K)
  more than paid for it. The consumed-content record moved from the policy into Stream, so no
  row gained a slot. The tightest row is **344,817, 5,183 under 350K**, and the suite's start
  margin is **5,000** again (`START_MARGIN`; it stood at 2,500 between the two rounds). The rows
  with replaced dependencies count three mint-path dependencies now (the artist registry is
  fixed, AUC-39); their ceilings (355,000 and 361,000) were set by the Stream lane at its
  measured figure plus about 2%.
- **`authorize`** (91,232, **0 new slots**, was 1) replaces `consume` (93,130): the policy runs
  the item rules and terms quote Stream ran before; the consumed-content slot is Stream's. Its
  ceiling is 94,000 (the Stream lane's measured 91,180, plus about 2%; a lowered count).
- **`createWallet`** fell by 1,089,685 to 95,950 and writes 1 new slot (was 4): a wallet is a
  66-byte vault of the split ledger (about 0.43M under Glamsterdam [E] =
  95,950 − 66 × 200 + 66 × 1,542 + 89,000 + 157,000). Its ceiling is 100,000. Releases name the
  wallet by payee list and salt: `release` −255, `claimSigned` −3,900 and −3,892.
- **`createEdition`** rose by 9,035 to 255,539 and the bound `createEdition` by 13,148 to
  157,492 (`EditionTermsLocked`, a cold fee-recipient read, the forward-all calls and the
  claim's read of Stream's content record); the bound row crossed 148,000 and its ceiling moved
  to **158,000** (measured 154,572 when set, plus about 2%).
- **The edition auction** (its lane's ceilings, measured plus about 2%, reasons in
  `EditionAuctionGasReport.t.sol`): `open` 282,319 (ceiling 290,000) and the adapter's first
  328,056 (337,000), with the per-sale terms record and limits; a new row, an artist's first
  `open`, which deploys both split wallets: **434,052** gas, 8 new slots and 2 new accounts
  (ceiling 443,000; on the split factory it measured 2,611,680 and 14 slots); the capped-sweep
  `settle` 169,693 (ceiling **174,000**: the seal at settlement, the governed payout gas read,
  and a seller wallet that now exists); a winner's `claimBid` 98,561 (the price in the mint
  data and `EditionPrimaryMint`); the worst settlement call 245,619 of execution, under its
  350,000.
- **The re-rate** rose by 7,582 to 197,732: an admin's governed `execute` updates the manager's
  liveness clock and checks its hand-over flag (GV-42, GV-43); its ceiling moved from 192,000 to
  **203,000** (measured 198,314 when set, plus about 2%).
- **`settle`** rose by 166 to 511 (the payee checks of the refusal-exit review, and the fee
  recipient now a vault).
- **`tokenURI`**: the size matrix's worst case is 2,729,953 (6,606 less); the budget proof's
  worst is 7,695,805 of 8M (`TokenUriBudget.t.sol`). The default renderer forwards all gas on
  every read, and its preview bound is `Limits.MAX_PREVIEW_BYTES`.
- **Every other row** moved by at most 495 (`royaltyInfo` −495, `refreshStanding` +104 and +210).
  No start budget and no slot maximum is raised.

(Note, 15 November 2026, review A fix pass.) Re-measured after the fixes of review A: Stream's
fallback forwards only its three views, `owner` and `contractURI` are native, `WorkMinted`
carries the seed policy in its flags word and the mint-policy answer's bounds no longer wrap;
every start row moved by at most 33 gas (the tightest, 344,816, keeps 5,184 under 350K).
`createEdition` reads only Stream's permanent record (M-1): no package proof and no mint-policy
claim, so it writes one slot fewer (5, and 1 for an edition its sale bound) and costs about
42,000 less; its ceilings move down. The replaced-dependency ceilings return to measured plus
about 2% (I-2). The edition auction's `settle` reads its sale word and terms with one SLOAD
each (I-1): about 2,400 less per scan call, 3,800 less on the call that begins settlement.
The edition auction's `open` confirms each payout wallet through the ledger's idempotent
`createWallet`, never by code at the address (review C, F16): +7,139 when both wallets exist
(ceilings 296,000 and 342,000), −5,278 when it deploys them.

| Start row | Gas | Under 350K |
| --- | --- | --- |
| The binding row | 337,951 | 12,049 |
| With a VRF seed | 343,659 | 6,341 |
| VRF seed, edition master with 64 bytes of params (the tightest) | 344,816 | 5,184 |

(Note, 15 November 2026, the integration of the four review-fix passes.) Re-measured on the
merged tree, with every review fix in: each start row moved by at most 196 gas against the
review A pass (the tightest, an artist's first two-party VRF start with an edition master at the
params bound, is **344,980, 5,020 under 350K**, so the suite's 5,000 margin holds with 20 gas to
spare); `createWallet` rose by 82 to 96,032 (the payee checks of review C, F9); the edition
auction's `open` rows by 738 (the ledger's wallet confirmation and the edition terms read);
`tokenURI`'s size-matrix worst case fell to 2,698,572 and its budget proof's to 7,696,856, with
the renderer reading only Stream's native views and storage. No row crossed its ceiling, no
ceiling moved and no start budget or slot maximum was raised.

| Start row | Gas | Under 350K |
| --- | --- | --- |
| The binding row | 338,147 | 11,853 |
| With a VRF seed | 343,823 | 6,177 |
| VRF seed, edition master with 64 bytes of params (the tightest) | 344,980 | 5,020 |

(Note, 16 November 2026, the fixes of review E.) None of them touches the start path. Re-measured,
start and other rows moved by 32 gas or less either way (bytecode metadata and code hashes of
changed contracts, not logic): the binding row is 338,115, with a VRF seed 343,791, and the
tightest **344,968, 5,032 under 350K** (32 gas inside the suite's 5,000 margin). No ceiling, count
or budget moved.

| Start row | Gas | Under 350K |
| --- | --- | --- |
| The binding row | 338,115 | 11,885 |
| With a VRF seed | 343,791 | 6,209 |
| VRF seed, edition master with 64 bytes of params (the tightest) | 344,968 | 5,032 |

(Note, 16 November 2026, the fixes of the automated reviews, three rounds.) None touches the
start path's logic (the one Stream change is in `setDependency`). Re-measured on the final tree,
start rows moved by 44 gas or less either way (code hashes and calldata of changed contracts):
the binding row is 338,115, with a VRF seed 343,779, and the tightest **344,968, 5,032 under
350K** (32 gas inside the suite's 5,000 margin). Checking the tombstone on every start, as one finding proposed, was
measured at +2,217 gas a start (the tightest row 347,177, over the margin) and not adopted.
`createEdition` rose by 230 (Editions' bounded reads), `claimSigned` by 424 and 444 (the
router's signature-bytes and payee-count checks), the re-rate by 1,890 (the manager's `execute`
now records admin activity) and `royaltyInfo` by 10. The `tokenURI` budget proof's worst row is now the one with every chunk
read linked from 3 parts, the renderer's bound, 7,902,021 (whole chunks: 7,697,762; at 4 parts
it measured 7,974,892, too close to 8M to keep). No ceiling, count or budget moved.

| Start row | Gas | Under 350K |
| --- | --- | --- |
| The binding row | 338,115 | 11,885 |
| With a VRF seed | 343,779 | 6,221 |
| VRF seed, edition master with 64 bytes of params (the tightest) | 344,968 | 5,032 |

(Note, 16 November 2026, the fourth automated review round.) Re-measured on the final tree.
Against the tree before the round (which already measured several rows above their earlier
figures: the tightest start row 344,960, `claimSigned` 138,578, the edition auction's `open`
290,306, 336,043 and 429,622, `claimBid` 98,580, the bound `createEdition` 115,541), only the
manager moved anything: its bytecode grew (the recovery, lane and activity-event fixes), which
moves its dispatch for the `canCall` every start asks by 20 gas or less (the tightest row
344,980, 5,020 under 350K, 20 gas inside the suite's 5,000 margin; `authorize` +20; a later
`claimSigned` +24; the wallet-deploying `open` −30), and the re-rate rose by 1,588 (the
`AdminActivity` event of the executing admin). No start-path logic changed; no ceiling, count
or budget moved.

| Start row | Gas | Under 350K |
| --- | --- | --- |
| The binding row | 338,127 | 11,873 |
| With a VRF seed | 343,823 | 6,177 |
| VRF seed, edition master with 64 bytes of params (the tightest) | 344,980 | 5,020 |


(Note, 17 November 2026, [ADR 0009](0009-second-permanence-pass.md).) Re-measured after the
second permanence pass and its review fixes: the 1/1 and edition-auction rows are
`test_Gas_Table` and `EditionAuctionGasReport.t.sol` at the merge of the review fixes; the
start-row margin gate is 3,000 under 350K (rows at or under 347,000), and the tightest row is
346,923. A later gas pass passes the terms record `_start` locks to the first bid of
`startWithBid`, which no longer reads its two cold slots back: every `startWithBid` row falls by
about 5,300 (the tightest to 341,582, 8,418 under 350K), a `bid` by 219, and a `start` without a
bid rises by 21; the start, bid and settle rows below are measured after it. A start whose move a consolidated (non-root) wallet signed has its own regression
ceiling (LIM-ID-21). The `refreshStanding` rows and the edition `withdrawBid` row left with
their functions. The Independent Stream rows keep their earlier figures with the current ceilings;
CI enforces those ceilings (`IndependentStreamGas.t.sol`).

The earlier table (before the plain core; its start rows show the 370,000 ceiling over earlier
measurements, and its Sepolia column is r3's):

| Operation | Prague gas | Prague ceiling | New slots | New accounts | Sepolia gas |
| --- | ---: | ---: | ---: | ---: | ---: |
| `start`, steady state | 267,047 | 370,000 | **5** | 0 | 735,859 |
| `startWithBid`, steady state | 303,745 | 370,000 | **6** | 0 | 871,980 |
| `start`, steady state, move signed by a consolidated (non-root) wallet | 314,220 | 321,000 (regression; LIM-ID-21) | 5 | 0 | — |
| `start`, two-party work | 275,543 | 370,000 | **5** | 0 | — |
| `startWithBid`, two-party work | 312,241 | 370,000 | **6** | 0 | — |
| `start`, VRF work | 272,745 | 370,000 | **5** | 0 | 852,868 (r2) |
| `start`, edition master | 267,137 | 370,000 | **5** | 0 | 736,477 |
| `start`, edition master with 64 bytes of params (the bound) | 268,229 | 370,000 | **5** | 0 | — |
| `start`, an artist's first work | 289,580 | 370,000 | **6** | 0 | — |
| `startWithBid`, an artist's first work | 326,278 | 370,000 | **7** | 0 | — |
| `startWithBid`, an artist's first work, two-party | 334,749 | 370,000 | **7** | 0 | — |
| `startWithBid`, an artist's first work, two-party, VRF | 340,405 | 370,000 | **7** | 0 | — |
| `startWithBid`, an artist's first work, two-party, VRF, edition master with 64 bytes of params (the bound) | 341,582 | 370,000 | **7** | 0 | — |
| `startWithBid`, an artist's first work, two-party, the three mint-path dependencies replaced | 341,133 | 352,000 (regression; LIM-GAS-11) | 7 | 0 | — |
| `startWithBid`, an artist's first work, two-party, VRF, the three mint-path dependencies replaced | 346,789 | 358,000 (regression; LIM-GAS-11) | 7 | 0 | — |
| `startWithBid`, ERC-20 by relayed Permit2 | 348,817 | 365,000 (regression) | 6 | 0 | — |
| `start`, first work in a new collection | 267,058 | 400,000 | 5 | 0 | 846,977 (r2) |
| `start`, first work ever (one-time) | 440,113 | 449,000 (regression) | 13 | 0 | 1,601,871 |
| `startWithBid`, first bid under new sale terms (one-time) | 373,894 | 390,000 (regression) | 9 | 0 | 1,213,250 |
| `bid` that outbids | 73,308 | 75,000 (regression) | 1 | 0 | 169,060 |
| `settle`, first payout to a seller wallet | 191,931 | 400,000 | 2 | 1 | 449,934 (sim.) |
| `settle`, with a bid | 166,931 | 400,000 | 2 | 0 | 257,763 (r2) |
| `settle`, no bid (to the museum, D140) | 129,700 | 400,000 | 1 | 0 | — |
| `auction` (view, cold, answered by the auction's lens) | 39,294 | 41,000 (regression) | 0 | 0 | — |
| `minimumBid` (view, cold, answered by the auction's lens) | 38,168 | 39,000 (regression) | 0 | 0 | — |
| `auctionClock` (view, cold, answered by the auction itself) | 24,304 | 25,000 (regression) | 0 | 0 | — |
| `authorize`, the mint policy's share of a start, as a call (was `consume`) | 93,065 | 94,000 (regression) | 0 | 0 | part of `start` |
| `createEdition` | 213,666 | 218,000 (regression) | 5 | 0 | 887,954 (sim.) |
| `createEdition`, an edition its sale bound at open | 115,585 | 118,000 (regression) | 1 | 0 | — |
| re-rate a work (governed `execute`) | 188,858 | 203,000 (regression) | 1 | 0 | — |
| `royaltyInfo` (view; `RoyaltyInfoGas.t.sol` caps its gas) | 41,380 | 50,000 of execution | 0 | 0 | 36,426 |
| `tokenURI` (view, the size matrix) | at most 2,698,572 | 8,000,000 | 0 | 0 | unchanged |
| `createWallet`, a seller wallet (one artist payee) | 96,077 | 100,000 (regression) | 1 | 1 | — |
| `release`, the artist's first ETH release | 95,813 | 96,000 (regression) | 2 | 0 | — |
| `claimSigned`, the artist's first signed release | 141,353 | 145,000 (regression) | 3 | 0 | — |
| `claimSigned`, a later signed release (next nonce) | 90,033 | 92,000 (regression) | 0 | 0 | — |
| Edition auction `open`, steady state (binds the edition) | 298,471 | 301,000 (regression) | 6 | 0 | — |
| Edition auction `open`, the adapter's first (one-time) | 298,471 | 342,000 (regression) | 8 | 0 | — |
| Edition auction `open`, an artist's first sale (deploys both split wallets) | 437,787 | 443,000 (regression) | 8 | 2 | — |
| Edition `bid`, its 8-step word exists | 69,194 | 110,000 | 1 | 0 | — |
| Edition `bid`, opens an 8-step word | 86,264 | 110,000 | 2 | 0 | — |
| Edition `bid`, capped sale | 71,611 | 110,000 | 1 | 0 | — |
| Edition `bid` near the close (1/1 read, soft close) | 78,418 | 110,000 | 1 | 0 | — |
| Edition `bid`, worst path (capped, opens an 8-step word, the 1/1 read live after its dispute pause lapsed, soft close; review PoC, not in CI) | 106,295 | 110,000 | 2 | 0 | — |
| Edition `raise`, same 8-step word | 53,808 | 56,000 (regression) | 0 | 0 | — |
| Edition `raise`, capped (departure logged) | 79,034 | 81,000 (regression) | 1 | 0 | — |
| Edition `settle`, 40 used steps | 150,370 | 400,000 | 1 | 0 | — |
| Edition `settle`, capped, one departure swept | 178,079 | 182,000 (regression) | 1 | 0 | — |
| Edition `settle`, every step used (512 steps, departures at the cut), each call | at most 243,188 of execution | 350,000 of execution | 0 to 2 (the call that clears and leaves its sweep unfinished writes the result and its settler's progress) | 0 | — |
| Edition `settle`, a 96-departure chunk with departures scattered over the log's words (336 steps), each call; review PoC, not in CI | at most 307,070 of execution | 350,000 of execution | 0 to 2 | 0 | — |
| Edition `claimBid`, a winner and new holder | 98,561 | 100,000 | 1 | 0 | — |
| Edition `claimBid`, refund only | 47,518 | 49,000 (regression) | 0 | 0 | — |
| Edition `claimBidFor`, refund credited | 64,557 | 67,000 (regression) | 1 | 0 | — |
| Independent Stream `joinIndependentStream`, creating the identity (provenance and consent checked) | 303,115 | 345,000 (regression) | 6 | 0 | ~0.96M [E] |
| Independent Stream `approveItem` | 59,357 | 61,000 (regression) | 1 | 0 | ~0.15M [E] |
| Independent Stream `start`, first work (deploys both vaults; license text checked) | 679,109 | 700,000 (regression) | 18 | 2 | ~2.77M [E] |
| Independent Stream `start`, steady | 416,019 | 425,000 (regression) | 10 | 0 | ~1.31M [E] |
| Independent Stream first `bid` | 192,512 | 196,000 (regression) | 5 | 0 | ~0.64M [E] |
| Independent Stream `settle`, sold | 179,197 | 187,000 (regression) | 2 | 0 | ~0.35M [E] |
| Independent Stream `settle`, unbid (to the template) | 153,849 | 162,000 (regression) | 2 | 0 | ~0.33M [E] |
| Independent Stream restart | 248,303 | 249,000 (regression) | 4 | 0 | ~0.60M [E] |
| Independent Stream edition `open` | 373,965 | 345,000 (regression) | 7 | 0 | ~1.00M [E] |
| Independent Stream `createEdition` | 86,736 | 90,000 (regression) | 1 | 0 | ~0.18M [E] |
| Independent Stream edition `settle` | 151,447 | 162,000 (regression) | 1 | 0 | ~0.24M [E] |
| Deploy `IndependentStream6529` (whole transaction; 5,100,251 through its deployer, which records it; each deployment row measured in its own test) | 5,418,645 | 5,600,000 (regression) | 11 | 1 | ~37.9M [E] through its deployer ([ADR 0008](0008-independent-stream.md) §1) |
| Deploy `IndependentStreamEditions6529` (whole transaction; 3,592,141 through its deployer) | 3,805,265 | 3,870,000 (regression) | 8 | 1 | ~26.6M [E] through its deployer |

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
  - QUALITY-2: `StreamEditions6529.mint` returns only the sale kind of its terms, which the
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

The same operations, as CI measured them for the r2 comparison (on the code r2 ran, before the
state-growth diet; today's figures are in the table above) and as the r2 receipts replay with
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

- **This ADR's table** (amendment of 23 November 2026): re-measured on the plain core, with what
  each ceiling applies to and the Sepolia starts of r6 and r7 beside their rows. No ceiling or
  count changed; the earlier table is kept as history.

- **ADR 0001.** The 300K start budget (Intended behavior) was already amended
  to 350K by ADR 0003. It is now Prague gas plus the slot maximum. The storage
  figures in §8 (0.23 ETH per MB per gwei, 72 KB per transaction) predate
  Glamsterdam.
- **ADR 0003.** The 350K steady-state start gate and its measured table are
  Prague gas. The "two full chunks per transaction" figure predates
  Glamsterdam: one full chunk per transaction under Glamsterdam (uploader
  README).
