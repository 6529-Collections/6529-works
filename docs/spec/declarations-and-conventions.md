# Declarations and conventions

Conventions that tooling, front ends, venues and indexers build on the deployed contracts, with no
contract logic of their own: a declarations document each work can carry, a conservation floor the
curation signer checks, statement kinds for proposed content changes, catalogue entries,
citations and custody attestations, an off-chain control proof, and a fact sheet for each work.

> Pre-audit. See the [project status](../../README.md#status).

> **Conventions, not contract rules.** No contract enforces anything on this page beyond the
> contract rules it cites. A document that breaks a convention is still accepted on chain; readers
> apply the rules below (LIM-CNT-13). The work powers are read through `IWorkPowers`, which the
> RECORDS module `WorkRules` implements ([ADR 0006](../adr/0006-work-powers-and-conventions.md)).

## Contracts

| Contract | What the conventions use |
| --- | --- |
| [`StatementLog`](../../src/records/StatementLog.sol) | Every convention statement (`append`, `appendSigned`, `appendPlatform`); `chainOf`, `latestDisputeOutcome`, `artistResolver` |
| [`StatementKinds`](../../src/interfaces/types/StatementKinds.sol) | The convention kind labels ([registry](disputes-and-statements.md#statement-kind-registry)) |
| [`WorkFacts`](../../src/core/WorkFacts.sol) | `factsOf` (media, record, license, finalized, on-chain complete, pinned renderer, locks); `RecordOpened` |
| [`WorkRules`](../../src/records/WorkRules.sol), [`WorkDelivery`](../../src/stream/WorkDelivery.sol) | `renouncedPowers` (`IWorkPowers`, DCL-8); the delivery module's locators for each file |
| [`ContentStore`](../../src/content/ContentStore.sol) | `fileInfo`, `read`, `isComplete`, `sha256Of` |
| [`DependencyRegistry`](../../src/content/DependencyRegistry.sol) | `resolve` (a declared dependency's file, and whether it is deprecated) |
| [`Stream`](../../src/core/Stream.sol) | `ownerOf`, `workOf`, `rendererOf`, `tokenOfContent`; `WorkMinted` (content hash, package root) and `PrimarySale` (price) |
| `Accounts` ([`IArtistRegistry`](../../src/interfaces/IArtistRegistry.sol)), [`ConsolidationAdapter`](../../src/identity/ConsolidationAdapter.sol) | The profile document hash, the account's root, pending changes, the consolidation source |
| [`EnglishAuction`](../../src/sales/EnglishAuction.sol), [`UniformEditionAuction`](../../src/sales/UniformEditionAuction.sol) | `pendingDelivery`; `saleIdOf`, `clearing` (primary prices) |

The JSON Schemas (Draft 2020-12) are in [`schemas/`](schemas/), with an example of each document in
[`schemas/examples/`](schemas/examples/). [`tools/conventions/`](../../tools/conventions/README.md)
implements the rules in Python (standard library only) for front ends, venues and the signer to
copy or test against; this page is the authority where the two differ.

## What the code fixes

- A kind is any nonzero `bytes32`; only `DISPUTE_OUTCOME`, `CURATION_EVIDENCE` and
  `GOVERNANCE_MANIFEST` are reserved (DSP-4). Readers enforce each convention kind's writer.
- ARTIST is any wallet of the lead artist's account, only for a Stream work or an edition (through
  its master) (ID-11): there is no ARTIST statement about an item before mint or about the artist
  subject.
- OWNER is the ERC-721 owner, else any ERC-1155 holder, read when the entry is appended.
- A statement carries a hash and one locator (a URI of at most 8,192 bytes, or a content-store
  file ID). The log never reads the document.
- The renderer uses only the PRIMARY file, the first PREVIEW image and the license text; no other
  AUXILIARY file reaches `tokenURI`.
- The media list (file ID, SHA-256, role per entry) is committed by the item's media hash, which
  the signer attests; `WorkFacts.open` opens only that list and nothing changes it afterwards.
  The declared SHA-256 is never recomputed on chain, so the signer checks it.

## Document format

**DCL-1.** Every convention document is UTF-8 JSON in RFC 8785 canonical form with a `v` member
and, for a statement document, a `subject` naming the statement's chain ID, token and token ID.
The statement's `kind` is the label hash, `schema` is `keccak256` of the schema's `$id`
(`urn:6529-works:schema:<name>:v1`), `content` is SHA-256 (algorithm 2) of the document, and the
locator is an `ar://` or `ipfs://` address or a complete content-store file. A document is at most
65,536 bytes; a `uint256` member is a decimal string of at most 2<sup>256</sup> − 1.

**DCL-2.** A reader counts a convention statement only after it rebuilds the subject's chain from
`StatementAppended` and proves it against `chainOf`, keys the subject on the official address,
checks the kind's role (for ARTIST, a resolver the deployment installed), fetches the document and
checks its hash, canonical form, schema and `subject`, and follows `supersedes` only within the
same subject, kind and role.

## The declarations document

**DCL-3.** A work's declarations document is the one AUXILIARY media file with MIME type
`application/vnd.6529-works.declarations+json`, stored `Identity` in one chunk (at most 24,575
bytes), following [`declarations.v1`](schemas/declarations.v1.schema.json) with `contentHash`
equal to the work's. Two make the declarations `ambiguous`. The media hash fixes it from approval.
Its sections, all optional: `conservation` (DCL-4, DCL-5), `custodians` and `citations` (DCL-6,
DCL-18, DCL-21, DCL-22), `timeCapsule` (DCL-7) and `livingWork` (DCL-9). Examples:
[still image](schemas/examples/declarations.json),
[generative](schemas/examples/declarations-generative.json),
[time capsule](schemas/examples/declarations-time-capsule.json).

### The conservation floor

**DCL-4.** The floor is the minimum set of preservation facts a work states; each may be waived
with a reason:

| Fact | Content | Applies to |
| --- | --- | --- |
| `storage` | For every media file but the declarations: file ID, SHA-256, and at least two storage receipts of distinct network or provider, each saying whether it holds the `stored` stream or the `decoded` media | every work |
| `format` | MIME type; width and height for images and video; duration for time-based media | every work |
| `license` | License identifier and SHA-256 of its full text | every work |
| `generative` | Renderer address and code hash, dependencies (name, version, file ID), seed policy, runtime | a work whose primary file is a script type, whose record lists dependencies, or whose seed policy is not `NONE` |
| `display` | Aspect ratio, background, looping, sound, interaction | every work |

**DCL-5.** Approval rules are wave policy, not code ([ADR 0001 §3](../adr/0001-v1-scope.md#3-curation-and-approved-packages)).
When a wave runs the check, the signer's tooling, before it attests: refuses two declarations
files; requires the file `Identity`, complete, canonical, schema-valid and naming the content
hash; checks each unwaived fact (a `stored` copy by its bytes against the committed chunk hashes,
a `decoded` copy by its SHA-256, and each file's declared SHA-256 tied to its chunks at least once;
MIME types against `fileInfo`; the license key and text hash; the renderer and its code hash, each
dependency through `DependencyRegistry.resolve` in the record's order, the seed policy); refuses
a time capsule outside policy or whose ciphertext is not an AUXILIARY media file; and requires
distinct custodians and well-formed citations. The exact procedure is `check_floor` in
[`tools/conventions/`](../../tools/conventions/README.md).

**DCL-33.** When it runs the check, the signer publishes each item's result as a
[`floor-result.v1`](schemas/floor-result.v1.schema.json) object in the `conservationFloor` member
of its `CURATION_EVIDENCE` document about the package root. A fact sheet uses it only when it is
valid, names the work's item hash and names the declarations file the sheet found; otherwise every
fact is `unmet`.

### Custodians, citations, time capsule, work powers, living work

- **DCL-6.** Birth custodians and citations are the artist's approved claims.
- **DCL-7.** A time capsule is unenforced: nothing on chain decrypts or checks the date. Its
  ciphertext is an AUXILIARY media file. It is outside the v1 curation policy until the owner
  approves it.
- **DCL-8.** The work powers, in bit order: `ROYALTY_RATE` (bit 0, stops `WorkRules.setRoyaltyRate`),
  `RELICENSE` (bit 1, stops `WorkRules.relicense`), `RENDERER_REPIN` (bit 2, stops
  `WorkRules.repinRenderer`; only after finalize). `IWorkPowers.renouncedPowers(tokenId)` reports
  which are renounced; without `IWorkPowers` a reader shows them as not available.
- **DCL-9.** A living work's change emits no ERC-4906 event; readers re-render at
  `suggestedRefreshSeconds` or date their cached image.

## Proposed content change (1/1 only)

A display-only way for the artist to offer, and the owner to accept, new content for a 1/1. The
token's media, content hash and `tokenURI` never change.

- **DCL-10.** A `CONTENT_CHANGE_PROPOSAL` counts only as ARTIST about a Stream token
  ([schema](schemas/content-change-proposal.v1.schema.json)); a later proposal with
  `withdrawn: true` withdraws it.
- **DCL-11.** A `CONTENT_CHANGE_ACCEPTANCE` counts only as OWNER about the same token, naming an
  earlier valid, unwithdrawn, unexpired proposal by entry hash
  ([schema](schemas/content-change-acceptance.v1.schema.json)); `decision: "restore"` returns to
  the approved content.
- **DCL-12.** The latest valid acceptance decides the display; a reader checks the fetched bytes'
  SHA-256 and keeps the approved content one action away.
- **DCL-13.** An acceptance survives a transfer, labelled by who accepted it.
- **DCL-14.** A burned token has no display; a dispute outcome is always shown.
- **DCL-15.** Editions never take a content change (every holder passes the OWNER check); a
  proposal whose bytes were minted as another work (`Stream.tokenOfContent`) is flagged.

## Catalogue and citations

- **DCL-16.** A `CATALOGUE_ENTRY` counts only as ARTIST about a Stream token; the latest per work
  wins; two works of one artist sharing a `catalogueNumber` are both flagged.
- **DCL-17.** The artist-wide catalogue ([`catalogue.v1`](schemas/catalogue.v1.schema.json)) is
  named by hash from the artist's profile document, which changes only through a staged identity
  change.
- **DCL-18.** A `CITATION` counts only as ARTIST about the citing work, when well formed
  (schema-valid, nonzero chain ID, not the work itself), and is the citing artist's claim.

## Custody attestations for a physical twin

**DCL-19.** A custodian signs EIP-712 typed data, domain `{name: "6529 Works Custody Attestation",
version: "1", chainId}` with no verifying contract:

```text
CustodyAttestation(address token,uint256 tokenId,bytes32 objectId,uint8 status,uint64 asOf,address successor,bytes32 evidenceHash)
```

`status` is 1 HELD, 2 RELEASED (to `successor`), 3 MISSING or 4 DESTROYED. Type hash
`0x3dc91787a59cbc3117d2a54785ad6b184b56a9699733e6713675770b4787fe15`; the
[example](schemas/examples/custody-attestation.json) is signed by public Anvil test account 0
(digest `0xa03cc2c3767834df2ef6c583fd5d08e6d65ddd616d2f90a96e0ad8e00e152e2a`).

- **DCL-20.** It counts posted by OWNER, ARTIST or PLATFORM, with a valid custodian signature
  (verified as `SignatureVerifier` does), only for the work it names.
- **DCL-21.** The latest `asOf` counts (the later entry on a tie); more than one hour after the
  entry's time is discarded; older than the custodian's `maxAttestationAgeDays` (365 days if
  unnamed) is stale; a named custodian with no attestation is `NONE`.
- **DCL-22.** Only a named custodian, or the successor in a recognized custodian's latest RELEASED
  attestation, is recognized.

## Control proof

An off-chain challenge and response by which a venue checks that the person in front of it
controls the wallet that holds a work. Nothing is written on chain.

**DCL-23.** EIP-712, domain `{name: "6529 Works Control Proof", version: "1", chainId}`:

```text
ControlProof(string venue,bytes32 nonce,uint64 issuedAt,uint64 expiresAt,uint256 chainId,address token,uint256 tokenId,address holder,address signer)
```

Type hash `0x551abbed9e673b4462640aaa67f046692206a5f53883fb9c6187674681c102eb`; the
[example](schemas/examples/control-proof.json) is signed by Anvil test account 0 (digest
`0x2548db021144b031169071ded42000449c5128184168ca0bd94e5d56c4e0a057`).

- **DCL-24.** The verifier issues a fresh nonce valid for at most 10 minutes, then on the response
  first claims the stored challenge by nonce atomically (spending it), requires the response to
  equal it, checks the time window (60 seconds of skew), builds the digest with its own chain ID,
  verifies the signature, and reads ownership at a recent block (`ownerOf`, or `balanceOf` for an
  edition; while a sold 1/1 awaits delivery, `EnglishAuction.pendingDelivery` names the buyer).
- **DCL-25.** A hot signer proves a cold holder only through the accounts module's consolidation
  source (`isConsolidated`: a live two-way consolidation, no minimum age).

<a id="fact-sheet"></a>

## Fact sheet

A fact sheet states what is recorded about one work and who can change what, generated off chain
from reads at one block, with no warnings or scores
([`fact-sheet.v1`](schemas/fact-sheet.v1.schema.json), [example](schemas/examples/fact-sheet.json)).

- **DCL-26.** Every read is made at one block; the content hash and package root come from
  `WorkMinted` (no view returns them).
- **DCL-27.** Roles and delays come from the generated [role matrix](../audit/roles.md) and the
  deployment's events, never from this page; rows dropped once they no longer apply (before or
  after finalize, CC0 license, a recorded sale outcome, a renounced power).
- **DCL-28.** The sheet distinguishes: record not open, open or finalized; on-chain complete;
  disputed (token or item); sale outcome NONE, SOLD, UNSOLD or RESCUED; each power; declarations
  absent, valid, invalid, ambiguous or unreadable; each floor fact; display changed; custody
  recognized, fresh or stale.

## Primary price history

**DCL-32.** A 1/1's price is only in the log (`Stream.PrimarySale`, `EnglishAuction.SaleSettled`;
[AUC-8](stream-and-auctions.md#rules-and-invariants)); an edition's is
`UniformEditionAuction.clearing(saleIdOf(editions, editionId))` and `AuctionCleared`. An
edition's ID is its master's token ID. Secondary sales are not recorded.

## Rules and invariants

Every rule here is applied off chain; none is a contract invariant.

| ID | Rule | Applied by | Supported on chain by |
| --- | --- | --- | --- |
| DCL-1 | Convention documents are canonical JSON with `v` and `subject`; `schema` is the hash of the `$id`; content is SHA-256; at most 65,536 bytes; a `uint256` string is at most 2<sup>256</sup> − 1. | Writers' tooling; readers | DSP-2 |
| DCL-2 | A convention statement counts only after chain proof, official subject, the kind's role, a trusted resolver, hash, schema and subject checks, and supersession within kind and role. | Readers | DSP-1, DSP-7, DSP-10 |
| DCL-3 | The declarations document is the one AUXILIARY file of its MIME type, `Identity`, one chunk, matching the content hash, and complete in the content store when the signer attests; fixed from approval. | Signer's tooling; readers | WS-2, WS-6, WS-25 |
| DCL-4 | The floor's facts, each waivable with a reason; each storage receipt declares the form of the bytes it holds; a stored copy reproduces the committed chunks. | Artists' tooling | none |
| DCL-5 | Current practice: the signer checks the floor before attesting: stored copies by their bytes against the committed chunks, and each file's declared SHA-256 tied to its chunks once (WS-30); generative by script MIME type, non-empty record dependencies or seed policy; dependencies resolved by their bytes32 labels and compared in order; custodians distinct by (address, object); citations well formed. | Curation signer | The evidence hash the package registry stores ([curation](curation.md#concepts)); DSP-4 |
| DCL-6 | Birth custodians and citations are the artist's approved claims. | Readers | WS-6 |
| DCL-7 | A time capsule is unenforced, its ciphertext is an AUXILIARY media file, and it is outside the v1 curation policy until the owner approves it. | Curation signer; readers | WS-6 |
| DCL-8 | The work powers are `ROYALTY_RATE`, `RELICENSE` and `RENDERER_REPIN`, in bit order; which are renounced comes from `IWorkPowers.renouncedPowers`. | Readers | WS-37, WS-38 |
| DCL-9 | A living work's change emits no refresh event; readers re-render or date their cache. | Readers | none |
| DCL-10 | A proposal counts only as ARTIST about a 6529 Stream token. | Readers | ID-11, DSP-7 |
| DCL-11 | An acceptance counts only as OWNER about the same token, citing an earlier valid proposal. | Readers | DSP-6 |
| DCL-12 | The latest valid acceptance decides the display; withdrawal undoes it; `tokenURI` never changes. | Readers | WS-6 |
| DCL-13 | An acceptance survives a transfer, labelled by who accepted it. | Readers | none |
| DCL-14 | Burns and dispute outcomes prevail over the display. | Readers | DSP-12 |
| DCL-15 | Editions never take a content change; proposed bytes minted as another work are flagged. | Readers | DSP-11 subject rules; `tokenOfContent` |
| DCL-16 | A catalogue entry counts only as ARTIST; the latest per work wins; duplicate numbers within one artist's works are flagged. | Readers | ID-11 |
| DCL-17 | The artist-wide catalogue is named from the profile document. | Artists; readers | ID-5, ID-6, ID-11 |
| DCL-18 | A citation counts only as ARTIST about the citing work, only when well formed (schema-valid, non-zero chain ID, not the work itself), and is shown as the citing artist's claim. | Readers | ID-11 |
| DCL-19 | Custody attestations are the typed data above. | Custodians' tooling | none |
| DCL-20 | A custody attestation counts as posted by OWNER, ARTIST or PLATFORM, only with a valid custodian signature, and only for the work it names. | Readers | DSP-3, DSP-6 |
| DCL-21 | The latest `asOf` counts, the later entry on a tie; future-dated is discarded; older than the allowed age is stale; a named custodian with no attestation is `NONE`. | Readers | none |
| DCL-22 | Only a named custodian, or the successor in a recognized custodian's latest attestation when it is RELEASED, is recognized. | Readers | WS-6 |
| DCL-23 | Control proofs are the typed data above, in the domain of the token's chain. | Venues; wallets | none |
| DCL-24 | The verifier first claims the issued challenge atomically, spending the nonce; the response must equal it; the verifier builds the digest with its own chain ID and checks the time window, the signature and ownership at a recent block. | Venues | none |
| DCL-25 | A consolidated signer proves a cold holder only through the registry's consolidation source (`isConsolidated`: a live two-way consolidation, no minimum age). | Venues | ID-2, ID-4 |
| DCL-26 | A fact sheet reads everything at one block; the content hash comes from `WorkMinted`. | Sheet generators | none |
| DCL-27 | Roles and delays on a fact sheet come from the role matrix and the deployment's events; the generator applies the six row rules. | Sheet generators | GV-2, GV-15 |
| DCL-28 | The fact sheet distinguishes the states listed, including a record not yet open. | Sheet generators | none |
| DCL-32 | Primary prices come from the reads and events listed. | Readers | AUC-8, EA-11 |
| DCL-33 | When it runs the check, the signer publishes each item's floor result as `floor-result.v1` in the curation evidence; a fact sheet uses it only when it matches the work and its declarations, and otherwise shows every fact `unmet`. | Curation signer; sheet generators | DSP-4 |
## Parameters and limits

| Parameter | Value | Rule |
| --- | --- | --- |
| Declarations MIME type and size | `application/vnd.6529-works.declarations+json`; `Identity`, at most 24,575 bytes | DCL-3 |
| Other convention documents | at most 65,536 bytes | DCL-1 |
| Storage receipts per file | at least 2, of distinct network or provider | DCL-4, DCL-5 |
| Script MIME types (a generative work) | `text/html`, `text/javascript`, `application/javascript`, `text/ecmascript`, `application/ecmascript`, `image/svg+xml` | DCL-4, DCL-5 |
| Work powers | `ROYALTY_RATE` (1), `RELICENSE` (2), `RENDERER_REPIN` (4) | DCL-8; [`IWorkPowers.sol`](../../src/interfaces/IWorkPowers.sol) |
| Custody age, future skew | 365 days for an unnamed custodian; 1 hour | DCL-21 |
| Control proof validity | at most 10 minutes; 60 seconds of skew | DCL-24 |

## References

- Schemas and examples: [`schemas/`](schemas/); reference tools:
  [`tools/conventions/`](../../tools/conventions/README.md).
- ADRs: [ADR 0001 §3](../adr/0001-v1-scope.md#3-curation-and-approved-packages),
  [§12](../adr/0001-v1-scope.md#12-disputes), [ADR 0006](../adr/0006-work-powers-and-conventions.md)
  (the grade it named was removed on 16 November 2026; the fact sheet replaced the promise card).
- Related: [disputes and statements](disputes-and-statements.md), [works and storage](works-and-storage.md),
  [curation](curation.md), [identity and recovery](identity-and-recovery.md),
  [reading a work](../integrators/reading-a-work.md).
