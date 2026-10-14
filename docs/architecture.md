# 6529 Works architecture

This document is for builders implementing the v1 contracts and for reviewers
checking them. It describes how the contracts fit together, how the main flows
cross them, and where trust sits. The scope and the rules come from
[ADR 0001](adr/0001-v1-scope.md), as amended by the integrator's PR #10 review
decisions (D1–D26); where this document and the ADR differ, the ADR and those
decisions win. The precise contract surfaces are the interfaces in
[`src/interfaces/`](../src/interfaces/), which carry full NatSpec.

> **Status:** pre-audit, under construction. The interfaces are the agreed
> contract between implementation lanes; they are not yet implemented in full.

## Modules

```
                    governance: one AccessManager (Roles.sol) restricts every
                    governed selector; satellites are bound once at genesis
  ............................................................................

   artists, voters      curation signer (signs only)     anyone
        |                         |                           |
        v                         v                           v
  +-----------------+    +------------------+       +--------------------+
  | IPackageRegistry|--->| ICurationVerifier|       |  IEnglishAuction   |  shared sale
  | approve, accept |    | (v1: ICuration-  |       |  IFixedPriceSale   |  adapters
  | consume, unique |    |  SignerVerifier) |       |  IDutchSale        |  (ISaleAdapter)
  +-----------------+    +------------------+       +--------------------+
     |  ^   bound: Stream, Editions                    | IMintTarget  |
     |  |                                              v              v
     |  |  +-----------------+  payout     +----------------+  +-------------+
     |  |  | IArtistRegistry |<------------|  IStream core  |<>|  IEditions  |
     |  |  | (IArtistRole-   |             | ERC-721, terms |  |  ERC-1155   |
     |  |  |  Resolver)      |             | royalty, link  |  +-------------+
     |  |  +-----------------+             +----------------+        ^
     |  |       ^ consolidation               | bound    ^            | notify
     |  +-------+-- consume (bound) ----------+          |            |
     |                                       +----------------+       |
     |   +--------------------+    terms     |  IWorkRecords  |-------+
     |   | IEconomicsResolver |<-------------|  record files, |
     |   +--------------------+              |  media, license|
     |        | allowlist, splits (economics)|  finalize, pins|
     |        v                              |  locators      |
     |   SplitFactory*, SplitWallet*,        +----------------+
     |   RevenueEscrow*, AssetAllowlist*            | reads        tokenURI
     |                                              v                 |
     |   +---------------+   bytes   +-------------+   +-----------------+
     |   | IContentStore |<----------|  IRenderer  |-->|  IStatementLog  |
     |   | IDependency-  |           | (immutable, |   | (append-only,   |
     |   |  Registry     |           |  pinned)    |   |  signed)        |
     |   +---------------+           +-------------+   +-----------------+
     |
     +-- IEntropyModule (optional VRF, seeds keyed by item hash, before the start)
         IFederationRegistry (v1.1 placeholder; read by the sale adapters)
```

`*` marks the economics lane's interfaces (`src/economics/interfaces/`).

| Interface | Contract (lane folder) | ADR 0001 |
| --- | --- | --- |
| `IStream` (+ `IMintTarget`) | 6529 Stream core ERC-721 (`src/stream/`) | §1, §4, §7, §12 |
| `IWorkRecords` | work records satellite (`src/stream/`) | §8, §10 |
| `IEditions` (+ `IMintTarget`) | 6529 Editions ERC-1155 (`src/editions/`) | §6 |
| `IPackageRegistry`, `ICurationVerifier` (v1: `ICurationSignerVerifier`) | package registry, v1 verifier (`src/curation/`) | §3 |
| `IContentStore`, `IDependencyRegistry`, `IRenderer` | content store, dependency registry, renderer (`src/content/`) | §8 |
| `ISaleAdapter`, `IEnglishAuction`, `IFixedPriceSale`, `IDutchSale` | shared sale adapters (`src/sales/`) | §5, §6, §12 |
| `IEconomicsResolver` and the economics lane's interfaces | money routing (`src/economics/`) | §5, §7 |
| `IArtistRegistry` (+ `IArtistRoleResolver`), `IConsolidationSource` | artist registry, consolidation adapter (`src/identity/`) | §11 |
| `IStatementLog` | statement log (`src/records/`) | §12, §15 |
| `IEntropyModule` | optional VRF module (`src/entropy/`) | §9 |
| `IFederationRegistry` | v1.1 placeholder, no v1 implementation (`src/federated/`) | §16 |

Shared types live in [`src/interfaces/types/`](../src/interfaces/types/):
- package items, parties, licenses and sale terms (`PackageTypes`);
- media files and locators (`ContentTypes`);
- payments, primary terms and locked terms (`SaleTypes`);
- currencies, product IDs and work terms (`EconomicsTypes`; payees are the
  economics lane's `ISplitWallet.Payee`, shares out of `Splits.DENOMINATOR`);
- artist identities (`IdentityTypes`);
- per-call bounds (`Limits`);
- the protocol hashes (`WorksHashing`);
- every EIP-712 domain, typehash and Permit2 witness (`Typehashes`);
- the statement log's `HashRef` and `StatementKinds`.

## Identifiers and hashes

Package hashes are keccak256 over `abi.encode`, each type with its own domain
label, with no chain ID or contract address, so they are identical on Sepolia
and mainnet. `WorksHashing` and `Typehashes` are the reference; their golden
vectors in `test/interfaces/` were computed with `cast`, as off-chain tools do.
Two kinds of hash are deliberately bound to one chain and contract: EIP-712
signatures (each in its contract's domain) and fixed-price allowlist leaves.

| Identifier | Definition |
| --- | --- |
| item hash | `keccak256(abi.encode(PACKAGE_ITEM_DOMAIN, item))` |
| package root | OpenZeppelin `MerkleProof` root (sorted pairs) over leaves `keccak256(bytes.concat(itemHash))`; equal to `StandardMerkleTree` with leaf values `[PACKAGE_ITEM_DOMAIN, item]` |
| media hash | `keccak256(abi.encode(MEDIA_DOMAIN, media))` over every media file (file ID, decoded SHA-256, role), primary first; fixed by approval |
| content hash | the decoded SHA-256 of the primary media, carried by the item; the per-product uniqueness key |
| record file ID | the content-store file ID of a work's JSON descriptive record: one chunk of at most 12,288 bytes, `Identity` encoding, at most 16 artists; editable until finalize |
| license key | keccak256 of the ASCII-lowercased SPDX ID (the ID itself keeps its case, from `[A-Za-z0-9.+-]`); CC0 is `keccak256("cc0-1.0")` |
| file ID | `keccak256(abi.encode(chunkHashes, length, encoding, mimeType, sha256Hash))` (`IContentStore.manifestId`) |
| split wallet | the economics split factory's CREATE2 address over a canonical payee list (fixed payees by address, then artist-resolved payees by artist ID); predicted before deployment |
| artist ID | `artistIdOf(account)` if nonzero, otherwise `uint256(uint160(account))`; fits in 160 bits and never changes |
| product ID | `PRODUCT_STREAM`, `PRODUCT_EDITIONS`, `PRODUCT_FEDERATED` (`keccak256` of the name) |
| token ID | one global sequence on 6529 Stream, from 1, assigned at sale start, never reused |
| edition ID | equal to the master's Stream token ID |
| sale ID | auctions: `uint256(keccak256(abi.encode(token, tokenId)))`; fixed price and Dutch: sequential, one open sale per `(token, id)` |
| kinds | `bytes32` labels: `SaleKind.*` and `StatementKinds.*` |

Shares and rates use a denominator of 100,000 (6.529% is 6,529). The currency
`address(0)` is ETH; `CURRENCY_DEFAULT` in package terms means "the product's
default when the sale starts".

## Call flows

### Curated sale: approve, start, bid, settle, royalties

1. **Prepare (off-chain and permissionless).**
   - The artist uploads media to Arweave and IPFS and registers a content-store
     manifest for every media file, the JSON descriptive record and the license
     text.
   - Tools build the package document. Each item commits the content hash,
     the media hash, the record file ID, the parties, the canonical payee list
     (every payee a party), the collection, kind, license, seed policy and sale
     terms.
   - Split wallets are not deployed; their CREATE2 addresses are predicted.
2. **Vote and approve.**
   - Voters approve the package root in a 6529 wave.
   - The curation signer checks every declared SHA-256 against the decoded
     bytes, then signs `PackageApproval`; the attestation is
     `abi.encode(signer, signature)`.
   - Anyone calls `IPackageRegistry.registerPackage`, which emits the signer
     and the evidence hash. The CURATOR role appends `CURATION_EVIDENCE`.
3. **Consent.** Each party's `PackageAcceptance` is recorded as
   `acceptedAs[root][account] = artistId`; a first acceptance creates the
   identity and counts as artist activity.
4. **Seed (VRF works only).** Anyone calls `IEntropyModule.requestSeed(item,
   packageRoot, proof)` for an approved, unconsumed VRF item. The seed is keyed
   by item hash. While no seed is fixed, anyone may add another request after
   the retry delay (at least 3 days); the first delivery wins and later ones are
   no-ops. Nothing is in custody yet, so nothing can get stuck.
5. **Move to Stream.** The lead artist signs `MoveToStream` off-chain;
   `revokeMove` cancels an unused one.
6. **Start (permissionless; per steady-state start, at most 350K Prague gas and
   6 new slots, 7 with a bid; ADR 0004).** Anyone calls
   `IEnglishAuction.start(stream, abi.encode(StreamMintRequest))` or
   `startWithBid`.
   - The auction calls `IStream.mint`, which checks the admitted-minter mapping
     and calls `IPackageRegistry.consume`.
     Consume checks the proof, `acceptedAs` for each party (no registry calls),
     the payees, the move signature, and single use plus uniqueness in one
     storage word.
   - A VRF item reverts unless its seed is delivered.
   - Stream assigns the token ID and serial and locks the fee terms from
     `IEconomicsResolver.economics` and the predicted seller wallet from
     `ISplitFactory.walletFor` over the item's payees (what `newWorkTerms`
     returns, without its royalty-receiver derivation). It stores the item hash,
     the seller, the lead artist and one packed word; the royalty receiver is
     derived from the seller and fee terms when `royaltyInfo` is called, not
     stored.
   - The auction stores its sale and starts the 24-hour clock.
7. **Open the record (permissionless, off the start path).**
   `IWorkRecords.openRecord(tokenId, item, media)` checks the item against
   Stream's item hash, and the media against the media hash, the content hash
   and the content store's declared SHA-256. It then stores the record file ID,
   the media file IDs and an ARTIST seed. Until then every per-token
   `IWorkRecords` call reverts with `RecordNotOpen`, and the renderer shows
   core-only metadata.
8. **Bid.** The first bid is at least `max(openingBid, 1)` and locks the
   currency's increment floor; later bids add `max(5%, floor)`. Late bids extend the end, outbid bidders are
   credited and `claim`, and PERMIT2 bids carry the `Bid` witness.
9. **Settle (permissionless).** `settle` delivers the token or records a pending
   claim (`claimDelivery`, where the winner names the recipient).
   - Seller and fee terms are read back from the token, and the predicted seller
     wallet and the fee recipient are paid; failed pushes go to the escrow.
   - With no bids, the token goes to the artist's current authority, resolved
     at settlement.
   - Settlement calls `IMintTarget.markPrimarySettled`, even when delivery is still
     pending, so a winner who never claims cannot block the edition.
10. **Royalties.** `royaltyInfo` derives the receiver from the stored seller and
    fee terms, and reads the stored rate.
    - Payees `release` from split wallets, or batch through the claim router.
    - Artist-resolved payees are paid at `IArtistRegistry.payoutAddress`.

### Edition master and edition sale

1. The item has kind `EDITION_MASTER` and edition terms. The master is auctioned
   as above.
2. Once `IStream.primarySaleSettled(workId)` is true, anyone calls
   `IEditions.createEdition(workId, item, packageRoot, proof)`.
   - Editions checks the item against the master's item hash and the package,
     which must still be approved, and claims the content hash under
     `PRODUCT_EDITIONS`.
   - It locks economics, records `(stream, workId, contentHash)` and calls
     `IStream.linkEdition`.
   - A burned or disputed master never gets an edition.
3. The creator or the PLATFORM role opens one sale per `(token, id)` on the
   fixed-price or Dutch adapter.
   - Allowlist leaves bind `(chainid, adapter, token, id, phase, account, cap,
     price)`, with the account being the receiving wallet (or the payer, for
     payer-keyed phases).
   - A per-wallet price below the package price counts only if the artist
     approved the phases.
4. Each purchase mints through `IEditions.mint`. Dutch purchases charge exactly
   the current price, and `Payment.amount` is the maximum the buyer will pay.
   The edition renders its master's media and record. `WorkRecords` calls
   `notifyMasterUpdated` when the master changes, and `notifyAllUpdated` after a
   global or collection preferred-location change (as does Stream after a new
   default renderer), so Editions re-emits ERC-4906.

### Records, finalize, on-chain upgrade

1. Until finalize the artist may point the work at a new record file
   (`setRecord`, bound to the state hash). Media never changes.
   - The version bumps only on a real change: the record pointer, license,
     royalty rate or renderer pin. An identical re-publish is a no-op.
2. The artist or the PLATFORM role appends ARWEAVE or IPFS locators.
   - The STORAGE_OPERATOR role sets preferences. The most specific one wins:
     the file index, then the collection kind, then the global kind, then the
     first registered locator. A file with no locator yields an empty one.
   - It cannot add, remove or alter locators.
3. The artist calls `finalize(tokenId, expectedStateHash)` once the record file
   is on-chain complete: the record becomes immutable and Stream's default
   renderer is pinned.
4. Anyone uploads the media's chunks and calls `syncOnChain`; the work is then
   permanently on-chain complete. This does not change the state hash.
5. Amendments need agreement plus a governed action:
   - **Relicensing:** every party, PARAMETER_SETTER role. CC0 is irrevocable.
   - **Royalty-rate change:** every party, FUNDS_SETTER role. Payees never
     change. A master's change also applies to its edition
     (`IEditions.setRoyaltyRate`).
   - **Errata repin:** the artist, SUCCESSOR_SETTER role and its 30-day delay.

### Recovery

1. A lost or stolen key: an established consolidated wallet (6529 delegation,
   use case 999, at least 30 days old, not expired) stages a STANDARD change,
   with the new authority's signed acceptance.
2. The registry captures cancellers at staging: the effective wallets in the
   artist's sticky standing snapshot. A refresh records every two-way
   consolidation, a young one as pending until it is 30 days old; a keeper or
   the 6529.io UI refreshes after consolidation events. An established wallet
   that is no longer consolidated keeps standing until a refresh at least 30
   days after it went missing, so revoking the artist's consolidations cannot
   strip their standing. A pending one found no longer consolidated is dropped
   at once: a consolidation that ended before its 30 days never counts. An authority can also burn its current change nonce
   (`revokeNonce`) so that a change it pre-signed can never be staged.
   - For 7 days, the previous authority or any captured wallet can cancel.
   - The guardian can veto (`vetoChange`), which blocks a change but never
     redirects it.
3. After 7 days anyone calls `executeChange`. At staging and again at execution,
   the new authority must never have been an authority (of any artist, this
   one included: A, then B, then A is refused, so A's unused signatures stay
   void), and not reserved by another artist's pending change. Staging
   reserves it (`reservedFor`) until the change ends, so a package acceptance
   by the new key cannot register it as a separate artist meanwhile. Future
   payouts follow the new payout address, including balances already accrued.
4. Overrides cover contested changes, estates, and lost keys with no
   consolidation.
   - `stageOverride` (PARAMETER_SETTER role) needs the new authority's
     `OverrideAcceptance` signature and gives 180 days' public notice.
   - Estates and lost keys also need a year without the artist's own activity:
     registration, a staged change, a heartbeat, a cancellation by the old key
     or a captured wallet, a nonce revocation, or an executed change. Overrides
     and guardian vetoes do not count.
   - Only captured wallets, never the old key, can stop an override, and a
     captured wallet's cancel only contests it. A TDH vote, recorded as a
     DISPUTE_OUTCOME statement on `(registry, artistId)`, decides the contest
     through the governed 30-day `resolveContested` (uphold executes, void
     deletes). The guardian can veto, and an unresolved contest lapses after a
     year.

### Dispute pause

1. A dispute is filed in the 6529 disputes wave. The GUARDIAN role calls
   `IEnglishAuction.pause`; the pause allowance is 7 days in total.
2. While paused, the high bidder may `withdrawBid`.
3. **Upheld.** The platform appends a `DISPUTE_OUTCOME` statement. The
   PARAMETER_SETTER role then calls `cancel(saleId, outcomeRef)` while the
   auction is still paused.
   - `outcomeRef` must equal `latestDisputeOutcome`.
   - The window is inclusive (`block.timestamp <= pausedUntil`).
   - The bid is credited back and the token is burned. Anyone then calls
     `IStream.releaseContent(tokenId, contentHash)`, which passes the burned
     work's item hash to `IPackageRegistry.releaseContent`: the content hash is
     freed for its rightful artist and the item is tombstoned.
4. **Rejected.** The UNPAUSER role calls `resume`. With no outcome, the pause
   ends by itself when the allowance runs out.
5. **After a sale.** A dispute only produces a statement; the renderer shows
   it through `latestDisputeOutcome`.

## Trust boundaries

| Actor | Can | Cannot |
| --- | --- | --- |
| Curation signer | Attest that a package root was approved, after checking every declared SHA-256 against the decoded bytes. The v1 verifier trusts the key, not the vote. | Call any contract (it only signs); mint without party consent and the move signature; alter an item; reuse an item or a content hash. The guardian can disable a key at once; re-enabling takes 30 days. |
| Guardian Safes | Pause a live auction (at most 7 days); veto identity changes; revoke unconsumed approvals; disable a curation signer; cancel scheduled governance operations | Redirect funds or identities; cancel or resume an auction |
| Storage operator | Set preferred locations among registered, hash-equal locators | Add, remove or change locators; change content hashes |
| Platform | Create collections; add locators; open edition sales and phases | Change an approved package's prices, currencies, sizes or media; set allowlist prices below the package price without the artist's signed approval |
| CURATOR role | Append CURATION_EVIDENCE statements | Approve packages |
| Admin Safe and setter roles | Governed setters behind the delay classes (48 hours, 14 days, 30 days), compare-and-set; genesis bindings, once | Change a work's royalty rate or license without every party, or its renderer pin without the artist |
| Lead artist (current authority) | Move to Stream; edit the record until finalize; finalize; co-sign amendments; open edition sales | Change the approved media, parties, payees or sale terms |
| Sale adapters (admitted) | Mint through `IMintTarget` on the token's own terms | Mint outside an approved item or an edition's terms |
| Bound contracts | Stream consumes items; Editions claims content hashes; the package registry registers artists; the federation registry lists federated contracts under artists; WorkRecords sets royalty rates and asks Stream and Editions for ERC-4906 | Act for anyone else: each binding is one caller, set once at genesis |
| VRF coordinator | Deliver a seed once per requested item | Choose which items are VRF, or change a delivered seed |
| 6529 delegation contract | Supply consolidations used as recovery cancellers and stagers | Execute a change before 7 days, or bypass the guardian veto |

On-chain content uniqueness is defense in depth: the curation signer's SHA-256
check, covered by the evidence hash, is the primary control. Every external
value transfer is pull-based or falls back to the escrow, and every ERC-20
movement is checked by exact balance delta.

## Governance map

The governance lane owns role IDs and delays in `src/governance/Roles.sol`. The
interfaces name the role each governed selector is meant to map to:

| Role | Selectors |
| --- | --- |
| ADMIN (genesis, once each) | `IStream.bindWorkRecords`, `bindEditions`; `IPackageRegistry.bindStream`, `bindEditions`; `IArtistRegistry.bindPackageRegistry`, `bindStream`, `bindFederationRegistry`, `bindSplitFactory`, `bindStatementLog`; `IEditions.bindWorkRecords` |
| GUARDIAN | `IEnglishAuction.pause`, `IArtistRegistry.vetoChange`, `IPackageRegistry.revokePackage` (also pre-revokes unregistered roots), `ICurationSignerVerifier.disableSigner`; economics `IAssetAllowlist.deprecateAsset` |
| UNPAUSER | `IEnglishAuction.resume` |
| STORAGE_OPERATOR | `IWorkRecords.setPreferredKind`, `setCollectionPreferredKind`, `setFilePreference` |
| PLATFORM | `IStream.createCollection`; `IWorkRecords.addLocator` (also the artist); sale `openSale` and `closeSale` (also the creator) |
| CURATOR | statement log `appendCurator` (CURATION_EVIDENCE) |
| PARAMETER_SETTER (48 hours) | `IStream.setContractURI`, `IEditions.setContractURI`, `IWorkRecords.relicense`, `IEnglishAuction.cancel`, `setConfig`, `setOpeningBid`, `IEconomicsResolver.setRoyaltyRate`, `setDefaultLicense`, `IArtistRegistry.stageOverride`, `IFederationRegistry.setStatus`, `setArtistDelisted`; economics `IAssetAllowlist.setIncrementFloor` (economics setters are guarded by an expected revision) |
| FUNDS_SETTER (14 days) | `IWorkRecords.setRoyaltyRate`, `IStream.setOwner`, `IEditions.setOwner`, `IEconomicsResolver.setFeeTerms`; economics `IAssetAllowlist.admitAsset`, `setDefaultCurrency`, `IRevenueEscrow.recover` (ADR 0002, ADR 0003) |
| SUCCESSOR_SETTER (30 days) | `IMintTarget.setAdmittedMinter` (6529 Stream and 6529 Editions), `IStream.setDefaultRenderer`, `IWorkRecords.repinRenderer`, `IPackageRegistry.setVerifier`, `ICurationSignerVerifier.enableSigner`, `IArtistRegistry.setConsolidationSource`, `resolveContested`, `IEntropyModule.setCoordinator`, `ISaleAdapter.setTarget`, `setFederationRegistry` |

There is no SYSTEM role: contract-to-contract calls use the one-shot bindings in
the first row, so they skip the AccessManager hop. Sale adapters are admitted
to mint through each token's admitted-minter mapping (`setAdmittedMinter`), not
the MINTER role, for the same reason. Each bind rejects EIP-7702 delegated
accounts and checks ERC-165, except where the target does not implement it:
`IArtistRegistry.bindSplitFactory` checks only for code, and `bindStatementLog`
checks for code and that the log's artist resolver is the registry. Every installed dependency
(verifier, renderer, consolidation source, entropy module, economics resolver,
package registry, sale adapter, federation registry) supports ERC-165. Installs
check it, pin the code hash and reject EIP-7702 delegated accounts.

Each configuration epoch's manifest hash is recorded through the statement log's
restricted `appendGovernanceManifest`. Governed functions are non-payable, and
setters for funds, recipients, verifiers and renderers are compare-and-set.

## Budget notes

- **Start gas (ADR 0003, ADR 0004).** An end-to-end test measures `start`.
  - The gate is 350K Prague gas, and at most 6 new storage slots (7 with a
    bid), per steady-state ETH start transaction. The first start in
    an empty collection or custody may cost more; its measured value is recorded.
  - Glamsterdam prices each new slot at about 111K on Sepolia, so the same start
    costs about 847K there. Every operation in the gas report asserts its exact
    count of new slots and new accounts.
  - Stream stores the item hash, the seller, the lead artist and one packed
    word per token, and derives the royalty receiver. The registry stores one
    word per consumed item.
  - Mint checks an admitted-minter mapping, not an AccessManager hop.
  - The auction locks the increment floor at the first bid, not at start, and
    reads seller and fee terms back from the token.
  - Record opening, ARTIST seeds, VRF requests, split-wallet deployment and
    artist heartbeats all happen off the start path.
- **`tokenURI` gas (at most 8M).** The renderer inlines media only for on-chain
  complete works under the inline threshold.
- **Transaction cap.** Every transaction's regular gas must fit the
  EIP-7825 cap of 16,777,216; `Limits` bounds every user-supplied array with that
  in mind. On Sepolia, state-creation gas above the cap was accepted (ADR 0004).
- **Contract size.** Stream core stays within EIP-170 because records, licenses,
  finalize and locators live in `IWorkRecords`.
- **Lines.** Interfaces and shared types count toward the 12K-line budget.
