# ADR 0008: 6529 Stream Federated in v1

Status: Accepted by owner instruction, 15 November 2026. Recorded by the delivery owner
(Claude Code, acting for the repository owner). Amends [ADR 0001](0001-v1-scope.md) §16 (the
federated tier, as already moved into v1 by [ADR 0007](0007-permanence.md)) and
[ADR 0005](0005-stream-editions-auction.md) decision 9 (an unbid federated work). Specifies
ADR 0007's package P6, which that record left "in v1, specified by a later ADR".

The behaviour is specified in [Federation](../spec/federation.md) (rules FED-1 to FED-63); this
record is how it was decided. It is true at the tip that merges ADR 0007's review fixes
(16 November 2026): §4, §7, §8 and §10 record what that merge changed underneath the federation.

## Context

The owner decided on 15 November 2026 that Federated Stream (an artist's own ERC-721 of 1/1s)
and Federated Stream Editions (the ERC-1155 of a linked pair) ship in v1. They are artist-run
and uncurated, split 90% to the creator and 10% to the network on primary sales and royalties,
earn no TDH, and must be listed in the network's directory so the network knows about them.
The 10% is what an artist pays for the registry; an artist who does not want to pay may deploy
any contract outside it, and the network adds no control whose only purpose is to restrict that.
What must hold is that a listed contract pays the 10% on what it sells and earns, and cannot stay
listed while routing around it; exit is one-way and clean; delisting never touches tokens,
ownership or funds owed.

Study H sized the design and proposed seventeen decisions with defaults; the owner approved the
defaults. ADR 0007 built the permanent part: the artist registry's per-token directory, its
replaceable federation-registry pointer, `registerFederated`, token-written exit, and the
English auction's refused-settlement exit with nine guarantees a federated template must meet.

## Decision

### 0. The registry bargain

The 10% pays for the registry: the listing in the permanent directory, the shared adapters and
infrastructure, and recognition by the network. A listed contract pays it on everything it sells
through a network adapter (the adapter takes the share from the registry, never from the token,
and pays the network itself) and on every royalty of a work minted while listed (the royalty
receiver is a split-ledger vault paying the governed fee vault 10%, fixed at construction).
Deploying any contract outside the registry is welcome and needs nobody's permission; the
network adds no control whose only purpose is to restrict it. Exit is one-way: once a contract
leaves, it never rejoins, starts no new sale through a network adapter (§8), and its earlier
works keep their 90/10 vaults. Delisting, by vote, stops new sales and ends running ones unsold
with refunds; neither delisting nor exit ever touches tokens, ownership, records or funds owed.

### 1. Forms and deployment

- Two templates: `FederatedStream` (ERC-721) and `FederatedEditions` (the pair's ERC-1155,
  anchored by the partner's EDITION_MASTER works). A standalone ERC-1155 is deferred (no sale
  method fits it).
- A full copy per artist: no shared multi-artist contract, no clones, no `delegatecall`. Clones
  can be added later as a new template version, touching nothing permanent.
- **No immutables.** Every value a constructor takes is written to storage, so every deployment
  of a version has one runtime code hash. "A genuine template" is one `EXTCODEHASH` check,
  with no trusted factory and no factory at all.

### 2. Joining: initiated and confirmed by the token

- The artist calls `joinFederation` on its own token; the token calls the artist registry's
  current federation registry (`register`), which checks the token's code hash is an approved,
  unsuspended version, that it names the canonical artist registry and split ledger, and that
  its locked fee share and fee recipient equal the economics resolver's `PRODUCT_FEDERATED`
  values now; for a pair, that the partner is the other approved form and names it back, with
  the same artist and terms. It creates the artist's identity from the artist's own signature
  (`IArtistRegistry.registerFederated`) if needed, then lists the token
  (`listFederatedContract`; the artist registry reads the code hash itself).
- The token then requires that it was not listed before and is listed now, under its own artist,
  ACTIVE, and emits `FederationJoined` with its own facts in the same transaction. **This closes
  the residual ADR 0007 recorded:** a registry that lists a genuine token first, with wrong
  facts, leaves a listing the token can never confirm, so the token never mints through a
  network adapter under it (the artist leaves and redeploys), and a logs-only reader recognises
  a listing only when the token's own `FederationJoined` follows it with the same facts. The
  token's `FederationTermsLocked` constructor event carries the same facts again.

### 3. The registry stores no entry

An entry (form, partner, artist, version, code hash, fee share, status) is composed on read from
the permanent directory (artist and status), the token's locked storage (fee terms and partner,
read only for an approved code hash) and the registry's template table. A replacement registry
therefore inherits every listing with nothing to migrate and nothing to trust from its
predecessor. The registry's own state is the template table and the admitted adapters. A
contract that left has no entry (§8).
`IFederationRegistry` is reduced to what other contracts call (`register`, `entry`, `isActive`,
`canMint`); since every future registry must answer it, it is small on purpose.

### 4. Works, minting and the minimal record

- A federated work is a `PackageItem` with its media list, hashed exactly as a curated item
  (`WorksHashing.itemHash`), so tools build both alike. It is approved **on chain** by the
  artist (`approveItem`, which also sets its royalty rate: no floor, at most 100%), not by an
  off-chain signature: no signature scheme, domain or nonce in a permanent contract, and any
  wallet type works.
- `mint` accepts only an adapter the registry admits (`canMint`), only into that adapter's
  custody, only for an approved item sold in ETH. The first mint opens the work: each media
  file must be registered in the content store with its declared SHA-256; the seller vault of
  the item's payees and the 90/10 royalty vault are deployed through the split ledger now, so no
  sale pays an undeployed vault.
- The record is held by the template, which is its own `workRecords()`; finalize pins the
  artist-chosen default renderer by code hash. **The renderer's read path (after ADR 0007's
  review fix H-1).** The shared `Renderer` no longer reads a work through the replaceable view
  extension: it reads `coreOf` and, with `extsload`, the token word and the collection's name at
  the slots `StreamLayout` publishes for 6529 Stream. The federated template exposes exactly
  that native path rather than a separate one: its storage puts the one collection at slot 17
  (the ERC-721 name two slots into the entry, written at construction: one more slot at
  deployment) and the token words at slot 18 (the minting adapter in the seller's 160 bits, the
  work ID in the serial's 32), and it answers `extsload` as Stream does. Both are as immune to
  replaceable code as Stream's: a template version's code, and so its layout, never changes, and
  a test pins the slots to the compiler's layout. `work` and `collection` remain for
  integrators.
- **Rules a work's own data cannot break.** A locator URI is at most `Limits.MAX_URI_BYTES` of
  printable ASCII without `"` or `\` (WorkRecords' WS-40 rule, applied at `setLocator`), so the
  renderer's UTF-8 check can never refuse it and no locator breaks the work's metadata. The
  license ID follows the mint rule (`SpdxId`), checked at the first mint, so the renderer can
  always read and show it.
- **An item names no one but the artist.** No party consents on chain to a federated work, so
  the first mint refuses an item whose parties name any account but the artist's (its ID's
  account), or whose payees name any artist ID but the artist's (`InvalidMintRequest`); fixed
  payees are accounts the artist pays. A federated work therefore cannot touch another artist's
  payout (no artist-resolved payee routes through another identity), standing or directory
  entry, and a logs-only reader reading `WorkOpened` sees only the artist as a party.
  Collaborators are credited as fixed payees or in the record (the artist's own words). The
  spec says what a reader should show.
- **What a federated work lacks, compared with a canonical one:** curation and a package root;
  parties' consents; VRF seeds; collections and serials beyond the contract itself (one
  collection, the work ID as the serial); governed amendments (relicensing, errata repin) and
  the delivery satellite (one artist-set locator per file); added stores beside the content
  store; statement-log artist resolution; content uniqueness across the network; the museum and
  rescue; a permanent home (a template version's bug stays in its copies); TDH and consensus
  weight.
- **The records redesign of ADR 0007's review (two sync walks, added stores).** A federated work
  keeps its own minimal record; nothing in the template, the renderer's reads of it or the
  adapters assumes `WorkRecords`' shape: the renderer reads only `isOpen`, `record` (whose
  shape is unchanged), `mediaOf`, `preferredLocator`, `licenseOf` and `seedOf`, and inlines
  only from the content store (`syncOnChain` checks every file complete there).

### 5. Unsold works stay with the template (amends ADR 0005 decision 9)

An UNBID or FROZEN_OUT settlement moves the token into the template's own custody, with no
receiver call; a refused settlement's pending delivery can only be claimed by the template
(`primaryTerms(...).creator` is the template), through `reclaim`. A work therefore leaves the
template only through a sale. A restart needs the artist's fresh approval; because a sale
adapter keys a sale by token and ID, it burns the unsold token and mints the next token ID for
the same work. An edition master whose edition sale began never restarts.

### 6. Revenue

- **Primary.** The English auction takes the fee share from the registry entry and pays the
  resolver's federated recipient, both locked at start, never what the token reports (as built
  in ADR 0007). The federated edition auction does the same at open (its lens's `feeTerms`).
- **Royalties.** `royaltyInfo` names the split-ledger vault paying the seller 90% and the locked
  fee recipient (the governed fee vault) 10%, for every work minted while listed; the share and
  recipient are fixed at construction with no setter, and the registry checks them at joining.
  The network pulls its 10% from the permanent ledger.
- A listed token cannot change its fee terms: no setter, and its code hash is fixed.
- **Splits after ADR 0007's review.** The split ledger now refuses payees that can never be paid
  (an artist ID of 2^160 or more, the ledger itself). A template deploys every vault through the
  ledger at the first mint, so an item with such a payee is refused before anything is owed; the
  90/10 royalty pair (the seller vault and the governed fee vault) passes.
- **Identity after ADR 0007's review.** Artist powers read the artist registry's active
  authority, whose rules (a consolidated wallet acts only for a dormant artist; heartbeats are
  the authority's) the templates inherit unchanged; settlement reads no identity state.

### 7. The pair's editions

`FederatedEditions` mirrors 6529 Stream Editions where it applies: one adapter bound per edition
(the one whose sale opens it), sealed at its sale's count, created by anyone once the master
settled, priced mints logged, royalties to the master's vault at the master's current rate. The
sale is the uniform-price edition auction **deployed a second time from the same source**: the
contract and its lens become `UniformEditionAuctionBase` and `UniformEditionAuctionLensBase`
with a few virtual hooks (which edition contract a sale sells, whose 1/1 anchors it, the fee it
locks, the abandonment seal, the 1/1 clock); `UniformEditionAuction` and its lens implement them
with the existing immutables, `FederatedEditionAuction` and its lens with a per-sale record and
the registry. A single parameterised adapter was rejected: it would move every canonical edition
row and does not fit 6529 Stream Editions' auction's EIP-170 margin. A delisted pair's running
edition sale reads its 1/1 as cancelled and voids with full refunds; an abandoned sale's seal at
zero is best effort, so a faulty edition contract cannot hold bidders' ETH.

After ADR 0007's review fixes:
- **`createEdition` depends on nothing replaceable.** 6529 Stream Editions dropped its read of
  the mint policy (M-1). `FederatedEditions.createEdition` never had one: it reads only its
  partner `FederatedStream` (fixed code: `coreOf`'s item hash and `primarySaleSettled`), the
  split ledger (permanent) and its own storage, and is permissionless, so a settled master's
  edition can always be created.
- **Abandonment.** The adapter enforces its own time floor (L-3) and adds what 6529 Stream's
  rescue delay for the English auction's works adds to its 90-day floor (L-4; review E's N-2:
  the delay Stream locked when the English auction was removed, else the delay in force),
  capped by the governed `rescueCapDays` limit (90 to 730 days, 730 at launch), because a
  canonical master may wait on a rescue. The shared bases take the uncapped addition from a
  hook (`_rescueLengthening`) and apply the cap from the shared limits word: the canonical
  deployment and its lens read Stream (its `extsload` at `StreamLayout.minterSlot`, then
  `rescueDelay`) with all the gas; the federated ones add nothing and read no 6529 Stream slot,
  since a federated 1/1 has no rescue. A federated sale is therefore abandonable at its end plus
  its locked delay, whatever Stream's rescue delay or the cap, and the floor is still enforced by
  the adapter itself. The federated deployment is constructed with the same genesis limits
  (`DeployV1.editionAuctionLimits`, `rescueCapDays` 730 included), governed by its own
  `setLimits`.
- **Wallets.** The lens always calls the ledger's idempotent `createWallet` for the seller and
  royalty vaults (F16) through the deployment's factory (for a federated token, the split
  ledger its terms name, which the registry checked); the template deployed both at the first
  mint, so the call confirms them.
- **Settlement reads.** `settle` decodes the sale word and terms once (I-1) in the shared base,
  for both deployments.

### 8. Governance, delisting and exit

- Template approval and revocation, and adapter admission: SUCCESSOR_SETTER, 30 days. Template
  suspension: GUARDIAN, immediate (new works only). Resumption and delisting: PARAMETER_SETTER,
  48 hours, guardian-vetoable, the vote reference recorded in the artist registry's event.
- Suspension stops new joins and new works; running sales finish. Revocation and delisting stop
  new sales and end running sales unsold with refunds (the work stays with the template);
  `propagateRevocation` writes a revoked template's listings DELISTED in the directory, anyone
  may call it. Nothing touches tokens, ownership, records, vaults or credits.
- Exit (`leaveFederation`, the artist, one-way) writes LEFT through the token itself; running
  sales finish (`isActive` serves LEFT); works minted before keep the 90/10 vault; new works pay
  no network share; the artist then admits its own minters.
- **A contract that left starts no sale through a network adapter.** As first built, the
  registry reported a LEFT contract ACTIVE everywhere (the English auction had no bytes for a
  third status). That allowed a left contract whose artist admitted the English auction (or the
  federated edition auction) as its own minter to start a new sale there: `isActive` said
  served, the template's own minter list let the mint through, and the adapter locked the
  registry entry's 10% for a contract no longer in the federation. Closed in the registry, with
  no change to the English auction (514 bytes of margin, untouched): `entry` answers nothing for
  a LEFT contract, and both adapters require the entry's code hash to be the token's before
  they lock a fee, so a new sale reverts (`InvalidSaleTerms`) while a sale started before the
  exit still settles and pays the share it locked.
- **Roles at genesis, and the class delays.** The registry's selectors map to SUCCESSOR_SETTER,
  GUARDIAN and PARAMETER_SETTER as above; since ADR 0007's review every grant carries its
  role's class delay, so no holder can be seated below those delays. Genesis wires the
  federation's first configuration as zero-delay installer calls (§10); every later approval,
  revocation, adapter change, suspension, resumption or delisting waits its class.
- Disputes apply to federated auctions (the English auction's pause and cancel). ETH only. No
  VRF. No royalty floor. Every artist power is checked against the artist registry's active
  authority, so recovery works; the network holds no power over a deployed template.

### 9. Budgets, sizes and the artist's deployment cost

Measured at the merged tip (16 November 2026).

- **Source lines:** **15,972** non-comment lines under `src/` (the permanence tip has 14,382; the
  federation adds the templates, the registry, the federated edition auction and lens, three
  new interfaces and a reshaped `IFederationRegistry`, the shared edition-auction bases and
  their rescue hook, and the genesis wiring selectors). The budget is raised to **16,000** to
  admit federation (owner, 16 November 2026; see Amendments).
- **EIP-170 (runtime bytes, margin):** `FederatedStream` 22,608 (1,968), `FederatedEditions`
  16,194 (8,382), `FederationRegistry` 8,423 (16,153), `FederatedEditionAuction` 23,279
  (1,297), its lens 23,837 (739). Canonical contracts this changes: `UniformEditionAuction`
  23,884 to 23,912 (664), its lens 23,129 to 23,062 (1,514); `GovernanceConfigurator` 11,473
  to 11,554 runtime, 37,079 to 37,160 initcode (the three genesis selectors). The English
  auction is unchanged at 24,062 (514), as are Stream, Editions, WorkRecords, the artist
  registry and the renderer. Every contract keeps 512, with no exemption.
- **The artist pays the templates' deployment once.** Measured (Prague, whole transaction:
  21,000 + 32,000, calldata, the constructor and 200 per code byte): `FederatedStream`
  **5,214,846** (22,608 bytes, 11 slots); `FederatedEditions` **3,754,423** (16,194 bytes, 8 slots);
  a pair **8,969,269**. Glamsterdam estimate from ADR 0004's unit prices (code 1,542 per byte, a
  new slot about 111,000, an empty CREATE about 210,000), replacing the Prague components
  (code at 200 per byte, a slot at 22,100, and the 53,000 of the transaction and CREATE
  bases):
  - 721: 5,214,846 - 22,608 x 200 + 22,608 x 1,542 - 11 x 22,100 + 11 x 111,000 - 53,000 +
    210,000 = **36,689,682** (about 36.7M: the code term is 22,608 x 1,342 = 30,339,936, the slots 11 x 88,900 = 977,900);
  - 1155: 3,754,423 - 16,194 x 200 + 16,194 x 1,542 - 8 x 22,100 + 8 x 111,000 - 53,000 +
    210,000 = **26,354,971** (about 26.4M);
  - a pair: about **63.0M**. Calldata repricing under Glamsterdam is not modelled [U]. At 1 /
    5 / 10 gwei that is about 0.037 / 0.18 / 0.37 ETH for a 721 alone. Clones (study H §4)
    would cut this to about 1.5M per contract and remain a later template version, touching
    nothing permanent.
- **Gas rows** (Prague; federated rows are their own, with ceilings in
  `FederationGas.t.sol` and ADR 0004's table): join creating the identity 284,685 (7 slots); `approveItem` 59,334 (1); a first start deploying both vaults 666,394 (18 slots, 2 accounts); a steady start 403,304 (10); a first bid 189,476 (5); settle sold 176,220 (2); settle unbid 150,850 (2); restart 245,056 (4); federated edition `open` 363,784 (7); `createEdition` 86,758 (1); edition settle 149,965 (1). Glamsterdam, adding about 89,000 per new
  slot (and about 245,600 per vault created): steady start about 1.29M (403,304 + 10 x 89,000), first start about
  2.76M (666,394 + 18 x 89,000 + 2 x 245,600). A federated settlement executes about 95,000 gas, far inside the refusal gas less
  the auction's 2.43M (guarantee 1).
- **Canonical rows:** no 1/1 row moved (the English auction is unchanged; the tightest start row is 344,968, as on the permanence tip, 5,032 under 350,000, so the 5,000 start margin holds). The edition auction's three `open` rows rose by 261 each over the permanence tip measured on the same day (290,195 to 290,456; 335,932 to 336,193; 429,511 to 429,772; ceilings unchanged; the tip's table still lists the values before review E's limits word, 70 lower): the shared base's hooks, within the +303 the lane first measured. Claiming a winner rose by 8 (98,580 to 98,588). Its other rows moved by at most 16 gas either way (a bid near the close 78,018 to 78,002; settle, 40 steps, 150,391 to 150,375; the capped sweep settle 163,355 to 163,353; claiming a winner 98,539 to 98,547; a withdrawal during a 1/1 pause 87,980 to 87,964).

### 10. Genesis wiring

Genesis deploys the federation registry, the federated edition auction's lens and the federated
edition auction (`DeployV1.order`), and wires, as zero-delay installer calls before any selector
is mapped: the artist registry's one-shot `bindFederationRegistry`, the English auction's
`setFederationRegistry` (which pins the registry's code hash), `setAdapter` for the English
auction and the federated edition auction, and `approveTemplate` for `FederatedStream` and
`FederatedEditions`, version 1. The template code hashes are computed by the deploy script from
the build (`DeployV1.templateCodeHash`: `keccak256(type(T).runtimeCode)`, the code hash of every
copy because the templates have no immutables), never held as literals in the configuration.
`GovernanceConfig.isGenesisSelector` admits exactly these three new selectors besides the bind;
every later change waits its class. `VerifyV1.checkFederation` reads the binding, the English
auction's registry and pinned code hash, both admitted adapters, both approved templates
(version and form), the federated edition auction's lens and the federated product's economics
(10% to the fee vault). The registry's roles are SUCCESSOR_SETTER (approve, revoke, adapters;
30 days), GUARDIAN (suspend; immediate) and PARAMETER_SETTER (resume, delist and relist;
48 hours); the federated edition auction's are 6529 Stream Editions' auction's, without
`setTarget` (the registry decides what it sells).

### 11. The nine template guarantees

The English auction's refusal exit stays fair only if a federated template meets the nine
guarantees of [Stream and auctions](../spec/stream-and-auctions.md#what-a-federated-template-must-guarantee).
The v1 templates meet them by construction ([Federation](../spec/federation.md#the-nine-template-guarantees-as-met)
gives each with its test): settlement makes no external call and reads only its own storage
(gas about 95,000; no third-party guards; no buyer or recipient code; no identity state);
`primarySale` answers NONE until the minting adapter settles; the seller vault, fee flag and
creator are written at mint and the fee terms at construction; `ownerOf` and the transfer are
OpenZeppelin's, unmodified; only the minting adapter settles, once, with `holder` zero for SOLD
and the template for an unsold work; and the code is fixed (no proxy, no delegatecall, no
immutables), so the approved code hash is the code that runs.

## Decisions the study left open, as built

Each is the delivery owner's choice where study H left the question open; **the owner may
revisit any of them**.

1. Royalty rate per work: set by the artist's on-chain approval, no floor, at most 100,000.
   (Owner may revisit.)
2. Item consent: on-chain approval by the artist alone, not signatures; since no other party
   consents on chain, an item names no party but the artist and no artist-resolved payee but
   the artist (FED-60). (Owner may revisit: a signature scheme for collaborators would let them
   be named.)
3. A restart takes a new token ID (forced by the adapters' sale keys), needs a fresh approval,
   and is refused for an edition master whose edition sale began. (Owner may revisit.)
4. A federated work's renderer default is the artist's to set; finalize pins it. (Owner may
   revisit.)
5. Locators: one per media file, set and changed by the artist; the URI follows WS-40's
   printable-ASCII rule and length bound, no count bound. (Owner may revisit.)
6. `IFederationRegistry.Status` keeps three values; a LEFT contract has no entry (no new sale
   through a network adapter) while `isActive` still serves its running sales; the directory
   records the exit. (Owner may revisit: a fourth status would need English auction bytes.)
7. A token whose listing was made by another registry first can never be confirmed; it never
   sells under that listing. (Owner may revisit.)
8. Template suspension is lifted by PARAMETER_SETTER (48 hours); revocation is terminal.
   (Owner may revisit.)
9. Artist-level delisting is expressed as per-token status writes in caller-sized batches.
   (Owner may revisit.)
10. The federated edition auction reads the registry from the artist registry's pointer (no
    own pointer, saving bytes the adapter does not have). (Owner may revisit.)
11. The renderer reads a federated work through the same native path as a 6529 Stream work
    (`coreOf`, `extsload` at `StreamLayout`'s slots), so the template stores its collection
    name a second time at deployment (one slot) rather than showing no collection. (Owner may
    revisit: answering collection 0 would save the slot and drop the collection and serial
    traits.)
12. The federation's first configuration is wired at genesis (three more genesis selectors)
    rather than waiting 30 days after it. (Owner may revisit.)
13. The edition auction's `open` rows keep the +303 the shared base's hooks cost rather than a
    duplicated base (about +1,800 lines). (Owner may revisit.)

## Not fixable (documented)

Residual leakage (LIM-FED-1): marketplaces that ignore ERC-2981; a 0% royalty rate; a self-bid
at the opening bid followed by an off-chain sale; side payments; works sold after an exit
through the artist's own minters; and, as governance risk rather than artist leakage, a
replacement registry or adapter taking a different fee (30-day swap with guardian veto). None
lets a listed contract sell through a network adapter without the locked share. A bug in an
approved template persists in its deployed copies (deployed code never changes); suspension and
revocation stop its sales (LIM-FED-2). The deployment cost falls on the artist (LIM-FED-3).

## Amendments

- Budget: raised to 16,000 to admit federation, 16 November 2026 (owner: the budget can
  increase).
