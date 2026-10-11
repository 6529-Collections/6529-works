# governance

One OpenZeppelin 5.7.0 `AccessManager` governs 6529 Stream, 6529 Editions and
every satellite. The design follows [ADR 0001](../../docs/adr/0001-v1-scope.md) §13,
with the guardian's veto and pause powers from §11 and §12, as amended by
[ADR 0002](../../docs/adr/0002-access-manager-hardening.md). There are no bespoke
executor, policy or registry contracts.

| File | Purpose |
| --- | --- |
| `Roles.sol` | Canonical role IDs, delay classes, execution delays and grant delays. Every lane imports it. |
| `WorksAccessManager.sol` | The stock manager plus two cancellation rules (below). |
| `GovernanceConfig.sol` | Internal library: `validate`, `install`, `verify` (readback) and `hasRecord`. |
| `GovernanceConfigurator.sol` | Deploys its own `WorksAccessManager`, configures it in one transaction, renounces, and verifies it. |
| `BoundedParameter.sol` | Raise-only parameters: at most 2× per step, with an absolute ceiling (§13.9). |

## Role model

A delay in `AccessManager` belongs to a (role, holder) pair, not to a function.
A delay class is therefore a role whose holders always carry the class delay. The
configurator derives every execution delay, grant delay, role admin and role
guardian from `Roles.sol`, so a configuration names holders only and cannot pick
a wrong delay.

| Role | ID | Holder | Execution delay | Grant delay | Map to it |
| --- | --- | --- | --- | --- | --- |
| `ADMIN` | 0 | Hot admin Safe and cold recovery admin Safe (distinct signers) | 30 days | 30 days | Nothing explicitly. The manager's own admin functions and unmapped selectors fall back to it. |
| `GUARDIAN` | 1 | Guardian Safes: at least two, three by default | immediate | 30 days | Immediate vetoes: dispute pause (§12), identity-change veto (§11), curation `disableSigner` |
| `PAUSER` | 2 | Guardian Safes | immediate | 48 hours | `pause` |
| `UNPAUSER` | 3 | Hot admin Safe (never a pauser) | 48 hours | 48 hours | `unpause` |
| `CURATION_SIGNER` | 4 | Curation signer keys, at least two at genesis | — | 30 days | Nothing: a signer registry, not a caller |
| `STORAGE_OPERATOR` | 5 | Storage operator key | immediate | 48 hours | Preferred-location switches (§8) |
| `MINTER` | 6 | Sale adapter contracts | immediate | 30 days | Mint entry points (§5) |
| `KEEPER` | 7 | Keeper bots | immediate | 48 hours | Upkeep |
| `PLATFORM` | 8 | Platform key | immediate | 48 hours | Locator registration, statement log `appendPlatform` (§8, §12). The log refuses delayed writers. |
| `PARAMETER_SETTER` | 9 | Hot admin Safe | 48 hours | 48 hours | Sale parameters, defaults for new works, raise-only gas parameters, dispute outcomes ("upheld" scheduled by day 5 of the pause) |
| `FUNDS_SETTER` | 10 | Hot admin Safe | 14 days | 14 days | Network recipients, royalty and split defaults, currency allowlist and default currency |
| `SUCCESSOR_SETTER` | 11 | Hot admin Safe | 30 days | 30 days | Verifier, renderer and errata pins, identity source, VRF coordinator, one-way freezes, curation signer re-enable, statement log `appendGovernanceManifest` and `setArtistResolver` |
| `CURATOR` | 12 | Curation team key | immediate | 30 days | Statement log `appendCurator`, which writes `CURATION_EVIDENCE` statements. The log refuses delayed writers. |

- **Role admins:** every role's admin is `ADMIN`.
- **Role guardians:** every role except `ADMIN` has `GUARDIAN` as its guardian.
- **Target admin delays:** every target, the manager included, has a 30-day admin delay.
- **Guardians hold `GUARDIAN` and `PAUSER` only.** This keeps the veto separate from any action.
- **The curation signer key is never an on-chain caller.** No function maps to
  `CURATION_SIGNER`; curator statements go through `CURATOR`.
- **Contract-to-contract calls use no role.** They go through per-pair, one-shot
  caller bindings inside the target contracts, set once at genesis and locked forever.
  A shared contract role would let any holder call every hook.

**Delay classes:**
- immediate: tightening actions and pauses;
- 48 hours: standard actions;
- 14 days: funds and recipients;
- 30 days: verifier, successor and meta-governance.

`AccessManager` only sees selectors, so each target enforces its own direction rules. Pause and unpause are separate selectors, and gas parameters use `BoundedParameter`.

## How the guardians cancel the admin

`WorksAccessManager` changes only `_canCancel`:

1. **Any `GUARDIAN` holder can cancel any scheduled operation.**
2. **Nobody but its scheduler can cancel an operation that revokes one of the
   canceller's own roles.** No guardian, and no admin, can veto its own removal.
   A scheduler may still withdraw its own proposal, even one that removes itself.

Why both rules, from what OZ 5.7.0's source does:

- **Stock cancellation is selector-scoped:** the scheduler, any admin, or the
  guardian of `getTargetFunctionRole(target, selector)`. `ADMIN_ROLE`'s guardian
  is locked to `ADMIN`. On a stock manager, guardians therefore cannot cancel:
  - the admin's operations on the manager itself, because its admin selectors
    resolve to `ADMIN_ROLE`;
  - a `setAuthority(rogue)` scheduled directly on a target. `canCall`
    special-cases this selector and `setTargetFunctionRole` refuses to map it, so
    the admin owns the target after 30 days;
  - any target selector left unmapped.

  Rule 1 closes all three. `GuardianCancel.t.sol` proves each gap on a stock
  manager and its fix here.
- **Rule 2 cannot be expressed per selector, because it depends on arguments.**
  It also stops a compromised hot admin from cancelling the cold admin's
  `revokeRole(ADMIN, hot)`. Stock OZ lets any admin cancel any operation.
- **Wrappers cannot smuggle a revocation past Rule 2.** A revocation scheduled
  inside `multicall` or a nested `execute` can never execute, and a scheduled
  `renounceRole` fails its confirmation check. The tests cover all three.
- **`canCall` on the manager's own selectors is reported as `ADMIN`.** It shows
  `ADMIN` membership and execution delay, so every admin sees `(false, 30 days)`.
  The authoritative check is `_getAdminRestrictions`: `grantRole` and `revokeRole`
  consult the role's admin, which is `ADMIN` for every role.

## Deploying and configuring

A deploy script must:

1. **Deploy `GovernanceConfigurator(deployer)`.** Its constructor deploys
   `WorksAccessManager(address(this))` as `worksManager()`, so the manager's code is
   the hardened one and its only initial admin is the configurator. `deployer`, the
   operator broadcasting the genesis, is the only account allowed to call
   `configure`. Because it is an argument, not `msg.sender`, the configurator can be
   deployed through a CREATE2 factory: its address is predictable, and so is the
   manager's (`CREATE` nonce 1 of the configurator). A configurator deployed by anyone
   else, naming any deployer, only ever governs the new manager it creates, never the
   real one.
2. **Deploy every target with `authority = configurator.worksManager()`.**
3. **Call `configurator.configure(cfg, manifestHash, wiring)`.**
   - `cfg.grants` lists `(role, account)` pairs.
   - `cfg.targets` lists each target with its `(selector, role)` pairs.
   - `wiring` lists the genesis calls (see "Genesis wiring" below).
   - The call validates `cfg` and `wiring` and installs, in one transaction:
     - labels, guardians and grant delays for every role;
     - 30-day target admin delays, the manager's included;
     - the genesis wiring calls, as zero-delay `ADMIN`;
     - function roles;
     - grants at their class delays.
   - It then renounces `ADMIN` and emits `GovernanceConfigured(manager,
     keccak256(abi.encode(cfg)), manifestHash, keccak256(abi.encode(wiring)))`.
   - [`config/genesis.example.json`](../../config/genesis.example.json) is the
     committed example of `cfg` and `wiring` for every v1 contract.
4. **Wait `minSetback()` (5 days).** Grant and target-admin delays become
   effective then. The admins' 30-day execution delay covers that window.
5. **Run `configurator.verify(cfg)` (CI readback via `eth_call`).** It reverts with
   a specific error on any difference:
   - the configurator still holds `ADMIN`;
   - a configured admin lacks the full 30-day delay, or has a reduction pending;
   - any role, holder or selector differs from `cfg`.

**Genesis wiring.** The one-shot `bind*` calls, the admitted-minter grants and the
sale targets are `restricted`. After genesis they resolve to a 30-day role, or to
`ADMIN` if unmapped, so the system could not operate for 30 days. `configure`
therefore executes them itself:

- **Timing:** they run after the roles and target admin delays are installed, but
  before any selector is mapped. Every wired selector still resolves to the
  configurator's zero-delay `ADMIN`, even one that `cfg` then maps to a 30-day role,
  such as `setAdmittedMinter`.
- **Allowed calls:** an allow-list, `GovernanceConfig.isGenesisSelector`, built from
  the compiled interface selectors:
  - `bindWorkRecords`, `bindEditions`, `bindStream`, `bindPackageRegistry`,
    `bindSplitFactory`, and `bindFederationRegistry` (listed for completeness, though
    v1 defers it);
  - `setAdmittedMinter(address,bool)`;
  - `setTarget(address,bool)`;
  - `appendGovernanceManifest`, so the epoch-0 manifest is written at genesis and the
    manifest history starts there.

  Anything else, such as a verifier swap or a recipient change, is rejected with
  `WiringSelectorNotAllowed`. A call to an unconfigured target, or to the manager
  (never a configured target), is rejected with `InvalidWiringCall`. There are at
  most `MAX_WIRING_CALLS` (64) calls.
- **Failure:** a reverting call reverts the whole configuration with the callee's
  error, or with `WiringCallFailed(index)` if it gave none. Nothing is applied, and the
  configurator still holds `ADMIN`, so the deployer can fix the wiring and call
  `configure` again.
- **Gas:** the example genesis configuration with 64 wiring calls costs about 6.6M gas,
  39% of the EIP-7825 cap of 2^24, including worst-case calldata. Every account is
  cooled first, so nothing is cheaper than in a real transaction.
- **Deployment readback.** `verify` reads roles and selectors, not what the wiring did.
  Deployment CI therefore:
  - recomputes `wiringHash` from the committed JSON and compares it with the
    `GovernanceConfigured` event;
  - reads back each wired getter: `workRecords()`, `editions()`, `stream()`, the
    package registry and split factory on the artist registry, `isAdmittedMinter`,
    and the adapters' target lists.

  The integration lane implements this in `script/Verify.s.sol`.

**What `validate` rejects** (and readback re-checks where `AccessManager` exposes it):

- **Guardians:**
  - fewer than two;
  - a guardian holding or pending any role other than `PAUSER`.
- **Required holders:** a missing `ADMIN`, `PAUSER` or `UNPAUSER`.
- **Separation of roles:**
  - one account holding both `PAUSER` and `UNPAUSER`.
- **Malformed grants:** duplicates, zero addresses and unknown roles.
- **Targets:** a target that is the manager, has no code, repeats, or answers
  `authority()` with any other manager (stock or pre-seeded).
- **Selectors:**
  - a selector listed twice on one target;
  - a selector mapped to `ADMIN`, `CURATION_SIGNER` or `PUBLIC`.

**Rules for target contracts (every lane):**

- **Map every `restricted` selector to exactly one class role.** Unmapped
  selectors fall back to `ADMIN` (30 days). Contract-to-contract entry points are
  not `restricted`: they check a caller binding the target sets once at genesis.
- **Keep governed functions non-payable.** `AccessManager.execute` forwards
  `msg.value`. `GovernanceFixture._acceptsValue` probes this.
- **Compare-and-set:** setters for funds, recipients, the verifier and the
  renderer take the expected current value, so stale operations revert.
- **Evidence:** every setter emits its old and new values.
- **Raise-only parameters:** use `BoundedParameter.initial` in the constructor
  and `BoundedParameter.raise` in the setter, with a code-level constant ceiling.
  - "2× per step" bounds each operation, not each period. A chain of raises
    scheduled together can reach the ceiling inside one window, which matches
    ADR §13.9. A target that needs a rate limit enforces it itself.
- **Integration tests:** inherit `test/helpers/GovernanceFixture.sol`. It deploys
  the default layout: hot and cold admins, three guardians, two curation signers,
  a curator and one key per operational role. `test/mocks/GovernanceMocks.sol`
  holds a sample target.

## Operating procedures

- **Guardian liveness.** Safety requires **at least two honest guardians online at
  all times**:
  - one may be the target of a hostile revocation, which it cannot veto itself;
  - the other cancels that revocation.

  With one guardian online, a compromised admin removes it in 30 days and then
  nothing stops a target takeover (`test_Residual_LivenessNeedsTwoHonestGuardiansOnline`).
  Run three or more guardians. The deploy default is three. The code minimum stays
  at the ADR floor of two.
- **Emergencies.**
  - Pausing is immediate (`PAUSER`).
  - Unpausing waits 48 hours, during which any guardian can cancel it.
  - Revoking a role is a meta action and waits 30 days, so pause the affected
    target while a revocation matures.
  - A compromised curation signer is cut off immediately by the curation verifier's
    one-way `disableSigner` (mapped to `GUARDIAN`). Re-enabling a signer is in the
    30-day class.
- **Operation expiry.** An operation must execute within one week after it
  becomes ready (`expiration()`). After that it is dead and must be rescheduled
  with the full delay.
- **Rotating a guardian (cooperative).** Grant the replacement first, then revoke:
  1. Schedule `grantRole(GUARDIAN, new)` and `grantRole(PAUSER, new)`.
  2. Once both are active (after 30 days plus the 30-day grant delay), schedule
     `revokeRole(GUARDIAN, old)` and `revokeRole(PAUSER, old)`.

  The departing guardian cannot cancel its own removal; the others can. The
  guardian count never drops below the configured number.
- **Rotating the hot admin Safe (cooperative):**
  1. The old admin schedules grants of `ADMIN`, `UNPAUSER` and the three setters
     to the new Safe, each at its class delay.
  2. Guardians, the old admin or the cold admin cancel every other pending
     operation of the old admin. List them from `OperationScheduled` events not
     yet followed by `OperationExecuted` or `OperationCanceled`.
  3. Execute the grants after 30 days and wait for the grant delays.
  4. The old admin renounces every role, which is immediate.
  5. Any operation the old admin still has scheduled can no longer execute.
- **Recovering from a compromised hot admin (cold admin Safe):**
  1. The cold admin schedules `revokeRole` of every hot-admin role
     (`ADMIN`, `UNPAUSER` and the three setters). Rule 2 stops the hot admin from
     cancelling them.
  2. Guardians cancel the hot admin's counter-moves, such as a
     `revokeRole(ADMIN, cold)`. The cold admin cannot cancel its own removal.
  3. After 30 days the cold admin executes the revocations.
  4. Only then does it grant the roles to a new hot Safe. Revocations go first,
     because a still-active hot admin can cancel grants to its replacement.

  The owner confirms the cold Safe and its signer set at deployment.
- **Onboarding a target after genesis:**
  1. Schedule `setTargetAdminDelay(newTarget, 30 days)` and one
     `setTargetFunctionRole` per selector. Each is a 30-day admin operation the
     guardians can veto.
  2. Execute them, for example in one `multicall`.
  3. Wait `minSetback()`.
  4. Re-run readback with the target added to `cfg`.
- **Post-genesis configuration epochs.**
  - Each epoch's signed manifest is published as a statement-log entry of kind
    `GOVERNANCE_MANIFEST`, in the 30-day class (`SUCCESSOR_SETTER`).
  - It is scheduled alongside the epoch's operations.
  - The configurator emits only the genesis manifest hash.

## Readback limits (deployment CI requirements)

- **Pending delay reductions are invisible to `verify`.** OpenZeppelin exposes no
  getter for a pending grant-delay or target-admin-delay change, so `verify` passes
  until a reduction lands (`test_Limitation_ReadbackCannotSeePendingDelayReductions`).
  Deployment CI (the integration lane) **must** scan every `RoleGrantDelayChanged`
  and `TargetAdminDelayUpdated` event and fail on any whose effect time is in the
  future. Pending execution-delay changes are visible through `getAccess`, and
  `verify` rejects them.
- **No holder enumeration.** `AccessManager` cannot list role members, so `verify`
  checks the holders named in `cfg`. Because the configurator deployed the manager
  and was its only initial admin, every other holder comes from a configured grant
  or a later 30-day, guardian-vetoable grant. Deployment CI must reconcile
  `RoleGranted` and `RoleRevoked` events against `cfg`.

## Design notes

- **The `Multicall` exemption.** OpenZeppelin `Multicall`'s self-delegatecall,
  inherited by `WorksAccessManager`, is the one sanctioned exemption to the
  no-delegatecall rule. It only batches calls into the manager itself; it is not a
  proxy. Each batched admin call still consumes its own schedule.
- **No META role.** An earlier draft mapped the manager's admin selectors to a META
  role guarded by `GUARDIAN`. Rule 1 already gives guardians that power, and the
  mapping made `canCall` misreport admins that did not also hold META, so it was
  removed.

## Decisions (review of PR #7, 11 October 2026; recorded in ADR 0002)

- **`MINTER`:** 30-day grant delay.
- **Curation signers:**
  - the curation verifier gets a one-way, per-signer `disableSigner`, mapped to
    `GUARDIAN` (immediate);
  - re-enabling is in the 30-day class;
  - at least two signers are provisioned at genesis.
- **Cold admin Safe:** recommended. The configuration supports several `ADMIN`
  holders, a hot admin and a cold recovery admin with distinct signers. The owner
  confirms at deployment.
- **"Guardian set frozen while a terminal action is pending"** (ADR §13.3): replaced
  by the 30-day delay plus the other guardians' veto. The integrator amends the ADR.
- **Post-genesis manifests:** published as `GOVERNANCE_MANIFEST` statement-log
  entries in the 30-day class.
- **Dispute outcomes:** "upheld" stays in the 48-hour class, scheduled by day 5 of
  the pause. The dispute lane enforces this.
- **`CURATOR`:** appends `CURATION_EVIDENCE` statements (`StatementLog.appendCurator`),
  with zero execution delay and a 30-day grant delay. `PLATFORM` (zero delay) serves
  `appendPlatform`, and `appendGovernanceManifest` is in the 30-day class.
- **Contract-to-contract calls:** no shared role. Targets use per-pair, one-shot
  caller bindings, set at genesis and locked forever.

## Residual risks

- **Colluding guardians** can cancel each other's removal. Per-account protection
  cannot tell this apart from defending a guardian against a compromised admin
  (`test_Residual_ColludingGuardiansCanShieldEachOther`). The mitigation is
  guardian independence.
- **Guardian liveness**, as described under Operating procedures.
