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
src/editions/    6529 Stream Editions ERC-1155
src/federated/   templates, factory and registry (v1.1, if needed; v1 keeps the interfaces)
src/curation/    package registry and curation verifier
src/content/     content store, dependency registry and renderer
src/sales/       shared sale adapters: the English auction; the edition auction (ADR 0005)
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

**4 November 2026: release candidate
[v1.0.0-rc.2](../docs/releases/v1.0.0-rc.2.md).** Phases 1 to 6 are complete. Phase 7
(testnet) has four Sepolia rehearsals: r4 (1 November 2026) runs rc.2's code, `1e7022b`, with
the uniform edition auction run on chain
([record](../deployments/11155111/README.md#sepolia-r4-1-november-2026-current),
[flows](../deployments/11155111/flows.md#r4-the-rc2-candidate-1-november-2026)), and r3 runs
[v1.0.0-rc.1](../docs/releases/v1.0.0-rc.1.md). The items under "Open in phase 7" are still to
do. The code is pre-audit and not production-ready: no external audit has started, and r4 is a
testnet rehearsal whose live Verify is due from 6 November 2026, 12:41:36 UTC.

**What rc.2 is.** The tag on `main` whose contracts, deploy and verify scripts, genesis policy and
`foundry.toml` are those of `1e7022b`, the code deployed as Sepolia rehearsal r4. To rc.1 it adds
[ADR 0005](../docs/adr/0005-stream-editions-auction.md)'s 6529 Stream Editions auction
(`UniformEditionAuction`, its lens, `UniformClearing` and `StepLadder`); generic editions bound
to the adapter that sells them (`bindMinter`), with the fixed-price and Dutch adapters removed;
the museum rule and 6529 Stream's record of each 1/1's primary-sale outcome; pluggable 1/1 sale
methods and governed dependencies; the fixes of the rc.2 seven-lens review (passes A, B and C)
and the rescue-settle fix; and the owner's decisions of 31 October and 1 November 2026 (ADR 0005
and [ADR 0001](../docs/adr/0001-v1-scope.md)'s amendments).

**The evidence** (figures in the [release notes](../docs/releases/v1.0.0-rc.2.md#evidence)):
- adversarial reviews by AI agents, neither an external audit: the October
  [internal review](../docs/security/internal-review-2026-10.md) (no Critical or High finding,
  9 Medium and 30 Low; every Medium and 28 Lows fixed in #51 to #57), and the rc.2 seven-lens
  review, fixed in passes A, B and C (#90, #89, #87), with a Low from the review of #91 fixed in
  #92;
- the test suite: unit, fuzz, integration and fork tests, stateful invariants on every contract
  that moves money, on the wired stack and on the edition auction, a differential fuzz of the
  edition auction against a brute-force reference, per-contract coverage and mutation floors,
  and Halmos proofs over the text, base64, bounded-call, signer-epoch and split libraries and the
  edition auction's clearing and step ladder ([Testing](../docs/testing/README.md));
- the gas budgets of ADR 0004, in Prague gas with exact counts of new slots and accounts, gated
  in CI;
- Sepolia r4: every contract an exact match on Sourcify, Verify passing on a fork advanced five
  days, and the rc.2 flows measured on chain
  ([record](../deployments/11155111/README.md#sepolia-r4-1-november-2026-current),
  [flows](../deployments/11155111/flows.md#r4-the-rc2-candidate-1-november-2026)).

**Open in phase 7:**
- r3's settlements, edition sale and purchases, and a real anti-snipe bid, from 16 October
  2026, 20:35 UTC; until then those rows are simulated;
- the live Verify: r1 and r2 from 16 October, r3 from 20 October, r4 from 6 November 2026,
  12:41:36 UTC;
- the flows not yet run on Sepolia: guardian and admin operations other than r4's dispute
  pause and cancel (which voided an edition sale and refunded it), and a
  recovery or identity change (each needs a Safe or waits a governed delay); finalize and
  preferred-location failover; ERC-20 payments by Permit2
  ([flows](../deployments/11155111/flows.md#pending));
- Etherscan verification, which needs an API key (Sourcify is done);
- the marketplace and metadata rendering matrix
  ([launch checklist](https://github.com/6529-Collections/6529-works/issues/1));
- the fork deploy simulation (`test/fork/DeploySimulationFork.t.sol`): it still runs r3's inputs
  and expects rc.1's 15 governed contracts and 19 wiring calls, where rc.2 deploys 14 and 18, so
  it has failed in the nightly run since 1 November 2026. The other fork tests pass.

**Next (phase 8, audit and mainnet):**
1. **External audit** of the release candidate, with the [auditor pack](../docs/audit/README.md)
   and the review's
   [residual risks](../docs/security/internal-review-2026-10.md#6-residual-risks-and-recommended-next-steps);
   then remediation and a new release candidate.
2. **Mainnet prerequisites:**
   - Glamsterdam's final mainnet parameters: then re-measure ADR 0004's Sepolia column on them,
     the fixed gas allowances (`DELIVERY_GAS`, `PAYOUT_GAS`, the auction's ERC-20 payout frame,
     the VRF callback limit, the claim router's minimums and shortfall ceiling, the
     consolidation read stipend) and the state-gas reservoir (runbook step 13);
   - the network-held role holders of owner decision 18
     ([LIM-GV-18](../docs/audit/known-limitations.md)): a community council for the delayed
     roles, a security council holding PAUSER and GUARDIAN as three guardian Safes with disjoint
     signers, and a dedicated curation signer, with hardware-wallet signers; and the
     operational keys;
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
- 16 October: v1.0.0-rc.1; the mutation baseline completed (#72) and its 78 open gaps closed
  (#73).
- 31 October and 1 November: ADR 0005 and its lanes, with Stream's pluggable 1/1 sales,
  governed dependencies and primary-sale outcomes (#74 to #86); the seven-lens review's fix
  passes A, B and C (#90, #89, #87); owner decisions 18 to 24 (#91) and the rescue-settle fix
  (#92); Sepolia r4, deployed on 1 November (#93); ADR 0001's Main Stage amendment (#94).
- 4 November: mutation floors for rc.2's new contracts (#95); v1.0.0-rc.2.
