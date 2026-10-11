# identity

The slim artist registry (`artistId`, authority address, profile document hash,
6529 profile ID) through which artist payouts resolve, and the consolidation
adapter that reads the 6529 delegation contract's registration and expiry
dates directly. Identity and payout changes wait 7 days, cancellers are
captured at staging, and contested changes, estates and lost keys use the
180-day public override. Signatures are checked with the shared verifier in
`libraries/`. Governed by
[ADR 0001 §11](../../docs/adr/0001-v1-scope.md#11-artist-identity-and-recovery),
including its "Hardening" decisions.

## Contracts

| Contract | Role |
| --- | --- |
| `ArtistRegistry` | `IArtistRegistry` and `IArtistRoleResolver`, plus the economics lane's `IArtistPayoutResolver` (`payoutAddress`, also reported through ERC-165). |
| `ConsolidationAdapter` | `IConsolidationSource` over the 6529 delegation contract `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`, use case 999, all collections. |

## Lifecycle

1. **Register.** The bound package registry calls `register` on an artist's
   first acceptance. The artist ID is `uint256(uint160(first authority))`, and
   the payout starts as the authority. An account's artist ID is
   `artistIdOf(account)` when non-zero, otherwise `uint160(account)`.
2. **Stage a STANDARD change.** The authority, or a wallet consolidated with it
   for at least 30 days, signs the EIP-712 `IdentityChange` payload: the
   artist ID, the next identity (authority, payout, profile ID, profile
   document hash), the artist's nonce and a deadline. A new authority
   countersigns the same digest. Anyone relays it with `stageChange`, which
   consumes the nonce and captures the cancellers.
3. **Wait 7 days.** Until then, these can stop the change:
   - the previous authority (`cancelChange`);
   - any wallet captured at staging (`cancelChange`);
   - the guardian (`vetoChange`, veto only).
4. **Execute.** Anyone calls `executeChange` once it is due. Split wallets then
   pay the new payout address, including balances already accrued.

**Overrides.** CONTESTED, ESTATE and LOST_KEY overrides:
- are staged by the PARAMETER_SETTER role with an evidence hash;
- wait 180 days;
- if they change the authority, carry the new authority's `OverrideAcceptance`
  signature (single-use, with a deadline);
- for ESTATE and LOST_KEY, need a year without signed activity.

Only captured wallets and the guardian can stop an override, never the old
key. An override replaces a pending STANDARD change, so a key holder cannot
block one by keeping a change staged.

**Preventive revocation.** `revokeNonce` burns the current nonce, voiding every
unused payload signed for it.

## Who may call what

| Function | Caller |
| --- | --- |
| `register` | the bound package registry only |
| `stageChange` | anyone, relaying the authority's or an established wallet's signature |
| `stageOverride` | PARAMETER_SETTER (48 hours) |
| `cancelChange` | a captured wallet, or the previous authority for a STANDARD change |
| `vetoChange` | GUARDIAN (immediate); it can only delete a pending change |
| `executeChange` | anyone, once due |
| `heartbeat` | the authority, an established wallet, or the bound package registry |
| `revokeNonce` | the authority or an established wallet |
| `setConsolidationSource` | SUCCESSOR_SETTER (30 days), compare-and-set; requires code, ERC-165 and no EIP-7702 delegation |
| `bindPackageRegistry`, `bindStream`, `bindFederationRegistry` | the admin, once each (genesis wiring), then locked |
| `listFederatedContract` | the bound v1.1 federation registry only |

## Consolidation standing

A wallet is established for an account when both have registered a
consolidation of the other for all collections, and in each direction some
registration is at least 30 days old and has `expiryDate > now`. The vendored
`checkConsolidationStatus` ignores both age and expiry, so the adapter reads
the delegation contract's public getters itself:
- `delegatorHashes` for the account's delegate list;
- `globalDelegationHashes` for each pair's registrations and dates.

A revocation deletes every registration of a pair, so a stored registration
has been live since its date.

The walks are bounded:
- 32 delegate entries scanned;
- 4 registrations read per direction;
- at most 16 wallets captured.

Each getter call forwards a fixed 50,000 gas through `BoundedCall`, and reverts
if the caller cannot supply it. A gas-starved transaction therefore cannot
truncate the canceller set. Entries a key holder appends later cannot displace
the wallets consolidated before a compromise, which sit at the front of the
list.

## Trust and failure modes

- **Guardian.** It can block any pending change but has no path that writes an
  identity.
- **Governance.** It can stage overrides, but captured wallets can cancel them
  and the guardian can veto them. Overrides that change the authority need the
  new authority's signature.
- **Profile fields.** The profile ID and profile document hash are the
  artist's claims. They are bound into signatures but not verified against
  6529 profiles.
- **Stolen key.** A thief holding the key can cancel a STANDARD recovery (the
  ADR allows the old key to cancel). Recovery then goes through a CONTESTED
  override, which the old key cannot cancel.
- **Thief's own consolidation.** A thief who keeps a key long enough can
  establish a consolidation of their own. That wallet would then be captured as
  a canceller of later overrides. See the PR's open questions.

## Gas

These figures are measured with cold storage in
`test/identity/ArtistRegistry.t.sol` and
`test/identity/ConsolidationAdapter.t.sol`. Both cases are far inside the
16,777,216-gas transaction cap.
- `stageChange` with 16 captured wallets after a 32-entry scan: about 2.2M gas.
- `establishedWallets` at its full worst case (32 entries with maximal reads):
  about 1.9M gas.
