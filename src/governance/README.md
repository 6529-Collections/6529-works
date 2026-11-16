# governance

One OpenZeppelin 5.7.0 `AccessManager`, subclassed as `WorksAccessManager`, governs every 6529
Works contract; a one-shot configurator installs genesis in one transaction. Rules and flows:
[Governance](../../docs/spec/governance.md) (`GV-*`); selectors, roles and delays: the generated
[role and permission matrix](../../docs/audit/roles.md).

## Files

| File | What it is |
| --- | --- |
| `Roles.sol` | Internal library: role IDs 0 to 12, the four delay classes, each role's execution delay, grant delay and label, `isSuspendable`. Every contract imports it; nothing hard-codes a role ID. `MINTER` (6) and `KEEPER` (7) are defined but unused in v1: genesis grants them to nobody and no selector maps to them. |
| `WorksAccessManager.sol` | Stock `AccessManager` plus: the three cancellation rules and the escalated lane (`_canCancel`, `schedule`, `cancel`); suspension (`suspend`, `isSuspended`, `hasRole`); seat lists, caps and the class-delay floor (`_grantRole`, `_revokeRole`; OpenZeppelin's `renounceRole` runs through `_revokeRole`); the managed list (the target setters); governed parameters, recovery and succession (`setParameter`, `setRecoveryAddress`, `registerSuccessor`, `acceptSuccession`, `migrate`, `heartbeat`, `openRecovery`, `approveRecovery`, `objectToRecovery`, `completeRecovery`). |
| `SuccessionProbe.sol` | A stock `AccessManaged` contract `registerSuccessor` creates for the proposed successor, which must re-point it to the manager before `acceptSuccession` (proof it can make the `setAuthority` call every permanent contract needs). |
| `GovernanceConfig.sol` | Internal library: `validate`, `validateWiring`, `isGenesisSelector`, `install`, `verify` (readback) and `hasRecord`. |
| `GovernanceConfigurator.sol` | Deploys its own `WorksAccessManager`, runs `configure(cfg, manifestHash, wiring)` once for its `deployer`, renounces `ADMIN`, and exposes `verify(cfg)` for readback (which also checks the managed list). |
| `BoundedParameter.sol` | Internal library for raise-only parameters: at most double per step, never above a ceiling fixed in the target's code. Its one v1 user is the entropy module's callback gas limit. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Holders of a delayed role | `schedule`, then `execute` (or the target itself) after the delay and within the one-week expiry | GV-4, GV-5, GV-7 |
| Any active guardian | `cancel` of any scheduled operation, except as Rules 2 and 3 restrict; `suspend(roleId, account)` for a `PLATFORM`, `CURATOR` or `STORAGE_OPERATOR` record | GV-1 to GV-3, GV-25 to GV-28 |
| `ADMIN` (30 days) | `grantRole`, `revokeRole`, remaps, target closure and authority moves; a grant or revocation of a suspended record lifts it | GV-4, GV-28, GV-38 to GV-40 |
| `ADMIN` (slow lane, 60 days by default) | `setParameter`, `setRecoveryAddress`, `registerSuccessor` (only proposes; zero withdraws; escalated after a guardian's cancellation) | GV-37, GV-41, GV-43 |
| The pending successor itself | `acceptSuccession`, once it has re-pointed `successionProbe()` to the manager | GV-43 |
| Any active guardian | on an escalated operation, `cancel` is one vote; `approveRecovery`, `objectToRecovery` | GV-37, GV-42 |
| Any active admin | `heartbeat` | GV-42 |
| Anyone | `openRecovery` and `completeRecovery` when their conditions hold; `migrate(from, to)` once the successor has accepted | GV-42, GV-45 |
| A role holder | `renounceRole` for itself, at once; it also lifts its own suspension | GV-28 |
| The deployer, once | `GovernanceConfigurator.configure`, then `verify` by `eth_call` five days later | GV-8 to GV-13 |
| Every governed contract | `restricted` asks `canCall`; some read `PLATFORM`, `CURATOR` or `CURATION_SIGNER` directly | [Roles that targets read directly](../../docs/spec/governance.md#roles-that-targets-read-directly) |

Flows: [Genesis configure](../../docs/spec/governance.md#genesis-configure),
[Suspension of operational keys](../../docs/spec/governance.md#suspension-of-operational-keys).

## Developer notes

- **A new governed function** follows GV-17 to GV-24
  ([rules](../../docs/spec/governance.md#rules-and-invariants)): map its selector in
  [`config/genesis.example.json`](../../config/genesis.example.json) (unmapped falls back to
  `ADMIN`), run `python tools/gen_role_matrix.py`, and add a new `bind*` to
  `GovernanceConfig.isGenesisSelector` and the wiring.
- **Bytecode.** Run `forge build --sizes` (manager runtime and configurator initcode) before
  adding to the manager; figures in the [audit scope](../../docs/audit/scope.md#governance).
- **Storage.** Escalated operations live in OpenZeppelin's schedule, each with an `Escalation`
  record; seats are `EnumerableSet`s for
  `ADMIN` and `GUARDIAN`; handed over means `successor != 0`, and `migrate` keeps no state.
- **Where `WorksAccessManager` changes OpenZeppelin, and what each change relies on.** Rules 2
  and 3 depend on the operation's arguments and scheduler, which no per-selector setting can
  express; keep them in `_canCancel`. Upgrading OpenZeppelin means rechecking each override
  against the upstream behavior it depends on:
  - `canCall`, `hasRole`: answer nothing once handed over; `hasRole` hides a suspended holder.
  - `schedule`: adds the slow and escalated delays by raising `when` before `super.schedule`,
    so it relies on upstream accepting a later `when` and on its own setback and minimum-delay
    handling; records the escalation from the nonce `super.schedule` returns.
  - `cancel`, `_canCancel`: the vote counts on `hashOperation`, `getNonce` and `getSchedule`
    (an escalation is live only for the current nonce of a scheduled operation) and on
    `super.cancel` calling `_canCancel` before it clears the schedule.
  - `consumeScheduledOp`, `_consumeScheduledOp`: record admin activity around upstream
    consumption; `execute` must keep reaching `_consumeScheduledOp`.
  - `_grantRole`, `_revokeRole`: seat caps, class delays, serials and suspension lifts rely on
    `_grantRole`'s `newMember` return and on `renounceRole` reaching `_revokeRole`.
  - `_setTargetFunctionRole`, `_setTargetAdminDelay`, `_setTargetClosed`: the managed-target
    list and the refusal to remap or close the manager rely on the public setters routing
    through these hooks.
  - `migrate` calls each target's stock `AccessManaged.setAuthority` directly, and
    `acceptSuccession` reads the probe's `authority()` after the successor's own
    `setAuthority`: both rely on that function accepting only the current authority as caller.
  - `multicall` and nested `execute` still cannot carry a revocation (GV-3), and the readback
    getters `verify` relies on keep their shapes.
- **`Multicall`'s self-`delegatecall`** is the one sanctioned exception to the no-delegatecall
  rule, unseen by `tools/check_budgets.py` (LIM-GV-8). Readback gaps: `script/Verify.s.sol`
  (LIM-GV-6).
- **Tests:** `forge test --match-path 'test/governance/**'`, the
  [`GovernanceFixture.sol`](../../test/helpers/GovernanceFixture.sol) base, and
  [`test/integration/`](../../test/integration/); [Testing](../../docs/testing/README.md).

## See also

[ADR 0001 §13](../../docs/adr/0001-v1-scope.md#13-governance) (with the guardian powers of §11 and §12),
[ADR 0002](../../docs/adr/0002-access-manager-hardening.md) and its addendum,
[ADR 0003, governance](../../docs/adr/0003-build-time-decisions.md#governance-extends-adr-0002);
[trust assumptions](../../docs/audit/trust-assumptions.md#governance-roles),
[threat model](../../docs/audit/threat-model.md),
[known limitations](../../docs/audit/known-limitations.md#trust-and-governance);
[runbook](../../script/README.md#operating-procedures).
