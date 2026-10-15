# Auditor pack

Everything an audit team needs to start on 6529 Works: what is in scope, what each role and
dependency is trusted with, every governed selector, the threat model, the invariants the
tests prove, the risks already accepted, and how to build, test and measure.

> Pre-audit. See the [project status](../../README.md#status).

AI agents carried out an internal adversarial review on 14 October 2026; its report, with every
finding, decision and residual risk, is
[docs/security/internal-review-2026-10.md](../security/internal-review-2026-10.md). The fixes
merged in PRs #51 to #57 and are cited by finding ID. No external audit has started.

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

- **Contract size.** `EnglishAuction` and `Renderer` have the smallest EIP-170 margins
  ([scope](scope.md#contracts-in-scope)).
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
- **The governance cancel rules and suspension.** `WorksAccessManager` overrides
  OpenZeppelin's cancel check (three rules) and its membership check (`hasRole`, for the
  guardians' suspension of operational keys)
  ([governance spec](../spec/governance.md), [ADR 0002](../adr/0002-access-manager-hardening.md)
  and its addendum).
- **The deployment and readback guards.** The trust model assumes bare, independent admin and
  guardian Safes and canonical dependencies, which only `Deploy.s.sol` and `Verify.s.sol`
  check, off chain ([trust assumptions](trust-assumptions.md#admin-safes)).
- **`tokenURI` within 8M gas** for any record within bounds; the worst measured case is about
  2.5% under the budget ([rendering spec](../spec/rendering-and-tokenuri.md)).

## Existing evidence

- **Tests.** Unit, fuzz, stateful invariant, integration and review-regression suites in
  [`test/`](../../test/), organised by contract and function ([the map](../../test/README.md)).
  A regression test for a review finding carries the finding ID in a `/// Regression:` NatSpec
  line, so `grep -rn "Regression: MARKET-2" test/` finds every test for MARKET-2. Coverage,
  mutation testing and Halmos proofs are in [Testing](../testing/README.md).
- **The internal review.** Findings, fixes, decisions, residual risks and how to reproduce
  them: [internal-review-2026-10.md](../security/internal-review-2026-10.md).
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
