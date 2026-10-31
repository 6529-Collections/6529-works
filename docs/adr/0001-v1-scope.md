# ADR 0001: 6529 Works v1 scope

Status: Accepted by the owner, 11 October 2026. §13 is amended by
[ADR 0002](0002-access-manager-hardening.md); build-time decisions across §3–§13
are recorded in [ADR 0003](0003-build-time-decisions.md); the gas budgets under
Glamsterdam are in [ADR 0004](0004-gas-budgets-under-glamsterdam.md). The edition sale, the
6529 Stream Editions name and where an unbid work goes (§1–§3, §5, §6, §12, §16, §17 and the
non-goals) are amended by [ADR 0005](0005-stream-editions-auction.md).

Origin: this decision was accepted in the 6529Stream repository as ADR 0055
(6529Stream PR #745),
and it is the founding decision of this repository. Unless qualified otherwise,
references below to ADR numbers, pull requests and issues refer to the
6529Stream repository (private since 11 October 2026), which
holds the RC1 reference implementation and its history. "This ADR" means this
document.

## Problem

Stream has no single statement of what the product is. Without that anchor,
the v1 specification and the autonomous implementation grew in different
directions from the owner's intent.

- **`main` (RC1, `569bf87f1`)** is a working, reduced current stack on
  Sepolia: 171 Solidity files. A read-only security review on 10 October 2026
  found no Critical or High issues. It confirmed two Medium issues:
  - `royaltyInfo` silently returns zero unless about 3M gas remains;
  - English-auction settlement locks permanently if the winner cannot receive
    the NFT.
- **RC1 is shaped like NextGen, a 1/1/x platform:**
  - entropy is mandatory for every token;
  - name, description, image and script are set per collection;
  - each token is named "Collection #serial" with no per-token attributes.
- **PR #744 (full v1) is not a viable path to an auditable protocol:**
  - 3,201 Solidity files and about 1,900 separately linked libraries;
  - 0 of 200 CI runs green, because the build does not finish within CI
    limits;
  - generated client fixtures make up 78% of its +8.2M lines;
  - two verified High findings;
  - an artist domain of 1,004 files, mostly importing history from a
    predecessor registry that does not exist.
- **Root causes:**
  - a "maximum permanence, no deferred tier" posture
    ([PV1-SCOPE] in `docs/launch-v1-target-architecture.md`) and a 37-role
    genesis inventory ([LCM-GENESIS]);
  - an append-only "add a parallel family" agent rule;
  - splitting contracts to fit EIP-170;
  - progress measured by local capacity proofs rather than whole-system
    builds.

## Decision

### 1. Product

6529 Stream is the network-curated ERC-721 contract for 1/1 artworks, grouped
into collections. In this ADR, "Stream" abbreviates 6529 Stream. Every work in Stream has passed network curation.

- **Not long-form generative (1/1/x).** That is NextGen.
- **Not editions.** Editions live in 6529 Editions (§6).

### 2. Network tiers

| Tier | Admission | Contract | Primary split (default) |
| --- | --- | --- | --- |
| The Memes | Main Stage winners, ranked by TDH-weighted votes (about 150 a year) | Existing Memes ERC-1155 | 50/50 (unchanged; outside this ADR) |
| 6529 Stream | Approved by the published TDH rule, either from Main Stage or from dedicated Stream waves | One shared Stream ERC-721 | 75% artist / 25% network |
| 6529 Editions | An approved edition package anchored by a Stream edition master | One shared 6529 Editions ERC-1155 | 75 / 25 |
| 6529 Stream Federated | Artist-deployed contracts from the network's templates, registered permissionlessly (no curation) | Artist's own ERC-721, ERC-1155 or linked pair | 90% artist / 10% network (v1.1, only if needed) |

### 3. Curation and approved packages

**Submission and voting**
- Artists submit through 6529 waves. Votes are weighted by TDH.
- A Main Stage submission that satisfies the published approval rule becomes
  Stream-eligible even if it does not win a Meme slot.
- Approval rules (for example 10M TDH held for 24 hours), bucket approvals and
  pacing are wave policy, not contract code. A single artist may have many
  works approved at once.

**The package**
- The artist submits a package, and voters vote on it. The package hash is a
  Merkle root over its items.
- Each item commits to:
  - the content manifest hash;
  - the metadata hash;
  - the artist and collaborators;
  - the split;
  - the collection;
  - the kind: `ORIGINAL` or `EDITION_MASTER`;
  - for an edition master, the edition size, format and price.
- Only items that exactly match an approved package can be minted, and each
  item at most once.
- Every listed party (the artist and each collaborator) signs the package root,
  so nobody can be named, or have money routed to them, without consent.
- Package items are hashed as canonical JSON (RFC 8785, integers as decimal
  strings, duplicate keys rejected), so off-chain tools and contracts agree on
  the same bytes.

**Verification**
- Stream asks an `ICurationVerifier` whether a package is approved.
- In v1, the verifier checks an EIP-712 attestation from the curation-signer
  role.
  - The vote snapshot, the TDH snapshot and the rule parameters are published.
  - The evidence hash is written to the statement log (§12).
- A verifier backed by the 6529 chain replaces it later through a timelocked
  action. Package IDs are content-addressed and independent of the chain.
- **Trust boundary:** until then, the contract trusts the curation signer, not
  the vote itself.

**Exclusivity**
- A work cannot be both a Meme and a Stream or Editions work. The wave layer
  enforces this.
- **Content-hash uniqueness is checked within each product.**
  - 6529 Stream rejects a content hash already minted on Stream.
  - 6529 Editions rejects a content hash already used by another edition.
  - The one permitted reuse across products is the linked pair: an edition
    must carry exactly its Stream master's hash (§6), and that mint is valid.

**Artist's choice**
- After approval, the artist signs a "move to Stream" message. That makes the
  work startable (§5).
- Approvals do not expire.
- An unused "move to Stream" signature can be revoked before use, through a
  nonce bitmap or revoke-by-digest.

### 4. Stream token model

- **One shared ERC-721 holds every Stream work.** Attention and money
  concentrate in one contract. The Memes, a top-ranked collection, is the
  precedent.
- **No per-artist or per-collection contracts in v1,** and no factory.
- **Token IDs are one chronological global sequence,** assigned when a work's
  auction starts.
- **Collections are groupings inside the contract:** a collection ID plus a
  per-collection serial.
  - A collection may contain works by several artists.
  - Collection and artist are exposed as metadata traits.
  - 6529.io renders collection pages.
  - 6529 holds the marketplace `owner()`.
- **No numbered editions in Stream.**
- **Token IDs are never reused.** A burned token, for example after an upheld
  dispute, leaves a gap in the sequence.

### 5. Sales and auctions

| Rule | Value |
| --- | --- |
| Primary sale type | Auction only in v1. New sale types are added later as separate adapters (see "Sale extensibility" below). |
| Starting bid | 0, a governed parameter that can be raised without code changes |
| Minimum increment | `max(5%, absolute floor)`, governed; the floor is set per currency (0.001 ETH for ETH) |
| Duration | 24 hours with anti-snipe extensions, governed policy |
| Currency | A governed configuration: ETH or any approved ERC-20 (for example USDC, or a future 6529 token). Stream launches with ETH (see "Payment currency" below). |

**Payment currency is configuration, not code.**
- Every shared sale adapter, the auction included, settles in ETH or in any
  ERC-20 on the governed asset allowlist.
- **The default currency for each product** (6529 Stream auctions, 6529 Editions
  sales) is a governed setting. A package's sale terms may name a currency from
  the allowlist.
- **Each sale locks its currency when it starts.** A configuration change
  affects only sales that start afterwards.
- **Switching Stream to USDC, or adding a 6529 token,** is a timelocked
  governance action: admit the asset, then change the default. No contract
  changes.
- **Asset admission:** only standard ERC-20s, meaning tokens that return a
  value on transfer, take no fee on transfer and do not rebase. Every transfer
  is checked by exact balance delta. Bidders can approve and bid in one step
  with permits (EIP-2612 or Permit2).
- **Robustness:** refunds are pull-based, and wallet payments fall back to
  escrow. A token that blocks a specific address (as USDC can) therefore cannot
  block an auction.
- **Launch defaults:** 6529 Stream auctions use ETH. 6529 Editions use ETH plus
  any admitted ERC-20s.

**Starting an auction is permissionless.** Anyone may submit the start
transaction and pay its gas: a bidder, the artist or the network. The network
is not obliged to pay. The transaction:
- verifies the approval and the artist's move signature;
- mints the token into auction custody;
- starts the clock.

Starting together with a first bid is allowed.

**If there are no bids, the NFT goes to the artist.**
(Amended by [ADR 0005](0005-stream-editions-auction.md): to the 6529 Network Museum for 6529 Stream, and to
the artist for a federated work.)

**Sale extensibility.** Package sale terms carry a sale-kind identifier and
its parameters.
- **Shared sale adapters.** Sale adapters are shared modules written against a
  minimal mint interface, not against Stream specifically. v1 ships:
  - the English auction;
  - fixed price, with allowlist phases and ERC-20 permits;
  - a Dutch (descending-price) sale, built on the existing pricing library.
- **Who may use which adapter.**
  - 6529 Stream itself is auction-only.
  - 6529 Editions may use fixed price or Dutch.
  - 6529 Stream Federated contracts may use any shared adapter once they
    launch, under the network fee.
  (Amended by [ADR 0005](0005-stream-editions-auction.md): v1 ships the English auction and the uniform-price
  edition auction; fixed price and Dutch are removed, 6529 Stream Editions sell only by the
  edition auction, in ETH, and further methods are adapters governance admits.)
- **Adding a sale type later,** such as private sales, offers or burn-to-mint:
  - it is a separate adapter contract;
  - it receives the minter role through a timelocked AccessManager action;
  - Core and the package format do not change.

**Settlement must not depend on the winner accepting the NFT.** If delivery
fails, the winner gets a pending claim instead (fixes the RC1 Medium finding).

### 6. 6529 Editions

(Amended by [ADR 0005](0005-stream-editions-auction.md): renamed 6529 Stream Editions; an optional maximum count
replaces the artist's size, format and price, and the uniform-price edition auction, which
runs alongside the master's 1/1, replaces the fixed-price and Dutch sales, allowlist phases and
ERC-20 payments.)

- **One shared ERC-1155, "6529 Editions", in v1 scope.**
- **Every edition is anchored by an edition master.** The master is a Stream
  1/1 of kind `EDITION_MASTER`, auctioned like any Stream work.
- **The two are linked in both directions.**
  - The Stream work records `(editionContract, editionId)`.
  - The edition token records `(stream, workId, contentHash)`.
  - The link is created only from the approved package, and is permanent once
    both sides are finalized.
  - The edition renders the same `ContentStore` bytes and hash as its master.
- **The artist chooses edition size, format and price** within the package.
  Edition sales use the shared fixed-price adapter (with optional allowlist
  phases and ERC-20 permits) or the shared Dutch adapter (§5).
- **Phased allowlist sales.** An edition sale may run allowlist phases, such as
  TDH-based phases built by 6529's distribution tooling, before a public phase.
  - The allowlist is a Merkle root per phase, with a per-wallet cap and an
    optional per-wallet price. It reuses PR #744's domain-separated,
    double-hashed leaf design.
  - **The leaf is checked against the wallet that actually receives the token,**
    or against the payer for payer-keyed phases. This fixes #744's High
    finding, where the leaf was checked against one address but the token was
    minted to another.
- **ERC-20 payments:** approved standard ERC-20s, per the payment-currency
  configuration in §5, through permits (EIP-2612 and Permit2) and signed
  payment intents. This reuses the existing built code.
- **No small numbered editions.**
- **License:** an edition carries its master's license (§8).

### 7. Economics

**Defaults today**
- Stream primary: 75% artist, 25% network. Editions: the same.
- Secondary royalties: 6.529% (ERC-2981), with the same split.
- Collaborators share the artist's portion as the package specifies.
- Royalty and split rates use a 100,000 denominator, so 6.529% is exact (6,529).
  A 10,000 basis-point denominator cannot express it.
- Each work's royalty terms are locked at mint and, where feasible, read
  directly by Core, so `royaltyInfo` needs no fragile external call.

**Flexibility**
- Governance may change the defaults for new works: rate, recipients, and
  multi-party splits with any basis points.
- Existing works keep the terms locked at mint. Changing them requires the
  artist's agreement plus a governed action.

**Kept from RC1 and #744**
- the split factory and immutable pull-payment split wallets, with any number
  of recipients;
- royalty and revenue resolvers with scoped assignments;
- the settlement-recorder pattern: exact balance deltas, single-use
  settlement keys, rejection of fee-on-transfer tokens;
- the escrow fallback, with a permissionless flush;
- optional batch claims and signed release authorization.

**Fixes carried forward**
- `royaltyInfo` uses its own small completion buffer and reverts when gas is
  short, instead of returning zero.
- Raise-only gas parameters get absolute ceilings.
- Deprecated or inactive assets stay withdrawable.
- Escrow terminal recovery requires the consent of the affected accounts.

The network pays Arweave and IPFS storage costs from its share.

### 8. Works, content and storage

**Work record**
- Each token has its own content record: title, description, artists, year,
  medium, dimensions and attributes.
- Its media list gives each file's sha256, size, MIME type and locators.
- The artist can edit the record until finalizing it. After that, the content
  hashes are immutable.

**License (owner direction, 11 October 2026)**
- **Every work carries a license field:** an SPDX-style identifier (for example
  `CC0-1.0`) plus the hash and locator of the full license text, stored in the
  content store so the text itself is permanent.
- **Exposure:** the license is part of the package that voters approve and the
  artist signs. It is exposed in token metadata (`license`, `license_url`) and
  through the read API.
- **Defaults:** 6529 Stream and 6529 Editions default to **CC0**.
- **Changing the default:** the default is a governed setting, so the network
  can change it later. The change applies to new works only, as with royalties
  (§7).
- **Existing works:** a work's license changes only with the artist's agreement
  plus a governed action, and only toward more permissive terms. A CC0
  dedication is irrevocable, so a work released under CC0 stays CC0.
- **Editions** carry their master's license.
- **6529 Stream Federated contracts** may use any license, including all
  rights reserved or custom terms, set by the artist per work (§16).
- **Not legal advice:** the license wording, and artists' informed consent to
  CC0, are reviewed by counsel before launch.

**Off-chain storage by default at mint**
- **Arweave:** a base-layer transaction for primary media.
- **IPFS:** a fixed, deterministic CID profile (CIDv1, raw leaves, fixed
  chunker, sha2-256), pinned by at least two independent providers plus a
  6529 node.
- Locators are append-only. Only artist or platform roles can register them.
  (Amended by [ADR 0003](0003-build-time-decisions.md): each is a bare content
  address, and after finalize only the platform registers them.)

**Preferred location**
- `tokenURI` serves the locator chosen by the first match in this order: a
  global setting, then a collection override, then a file override, then the
  next registered locator as fallback.
- A storage-operator role (AccessManager, zero delay) switches only among
  registered locators that share the same hash.
  - Every switch emits ERC-4906 events.
  - The role cannot add or remove locators, and cannot change hashes.
- An off-chain health monitor verifies copies, re-pins or re-uploads from a
  surviving copy, and posts fixity statements.

**On-chain upgrade**
- Anyone may upload content-addressed SSTORE2 chunks that match the committed
  manifest. The collector is the designated payer in the product.
- The work then becomes on-chain complete. On-chain bytes are permanent.
- Cost is about 0.23 ETH per MB per gwei, and about 72 KB fits in each
  transaction. (Pre-Glamsterdam figures: see
  [ADR 0004](0004-gas-budgets-under-glamsterdam.md) for current ones.)
- Libraries such as p5.js and three.js live in a shared dependency registry.
  Text is gzipped.

**`tokenURI` size**
- `tokenURI` stays small.
- Media of 256 KB or less is inlined, but only once the work is on-chain
  complete.
- From 256 KB to 1 MB, `tokenURI` gives a mirror URL plus a small on-chain
  preview, and a separate view function returns the full inline version.
- Above 1 MB, the media is available through the chunked reader only.
- The final threshold is set by a Sepolia test matrix.
- The renderer's bounded read must allow at least the inline threshold. RC1's
  64 KB return cap is too small for 256 KB media.

### 9. Seeded and generative 1/1s

Seeded works are allowed as 1/1s, in two ways:
- **(a) Artist-chosen seed.** The seed is committed in the package. This is the
  default.
- **(b) VRF reveal.** An optional module enabled per work. The work is revealed
  before bidding: the start transaction requests randomness, and the 24-hour
  clock starts when the seed is delivered. A request that never delivered
  randomness may be re-requested. Reveals after settlement ("mystery" works) are
  not in v1.

Entropy is not part of Core's mint path. Copies never get their own seeds
(1/1/x is NextGen).

### 10. Permanence

- **Finalizing a work** by the artist makes its content record immutable and
  pins its renderer.
- **Changes scoped to a work or collection** require the artist's co-signature
  and a governed action.
- **The errata path** (a new renderer pin) requires the artist, governance, a
  30-day delay and a public event.
- **Carve-out:** delivery routing (§8, preferred location among hash-equal
  copies) stays operable after finalize. "Final" fixes the content and output
  format, not the URL.

### 11. Artist identity and recovery

**Registry**
- A slim artist registry holds:
  - `artistId`;
  - the authority address;
  - the profile document hash;
  - the 6529 profile ID.
- It is created from the artist's first package signature.
- The artist's share of payments resolves through the registry, so recovery
  and estates redirect future withdrawals.

**Recovery uses 6529 consolidation** (delegation contract
`0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`, use case 999).
- A consolidated wallet counts only if its consolidation is at least 30 days
  old and has not expired.
- Every change to identity or payout waits 7 days.
- During that wait, any of these can cancel it:
  - any established consolidated wallet;
  - the old key;
  - the network, acting only as a veto. It can block a change but never
    redirect anything.
- Contested changes go to a network override process with a 180-day public
  notice.
- Estates, and lost keys with no consolidation, use the same 180-day public
  override. It can be staged only after at least one year with no signed
  activity from the artist's keys or established consolidated wallets.
- The delegation contract's primary-address use case (997) is not used as a
  live payout address.
- The identity source can be swapped when the 6529 chain arrives.

**Hardening (decided 11 October 2026)**
- **Canceller set captured at staging.** The consolidated wallets that may cancel
  a change are the ones established when the change is staged. A thief who
  later revokes consolidations cannot strip the artist's wallets of standing.
- **The old key cannot cancel the 180-day override** for contested changes,
  estates or lost keys. Otherwise a stolen key could block recovery forever.
  Only established consolidated wallets captured at staging can cancel it.
- **Delays:** artist-initiated identity and payout changes wait 7 days. The
  14-day funds class applies to network-level recipients, not artist payouts.
- **Signed payloads:** every artist-signed identity payload includes the 6529
  profile ID and the profile document hash, and every signature carries a
  deadline.
- **Payout redirection reaches accrued balances only through an artist-resolved
  recipient** in the split wallet. Recovery and estates then cover balances
  already accrued, with the trade-off that a hijack surviving the 7-day window
  also reaches them.
- **The verifier base is one shared signature library:** low-s ECDSA,
  ERC-2098, EIP-7702 delegated accounts, and ERC-1271 with a gas check and an
  exact magic value. The consolidation adapter walks the delegation contract's
  registration and expiry dates directly, because the vendored
  `checkConsolidationStatus` ignores consolidation age and expiry.

### 12. Disputes

**Final decisions are made by TDH vote.**
- Disputes are filed with evidence in a 6529 disputes wave.

**During an auction**
- The guardian Safe may only pause a live auction, for at most 7 days.
- Bidders may withdraw their bids while the auction is paused.
- If the dispute is upheld:
  - the auction is cancelled;
  - all bids are refunded;
  - the token is burned;
  - the outcome is recorded.
- If the dispute is rejected, or no outcome arrives within 7 days, the auction
  resumes with its remaining time, and anti-sniping still applies.

(Amended by [ADR 0005](0005-stream-editions-auction.md): while a 1/1 is paused, its edition
auction keeps taking bids and its bidders may withdraw; an upheld dispute's cancel voids the
edition auction with full refunds.)

**After a sale**
- A dispute results only in a public statement in the statement log, shown in
  the work's metadata.
- Nothing is confiscated.
- Royalties do not change without the artist's agreement.

**Statement log**
- Stream keeps one append-only, signed statement log.
- Each entry records:
  - the work;
  - the statement kind;
  - the schema hash;
  - a content hash plus URI, or a `ContentStore` file;
  - the signer's role: artist, owner, curator or platform.
- The log is used for disputes, fixity checks, artist statements and museum
  accession records.

### 13. Governance

**OpenZeppelin 5 AccessManager governs Stream, 6529 Editions and all
satellites.**
- The compiler moves to Solidity 0.8.24 or later (v1 pins 0.8.37). This supersedes the 0.8.19
  pin in `AGENTS.md` and `docs/tooling.md`, which are updated in the
  implementation PR.

**Role holders (proposed). The owner sets the Safe signer thresholds.**
- an admin Safe holds the AccessManager admin role;
- a guardian Safe can pause, cancel scheduled operations, pause auctions for
  disputes and veto identity changes;
- the curation signer key signs approvals (v1 verifier);
- a storage-operator role switches preferred locations;
- keeper roles are added as needed.

**Delay classes (proposed defaults)**

| Class | Delay |
| --- | --- |
| Tightening actions and pauses | Immediate |
| Standard actions | 48 hours |
| Funds and recipients | 14 days |
| Verifier and successor-level swaps | 30 days |

**What is not carried to v1**
- RC1's 13 bespoke governance contracts are dropped:
  - Executor, Bootstrap, Evidence, Policy, ActionPolicy, Scheduling;
  - Manifest, SystemManifest, StateExport;
  - ModuleRegistry, RoleRegistry and the actor contracts.
- The manifest becomes a signed JSON document whose hash is emitted in an
  event.
- State export moves to an indexer.

**AccessManager hardening requirements**
1. **Meta-governance is never faster than the slowest class.**
   - The admin role's execution delay is at least 30 days.
   - Every target's admin delay is at least 30 days.
   - Each class role's grant delay is at least as long as its class delay.

   Otherwise the admin could remap a 14-day function to the 48-hour role.
2. **The guardian Safe can cancel admin operations on the AccessManager
   itself.** By default OZ 5 lets only the scheduler, an admin or the target
   function's guardian cancel, so a compromised admin's `revokeRole` or
   `setTargetFunctionRole` could not be stopped.
   - Fix: map the manager's own admin selectors to a meta role guarded by the
     guardian Safe, or place a TimelockController in front of the admin role
     with the guardian as canceller.
   - This must be proven by a Foundry test before deployment.
   - Guardian entrenchment is also prevented: a guardian cannot cancel its own
     replacement.
3. **Guardian rules:**
   - at least two veto guardians;
   - a guardian is never a proposer;
   - pause and unpause have separate holders;
   - the guardian set cannot change while a terminal action is pending.
4. **One selector, one delay class.** Direction rules, such as raise-only or
   pause/unpause, are enforced in the target contract, because AccessManager
   only sees selectors.
5. **Compare-and-set on sensitive setters.** Setters for funds, recipients, the
   verifier and the renderer take an expected current value, so stale
   operations revert. A rotated admin's pending operations are cancelled.
6. **Dependencies are pinned at install:** code hash, ERC-165 support, and
   rejection of EIP-7702 delegated accounts. Freezes are one-way and in the
   30-day class.
7. **Governed functions are non-payable.** `AccessManager.execute` forwards
   `msg.value`.
8. **Evidence trail:**
   - every setter emits its old and new values;
   - each configuration epoch emits a manifest hash;
   - CI verifies deployed roles and delays against the committed configuration
     JSON.
9. **Gas parameters:** raise-only, at most 2x per step, with an absolute
   ceiling.

### 14. Chain

Stream deploys on Ethereum mainnet only. The future 6529 chain serves votes
and identity, and verifiers switch to it when it is available. Stream ships
before that chain.

### 15. Museum

- **Museum work moves to `6529-Collections/6529Stream-museum`.**
- **Stream v1 provides the source data** through:
  - the statement log (§12), including package hashes recorded at accession;
  - events and read functions sufficient to rebuild a museum package from
    chain data alone. These are requirements R1–R4 in that repository's
    `docs/END_STATE.md`.
- **No museum semantics in Core.**

### 16. 6529 Stream Federated

Federation lets an artist run their own contract, built from the network's
audited templates, as a registered member of the 6529 network.

**Purpose: open, automated discovery (owner direction, 11 October 2026).** The
registry is a public, on-chain directory of every federated contract and work.
- Anyone can join by deploying and registering.
- Anyone can read the directory.
- Anyone can curate on top of it as they like: 6529.io, community waves,
  galleries, lists, third-party apps.
- The protocol does not curate federated work. It only provides the trustworthy
  directory, the shared infrastructure and the fee-settling sale adapters. It ships in v1.1
only if needed. v1 only has to keep the interfaces that make it possible: the
shared sale adapters, the template-ready token code, and a registry interface.

**Forms.** One of these, chosen at deployment:
- a federated **ERC-721** for the artist's own 1/1s;
- a federated **ERC-1155** for the artist's own editions;
- a **linked pair**: a 721 and a 1155 linked in both directions, with the same
  master/edition link model as 6529 Stream and 6529 Editions (§6).

**Components**
- **Templates.** Each template is the 6529 Stream or 6529 Editions token code
  with curation switched off. Each template version is reviewed and audited,
  and identified by its code hash. New template versions are published by
  governance. Deployed contracts never change.
- **Factory.** Deploys a template as a full, non-proxy contract. It deploys
  both halves of a linked pair and links them in the same transaction. The
  artist pays the gas: about 4–5M gas per contract.
- **Federation registry.** The on-chain list of contracts that belong to the
  network. For each contract it records:
  - the address;
  - the form (721, 1155 or pair, with the pair partner);
  - the artist ID;
  - the template version and code hash;
  - the fee terms;
  - the status: `ACTIVE` or `DELISTED`.

  Only the factory can add entries, so only genuine template deployments are
  registered. Its readers are:
  - the shared sale adapters, which accept sales only for `ACTIVE` contracts
    and read the fee from here;
  - 6529.io, indexers, the museum tooling, and TDH if that is enabled later.

**Lifecycle and rules (decided 11 October 2026)**
- **Registration is permissionless.** Anyone with a 6529 artist identity, which
  the deployment signature creates if needed, can deploy and register. Nobody
  approves it.
- **No curation.** The artist decides what to mint.
- **Minting happens only through the network's shared sale adapters:**
  auction, fixed price with allowlist phases and ERC-20 permits, and Dutch.
  - The template's mint function accepts calls only from the adapters that
    governance has admitted.
  - Gifting is a zero-price adapter sale.
  (Amended by [ADR 0005](0005-stream-editions-auction.md): federated contracts start with the English auction and
  the uniform-price edition auction, further methods are adapters governance admits, and v1
  has no gifting adapter. An unbid federated 1/1 stays with its artist.)
- **Fees.** Primary sales split 90% artist, 10% network. The adapter settles the
  fee on each sale. The fee terms are fixed in the registry entry at
  deployment. They change for new deployments only, and existing contracts
  change only with the artist's agreement (the same rule as §7).
- **Currency** is chosen per sale from the governed asset allowlist (§5).
- **Delisting** for fraud, impersonation or illegal content is decided by TDH
  vote, using the dispute process (§12).
  - A delisted contract cannot sell through the network's adapters and is
    hidden from 6529.io.
  - Tokens, content and ownership are never touched.
  - Relisting also requires a vote.

**Who controls a federated contract**
- **The artist,** through their artist identity, which includes consolidation
  recovery (§11), controls:
  - contract metadata and the marketplace `owner()`;
  - sale configuration;
  - finalize;
  - royalty terms for new works;
  - the license for each work, which can be any license (§8).
- **The network** has no power over tokens or content. It can only:
  - change the registry status, by vote;
  - change which adapters are admitted, for new sales.
- **Shared infrastructure** is the network's: content store, renderer,
  statement log and artist registry. Finalized works pin their renderer
  (§10), so network changes never alter a finalized federated work.

**Linking rules (decided 11 October 2026)**
- **Two separate worlds.**
  - The **curated** world: 6529 Stream masters link only to official 6529
    Editions.
  - The **federated** world: an artist's 721 links only to the artist's own
    1155, inside a linked pair.
- **No work-level links between the two worlds.** A curated Stream 1/1 never
  has its edition on a federated contract, and a federated edition never
  claims a Stream master. This keeps curated editions official, keeps network
  economics at 75/25, and avoids "curated by association".
- **Discovery across the worlds goes through the artist,** not the work. The
  artist registry lists an artist's federated contracts, so 6529.io can show
  "this Stream artist also has these contracts".
- **Federated works are not re-minted on 6529 Stream.** Federation is not a
  path into curation.

**Royalties (decided 11 October 2026).** The artist sets the royalty rate for
each new work, as on Stream. The network takes 10% of royalties, mirroring the
primary split.
Royalties remain advisory (ERC-2981) and cannot be enforced on-chain.

**Issues and accepted risks**
- **Fee leakage through gifts.** An artist can gift a token to their own second
  wallet and sell it elsewhere. Self-gifts cannot be reliably detected (fresh
  wallets are free), so this leakage is accepted. Gifts are public and visible
  in the registry's sale history.
- **Impersonation.** Anyone can deploy a contract named after a famous artist.
  The registry binds each contract to an artist ID, 6529.io shows verified
  6529 profiles, and impersonators are delisted by vote. Until a vote, a
  fraudulent contract can trade on outside marketplaces.
- **Fragmented liquidity.** Each federated contract is its own marketplace
  collection, by design. This is the trade the artist chooses.
- **Network dependency.** Federated works depend on network-run shared
  infrastructure. Finalize pins, content addressing and Arweave/IPFS
  redundancy limit that dependency to display and sales, never content.
- **Template obsolescence.** Old template versions stay valid forever. Only new
  deployments use new versions.
- **Scale.** Permissionless registration means many low-activity contracts.
  6529.io curates what it features; the registry stays a complete, neutral
  list.

**Further decisions (11 October 2026)**
- **Federated contracts do not count toward TDH.**
- **A TDH vote may delist an artist identity,** which delists every contract
  registered to that identity at once. Tokens are never touched, and
  relisting also requires a vote.

### 17. Reuse plan (from RC1 and PR #744)

This plan is the result of a five-domain "keep the excellent work" review,
11 October 2026. Items are rewritten within the budgets, not merged wholesale.

| Domain | Keep as-is | Port (rewrite smaller) | Reference / parked |
| --- | --- | --- | --- |
| Signatures and identity | #744 artist signature verifier (one shared library); EIP-7702 delegated-account detector | Pending-change state machine; linear payout chain with deadline; two-sided authority change; package and collaborator acceptance keyed by package hash; preventive revocation | Window discipline; per-entity hash chain and write-once archive |
| Auctions and money | `StreamClaimRouter`; `StreamReleaseAuthorization` (on OZ `SignatureChecker`) | RC1 `StreamEnglishAuctionHouse` as the auction base, plus #744's auction clock, capped NFT delivery with pending claim, ETH escrow fallback and pause clock | Package-item Merkle proof; "accounts losing share must consent"; ticket-gate shape for the curation verifier. Ported for 6529 Editions: Merkle allowlist phases (with the recipient fix) and ERC-20 payments with Permit/Permit2 and payment intents. Ported as a shared v1 adapter: Dutch pricing (for Editions and future federated contracts). Parked: delegate.xyz gate |
| Core | Gas-reserve check (63/64 rule); overflow-free royalty math | Code-hash and ERC-165 pinned links at install; one-way freeze; per-token pins; burn-surviving token identity and supply counters; restricted ERC-4906/7572 emitters | Old/new-state binding (as compare-and-set); genesis-plan verification as a deploy script; guardian rules; publish/challenge/supersede; golden typehash tests |
| Metadata, content, entropy | Escaping and UTF-8 kit with parity fuzz tests; VRF v2.5 adapter (moved to the V2Plus base); SSTORE2; bounded staticcall | Content store (24,575-byte chunks, range reads); RC1 entropy coordinator slimmed into the optional VRF module; owner record book and `HashRef` as the statement-log base; freeze compare-and-set for finalize | Compact `tokenURI` with `web3://` full views; plan-based multi-transaction upload; dependency-registry API. Dropped: Arweave inclusion verifier (it still trusts an observer quorum; signed fixity statements cover v1) |
| Tooling, tests, SDK | Deployed-bytecode verifier; official Safe fixture (1.3/1.4.1/1.5) | Compiler export with `--check`; invariant handler and campaign runner; adversarial mocks; RC1 TypeScript client and #744 Safe-plan helpers (SDK base); deploy assembly with non-broadcastable rehearsal; CI hygiene | Deployment-evidence layout; pre-send gas-cap simulation and transaction journal; threat model; [LTA-HASH]/[LTA-DEPLOY] rules; English-auction and money-invariant spec text |

(Amended by [ADR 0005](0005-stream-editions-auction.md): the ported allowlist phases, ERC-20 permits for editions
and Dutch pricing leave v1; they remain at `v1.0.0-rc.1`.)

The minimal reproducibility kit replaces about 35K lines of release tooling with
about 800. It consists of:
- one release compilation unit;
- the committed compiler input, manifest and artifacts;
- a deployment record with bytecode verification, configuration readback,
  Sourcify and Etherscan records, `SHA256SUMS` and a tag;
- an automated Sourcify submitter.

## Current behavior

RC1 on `main` remains the deployed reference instance. Its deployment is
`deployments/current/sepolia-2026-09-10`. PR #744 stays an unmerged draft.

## Intended behavior

The implementation is a fresh v1 with a new Core, deployed first to Sepolia
and then to mainnet.

**Target contract inventory (about 12):**
1. Stream ERC-721
2. package registry
3. curation verifier
4. work and content records
5. content store and dependency registry
6. renderer
7. auction house
8. 6529 Editions ERC-1155 with its edition sale
9. split factory and split wallet
10. royalty and revenue resolvers
11. artist registry
12. statement log

AccessManager governs all of them. The VRF module is optional.

**Engineering budgets, enforced as CI gates:**
- **Size:** 8–12K non-comment lines of production Solidity.
- **Structure:** at most 5 linked libraries; no delegatecall; no proxies.
- **Contract size:** EIP-170 enforced in every Foundry profile.
- **CI time:** full build and test in under 15 minutes.
- **Gas:** starting an auction costs 300K gas or less; `tokenURI` costs 8M gas
  or less in the worst case. (Amended by ADR 0003 and
  [ADR 0004](0004-gas-budgets-under-glamsterdam.md): see ADR 0004 for current
  figures.)
- **Testing:**
  - forge-std assertions;
  - selector-specific `expectRevert`;
  - invariant campaigns of at least 256 runs × depth 128 for every contract
    that moves money.
- **Merging:** required status checks plus one human approval.
- **Verification:** compiler metadata (CBOR with an IPFS bytecode hash) is
  enabled, so Sourcify and Etherscan report exact matches. Reproducibility comes
  from the committed standard-JSON input of one release compilation unit.

## Alternatives considered

- **Finish PR #744 as specified.**
  - Rejected: it cannot be built within CI limits, needs 1,200–2,100
    deployments, and is too large to audit.
- **Per-artist or per-collection contracts, or a hybrid factory.**
  - Rejected: they fragment liquidity.
- **Numbered ERC-721 editions inside Stream.**
  - Rejected: cheap copies would mix with 1/1s in one contract.
  - Editions go to the linked 1155 instead.
- **Keep RC1's bespoke governance.**
  - Rejected in favour of a standard, audited AccessManager.
- **Mandatory on-chain storage up to 1 MB.**
  - Rejected for gas-cost exposure.
  - Off-chain by default, with a collector-funded upgrade path.
- **A royalty "floor plus notice" for existing works.**
  - Rejected in favour of "new works only, unless the artist agrees".

## Security impact

- **The audit scope shrinks** from about 450K non-comment lines (PR #744) to a
  target of 8–12K.
- **The trust boundaries are explicit:**
  - the curation signer (until the 6529 chain);
  - the storage operator (display routing only);
  - the guardian (pause and veto only);
  - the admin Safe behind the delay classes.
- **The RC1 Medium findings and #744's verified findings are designed out:**
  - binding the allowlist leaf to the token recipient;
  - finalized `tokenURI` depending on a pointer nothing installs;
  - guardian-set changes taking effect immediately;
  - consent not keyed to the binding generation;
  - refunded purchases counting toward refund-window caps.

## Release impact

- v1 requires a new deployment. The RC1 Sepolia instance becomes historical.
- Release evidence is regenerated for the v1 source; RC1 artifacts are not
  edited.

## Test plan

- Focused unit tests and stateful invariants per contract:
  - value conservation;
  - single-use packages and items;
  - auction solvency;
  - split sums.
- A Sepolia acceptance run covering:
  - curated package → start → bids → settle → royalties;
  - an edition master plus its linked 1155 sale;
  - an off-chain to on-chain upgrade;
  - preferred-location failover;
  - consolidation recovery;
  - a dispute pause.
- A marketplace and `tokenURI` size matrix.

## Rollout plan

1. Owner accepts this ADR.
2. Update `AGENTS.md`, the status and readiness docs, the roadmap and the
   backlog.
3. Build to the budgets on a short-lived, always-green trunk.
4. Independent review, then deploy to Sepolia.
5. External audit, then mainnet.

## Non-goals and deferrals

**Not in v1:**
- for 6529 Stream: buy-now, offers, private sales and gifting as primary sales
  (Stream is auction-only; Editions keep fixed-price and Dutch sales, §6);
  (amended by [ADR 0005](0005-stream-editions-auction.md): editions sell by the uniform-price edition auction;
  clearing sales stay a non-goal for 6529 Stream's 1/1s)
- in Stream: Dutch auctions, clearing sales, refund windows, pay-what-you-want,
  curated sales, burn-to-mint, consignment, allowlist phases and delegated
  minting;
- the ARRNG fallback;
- PR #744's token, release, season and view finality scopes, render-critical
  inventories and coverage proofs;
- artist history hydration, import and export;
- class-four stewards and on-chain estate or dormancy;
- rewinds, appeals and artist delegation;
- museum hooks in Core;
- per-artist contracts;
- the Arweave inclusion verifier (dropped).

## Accepted risks

- Until the 6529 chain exists, curation outcomes rest on a trusted signer
  backed by published evidence.
- Starting bids at 0 can produce very low sale prices.
- Off-chain storage depends on Arweave and IPFS until a work is upgraded
  on-chain.
- Concentrating all works in one contract raises its security bar.

## Superseded or amended

- **Superseded:** [PV1-SCOPE] and the 37-role [LCM-GENESIS] inventory, for v1.
- **ADR 0004** (governance mechanics) and **ADR 0024** (governance catalog):
  replaced by §13.
- **ADR 0017** (raise-only parameters): amended to require ceilings.
- **ADR 0005** (randomness) and the VRF-fallback requirement cited in
  `docs/launch-v1-target-architecture.md`: amended by §9. Entropy is optional
  per work, and VRF alone is acceptable.
- **ADR 0006** (metadata freeze): amended by §10.
- **ADRs 0022 and 0023** (artist registry packets): superseded by §11.
- **ADR 0036** (on #744 only): delivery moved to the museum repository.
- **Retained:** ADR 0007 (no proxies), the ADR 0008 revenue principles and the
  ADR 0016 Core-native ERC-721.

## Open items

- Whether Stream and 6529 Editions count toward TDH (a backend decision,
  later).
- Safe signer thresholds, curation-signer operations, and the obligations for
  publishing evidence.
- Exact parameter values: wave thresholds, delay lengths, the inline threshold
  (from the Sepolia matrix) and gas ceilings.
- The timeline for the 6529 chain verifier.
- The autonomous Codex run on PR #744 was terminated on 11 October 2026 at the
  owner's instruction. Delivery passes to Claude Code under this ADR.
