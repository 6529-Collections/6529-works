# 6529 Works architecture

This document is for builders implementing the v1 contracts and for reviewers
checking them. It describes how the contracts fit together, how the main flows
cross them, and where trust sits. The scope and the rules come from
[ADR 0001](adr/0001-v1-scope.md), as amended by the integrator's PR #10 review
decisions (D1–D26); where this document and the ADR differ, the ADR and those
decisions win. The precise contract surfaces are the interfaces in
[`src/interfaces/`](../src/interfaces/), which carry full NatSpec.

> **Status:** pre-audit. Every v1 module is implemented on `main`. This document
> is the overview; the [protocol specification](spec/README.md) describes how each
> area works now, flow by flow, and the [role and permission matrix](audit/roles.md)
> lists every governed selector.

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
  | approve, accept |    | (v1: ICuration-  |       |  IUniformEdition-  |  adapters
  | consume, unique |    |  SignerVerifier) |       |  Auction           |  (ISaleAdapter)
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
     +-- IEntropyModule (optional VRF, one seed per content hash, before the start)
         IFederationRegistry (v1.1 placeholder; read by the sale adapters)
```

`*` marks the economics lane's interfaces (`src/economics/interfaces/`).

| Interface | Contract (lane folder) | ADR 0001 |
| --- | --- | --- |
| `IStream` (+ `IMintTarget`) | 6529 Stream core ERC-721 (`src/stream/`) | §1, §4, §7, §12 |
| `IWorkRecords` | work records satellite (`src/stream/`) | §8, §10 |
| `IEditions` (+ `IMintTarget`) | 6529 Stream Editions ERC-1155 (`src/editions/`) | §6 |
| `IPackageRegistry`, `ICurationVerifier` (v1: `ICurationSignerVerifier`) | package registry, v1 verifier (`src/curation/`) | §3 |
| `IContentStore`, `IDependencyRegistry`, `IRenderer` | content store, dependency registry, renderer (`src/content/`) | §8 |
| `ISaleAdapter`, `IEnglishAuction`, `IUniformEditionAuction` | shared sale adapters (`src/sales/`) | §5, §6, §12; ADR 0005 |
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
signatures, each in its contract's domain.

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
| sale ID | both auctions: `uint256(keccak256(abi.encode(token, tokenId)))`; the edition auction's token is 6529 Stream Editions and its ID the edition ID |
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
   - Voters approve the package root on Main Stage, the only way into 6529 Stream (owner
     decision 25).
   - The curation signer checks every declared SHA-256 against the decoded
     bytes, then signs `PackageApproval`; the attestation is
     `abi.encode(signer, signature)`.
   - Anyone calls `IPackageRegistry.registerPackage`, which emits the signer
     and the evidence hash. The CURATOR role appends `CURATION_EVIDENCE`.
3. **Consent.** Each party's `PackageAcceptance` is recorded as
   `acceptedAs[root][account] = artistId`; a first acceptance creates the
   identity and counts as artist activity.
4. **Seed (VRF works only).** Anyone calls `IEntropyModule.requestSeed(item,
   packageRoot, proof)` for an approved, unconsumed VRF item. The seed is drawn
   once per content hash: every approved item carrying the same work links to
   that one draw and reads it by item hash, so re-packaging a work cannot draw
   again. While no seed is fixed, anyone may add another request after the
   retry delay (at least 3 days); the first delivery wins and later ones are
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
     returns, without its royalty-receiver derivation). It stores two words per
     token, the seller with the packed serial, collection, flags and terms ID,
     and the item hash; the terms (the lead artist and the fee terms) are one
     word shared by the artist's works. The royalty receiver is derived from the
     seller and fee terms when `royaltyInfo` is called, not stored.
   - The auction stores its sale and starts the 24-hour clock.
7. **Open the record (permissionless, off the start path).**
   `IWorkRecords.openRecord(tokenId, item, media)` checks the item against
   Stream's item hash, and the media against the media hash, the content hash
   and the content store's declared SHA-256, and caps each PREVIEW file's size
   (`Limits.MAX_PREVIEW_BYTES`). It then stores the record file ID,
   the media file IDs and an ARTIST seed. Until then every per-token
   `IWorkRecords` call reverts with `RecordNotOpen`, and the renderer shows
   core-only metadata.
8. **Bid.** The first bid is at least the opening bid locked when the auction
   started (or the reserve a withdrawn bid left, if higher), and at least 1 wei;
   it locks the currency's increment floor. Later bids add `max(5%, floor)`. Late bids extend the end, outbid bidders are
   credited and `claim`, and PERMIT2 bids carry the `Bid` witness.
9. **Settle (permissionless).** `settle` delivers the token or records a pending
   claim (`claimDelivery`, where the winner names the recipient).
   - Seller and fee terms are read back from the token, and the predicted seller
     wallet and the fee recipient are paid; failed pushes go to the escrow. An
     ERC-20 payout runs in its own call frame: if it fails even through the
     escrow (the token changed behaviour, or blocks the auction), it is credited
     to its wallet in the auction and the work is still delivered; anyone pays
     the credit out with `claimFor(wallet, token)` once the token works again
     (ERC-20 only; ETH credits are bidders' refunds, claimed by the bidder). The
     settler must forward the frame's 1,000,000 gas: an ERC-20 settle needs a
     call gas limit of about 1.11M.
   - A deprecated currency freezes the auction (MARKET-2): nothing settles, and
     a standing bidder may withdraw. A re-admission comes no earlier than 14
     days after the deprecation. If it comes after the auction's end, or within
     its last anti-snipe window, the first `settle` reopens the auction for at
     least the governed duration; otherwise the auction settles as usual. Once
     the currency has been deprecated for 30 days, anyone
     may end the sale unsold (reported FROZEN_OUT): the standing bid is credited
     back and the work goes where an unbid work goes, the museum for a 6529
     Stream work and the artist for any other token (owner decisions 9 and 10).
     The resolver never accepts a fee recipient it can recognise as unable to
     be paid (the escrow, the claim router, a sale adapter, Stream, Editions,
     the registries, the work records, the release verifier).
   - Settlement reports the outcome to the token, `IMintTarget.settlePrimary`
     (owner decision 17): SOLD with the buyer, currency and price, UNBID, or
     FROZEN_OUT. Stream records it, even when delivery is still pending, so a
     winner who never claims cannot block the edition, and returns the seller
     and fee terms the auction pays by.
   - With no bids, Stream itself moves a 6529 Stream work to the 6529 Network
     Museum, `EconomicsResolver.museum()` resolved at settlement (D140), for
     every admitted 1/1 adapter. Any other token's work, federated or listed,
     goes to its artist's active authority, and while a recovery override is
     pending its settlement waits.
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
     which the registry must have registered (a later revocation of the root
     does not strand the edition of a master already sold from it), and claims
     the content hash under
     `PRODUCT_EDITIONS`.
   - It locks economics, records `(stream, workId, contentHash)` and calls
     `IStream.linkEdition`.
   - A burned or disputed master never gets an edition.
3. The edition auction runs beside the master's 1/1: anyone opens it from the
   1/1's start (the keeper batches it with `start`), anyone bids a quantity at a
   ladder step in ETH, and it closes a governed offset after the 1/1's final end, or
   later under its own soft close. Settlement needs the 1/1 settled and, when
   copies sold, the edition created (step 2); it computes one clearing price and
   count and pays the seller and the network.
4. Each claim of a winning bid mints through `IEditions.mint`, so the edition
   reaches exactly the count sold; losers' escrow is refunded in full
   ([editions and sales](spec/editions-and-sales.md)). Editions mints only for an
   adapter whose sale kind the edition's terms name, within the creator's
   optional cap. Each edition is bound to one adapter: the one whose sale opened
   it (`bindMinter`), or else the first to mint it. A new sale method is a new
   adapter, never a new Editions.
5. The edition renders its master's media and record. `WorkRecords` calls
   `notifyMasterUpdated` when the master changes, and `notifyAllUpdated` after a
   global or collection preferred-location change (as does Stream after a new
   default renderer), so Editions re-emits ERC-4906.

### Records, finalize, on-chain upgrade

1. Until finalize the artist may point the work at a new record file
   (`setRecord`, bound to the state hash). Media never changes.
   - The version bumps only on a real change: the record pointer, license,
     royalty rate or renderer pin. An identical re-publish is a no-op.
2. The artist or the PLATFORM role appends ARWEAVE or IPFS locators. Each is a
   content address: `ar://` and a 43-character transaction ID, or `ipfs://` and
   a CIDv1 of the fixed profile, with no path.
   - The STORAGE_OPERATOR role sets preferences. The most specific one wins:
     the file index, then the collection kind, then the global kind, then the
     first registered locator. A file with no locator yields an empty one.
   - After finalize only the PLATFORM role adds locators.
   - It cannot add, remove or alter locators.
3. The artist calls `finalize(tokenId, expectedStateHash)` once the record file
   is on-chain complete: the record becomes immutable and Stream's default
   renderer is pinned.
4. Anyone uploads the media's chunks and calls `syncOnChain`; the work is then
   permanently on-chain complete. A call checks whole files up to 512 chunks and
   keeps its place, so a large work takes a few calls, each within the
   per-transaction cap. This does not change the state hash.
5. Amendments need agreement plus a governed action:
   - **Relicensing:** every party, PARAMETER_SETTER role. CC0 is irrevocable, and a
     CC0 license (approved or set this way) names the deployment's CC0 text.
   - **Royalty-rate change:** every party, FUNDS_SETTER role. Payees never
     change. A master's change also applies to its edition
     (`IEditions.setRoyaltyRate`).
   - **Errata repin:** the artist, SUCCESSOR_SETTER role and its 30-day delay.

### Recovery

1. A lost key: an established consolidated wallet (6529 delegation, use case
   999, at least 30 days old, not expired) stages a STANDARD change, with the
   new authority's signed acceptance. A stolen key cannot be recovered this
   way, because the thief, as the previous authority, can cancel any STANDARD
   change; a stolen key goes through the override in step 4.
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
   - `stageOverride` (PARAMETER_SETTER role) gives 180 days' public notice. An
     override that moves the authority needs the new authority's
     `OverrideAcceptance` signature; a payout-only override needs none.
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
   - While an override that would move the authority is pending, nobody acts
     as the artist (ADR 0003 owner decision 6). `activeAuthorityOf` is zero, so
     the sale `creator`, move and acceptance signatures, record amendments and
     consents, and ARTIST statements all refuse both the old and the new key
     until it executes, is vetoed or voided, or lapses. A federated work's
     no-bid settlement waits for the outcome (a canonical one goes to the
     museum); sales already running continue, with
     the artist's share frozen. `authorityOf` keeps identifying the artist.

### Dispute pause

1. A dispute is filed in the 6529 disputes wave. The GUARDIAN role calls
   `IEnglishAuction.pause`: one dispute pause per auction, lasting at most 7
   days (`MAX_PAUSE`).
2. While paused, the high bidder may `withdrawBid`. The withdrawn amount
   stays as a reserve the next bid must reach. When the auction resumes (by
   `resume` or when the pause lapses) it runs for its remaining time or the
   governed duration, whichever is longer (the anti-snipe window if longer
   still), with or without a standing bid, so the refunded bidders can return.
3. **Upheld.** The platform appends a `DISPUTE_OUTCOME` statement about the
   token (it must exist; an outcome recorded about the item before its mint is
   also shown, until one about the token replaces it). The PARAMETER_SETTER
   role then calls `cancel(saleId, outcomeRef)` while the auction is still
   paused.
   - `outcomeRef` must be the token's own latest outcome
     (`disputeOutcomeOf`, with no item fallback) and must have been recorded
     after the pause: the auction keeps, at the pause, the chain position a
     later outcome must reach, so an outcome recorded before the pause, or one
     about the package item, cannot cancel it.
   - The window is inclusive (`block.timestamp <= pausedAt + MAX_PAUSE`).
   - The bid is credited back and the token is burned.
   - **Before the cancel executes, the guardian revokes every approved root
     that lists the copier's items** (`revokePackage`): any other copy of the
     content, and the copier's other works in those packages. Revocation is
     per root, and the cancel tombstones only the burned item.
   - PARAMETER_SETTER then calls `IStream.releaseContent(tokenId, contentHash,
     beneficiary)` (48 hours; schedule it with the cancel, to execute after
     it), naming the rightful artist's ID from the outcome. The beneficiary must
     be a registered artist (`UnknownArtist` otherwise), so schedule the release
     once the rightful artist has an identity (its first package acceptance
     creates it). Stream passes the burned work's item hash to
     `IPackageRegistry.releaseContent`: the content hash is reserved for items
     whose lead artist is the beneficiary, and the burned item is tombstoned. A
     release happens once per burned work, so the guardians check the
     beneficiary during the delay.
4. **Rejected.** The UNPAUSER role calls `resume`, no earlier than 48 hours
   after the pause (the auction refuses an earlier one, even if it was
   scheduled before the pause, so the guardians always have the standard
   window to cancel it). With no outcome, the pause ends by itself when the
   allowance runs out.
5. **After a sale.** A dispute only produces a statement; the renderer shows
   it through `latestDisputeOutcome`, on the work and on its edition. The
   latest outcome about a work is its current dispute status, so each outcome
   document restates the earlier outcomes it keeps in force and cites the one
   it replaces in `supersedes`.

## Trust boundaries

| Actor | Can | Cannot |
| --- | --- | --- |
| Curation signer | Attest that a package root was approved, after checking every declared SHA-256 against the decoded bytes. The v1 verifier trusts the key, not the vote. | Call any contract (it only signs); mint without party consent and the move signature; alter an item; reuse an item or a content hash. The guardian can disable a key at once; re-enabling takes 30 days and starts a new signer epoch, so no earlier approval revives. |
| Guardian Safes | Pause a live auction for a dispute (once, at most 7 days); pause the sale adapters' new sales; deprecate a currency, which freezes live auctions in it; veto identity changes; revoke unconsumed approvals; disable a curation signer; deprecate a dependency version; cancel scheduled governance operations; suspend a platform, curator or storage operator key at once (lifted only by a 30-day ADMIN grant or revocation) | Redirect funds or identities; cancel or resume an auction; lift a suspension or grant any role |
| Storage operator | Set preferred locations among the copies registered for each file (the contract stores no locator hash; the off-chain monitor verifies copies) | Add, remove or change locators; change content hashes |
| Platform | Create collections; add locators | Change an approved package's terms or media |
| CURATOR role | Append CURATION_EVIDENCE statements | Approve packages |
| Admin Safe and setter roles | Governed setters behind the delay classes (48 hours, 14 days, 30 days), compare-and-set; genesis bindings, once | Change a work's royalty rate or license without every party, or its renderer pin without the artist; move an escrow credit anywhere but an identical replacement wallet, or the replacement its holder named (`consentToRecovery`) |
| Lead artist (active authority) | Move to Stream; edit the record until finalize; finalize; co-sign amendments | Change the approved media, parties, payees or sale terms |
| Sale adapters (admitted) | Mint through `IMintTarget` on the token's own terms | Mint outside an approved item or an edition's terms |
| Bound contracts | Stream consumes items; Editions claims content hashes; the package registry registers artists; the federation registry lists federated contracts under artists; WorkRecords sets royalty rates and asks Stream and Editions for ERC-4906 | Act for anyone else: each binding is one caller, set once at genesis |
| VRF coordinator | Deliver a seed once per requested content | Choose which items are VRF, or change a delivered seed |
| 6529 delegation contract | Supply consolidations used as recovery cancellers and stagers | Execute a change before 7 days, or bypass the guardian veto |

On-chain content uniqueness is defense in depth: the curation signer's SHA-256
check, covered by the evidence hash, is the primary control. Every external
value transfer is pull-based or falls back to the escrow, and every ERC-20
movement is checked by exact balance delta.

## Governance map

The governance lane owns role IDs and delays in `src/governance/Roles.sol`. The
interfaces name the role each governed selector is meant to map to. The complete,
authoritative list, generated from `config/genesis.example.json`, is the
[role and permission matrix](audit/roles.md):

| Role | Selectors |
| --- | --- |
| ADMIN (genesis, once each) | `IStream.bindWorkRecords`, `bindEditions`; `IPackageRegistry.bindStream`, `bindEditions`; `IArtistRegistry.bindPackageRegistry`, `bindStream`, `bindSplitFactory`, `bindStatementLog`; `IEditions.bindWorkRecords`. `IArtistRegistry.bindFederationRegistry` is deferred to v1.1 (a 30-day ADMIN action then) |
| GUARDIAN | `IEnglishAuction.pause(saleId, disputeRef)`, `IArtistRegistry.vetoChange`, `IPackageRegistry.revokePackage` (also pre-revokes unregistered roots), `ICurationSignerVerifier.disableSigner`, `IDependencyRegistry.deprecate`; economics `IAssetAllowlist.deprecateAsset`; the manager's own `WorksAccessManager.suspend` (checked by the manager, not mapped) |
| PAUSER | the sale adapters' emergency `pause()` |
| UNPAUSER (48 hours) | `IEnglishAuction.resume`; the sale adapters' `unpause()` |
| STORAGE_OPERATOR | `IWorkRecords.setPreferredKind`, `setCollectionPreferredKind`, `setFilePreference` |
| PLATFORM | `IStream.createCollection`; `IWorkRecords.addLocator` (also the artist); statement log `appendPlatform` (DISPUTE_OUTCOME) |
| CURATOR | statement log `appendCurator` (CURATION_EVIDENCE) |
| PARAMETER_SETTER (48 hours) | `IStream.setContractURI`, `releaseContent`, `IEditions.setContractURI`, `IWorkRecords.relicense`, `IEnglishAuction.cancel`, `setConfig`, `setOpeningBid`, `IEconomicsResolver.setRoyaltyRate`, `setDefaultLicense`, `IArtistRegistry.stageOverride`, `IDependencyRegistry.register`, `IEntropyModule.setConfig`, `IFederationRegistry.setStatus`, `setArtistDelisted` (v1.1); economics `IAssetAllowlist.setIncrementFloor` (economics setters are guarded by an expected revision) |
| FUNDS_SETTER (14 days) | `IWorkRecords.setRoyaltyRate`, `IStream.setOwner`, `IEditions.setOwner`, `IEconomicsResolver.setFeeTerms`; economics `IAssetAllowlist.admitAsset`, `setDefaultCurrency`, `IRevenueEscrow.recover` (ADR 0002, ADR 0003) |
| SUCCESSOR_SETTER (30 days) | `IMintTarget.setAdmittedMinter` (6529 Stream and 6529 Stream Editions), `IStream.setDefaultRenderer`, `IWorkRecords.repinRenderer`, `IPackageRegistry.setVerifier`, `ICurationSignerVerifier.enableSigner`, `IArtistRegistry.setConsolidationSource`, `resolveContested`, `IEntropyModule.setCoordinator`, entropy `lowerCallbackGasLimit`, `ISaleAdapter.setTarget`, `setFederationRegistry`; statement log `setArtistResolver`, `appendGovernanceManifest` |

There is no SYSTEM role: contract-to-contract calls use the one-shot bindings in
the first row, so they skip the AccessManager hop. Sale adapters are admitted
to mint through each token's admitted-minter mapping (`setAdmittedMinter`), not
the MINTER role, for the same reason. Each bind rejects EIP-7702 delegated
accounts and checks ERC-165, except where the target does not implement it:
`IArtistRegistry.bindSplitFactory` checks only for code, and `bindStatementLog`
checks for code and that the log's artist resolver is the registry. Every installed dependency
is checked at install for code, ERC-165 support where it has it, and no EIP-7702
delegation. The curation verifier, the default renderer, the consolidation
source, the VRF coordinator, the statement log's artist resolver, the split
factory's payout resolver and release verifier, and the sale adapters'
federation registry are also pinned to a reviewed code hash and checked against
it again at use. Stream's package registry, artist registry, economics resolver
and entropy module, and the admitted sale adapters, are checked at install only,
with no code-hash pin. The auditor pack lists every pin and its test
([trust assumptions](audit/trust-assumptions.md#pinned-code-hashes)).

Renderer pins are checked again at use (DEPS-6): `Stream.rendererOf`, which
`tokenURI` and 6529 Stream Editions' `uri` go through, compares the default renderer's
code hash with the one it was installed with, and `WorkRecords.pinnedRenderer`
compares a finalized work's renderer with the hash it was pinned with. Changed code
fails closed: the metadata view reverts, never falling back to another renderer,
until a new default renderer or the errata repin is installed.

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
  - Stream stores two words per token (the seller with the packed fields and a
    terms ID; the item hash) and one shared terms word per artist and economics,
    and derives the royalty receiver. A start under existing terms writes 5 new
    slots, 6 with a bid; a first start under new terms writes the terms word too
    (one word more on a hashed-position collision, an accepted limitation). The
    registry stores one word per consumed item.
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
