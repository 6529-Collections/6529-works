# governance

One OpenZeppelin 5.7.0 `AccessManager`, subclassed as `WorksAccessManager`, governs every 6529
Works contract: each restricted selector maps to one role, each role is one delay class, any
guardian can cancel any scheduled operation and suspend a compromised operational key, and a
one-shot configurator installs the whole genesis configuration in one transaction. There are no
bespoke executor, policy or registry contracts. The rules, role table and flows are in
[Governance](../../docs/spec/governance.md) (`GV-*`); every selector with its role, delay and
cancel rule is in the generated [role and permission matrix](../../docs/audit/roles.md).

## Files

| File | What it is |
| --- | --- |
| `Roles.sol` | Internal library: role IDs 0 to 12, the four delay classes, each role's execution delay, grant delay and label, `isSuspendable`. Every contract imports it; nothing hard-codes a role ID. `MINTER` (6) and `KEEPER` (7) are defined but unused in v1: genesis grants them to nobody and no selector maps to them. |
| `WorksAccessManager.sol` | Stock `AccessManager` with four overrides: `_canCancel` (the three cancellation rules), `hasRole` (a suspended holder is not a member), and `_grantRole` and `_revokeRole` (each lifts a suspension; OpenZeppelin's `renounceRole` runs through `_revokeRole`). Adds `suspend` and `isSuspended`. |
| `GovernanceConfig.sol` | Internal library: `validate`, `validateWiring`, `isGenesisSelector`, `install`, `verify` (readback) and `hasRecord`. |
| `GovernanceConfigurator.sol` | Deploys its own `WorksAccessManager`, runs `configure(cfg, manifestHash, wiring)` once for its `deployer`, renounces `ADMIN`, and exposes `verify(cfg)` for readback. |
| `BoundedParameter.sol` | Internal library for raise-only parameters: at most double per step, never above a ceiling fixed in the target's code. Its one v1 user is the entropy module's callback gas limit. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Holders of a delayed role | `schedule`, then `execute` (or the target itself) after the delay and within the one-week expiry | GV-4, GV-5, GV-7 |
| Any active guardian | `cancel` of any scheduled operation, except as Rules 2 and 3 restrict; `suspend(roleId, account)` for a `PLATFORM`, `CURATOR` or `STORAGE_OPERATOR` record | GV-1 to GV-3, GV-25 to GV-28 |
| `ADMIN` (30 days) | `grantRole`, `revokeRole`, remaps, target closure and authority moves; a grant or revocation of a suspended record lifts it | GV-4, GV-28 |
| A role holder | `renounceRole` for itself, at once; it also lifts its own suspension | GV-28 |
| The deployer, once | `GovernanceConfigurator.configure`, then `verify` by `eth_call` five days later | GV-8 to GV-13 |
| Every governed contract | `restricted` asks `canCall`; some read `PLATFORM`, `CURATOR` or `CURATION_SIGNER` directly | [Roles that targets read directly](../../docs/spec/governance.md#roles-that-targets-read-directly) |

The genesis flow, the wiring allow-list and the readback checks are under
[Genesis configure](../../docs/spec/governance.md#genesis-configure); the suspension state
machine under [Suspension of operational keys](../../docs/spec/governance.md#suspension-of-operational-keys).

## Rules for every target contract

These are what a new or changed governed function must do; each is a spec rule that CI or the
tests check.

- **Map every `restricted` selector** in [`config/genesis.example.json`](../../config/genesis.example.json)
  to exactly one class role, or list it as genesis-only or deferred (GV-17;
  `tools/check_genesis.py` fails otherwise). An unmapped selector falls back to `ADMIN`.
  Then regenerate the matrix with `python tools/gen_role_matrix.py` (CI runs `--check`).
- **Keep governed functions non-payable** (GV-18): `AccessManager.execute` forwards
  `msg.value`. `GovernanceFixture._acceptsValue` probes it.
- **Compare-and-set** setters for funds, recipients, verifiers, renderers and sale parameters
  take the expected current value or revision (GV-19).
- **Emit an event** from every governed setter: value setters the old and the new value,
  per-key toggles (`setTarget`, `setAdmittedMinter`) the key and its new state (GV-20).
- **Raise-only parameters** use `BoundedParameter.initial` in the constructor and `raise` in the
  setter, with a code-level ceiling (GV-21). "At most double" bounds each operation, not each
  window (LIM-GV-7).
- **Contract-to-contract calls** use a one-shot `bind*` resolved to `ADMIN` and run by the
  genesis wiring, never a shared role (GV-24). A new bind must be added to
  `GovernanceConfig.isGenesisSelector` and to the wiring.
- **Delays that reverse a tightening action** (an unpause, a resume, a re-admission) count from
  that action in the target's own code, not from scheduling (GV-23).

## Developer notes

- **`WorksAccessManager` changes OpenZeppelin behavior in four places only.** Rules 2 and 3
  depend on the operation's arguments and scheduler, which no per-selector setting can express;
  keep them in `_canCancel`. Upgrading OpenZeppelin means rechecking that `renounceRole` still
  reaches `_revokeRole`, that `multicall` and nested `execute` still cannot carry a revocation
  (GV-3), and the readback getters `verify` relies on.
- **The `Multicall` exemption.** OpenZeppelin `Multicall`'s self-`delegatecall` is the one
  sanctioned exception to the no-delegatecall rule; `tools/check_budgets.py` scans only
  `src/`, so it does not see it (LIM-GV-8).
- **`configure` gas.** With the maximum 64 wiring calls it must stay inside the EIP-7825 cap;
  the figure and its gate are in the spec's
  [parameters](../../docs/spec/governance.md#parameters-and-limits), measured by
  `GenesisConfig.t.sol` and `Genesis.t.sol`.
- **Suspendable flags.** `tools/check_genesis.py` checks only that each `suspendable` flag in
  the genesis JSON is a boolean on a zero-delay operational role; `GenesisConfig.t.sol`
  compares the flags with `Roles.isSuspendable`.
- **What readback cannot see** (pending grant-delay and target-admin-delay cuts, holders outside
  `cfg`, what the wiring did) is covered by `script/Verify.s.sol`
  ([runbook, step 11](../../script/README.md#11-verify-after-5-days); LIM-GV-6).
- **Test fixture.** Integration tests inherit
  [`GovernanceFixture.sol`](../../test/helpers/GovernanceFixture.sol): hot and cold admins,
  three guardians, two curation signers, a curator and one key per operational role.
  [`GovernanceMocks.sol`](../../test/mocks/GovernanceMocks.sol) holds a sample target.
- **Tests:** `forge test --match-path 'test/governance/**'` (cancellation rules against a stock
  manager, hardening, suspension, genesis, wiring, the invariant campaign);
  `GovernanceRecovery.t.sol` and `Genesis.t.sol` in [`test/integration/`](../../test/integration/).

## Operating it

Guardian liveness, emergencies, rotations, onboarding a target and publishing a configuration
epoch are in the runbook's [operating procedures](../../script/README.md#operating-procedures)
and [admin recovery](../../script/README.md#admin-recovery). Residual risks (colluding or
dishonest guardians, liveness, suspension length) are LIM-GV-4 to LIM-GV-15 in
[known limitations](../../docs/audit/known-limitations.md#trust-and-governance).

## See also

[ADR 0001 §13](../../docs/adr/0001-v1-scope.md#13-governance) (with the guardian powers of §11 and §12),
[ADR 0002](../../docs/adr/0002-access-manager-hardening.md) and its addendum,
[ADR 0003, governance](../../docs/adr/0003-build-time-decisions.md#governance-extends-adr-0002);
[trust assumptions](../../docs/audit/trust-assumptions.md#governance-roles),
[threat model](../../docs/audit/threat-model.md).
