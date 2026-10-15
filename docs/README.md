# Documentation

> Pre-audit. See the [project status](../README.md#status).

## By audience

| You want to | Read |
| --- | --- |
| Learn how the protocol works now | The [specification](spec/README.md) and the [glossary](glossary.md) |
| See how the contracts fit together | The [architecture overview](architecture.md) |
| Integrate a marketplace, wallet or indexer | The [integrator guide](integrators/README.md) |
| Audit or review the code | The [auditor pack](audit/README.md) |
| Know why a decision was made | The [ADRs](adr/README.md) |
| Deploy or operate | The [runbook](../script/README.md) and the [genesis configuration](../config/README.md) |
| Contribute | [CONTRIBUTING.md](../CONTRIBUTING.md); automated agents also read [AGENTS.md](../AGENTS.md) |
| Run or extend the tests, or see how strong they are | [Testing](testing/README.md): the layers of the suite, coverage, mutation testing and the symbolic proofs |
| Report a vulnerability | [SECURITY.md](../SECURITY.md) |
| Read the internal review | [Internal review, October 2026](security/internal-review-2026-10.md): by AI agents, not an external audit |

## Where each fact lives

Each fact has one owner; other pages link to it.

| Fact | Owner |
| --- | --- |
| Rules, state machines and parameters | The [specification](spec/README.md) page of the area, by rule ID |
| Where the code departs from an ADR | The [register](spec/README.md#differences-from-the-adrs) in the specification index |
| Event signatures and topic0 values | [Events and indexing](integrators/events-and-indexing.md) |
| Selector, role and delay | The generated [role and permission matrix](audit/roles.md) |
| Gas budgets and measured gas | [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#the-table); Sepolia receipts in [flows](../deployments/11155111/flows.md) |
| Accepted risks and known gaps | [Known limitations](audit/known-limitations.md) |
| Deployed addresses | [Addresses](integrators/addresses.md) and [`deployments/`](../deployments/11155111/README.md) |

## Module READMEs

Each folder under `src/` has a README that maps its code (files, entry points with rule IDs,
storage and bytecode notes, the tests to run) and links to the owners above:
[stream](../src/stream/README.md), [editions](../src/editions/README.md),
[curation](../src/curation/README.md), [sales](../src/sales/README.md),
[economics](../src/economics/README.md), [identity](../src/identity/README.md),
[content](../src/content/README.md), [records](../src/records/README.md),
[entropy](../src/entropy/README.md), [governance](../src/governance/README.md),
[libraries](../src/libraries/README.md), [interfaces](../src/interfaces/README.md) and
[federated](../src/federated/README.md) (v1.1, only if needed). Where a README and the
specification differ, the specification follows the code. How to run and measure the tests is
in [Testing](testing/README.md).

## Checks that keep the docs honest

| Tool | Checks |
| --- | --- |
| [`tools/check_markdown_links.py`](../tools/check_markdown_links.py) | Every relative link and anchor resolves |
| [`tools/gen_role_matrix.py`](../tools/gen_role_matrix.py) `--check` | The role matrix matches `config/genesis.example.json` |
| [`tools/check_docs_facts.py`](../tools/check_docs_facts.py) | Cited test names, interface IDs, event topic0 values, nSLOC and bytecode sizes match the code |
| [`tools/check_genesis.py`](../tools/check_genesis.py) | The genesis configuration matches the compiled selectors |
| [`tools/check_natspec.py`](../tools/check_natspec.py) | Every external or public function, getter, event and error in `src/` has complete NatSpec |
| [`tools/check_budgets.py`](../tools/check_budgets.py), [`tools/check_slither.py`](../tools/check_slither.py) | The engineering budgets; reviewed Slither findings ([triage](security/slither-triage.md)) |

All tools use only the Python standard library; CI runs them ([`ci.yml`](../.github/workflows/ci.yml);
coverage and the Halmos proofs on `main` in [`strength.yml`](../.github/workflows/strength.yml),
and the scheduled runs in [`nightly.yml`](../.github/workflows/nightly.yml) and
[`mutation.yml`](../.github/workflows/mutation.yml)).
The tools that measure the tests ([`tools/check_coverage.py`](../tools/check_coverage.py),
[`tools/mutation.py`](../tools/mutation.py)) and the Halmos setup are described in
[Testing](testing/README.md); Slither's and Halmos's versions are hash-locked in
[`requirements-tools.lock`](../requirements-tools.lock). The [changelog](../CHANGELOG.md)
records what changed.
