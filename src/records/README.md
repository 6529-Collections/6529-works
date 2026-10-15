# records

The statement log: one append-only, signed log in which artists, owners, curators and the
platform publish statements about a work, an approved item, an artist or the governance chain.
It carries artist statements, provenance and fixity records, curation evidence, dispute
outcomes and governance manifests, and answers a work's current dispute status for the
renderer. The rules are in [Disputes and statements](../../docs/spec/disputes-and-statements.md)
(`DSP-1` to `DSP-12`); the formulas for the entry hash, the chain head and the EIP-712 digest
are under [Relayed artist statement](../../docs/spec/disputes-and-statements.md#relayed-artist-statement).

## Files

| File | What it is |
| --- | --- |
| `StatementLog.sol` | The log: the append paths per role, the EIP-712 relay and its nonces, the per-subject hash chain, the latest dispute outcome per subject. Holds no value; no pause, no edit, no delete. |
| [`IStatementLog`](../interfaces/IStatementLog.sol) | `Role`, `Statement`, events, errors and the external surface. |
| [`HashRef`](../interfaces/types/HashRef.sol) | The content hash type and its three accepted algorithm IDs. |
| [`StatementKinds`](../interfaces/types/StatementKinds.sol) | Well-known kind labels (constants only); three are reserved: `DISPUTE_OUTCOME`, `CURATION_EVIDENCE` and `GOVERNANCE_MANIFEST`. |
| [`IArtistRoleResolver`](../interfaces/IArtistRoleResolver.sol) | The one question the log asks about ARTIST statements; `ArtistRegistry` implements it. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| An artist (via the resolver) or a token owner | `append(role, statement)` | DSP-2, DSP-3, DSP-6, DSP-7 |
| The CURATOR and PLATFORM keys | `appendCurator`, `appendPlatform` (restricted, zero delay at genesis) | DSP-3, DSP-4 |
| Anyone, relaying a signer's EIP-712 authorization | `appendSigned(role, statement, signer, nonce, deadline, signature)`; the signer may `revokeNonce` | DSP-9 |
| Governance, once per configuration epoch | `appendGovernanceManifest` (30 days), the only writer of `GOVERNANCE_MANIFEST` and the only path where the AccessManager is the signer | DSP-4, DSP-5 |
| Governance | `setArtistResolver(expected, next, codeHash)` | DSP-8 |
| The renderer, the auction, the artist registry (views) | `latestDisputeOutcome` (with the item fallback), `disputeOutcomeOf` (own outcome and its chain index), `chainOf` | DSP-12 |

Selectors, roles and delays are in the [role matrix](../../docs/audit/roles.md#statementlog);
events in [StatementLog events](../../docs/integrators/events-and-indexing.md#statementlog).

## Developer notes

- **Storage per subject.** `Chain` is two words: the entry count and the index of the latest
  dispute outcome share one, the chain head is the other. A subject with a dispute outcome
  also has one word in `_latestDispute` (the entry hash). Relay nonces are a per-signer bitmap,
  256 to a word. Everything else is in `StatementAppended`, so an indexer rebuilds and proves a
  subject's history from events against `chainOf`.
- **Hash changes are breaking.** The type strings, domain tags, entry hash and head are pinned
  as fixed hex by [`StatementLogGolden.t.sol`](../../test/records/StatementLogGolden.t.sol),
  produced by an independent Python implementation and checked against forge's typed-data
  encoder. Signers and indexers compute the same values.
- **Where the AccessManager is consulted.** Only for CURATOR and PLATFORM, by `restricted` on
  the direct paths and by `canCallWithDelay` on the relay (an immediate answer only). ARTIST
  and OWNER never consult it, which is the whole of the "no governance path to an artist
  statement" guarantee; keep it that way. The trust boundary for ARTIST entries is in
  [trust assumptions](../../docs/audit/trust-assumptions.md#resolvers-and-renderer-pins).
- **Owner reads** forward `OWNER_READ_GAS` (50,000) and accept 32 bytes; only a full 32-byte
  `ownerOf` answer counts as ERC-721, anything else falls through to `balanceOf`.
  [`StatementLogOwnerRead.t.sol`](../../test/records/StatementLogOwnerRead.t.sol) pins the
  margin of a stock OpenZeppelin read (about 2.6K cold) against the cap from both sides.
- **Supersession is not checked on-chain** (one more write per entry); readers verify
  `supersedes` against the rebuilt chain (LIM-CNT-12 in
  [known limitations](../../docs/audit/known-limitations.md#content-records-and-rendering)).
- **Gas:** `test_Gas_PerAppend` in [`StatementLog.t.sol`](../../test/records/StatementLog.t.sol)
  prints each path's execution gas; the spec holds the gated figure.
- **Bytecode:** wide margin; figures in the
  [audit scope](../../docs/audit/scope.md#curation-identity-and-records).
- **Tests:** `forge test --match-path 'test/records/**'`: unit, policy, golden vectors and a
  handler-based invariant suite whose model ([`StatementModel.sol`](../../test/records/StatementModel.sol))
  rebuilds hashes and heads from events. Dispute paths end to end:
  [`Dispute.t.sol`](../../test/integration/Dispute.t.sol). Coverage and mutation testing:
  [Testing](../../docs/testing/README.md).

## See also

[ADR 0001 §12](../../docs/adr/0001-v1-scope.md#12-disputes) (statement log, disputes), §3
(curation evidence) and §15; [ADR 0002](../../docs/adr/0002-access-manager-hardening.md)
decision 6 (governance manifests); [governance spec, configuration epochs](../../docs/spec/governance.md#configuration-epochs-and-governance-manifests);
[known limitations](../../docs/audit/known-limitations.md) LIM-GV-10.
