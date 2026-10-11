# identity

The slim artist registry (`artistId`, authority address, profile document hash,
6529 profile ID) through which artist payouts resolve, and the consolidation
adapter that reads the 6529 delegation contract's registration and expiry
dates directly. Identity and payout changes wait 7 days, cancellers come from
a sticky standing snapshot of consolidated wallets, and contested changes,
estates and lost keys use the 180-day public override.
Signatures are checked with the shared verifier in `libraries/`. Governed by
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
4. **Execute.** Anyone calls `executeChange` once it is due. If the next
   identity is no longer valid (its authority was taken, or its payout became a
   split wallet), the change is cleared with
   `ChangeCancelled(artistId, registry, false)` instead of reverting.

**Overrides.** CONTESTED, ESTATE and LOST_KEY overrides:
- are staged by the PARAMETER_SETTER role with an evidence hash;
- wait 180 days;
- if they change the authority, carry the new authority's
  `Typehashes.OVERRIDE_ACCEPTANCE` signature with a deadline. It binds no change
  nonce, so a key holder cannot void it by burning nonces, and the registry
  consumes it once by digest (a replay reverts);
- for ESTATE and LOST_KEY, need a year without signed activity.

Only captured wallets and the guardian can stop an override, never the old
key. An override replaces a pending STANDARD change, so a key holder cannot
block one by keeping a change staged.

**Preventive revocation.** The authority's `revokeNonce` burns the current
nonce, voiding every unused STANDARD payload signed for it. Override
acceptances are unaffected (`test_Override_AcceptanceSurvivesANonceBurn`).

## Recovery standing (sticky snapshot)

Each artist has a snapshot of at most 16 consolidated wallets. These calls
refresh it:
- registration;
- every staging;
- a heartbeat;
- an executed change, which refreshes for the identity it installs;
- `refreshStanding(artistId)`, which anyone may call and which is not activity.

**Keeper.** A permissionless refresh keeper, or the 6529.io UI, calls
`refreshStanding` after consolidation events. One refresh any time after
consolidating is enough to record a wallet.

A refresh does three things:
- **Records.** It records every live two-way consolidation it sees
  (`StandingAdded`, with `effectiveAt`). A young one is recorded as pending,
  with `effectiveAt` set to its registration time plus 30 days. A pending entry
  confers no standing before `effectiveAt`.
- **Marks missing.** A recorded wallet that is no longer consolidated is marked
  missing (`StandingMissing`) and keeps its standing. Before marking, the
  registry checks the wallet directly with the source (`effectiveAt`), not only
  against the bounded scan, so a wallet that is still consolidated is never
  marked missing.
- **Removes.** It removes a wallet missing for at least 30 days
  (`StandingRemoved`). Removal needs a refresh that observes the elapsed 30
  days.

**When the snapshot is full,** nothing is evicted early. Slots free up only as
missing entries pass their 30-day grace and are removed. Free slots go to
established wallets before pending ones. A key holder therefore cannot push
recorded wallets out by consolidating more.

**After a rotation,** the previous authority's wallets stay in the snapshot as
missing, with standing, for the grace. A full snapshot then admits the new
authority's wallets only as those age out
(`test_Standing_PostRotationFullSnapshot`).

**Captured cancellers** are the snapshot's entries whose `effectiveAt` has
passed, including missing ones within their grace. The staging's own refresh
has already removed the rest. That makes at most 16.

**What this guarantees.** Someone holding the authority key controls the live
consolidation data. They can revoke the artist's consolidations, reorder the
delegate list, or add a sub-delegate. None of that strips a recorded wallet of
standing, even before staging. To do so, the key holder must let a refresh
record the wallet missing (a public event) and then wait 30 days. These tests
cover it:
- `test_PoC1_RevokeThenStageStillCapturesTheWallet`;
- `test_PoC2_SwapAndPopCannotDisplaceStanding`;
- `test_N1_YoungWalletRecordedPendingIsCapturedAfterRevocation`;
- `test_Standing_LostOnlyAfterAPublicThirtyDayGrace`.

A wallet that no refresh has ever recorded has no standing. That is why the
keeper refreshes after consolidation events.

## Payout freeze

`payoutAddress(artistId)` returns zero while a pending change (STANDARD or
override) would move the payout. Split wallets refuse to release on zero, so
accrued balances wait for the outcome instead of following a contested
redirect.

This stops a thief holding a stolen key, which is still the payout, from
pulling during a 180-day recovery override that moves the payout. The old key
cannot cancel that override. `test_Attack_ThiefCannotPullDuringARecoveryOverride`
demonstrates this.

A change that keeps the payout, including an override that keeps a safe
payout, does not freeze it.

**Trade-off.** The artist's own pulls pause while a payout-moving change is
pending. Someone holding the key can re-freeze them by staging again after
each cancel; the guardian veto and the override path end that. Artist-resolved
split payees are pull-only (economics lane): only the current
`payoutAddress`, or a signature from it, can release.

## Payout validation

Because artist payees are pull-only, some payouts would strand or stall funds.
These are rejected at registration, at staging, and again at execution:
- the zero address;
- this registry;
- the bound package registry;
- 6529 Stream and its Editions;
- any split wallet the bound split factory deployed (`ISplitFactory.isWallet`).

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
| `refreshStanding` | anyone |
| `setConsolidationSource` | SUCCESSOR_SETTER (30 days), compare-and-set; requires the reviewed code hash, ERC-165 and no EIP-7702 delegation |
| `bindPackageRegistry`, `bindStream`, `bindFederationRegistry` | the admin, once each (genesis wiring), then locked; each target must answer ERC-165 for its interface (`IPackageRegistry`, `IStream`, `IFederationRegistry`) |
| `bindSplitFactory` | the admin, once (genesis wiring), then locked; requires code (the factory has no ERC-165) |
| `listFederatedContract` | the bound v1.1 federation registry only; at most 64 per artist |

**Signed activity** is what resets the one-year dormancy clock:
- registration;
- a staged change;
- a heartbeat;
- a cancel by the old key or a captured wallet;
- a nonce revocation;
- an executed change, which restarts the clock for the identity it installs.

Governed overrides, guardian vetoes and standing refreshes never count.

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
- at most 16 wallets returned.

Each getter call forwards a fixed 50,000 gas through `BoundedCall`, and reverts
if the caller cannot supply it, so a gas-starved transaction cannot truncate a
walk. The getters cost at most about 16,000 gas cold (a registration read is
seven cold slots). The 50,000 stipend assumes no repricing triples that.

`consolidations` returns every consolidated wallet the 32-entry scan sees, with
its `effectiveAt`. `effectiveAt(account, wallet)` checks one pair directly.
Both include young consolidations.

The adapter is a live view that the account's keys control:
- the account's own key can add delegations;
- any use-case-998 sub-delegate of the account can write its delegations
  (`registerDelegationAddressUsingSubDelegation`), and so can make a wallet
  established for it without the account's key;
- revocation is swap-and-pop, which reorders the delegate list.

The standing snapshot above, not the order of this list, protects the artist's
wallets.

**Sepolia.** The adapter takes the delegation contract's address as a
constructor argument. The deploy lane checks whether the 6529 delegation
contract exists on Sepolia, and deploys a faithful mock there if it does not.

## Trust and failure modes

- **Guardian.** It can block any pending change but has no path that writes an
  identity.
- **Governance.** It can stage overrides, but captured wallets can cancel them
  and the guardian can veto them. An override that changes the authority needs
  the new authority's signature. An override that changes only the payout
  needs no consent from the artist. It goes through unless a captured wallet
  cancels it or the guardian vetoes it.
- **Consolidation source.** `setConsolidationSource` is a full-trust path on
  the 30-day class. The source decides who has standing, so a malicious source
  could grant or deny it.
- **Profile fields.** The profile ID and profile document hash are the
  artist's unverified claims. They are bound into signatures but not checked
  against 6529 profiles.
- **Stolen key.** By design (ADR §11), the old key can cancel a 7-day
  STANDARD change. A stolen key therefore forces the 180-day CONTESTED route,
  which the old key cannot cancel.
- **The old key after a rotation.** After a rotation A to N, if A and N are
  still consolidated, A is an established wallet of N. A is then captured as an
  override canceller (`test_PoC8_OldKeyConsolidatedWithTheNewAuthorityIsCaptured`).
  The artist should revoke the N-to-A consolidation after rotating. A keeps
  standing for the 30-day grace after a refresh records it missing.
- **Override acceptances.** They are nonce-free and single-use by digest. A
  key holder cannot void a scheduled override by burning nonces. Reusing an
  acceptance, after a veto or a cancel, reverts with `AcceptanceUsed`
  (`test_Override_SameAcceptanceCannotBeConsumedTwice`).
- **Statements before mint (v1 limitation).** `isArtist` returns false for
  pre-mint subjects `(address(0), uint256(itemHash))`, because the registry
  cannot map an item hash to its lead artist. ARTIST statements start once a
  work is minted.

## Residual risk: wallets of anyone who holds the key for 30 days

This is an owner decision, escalated by the integrator.

**The attack.** Captured wallets can cancel any override, and the snapshot
records every wallet consolidated with the current authority. Anyone who holds
the authority key for at least 30 days can consolidate wallets of their own
with it. Once those consolidations are 30 days old and a refresh has recorded
them, those wallets gain standing.
- **Before a hijack.** A thief who quietly holds the artist's key for 30 days
  gains wallets that are captured with the artist's genuine wallets. When the
  network stages the 180-day CONTESTED override, the thief's wallet cancels it,
  and every re-staged override the same way.
- **Filling free slots.** A key holder can fill the snapshot's free slots with
  pending entries of their own. A genuine wallet consolidated afterwards is
  then not recorded while those slots are held
  (`test_ResidualRisk_KeyHolderFillsFreeSlots`).
- **After a hijack executes.** The thief's own prepared wallets, consolidated
  with the thief's new authority, are recorded at the execution. The artist's
  genuine wallets keep standing for 30 days after the hijack's refresh records
  them missing.

`test_PoC3_ResidualRiskThiefWalletsCancelOverridesAfterAHijack` demonstrates
the post-hijack case. The guardian can veto changes but cannot undo a cancel.

**Owner options, not implemented:**
- **(b) Cap override cancels.** After a set number of cancels, only the
  guardian can stop the override.
- **TDH-vote escalation.** A cancel moves the 180-day override into a contested
  state that a governed, TDH-vote-backed action resolves, instead of killing
  it.
- **(L4) Dormancy at execution.** Re-check dormancy when an ESTATE or LOST_KEY
  override executes, so activity during the notice voids it. Today, as the ADR
  states, only a captured wallet or the guardian can stop one.

## Gas

These figures are measured all-cold in `test/identity/ArtistRegistryReview.t.sol`
(`test_WorstCase_*`) and `test/identity/ConsolidationAdapter.t.sol`.

**The adversarial worst case.** Every one of the 32 scanned wallets, and every
one of the 16 directly checked recorded wallets, needs 8 cold registration
reads, because the forward padding sits beyond the 32-entry scan window. At the
measured call, the 16 recorded wallets age out and 16 scanned wallets are
recorded (and, for a staging, captured):
- `stageOverride`: about 7.46M gas to execute;
- `stageChange`: about 7.44M gas;
- `refreshStanding`: about 6.82M gas.

That is about 45% of the 16,777,216-gas EIP-7825 transaction cap. The tests
assert each stays under half of the cap, including intrinsic and calldata gas.

One direct check (`effectiveAt`, 8 cold reads) costs about 130K gas.
`establishedWallets` alone, over 32 distinct cold entries, costs about 2.8M
gas.
