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
   the cancellers. A change that moves the authority reserves the new one for
   the artist (`reservedFor`) until it executes or ends: `register` (a package
   acceptance by the new key) and another artist's change revert with
   `AccountTaken`, so the new key cannot become a separate artist meanwhile and
   void the change.
3. **Wait 7 days.** Until then, these can stop the change:
   - the previous authority (`cancelChange`);
   - any wallet captured at staging (`cancelChange`);
   - the guardian (`vetoChange`, veto only).
4. **Execute.** Anyone calls `executeChange` once it is due. If the next
   identity is no longer valid (its payout became a split wallet), the change is
   cleared with `ChangeCancelled(artistId, registry, false)` instead of
   reverting. The authority is re-checked too, as defence in depth; the
   reservation keeps anything from taking it.

**Overrides.** CONTESTED, ESTATE and LOST_KEY overrides:
- are staged by the PARAMETER_SETTER role with an evidence hash;
- wait 180 days;
- if they change the authority, carry the new authority's
  `Typehashes.OVERRIDE_ACCEPTANCE` signature with a deadline. It binds no change
  nonce, so a key holder cannot void it by burning nonces, and the registry
  consumes it once by digest (a replay reverts);
- for ESTATE and LOST_KEY, need a year without signed activity.

The old key can never stop an override. An override replaces a pending
STANDARD change, so a key holder cannot block one by keeping a change staged.

**Contested overrides (ADR 0003 owner decision 1).** A captured wallet's
cancel during the 180-day notice does not kill an override. It contests it:
- `ChangeContested` records the wallet. The pending change keeps `contestedAt`
  and `priorOutcome`, the artist's latest DISPUTE_OUTCOME entry at that moment.
- A contest is refused once the notice has ended (`ContestWindowClosed`), so it
  cannot front-run a due execution. The worst stall is therefore 180 plus 365
  days.
- Further cancels do nothing, and `executeChange` refuses the override.
- A TDH vote decides it. The PLATFORM role records the vote as a
  DISPUTE_OUTCOME statement on the subject `(registry, artistId)`, after the
  contest. Governance then calls `resolveContested(artistId, uphold,
  outcomeRef)` (SUCCESSOR_SETTER, 30 days), citing that statement's entry hash.
  The hash must equal `latestDisputeOutcome(registry, artistId)` and differ
  from `priorOutcome` (`OutcomePredatesContest`). Entry hashes are unique, so
  only a vote recorded after this contest qualifies: an earlier vote, or one
  recorded before the contest, does not.
  - Upholding executes the override, but not before its 180-day notice ends,
    and with the same re-checks as `executeChange`.
  - Voiding deletes it.
  - Both emit `ContestResolved`, whose `executed` flag is false for a void, and
    for an upheld change that the re-checks cleared.
- The guardian can still veto a contested override, which voids it.
- A contest nobody resolves within 365 days lapses. `payoutAddress` stops
  freezing at once, and anyone may then call `expireContest` to delete it
  (`ContestExpired`). Until then a new change waits behind it.

A STANDARD 7-day change still dies on a cancel by its previous authority or a
captured wallet.

**Scheduling a resolution.** `resolveContested` is a 30-day governed action:
- Schedule an uphold no earlier than `executableAt` minus 30 days. An uphold
  that executes before `executableAt` reverts with `ChangeNotDue`, and the
  AccessManager drops an operation not executed within 7 days of maturing.
- A later DISPUTE_OUTCOME on the same subject invalidates a scheduled
  resolution: it no longer cites the latest outcome.

**Preventive revocation.** The authority's `revokeNonce` burns the current
nonce, voiding every unused STANDARD payload signed for it. Override
acceptances are unaffected (`test_Override_AcceptanceSurvivesANonceBurn`).

**No return to an earlier authority.** A change's new authority must be an
account that has never been an authority, of any artist. Every earlier
authority still maps to the artist ID (a package naming it resolves), but the
artist can never rotate back to it: A, then B, then A reverts with
`AccountTaken(A)`, for a STANDARD change and for an override. The move,
fixed-price consent and acceptance signatures a key left unused are checked
against the current authority, so they never verify again once it rotates
away (`test_RotationBackToAPreviousAuthorityIsRefused`). Rotating to a
temporary key and back is therefore not possible: rotate to a fresh key.
Recovery likewise installs a fresh key. Changes that keep the current
authority (payout or profile only) are unaffected. Signed release
authorizations bind the payout address instead, which may return; see
`IReleaseVerifier`.

## Recovery standing (sticky snapshot)

Each artist has a snapshot of at most 16 consolidated wallets. These calls
refresh it:
- registration;
- every staging;
- a heartbeat;
- an executed change, which refreshes for the identity it installs;
- `refreshStanding(artistId)`, which anyone may call and which is not activity.

**Who refreshes: artists pay (owner decision).** Right after an artist links a
wallet, 6529.io prompts the artist to call `refreshStanding` from their own
wallet, so the artist pays the gas. A permissionless network keeper is optional,
a later safety net, not part of the launch. One refresh any time after
consolidating is enough to record a wallet.

A refresh does three things:
- **Records.** It records every live two-way consolidation it sees
  (`StandingAdded`, with `effectiveAt`). A young one is recorded as pending,
  with `effectiveAt` set to its registration time plus 30 days. A pending entry
  confers no standing before `effectiveAt`.
- **Marks missing.** An established wallet that is no longer consolidated is
  marked missing (`StandingMissing`) and keeps its standing. Before marking,
  the registry checks the wallet directly with the source (`effectiveAt`), not
  only against the bounded scan, so a wallet that is still consolidated is
  never marked missing.
- **Drops ended pending entries.** A pending entry that is no longer
  consolidated is removed at once (`StandingRemoved`). Its consolidation ended
  before its 30 days, so it never had standing (ADR 0001 §11), and a later
  consolidation starts a new 30 days
  (`test_Standing_PendingWalletRevokedBeforeThirtyDaysNeverGainsStanding`).
  A pending entry also follows its live consolidation's clock when a refresh
  finds it re-registered later, so a revocation and re-registration that no
  refresh saw does not keep the earlier date
  (`test_Standing_PendingEntryFollowsALaterReRegistration`).
  The registry cannot tell when a consolidation ended, only when a refresh
  observed it. An entry first found missing after its `effectiveAt` is
  treated as an established wallet gone missing, so an artist who revokes a
  wallet they did not consolidate should refresh at once.
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
record the wallet missing (a public event) and then wait 30 days. A wallet
still pending has no standing yet: revoking its consolidation before its 30
days end does remove it, as for any consolidation that never reached 30 days.
These tests cover it:
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
- any split wallet the bound split factory deployed (`ISplitFactory.isWallet`);
- any contract that declares, through ERC-165, the interface of the revenue
  escrow, the claim router, a sale adapter, a mint target, the artist or
  package registry or the work records (`src/libraries/ProtocolContracts.sol`).
  None of these can call `release`.

Limitations:
- A split wallet's predicted CREATE2 address cannot be detected on-chain before
  deployment. The re-check at execution catches one deployed while a change
  waits. Tools should also check `walletFor` off-chain.

## Who may call what

| Function | Caller |
| --- | --- |
| `register` | the bound package registry only; refuses an account that is mapped, or reserved by a pending change |
| `stageChange` | anyone, relaying the authority's or an established wallet's signature |
| `stageOverride` | PARAMETER_SETTER (48 hours) |
| `cancelChange` | a captured wallet, or the previous authority for a STANDARD change; a captured wallet's cancel contests an override |
| `vetoChange` | GUARDIAN (immediate); it can only delete a pending change, contested or not |
| `resolveContested` | SUCCESSOR_SETTER (30 days), citing the vote's recorded DISPUTE_OUTCOME |
| `expireContest` | anyone, once a contest is 365 days old |
| `executeChange` | anyone, once due |
| `heartbeat` | the authority or an established wallet |
| `revokeNonce` | the authority |
| `refreshStanding` | anyone |
| `setConsolidationSource` | SUCCESSOR_SETTER (30 days), compare-and-set; requires the reviewed code hash, ERC-165 and no EIP-7702 delegation |
| `bindPackageRegistry`, `bindStream`, `bindFederationRegistry` | the admin, once each (genesis wiring), then locked; each target must answer ERC-165 for its interface (`IPackageRegistry`, `IStream`, `IFederationRegistry`) |
| `bindSplitFactory`, `bindStatementLog` | the admin, once each (genesis wiring), then locked; requires code (neither has ERC-165) |
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

Each getter call forwards a fixed 200,000 gas, and reverts if the caller cannot
supply it (the `BoundedCall` gas check), so a gas-starved transaction cannot
truncate a walk. The getters cost at most about 16,000 gas cold (a
registration read is seven cold slots), and only the gas used is paid.

**Reads fail closed.** A getter past the end of its array reverts at once with
no revert data: the deployed contract is compiled with solc 0.8.18, and
Solidity's array getters revert without a `Panic` code. That, and only that,
ends a walk. A read that spends the whole stipend (out of gas), reverts with
data, or returns more than expected reverts with
`IConsolidationSource.DelegationReadFailed`. It never reads as "not
consolidated", which would mark every recorded wallet missing and remove it
after the grace.

**During a source outage** (a repricing, or a broken source), until the source
is fixed or swapped (`setConsolidationSource`, 30 days):
- staging, heartbeats and `refreshStanding` revert (fail closed);
- registration (a first package acceptance) and execution (`executeChange`, an
  upheld `resolveContested`) go ahead and skip their standing refresh, emitting
  `StandingRefreshSkipped(artistId)`. Skipping removes nobody's standing: the
  snapshot keeps what it had, and a refresh stops at the first failed read.
  Only the source's `DelegationReadFailed` is skipped; any other failure still
  reverts;
- once reads work again, `refreshStanding` for each artist in a
  `StandingRefreshSkipped` event catches up.

`test_SourceReadFailure_FailsClosed`,
`test_SourceReadFailure_ExecutionSkipsTheRefresh` and
`test_SourceReadFailure_OnlyTheOutageErrorIsSkipped` cover this.

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
  could grant or deny it. A source that cannot read halts identity calls (they
  revert) rather than stripping standing.
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

## Residual risk: wallets planted with the key

**The exposure.** The snapshot records every wallet consolidated with the
current authority. Anyone who can send one transaction from the authority key,
or a use-case-998 sub-delegate of it, can consolidate a wallet of their own
once a refresh records it. If the consolidation stays live for 30 days, the
wallet is captured as a canceller. The artist removes it by revoking the
consolidation and refreshing before those 30 days end: a pending entry found
no longer consolidated is dropped at once.
- **Before a hijack.** A thief who quietly holds the artist's key gains wallets
  captured alongside the artist's genuine wallets.
- **Filling free slots.** A key holder can fill the snapshot's free slots with
  pending entries of their own. A genuine wallet consolidated afterwards is
  then not recorded while those slots are held
  (`test_ResidualRisk_KeyHolderFillsFreeSlots`).
- **After a hijack executes.** The thief's own prepared wallets, consolidated
  with the thief's new authority, are recorded at the execution. The artist's
  genuine wallets keep standing for 30 days after the hijack's refresh records
  them missing (`test_PoC3_ResidualRiskThiefWalletsCancelOverridesAfterAHijack`).

**The stalemate is resolved by a vote (ADR 0003 owner decision 1).** Such a
wallet's cancel no longer kills the network's recovery override. It only
contests it, and only during the notice:
- the payout stays frozen while the override would move it, so the key holder
  cannot collect;
- a TDH vote, recorded after the contest, decides it, applied by the governed
  `resolveContested`;
- the guardian can still veto.

**The cost to the artist.** The artist's own captured wallet can no longer end
a rogue override alone. Its cancel only contests the override, and the payout
stays frozen until one of three things happens:
- a guardian veto;
- a governed void;
- the 365-day lapse.

Guardian monitoring must therefore watch `ChangeContested` events and scheduled
`resolveContested` operations.

`test_Contest_ThiefWalletContestsAndThePayoutStaysFrozen`,
`test_Contest_VoteUpholdsAndTheArtistRecovers` and the integration test
`test_ContestedOverrideUpheldByARecordedVote` cover this. What remains is the
time the dispute takes: the 180-day notice, the vote, and the 30-day governed
resolution. A contest left unresolved for a year lapses.

**Owner option, not implemented:** (L4) re-check dormancy when an ESTATE or
LOST_KEY override executes, so activity during the notice voids it. Today, as
the ADR states, only a captured wallet's contest or the guardian can stop one.

## Gas

These figures are measured all-cold in `test/identity/ArtistRegistryReview.t.sol`
(`test_WorstCase_*`) and `test/identity/ConsolidationAdapter.t.sol`.

**The adversarial worst case.** Every one of the 32 scanned wallets, and every
one of the 16 directly checked recorded wallets, needs 8 cold registration
reads, because the forward padding sits beyond the 32-entry scan window. At the
measured call, the 16 recorded wallets age out and 16 scanned wallets are
recorded (and, for a staging, captured):
- `stageOverride`: about 5.33M gas to execute;
- `stageChange`: about 5.31M gas;
- `refreshStanding`: about 4.66M gas.

That is about a third of the 16,777,216-gas EIP-7825 transaction cap. The tests
assert each stays under half of the cap, including intrinsic and calldata gas.

One direct check (`effectiveAt`, 8 cold reads) costs about 129K gas.
`establishedWallets` alone, over 32 distinct cold entries, costs about 2.8M
gas.
