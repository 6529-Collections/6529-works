# Auditor pack

What a reviewer needs to start on 6529 Works. No external audit has started; the code has been
reviewed only by AI agents.

> Pre-audit. See the [project status](../../README.md#status).

## The pack

| Page | Read it for |
| --- | --- |
| [Overview](../overview.md) | The system in three pages: the permanent core, its promise, the modules, a sale |
| [Scope](scope.md) | Every contract in `src/` with its size, and what is out of scope |
| [Trust assumptions](trust-assumptions.md) | What the network, each key and each dependency can do, to whom and how fast |
| [Role and permission matrix](roles.md) | Every restricted selector with its role and delay, generated from the genesis configuration |
| [Invariants](invariants.md) | The stateful invariants and key properties, linked to their tests |
| [Known limitations](known-limitations.md) | Limits already accepted, so they are not re-reported |

How to build and run the tests: the [quickstart](../quickstart.md) and
[Testing](../testing/README.md).

## Where to start

The permanent contracts are small and are the part that can never be fixed after launch:
[`src/core/`](../../src/core/) (`Stream6529`, `StreamEditions6529`, `StreamWorkFacts6529`,
`StreamDirectory6529`, `Modules`), the split ledger and vaults, the escrow and the content store.
The most useful review tries to break one sentence of the promise in
[ADR 0010](../adr/0010-plain-permanent-core.md):

1. no module or authority moves, freezes or burns a held token, and a transfer depends on no
   other contract;
2. a minted work's facts and media, a finalized record and a CC0 license never change;
3. money owed in a vault or the escrow is paid out by permanent code.

Then the modules against the seam: for each module, the worst it can do to an existing token,
fact or balance if it is hostile. The busiest module is `EnglishAuction` (start path: at most
370,000 Prague gas and 8 new storage slots; with a bid on a VRF work, which also writes the
seed, 395,000 and 9; asserted in the gas report).

## Existing evidence

- **Tests.** Unit, fuzz, invariant, integration, symbolic, log-replay and fork suites in
  [`test/`](../../test/) ([map](../../test/README.md)); coverage and mutation floors in
  [Testing](../testing/README.md).
- **Static analysis.** Slither runs in CI; every High or Medium finding has a reviewed row in
  the [triage record](../security/slither-triage.md).
- **Sepolia.** Earlier rehearsals ran the code before this restructuring
  ([flows](../../deployments/11155111/flows.md)); rounds r6, r7 and r8 run the plain core
  (r6: [record](../../deployments/11155111/README.md#sepolia-r6-23-november-2026-module-swap-test-instance),
  [flows](../../deployments/11155111/flows-r6.md); r7:
  [record](../../deployments/11155111/README.md#sepolia-r7-23-november-2026-clean-reference-instance),
  [flows](../../deployments/11155111/flows-r7.md); r8, the current instance, from `main` at
  `961bc956`:
  [record](../../deployments/11155111/README.md#sepolia-r8-23-november-2026-current-instance),
  [flows](../../deployments/11155111/flows-r8.md)). The flows are rehearsals with throwaway
  keys, not an audit.

## Reporting

Report findings privately through
[GitHub private vulnerability reporting](https://github.com/6529-Collections/6529-works/security/advisories/new)
([SECURITY.md](../../SECURITY.md)).
