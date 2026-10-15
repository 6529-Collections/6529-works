# Build, test and budgets

This page tells an auditor how to build and test 6529 Works exactly as CI does, which gates
CI enforces, and which gas, state-growth and engineering budgets every change must keep.
How strong the tests are (per-contract coverage and its floors, mutation testing, the Halmos
proofs) is on [Testing](../testing/README.md).

> Pre-audit. See the [project status](../../README.md#status).

## Prerequisites

| Tool or setting | Version or value | Where it is pinned |
| --- | --- | --- |
| Foundry (`forge`, `anvil`) | v1.7.1 | [`ci.yml`](../../.github/workflows/ci.yml): `foundry-rs/foundry-toolchain` with `version: v1.7.1`, retried with `foundryup --install 1.7.1` |
| Solidity compiler | 0.8.37 (`auto_detect_solc = false`) | [`foundry.toml`](../../foundry.toml) `solc_version` |
| EVM version | `prague` | `foundry.toml` `evm_version`; Prague adds no opcodes over Cancun, and the tests need EIP-7702 |
| Optimizer | on, 200 runs | `foundry.toml` `optimizer`, `optimizer_runs` |
| IR pipeline | off (`via_ir = false`) | `foundry.toml` |
| Metadata | CBOR with an IPFS bytecode hash (`bytecode_hash = "ipfs"`, `cbor_metadata = true`) | `foundry.toml`; ADR 0001 wants exact Sourcify and Etherscan matches |
| Contract size limit | EIP-170 and EIP-3860, not raised (`code_size_limit` is not set) | `foundry.toml` |
| OpenZeppelin Contracts | v5.7.0 (`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`) | git submodule `lib/openzeppelin-contracts`, [`foundry.lock`](../../foundry.lock) |
| forge-std | v1.17.0 (`f3dae6e6ee381f25eb6a246f7da9b85c91a68219`) | git submodule `lib/forge-std`, `foundry.lock` |
| Remappings | `@openzeppelin/contracts/` and `forge-std/` only (`auto_detect_remappings = false`) | `foundry.toml` |
| Python | 3.12 (CI uses 3.12.13); the tools use the standard library only | `ci.yml` |
| Slither | 0.11.6, with every dependency hash-locked | [`requirements-tools.in`](../../requirements-tools.in), [`requirements-tools.lock`](../../requirements-tools.lock) |

Foundry reads `config/` and `test/fixtures/` and writes only `deployments/` (`fs_permissions`
in `foundry.toml`). It downloads solc 0.8.37 itself.

## Clone and build

```bash
git clone --recurse-submodules https://github.com/6529-Collections/6529-works.git
cd 6529-works
forge build
```

- Without submodules, run `git submodule update --init`. CI checks out
  `lib/openzeppelin-contracts` and `lib/forge-std` without their nested, test-only submodules.
- `forge build` also lints production code; `[profile.default.lint]` ignores `test/**/*.sol`.
- `forge build --sizes` prints each contract's runtime and initcode size; the budget gate reads
  the same data as JSON.

## Test

```bash
forge test
```

| Goal | Command |
| --- | --- |
| One file | `forge test --match-path test/curation/PackageRegistry.t.sol` |
| One contract | `forge test --match-contract AuctionInvariantEth` |
| One test, with traces | `forge test --match-test test_consume_revertsDoubleConsume -vvvv` |
| Every stateful campaign (14 contracts) | `forge test --match-contract Invariant` |
| A deeper campaign than CI's (the nightly run's) | `FOUNDRY_PROFILE=deep forge test --match-test invariant_`: 2,000 runs of depth 256 |
| More fuzz runs | `FOUNDRY_FUZZ_RUNS=10000 forge test --match-test testFuzz_` |
| The integration flows on the real, wired contracts | `forge test --match-path "test/integration/*"` |
| Governance: the cancellation rules, suspension and recovery | `forge test --match-path "test/governance/*"`, then `forge test --match-contract GovernanceRecoveryTest` |
| The deploy guards and the readback (`Deploy.s.sol`, `DeployGuards`, `Verify.s.sol`) | `forge test --match-path test/deploy/DeployScript.t.sol` |
| The gas and state-growth gates | `forge test --match-path test/integration/GasReport.t.sol` |
| The gas table (operation, Prague gas, new slots, new accounts) | `forge test --match-test test_Gas_Table -vv` |
| The `tokenURI` budget | `forge test --match-path test/integration/TokenUriBudget.t.sol -vv` |
| Contract sizes | `forge build --sizes` |

- **Campaign settings.** 256 runs of depth 128 with `fail_on_revert`, and 256 fuzz runs, from
  `foundry.toml`; no test overrides them. What each campaign checks is on
  [Invariants](invariants.md).
- **`test_Gas_Table` prints, it does not gate.** Each row's gates run in its own `test_Gas_*`
  test.
- **The integration suite** mocks only external systems: the 6529 delegation contract, the
  Chainlink VRF coordinator, Permit2 (a faithful reproduction at the canonical address) and an
  EIP-2612 ERC-20 ([`test/integration/README.md`](../../test/integration/README.md)).

## CI

[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) runs these jobs, in parallel, on
every pull request and every push to `main`. `forge test` is split in three parts whose
filters together select every test exactly once; the required check **Contracts** is green
only when Build and checks and all three parts are.

| Job | Timeout | Steps, in order |
| --- | --- | --- |
| **Docs** | 5 minutes | `python -m tools.test_check_markdown_links`; `python tools/check_markdown_links.py`; `python -m tools.test_gen_role_matrix`; `python tools/gen_role_matrix.py --check`; `python -m tools.test_check_docs_facts`; `python tools/check_docs_facts.py` |
| **Build and checks** | 15 minutes | checkout with submodules; Python 3.12.13; Foundry v1.7.1; restore the compiler cache (keyed on Foundry 1.7.1, solc 0.8.37 and a digest of the staged `foundry.toml`, `foundry.lock`, `.gitmodules`, `src`, `test`, `script` and `lib` entries); `forge fmt --check`; `forge build`; save the cache; `python tools/check_docs_facts.py --artifacts out`; `python tools/check_budgets.py --profile default`; `python -m tools.test_check_budgets`; `python tools/check_genesis.py`; `python -m tools.test_check_genesis`; `python -m tools.test_check_coverage`; `python -m tools.test_mutation`; the content tooling tests |
| **Tests** (unit, fuzz and integration) | 15 minutes | the same setup and cache; `forge test --no-match-test ^invariant` |
| **Tests** (economics invariants) | 15 minutes | the same; `forge test --match-test ^invariant --match-contract ^EconomicsInvariant` |
| **Tests** (other invariants) | 15 minutes | the same; `forge test --match-test ^invariant --no-match-contract ^EconomicsInvariant` |
| **Contracts** | 5 minutes | fails unless Build and checks and the three Tests jobs succeeded |
| **Static analysis** | 15 minutes | checkout with submodules; Python 3.12.13; Foundry v1.7.1; install Slither from the hash lock; `python -m tools.test_check_slither`; `python tools/check_slither.py` |
Three more workflows run what a pull request leaves out, to keep the organisation's shared
runners for the checks above:
[`strength.yml`](../../.github/workflows/strength.yml) after every merge to `main`, nightly and
on demand (**Coverage**: `forge coverage` under the `lite` profile and
`python tools/check_coverage.py --uncovered`, uploading `lcov.info`; **Symbolic (Halmos)**:
`halmos` under the `symbolic` profile, one test contract at a time, every declared proof
required to pass), [`nightly.yml`](../../.github/workflows/nightly.yml) (the invariant
campaigns under the `deep` profile, and the fork tests in `test/fork` against public mainnet
and Sepolia endpoints) and [`mutation.yml`](../../.github/workflows/mutation.yml) (every
mutation shard, weekly). [Testing](../testing/README.md) describes them and the figures.

### The gates

| Gate | What fails it | Enforced by |
| --- | --- | --- |
| Format | Any file `forge fmt` would change (line length 100, tab width 4, bracket spacing) | `forge fmt --check`, `[fmt]` in `foundry.toml` |
| Build | A compile error | `forge build` |
| Tests | Any failing unit, fuzz, invariant or integration test, including the gas and state-growth gates | `forge test` |
| Budgets | More than 12,000 code lines under `src/`; `delegatecall` or `callcode` in `src/`; more than 5 libraries with a public or external function; any contract of the `default` profile over 24,576 bytes of runtime (EIP-170) or 49,152 bytes of initcode (EIP-3860) | [`tools/check_budgets.py`](../../tools/check_budgets.py) |
| Genesis configuration | A selector in [`config/genesis.example.json`](../../config/genesis.example.json) that is not in its contract's compiled ABI; a `restricted` function (inherited ones included) that is neither mapped, genesis-only nor deferred; a wiring call to an unlisted target or with a non-genesis selector; a delay that does not match its role's class; a role whose `suspendable` flag is not a boolean, or is set on a role with a delay or on GUARDIAN, PAUSER or CURATION_SIGNER; a function `WorksAccessManager` adds to its OpenZeppelin base that `manager` does not list, or lists with another selector, role or delay. `GenesisConfig.t.sol` checks the flags against `Roles.isSuspendable` exactly | [`tools/check_genesis.py`](../../tools/check_genesis.py) |
| Content tooling | A failing `unittest` in `tools/content`. `test_anvil.py` sends the uploader's calldata to the compiled `ContentStore` on a local Anvil node; `CONTENT_E2E_REQUIRE=1` makes a missing `anvil` or build output a failure, not a skip | `python -m unittest discover -s tools/content -t . -p "test_*.py"` |
| Slither | A High or Medium finding in a file outside `lib/`, `test/` and `script/` with no row in [`docs/security/slither-triage.md`](../security/slither-triage.md); any `src/**/*.sol` file Slither did not analyze; an unreadable report. Low, Informational and Optimization findings are counted, not gated | [`tools/check_slither.py`](../../tools/check_slither.py) |
| Markdown links | A relative link or `#anchor` in a tracked `*.md` file (outside `lib/`) that does not resolve, with exact letter case. External links are not fetched | [`tools/check_markdown_links.py`](../../tools/check_markdown_links.py) |
| Role matrix | [`docs/audit/roles.md`](roles.md) differs from what the generator renders from `config/genesis.example.json`, or the configuration fails the generator's own checks (selector hashes, roles, delays) | `tools/gen_role_matrix.py --check` |
| Coverage (on `main`, not pull requests) | A src/ contract below its line or branch floor in [`tools/coverage-floors.json`](../../tools/coverage-floors.json), a src/ file without an entry below 95% of lines or 85% of branches, or an entry for a file that no longer reports | [`tools/check_coverage.py`](../../tools/check_coverage.py) in `strength.yml` |
| Symbolic proofs (on `main`, not pull requests) | A `check_*` in `test/symbolic` with a counterexample, an error or a timeout, or one that did not run | `halmos` with [`halmos.toml`](../../halmos.toml) in `strength.yml` |
| CI time | A job running past its timeout | `timeout-minutes` in `ci.yml` |

Each gate's checker has unit tests that CI runs next to it (`tools/test_*.py`).

### Running the CI checks locally

```bash
forge fmt --check
forge build
forge test
python tools/check_budgets.py --profile default
python tools/check_genesis.py
python -m unittest discover -s tools/content -t . -p "test_*.py"
python tools/check_markdown_links.py
python tools/gen_role_matrix.py --check
python tools/check_natspec.py
```

Slither needs the pinned toolchain, ideally in a virtual environment. CI installs the hash
lock, wheels only:

```bash
python -m pip install --require-hashes --only-binary=:all: --no-deps -r requirements-tools.lock
```

If those wheels do not install on your platform, install the same pinned Slither from the
top-level pins ([CONTRIBUTING.md](../../CONTRIBUTING.md)), then run the gate:

```bash
python -m pip install -r requirements-tools.in
python tools/check_slither.py
```

`check_slither.py` runs `forge clean` and a full `forge build`, so it rebuilds `out/`. A
Slither version bump can change detector behavior, so the
[triage](../security/slither-triage.md) is redone in the same pull request.

## Python tools

All are standard library only and run from anywhere in the repository.

| Tool | Purpose |
| --- | --- |
| [`tools/check_budgets.py`](../../tools/check_budgets.py) | The engineering budgets: lines, delegatecall, linked libraries, contract sizes |
| [`tools/check_genesis.py`](../../tools/check_genesis.py) | The genesis configuration against the compiled contracts and `src/`; with `--config <file>`, a deployment's copy against the committed policy |
| [`tools/check_slither.py`](../../tools/check_slither.py) | Slither, gated by the triage record |
| [`tools/check_markdown_links.py`](../../tools/check_markdown_links.py) | Relative links and anchors in Markdown (`--no-git` checks untracked files too) |
| [`tools/check_natspec.py`](../../tools/check_natspec.py) | NatSpec completeness in `src/`: every external or public function, getter and event has `@notice` (or `@inheritdoc`) and a `@param` and `@return` for each parameter and return value; every error has `@notice` |
| `tools/gen_role_matrix.py` | Generates [Roles](roles.md) from the genesis configuration; `--check` fails if it is stale |
| [`tools/content/`](../../tools/content/README.md) | The content uploader: chunking, manifests, calldata, gas quotes under the Prague and Glamsterdam schedules, verification |

## Gas and state-growth rules

[ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#decision) owns these rules and
[its table](../adr/0004-gas-budgets-under-glamsterdam.md#the-table) the measured figures, which
move whenever a source file changes. CI enforces them in
[`GasReport.t.sol`](../../test/integration/GasReport.t.sol) and the tests listed under
[PROP-GAS](invariants.md#gas-state-growth-and-the-transaction-cap).

- **Prague gas.** Every budget and ceiling is a whole transaction's gas priced with Prague's
  schedule, with storage and accounts cold at the start (ADR 0004 decision 1). Foundry 1.7.1
  has no Amsterdam EVM, so CI cannot measure Glamsterdam gas.
- **The start budget.** A steady-state `start` or `startWithBid` in ETH costs at most 350K
  Prague gas (`START_BUDGET` in [`IntegrationBase.sol`](../../test/integration/IntegrationBase.sol))
  and writes at most 6 or 7 new slots (`START_MAX_SLOTS`, `START_WITH_BID_MAX_SLOTS`). ERC-20
  starts have a regression ceiling, not a budget (decision 6).
- **Ceilings.** `settle` and the first start in a new collection have 400K test ceilings,
  `royaltyInfo` 50,000 gas of execution, and `tokenURI` 8M (`TOKEN_URI_BUDGET`, tested in
  [`TokenUriBudget.t.sol`](../../test/integration/TokenUriBudget.t.sol) and
  [`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol)). Every other operation
  has a regression ceiling (the `*_CEILING` constants); a change that crosses one says why in
  its pull request.
- **Exact counts.** Every `test_Gas_*` asserts its exact number of new slots and new accounts
  (`_growthIs`), as [`StateGrowth.sol`](../../test/helpers/StateGrowth.sol) defines them.
  Lowering a count updates the test, ADR 0004's table and `AGENTS.md` in the same pull request;
  raising one needs a stated reason; raising the start maxima needs an ADR.
- **The transaction cap.** Worst-case bounded inputs fit EIP-7825's 16,777,216 gas. Foundry
  does not enforce the cap, so each test adds the intrinsic gas and calldata itself and asserts
  its own margin (PROP-GAS-7).
- **The harness.** `IntegrationBase._measure` cools storage, adds 2,500 gas
  (`COLD_ACCOUNT_SURCHARGE`) for each account the test had already warmed, and measures before
  it records a state diff. [`GasHarness.t.sol`](../../test/integration/GasHarness.t.sol) checks
  the correction against a fully cold run (PROP-GAS-4).
- **What CI cannot check:** Glamsterdam totals, the pricing of code bytes, real payees' receive
  code, and how mainnet's cap treats state gas
  ([Known limitations](known-limitations.md#gas-and-glamsterdam)).

## Other engineering budgets

| Budget | Limit | Enforced by | Source |
| --- | --- | --- | --- |
| Solidity size | At most 12,000 non-comment, non-blank lines under `src/`; interfaces and shared types count | `check_budgets.py` (`MAX_LINES`) | [ADR 0001](../adr/0001-v1-scope.md#intended-behavior), [AGENTS.md](../../AGENTS.md) |
| Linked libraries | At most 5 libraries with a public or external function | `check_budgets.py` (`MAX_LINKED_LIBRARIES`) | ADR 0001, AGENTS.md |
| No delegatecall | No `delegatecall` or `callcode` in `src/`; the one sanctioned exception is OpenZeppelin `Multicall` in `lib/`, inherited by `WorksAccessManager` | `check_budgets.py` (a scan of `src/` with comments and strings stripped) | ADR 0001, [ADR 0002](../adr/0002-access-manager-hardening.md#security-impact) |
| No proxies | No contract is a proxy | By design; the delegatecall scan is the mechanical check | ADR 0001 |
| Contract size | Every contract of the `default` profile within EIP-170 (24,576 bytes of runtime) and EIP-3860 (49,152 bytes of initcode) | `check_budgets.py --profile default`, from `forge build --sizes --json` | ADR 0001, AGENTS.md |
| Static analysis | No unreviewed High or Medium Slither finding | `check_slither.py` and the [triage record](../security/slither-triage.md) | AGENTS.md |
| Invariant campaigns | At least 256 runs of depth 128 for every contract that moves money | `foundry.toml`; the campaigns and their [gaps](invariants.md#gaps) are on Invariants | ADR 0001, AGENTS.md |
| CI time | Under 15 minutes | Each job's `timeout-minutes`: 15 for Build and checks, each Tests part and Static analysis (all in parallel), and for Coverage and Symbolic in `strength.yml`; 5 for Docs and the Contracts summary | ADR 0001, AGENTS.md |

The budget checker measures the profile named by `--profile` (`default` unless given) and never
infers it from `foundry.toml`, so adding a profile cannot silently change which bytecode the
size gate measures.

## Differences from the ADRs

See the [register](../spec/README.md#differences-from-the-adrs).

## References

- Configuration: [`foundry.toml`](../../foundry.toml), [`foundry.lock`](../../foundry.lock),
  [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml),
  [`slither.config.json`](../../slither.config.json)
- Tools: [`tools/`](../../tools/), [`tools/content/README.md`](../../tools/content/README.md)
- ADRs: [ADR 0001](../adr/0001-v1-scope.md#intended-behavior),
  [ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md)
- Tests: [`GasReport.t.sol`](../../test/integration/GasReport.t.sol),
  [`GasHarness.t.sol`](../../test/integration/GasHarness.t.sol),
  [`IntegrationBase.sol`](../../test/integration/IntegrationBase.sol),
  [`StateGrowth.sol`](../../test/helpers/StateGrowth.sol),
  [`TokenUriBudget.t.sol`](../../test/integration/TokenUriBudget.t.sol)
- Related pages: [Invariants](invariants.md), [Known limitations and accepted risks](known-limitations.md),
  [Roles](roles.md), [Scope](scope.md)
