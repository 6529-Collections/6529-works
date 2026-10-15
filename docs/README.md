# Documentation

Where to find things in 6529 Works. The project is pre-audit; the
[root README](../README.md) gives the overview, the status and the quickstart.

## Start here

| If you want to | Read |
| --- | --- |
| Understand how the protocol works now | The [specification](spec/README.md), one page per area, and the [glossary](glossary.md) |
| See how the contracts fit together | [Architecture](architecture.md): modules, identifiers, call flows, trust boundaries, governance map |
| Integrate a marketplace, wallet, indexer or front end | The [integrator guide](integrators/README.md) |
| Audit or review the code | The [auditor pack](audit/README.md) |
| Understand what v1 is and is not, and why | [ADR 0001: v1 scope](adr/0001-v1-scope.md) and the later [ADRs](adr/README.md) |
| Know what is built and what is next | [Delivery plan](../ops/DELIVERY_PLAN.md), and the [launch checklist](https://github.com/6529-Collections/6529-works/issues/1) |
| Deploy, or verify a deployment | [script/README.md](../script/README.md): the anvil dry run and the Sepolia runbook |
| Contribute a change | [CONTRIBUTING.md](../CONTRIBUTING.md); automated agents also read [AGENTS.md](../AGENTS.md) |
| Report a vulnerability | [SECURITY.md](../SECURITY.md) |

## Specification

How each area works now: state machines, call sequences with roles and delays, rules with the
tests that prove them, events, and failure modes. The ADRs record how the design was decided;
the specification is the current behavior.

| Page | Covers |
| --- | --- |
| [Specification index](spec/README.md) | How the pages fit together and how to read them |
| [Works and storage](spec/works-and-storage.md) | Work records, licenses, finalize, locators, the content store and dependency registry |
| [Curation](spec/curation.md) | Packages, items, approvals, consent, the move signature, consume-once and uniqueness |
| [Stream and auctions](spec/stream-and-auctions.md) | The ERC-721, minting, royalties and the English auction |
| [Editions and sales](spec/editions-and-sales.md) | The linked ERC-1155 and the fixed-price and Dutch adapters |
| [Economics and payouts](spec/economics-and-payouts.md) | Split wallets, currencies, the escrow, signed releases and batch claims |
| [Identity and recovery](spec/identity-and-recovery.md) | The artist registry, consolidations, changes, overrides, contests and restraint |
| [Disputes and statements](spec/disputes-and-statements.md) | The dispute pause, upheld and rejected outcomes, and the statement log |
| [Governance](spec/governance.md) | The AccessManager, roles and delay classes, guardians, genesis and operations |
| [Entropy](spec/entropy.md) | Optional Chainlink VRF seeds |
| [Rendering and tokenURI](spec/rendering-and-tokenuri.md) | The renderer, metadata, inline media and pins |
| [Glossary](glossary.md) | Every protocol term |

## Auditor pack

| Page | Covers |
| --- | --- |
| [Auditor pack index](audit/README.md) | How to use the pack |
| [Scope](audit/scope.md) | Every contract with its nSLOC and bytecode size; what is out of scope |
| [Trust assumptions](audit/trust-assumptions.md) | Per role and per external dependency |
| [Role and permission matrix](audit/roles.md) | Every restricted selector, its role, delay class and guardian cancel (generated) |
| [Threat model](audit/threat-model.md) | Actors, assets, attack surfaces and mitigations |
| [Invariants](audit/invariants.md) | Every tested invariant, linked to its test |
| [Known limitations](audit/known-limitations.md) | Accepted risks and known gaps, with their sources |
| [Build, test and budgets](audit/build-and-test.md) | Building, testing, CI gates, and the gas and state-growth rules |

## Integrator guide

| Page | Covers |
| --- | --- |
| [Integrator guide index](integrators/README.md) | Where to start |
| [Reading a work](integrators/reading-a-work.md) | `tokenURI` JSON, fields, media, editions, dispute statements |
| [Events and indexing](integrators/events-and-indexing.md) | Every event, and how to rebuild state from logs |
| [Addresses](integrators/addresses.md) | Sepolia r2; mainnet to be decided |
| [ABIs and interface IDs](integrators/abis-and-interface-ids.md) | Where ABIs come from, ERC-165 IDs, EIP-712 domains and the protocol hashes |
| [Buying, bidding, settling and claiming](integrators/buying-bidding-settling.md) | Call sequences, errors to handle and gas notes |
| [Storage](integrators/storage.md) | Content addresses, Arweave and IPFS, and the uploader |

## Architecture decision records

The ADRs are the scope and the law, and the record of why. A later ADR amends an earlier one;
where an ADR and the code differ, the specification describes the code and names the
difference. The [ADR index](adr/README.md) lists their status.

| ADR | Decides |
| --- | --- |
| [0001: v1 scope](adr/0001-v1-scope.md) | The product, network tiers, curation, token model, sales, Editions, economics, storage, permanence, identity and recovery, disputes, governance, Federated, the reuse plan and the engineering budgets |
| [0002: AccessManager hardening](adr/0002-access-manager-hardening.md) | How guardians cancel any scheduled operation, guardian rules, the cold recovery admin, manifests after genesis, and the selector delay classes |
| [0003: build-time decisions](adr/0003-build-time-decisions.md) | What building the modules changed: ABI package hashing, the Stream and WorkRecords split, the 350K start-gas budget, pull-only artist payouts, base64 attestation, the EIP-7825 transaction cap, and the owner's decisions on recovery and governance |
| [0004: gas budgets under Glamsterdam](adr/0004-gas-budgets-under-glamsterdam.md) | Gas budgets in Prague gas, exact counts of new storage slots and accounts per operation, the measured Glamsterdam totals, the per-transaction cap restated, and the payee assumption |

Earlier decisions for the RC1 reference implementation are in the ADR index of the
private 6529Stream repository.

## Modules

Every module folder under `src/` has a README with its design notes and limits.

| Module | README |
| --- | --- |
| Stream: the shared ERC-721 and its records satellite | [`src/stream`](../src/stream/README.md) |
| Editions: the shared ERC-1155 | [`src/editions`](../src/editions/README.md) |
| Curation: package registry and curation verifier | [`src/curation`](../src/curation/README.md) |
| Sales: English auction, fixed-price and Dutch adapters | [`src/sales`](../src/sales/README.md) |
| Economics: split wallets, escrow, currency allowlist, resolver | [`src/economics`](../src/economics/README.md) |
| Identity: artist registry and consolidation recovery | [`src/identity`](../src/identity/README.md) |
| Content: content store, dependency registry, renderer | [`src/content`](../src/content/README.md) |
| Records: the statement log | [`src/records`](../src/records/README.md) |
| Entropy: the optional VRF module | [`src/entropy`](../src/entropy/README.md) |
| Governance: AccessManager, roles, configurator | [`src/governance`](../src/governance/README.md) |
| Libraries: shared internal libraries | [`src/libraries`](../src/libraries/README.md) |
| Interfaces: contract surfaces and shared types | [`src/interfaces`](../src/interfaces/README.md) |
| Federated: templates, factory and registry (v1.1, only if needed) | [`src/federated`](../src/federated/README.md) |

## Testing

The testing strategy, coverage and mutation testing are documented in
[`docs/testing/`](https://github.com/6529-Collections/6529-works/blob/main/docs/testing/README.md).
The integration suite on the real, wired contracts is described in
[`test/integration/README.md`](../test/integration/README.md), and the invariant campaigns
are listed in the [auditor pack](audit/invariants.md).

## Security

- [SECURITY.md](../SECURITY.md): the policy and how to report privately.
- [Slither triage](security/slither-triage.md): the record of reviewed High and Medium
  static-analysis findings. CI fails on any finding that has no row here.
- [Internal review, October 2026](security/internal-review-2026-10.md): the internal adversarial
  review by AI agents (not an external audit), its findings, fixes and residual risks.
- The [threat model](audit/threat-model.md), [trust assumptions](audit/trust-assumptions.md)
  and [known limitations](audit/known-limitations.md) in the auditor pack.

## Configuration and deployment

- [`config/`](../config/README.md): the committed genesis configuration and policy, with
  placeholder addresses, checked in CI by `tools/check_genesis.py`.
- [`script/`](../script/README.md): the deploy library, genesis and readback scripts, and the
  Sepolia runbook.
- [`deployments/11155111/`](../deployments/11155111/README.md): the Sepolia records, and the
  [flows measured under Glamsterdam](../deployments/11155111/flows.md).
- [`ops/DELIVERY_PLAN.md`](../ops/DELIVERY_PLAN.md): phases, exit criteria and current status.

## Tooling

All tools use only the Python standard library and run from the repository root.

| Tool | Purpose |
| --- | --- |
| [`tools/check_budgets.py`](../tools/check_budgets.py) | The budget gate: source lines, linked libraries, `delegatecall`, and EIP-170 and EIP-3860 sizes. Run it with `--profile default` |
| [`tools/check_genesis.py`](../tools/check_genesis.py) | Checks the genesis configuration against the compiled selectors and every `restricted` function |
| [`tools/gen_role_matrix.py`](../tools/gen_role_matrix.py) | Generates the [role and permission matrix](audit/roles.md) from the genesis configuration; `--check` fails if it is stale |
| [`tools/check_slither.py`](../tools/check_slither.py) | Runs Slither and checks every High or Medium finding against the [triage record](security/slither-triage.md) |
| [`tools/check_markdown_links.py`](../tools/check_markdown_links.py) | Fails on a broken relative link or anchor in any tracked Markdown file |
| [`tools/content`](../tools/content/README.md) | Uploader tooling: plan, stage, verify and rebuild a work's bytes in the content store |

Each checker has unit tests beside it (`tools/test_*.py`). Slither's version is pinned in
[`requirements-tools.in`](../requirements-tools.in) and hash-locked for CI in
[`requirements-tools.lock`](../requirements-tools.lock); its path filter is in
[`slither.config.json`](../slither.config.json). The CI jobs are defined in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Project history

[CHANGELOG.md](../CHANGELOG.md) records what changed. The RC1 reference implementation,
which predates this repository, is kept in the private 6529Stream repository.
