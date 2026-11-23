# Addresses

Where the contracts are deployed, and which source each deployment runs.

> Pre-audit. See the [project status](../../README.md#status).

There is no mainnet deployment. The Sepolia instances are testnet rehearsals with throwaway
signers; do not send them value you care about.

| Network | Chain ID | Instance | Source | Record |
| --- | ---: | --- | --- | --- |
| Ethereum mainnet | 1 | Not deployed | | |
| Sepolia | 11155111 | r6 (current) | `main` at `2aac8579`, the plain core ([ADR 0010](../adr/0010-plain-permanent-core.md)) | [`core-1795412520.json`](../../deployments/11155111/core-1795412520.json) |
| Sepolia | 11155111 | r5 (superseded) | `main` at `ca02473`, the design before ADR 0010 | [`1795338612.json`](../../deployments/11155111/1795338612.json) |

Earlier rounds (r1 to r4) ran earlier designs; their records stay in
[`deployments/11155111/`](../../deployments/11155111) and the
[Sepolia README](../../deployments/11155111/README.md). Every address of every instance comes
from its deployment record, which is the source of truth; this page does not copy them.

The plain core changes every address: r5's contracts do not implement the interfaces the other
pages describe.

## Checking an instance yourself

- **Code.** Each record pins every contract's address and code hash.
  [`script/VerifyCore.s.sol`](../../script/VerifyCore.s.sol) deploys the same build again in
  memory from the record's `forkBlock` and compares every address and runtime code, the module
  slots, the minters, the settings, the stored configuration, the epoch-0 manifest and the
  governance configuration with the chain. Run it from the instance's source commit with the
  round's `deploy.env` ([runbook](../../script/README.md#4-after-the-broadcast)). It checks the
  state right after genesis, so for r6 run it at a block before the renderer announcement, as
  [Reading r6 back later](../../deployments/11155111/README.md#reading-r6-back-later) shows.
  r6 passed it on 23 November 2026, and Sourcify holds an exact match for each of its 35
  contracts.
- **Governance.** The genesis policy each instance installed is committed under `config/`. The
  [role matrix](../audit/roles.md) is generated from `main`'s genesis policy.
- **Settings.** Read `moduleDelay()`, `rescueDelay()`, `rebindDelay()` and
  `StreamDirectory6529.unclaimedPeriod()` directly; they are the network's settings and may differ
  from their launch values (7, 14, 14 and 180 days).
