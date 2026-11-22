# curation

The package registry and the v1 curation verifier: how a network-approved package of works is
registered, accepted by every party, moved to 6529 Stream by its lead artist and admitted once
at the auction start. The package registry is 6529 Stream's mint policy
([`IMintPolicy`](../interfaces/core/IMintPolicy.sol), ADR 0010): the sale contract calls it,
then mints in Stream with the facts it answers; Stream never calls it. The rules are in
[Curation](../../docs/spec/curation.md) (`CUR-*`); the signer's off-chain obligations are under
[Trust obligations of the curation signer](../../docs/spec/curation.md#trust-obligations-of-the-curation-signer).

## Files

| File | What it is |
| --- | --- |
| `PackageRegistry.sol` | Package roots and their status, party acceptances (and identity creation), move signatures and nonces, the verifier swap, the kill of a signer's registered approvals, the edition-sale approval check ([`IItemApprovals`](../interfaces/IItemApprovals.sol)), and, as 6529 Stream's mint policy ([`IMintPolicy`](../interfaces/core/IMintPolicy.sol)), the item rules, the VRF seed, the terms of a new work (`MintFacts`, `MintTerms`) and the content rules after an upheld dispute (`releaseContent`, `releasedTo`, `isBarred`). Implements [`IPackageRegistry`](../interfaces/IPackageRegistry.sol). |
| `Eip712CurationVerifier.sol` | The v1 [`ICurationVerifier`](../interfaces/ICurationVerifier.sol): an EIP-712 `PackageApproval` by an active `CURATION_SIGNER` over its current signer epoch; the network's one-way `disableSigner` and `enableSigner`. |

Item hashes and leaves come from [`WorksHashing`](../interfaces/types/WorksHashing.sol), type
strings from [`Typehashes`](../interfaces/types/Typehashes.sol), edition-terms validity from
[`EditionRules`](../editions/EditionRules.sol).

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Anyone | `registerPackage(root, evidenceHash, attestation)` with the signer's approval | CUR-2 to CUR-5 |
| Anyone, relaying a party's proof (`abi.encodePacked(wallet, signature)`) | `acceptPackage(root, acceptance, proof)`; the first acceptance of an account calls `ArtistRegistry.register` | CUR-7, CUR-19 |
| A wallet of the artist's account | `revokeMove(artistId, nonce)` | CUR-11 |
| An edition sale opening (view) | `isApprovedItem(root, itemHash, proof)` | CUR-24 |
| An active minter of the bound Stream (the English auction), at the start | `authorize(token, request)`, then `IStream.mint(custody, facts)`; `preview` answers the same unverified | CUR-1, CUR-6, CUR-8 to CUR-10, CUR-12, CUR-14 |
| The entropy module (views) | `packageOf`, `consumedItemOf` for its request gate | ENT-1 in [Entropy](../../docs/spec/entropy.md#rules-and-invariants) |
| The network | `revokePackage`, `killSignerApprovals`, `setVerifier`, `setEntropyModule`, `releaseContent`, `disableSigner`, `enableSigner`; the genesis binds `bindStream` | CUR-15 to CUR-18, CUR-23; [role matrix](../../docs/audit/roles.md#packageregistry) |

The call sequences (approve and register, acceptance, move and start, release)
are under [Flows](../../docs/spec/curation.md#flows).

## Developer notes

- **Single use.** An item mints once because Stream keeps one live token per content hash
  (`tokenOfContent`). When that token was burned (an upheld dispute), the content mints again
  only after `releaseContent` names the burned token and a beneficiary, only for an item whose
  lead artist is the beneficiary, and never by the burned item, which the release bars
  (`isBarred`). A release is used up by the next mint.
- **Open item values.** `PackageItem.kind`, `seedPolicy` and `Party.role` are `uint8`s, so the
  permanent contracts decode any value; this policy refuses, for a new item, any kind, seed
  policy or party role it does not know (`InvalidItem`, `InvalidSeedPolicy`; CUR-9). A successor
  policy may accept new values.
- **Start-path budget.** `authorize` runs inside every auction start, so it is held to its
  [ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table) row (one new slot,
  a regression ceiling). Its external calls are the lead artist's `activeAuthorityOf` (a move
  signed by the root is verified here; any other wallet of the account goes through
  `requireSigned`, a non-default path that reads the consolidation source), Stream's
  `isMinter` and `tokenOfContent`, the resolver's `newWorkTerms` (two `walletFor` derivations)
  and, for a VRF item, the entropy module's delivery and seed;
  consent is read from `acceptedAs`. The kill epoch sits beside `stream`, a word the start
  reads anyway. Adding a call or a write
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
  `PackageRegistryGas.t.sol`, which measures `authorize` cold, directly and as Stream calls it);
  Halmos proofs of the signer-epoch encoding in `test/symbolic/` ([Testing](../../docs/testing/README.md)); end to end,
  `CuratedSale.t.sol`.

## See also

[ADR 0001 §3](../../docs/adr/0001-v1-scope.md#3-curation-and-approved-packages) (with the §6
linked-pair exception), [ADR 0003](../../docs/adr/0003-build-time-decisions.md); the
[differences from the ADRs](../../docs/spec/README.md#differences-from-the-adrs) (`CUR-*` rows);
[known limitations](../../docs/audit/known-limitations.md#trust-and-governance) LIM-GV-1 to
LIM-GV-3; [threat model](../../docs/audit/trust-assumptions.md).
