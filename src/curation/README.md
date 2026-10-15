# curation

The package registry and the v1 curation verifier: how a network-approved package of works is
registered, accepted by every party, moved to 6529 Stream by its lead artist and consumed once
at the auction start, and how 6529 Editions claims a master's content. The rules are in
[Curation](../../docs/spec/curation.md) (`CUR-*`); the signer's off-chain obligations are under
[Trust obligations of the curation signer](../../docs/spec/curation.md#trust-obligations-of-the-curation-signer).

## Files

| File | What it is |
| --- | --- |
| `PackageRegistry.sol` | Package roots and their status, party acceptances (and identity creation), move signatures and nonces, consume-once and content uniqueness for Stream, the Editions content claim, the post-dispute content release, the verifier swap. Implements [`IPackageRegistry`](../interfaces/IPackageRegistry.sol). |
| `Eip712CurationVerifier.sol` | The v1 [`ICurationVerifier`](../interfaces/ICurationVerifier.sol): an EIP-712 `PackageApproval` by an active `CURATION_SIGNER` over its current signer epoch; the guardian's one-way `disableSigner` and the governed `enableSigner`. |

Item hashes and leaves come from [`WorksHashing`](../interfaces/types/WorksHashing.sol), type
strings from [`Typehashes`](../interfaces/types/Typehashes.sol), edition-terms validity from
[`EditionRules`](../editions/EditionRules.sol).

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone | `registerPackage(root, evidenceHash, attestation)` with the signer's approval | CUR-2 to CUR-5 |
| Anyone, relaying a party's signature | `acceptPackage(root, acceptance, signature)`; the first acceptance of an account calls `ArtistRegistry.register` | CUR-7, CUR-19 |
| The artist's active authority | `revokeMove(artistId, nonce)` | CUR-11 |
| The bound Stream, inside `mint` | `consume(root, item, proof, move)` at the auction start; `releaseContent` after an upheld dispute | CUR-1, CUR-6, CUR-8 to CUR-10, CUR-12, CUR-14 |
| The bound Editions | `claimContent(contentHash, itemHash)` | CUR-13 |
| The entropy module (views) | `packageOf`, `consumedItemOf` for its request gate | ENT-1 in [Entropy](../../docs/spec/entropy.md#rules-and-invariants) |
| Governance | `revokePackage`, `setVerifier`, `disableSigner`, `enableSigner`; the genesis binds `bindStream`, `bindEditions` | CUR-15 to CUR-18; [role matrix](../../docs/audit/roles.md#packageregistry) |

The call sequences (approve and register, acceptance, move and start, content claim, release)
are under [Flows](../../docs/spec/curation.md#flows).

## Developer notes

- **Storage.** `consume` writes one new slot, `_streamItems[contentHash] = itemHash`, which is
  both the consume-once record and the uniqueness record. A release sets that slot to the
  marker `RELEASED`, tombstones the burned item (`_released`) and records the artist the content
  is reserved for (`_releasedTo`); the reservation is read only on a released slot, so a fresh
  `consume` pays nothing for it. Editions claims live in a separate
  map (`_editionItems`), so the linked pair is the one cross-product reuse of a content hash.
- **Start-path budget.** `consume` runs inside every auction start, so it is held to its
  [ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table) row (one new slot,
  a regression ceiling). Its only external call is the lead artist's `activeAuthorityOf`;
  consent is read from `acceptedAs`, never from the artist registry. Adding a call or a write
  here moves every `start` row of the gas report.
- **Move nonces.** A per-artist bitmap of 255 nonces per word with a sentinel in bit 255; the
  acceptance that creates an identity writes the sentinel into word 0, so tools use nonces
  sequentially from 0 and the first 255 starts write no new slot for the nonce.
- **Gotchas.** Revocation is per root, not per item; a verifier swap never re-checks registered
  roots; the verifier's code hash is re-checked at every registration; a retired verifier can
  never be reinstalled. Each is a rule above; keep the tests that pin them.
- **Bytecode:** comfortable margin; figures in the
  [audit scope](../../docs/audit/scope.md#curation-identity-and-records).
- **Tests:** `forge test --match-path 'test/curation/**'` (unit, the registry invariant suite and
  `PackageRegistryGas.t.sol`, which measures `consume` cold, directly and as Stream calls it);
  end to end, [`CuratedSale.t.sol`](../../test/integration/CuratedSale.t.sol).

## See also

[ADR 0001 §3](../../docs/adr/0001-v1-scope.md#3-curation-and-approved-packages) (with the §6
linked-pair exception), [ADR 0003](../../docs/adr/0003-build-time-decisions.md); the
[differences from the ADRs](../../docs/spec/README.md#differences-from-the-adrs) (`CUR-*` rows);
[known limitations](../../docs/audit/known-limitations.md#trust-and-governance) LIM-GV-1 to
LIM-GV-3; [threat model](../../docs/audit/threat-model.md).
