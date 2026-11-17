# 6529 Works

[![CI](https://github.com/6529-Collections/6529-works/actions/workflows/ci.yml/badge.svg)](https://github.com/6529-Collections/6529-works/actions/workflows/ci.yml)

6529 Works is the 6529 network's art protocol. It holds two products: **6529 Stream**, one
shared ERC-721 for curated 1/1 artworks, and **6529 Stream Editions**, one shared ERC-1155
whose editions are each anchored by a Stream master. Curated Stream works are approved by
TDH-weighted votes on 6529's Main Stage, the only way into the shared contracts, and attested by
a curation signer; every party named in a curated work signs before it can be sold. A separate
lane, 6529 Stream Federated, lists artists' own contracts built from the network's templates
without that vote, signer or party consent ([ADR 0008](docs/adr/0008-federation.md)). Anyone may start a work's 24-hour English auction, and anyone may settle it.
Money moves by pull: proceeds and royalties collect in immutable split wallets that payees
release from, with an escrow for payments that fail. Content is addressed by hash and stored on
Arweave and IPFS, and anyone can put a work's files on-chain. One OpenZeppelin `AccessManager`
governs every contract: one network address acts at once or after fixed delays of 24 hours,
3 days or 7 days, and an optional brake can delay a scheduled action once.

> **Status: pre-audit.** Do not use this code to custody value. It has had an internal
> adversarial review by AI agents, not an external audit. A rehearsal runs on Sepolia; there
> is no mainnet deployment. See [Status](#status).

## Status

| | |
| --- | --- |
| Maturity | **Pre-audit.** Not production-ready. An internal adversarial review, carried out by AI agents in October 2026, found no Critical or High issues; its fixes are merged ([report](docs/security/internal-review-2026-10.md)), as are those of the rc.2 seven-lens review, also by AI agents. No external audit has started. |
| Release | **[v1.0.0-rc.2](docs/releases/v1.0.0-rc.2.md)**, 4 November 2026: the second release candidate, pre-audit. Its contracts and deploy pipeline are the code Sepolia r4 runs. The first, [v1.0.0-rc.1](docs/releases/v1.0.0-rc.1.md), is the code of r3. |
| Scope | Fixed by [ADR 0001](docs/adr/0001-v1-scope.md) and the ADRs that amend it, through [ADR 0008](docs/adr/0008-federation.md) ([index](docs/adr/README.md)). |
| Code | Every v1 module is on `main`, with about 3,000 unit, fuzz, integration, invariant and fork tests ([testing](docs/testing/README.md), [invariants](docs/audit/invariants.md)). |
| Testnet | Sepolia rehearsal **r4**, deployed on 1 November 2026 from `1e7022b` (the code of v1.0.0-rc.2: the uniform edition auction, the museum rule and the rc.2 fixes) with throwaway signers in the mainnet Safe structure and 1-hour 1/1 auctions, every contract verified on Sourcify: [addresses](docs/integrators/addresses.md), [deployment record](deployments/11155111/README.md), [flows and their gas](deployments/11155111/flows.md). It is a rehearsal; its live Verify passed on 6 November 2026, after the 5-day setback. `main` has moved on since: the permanence and federation work ([ADR 0007](docs/adr/0007-permanence.md), [ADR 0008](docs/adr/0008-federation.md)) and the single network address are not on a testnet yet, so r4's ABIs and roles differ from `main`'s. |
| Mainnet | Not deployed. It follows an external audit ([delivery plan](ops/DELIVERY_PLAN.md)). |
| Known limits | Listed with their sources in [known limitations and accepted risks](docs/audit/known-limitations.md). |


## Quickstart

You need [Foundry](https://book.getfoundry.sh/) v1.7.1 (as CI pins it), Python 3.12 or later
(standard library only) and, for the local walkthrough, bash (Git Bash on Windows).

```bash
git clone --recurse-submodules https://github.com/6529-Collections/6529-works.git
cd 6529-works
forge build                                  # first build: about 470 files, about 5 minutes
forge test --no-match-test "^invariant"      # about 1 minute; plain `forge test` takes about 15
bash script/local/walkthrough.sh             # deploy on anvil and sell one work end to end
```

The [quickstart](docs/quickstart.md) explains each step, what to expect (the lint warnings
`forge build` prints, the timings, the CI checks to run locally) and what the walkthrough does.

## Where to go next

| You want to | Start with |
| --- | --- |
| Understand the protocol | The [architecture overview](docs/architecture.md), the [specification](docs/spec/README.md) and the [glossary](docs/glossary.md) |
| Integrate a marketplace, wallet, indexer or front end | The [integrator guide](docs/integrators/README.md) |
| Run, read or extend the tests | [Testing](docs/testing/README.md) and the [test map](test/README.md) |
| Deploy or operate | The [deploy runbook](script/README.md) and the [genesis configuration](config/README.md) |
| Audit or review security | The [auditor pack](docs/audit/README.md): scope and sizes, trust, roles, threat model, invariants, limitations |
| Contribute code | [CONTRIBUTING.md](CONTRIBUTING.md); automated agents also read [AGENTS.md](AGENTS.md) |
| Know why a decision was made | The [ADRs](docs/adr/README.md) |

Everything else is indexed in [docs/README.md](docs/README.md).

## Repository layout

```
src/         contracts, one folder per module, each with a README that maps its code
test/        unit, fuzz, invariant, integration, fork and symbolic tests
script/      the deploy library, deploy and verify scripts, the local walkthrough, the Sepolia tools
config/      the committed genesis policy and the Sepolia instances' copies
deployments/ deployment records and measured flows, per chain
tools/       standard-library Python: CI gates, generators and the content uploader
docs/        specification, auditor pack, integrator guide, glossary, ADRs, architecture
ops/         the delivery plan
lib/         git submodules: OpenZeppelin Contracts 5.7.0 and forge-std 1.17.0
```

## Security

Report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/6529-Collections/6529-works/security/advisories/new),
as [SECURITY.md](SECURITY.md) describes. Do not open public issues for exploitable bugs, and
never include keys or secrets.

## License

The code is MIT ([LICENSE](LICENSE)). Artworks minted on 6529 Stream and 6529 Stream Editions
default to CC0 ([ADR 0001 §8](docs/adr/0001-v1-scope.md#8-works-content-and-storage)).
