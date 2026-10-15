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
  its auction, Stream's governed `releaseContent` (PARAMETER_SETTER, 48 hours)
  names the rightful artist the dispute outcome identifies: the hash is reserved
  for that artist, so only an item whose lead artist it is may consume it
  (`ContentReserved` otherwise), and the burned item is tombstoned for good.
  The release happens once per burned item and names a registered artist
  (`UnknownArtist` otherwise), so it is scheduled once the rightful artist has
  an identity; `releasedTo` reads the beneficiary.
- **`Eip712CurationVerifier`.** It accepts a `PackageApproval(packageRoot,
  evidenceHash, signerEpoch)` EIP-712 signature by an active curation signer,
  encoded exactly as `abi.encode(signer, signature)`, and reports that signer. A
  signer is active while it holds `Roles.CURATION_SIGNER` with no execution
  delay and the guardian has not disabled it. Disabling is immediate and
  one-way; re-enabling is in the 30-day class. Deployments grant the role to at
  least two keys. The signature binds the signer's current `signerEpoch`: the
  time its role grant took effect, how many times it was disabled or enabled,
  and a salt drawn from `block.prevrandao` at each of those changes. An approval
  made before a disable (or under a revoked grant of the role) never counts
  again, and one signed while the signer is disabled cannot name the epoch its
  re-enable will start. The signer re-signs what it still approves; tooling
  reads `signerEpoch(signer)` before signing.
- **VRF media revisions.** A revision of a VRF work that changes its primary
  media has a new content hash, so it draws a new seed. Before approving such
  a revision of a work whose seed was delivered, the guardian revokes the old
  root.
- **Stopping a signer.** `disableSigner` (GUARDIAN, immediate) is the way to
  stop a signer, and only it, or revoking the role and granting it again, ends
  an epoch. An ADMIN change of the signer's execution delay makes it inactive
  while the delay is nonzero but keeps its epoch. After any suspected
  compromise, use a fresh key: disable the old one and grant the role to a new
  address.

**Governance.** The genesis configurator, which holds ADMIN with no delay until
it renounces it, binds Stream and Editions (`bindStream`, `bindEditions`, each
once and independently; each must answer ERC-165 for its interface). The
guardian revokes roots at once, including a root not yet registered (a leaked
attestation), which can then never be registered. Revocation is per root, not
per item: an item listed in two roots stays consumable through the other, so
the guardian revokes every root that lists it. Disabling a curation signer
stops only future registrations. The verifier is swapped through the 30-day
class: compare-and-set, ERC-165 checked, code-hash pinned, never a no-op, and
never back to a verifier installed before (a replaced verifier is retired). The
pinned hash is checked again at every registration (`InvalidDependency`), so
code that replaced the reviewed code at the verifier's address registers
nothing.

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

**Gas.** `consume` sits on the auction start path, whose budget is 350K Prague
gas and at most 6 new slots (7 with a bid) per steady-state start
([ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md)). It writes
one of those slots
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
