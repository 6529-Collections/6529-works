# Addresses

Where the contracts are deployed, and which source each deployment runs.

> Pre-audit. See the [project status](../../README.md#status).

There is no mainnet deployment. The Sepolia instances are testnet rehearsals with throwaway
signers; do not send them value you care about. r10 is the first instance of the
renamed code. Every earlier instance below was deployed before the rename of 28 November 2026
and keeps the protocol's earlier name, "6529 Works", in its records and in every signing
domain (for example `6529 Works Package Registry`).

| Network | Chain ID | Instance | Source | Record |
| --- | ---: | --- | --- | --- |
| Ethereum mainnet | 1 | Not deployed | | |
| Sepolia | 11155111 | r10 (current instance, open gate) | `main` at `c6d49658`, the plain core ([ADR 0010](../adr/0010-plain-permanent-core.md)) under the name 6529 Stream. **Not curated**: a test-only contract, `SepoliaOpenGate` at `0xD40A02677136bd5F147775FC2C143d90c42A424F`, holds `CURATION_SIGNER` and `PLATFORM`, so any wallet can register a package and create a collection ([The open gate](../../script/sepolia/open-gate.md)); governance is otherwise as genesis installed it | [`core-1795871904.json`](../../deployments/11155111/core-1795871904.json) |
| Sepolia | 11155111 | r9 (earlier instance, open gate, earlier name) | `main` at `355a7a71`, the plain core ([ADR 0010](../adr/0010-plain-permanent-core.md)). **Not curated**: a test-only contract, `SepoliaOpenGate` at `0x843d8DCdD279215225f39AFCA33a5Fd4E84370Ac`, holds `CURATION_SIGNER` and `PLATFORM`, so any wallet can register a package and create a collection ([The open gate](../../script/sepolia/open-gate.md)); governance is otherwise as genesis installed it | [`core-1795840548.json`](../../deployments/11155111/core-1795840548.json) |
| Sepolia | 11155111 | r8 (earlier instance) | `main` at `961bc956`, the plain core ([ADR 0010](../adr/0010-plain-permanent-core.md)) with the module fixes of that commit (an edition sale no longer follows a 1/1 offered again; `restart` waits 15 minutes; `auctionClock` answers four values); governance as genesis installed it | [`core-1795440624.json`](../../deployments/11155111/core-1795440624.json) |
| Sepolia | 11155111 | r7 (reference instance) | `main` at `5de6abaa`, the plain core without those module fixes; governance as genesis installed it | [`core-1795423896.json`](../../deployments/11155111/core-1795423896.json) |
| Sepolia | 11155111 | r6 (module-swap test instance) | `main` at `2aac8579`, the same contracts; a renderer is announced for `Stream6529`'s `RENDERER` slot, ready on 30 November 2026 at 06:18:12 UTC | [`core-1795412520.json`](../../deployments/11155111/core-1795412520.json) |
| Sepolia | 11155111 | r5 (superseded) | `main` at `ca02473`, the design before ADR 0010 | [`1795338612.json`](../../deployments/11155111/1795338612.json) |

Earlier rounds (r1 to r4) ran earlier designs; their records stay in
[`deployments/11155111/`](../../deployments/11155111) and the
[Sepolia README](../../deployments/11155111/README.md). Every address of every instance comes
from its deployment record, which is the source of truth; this page does not copy them.

r6 to r10 are five separate deployments, with different addresses: use one instance's
record throughout, never a mix. They share the network Safe, the holders' keys and the VRF
subscription. r6 and r7 run the same contracts; r8 runs the modules as changed at `961bc956`
(the permanent contracts are the same source); r9 runs `main` at `355a7a71` and r10 runs `main`
at `c6d49658`. Use r10 for a test
page: its open gate lets any wallet run the curated path, which also means that nothing on it
was curated. The gate is a Sepolia test convenience and is never deployed on mainnet. r9 is
open in the same way, under the earlier name: its signing domains differ from r10's, so a
page built for one does not sign for the other. r8 is the
instance to use when you need the curated path as it is governed (only its curation signers
approve packages), r7 the one to compare against for the behaviour before the module changes
of `961bc956`, and r6 the one to follow for the module swap.

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
  chain's head, each from its own source commit; r9 and r10 each passed it at the head before
  their gate was granted its two roles, and since then pass with `ALLOW_GOVERNANCE_CHANGES=1`,
  which prints those two grants; for
  r6 run it at a block before the renderer announcement, as
  [Reading r6 back later](../../deployments/11155111/README.md#reading-r6-back-later) shows.
  r6, r7 and r8 passed it on 23 November 2026 and r9 and r10 on 28 November 2026, and Sourcify holds
  an exact match for each instance's 35 contracts.
- **Governance.** The genesis policy each instance installed is committed under `config/`. The
  [role matrix](../audit/roles.md) is generated from `main`'s genesis policy.
- **Settings.** Read `moduleDelay()`, `rescueDelay()`, `rebindDelay()` and
  `StreamDirectory6529.unclaimedPeriod()` directly; they are the network's settings and may differ
  from their launch values (7, 14, 14 and 180 days).
