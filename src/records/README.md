# records

The single append-only, signed statement log for works. Each entry records the
subject, a statement kind, a schema hash, the content (a `HashRef` plus a URI,
or a `ContentStore` file) and the signer's role: artist, owner, curator or
platform. It carries artist statements, interviews, exhibition and
conservation records, storage-copy and fixity records, museum accession
records (including package hashes), curation evidence and dispute outcomes.
Governed by [ADR 0001](../../docs/adr/0001-v1-scope.md) §12 ("Statement log"),
with §3 (curation evidence hash) and §15 (museum source data), and by
[ADR 0002](../../docs/adr/0002-access-manager-hardening.md) §6 (governance
manifests).

| File | Role |
| --- | --- |
| `StatementLog.sol` | The log: append paths, EIP-712 relay, nonces, chain heads, dispute pointer. |
| [`IStatementLog`](../interfaces/IStatementLog.sol) (in `src/interfaces/`) | `Role`, `Statement`, events, errors and the external surface. |
| [`HashRef`](../interfaces/types/HashRef.sol) (in `src/interfaces/types/`) | `HashRef{algorithm, digest}` and the recognised algorithm IDs. |
| [`IArtistRoleResolver`](../interfaces/IArtistRoleResolver.sol) (in `src/interfaces/`) | The one question the log asks the artist registry. |
| [`StatementKinds`](../interfaces/types/StatementKinds.sol) (in `src/interfaces/types/`) | Well-known kind labels (constants only, no bytecode). |

## What is stored, what is emitted

Per subject the contract stores two words: the entry `count` and the chain
`head`, where `head' = keccak256(abi.encode(HEAD_DOMAIN, head, entryHash))` and
the first head is zero. Everything else is emitted in `StatementAppended`, in
full, so an indexer rebuilds a subject's history from logs and proves it
complete by matching `chainOf(token, id)`. Nothing is edited or deleted; there
is no pause, no admin write path and no value held.

**Subject.** `(token, id)`: a token contract and token ID, or `token ==
address(0)` and `id` a work ID that has no token yet (an approved package item).
`subjectKey = keccak256(abi.encode(token, id))`. The log does not link a
work-ID subject to the token-ID subject the work later becomes; the Stream or
the package registry holds that link, and a reader joins the two chains.

**Statement** (what is signed):

| Field | Rule |
| --- | --- |
| `kind` | Any non-zero `bytes32`. `StatementKinds` lists the well-known ones; new kinds need no deployment. Two are reserved, below. |
| `schema` | Non-zero hash of the schema the content follows. |
| `content` | `HashRef`: algorithm 1 keccak256, 2 SHA-256 or 3 BLAKE3, and a non-zero 32-byte digest. IDs 4 and 5 (RC1's variable-length multihash and CID) and 6 (an Arweave transaction ID, which is a locator, not a digest) are not accepted; put those identifiers in `uri`. |
| `uri` | At most 2,048 bytes of well-formed UTF-8. |
| `fileId` | A `ContentStore` file ID. **Exactly one** of a non-empty `uri` and a non-zero `fileId` is required (ADR 0001 §12: "a content hash plus URI, or a `ContentStore` file"). |
| `supersedes` | Entry hash of an earlier entry this one corrects or replaces, or zero. |

**Reserved kinds.** `DISPUTE_OUTCOME` may be written only under PLATFORM,
`CURATION_EVIDENCE` only under CURATOR, and `GOVERNANCE_MANIFEST` only through
`appendGovernanceManifest` (`ReservedKind` otherwise). Every other kind may be
written under any role, so consumers read `kind` together with `role`. The log keeps the latest `DISPUTE_OUTCOME` entry hash per subject
(`latestDisputeOutcome(token, id)`, one slot, written only for that kind), so a
renderer can show dispute status (ADR 0001 §12) without scanning events.

**Dispute outcomes.**
- **Subjects.** A `DISPUTE_OUTCOME` about an ERC-721 token (by ERC-165) needs
  the token to exist when it is recorded (`UnknownDisputeSubject` otherwise):
  not yet minted or burned tokens are refused. Every ERC-1155 subject is
  refused: an edition's outcome is recorded on its master, which the edition's
  metadata shows, and an outcome about a federated ERC-1155 work goes on its
  master or waits for v1.1. Subjects that are not tokens (an item before its mint, `(address(0), uint256(itemHash))`; a
  work ID; an artist in the artist registry) are not checked.
- **What `latestDisputeOutcome` answers: the display rule.** For a 6529 Stream
  token with no outcome of its own, it answers the latest outcome about the
  package item the token was minted from (one bounded `coreOf` read), so a
  pre-mint outcome is shown on the work and its edition.
  `disputeOutcomeOf(token, id)` answers the subject's own latest outcome, with
  no fallback, and its position in the subject's chain, so a caller that read
  `chainOf(token, id).count` earlier (when it paused a sale, for example) can
  tell whether the outcome was recorded since.
- **Precedence.** The latest outcome about the token is the work's current
  dispute status: it replaces every earlier outcome, about the token or about
  its item, in that answer and in the metadata. Earlier outcomes stay in the
  chain and its events. So each `DISPUTE_OUTCOME` document must state the
  status of every earlier dispute it keeps in force (a rejected second
  dispute restates an upheld first one) and cite the outcome it replaces in
  `supersedes`.

**Entry hash** (the identity other entries cite), all words ABI-encoded:

```
statementHash = EIP-712 hashStruct(Statement)          // type string in StatementLog.sol
entryHash = keccak256(abi.encode(
    keccak256("6529.works.StatementLog.entry.v1"),
    block.chainid, address(log), subjectKey, index, uint8(role), signer,
    resolver, uint64(recordedAt), statementHash))
head' = keccak256(abi.encode(keccak256("6529.works.StatementLog.head.v1"), head, entryHash))
```

`index` is the entry's zero-based position in the subject's chain, so identical
statements appended twice get different hashes. `resolver` is the artist
resolver that vouched for the signer on an ARTIST entry, and zero on every other
role. The event carries every input (`role`, `resolver`, `index`, `recordedAt`,
`signer`, the whole `Statement`) plus the resulting `entryHash` and `head`. A
relayed entry is followed by `StatementRelayed(entryHash, signer, nonce)`.
`test/records/StatementLogGolden.t.sol` pins every type hash, the digest, an
entry hash and a head as fixed hex values, produced by a pure-Python
implementation and checked against forge's own typed-data encoder; the model in
`test/records/StatementModel.sol` rebuilds hashes and heads from events.

**Supersession.** A correction is a new entry whose `supersedes` is the earlier
entry's hash. The log does not check that the hash exists in the same subject:
that would cost one more storage write per entry. Readers verify it against the
rebuilt chain, and decide whose corrections to honour.

## Who may write

| Role | Entry point | Rule |
| --- | --- | --- |
| ARTIST | `append(Role.ARTIST, s)` | `IArtistRoleResolver(artistResolver).isArtist(token, id, signer)`. Unset resolver means no artist statements. |
| OWNER | `append(Role.OWNER, s)` | `ownerOf(id) == signer` (ERC-721) or `balanceOf(signer, id) > 0` (ERC-1155), each read capped at `OWNER_READ_GAS` and 32 bytes of return data. Only a full 32-byte `ownerOf` answer is an ERC-721 answer; anything else falls through to `balanceOf`. Any failure means "not the owner". Any holder of an edition may speak as its owner. A work-ID subject has no owner. |
| CURATOR | `appendCurator(s)`, `restricted` | The AccessManager role mapped to that selector. |
| PLATFORM | `appendPlatform(s)`, `restricted` | The AccessManager role mapped to that selector. |
| PLATFORM, signed by the AccessManager | `appendGovernanceManifest(s)`, `restricted` | The only path for `GOVERNANCE_MANIFEST`. The subject must be `(authority(), 0)` and the kind `GOVERNANCE_MANIFEST`. Records `signer = authority()` and role PLATFORM. |
| any | `appendSigned(role, s, signer, nonce, deadline, sig)` | EIP-712 signature by `signer`, who must hold `role` by the rules above. Anyone may submit. |

**No statement is attributed to the AccessManager, with one exception.** If
the caller is the `authority()` (a scheduled `AccessManager.execute`, or the
manager holding an edition), the append reverts with `AuthorityCannotSign`. So
CURATOR and PLATFORM roles must have zero execution delay: a delayed role cannot
write at all, and a relayed statement from a delayed signer is refused.

**The exception is the governance manifest** (ADR 0002 §6): each post-genesis
configuration epoch publishes its manifest hash as a `GOVERNANCE_MANIFEST` entry,
scheduled through the AccessManager alongside the epoch's operations.
`appendGovernanceManifest` is the only path that may write that kind and the
only one where the manager may sign: it records `signer = authority()` and role
PLATFORM, under the subject `(authority(), 0)`, so the governance chain lives
under the manager's address. The statement carries the content as a hash plus a
URI or a file ID, with `supersedes` citing the previous epoch's entry. The caller
passes the subject and kind explicitly and the log rejects any other value
(`InvalidGovernanceManifest`), so a scheduled operation shows exactly what it
will record. Every other path still rejects both the kind and the manager as
signer, whoever calls.

### Trust boundary for ARTIST statements

No governance role has a *direct* path to an ARTIST or OWNER statement: those
roles never consult the AccessManager, and the restricted functions cannot write
them. That is the whole of the guarantee. ARTIST authority is **exactly as
strong as**:

1. the resolver's code, and whatever governs the resolver's answers (a resolver
   that forwards to a mutable backend is only as trustworthy as that backend);
2. `setArtistResolver(expected, next, codeHash)`, which can install a resolver
   that vouches for anyone; and
3. the AccessManager that can call it, including its power to replace this
   contract's authority (`AccessManager.updateAuthority`, which ends in
   `setAuthority`).

The install checks (compare-and-set, ERC-165, code present, not an EIP-7702
account, reviewed code hash) bind bytecode, not behaviour. The code hash is
checked again at every ARTIST authorization (`ResolverCodeHashMismatch`), not
only at install. What the log adds is
visibility: every ARTIST entry records the resolver that vouched for it, in its
entry hash and its event, and every swap emits `ArtistResolverSet`. A reader can
therefore discard or flag the entries of any resolver it does not trust. OWNER
authority is likewise only as strong as the token contract; subjects are keyed
by `(token, id)`, so consumers key on the official contract addresses.

Requirements that this places on other lanes:

- `setArtistResolver` **must map to the 30-day class** (verifier and
  successor-level swaps, ADR 0001 §13). The integrator enforces this in the
  deploy configuration; the log cannot.
- A resolver must be **immutable, or governed so that no answer is ever made
  true faster than the 30-day class**, with every change public (see
  `IArtistRoleResolver`). A guardian-vetoable withholding is allowed (ADR 0003
  owner decision 6: the artist registry withholds `isArtist` while a recovery
  override is pending).
- `appendGovernanceManifest` **must map to the 30-day class** and be scheduled
  through the AccessManager with the epoch's operations. The log cannot enforce
  the delay, which belongs to the mapping: a zero-delay mapping would let its
  role holder write a manager-signed entry at once.
- Wire `appendCurator` and `appendPlatform` to the curator and platform roles
  with zero execution delay. Until the manager maps them, its default applies
  and only ADMIN_ROLE can call them. TODO: use the role IDs from
  `src/governance/Roles.sol` once it exists.

## Relay

`appendSigned` verifies, in order: deadline (inclusive), nonce unused, signature
(`SignatureVerifier`: low-s ECDSA, ERC-2098, EIP-7702 delegated accounts,
ERC-1271 with a gas cap), then the signer's role. The nonce is spent in the same
transaction as the append, so a failed append spends nothing. Nonces are a
per-signer bitmap; `revokeNonce(n)` spends one before use. `authorizationDigest`
returns the digest to sign. The domain is `EIP712("6529 Works Statement Log",
"1")`, so the chain ID and contract address are bound:

```
Authorization(uint8 role,address signer,uint256 nonce,uint64 deadline,Statement statement)
Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)
HashRef(uint16 algorithm,bytes32 digest)
```

## Gas

Execution gas with cold storage and accounts (add the 21,000 intrinsic and
calldata), from `test_Gas_PerAppend`:

| Call | Gas |
| --- | --- |
| `append` ARTIST, first entry of a subject | ~76K |
| `append` ARTIST, later entry | ~37K |
| `append` OWNER (ERC-721) | ~36K |
| `appendCurator` | ~40K |
| `appendSigned`, same / new nonce word | ~52K / ~69K |

An unmodified OpenZeppelin ERC-721 or ERC-1155 read costs about 2.6K gas cold,
against the 50K `OWNER_READ_GAS` cap (`StatementLogOwnerRead.t.sol` pins the
margin from both sides).

## Limits and decisions

- Subjects are open: any `token` address is accepted, because only the signer's
  role is checked.
- `fileId` is opaque here; the content lane owns the `ContentStore` ID format.
- Not here: removal, editing, pausing, or an on-chain check that a `supersedes`
  target exists.

Tests: `test/records/` (unit, fuzz, golden vectors, handler-based invariants).
