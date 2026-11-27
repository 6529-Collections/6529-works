# 6529 Works

[![CI](https://github.com/6529-Collections/6529-works/actions/workflows/ci.yml/badge.svg)](https://github.com/6529-Collections/6529-works/actions/workflows/ci.yml)

6529 Works is the 6529 network's art protocol. It holds **6529 Stream**, one shared ERC-721 for
curated 1/1 artworks, and **6529 Stream Editions**, one shared ERC-1155 whose editions are each
anchored by a Stream work. **6529 Independent Stream** and **6529 Independent Stream Editions**
are an artist's own pair of contracts, built from the same code. Sales are in ETH: a 1/1 sells
in an English auction and an edition in a uniform-price auction, and anyone may start and
settle them. Money moves by pull through immutable split vaults.

A small set of **permanent** contracts holds only who owns which token, the facts of each
finished work and money already owed. Everything that is a rule lives in **replaceable
modules**, which the network adds (after a waiting period that is the network's own setting,
7 days at launch) and removes at once ([ADR 0010](docs/adr/0010-plain-permanent-core.md)).

**Start with the [three-page overview](docs/overview.md).**

> **Status: pre-audit.** Do not use this code to custody value. It has been reviewed only by AI
> agents; no external audit has taken place. There is no mainnet deployment.

## Status

| | |
| --- | --- |
| Maturity | **Pre-audit.** Not production-ready. |
| Release | **[v1.0.0-rc.3](docs/releases/v1.0.0-rc.3.md)**, 23 November 2026. Its contracts and deploy and verify scripts are the code Sepolia r8 runs (`961bc956`). The earlier candidates, `v1.0.0-rc.1` and `v1.0.0-rc.2`, are the code before the restructuring. |
| Code | The permanent contracts are in [`src/core/`](src/core/), the modules beside them ([ADR 0010](docs/adr/0010-plain-permanent-core.md)). |
| Tests | Counts of one full pass: the [validation record](docs/testing/validation-2026-11-23.md). Gaps: [what is not tested](docs/testing/README.md#what-is-not-tested). |
| Testnet | Three Sepolia instances of the plain core, all deployed on 23 November 2026 with throwaway signers: r8, the current instance, from `main` at `961bc956`, which carries that commit's module fixes and whose governance is as genesis installed it ([deployment record](deployments/11155111/README.md#sepolia-r8-23-november-2026-current-instance)); r7, the reference instance from `main` at `5de6abaa`, without those fixes, its governance also as installed ([deployment record](deployments/11155111/README.md#sepolia-r7-23-november-2026-clean-reference-instance)); and r6, from `main` at `2aac8579`, kept with a renderer proposal pending for a module-swap test ([deployment record](deployments/11155111/README.md#sepolia-r6-23-november-2026-module-swap-test-instance)). Earlier rehearsals (up to r5) ran the code before the restructuring. |
| Mainnet | Not deployed. |
| Known limits | [Known limitations](docs/audit/known-limitations.md) |

## Quickstart

You need [Foundry](https://book.getfoundry.sh/) v1.7.1 and Python 3.12 or later (standard
library only).

```bash
git clone --recurse-submodules https://github.com/6529-Collections/6529-works.git
cd 6529-works
forge build
forge test --no-match-test "^invariant"
```

The [quickstart](docs/quickstart.md) explains each step.

## Where to go next

| You want to | Start with |
| --- | --- |
| Understand the system | [Overview](docs/overview.md), then [architecture](docs/architecture.md) and the [specification](docs/spec/README.md) |
| Integrate a marketplace, wallet or indexer | The [integrator guide](docs/integrators/README.md), [`abi/`](abi/), [`examples/`](examples/README.md) and the reference [`keeper/`](keeper/README.md) |
| Review or audit | The [auditor pack](docs/audit/README.md) |
| Deploy | The [deploy runbook](script/README.md) and the [genesis configuration](config/README.md) |
| Contribute | [CONTRIBUTING.md](CONTRIBUTING.md); automated agents read [AGENTS.md](AGENTS.md) |
| Know why a decision was made | The [ADRs](docs/adr/README.md) |

## Repository layout

```
src/core/    the permanent contracts: Stream6529, StreamEditions6529, StreamWorkFacts6529, StreamDirectory6529, Modules
src/         the modules, the money contracts and shared libraries, one folder per area
test/        unit, fuzz, invariant, integration, fork, symbolic and log-replay tests
script/      the deploy library, deploy and verify scripts, Sepolia tools
config/      the genesis policy and the Sepolia instances' copies
deployments/ deployment records and measured flows, per chain
tools/       standard-library Python: CI gates and generators
docs/        overview, specification, auditor pack, integrator guide, glossary, ADRs
lib/         OpenZeppelin Contracts 5.7.0 and forge-std 1.17.0
```

## Security

Report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/6529-Collections/6529-works/security/advisories/new)
([SECURITY.md](SECURITY.md)). Never include keys or secrets.

## License

The code is MIT ([LICENSE](LICENSE)). Artworks minted on 6529 Stream and 6529 Stream Editions
default to CC0 ([ADR 0001 §8](docs/adr/0001-v1-scope.md#8-works-content-and-storage)).
