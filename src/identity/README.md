# identity

The artist registry and its consolidation adapter: who an artist is (an artist ID, an
authority key, a payout address and profile claims), how the key or payout changes (a STANDARD
change, or an override for contested, estate and lost-key cases, with governed waits that never
go below their genesis values), who may cancel or contest a change (a sticky snapshot of
consolidated wallets), the payout freeze and the restraint that keep a stolen key from acting
while recovery is pending, and the permanent directory of federated contracts. The rules are in
[Identity and recovery](../../docs/spec/identity-and-recovery.md) (`ID-*`); the contest vote is
also in [Disputes and statements](../../docs/spec/disputes-and-statements.md#identity-contest-decided-by-a-recorded-vote).

## Files

| File | What it is |
| --- | --- |
| `ArtistRegistry.sol` | [`IArtistRegistry`](../interfaces/IArtistRegistry.sol), which is also the statement log's [`IArtistRoleResolver`](../interfaces/IArtistRoleResolver.sol) (`isArtist`) and the split wallets' [`IArtistPayoutResolver`](../economics/interfaces/IArtistPayoutResolver.sol) (`payoutAddress`): identities, changes, overrides, contests, the standing snapshot, the restraint. |
| `ConsolidationAdapter.sol` | `IConsolidationSource` (declared in `IArtistRegistry.sol`) over the 6529 delegation contract: whether two wallets have a live, two-way, all-collections, use-case-999 consolidation at least 30 days old, read from the contract's public getters with bounded, fail-closed walks. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| The bound package registry | `register` on an account's first package acceptance | ID-1, ID-2 |
| The bound federation registry | `registerFederated` (with the account's own signature); `listFederatedContract`, `setFederatedStatus` | ID-32 to ID-34 |
| A listed federated token | `recordFederationExit` (LEFT, terminal) | ID-34 |
| Anyone, relaying the authority's signature, or, only for a dormant artist, an established wallet's (never a previous authority's; the change then waits the override delay) | `stageChange` (STANDARD) | ID-3 to ID-6, ID-40 |
| The authority | `revokeNonce`; `heartbeat` (the authority only) | ID-5, ID-7, ID-19, ID-40 |
| The previous authority or a captured wallet | `cancelChange`: cancels a STANDARD change, contests an override during its notice | ID-9, ID-13 |
| Anyone | `executeChange` once due; `refreshStanding`; `expireContest` once the locked contest timeout has passed | ID-8, ID-15, ID-20 to ID-23 |
| Governance | `stageOverride` (with the new authority's acceptance), `resolveContested` citing a recorded vote, `vetoChange`, `setConsolidationSource`, `setPackageRegistry` (Stream's successor package registry, owner decision 16), `setFederationRegistry`, `setTimer`; the genesis binds | ID-10 to ID-14, ID-27, ID-29 to ID-31, ID-35, ID-36; [role matrix](../../docs/audit/roles.md#artistregistry) |
| The statement log; split wallets; every creator power | `isArtist`; `payoutAddress`; `activeAuthorityOf` (zero while restrained) | ID-16, ID-18, ID-28 |

Genesis wires `bindPackageRegistry`, `bindStream`, `bindSplitFactory` and `bindStatementLog`.
The flows (lost key, stolen key and restraint, contest and vote, estate, refreshing standing,
guardian veto) are under [Flows](../../docs/spec/identity-and-recovery.md#flows); the powers the
restraint withholds are in the [stolen-key flow](../../docs/spec/identity-and-recovery.md#stolen-key-override-and-restraint).

## Developer notes

- **The registry is permanent.** Split wallets and Stream pin it immutably, so it is never
  redeployed; the identity source and the federation registry are swapped inside it
  (`setConsolidationSource`, `setFederationRegistry`, compare-and-set).
- **Timers are one packed word** (`_timerWord`, 48 bits per `IArtistRegistry.Timer`), between the
  packed `FLOORS` and `CEILINGS` constants. A staging locks its delay into `executableAt` and the
  contest timeout into `PendingChange.contestTimeout` (free: it shares `kind`'s slot).
- **Federation directory.** `_listings[token]` is one slot (`uint160` artist ID and status); the
  fixed fields live only in `FederatedContractListed`. No identity path reads it.
- **The source decides nothing for a live artist** (ID-40). The registry is permanent and the
  consolidation source replaceable, so a wallet the source names signs a change only for a
  dormant artist (checked before the source is read), that change waits the override delay
  and records no activity, and only the authority heartbeats. Only the authority's own acts
  move the last activity: a captured wallet's cancel or contest records none, and an execution
  records it only when it installs a new authority (review E, N-1). What a hostile source can still
  do is listed in the spec ([what the source decides](../../docs/spec/identity-and-recovery.md#what-the-consolidation-source-decides)).
- **Refreshes are best-effort except `refreshStanding`.** Any source failure skips the refresh
  (`StandingRefreshSkipped`); a shortfall (a failed read that left at most 1/8 of the gas, or a
  source revert with `BoundedCallInsufficientGas` or `BoundedCallShortfall`, the
  `IConsolidationSource` convention) reverts. Source times are clamped to 48 bits, and every
  change of an entry's `effectiveAt` emits `StandingAdded`.
- **One-read active authority.** `Artist` keeps a `restrained` flag beside the authority: every
  staging sets it, every end of a change (execution, veto, cancel, a voided or lapsed contest, a
  failed re-check at execution) clears it, and `activeAuthorityOf` reads the pending change only
  while it is set. Every new way a change can end must clear the flag;
  [`RestrainedFlag.t.sol`](../../test/identity/RestrainedFlag.t.sol) and the identity invariants
  check it against the pending change. `activeAuthorityOf` sits on the auction start and settle
  paths, so its cost shows up in the
  [ADR 0004 table](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table).
- **Storage.** `_artists` (the identity fields, last activity and nonce), `_pending` (one change
  with its captured cancellers), `_standing` (at most 16 entries), `artistIdOf` for every past
  and present authority, `reservedFor` for a staged new authority, and `_acceptanceUsed` for
  override acceptances consumed by digest.
- **Bounded walks, worst cases.** Refreshes and stagings walk at most 32 scanned and 16 recorded
  wallets with at most 8 cold registration reads each; the tests assert the worst cases stay
  under half the EIP-7825 cap (figures in the spec's
  [parameters](../../docs/spec/identity-and-recovery.md#parameters-and-limits)). Raising
  `Limits.MAX_CANCELLERS` or the adapter's scan bounds means re-measuring them.
- **The adapter fails closed.** Only a cheap revert with no data (the deployed delegation
  contract's array getters past their end) ends a walk; a read that runs out of gas, reverts
  with data or returns too much reverts with `DelegationReadFailed`, never reads as "not
  consolidated". During an outage only `refreshStanding` and a consolidated wallet's signer
  check revert (ID-26, LIM-ID-9).
- **Delegation contract.** A constructor argument: mainnet's 6529 delegation contract, and on
  Sepolia the official deployment with identical runtime bytecode
  ([deployments](../../deployments/11155111/README.md)); on mainnet the deploy and Verify pin
  the address and code hash (GV-31).
- **Bytecode:** comfortable margin; figures in the
  [audit scope](../../docs/audit/scope.md#curation-identity-and-records).
- **Tests:** `forge test --match-path 'test/identity/**'`: units, the standing snapshot and its
  worst cases (`ArtistRegistryStanding.t.sol`), contested overrides, the restrained flag, the adapter
  against the real getter shapes, the federation directory, timers, recovery with a dead source,
  signature agility, and the invariant suite. End to end:
  `IdentityRecovery.t.sol` and `RecoveryRestraint.t.sol` in
  [`test/integration/`](../../test/integration/). Coverage and mutation testing: [Testing](../../docs/testing/README.md).

## See also

[ADR 0001 §11](../../docs/adr/0001-v1-scope.md#11-artist-identity-and-recovery) (with its
"Hardening" decisions), [ADR 0003, identity](../../docs/adr/0003-build-time-decisions.md#identity-and-recovery-amends-adr-0001-11)
and its [owner decisions](../../docs/adr/0003-build-time-decisions.md#owner-decisions-11-october-2026)
(1 contested overrides, 4 artists pay for refreshes, 6 the restraint);
[known limitations](../../docs/audit/known-limitations.md#identity-and-recovery) LIM-ID-1 to
LIM-ID-14; [trust assumptions](../../docs/audit/trust-assumptions.md);
[runbook, standing refresh](../../script/README.md#12-standing-refresh-refreshstanding).
