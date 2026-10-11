# 6529 Works

[![CI](https://github.com/6529-Collections/6529-works/actions/workflows/ci.yml/badge.svg)](https://github.com/6529-Collections/6529-works/actions/workflows/ci.yml)

6529 Works is the 6529 network's art protocol: the smart contracts for **6529 Stream**,
a curated ERC-721 of 1/1 artworks; **6529 Editions**, a linked ERC-1155 of editions
anchored by Stream masters; and **6529 Stream Federated** (v1.1, only if needed), which
lets artists run their own contracts from the network's templates. Stream works are
curated by TDH-weighted votes in 6529 waves, sold in permissionless auctions that run
24 hours by default, and paid out through immutable pull-payment split wallets. Content
is content-addressed and stored on Arweave and IPFS, with an optional on-chain upgrade.

> **Status: pre-audit, not deployed.** Do not use this code to custody value. The scope
> is fixed by [ADR 0001](docs/adr/0001-v1-scope.md); see [Status](#status-and-maturity)
> for what exists today.

## Tiers

| Tier | Admission | Contract | Primary split (default) |
| --- | --- | --- | --- |
| The Memes | Main Stage winners, ranked by TDH-weighted votes | Existing Memes ERC-1155 (outside this repository) | 50 / 50 |
| 6529 Stream | Approved by the published TDH rule | One shared ERC-721 | 75% artist / 25% network |
| 6529 Editions | An approved edition package anchored by a Stream master | One shared ERC-1155 | 75 / 25 |
| 6529 Stream Federated (v1.1) | Permissionless registration, no curation | Artist-owned contracts from audited templates | 90 / 10 |

Secondary royalties default to 6.529% (ERC-2981); rates use a 100,000 denominator so that
is exact. Defaults apply to new works only: a work keeps the terms it was minted with.

## How a work flows

```
 curation     artist package --> 6529 wave vote --> curation signer attests
                                                         |
 package      anyone registers --> PackageRegistry <-- every listed party accepts
                                          |
 move         lead artist signs "move to Stream" (revocable)
                                          |
 start        anyone calls start --> EnglishAuction --> Stream.mint --> item consumed
                                  (24 h by default)     (token ID, terms locked)
                                          |
 bids         late bids extend the clock; refunds are pulled
                                          |
 settlement   anyone settles --> token to the winner (or a pending claim)
                                  proceeds to split wallets (a failed push: RevenueEscrow)
                                          |
 royalties    ERC-2981 --> split wallets --> payees release (pull)
                                          |
 edition      master settled --> Editions.createEdition --> fixed-price or Dutch sale
```

1. **Curation.** The artist submits a package: a Merkle root over its items. Voters
   approve it in a 6529 wave. The curation signer checks every declared SHA-256 against
   the decoded bytes and signs an EIP-712 `PackageApproval`. In v1 the contracts trust
   that key, not the vote itself.
2. **The package.** Anyone registers an approved package. Every listed party signs the
   root, so nobody is named, or paid, without consent. Each item can be minted once.
3. **The move signature.** The lead artist signs `MoveToStream`, which makes the work
   startable. An unused signature can be revoked.
4. **Auction start.** Anyone may start the auction and pay its gas. The start verifies
   the proof and signatures, mints the token into auction custody and starts the clock.
   Seeded works can use an optional VRF module, requested before the start.
5. **Settlement.** Anyone may settle. A winner who cannot receive the NFT gets a pending
   claim instead of blocking the sale. With no bids the token goes to the artist.
6. **Royalties.** `royaltyInfo` reads terms locked at mint. Payees pull from split
   wallets; artist payouts follow the artist registry, including recovery.
7. **The edition.** Once a master's sale has settled, anyone creates its linked edition
   from the approved package. Editions sell on the fixed-price or Dutch adapter.

The full call flows, trust boundaries and governance map are in
[docs/architecture.md](docs/architecture.md).

## Modules

Status is on `main` as of 11 October 2026. Each module's README carries its design;
the [delivery plan](ops/DELIVERY_PLAN.md) holds the current state.

| Module | Contracts | What it does | Status |
| --- | --- | --- | --- |
| [`stream`](src/stream/README.md) | `Stream`, `WorkRecords` | The shared ERC-721 and its records satellite: finalize, license, locators | On `main` |
| [`editions`](src/editions/README.md) | `Editions` | The shared ERC-1155, linked to Stream masters | On `main` |
| [`curation`](src/curation/README.md) | `PackageRegistry`, `Eip712CurationVerifier` | Package roots, party consent, consume-once items, signer attestations | On `main` |
| [`sales`](src/sales/README.md) | `EnglishAuction`; fixed-price and Dutch adapters | Shared sale adapters over a minimal mint interface | On `main` |
| [`economics`](src/economics/README.md) | `SplitFactory`, `SplitWallet`, `RevenueEscrow`, `AssetAllowlist`, `EconomicsResolver`, `ReleaseVerifier`, `ClaimRouter` | Split wallets, escrow fallback, currency allowlist, per-product terms | On `main` |
| [`identity`](src/identity/README.md) | `ArtistRegistry`, `ConsolidationAdapter` | Artist identity, payout resolution, 7-day recovery, 180-day override | On `main` |
| [`content`](src/content/README.md) | `ContentStore`, `DependencyRegistry`; `Renderer` | Content-addressed chunks, shared libraries, `tokenURI` | On `main` |
| [`records`](src/records/README.md) | `StatementLog` | Append-only signed log: disputes, curation evidence, fixity, manifests | On `main` |
| [`entropy`](src/entropy/README.md) | `VrfEntropyModule` | Optional Chainlink VRF v2.5 seed per work, delivered before the mint | On `main` |
| [`governance`](src/governance/README.md) | `WorksAccessManager`, `GovernanceConfigurator`, `Roles`, `BoundedParameter` | One AccessManager governs everything; guardians can cancel any scheduled operation | On `main`, including genesis wiring |
| [`libraries`](src/libraries/README.md) | `SignatureVerifier`, `DelegatedEOA`, `JsonEscape`, `Utf8`, `SSTORE2`, `BoundedCall` | Shared internal libraries (none is linked) | On `main` |
| [`interfaces`](src/interfaces/README.md) | `IStream`, `IEditions`, `IMintTarget`, and more | Contract surfaces and shared types every module builds against | On `main` |
| [`federated`](src/federated/README.md) | none in v1 | Templates, factory and registry; v1 keeps only the interfaces | v1.1, only if needed |

## Engineering principles

- **Small enough to audit.** A hard line budget, no proxies, no `delegatecall`, every
  contract within EIP-170. Shared code is internal libraries, not linked ones.
- **Explicit trust boundaries.** One OpenZeppelin 5.7.0 `AccessManager` subclass governs
  every contract behind delay classes (immediate, 48 hours, 14 days, 30 days). Setters
  for funds, recipients, verifiers and renderers are compare-and-set, and governed
  functions are non-payable. Guardians can veto and pause, never redirect.
- **Money moves by pull.** Refunds are claimed, never pushed. Payouts collect in split
  wallets that payees release from, token transfers are checked by exact balance delta,
  and a payment that fails falls back to an escrow.
- **Signatures are bound.** EIP-712 domains, `abi.encode` hashing, storage-backed replay
  protection, and one shared verifier (low-s ECDSA, ERC-2098, ERC-1271, EIP-7702 aware).
- **Fail closed, and say so in events.** Custom errors, no soft-failing reads, an event
  for every important state change.
- **Permanence.** Content-addressed storage, finalize pins a work's renderer, and the
  artist's record is immutable once finalized.

### Budgets

| Budget | Limit | Enforced by |
| --- | --- | --- |
| Solidity under `src/` | At most 12,000 non-comment lines (the ADR targets 8–12K) | `tools/check_budgets.py` |
| Linked libraries | At most 5 | `tools/check_budgets.py` |
| `delegatecall` and proxies | None in `src/`; the one sanctioned exception is OpenZeppelin's `Multicall` in `lib/` ([ADR 0002](docs/adr/0002-access-manager-hardening.md)) | `tools/check_budgets.py`; no proxies by design |
| Contract size | EIP-170 (24,576 bytes runtime) and EIP-3860 (49,152 bytes initcode), every contract | `tools/check_budgets.py` on `forge build --sizes` |
| Auction start | At most 350,000 gas at steady state ([ADR 0003](docs/adr/0003-build-time-decisions.md); ADR 0001 said 300K) | `test/sales/auction/EnglishAuctionGas.t.sol` |
| Transaction cap | Every transaction fits 16,777,216 gas (EIP-7825, Fusaka) for worst-case inputs | Gas-cap tests; `Limits` bounds every array |
| `tokenURI` | At most 8M gas in the worst case | The renderer's tests, once [#20](https://github.com/6529-Collections/6529-works/pull/20) lands |
| Invariants | At least 256 runs of depth 128 for contracts that move value | `foundry.toml` |
| CI time | Under 15 minutes per job | Job timeouts |

### CI gates

Every pull request runs three jobs in [`ci.yml`](.github/workflows/ci.yml). **Contracts**:
`forge fmt --check`, `forge build`, `forge test`, the budget gate and the content tooling
tests. **Static analysis**: Slither, failing on any High or Medium finding without a
reviewed row in [`docs/security/slither-triage.md`](docs/security/slither-triage.md).
**Docs**: a broken relative link or anchor in any Markdown file fails the job.

## Quickstart

You need [Foundry](https://book.getfoundry.sh/) (CI pins v1.7.1) and Python 3.12 or
later. The Python tools use only the standard library. Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/6529-Collections/6529-works.git
```

Then `cd 6529-works` (if you cloned without submodules, run `git submodule update --init`).
Build and test:

```bash
forge build
```

```bash
forge test
```

Run the same checks as CI:

```bash
forge fmt --check
```

```bash
python tools/check_budgets.py --profile default
```

```bash
python tools/check_markdown_links.py
```

Slither needs a one-time install of the pinned, hash-locked toolchain (ideally in a virtualenv):

```bash
python -m pip install --require-hashes --only-binary=:all: --no-deps -r requirements-tools.lock
```

Then:

```bash
python tools/check_slither.py
```

The code is Solidity 0.8.37 on the `prague` EVM, with OpenZeppelin 5.7.0 and forge-std 1.17.0
in `lib/`. See [CONTRIBUTING.md](CONTRIBUTING.md) and, for automated agents, [AGENTS.md](AGENTS.md).

## Status and maturity

- **Pre-audit and not deployed.** There is no v1 deployment on any network and no
  external audit. Nothing here is production-ready.
- **What exists.** Every v1 module is on `main` with unit, fuzz and invariant tests:
  Stream and its records satellite, Editions, curation, the English auction and the
  fixed-price and Dutch sales, economics, identity, the content store and renderer, the
  statement log, the entropy module and governance with genesis wiring.
  The deploy library, genesis and readback scripts and a Sepolia runbook are in
  [`script/`](script/README.md); they have been dry-run on a local chain only.
  End-to-end flows on the real, integrated contracts are in `test/integration/`, with a
  gas report: steady-state `start` about 276K, `startWithBid` about 317K, and
  `tokenURI` at most about 7.8M with every record cap filled.
- **What does not exist yet.** The Sepolia deployment (it needs the owner's keys and Safes), the external audit and
  mainnet. [ADR 0003](docs/adr/0003-build-time-decisions.md) lists the open owner decisions.
- **v1.1 and deferred.** 6529 Stream Federated ships in v1.1, and only if needed.
  Deferred beyond v1: other Stream sale types (buy-now, offers, private sales,
  burn-to-mint), VRF reveals after settlement, a verifier backed by the 6529 chain,
  and the museum, which has its own repository.
- **Where to look.** The [delivery plan](ops/DELIVERY_PLAN.md) is the single source of
  delivery state, the [launch checklist](https://github.com/6529-Collections/6529-works/issues/1)
  tracks what remains before launch, and the [docs index](docs/README.md) lists everything
  else. The earlier RC1 reference implementation, deployed on Sepolia, lives in
  [6529Stream](https://github.com/6529-Collections/6529Stream).

## Security

Report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/6529-Collections/6529-works/security/advisories/new),
as described in [SECURITY.md](SECURITY.md). Do not open public issues for exploitable
bugs, and never include keys or secrets.

## Repository layout

```
src/         contracts, one folder per module (see Modules), plus interfaces/ for shared surfaces
test/        unit, fuzz, invariant and integration tests, with shared mocks and helpers
script/      the deploy library, deploy and verify scripts, and the Sepolia runbook
tools/       standard-library Python: the CI gates, and uploader tooling in tools/content
docs/        index, ADRs, architecture and the Slither triage record
ops/         the delivery plan
lib/         git submodules: OpenZeppelin Contracts and forge-std
```

## License

Code is MIT, see [LICENSE](LICENSE). Artworks minted on 6529 Stream and 6529 Editions
default to CC0 ([ADR 0001 §8](docs/adr/0001-v1-scope.md#8-works-content-and-storage)).
