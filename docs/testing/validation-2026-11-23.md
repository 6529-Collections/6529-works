# Validation record, 23 November 2026

One pass of every test layer of the [testing guide](README.md) over one commit of `main`,
run on 23 November 2026 before that commit was tagged as a release candidate. It records what
ran, the counts and the result. It is evidence for reviewers, not an audit: the project is
pre-audit ([SECURITY.md](../../SECURITY.md)), and nothing here claims that the contracts are
correct or ready for production.

## How it was run

- **Code.** Commit `961bc956` of `main`. The Halmos row ran on that commit with one test file
  changed, `test/symbolic/EditionsCoreSymbolic.t.sol` (see
  [the royalty proof](#the-royalty-proof)); no file under `src/` differs.
- **Machine.** One rented 96-core Linux machine (Ubuntu 24.04), several items at a time, so
  the times are wall-clock times under load and are not comparable with a CI runner's.
- **Tools.** Foundry 1.7.1, solc 0.8.37, Python 3.12, and the pinned
  [`requirements-tools.lock`](../../requirements-tools.lock): Halmos 0.3.3 with yices,
  slither-analyzer 0.11.6; Medusa 1.5.1.
- **Commands.** The ones the workflows in [`.github/workflows/`](../../.github/workflows) run,
  with the same filters and profiles.

## Results

Every finished item passed. "Tests" counts test functions; a fuzz or invariant test counts once.

| Item | Command | Count | Time | Result |
| --- | --- | --- | ---: | --- |
| Build, whole tree | `forge build` | `src`, `test`, `script`, `examples`, the keeper fixture | 201 s | pass |
| Format | `forge fmt --check`, and of `examples` and `keeper/test` | | 1 s | pass |
| Unit, fuzz, replay, integration, examples | `forge test --no-match-test ^invariant` | 268 suites: 3,200 passed, 8 skipped | 27 s | pass |
| Invariants, default profile (256 runs of 128 calls) | the six parts of `ci.yml` | 68 tests | 90 to 481 s a part | pass |
| Invariants, deep profile (2,000 runs of 256 calls) | the five parts of `nightly.yml` | 68 tests | | still running when this page was first committed |
| Fuzz, deep profile (10,000 runs) | `forge test --no-match-test ^invariant --no-match-path "test/fork/*"` | 261 suites: 3,200 passed, 1 skipped | 129 s | pass |
| Settlement scan, deep profile | `testFuzz_Settlement_EqualsTheLibraryClearing` | 1 test, 10,000 runs | 4 s | pass |
| Symbolic proofs | `FOUNDRY_PROFILE=symbolic halmos` | 77 of 77 proofs in 15 contracts | 908 s | pass |
| Second fuzzer | `medusa fuzz --timeout 1800`, each of the four harnesses | 28 properties in 4 harnesses; 0.7 to 4.9 million calls a harness | 30 min each | pass |
| Medusa's Forge runners | `forge test --match-path "test/medusa/*"` | 8 tests | 39 s | pass |
| Fork tests | `forge test --match-path "test/fork/*"`, mainnet and Sepolia | 7 suites: 47 passed | 57 s | pass |
| Coverage | `forge coverage` under `lite`, then `check_coverage.py` | 63 `src/` files at or above their floors; 84.3% of lines, 76.2% of branches | 207 s | pass |
| Gas table | `test_Gas_Table`, and the five gas suites of `test/integration` | 1 test; 67 tests | 9 s | pass |
| Static analysis | `check_slither.py` | 83 High or Medium findings, each with a disposition | 73 s | pass |
| Budgets | `check_budgets.py --profile default` | sizes, margins, nSLOC, libraries | 1 s | pass |
| ABI and storage snapshots | `check_snapshots.py` | 66 contracts and libraries | 1 s | pass |
| Exported ABIs | `export_abis.py --check` | 86 files | 2 s | pass |
| Vectors and event topics | `make_vectors.py --check` | | 1 s | pass |
| Genesis configuration | `check_genesis.py` | 21 contracts, 10 wiring calls | 16 s | pass |
| Documentation checks | links, docs facts (also against the build), facts export, role matrix, NatSpec, comment codes | 2,924 links in 82 files; 102 sizes, 64 nSLOC figures, 1,563 test names, 195 topic values; NatSpec in 120 files | 7 s | pass |
| Rule traceability | `check_rules.py --uncovered` | 473 rules, 55 invariants, none uncovered | 1 s | pass |
| Tool self-tests | `unittest` over `tools`, `tools/content`, `tools/conventions`, `script/sepolia` | 865, 277, 163 and 17 tests; 2 skipped | 205 s | pass |
| Examples | `forge test --match-path "examples/*"` | 9 suites: 17 passed | 2 s | pass |
| Reference keeper | `KEEPER_E2E_REQUIRE=1 python -m unittest keeper.test_keeper` | 43 tests, unit and end-to-end on anvil | 7 s | pass |
| Local walkthrough | `bash script/local/walkthrough.sh` | every step | 18 s | pass |

Notes on the counts:

- **Skipped tests.** Without an RPC URL the seven fork suites skip in `setUp`; the fork row
  ran them. The test that writes the keeper's fixture (`keeper/test`) runs only when asked. The two
  skipped tool tests need a program that was not installed on the machine (`ipfs`) or one
  particular build of zlib.
- **Coverage.** `forge coverage` runs unoptimized code, so the tests that hold a gas ceiling, a
  memory budget or a contract size fail there, as the [guide](README.md#coverage) says: 55
  did, all of that kind (3,213 passed). They pass in the rows above, which run the optimized
  build.
- **Fork tests** ran against public endpoints at the chains' heads on the day, not at a pinned
  block.
- **Medusa** started each harness from an empty corpus; the nightly workflow keeps one between
  runs.

## The royalty proof

`check_RoyaltyInfoFromStorage` of `EditionsCoreSymbolicTest` timed out on three of the last
five runs of the strength workflow on `main`. The solver needs about 90 seconds of its
120-second limit for one fact, that a 256-bit division by the denominator gives back the rate
(92 seconds in each of five runs on the machine above; 88 seconds on a CI run that passed), so
a slower runner passed the limit. The proof now takes that division as given and proves the
rest for every rate, and `test_DividesBackToTheRate_EveryRate` in the same contract checks the
division for each of the 100,001 rates an edition can store. Together they cover what the
proof covered before. Eight runs of the whole contract on four cores, while the machine was
busy with the rows above, took 0.19 to 0.42 seconds for this proof and at most 3.3 seconds for
all six. A proof with a wrong expected amount, and one with a false claim about a single rate,
both fail with a counterexample, so the given fact does not make the proof vacuous.

## One fault found in the tooling

The nightly job "Deep differential fuzz (edition auction settlement)" selected no test: Forge
matches `--match-test` against a test's signature, so the filter's closing `$` matched nothing,
and Forge passes when no test is selected. The same test ran 10,000 times in the nightly deep
fuzz job all along, so no run was lost. The filter is corrected and the step now requires that
the one test ran.

## Not run

- **No audit and no other prover.** As in [What is not tested](README.md#what-is-not-tested).
- **Mutation testing of every file.** Only the files named in
  [Mutation scores](mutation-scores.md) as measured again on this commit were run; the weekly
  workflow runs the rest.
- **The hosted workflows.** This pass ran the workflows' commands on a rented machine, not the
  workflows themselves; their own runs on `961bc956` are on the repository's Actions page.
- **A live deployment.** No contract was deployed or read back from a chain
  (`script/VerifyCore.s.sol`); the Sepolia instances are recorded in
  [`deployments/11155111`](../../deployments/11155111/README.md).
- **Other platforms.** Linux only; the walkthrough and the tools were not run on Windows or
  macOS in this pass.
