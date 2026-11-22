# Testing

How the 6529 Works test suite is organised, how to run each part, what CI runs and when,
and how strong the tests are measured to be. The project is pre-audit: a strong suite is
evidence for reviewers, not a substitute for an audit. [The test map](../../test/README.md)
says where the tests for a contract, a function or a review finding live, and how tests and
mocks are named.

The suite has layers because each one catches a different kind of mistake. Unit tests pin
the behaviour someone thought of. Fuzz and invariant tests find the inputs and call
sequences nobody thought of. A second fuzzer with its own model of the rules catches a
mistake the first one's handlers share with the code. Integration and fork tests catch two
correct systems that disagree. Log replay catches state an indexer cannot rebuild. Oracles
catch a fast implementation that drifts from a simple one. Symbolic proofs close the input
space where it is small enough. Snapshots catch an interface or storage layout that moved,
and traceability a rule nobody tests. Coverage shows what no test reaches, and mutation
testing shows what the tests reach but do not check. [What is not tested](#what-is-not-tested)
says, plainly, where the layers stop.

## Run it

```bash
forge build
forge test                                            # every test, invariants at 256 x 128
forge test --no-match-test "^invariant"               # without the invariant campaigns
python tools/check_snapshots.py                       # ABI and storage layout, after forge build
python tools/check_rules.py --uncovered               # every rule names a test that exists
python tools/make_vectors.py --check                  # real-data vectors and event topics
```

The whole `forge test` ran 3,084 tests (3,040 passed, the 44 fork tests skipped without an RPC
URL) in 11 to 16 minutes of wall time (3 to 6 CPU hours) in two runs on a 48-thread Windows
machine shared with other jobs, on 17 November 2026. Longer campaigns, as the nightly workflow runs them (10,000 fuzz runs; 2,000
invariant runs of 256 calls):

```bash
FOUNDRY_PROFILE=deep forge test --no-match-test "^invariant" --no-match-path "test/fork/*"
FOUNDRY_PROFILE=deep forge test --match-test "^invariant"
```

The integration examples in `examples/` and the keeper fixture are compiled through
`test/Integrators.t.sol`, so `forge test` runs the examples (`forge test --match-path
"examples/*"`); the fixture skips. The keeper's tests: `python -m unittest keeper.test_keeper`
(anvil; `KEEPER_E2E_REQUIRE=1` fails instead of skipping). The local walkthrough,
`bash script/local/walkthrough.sh`, deploys on a fresh anvil node, accepts the network, runs
Verify and sells one work end to end ([script/local](../../script/local/README.md)); CI runs it
in its own job.

The other layers have their own commands, in their sections: Halmos
([symbolic proofs](#symbolic-proofs-halmos)), Medusa ([second fuzzer](#second-fuzzer-medusa)),
the fork suites ([Safe fork tests](#safe-fork-tests)), coverage and mutation testing.

## Layers

| Layer | Files | What it proves | Run it | Runs |
| --- | --- | --- | --- | --- |
| Unit | `test/<module>/*.t.sol` | Every function's happy path, every revert by its exact error and arguments, events, access control, and a regression test for every review finding; every rule of the [specification](../spec/README.md) cites the tests that pin it | `forge test --match-path "test/stream/**"` | PR |
| Property fuzz | `testFuzz_*` beside the unit tests | The same properties over random inputs, 256 runs; 10,000 in the `deep` profile | `forge test --match-test testFuzz` | PR; deep nightly |
| Stateful invariants | `*Invariant*.t.sol`, `*.invariant.t.sol`, `test/*/invariant/`, with their handlers | The INV rows of [Invariants](../audit/invariants.md) over random call sequences, 256 runs of 128 calls, `fail_on_revert`; 2,000 of 256 in `deep`. Every campaign has a handler self-test ([below](#handler-self-tests-and-the-new-campaigns)) | `forge test --match-test "^invariant"` | PR; deep nightly |
| Integration | [`test/integration/`](../../test/integration/README.md), and a module's real-stack suites such as `test/sales/auction/Auction*.t.sol` | The real, wired v1 stack, deployed by the deploy library with the committed genesis configuration; only external systems are mocked | `forge test --match-path "test/integration/*"` | PR |
| Gas and state growth | `test/integration/GasReport.t.sol`, the `*Gas*` and `*GasCap*` tests, [`StateGrowth`](../../test/helpers/StateGrowth.sol) | Prague gas ceilings and the exact new storage slots and accounts of every operation ([ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md)), and the 16,777,216 transaction cap for worst-case inputs | `forge test --match-test test_Gas_Table -vv` prints the table | PR |
| Oracles and differential | [`TextOracles`](../../test/helpers/TextOracles.sol), the frozen RC1 code in [`Pr744Utf8`](../../test/helpers/Pr744Utf8.sol) and [`Pr744Escape`](../../test/helpers/Pr744Escape.sol), the vectors in [`test/fixtures/oracles/`](../../test/fixtures/oracles) from [`tools/content/oracles.py`](../../tools/content/oracles.py), the uploader's golden vectors, the edition auction's golden vectors in [`test/fixtures/edition-auction/`](../../test/fixtures/edition-auction) from [`tools/edition_auction_ref.py`](../../tools/edition_auction_ref.py), and [`UniformClearingReference`](../../test/helpers/UniformClearingReference.sol) | Assembly against naive byte loops and against RC1; the JSON scanner against `serde_json` and CPython; the Python uploader against the real `ContentStore`; the edition auction's clearing against the reference model's vectors and a brute-force per-unit clearing | `forge test --match-path "test/content/**"`, and `python -m unittest discover -s tools/content -t . -p "test_*.py"` | PR |
| Symbolic | [`test/symbolic/`](../../test/symbolic) | 67 Halmos proofs (`check_*`): the pure libraries, and the state rules of the permanent contracts (ledger, escrow, governed vault, statement log, Stream and work records, Editions, the federated template) on the real contracts ([below](#symbolic-proofs-halmos)) | `FOUNDRY_PROFILE=symbolic halmos` | after merge and daily, one job per test contract |
| Second fuzzer | [`test/medusa/`](../../test/medusa), [`medusa.json`](../../medusa.json) | Three cheatcode-free harnesses, each with its own model of the rules written from the spec, run by Medusa and by a Forge runner ([below](#second-fuzzer-medusa)) | `medusa fuzz --compilation-target test/medusa/LedgerMedusa.sol --target-contracts LedgerMedusa` | Forge runner on PR; Medusa nightly |
| Fork | [`test/fork/`](../../test/fork/README.md) | The stack against the real delegation contract, Permit2 and the VRF coordinator on local forks of mainnet and Sepolia, and the deploy script simulated on Sepolia; skipped without an RPC URL | `forge test --match-path "test/fork/*"` with `FORK_MAINNET_RPC` and `FORK_SEPOLIA_RPC` set | nightly |
| Safe | `test/fork/Safe*.t.sol` | The network, an artist wallet, holders, the museum and the fee destination as real Safe v1.4.1 wallets on a mainnet fork ([below](#safe-fork-tests)) | `forge test --match-path "test/fork/Safe*" -vv` with `FORK_MAINNET_RPC` set | nightly |
| Log replay | [`test/replay/`](../../test/replay) (`LogReplay*.t.sol`, `*Indexer.sol`); the statement log's handler (`test/records/StatementLogHandler.sol`) | Eight permanent contracts rebuilt from their logs alone; the comparison fails on disagreement; every compiled event is replayed ([below](#log-replay-and-real-data)) | `forge test --match-path "test/replay/*"` | PR |
| Real data | `test/replay/RealVectors.t.sol`, [`test/fixtures/real/`](../../test/fixtures/real), [`tools/make_vectors.py`](../../tools/make_vectors.py) | A 6529 Network Museum record (6529NM-W-0029) through upload, curated sale, record and `tokenURI` | `forge test --match-contract RealVectors`, `python tools/make_vectors.py --check` | PR |
| ABI and storage snapshots | [`test/snapshots/`](../../test/snapshots), [`tools/check_snapshots.py`](../../tools/check_snapshots.py) | Every `src/` contract's ABI (selectors, topics, errors) and storage layout against committed snapshots ([below](#abi-and-storage-snapshots)) | `python tools/check_snapshots.py` | PR (Build and checks) |
| Rule traceability | [`tools/check_rules.py`](../../tools/check_rules.py), [`tools/rules-uncovered.txt`](../../tools/rules-uncovered.txt) | Every spec rule names a test that exists, every invariant names its function ([below](#rule-traceability)) | `python tools/check_rules.py --uncovered` | PR (Docs) |
| Coverage | `forge coverage` and [`tools/check_coverage.py`](../../tools/check_coverage.py) | What no test reaches, per contract, against a floor per contract ([below](#coverage)) | see below | after merge and daily |
| Mutation | [`tools/mutation.py`](../../tools/mutation.py), on `slither-mutate` | Which changes to the code no test notices ([below](#mutation-testing)) | see below | weekly |
| Live | [`script/Verify.s.sol`](../../script/Verify.s.sol) and the records in [`deployments/11155111/`](../../deployments/11155111) | The Sepolia rehearsals: every address, code hash, configuration value and event read back from the chain, and the v1 flows run for real | [`script/README.md`](../../script/README.md) | on demand |
| Tool self-tests | `tools/test_*.py` | Each checker and generator reports the fault it exists to find | `python -m tools.test_check_rules`, and the same for each `tools/test_*.py` | PR |

Conventions: forge-std assertions; `vm.expectRevert` with the exact selector and arguments;
mocks in [`test/mocks/<module>/`](../../test/mocks), one behaviour per name, with the
adversarial ones (tokens that lie about balances, return bombs, gas burners, reentrant
recipients) beside them; a review finding gets a regression test named for the behaviour it
pins, with the finding's ID in a `/// Regression:` NatSpec line
([naming](../../test/README.md#naming)). Every check added by the November 2026 testing build
was shown to fail on a planted fault (a temporary edit of `src/` or of the test, reverted); each
section below says which.

## What CI runs

| Job | When | What | Time | Required |
| --- | --- | --- | --- | --- |
| Contracts | every pull request and push to `main` | the summary of Build and checks, the six Tests jobs and the Local walkthrough, green only when all are | seconds, after the last of them | yes |
| Build and checks | every pull request and push | `forge fmt --check`, `forge build` (from the cached compiler output), the docs facts against the build, the ABI and storage snapshots, the real-data vectors and event topics (`make_vectors.py --check`), the exported ABIs (`export_abis.py --check`), the format of `examples/` and `keeper/test/`, the budget gate, the genesis check, the content and convention tooling tests, the reference keeper's tests on anvil (`KEEPER_E2E_REQUIRE=1`), and the tools' unit tests | about 3.5 min before this build; the snapshot and vector checks add about two seconds | through Contracts |
| Tests (unit, fuzz and integration) | every pull request and push | `forge test --no-match-test ^invariant`: also the replay suites, the real-data vectors and the Medusa harnesses' self-tests | about 1 min before this build; the replay suites add under a second after the build | through Contracts |
| Tests (economics invariants, escrow and marks) | every pull request and push | six of the economics invariants (`invariant_Dust*`, `invariant_Escrow*`, `invariant_Intermediaries*`, `invariant_Marks*`, `invariant_Observed*`): 256 runs of depth 128 | not yet measured on a runner since the split | through Contracts |
| Tests (economics invariants, releases) | every pull request and push | the other four (`invariant_Recipients*`, `invariant_Released*`, `invariant_Wallet*`): 256 runs of depth 128 | not yet measured on a runner since the split | through Contracts |
| Tests (testing-build invariants) | every pull request and push | the four campaigns added in November 2026 (`WorkDelivery`, `GovernedVault`, `FederatedState`, `CurationSigner`): 256 runs of depth 128 | 18 to 70 s each locally; not yet measured on a runner | through Contracts |
| Tests (auction invariants) | every pull request and push | the English and edition auction invariant suites (`Auction*`, `EditionAuction*`): 256 runs of depth 128 | not yet measured on a runner | through Contracts |
| Tests (other invariants) | every pull request and push | every other invariant suite, the Medusa harnesses' Forge runners (64 runs of depth 64) among them | about 7 min before this build; the runners add about 22 s locally | through Contracts |
| Local walkthrough | every pull request and push | `forge build`, then `bash script/local/walkthrough.sh`: deploy on anvil, accept, Verify, and one work sold end to end | about 1.5 min locally after a build; not yet measured on a runner | through Contracts |
| Static analysis | every pull request and push | Slither 0.11.6: no untriaged High or Medium finding | about 1 min | yes |
| Docs | every pull request and push | relative links and anchors in Markdown, the generated role matrix, the facts the docs quote from the code, and rule traceability (`check_rules.py`, which lists the known uncovered rules) | under 1 min | no |
| Coverage (`.github/workflows/strength.yml`) | every push to `main`, every day at 04:30 UTC, and on demand | `forge coverage` under the lite profile; the per-contract table in the job summary; fails when a contract drops below its floor; uploads `lcov.info` | about 4 min | no (not on pull requests) |
| Symbolic (Halmos) (`strength.yml`) | as Coverage | one job per `*SymbolicTest` contract in `test/symbolic` (a listing job finds them and fails if a `check_*` sits outside one), each with a 30-minute limit; a job fails unless every proof its contract declares passed | 67 proofs in 8 min locally (the longest contract 2.5 min with its build); not yet run on a runner since the matrix | no (not on pull requests) |
| Nightly (`.github/workflows/nightly.yml`) | every day at 03:30 UTC, and on demand | the invariant suites under the `deep` profile (2,000 runs of depth 256) in five jobs of up to 3 hours (the economics invariants in two, the four new campaigns, the auctions, the others); every fuzz test at 10,000 runs (`deep`); one 30-minute Medusa campaign per harness (45-minute job, the release checked against a pinned SHA-256, the corpus cached); the fork tests in `test/fork` (the Safe suites included) against public mainnet and Sepolia endpoints | locally: deep fuzz 10.5 min on 48 threads (5.9 CPU hours, so roughly 1.5 hours on a 4-core runner); the four new campaigns under `deep` about 68 min; the fork suites 6 s from the RPC cache. The deep fuzz, the new deep partition and the Medusa jobs have not run on a runner | no (scheduled) |
| Mutation (`.github/workflows/mutation.yml`) | weekly, Sunday 02:00 UTC, and on demand; one small shard when a push to `main` changes the workflow or the tool | every shard of `tools/mutation.py`, eight jobs at a time, each stopped at a 335-minute budget; the merged report in the run summary, with a row for every planned file; fails, naming the shard or contract, when a planned shard left no results or ran out of its budget, a contract has no floor, or a contract's kill rate drops below its floor | several hours | no (scheduled) |

`forge test` runs in six parts whose filters together select every test exactly once (3,259
tests on 22 November 2026: 3,160, 6, 4, 16, 25 and 48; the 12 examples and the keeper fixture fall
in the first), so the parts run on separate runners. Each
part restores the latest compiler output and compiles only what changed. The 15-minute CI
budget applies to each job. The fourth part holds the four campaigns of this build, which
added about 60% to the other invariants' CPU time locally (2,730 to 4,358 CPU seconds), more
than a shared runner's other-invariants job could take within its budget. The organisation's
runners are shared, so a run's wall time is mostly the wait for them. The auction invariants
became a part of their own, and the economics invariants two parts split by test, on
21 November 2026, when those jobs reached or neared that
budget.

Coverage and the Halmos proofs run after a merge rather than on the pull request, to keep the
shared runners for the required checks. A change that may lower coverage or touch a proven
contract should run them locally first (the commands are below); a regression otherwise shows
on `main`'s next run.

**What has run only locally.** Every figure on this page from the November 2026 testing build
was measured on one Windows machine. Not yet run in CI: the Medusa campaigns, the per-contract
Halmos matrix, the deep fuzz job, the deep partition of the four new campaigns, the fourth Tests
partition, and the snapshot, traceability and vector steps. Each is first proven on its first
pull request, merge or scheduled run.

## ABI and storage snapshots

```bash
forge build
python tools/check_snapshots.py            # compare
python tools/check_snapshots.py --update   # rewrite, after an agreed change
```

Every contract and library declared in `src/` (interfaces and abstract contracts excepted) has
`test/snapshots/abi/<Name>.json`: each function, event and error with its full ABI entry
(parameter names, internal types, mutability, indexed flags), its canonical signature, and its
selector or topic0. Every contract also has `test/snapshots/storage/<Name>.json`: the slot,
offset, type and declaring contract of each state variable, and of each member of each struct
stored anywhere in its storage, keyed by the struct's qualified name, with no compiler AST IDs.
The tool reads the artifacts in `out/`; `extra_output = ["storageLayout"]` in `foundry.toml`
puts the layout there and changes no bytecode (every artifact's creation and runtime code was
compared byte for byte before and after the line was added). It fails on any difference, on a
contract without a snapshot, and on a snapshot whose contract is gone, and it runs in about a
second. Storage the code addresses itself at fixed slots in assembly is not in the compiler's
layout: [`StreamLayout.t.sol`](../../test/stream/StreamLayout.t.sol) pins the slots the
renderer reads. The tool's unit tests plant a renamed parameter, a changed event, a new error, a
moved slot, a retyped and a shifted struct member, a missing and a stale snapshot, and show each
fails; on the real tree a parameter renamed in `GovernedVault` and a state variable inserted
before its destination failed both of its snapshots, and the edit was reverted.

## Rule traceability

```bash
python tools/check_rules.py --uncovered
```

Every rule row of `docs/spec/*.md` and every property (`PROP-*`) of
[Invariants](../audit/invariants.md) must name in its tests cell at least one test function
(`test_*`, `testFuzz_*`, `invariant_*`, `check_*`, `property_*`; a `*` matches any characters
and must match at least one) or an invariant or property ID that resolves. A test file alone is
not a test, and a named test that does not exist fails whatever else the cell names. Every
invariant (`INV-*`) must name in its Test cell a function that exists: an `invariant_*`
function, a handler action, or an `afterInvariant` hook. A rule with no test today is listed in
[`tools/rules-uncovered.txt`](../../tools/rules-uncovered.txt) as `removed` (the row only says
the rule was removed), `declaration` (an off-chain convention) or `uncovered`, and is reported
as known uncovered. The list can only shrink: an entry for a rule that now names a test, or for
an ID the spec does not define, fails the check.

On 21 November 2026, 458 rules and 107 invariants resolve; known uncovered are 6 removed
rows, the 30 declaration rows (`DCL-*`, whose conventions the Python tests in
`tools/conventions/` exercise) and 3 live rules: FED-57, GV-18 and GV-20. Writing the
checker found five rules that cited only a test file or an abbreviation (GV-12, GV-15, GV-19,
GV-21, ID-16), one property that cited only a file (PROP-GAS-5), one invariant whose Test cell
named no function (INV-ECO-8), and one property citing `test_WorstCase_*` in
`ArtistRegistry.t.sol`, which matches no test (PROP-GAS-7); the first seven now name the tests
that pin them, and the stale citation was removed. The rule cells also name the proofs, Medusa
properties, replay, Safe and campaign tests of the November 2026 build that cover them.

## Handler self-tests and the new campaigns

A campaign whose handler actions return early passes without testing anything. Every campaign
now has a self-test. Seven replay campaign-shaped sequences of their own (`test_EveryActionRuns`
and its kin, listed in [Invariants](../audit/invariants.md#campaign-settings)); the other
seventeen have `test_HandlerPathsReachState`, built on
[`HandlerReach`](../../test/helpers/HandlerReach.sol): it calls every targeted handler action
with mixed-width arguments, reads each call's state diff, and fails unless every action changed
a contract under test, was refused by one, moved the clock or called it, as its expectation
names; then it checks every invariant on the state the drive left. Each self-test was shown to
fail with one handler action made to return at once.

Writing them found four handlers that had not been exercising what they were written for, all
fixed in the test code: the Stream handler's stale-consent replay always replayed the current
rate, so INV-STR-4's refusal was never reached; the work-records governance handler failed every
preference call after its first delivery swap; the federation handler's `bid` landed almost no
bids (runs with a sold federated sale went from 8 to 22 of 40); the refusal campaign's
`claimDelivery` never succeeded (it now claims as the party the auction names, still rarely).

Four new campaigns (256 x 128, `fail_on_revert`): delivery contracts (INV-WD-1 to INV-WD-4),
the governed vault (INV-ECO-15 to INV-ECO-17), federated template state (INV-FED-1 to
INV-FED-6) and curation signers (INV-CUR-7 to INV-CUR-9). Each invariant was shown to fail on a
planted fault in `src/` (for example a dead locator mark overwritten, `forward` paying the
caller, a federated SOLD stored as FROZEN_OUT, a re-enabled signer keeping its epoch); two
passed at first because the model followed the forbidden success, and now count that success
directly. Locally: 18 to 70 s each at the default size, about 68 minutes in all under `deep`.

## Second fuzzer (Medusa)

```bash
FOUNDRY_OUT=out-medusa FOUNDRY_CACHE_PATH=cache-medusa medusa fuzz --config medusa.json \
  --compilation-target test/medusa/LedgerMedusa.sol --target-contracts LedgerMedusa --timeout 600
forge test --match-path "test/medusa/*"                     # the Forge runners and self-tests
```

Three harnesses, each with its own model of the rules written from the spec, sharing no code
with any `*Handler.sol`: no forge-std, no cheatcodes, every action through `Actor` contracts,
and no action ever reverts. Each predicts every call's outcome (`property_ModelPredictsEveryOutcome`).

| Harness | Real contracts | Properties (rules) |
| --- | --- | --- |
| `LedgerMedusa` | `SplitLedger`, `SplitVault` wallets, `RevenueEscrow`, `GovernedVault` | `WalletsConserveValue` (ECO-14, INV-ECO-1, INV-ECO-12), `ReleasedWithinEntitlement` (ECO-13, INV-ECO-2, ECO-44), `DustIsBounded` (INV-ECO-5), `EscrowIsSolvent` (ECO-27, INV-ECO-6, ECO-40, ECO-45, ECO-28), `NoUnauthorizedRelease` (ECO-15 to ECO-17, ECO-5, ECO-20, ECO-21, ECO-41), `NetworkShareIsPaidOrDue` (ECO-43, INV-ECO-14) |
| `StreamMedusa` | `Stream`, `WorkRecords`, `ContentStore` | `SupplyIsMintedMinusBurned` (INV-STR-1), `IdsNeverReused` (INV-STR-2), `SettledOnlyByTheMintingAdapter` (INV-STR-6, INV-STR-11), `FinalizedRecordsNeverChange` (INV-STR-8), `RenouncedMaskOnlyGrows` (INV-STR-12, WS-37, WS-38), `NoContentMintsTwice` (INV-STR-16, AUC-44) |
| `LogMedusa` | `StatementLog`, `Editions` | `CountAndHeadMatchTheModel` (DSP-1, DSP-10), `RolesWriteOnlyTheirKinds` (DSP-3 to DSP-5), `SpentNoncesStaySpent` (INV-DSP-7, DSP-9), `EditionSupplyAccounting` (INV-ED-2, ED-5), `SealedSupplyHolds` (INV-ED-6, ED-25) |

Each harness has a Forge runner (`invariant_MedusaPropertiesHold`, 64 runs of depth 64) and
`test_HarnessActionsReachState`. Twelve planted faults in `src/`, four per harness (a release
that skips `totalReleased`, `releaseTo` without its payout check, a flush that pays the caller, a
forfeit before 180 days; settlement by any admitted adapter, a burn after settlement, a renounce
that clears a bit, a second mint of consumed content; a head that skips a field, a revocation
that does not spend the nonce, a seal reopened, a mint past the cap) each broke a property
under Medusa within one to three minutes. Under Forge the 64 x 64 runner missed two of them (the
cleared bit and the reopened seal), which only the self-test caught.

Medusa 1.5.1 has run locally on Windows only. Ten-minute campaigns of each harness passed every
property (about 816, 3,370 and 2,920 calls a second); on the integrated branch, two-minute runs
of each passed again (145,000, 441,000 and 362,000 calls), with the targeted compile through
crytic-compile 0.4.2 from the repository's lock. It has not run in CI.

## Safe fork tests

```bash
FORK_MAINNET_RPC=https://ethereum-rpc.publicnode.com forge test --match-path "test/fork/Safe*" -vv
```

[`SafeForkBase.sol`](../../test/fork/SafeForkBase.sol) uses Safe v1.4.1's singleton, proxy
factory, `MultiSendCallOnly` and `CompatibilityFallbackHandler` at their canonical addresses,
each code-hash pinned. The network and the fee vault's destination are 2-of-3 Safes; the deploy
library installs genesis and the network Safe accepts it in a real Safe transaction.
[`SafeNetwork.t.sol`](../../test/fork/SafeNetwork.t.sol) (9 tests): delayed setters scheduled and
executed through the manager in MultiSend batches (GV-2, ECO-4, ECO-37, ECO-41), a stale revision
reverting the whole batch, a direct call and a one-of-three signature refused, the no-delay
signer kill (CUR-17, CUR-23, CUR-24), unpause, the brake (GV-5, GV-6) and a handover to a second
Safe. [`SafeAccounts.t.sol`](../../test/fork/SafeAccounts.t.sol) (11 tests): a Safe as an artist
account signing wallet-prefixed ERC-1271 proofs (acceptance and move, CUR-7, CUR-10; a relayed
statement, DSP-9; royalty consent, WS-14; a signed release, ECO-20), each invalidated by an owner
swap; a Safe releasing its own share, bidding, winning a 721 and receiving 1155 copies; the museum
and fee destinations as Safes. Planted faults: a threshold of 3 with two signatures, a 1.3.0 or
L2 singleton, the 1.3.0 `MultiSendCallOnly`, a setter called directly, the SafeMessage wrapping
dropped, MultiSend by CALL: each failed. With the public endpoints, all 20 Safe tests and the 24
other fork tests passed on the integrated branch (6 s wall from Foundry's RPC cache). publicnode
serves no archive state, so a pinned block must be recent.

## Log replay and real data

```bash
forge test --match-path "test/replay/*"
python tools/make_vectors.py --check                        # fixtures reproduce byte for byte
```

Each indexer in [`test/replay/`](../../test/replay) consumes `Vm.Log` records of one emitter and
nothing else (it never calls its contract), written from
[Events and indexing](../integrators/events-and-indexing.md): Stream and work records, the split
ledger and the escrow, Editions, the content store, the federation registry and the artist
registry's federated directory. Each suite runs a history that emits every event, then compares
every public view with the indexer's state (WS-44, WS-23, ECO-10 to ECO-22, ECO-27, ECO-28,
ECO-40, ECO-44, ECO-45, ED-5, ED-7, ED-25 to ED-27, WS-27, WS-50 to WS-54, FED-43 to FED-49,
FED-64, FED-65), checks every event in the compiled ABI was replayed (`event-topics.json`, written
by `make_vectors.py`), and has a control: one `vm.store` makes the comparison fail. Planted
faults (a stale `RoyaltyRateChanged`, a dropped `StoreRetired`, a stale seal, a dropped
`ChunkLinked`, `NonceUsed`, `Flushed` or `RecoveryConsentSet`, a stale `AdapterSet` or federated
share) each failed. The four gaps the lane found (Stream's genesis dependencies, the finalized
renderer's code hash, whether an escrow recovery used a consent, an edition's artist ID) were
fixed in the contracts' events, and are now ordinary replay checks.

[`RealVectors.t.sol`](../../test/replay/RealVectors.t.sol) takes the 6529 Network Museum record
6529NM-W-0029, copied byte for byte from a pinned commit of the Museum's CC0 records (the artwork
image itself is not copied: only its length, SHA-256 and chunk hashes), uploads the record with
the uploader's layout, sells the work through a curated sale, opens and finalizes the record, and
checks the file IDs, SHA-256, six `tokenURI` fragments and a catalogue statement's hash against
the fixture.

## Coverage

```bash
FOUNDRY_PROFILE=lite forge coverage --report lcov --report summary --allow-failure
python tools/check_coverage.py --uncovered
```

- **Profile.** Coverage instruments unoptimized code, so it runs under `lite`
  ([`foundry.toml`](../../foundry.toml)): the same sources and compiler, with 64 fuzz runs
  and 16 invariant runs of depth 64. That is enough to reach every line and branch the full
  campaigns reach: two runs with different fuzz seeds gave identical per-contract figures.
  No `--ir-minimum` is needed; the unoptimized legacy pipeline compiles every contract.
- **Expected failures.** Without the optimizer about 80 gas-ceiling tests fail
  (`GasReport`, the `*Gas*` and `*GasRule*` tests, the `tokenURI` budgets, the lens
  differential's long sequences, and `DeployScriptTest`, whose deployment runs out of gas
  unoptimized). `--allow-failure` keeps the run going and writes the report; the Tests jobs run
  every test for real.
- **The gate.** [`tools/coverage-floors.json`](../../tools/coverage-floors.json) holds a
  floor per src/ contract: the measured figure minus a margin of 1 point for lines and 2 for
  branches, rounded down to 0.1. A contract below either floor fails the check. A src/ file
  with no entry must meet the default floor (95% lines, 85% branches), so new code arrives
  tested; an entry whose file no longer reports coverage also fails, so the floors follow the
  tree. The floors are per contract because a total hides a regression in a small, critical
  file behind growth elsewhere. The margin is small because the figures are stable across
  fuzz seeds; it still fails the first unreached line of any contract under 100 lines.
- **Raising floors.** After adding tests, `python tools/check_coverage.py --write-floors`
  rewrites the floors from the run; review the diff. Lowering a floor needs a reason in the
  pull request.

Measured on 21 November 2026, on `claude/coverage` (main at ff334c1f with the coverage tests of
that branch; Foundry 1.7.1, lite profile). Of the 58 src/ contracts with code, 49 are at 100% of
lines, branches and functions; `check_coverage.py` prints all of them. The others, and what they
leave unreached:

| Contract | Lines | Branches | Unreached |
| --- | ---: | ---: | --- |
| `economics/TokenTransfer.sol` | 98.55% (68/69) | 94.12% (16/17) | `transferExact`'s own revert: unreachable, because the strict transfer path never returns false (it reverts inside) |
| `editions/Editions.sol` | 99.62% (260/261) | 100% (58/58) | `settlePrimary`'s `return nothing;`: the function runs, but the coverage map gives that statement no executed code |
| `federated/FederatedEditions.sol` | 99.17% (120/121) | 100% (24/24) | the same `return nothing;` in its `settlePrimary` |
| `sales/EnglishAuction.sol` | 99.57% (461/463) | 98.00% (98/100) | `_isTarget`'s listed-token return (its callers ask only for unlisted or federated tokens), and a locked fee share above the denominator |
| `sales/EnglishAuctionLens.sol` | 99.51% (204/205) | 91.67% (22/24) | `refusableAt` for an unknown sale, and for a sale whose pause ran its full course; not yet tested |
| `sales/UniformEditionAuction.sol` | 99.60% (503/505) | 95.45% (84/88) | `abandon` in the wrong state, the soft close capped by the backstop, a position past 2^32, and the 2^24th terms record; not yet classified |
| `sales/UniformEditionAuctionLens.sol` | 99.81% (513/514) | 96.59% (85/88) | a split factory that returns another wallet, one branch of `_abandon`'s 1/1 end, and `_sorted`'s skip of entries below `from`; not yet classified |
| `stream/Stream.sol` | 100% (454/454) | 97.67% (84/86) | the 65,536th fee recipient and the 2^23rd terms word in the overflow range |
| `stream/WorkRecords.sol` | 100% (431/431) | 97.75% (87/89) | `mediaStore` past the work's media count, and a content store that returns a short `FileInfo`; not yet classified |
| **src/ total** | **99.88% (7,283/7,292)** | **98.89% (1,427/1,443)** | functions 100% (1,062/1,062) |

Since then the mutation gap lane's `test_Start_RevertsWhenTheSaleAlreadyExists` reaches `start`
on a sale that already exists: on d50bb61's code with the lane's tests, `EnglishAuction.sol`
leaves only the locked fee share above the denominator, at 98.96% of branches (95/96). ADR 0005
has since removed `MintSaleBase` with the fixed-price and Dutch adapters; its row is kept as
measured.

## Mutation testing

```bash
python tools/mutation.py list                       # the shards
python tools/mutation.py run libraries-Utf8         # in a scratch checkout: it edits src/
python tools/mutation.py report mutation --markdown mutation/report.md
```

- **Tool.** `slither-mutate`, part of the Slither release CI already pins
  ([`requirements-tools.lock`](../../requirements-tools.lock)), so mutation testing adds no
  tool. It has 15 operators: replace a function body with a revert, comment out a statement,
  swap relational, arithmetic, logical, bitwise, unary and assignment operators, replace
  integer literals, wrap statements in `if` and `while`, change variable initialisers and
  function headers, and Solidity-specific swaps. Gambit and vertigo-rs were the
  alternatives; both would add a tool to pin and maintain (Gambit only generates mutants, so
  it also needs a harness to compile and test them), for operators slither-mutate largely
  shares.
- **CONST.** slither-mutate never changes a `constant`, and the protocol's limits are
  constants, so `tools/mutation.py` adds one rule: every integer-literal constant is moved one
  up and one down, and each change must fail a test.
- **How a shard runs.** One shard per src/ file, planned from the tree, so a new file gets
  its shard with nothing to register. The thirteen files whose whole shard does not finish in
  a 6-hour CI job (`ContentStore`, `JsonScan`, `Renderer`, `PackageRegistry`,
  `GovernanceConfig`, `ArtistRegistry`, `EnglishAuction`, `EnglishAuctionLens`,
  `UniformClearing`, `UniformEditionAuction`, `UniformEditionAuctionLens`, `Stream`,
  `WorkRecords`; `SPLIT_FILES` in the tool) are split into four shards that run in parallel:
  statements (revert, comment, CONST),
  arithmetic, logical and unary operators, relational operators, and `if` conditions. They skip
  the other eight operators, which on these files gave hours of almost only equivalent or
  repeated mutants (nine assignment variants of one subtraction, a literal 0 replaced by 0,
  `storage` read as `memory`, a `constant` read as `immutable`); every other file runs all
  fifteen. On those files the
  relational shard makes two replacements per comparison (the boundary shift and the equality
  flip, which subsume the other three) instead of five. Seven more files whose single shard
  does not finish in a job keep every operator and all five relational replacements
  (`RevenueEscrow`, `SplitLedger`, `FederatedEditions`, `FederatedMembership`, `FederatedStream`,
  `FederationRegistry`, `WorkDelivery`; `FULL_SPLIT_FILES`): they run as five shards, the four
  groups plus the eight operators the others skip, so their mutants are exactly a single
  shard's and their floors were measured on the same mutants. The relational shard of two of
  them runs in parts (`RELATION_PARTS`: `FederatedStream` in four, `FederationRegistry` in
  three; on the second campaign it took about 10 and 5 hours): part k of n mutates every n-th
  comparison from the k-th, in the order the operator visits them, with every replacement, so
  the parts together make the whole shard's mutants. Each mutant runs the tests of its
  module first, under the `lite` profile with `--fail-fast`; every survivor then runs against
  the whole suite, so a mutant an integration test kills counts as killed. A mutant whose
  tests time out (20 minutes) counts as killed, as slither-mutate counts it; the report
  lists how many. In CI a shard also has a 335-minute budget (`run --budget`), below the job's
  6-hour limit, where a cancelled job would leave no results at all. A shard still mutating
  then stops, restores `src/`, and reports `timeout` (its file belongs in `SPLIT_FILES`). A
  shard still re-checking has run every mutant against its module's tests: it stops there,
  the survivors it did not re-check count as survived, and the report lists the contract's
  rate as a lower bound with how many were left.
- **Zero comparisons.** For an unsigned value, `x == 0` read as `x <= 0` (and `x != 0` as
  `x > 0`, `x > 0` as `x != 0`, `x <= 0` as `x == 0`, and the mirrors) cannot change anything,
  and each such survivor cost a full re-check, so the fixed ROR does not make those
  replacements; it makes every other one.
- **The report.** `report --shards` takes the run's plan, so every planned file gets a row. A
  planned shard that left no results (a cancelled job, a lost runner) marks its file
  `missing` and names the shard, and a split file with some groups missing is not scored as if
  it were whole. The run fails with an annotation per contract.
- **Limits.** Inside inline assembly slither-mutate only comments out statements (its operator
  rules read Solidity expressions), so the word-level logic of `Utf8`, `JsonEscape`,
  `JsonScan`, `DataUri`, `HtmlScript`, `Base64Validator` and `SSTORE2` gets fewer mutants than
  Solidity code does; the oracles and the Halmos proofs cover it. The Halmos proofs are not
  part of the mutants' test command, so a survivor there may still be caught by a proof; triage
  says so. Many assembly survivors only change how far a scan skips ahead, which
  changes gas and not results. A gas test can kill a mutant that only makes the code more
  expensive; that still shows the change is observable.
- **Floors.** [`tools/mutation-floors.json`](../../tools/mutation-floors.json) holds a
  kill-rate floor per contract, a measured rate minus 2 points (`margin`) rounded down to a
  whole point, and `report --floors` fails when a contract drops below its floor, did not
  finish, has mutants and no floor (so a new src/ file gets one from its first run), or has a
  floor and no mutants (the run measured nothing, a log the tool could not read, say).
  `python tools/mutation.py report mutation --write-floors tools/mutation-floors.json`
  writes the floors of the contracts a run measured and keeps the others. A unit test checks
  that every floor names a src/ file with code.
- **slither-mutate 0.11.6 fixes.** `tools/mutation.py` runs slither-mutate through a shim
  that fixes three bugs found here. ROR (relational operators) aborted on the first Yul
  comparison it met, which silently dropped every relational mutant of the eight contracts
  with assembly comparisons; LIR (literals) aborted on any `bool` literal; and on Windows,
  restoring files in text mode turned LF into CRLF, which misplaced every mutant after the
  first. The fixed ROR also replaces only the operator between the two operands (the stock
  one wrote the whole statement's text into the comparison's place, so many of its mutants
  did not compile) and skips Yul comparisons; LIR gives `bool` the values `false` and `true`.

**Status.** The first full baseline is in [mutation-baseline.md](mutation-baseline.md): 11,735
mutants of 054442d's code in 50 contracts, 88.2% killed by the campaign and 90.6% by the final
suite, 98.9% once the 992 equivalent mutants are left out. Every survivor is triaged there, and
`tools/mutation-floors.json` holds a floor for each contract the baseline measured. 289 of the
campaign's survivors were gaps in the suite. The final suite kills 280 of them: 211 through
tests written for the baseline, and 69 through the gap lane that followed it, which also
re-triaged 3 (2 equivalent, 1 defensive) and found 6 moved by #66 into the `Dependency`
library, where the replacing code's mutants are killed. No gap is open. Running the tool on
the libraries, the content readers and the economics module while it was built already found
checks the suite was missing, now pinned by tests: ill-formed UTF-8 lead bytes cut at a chunk
end; an escape letter other than `u` before four hex digits; JSON and script escaping reading
past the input's end; a token that refuses `approve` by
reverting, returns more than one word, or sets the upper bits of its `true`, and balances above
2**128; the resolver's bounds on each side; and CC0 license texts either side of the pinned
one.

**Second campaign (21 to 22 November 2026).** The files the permanence passes added had no
floor, and the permanent contracts the second pass rewrote had stale ones. A second campaign on
eac9dd2e measured 19 files (two with nothing to mutate) in about 153 hours of shard time on 22
checkouts: 5,093 mutants, 4,518 killed by the campaign (88.7%) and 4,819 by the final suite
(94.6%), every remaining survivor argued equivalent, gas-only or defensive. It set or raised
their floors; its tables and the triage of every survivor are in
[mutation-baseline.md](mutation-baseline.md#second-campaign-21-to-22-november-2026). It wrote
107 new tests, and extended about 26, for its gaps, each run against the mutant it kills. None
of its survivors was a defect in a contract; three were access checks no test pinned
(`ArtistRegistry.resolveContested`, `FederationRegistry.setStatus`, and `FederatedStream`'s
`setLocator` and `setDefaultRenderer`), now pinned. It did not reach every stale floor, and two
of its shards ran longer than the weekly job allows (now split in parts): see
[what it did not reach](mutation-baseline.md#not-reached).

**Third batch (22 November 2026).** The files the second campaign did not reach ran as the tool's
own shards on two rented 96-core machines: 14 files, 5,917 mutants once `GovernanceConfig`'s
earlier groups are added, 5,476 killed (92.5%) and 5,548 by the final suite (93.8%). 45 new tests,
each run against the mutant it kills, pin among others the content store's checks on an added
source's answer, `StatementLog`'s relay delay, a fee share at and above the denominator, the
auction's re-entry guard on `expireCredit` and the governance readback. Midway the owner decided
to restructure `Stream`, `WorkRecords`, `Editions` and the English and edition auctions with their
lenses; for those seven only rule-level tests were kept (access, who may act, who is paid), their
other 232 survivors are listed as deferred with a category, and their floors are unchanged.
`ContentStore`, `StatementLog`, `EditionRules`, `WorksAccessManager`, `Roles`, `GovernanceConfig`
and `GovernanceConfigurator` were triaged in full and their floors set or raised. No survivor was
a defect. `UniformEditionAuction` now measures 88.6%, below its floor of 91, until the restructure
or a reset. Tables and triage:
[third batch](mutation-baseline.md#third-batch-22-november-2026).

## Symbolic proofs (Halmos)

```bash
python -m pip install --require-hashes --only-binary=:all: --no-deps -r requirements-tools.lock
FOUNDRY_PROFILE=symbolic halmos
```

[`halmos.toml`](../../halmos.toml) holds the options, and the `symbolic` profile compiles
only `test/symbolic` into `out-symbolic/` (run Halmos itself to build it: a plain
`forge build` there leaves artifacts without the AST Halmos reads). The solver is the pinned
`yices-smt2` from the lock, so Halmos downloads nothing. A proof marked **unbounded** covers
every input; one marked **bounded** covers every input up to the size it states, and nothing
beyond.

| Library | Proof (`check_*`) | Scope |
| --- | --- | --- |
| `Base64Validator.isAlphabet` | `isAlphabet_fullWord`: the word-at-a-time test equals the byte-by-byte RFC 4648 alphabet test | unbounded: every 32-byte word |
| | `isAlphabet_everyPrefixOfTwoWords`: the same for every prefix of a two-word buffer, which is left unchanged | unbounded content, lengths 0 to 64 |
| | `isAlphabet_restoresTheNeighbouringWord`: a buffer not padded to a word keeps the memory after it | unbounded content, lengths 1 to 31 |
| `SpdxId` | `spdxId_matchesTheRuleForEveryInput`: the memory and calldata forms equal the byte-range rule | every input of 0 to 65 bytes: the whole rule |
| `BoundedCall` | `hasSufficientGas_neverReverts`: the gas rule is total | unbounded |
| | `tryRead_copiesOnlyWhatFits`, `tryRead_failuresCopyNothing`, `readWord_acceptsExactlyOneWord`: a return is copied exactly when it fits, failures copy nothing, `readWord` takes exactly one word | every content, `maxReturn` and gas limit; return sizes 0, 1, 31, 32, 33, 63, 64, 65 and 96 |
| | `decodeString_acceptsOnlyCanonical`, `decodeString_rejectsLengthsPastTheBuffer`, `decodeString_acceptsEveryCanonicalEncoding`: exactly the canonical ABI encodings are accepted | every content, offset word and `maxLength`; buffers of 64 to 128 bytes (strings of 0 to 64 bytes) |
| `Eip712CurationVerifier` epochs | `signerEpoch_packsItsFieldsInjectively`: grant time, salt and change count each sit in their own bits | unbounded: every stored signer state |
| | `disableAndEnable_alwaysEndTheEpoch`: every disable and enable changes the epoch and the approval digest | unbounded |
| `Splits` | `validate_acceptsExactlyTheCanonicalLists`: the payee-list rule, payee by payee | every field; lists of 0 to 3 payees |
| | `royaltyPayees_isCanonical`: the royalty wallet's payee list is canonical | unbounded |
| `Utf8` | `utf8_isValidMatchesTheOracle`, `utf8_streamingAtEverySplitEqualsWhole`, `utf8_returnedStatesAreWellFormed`: the validator against a code-point decoder, streamed across every split | bounded: every input of up to 4 bytes |
| `JsonEscape` | `jsonEscape_matchesTheOracle` | bounded: every input of up to 4 bytes |
| `DataUri` | `dataUri_findsEveryHitInAWord`, `dataUri_ignoresTheBytesPastTheEnd`: a `%` or `#` is found wherever it is | unbounded: every 32-byte and 31-byte text |
| `HtmlScript` | `htmlScript_matchesTheReference`: output and `<` cap against a reference | bounded: every input of 4 to 6 bytes |
| | `htmlScript_endTagInAnyCase`: `</script` in every case mix | bounded: 8 to 10 bytes starting `</` |
| `StepLadder.mantissa` | `mantissa_isBoundedAndStrictlyIncreasing`: the packed E192 table is 100 to 988, strictly rising, and its last entry is below ten times its first, so every ladder rises across decades | unbounded: every index |
| `UniformClearing.clear` | `clear_isD138UncappedOnThreeSteps`, `clear_isD138CappedOnTwoSteps`, `clear_isD138WithNoMargin`, `clear_isD138AtTheLargestMargin`: the result is D138 unit by unit (`R*` is attained and no count earns more; the result passes the margin and no larger count does; its step, price and cut-step fields) | bounded: every unit count from 0 to 255 on fixed steps of the 100-wei, 48-a-decade ladder; 3 steps a decade apart (0, 48, 96) uncapped at 10%; 2 neighbouring steps (2, 3) under every cap from 1 to 255 at 10%; 2 steps (0 and 48, 0 and 34) under every cap below 256 or none at 0% and 50% |
| `UniformClearing.sweep`, `wonAtCut` | `sweep_unitsWonSumToTheCutInArrivalOrder`: the swept cut-off hands out exactly the cut units, first in first out | bounded: queues of 5 entries of 1 to 255 units, any of them departed |
| | `sweep_acceptsExactlyTheNextDeparture`, `wonAtCut_isTheClamp`: the order check and the clamp | unbounded (64-bit positions and units for the sweep) |

Every proof was checked to fail when a bug is planted in the library it covers (a sort test
made non-strict in `Splits`, a bit flipped in the `SpdxId` mask, a range constant moved in
`Base64Validator`, a field shifted in the epoch, the padding check dropped in
`decodeString`, overlong two-byte forms let through in `Utf8`, upper-case hex in
`JsonEscape`, two mantissas swapped in `StepLadder`, a strict margin comparison in
`UniformClearing.clear`, a sweep that moves the cut-off one unit too far).

**Stateful proofs.** Six test contracts (`LedgerSymbolic`, `EscrowSymbolic`,
`StatementLogSymbolic`, `StreamSymbolic`, `EditionsSymbolic`, `FederatedSymbolic`) run the real
permanent contracts behind a real AccessManager, with stand-ins for their neighbours (`Sym*`),
"any caller, any action index" inputs and branch-free helpers (`SymHelpers`, after the
provenance registry's `_and`, `_or`, `_pick`). Each proof names its rules and states its bounds
in NatSpec. The stand-ins for signatures and consents accept everything, so the proofs cover who
may call, nonces and state, not ECDSA or ERC-1271 themselves.

| Contract | Proof (`check_*`) | Rules | Bounds |
| --- | --- | --- | --- |
| `SplitLedger`, `SplitVault` | `release_neverExceedsEntitlement`, `release_paysOnlyThePayeesOwnAccount`, `artistPayee_onlyTheCurrentPayoutReleases`, `signedRelease_nonceIsSingleUse`, `nonces_inOneWordAreIndependent`, `failedSignedRelease_keepsItsNonce`, `vault_obeysOnlyItsLedger`, `mark_cannotBeReplacedAndForfeitWaits180Days` | ECO-13, INV-ECO-2, ECO-15 to ECO-17, ECO-20 to ECO-22, ECO-39, ECO-44, INV-ECO-14 | ETH only, 64-bit receipts, fixed EOA payees and recipients; one payee across two deposits |
| `RevenueEscrow`, `GovernedVault` | `flush_paysOnlyTheCreditedWallet`, `expiry_waits180Days`, `sweepExcess_neverTouchesOwed`, `recover_onlyToTheEquivalentWallet`, `everyGovernedWrite_needsItsRole`, `governedVault_paysOnlyItsDestination` | ECO-27, ECO-45, ECO-40, INV-ECO-13, ECO-28, INV-ECO-10, ECO-5, ECO-41 | ETH only, 64-bit credits; any caller and any restricted selector |
| `StatementLog` | `append_servesOnlyArtistAndOwner`, `outcomeKinds_onlyFromTheirRole`, `noEntryNamesTheManager`, `relay_deadlineNonceAndSigner`, `head_followsTheFormula` | DSP-3, DSP-4, DSP-5, DSP-9, DSP-1, DSP-10 | a fixed URI (its UTF-8 rule is `TextSymbolicTest`'s); two appends with symbolic fields |
| `Stream`, `WorkRecords` | `settlePrimary_onlyTheMintingAdapterOnce`, `burn_onlyTheMintingAdapterBeforeSettlement`, `everyRestrictedStreamWrite_needsItsRole`, `renounce_onlyGainsBits`, `renouncedPower_alwaysReverts`, `royaltyRate_atMost100000`, `cc0_isIrrevocable`, `finalizedRecord_refusesSetRecordAndFinalize`, `perTokenCalls_revertUntilOpen` | INV-STR-6, INV-STR-11, INV-STR-7, DSP-20, INV-STR-12, INV-STR-13, WS-37, WS-38, INV-STR-14, WS-12, INV-STR-8, WS-1 | 11 Stream and 6 WorkRecords restricted selectors; license identifiers of 3 bytes, or 3 bytes and "-1.0" |
| `Editions` | `mint_neverPassesTheCap`, `seal_isOnceAndBoundsMints`, `boundAdapter_neverRebinds` | INV-ED-2, INV-ED-6, ED-25, INV-ED-5 | the master's content hash is keccak (Halmos 0.3.3 fails on the SHA-256 precompile there) |
| `FederatedStream` | `noRestrictedFunction_onATemplate`, `beforeJoining_nothingMints`, `settle_onlyTheMintingAdapterOnce`, `royaltyRate_onlyFalls`, `feeShareInForce_isTheMinimum` | FED-4, FED-5, FED-16, FED-24, FED-73 | any caller and action index |

Each stateful proof was shown to fail on a planted fault in `src/` (for example a release that
skips `totalReleased`, a nonce bit computed with the wrong mask, `sweepExcess` ignoring
`totalOwed`, settlement by any admitted adapter, an equal federated rate accepted, max taken for
min in the fee share). One exception: with the CC0 comparison dropped, the fully symbolic
`cc0_isIrrevocable` did not finish within 30 minutes; with the identifier fixed to "mit" (a
proof-side edit, reverted) the same fault failed in half a second. All 67 proofs passed on the
integrated branch on 17 November 2026 in 8 minutes of wall time (Halmos 0.3.3, yices); the
longest contracts were `TextSymbolicTest` (147 s with its build), `UniformClearingSymbolicTest`
(91 s) and `StreamSymbolicTest` (49 s).

**Not proved, and why.**

- **`UniformClearing` on larger books, and `StepLadder.price` with a symbolic base.** The
  library branches on every used step, so the paths multiply: three neighbouring steps without a
  cap already timed out (a 120 s solver query), and the plan's five steps would not fit the CI
  job. Every price of every ladder symbolic in the base needs 256-bit division by 100 and timed
  out too; the table proof above and the floor `base * x / 100` rising with `x` (for a base of at
  least 100) give the order instead. The brute force over unit bids (10,000 fuzz runs), the
  two-pass step reference on up to 512 steps of 32-bit units, the golden vectors in
  [`test/sales/uniform/`](../../test/sales/uniform), and every step of every ladder at the
  domain's extreme bases cover them.

- **`Splits.entitlement`** (equals `mulDiv`, never above what was observed, the sum of the
  shares at most it with bounded dust). Every formulation tried, at full width and with
  `observed` bounded to 2**128, 2**64 and even to the denominator, and with a
  multiplication-only specification, timed out in yices and in z3 after 5 to 15 minutes:
  each needs a 256-bit division. These properties stay with the full-range fuzz tests in
  [`SplitMath.t.sol`](../../test/economics/SplitMath.t.sol) and the economics invariants.
- **`BoundedCall.hasSufficientGas`'s exact value** and its EIP-150 consequence (the callee
  gets the whole limit): the division by 63 times out the same way, even for 64-bit gas
  amounts. The boundary unit tests in
  [`BoundedCall.t.sol`](../../test/libraries/BoundedCall.t.sol) cover them.
- **The auction's 96-bit increment.** After #57 the step is an expression inside
  `_minNextBid`, a view over the sale's storage, not a pure function, so it is skipped. A
  pure helper would make it a candidate, but it divides by the denominator too.
- **Base64 encoding and attestation.** The protocol decodes no base64. Encoding is
  OpenZeppelin's `Base64` (table lookups at data-dependent memory offsets, which Halmos
  cannot follow); the uploader's golden vectors check it against Python's `base64`.
  Attestation is stateful (`ContentStore` over SSTORE2 chunks); its pure core is
  `Base64Validator`, proved above, and `Base64Attest.t.sol` covers the padding.
- **Longer text.** The bounded proofs stop where the paths multiply (each byte branches) or
  where an output's length depends on a symbolic count (Halmos cannot write memory at a
  symbolic offset). The differential fuzz tests and the Python oracles cover longer inputs.

**Stability.** Halmos 0.3.3 crashed once on a CI runner inside Z3 while Python's cyclic
garbage collector ran; `disable-gc` in `halmos.toml` turns that collector off. Running one test
contract at a time (`--match-contract`) makes a crash name its contract while the rest still
report. The results are otherwise deterministic: the solver and every input are pinned. The 23
proofs before the edition auction take about 4 minutes on a GitHub runner; the 8 for
`UniformClearing` and `StepLadder` took about 3 more locally with 4 solver threads, a runner's
core count.

## Gaps: the next testing lane

What the measurements above leave for the next lane, most valuable first in each group. Items
that need a change under `src/` are for the module owners; the rest are tests.

**From mutation testing:**

The baseline's 78 open gaps are closed: the gap lane killed 69 with focused tests, re-triaged 3,
and found 6 moved by #66 ([how each was decided](mutation-baseline.md#what-survives-and-why)).
None was a bug.

**rc.2 (November 2026).** The weekly run on 808705c1 and the runs on rc.2's code that followed
it (PR #95) measured the contracts the baseline never saw, and every survivor of the edition
auction's files was triaged. Kill rates and the floors they set:

| Contract | Killed | Kill rate | Floor |
| --- | ---: | ---: | ---: |
| `UniformEditionAuction` | 1,064 of 1,142 | 93.2% | 91 |
| `UniformEditionAuctionLens` | 731 of 818 | 89.4% | 87 |
| `UniformClearing` | 274 of 288 | 95.1% | 93 |
| `StepLadder` | 205 of 217 | 94.5% | 92 |
| `EnglishAuctionLens` | 316 of 332 | 95.2% | 93 |
| `Dependency` | 42 of 43 | 97.7% | 95 |

Fifty-seven survivors, about twenty gaps, are now killed by tests: an underpaid raise and steps
past the ladder; the stored soft end at the backstop; a second network fee recipient overwriting
the first one's index (an earlier sale's fee would have gone to the newer recipient); one-call
settlement below the cap and at a rationed step without departures; the scan stopping at the
cap; every field of `setConfig`'s expectation and an unpause after its delay; the lens's paging
heap for departures logged in position order and shuffled (only reverse order was tested), a
quote that pulls units in, and the views' guards. None was a bug in `src/`. The rest are
equivalent (unsigned and enum orderings, statement-form increments, a cached end the 1/1 only
moves later), defensive (bounds of 65,535 configurations or fee recipients, reentrancy guards
with no untrusted call inside) or event-only (a zero `Credited` on a full win).

The same pass re-checked every floor on rc.2's code. Three baseline floors were set from fewer
mutants than the CI run makes of the same code, and are recorded again from it, every survivor
triaged: `EditionRules` 85 (rewritten by #76; 14 of 16, the two left equivalent), `TokenTransfer`
90 (166 of 180; unsigned and enum comparisons, the dead strict-path branch, and lying-token
balance checks) and `SignatureVerifier` 80 (84 of 102; the comparisons behind OpenZeppelin's own
checks, as the baseline triaged them, and the ERC-1271 gas margin). Tests written for the
others' survivors keep their floors: `Eip712CurationVerifier` (the decoder's length and offset
bounds, ERC-165) and `AssetAllowlist` (`statusClock`'s `inactiveTotal`, which no test read).

What mutation testing still leaves: only an exact-gas harness would see the gas-margin
survivors, and only a lying mock of a trusted contract the defensive ones.

**From coverage:**

1. `TokenTransfer.transferExact` checks `_transfer`'s result and reverts, but the strict path
   never returns false (`_moveExact` reverts on any failure when it does not tolerate one), so
   the branch is dead. Remove it or say why it stays (src/ owners).
2. The edition auction's new files (`UniformEditionAuction`, its lens, `UniformClearing`,
   `StepLadder`) have no measured figures yet; they start at the default floor (95% of lines,
   85% of branches) until `main`'s next coverage run sets theirs.
3. A relicense consent from a party that never registered as an artist takes
   `WorkRecords`' `artistIdOf == 0` fallback, which today ends in the registry's
   `UnknownArtist`. Decide the intended outcome and test it.
4. Defensive guards that need a lying mock to reach: a registry that assigns another artist
   ID, or reports a zero authority (`PackageRegistry`); a malformed `consume` answer and the
   65,536th fee recipient and the 2**23rd overflow terms word, reachable with `vm.store`
   (`Stream`); a short `FileInfo`
   (`WorkRecords`); a locked fee share above the denominator (`EnglishAuction`).

**From the symbolic proofs:**

1. `Splits.entitlement`'s arithmetic and `BoundedCall.hasSufficientGas`'s exact rule: try
   bitwuzla (Halmos can fetch a checksum-pinned binary of it; it handles bit-vector division
   far better than yices and z3), or run them in a scheduled job with hour-long timeouts.
2. The auction's increment step: a pure helper would make it a candidate after #57 (it divides
   by the denominator, so expect the same difficulty as `Splits`).
3. The word-at-a-time paths of `Utf8` and `JsonEscape` (32 bytes and more) are fuzzed only.
   Proofs over one symbolic byte at each position of an otherwise fixed word would cover the
   word classification.

**Missing layers:**

1. A scheduled live check. The nightly run forks mainnet and Sepolia, but nothing reads the
   recorded Sepolia deployment back on a schedule. Running `Verify.s.sol` against it nightly
   would catch drift between the record and the chain.
2. Halmos's invariant mode for small state machines (the curation verifier's signer state, the
   escrow's credit book) with a depth of two or three calls.

**Process:**

1. Coverage and Symbolic report on `main`, after the merge. If the runner queue allows, run
   them on pull requests again and make them required checks.

## What is not tested

- **No external audit.** The project is pre-audit ([SECURITY.md](../../SECURITY.md)).
- **What has run only locally.** The Medusa campaigns, the per-contract Halmos matrix, the deep
  fuzz job, the deep partition of the four new campaigns, the fourth Tests partition and the
  snapshot, traceability and vector steps have run on one Windows machine and not yet in CI.
  The fork and Safe suites have run locally against public endpoints, not on a test network.
- **Bounded proofs only.** The Halmos proofs cover every input within the bounds stated in
  [Symbolic proofs](#symbolic-proofs-halmos): ETH only and 64-bit amounts for the money proofs,
  one payee across two deposits, 3-byte license identifiers, fixed URIs, keccak in place of
  SHA-256 for an edition's content hash. Not proved: the share arithmetic across payees (256-bit
  division), multi-payee release interleavings, fully symbolic 7-byte license identifiers, ECDSA
  and ERC-1271 themselves. No other prover (Certora, SMTChecker) has been run.
- **The second fuzzer's stand-ins.** The Medusa harnesses replace the AccessManager with a stub
  authority (no role matrix or delays) and stand in for the mint policy, artist registry,
  economics resolver and renderers; Editions reads a stub Stream. They do not cover hostile
  tokens, gas shortfall paths, relicensing or royalty consents, `syncOnChain`, `bindMinter` or
  ECDSA signatures (ERC-1271 only).
- **Safe coverage.** No relicense (WS-13) through a Safe (royalty consent covers the same
  consent path); no Safe as a fixed payee (a fixed payee must be a party account); no Safe as the
  federated fee recipient (ECO-3); no Sepolia variant.
- **Replay coverage.** Not replayed: artist-registry identity changes and `WorkDelivery`
  (replaceable); balances (`observed`, `releasable`) and chunk bytes are not in logs by design; a
  value whose key no log names is compared only for probed keys. Editions are sold through a
  stand-in adapter in the replay suite, not the edition auction. No Memes card is among the real
  data: only one Museum record, whose image bytes are not stored.
- **Campaign gaps.** Listed in [Invariants: Gaps](../audit/invariants.md#gaps): among them the
  refusal campaign's rare pending deliveries, curation signers' execution-delay changes, and
  delivery successors carrying a predecessor's locators.
- **Rules without a test.** Three live rules name no test: FED-57 (the federated pair's use of
  the shared edition auction base), GV-18 (every governed setter emits old and new values) and
  GV-20 (dependency checks across setters). The 30
  declaration rules are off-chain conventions ([rule traceability](#rule-traceability)).
- **Mutation floors.** Every file the weekly run mutates has a floor. `BoundedParameter` and
  `UniformClearing` keep floors measured before later rewrites. `Stream`, `WorkRecords`,
  `Editions`, `EnglishAuction`, `UniformEditionAuction` and both lenses were measured by the
  [third batch](mutation-baseline.md#third-batch-22-november-2026) but keep their earlier floors
  while they are restructured; 232 of their survivors are deferred untested, and
  `UniformEditionAuction` measures below its floor. Since 21
  November 2026 every src/ file with executable code has its own coverage floor
  ([coverage](#coverage)).
