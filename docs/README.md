# Documentation

> Pre-audit. See the [project status](../README.md#status).

Start with the [three-page overview](overview.md).

| You want to | Read |
| --- | --- |
| Know what the system is and what is permanent | [Overview](overview.md) |
| See the contracts and how they call each other | [Architecture](architecture.md) |
| Look up a rule | The [specification](spec/README.md), by rule ID; terms in the [glossary](glossary.md) |
| Build, test and run locally | [Quickstart](quickstart.md) and [Testing](testing/README.md) |
| Integrate a marketplace, wallet or indexer | [Integrator guide](integrators/README.md) |
| Review or audit | [Auditor pack](audit/README.md) |
| Know why a decision was made | [ADRs](adr/README.md) |
| Deploy or operate | The [runbook](../script/README.md) and the [genesis configuration](../config/README.md) |
| Report a vulnerability | [SECURITY.md](../SECURITY.md) |
| See what a release contains | The release notes of [v1.0.0-rc.3](releases/v1.0.0-rc.3.md), the current release candidate (pre-audit), and the [changelog](../CHANGELOG.md) |

## Where each fact lives

| Fact | Owner |
| --- | --- |
| Rules and parameters | The [specification](spec/README.md) page of the area, by rule ID |
| Event signatures and topic0 values | [Events and indexing](integrators/events-and-indexing.md) |
| Selector, role and delay | The generated [role matrix](audit/roles.md) |
| Gas budgets and measured gas | [ADR 0004](adr/0004-gas-budgets-under-glamsterdam.md#the-table) |
| Accepted risks and known gaps | [Known limitations](audit/known-limitations.md) |
| Deployed addresses | [Addresses](integrators/addresses.md) and [`deployments/`](../deployments/11155111/README.md) |

[`facts.json`](facts.json) is generated from these owners by
[`tools/gen_facts.py`](../tools/gen_facts.py) for the 6529.io site.

## Checks that keep the docs honest

`tools/check_markdown_links.py` (links and anchors), `tools/gen_role_matrix.py --check` (the role
matrix matches the genesis configuration), `tools/check_docs_facts.py` (test names, interface
IDs, topic0 values and sizes match the code), `tools/check_rules.py` (every rule names tests),
`tools/check_natspec.py` and `tools/check_comment_codes.py` (NatSpec is complete and cites only
what a reader can look up).
