# curation

The package registry and the v1 curation verifier. Governed by
[ADR 0001 §3](../../docs/adr/0001-v1-scope.md#3-curation-and-approved-packages),
with the linked-pair exception from §6.

- **`PackageRegistry`.** A package root is a Merkle root over item leaves
  (`WorksHashing`: ABI-encoded items, double-hashed leaves). Anyone registers a
  root that the verifier approves, and the registry records its evidence hash
  and signer. Every listed party signs the root (`acceptPackage`); the first
  acceptance of an account creates its artist identity. The bound 6529 Stream
  consumes each item once at its auction start, after checking the proof, every
  party's acceptance, the canonical payee list and the lead artist's revocable
  "move to Stream" signature (a deadline and a per-artist nonce bitmap). The
  bound 6529 Editions claims an edition's content hash, which must be the hash
  its master item consumed on Stream. When an upheld dispute burns a work during
  its auction, Stream calls `releaseContent`: the hash becomes free for its
  rightful artist, and the burned item is tombstoned for good.
- **`Eip712CurationVerifier`.** It accepts a `PackageApproval(packageRoot,
  evidenceHash)` EIP-712 signature by an active curation signer, encoded exactly
  as `abi.encode(signer, signature)`, and reports that signer. A signer is
  active while it holds `Roles.CURATION_SIGNER` with no execution delay and the
  guardian has not disabled it. Disabling is immediate and one-way; re-enabling
  is in the 30-day class. Deployments grant the role to at least two keys.

**Governance.** The genesis configurator, which holds ADMIN with no delay until
it renounces it, binds Stream and Editions (`bindStream`, `bindEditions`, each
once and independently; each must answer ERC-165 for its interface). The
guardian revokes roots at once, including a root not yet registered (a leaked
attestation), which can then never be registered. Revocation is per root, not
per item: an item listed in two roots stays consumable through the other, so
the guardian revokes every root that lists it. Disabling a curation signer
stops only future registrations. The verifier is swapped through the 30-day
class: compare-and-set, ERC-165 checked, code-hash pinned, never a no-op.

**Consent is per account.** An acceptance is recorded as
`acceptedAs[root][account] = artistId` for the account that the item lists,
signed by that account's artist's current authority. An item that lists an
artist under a different address (for example a new authority after recovery)
needs an acceptance for that address too, and an item that lists two accounts of
the same artist is invalid. The first acceptance relayed sets a new identity's
profile, so pre-signed acceptances with different profile fields succeed only in
the order a relayer submits them. Only that first acceptance counts as activity
for the artist registry's dormancy clock; later acceptances and move signatures
do not, to keep the auction start cheap.

**Move nonces are sequential.** Each artist's nonces live in a bitmap of 255 per
word. The acceptance that creates the identity pre-writes word 0, so tools
should use nonces 0, 1, 2… per artist: the first 255 starts then update an
existing slot instead of creating one.

**Gas.** `consume` sits on the 300K auction start. It writes one fresh slot
(Stream's content hash → item hash, which is both the consume-once record and
the uniqueness record), reads consent from `acceptedAs`, and makes one external
call: the lead artist's current authority.
`test/curation/PackageRegistryGas.t.sol` measures it cold, directly and in the
call shape Stream uses.

**Trust.** Content uniqueness keys on the item's declared `contentHash`, the
decoded SHA-256 of its primary media, never on a file ID. The contracts cannot
recompute that hash, so the check is defense in depth: the curation signer
verifies every declared SHA-256 against the decoded bytes before attesting, and
the evidence hash covers that check.
