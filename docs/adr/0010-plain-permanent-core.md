# ADR 0010: A plain permanent core

Status: Accepted by owner instruction, 22 November 2026. Amends [ADR 0001](0001-v1-scope.md),
[ADR 0004](0004-gas-budgets-under-glamsterdam.md) (the start budget),
[ADR 0007](0007-permanence.md) (what is permanent), [ADR 0008](0008-independent-stream.md) (the
templates) and [ADR 0009](0009-second-permanence-pass.md) (its compiled waits in permanent contracts become settings).
Pre-audit: nothing here claims an audit, production readiness or correctness.

## Context

A cold review of `581cfb6f` scored the repository 5.5 of 10. Its main points: the permanent
contracts are too large; the 24,576-byte code limit is steering the design; and novel code (a
hand-written ABI decoder, a hand-rolled hash table, hand-packed words, an assembly event) sits in
contracts that can never be replaced. The owner decided to shrink the permanent contracts
radically. A study with prototypes and measurements preceded this record.

## Decision

**Permanent contracts hold only what must never change:**
1. who owns which token, and the collection's address;
2. the facts of a finished work;
3. money already owed.

**Everything that is a rule lives in replaceable modules:** fee terms, sale state, rescue
routing, who may edit a record and when, consent, notice timers, identity, delisting, the
royalty policy. Code moves; nothing is dropped from the product except, as agreed, ERC-20
payments (ETH only at launch: no Permit2, no currency freeze and reopening).

**Permanent code is plain:** OpenZeppelin tokens with one struct per token; no hand-written
decoder, hash table, hand-packed word or assembly in the tokens and records; no gas number; no
`try`/`catch`.

### What "permanent" promises

1. Your token is yours: once you hold it, nobody (not the network, not any module) can move,
   freeze or burn it, and a transfer never depends on any other contract working.
2. The work is fixed: who made it and the item it was minted from never change, its media files
   never change, its description never changes once finalized, and a CC0 license can never be
   taken back.
3. Everything else is run by replaceable modules, which the network adds and removes; waiting
   periods are the network's settings, not promises (at launch: 7 days before an added module
   takes effect); money already in a split vault or the escrow is paid out by permanent code,
   an artist's share to the address the accounts module names for the artist at that time.

Some acts of the RECORDS module cannot be undone by replacing it, and are allowed by this
design: finalizing a record, making a work CC0, locking a license or a pin, and re-pinning a
finalized work.

### The seam

A permanent contract accepts four things from a module and nothing else:

1. A registered **minter** (a sale contract) may mint a new token and state its facts. While it
   still holds a token whose sale has no outcome, it may record the outcome, once, or burn the
   token.
2. The **TERMS** module may set a token's royalty receiver and rate, and lock the rate for good.
3. The **RENDERER** module draws a work that is not finalized. A finalized work is drawn by the
   renderer pinned in `StreamWorkFacts6529`.
4. The **RECORDS** module may change a work's record, license and pin within what
   `StreamWorkFacts6529` allows: never the media, never the record after finalize, never away from
   CC0, never past a lock.

No module can move a token, change a fact fixed at mint, or touch money in a vault or the
escrow. The one move by anyone but the owner is `rescue`: the network may move a token that a
removed minter still holds unsold, once the rescue period has passed since the removal.

### Waiting periods

There are **no fixed time periods in permanent contracts** (owner, 22 November 2026: "you never
know what may happen; for example there could be a chain break and we have to take action").
Every wait in permanent code is a setting of the network: a stored value with a launch value,
changed by the network at once (no floor, no delay on the change, zero allowed), with an event
carrying the old and the new value. They are not promises.

| Waiting period | Launch value | Setting | How a change treats what is already running |
| --- | --- | --- | --- |
| Before an added module or minter takes effect | 7 days | `moduleDelay` in each token contract and in `StreamDirectory6529` | An addition already announced keeps the time it was given |
| After a minter's removal, before `rescue` of a token it still holds unsold | 14 days | `Stream6529.rescueDelay` (each Independent Stream token has its own) | Read when the rescue is attempted |
| After a minter's removal, before `rebind` of an edition with no seal | 14 days | `StreamEditions6529.rebindDelay` | Read when the rebind is attempted |
| Before unclaimed money can go to the network (a marked split-vault share; an aged escrow credit) | 180 days | `StreamDirectory6529.unclaimedPeriod`, read by `SplitLedger` and `RevenueEscrow` | Read when the forfeit or expiry is attempted, so it applies to marks and credits already running |

Removing a module or minter is immediate. The split ledger stays unowned: it reads the unclaimed
period from `StreamDirectory6529`, the address it already asks for payout addresses, so it gains no
authority, no setter and no storage; one setting serves the ledger and the escrow. If that read
fails, the forfeit or expiry reverts and the money stays where it is.

What stays fixed are the rules, not durations: nobody moves, freezes or burns a held token; mint
facts, media, the finalized record and CC0 do not change; an edition's maximum and seal hold; no
module touches a token, a finalized fact or owed money. Limits that bound the work of one
transaction (payees per vault, chunks per file, name lengths) are not time periods and stay
compiled. Role delays of the AccessManager are also the network's to change. Documents must not
call any of these periods a guarantee.

### If a module is missing, hostile or out of gas

| Answer | Behaviour |
| --- | --- |
| `ownerOf`, transfers, approvals | Always work; no call leaves the token contract |
| `royaltyInfo` | Two storage reads; no module is asked |
| `tokenURI` | Reverts if its renderer is missing, fails, runs out of gas, or (pinned) has changed code. It never falls back to another renderer |
| `mint` | Needs an active minter; existing tokens are unaffected |
| A vault release to an artist | Reverts if the accounts module is missing or fails; the money stays in the vault |

A call that runs out of gas reverts the whole call: no path returns a default.

### What moved where

| Today | After |
| --- | --- |
| `Stream6529` (799 lines, 22,814 bytes) | `src/core/StreamBase.sol` and `Stream6529.sol`, with `Modules.sol` (prototype: about 320 lines, 13,393 bytes) |
| Interned terms, fee recipients, fee share, museum routing, sale kinds in `Stream6529` | The sale contract (seller and fee share per sale) and the `TERMS` module |
| Content release and tombstones in `Stream6529` | The mint policy (`PackageRegistry`); the token keeps "one live token per content" |
| `StreamViews`, `StreamLayout`, `extsload` | Deleted; plain getters `workOf`, `collectionOf` |
| `StreamEditions6529` (502 lines, 19,966 bytes) | `src/core/EditionsBase.sol` and `StreamEditions6529.sol` (prototype: 12,113 bytes) |
| Edition creation rules and economics in `StreamEditions6529` | The edition sale contract |
| `WorkRecords` (737 lines, 22,934 bytes) | `src/core/StreamWorkFacts6529.sol` (permanent facts, 9,076 bytes) and the `RECORDS` module `WorkRules` |
| `ArtistRegistry` (permanent) | The replaceable `Accounts` module behind the permanent `src/core/StreamDirectory6529.sol` |
| The Independent Stream directory in `ArtistRegistry` | `IndependentStreamRegistry` |
| `IndependentStream6529`, `IndependentStreamEditions6529` (full contracts with their own records) | The same plain token bases with a different gate; records in the shared `StreamWorkFacts6529` |
| `EnglishAuctionLens` | Folded back into `EnglishAuction` |
| `SplitLedger`, `SplitVault` | Unchanged; deployed with `StreamDirectory6529` as payout resolver |
| `RevenueEscrow`, `ContentStore` | Fixed on a separate branch: aged-credit expiry, `locked()`, ranged completeness attestation |
| `StatementLog` | One read changes (`itemHashOf`) |

The frozen interfaces are in `src/interfaces/core/`.

### The owner's ten answers (22 November 2026)

1. "The network's share on an existing work can only go down" is enforced by the `TERMS` module,
   not by permanent code.
2. Artist identity and payout addresses come from a replaceable accounts module; tokens keep an
   artist ID.
3. No fixed time periods in permanent contracts. Every wait is the network's setting, changed
   at once, with no floor: adding a module or minter (7 days at launch), rescue and edition
   rebind after a minter's removal (14 days at launch), the unclaimed period (180 days at
   launch). This replaces the earlier "7 days, in code". Removal of a module or minter is
   immediate.
4. The 350,000 start budget is replaced by a 370,000 ceiling and 8 new slots.
5. A sale's price is logged, not stored.
6. Only money that has itself waited the unclaimed period (180 days at launch) expires to the
   network, in the escrow and both
   auctions; no third party can shorten or postpone a clock.
7. The network may rebind a stuck edition (no copies, not sealed) once the rebind period (14
   days at launch) has passed since its sale contract was removed.
8. An unsold Independent Stream work waits in the network's sale contract and can be offered again
   there; the artist cannot take it without a sale.
9. A freeze still blocks a contest of a replacement, and a freeze can be placed again; the
   documents say so.
10. A collaborator's consent covers the royalty rate, for Independent Stream works.

### Gas

Measured on the real auction and mint policy against a plain core (Prague gas): a steady start
rises from 267,067 to 311,906 (two more new slots: the token's royalty word and the sale's
seller word); the tightest start row from 341,582 to 363,899; a settle with a bid falls from
166,931 to 140,998; cold `royaltyInfo` from 41,390 to 26,275; `tokenURI` is unchanged within
1%. **New gate: every start row at most 370,000 Prague gas and 8 new slots.** ADR 0004's table
is re-measured on the built stack.

### Decided while freezing the interfaces

- A burn does not clear `tokenOfContent`; a content mints again when the token it names is
  burned. The mint policy reads that token to apply the release rules.
- The seed is stored in the token at mint; the entropy "eras" list is gone.
- The token contracts are split into a base with six frozen hooks (`StreamBase`,
  `EditionsBase`) and a thin concrete contract, so the Independent Stream pair is the same code.
- An Independent Stream token has no minter list: its minters are the Independent Stream module's
  answer, and the waiting period applies to installing that module in `StreamDirectory6529`. Which
  contracts count as its removed minters (for `rescue`) is also that module's answer.
- Genesis modules and minters are constructor arguments (predicted addresses); after
  construction every addition goes through the waiting period in force.
- An edition is created by its sale contract in one call (`create`), not by anyone later.
- `IAccounts` loses its two Independent Stream views and gains `payoutAddress`.

## Deferred

- Shrinking the edition auction's lenses and the renderer (both replaceable; unchanged in size).
- The ledger's calldata binary search stays.
- Old interfaces under `src/interfaces/` are deleted at integration, once nothing imports them.

## Consequences

- Sepolia round r5 is replaced by a new deployment; every address changes.
- The specification pages move rules between "facts" and "modules"; every sentence calling a
  role delay a guarantee is corrected.
- Tests of removed mechanisms (interned terms, the view extension, `extsload`, dependency
  replacement, the sync walks, ERC-20 paths) are deleted with them; behaviour tests are ported.

## Amendment note (22 November 2026, after integration)

The waiting-period table above says the unclaimed period is "read when the forfeit or expiry is
attempted". That is exact for the split ledger and for both auctions (`AgedCredits`). The escrow
also reads the period at every deposit and recovery, when it ages an account's credit windows:
a change of the period reaches every amount not yet aged, and an amount a write has already
counted as aged stays aged (`RevenueEscrow`, ECO-45).

Decision 6 ("no third party can shorten or postpone a clock") holds as written for both
auctions (`AgedCredits`). For the escrow the rule is: money expires only after it has itself
waited the period; a window's due time can be at most two periods after its first deposit.
A deposit into an open window, by anyone, can move that window's due time later within that
bound and never earlier (`RevenueEscrow`, ECO-45; owner ruling of 22 November 2026).

Decision 4 (the 370,000 ceiling and 8 new slots) holds for every start row but one kind. A
start with a bid of a VRF work also writes the work's seed, a ninth slot, in the token. Those
rows have their own ceiling: 395,000 Prague gas and 9 new slots. The ceilings are test budgets
asserted in the gas report, not chain code (owner ruling of 22 November 2026).

Decision 7 (the network may rebind a stuck edition) covers every edition with no seal whose
minter was removed, with or without copies: the copies stay and count toward the maximum, and
the new minter seals at or above them (owner ruling of 22 November 2026). A minter added again
after a removal gets no new power during its wait, on both tokens: on the editions token it
seals nothing and mints only editions sealed before its removal.
