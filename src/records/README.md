# records

The single append-only, signed statement log for works. Each entry records the
subject, a statement kind, a schema hash, the content (a `HashRef` plus a URI,
or a `ContentStore` file) and the signer's role: artist, owner, curator or
platform. It carries artist statements, interviews, exhibition and
conservation records, storage-copy and fixity records, museum accession
records (including package hashes), curation evidence and dispute outcomes.
Governed by [ADR 0001](../../docs/adr/0001-v1-scope.md) §12 ("Statement log"),
with §3 (curation evidence hash) and §15 (museum source data).

| File | Role |
| --- | --- |
| `StatementLog.sol` | The log: append paths, EIP-712 relay, nonces, chain heads. |
| `IStatementLog.sol` | `Role`, `Statement`, events, errors and the external surface. |
| `HashRef.sol` | `HashRef{algorithm, digest}` and the recognised algorithm IDs. |
| `IArtistRoleResolver.sol` | The one question the log asks the artist registry. |
| `StatementKinds.sol` | Well-known kind labels (constants only, no bytecode). |

## What is stored, what is emitted

Per subject the contract stores two words: the entry `count` and the chain
`head`, where `head' = keccak256(abi.encode(head, entryHash))` and the first
head is zero. Everything else is emitted in `StatementAppended`, in full, so an
indexer rebuilds a subject's history from logs and proves it complete by
matching `chainOf(token, id)`. Nothing is edited or deleted; there is no
pause, no admin write path and no value held.

**Subject.** `(token, id)`: a token contract and token ID, or `token ==
address(0)` and `id` a work ID that has no token yet (an approved package item).
`subjectKey = keccak256(abi.encode(token, id))`.

**Statement** (what is signed):

| Field | Rule |
| --- | --- |
| `kind` | Any non-zero `bytes32`. `StatementKinds` lists the well-known ones; new kinds need no deployment. |
| `schema` | Non-zero hash of the schema the content follows. |
| `content` | `HashRef`: algorithm 1 keccak256, 2 SHA-256, 3 BLAKE3 or 6 Arweave tx ID, and a non-zero 32-byte digest. IDs 4 and 5 (RC1's variable-length multihash and CID) are unused; put those identifiers in `uri`. |
| `uri` | At most 2,048 bytes of well-formed UTF-8; may be empty. |
| `fileId` | A `ContentStore` file ID, or zero. Only one of `uri` and `fileId` may be set; neither is a bare hash commitment. |
| `supersedes` | Entry hash of an earlier entry this one corrects or replaces, or zero. |

**Entry hash** (the identity other entries cite), all words ABI-encoded:

```
statementHash = EIP-712 hashStruct(Statement)          // type string in StatementLog.sol
entryHash = keccak256(abi.encode(
    keccak256("6529.works.StatementLog.entry.v1"),
    block.chainid, address(log), subjectKey, index, uint8(role), signer,
    uint64(recordedAt), statementHash))
```

`index` is the entry's zero-based position in the subject's chain, so identical
statements appended twice get different hashes. The event carries every input
(`role`, `index`, `recordedAt`, `signer`, the whole `Statement`) plus the
resulting `entryHash` and `head`. Tests rebuild both from events with an
independent model (`test/records/StatementModel.sol`) and compare to storage.

**Supersession.** A correction is a new entry whose `supersedes` is the earlier
entry's hash. The log does not check that the hash exists in the same subject:
that would cost one more storage write per entry. Readers verify it against the
rebuilt chain, and decide whose corrections to honour. A kind is likewise not
tied to a role, so consumers must read `kind` together with `role`.

## Who may write

| Role | Entry point | Rule |
| --- | --- | --- |
| ARTIST | `append(Role.ARTIST, s)` | `IArtistRoleResolver(artistResolver).isArtist(token, id, signer)`. Unset resolver means no artist statements. |
| OWNER | `append(Role.OWNER, s)` | `ownerOf(id) == signer` (ERC-721) or `balanceOf(signer, id) > 0` (ERC-1155), each read gas- and size-capped; any failure means "not the owner". A work-ID subject has no owner. |
| CURATOR | `appendCurator(s)`, `restricted` | The AccessManager role mapped to that selector. |
| PLATFORM | `appendPlatform(s)`, `restricted` | The AccessManager role mapped to that selector. |
| any | `appendSigned(role, s, signer, nonce, deadline, sig)` | EIP-712 signature by `signer`, who must hold `role` by the rules above. Anyone may submit. |

**Admins can never write ARTIST or OWNER statements.** Those two roles never
consult the AccessManager, and the restricted functions cannot write them, so no
governance role, the admin role included, is a path to either. Tests cover a
direct and a relayed admin attempt, an admin holding every governed role, and an
invariant campaign that has the admin, curator and platform try on every run.
The one governed lever is `setArtistResolver(expected, next, codeHash)`: it is
`restricted`, compare-and-set, pinned to a reviewed code hash and checked for
ERC-165, code and EIP-7702 delegation. Give it the 30-day verifier class. Zero
switches ARTIST statements off.

**Wiring (governance lane).** The AccessManager maps `appendCurator` and
`appendPlatform` to the curator and platform roles. Until it does, the manager's
default applies and only ADMIN_ROLE can call them. TODO: use the role IDs from
`src/governance/Roles.sol` once it exists. Both roles should have zero execution
delay: a relayed CURATOR or PLATFORM statement is accepted only for a signer
with no delay, and a call run through `AccessManager.execute` records the
manager as the signer.

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
| `append` ARTIST, first entry of a subject | ~73K |
| `append` ARTIST, later entry | ~34K |
| `append` OWNER (ERC-721) | ~33K |
| `appendCurator` | ~39K |
| `appendSigned`, same / new nonce word | ~46K / ~63K |

## Limits and decisions

- Subjects are open: any `token` address is accepted, because only the signer's
  role is checked. Consumers key on the official Stream, Editions and (later)
  registered federated contract addresses.
- `fileId` is opaque here; the content lane owns the `ContentStore` ID format.
- Not here: removal, editing, pausing, kind-to-role rules, or an on-chain check
  that a `supersedes` target exists.

Tests: `test/records/` (unit, fuzz, handler-based invariants).
