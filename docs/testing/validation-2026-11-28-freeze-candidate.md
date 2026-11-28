# Validation record, 28 November 2026, the freeze candidate

One pass of every test layer of the [testing guide](README.md) over one commit of `main`,
run on 28 November 2026 after the rename to 6529 Stream (#142) and the pre-freeze cleanups
(#143). It follows the [record made earlier the same day](validation-2026-11-28.md) on commit
`355a7a71` and records what ran, the counts and the result. It is evidence for reviewers, not
an audit: the project is pre-audit ([SECURITY.md](../../SECURITY.md)), and nothing here claims
that the contracts are correct or ready for production.

One row failed, on a fault in a test, not in a contract: [The fork tests](#the-fork-tests)
says what failed, what was changed and what was run again. Every other row passed on its
first run.

## How it was run

- **Code.** Commit `c6d49658` of `main`
  (`c6d4965861907841519cf3878c9db7052424a9a0`). The fork row ran again on commit `801917fc`
  of the branch that adds this record, which differs from `c6d49658` in one test file,
  `test/fork/ReadbackLogsFork.t.sol` (one key, with a comment). No file under `src/` differs,
  so the other rows stand as measured on `c6d49658`.
- **Machines.** Two rented 96-core Linux machines (Ubuntu 24.04), several items at a time, so
  the times are wall-clock times under load and are not comparable with a CI runner's. Each
  item ran in its own checkout, and a `forge test` row's time leaves out that checkout's
  build.
- **Tools.** Foundry 1.7.1, solc 0.8.37, Python 3.12, and the pinned
  [`requirements-tools.lock`](../../requirements-tools.lock): Halmos 0.3.3 with yices,
  slither-analyzer 0.11.6; Medusa 1.5.1.
- **Commands.** The ones the workflows in [`.github/workflows/`](../../.github/workflows) run,
  with the same filters and profiles.

## Results

"Tests" counts test functions; a fuzz or invariant test counts once.

| Item | Command | Count | Time | Result |
| --- | --- | --- | ---: | --- |
| Build, whole tree | `forge build` | `src`, `test`, `script`, `examples`, the keeper fixture | 231 s | pass |
| Format | `forge fmt --check`, and of `examples` and `keeper/test` | | 1 s | pass |
| Unit, fuzz, replay, integration, examples | `forge test --no-match-test ^invariant` | 289 suites: 3,403 passed, 9 skipped | 20 s | pass |
| Invariants, default profile (256 runs of 128 calls) | the six parts of `ci.yml` | 69 tests | 44 to 433 s a part | pass |
| Invariants, deep profile (2,000 runs of 256 calls) | the five parts of `nightly.yml` | 69 tests | 689 to 4,479 s a part | pass |
| Fuzz, deep profile (10,000 runs) | `forge test --no-match-test ^invariant --no-match-path "test/fork/*"`, twice: Forge's own seed, then `--fuzz-seed 0x6529` | 281 suites: 3,403 passed, 1 skipped, each time | 105 s and 101 s | pass |
| Settlement scan, deep profile | `testFuzz_Settlement_EqualsTheLibraryClearing` | 1 test, 10,000 runs | 4 s | pass |
| Symbolic proofs | `FOUNDRY_PROFILE=symbolic halmos` | 77 of 77 proofs in 15 contracts | 719 s | pass |
| Second fuzzer | `medusa fuzz --timeout 1800`, each of the four harnesses | 28 properties in 4 harnesses; 1.0 to 6.8 million calls a harness | 30 min each | pass |
| Medusa's Forge runners | `forge test --match-path "test/medusa/*"` | 8 tests | 40 s | pass |
| Fork tests, on `c6d49658` | `forge test --match-path "test/fork/*"`, mainnet and Sepolia | 8 suites: 49 passed, 1 failed | 4 s | **fail** ([below](#the-fork-tests)) |
| Fork tests, on `801917fc` | the same | 8 suites: 50 passed | 12 s | pass |
| Coverage | `forge coverage` under `lite`, then `check_coverage.py` | 63 `src/` files at or above their floors; 84.9% of lines, 76.6% of branches | 173 s | pass |
| Gas table and gas ceilings | `test_Gas_Table`; the six gas files of `test/integration`; every test named `Gas` | 1 test; 76 tests; 223 tests | 16 s | pass |
| Static analysis | `check_slither.py` | 84 High or Medium findings, each with a disposition | 40 s | pass |
| Budgets | `check_budgets.py --profile default` | sizes, margins, nSLOC, libraries ([Contract sizes](#contract-sizes)) | 1 s | pass |
| ABI and storage snapshots | `check_snapshots.py` | 66 contracts and libraries | 1 s | pass |
| Exported ABIs | `export_abis.py --check` | 88 files | 1 s | pass |
| Vectors and event topics | `make_vectors.py --check` | | 1 s | pass |
| Genesis configuration | `check_genesis.py` | 21 contracts, 10 wiring calls | 6 s | pass |
| Documentation checks | links, docs facts (also against the build), facts export, role matrix, NatSpec, comment codes, invariant shards | 3,581 links in 89 files; 102 sizes, 64 nSLOC figures, 1,576 test names, 196 topic values; NatSpec in 121 files | 4 s | pass |
| Mutation scores and floors | `gen_mutation_scores.py --check` | the page and the floors file agree with `tools/mutation-scores.json` | 1 s | pass |
| Rule traceability | `check_rules.py --uncovered` | 487 rules, 85 invariants, none uncovered | 1 s | pass |
| Tool self-tests | `unittest` over `tools`, `tools/content`, `tools/conventions`, `script/sepolia` | 941, 277, 163 and 29 tests; 6 skipped | 214 s | pass |
| Examples | `forge test --match-path "examples/*"` | 9 suites: 18 passed | 2 s | pass |
| Reference keeper | `KEEPER_E2E_REQUIRE=1 python -m unittest keeper.test_keeper` | 43 tests, unit and end-to-end on anvil | 12 s | pass |
| Local walkthrough | `bash script/local/walkthrough.sh` | every step | 22 s | pass |

Notes on the counts:

- **Skipped tests.** Without an RPC URL the eight fork suites skip in `setUp`; the fork rows
  ran them. The test that writes the keeper's fixture (`keeper/test`) runs only when asked.
  Four of the skipped tool tests need PowerShell and the other two a program that was not
  installed on the machines (`ipfs`) or one particular build of zlib.
- **Invariants.** The default profile's parts ran 6, 4, 23, 3, 2 and 31 tests; the deep
  profile's 6, 4, 23, 3 and 33. `check_invariant_shards.py` confirms that every invariant test
  is selected by exactly one part of each.
- **Coverage.** The percentages are Forge's totals over every compiled file, tests and
  scripts included, as in the earlier records; over `src/` alone `check_coverage.py` reports
  99.89% of lines (6,368 of 6,375) and 99.31% of branches (1,296 of 1,305). `forge coverage`
  runs unoptimized code, so the tests that hold a gas ceiling, a memory budget or a contract
  size fail there, as the [guide](README.md#coverage) says: 63 did, all of that kind (3,409
  passed). They pass in the rows above, which run the optimized build.
- **Fork tests** ran against public endpoints at the chains' heads on the day, not at a pinned
  block. They read the chains; nothing was sent to either.
- **Medusa** started each harness from an empty corpus; the nightly workflow keeps one between
  runs.

## Against the earlier record

The [earlier record](validation-2026-11-28.md) counted 3,382 tests on `5da3ec36`; this pass
counts 3,403, 21 more, in the whole suite and in the deep fuzz row alike. Coverage ran the
same 21 more. They are:

| Change | Tests | What |
| --- | ---: | --- |
| Sepolia open-gate test instance (#139) | 17 | `test/sepolia/SepoliaOpenGate.t.sol`, one new suite: 288 suites became 289, and the deep fuzz row's 280 became 281 |
| Rename to 6529 Stream (#142) | 1 | `test_IndependentConsent_Golden` pins the renamed Independent Stream consent domain and one consent digest. Five tests took the new name in their own names; none was added or removed by that |
| Pre-freeze cleanups (#143) | 3 | `test_preview_beforeAnyAcceptance` and `test_preview_resolvesAKnownPartysArtistId` for `PackageRegistry.preview`, and one test of the preview in [`StartASale.t.sol`](../../examples/StartASale.t.sol), which took the examples' row from 17 tests to 18 |

The five constants #143 removed from `Typehashes` were asserted inside one test that stays,
and no test named the removed enum, so removing them changed no count. The other counts that
moved:

- **Invariants, proofs and properties** are the same: 69, 77 and 28.
- **Coverage of `src/`.** Seven more lines and one more branch, all reached: 6,375 lines and
  1,305 branches, with seven lines and nine branches unreached, as many as before.
- **Exported ABIs.** 88 files, one more than before.
- **Rules.** 487, one more; none uncovered.
- **Tool self-tests.** 941 in `tools`, two more.
- **Documentation checks.** 3,581 links in 89 files (3,374 in 86), 1,576 cited test names
  (1,564).
- **Contract sizes.** Two of the five with the least room changed
  ([below](#contract-sizes)).

## Contract sizes

`check_budgets.py` holds every contract declared in `src/` to at least 512 bytes under the
EIP-170 limit of 24,576 bytes of runtime code, and the four permanent contracts of `src/core`
to at least 3,000. All 34 contracts with code keep their margin and none is exempt. The five
with the least room:

| Contract | Runtime size | Margin |
| --- | ---: | ---: |
| `Renderer` | 24,059 | 517 |
| `IndependentStreamRegistry` | 24,053 | 523 |
| `IndependentEditionAuctionLens` | 24,014 | 562 |
| `IndependentEditionAuction` | 23,957 | 619 |
| `UniformEditionAuction` | 23,535 | 1,041 |

`Renderer` is five bytes from its floor and `IndependentStreamRegistry` eleven. In the earlier
record the registry was exactly at its floor (24,064 bytes) and the renderer two bytes smaller
(24,057). The tightest of the four core contracts is `Stream6529`, 14,870 bytes, 9,706 under
the limit, as before.

## The fork tests

On `c6d49658` one of the 50 fork tests failed,
`test_ReadbackLogs_AreTheSameWhateverTheBlockRange` of `test/fork/ReadbackLogsFork.t.sol`,
before it made any call to a contract:

```text
vm.parseJsonAddress: path ".contracts.StreamAccessManager.address" must return exactly one JSON value
```

The test reads the address of the access manager from a committed deployment record,
`deployments/11155111/core-1795440624.json`. That record was written before the rename and
lists the contract under its earlier name, `WorksAccessManager`. The rename (#142) changed the
name in the test and, rightly, left the record as it was written, so the test asked the record
for a key it does not have. The fault is in the test. No contract ran, and the earlier record's
fork row passed this test on the same deployment.

The test runs only when `FORK_SEPOLIA_LOGS_RPC` is set. No workflow sets it: the pull-request
checks set no RPC URL and the nightly fork job sets the other two, so both skipped the test
and neither showed the failure.

The test now reads the key the record has, with a comment that says why (commit `801917fc`).
On that commit the fork row passed, 50 of 50, and the whole suite gave the same 3,403 passed
and 9 skipped. The other rows were not run again: the change is to one test file that only the
fork row runs.

## Not run

- **No audit and no other prover.** As in [What is not tested](README.md#what-is-not-tested).
- **Mutation testing.** No mutant ran in this pass, as in the earlier one; it confirmed only
  that the scores page and the floors agree with their data file. `PackageRegistry.sol`,
  whose `preview` #143 changed, and the other files #143 touched have not been measured
  again since: their scores on the [Mutation scores](mutation-scores.md) page are of the code
  before it. The weekly workflow runs every file.
- **The other rows on the corrected commit.** Only the format check, the build, the fork row
  and the whole suite ran on `801917fc`.
- **The hosted workflows.** This pass ran the workflows' commands on rented machines, not the
  workflows themselves; their own runs are on the repository's Actions page.
- **A live deployment.** No contract was deployed or read back from a chain
  (`script/VerifyCore.s.sol`); the Sepolia instances are recorded in
  [`deployments/11155111`](../../deployments/11155111/README.md).
- **Other platforms.** Linux only; the walkthrough and the tools were not run on Windows or
  macOS in this pass.
