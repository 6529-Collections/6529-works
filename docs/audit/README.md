# Auditor pack

What a reviewer needs to start on 6529 Stream. No external audit has started; the code has been
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

The permanent contracts are the part that can never be fixed after launch:
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

- **Tests.** Suites in [`test/`](../../test/) ([map](../../test/README.md)); counts of one
  full pass in the [validation record](../testing/validation-2026-11-28.md); commands, floors
  and gaps in [Testing](../testing/README.md).
- **Static analysis.** Slither runs in CI; every High or Medium finding has a reviewed row in
  the [triage record](../security/slither-triage.md).
- **Sepolia.** Earlier rehearsals ran the code before this restructuring
  ([flows](../../deployments/11155111/flows.md)); rounds r6 to r9 run the plain core
  (r6: [record](../../deployments/11155111/README.md#sepolia-r6-23-november-2026-module-swap-test-instance),
  [flows](../../deployments/11155111/flows-r6.md); r7:
  [record](../../deployments/11155111/README.md#sepolia-r7-23-november-2026-clean-reference-instance),
  [flows](../../deployments/11155111/flows-r7.md); r8, from `main` at `961bc956`:
  [record](../../deployments/11155111/README.md#sepolia-r8-23-november-2026-earlier-instance),
  [flows](../../deployments/11155111/flows-r8.md); r9, the current instance, from `main` at
  `355a7a71`, opened to any wallet by a test-only gate that is never deployed on mainnet:
  [record](../../deployments/11155111/README.md#sepolia-r9-28-november-2026-current-instance-with-an-open-gate),
  [flows](../../deployments/11155111/flows-r9.md)). The flows are rehearsals with throwaway
  keys, not an audit. These records are dated before 28 November 2026 and use the protocol's
  earlier name, "6529 Works"; so do the signing domains of those instances.

## Reporting

Report findings privately through
[GitHub private vulnerability reporting](https://github.com/6529-Collections/6529-stream/security/advisories/new)
([SECURITY.md](../../SECURITY.md)).
