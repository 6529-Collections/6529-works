# 6529 Works

The 6529 network's art protocol: the smart contracts behind **6529 Stream**,
**6529 Editions** and **6529 Stream Federated**.

- **6529 Stream** is the network's curated contract for 1/1 artworks.
  - Artists submit works to 6529 waves, and the community votes with TDH.
  - An approved package is minted exactly as voted, then sold in a 24-hour
    auction on one shared, chronological ERC-721.
- **6529 Editions** is one shared ERC-1155 for editions. Each edition is anchored
  by a Stream master 1/1 and linked to it in both directions.
- **6529 Stream Federated** lets artists run their own contracts from the
  network's audited templates. The contracts are discoverable on-chain through a
  permissionless registry. It ships in v1.1, if needed.

> **Status:** pre-audit, under construction. Nothing here is deployed to mainnet.
> The design is fixed by [ADR 0001](docs/adr/0001-v1-scope.md), and progress
> follows the [delivery plan](ops/DELIVERY_PLAN.md).
> The earlier RC1 reference implementation, which runs on Sepolia, lives in
> [6529Stream](https://github.com/6529-Collections/6529Stream).

## How it fits together

| Tier | Admission | Contract | Primary split (default) |
| --- | --- | --- | --- |
| The Memes | Main Stage winners, ranked by TDH vote | Existing Memes ERC-1155 | 50 / 50 |
| 6529 Stream | Works that pass the published TDH approval rule | One shared ERC-721 (this repo) | 75% artist / 25% network |
| 6529 Editions | Edition packages anchored by a Stream master | One shared ERC-1155 (this repo) | 75 / 25 |
| 6529 Stream Federated | Permissionless registration, no curation | Artist-owned contracts from templates (this repo) | 90 / 10 |

Design principles:
- **Permanence.** Content is content-addressed, stored on Arweave and IPFS with
  an optional on-chain upgrade. Artists finalize their works, and renderers are
  pinned.
- **Explicit trust boundaries.** Governance runs through OpenZeppelin
  AccessManager with timelocks and a guardian.
- **A small, auditable codebase,** with budgets enforced in CI:
  - 8–12K non-comment lines of Solidity;
  - no proxies and no delegatecall;
  - CI under 15 minutes.

## Repository layout

```
src/          contracts: stream, editions, federated, curation, content, sales,
              economics, identity, records, governance, libraries
test/         unit, invariant and integration tests
script/       deployment and verification scripts
docs/adr/     architecture decisions (ADR 0001 is the v1 scope)
ops/          delivery plan
```

## Develop

Requires [Foundry](https://book.getfoundry.sh/). Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/6529-Collections/6529-works.git
cd 6529-works
forge build
forge test
```

Contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md). Instructions for
automated agents are in [AGENTS.md](AGENTS.md).

## Security

This code is pre-audit. Do not use it to custody value. Report vulnerabilities
privately as described in [SECURITY.md](SECURITY.md).

## License

Code: MIT, see [LICENSE](LICENSE). Artworks minted on 6529 Stream and 6529
Editions default to CC0 (ADR 0001 §8).
