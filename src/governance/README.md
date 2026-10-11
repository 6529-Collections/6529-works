# governance

One OpenZeppelin 5.7.0 `AccessManager` governs 6529 Stream, 6529 Editions and
every satellite. The design follows [ADR 0001](../../docs/adr/0001-v1-scope.md) §13,
with the guardian's veto and pause powers from §11 and §12. There are no bespoke
executor, policy or registry contracts.

| File | Purpose |
| --- | --- |
| `Roles.sol` | Canonical role IDs, delay classes, execution delays and grant delays. Every lane imports it. |
| `WorksAccessManager.sol` | The stock manager plus two cancellation rules (below). Deploy this, never a bare `AccessManager`. |
| `GovernanceConfig.sol` | Internal library: `validate`, `install` and `verify` (readback). |
| `GovernanceConfigurator.sol` | One-shot installer that holds the initial admin role, configures everything in one transaction, then renounces. |
| `BoundedParameter.sol` | Raise-only parameters: at most 2× per step, with an absolute ceiling (§13.9). |

## Role model

A delay in `AccessManager` belongs to a (role, holder) pair, not to a function.
A delay class is therefore a role whose holders always carry the class delay. The
configurator derives every execution delay, grant delay, role admin and role
guardian from `Roles.sol`, so a configuration names holders only and cannot pick
a wrong delay.

| Role | ID | Holder | Execution delay | Grant delay | Map to it |
| --- | --- | --- | --- | --- | --- |
| `ADMIN` | 0 | admin Safe | 30 days | 30 days | Nothing explicitly. Unmapped selectors fall back to it. |
| `GUARDIAN` | 1 | at least two guardian Safes | immediate | 30 days | Immediate vetoes: dispute pause (§12), identity-change veto (§11) |
| `PAUSER` | 2 | guardian Safes | immediate | 48 hours | `pause` |
| `UNPAUSER` | 3 | admin Safe (never a pauser) | 48 hours | 48 hours | `unpause` |
| `CURATION_SIGNER` | 4 | curation signer key | — | 30 days | Nothing: a signer registry, not a caller |
| `STORAGE_OPERATOR` | 5 | storage operator key | immediate | 48 hours | Preferred-location switches (§8) |
| `MINTER` | 6 | sale adapter contracts | immediate | 30 days | Mint entry points (§5) |
| `KEEPER` | 7 | keeper bots | immediate | 48 hours | Upkeep |
| `PLATFORM` | 8 | platform key | immediate | 48 hours | Locator registration, platform statements (§8, §12) |
| `PARAMETER_SETTER` | 9 | admin Safe | 48 hours | 48 hours | Sale parameters, defaults for new works, dispute outcomes, raise-only gas parameters |
| `FUNDS_SETTER` | 10 | admin Safe | 14 days | 14 days | Network recipients, royalty and split defaults, currency allowlist and default currency |
| `SUCCESSOR_SETTER` | 11 | admin Safe | 30 days | 30 days | Verifier, renderer and errata pins, identity source, VRF coordinator, one-way freezes |
| `META` | 12 | admin Safe (granted with `ADMIN`) | 30 days | 30 days | The manager's own ten admin selectors (set by the configurator) |

All role admins are `ADMIN`. The guardian of every role except `ADMIN` is
`GUARDIAN`. Every target, the manager included, has a 30-day admin delay.

**Delay classes:** immediate (tightening and pauses), 48 hours (standard),
14 days (funds and recipients), 30 days (verifier, successor and meta).
`AccessManager` only sees selectors, so a target enforces direction rules itself:
pause and unpause are separate selectors, and gas parameters use `BoundedParameter`.

## How the guardians cancel the admin

`WorksAccessManager` changes only `_canCancel`:

1. **Any `GUARDIAN` holder can cancel any scheduled operation.**
2. **Nobody but its scheduler can cancel an operation that revokes one of the
   canceller's own roles.** No guardian, and no admin, can veto its own removal.

Both rules exist because of what OZ 5.7.0's source actually does:

- **Stock cancellation is selector-scoped.** It is open to the scheduler, any
  admin, or the guardian of `getTargetFunctionRole(target, selector)`.
  `ADMIN_ROLE`'s guardian is fixed to `ADMIN`.
- **Mapping the manager's admin selectors to `META` (guardian `GUARDIAN`) lets
  guardians cancel admin operations on the manager.** It does not change who may
  call those selectors, because `_getAdminRestrictions` ignores the mapping. The
  configurator still installs it (defence in depth, and a correct `canCall` view).
- **Two admin paths remain uncancellable on a stock manager:**
  - **Direct `setAuthority`:** scheduling `setAuthority(rogue)` directly on a
    target. `canCall` special-cases this selector and `setTargetFunctionRole`
    refuses to map it. After 30 days the admin owns the target.
  - **Unmapped selectors:** any selector a target forgets to map.

  Rule 1 closes both. The tests `test_StockManagerCannotStopDirectSetAuthority` and
  `test_GuardianCancelsDirectSetAuthorityOnTarget` prove it.
- **Rule 2 cannot be expressed per selector, because it depends on arguments.**

Mapping `META` alone is the ADR's first option. A `TimelockController` in front of
the admin would have the same entrenchment gap, plus a second delay mechanism.

## Deploying and configuring

A deploy script must:

1. **Deploy `GovernanceConfigurator`.** The deployer becomes the only account
   allowed to call `configure`.
2. **Deploy `WorksAccessManager(address(configurator))`.**
3. **Deploy every target with `authority = manager`.**
4. **Call `configurator.configure(manager, cfg, manifestHash)`.**
   - `cfg.grants` lists `(role, account)` pairs.
   - `cfg.targets` lists each target with its `(selector, role)` pairs.
   - The call validates `cfg` and applies it in one transaction:
     - labels, guardians and grant delays for every role;
     - `META` mapping of the manager's admin selectors;
     - 30-day target admin delays;
     - function roles;
     - grants at their class delays.
   - It then renounces `ADMIN` and emits `GovernanceConfigured(manager,
     keccak256(abi.encode(cfg)), manifestHash)`.
5. **Wait `minSetback()` (5 days).** Grant delays and target admin delays become
   effective then. The admin's 30-day execution delay covers that window.
6. **Run `configurator.verify(manager, cfg)` (CI readback via `eth_call`).** It
   reverts with a specific error on any difference.

`validate` rejects:

- fewer than two guardians;
- a guardian holding any proposer role (`ADMIN`, `META`, `UNPAUSER` or a setter);
- one account holding both `PAUSER` and `UNPAUSER`;
- a missing `ADMIN`, `PAUSER` or `UNPAUSER` holder;
- duplicate grants, zero addresses, explicit `META` grants and unknown roles;
- a target that is the manager, has no code, repeats, or answers `authority()`
  with another manager;
- a selector listed twice on one target;
- a selector mapped to `ADMIN`, `META`, `CURATION_SIGNER` or `PUBLIC`.

**Rules for target contracts (every lane):**

- **Map every `restricted` selector to exactly one class role.** Unmapped
  selectors fall back to `ADMIN` (30 days).
- **Keep governed functions non-payable.** `AccessManager.execute` forwards
  `msg.value`. `GovernanceFixture._acceptsValue` probes this.
- **Compare-and-set:** setters for funds, recipients, the verifier and the
  renderer take the expected current value, so stale operations revert.
- **Evidence:** every setter emits its old and new values.
- **Raise-only parameters:** use `BoundedParameter.initial` in the constructor
  and `BoundedParameter.raise` in the setter, with a code-level constant ceiling.
- **Integration tests:** inherit `test/helpers/GovernanceFixture.sol` to
  configure your targets the way a deploy script must.
  `test/mocks/GovernanceMocks.sol` holds a sample target.

## Operating procedures

- **Emergencies.**
  - Pausing is immediate (`PAUSER`).
  - Unpausing waits 48 hours, during which a guardian can cancel it.
  - Revoking a role is a meta action and waits 30 days. Pause the affected target
    while a revocation matures.
- **Operation expiry.** An operation must execute within one week after it
  becomes ready (`expiration()`). After that it is dead and must be rescheduled
  with the full delay.
- **Rotating the admin Safe** (`test_RotatedAdminPendingOperationsAreCancelled`):
  1. The old admin schedules grants of `ADMIN`, `META`, `UNPAUSER` and the three
     setters to the new Safe, each at its class delay.
  2. Guardians, or the old admin, cancel every other pending operation of the old
     admin. List them from `OperationScheduled` events not yet followed by
     `OperationExecuted` or `OperationCanceled`.
  3. Execute the grants after 30 days and wait for the grant delays.
  4. The old admin renounces every role, which is immediate. Alternatively, the new
     admin schedules the revocations; under rule 2 the old admin cannot cancel them.
  5. Any operation the old admin still has scheduled can no longer execute.
- **Rotating a guardian.**
  - The admin schedules `revokeRole(GUARDIAN, old)` and `revokeRole(PAUSER, old)`.
    The old guardian cannot cancel them; the other guardians can.
  - Grant the replacement separately. A departing guardian can cancel that grant,
    but not its own removal, so re-schedule the grant after the revocation.

## Residual risks and limits

- **Colluding guardians.** If every guardian colludes, each can cancel the
  others' removal. Per-account protection cannot tell this apart from defending a
  guardian against a compromised admin. The mitigation is guardian independence
  (`test_Residual_ColludingGuardiansCanShieldEachOther`).
- **A compromised sole admin is contained, not removed.** Guardians can veto
  everything it schedules, but only an admin can grant or revoke `ADMIN`.
- **Readback has no holder enumeration.** `verify` checks the holders named in
  `cfg`. `AccessManager` cannot enumerate members, so an indexer checks for extra
  holders from `RoleGranted` events.
- **Guardian rules after deployment.** Changing the guardian set takes the full
  30-day meta delay plus the other guardians' veto. The ADR's "guardian set cannot
  change while a terminal action is pending" is not tracked separately, and
  `verify` flags a guardian that gains a proposer role.
