# Glossary

Every protocol term a reader meets in this repository, in alphabetical order, as the code on
`main` defines it. Each entry links the page that specifies the rules. Link a term as
`glossary.md#<term>` from `docs/` and `../glossary.md#<term>` from `docs/spec/`.

> Pre-audit. See the [project status](../README.md#status).

Governed delays are named by [delay class](#delay-class), and shares and rates are out of
100,000 ([denominator](#denominator)).

[0-9](#0-9) · [A](#a) · [B](#b) · [C](#c) · [D](#d) · [E](#e) · [F](#f) · [G](#g) · [H](#h) ·
[I](#i) · [K](#k) · [L](#l) · [M](#m) · [N](#n) · [O](#o) · [P](#p) · [R](#r) · [S](#s) ·
[T](#t) · [U](#u) · [V](#v) · [W](#w)

## 0-9

### 6529 Network Museum

The account that receives a 6529 Stream 1/1 whose sale ends unsold, unbid or frozen out
(`EconomicsResolver.museum`, set by FUNDS_SETTER): 6529 Stream itself moves the work there when
the adapter reports the outcome (`settlePrimary`, owner decision 17). Another token's unsold work
goes to its creator.

See: [stream and auctions](spec/stream-and-auctions.md).

### 6529 Stream

The one shared, network-curated ERC-721 of 1/1 works (`Stream`), sold by English auction, with
each work's record in [WorkRecords](#workrecords).

See: [stream and auctions](spec/stream-and-auctions.md).

### 6529 Stream Editions

The one shared ERC-1155 for editions (`Editions`, symbol `STREAMEDITIONS`), each anchored by a
6529 Stream [edition master](#edition-master) and sold by the [edition auction](#edition-auction).
Named 6529 Editions before ADR 0005 (D139).

See: [editions and sales](spec/editions-and-sales.md).

### 6529 Stream Federated

The v1.1 tier, built only if needed: artist-deployed contracts sold through the shared
[sale adapters](#sale-adapter). v1 installs no federation registry.

See: [federated README](../src/federated/README.md).

## A

### acceptance

A party's EIP-712 `PackageAcceptance` signature over a package root. An account with no
[artist ID](#artist-id) signs it itself, creating the identity; otherwise its artist's
[active authority](#active-authority) signs.

See: [curation](spec/curation.md).

### AccessManager

OpenZeppelin's `AccessManager`, the one governance contract: each `restricted` selector maps to a
[role](#role). Deployments use [WorksAccessManager](#worksaccessmanager).

See: [governance](spec/governance.md).

### active authority

The address that may act as an artist now (`activeAuthorityOf`): the [authority](#authority),
or zero during a [restraint](#restraint).

See: [identity and recovery](spec/identity-and-recovery.md).

### admin

A holder of `Roles.ADMIN`, with a 30-day delay: the hot or the cold admin Safe. An executed
ADMIN grant or revocation lifts a [suspension](#suspension), as does the holder's own
`renounceRole`.

See: [governance](spec/governance.md).

### admitted minter

A sale adapter a token allows to call `mint` (`isAdmittedMinter`). A removed adapter can still
settle and [burn](#burn) what it minted.

See: [stream and auctions](spec/stream-and-auctions.md).

### amendment

A change to a minted work by signed consent plus a governed action: a [relicense](#relicense),
a royalty-rate change or an [errata repin](#errata-repin).

See: [works and storage](spec/works-and-storage.md).

### anti-snipe

The English auction's rule that a bid in the last `extensionWindow` seconds extends the end to
that long after the bid.

See: [stream and auctions](spec/stream-and-auctions.md).

### artist

A [party](#party) with `PartyRole.ARTIST` in a package item, or an identity in the artist
registry: an [artist ID](#artist-id), [authority](#authority),
[payout address](#payout-address) and [profile](#profile).

See: [identity and recovery](spec/identity-and-recovery.md).

### artist ID

The permanent number of an artist identity, `uint256(uint160(first authority))`. It never
changes when the authority does.

See: [identity and recovery](spec/identity-and-recovery.md).

### artist resolver

The contract the [statement log](#statement-log) asks who may speak as ARTIST for a subject; in
v1, the artist registry.

See: [disputes and statements](spec/disputes-and-statements.md).

### artist-resolved payee

A split-wallet payee named by `artistId`, paid at the artist's current
[payout address](#payout-address), which alone may release it.

See: [economics and payouts](spec/economics-and-payouts.md).

### asset allowlist

The governed list of payment currencies (`AssetAllowlist`). A deprecation (GUARDIAN, immediate)
halts sales and freezes auctions in that currency.

See: [economics and payouts](spec/economics-and-payouts.md).

### attestation

Either a [curation attestation](#curation-attestation) or a
[base64 attestation](#base64-attestation). Say which.

### authority

The address that signs for an artist identity (`authorityOf`). It is never zero, and a past
authority maps to its artist forever.

See: [identity and recovery](spec/identity-and-recovery.md).

## B

### base64 attestation

The content store's permanent record that a file's stored bytes are strict base64
(`attestBase64`). The renderer inlines a `Base64` file only once attested.

See: [works and storage](spec/works-and-storage.md).

### binding

A one-shot contract-to-contract caller link set at genesis, such as `Stream.bindWorkRecords`.
Bound calls use no [role](#role).

See: [governance](spec/governance.md).

### breadth margin

The share of the best revenue the edition auction's clearing may give up to sell more copies:
the count is the largest whose revenue is within the margin of the best (governed).

See: [editions and sales](spec/editions-and-sales.md#the-clearing).

### burn

Destroying a token (`IMintTarget.burn`). A 6529 Stream token burns only when an upheld dispute
cancels its auction; burned edition copies still count toward the size.

See: [stream and auctions](spec/stream-and-auctions.md).

## C

### canonical payee list

A split wallet's payee list in its one valid order: 1 to 64 payees (`Splits.MAX_PAYEES`) whose
shares sum to 100,000, strictly ascending.

See: [economics and payouts](spec/economics-and-payouts.md).

### captured wallet

A [standing](#standing) wallet captured as a canceller when an identity change is staged, at
most 16 (`Limits.MAX_CANCELLERS`). Its cancel of an [override](#override) is a
[contest](#contest).

See: [identity and recovery](spec/identity-and-recovery.md).

### CC0 text

The CC0 1.0 legal code each deployment stores at genesis (`cc0TextFileId`). Every CC0 license
must name this file.

See: [works and storage](spec/works-and-storage.md).

### chain head

The rolling hash of one statement-log subject's entries (`chainOf`), which lets an indexer prove
a rebuilt chain complete.

See: [disputes and statements](spec/disputes-and-statements.md).

### chunk

A piece of a content-store file, at most 24,575 bytes (`IContentStore.CHUNK_SIZE`), stored as
contract code by [SSTORE2](#sstore2).

See: [works and storage](spec/works-and-storage.md).

### claim

Taking what an account is owed, by pull: [credits](#credit), a
[pending delivery](#pending-delivery) or split-wallet releases.

See: [buying, bidding and settling](integrators/buying-bidding-settling.md).

### claim router

A stateless contract that batches split-wallet releases (`ClaimRouter`). It never holds or
redirects funds.

See: [economics and payouts](spec/economics-and-payouts.md).

### clearing price

The one price every winner of an [edition auction](#edition-auction) pays per copy: the price of
the lowest winning step.

See: [editions and sales](spec/editions-and-sales.md#the-clearing).

### collaborator

A [party](#party) with `PartyRole.COLLABORATOR`, a credited contributor, paid only if also
listed as a payee.

See: [curation](spec/curation.md).

### collection

A named grouping of 6529 Stream works, created by PLATFORM. Each work has a per-collection
[serial](#serial).

See: [stream and auctions](spec/stream-and-auctions.md).

### compare-and-set

The rule that a governed setter names the value it expects to replace and reverts if it is
stale, so a queued operation never applies to a state it did not target.

See: [governance](spec/governance.md).

### configuration epoch

One governance configuration: genesis, then each later set of role, selector or delay changes,
each with its [governance manifest](#governance-manifest).

See: [governance](spec/governance.md).

### consent

An account's signed agreement: an [acceptance](#acceptance), an [amendment](#amendment)
consent, an identity-change acceptance or an escrow recovery consent.

See: [`Typehashes.sol`](../src/interfaces/types/Typehashes.sol).

### consolidation

A two-way link between two wallets in the 6529 [delegation contract](#delegation-contract).
Once at least 30 days old in each direction (`ConsolidationAdapter.MIN_AGE`), it makes an
[established wallet](#established-wallet).

See: [identity and recovery](spec/identity-and-recovery.md).

### consume

The package registry's single-use check when a Stream auction start mints
(`PackageRegistry.consume`). It verifies the item and the [move](#move), and marks the content
used.

See: [curation](spec/curation.md).

### content hash

The decoded SHA-256 of a work's primary media, the [uniqueness](#uniqueness) key. The contracts
cannot recompute it, so the curation signer checks it off-chain.

See: [curation](spec/curation.md).

### content manifest

A content-store file's declaration (`registerManifest`): chunk hashes, length,
[encoding](#encoding), MIME type and decoded SHA-256. Its hash is the [file ID](#file-id).

See: [storage](integrators/storage.md).

### content release

The governed step after an upheld dispute burned a work (`Stream.releaseContent`): it
[tombstones](#tombstone) the item and frees its content hash for the rightful artist.

See: [disputes and statements](spec/disputes-and-statements.md).

### content store

The permissionless, content-addressed file store all contracts share (`ContentStore`). It has no
owner, and on-chain bytes are permanent.

See: [works and storage](spec/works-and-storage.md).

### contest

A [captured wallet](#captured-wallet)'s cancel of a pending [override](#override), which then
waits for a TDH vote or lapses after 365 days (`ArtistRegistry.CONTEST_TIMEOUT`).

See: [identity and recovery](spec/identity-and-recovery.md).

### copy

One unit of an edition's ERC-1155 supply, minted when a winning
[edition auction](#edition-auction) bid is claimed.

See: [editions and sales](spec/editions-and-sales.md).

### core

6529 Stream's ERC-721 contract (`Stream.sol`), as distinct from its records
[satellite](#satellite).

See: [stream and auctions](spec/stream-and-auctions.md).

### core-only metadata

What the renderer returns, without reverting, when a work's record is not usable, with a
[record status](#record-status).

See: [rendering and tokenURI](spec/rendering-and-tokenuri.md).

### creator

The lead artist's [active authority](#active-authority) in a token's
[PrimaryTerms](#primaryterms). It receives an unsold federated auction token.

See: [stream and auctions](spec/stream-and-auctions.md).

### credit

An amount owed and claimable by pull: refunds and failed payouts on an adapter (`claimable`), or
failed payments in the [escrow](#escrow) (`owed`).

See: [buying, bidding and settling](integrators/buying-bidding-settling.md).

### curation attestation

A curation signer's EIP-712 `PackageApproval` of a package root and
[evidence hash](#evidence-hash), valid only in its current [signer epoch](#signer-epoch).

See: [curation](spec/curation.md).

### curation evidence

The published record behind an approval: its [evidence hash](#evidence-hash) is signed with the
root, and CURATOR publishes it as a `CURATION_EVIDENCE` statement.

See: [curation](spec/curation.md).

### curation signer

A `Roles.CURATION_SIGNER` key whose package approvals the curation verifier accepts. It only
signs; the guardian's `disableSigner` is its kill switch.

See: [curation](spec/curation.md).

### curator

The holder of `Roles.CURATOR`, a zero-delay key that appends curator statements. It does not
approve packages, and a guardian can [suspend](#suspension) it.

See: [disputes and statements](spec/disputes-and-statements.md).

### currency

The asset a sale is paid in: ETH (`address(0)`) or an ERC-20 active on the
[asset allowlist](#asset-allowlist), locked when the sale starts.

See: [economics and payouts](spec/economics-and-payouts.md).

### currency freeze

An English auction whose locked currency is deprecated: nothing settles, bids revert and the high bidder may withdraw; after 30 days anyone may end it unsold.

See: [stream and auctions](spec/stream-and-auctions.md#rules-and-invariants) (AUC-25).

### CURRENCY_DEFAULT

The package-terms currency `address(type(uint160).max)`: the product's default currency when the
sale starts. It requires a zero price.

See: [economics and payouts](spec/economics-and-payouts.md).

### cut step

The step at which a creator's cap stops the clearing inside the step, so only some of its units
win; they fill in queue [position](#position) order.

See: [editions and sales](spec/editions-and-sales.md#the-cut-step).

## D

### delay class

How long a governed action waits: immediate, standard (48 hours), funds (14 days) or successor
(30 days) (`Roles.STANDARD`, `FUNDS`, `SUCCESSOR`).

See: [governance](spec/governance.md).

### delegation contract

The 6529 delegation contract, whose use case 999 registrations are the
[consolidations](#consolidation) the artist registry reads.

See: [addresses](integrators/addresses.md).

### denominator

The 100,000 parts every share and rate is out of (`Splits.DENOMINATOR`), so the 6.529% royalty
is 6,529.

See: [economics and payouts](spec/economics-and-payouts.md).

### departure hint

The order, by [position](#position), of a [cut step](#cut-step)'s raises and withdrawals, which
a settler supplies so settlement can close the holes they left. Each settler sweeps on its own:
`settlementOrderFor(saleId, settler)` computes the rest of its sweep.

See: [editions and sales](spec/editions-and-sales.md#the-cut-step).

### dependency registry

The governed, append-only map from `(name, version)` to on-chain content-store files for shared
libraries such as p5.js (`DependencyRegistry`).

See: [works and storage](spec/works-and-storage.md).

### display rule

The statement log's answer for a 6529 Stream token with no dispute outcome of its own: the latest outcome about the package item it was minted from (`latestDisputeOutcome`).

See: [disputes and statements](spec/disputes-and-statements.md).

### dispute

A claim against a work, decided by TDH vote off-chain. Upheld during an auction, it cancels the
sale and burns the token; afterwards it only produces a statement.

See: [disputes and statements](spec/disputes-and-statements.md).

### dispute outcome

A `DISPUTE_OUTCOME` statement recording a dispute vote's result, which an auction `cancel` and
`resolveContested` must cite. PLATFORM is its only writer, through `appendPlatform` or a relayed
`appendSigned` signed by a PLATFORM holder.

See: [disputes and statements](spec/disputes-and-statements.md).

### dispute pause

The guardian's one pause of a live English auction, at most 7 days (`EnglishAuction.MAX_PAUSE`),
during which the high bidder may withdraw.

See: [stream and auctions](spec/stream-and-auctions.md).

### dormancy

A year without the artist's own signed activity (`ArtistRegistry.DORMANCY`), required before an
ESTATE or LOST_KEY [override](#override).

See: [identity and recovery](spec/identity-and-recovery.md).

## E

### economics resolver

The governed source of each [product](#product)'s fee terms, royalty rate, license and currency
(`EconomicsResolver`). Changes apply only to later mints and sales.

See: [economics and payouts](spec/economics-and-payouts.md).

### edition

A 6529 Stream Editions token ID, equal to its [edition master](#edition-master)'s Stream token
ID. Anyone creates it once the master's primary sale has settled.

See: [editions and sales](spec/editions-and-sales.md).

### edition auction

The uniform-price auction that sells an edition's copies (`UniformEditionAuction`): public,
firm bids of a quantity at a [step](#step-ladder), one [clearing price](#clearing-price), and
exactly as many copies as it sells. It runs beside the master's 1/1 and closes after it.

See: [editions and sales](spec/editions-and-sales.md).

### edition master

A 6529 Stream work of kind `EDITION_MASTER`: a 1/1 that also anchors one [edition](#edition).
Also called the master.

See: [editions and sales](spec/editions-and-sales.md).

### EIP-170

Ethereum's 24,576-byte limit on deployed code, which sets the content-store [chunk](#chunk)
size.

See: [`SSTORE2.sol`](../src/libraries/SSTORE2.sol).

### EIP-712

The standard for signing typed structured data, used by every protocol signature.

See: [ABIs and interface IDs](integrators/abis-and-interface-ids.md).

### EIP-2612

ERC-20 `permit`, an approval signed off-chain, accepted as a payment method.

See: [buying, bidding and settling](integrators/buying-bidding-settling.md).

### EIP-7702

Code delegation for EOAs. Installs and bindings reject delegated accounts
(`DelegatedEOA.isDelegated`).

See: [`DelegatedEOA.sol`](../src/libraries/DelegatedEOA.sol).

### EIP-7825

The per-transaction gas cap of 16,777,216. Every worst-case transaction is tested under it in
[Prague gas](#prague-gas).

See: [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#decision).

### encoding

How a content-store file's bytes relate to its media (`Encoding`): `Identity`, `Gzip`, `Base64`
or `GzipBase64`.

See: [storage](integrators/storage.md).

### entropy module

The optional contract that draws VRF seeds (`VrfEntropyModule`), one draw per content hash,
before the auction start.

See: [entropy](spec/entropy.md).

### entry hash

The identity of one statement-log entry, which other entries cite. Its index makes identical
statements distinct.

See: [disputes and statements](spec/disputes-and-statements.md).

### epoch

Either a [configuration epoch](#configuration-epoch) or a [signer epoch](#signer-epoch). Say
which.

### ERC-20

The fungible-token standard. Movements are checked by exact balance delta (`TokenTransfer`), so
fee-on-transfer and rebasing tokens revert.

See: [economics and payouts](spec/economics-and-payouts.md).

### ERC-165

Interface detection (`supportsInterface`), required of most install and binding targets.

See: [ABIs and interface IDs](integrators/abis-and-interface-ids.md).

### ERC-721

The NFT standard 6529 Stream implements; each token is one work.

See: [`Stream.sol`](../src/stream/Stream.sol).

### ERC-1155

The multi-token standard 6529 Stream Editions implements: each ID is an edition, each unit a
[copy](#copy).

See: [`Editions.sol`](../src/editions/Editions.sol).

### ERC-1271

Signature validation for contract accounts, accepted for every protocol signature with 200,000
gas (`SignatureVerifier.ERC1271_GAS_LIMIT`).

See: [`SignatureVerifier.sol`](../src/libraries/SignatureVerifier.sol).

### ERC-2098

The 64-byte compact ECDSA signature, accepted beside the 65-byte form.

See: [`SignatureVerifier.sol`](../src/libraries/SignatureVerifier.sol).

### ERC-2981

The NFT royalty standard (`royaltyInfo`), paying the [royalty rate](#royalty-rate) to the
[royalty wallet](#royalty-wallet).

See: [economics and payouts](spec/economics-and-payouts.md).

### ERC-4906

Metadata update events (`MetadataUpdate`, `BatchMetadataUpdate`), emitted when a work's metadata
may have changed.

See: [events and indexing](integrators/events-and-indexing.md).

### ERC-7572

Contract-level metadata (`contractURI`) on 6529 Stream and 6529 Stream Editions.

See: [reading a work](integrators/reading-a-work.md).

### errata repin

The only way to change a finalized work's renderer (`WorkRecords.repinRenderer`, 30 days), with
the lead artist's signature.

See: [rendering and tokenURI](spec/rendering-and-tokenuri.md).

### escrow

The revenue escrow (`RevenueEscrow`), which credits a wallet whose payment failed; anyone may
flush the credit to it. Governed recovery moves a credit only to an equivalent or consented
replacement.

See: [economics and payouts](spec/economics-and-payouts.md).

### established wallet

A wallet consolidated with an account in both directions for at least 30 days. It may stage a
[standard change](#standard-change) and gain [standing](#standing).

See: [identity and recovery](spec/identity-and-recovery.md).

### evidence hash

The hash a curation signer signs with a package root, committing to the published vote and
rules. An [override](#override) carries one too.

See: [curation](spec/curation.md).

### execution delay

The delay an AccessManager role holder waits between scheduling a governed call and executing it; every holder of a role carries its class delay.

See: [role and permission matrix](audit/roles.md).

## F

### file ID

A content-store file's name, the hash of its [content manifest](#content-manifest). It does not
depend on the chain.

See: [storage](integrators/storage.md).

### file role

A media file's role (`FileRole`): PRIMARY (the artwork, first), PREVIEW (a small still image) or
AUXILIARY.

See: [works and storage](spec/works-and-storage.md).

### finalize

The lead artist's `WorkRecords.finalize`, which makes the record immutable and [pins](#pin) the
current default renderer.

See: [works and storage](spec/works-and-storage.md).

### finding ID

An identifier such as MARKET-2 that names a finding of the internal adversarial review.

See: [known limitations](audit/known-limitations.md).

### fixed payee

A split-wallet payee named by `account`. Anyone may release its share to that account.

See: [economics and payouts](spec/economics-and-payouts.md).

### fullTokenURI

`IRenderer.fullTokenURI`: metadata with media inlined up to 1 MiB (`Renderer.MAX_INLINE_BYTES`),
for `eth_call`, with no gas promise.

See: [rendering and tokenURI](spec/rendering-and-tokenuri.md).

## G

### genesis

The one-transaction governance setup (`GovernanceConfigurator.configure`): roles, delays,
selectors and wiring, after which the configurator renounces ADMIN.

See: [governance](spec/governance.md).

### Glamsterdam

The Ethereum upgrade, active on Sepolia since 6 October 2026, that reprices state creation.
Foundry cannot measure it.

See: [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#problem).

### governance manifest

The signed JSON document describing one [configuration epoch](#configuration-epoch). Only its
hash is on-chain.

See: [governance](spec/governance.md).

### grant delay

How long a newly granted role takes to become active, never shorter than the role's execution delay.

See: [role and permission matrix](audit/roles.md).

### guardian

A holder of `Roles.GUARDIAN`, an independent Safe that cancels, pauses, vetoes and
[suspends](#suspension) at once. Guardians block, never redirect, and cannot lift a suspension.

See: [governance](spec/governance.md).

## H

### heartbeat

`ArtistRegistry.heartbeat`: recorded activity by the authority or an established wallet, which
resets [dormancy](#dormancy).

See: [identity and recovery](spec/identity-and-recovery.md).

## I

### increment floor

A currency's absolute minimum bid increment (`incrementFloor`). A bid must beat the high bid by
the larger of the floor and the increment share.

See: [stream and auctions](spec/stream-and-auctions.md).

### inline threshold

The largest primary file `tokenURI` inlines, in cost-weighted bytes (256 KiB by default,
`Renderer.DEFAULT_INLINE_THRESHOLD`).

See: [rendering and tokenURI](spec/rendering-and-tokenuri.md).

### item

One entry of a [package](#package) (`PackageItem`): everything voters approve and parties sign
for one work. It mints at most once.

See: [curation](spec/curation.md).

### item hash

An item's chain-independent identity (`WorksHashing.itemHash`), stored per token by 6529 Stream.

See: [curation](spec/curation.md).

### item kind

What an item mints (`ItemKind`): ORIGINAL or EDITION_MASTER.

See: [curation](spec/curation.md).

## K

### keeper

An automated account calling permissionless upkeep such as escrow `flush`. No v1 selector maps
to `Roles.KEEPER`.

See: [roles](audit/roles.md).

## L

### lead artist

The first party of every item. Its [active authority](#active-authority) signs the
[move](#move), edits the record and acts as [creator](#creator).

See: [curation](spec/curation.md).

### license

A work's SPDX license identifier plus the file ID of its full text (`License`). The default is
CC0.

See: [works and storage](spec/works-and-storage.md).

### license key

The `keccak256` of a lowercased SPDX ID (`WorksHashing.licenseKey`), on which licenses are
compared.

See: [works and storage](spec/works-and-storage.md).

### locator

A registered Arweave or IPFS copy of a media file (`Locator`), append-only, at most 16 per file
(`Limits.MAX_LOCATORS_PER_FILE`).

See: [storage](integrators/storage.md).

### LockedTerms

The terms the English auction locks for one sale: token, ID, currency, price, seller and fee terms.

See: [stream and auctions](spec/stream-and-auctions.md).

## M

### manifest

Either a [content manifest](#content-manifest) or a [governance manifest](#governance-manifest).
Say which.

### marketplace owner

The address `owner()` returns on 6529 Stream and 6529 Stream Editions, for marketplace
settings. It has no on-chain powers.

See: [stream and auctions](spec/stream-and-auctions.md).

### master

See [edition master](#edition-master).

### media hash

The hash of a work's ordered media list (`WorksHashing.mediaHash`), fixed by its package item.

See: [works and storage](spec/works-and-storage.md).

### minSetback

OpenZeppelin AccessManager's 5-day minimum wait (`minSetback()`) before a delay change takes
effect.

See: [governance](spec/governance.md).

### move

The lead artist's revocable EIP-712 `MoveToStream` signature authorizing a Stream mint, checked
at [consume](#consume).

See: [curation](spec/curation.md).

## N

### network fee

The network's share of a primary sale or royalty, locked per work at mint; 25,000 at launch for
6529 Stream and 6529 Stream Editions (`EconomicsResolver.DEFAULT_FEE_SHARE`).

See: [economics and payouts](spec/economics-and-payouts.md).

### new account

An account empty before a transaction and not after it, such as a contract creation, counted in
the gas reports.

See: [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#decision).

### new slot

A storage slot zero before a transaction and nonzero after it. CI asserts each operation's exact
count.

See: [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#decision).

### nonce

A single-use number a signature binds, revocable before use. No replay protection keys on
signature bytes.

See: [`Typehashes.sol`](../src/interfaces/types/Typehashes.sol).

## O

### on-chain complete

A work's one-way state once all its media is in the content store (`WorkRecords.syncOnChain`).
Only such works inline.

See: [works and storage](spec/works-and-storage.md).

### opening bid

A currency's governed minimum first bid (`openingBid`), locked by each auction at its start.

See: [stream and auctions](spec/stream-and-auctions.md).

### override

A governed identity change with 180 days' notice (`ArtistRegistry.OVERRIDE_DELAY`). The old key
cannot cancel it; a captured wallet [contests](#contest) it.

See: [identity and recovery](spec/identity-and-recovery.md).

## P

### package

The items an artist submits for curation, committed as one [package root](#package-root).
Approvals never expire, though roots can be [revoked](#revocation).

See: [curation](spec/curation.md).

### package root

The chain-independent Merkle root over a package's [item hashes](#item-hash).

See: [curation](spec/curation.md).

### party

An artist or collaborator an item names, 1 to 16 (`Limits.MAX_PARTIES`). Every party must
[accept](#acceptance), and every payee must be a party.

See: [curation](spec/curation.md).

### pause

A [dispute pause](#dispute-pause) of one auction, or an adapter pause (PAUSER) of new sales,
which `unpause` cannot end within 48 hours.

See: [stream and auctions](spec/stream-and-auctions.md).

### payout address

Where an artist's [artist-resolved](#artist-resolved-payee) payments go (`payoutAddress`),
changed only by a staged change or override.

See: [identity and recovery](spec/identity-and-recovery.md).

### payout freeze

`payoutAddress` returning zero while a pending change would move it, so split wallets hold the
artist's balance.

See: [identity and recovery](spec/identity-and-recovery.md).

### payout resolver

The contract split wallets ask for an artist's payout address: the artist registry, pinned by
code hash.

See: [economics and payouts](spec/economics-and-payouts.md).

### pending claim

See [pending delivery](#pending-delivery).

### pending delivery

An auction token whose delivery failed at settlement, held for a later `claimDelivery`. Also
called a pending claim.

See: [buying, bidding and settling](integrators/buying-bidding-settling.md).

### Permit2

Uniswap's signature-transfer contract. A `PERMIT2` payment's witness binds the action, so a
relayer can submit it.

See: [buying, bidding and settling](integrators/buying-bidding-settling.md).

### pin

To record an address with its code hash, so the protocol fails closed if the code changes.

See: [trust assumptions](audit/trust-assumptions.md).

### platform

The holder of `Roles.PLATFORM`, 6529's zero-delay key. It creates collections, adds locators
and appends platform statements, as the only writer of DISPUTE_OUTCOME; a guardian can
[suspend](#suspension) it.

See: [trust assumptions](audit/trust-assumptions.md).

### position

A bid's place in its step's queue in a capped [edition auction](#edition-auction): the units that
entered the step before it. A raise rejoins at the back of its new step.

See: [editions and sales](spec/editions-and-sales.md#the-cut-step).

### Prague gas

A whole transaction's gas priced with Prague's schedule, cold at the start: the unit of every
gas budget.

See: [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#decision).

### preferred locator

The copy `tokenURI` serves for a file (`preferredLocator`), chosen by the
[storage operator](#storage-operator)'s most specific setting.

See: [storage](integrators/storage.md).

### primary sale settled

A Stream token's flag, set by its minting adapter at settlement. It gates edition creation and
ends burnability.

See: [stream and auctions](spec/stream-and-auctions.md).

### PrimaryTerms

What a token tells a sale adapter about its primary sale: sale kind, currency, price, seller, fee
terms and [creator](#creator).

See: [economics and payouts](spec/economics-and-payouts.md).

### product

A scope for economics and uniqueness: `PRODUCT_STREAM`, `PRODUCT_EDITIONS` or
`PRODUCT_FEDERATED`.

See: [economics and payouts](spec/economics-and-payouts.md).

### profile

An artist identity's claimed 6529 profile ID and document hash, signed but not verified
on-chain.

See: [identity and recovery](spec/identity-and-recovery.md).

## R

### raise-only parameter

A gas parameter that may only rise, at most 2× per step, to a code-level ceiling
(`BoundedParameter`).

See: [entropy](spec/entropy.md).

### record

A work's descriptive JSON file in the content store, at most 12,288 bytes
(`Limits.MAX_RECORD_BYTES`), which the lead artist may replace until [finalize](#finalize).

See: [works and storage](spec/works-and-storage.md).

### record status

Why [core-only metadata](#core-only-metadata) is shown: `not_open`, `incomplete` or `invalid`.

See: [reading a work](integrators/reading-a-work.md).

### regression ceiling

An operation's Prague gas when ADR 0004 was accepted, plus about 2%. A change that crosses it
says why.

See: [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#decision).

### release

Paying a split-wallet payee its share. Anyone may release a fixed payee; only the payout address
releases an artist-resolved one.

See: [economics and payouts](spec/economics-and-payouts.md).

### relicense

A change of a work's license (`WorkRecords.relicense`, PARAMETER_SETTER, 48 hours) with every
party's consent. A CC0 work stays CC0 for good.

See: [works and storage](spec/works-and-storage.md).

### renderer

The immutable, stateless contract that builds `tokenURI` (`Renderer`). Works use the default
renderer until finalize pins one.

See: [rendering and tokenURI](spec/rendering-and-tokenuri.md).

### reserve

The amount a bid withdrawn during a dispute pause or currency freeze leaves behind: the next bid must reach it.

See: [stream and auctions](spec/stream-and-auctions.md#rules-and-invariants).

### reserved authority

An account a pending identity change would make an artist's authority (`reservedFor`). It
cannot register or become another artist's authority meanwhile.

See: [identity and recovery](spec/identity-and-recovery.md).

### resolver

The [economics resolver](#economics-resolver), [artist resolver](#artist-resolver) or
[payout resolver](#payout-resolver). Say which.

### restraint

The state in which `activeAuthorityOf` is zero because a pending override would move the
authority (IDENTITY-1). Nobody acts as the artist; running sales continue.

See: [identity and recovery](spec/identity-and-recovery.md).

### revocation

The guardian's immediate withdrawal of a package root's approval (`revokePackage`). A role
revocation is the AccessManager's `revokeRole`.

See: [curation](spec/curation.md).

### role

An AccessManager role from `Roles.sol`, whose holders carry its [delay class](#delay-class).
Statement speakers use a separate [statement role](#statement-role).

See: [roles](audit/roles.md).

### royalty rate

A work's ERC-2981 rate out of 100,000, 6,529 at launch (`EconomicsResolver.DEFAULT_ROYALTY_RATE`),
locked at mint.

See: [economics and payouts](spec/economics-and-payouts.md).

### royalty wallet

The split wallet that receives a work's royalties and pays the [seller wallet](#seller-wallet)
and the network fee.

See: [economics and payouts](spec/economics-and-payouts.md).

## S

### sale adapter

A shared contract that sells tokens through `IMintTarget`: the English auction and the
[edition auction](#edition-auction). It pays out with the escrow as fallback.

See: [buying, bidding and settling](integrators/buying-bidding-settling.md).

### sale ID

A sale's number in its adapter: a hash of `(token, tokenId)` (`saleIdOf`), on both auctions.

See: [architecture](architecture.md#identifiers-and-hashes).

### sale kind

A `bytes32` label naming a sale method, claimed by its adapter: `ENGLISH_AUCTION` or
`UNIFORM_AUCTION`. A token mints only for an admitted adapter of its terms' kind; `FIXED_PRICE`
and `DUTCH` are reserved labels of rc.1's removed adapters.

See: [`SaleTypes.sol`](../src/interfaces/types/SaleTypes.sol).

### satellite

A contract that serves 6529 Stream's core from outside it, chiefly [WorkRecords](#workrecords).

See: [architecture](architecture.md#modules).

### seed

The 32-byte value a seeded work's code reads (`seedOf`), passed to scripts in
[window.works](#windowworks).

See: [entropy](spec/entropy.md).

### seed policy

Where a work's seed comes from (`SeedPolicy`): NONE, ARTIST or VRF.

See: [entropy](spec/entropy.md).

### seller wallet

The split wallet of an item's payees, a predicted CREATE2 address that receives the seller
proceeds.

See: [economics and payouts](spec/economics-and-payouts.md).

### serial

A work's number within its [collection](#collection), from 1.

See: [stream and auctions](spec/stream-and-auctions.md).

### settle

`settle` on either auction, permissionless after the end. The English auction delivers the token,
pays out and marks the primary sale settled; the edition auction stores its clearing and pays
out, and claims then mint the copies.

See: [stream and auctions](spec/stream-and-auctions.md), [editions and sales](spec/editions-and-sales.md).

### signed release

A payee's EIP-712 `ReleaseAuthorization` that anyone may submit, with a revocable nonce.

See: [economics and payouts](spec/economics-and-payouts.md).

### signer epoch

The value a curation signer's approval must bind. A disable or re-enable starts a new one, so
older approvals never count again.

See: [curation](spec/curation.md).

### soft close

The edition auction's anti-snipe: a bid in its last window moves the close to that window after
the bid, never past a governed backstop.

See: [editions and sales](spec/editions-and-sales.md#timing-alongside-the-11).

### split wallet

An immutable pull-payment wallet (`SplitWallet`) whose CREATE2 address commits to its
[canonical payee list](#canonical-payee-list).

See: [economics and payouts](spec/economics-and-payouts.md).

### SSTORE2

Storing bytes as a contract's runtime code at a CREATE2 address salted by their hash.

See: [`SSTORE2.sol`](../src/libraries/SSTORE2.sol).

### standard change

An identity change of kind STANDARD, executable after 7 days (`ArtistRegistry.CHANGE_DELAY`).
The previous authority or a captured wallet may cancel it.

See: [identity and recovery](spec/identity-and-recovery.md).

### standing

A consolidated wallet's right to cancel or contest an artist's pending identity change. A
refresh records it once the consolidation is 30 days old, and it lasts 30 days
(`ArtistRegistry.STANDING_GRACE`) after the consolidation ends.

See: [identity and recovery](spec/identity-and-recovery.md).

### start

The permissionless auction start that mints (`EnglishAuction.start`, `startWithBid`): Stream
[consumes](#consume) the item and the clock starts.

See: [stream and auctions](spec/stream-and-auctions.md).

### start budget

The gas gate on a steady-state ETH `start`: at most 350,000 Prague gas and 6 new slots (7 with a
bid).

See: [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#the-table).

### state hash

A work's state commitment (`workStateHash`), which every finalize and amendment signature binds.

See: [works and storage](spec/works-and-storage.md).

### statement

One signed, permanent entry in the statement log (`Statement`): a [subject](#subject), a kind and
a content hash.

See: [disputes and statements](spec/disputes-and-statements.md).

### statement kind

A label of what a statement is (`StatementKinds`). `DISPUTE_OUTCOME`, `CURATION_EVIDENCE` and
`GOVERNANCE_MANIFEST` are reserved.

See: [disputes and statements](spec/disputes-and-statements.md).

### statement log

The append-only log of signed statements (`StatementLog`), which stores per subject only a
count, a [chain head](#chain-head) and the latest dispute outcome. A CURATOR or PLATFORM holder
with an execution delay cannot write at once or by relay, but could schedule the restricted
`appendCurator` or `appendPlatform` call.

See: [disputes and statements](spec/disputes-and-statements.md).

### statement role

Who a statement speaks as: ARTIST (per the [artist resolver](#artist-resolver)), OWNER, or a
zero-delay CURATOR or PLATFORM holder.

See: [disputes and statements](spec/disputes-and-statements.md).

### step ladder

The fixed prices an edition bid may name, step by step from a base price, from a table of E192
mantissas: exact, strictly increasing, and the same in every client.

See: [editions and sales](spec/editions-and-sales.md#the-step-ladder).

### sticky standing snapshot

Each artist's list of at most 16 wallets with [standing](#standing) (`standingOf`). Nothing is
evicted early, so a thief cannot strip it.

See: [identity and recovery](spec/identity-and-recovery.md).

### storage operator

The holder of `Roles.STORAGE_OPERATOR`, a zero-delay key that sets the
[preferred locator](#preferred-locator) settings.

See: [works and storage](spec/works-and-storage.md).

### subject

What a statement is about: `(token, id)`, or `(address(0), id)` for an item or package before a
token exists.

See: [disputes and statements](spec/disputes-and-statements.md).

### supersession

A statement naming an earlier [entry hash](#entry-hash) it replaces (`supersedes`), unchecked by
the log.

See: [disputes and statements](spec/disputes-and-statements.md).

### suspendable role

A role a guardian may [suspend](#suspension): PLATFORM, CURATOR or STORAGE_OPERATOR
(`Roles.isSuspendable`).

See: [governance](spec/governance.md).

### suspension

A guardian's immediate stop of a [suspendable role](#suspendable-role)'s holder
(`WorksAccessManager.suspend`, review finding GOV-2). Only an executed ADMIN grant or revocation
of that role (30 days, guardian-vetoable) or the holder's own `renounceRole` lifts it
(`WorksAccessManager._grantRole`, `_revokeRole`).

See: [governance](spec/governance.md).

## T

### target

A token contract a sale adapter may sell (`isTarget`), listed by governance (`setTarget`). In
AccessManager terms, a target is any contract the manager governs.

See: [editions and sales](spec/editions-and-sales.md), [governance](spec/governance.md).

### target admin delay

The delay before an ADMIN change to a governed contract's settings in the AccessManager (its selector roles, closure or authority) takes effect: 30 days for every target.

See: [governance](spec/governance.md).

### TDH

Total Days Held, the 6529 network's holding-based voting weight. The contracts never read it.

See: [trust assumptions](audit/trust-assumptions.md).

### The Memes

6529's existing ERC-1155 of Main Stage winners, outside this repository.

See: [ADR 0001 §2](adr/0001-v1-scope.md#2-network-tiers).

### token ID

A 6529 Stream work's ERC-721 ID, from one global sequence starting at 1, assigned when its
auction starts and never reused.

See: [stream and auctions](spec/stream-and-auctions.md).

### tokenURI

The ERC-721 metadata URI, built by the work's [renderer](#renderer) within an 8M-gas budget
(ADR 0004).

See: [rendering and tokenURI](spec/rendering-and-tokenuri.md).

### tombstone

The permanent mark on a burned item after a [content release](#content-release): it never
consumes again.

See: [disputes and statements](spec/disputes-and-statements.md).

## U

### uniqueness

The rule that a content hash belongs to at most one item per product; an edition reuses only its
master's.

See: [curation](spec/curation.md).

## V

### veto

The guardian's immediate deletion of a pending identity change (`vetoChange`). It blocks, never
redirects.

See: [identity and recovery](spec/identity-and-recovery.md).

### VRF

Verifiable random function: Chainlink VRF v2.5, through which the
[entropy module](#entropy-module) draws seeds.

See: [entropy](spec/entropy.md).

## W

### wave

A 6529 network discussion and voting space for curation and disputes. The contracts never read
one.

See: [ADR 0001 §12](adr/0001-v1-scope.md#12-disputes).

### window.works

The object `{ v: 1, tokenId, seed }` the renderer's page sets before a JavaScript primary runs, a
stable public API.

See: [rendering and tokenURI](spec/rendering-and-tokenuri.md).

### work

A 6529 Stream 1/1: its token and its record in [WorkRecords](#workrecords).

See: [reading a work](integrators/reading-a-work.md).

### work ID

A 6529 Stream token ID, as `createEdition` and `masterOf` use it.

See: [editions and sales](spec/editions-and-sales.md).

### WorkRecords

6529 Stream's records satellite (`WorkRecords`): record, media, license, seed, state hash,
renderer pin and locators.

See: [works and storage](spec/works-and-storage.md).

### WorksAccessManager

OpenZeppelin's `AccessManager` plus guardian [suspension](#suspension) and three cancel rules:
any guardian may cancel an operation (Rule 1), no account may cancel another's revocation of its
own role (Rule 2), and only a guardian may cancel another account's role revocation (Rule 3).

See: [governance](spec/governance.md).
