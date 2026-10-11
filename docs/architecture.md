# 6529 Works architecture

This document is for builders implementing the v1 contracts and for reviewers
checking them. It describes how the contracts fit together, how the main flows
cross them, and where trust sits. The scope and the rules come from
[ADR 0001](adr/0001-v1-scope.md); where this document and the ADR differ, the
ADR wins. The precise contract surfaces are the interfaces in
[`src/interfaces/`](../src/interfaces/), which carry full NatSpec.

> **Status:** pre-audit, under construction. The interfaces are the agreed
> contract between implementation lanes; they are not yet implemented in full.

## Modules

```
                              governance: one AccessManager (Roles.sol)
                     restricts every governed selector below; guardian cancels
  ............................................................................
                                                                          
   artists, voters          curation signer        anyone (start, upload, settle)
        |                         |                          |
        v                         v                          v
  +-----------------+    +------------------+       +--------------------+
  | IPackageRegistry|--->| ICurationVerifier|       |  IEnglishAuction   |  shared sale
  |  approve, accept|    |  (pluggable, v1: |       |  IFixedPriceSale   |  adapters
  |  consume, unique|    |   EIP-712 signer)|       |  IDutchSale        |  (ISaleAdapter)
  +-----------------+    +------------------+       +--------------------+
     |   ^        |                                    |  IMintTarget   |  |
     |   |        | register / authority               v                v  | failed pushes
     |   |        v                          +----------------+  +-------------+  |
     |   |  +-----------------+   payout     |    IStream     |  |  IEditions  |  v
     |   |  | IArtistRegistry |<-------------|  ERC-721, works|<>|  ERC-1155   | +--------------+
     |   |  | (IArtistRole-   |              |  records, pins |  |  editions   | |RevenueEscrow*|
     |   |  |  Resolver)      |              +----------------+  +-------------+ +--------------+
     |   |  +-----------------+                |  |  |  |  royalty, seller
     |   |        ^ consolidation              |  |  |  v
     |   |        | (6529 delegation)          |  |  |  +--------------+  +---------------+
     |   +--------+-- consume (SYSTEM) --------+  |  |  | SplitFactory*|->| SplitWallet*  |
     |                                            |  |  +--------------+  | (artist-      |
     |    +--------------------+   terms, currency|  |                    |  resolved pay)|
     |    | IEconomicsResolver |<-----------------+  |                    +---------------+
     |    +--------------------+                     | tokenURI
     |                                               v
     |    +---------------+  bytes  +-------------+  +-----------------+
     |    | IContentStore |<--------|  IRenderer  |->| IStatementLog   | (dispute outcomes,
     |    | IDependency-  |         | (immutable, |  | (append-only,   |  evidence, fixity,
     |    |  Registry     |         |  pinned)    |  |  signed)        |  statements)
     |    +---------------+         +-------------+  +-----------------+
     |                                ^
     +-- IEntropyModule (optional VRF; seeds read by IStream and the auction)
         IFederationRegistry (v1.1 placeholder; read by adapters and indexers)
```

| Interface | Contract (lane folder) | ADR 0001 |
| --- | --- | --- |
| `IStream` (+ `IMintTarget`) | 6529 Stream ERC-721 (`src/stream/`) | §1, §4, §7, §8, §10, §12 |
| `IEditions` (+ `IMintTarget`) | 6529 Editions ERC-1155 (`src/editions/`) | §6 |
| `IPackageRegistry`, `ICurationVerifier` (v1: `ICurationSignerVerifier`) | package registry, v1 verifier (`src/curation/`) | §3 |
| `IContentStore`, `IDependencyRegistry`, `IRenderer` | content store, dependency registry, renderer (`src/content/`) | §8 |
| `ISaleAdapter`, `IEnglishAuction`, `IFixedPriceSale`, `IDutchSale` | shared sale adapters (`src/sales/`) | §5, §6, §12 |
| `IEconomicsResolver`; the economics lane's `ISplitFactory`, `ISplitWallet`, `IRevenueEscrow`, `IAssetAllowlist`, `IClaimRouter`, `IArtistPayoutResolver` (marked * above) | money routing (`src/economics/`) | §5, §7 |
| `IArtistRegistry` (+ `IArtistRoleResolver`), `IConsolidationSource` | artist registry, consolidation adapter (`src/identity/`) | §11 |
| `IStatementLog` | statement log (`src/records/`) | §12, §15 |
| `IEntropyModule` | optional VRF module (`src/stream/` or its own folder) | §9 |
| `IFederationRegistry` | v1.1 placeholder, no v1 implementation (`src/federated/`) | §16 |

Shared types live in [`src/interfaces/types/`](../src/interfaces/types/):
- package items and sale terms (`PackageTypes`);
- media and work records (`ContentTypes`);
- payments and primary terms (`SaleTypes`);
- shares, payees, currencies and product IDs (`EconomicsTypes`);
- artist identities (`IdentityTypes`);
- the bounds on every user-supplied array (`Limits`);
- the one definition of every protocol hash (`WorksHashing`);
- the statement log's `HashRef` and `StatementKinds`.

`IStatementLog`, `IArtistRoleResolver`, `IContentStore` and
`IDependencyRegistry` live in `src/interfaces/` beside the interfaces above.
The split, escrow and allowlist interfaces come from the economics lane. They
stay in `src/economics/interfaces/` until they move here, and until then
`Payee` mirrors its `ISplitWallet.Payee` exactly.

## Identifiers and hashes

All hashes are keccak256 over `abi.encode`, each type with its own domain
label, and none includes a chain ID or contract address, so they are identical
on Sepolia and mainnet. `WorksHashing` is the reference implementation; its
golden vectors in `test/interfaces/WorksHashing.t.sol` were computed with
`cast`, the same way off-chain tools compute them.

Two kinds of hash are deliberately bound to one chain and one contract. EIP-712
signatures that authorize actions use their verifying contract's domain, and
fixed-price allowlist leaves include `block.chainid` and the adapter's address
(see `IFixedPriceSale`), because an allowlist belongs to one sale.

| Identifier | Definition |
| --- | --- |
| item hash | `keccak256(abi.encode(PACKAGE_ITEM_DOMAIN, item))` |
| package root | OpenZeppelin `MerkleProof` root (sorted pairs) over leaves `keccak256(bytes.concat(itemHash))`; equal to `StandardMerkleTree` with leaf values `[PACKAGE_ITEM_DOMAIN, item]` |
| work record hash | `keccak256(abi.encode(WORK_RECORD_DOMAIN, work))`, committed as `PackageItem.metadataHash` |
| split wallet | the economics split factory's CREATE2 address over a canonical payee list (fixed payees by address, then artist-resolved payees by artist ID); predicted before deployment |
| file ID | `keccak256(abi.encode(chunkHashes, length, encoding, mimeType, sha256Hash))` (`IContentStore.manifestId`) |
| content ID | the file ID of a work's primary media, committed by the package item |
| content hash | the decoded SHA-256 the content store declares for the content ID (`IContentStore.sha256Of(contentId)`); the per-product uniqueness key, independent of MIME type and encoding |
| token ID | one global sequence on 6529 Stream, from 1, assigned at sale start, never reused |
| edition ID | equal to the master's Stream token ID |
| artist ID | `uint256(uint160(first authority))`, fixed when the first package acceptance creates the identity; known before any transaction and the same on every chain |
| product ID | `PRODUCT_STREAM`, `PRODUCT_EDITIONS`, `PRODUCT_FEDERATED` (`keccak256` of the name); scopes economics, default currencies and content uniqueness |
| sale ID | sequential per adapter |
| kinds | `bytes32` labels: `SaleKind.*` and `StatementKinds.*`, so new kinds need no format change |

Shares and rates use a denominator of 100,000 (6.529% is 6,529). The currency
`address(0)` is ETH; `CURRENCY_DEFAULT` in package terms means "the product's
default when the sale starts".

## Call flows

### Curated sale: approve, start, bid, settle, royalties

1. **Prepare (off-chain and permissionless).** The artist uploads media to
   Arweave and IPFS and registers each file's manifest in the content store
   (`registerManifest`). Tools build the package document; each item commits
   its content ID, the work record hash, the parties, the canonical payee list
   of the artist portion (shares out of 100,000; every payee a party), the
   collection, kind, license, seed policy and sale terms. Artist IDs are derived
   from addresses, so the payee list can name artist-resolved payees before any
   identity exists. Split wallets are not deployed: their CREATE2 addresses are
   predicted, and anyone may deploy them later (about 1.6M gas each).
2. **Vote and approve.** Voters approve the package root in a 6529 wave. The
   curation signer signs `PackageApproval(packageRoot, evidenceHash)`; anyone
   calls `IPackageRegistry.registerPackage`, which asks the verifier and stores
   the approval. The curation signer appends the `CURATION_EVIDENCE` statement.
3. **Consent.** Every party's signed `PackageAcceptance` is recorded with
   `acceptPackage`; a first acceptance creates the artist identity.
4. **Move to Stream.** The lead artist signs `MoveToStream(root, itemHash,
   nonce, deadline)` off-chain. It can be revoked before use (`revokeMove`).
5. **Start (permissionless).** Anyone calls `IEnglishAuction.start(stream,
   abi.encode(StreamMintRequest))` (or `startWithBid`). The auction calls
   `IStream.mint`, which calls `IPackageRegistry.consume` (proof, consents,
   canonical payees covered by parties, move signature, single use, and
   uniqueness under `PRODUCT_STREAM` of the content hash it reads from the
   content store), assigns the next token ID and collection serial, locks the
   predicted seller and royalty wallets and rates from
   `IEconomicsResolver.newWorkTerms`, mints into auction custody and returns
   `PrimaryTerms`. The auction locks the currency and terms and starts the
   24-hour clock. For a VRF work it calls `IEntropyModule.request`, and the
   clock starts in `activate` once the seed is delivered.
6. **Bid.** Bids reach `minimumBid` (`max(5%, currency floor)` over the high
   bid); late bids extend the end; outbid bidders are credited and `claim`.
   ERC-20 bids use `Payment` with EIP-2612 or Permit2 (a relayable payment
   intent).
7. **Settle (permissionless).** After the end, `settle` delivers the token to
   the winner, or records a pending claim if delivery fails (`claimDelivery`),
   and pays the seller wallet (deployed or not) and the network fee, depositing
   into the revenue escrow if a push fails. With no bids the token goes to the lead artist.
8. **Royalties.** Marketplaces read `royaltyInfo` (6.529% at launch), which
   reads the terms locked at mint without any external call. Royalties flow to
   the royalty wallet; payees `release` from split wallets (or in batches
   through the claim router), and artist-resolved payees are paid at
   `IArtistRegistry.payoutAddress(artistId)`, read at release time.

### Edition master and edition sale

1. The item has kind `EDITION_MASTER` and edition terms (format, size, window,
   price, currency, sale kind). The master is auctioned as above.
2. Anyone calls `IEditions.createEdition(workId, item)`. Editions checks the
   item against the master's committed item hash, claims the master's content
   hash under `PRODUCT_EDITIONS`, locks economics, records `(stream, workId, contentId)` and
   calls `IStream.linkEdition`. Both directions are written in one transaction
   and never change; the edition ID equals the master's token ID.
3. The lead artist or the PLATFORM role opens a sale on the fixed-price or
   Dutch adapter. Fixed price may run allowlist phases: each phase has a Merkle
   root of leaves bound to the receiving wallet (or the payer, for payer-keyed
   phases), a per-wallet cap and an optional per-wallet price. A per-wallet
   price below the package price counts only if the artist approved the phase
   configuration, by opening the sale or by signing `PhaseConfiguration`.
4. Each purchase calls `IEditions.mint` through the adapter, which enforces the
   size or window, pays the seller wallet and the fee, and emits `SaleSettled`.
   The edition renders its master's content through the master's renderer.

### Upload, finalize, upgrade

1. Before finalize the lead artist may replace the work record
   (`setWorkRecord`, bound to `workStateHash`); anyone may publish the approved
   record. The primary file always stays the approved content ID.
2. The artist or the PLATFORM role appends locators (`addLocator`: Arweave,
   IPFS, HTTPS). The STORAGE_OPERATOR role switches the preferred location among
   registered copies (global kind, then collection kind, then file index, then
   the first registered), emitting ERC-4906 events; it cannot add, remove or
   alter locators.
3. The artist calls `finalize(tokenId, expectedStateHash)`: the record becomes
   immutable and the default renderer is pinned. Delivery routing stays
   operable.
4. Anyone, typically the collector, uploads the media's chunks to the content
   store (`writeChunk`, about 72 KB per transaction). When every file is
   complete, anyone calls `IStream.syncOnChain`; the work is permanently
   on-chain complete and `tokenURI` may inline media up to the inline threshold.
5. Errata after finalize: `repinRenderer` needs the artist's co-signature, the
   SUCCESSOR_SETTER role and its 30-day delay, and emits a public event.

### Recovery

1. A lost or stolen key: an established consolidated wallet (6529 delegation,
   use case 999, at least 30 days old, not expired) stages a STANDARD change
   with `stageChange`, signed, with the new authority's acceptance.
2. The registry captures the established consolidated wallets at staging as
   cancellers. For 7 days the previous authority, any captured wallet, or the
   guardian (`vetoChange`, veto only) can cancel.
3. After 7 days anyone calls `executeChange`. Future payouts follow the new
   payout address, including balances already accrued in artist-resolved
   split payees.
4. Contested changes, estates and lost keys without consolidation use
   `stageOverride` (PARAMETER_SETTER role) with a 180-day public notice; estates
   and lost keys need a year without signed activity. Only captured wallets, not
   the old key, can cancel an override.

### Dispute pause

1. A dispute is filed in the 6529 disputes wave. The GUARDIAN role calls
   `IEnglishAuction.pause(saleId, disputeRef)`; the pause allowance is 7 days in
   total.
2. While paused, the high bidder may `withdrawBid`.
3. Upheld: the platform appends a `DISPUTE_OUTCOME` statement, and the
   PARAMETER_SETTER role calls `cancel(saleId, outcomeRef)` while the auction is
   still paused, citing that entry (`outcomeRef` must equal
   `IStatementLog.latestDisputeOutcome(token, tokenId)`): the bid is credited
   back and the token is burned, leaving a gap in the ID sequence. The item
   stays consumed.
4. Rejected: the UNPAUSER role calls `resume`. With no outcome, the pause ends
   by itself when the allowance runs out. Either way the auction continues with
   its remaining time, and anti-sniping still applies.
5. After a sale, a dispute only produces a statement; the renderer shows it in
   metadata through `latestDisputeOutcome`.

## Trust boundaries

| Actor | Can | Cannot |
| --- | --- | --- |
| Curation signer | Attest that a package root was approved (the v1 verifier trusts the key, not the vote); the guardian can disable a key at once, and re-enabling takes 30 days | Mint without party consent and the artist's move signature; alter an item; reuse an item or a content ID |
| Guardian Safes | Pause a live auction (at most 7 days), veto identity changes, revoke unconsumed package approvals, disable a curation signer, cancel scheduled governance operations | Redirect funds or identities; cancel an auction; resume it |
| Storage operator | Switch the preferred location among registered, hash-equal locators | Add, remove or change locators; change content hashes |
| Platform | Create collections, add locators, open edition sales and phases, post platform statements | Change prices, currencies, sizes or content of an approved package; set allowlist prices below the package price without the artist's signed approval |
| Admin Safe and setter roles | Governed setters behind the delay classes (48 hours, 14 days, 30 days), compare-and-set | Change a work's royalty, license or renderer pin without the artist's co-signature |
| Lead artist (current authority) | Move to Stream, edit the record until finalize, finalize, co-sign amendments, open edition sales | Change the approved content ID, parties, shares or sale terms |
| Sale adapters (MINTER) | Mint through `IMintTarget` on the token's own terms | Mint outside an approved item or an edition's terms |
| Protocol contracts (SYSTEM) | Consume items, claim content IDs, register artist identities | Act for an operator or an artist |
| VRF coordinator | Deliver a seed once per requested work | Choose which works are VRF, or change a delivered seed |
| 6529 delegation contract | Supply consolidations used as recovery cancellers and stagers | Execute a change before 7 days, or bypass the guardian veto |

Every external value transfer is pull-based or falls back to the escrow, and
every ERC-20 movement is checked by exact balance delta, so no single token or
recipient can block a sale.

## Governance map

The governance lane owns role IDs and delays in `src/governance/Roles.sol`.
The interfaces name the role each governed selector is meant to map to:

| Role | Selectors |
| --- | --- |
| GUARDIAN | `IAssetAllowlist.deprecateAsset` (economics lane; tightening), `IEnglishAuction.pause`, `IArtistRegistry.vetoChange`, `IPackageRegistry.revokePackage`, `ICurationSignerVerifier.disableSigner` |
| UNPAUSER | `IEnglishAuction.resume` |
| STORAGE_OPERATOR | `IStream.setPreferredKind`, `setCollectionPreferredKind`, `setFilePreference` |
| PLATFORM | `IStream.createCollection`, `IStream.addLocator` (also the artist), sale `openSale` and `closeSale` (also the creator) |
| MINTER | `IMintTarget.mint`, `IMintTarget.burn` on 6529 Stream and 6529 Editions |
| SYSTEM (proposed) | `IPackageRegistry.consume`, `claimContent`; `IArtistRegistry.register`, `heartbeat` (also the artist) |
| PARAMETER_SETTER (48 hours) | `IStream.relicense`, `setContractURI`; `IEditions.setContractURI`; `IEnglishAuction.cancel`, `setConfig`, `setOpeningBid`; `IEconomicsResolver.setDefaultLicense`; economics lane `IAssetAllowlist.admitAsset`, `setIncrementFloor`, `setDefaultCurrency`; `IArtistRegistry.stageOverride`; `IFederationRegistry.setStatus`, `setArtistDelisted` |
| FUNDS_SETTER (14 days) | `IStream.setRoyalty`, `setOwner`; `IEditions.setOwner`; `IEconomicsResolver.setEconomics` |
| SUCCESSOR_SETTER (30 days) | `IStream.setEditions`, `setDefaultRenderer`, `repinRenderer`; `IPackageRegistry.setVerifier`; `ICurationSignerVerifier.enableSigner`; `IArtistRegistry.setConsolidationSource`; `ISaleAdapter.setTarget` |

Each configuration epoch's manifest hash is recorded through the statement
log's restricted `appendGovernanceManifest`, the only path that may write a
`GOVERNANCE_MANIFEST` entry. Governed functions are non-payable. Setters for
funds, recipients, verifiers and renderers take the expected current value. Work amendments (`relicense`,
`setRoyalty`, `repinRenderer`) also need the artist's EIP-712 `WorkAmendment`
signature bound to the work's state hash.

## Budget notes

- **Start gas (at most 300K).** The start path consumes an item, mints, locks
  terms and opens the auction in one transaction. Implementations should store
  only what later reads need, pack it, and keep everything else in events.
  Split wallets are paid at predicted addresses and never deployed on the
  start path; package preparation registers manifests beforehand; and the
  registry can key single use and content uniqueness in one slot.
- **`tokenURI` gas (at most 8M).** The renderer inlines media only for on-chain
  complete works under the inline threshold; larger media go through chunked
  reads.
- **Transaction cap.** Every transaction must fit the EIP-7825 cap of
  16,777,216 gas. `Limits` bounds every user-supplied array and blob with that
  cap in mind; in particular a work record is at most 24,575 encoded bytes and
  must be stored as one SSTORE2 chunk, not word by word.
- **Lines.** Interfaces and shared types count toward the 12K-line budget
  (about 1,000 lines today).
