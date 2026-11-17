# governance

One OpenZeppelin 5.7.0 `AccessManager`, subclassed as `WorksAccessManager`, governs every 6529
Works contract: one authority address (the network), one optional brake, and fixed delays. A
one-shot configurator installs genesis in one transaction. Rules and flows:
[Governance](../../docs/spec/governance.md) (`GV-*`); selectors, roles and delays: the generated
[role and permission matrix](../../docs/audit/roles.md).

## Files

| File | What it is |
| --- | --- |
| `Roles.sol` | Internal library: role IDs (3 unused), the fixed delays (24 hours, 3 days, 7 days, brake 7 days), `isNetworkRole`, `executionDelay`, `label`. Every contract imports it; nothing hard-codes a role ID. |
| `WorksAccessManager.sol` | Stock `AccessManager` plus the network (`network`, `pendingNetwork`, `transferNetwork`, `acceptNetwork`), the brake (`brake`, `setBrake`, `brakeOnce`, `notBefore`), a 14-day expiry, and the refusal to grant a network role or to remap or close the manager itself. |
| `GovernanceConfig.sol` | Internal library: `validate`, `validateWiring`, `isGenesisSelector`, `install`, `verify` (readback) and `hasRecord`. |
| `GovernanceConfigurator.sol` | Deploys its own `WorksAccessManager`, runs `configure(cfg, manifestHash, wiring)` once for its `deployer`, proposes the network, renounces its installer record, and exposes `verify(cfg)` for readback. |
| `BoundedParameter.sol` | Internal library for raise-only parameters: at most double per step, never above a ceiling fixed in the target's code. Its one v1 user is the entropy module's callback gas limit. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| The network | `schedule`, then `execute` (or the target itself) after the class delay; at-once powers directly; `cancel` of any operation | GV-1, GV-2, GV-8 |
| The network (7 days) | `transferNetwork`, `setBrake`, remaps, closures, role settings, `updateAuthority` | GV-4, GV-5, GV-9 |
| The network (no delay) | `grantRole`, `revokeRole` of an operational key | GV-3 |
| The proposed network | `acceptNetwork` | GV-4 |
| The brake | `brakeOnce(operationId)` | GV-6 |
| An operational key | its mapped functions at once; `renounceRole` for itself | GV-3 |
| The deployer, once | `GovernanceConfigurator.configure`, then `verify` by `eth_call` after the network accepts | GV-10 to GV-13 |
| Every governed contract | `restricted` asks `canCall`; some read `PLATFORM`, `CURATOR` or `CURATION_SIGNER` directly | [Roles that targets read directly](../../docs/spec/governance.md#roles-that-targets-read-directly) |

Flows: [Genesis configure](../../docs/spec/governance.md#genesis-configure),
[Handing the network over](../../docs/spec/governance.md#handing-the-network-over).

## Developer notes

- **A new governed function** follows GV-15 to GV-22
  ([rules](../../docs/spec/governance.md#rules-and-invariants)): mark it `restricted`, map its
  selector in [`config/genesis.example.json`](../../config/genesis.example.json) (unmapped falls
  back to `ADMIN`, 7 days), run `python tools/gen_role_matrix.py`, and add a new `bind*` to
  `GovernanceConfig.isGenesisSelector` and the wiring.
- **Storage.** Three addresses (`network`, `pendingNetwork`, `brake`) and one mapping of brake
  marks; everything else is OpenZeppelin's.
- **Where `WorksAccessManager` changes OpenZeppelin, and what each change relies on.** Upgrading
  OpenZeppelin means rechecking each override:
  - `hasRole`: every authorisation path (`canCall`, `_canCallSelf`, `_canCancel`) asks it, so the
    network roles answer from the `network` slot everywhere.
  - `_grantRole`: the only way into a role record; refusing network roles there covers
    `grantRole` and re-grants. The constructor's grant to the installer is allowed.
  - `_consumeScheduledOp`: both `execute` and a target's `consumeScheduledOp` reach it, so a
    brake mark holds either path.
  - `expiration`: `getSchedule`, `_consumeScheduledOp` and `_checkNotScheduled` read it.
  - `_setTargetFunctionRole`, `_setTargetClosed`: the public setters route through them.
- **`Multicall`'s self-`delegatecall`** is the one sanctioned exception to the no-delegatecall
  rule, unseen by `tools/check_budgets.py`.
- **Tests:** `forge test --match-path 'test/governance/**'`, the
  [`GovernanceFixture.sol`](../../test/helpers/GovernanceFixture.sol) base (one network, one
  brake, operational keys; the network accepts in `_deployGovernance`), and
  [`test/integration/`](../../test/integration/); [Testing](../../docs/testing/README.md).

## See also

[ADR 0001 §13](../../docs/adr/0001-v1-scope.md#13-governance),
[ADR 0002](../../docs/adr/0002-access-manager-hardening.md) (both history; the current model is the
spec page), [trust assumptions](../../docs/audit/trust-assumptions.md#governance-roles),
[known limitations](../../docs/audit/known-limitations.md#trust-and-governance),
[runbook](../../script/README.md#operating-procedures).
