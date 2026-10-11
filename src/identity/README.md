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
| `ArtistRegistry` | `IArtistRegistry`, which is also the statement log's `IArtistRoleResolver` and the split wallets' `IArtistPayoutResolver`. |
| `ConsolidationAdapter` | `IConsolidationSource` over the 6529 delegation contract `0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`, use case 999, all collections. |

**The registry address never changes.** Split wallets pin it immutably. When
ADR §11 says "the identity source can be swapped", the swap happens inside the
registry, through `setConsolidationSource`. The registry is never redeployed or
replaced.

## Lifecycle

1. **Register.** The bound package registry calls `register` on an artist's
   first acceptance. The artist ID is `uint256(uint160(first authority))`, and
   the payout starts as the authority. An account's artist ID is
   `artistIdOf(account)` when non-zero, otherwise `uint160(account)`.
2. **Stage a STANDARD change.** The authority, or a wallet consolidated with it
   for at least 30 days, signs `Typehashes.IDENTITY_CHANGE`: the artist ID, the
   next identity (authority, payout, profile ID, profile document hash), the
   artist's nonce and a deadline. A new authority countersigns the same digest.
   Anyone relays it with `stageChange`, which consumes the nonce and captures
   the cancellers.
3. **Wait 7 days.** Until then, these can stop the change:
   - the previous authority (`cancelChange`);
   - any wallet captured at staging (`cancelChange`);
   - the guardian (`vetoChange`, veto only).
4. **Execute.** Anyone calls `executeChange` once it is due.

**Overrides.** CONTESTED, ESTATE and LOST_KEY overrides:
- are staged by the PARAMETER_SETTER role with an evidence hash;
- wait 180 days;
- if they change the authority, carry the new authority's
  `Typehashes.OVERRIDE_ACCEPTANCE` signature (single-use, with a deadline, and
  free of the artist nonce, so a held key cannot void it);
- for ESTATE and LOST_KEY, need a year without signed activity.

Only captured wallets and the guardian can stop an override, never the old
key. An override replaces a pending STANDARD change, so a key holder cannot
block one by keeping a change staged.

**Preventive revocation.** The authority's `revokeNonce` burns the current
nonce, voiding every unused payload signed for it.

## Payout freeze

`payoutAddress(artistId)` returns zero while either of these is pending:
- an override;
- a STANDARD change that moves the payout.

Split wallets refuse to release on zero, so accrued balances wait for the
outcome instead of following a contested redirect.

This is what stops a thief holding a stolen key from pulling accrued balances
during a 180-day recovery override. The thief's key is still the payout, and
the old key cannot cancel the override.
`test_Attack_ThiefCannotPullDuringARecoveryOverride` demonstrates this.

**Trade-off.** The artist's own withdrawals also pause for the window: 7 days,
or 180 for an override. Someone holding the key can re-freeze them by staging
again after each cancel; the guardian veto and the override path end that.

A change that keeps the payout, such as an authority or profile change, does
not freeze it. Artist-resolved split payees are pull-only (economics lane):
only the current `payoutAddress`, or a signature from it, can release.

## Payout validation

Because artist payees are pull-only, some payouts would strand or stall funds.
These are rejected at registration, at staging, and again at execution:
- the zero address;
- this registry;
- the bound package registry;
- 6529 Stream and its Editions;
- any split wallet the bound split factory deployed (`isWallet`).

Limitations:
- A split wallet's predicted CREATE2 address cannot be detected on-chain before
  deployment. The re-check at execution catches one deployed while a change
  waits. Tools should also check `walletFor` off-chain.
- Other routers, such as the claim router, are not bound and are not checked.

## Who may call what

| Function | Caller |
| --- | --- |
| `register` | the bound package registry only |
| `stageChange` | anyone, relaying the authority's or an established wallet's signature |
| `stageOverride` | PARAMETER_SETTER (48 hours) |
| `cancelChange` | a captured wallet, or the previous authority for a STANDARD change |
| `vetoChange` | GUARDIAN (immediate); it can only delete a pending change |
| `executeChange` | anyone, once due |
| `heartbeat` | the authority or an established wallet |
| `revokeNonce` | the authority |
| `setConsolidationSource` | SUCCESSOR_SETTER (30 days), compare-and-set; requires the reviewed code hash, ERC-165 and no EIP-7702 delegation |
| `bindPackageRegistry`, `bindStream`, `bindFederationRegistry` | the admin, once each (genesis wiring), then locked; each target must answer ERC-165 for its interface |
| `bindSplitFactory` | the admin, once (genesis wiring), then locked; requires code (the factory has no ERC-165) |
| `listFederatedContract` | the bound v1.1 federation registry only |

**Signed activity** is what resets the one-year dormancy clock:
- registration;
- a staged change;
- a heartbeat;
- a cancel by the artist's keys or a captured wallet;
- a nonce revocation.

Executing a change also restarts the clock for the identity it installs.

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

**Sepolia.** The adapter takes the delegation contract's address as a
constructor argument. The deploy lane checks whether the 6529 delegation
contract exists on Sepolia, and deploys a faithful mock there if it does not.

## Trust and failure modes

- **Guardian.** It can block any pending change but has no path that writes an
  identity.
- **Governance.** It can stage overrides, but captured wallets can cancel them
  and the guardian can veto them. Overrides that change the authority need the
  new authority's signature.
- **Profile fields.** The profile ID and profile document hash are the
  artist's unverified claims. They are bound into signatures but not checked
  against 6529 profiles.
- **Stolen key.** By design (ADR §11), the old key can cancel a 7-day
  STANDARD change. A stolen key therefore forces the 180-day CONTESTED route,
  which the old key cannot cancel.
- **Statements before mint (v1 limitation).** `isArtist` returns false for
  pre-mint subjects `(address(0), uint256(itemHash))`, because the registry
  cannot map an item hash to its lead artist. ARTIST statements start once a
  work is minted.

## Residual risk: a thief's own consolidated wallet

This is an owner decision, escalated by the integrator. The registry
implements ADR §11 as written.

**The attack**
1. A thief holds the artist's key for at least 30 days.
2. The thief uses it to register a consolidation, in both directions, between
   the key and a wallet the thief controls. That wallet becomes established.
3. When the network stages the 180-day CONTESTED override to recover the
   identity, the thief's wallet is captured as a canceller with the artist's
   genuine wallets.
4. The thief's wallet cancels the override. Each re-staged override is captured
   and cancelled the same way.

The guardian can block changes but cannot undo a cancel.
`test_ResidualRisk_ThiefWalletCapturedAsOverrideCanceller` demonstrates this
behaviour.

**Candidate mitigation (not implemented).** A cancel of a 180-day override no
longer kills it. Instead it escalates the override to a contested state, which
a governed, TDH-vote-backed action resolves.

## Gas

These figures are measured with cold storage in
`test/identity/ArtistRegistry.t.sol` and
`test/identity/ConsolidationAdapter.t.sol`. Both cases are far inside the
16,777,216-gas transaction cap.
- `stageChange` with 16 captured wallets after a 32-entry scan: about 2.2M gas.
- `establishedWallets` at its full worst case (32 entries with maximal reads):
  about 1.9M gas.
