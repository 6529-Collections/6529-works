# Glossary

Every protocol term a reader meets in this repository, in alphabetical order. Each definition
follows the code on `main`. The "See" line links where the term is defined (code), decided
(ADR) or specified (spec page). Other pages link a term as `glossary.md#<term>` from `docs/`
and `../glossary.md#<term>` from `docs/spec/`.

> **Status.** Pre-audit. These definitions describe `main` at `c4b3355` (15 October 2026).
> Where an ADR or a module README uses another name or rule, this page follows the code.

Governed delays are named by [delay class](#delay-class): immediate, standard (48 hours), funds
(14 days) and successor (30 days), from [`Roles`](../src/governance/Roles.sol). Shares and rates
are out of 100,000 ([denominator](#denominator)).

[0-9](#0-9) · [A](#a) · [B](#b) · [C](#c) · [D](#d) · [E](#e) · [F](#f) · [G](#g) · [H](#h) ·
[I](#i) · [K](#k) · [L](#l) · [M](#m) · [N](#n) · [O](#o) · [P](#p) · [R](#r) · [S](#s) ·
[T](#t) · [U](#u) · [V](#v) · [W](#w)

## 0-9

### 6529 Editions

The one shared ERC-1155 for editions (`Editions`, `IEditions`). Every [edition](#edition) is
anchored by a 6529 Stream [edition master](#edition-master) and created only from its approved
package item. Primary sales split 75% artist and 25% network at launch
(`EconomicsResolver.DEFAULT_FEE_SHARE`, 25,000).

See: [`Editions.sol`](../src/editions/Editions.sol),
[ADR 0001 §6](adr/0001-v1-scope.md#6-6529-editions),
[editions and sales](spec/editions-and-sales.md).

### 6529 Stream

The one shared, network-curated ERC-721 that holds every curated 1/1 (`Stream`, `IStream`), with
each work's record in the [WorkRecords](#workrecords) satellite. Its works are sold only by
English auction. Primary sales and royalties split 75% artist and 25% network at launch
(`EconomicsResolver.DEFAULT_FEE_SHARE`), and the royalty rate is 6.529%
(`EconomicsResolver.DEFAULT_ROYALTY_RATE`, 6,529).

See: [`Stream.sol`](../src/stream/Stream.sol), [ADR 0001 §4](adr/0001-v1-scope.md#4-stream-token-model),
[stream and auctions](spec/stream-and-auctions.md).

### 6529 Stream Federated

The v1.1 tier, built only if needed: artist-deployed contracts from the network's templates,
registered without curation in a federation registry and sold through the shared
[sale adapters](#sale-adapter) at a 90/10 split (`EconomicsResolver.FEDERATED_FEE_SHARE`,
10,000). v1 ships only `IFederationRegistry`, the `PRODUCT_FEDERATED` economics and the
adapters' federation hooks; no federation registry is installed.

See: [`IFederationRegistry`](../src/interfaces/IFederationRegistry.sol),
[federated README](../src/federated/README.md),
[ADR 0001 §16](adr/0001-v1-scope.md#16-6529-stream-federated).

## A

### acceptance

A party's EIP-712 `PackageAcceptance` signature over a package root
(`Typehashes.PACKAGE_ACCEPTANCE`), relayed by anyone through `PackageRegistry.acceptPackage` and
recorded as `acceptedAs[root][account] = artistId`. The account signs it itself when it has no
[artist ID](#artist-id) yet, which creates the identity; otherwise the
[active authority](#active-authority) of its artist signs. Only that first, identity-creating
acceptance counts as [dormancy](#dormancy) activity.

See: [`IPackageRegistry`](../src/interfaces/IPackageRegistry.sol),
[`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol), [curation](spec/curation.md).

### AccessManager

OpenZeppelin 5.7.0's `AccessManager`, the one governance contract for every v1 contract. Each
governed (`restricted`) selector maps to one [role](#role), and a role's holders carry its
[delay class](#delay-class) as their execution delay. Deployments use the subclass
[WorksAccessManager](#worksaccessmanager); an operation not executed within one week of
becoming ready expires (`expiration()`).

See: [governance README](../src/governance/README.md#role-model),
[ADR 0002](adr/0002-access-manager-hardening.md#decision), [governance](spec/governance.md).

### active authority

The address that may act as an artist now: `IArtistRegistry.activeAuthorityOf(artistId)`. It
equals the [authority](#authority), except that it is zero while a pending
[override](#override) would move the authority (the [restraint](#restraint)). Sale creator
powers, move and acceptance signatures, record amendments and party consents, and ARTIST
statements all read it.

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[ADR 0003 owner decision 6](adr/0003-build-time-decisions.md#owner-decisions-11-october-2026),
[identity and recovery](spec/identity-and-recovery.md).

### admin

A holder of `Roles.ADMIN` (ID 0, OpenZeppelin's `ADMIN_ROLE`), with a 30-day execution delay.
ADMIN administers every role and the manager's own functions, and unmapped selectors fall back to
it. The policy has two: the hot admin Safe and a cold recovery admin Safe that exists to revoke a
compromised hot admin.

See: [`Roles.sol`](../src/governance/Roles.sol),
[ADR 0002 decision 5](adr/0002-access-manager-hardening.md#decision),
[governance](spec/governance.md).

### admitted minter

A sale adapter in a token's admitted-minter mapping (`IMintTarget.isAdmittedMinter`): the only
callers of `mint` on 6529 Stream and 6529 Editions. `setAdmittedMinter` (SUCCESSOR_SETTER,
30 days) checks ERC-165 for `ISaleAdapter` and rejects EIP-7702 delegated accounts. A removed
adapter can still settle and [burn](#burn) the tokens it minted; adapters do not use the
`MINTER` role.

See: [`IMintTarget`](../src/interfaces/IMintTarget.sol),
[ADR 0003 governance](adr/0003-build-time-decisions.md#governance-extends-adr-0002),
[stream and auctions](spec/stream-and-auctions.md).

### allowlist leaf

The Merkle leaf that admits one wallet to a fixed-price [phase](#phase):
`keccak256(bytes.concat(keccak256(abi.encode(ALLOWLIST_LEAF_DOMAIN, chainid, adapter, token, id, phase, account, cap, price))))`,
with `ALLOWLIST_LEAF_DOMAIN = keccak256("6529WORKS_ALLOWLIST_LEAF_V1")`. `account` is the wallet
that receives the copies, or the payer in a payer-keyed phase. Unlike package hashes, a leaf is
bound to one chain and one adapter.

See: [`IFixedPriceSale`](../src/interfaces/IFixedPriceSale.sol),
[sales README](../src/sales/README.md#allowlists), [editions and sales](spec/editions-and-sales.md).

### amendment

A change to a minted work that needs agreement plus a governed action: a
[relicense](#relicense) (every party, PARAMETER_SETTER, 48 hours), a royalty-rate change (every
party, FUNDS_SETTER, 14 days) or an [errata repin](#errata-repin) (the lead artist,
SUCCESSOR_SETTER, 30 days). Each consent is an EIP-712 signature by the signer's
[active authority](#active-authority), bound to the work's [state hash](#state-hash) and a
deadline.

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol),
[ADR 0001 §10](adr/0001-v1-scope.md#10-permanence), [works and storage](spec/works-and-storage.md).

### anti-snipe

The English auction's extension rule: a bid in the last `extensionWindow` seconds moves the end
to `extensionWindow` seconds after that bid (`IEnglishAuction.AuctionConfig`). The window is
governed (PARAMETER_SETTER, 48 hours) between 1 minute and 1 day
(`EnglishAuction.MIN_EXTENSION_WINDOW`, `MAX_EXTENSION_WINDOW`) and at most the duration, and
each auction locks it at its start. The deploy default is 15 minutes (`AUCTION_EXTENSION_WINDOW`
in `script/Deploy.s.sol`).

See: [`IEnglishAuction`](../src/interfaces/IEnglishAuction.sol),
[`Deploy.s.sol`](../script/Deploy.s.sol), [stream and auctions](spec/stream-and-auctions.md).

### artist

Two related meanings. In a package item, a [party](#party) with `PartyRole.ARTIST`, a credited
author; the first party of every item is the [lead artist](#lead-artist). In the artist
registry, an artist identity: an [artist ID](#artist-id) with an [authority](#authority), a
[payout address](#payout-address) and a [profile](#profile).

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol),
[`IdentityTypes.sol`](../src/interfaces/types/IdentityTypes.sol),
[identity and recovery](spec/identity-and-recovery.md).

### artist ID

The permanent number of an artist identity: `uint256(uint160(first authority))`, created by
the identity's first [acceptance](#acceptance). For any account it is `artistIdOf(account)` when
nonzero and `uint256(uint160(account))` otherwise, so tools know every artist ID before any
transaction. It fits in 160 bits and never changes when the authority does.

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[ADR 0003 identity](adr/0003-build-time-decisions.md#identity-and-recovery-amends-adr-0001-11),
[identity and recovery](spec/identity-and-recovery.md).

### artist resolver

The contract the [statement log](#statement-log) asks whether an account may speak as ARTIST
for a subject (`IArtistRoleResolver.isArtist`). In v1 it is the artist registry, which answers
true for the [active authority](#active-authority) of a minted work's lead artist, or of an
edition's master. `setArtistResolver` installs it (SUCCESSOR_SETTER, 30 days, compare-and-set,
code hash pinned and re-checked at every ARTIST append), and every ARTIST entry records it.

See: [`IArtistRoleResolver`](../src/interfaces/IArtistRoleResolver.sol),
[records README](../src/records/README.md#trust-boundary-for-artist-statements),
[disputes and statements](spec/disputes-and-statements.md).

### artist-resolved payee

A split-wallet payee that names an `artistId` (with a zero `account`) and is paid at that
artist's current [payout address](#payout-address) when funds are released. It is pull-only:
only that payout address may release, directly or by [signed release](#signed-release), so a
recovery also redirects balances already accrued.

See: [`ISplitWallet`](../src/economics/interfaces/ISplitWallet.sol),
[economics README](../src/economics/README.md#who-can-release),
[economics and payouts](spec/economics-and-payouts.md).

### asset allowlist

The governed list of payment currencies (`AssetAllowlist`, `IAssetAllowlist`). Each asset is
`None`, `Active` or `Deprecated`, with a per-currency [increment floor](#increment-floor), and
each [product](#product) has a default currency. Admission is FUNDS_SETTER (14 days) and
deprecation GUARDIAN (immediate); a deprecation halts sales and freezes auctions in that currency.

See: [`IAssetAllowlist`](../src/economics/interfaces/IAssetAllowlist.sol),
[economics README](../src/economics/README.md#governance),
[economics and payouts](spec/economics-and-payouts.md).

### attestation

Two different checks. A [curation attestation](#curation-attestation) is a curation signer's
approval of a package root. A [base64 attestation](#base64-attestation) is the content store's
record that a file's stored text is strict base64. Say which.

### authority

The address that signs for an artist identity (`ArtistIdentity.authority`, read with
`authorityOf`). It is never zero, and it identifies the artist even during a
[restraint](#restraint). Every account that has been an authority maps to its artist ID
forever, and a change's new authority must be the current one or an account that has never
been an authority of any artist (`AccountTaken` otherwise).

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[ADR 0003 identity](adr/0003-build-time-decisions.md#identity-and-recovery-amends-adr-0001-11),
[identity and recovery](spec/identity-and-recovery.md).

## B

### base64 attestation

The content store's permanent record that a `Base64` or `GzipBase64` file's stored bytes are
strict RFC 4648 base64 (`attestBase64(fileId)`, read with `isBase64Attested`). Anyone may call
it; one call checks at most 48 chunks (`ContentStore.ATTEST_CHUNKS_PER_CALL`) and the next
resumes where it stopped. The renderer inlines a `Base64` file only once it is attested.

See: [`IContentStore`](../src/interfaces/IContentStore.sol),
[content README](../src/content/README.md#base64-attestation),
[works and storage](spec/works-and-storage.md).

### binding

A one-shot, contract-to-contract caller link, set once at genesis and never changed: for
example `Stream.bindWorkRecords`, `PackageRegistry.bindStream` or
`ArtistRegistry.bindSplitFactory` (each ADMIN, run by the genesis wiring, emitting
`Bound(name, target)`). A bound function trusts only its bound caller, so contract-to-contract
calls use no [role](#role). Each bind rejects EIP-7702 delegated accounts and checks ERC-165
where the target implements it.

See: [governance README](../src/governance/README.md#deploying-and-configuring),
[ADR 0003 governance](adr/0003-build-time-decisions.md#governance-extends-adr-0002),
[governance](spec/governance.md).

### burn

Destroying a token through `IMintTarget.burn`, from the caller's own balance. On 6529 Stream
only the minting adapter may burn, and the auction does so only when an upheld dispute cancels
its sale, before the primary sale settles; the token ID is never reused. On 6529 Editions any
adapter ever admitted may burn copies it holds, and burned copies still count toward the size.

See: [`IMintTarget`](../src/interfaces/IMintTarget.sol),
[ADR 0001 §12](adr/0001-v1-scope.md#12-disputes), [stream and auctions](spec/stream-and-auctions.md).

## C

### canonical payee list

A split wallet's payee list in its one valid order: 1 to 64 payees (`Splits.MAX_PAYEES`), each
either fixed or artist-resolved with a nonzero share, strictly ascending by
`(artistId, account)` (so fixed payees come first, by address), with shares summing to 100,000.
`Splits.validate` enforces it, and a package item's payees must form one in which every payee is
a party.

See: [`Splits.sol`](../src/economics/Splits.sol),
[economics README](../src/economics/README.md#for-sale-adapters),
[economics and payouts](spec/economics-and-payouts.md).

### captured wallet

A wallet captured as a canceller when an identity change is staged: an entry of the artist's
[sticky standing snapshot](#sticky-standing-snapshot) whose `effectiveAt` has passed, including
missing entries within their grace. At most 16 are captured (`Limits.MAX_CANCELLERS`), stored
in `PendingChange.cancellers`. A captured wallet may cancel a
[standard change](#standard-change), and its cancel of an [override](#override) is a
[contest](#contest).

See: [`IdentityTypes.sol`](../src/interfaces/types/IdentityTypes.sol),
[identity README](../src/identity/README.md#recovery-standing-sticky-snapshot),
[identity and recovery](spec/identity-and-recovery.md).

### CC0 text

The CC0 1.0 Universal legal code each deployment uploads to the content store at genesis
(7,048 bytes, `DeployV1.CC0_LEGALCODE_LENGTH`, pinned by SHA-256) and records as `cc0TextFileId`
in WorkRecords and the economics resolver. A license whose [license key](#license-key) is CC0
must name this file, at `openRecord`, at a relicense and as a product default, so a CC0 work
never points at other terms.

See: [`WorkRecords.sol`](../src/stream/WorkRecords.sol), [`DeployV1.sol`](../script/DeployV1.sol),
[works and storage](spec/works-and-storage.md).

### chain head

The rolling hash of one statement-log subject's entries:
`head' = keccak256(abi.encode(HEAD_DOMAIN, head, entryHash))`, starting from zero. The log
stores the count and head per subject (`chainOf`), so an indexer that rebuilds a chain from
events can prove it complete.

See: [`IStatementLog`](../src/interfaces/IStatementLog.sol),
[records README](../src/records/README.md#what-is-stored-what-is-emitted),
[disputes and statements](spec/disputes-and-statements.md).

### chunk

A piece of a content-store file: at most 24,575 bytes (`IContentStore.CHUNK_SIZE`, EIP-170's
limit minus the STOP byte), stored as the code of a CREATE2 contract by [SSTORE2](#sstore2) and
identified by its keccak256. Every chunk of a file except the last is exactly full, and writing
bytes already stored is a no-op.

See: [`ContentStore.sol`](../src/content/ContentStore.sol),
[content README](../src/content/README.md#the-model), [works and storage](spec/works-and-storage.md).

### claim

Taking what an account is owed, by pull: a sale adapter's [credits](#credit) (`claim`, and
`claimFor` on the auction), a [pending delivery](#pending-delivery) (`claimDelivery`), or
split-wallet releases batched by the [claim router](#claim-router). `PackageRegistry.claimContent`
is unrelated: it records an edition's use of its master's content hash.

See: [`ISaleAdapter`](../src/interfaces/ISaleAdapter.sol),
[`IEnglishAuction`](../src/interfaces/IEnglishAuction.sol),
[buying, bidding and settling](integrators/buying-bidding-settling.md).

### claim router

A stateless contract that batches split-wallet releases (`ClaimRouter`): up to 50 plain items
for fixed payees (`MAX_CLAIMS`) or 20 signed items for any payee (`MAX_SIGNED_CLAIMS`),
atomically or in continue mode. It never holds or redirects funds.

See: [`IClaimRouter`](../src/economics/interfaces/IClaimRouter.sol),
[economics README](../src/economics/README.md#batch-claims-and-gas),
[economics and payouts](spec/economics-and-payouts.md).

### collaborator

A [party](#party) with `PartyRole.COLLABORATOR`: a credited contributor to a work. Like every
party, a collaborator must accept the package root before the item can be consumed, and is paid
only if the item also lists it as a payee.

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol), [curation](spec/curation.md).

### collection

A named grouping of 6529 Stream works, possibly by several artists, created by the PLATFORM role
(`IStream.createCollection`) with sequential IDs from 1. Each work has a per-collection
[serial](#serial), and collection IDs stay below 2^32 (`IStream`).

See: [`IStream`](../src/interfaces/IStream.sol), [ADR 0001 §4](adr/0001-v1-scope.md#4-stream-token-model),
[stream and auctions](spec/stream-and-auctions.md).

### compare-and-set

The rule that a governed setter takes the value, or revision counter, it expects to replace and
reverts if it is stale (`ExpectedValueMismatch`, `RevisionMismatch`), so a queued operation never
applies to a state it did not target. Setters for funds, recipients, verifiers, renderers and
sources, the auction parameters and every economics and allowlist setting follow it.

See: [ADR 0001 §13](adr/0001-v1-scope.md#13-governance) (hardening requirement 5),
[governance README](../src/governance/README.md#deploying-and-configuring),
[governance](spec/governance.md).

### configuration epoch

One governance configuration of the AccessManager: genesis is the first, and each later set of
role, selector or delay changes is another. Each epoch publishes the hash of its
[governance manifest](#governance-manifest): genesis in `GovernanceConfigured` and through the
genesis wiring, later epochs as a `GOVERNANCE_MANIFEST` statement
(`appendGovernanceManifest`, SUCCESSOR_SETTER, 30 days) scheduled with the epoch's operations.

See: [`GovernanceConfigurator.sol`](../src/governance/GovernanceConfigurator.sol),
[ADR 0002 decision 6](adr/0002-access-manager-hardening.md#decision),
[governance](spec/governance.md).

### consent

An account's signed agreement. The kinds are a party's package [acceptance](#acceptance); a
party's consent to an [amendment](#amendment); the creator's
[phase configuration](#phase-configuration); a new authority's acceptance of an identity change
or override; and an escrow recovery consent, in which an account that is not a split wallet names
its replacement (`RevenueEscrow.consentToRecovery`).

See: [`Typehashes.sol`](../src/interfaces/types/Typehashes.sol),
[`IRevenueEscrow`](../src/economics/interfaces/IRevenueEscrow.sol).

### consolidation

A two-way link between two wallets in the 6529 [delegation contract](#delegation-contract),
registered for use case 999 and all collections. A wallet is established for an account when,
in each direction, some registration is at least 30 days old (`ConsolidationAdapter.MIN_AGE`)
and unexpired. [Established wallets](#established-wallet) can stage standard changes and gain
[standing](#standing).

See: [`ConsolidationAdapter.sol`](../src/identity/ConsolidationAdapter.sol),
[identity README](../src/identity/README.md#consolidation-standing),
[identity and recovery](spec/identity-and-recovery.md).

### consume

The package registry's single-use check at an auction start (`IPackageRegistry.consume`, callable
only by the bound 6529 Stream from `mint`). It checks the item's Merkle proof under an approved
root, every party's acceptance, the canonical payee list and the [move](#move) signature, then
writes one storage word, Stream's `contentHash => itemHash`, which is both the consume-once
record and the [uniqueness](#uniqueness) record.

See: [`IPackageRegistry`](../src/interfaces/IPackageRegistry.sol),
[curation README](../src/curation/README.md), [curation](spec/curation.md).

### content hash

The decoded SHA-256 of a work's primary media (`PackageItem.contentHash`, equal to the first
media file's `sha256Hash`). It is the per-product [uniqueness](#uniqueness) key, the key of a
work's VRF draw and the `content_hash` the renderer shows. The contracts cannot recompute it, so
the curation signer verifies it against the decoded bytes before attesting.

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol),
[ADR 0003 package format](adr/0003-build-time-decisions.md#package-format-and-curation-amends-adr-0001-3),
[curation](spec/curation.md).

### content manifest

A content-store file's declaration (`registerManifest`): the ordered chunk hashes, the stored
length, the [encoding](#encoding), the MIME type and the SHA-256 of the decoded media. It can be
registered before, during or after its chunks are uploaded, and its hash is the
[file ID](#file-id).

See: [`IContentStore`](../src/interfaces/IContentStore.sol),
[content README](../src/content/README.md#the-model), [storage](integrators/storage.md).

### content release

The governed step after an upheld dispute burned a work during its auction:
`IStream.releaseContent(tokenId, contentHash, beneficiary)` (PARAMETER_SETTER, 48 hours) passes
the burned work's item hash to `PackageRegistry.releaseContent`. The content hash is then
reserved for items whose lead artist is the registered `beneficiary` (`releasedTo`), and the
burned item is [tombstoned](#tombstone). A release happens once per burned work.

See: [`IStream`](../src/interfaces/IStream.sol),
[`IPackageRegistry`](../src/interfaces/IPackageRegistry.sol),
[disputes and statements](spec/disputes-and-statements.md).

### content store

The permissionless, content-addressed file store every v1 contract shares (`ContentStore`,
`IContentStore`): files of 1 to 512 [chunks](#chunk) (`MAX_CHUNKS`), each described by a
[content manifest](#content-manifest) and read by verified range reads. It has no owner, no
governance and no payable function, and on-chain bytes are permanent.

See: [`IContentStore`](../src/interfaces/IContentStore.sol),
[content README](../src/content/README.md#content-store-and-dependency-registry),
[storage](integrators/storage.md).

### contest

A [captured wallet](#captured-wallet)'s `cancelChange` on a pending [override](#override) during
its 180-day notice. The override is not deleted: it becomes contested (`ChangeContested`) and
waits for a TDH vote, recorded as a DISPUTE_OUTCOME statement on `(registry, artistId)` and
applied by `resolveContested` (SUCCESSOR_SETTER, 30 days): uphold executes it, void deletes it. A
contest nobody resolves lapses after 365 days (`ArtistRegistry.CONTEST_TIMEOUT`).

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[ADR 0003 owner decision 1](adr/0003-build-time-decisions.md#owner-decisions-11-october-2026),
[identity and recovery](spec/identity-and-recovery.md).

### copy

One unit of an edition's ERC-1155 supply on 6529 Editions. Copies are minted only by admitted
fixed-price or Dutch adapters, at the price, currency and size the package fixed. Burned copies
still count toward the size, and a copy never gets its own seed.

See: [`IEditions`](../src/interfaces/IEditions.sol),
[editions README](../src/editions/README.md), [editions and sales](spec/editions-and-sales.md).

### core

6529 Stream's ERC-721 contract (`Stream.sol`), as distinct from its records
[satellite](#satellite). It holds ownership, collections and serials, the terms locked at mint,
the edition link and `royaltyInfo`, and forwards `tokenURI` to the work's renderer.

See: [`IStream`](../src/interfaces/IStream.sol), [stream README](../src/stream/README.md#core-token).

### core-only metadata

What the renderer returns, without reverting, for a work whose record is not usable (see
[record status](#record-status)). It carries only what 6529 Stream knows: a name from the
collection and serial (`Spring #12`), the artist ID, collection, serial, edition, seed and
dispute traits, the description "The work record is not available." and a `record_status` field.

See: [`IRenderer`](../src/interfaces/IRenderer.sol),
[content README](../src/content/README.md#what-it-reads-and-how-it-fails),
[rendering and tokenURI](spec/rendering-and-tokenuri.md).

### creator

The `creator` in a token's [PrimaryTerms](#primaryterms): the lead artist's
[active authority](#active-authority), resolved through the artist registry each time the terms
are read. It receives an auction token that drew no bids, may open and close edition sales and
signs [phase configurations](#phase-configuration). It is zero during a [restraint](#restraint).

See: [`SaleTypes.sol`](../src/interfaces/types/SaleTypes.sol),
[sales README](../src/sales/README.md#opening-a-sale), [editions and sales](spec/editions-and-sales.md).

### credit

An amount owed to an account and claimable by pull. A sale adapter credits outbid and withdrawn
bids, ETH overpayments and, on the auction, ERC-20 payouts that failed even through the escrow
(`Credited`, `claimable`). The [escrow](#escrow) credits wallets whose payment failed (`owed`).

See: [`ISaleAdapter`](../src/interfaces/ISaleAdapter.sol),
[`IRevenueEscrow`](../src/economics/interfaces/IRevenueEscrow.sol),
[buying, bidding and settling](integrators/buying-bidding-settling.md).

### curation attestation

The proof that a curation signer approved a package root: `abi.encode(signer, signature)`, the
signature being an EIP-712 `PackageApproval(packageRoot, evidenceHash, signerEpoch)` in the v1
verifier's domain. `PackageRegistry.registerPackage` asks the verifier, which returns the signer
only if it is active and the signature binds its current [signer epoch](#signer-epoch).

See: [`ICurationVerifier`](../src/interfaces/ICurationVerifier.sol),
[curation README](../src/curation/README.md), [curation](spec/curation.md).

### curation evidence

The published record behind an approval. Its hash, the [evidence hash](#evidence-hash), is signed
with the root and emitted by `registerPackage`, and the CURATOR role appends the matching
`CURATION_EVIDENCE` statement (subject `(address(0), uint256(packageRoot))`), a kind reserved to
CURATOR.

See: [`IPackageRegistry`](../src/interfaces/IPackageRegistry.sol),
[`StatementKinds.sol`](../src/interfaces/types/StatementKinds.sol), [curation](spec/curation.md).

### curation signer

A key holding `Roles.CURATION_SIGNER` (ID 4) whose approvals the v1 verifier
(`Eip712CurationVerifier`) accepts while the role has no execution delay and the guardian has not
disabled the key. It only signs and never calls a contract. Before attesting it must, off-chain,
verify every declared SHA-256 and simulate `openRecord`; the contracts cannot check this.

See: [`ICurationVerifier`](../src/interfaces/ICurationVerifier.sol),
[curation README](../src/curation/README.md), [curation](spec/curation.md).

### curator

The holder of `Roles.CURATOR` (ID 12), the curation team's key, with zero execution delay. It
appends curator statements through `StatementLog.appendCurator`, including `CURATION_EVIDENCE`.
It does not approve packages: that is the [curation signer](#curation-signer)'s attestation.

See: [`Roles.sol`](../src/governance/Roles.sol), [records README](../src/records/README.md#who-may-write).

### currency

The asset a sale is paid in: ETH as `CURRENCY_ETH` (`address(0)`) or an ERC-20 active on the
[asset allowlist](#asset-allowlist). Package terms may also say
[CURRENCY_DEFAULT](#currency_default). Every sale locks its resolved currency when it starts or
opens; each product's default currency is a governed setting (FUNDS_SETTER, 14 days), set to ETH
at genesis.

See: [`EconomicsTypes.sol`](../src/interfaces/types/EconomicsTypes.sol),
[ADR 0001 §5](adr/0001-v1-scope.md#5-sales-and-auctions),
[economics and payouts](spec/economics-and-payouts.md).

### CURRENCY_DEFAULT

The currency value `address(type(uint160).max)` that means "the product's default currency when
the sale starts". It is valid only in package sale and edition terms, and only with a zero price
(a priced sale must name its currency). `IEconomicsResolver.resolveCurrency` resolves it; it is
never a sale's locked currency.

See: [`EconomicsTypes.sol`](../src/interfaces/types/EconomicsTypes.sol),
[`IEconomicsResolver`](../src/interfaces/IEconomicsResolver.sol),
[economics and payouts](spec/economics-and-payouts.md).

## D

### delay class

The four delays governed actions wait. Each is a role whose holders carry it as their execution
delay (`Roles.sol`):

| Class | Delay | Constant | Covers |
| --- | --- | --- | --- |
| immediate | none | `Roles.IMMEDIATE` | Tightening actions and pauses |
| standard | 48 hours | `Roles.STANDARD` | Sale parameters, defaults for new works, dispute outcomes |
| funds | 14 days | `Roles.FUNDS` | Funds and network-level recipients |
| successor | 30 days | `Roles.SUCCESSOR` | Verifier, renderer and successor swaps, one-way freezes, meta-governance |

See: [`Roles.sol`](../src/governance/Roles.sol),
[ADR 0001 §13](adr/0001-v1-scope.md#13-governance), [governance](spec/governance.md).

### delegation contract

The 6529 delegation contract (`0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d` on mainnet), whose
use case 999 registrations are the [consolidations](#consolidation) the artist registry reads
through `ConsolidationAdapter`. Use case 998 sub-delegates can write an account's delegations;
use case 997 (primary address) is never used as a payout.

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[identity README](../src/identity/README.md#consolidation-standing),
[addresses](integrators/addresses.md).

### denominator

The 100,000 parts every share and rate is out of (`Splits.DENOMINATOR`), so the 6.529% royalty
is exactly 6,529. Fee shares, payee shares, royalty rates and the auction's increment share all
use it.

See: [`Splits.sol`](../src/economics/Splits.sol), [ADR 0001 §7](adr/0001-v1-scope.md#7-economics).

### dependency registry

The governed map from `(name, version)` labels to content-store files for shared libraries such
as p5.js and three.js (`DependencyRegistry`, `IDependencyRegistry`). A version must be on-chain
complete to register and can never change or be removed. `register` maps to PARAMETER_SETTER
(48 hours) and the one-way `deprecate` flag to GUARDIAN (immediate) in
`config/genesis.example.json`.

See: [`IDependencyRegistry`](../src/interfaces/IDependencyRegistry.sol),
[content README](../src/content/README.md#dependencyregistry),
[`genesis.example.json`](../config/genesis.example.json).

### dispute

A claim against a work, filed with evidence in the 6529 disputes [wave](#wave) and decided by
TDH vote off-chain. During an auction the guardian may [pause](#dispute-pause) it; an upheld
dispute cancels the auction (PARAMETER_SETTER, 48 hours, citing the
[dispute outcome](#dispute-outcome)), credits the bid back and burns the token. After a sale a
dispute only produces a statement: nothing is confiscated.

See: [`IEnglishAuction`](../src/interfaces/IEnglishAuction.sol),
[ADR 0001 §12](adr/0001-v1-scope.md#12-disputes),
[disputes and statements](spec/disputes-and-statements.md).

### dispute outcome

A `DISPUTE_OUTCOME` statement, a kind reserved to the PLATFORM role, that records a dispute
vote's result about a subject. The log keeps each subject's latest one: `latestDisputeOutcome`
answers with a fallback from a Stream token to its package item, `disputeOutcomeOf` without it.
The renderer shows it, and an auction `cancel` and `resolveContested` must cite it.

See: [`IStatementLog`](../src/interfaces/IStatementLog.sol),
[records README](../src/records/README.md#what-is-stored-what-is-emitted),
[disputes and statements](spec/disputes-and-statements.md).

### dispute pause

The guardian's pause of a live English auction (`IEnglishAuction.pause`, GUARDIAN, immediate):
one pause per auction, lasting at most 7 days (`EnglishAuction.MAX_PAUSE`), during which the
high bidder may withdraw. It ends by `resume` (UNPAUSER, no earlier than 48 hours after the
pause), by an upheld `cancel`, or by itself after 7 days; the resumed auction runs at least the
governed duration.

See: [`IEnglishAuction`](../src/interfaces/IEnglishAuction.sol),
[ADR 0003 disputes](adr/0003-build-time-decisions.md#disputes-and-statements-amends-adr-0001-12),
[stream and auctions](spec/stream-and-auctions.md).

### dormancy

A year without the artist's own signed activity (`ArtistRegistry.DORMANCY`, 365 days), required
before an ESTATE or LOST_KEY [override](#override) can be staged. Activity is registration, a
staged change, a [heartbeat](#heartbeat), a cancel by the old key or a captured wallet, a nonce
revocation or an executed change; overrides, vetoes and standing refreshes never count.

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[identity README](../src/identity/README.md#who-may-call-what),
[identity and recovery](spec/identity-and-recovery.md).

## E

### economics resolver

The governed source of each [product](#product)'s economics (`EconomicsResolver`,
`IEconomicsResolver`): the network fee recipient and fee share, the royalty rate and default
license for new works, the terms a work locks at mint (`newWorkTerms`) and the currency a sale
must lock (`resolveCurrency`). Changes apply only to works minted and sales started afterwards.

See: [`IEconomicsResolver`](../src/interfaces/IEconomicsResolver.sol),
[economics README](../src/economics/README.md#new-work-terms),
[economics and payouts](spec/economics-and-payouts.md).

### edition

A 6529 Editions token ID anchored by one [edition master](#edition-master); the edition ID
equals the master's Stream token ID. Anyone creates it with `createEdition` once the master's
primary sale has settled, which locks the `PRODUCT_EDITIONS` economics and links both
directions. It renders its master's media and record and carries its master's license.

See: [`IEditions`](../src/interfaces/IEditions.sol), [editions README](../src/editions/README.md),
[editions and sales](spec/editions-and-sales.md).

### edition format

Whether an edition has a fixed size or an open window (`EditionFormat`). FIXED sells at most
`size` copies with no time limit. OPEN sells for `window` seconds from its first mint, capped at
`size` when nonzero; because that window starts only once, any sale of an OPEN edition needs the
artist's approval.

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol),
[editions and sales](spec/editions-and-sales.md).

### edition master

A 6529 Stream work of kind `EDITION_MASTER`: a 1/1 auctioned like any work that also anchors
exactly one [edition](#edition), created from the same package item after its sale settles. A
master with an edition has settled and is never burned. Also called the master.

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol),
[ADR 0001 §6](adr/0001-v1-scope.md#6-6529-editions), [editions and sales](spec/editions-and-sales.md).

### EIP-170

Ethereum's 24,576-byte limit on deployed contract code. It sets the content-store
[chunk](#chunk) size (24,575 bytes, `SSTORE2.MAX_CHUNK_LENGTH`), and it is why 6529 Stream keeps
records in the WorkRecords satellite.

See: [`SSTORE2.sol`](../src/libraries/SSTORE2.sol),
[ADR 0003 token model](adr/0003-build-time-decisions.md#token-model-and-storage-amends-adr-0001-4-and-8).

### EIP-712

The standard for signing typed structured data. Every artist, party, curation, consent, release
and relayed-statement signature in the protocol is EIP-712, in its contract's domain
`(name, "1", chainid, contract)`. `Typehashes` holds most names and type hashes; the statement
log and the release verifier define their own.

See: [`Typehashes.sol`](../src/interfaces/types/Typehashes.sol),
[ABIs and interface IDs](integrators/abis-and-interface-ids.md).

### EIP-2612

ERC-20 `permit`: an approval signed off-chain. A `PERMIT` payment carries a 65-byte permit for
the amount, then the adapter pulls the tokens; the payer must be `msg.sender`.

See: [`SaleTypes.sol`](../src/interfaces/types/SaleTypes.sol),
[sales README](../src/sales/README.md#payments).

### EIP-7702

Ethereum's mechanism for an EOA to delegate its code to a contract, leaving the 23-byte
designator `0xef0100 || delegate` as its code. Every install and binding rejects delegated
accounts (`DelegatedEOA.isDelegated`), and the shared `SignatureVerifier` checks a delegated EOA
by `ecrecover` first, then by ERC-1271.

See: [`DelegatedEOA.sol`](../src/libraries/DelegatedEOA.sol),
[`SignatureVerifier.sol`](../src/libraries/SignatureVerifier.sol).

### EIP-7825

The per-transaction gas cap of 16,777,216 (2^24) that the Fusaka upgrade introduced. `Limits` and
the other bounds keep every worst-case transaction under it in [Prague gas](#prague-gas); ADR 0004
records that Sepolia, under Glamsterdam, applied it to regular gas only.

See: [`Limits.sol`](../src/interfaces/types/Limits.sol),
[ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#decision).

### encoding

How a content-store file's stored bytes relate to its media (`IContentStore.Encoding`), part of
its file ID: `Identity` (the media), `Gzip`, `Base64` (RFC 4648 text) or `GzipBase64`. A record
must be `Identity`, media meant to be inlined should be `Base64`, and gzip files are never
inlined.

See: [`IContentStore`](../src/interfaces/IContentStore.sol),
[content README](../src/content/README.md#the-model), [storage](integrators/storage.md).

### entropy module

The optional contract that supplies VRF seeds (`VrfEntropyModule`, `IEntropyModule`), outside
Stream's mint path. Anyone may request the seed of an approved, unconsumed VRF item's content,
one draw per content hash; the first delivery is final, and an undelivered request may be
repeated after the retry delay (3 to 30 days, `MIN_RETRY_DELAY`, `MAX_RETRY_DELAY`).

See: [`IEntropyModule`](../src/interfaces/IEntropyModule.sol),
[entropy README](../src/entropy/README.md#flow-decision-d4), [entropy](spec/entropy.md).

### entry hash

The identity of one statement-log entry, which other entries cite: keccak256 over the entry
domain, chain ID, log address, subject key, index, role, signer, resolver, recording time and
the EIP-712 hash of the statement. The index makes identical statements appended twice distinct.

See: [`StatementLog.sol`](../src/records/StatementLog.sol),
[records README](../src/records/README.md#what-is-stored-what-is-emitted),
[events and indexing](integrators/events-and-indexing.md).

### epoch

Two unrelated counters: a governance [configuration epoch](#configuration-epoch), or a curation
[signer epoch](#signer-epoch). Say which.

### ERC-20

The fungible-token standard. The protocol admits only standard ERC-20s (a value returned on
transfer, no fee on transfer, no rebase) through the asset allowlist, and checks every movement
by exact balance delta (`TokenTransfer`), so fee-on-transfer, rebasing and non-returning tokens
revert.

See: [`TokenTransfer.sol`](../src/economics/TokenTransfer.sol),
[ADR 0001 §5](adr/0001-v1-scope.md#5-sales-and-auctions).

### ERC-165

Interface detection (`supportsInterface`). Installs and most bindings require the target to
answer ERC-165 for its interface, and `ProtocolContracts` uses it to recognize the protocol
contracts that can be neither a payout address nor a fee recipient.

See: [`ProtocolContracts.sol`](../src/libraries/ProtocolContracts.sol),
[ABIs and interface IDs](integrators/abis-and-interface-ids.md).

### ERC-721

The NFT standard 6529 Stream implements (OpenZeppelin `ERC721`); each token is one 1/1 work.

See: [`Stream.sol`](../src/stream/Stream.sol).

### ERC-1155

The multi-token standard 6529 Editions implements: each ID is one edition and each unit one
[copy](#copy). An OWNER statement about an edition may come from any holder.

See: [`Editions.sol`](../src/editions/Editions.sol).

### ERC-1271

Signature validation for contract accounts (`isValidSignature`). The shared `SignatureVerifier`
accepts it for every protocol signature, forwarding a fixed 200,000 gas
(`SignatureVerifier.ERC1271_GAS_LIMIT`) and requiring exactly the magic value in 32 bytes of
return data.

See: [`SignatureVerifier.sol`](../src/libraries/SignatureVerifier.sol).

### ERC-2098

The 64-byte compact form of an ECDSA signature. `SignatureVerifier` accepts it beside the
65-byte form, so no replay protection keys on signature bytes.

See: [`SignatureVerifier.sol`](../src/libraries/SignatureVerifier.sol).

### ERC-2981

The NFT royalty standard (`royaltyInfo`), implemented by 6529 Stream and 6529 Editions: the
amount is `floor(price × rate / 100,000)`. Stream derives the receiver, the
[royalty wallet](#royalty-wallet), in one view call, and reverts rather than return zero when
gas is short.

See: [`IStream`](../src/interfaces/IStream.sol), [stream README](../src/stream/README.md#core-token).

### ERC-4906

Metadata update events (`MetadataUpdate`, `BatchMetadataUpdate`). 6529 Stream emits them when
WorkRecords asks (`emitMetadataUpdate`); 6529 Editions re-emits them for an edition when its
master changes (`notifyMasterUpdated`) and for every edition after a global or collection
preferred-location change or a new default renderer (`notifyAllUpdated`).

See: [`IEditions`](../src/interfaces/IEditions.sol),
[events and indexing](integrators/events-and-indexing.md).

### ERC-7572

Contract-level metadata (`contractURI`, `ContractURIUpdated`) on 6529 Stream and 6529 Editions;
`setContractURI` is PARAMETER_SETTER (48 hours).

See: [`IStream`](../src/interfaces/IStream.sol), [`IEditions`](../src/interfaces/IEditions.sol).

### errata repin

The only way to change a finalized work's renderer: `WorkRecords.repinRenderer`
(SUCCESSOR_SETTER, 30 days) with the lead artist's EIP-712 `RendererRepin` signature, which binds
the new renderer's code hash. It also restores a finalized work's metadata after its pinned
renderer's code changed.

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol),
[ADR 0001 §10](adr/0001-v1-scope.md#10-permanence),
[rendering and tokenURI](spec/rendering-and-tokenuri.md).

### escrow

The revenue escrow (`RevenueEscrow`): it credits a wallet whose payment failed, keyed by
`(wallet, asset)`, and anyone may flush a credit to its wallet. Governed `recover`
(FUNDS_SETTER, 14 days) moves a split wallet's credit only to an equivalent replacement wallet,
and any other account's credit only to the replacement that account named
(`consentToRecovery`).

See: [`IRevenueEscrow`](../src/economics/interfaces/IRevenueEscrow.sol),
[economics README](../src/economics/README.md#escrow-recovery),
[economics and payouts](spec/economics-and-payouts.md).

### established wallet

A wallet consolidated with an account in both directions, with some registration in each
direction at least 30 days old and unexpired (`IConsolidationSource.isEstablished`). An
established wallet may stage a [standard change](#standard-change) and send a
[heartbeat](#heartbeat), and gains [standing](#standing) once a refresh records it.

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[identity README](../src/identity/README.md#consolidation-standing).

### evidence hash

The hash a curation signer signs with a package root. It commits to the published vote snapshot,
TDH snapshot and rule parameters, and to the signer's check of every declared SHA-256; the
registry stores and emits it (`packageOf`, `PackageRegistered`). An [override](#override) also
carries an evidence hash committing to its public record.

See: [`ICurationVerifier`](../src/interfaces/ICurationVerifier.sol),
[ADR 0001 §3](adr/0001-v1-scope.md#3-curation-and-approved-packages), [curation](spec/curation.md).

## F

### file ID

A content-store file's name:
`keccak256(abi.encode(chunkHashes, length, encoding, mimeType, sha256Hash))`
(`IContentStore.manifestId`). It is chain- and deployment-independent and names one exact
encoded stream forever. It is not a uniqueness key: the same media in two encodings has two file
IDs.

See: [`IContentStore`](../src/interfaces/IContentStore.sol),
[content README](../src/content/README.md#the-model), [storage](integrators/storage.md).

### file role

A media file's role in a work (`FileRole`): PRIMARY, the artwork, exactly one and first;
PREVIEW, a small still image, which `openRecord` caps at 16 KiB stored for a Stream work
(`Limits.MAX_PREVIEW_BYTES`, an `Identity` file counting four times); or AUXILIARY, everything
else the work loads.

See: [`ContentTypes.sol`](../src/interfaces/types/ContentTypes.sol),
[content README](../src/content/README.md#media).

### finalize

The lead artist's `WorkRecords.finalize(tokenId, expectedStateHash)`. It requires the record
file to meet the structural bounds (registered, `Identity`, one chunk) and be complete, and the
license text to be complete on-chain, then makes the
record immutable and [pins](#pin) Stream's current default renderer. Locators may still be added
afterwards, by PLATFORM only.

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol),
[ADR 0001 §10](adr/0001-v1-scope.md#10-permanence), [works and storage](spec/works-and-storage.md).

### finding ID

An identifier such as MARKET-2 or IDENTITY-1 that names a finding of the internal adversarial
review; the prefix names the area (for example SIGS, DEPS, LIFECYCLE, MARKET, IDENTITY, CONTENT,
CALLS, MONEY, GOV). ADRs, READMEs and code comments cite findings by ID.

See: [ADR 0003](adr/0003-build-time-decisions.md), [known limitations](audit/known-limitations.md).

### fixed payee

A split-wallet payee that names an `account` (with `artistId` zero). Anyone may release its share,
which can go only to that account; the account itself may `releaseTo` another recipient or sign a
release. The network fee recipient is a fixed payee of every royalty wallet with a fee.

See: [`ISplitWallet`](../src/economics/interfaces/ISplitWallet.sol),
[economics README](../src/economics/README.md#who-can-release).

### fullTokenURI

`IRenderer.fullTokenURI(token, id)`: the metadata with media inlined up to 1 MiB cost-weighted
(`Renderer.MAX_INLINE_BYTES`, an `Identity` byte counting eight times), meant for `eth_call`. It
has no 8M-gas promise and reverts (`RendererNotInlineable`) instead of falling back to a locator.

See: [`IRenderer`](../src/interfaces/IRenderer.sol), [content README](../src/content/README.md#media),
[rendering and tokenURI](spec/rendering-and-tokenuri.md).

## G

### genesis

The one-transaction setup of a deployment's governance:
`GovernanceConfigurator.configure(cfg, manifestHash, wiring)` installs every role, delay and
selector on its own WorksAccessManager, runs the genesis wiring (bindings, minter admissions,
sale targets, first default currencies and the epoch-0 manifest; at most 64 calls,
`GovernanceConfig.MAX_WIRING_CALLS`), renounces ADMIN and emits `GovernanceConfigured`.
`config/genesis.example.json` is the committed example.

See: [governance README](../src/governance/README.md#deploying-and-configuring),
[`genesis.example.json`](../config/genesis.example.json), [governance](spec/governance.md).

### gift

A zero-price edition sale: a package price of zero, or an artist-approved leaf price of zero. A
gift pays no network fee.

See: [sales README](../src/sales/README.md#allowlists), [editions and sales](spec/editions-and-sales.md).

### Glamsterdam

The Ethereum network upgrade (EVM version Amsterdam) that Sepolia activated on 6 October 2026. It
reprices state creation: on Sepolia a new storage slot costs about 111,000 gas against 22,100
under Prague (ADR 0004). Foundry 1.7.1 cannot measure it, so the gas budgets are in
[Prague gas](#prague-gas).

See: [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#problem).

### governance manifest

The signed JSON document that describes one [configuration epoch](#configuration-epoch): its
roles, holders, selectors and delays. Only its hash is on-chain: in `GovernanceConfigured` at
genesis, and as a `GOVERNANCE_MANIFEST` statement, written only by `appendGovernanceManifest`
with the AccessManager as signer and the subject `(manager, 0)`.

See: [`IStatementLog`](../src/interfaces/IStatementLog.sol),
[ADR 0002 decision 6](adr/0002-access-manager-hardening.md#decision), [governance](spec/governance.md).

### guardian

A holder of `Roles.GUARDIAN` (ID 1): a guardian Safe that holds only GUARDIAN and PAUSER, at
least two by the code and three at deployment. Guardians cancel scheduled operations (never their
own removal) and act at once to pause, veto, revoke, disable and deprecate. They can block, never
redirect.

See: [`Roles.sol`](../src/governance/Roles.sol),
[governance README](../src/governance/README.md#how-the-guardians-cancel-the-admin),
[trust assumptions](audit/trust-assumptions.md).

## H

### heartbeat

`ArtistRegistry.heartbeat(artistId)`, called by the authority or an established wallet. It
records signed activity, which resets the [dormancy](#dormancy) clock, and refreshes the standing
snapshot. It is never on the auction-start path.

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[identity and recovery](spec/identity-and-recovery.md).

## I

### increment floor

A currency's absolute minimum bid increment (`IAssetAllowlist.incrementFloor`), set at
admission and changed by PARAMETER_SETTER (48 hours); the ETH deploy default is 0.001 ETH
(`ETH_INCREMENT_FLOOR` in `script/Deploy.s.sol`). An auction locks it at its first bid, and each
later bid must beat the high bid by the larger of the floor and the increment share (5% by
default).

See: [`IEnglishAuction`](../src/interfaces/IEnglishAuction.sol),
[`Deploy.s.sol`](../script/Deploy.s.sol), [stream and auctions](spec/stream-and-auctions.md).

### inline threshold

The largest primary file `tokenURI` inlines, in cost-weighted stored bytes
(`IRenderer.inlineThreshold()`, fixed at deployment; `Renderer.DEFAULT_INLINE_THRESHOLD` is
262,144, 256 KiB). An `Identity` byte counts eight times, because the renderer must
base64-encode it, so a `Base64` file inlines up to 256 KiB and an `Identity` file up to 32 KiB.
Only on-chain complete works inline their primary file.

See: [`IRenderer`](../src/interfaces/IRenderer.sol), [content README](../src/content/README.md#media),
[rendering and tokenURI](spec/rendering-and-tokenuri.md).

### item

One entry of a [package](#package) (`PackageItem`): everything voters approve and every party
signs for one work. That is its kind, collection, content hash, media hash, record file ID,
parties, payees, license, seed policy and seed, sale terms and edition terms. An item mints at
most once.

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol),
[ADR 0001 §3](adr/0001-v1-scope.md#3-curation-and-approved-packages), [curation](spec/curation.md).

### item hash

`keccak256(abi.encode(PACKAGE_ITEM_DOMAIN, item))` (`WorksHashing.itemHash`), an item's
identity. No chain ID or address enters it, so it is the same on every chain. 6529 Stream stores
it per token, and the statement log uses `(address(0), uint256(itemHash))` as the subject of an
item before its mint.

See: [`WorksHashing.sol`](../src/interfaces/types/WorksHashing.sol),
[architecture](architecture.md#identifiers-and-hashes), [curation](spec/curation.md).

### item kind

What an item mints (`ItemKind`): ORIGINAL, a 1/1, or EDITION_MASTER, a 1/1 that also anchors one
edition.

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol).

## K

### keeper

An automated account that calls permissionless upkeep, such as `refreshStanding`, escrow `flush`
or claim-router batches. `Roles.KEEPER` (ID 7) exists, but no v1 selector maps to it
(`config/genesis.example.json`).

See: [`Roles.sol`](../src/governance/Roles.sol), [`genesis.example.json`](../config/genesis.example.json).

## L

### lead artist

The first party of every item, always `PartyRole.ARTIST`. Its artist's
[active authority](#active-authority) signs the [move](#move), edits the record, finalizes,
signs errata repins and acts as the sale [creator](#creator); 6529 Stream stores its artist ID
per token (`artistOf`).

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol),
[`IStream`](../src/interfaces/IStream.sol).

### license

A work's license (`License`): an SPDX identifier or `LicenseRef-` expression in its original
case, from `[A-Za-z0-9.+-]`, at most 64 bytes (`Limits.MAX_LICENSE_ID_BYTES`), plus the
content-store file ID of the full text. 6529 Stream and 6529 Editions default to CC0
(`EconomicsResolver.CC0`, `CC0-1.0`), and an edition carries its master's license.

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol),
[ADR 0001 §8](adr/0001-v1-scope.md#8-works-content-and-storage),
[works and storage](spec/works-and-storage.md).

### license key

`keccak256` of the ASCII-lowercased SPDX ID (`WorksHashing.licenseKey`); CC0's is
`keccak256("cc0-1.0")` (`WorksHashing.CC0_LICENSE_KEY`). Licenses are compared, and CC0
irrevocability is enforced, on this key, while the ID keeps its case for display.

See: [`WorksHashing.sol`](../src/interfaces/types/WorksHashing.sol),
[ADR 0003 token model](adr/0003-build-time-decisions.md#token-model-and-storage-amends-adr-0001-4-and-8).

### locator

A registered copy of a media file (`Locator`): ARWEAVE, `ar://` plus a 43-character transaction
ID, or IPFS, `ipfs://` plus a base32 CIDv1 of the fixed profile, with nothing after it.
Locators are append-only, at most 16 per file (`Limits.MAX_LOCATORS_PER_FILE`): before
finalize 8 from the artist and 8 from the platform. ONCHAIN is the implicit copy of an on-chain
complete work, and NONE means no copy.

See: [`ContentTypes.sol`](../src/interfaces/types/ContentTypes.sol),
[stream README](../src/stream/README.md#records-satellite), [storage](integrators/storage.md).

### LockedTerms

The terms a sale adapter locks for one sale (`LockedTerms`): token, ID, currency, price,
seller, fee recipient and fee share. The fixed-price and Dutch adapters store them when the sale
opens; the auction locks the currency at start and reads the seller and fee terms back from the
token at settlement.

See: [`SaleTypes.sol`](../src/interfaces/types/SaleTypes.sol),
[sales README](../src/sales/README.md#opening-a-sale), [editions and sales](spec/editions-and-sales.md).

## M

### manifest

Two unrelated documents: a content-store [content manifest](#content-manifest), or a
[governance manifest](#governance-manifest). Say which.

### marketplace owner

The address `owner()` returns on 6529 Stream and 6529 Editions, held by 6529 so marketplaces let
it configure creator earnings; it has no on-chain powers. `setOwner` is FUNDS_SETTER (14 days),
compare-and-set.

See: [`IStream`](../src/interfaces/IStream.sol), [`IEditions`](../src/interfaces/IEditions.sol).

### master

See [edition master](#edition-master).

### media hash

`keccak256(abi.encode(MEDIA_DOMAIN, media))` (`WorksHashing.mediaHash`) over a work's ordered
media list: each file's ID, decoded SHA-256 and role, primary first. A package item commits to
it, so media is fixed at approval, and `openRecord` checks the list against it.

See: [`WorksHashing.sol`](../src/interfaces/types/WorksHashing.sol),
[works and storage](spec/works-and-storage.md).

### minSetback

OpenZeppelin AccessManager's minimum delay before a grant-delay or target-admin-delay change takes
effect: 5 days (`minSetback()`). The delays genesis installs become effective only then, so
deployment readback (`GovernanceConfigurator.verify`) runs at least that long after `configure`.

See: [governance README](../src/governance/README.md#deploying-and-configuring),
[governance](spec/governance.md).

### move

The lead artist's revocable "move to Stream" authorization: an EIP-712
`MoveToStream(packageRoot, itemHash, nonce, deadline)` signature by its active authority in the
package registry's domain, checked at [consume](#consume). The nonce is single-use per artist, in
a bitmap of 255 per word; `revokeMove` revokes an unused one.

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol),
[curation README](../src/curation/README.md), [curation](spec/curation.md).

## N

### network fee

The network's share of a primary sale or a royalty: `floor(total × feeShare / 100,000)` paid to
the product's network fee recipient, with the rest to the seller wallet. `setFeeTerms`
(FUNDS_SETTER, 14 days) sets fee share and recipient per product, and each work locks them at
mint; the launch shares are 25,000 for Stream and Editions and 10,000 for Federated
(`EconomicsResolver.DEFAULT_FEE_SHARE`, `FEDERATED_FEE_SHARE`).

See: [`IEconomicsResolver`](../src/interfaces/IEconomicsResolver.sol),
[sales README](../src/sales/README.md#payouts), [economics and payouts](spec/economics-and-payouts.md).

### new account

In the gas reports, an account that is empty before a transaction (no code, nonce zero, balance
zero) and not empty after it: a contract creation, or ETH sent to an empty address. ADR 0004
counts them per operation because Glamsterdam prices each at about 184,000 more gas on Sepolia.

See: [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#decision),
[`GasReport.t.sol`](../test/integration/GasReport.t.sol).

### new slot

A storage slot that is zero before a transaction and nonzero after it, counted once however often
it is written, and not counted if a revert undid the write. CI asserts each measured operation's
exact count; a steady-state ETH `start` may create at most 6 and `startWithBid` 7 (ADR 0004).

See: [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#the-table),
[`GasReport.t.sol`](../test/integration/GasReport.t.sol).

### nonce

A single-use counter, revocable before use. The protocol keeps several: an artist's move nonces
(`revokeMove`), an identity's change nonce (`ArtistRegistry.revokeNonce`), a creator's
phase-configuration nonces (`revokeConsentNonce`), a payee's release nonces
(`ReleaseVerifier.revokeNonce`) and a signer's statement relay nonces (`StatementLog.revokeNonce`).
No replay protection keys on signature bytes.

See: [`Typehashes.sol`](../src/interfaces/types/Typehashes.sol),
[`SignatureVerifier.sol`](../src/libraries/SignatureVerifier.sol).

## O

### on-chain complete

A work's one-way state once every media file is complete in the content store
(`RecordInfo.onChainComplete`), marked by the permissionless, resumable
`WorkRecords.syncOnChain`. Only on-chain complete works inline their primary file, and the mark
does not change the state hash.

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol),
[stream README](../src/stream/README.md#records-satellite), [works and storage](spec/works-and-storage.md).

### opening bid

A currency's governed minimum first bid (`IEnglishAuction.openingBid`), zero at launch. The first
bid must be at least `max(openingBid, 1)`. `setOpeningBid` (PARAMETER_SETTER, 48 hours,
compare-and-set) moves it either way up to 1,000 increment floors
(`EnglishAuction.OPENING_BID_FLOORS`), and each auction locks it at its start.

See: [`IEnglishAuction`](../src/interfaces/IEnglishAuction.sol),
[ADR 0003 sales](adr/0003-build-time-decisions.md#sales-and-auctions-amends-adr-0001-5-6-and-9),
[stream and auctions](spec/stream-and-auctions.md).

### override

A governed identity change with a 180-day public notice (`ArtistRegistry.OVERRIDE_DELAY`), staged
by PARAMETER_SETTER (48 hours) with an evidence hash. Its kind (`ChangeKind`) is CONTESTED (for
example after a key theft), ESTATE or LOST_KEY; the last two need [dormancy](#dormancy). The old
key cannot cancel it: a captured wallet's cancel [contests](#contest) it, and the guardian may
[veto](#veto) it.

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[identity README](../src/identity/README.md#lifecycle),
[identity and recovery](spec/identity-and-recovery.md).

## P

### package

The set of items an artist submits for curation and voters approve, committed as one
[package root](#package-root). Anyone registers an approved root (`registerPackage`), every party
accepts it, and approvals never expire, though the guardian may [revoke](#revocation) a root.

See: [`IPackageRegistry`](../src/interfaces/IPackageRegistry.sol),
[ADR 0001 §3](adr/0001-v1-scope.md#3-curation-and-approved-packages), [curation](spec/curation.md).

### package root

The OpenZeppelin `MerkleProof` root (sorted pairs) over the leaves
`keccak256(bytes.concat(itemHash))`, equal to a `StandardMerkleTree` with leaf values
`[PACKAGE_ITEM_DOMAIN, item]`; a one-item package's root is its leaf. It is chain-independent, so
a package has the same root on Sepolia and mainnet.

See: [`WorksHashing.sol`](../src/interfaces/types/WorksHashing.sol),
[architecture](architecture.md#identifiers-and-hashes), [curation](spec/curation.md).

### party

An account a package item names (`Party`): an artist or a collaborator, 1 to 16 per item
(`Limits.MAX_PARTIES`), distinct, lead artist first. Every party must [accept](#acceptance) the
package root, and every payee must be a party, so nobody is named or paid without consent.

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol), [curation](spec/curation.md).

### pause

Two different pauses. A [dispute pause](#dispute-pause) stops one live auction (GUARDIAN). An
adapter pause (`ISaleAdapter.pause`, PAUSER, immediate) stops an adapter's new opens, starts and
purchases while bids, settlements, claims and closes continue; `unpause` (UNPAUSER) is refused
until 48 hours after the pause.

See: [`ISaleAdapter`](../src/interfaces/ISaleAdapter.sol),
[sales README](../src/sales/README.md#opening-a-sale).

### payout address

Where an artist's [artist-resolved](#artist-resolved-payee) split payments go
(`ArtistIdentity.payout`, read with `payoutAddress(artistId)`). It starts as the authority and
changes only through a staged change or override. It must be an account that can call `release`
itself: never zero, a split wallet or a protocol contract.

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[identity README](../src/identity/README.md#payout-validation),
[identity and recovery](spec/identity-and-recovery.md).

### payout freeze

`payoutAddress(artistId)` returning zero while a pending standard change or override would move
the payout. Split wallets refuse to release on zero, so accrued balances wait for the outcome
instead of following a contested redirect; a lapsed contest stops freezing at once.

See: [identity README](../src/identity/README.md#payout-freeze),
[identity and recovery](spec/identity-and-recovery.md).

### payout resolver

The contract split wallets ask for an artist-resolved payee's current payout address
(`IArtistPayoutResolver.payoutAddress`): the artist registry, pinned by code hash in each wallet
at deployment.

See: [`IArtistPayoutResolver`](../src/economics/interfaces/IArtistPayoutResolver.sol),
[`ISplitWallet`](../src/economics/interfaces/ISplitWallet.sol).

### pending claim

See [pending delivery](#pending-delivery).

### pending delivery

An auction token whose delivery to the winner failed at settlement. `settle` forwards 300,000 gas
(`EnglishAuction.DELIVERY_GAS`) to the token's `safeTransferFrom` and, on failure, records the
token as pending (`DeliveryPending`, `pendingDelivery(saleId)`) instead of reverting. The
recipient or the winning bidder (with no bid, the artist) later claims it to any address with
`claimDelivery(saleId, to)`. Also called a pending claim.

See: [`IEnglishAuction`](../src/interfaces/IEnglishAuction.sol),
[ADR 0001 §5](adr/0001-v1-scope.md#5-sales-and-auctions),
[buying, bidding and settling](integrators/buying-bidding-settling.md).

### Permit2

Uniswap's canonical signature-transfer contract (`DeployV1.CANONICAL_PERMIT2`). A `PERMIT2`
payment uses `permitWitnessTransferFrom` with a witness that binds the action
(`Typehashes.BID_WITNESS`, `START_BID_WITNESS`, `PURCHASE_WITNESS`, `DUTCH_PURCHASE_WITNESS`), so
a relayer can submit the payer's signed payment intent.

See: [`ISignatureTransfer`](../src/interfaces/external/ISignatureTransfer.sol),
[sales README](../src/sales/README.md#payments).

### phase

One time window of a fixed-price sale (`IFixedPriceSale.Phase`): `[start, end)`, an optional
allowlist Merkle root (zero means public), a per-wallet cap, and flags for payer-keyed leaves and
leaf prices. A sale has 1 to 16 phases (`Limits.MAX_PHASES`), and purchase counts persist per
`(token, id, phase, account)` across sales.

See: [`IFixedPriceSale`](../src/interfaces/IFixedPriceSale.sol),
[sales README](../src/sales/README.md#allowlists), [editions and sales](spec/editions-and-sales.md).

### phase configuration

The creator's EIP-712 `PhaseConfiguration` approval of a fixed-price sale
(`Typehashes.PHASE_CONFIGURATION`). It binds the token, ID, resolved currency, package price,
every phase, a single-use revocable nonce and a deadline. PLATFORM needs it to open leaf-priced
phases or any sale of an OPEN edition (MARKET-6).

See: [`Typehashes.sol`](../src/interfaces/types/Typehashes.sol),
[sales README](../src/sales/README.md#allowlists), [editions and sales](spec/editions-and-sales.md).

### pin

To record an address with its code hash, so the protocol uses only that code. Finalize pins
Stream's current default renderer for the work. The renderers, curation verifier, VRF
coordinator, artist resolver, consolidation source, federation registry and split wallets' payout
resolver are pinned at install and re-checked at use, failing closed on a mismatch; other
dependencies are not all pinned.

See: [trust assumptions](audit/trust-assumptions.md#pinned-code-hashes),
[stream README](../src/stream/README.md#core-token),
[architecture](architecture.md#governance-map),
[rendering and tokenURI](spec/rendering-and-tokenuri.md).

### platform

The holder of `Roles.PLATFORM` (ID 8), 6529's platform key, with zero execution delay. It creates
collections, adds locators (alone after finalize), opens FIXED edition sales at the package terms
and closes the sales it opened alone, and appends platform statements, including DISPUTE_OUTCOME.

See: [`Roles.sol`](../src/governance/Roles.sol), [trust assumptions](audit/trust-assumptions.md).

### Prague gas

A whole transaction's gas (intrinsic, calldata and execution, before refunds) priced with
Ethereum's Prague schedule, with storage and accounts cold as in a real transaction. It is the
unit of every gas budget, because Foundry measures it; Glamsterdam totals are published beside it
but not gated.

See: [ADR 0004 decision 1](adr/0004-gas-budgets-under-glamsterdam.md#decision),
[`GasReport.t.sol`](../test/integration/GasReport.t.sol).

### preferred locator

The copy `tokenURI` serves for a file (`IWorkRecords.preferredLocator`). The most specific setting
wins: the file's preferred index, then the collection's preferred kind, then the global kind, then
the first registered locator, then the implicit ONCHAIN copy. The
[storage operator](#storage-operator) sets the preferences.

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol),
[ADR 0003 token model](adr/0003-build-time-decisions.md#token-model-and-storage-amends-adr-0001-4-and-8),
[storage](integrators/storage.md).

### primary sale settled

A Stream token's flag, set by its minting adapter at settlement (`markPrimarySettled`, read with
`primarySaleSettled`) before delivery, so a winner who never claims blocks nothing. It gates
edition creation and ends the token's burnability.

See: [`IMintTarget`](../src/interfaces/IMintTarget.sol), [`IStream`](../src/interfaces/IStream.sol).

### PrimaryTerms

What a token tells a sale adapter about a primary sale (`PrimaryTerms`): sale kind, currency,
price, params, seller, fee recipient, fee share and [creator](#creator), returned by `mint` and
`primaryTerms`. For a minted Stream token only the sale kind, seller, fee terms and creator are
set.

See: [`SaleTypes.sol`](../src/interfaces/types/SaleTypes.sol),
[`IMintTarget`](../src/interfaces/IMintTarget.sol).

### product

A scope for economics, default currencies and content uniqueness: `PRODUCT_STREAM`,
`PRODUCT_EDITIONS` or `PRODUCT_FEDERATED`, each the keccak256 of its name.

See: [`EconomicsTypes.sol`](../src/interfaces/types/EconomicsTypes.sol),
[ADR 0001 §2](adr/0001-v1-scope.md#2-network-tiers).

### profile

An artist identity's `profileId` (its claimed 6529 profile ID) and `profileDocHash` (the hash of
its profile document). The registry binds both into identity signatures but does not verify them
against 6529 profiles.

See: [`IdentityTypes.sol`](../src/interfaces/types/IdentityTypes.sol),
[identity README](../src/identity/README.md#trust-and-failure-modes).

## R

### raise-only parameter

A gas parameter that may only rise, at most 2× per step, up to a code-level ceiling
(`BoundedParameter`). The VRF callback gas limit is one (100,000 to 2,500,000,
`VrfEntropyModule.MIN_CALLBACK_GAS`, `MAX_CALLBACK_GAS`); lowering it, never below the floor, is a
separate action (`lowerCallbackGasLimit`, SUCCESSOR_SETTER, 30 days).

See: [`BoundedParameter.sol`](../src/governance/BoundedParameter.sol),
[entropy README](../src/entropy/README.md#configuration).

### record

A work's descriptive record: a UTF-8 JSON file in the content store (`Identity`, one chunk, at
most 12,288 bytes, `Limits.MAX_RECORD_BYTES`) whose file ID WorkRecords stores. The lead artist
may point the work at a new record file with `setRecord` until [finalize](#finalize), and the
renderer validates the JSON.

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol),
[content README](../src/content/README.md#the-record), [works and storage](spec/works-and-storage.md).

### record status

The `record_status` field of [core-only metadata](#core-only-metadata), saying why a record is
not shown: `not_open` (`openRecord` has not run), `incomplete` (the record file is not fully in
the content store) or `invalid` (the record breaks a renderer rule).

See: [`IRenderer`](../src/interfaces/IRenderer.sol),
[content README](../src/content/README.md#what-it-reads-and-how-it-fails),
[reading a work](integrators/reading-a-work.md).

### regression ceiling

A measured operation's Prague gas when ADR 0004 was accepted, plus about 2%, rounded up to the
thousand. It is not a budget: a change that crosses one says why in its pull request and moves
it.

See: [ADR 0004 decision 1](adr/0004-gas-budgets-under-glamsterdam.md#decision).

### release

Paying a split-wallet payee its releasable share, `floor(observed × share / 100,000) − released`,
where `observed` is the wallet's balance plus everything released (`ISplitWallet.release`,
`releaseTo`, `releaseWithAuthorization`). Anyone may release a fixed payee to its own account;
only an artist-resolved payee's current payout address may release, directly or by signature.

See: [`ISplitWallet`](../src/economics/interfaces/ISplitWallet.sol),
[economics README](../src/economics/README.md#who-can-release),
[economics and payouts](spec/economics-and-payouts.md).

### relicense

A change of a work's license: `WorkRecords.relicense` (PARAMETER_SETTER, 48 hours) with every
party's EIP-712 `Relicense` consent. Only CC0 irrevocability is enforced on-chain; whether the new
license is more permissive rests with the consents and governance.

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol), [works and storage](spec/works-and-storage.md).

### renderer

The immutable, stateless contract that builds `tokenURI` and `fullTokenURI` for Stream works and
editions (`Renderer`, `IRenderer`). Works use Stream's default renderer (`setDefaultRenderer`,
SUCCESSOR_SETTER, 30 days, code-hash pinned) until finalize pins it. `rendererOf` reverts, never
falling back, when a renderer's code no longer matches its pin.

See: [`IRenderer`](../src/interfaces/IRenderer.sol), [content README](../src/content/README.md#renderer),
[rendering and tokenURI](spec/rendering-and-tokenuri.md).

### reserved authority

An account that a pending identity change would make an artist's new authority
(`reservedFor(account)`). Until the change executes or ends, the account cannot register as an
artist or become another artist's authority (`AccountTaken`).

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[identity README](../src/identity/README.md#lifecycle).

### resolver

Three different resolvers: the [economics resolver](#economics-resolver), the statement log's
[artist resolver](#artist-resolver) and the split wallets' [payout resolver](#payout-resolver).
The last two are both the artist registry. Say which.

### restraint

The state in which nobody acts as the artist: from the staging of an override that would move the
authority until it executes, is vetoed or voided, or its contest lapses, `activeAuthorityOf`
returns zero (ADR 0003 owner decision 6, IDENTITY-1). Running sales continue (with the artist's
share frozen if the override also moves the payout), a no-bid settlement waits, and PLATFORM may
close any of the artist's sales and open FIXED edition sales at the package terms.

See: [identity README](../src/identity/README.md#restrained-authority-during-a-recovery-override),
[ADR 0003 owner decision 6](adr/0003-build-time-decisions.md#owner-decisions-11-october-2026),
[identity and recovery](spec/identity-and-recovery.md).

### revocation

The guardian's immediate withdrawal of a package root's approval (`revokePackage`, GUARDIAN): its
unconsumed items can no longer mint, and a root not yet registered can then never be registered.
Revocation is per root, so an item listed in another approved root stays consumable there.

See: [`IPackageRegistry`](../src/interfaces/IPackageRegistry.sol),
[curation README](../src/curation/README.md), [curation](spec/curation.md).

### role

An AccessManager role from `Roles.sol`, from `ADMIN` (ID 0) to `CURATOR` (ID 12); each role's
holders carry its [delay class](#delay-class) as their execution delay. The
[role and permission matrix](audit/roles.md) lists every role's delays, holders and functions.
Contract-to-contract calls use [bindings](#binding), not roles, and the statement log's speaker
roles are a separate [statement role](#statement-role).

See: [`Roles.sol`](../src/governance/Roles.sol), [roles](audit/roles.md),
[`genesis.example.json`](../config/genesis.example.json).

### royalty rate

A work's ERC-2981 rate out of 100,000, 6,529 at launch (`EconomicsResolver.DEFAULT_ROYALTY_RATE`).
A new work locks its product's rate at mint (the product rate is PARAMETER_SETTER, 48 hours). An
existing work's rate changes only with every party's consent plus FUNDS_SETTER
(`WorkRecords.setRoyaltyRate`, 14 days), and a master's change carries to its edition.

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol),
[ADR 0001 §7](adr/0001-v1-scope.md#7-economics), [economics and payouts](spec/economics-and-payouts.md).

### royalty wallet

The split wallet that receives a work's royalties:
`walletFor(Splits.royaltyPayees(seller, feeRecipient, feeShare), 0)`, paying
`100,000 − feeShare` to the [seller wallet](#seller-wallet) and `feeShare` to the network fee
recipient, or the seller wallet itself when the fee share is zero. 6529 Stream derives it at each
`royaltyInfo` call instead of storing it.

See: [`IEconomicsResolver`](../src/interfaces/IEconomicsResolver.sol),
[economics README](../src/economics/README.md#new-work-terms),
[economics and payouts](spec/economics-and-payouts.md).

## S

### sale adapter

A shared contract that sells tokens through `IMintTarget` and nothing else (`ISaleAdapter`): the
English auction (6529 Stream's only primary sale), and the fixed-price and Dutch sales (6529
Editions). It locks the terms when a sale starts, pays the seller wallet and fee recipient with the
escrow as fallback, and credits refunds for pull claims.

See: [`ISaleAdapter`](../src/interfaces/ISaleAdapter.sol), [sales README](../src/sales/README.md),
[buying, bidding and settling](integrators/buying-bidding-settling.md).

### sale ID

A sale's number in its adapter. The auction derives it as
`uint256(keccak256(abi.encode(token, tokenId)))` (`saleIdOf`); the fixed-price and Dutch adapters
number sales from 1 (`MintSaleBase.nextSaleId`), with at most one open sale per `(token, id)`.

See: [`IEnglishAuction`](../src/interfaces/IEnglishAuction.sol),
[`MintSaleBase.sol`](../src/sales/MintSaleBase.sol),
[architecture](architecture.md#identifiers-and-hashes).

### sale kind

A `bytes32` label naming a sale type (`SaleKind`): `ENGLISH_AUCTION`, `FIXED_PRICE` or `DUTCH`,
each the keccak256 of its name. A token mints only for an adapter whose `saleKind()` equals its
terms' kind, and 6529 Stream accepts only `ENGLISH_AUCTION`.

See: [`SaleTypes.sol`](../src/interfaces/types/SaleTypes.sol),
[`IMintTarget`](../src/interfaces/IMintTarget.sol).

### satellite

A contract that serves 6529 Stream's core from outside it; chiefly [WorkRecords](#workrecords),
the records satellite. `IStream` also calls 6529 Editions a satellite (both are bound once), and
ADR 0001 §13 uses the word for every governed contract other than the two tokens.

See: [stream README](../src/stream/README.md), [architecture](architecture.md#modules).

### schedule delay

How far a fixed-price or Dutch sale's schedule has moved since it opened (`scheduleDelay(saleId)`):
the time the adapter was paused and the sale's currency deprecated since then, running halts
included. Phase windows and the Dutch curve run that much later, so a halt never uses up a phase or
lets the price fall; overlapping halts count twice (MARKET-1).

See: [`IFixedPriceSale`](../src/interfaces/IFixedPriceSale.sol),
[sales README](../src/sales/README.md#opening-a-sale), [editions and sales](spec/editions-and-sales.md).

### seed

The 32-byte value a seeded work's code reads (`IWorkRecords.seedOf`): the artist's choice committed
in the item under ARTIST, stored when the record opens; the entropy module's VRF output under VRF;
zero under NONE. The renderer shows it as the `Seed` trait and passes it to scripts in
[window.works](#windowworks).

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol), [entropy](spec/entropy.md).

### seed policy

Where a work's seed comes from (`SeedPolicy`): NONE (unseeded), ARTIST (chosen by the artist and
committed in the package) or VRF (delivered by the [entropy module](#entropy-module) before the
start). A copy never gets its own seed.

See: [`PackageTypes.sol`](../src/interfaces/types/PackageTypes.sol),
[ADR 0001 §9](adr/0001-v1-scope.md#9-seeded-and-generative-11s), [entropy](spec/entropy.md).

### seller wallet

The split wallet of an item's payees, the artist portion: `walletFor(payees, 0)` on the split
factory, a predicted CREATE2 address that may not be deployed yet. Sale adapters pay it the seller
proceeds, and one seller wallet serves every work with the same payees.

See: [`IEconomicsResolver`](../src/interfaces/IEconomicsResolver.sol),
[economics README](../src/economics/README.md#new-work-terms),
[economics and payouts](spec/economics-and-payouts.md).

### serial

A work's number within its [collection](#collection), from 1 and below 2^32 (`IStream`), assigned
at mint together with the token ID.

See: [`IStream`](../src/interfaces/IStream.sol).

### settle

`EnglishAuction.settle(saleId)`, permissionless after the end. It delivers the token or records a
[pending delivery](#pending-delivery), pays the seller wallet and the network fee (through the
escrow on failure), and marks the primary sale settled. With no bids the token goes to the
[creator](#creator); while the currency is deprecated nothing settles for 30 days, after which
`settle` ends the auction unsold (MARKET-2).

See: [`IEnglishAuction`](../src/interfaces/IEnglishAuction.sol),
[buying, bidding and settling](integrators/buying-bidding-settling.md),
[stream and auctions](spec/stream-and-auctions.md).

### signed release

A payee's EIP-712 `ReleaseAuthorization`, in the release verifier's domain, that anyone submits with
`releaseWithAuthorization`. It binds wallet, asset, payee, account, recipient, amount, nonce and
deadline; the account must be the payee's payout address when it is used, and nonces are unordered
and revocable (`ReleaseVerifier.revokeNonce`).

See: [`IReleaseVerifier`](../src/economics/interfaces/IReleaseVerifier.sol),
[economics README](../src/economics/README.md#who-can-release).

### signer epoch

The value a curation signer's approval must bind to count (`signerEpoch(signer)`): when its
CURATION_SIGNER grant took effect, how many times it was disabled or enabled, and a salt drawn from
`block.prevrandao` at each change. A disable, a re-enable or a fresh grant of the role starts a new
epoch, so an approval made before a disable never counts again.

See: [`ICurationVerifier`](../src/interfaces/ICurationVerifier.sol),
[curation README](../src/curation/README.md), [curation](spec/curation.md).

### split wallet

An immutable pull-payment wallet for ETH and any ERC-20 (`SplitWallet`), deployed by the split
factory at a CREATE2 address that commits to a [canonical payee list](#canonical-payee-list) and a
salt, so its address is known before deployment. Funds sent to the predicted address are split
once anyone deploys it, and payees take their shares by [release](#release).

See: [`ISplitWallet`](../src/economics/interfaces/ISplitWallet.sol),
[`ISplitFactory`](../src/economics/interfaces/ISplitFactory.sol),
[economics and payouts](spec/economics-and-payouts.md).

### SSTORE2

Storing bytes as the runtime code of a contract (`SSTORE2.sol`): `write` deploys `0x00 || data` by
CREATE2 with `salt = keccak256(data)`, so a chunk is content-addressed and written once. Reads
check the leading STOP byte and, where asked, the expected hash.

See: [`SSTORE2.sol`](../src/libraries/SSTORE2.sol).

### standard change

An identity change of kind STANDARD. The authority or an established wallet signs
`IdentityChange` (artist ID, next identity, nonce, deadline), a new authority countersigns,
anyone relays it (`stageChange`), and anyone executes it after 7 days
(`ArtistRegistry.CHANGE_DELAY`). The previous authority or a captured wallet may cancel it, and the
guardian may [veto](#veto) it.

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[identity README](../src/identity/README.md#lifecycle),
[identity and recovery](spec/identity-and-recovery.md).

### standing

A consolidated wallet's right to cancel or contest an artist's pending identity change. A wallet
has it from `effectiveAt` (its consolidation's registration plus 30 days) once a refresh records
it, and keeps it for 30 days (`ArtistRegistry.STANDING_GRACE`) after a refresh finds it no longer
consolidated.

See: [`IdentityTypes.sol`](../src/interfaces/types/IdentityTypes.sol),
[identity README](../src/identity/README.md#recovery-standing-sticky-snapshot),
[identity and recovery](spec/identity-and-recovery.md).

### start

The permissionless auction start that mints: `EnglishAuction.start(token, mintData)` or
`startWithBid`, with `mintData` set to `abi.encode(StreamMintRequest)`. Stream's `mint` consumes
the item, assigns the token ID and serial, locks the fee terms and mints into the auction's
custody, and the clock (24 hours by default, `AUCTION_DURATION`) starts in the same transaction. A
VRF item reverts unless its seed is delivered.

See: [`IEnglishAuction`](../src/interfaces/IEnglishAuction.sol),
[architecture](architecture.md#curated-sale-approve-start-bid-settle-royalties),
[stream and auctions](spec/stream-and-auctions.md).

### start budget

The gas gate on a steady-state `start` and `startWithBid` in ETH: at most 350,000 Prague gas and
at most 6 new slots (7 with a bid), measured end to end in `test/integration/GasReport.t.sol`.
Raising either slot maximum needs an ADR.

See: [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#decision),
[`GasReport.t.sol`](../test/integration/GasReport.t.sol).

### state hash

A work's state commitment (`WorkRecords.workStateHash`): keccak256 over the token ID, the version,
the record file ID, the license key and text, the royalty rate and the effective renderer. Every
finalize and signed amendment binds it, and the version bumps only on a real change, so a consent
never applies twice or to a state its signer did not see.

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol),
[stream README](../src/stream/README.md#records-satellite),
[works and storage](spec/works-and-storage.md).

### statement

One signed entry in the statement log (`Statement`): a [subject](#subject) `(token, id)`, a kind, a
schema hash, a content hash (`HashRef`), exactly one of a URI or a content-store file ID, and an
optional `supersedes`. Statements are never edited or deleted.

See: [`IStatementLog`](../src/interfaces/IStatementLog.sol),
[records README](../src/records/README.md#what-is-stored-what-is-emitted),
[disputes and statements](spec/disputes-and-statements.md).

### statement kind

A nonzero `bytes32` label of what a statement is (`StatementKinds`), for example
`ARTIST_STATEMENT`, `FIXITY_CHECK` or `ACCESSION`; new kinds need no deployment. Three are
reserved: `DISPUTE_OUTCOME` to PLATFORM, `CURATION_EVIDENCE` to CURATOR and `GOVERNANCE_MANIFEST`
to `appendGovernanceManifest`.

See: [`StatementKinds.sol`](../src/interfaces/types/StatementKinds.sol),
[disputes and statements](spec/disputes-and-statements.md).

### statement log

The single append-only, signed log of statements about works (`StatementLog`, `IStatementLog`). It
stores only a count and a [chain head](#chain-head) per subject, plus each subject's latest dispute
outcome, and emits every entry in full. It has no pause, no admin write path and holds no value.

See: [`IStatementLog`](../src/interfaces/IStatementLog.sol), [records README](../src/records/README.md),
[disputes and statements](spec/disputes-and-statements.md).

### statement role

Who a statement speaks as (`Role`): ARTIST, vouched for by the [artist resolver](#artist-resolver);
OWNER, the token's owner or an edition holder; CURATOR or PLATFORM, the AccessManager roles of the
same names with zero delay. Consumers read a statement's kind together with its role.

See: [`IStatementLog`](../src/interfaces/IStatementLog.sol),
[records README](../src/records/README.md#who-may-write).

### sticky standing snapshot

Each artist's list of at most 16 consolidated wallets (`standingOf`, `Limits.MAX_CANCELLERS`),
each with [standing](#standing) once its consolidation is 30 days old. It is refreshed at
registration, staging, heartbeat and execution, and by anyone (`refreshStanding`). It is sticky: nothing is evicted early, and a wallet that stops being
consolidated keeps standing for the 30-day grace, so a key thief cannot strip the artist's wallets
by revoking consolidations.

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[identity README](../src/identity/README.md#recovery-standing-sticky-snapshot),
[identity and recovery](spec/identity-and-recovery.md).

### storage operator

The holder of `Roles.STORAGE_OPERATOR` (ID 5), with zero delay. It sets the global, collection and
file [preferred locator](#preferred-locator) settings, choosing only among registered copies; it
cannot add, remove or change locators or hashes.

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol),
[trust assumptions](audit/trust-assumptions.md).

### subject

What a statement is about: `(token, id)`, a token contract and token ID, or `token == address(0)`
and an `id` with no token yet (an item hash before its mint, or a package root for curation
evidence). Its key is `keccak256(abi.encode(token, id))`, and the log does not link a pre-mint
subject to the token it becomes.

See: [`IStatementLog`](../src/interfaces/IStatementLog.sol),
[records README](../src/records/README.md#what-is-stored-what-is-emitted).

### supersession

How a statement corrects or replaces an earlier one: its `supersedes` field names the earlier
[entry hash](#entry-hash). The log does not check the target; readers verify it against the
rebuilt chain.

See: [records README](../src/records/README.md#what-is-stored-what-is-emitted).

## T

### target

A token contract a sale adapter may sell (`isTarget`): listed by governance (`setTarget`,
SUCCESSOR_SETTER, 30 days) or, from v1.1, active in the federation registry. Running sales finish
when a token is unlisted.

See: [`ISaleAdapter`](../src/interfaces/ISaleAdapter.sol),
[sales README](../src/sales/README.md#opening-a-sale).

### TDH

TDH (Total Days Held), the 6529 network's holding-based voting weight. Curation approvals, dispute
outcomes, contested overrides and federated delistings are decided by TDH-weighted votes off-chain;
the contracts never read TDH and trust the curation signer and the governed actions that record
the outcomes.

See: [ADR 0001 §3](adr/0001-v1-scope.md#3-curation-and-approved-packages),
[trust assumptions](audit/trust-assumptions.md).

### The Memes

6529's existing ERC-1155 of Main Stage winners, chosen by TDH-weighted votes. It is outside this
repository and keeps its own 50/50 split. A work cannot be both a Meme and a 6529 Stream or 6529
Editions work; the wave layer enforces this.

See: [ADR 0001 §2](adr/0001-v1-scope.md#2-network-tiers).

### token ID

A 6529 Stream work's ERC-721 ID: one chronological global sequence from 1, assigned when its
auction starts and never reused (a burn leaves a gap). An edition's ID on 6529 Editions equals its
master's token ID.

See: [`IStream`](../src/interfaces/IStream.sol), [ADR 0001 §4](adr/0001-v1-scope.md#4-stream-token-model).

### tokenURI

The ERC-721 metadata URI. `Stream.tokenURI` (and `Editions.uri`) forwards to the work's renderer,
which returns `data:application/json;utf8,` JSON within an 8M-gas budget (ADR 0004). It inlines
media only under the [inline threshold](#inline-threshold) and otherwise gives the
[preferred locator](#preferred-locator).

See: [`IRenderer`](../src/interfaces/IRenderer.sol), [content README](../src/content/README.md#output),
[rendering and tokenURI](spec/rendering-and-tokenuri.md).

### tombstone

The permanent mark on a burned item after a [content release](#content-release): the package
registry never consumes that item again, through any root, while its content hash is freed for the
rightful artist's items.

See: [`IPackageRegistry`](../src/interfaces/IPackageRegistry.sol),
[curation README](../src/curation/README.md).

## U

### uniqueness

The rule that a content hash is held by at most one item per product, recorded in one
package-registry storage word per product and content hash (`consumedItemOf`,
`editionClaimOf`). The only cross-product reuse is an edition claiming its master's content hash. It is defense in depth
behind the curation signer's SHA-256 check.

See: [`IPackageRegistry`](../src/interfaces/IPackageRegistry.sol),
[ADR 0001 §3](adr/0001-v1-scope.md#3-curation-and-approved-packages), [curation](spec/curation.md).

## V

### veto

The guardian's immediate deletion of a pending identity change, contested or not
(`ArtistRegistry.vetoChange`, GUARDIAN). It blocks a change but never redirects it.

See: [`IArtistRegistry`](../src/interfaces/IArtistRegistry.sol),
[identity and recovery](spec/identity-and-recovery.md).

### VRF

Verifiable random function: here Chainlink VRF v2.5, through which the
[entropy module](#entropy-module) draws a work's seed before its auction starts. A seed is drawn
once per content hash, is the VRF output unchanged, and never changes after the first delivery.

See: [entropy README](../src/entropy/README.md), [ADR 0001 §9](adr/0001-v1-scope.md#9-seeded-and-generative-11s),
[entropy](spec/entropy.md).

## W

### wave

A 6529 network discussion and voting space. Artists submit packages to curation waves, and disputes are
filed in the 6529 disputes wave; votes are off-chain and TDH-weighted, and the contracts never read
a wave.

See: [ADR 0001 §3](adr/0001-v1-scope.md#3-curation-and-approved-packages),
[ADR 0001 §12](adr/0001-v1-scope.md#12-disputes).

### window.works

The object the renderer's HTML page sets before a JavaScript primary runs:
`{ v: 1, tokenId, seed }`, with `seed` a hex string or null. It is a stable public API: a finalized
work pins its renderer, so any change to its fields needs a new `v` and a new renderer.

See: [content README](../src/content/README.md#the-page-around-a-script),
[rendering and tokenURI](spec/rendering-and-tokenuri.md).

### work

A 6529 Stream 1/1: its token and its record. That is the core fields 6529 Stream stores, and the
record, media, license, seed and locators in [WorkRecords](#workrecords).

See: [`IStream`](../src/interfaces/IStream.sol), [`IWorkRecords`](../src/interfaces/IWorkRecords.sol),
[reading a work](integrators/reading-a-work.md).

### work ID

Two uses. In 6529 Stream and 6529 Editions (`createEdition(workId, ...)`, `masterOf`), a work ID is
a Stream token ID. In the statement log, a subject with `token == address(0)` carries a work ID
with no token yet: an item hash before its mint, or a package root for curation evidence.

See: [`IEditions`](../src/interfaces/IEditions.sol), [`IStatementLog`](../src/interfaces/IStatementLog.sol).

### WorkRecords

6529 Stream's records satellite (`WorkRecords.sol`, `IWorkRecords`): each work's record, media,
license, ARTIST seed, state hash, finalize and renderer pin, on-chain completeness, amendments,
locators and preferred location. Nothing is written at mint; every per-token function reverts with
`RecordNotOpen` until the permissionless `openRecord`.

See: [`IWorkRecords`](../src/interfaces/IWorkRecords.sol),
[stream README](../src/stream/README.md#records-satellite),
[works and storage](spec/works-and-storage.md).

### WorksAccessManager

OpenZeppelin's `AccessManager` with one change, to its cancel check: any GUARDIAN holder may cancel
any scheduled operation (Rule 1), and only its scheduler may cancel an operation that revokes one of
the canceller's own roles (Rule 2). `GovernanceConfigurator` deploys it, and the configuration
rejects a stock manager.

See: [`WorksAccessManager.sol`](../src/governance/WorksAccessManager.sol),
[ADR 0002 decision 1](adr/0002-access-manager-hardening.md#decision),
[governance](spec/governance.md).
