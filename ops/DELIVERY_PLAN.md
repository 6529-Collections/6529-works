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
  - starting an auction costs 350K gas or less at steady state (ADR 0003);
  - every transaction fits the 16,777,216-gas cap (EIP-7825);
  - `tokenURI` costs 8M gas or less.
- **Port, don't merge.** Reuse comes from the ADR 0001 §17 keep list, rewritten
  to the budgets. The RC1 reference
  ([6529Stream](https://github.com/6529-Collections/6529Stream)) and its PR #744
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

- 11 October 2026: repository created and ADR 0001 recorded.
- **Phases 1–6 complete:**
  - skeleton and CI gates: budgets, Slither, links, genesis coverage;
  - shared libraries;
  - governance hardening (ADR 0002) and genesis wiring;
  - every v1 module, independently reviewed: Stream and records, Editions, curation,
    auction, fixed-price and Dutch sales, economics, identity with consolidation
    recovery, content store and renderer, statement log, entropy.
- **Build-time decisions:** [ADR 0003](../docs/adr/0003-build-time-decisions.md).
- **Integration:**
  - end-to-end flows pass on the real contracts;
  - steady-state `start` is about 276K gas, and `startWithBid` about 317K (two-party about 325K);
  - `tokenURI` is at most about 7.8M gas.
- **Deployment:**
  - the deploy library, genesis and readback scripts are done;
  - they have been dry-run on a local chain with Verify passing after the 5-day delay;
  - the Sepolia runbook is in `script/README.md`.
- **Next (phase 7, testnet):**
  - the owner decides the open items in ADR 0003;
  - the owner provisions the Safes, the curation signers, the VRF subscription and the
    delegation mock on Sepolia;
  - then a Sepolia deploy, Verify, the flow and marketplace matrix, and the `tokenURI`
    threshold matrix.
