# ADR 0002: AccessManager hardening as implemented

Status: Accepted by the delivery owner (Claude Code, acting for the repository
owner), 11 October 2026. Amends [ADR 0001 §13](0001-v1-scope.md#13-governance).

## Problem

ADR 0001 §13 requires that the guardian Safe can cancel admin operations,
including operations on the AccessManager itself. It names two ways to do this:
- map the manager's own admin selectors to a meta role guarded by the guardian;
- place a TimelockController in front of the admin role.

Building and reviewing the governance module against OpenZeppelin 5.7.0 showed
that neither option is sufficient on its own.

- **Direct `setAuthority`.** A stock `AccessManager` treats `setAuthority`
  scheduled on a target as a special case and will not map it to a role, so
  only ADMIN can cancel it. A meta-role mapping cannot reach it.
- **Unmapped selectors.** Any target function left unmapped falls back to
  ADMIN. ADMIN's guardian cannot be reassigned, so a guardian cannot cancel
  those operations either.
- **Entrenchment.** "A guardian cannot cancel its own replacement" depends on
  the call's arguments: which role, and which account. OpenZeppelin's
  per-selector rules cannot express that, and a TimelockController has the same
  gap.

## Decision

**1. A subclassed manager.** `WorksAccessManager` is OpenZeppelin's
`AccessManager` with one change, to its cancel check:
- **Rule 1.** Any GUARDIAN holder may cancel any scheduled operation. This
  closes both gaps above.
- **Rule 2.** Only the account that scheduled an operation may cancel an
  operation that revokes one of the canceller's own roles. This applies to
  every role, ADMIN included. A guardian cannot block its own replacement, and
  a compromised admin cannot block another admin from revoking it.

`canCall`, `schedule`, `execute` and the delay semantics are unchanged.

**2. No meta role.** Rule 1 gives the guardians everything the meta-role
mapping would have given them, so the meta role is not used.

**3. The configurator owns its manager.**
- `GovernanceConfigurator` deploys its own `WorksAccessManager` and applies the
  whole configuration in one transaction.
- It then renounces its admin role and emits the configuration and manifest
  hashes.
- Its readback rejects any other manager and any unexpected admin.

Deploy scripts must use the configurator's manager, never a stock
`AccessManager`.

**4. Guardian rules.** These amend ADR 0001 §13, hardening requirement 3.
- **At least two guardians,** and three or more at deployment. Rule 2 means the
  veto holds only while at least two honest guardians are online.
- **Guardians hold only the GUARDIAN and PAUSER roles,** never operational
  roles such as MINTER, CURATION_SIGNER, PLATFORM, STORAGE_OPERATOR or KEEPER.
- **Rotation grants the replacement first,** then revokes the old guardian.
- **The literal rule "the guardian set cannot change while a terminal action is
  pending" is replaced.** Every change to the guardian set is already a 30-day
  operation that the other guardians can veto. A literal rule would need
  terminal-action tracking inside the manager, and could be sidestepped by
  cancelling, changing the guardians and rescheduling.

**5. A cold recovery admin (recommended).**
- A second admin Safe, with distinct signers, holds only ADMIN.
- If the hot admin is compromised, the cold admin schedules
  `revokeRole(ADMIN, hot)`. Under Rule 2 the hot admin cannot cancel that.
- Without a second admin, a compromised sole admin can be vetoed indefinitely
  but never removed.
- The owner confirms the admin topology at deployment.

**6. Manifests after genesis.**
- Each configuration epoch publishes its manifest hash as a statement-log entry
  of kind `GOVERNANCE_MANIFEST`, in the 30-day class.
- The entry is scheduled alongside the epoch's operations, so the hash is
  public before the changes take effect.
- Deployment CI checks it against the committed configuration and the on-chain
  readback.

**7. Selector classes decided during the build.**

| Function | Class |
| --- | --- |
| `AssetAllowlist.admitAsset`, `setDefaultCurrency` | Funds and recipients (14 days) |
| `AssetAllowlist.setIncrementFloor` | Standard (48 hours) |
| `AssetAllowlist.deprecateAsset` | Immediate (tightening) |
| `StatementLog.setArtistResolver` | Verifier and successor (30 days) |
| `StatementLog.appendCurator`, `appendPlatform` | Zero-delay CURATOR and PLATFORM roles |
| `DependencyRegistry.register` | Standard (48 hours) |
| `DependencyRegistry.deprecate` | Immediate |
| Curation verifier swap | Verifier and successor (30 days) |
| Curation verifier `disableSigner` (one-way, per signer) | Immediate, GUARDIAN |
| Re-enabling a curation signer | Verifier and successor (30 days) |
| MINTER grant | 30-day grant delay |
| Dispute pause | Immediate, GUARDIAN |
| Upheld dispute (cancel, refund, burn) | Standard (48 hours), scheduled by day 5 of the 7-day pause |
| `Stream.releaseContent` after an upheld dispute (names the rightful artist) | Standard (48 hours), PARAMETER_SETTER, scheduled with the cancel (added by the 14 October 2026 review) |
| Entropy `lowerCallbackGasLimit` (never below the floor) | Verifier and successor (30 days), SUCCESSOR_SETTER (added by the 14 October 2026 review) |

At least two curation signers are provisioned at genesis, so disabling one does
not halt curation.

## Alternatives considered

- **Meta-role mapping only:** leaves direct `setAuthority` and unmapped
  selectors uncancellable by guardians.
- **TimelockController in front of ADMIN:** the guardian becomes a canceller,
  but cannot be prevented from cancelling its own replacement.
- **Forking OpenZeppelin's `AccessManager`:** a larger audit surface than
  overriding one internal check.

## Security impact

**Closed**
- A compromised admin can no longer take over a target through an operation the
  guardians cannot cancel.
- A guardian can no longer entrench itself.
- A configuration applied to the wrong manager is rejected.

**Residual**
- Guardians who all collude can shield each other from removal.
- Readback cannot see delay reductions that are still pending. OpenZeppelin
  exposes no getter for them, so deployment CI scans `RoleGrantDelayChanged`
  and `TargetAdminDelayUpdated` events for future effect times.
- Readback can check only the role holders named in the configuration;
  OpenZeppelin cannot enumerate role members. An indexer must catch any extras.
- "At most 2× per step" limits each operation, not each time window. Several
  raises can reach a parameter's ceiling within one window.
- OpenZeppelin `Multicall` adds one self-`DELEGATECALL` to the manager. This is
  the single sanctioned exception to the no-delegatecall rule: it batches calls,
  it is not a proxy.

## Test plan

**Foundry tests**
- A compromised admin schedules a guardian revocation, the guardian cancels
  it, and the admin cannot execute early.
- Anti-entrenchment holds under `multicall`, nested `execute` and
  non-canonical calldata.
- A stock manager and a manager with a pre-seeded admin are both rejected.
- Every §13 requirement has a test.

**Stateful invariant campaign:** a compromised admin acts against vigilant
guardians, with benign rotations allowed to execute.

## Superseded or amended

ADR 0001 §13:
- hardening requirement 2 is met by decision 1, not by the two options named;
- hardening requirement 3 is amended by decision 4;
- hardening requirement 8 is extended by decision 6.

## Addendum (review of 14 October 2026)

Accepted by the delivery owner. It amends decision 1 and the security impact above.

**Rule 3.** Only a guardian, or the account that scheduled it, may cancel a
`revokeRole` operation on the manager. No admin can veto another account's
removal. Every other operation keeps OpenZeppelin's rules, so an admin still
cancels another admin's grants, remaps and authority moves when the guardians are
offline.
- **Why:** the cold admin's recovery (decision 5) must finish even when the hot
  admin and one guardian act together. With Rule 3 the cold admin removes the
  guardian in one 30-day round, then the hot admin in the next.
- **Trade-off:** an admin can no longer defend a guardian against another
  admin's revocation. That defence rests on the other guardians, which decision 4
  already assumes.
- **Residual:** until its removal executes, a dishonest guardian can cancel every
  operation and keep paused targets paused.

**Guardian suspension of operational keys.** Any guardian may call
`WorksAccessManager.suspend(role, account)` for a holder of a zero-delay operational
role: PLATFORM, CURATOR or STORAGE_OPERATOR.
- **Effect:** the holder fails `hasRole`, and so `canCall` and every manual check
  built on it, in the same block. Revoking a role takes the admin's 30-day delay, and
  most targets of these roles have no pause.
- **One way:** a tightening action, like a pause. Lifting it is an ADMIN action in
  the 30-day class (a grant of that role to that account), or happens through
  revocation and a new grant. Guardians still never propose.
- **Not suspendable:** ADMIN, GUARDIAN, PAUSER, UNPAUSER, the setter roles, MINTER,
  KEEPER and CURATION_SIGNER. A curation signer's kill switch is the verifier's
  one-way `disableSigner`, which also ends its approval epoch; a lift by grant would
  not.
