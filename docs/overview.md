# 6529 Works in three pages

> Pre-audit. Nothing here claims an audit, production readiness or correctness. See the
> [project status](../README.md#status).

## 1. What it is

6529 Works is the 6529 network's art protocol on Ethereum. It has two products:

- **6529 Stream**, one shared ERC-721 for curated 1/1 artworks. A work gets in only after the
  network's curation approves it, and every party named in it has signed.
- **6529 Stream Editions**, one shared ERC-1155. Each edition is anchored by a Stream work
  (its master) and sells in a uniform-price auction that closes just after the master's sale.

Beside them, **6529 Independent Stream** and **6529 Independent Stream Editions** are an artist's
own token pair, built from the same code and listed by the network without the curation vote.

Sales are in ETH. Anyone may start an approved work's English auction, and anyone may settle it.
Money moves by pull: proceeds and royalties collect in immutable split vaults that each payee
releases from, and a payment that fails waits in an escrow for its owner. Content is addressed
by hash and stored on Arweave and IPFS; anyone can put a work's files on-chain.

The **network** is one address, a 2-of-n Safe today and the TDH-governed account once the bridge
exists. It is the authority over everything that is not fixed: it chooses the modules, the sale
contracts and the settings described below.

## 2. The permanent core and its promise

A few contracts are deployed once and never replaced. They hold only three things: who owns
which token (and the collection's address), the facts of a finished work, and money already
owed.

| Permanent contract | What it keeps |
| --- | --- |
| `Stream6529` | Ownership of each 1/1; the facts fixed at mint (item, artist, collection, serial, seed); how the first sale ended; the royalty receiver and rate |
| `StreamEditions6529` | Ownership of each copy; each edition's maximum, count minted and seal |
| `StreamWorkFacts6529` | Each work's media files, descriptive record, license and pinned renderer, for Stream and every Independent Stream token |
| `StreamDirectory6529` | Where the network's shared modules are (accounts, Independent Stream, the Independent Stream tokens' terms and records), and the unclaimed period |
| `SplitLedger` and its vaults | Money owed to payees; unowned |
| `RevenueEscrow` | Payments that failed, held for their owner |
| `ContentStore` | Bytes put on-chain; never removed |

Their code is plain: OpenZeppelin tokens, one struct per token, no assembly, no hand-written
decoders, no gas numbers. What "permanent" promises, in the words of
[ADR 0010](adr/0010-plain-permanent-core.md):

1. Your token is yours: once you hold it, nobody (not the network, not any module) can move,
   freeze or burn it, and a transfer never depends on any other contract working.
2. The work is fixed: who made it and the item it was minted from never change, its media files
   never change, its description never changes once finalized, and a CC0 license can never be
   taken back.
3. Everything else is run by replaceable modules, which the network adds and removes; waiting
   periods are the network's settings, not promises (at launch: 7 days before an added module
   takes effect); money already in a split vault or the escrow is paid out by permanent code.

**The seam.** A permanent token accepts four things from modules and nothing else: an active
minter mints and records how a sale ended (or burns a token it still holds unsold); the TERMS
module sets royalty receiver and rate and may lock the rate; the RENDERER module draws a work
that is not finalized; the RECORDS module edits a work's record within what `StreamWorkFacts6529`
allows (never the media, never after finalize, never away from CC0, never past a lock). The one move
by anyone but the owner is `rescue`: the network may move a token that a removed sale contract still
holds unsold.

## 3. The modules and who can change them

| Module (replaceable) | Its job |
| --- | --- |
| `EnglishAuction` | The 1/1 sale: start (mint into its custody), bids, credits, settlement, the dispute pause |
| `PackageRegistry` (mint policy) | What may be minted: the approved item, the artist's signature, content rules, the sale terms |
| `UniformEditionAuction` | Creates an edition when it opens, sells it, mints to winners, seals the supply |
| `StreamTerms` (TERMS) | Royalty receiver and rate; lowering the network's fee share (only down) |
| `WorkRules` (RECORDS) and `WorkDelivery` | Who may edit a record and when; finalize; consent to relicense; where files are served from |
| `Renderer` (RENDERER) | Builds `tokenURI` for a work that is not finalized |
| `Accounts` (in `StreamDirectory6529`) | Artist accounts, wallets, payout addresses, replacement and recovery |
| `IndependentStreamRegistry` (in `StreamDirectory6529`) | Independent Stream listings, delisting, which sale contracts may mint for an Independent Stream token |
| `EconomicsResolver`, `StatementLog`, `DependencyRegistry`, entropy | Fee recipients and defaults; disputes and statements; libraries for generative works; VRF seeds |

**Who changes them.** Only the network. It announces a module or adds a sale contract; anyone
installs it once the waiting period has passed. It removes one at once. Each permanent contract
counts the wait itself.

**Waiting periods are settings, not promises.** Every wait in a permanent contract is a stored
value with a launch value, which the network changes at once (no floor, zero allowed), with an
event carrying the old and the new value:

| Setting | Where | Launch value | What a change does to what is already running |
| --- | --- | --- | --- |
| `moduleDelay` | each token contract and `StreamDirectory6529` | 7 days | An addition already announced keeps the time it was given |
| `rescueDelay` | `Stream6529` (each Independent Stream token has its own) | 14 days | Read when a rescue is attempted |
| `rebindDelay` | `StreamEditions6529` | 14 days | Read when a rebind is attempted |
| `unclaimedPeriod` | `StreamDirectory6529`, read by `SplitLedger`, `RevenueEscrow` and both auctions | 180 days | The split ledger and the auctions read it when a forfeit or expiry is attempted. The escrow also reads it at every deposit and recovery; an amount it has already counted as aged stays aged |

**Numbers compiled into replaceable contracts.** These are fixed in today's modules and change
only when the network installs a different module: the accounts module's 2-day own change,
14-day replacement notice, 90-day contest lapse and 14-day freeze; the 14-day finalize notice in
`WorkRules`; the auction's dispute pause (at most 3 days) and 2-day Independent Stream refusal exit;
the edition auction's 15-minute close after the 1/1 and 21-day abandon. Limits on the work of one
transaction (payees per vault, chunks per file, name lengths) are compiled everywhere.

**Role delays.** The network acts through one OpenZeppelin `AccessManager`, with delay classes
of none, 24 hours, 3 days and 7 days. These are the network's too: one 7-day action can remap a
function or change a class, so a class's delay holds until such a remap changes it. The full
map is the [role matrix](audit/roles.md); what the network can do, to whom and how fast is
[trust assumptions](audit/trust-assumptions.md).

## 4. How a sale flows

**A curated 1/1.**
1. The work is approved by curation; the artist and every party sign the item.
2. Anyone calls `start` on `EnglishAuction` (or on `SaleStarter`, which also deploys the work's
   split vaults and opens its record in the same transaction). The auction asks the mint policy, which checks
   the item and answers the mint facts and the sale terms. The auction mints the token into its
   own custody and opens a 24-hour clock (a governed value).
3. Bidders bid in ETH. An outbid bid becomes a credit its owner claims.
4. Anyone calls `settle` after the end. The auction records the sale on `Stream6529` (the price is
   logged), delivers the token, and pays the seller's split vault and the network. Unsold, the
   token goes to the museum the network names.
5. Payees release their shares from the split vault whenever they like. Royalties on later
   sales arrive at the receiver `Stream6529` stores.

**An edition.** When the master's sale is open, the edition auction calls
`StreamEditions6529.create` once with the maximum and royalty, takes bids at one clearing price,
closes 15 minutes after the master, seals the supply and mints each winner's copies when they claim.

**An Independent Stream work.** The artist's own token (the same plain code) mints only through sale
contracts the Independent Stream module allows. Collaborators consent to the item and its royalty
rate. An unsold Independent Stream work waits in the network's sale contract and can be offered
again there.

**A finished work.** The artist finalizes the record. `StreamWorkFacts6529` then freezes the
description and pins the renderer that draws it; a CC0 license never changes.

## Where next

| You want | Read |
| --- | --- |
| The contracts and how they call each other | [Architecture](architecture.md) |
| Every rule, by ID | [Specification](spec/README.md) |
| Build, test and run locally | [Quickstart](quickstart.md) |
| Integrate a marketplace, wallet or indexer | [Integrator guide](integrators/README.md) |
| Review the code | [Auditor pack](audit/README.md) |
| Why a decision was made | [ADRs](adr/README.md) |
