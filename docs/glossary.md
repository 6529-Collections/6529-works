# Glossary

The terms a reader meets in this repository, in plain English, as the plain-core stack defines
them ([ADR 0010](adr/0010-plain-permanent-core.md)). Start with the
[three-page overview](overview.md). Each entry links the page that owns its rules. Shares and
rates are out of 100,000.

> Pre-audit. See the [project status](../README.md#status).

## Products and contracts

### 6529 Stream

The one shared, network-curated ERC-721 of 1/1 works (`Stream6529`). Permanent. See
[stream and auctions](spec/stream-and-auctions.md).

### 6529 Stream Editions

The one shared ERC-1155 (`StreamEditions6529`). Each edition is anchored by a Stream master and sold
by an edition auction. Permanent. See [editions and sales](spec/editions-and-sales.md).

### 6529 Independent Stream

An artist's own token pair (6529 Independent Stream for 1/1s, 6529 Independent Stream Editions
for editions), built from the same plain token code as Stream and Editions, listed by the network
without the curation vote. Each collection keeps the artist's own name and symbol. See
[Independent Stream](spec/independent-stream.md).

### permanent contract

A contract deployed once and never replaced: `Stream6529`, `StreamEditions6529`,
`StreamWorkFacts6529`, `StreamDirectory6529`, `SplitLedger` and its vaults, `RevenueEscrow`,
`ContentStore`, and each Independent Stream token. It holds only ownership, the facts of a finished
work and money already owed.

### module

A replaceable contract that a permanent contract takes instructions or answers from. The network
adds and removes modules.

### seam

The four things a permanent token accepts from modules: a minter mints and records an outcome;
the TERMS module sets royalties; the RENDERER module draws an unfinalized work; the RECORDS
module edits a record within what `StreamWorkFacts6529` allows. Nothing else. See the
[overview](overview.md#2-the-permanent-core-and-its-promise).

### module slot

A named place in a permanent contract that holds one module (`TERMS`, `RENDERER`, `RECORDS` in a
token; `ACCOUNTS`, `INDEPENDENT_STREAM`, `INDEPENDENT_TERMS`, `INDEPENDENT_RECORDS` in
`StreamDirectory6529`).

### minter

A sale contract a token contract lists as allowed to mint. It may record the outcome of a token
it still holds unsold, once, or burn it. An Independent Stream token's minters are the Independent
Stream module's answer.

### WorkFacts

`StreamWorkFacts6529`: the permanent record of every work, keyed by token and token ID: media files
(fixed when the record opens), descriptive record (fixed at finalize), license, pinned renderer and
one-way locks. Unowned. See [works and storage](spec/works-and-storage.md).

### WorkRules

The RECORDS module: who may edit a record and when, finalize timing, consent to relicense or
change the royalty rate, repin, renunciations. Replaceable. See
[works and storage](spec/works-and-storage.md).

### StreamTerms

The TERMS module: sets royalty receiver and rate, locks the rate, and lowers the network's fee
share (only down). Replaceable. See [economics and payouts](spec/economics-and-payouts.md).

### Directory

`StreamDirectory6529`: the permanent address of the network's shared modules (accounts, Independent
Stream, the Independent Stream tokens' terms and records). The split ledger asks it for payout
addresses; it holds the [unclaimed period](#unclaimed-period).

### Accounts

The replaceable accounts module behind `StreamDirectory6529`: artist accounts, wallets, payout
addresses, replacement, freeze and contest. See
[identity and recovery](spec/identity-and-recovery.md).

### Independent Stream gate

The Independent Stream module's answer to an Independent Stream token: which sale contracts may mint
for it, and which were removed. Found through `StreamDirectory6529`. See
[Independent Stream](spec/independent-stream.md).

### mint policy

The module a sale contract asks before minting (`IMintPolicy.authorize`): for Stream the
`PackageRegistry`, for Independent Stream tokens the `IndependentStreamRegistry`. It checks the item
and answers the mint facts and sale terms. See [curation](spec/curation.md).

### entropy module

The replaceable module that delivers a VRF [seed](#seed) to a work whose seed policy asks for
one. See [entropy](spec/entropy.md).

### artist resolver

The contract the statement log asks who may speak as ARTIST for a subject: the accounts module.
See [disputes and statements](spec/disputes-and-statements.md).

## Network and settings

### TDH

The 6529 network's measure of holdings, behind its governance. The network address is a 2-of-n
Safe until the TDH bridge exists.

### delay class

One of the AccessManager's role delays: none, 24 hours, 3 days, 7 days. A class's delay holds
until a 7-day remap by the network changes it. See [governance](spec/governance.md) and the
[role matrix](audit/roles.md).

### moduleDelay

The wait between announcing a module (or adding a minter) and its first use. A network setting
in each token contract and `StreamDirectory6529`: 7 days at launch, changed at once, zero allowed.
An addition already announced keeps the time it was given.

### rescue

The network's move of a token that a removed minter still holds unsold, once the
[rescue delay](#rescuedelay) has passed since the removal. It reaches only a token that a
removed minter holds and whose sale outcome was never recorded. The English auction records the
outcome before a work leaves it, so no work it sold can be rescued.

### rescueDelay

The wait before a `rescue`. A network setting of each 1/1 token contract: 14 days at launch, read
when the rescue is attempted.

### rebind

The network's move of an edition with no seal to another edition sale contract,
once the [rebind delay](#rebinddelay) has passed since its own sale contract was removed.

### rebindDelay

The wait before a `rebind`. A network setting of `StreamEditions6529`: 14 days at launch, read when
the rebind is attempted.

### unclaimed period

How long money must wait unclaimed before it can go to the network: a marked split-vault share
or an aged escrow or auction credit. A network setting in `StreamDirectory6529`: 180 days at launch,
read when the forfeit or expiry is attempted. Only money that has itself waited counts.

### binding

Removed in the plain core (ADR 0010): the one-shot contract-to-contract links set at genesis.
Genesis modules and minters are now constructor arguments.

## Works

### package

A set of approved items, committed to by a [package root](#package-root). See
[curation](spec/curation.md).

### package root

The Merkle root of a package's items, signed by a curation signer with an
[evidence hash](#evidence-hash).

### item hash

The hash of one approved item. It commits to the content, media, parties, payees, license and
sale terms, and is stored in the token at mint.

### acceptance

A party's EIP-712 signature over a package root, given by any wallet of its account.

### move

A revocable EIP-712 signature by a wallet of the lead artist's account, authorizing a Stream
mint; checked when the item is [consumed](#consume).

### consume

The mint policy's check that an approved item mints once. The token itself keeps one live token
per content hash.

### content release

The mint policy's permission, after an upheld dispute burned a token, to mint that content again
for the same artist. See [curation](spec/curation.md).

### tombstone

The mint policy's mark that an item may never mint again.

### seed policy

Whether a work has no seed, an artist's seed, or a VRF seed. Recorded in the token, not
interpreted by it.

### seed

The value that decides how a generative work looks. Stored in the token at mint, never changed.

### vrf

Chainlink's verifiable randomness, used by the [entropy module](#entropy-module) for VRF seeds.

### outcome

How a token's first sale ended: none, sold, unsold or rescued. Set once by the holding minter
(or by `rescue`), never changed. The price is only logged.

### finalize

Freezing a work's descriptive record and pinning the renderer that draws it, in
`StreamWorkFacts6529`. Never undone.

### windowworks

`window.works`: the object `{ v: 1, tokenId, seed }` the renderer's page sets before a work's
JavaScript runs. See [rendering and tokenURI](spec/rendering-and-tokenuri.md).

## Curation, disputes and statements

### curation signer

A key the network grants whose EIP-712 approval of a package root the curation verifier accepts.

### signer epoch

The value a signer's approval must bind. A disable, re-enable or new grant starts a new one, so
older approvals stop counting.

### evidence hash

The hash a curation signer signs with a package root, committing to the published vote and
rules.

### curation evidence

The published record behind an approval, logged as a `CURATION_EVIDENCE` statement.

### wave

A 6529 network discussion and voting space for curation and disputes. The contracts never read
one.

### dispute pause

The auction's pause of one sale while a dispute is decided: at most 3 days, once per sale, a
compiled value of the replaceable auction. See [stream and auctions](spec/stream-and-auctions.md).

### dispute outcome

A network statement deciding a dispute; an upheld one lets the network cancel the sale and burn
the unsold token.

### statement

One entry in the statement log about a [subject](#subject). See
[disputes and statements](spec/disputes-and-statements.md).

### subject

What a statement is about: `(token, id)`, or `(address(0), id)` before a token exists.

### statement kind

A label of what a statement is. `DISPUTE_OUTCOME`, `CURATION_EVIDENCE` and `GOVERNANCE_MANIFEST`
are reserved.

### statement role

Who a statement speaks as: ARTIST (per the [artist resolver](#artist-resolver)), OWNER, CURATOR
or PLATFORM.

### entry hash

The identity of one statement-log entry, which other entries cite.

### supersession

A statement naming an earlier entry hash it replaces. The log does not check it.

### chain head

The rolling hash of one subject's entries, which lets an indexer prove a rebuilt chain complete.

## Accounts

### restraint

The state in which no wallet may act for an account: while it is frozen or a replacement is
pending. Running sales continue. A freeze blocks a contest of a replacement, and the network may
place a freeze again. See [identity and recovery](spec/identity-and-recovery.md).
