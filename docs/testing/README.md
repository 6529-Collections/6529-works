# Testing

How to run each part of the 6529 Works test suite, and what CI runs. The project is pre-audit:
the suite is evidence for reviewers, not a substitute for an audit.
[The test map](../../test/README.md) says where the tests for a contract live and how tests and
mocks are named.

Start with `forge build`, then `forge test --no-match-test "^invariant"`. It runs every unit,
fuzz, integration, replay and example test and names each one that fails. The
[validation record](validation-2026-11-28.md) has the counts of one pass of every layer over
one commit; [What is not tested](#what-is-not-tested) says where the suite stops.

> Some invariants that campaigns checked on the contracts before
> [ADR 0010](../adr/0010-plain-permanent-core.md) have no stateful campaign on the current
> ones; [Invariants](../audit/invariants.md#gaps) lists them. The coverage floors of the new
> files are placeholders. The mutation floors were measured on the current contracts on
> 23 November 2026 ([Mutation scores](mutation-scores.md)).

## Run it

```bash
forge build
forge test --no-match-test "^invariant"               # unit, fuzz, replay, examples
forge test --match-test "^invariant"                  # the invariant campaigns, 256 x 128
python tools/check_snapshots.py                       # ABI and storage layout, after forge build
python tools/check_rules.py --uncovered               # every rule names a test that exists
python tools/make_vectors.py --check                  # real-data vectors and event topics
```

The deeper campaigns the nightly workflow runs (10,000 fuzz runs; 2,000 invariant runs of 256
calls):

```bash
FOUNDRY_PROFILE=deep forge test --no-match-test "^invariant" --no-match-path "test/fork/*"
FOUNDRY_PROFILE=deep forge test --match-test "^invariant"
```

The integrator examples (`examples/`) and the keeper's anvil fixture are compiled through
`test/Integrators.t.sol`, so `forge test` runs them; `forge test --match-path "examples/*"` runs
the examples alone. The other entry points:

| What | Command |
| --- | --- |
| The local walkthrough: deploy on anvil, accept, read back, one full sale, one Independent Stream work, one module swap | `bash script/local/walkthrough.sh` ([script/local](../../script/local/README.md)) |
| The reference keeper, with its end-to-end tests on anvil | `KEEPER_E2E_REQUIRE=1 python -m unittest keeper.test_keeper` ([keeper](../../keeper/README.md)) |
| The tool self-tests | `python -m unittest discover -s tools -p "test_*.py"` |

## Layers

| Layer | Files | What it proves | Run it |
| --- | --- | --- | --- |
| Unit | `test/<module>/*.t.sol` | Every function's happy path, every revert by its exact error and arguments, events and access control | `forge test --match-path "test/<module>/*"` |
| Property fuzz | `testFuzz_*` beside the unit tests | The same properties over random inputs, 256 runs (10,000 under `deep`) | `forge test --match-test testFuzz` |
| Stateful invariants | `*Invariant*.t.sol`, `*.invariant.t.sol`, `test/*/invariant/` | The INV rows of [Invariants](../audit/invariants.md) over random call sequences, 256 runs of 128 calls, `fail_on_revert` | `forge test --match-test "^invariant"` |
| Hostile modules | `test/core/*Hostile*.t.sol` | A module that lies, reverts, burns all its gas or re-enters moves no token, changes no fact and moves no balance | `forge test --match-contract Hostile` |
| Deploy | [`test/deploy/`](../../test/deploy) | `script/DeployCore.sol`: predicted addresses, genesis modules and minters, the four settings at their launch values, the whole stack installed and read back | `forge test --match-path "test/deploy/*"` |
| Integration | [`test/integration/`](../../test/integration/README.md) | The whole stack deployed by `script/DeployCore.sol` with the committed genesis | `forge test --match-path "test/integration/*"` |
| Symbolic | [`test/symbolic/`](../../test/symbolic) | Halmos proofs (`check_*`) of the pure libraries and of state rules of the permanent contracts | [below](#symbolic-proofs-halmos) |
| Second fuzzer | [`test/medusa/`](../../test/medusa), `medusa.json` | Cheatcode-free harnesses with their own model of the rules | [below](#second-fuzzer-medusa) |
| Log replay | [`test/replay/`](../../test/replay) | `Stream6529`, `StreamEditions6529`, `StreamWorkFacts6529` and the Independent Stream tokens rebuilt from their logs alone | `forge test --match-path "test/replay/*"` |
| Fork | [`test/fork/`](../../test/fork/README.md) | The network as a real Safe on a fork, with an RPC URL | [fork tests](../../test/fork/README.md) |
| ABI and storage snapshots | [`test/snapshots/`](../../test/snapshots), [`tools/check_snapshots.py`](../../tools/check_snapshots.py) | Every `src/` contract's ABI and storage layout against the committed snapshot | `python tools/check_snapshots.py` |
| Rule traceability | [`tools/check_rules.py`](../../tools/check_rules.py), [`tools/rules-uncovered.txt`](../../tools/rules-uncovered.txt) | Every spec rule names a test that exists, every invariant its function | `python tools/check_rules.py --uncovered` |
| Coverage | `forge coverage`, [`tools/check_coverage.py`](../../tools/check_coverage.py) | What no test reaches, against a floor per contract | [below](#coverage) |
| Mutation | [`tools/mutation.py`](../../tools/mutation.py) | Which changes to the code no test notices, against a floor per file | [below](#mutation-testing) |
| Live | [`script/VerifyCore.s.sol`](../../script/VerifyCore.s.sol), [`deployments/11155111/`](../../deployments/11155111) | A deployment read back from the chain | the [runbook](../../script/README.md#4-after-the-broadcast) |

Conventions: forge-std assertions; `vm.expectRevert` with the exact selector and arguments;
mocks in [`test/mocks/<module>/`](../../test/mocks), one behaviour per name, with the adversarial
ones beside them. Tests read the four settings from the contracts; they never assume the launch
values.

## What CI runs

The workflows are in [`.github/workflows/`](../../.github/workflows).

| Workflow | When | What |
| --- | --- | --- |
| CI (`ci.yml`) | every pull request and push to `main` | Format, build, the checks against the build (docs facts, snapshots, exported ABIs, vectors, budgets, genesis, NatSpec, comment codes), the tests in parallel parts, the local walkthrough, Slither, and the documentation checks, among them `tools/check_invariant_shards.py`: every invariant test is selected by exactly one part |
| Strength (`strength.yml`) | every push to `main`, daily, on demand | Coverage against the floors; one Halmos job per symbolic test contract |
| Nightly (`nightly.yml`) | daily, on demand | The `deep` profile: invariant campaigns and fuzz tests; the Medusa harnesses |
| Mutation (`mutation.yml`) | weekly, on demand | Every shard of `tools/mutation.py`, compared with the floors |

Branch protection requires two checks of `ci.yml`: `Contracts` and `Static analysis`.
`Contracts` is green only when every other job of the workflow is: the documentation checks,
the build and its checks, every test part, the walkthrough and static analysis.

The other three workflows run on `main` only, so no pull request shows a failed run. Each ends
with a job that reports one: it opens an issue titled `<workflow name> workflow failed on
main` with a link to the run, or comments on that issue while it is open. Close the issue once
the cause is fixed.

## ABI and storage snapshots

```bash
forge build
python tools/check_snapshots.py            # compare
python tools/check_snapshots.py --update   # rewrite test/snapshots/ after an intended change
```

[`test/snapshots/`](../../test/snapshots) holds every `src/` contract's ABI (selectors, event
topics, errors) and storage layout. A difference fails CI, so a change to an interface or to a
permanent contract's storage is always visible in review.

## Second fuzzer (Medusa)

```bash
FOUNDRY_OUT=out-medusa FOUNDRY_CACHE_PATH=cache-medusa medusa fuzz --config medusa.json \
  --compilation-target test/medusa/LedgerMedusa.sol --target-contracts LedgerMedusa --timeout 600
forge test --match-path "test/medusa/*"                     # the Forge runners and self-tests
```

The harnesses share no code with any `*Handler.sol`: no forge-std, no cheatcodes, every action
through actor contracts, and no action ever reverts. Each predicts every call's outcome
(`property_ModelPredictsEveryOutcome`).

| Harness | Real contracts | Properties |
| --- | --- | --- |
| `LedgerMedusa` | `SplitLedger`, its wallets, `RevenueEscrow`, `GovernedVault` | `property_WalletsConserveValue`, `property_ReleasedWithinEntitlement`, `property_NoUnauthorizedRelease`, `property_NetworkShareIsPaidOrDue`, `property_EscrowIsSolvent`, `property_DustIsBounded` |
| `StreamCoreMedusa` | `Stream6529` | `property_SupplyIsMintedMinusBurned`, `property_OneLiveTokenPerContent`, `property_OutcomesAndOwnersMatchTheModel`, `property_FactsNeverChange`, `property_LockedRateHolds` |

## Symbolic proofs (Halmos)

```bash
python -m pip install --require-hashes --only-binary=:all: --no-deps -r requirements-tools.lock
FOUNDRY_PROFILE=symbolic halmos
```

[`halmos.toml`](../../halmos.toml) holds the options, and the `symbolic` profile compiles only
`test/symbolic` into `out-symbolic/`. The solver is the pinned `yices-smt2` from the lock. Each
`*SymbolicTest` contract states the bounds of its proofs in its NatSpec: a proof covers every
input up to those bounds and nothing beyond. The strength workflow runs one job per contract.
A proof takes a fact as given (`vm.assume`) only when a Forge test in the same contract checks
that fact for every input inside the proof's bounds: `check_RoyaltyInfoFromStorage` does so for
one 256-bit division the solver needs most of its time limit for, and
`test_DividesBackToTheRate_EveryRate` tries each of the 100,001 rates.

## Coverage

```bash
FOUNDRY_PROFILE=lite forge coverage --report lcov --report summary --allow-failure
python tools/check_coverage.py --uncovered
```

Coverage instruments unoptimized code, so it runs under the `lite` profile (the same sources and
compiler, fewer fuzz and invariant runs); gas-ceiling tests fail without the optimizer, so
`--allow-failure` keeps the run going. [`tools/coverage-floors.json`](../../tools/coverage-floors.json)
holds a floor per `src/` contract; a contract below either floor fails, and a file with no entry
must meet the default floor. After adding tests, `python tools/check_coverage.py --write-floors`
rewrites the floors from the run; lowering a floor needs a reason in the pull request.

## Mutation testing

```bash
python tools/mutation.py list                       # the shards
python tools/mutation.py run libraries-AgedCredits  # in a scratch checkout: it edits src/
python tools/mutation.py report mutation --markdown mutation/report.md
```

`slither-mutate` (pinned with Slither in [`requirements-tools.lock`](../../requirements-tools.lock))
generates the mutants; `tools/mutation.py` adds one rule of its own (every integer-literal
constant moved one up and one down), plans one shard per `src/` file, splits the files whose
shard does not finish in a CI job, and compares each file's score with its floor in
[`tools/mutation-floors.json`](../../tools/mutation-floors.json). slither-mutate mutates only the
contract named like its file, so the tool runs it once for every contract a file declares (a
base contract beside the concrete one would otherwise never be mutated). A group too slow for
one job runs in parts that together make exactly the group's mutants: the statements group is
cut by source line, because slither-mutate makes no comment mutant on a line whose revert
mutant survived, and both have to run in the same part. A run of slither-mutate that stops
before it has mutated its target fails its shard. A mutant whose tests run past the time
limit counts as killed; the report gives those apart from the other kills.
The scores measured on
the current contracts, with their survivors triaged, are in
[Mutation scores](mutation-scores.md); the figures measured on the contracts before ADR 0010 are
kept as a historical record in [mutation-baseline.md](mutation-baseline.md).

The tables of that page and the floors file are generated from
[`tools/mutation-scores.json`](../../tools/mutation-scores.json), which holds each file's
counts, its triaged survivors and the tests added for them:

```bash
python tools/mutation.py report mutation --json mutation/report.json   # after a campaign
python tools/gen_mutation_scores.py --merge mutation/report.json --commit <sha> --write-floors
python tools/gen_mutation_scores.py --check                            # what CI runs
```

`--merge` takes a file's new counts, keeps its earlier floor as "was" and drops its earlier
survivor rows, which describe mutants of older code; the new survivors are then triaged in the
data file and the page is written again.

## Validation records

A record of one pass of every layer over one commit, with the counts and what was not run:

- [28 November 2026](validation-2026-11-28.md), commit `355a7a71`; the deep fuzz row on
  `5da3ec36`.
- [23 November 2026](validation-2026-11-23.md), commit `961bc956`.

## What is not tested

- **No external audit.** The project is pre-audit ([SECURITY.md](../../SECURITY.md)).
- **Stateful campaigns.** [Invariants: Gaps](../audit/invariants.md#gaps) lists what no
  stateful campaign covers; unit, fuzz and integration tests cover those rules.
- **Mutation testing of every file.** The mutation floors are measured
  ([Mutation scores](mutation-scores.md)), except for any file that page lists as not finished.
- **Bounded proofs only.** The Halmos proofs cover every input within their stated bounds. Not
  proved: the share arithmetic across payees (256-bit division), multi-payee release
  interleavings, ECDSA and ERC-1271 themselves. No other prover has been run.
- **The second fuzzer's stand-ins.** The Medusa harnesses replace the AccessManager with a stub
  authority (no role matrix or delays) and stand in for the modules.
- **Replay coverage.** Balances and chunk bytes are not in logs by design; the accounts module
  and the delivery module are not replayed.
- **Rules without a test.** The rules that name no test are listed by
  `python tools/check_rules.py --uncovered`; the declaration rules are off-chain conventions.
- **Live rehearsal.** The new contracts run on Sepolia only (rounds r6 to r9,
  [records](../../deployments/11155111/README.md)); what each round did not run is at the end
  of its flows page. There is no mainnet deployment.
