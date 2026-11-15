# ADR 0008: 6529 Stream Federated in v1

Status: Accepted by owner instruction, 15 November 2026. Recorded by the delivery owner
(Claude Code, acting for the repository owner). Amends [ADR 0001](0001-v1-scope.md) §16 (the
federated tier, as already moved into v1 by [ADR 0007](0007-permanence.md)) and
[ADR 0005](0005-stream-editions-auction.md) decision 9 (an unbid federated work). Specifies
ADR 0007's package P6, which that record left "in v1, specified by a later ADR".

The behaviour is specified in [Federation](../spec/federation.md) (rules FED-1 to FED-58); this
record is how it was decided.

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
predecessor. The registry's own state is the template table and the admitted adapters.
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
- The record is held by the template and answers the shared `Renderer`'s read surface
  (`work`, `collection`, `workRecords` = itself, `isOpen`, `record`, `mediaOf`,
  `preferredLocator`, `licenseOf`, `seedOf`); finalize pins the artist-chosen default renderer
  by code hash. What a federated work does **not** have, compared with a canonical one: curation
  and a package root; parties' consents (only the artist approves; collaborators may be payees,
  credited only in the record); VRF seeds; collections and serials beyond the contract itself;
  governed amendments (relicensing, errata repin) and the delivery satellite (one artist-set
  locator per file); store adapters other than the content store; statement-log artist
  resolution; content uniqueness across the network; the museum and rescue; TDH.

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

### 8. Governance, delisting and exit

- Template approval and revocation, and adapter admission: SUCCESSOR_SETTER, 30 days. Template
  suspension: GUARDIAN, immediate (new works only). Resumption and delisting: PARAMETER_SETTER,
  48 hours, guardian-vetoable, the vote reference recorded in the artist registry's event.
- Suspension stops new joins and new works; running sales finish. Revocation and delisting stop
  new sales and end running sales unsold with refunds (the work stays with the template);
  `propagateRevocation` writes a revoked template's listings DELISTED in the directory, anyone
  may call it. Nothing touches tokens, ownership, records, vaults or credits.
- Exit (`leaveFederation`, the artist, one-way) writes LEFT through the token itself; running
  sales finish (LEFT counts as served); works minted before keep the 90/10 vault; new works pay
  no network share; the artist then admits its own minters.
- Disputes apply to federated auctions (the English auction's pause and cancel). ETH only. No
  VRF. No royalty floor. Every artist power is checked against the artist registry's active
  authority, so recovery works; the network holds no power over a deployed template.

### 9. Budgets, sizes and the artist's deployment cost

- **Source lines:** 14,155 to **15,678** (+1,523: the templates 850, the registry 194, the
  federated edition auction and lens 173, interfaces +211 (three new, `IFederationRegistry`
  reshaped), the shared edition-auction bases +95). Over the 15,000 budget; the owner allowed an increase, and the
  proposed budget is **16,000**.
- **EIP-170 (runtime bytes, margin):** `FederatedStream` 21,917 (2,659), `FederatedEditions`
  16,194 (8,382), `FederationRegistry` 8,389 (16,187), `FederatedEditionAuction` 23,929 (647),
  its lens 23,743 (833); `UniformEditionAuction` 23,880 to 23,895 (681), its lens 22,774 to
  22,686 (1,890); the English auction is unchanged at 24,062 (514). Every contract keeps 512.
- **The artist pays the templates' deployment once.** Measured (Prague, whole transaction:
  21,000 + 32,000, calldata, the constructor and 200 per code byte): `FederatedStream`
  **5,043,923** (21,917 bytes, 10 slots); `FederatedEditions` **3,754,423** (16,194 bytes,
  8 slots); a pair **8,798,346**. Glamsterdam estimate from ADR 0004's unit prices (code
  1,542 per byte, a new slot about 111,000, an empty CREATE about 210,000), replacing the
  Prague components:
  - 721: 5,043,923 - 21,917 x 200 + 21,917 x 1,542 - 10 x 22,100 + 10 x 111,000 - 53,000 +
    210,000 = **35,502,537** (about 35.5M);
  - 1155: 3,754,423 - 16,194 x 200 + 16,194 x 1,542 - 8 x 22,100 + 8 x 111,000 - 53,000 +
    210,000 = **26,354,971** (about 26.4M);
  - a pair: about **61.9M**. Calldata repricing under Glamsterdam is not modelled [U]. At 1 /
    5 / 10 gwei that is about 0.036 / 0.18 / 0.36 ETH for a 721 alone. Clones (study H §4)
    would cut this to about 1.5M per contract and remain a later template version.
- **Gas rows** (Prague; federated rows are their own, with ceilings in
  `FederationGas.t.sol`): join creating the identity 284,634 (7 slots); `approveItem` 59,334
  (1); a first start deploying both vaults 664,768 (18 slots, 2 accounts); a steady start
  401,678 (10); a first bid 189,476 (5); settle sold 176,220 (2); settle unbid 150,872 (2);
  restart 245,046 (4); federated edition `open` 359,657 (7); `createEdition` 86,713 (1);
  edition settle 156,258 (1). Glamsterdam, adding about 89,000 per new slot (and about 245,600
  per vault created): steady start about 1.29M, first start about 2.76M. A federated
  settlement executes about 95,000 gas, far inside the refusal gas less the auction's 2.43M
  (guarantee 1).
- **Canonical rows:** no 1/1 row moved (the English auction's code is unchanged but for an
  interface-ID constant); the edition auction's rows are unchanged within 16 gas except its three
  `open` rows, +303 each (the shared base's hooks), inside their ceilings.

## Decisions the study left open, as built

1. Royalty rate per work: set by the artist's on-chain approval, no floor, at most 100,000.
2. Item consent: on-chain approval by the artist alone, not signatures; parties beyond the lead
   are not consented on chain.
3. A restart takes a new token ID (forced by the adapters' sale keys), needs a fresh approval,
   and is refused for an edition master whose edition sale began.
4. A federated work's renderer default is the artist's to set; finalize pins it.
5. Locators: one per media file, set and changed by the artist; no grammar or count bound.
6. `IFederationRegistry.Status` keeps three values; a LEFT contract reads ACTIVE there (its
   running sales finish); the directory distinguishes it.
7. A token whose listing was made by another registry first can never be confirmed; it never
   sells under that listing.
8. Template suspension is lifted by PARAMETER_SETTER (48 hours); revocation is terminal.
9. Artist-level delisting is expressed as per-token status writes in caller-sized batches.
10. The federated edition auction reads the registry from the artist registry's pointer (no own
    pointer, saving bytes the adapter does not have).

## Not fixable (documented)

Residual leakage: marketplaces that ignore ERC-2981; a 0% royalty rate; a self-bid at the
opening bid followed by an off-chain sale; side payments; works sold after an exit; and, as
governance risk rather than artist leakage, a replacement registry or adapter taking a different
fee (30-day swap with guardian veto). A bug in an approved template persists in its deployed
copies (deployed code never changes); suspension and revocation stop its sales.

## Amendments

(None yet.)
