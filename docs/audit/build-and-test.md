# Build, test and budgets

This page tells an auditor how to build and test 6529 Works exactly as CI does, which gates
CI enforces, and the precise rules for gas and state growth that every change must keep. It
covers the toolchain pins, the commands for full and focused runs, each CI job and its
checks, the Python tools, the Prague-gas and new-state rules of
[ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md), how the test harness measures them,
and the other engineering budgets. The test strategy, coverage and mutation testing are
described in the [testing docs](https://github.com/6529-Collections/6529-works/blob/main/docs/testing/README.md).

> **Status.** Pre-audit. This page describes `main` at `46941d6` (15 October 2026). The ADRs
> record how the design was decided; this page is how it works now. Where they differ, this
> page follows the code and says so under [Differences from the ADRs](#differences-from-the-adrs).

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

Foundry has read access to `config/` and `test/fixtures/` and read-write access to
`deployments/` only (`fs_permissions` in `foundry.toml`). Foundry downloads solc 0.8.37
itself.

## Clone and build

```bash
git clone --recurse-submodules https://github.com/6529-Collections/6529-works.git
cd 6529-works
forge build
```

- If you cloned without submodules, run `git submodule update --init`. CI checks out
  `lib/openzeppelin-contracts` and `lib/forge-std` without their nested submodules, which are
  test-only.
- `forge build` also lints production code: `[profile.default.lint]` ignores `test/**/*.sol`,
  whose byte fixtures use deliberate casts.
- `forge build --sizes` prints each contract's runtime and initcode size; the budget gate
  reads the same data as JSON (see [Other engineering budgets](#other-engineering-budgets)).

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
| A deeper campaign than CI's | `FOUNDRY_INVARIANT_RUNS=1024 FOUNDRY_INVARIANT_DEPTH=256 forge test --match-contract Invariant` |
| More fuzz runs | `FOUNDRY_FUZZ_RUNS=10000 forge test --match-test testFuzz_` |
| The integration flows on the real, wired contracts | `forge test --match-path "test/integration/*"` |
| Governance: the cancellation rules, suspension and recovery | `forge test --match-path "test/governance/*"`, then `forge test --match-contract GovernanceRecoveryTest` |
| The deploy guards and the readback (`Deploy.s.sol`, `DeployGuards`, `Verify.s.sol`) | `forge test --match-path test/deploy/DeployScript.t.sol` |
| The gas and state-growth gates | `forge test --match-path test/integration/GasReport.t.sol` |
| The gas table (operation, Prague gas, new slots, new accounts) | `forge test --match-test test_Gas_Table -vv` |
| The `tokenURI` budget proof | `forge test --match-path test/integration/TokenUriBudget.t.sol -vv` |
| Contract sizes | `forge build --sizes` |

- **Campaign settings.** 256 runs of depth 128 with `fail_on_revert`, and 256 fuzz runs, from
  `foundry.toml`. No test overrides them. What each campaign proves is on
  [Invariants](invariants.md).
- **`test_Gas_Table` prints, it does not gate.** Each row's gates run in its own `test_Gas_*`
  test. The table runs every row twice from a fresh snapshot: once for its gas, then once for
  its new state (see [How the harness measures](#how-the-harness-measures)).
- **The integration suite** mocks only external systems: the 6529 delegation contract, the
  Chainlink VRF coordinator, Permit2 (a faithful reproduction at the canonical address) and an
  EIP-2612 ERC-20 ([`test/integration/README.md`](../../test/integration/README.md)).

## CI

[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) runs three jobs on every pull
request and every push to `main`. They run in parallel; each has its own timeout.

| Job | Timeout | Steps, in order |
| --- | --- | --- |
| **Docs** | 5 minutes | `python -m tools.test_check_markdown_links`; `python tools/check_markdown_links.py`; `python -m tools.test_gen_role_matrix`; `python tools/gen_role_matrix.py --check` |
| **Contracts** | 15 minutes | checkout with submodules; Python 3.12.13; Foundry v1.7.1; restore the compiler cache (keyed on Foundry 1.7.1, solc 0.8.37 and a digest of the staged `foundry.toml`, `foundry.lock`, `.gitmodules`, `src`, `test`, `script` and `lib` entries); `forge fmt --check`; `forge build`; `forge test`; `python tools/check_budgets.py --profile default`; `python -m tools.test_check_budgets`; `python tools/check_genesis.py`; `python -m tools.test_check_genesis`; the content tooling tests |
| **Static analysis** | 15 minutes | checkout with submodules; Python 3.12.13; Foundry v1.7.1; install Slither from the hash lock; `python -m tools.test_check_slither`; `python tools/check_slither.py` |

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
```

Slither needs the pinned toolchain, ideally in a virtual environment. CI installs the
hash lock, wheels only, with nothing built:

```bash
python -m pip install --require-hashes --only-binary=:all: --no-deps -r requirements-tools.lock
```

If the lock's wheels do not install on your platform, install the same pinned Slither from
the top-level pins instead ([CONTRIBUTING.md](../../CONTRIBUTING.md)):

```bash
python -m pip install -r requirements-tools.in
```

Then run the gate:

```bash
python tools/check_slither.py
```

`check_slither.py` runs `forge clean` and a full `forge build`, so it rebuilds `out/`. A
Slither version bump can change detector behavior, so the triage is redone in the same pull
request ([triage record](../security/slither-triage.md)).

## Python tools

All are standard library only and run from anywhere in the repository.

| Tool | Purpose |
| --- | --- |
| [`tools/check_budgets.py`](../../tools/check_budgets.py) | The engineering budgets: lines, delegatecall, linked libraries, contract sizes |
| [`tools/check_genesis.py`](../../tools/check_genesis.py) | The genesis configuration against the compiled contracts and `src/`; with `--config <file>`, a deployment's copy against the committed policy |
| [`tools/check_slither.py`](../../tools/check_slither.py) | Slither, gated by the triage record |
| [`tools/check_markdown_links.py`](../../tools/check_markdown_links.py) | Relative links and anchors in Markdown (`--no-git` checks untracked files too) |
| `tools/gen_role_matrix.py` | Generates [Roles](roles.md) from the genesis configuration; `--check` fails if it is stale |
| [`tools/content/`](../../tools/content/README.md) | The content uploader: chunking, manifests, calldata, gas quotes under the Prague and Glamsterdam schedules, verification |

## Gas and state-growth rules

The rules are in [ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md) and
[AGENTS.md](../../AGENTS.md). The measured figures for every operation are in
[ADR 0004's table](../adr/0004-gas-budgets-under-glamsterdam.md#the-table); this page does not
repeat them, because they move whenever a source file changes.

### Prague gas

**Prague gas** is a whole transaction's gas, priced with Prague's schedule: the 21,000
intrinsic gas, the calldata (EIP-2028, or the EIP-7623 floor when that is higher) and the
execution before refunds, with state creation at Prague's prices and every storage slot and
account cold at the start, as in a real transaction (ADR 0004, decision 1). Every budget and
ceiling below is Prague gas. Foundry 1.7.1 has no Amsterdam EVM, so CI cannot measure
Glamsterdam gas; see [What CI cannot check](#what-ci-cannot-check).

### The start budget

- **350K and 6 or 7 new slots.** A steady-state `start` in ETH costs at most 350K Prague gas
  and writes at most 6 new storage slots; `startWithBid` costs at most 350K and writes at most
  7. This holds for a one-artist work, a two-party work, a VRF work and an edition master
  (`START_BUDGET` in [`IntegrationBase.sol`](../../test/integration/IntegrationBase.sol);
  `START_MAX_SLOTS` and `START_WITH_BID_MAX_SLOTS` in
  [`GasReport.t.sol`](../../test/integration/GasReport.t.sol); ADR 0004 decisions 1, 2 and 6).
- **Steady state** means that Stream, the collection, the auction's custody balance, the
  artist's move-nonce word and the auction's shared sale terms (with and without the
  increment floor a first bid locks) have all been written before. The measured items are
  works in an eight-item package (proof depth 3).
- **The 6 slots** are Stream's three-word token record and the ERC-721 owner, the package
  registry's consumed-content record, and the auction's sale; `startWithBid` adds the bid
  (ADR 0004).
- **ERC-20 starts have no budget.** An ERC-20 `startWithBid` paid by relayed Permit2 has a
  regression ceiling and exact counts only. Admitting the first ERC-20, or approving a Stream
  package that names one, must come with a re-measurement and publication of its start cost,
  in Prague gas and on the target chain (ADR 0004 decision 6, AGENTS.md).
- **One-time starts** (the first work ever, the first bid under new sale terms) have
  regression ceilings, not the budget. The first start in a new collection has a 400K test
  ceiling (`FIRST_IN_COLLECTION_CEILING`).

### Test ceilings and regression ceilings

- **Test ceilings.** `settle` and the first start in a new collection: 400K Prague gas each
  (`SETTLE_CEILING`, `FIRST_IN_COLLECTION_CEILING`). `royaltyInfo`: under 50,000 gas of
  execution. `tokenURI`: 8M (below).
- **Regression ceilings.** Every other measured operation has one: its Prague gas when the
  ceiling was set, plus about 2%, rounded up to the thousand (the `*_CEILING` constants in
  `GasReport.t.sol`). A regression ceiling is not a budget. A change that crosses one says why
  in its pull request and moves it (ADR 0004 decision 1).
- Prague figures move by a few dozen gas whenever any source file changes: metadata hashes
  change CREATE2 addresses, and with them the calldata (ADR 0004).

### Exact counts of new slots and new accounts

- **Definitions** (ADR 0004 decision 2, [`StateGrowth.sol`](../../test/helpers/StateGrowth.sol)):
  - a **new slot** is a storage slot that is zero before the transaction and non-zero after
    it, read from the state itself. It counts once however often it is written; a write that
    a revert or a halt undid does not count; transient storage is never a slot;
  - a **new account** is an account that is empty before the transaction (no code, nonce
    zero, balance zero) and not empty after it: a contract creation, or ETH sent to an empty
    address. The sender is never new.
- **Every operation asserts its exact counts.** Every `test_Gas_*` row in `GasReport.t.sol`
  asserts its exact number of new slots and new accounts (`_growthIs`); on a mismatch it first
  logs each new slot and account by contract, so the failure names them. A `tokenURI` creates
  no state.
- **Changing a count.**
  - When a change lowers a count, the same pull request lowers the test's figure, ADR 0004's
    table and the figure in `AGENTS.md`. Lowering needs no new ADR.
  - Raising a count needs a stated reason in the pull request.
  - Raising the `start` or `startWithBid` maximum (6 and 7) needs an ADR.

### The per-transaction cap (EIP-7825)

- **The rule.** Every transaction's regular gas fits the EIP-7825 cap of 16,777,216 gas for
  worst-case bounded inputs ([AGENTS.md](../../AGENTS.md); ADR 0004 decision 4). The cap
  applies to regular gas; on Sepolia, transactions whose state-creation gas took them above it
  were accepted. That is an observation of Sepolia's behavior, not a reading of the final EIP
  mechanics ([Known limitations](known-limitations.md#gas-and-glamsterdam), LIM-GAS-2).
- **How CI checks it.** Foundry's `prague` EVM does not enforce the cap, so the tests build the
  worst case from cold state and add the intrinsic gas and the calldata (with the EIP-7623
  floor) themselves, in Prague gas, the measure Foundry has. Each test asserts its own margin
  below the cap: for example, at most 75% of it in [`GasCap.t.sol`](../../test/economics/GasCap.t.sol),
  and under half for the identity worst cases. The list of cap tests is PROP-GAS-7 on
  [Invariants](invariants.md#gas-state-growth-and-the-transaction-cap).
- **Bounded inputs.** [`Limits`](../../src/interfaces/types/Limits.sol) bounds every
  user-supplied array with the cap in mind.

### The `tokenURI` budget

`tokenURI` costs at most 8M Prague gas in the worst case (ADR 0004 decision 1). Three suites
prove it:
- [`TokenUriBudget.t.sol`](../../test/integration/TokenUriBudget.t.sol) builds, on the real
  stack, works with every cap the protocol allows at once (the dearest record of the
  renderer's matrix, 256 KiB of attested `Base64` primary media, the largest preview, 32 media
  files, 16 locators, the dearest collection name and a dispute statement) and measures
  `Stream.tokenURI` and `Editions.uri` cold against `TOKEN_URI_BUDGET` (8,000,000);
- [`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol) (`RendererGasTest`,
  `RendererGasBudgetTest`) holds the renderer's record and media matrix under 8M;
- `GasReport.t.sol` `test_Gas_TokenURIBySize` measures the inline-size matrix and asserts that
  a `tokenURI` creates no state.

### How the harness measures

[`IntegrationBase.sol`](../../test/integration/IntegrationBase.sol) measures each row;
Foundry 1.7.1 does not model a transaction's cold start fully, and the harness works around it.

1. **Cool, then call.** `_measure` cools the storage of every deployed contract (`vm.cool`
   through `_coolAll`), checks that cooling worked (`_requireCooling` fails once a state-diff
   recording has warmed the test), makes the call as the sender, and reads the called frame's
   gas from `vm.lastCallGas`. It reads that by hand: the pinned forge-std declares a sixth field
   (`gasStateUsed`) that Foundry 1.7.1 does not return. `_txGas` adds 21,000 and the calldata
   (or its EIP-7623 floor).
2. **Correct for warm accounts.** `vm.cool` cools storage but not accounts. Before measuring,
   `_warmth` probes which accounts of `_probeSet` the test has already touched (by the cost of
   `EXTCODESIZE`). `StateGrowth` then reports the accounts a real transaction would reach
   cold, and `_measureGrowth` adds `COLD_ACCOUNT_SURCHARGE` (2,500: EIP-2929's 2,600 cold
   against 100 warm) for each one the run priced warm. A call that reaches an account outside
   the probe set fails the measurement. Without the correction, a steady-state start read about
   17,500 gas low (ADR 0004).
3. **Measure first, record last.** Recording a state diff warms what it reads, and after a
   recording nothing in that test is cold again, even after a state revert. So each row is
   measured and then recorded from the same snapshot, and `test_Gas_Table` takes every row's
   gas before any row's recording. `_requireCooled` fails if the recorded call reached storage
   that `_coolAll` does not cool.
4. **Count from the state.** `StateGrowth.count` takes every slot and account the recording
   names as a candidate, and decides whether each is new by reading it before and after the
   call from the state itself, so it does not depend on how Foundry flags reverted frames.
   [`StateGrowth.t.sol`](../../test/helpers/StateGrowth.t.sol) covers overwrites, zero to zero,
   non-zero to zero, reverted writes, out-of-gas and `INVALID` frames, re-entrancy,
   `delegatecall`, transient storage, `CREATE`, and ETH to a fresh account or an empty
   precompile.
5. **Check the correction against the truth.** In
   [`GasHarness.t.sol`](../../test/integration/GasHarness.t.sol), `setUp` is a transaction of its
   own, so a test starts with every account and slot cold. A steady-state `start` measured
   there must equal the corrected figure measured after the test warmed every account the call
   reaches (`test_TheColdAccountCorrectionIsExact`); nothing is added when the accounts are
   already cold (`test_NothingIsAddedForAccountsAlreadyCold`); storage the harness does not cool
   is refused (`test_RequireCooledRefusesStorageItDoesNotCool`).

### What CI cannot check

From [ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#consequences):
- **Glamsterdam totals.** The Sepolia column of ADR 0004's table is measured by hand on a
  deployment. CI gates the count of new slots and accounts, which is the part of the
  Glamsterdam cost it can see.
- **Code bytes.** CI counts a contract creation as one new account; it does not price the
  creation's code bytes, which Glamsterdam reprices.
- **Real payees' receive code.** A Safe or a contract payee costs more to pay than the plain
  accounts CI uses (about 6,300 gas more for a Safe in the r2 replays).
- **The cap's treatment of state gas** on mainnet, until Foundry supports Amsterdam and
  mainnet's parameters are final.

The consequences are on [Known limitations](known-limitations.md#gas-and-glamsterdam).

## Other engineering budgets

| Budget | Limit | Enforced by | Source |
| --- | --- | --- | --- |
| Solidity size | At most 12,000 non-comment, non-blank lines under `src/` (the ADR targets 8 to 12K); interfaces and shared types count | `check_budgets.py` (`MAX_LINES`) | [ADR 0001](../adr/0001-v1-scope.md#intended-behavior), [AGENTS.md](../../AGENTS.md) |
| Linked libraries | At most 5 libraries with a public or external function | `check_budgets.py` (`MAX_LINKED_LIBRARIES`) | ADR 0001, AGENTS.md |
| No delegatecall | No `delegatecall` or `callcode` in `src/` code; the one sanctioned exception is OpenZeppelin `Multicall` in `lib/`, inherited by `WorksAccessManager` | `check_budgets.py` (a scan of `src/` with comments and strings stripped) | ADR 0001, [ADR 0002](../adr/0002-access-manager-hardening.md#security-impact) |
| No proxies | No contract is a proxy | By design; the delegatecall scan is the mechanical check | ADR 0001 |
| Contract size | Every contract of the `default` profile within EIP-170 (24,576 bytes of runtime) and EIP-3860 (49,152 bytes of initcode) | `check_budgets.py --profile default`, from `forge build --sizes --json` | ADR 0001, AGENTS.md |
| Static analysis | No unreviewed High or Medium Slither finding | `check_slither.py` and the [triage record](../security/slither-triage.md) | AGENTS.md |
| Invariant campaigns | At least 256 runs of depth 128 for every contract that moves money | `foundry.toml`; which contracts have campaigns is listed on [Invariants](invariants.md#gaps) | ADR 0001, AGENTS.md |
| CI time | Under 15 minutes | Each job's `timeout-minutes`: Contracts 15, Static analysis 15 (in parallel), Docs 5 | ADR 0001, AGENTS.md |

The budget checker always measures the profile named by `--profile` (`default` unless given);
it never infers the profile from `foundry.toml`, so adding a profile cannot silently change
which bytecode the size gate measures.

## Differences from the ADRs

- **ADR 0001, "EIP-170 enforced in every Foundry profile":** the size gate measures the one
  profile CI names (`--profile default`), which is the only profile `foundry.toml` defines.
- **ADR 0001, "8–12K non-comment lines":** the gate enforces the maximum (12,000) only; there
  is no minimum.
- **ADR 0001, "full build and test in under 15 minutes":** enforced as per-job timeouts. The
  Contracts and Static analysis jobs run in parallel, 15 minutes each.
- **ADR 0001, "reproducibility comes from the committed standard-JSON input of one release
  compilation unit":** no standard-JSON input is committed on `main`, and `Verify.s.sol` does not
  rebuild bytecode ([Known limitations](known-limitations.md#release-evidence), LIM-REL-1).
- **ADR 0001's start budget of 300K gas:** amended to 350K by ADR 0003 and restated as Prague
  gas with the 6 and 7 new-slot maxima by ADR 0004. The code and tests follow ADR 0004.

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
  [Roles](roles.md), [Scope](scope.md), the
  [testing docs](https://github.com/6529-Collections/6529-works/blob/main/docs/testing/README.md)
