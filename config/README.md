# config

Deployment configuration for the 6529 Works `WorksAccessManager`
([src/governance](../src/governance/README.md)).

[`genesis.core.example.json`](genesis.core.example.json) is the genesis configuration of the
plain core ([ADR 0010](../docs/adr/0010-plain-permanent-core.md)), written by
`python config/make_core_genesis.py` (`--check` fails if the committed file is stale). **Every
address in it is a placeholder**: `0x…a0xx` stands for a contract and `0x…b0xx` for a holder.
A deployment copies it, replaces the network and the holders, and the deploy library
([`script/DeployCore.sol`](../script/README.md)) substitutes the deployed contracts by name.

**This file is the policy.** A deployment's copy may differ only in its network, its holders,
its description and its address fields:
- `python tools/check_genesis.py --config <copy>` compares the copy with this file;
- off anvil, the deploy script refuses a copy whose governed targets or wiring differ from what
  this file produces (`DeployGuards.checkPolicy`).

A change to a role, a delay class or a wiring call is a change to this file, made by PR.

Genesis modules and minters are constructor arguments of `Stream6529`, `StreamEditions6529` and
`StreamDirectory6529`, so nothing is bound by wiring. Every function that changes a waiting period,
a module or a minter, and the two timed moves (`rescue`, `rebind`), maps to NETWORK with no role
delay: the wait that applies is the contract's own setting, which the network changes at once.

| Key | Contents |
| --- | --- |
| `network` | The single authority: one address, a 2-of-n Safe today. Every network role answers for it alone; the configurator proposes it and it calls `acceptNetwork()`. Off anvil the deploy script requires a deployed canonical Safe 1.3.0 or 1.4.1 with a threshold of at least 2, plain-key owners, no module and no guard |
| `roles` | Every role in `Roles.sol`, with its ID, execution class and delay, grant delay, and `network` (true for the roles only the network holds) |
| `holders` | Operational keys only: three pausers, two curation signers, one key each for storage, platform and curator. Off anvil the deploy script refuses placeholder and system addresses, a holder of a network role, a holder that is a contract of the deployment, and fewer than two curation signers |
| `peers` | Ungoverned addresses that wiring passes as arguments, including the manager (the epoch-0 manifest's subject) |
| `manager` | The manager's own functions beyond its OpenZeppelin base: `transferNetwork` and `setBrake` (ADMIN), the open `acceptNetwork` and `brakeOnce` |
| `contracts` | The governed targets: per contract its artifact and its governed selectors, each with its role, delay class and delay; `genesisOnly` one-shot binds (wired, never mapped) |
| `wiring` | The genesis calls `configure` makes before mapping any selector: the package registry's `bindStream` and entropy module, the edition auction's `setTarget(StreamEditions6529)`, the ETH opening bid of 0.05 ETH (`setOpeningBid`), the Independent Stream module's two adapters, two templates and entropy module, and the epoch-0 governance manifest. A call on a contract the deployment lacks (the entropy module without VRF) is left out |
| `settings` | The launch values of the four waiting periods, which `VerifyCore` reads back: `moduleDelay` 604,800 s on `Stream6529`, `StreamEditions6529` and `StreamDirectory6529`; `rescueDelay` 1,209,600 s on `Stream6529`; `rebindDelay` 1,209,600 s on `StreamEditions6529`; `unclaimedPeriod` 15,552,000 s on `StreamDirectory6529` |
| `initialInstalls` | Which initial settings are constructor arguments and which are wiring |
| `unusedRoles` | Roles with no selector |

Other files:
- `sepolia-r1/` to `sepolia-r6/`: each Sepolia round's public inputs (`accounts.json`,
  `genesis.json`, `deploy.env`, `manifest-epoch0.json`). r1 to r5 deployed earlier contracts and
  are kept as records; r6 is the first round of the plain core ([runbook](../script/README.md#sepolia)).
- `local/` (git-ignored): the walkthrough's genesis file, written by
  `script/local/make_genesis.py`.

## Checks

- **[`tools/check_genesis.py`](../tools/check_genesis.py)** (CI) compares every selector with
  `forge inspect <path:Contract> methodIdentifiers` and requires every `restricted` function of
  every concrete contract under `src/` to be mapped or genesis-only, so nothing falls back to
  ADMIN unnoticed. With `--config` it also checks a deployment's copy against this file.
- **[`tools/gen_role_matrix.py`](../tools/gen_role_matrix.py)** renders this file as the
  [role and permission matrix](../docs/audit/roles.md); CI runs it with `--check`.
- **`test/deploy/DeployCore.t.sol`** deploys the whole stack, installs this file with its
  wiring, accepts the network and reads everything back.
