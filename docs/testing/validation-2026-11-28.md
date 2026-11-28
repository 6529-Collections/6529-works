# Validation record, 28 November 2026

One pass of every test layer of the [testing guide](README.md) over one commit of `main`,
run on 28 November 2026 after the changes to how sales end, how editions are read and how a
module names the one it replaces (#135, #136, #137). It follows the
[record of 23 November](validation-2026-11-23.md) and records what ran, the counts and the
result. It is evidence for reviewers, not an audit: the project is pre-audit
([SECURITY.md](../../SECURITY.md)), and nothing here claims that the contracts are correct or
ready for production.

One row failed on its first run, on a fault in a test's inputs, not in a contract:
[The deep fuzz run](#the-deep-fuzz-run) says what failed, what was changed and what was run
again.

## How it was run

- **Code.** Commit `355a7a71` of `main`. The deep fuzz row ran again on the files of commit
  `5da3ec36` of `main`, which differs from `355a7a71` in one test file,
  `test/core/Stream.t.sol` (three lines). Every file under `src/` is byte for byte the same in
  both commits (one Git tree, `e4e8fb92`), so the other rows stand as measured on `355a7a71`.
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
| Build, whole tree | `forge build` | `src`, `test`, `script`, `examples`, the keeper fixture | 236 s | pass |
| Format | `forge fmt --check`, and of `examples` and `keeper/test` | | 1 s | pass |
| Unit, fuzz, replay, integration, examples | `forge test --no-match-test ^invariant` | 288 suites: 3,382 passed, 9 skipped | 18 s | pass |
| Invariants, default profile (256 runs of 128 calls) | the six parts of `ci.yml` | 69 tests | 45 to 316 s a part | pass |
| Invariants, deep profile (2,000 runs of 256 calls) | the five parts of `nightly.yml` | 69 tests | 858 to 4,125 s a part | pass |
| Fuzz, deep profile (10,000 runs), on `355a7a71` | `forge test --no-match-test ^invariant --no-match-path "test/fork/*"` | 280 suites: 3,381 passed, 1 failed, 1 skipped | 212 s | **fail** ([below](#the-deep-fuzz-run)) |
| Fuzz, deep profile (10,000 runs), on `5da3ec36` | the same, twice: Forge's own seed, then `--fuzz-seed 0x6529` | 280 suites: 3,382 passed, 1 skipped, each time | 156 s each | pass |
| Settlement scan, deep profile | `testFuzz_Settlement_EqualsTheLibraryClearing` | 1 test, 10,000 runs | 8 s | pass |
| Symbolic proofs | `FOUNDRY_PROFILE=symbolic halmos` | 77 of 77 proofs in 15 contracts | 619 s | pass |
| Second fuzzer | `medusa fuzz --timeout 1800`, each of the four harnesses | 28 properties in 4 harnesses; 1.1 to 7.2 million calls a harness | 30 min each | pass |
| Medusa's Forge runners | `forge test --match-path "test/medusa/*"` | 8 tests | 23 s | pass |
| Fork tests | `forge test --match-path "test/fork/*"`, mainnet and Sepolia | 8 suites: 50 passed | 12 s | pass |
| Coverage | `forge coverage` under `lite`, then `check_coverage.py` | 63 `src/` files at or above their floors; 85.1% of lines, 76.8% of branches | 177 s | pass |
| Gas table and gas ceilings | `test_Gas_Table`; the six gas files of `test/integration`; every test named `Gas` | 1 test; 76 tests; 223 tests | 7 s | pass |
| Static analysis | `check_slither.py` | 84 High or Medium findings, each with a disposition | 40 s | pass |
| Budgets | `check_budgets.py --profile default` | sizes, margins, nSLOC, libraries ([Contract sizes](#contract-sizes)) | 1 s | pass |
| ABI and storage snapshots | `check_snapshots.py` | 66 contracts and libraries | 1 s | pass |
| Exported ABIs | `export_abis.py --check` | 87 files | 1 s | pass |
| Vectors and event topics | `make_vectors.py --check` | | 1 s | pass |
| Genesis configuration | `check_genesis.py` | 21 contracts, 10 wiring calls | 6 s | pass |
| Documentation checks | links, docs facts (also against the build), facts export, role matrix, NatSpec, comment codes, invariant shards | 3,374 links in 86 files; 102 sizes, 64 nSLOC figures, 1,564 test names, 196 topic values; NatSpec in 121 files | 4 s | pass |
| Mutation scores and floors | `gen_mutation_scores.py --check` | the page and the floors file agree with `tools/mutation-scores.json` | 1 s | pass |
| Rule traceability | `check_rules.py --uncovered` | 486 rules, 85 invariants, none uncovered | 1 s | pass |
| Tool self-tests | `unittest` over `tools`, `tools/content`, `tools/conventions`, `script/sepolia` | 939, 277, 163 and 29 tests; 6 skipped | 180 s | pass |
| Examples | `forge test --match-path "examples/*"` | 9 suites: 17 passed | 1 s | pass |
| Reference keeper | `KEEPER_E2E_REQUIRE=1 python -m unittest keeper.test_keeper` | 43 tests, unit and end-to-end on anvil | 6 s | pass |
| Local walkthrough | `bash script/local/walkthrough.sh` | every step | 14 s | pass |

Notes on the counts:

- **Skipped tests.** Without an RPC URL the eight fork suites skip in `setUp`; the fork row
  ran them. The test that writes the keeper's fixture (`keeper/test`) runs only when asked.
  Four of the skipped tool tests need PowerShell and the other two a program that was not
  installed on the machines (`ipfs`) or one particular build of zlib.
- **Invariants.** The default profile's parts ran 6, 4, 23, 3, 2 and 31 tests; the deep
  profile's 6, 4, 23, 3 and 33. `check_invariant_shards.py` confirms that every invariant test
  is selected by exactly one part of each.
- **Coverage.** The percentages are Forge's totals over every compiled file, tests and
  scripts included, as in the earlier record; over `src/` alone `check_coverage.py` reports
  99.89% of lines (6,361 of 6,368) and 99.31% of branches (1,295 of 1,304). `forge coverage`
  runs unoptimized code, so the tests that hold a gas ceiling, a memory budget or a contract
  size fail there, as the [guide](README.md#coverage) says: 63 did, all of that kind (3,388
  passed). They pass in the rows above, which run the optimized build.
- **Fork tests** ran against public endpoints at the chains' heads on the day, not at a pinned
  block.
- **Medusa** started each harness from an empty corpus; the nightly workflow keeps one between
  runs.

## Contract sizes

`check_budgets.py` holds every contract declared in `src/` to at least 512 bytes under the
EIP-170 limit of 24,576 bytes of runtime code, and the four permanent contracts of `src/core`
to at least 3,000. All 34 contracts with code keep their margin and none is exempt. The five
with the least room:

| Contract | Runtime size | Margin |
| --- | ---: | ---: |
| `IndependentStreamRegistry` | 24,064 | 512 |
| `Renderer` | 24,057 | 519 |
| `IndependentEditionAuctionLens` | 24,014 | 562 |
| `IndependentEditionAuction` | 23,957 | 619 |
| `UniformEditionAuction` | 23,535 | 1,041 |

`IndependentStreamRegistry` is exactly at its floor: one more byte fails the gate. The
tightest of the four core contracts is `Stream6529`, 14,870 bytes, 9,706 under the limit.

## The deep fuzz run

On `355a7a71` the deep fuzz row failed on one test,
`testFuzz_Mint_StoresValidFactsExactly` of `test/core/Stream.t.sol`, at run 761 of 10,000,
with `InvalidMint()`. The test bounded the royalty rate but left the royalty receiver free,
and the fuzzer stated a zero receiver with a rate of 1,289. `mint` refuses that pair by design
(a rate with no receiver would send royalties nowhere), and
`test_Mint_RefusesMalformedFacts` pins the refusal. So the contract did what it is meant to
do and the test called an invalid input valid. At the default profile's 256 runs the fuzzer
rarely draws the pair, which is why the row above it passed.

The nightly workflow's deep fuzz job failed on the same test on 27 and 28 November, and on
24 November on `testFuzz_LockRoyaltyRate_TheRateNeverChangesTheReceiverStillCan`, which had
the same fault and was corrected in #132.

The test now sets the rate to zero when the receiver is zero (#138), so both valid cases stay
in: a zero receiver with a zero rate, and a non-zero receiver with any rate up to the
denominator. The other fuzz tests that pass a receiver, a rate or mint facts to `mint`,
`createEdition` or `setRoyalty` were read; each uses a fixed non-zero receiver or already
leaves the pair out. On the corrected files the row passed twice, under Forge's own seed and
under a fixed one, and the test alone passed 100,000 runs under each of eight seeds. Those
runs were made on the pull request's commit before it was merged; its files are the same as
those of `5da3ec36` (one Git tree).

## Not run

- **No audit and no other prover.** As in [What is not tested](README.md#what-is-not-tested).
- **Mutation testing.** No mutant ran in this pass. The files #135 and #136 changed were
  measured on those changes' branches (Mutation scores:
  [#135's files](mutation-scores.md#measured-again-on-6b15570c-and-1a13218b),
  [#136's files](mutation-scores.md#measured-again-on-0fa77564)); this pass
  confirmed only that the scores page and the floors agree with their data file. The weekly
  workflow runs every file.
- **The other rows on the corrected commit.** Only the deep fuzz row ran on the files of
  `5da3ec36`; the hosted CI ran its own checks on that commit.
- **The hosted workflows.** This pass ran the workflows' commands on rented machines, not the
  workflows themselves; their own runs are on the repository's Actions page.
- **A live deployment.** No contract was deployed or read back from a chain
  (`script/VerifyCore.s.sol`); the Sepolia instances are recorded in
  [`deployments/11155111`](../../deployments/11155111/README.md).
- **Other platforms.** Linux only; the walkthrough and the tools were not run on Windows or
  macOS in this pass.
