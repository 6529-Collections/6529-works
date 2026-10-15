# Auditor pack

Everything an audit team needs to start on 6529 Works: what is in scope, what each role and
dependency is trusted with, every governed selector, the threat model, the invariants the
tests prove, the risks already accepted, and how to build, test and measure.

> **Status.** Pre-audit. The pack describes `main` at `c4b3355` (15 October 2026). An internal
> adversarial review ran on 14 October 2026. Its fixes merged in PRs #51 and #53 to #57 and are
> cited by finding ID in the ADRs and the code. The governance and deployment fixes (GOV-1 to
> GOV-4, DEPS-3, DEPS-4) are in open PR #52 and are not on `main`. The review reports are not
> public. No external audit has started.

## The pack

| Page | Read it for |
| --- | --- |
| [Scope](scope.md) | Every contract in `src/` with its nSLOC and bytecode size, the inherited OpenZeppelin code, and what is out of scope |
| [Trust assumptions](trust-assumptions.md) | What each role and each external dependency is trusted to do, what it could do if compromised, and how the system recovers |
| [Role and permission matrix](roles.md) | Every restricted selector, its role, delay class and delay, and whether a guardian can cancel it. Generated from the genesis configuration and checked in CI |
| [Threat model](threat-model.md) | Assets, actors, attack surfaces and their mitigations, with the enforcing code and the tests |
| [Invariants](invariants.md) | Every stateful invariant and the key fuzz and unit properties, linked to their tests |
| [Known limitations and accepted risks](known-limitations.md) | Every limitation collected from the ADRs, READMEs and decisions, with its source |
| [Build, test and budgets](build-and-test.md) | Toolchain, commands, CI gates, and the gas and state-growth rules |

## Suggested reading order

1. The root [README](../../README.md) and the [architecture overview](../architecture.md), for
   the shape of the system.
2. [Scope](scope.md) and [trust assumptions](trust-assumptions.md).
3. The [specification](../spec/README.md) pages for the areas in focus. Each lists its rules
   with the tests that prove them.
4. The [threat model](threat-model.md) and the [role matrix](roles.md).
5. [Invariants](invariants.md) and [known limitations](known-limitations.md), to avoid
   re-reporting accepted risks and to find untested properties.
6. The ADRs ([0001](../adr/0001-v1-scope.md) to [0004](../adr/0004-gas-budgets-under-glamsterdam.md))
   for why the design is what it is.

## Where the code is tightest

Areas where a small change has large effects, or where the review concentrated:

- **Contract size.** `EnglishAuction` and `Renderer` sit 127 and 179 bytes under EIP-170
  ([scope](scope.md#how-the-figures-are-measured)).
- **The auction start path.** `EnglishAuction.start` → `Stream.mint` →
  `PackageRegistry.consume` carries a 350K Prague-gas budget and a cap of 6 new storage
  slots, asserted exactly in `test/integration/GasReport.t.sol`
  ([ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md)).
- **Settlement under hostile counterparties.** Receivers that refuse NFTs or ETH, tokens that
  block addresses, and the fixed gas allowances that absorb them
  ([ADR 0004, Security impact](../adr/0004-gas-budgets-under-glamsterdam.md#security-impact)).
- **Identity recovery.** The 7-day changes, 180-day overrides, contests decided by a recorded
  vote, the sticky standing snapshot and the restraint while an override is pending
  ([identity spec](../spec/identity-and-recovery.md)).
- **The governance cancel rules.** `WorksAccessManager` overrides one OpenZeppelin check
  ([governance spec](../spec/governance.md), [ADR 0002](../adr/0002-access-manager-hardening.md)).
- **`tokenURI` within 8M gas** for any record within bounds; the worst measured case is about
  2.5% under the budget ([rendering spec](../spec/rendering-and-tokenuri.md)).

## Existing evidence

- **Tests.** Unit, fuzz, stateful invariant, integration and review-regression suites in
  [`test/`](../../test/); review regressions are in [`test/adv/`](../../test/adv/), named by
  finding ID. The testing strategy, coverage and mutation testing are documented in
  [`docs/testing/`](https://github.com/6529-Collections/6529-works/blob/main/docs/testing/README.md).
- **Static analysis.** Slither runs in CI; every High or Medium finding has a reviewed row in
  the [triage record](../security/slither-triage.md).
- **Sepolia.** Two rehearsal deployments with the mainnet Safe structure, and every v1 flow run
  on them under Glamsterdam pricing ([flows](../../deployments/11155111/flows.md)). They run
  source that predates the review fixes.

## Reporting

Report findings privately through
[GitHub private vulnerability reporting](https://github.com/6529-Collections/6529-works/security/advisories/new)
([SECURITY.md](../../SECURITY.md)). Name the commit, the contract and function, the impact
and preconditions, and a proof of concept where safe.
