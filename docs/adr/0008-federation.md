# ADR 0008: 6529 Stream Federated in v1

Status: Accepted by owner instruction, 15 November 2026. Recorded by the delivery owner
(Claude Code, acting for the repository owner). Amends [ADR 0001](0001-v1-scope.md) §16 (the
federated tier, as already moved into v1 by [ADR 0007](0007-permanence.md)) and
[ADR 0005](0005-stream-editions-auction.md) decision 9 (an unbid federated work). Specifies
ADR 0007's package P6, which that record left "in v1, specified by a later ADR".

The behaviour is specified in [Federation](../spec/federation.md) (rules FED-1 to FED-71); this
record is how it was decided. It is true at the tip that merges ADR 0007's review fixes
(16 November 2026): §4, §7, §8 and §10 record what that merge changed underneath the federation.
§1, §2, §8, §10 and §12 record the fixes of the independent federation review (review F) and of
its verification (review G).

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
  of a version has one runtime code hash.
- **A genuine copy is bound to how it was deployed (review F, F1; review G, G3).** As first
  built, a genuine copy was one `EXTCODEHASH` check. A code hash fixes the runtime code, not the
  storage the constructor leaves: any initcode that returns the approved runtime can first write
  storage the constructor never writes (an operator approval, pre-seeded works or edition
  records), and such a copy would have joined, defeating the template guarantees and the fee
  bargain, with state no event announces. A template version is now its runtime code hash
  **bound to its deployer**: one `FederatedDeployer` per version, ownerless and immutable (no
  owner, role, fee, upgrade, delegatecall or selfdestruct). Its constructor writes the version's
  creation code to data contracts it creates itself (`SSTORE2`: two for `FederatedStream`'s
  25,170 bytes, one for `FederatedEditions`) and records their keccak256 (`creationHash`,
  `CreationCodeStored`). Its one function, `deploy(salt, config)`, open to anyone, CREATE2s that
  creation code followed by the ABI-encoded constructor arguments, under the salt
  `keccak256(abi.encode(msg.sender, salt))`, records the address (`deployed`) and emits
  `Deployed(token, caller, salt, config)`. It can deploy nothing else. `register` lists a copy
  only if the version's approved deployer recorded it, so its starting storage is exactly what
  the constructor writes from `config`. The constructor arguments, never the caller, decide the
  artist; a copy anyone deploys naming an artist is inert until that artist's authority joins it
  (§2), and the caller-bound salt means nobody can take an artist's chosen address.
  Approval names the deployer (`approveTemplate(codeHash, deployer, version, form)`; `TemplateSet`
  carries the deployer and its creation code hash).
- **Why a recording deployer (review G, G3).** Review F first built the alternative with no
  deployer state: the registry recomputed the CREATE2 address of the deterministic deployment
  proxy from a presented salt and the creation code. That does not rest on preimage resistance,
  as this record first said, but on 160-bit collision resistance: an attacker's own factory and
  hostile initcode can be ground against the proxy's address space with a birthday search of
  about 2^80 hashes, far out of reach today and not over the lifetime these contracts aim at. A
  recording deployer is immune: CREATE2 fails at an occupied address, and a contract deployed at
  a colliding address by anyone else is never recorded. The same 2^80 bound applies to the split
  ledger's counterfactual vault addresses that are paid before they are deployed (the permanence
  branch's split-ledger limitation, LIM-ID-12 and MONEY-4); the ledger is not changed here. The
  deterministic deployment proxy is no longer a federation dependency (the genesis deploy still
  uses Foundry's CREATE2 factory, as before), and with it the permissionless `publishCode`, its
  first-writer-wins record and the griefing review G found there (G2) are gone.
- **The artist's cost.** Deploying through the deployer costs **5,100,251** Prague gas for
  `FederatedStream` against **5,418,645** for a plain CREATE of the same initcode (-318,394: no
  25 KB of calldata, plus the code read and one record slot, 22,100), and **3,592,141** for
  `FederatedEditions` against 3,805,265 (-213,124); each row is measured in its own test, before
  any state-diff recording (pass 3: the deployer rows were measured after one and read low), and
  each adds the 2,500 by which the renderer, which the test's own config read had warmed, would be
  cheaper than in the artist's transaction, where its code hash is first read cold.
  The bytes deployed are the same; under Glamsterdam the record slot costs about 111,000 and the
  estimate (§9) is about **37.9M** and **26.6M**. Joining costs **303,115** (284,685 as first
  built; the consent signature, the deployer's record read and the pair and content-store
  checks).

### 2. Joining: initiated and confirmed by the token

- The artist calls `joinFederation(Join)` on its own token; the token calls the artist
  registry's current federation registry (`register`), which checks the token's code hash is an
  approved, unsuspended version and its provenance (§1: the version's deployer recorded it),
  that it names the canonical artist registry, split ledger and (the 1/1 template)
  content store, and that its locked fee share and fee recipient equal the economics resolver's
  `PRODUCT_FEDERATED` values now; for a pair, that the partner is the other approved form and
  names it back, with the same artist and terms, and, for the 1/1 half, that its editions are
  already listed ACTIVE under the same artist (the editions join first, §8). It creates the
  artist's identity from the artist's own signature (`IArtistRegistry.registerFederated`) if
  needed, then lists the token (`listFederatedContract`; the artist registry reads the code hash
  itself).
- **The artist's consent is verified by the permanent registry (review F, F4).** A replaced
  federation registry could once write a directory entry for any non-canonical contract under
  any artist ID, permanently. `listFederatedContract(FederatedListing, consent)` now requires the
  artist's active authority's EIP-712 `FederatedListing(artistId, token, form, partner, feeShare,
  feeRecipient, deadline)` signature, verified by the artist registry itself with the shared
  `SignatureVerifier` (ECDSA, EIP-7702, or ERC-1271 for a contract authority; zero, so never
  valid, while a recovery override restrains the authority). Since review G (I3) the consent
  covers the entry's facts too, so a registry holding a consent cannot list even that token
  with facts the artist did not sign; the typed data freezes at launch. A listing happens once
  per token, so the signature needs no nonce. No federation registry, however hostile, can list
  a contract under an artist who did not sign for that exact contract and those facts. A new
  artist signs twice in one join (the registration and the consent); an existing one once. The
  digest is computed off chain from the registry's EIP-712 domain (`eip712Domain`) and
  `Typehashes.FEDERATED_LISTING`; the registry hashes the struct's seven calldata words directly
  (a non-canonical word only fails the check), keeping its EIP-170 margin at 1,091.
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
therefore inherits every listing with no listing to migrate and nothing to trust from its
predecessor. Its own state, the template table and the admitted adapters, is not inherited: a
successor must approve every template version (each bound to its deployer) and admit the
adapters before the switch, or it serves nothing (§8). A
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
- **An exit is never more served than the status it left (review F, F2).** As first built, an
  exit from DELISTED wrote LEFT, which `isActive` serves, so a delisted artist could revive the
  running sales the vote had stopped. The fact lives in the permanent directory, the only party
  that knows the status at exit: `recordFederationExit` writes **LEFT_DELISTED** from DELISTED
  (LEFT from ACTIVE), terminal like LEFT. No registry serves it (`isActive` serves only ACTIVE
  and LEFT), it has no entry, and no status write leaves it, so both shared adapters and both
  lenses, which read `isActive` and `entry`, treat it as delisted for good. A replacement
  registry inherits it with nothing to carry over.
- **An exit cannot outrun a vote (review G, G1).** As first fixed, a delisting scheduled for
  48 hours could be pre-empted: the artist left, the artist registry refused the delisting of a
  LEFT entry, the operation reverted at execution and LEFT kept serving the running sales; one
  such member also reverted a whole batch. Now the permanent directory records a delisting of a
  LEFT entry as **LEFT_DELISTED** (previous LEFT in the event), so a delisting always lands and
  the running sales end unsold with refunds. LEFT_DELISTED is terminal: a relisting cannot
  reverse it, because the contract left (its exit already ended new sales; nothing remains to
  restore). The registry's batch `setStatus` skips what it cannot change (an unlisted contract,
  or one that left asked to be ACTIVE) instead of reverting. Every ordering of leave, delist,
  relist, suspend and revoke was walked: leave then delist and delist then leave both end
  LEFT_DELISTED; a relist after a leave stays LEFT (finishing only what ran before the exit) or
  LEFT_DELISTED; suspension is a template status that never changes the directory; revocation
  unserves every copy of its version whatever the directory says. No status is more served than
  the decision intended; delisting still touches no token, ownership or fund owed, and sales that
  were running and not delisted still finish.
- **The pair is listed and leaves as one (review F, F3).** As first built, the two halves of a
  pair joined and left independently, so editions of masters sold at the network's fee could be
  sold through the artist's own minters while the 1/1 contract stayed listed. Now: the 1/1 half
  joins only once its editions are listed ACTIVE under the same artist (`register`); the
  registry lets an editions contract mint (`canMint`) only while its partner is listed ACTIVE;
  `FederatedStream` mints or restarts an EDITION_MASTER only while its editions are listed
  ACTIVE (or after its own exit, when its masters pay no fee; review G, G4 added the restart); and `FederatedEditions` admits its own minters
  only once its partner is out of the federation too (unlisted, LEFT or LEFT_DELISTED). An exit
  of either half is still the artist's alone and one-way; the other half's rules follow it.
- **One registry pointer in effect (review F, F7).** The English auction pins its own
  federation registry (and its code hash), the templates and the federated edition lens read the
  artist registry's; a replacement of only one would have let them answer from different
  template tables. The English auction is not changed (514 bytes of margin): every
  `FederationRegistry` read (`entry`, `isActive`, `canMint`) now answers as the registry the
  artist registry currently names, unless that registry is itself the caller (so a registry that
  consults its predecessor gets the predecessor's own answer and forwarding never loops). The
  replacement procedure still swaps both pointers in one batch, and a successor must approve
  every template version (each bound to its deployer) and admit the adapters **before** the
  artist registry's pointer moves: a successor without them serves nothing, so running sales
  freeze out with refunds (pinned by `test_Replacement_SwappedBeforeItsApprovalsFreezesRunningSales`;
  the procedure is in the script README).
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
  authority, so recovery works. The network has no restricted function on a deployed template,
  but two governed powers reach it (review F, F9): the artist registry's governed recovery
  override (PARAMETER_SETTER, 48 hours, contestable) decides who holds the artist's powers, and
  the replaceable federation registry decides which adapters may mint new works (`canMint`)
  while the contract is listed; an admitted adapter of an item's sale kind can mint any approved
  item into its own custody.
- **Anyone may start an approved item (review F, F11), by design.** An approval is the artist's
  consent to one sale, started by anyone (a keeper, the artist, a collector) at any time through
  any admitted adapter of the item's sale kind; the artist chooses the timing by when it
  approves, and `revokeItem` withdraws an approval not yet used.
- **Two works can never be offered again (review F, F10), as intended.** A dispute-cancelled
  work (`burn`) has no live token and is never restarted: the upheld dispute is final for that
  work. A refused master (RETURNED) whose edition sale had bound never restarts (its edition is
  keyed by that token ID) and is never settled, so its edition cannot be created; the edition
  sale voids with refunds.

### 9. Budgets, sizes and the artist's deployment cost

Measured at the tip that merges the permanence branch at 8b6f94cb, after reviews F and G and
pass 3 (16 November 2026).

- **Source lines:** **16,376** non-comment lines under `src/` (15,972 as first built; reviews F
  and G and pass 3 add the provenance, the deployer, the consent, the pair rules, the exit
  statuses, the genesis scoping, the license-text rule, the batch bound and the edition
  adapter's registry checks; the rest is the permanence branch's later fixes). The budget was raised to
  **16,000** to admit federation and to **16,500** for the reviews' fixes (owner, 16 November
  2026; see Amendments).
- **EIP-170 (runtime bytes, margin):** `FederatedStream` 23,527 (1,049), `FederatedEditions`
  16,429 (8,147), `FederatedDeployer` 1,425 (23,151; initcode 2,398 plus the template's
  creation code as its argument), `FederationRegistry` 10,816 (13,760), `FederatedEditionAuction`
  23,930 (646), its lens 24,021 (555). Canonical contracts the federation changes:
  `UniformEditionAuction` 24,061 (515, with the permanence branch's payout-gas rule), its lens
  23,168 (1,408); `GovernanceConfigurator` 11,813 runtime, 37,708 initcode (the genesis
  selectors and their interface scoping); the artist registry 23,485 (1,091: the listing
  consent over the entry's facts and the exit transitions). The English auction is unchanged at
  24,062 (514). Every contract keeps 512, with no exemption.
- **The artist pays the templates' deployment once**, through each template's deployer (§1).
  Measured (Prague, whole transaction, each row in its own test): `FederatedStream`
  **5,100,251** through its deployer (5,418,645 as a plain CREATE of the same initcode: the
  deployer saves the 25 KB of calldata, reads the code from its data contracts and writes one
  record slot); `FederatedEditions` **3,592,141** (3,805,265 plain); a pair about **8.7M**. Glamsterdam estimate from ADR 0004's
  unit prices (code 1,542 per byte, a new slot about 111,000, an empty CREATE about 210,000),
  replacing the Prague components (code at 200 per byte, a slot at 22,100, the 53,000 of the
  transaction and CREATE bases):
  - 721: 5,100,251 + 23,527 x 1,342 (31,573,234) + 12 x 88,900 (11 constructor slots and the
    record: 1,066,800) + 157,000 = **37,897,285** (about 37.9M);
  - 1155: 3,592,141 + 16,429 x 1,342 (22,047,718) + 9 x 88,900 (800,100) + 157,000 =
    **26,596,959** (about 26.6M);
  - a pair: about **64.5M**. Calldata repricing under Glamsterdam is not modelled [U]; it would
    favour the deployer path, which sends no creation code. At 1 / 5 / 10 gwei that is about
    0.038 / 0.19 / 0.38 ETH for a 721 alone. Clones (study H §4) would cut this to about 1.5M per
    contract and remain a later template version, touching nothing permanent.
- **Gas rows** (Prague; federated rows are their own, with ceilings in `FederationGas.t.sol`
  and ADR 0004's table): join creating the identity 303,115 (7 slots; 284,685 as first built);
  `approveItem` 59,357 (1); a first start deploying both vaults 679,109 (18 slots, 2 accounts);
  a steady start 416,019 (10; the first mint's license-text check, pass 3); a first bid 192,512
  (5); settle sold 179,197 (2); settle unbid 153,849 (2); restart 248,303 (4); federated edition
  `open` 373,965 (7); `createEdition` 86,736 (1); edition settle 151,447 (1). The steady rows read the artist registry's pointer on each
  registry read (F7). Glamsterdam, adding about 89,000 per new slot (and about 245,600 per vault
  created): steady start about 1.31M, first start about 2.77M. A federated settlement executes
  about 95,000 gas, far inside the refusal gas less the auction's 2.43M (guarantee 1).
- **Canonical rows** (pass 3, against the permanence tip at 8b6f94cb): every start and 1/1 row
  is identical to the tip's; the tightest start row is 344,960 (40 under the 345,000 gate). The
  edition auction's three `open` rows are 290,567, 336,304 and 429,883 (+291 each over the tip:
  the shared bases' hooks), and its other rows move by at most 16 gas either way. The federated
  edition adapter's bid, raise and settle overrides (pass 3) move no canonical row: the base
  only makes those functions `public virtual` and three members `internal`, and 6529 Stream
  Editions' deployment keeps its size.

### 10. Genesis wiring

Genesis deploys the federation registry (naming the canonical content store), the two
templates' deployers (`FederatedStreamDeployer`, `FederatedEditionsDeployer`, each constructed
with the build's creation code, which it writes to its own data contracts), the federated
edition auction's lens and the federated edition auction (`DeployV1.order`). It wires, as zero-delay installer calls before
any selector is mapped: the artist registry's one-shot `bindFederationRegistry`, the English
auction's `setFederationRegistry` (which pins the registry's code hash), `setAdapter` for the
English auction and the federated edition auction, and `approveTemplate` for `FederatedStream`
and `FederatedEditions`, version 1, each with its runtime code hash and its deployer. The code
hash is computed by the deploy script from the build (`DeployV1.templateCodeHash`:
`keccak256(type(T).runtimeCode)`) and the deployer named in the configuration, never held as
literals. `GovernanceConfig.isGenesisSelector` admits exactly
these three new selectors besides the bind, and since review F (F5) each genesis setter reaches
only a target that declares its interface through ERC-165 (`genesisInterface`: the sale
adapters' `setFederationRegistry` and `setTarget` need `ISaleAdapter`, so the artist registry's
30-day `setFederationRegistry`, which shares the selector, can never be wired; the registry's
`setAdapter` and `approveTemplate` need `IFederationRegistry`; `setAdmittedMinter` needs
`IMintTarget`). Every later change waits its class; `validateWiring` runs only inside
`install`, so nothing changes after genesis. `VerifyV1.checkFederation` reads the binding, the
English auction's registry and pinned code hash, both admitted adapters, the registry's content
store, both approved templates (`checkTemplate`: version, form, the recorded deployer; the
deployer's runtime code is the build's `FederatedDeployer`, which has no privileged path; its
creation code, read back from its data contracts and rehashed, is the build's), the federated
edition auction's lens and the federated product's economics (10% to the fee vault).
**Which build (review F, F8).** With `bytecode_hash = "ipfs"`, any edit to a source a template
imports changes both hashes, so `checkFederation` run from a later commit fails by design
(`test_CheckTemplate_RefusesARebuiltArtifact`). Artists never handle the creation code: the
deployer holds the genesis build's, stored on chain (`codeOf`). The registry's roles are SUCCESSOR_SETTER (approve, revoke, adapters;
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

### 12. What a logs-only reader checks (reviews F and G)

A federated contract is a listed template copy of an artist when all of these hold, from logs
alone:

1. The artist registry's `FederatedContractListed(artistId, token, codeHash, form, partner,
   feeShare, feeRecipient)`, and no later `FederatedContractStatus` to LEFT or LEFT_DELISTED (an
   exit, or a delisting after one, ends it; ACTIVE and DELISTED are the vote's).
2. In the same transaction, the token's own `FederationJoined` with the same artist, fee terms
   and partner, and the registry's `Registered(token, artistId, codeHash, deployer)`, from a
   registry the artist registry named then (`FederationRegistrySet`, or the genesis bind).
3. That registry's `TemplateSet(codeHash, deployer, creationHash, ...)` approving that version.
4. The deployer's `Deployed(token, caller, salt, config)`, and its `CreationCodeStored
   (creationHash, pointers)`: the token is a contract that deployer created from that creation
   code with `config` (the constructor arguments, which fix the starting storage). The reader
   trusts the deployer's code once (the build's `FederatedDeployer`, ownerless), not a hash
   formula.
5. The artist's consent to those facts was verified by the permanent artist registry at listing
   (no log is needed: no listing exists without it).

### 13. Pass 3 (16 November 2026)

- **License text.** A federated work's license never changes, so its text meets, at the first
  mint, the rule 6529 Stream's records apply to a frozen license: a registered SHA-256 content
  store file of at most 16 chunks (`InvalidLicenseText`); finalize also needs it complete in
  the content store. Only missing chunks, which anyone may write, can stand in the way, so no
  work is stuck. Re-checked for other stuck states: every artist power waits only on the
  artist's authority (a recovery override restrains it until it resolves), every presence check
  (media, license text) can be completed by anyone writing chunks, a changed renderer is
  replaced by the artist before finalize, and a left contract admits its own minters; the two
  dead ends that remain are the documented ones (§8, F10).
- **Fees locked when a sale starts.** The English auction locks the federated fee recipient at
  start and the federated edition auction at open; tests pin that a governance change of
  `networkFeeRecipient(PRODUCT_FEDERATED)` before settlement redirects nothing. No path re-reads
  the live recipient.
- **A voided edition stays dead.** If a federated edition sale voids while its best-effort seal
  is refused (only a faulty token refuses it), the edition stays bound to that adapter's void
  sale: the adapter never reopens a sale ID (`AuctionExists`), another adapter cannot bind it
  (`MinterMismatch`), and no minter, the artist's own included, can mint it.
- **Canonical ledger in the lens.** The federated edition lens refuses a token whose reported
  split ledger is not the economics resolver's split factory before it deploys any wallet.
- **Bounded batches.** `setStatus` and `propagateRevocation` take at most `MAX_BATCH` (256)
  contracts. The worst element (a cold listed contract written DELISTED) measures about 11,800
  gas after the first (about 16,600 cold), under the 20,000 the bound assumes: 256 x 20,000 =
  5.12M, a third of EIP-7825's 2^24 cap.
- **No guard in the editions template.** `FederatedEditions.mint` updates its count and logs
  before the ERC-1155 acceptance call, so a mint re-entered from it (only the bound adapter can
  mint) sees the raised count and the maximum holds; a guard would add a permanent slot write to
  every mint for no property the template does not already keep. The order of an adapter's own
  claims is the adapter's (the edition auction's are `nonReentrant`).

### 14. Pass 3: the automated review of PR 105

- **Four-bit file roles.** A work's `files` word kept each role in a byte below the count in
  the top byte, so a 32nd file's role landed in the count. Roles (0 to 15) now take four bits
  each, bits 0 to 127; a 32-file work reads back every role. The other packed words of both
  templates (the approval word: status byte, 24-bit rate bounded by 100,000, work ID above bit
  32; the sale word: currency below bit 160, price capped at 96 bits) have boundary tests.
- **Compare-and-set default renderer.** `setDefaultRenderer(expected, renderer, codeHash)`, as
  6529 Stream's, and `DefaultRendererSet(previous, next, codeHash)`, 6529 Stream's event
  (`IFederatedStream` is now `0x5b4e5ccb`). The other artist setters were swept for the same
  two properties: `setRoyaltyRate` only falls and logs both rates; `approveItem`,
  `revokeItem` and `setAdmittedMinter` set an explicit per-key state; `linkEditions` is
  one-shot; `setOwner` logs both owners; `setContractURI` keeps ERC-7572's valueless event; `setRecord` and `setLocator` edit one work's own
  record before finalize, the previous value is the last `WorkOpened`, `RecordChanged` or
  `LocatorSet`, and only the artist acts, with no consent to go stale (6529 Stream's state
  hash exists for its multi-party consents), so they stay as they are.
- **A delisting closes the edition sale at once.** The federated edition adapter checks the
  registry on every bid and raise (`BiddingClosed`, end zero), not only near the close, and
  a settle call on a sale whose scan has paid nothing re-checks it, so a delisting between
  settle calls voids the sale with full refunds; a paid clearing stands. 6529 Stream Editions
  has no delisting (its target flag gates only `open`) and is unchanged.
- **Measurement.** Each template deployment row is measured in its own test before any
  state-diff recording (§1, §9 corrected). The template gas-rule test accepts below the passing
  limit only an empty revert or the split ledger's starved CREATE2, never another error.
- **Operations.** The registry replacement repeats its comparison immediately before the switch
  (`VerifyV1.checkSuccessorParity`); `check_genesis.py` types each symbolic wiring name.

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
   records the exit, as LEFT_DELISTED when it left while delisted (served by nothing). (Owner may
   revisit: a fourth adapter-side status would need English auction bytes.)
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
14. Provenance through one ownerless recording deployer per template version (§1, review G),
    immune to CREATE2 address collisions, rather than a recomputed address. (Owner may revisit.)
15. The listing consent is a signature verified by the artist registry, not a direct call
    (cheaper in bytes and gas, one transaction, works for contract authorities), and it covers
    the entry's facts. (Owner may revisit before launch: the typed data freezes then.)
16. LEFT_DELISTED is terminal: a relisting does not reverse a delisting that landed after an
    exit. (Owner may revisit before launch: the directory's transitions are permanent.)

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
- Budget: raised to 16,500 for the federation review's fixes (provenance, consent, the pair, the
  exit status, genesis scoping), 16 November 2026 (owner: the budget can increase).
