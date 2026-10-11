# Documentation

Where to find things in 6529 Works. The project is pre-audit and not deployed; the
[root README](../README.md) gives the overview and the quickstart.

## Start here

| If you want to | Read |
| --- | --- |
| Understand what v1 is and is not | [ADR 0001: v1 scope](adr/0001-v1-scope.md) |
| See how the contracts fit together | [Architecture](architecture.md): modules, identifiers, call flows, trust boundaries, governance map, budget notes |
| Know what is built and what is next | [Delivery plan](../ops/DELIVERY_PLAN.md), and the [launch checklist](https://github.com/6529-Collections/6529-works/issues/1) |
| Deploy, or verify a deployment | [script/README.md](../script/README.md): the anvil dry run and the Sepolia runbook |
| Contribute a change | [CONTRIBUTING.md](../CONTRIBUTING.md); automated agents also read [AGENTS.md](../AGENTS.md) |
| Report a vulnerability | [SECURITY.md](../SECURITY.md) |

## Architecture decision records

The ADRs are the scope and the law. Where the architecture document, a module README and
an ADR disagree, the accepted ADR wins, and a later ADR amends an earlier one. The
[ADR index](adr/README.md) lists their status.

| ADR | Decides |
| --- | --- |
| [0001: v1 scope](adr/0001-v1-scope.md) | The product, network tiers, curation, token model, sales, Editions, economics, storage, permanence, identity and recovery, disputes, governance, Federated, the reuse plan and the engineering budgets |
| [0002: AccessManager hardening](adr/0002-access-manager-hardening.md) | How guardians cancel any scheduled operation, guardian rules, the cold recovery admin, manifests after genesis, and the selector delay classes |
| [0003: build-time decisions](adr/0003-build-time-decisions.md) | What building the modules changed: ABI package hashing, the Stream and WorkRecords split, the 350K start-gas budget, pull-only artist payouts, base64 attestation, and the EIP-7825 transaction cap |

Earlier decisions for the RC1 reference implementation are in the
[6529Stream ADR index](https://github.com/6529-Collections/6529Stream/tree/main/docs/adr).

## Modules

Every module folder under `src/` has a README with its design and limits.

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

Every v1 module is on `main`; see the [module table](../README.md#modules).

## Security

- [SECURITY.md](../SECURITY.md): the policy and how to report privately.
- [Slither triage](security/slither-triage.md): the record of reviewed High and Medium
  static-analysis findings. CI fails on any finding that has no row here.
- The trust boundaries are in the
  [architecture document](architecture.md#trust-boundaries); the accepted risks are in
  [ADR 0001](adr/0001-v1-scope.md#accepted-risks) and [ADR 0003](adr/0003-build-time-decisions.md#security-impact).

## Configuration and deployment

- [`config/`](../config/README.md): the committed genesis configuration and policy, with
  placeholder addresses, checked in CI by `tools/check_genesis.py`.
- [`script/`](../script/README.md): the deploy library, genesis and readback scripts, and the
  Sepolia runbook.
- [`ops/DELIVERY_PLAN.md`](../ops/DELIVERY_PLAN.md): phases, exit criteria and current status.

## Tooling

All tools use only the Python standard library and run from the repository root.

| Tool | Purpose |
| --- | --- |
| [`tools/check_budgets.py`](../tools/check_budgets.py) | The budget gate: source lines, linked libraries, `delegatecall`, and EIP-170 and EIP-3860 sizes. Run it with `--profile default` |
| [`tools/check_slither.py`](../tools/check_slither.py) | Runs Slither and checks every High or Medium finding against the [triage record](security/slither-triage.md) |
| [`tools/check_markdown_links.py`](../tools/check_markdown_links.py) | Fails on a broken relative link or anchor in any tracked Markdown file |
| [`tools/content`](../tools/content/README.md) | Uploader tooling: plan, stage, verify and rebuild a work's bytes in the content store |

Each checker has unit tests beside it (`tools/test_check_*.py`). Slither's version is
pinned in [`requirements-tools.in`](../requirements-tools.in) and hash-locked for CI in
[`requirements-tools.lock`](../requirements-tools.lock); its path filter is in
[`slither.config.json`](../slither.config.json). The CI jobs are defined in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Project history

[CHANGELOG.md](../CHANGELOG.md) records what changed. The RC1 reference implementation,
which runs on Sepolia and predates this repository, is in
[6529Stream](https://github.com/6529-Collections/6529Stream).
