# Addresses

Where the contracts are deployed, and which source each deployment runs.

> Pre-audit. See the [project status](../../README.md#status).

There is no mainnet deployment. The Sepolia instances are testnet rehearsals with throwaway
signers; do not send them value you care about.

| Network | Chain ID | Instance | Source | Record |
| --- | ---: | --- | --- | --- |
| Ethereum mainnet | 1 | Not deployed | | |
| Sepolia | 11155111 | r8 (current instance) | `main` at `961bc956`, the plain core ([ADR 0010](../adr/0010-plain-permanent-core.md)) with the module fixes of that commit (an edition sale no longer follows a 1/1 offered again; `restart` waits 15 minutes; `auctionClock` answers four values); governance as genesis installed it | [`core-1795440624.json`](../../deployments/11155111/core-1795440624.json) |
| Sepolia | 11155111 | r7 (reference instance) | `main` at `5de6abaa`, the plain core without those module fixes; governance as genesis installed it | [`core-1795423896.json`](../../deployments/11155111/core-1795423896.json) |
| Sepolia | 11155111 | r6 (module-swap test instance) | `main` at `2aac8579`, the same contracts; a renderer is announced for `Stream6529`'s `RENDERER` slot, ready on 30 November 2026 at 06:18:12 UTC | [`core-1795412520.json`](../../deployments/11155111/core-1795412520.json) |
| Sepolia | 11155111 | r5 (superseded) | `main` at `ca02473`, the design before ADR 0010 | [`1795338612.json`](../../deployments/11155111/1795338612.json) |

Earlier rounds (r1 to r4) ran earlier designs; their records stay in
[`deployments/11155111/`](../../deployments/11155111) and the
[Sepolia README](../../deployments/11155111/README.md). Every address of every instance comes
from its deployment record, which is the source of truth; this page does not copy them.

r6, r7 and r8 are three separate deployments, with different addresses: use one instance's
record throughout, never a mix. They share the network Safe, the holders' keys and the VRF
subscription. r6 and r7 run the same contracts; r8 runs the modules as changed at `961bc956`
(the permanent contracts are the same source). Use r8. r7 is the instance to compare against
when you need the behaviour before those module changes, and r6 is the one to follow for the
module swap.

The plain core changes every address: r5's contracts do not implement the interfaces the other
pages describe.

## Checking an instance yourself

- **Code.** Each record pins every contract's address and code hash.
  [`script/VerifyCore.s.sol`](../../script/VerifyCore.s.sol) deploys the same build again in
  memory from the record's `forkBlock` and compares every address and runtime code, the module
  slots, the minters, the settings, the stored configuration, the epoch-0 manifest and the
  governance configuration with the chain. Run it from the instance's source commit with the
  round's `deploy.env` ([runbook](../../script/README.md#4-after-the-broadcast)). It checks the
  state genesis left. r7 and r8 are kept in that state, so run it against either at the
  chain's head, each from its own source commit; for
  r6 run it at a block before the renderer announcement, as
  [Reading r6 back later](../../deployments/11155111/README.md#reading-r6-back-later) shows.
  All three passed it on 23 November 2026, and Sourcify holds an exact match for each
  instance's 35 contracts.
- **Governance.** The genesis policy each instance installed is committed under `config/`. The
  [role matrix](../audit/roles.md) is generated from `main`'s genesis policy.
- **Settings.** Read `moduleDelay()`, `rescueDelay()`, `rebindDelay()` and
  `StreamDirectory6529.unclaimedPeriod()` directly; they are the network's settings and may differ
  from their launch values (7, 14, 14 and 180 days).
