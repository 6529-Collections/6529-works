# Delivery plan

- **Scope:** [ADR 0001](../docs/adr/0001-v1-scope.md).
- **Delivery owner:** Claude Code, acting for the repository owner.
- **State:** this file is the single source of delivery state.
- **Launch checklist:** [#1](https://github.com/6529-Collections/6529-works/issues/1).

## Principles

- **Always-green `main` and small PRs.** No long-lived integration branches.
- **Budgets are CI gates, not intentions:**
  - 8–12K non-comment lines of Solidity under `src/`;
  - at most 5 linked libraries;
  - no delegatecall or proxies;
  - EIP-170 respected;
  - CI under 15 minutes;
  - starting an ETH auction at steady state costs at most 350K Prague gas and 6 new storage
    slots, 7 with a bid (ADR 0004);
  - every reported operation has an exact count of new storage slots and new accounts, and a
    Prague gas ceiling (ADR 0004);
  - every transaction's regular gas fits the 16,777,216 cap (EIP-7825);
  - `tokenURI` costs 8M gas or less.
- **Port, don't merge.** Reuse comes from the ADR 0001 §17 keep list, rewritten
  to the budgets. The RC1 reference
  (the private 6529Stream repository) and its PR #744
  are reference material only.
- **Tests come with the code:**
  - stateful invariants for every contract that moves money (≥256 runs × depth
    128);
  - selector-specific revert tests;
  - shared adversarial mocks.

## Layout

```
src/libraries/   signatures, escaping and UTF-8, SSTORE2, bounded calls, EIP-7702 detection
src/stream/      6529 Stream ERC-721
src/editions/    6529 Editions ERC-1155
src/federated/   templates, factory and registry (v1.1, if needed; v1 keeps the interfaces)
src/curation/    package registry and curation verifier
src/content/     content store, dependency registry and renderer
src/sales/       shared sale adapters: English auction, fixed price (allowlist phases, permits), Dutch
src/economics/   split factory and wallet, royalty and revenue resolvers, escrow, currency allowlist
src/identity/    artist registry and consolidation adapter
src/records/     statement log
src/governance/  AccessManager role and delay configuration
test/            unit, invariant and integration tests
script/          deployment and verification
```

## Phases

| Phase | Outcome | Exit criteria |
| --- | --- | --- |
| 1. Skeleton | Layout; Foundry config (Solidity ≥0.8.24, OZ 5, forge-std); CI with budget gates | Skeleton CI green in under 15 minutes |
| 2. Foundations | Shared libraries; AccessManager configuration with hardening tests | Library parity and fuzz tests pass; guardian-cancel requirement proven |
| 3. Core products | Stream ERC-721; content store, dependency registry and renderer; package registry and curation verifier; statement log | Curated package → start → token renders from the content store |
| 4. Money | Auction adapter; split wallet and resolvers; currency allowlist | Invariant campaigns pass for auction, splits and escrow |
| 5. Editions and sales | 6529 Editions ERC-1155 with bilateral link; fixed-price adapter; Dutch adapter | Master auction plus linked edition sale works end to end |
| 6. Identity and disputes | Artist registry with consolidation recovery; dispute pause; optional VRF module | Recovery, override and dispute flows tested |
| 7. Testnet | Sepolia deployment, verification, flows and marketplace matrix | Launch checklist testnet section complete |
| 8. Audit and mainnet | External audit, remediation, mainnet ceremony | Launch checklist complete |

## Current status

**16 October 2026: release candidate
[v1.0.0-rc.1](../docs/releases/v1.0.0-rc.1.md).** Phases 1 to 6 are complete. Phase 7
(testnet) has three Sepolia rehearsals, the last of them RC1's code, with the items under "Open in
phase 7" still to do. The code is pre-audit and not production-ready.

**What RC1 is.** The tag on `main` whose contracts, deploy and verify scripts, genesis policy and
`foundry.toml` are those of `e5fe78c`, the code deployed as Sepolia rehearsal r3. It holds every
v1 module of [ADR 0001](../docs/adr/0001-v1-scope.md), as amended by ADRs
[0002](../docs/adr/0002-access-manager-hardening.md),
[0003](../docs/adr/0003-build-time-decisions.md) and
[0004](../docs/adr/0004-gas-budgets-under-glamsterdam.md), and what the October work added to
them: the review fixes, the state-growth gas diet and the source-quality pass.

**The evidence** (figures in the [release notes](../docs/releases/v1.0.0-rc.1.md#evidence)):
- an [internal adversarial review](../docs/security/internal-review-2026-10.md) by AI agents: no
  Critical or High finding, 9 Medium and 30 Low; every Medium and 28 Lows fixed in #51 to #57;
- the test suite: unit, fuzz, integration and fork tests, stateful invariants on every contract
  that moves money and on the wired stack, per-contract coverage and mutation floors, and Halmos
  proofs over the text, base64, bounded-call, signer-epoch and split libraries
  ([Testing](../docs/testing/README.md));
- the gas budgets of ADR 0004, in Prague gas with exact counts of new slots and accounts, gated
  in CI;
- Sepolia r3: every contract an exact match on Sourcify, Verify passing on a fork advanced five
  days, and the lifecycle measured on chain
  ([record](../deployments/11155111/README.md#sepolia-r3-15-october-2026-current),
  [flows](../deployments/11155111/flows.md#r3-the-release-candidate-15-october-2026)).

**Open in phase 7:**
- r3's settlements, edition sale and purchases, and a real anti-snipe bid, from 16 October
  2026, 20:35 UTC; until then those rows are simulated;
- the live Verify: r1 and r2 from 16 October, r3 from 20 October 2026;
- the flows not yet run on Sepolia: the dispute pause and other guardian operations, and a
  recovery or identity change (each needs a Safe or waits a governed delay); finalize and
  preferred-location failover; the Dutch sale and ERC-20 payments by Permit2
  ([flows](../deployments/11155111/flows.md#pending));
- Etherscan verification, which needs an API key (Sourcify is done);
- the marketplace and metadata rendering matrix
  ([launch checklist](https://github.com/6529-Collections/6529-works/issues/1));
- the mutation baseline's four contracts still to record (Editions, FixedPriceSale,
  MintSaleBase, GovernanceConfig).

**Next (phase 8, audit and mainnet):**
1. **External audit** of RC1, with the [auditor pack](../docs/audit/README.md) and the review's
   [residual risks](../docs/security/internal-review-2026-10.md#6-residual-risks-and-recommended-next-steps);
   then remediation and a new release candidate.
2. **Mainnet prerequisites:**
   - Glamsterdam's final mainnet parameters: then re-measure ADR 0004's Sepolia column on them,
     the fixed gas allowances (`DELIVERY_GAS`, `PAYOUT_GAS`, the auction's ERC-20 payout frame,
     the VRF callback limit, the claim router's minimums and shortfall ceiling, the
     consolidation read stipend) and the state-gas reservoir (runbook step 13);
   - the Safes with hardware-wallet signers: the hot and cold admin Safes and three guardian
     Safes, with no shared signer, and the operational keys;
   - the deployment ceremony from the [runbook](../script/README.md), then Verify after the
     5-day setback.
3. **6529 Stream Federated** in v1.1, only if needed (ADR 0001 §16).
4. **The front end:** the Stream, Editions and later Federated pages on 6529.io.

**History:**
- 11 October 2026: repository and ADR 0001; phases 1 to 6 (skeleton and CI gates, libraries,
  governance hardening in ADR 0002, every v1 module, build-time decisions in ADR 0003);
  Sepolia r1 (`60edd9b`) and r2 (`400f96d`), where Glamsterdam's repricing of state was found.
- 13 October: ADR 0004, gas budgets under Glamsterdam; the v1 flows measured on r1 and r2.
- 14 and 15 October: the internal adversarial review and its fixes (#51 to #57, report #60).
- 15 October: invariant suites and fork tests (#62), the gas diet (#63), test infrastructure
  (#58, #59, #65), docs (#61, #64), the quality pass (#66), Sepolia r3 (#67), the test
  organisation (#68) and the mutation baseline (#69).
- 16 October: v1.0.0-rc.1.
