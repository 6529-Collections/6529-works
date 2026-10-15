# identity

The artist registry and its consolidation adapter: who an artist is (an artist ID, an
authority key, a payout address and profile claims), how the key or payout changes (a 7-day
STANDARD change, or a 180-day override for contested, estate and lost-key cases), who may cancel
or contest a change (a sticky snapshot of consolidated wallets), and the payout freeze and the
restraint that keep a stolen key from acting while recovery is pending. The rules are in
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
| Anyone, relaying the authority's or an established wallet's signature | `stageChange` (STANDARD) | ID-3 to ID-6 |
| The authority | `revokeNonce`; `heartbeat` (also an established wallet) | ID-7, ID-19 |
| The previous authority or a captured wallet | `cancelChange`: cancels a STANDARD change, contests an override during its notice | ID-9, ID-13 |
| Anyone | `executeChange` once due; `refreshStanding`; `expireContest` after 365 days | ID-8, ID-15, ID-20 to ID-23 |
| Governance | `stageOverride` (with the new authority's acceptance), `resolveContested` citing a recorded vote, `vetoChange`, `setConsolidationSource`; the genesis binds | ID-10 to ID-14, ID-27, ID-29; [role matrix](../../docs/audit/roles.md#artistregistry) |
| The statement log; split wallets; every creator power | `isArtist`; `payoutAddress`; `activeAuthorityOf` (zero while restrained) | ID-16, ID-18, ID-28 |
| The v1.1 federation registry | `listFederatedContract` (deferred: `bindFederationRegistry` is not wired at genesis) | [Deferred](../../docs/audit/roles.md#deferred) |

Genesis wires `bindPackageRegistry`, `bindStream`, `bindSplitFactory` and `bindStatementLog`.
The flows (lost key, stolen key and restraint, contest and vote, estate, refreshing standing,
guardian veto) are under [Flows](../../docs/spec/identity-and-recovery.md#flows); the powers the
restraint withholds are in the [stolen-key flow](../../docs/spec/identity-and-recovery.md#stolen-key-override-and-restraint).

## Developer notes

- **The registry address never changes.** Split wallets pin it immutably, so it is never
  redeployed; the identity source is swapped inside it (`setConsolidationSource`, compare-and-set,
  code hash pinned and re-checked at every read).
- **One-read active authority.** `Artist` keeps a `restrained` flag beside the authority: every
  staging sets it, every end of a change (execution, veto, cancel, a voided or lapsed contest, a
  failed re-check at execution) clears it, and `activeAuthorityOf` reads the pending change only
  while it is set. Every new way a change can end must clear the flag;
  [`RestrainedFlag.t.sol`](../../test/identity/RestrainedFlag.t.sol) and the identity invariants
  check it against the pending change. `activeAuthorityOf` sits on the auction start, settle and
  `openSale` paths, so its cost shows up in the [ADR 0004 table](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table).
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
  consolidated". During an outage, staging, heartbeats and refreshes revert while registration
  and execution skip their refresh (ID-26, LIM-ID-9).
- **Delegation contract.** A constructor argument: mainnet's 6529 delegation contract, and on
  Sepolia the official deployment with identical runtime bytecode
  ([deployments](../../deployments/11155111/README.md)); on mainnet the deploy and Verify pin
  the address and code hash (GV-31).
- **Bytecode:** comfortable margin; figures in the
  [audit scope](../../docs/audit/scope.md#curation-identity-and-records).
- **Tests:** `forge test --match-path 'test/identity/**'`: units, review regressions and worst
  cases (`ArtistRegistryReview.t.sol`), contested overrides, the restrained flag, the adapter
  against the real getter shapes, and the invariant suite. End to end:
  `IdentityRecovery.t.sol` and `RecoveryRestraint.t.sol` in
  [`test/integration/`](../../test/integration/). Coverage and mutation testing: [Testing](../../docs/testing/README.md).

## See also

[ADR 0001 §11](../../docs/adr/0001-v1-scope.md#11-artist-identity-and-recovery) (with its
"Hardening" decisions), [ADR 0003, identity](../../docs/adr/0003-build-time-decisions.md#identity-and-recovery-amends-adr-0001-11)
and its [owner decisions](../../docs/adr/0003-build-time-decisions.md#owner-decisions-11-october-2026)
(1 contested overrides, 4 artists pay for refreshes, 6 the restraint);
[known limitations](../../docs/audit/known-limitations.md#identity-and-recovery) LIM-ID-1 to
LIM-ID-13; [trust assumptions](../../docs/audit/trust-assumptions.md);
[runbook, standing refresh](../../script/README.md#12-standing-refresh-refreshstanding).
