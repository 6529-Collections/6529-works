# Testing

How the 6529 Works test suite is organised, how to run each part, what CI runs and when,
and how strong the tests are measured to be. The project is pre-audit: a strong suite is
evidence for reviewers, not a substitute for an audit. [The test map](../../test/README.md)
says where the tests for a contract, a function or a review finding live, and how tests and
mocks are named.

The suite has layers because each one catches a different kind of mistake. Unit tests pin
the behaviour someone thought of. Fuzz and invariant tests find the inputs and call
sequences nobody thought of. Integration tests catch two correct modules that disagree.
Oracles catch a fast implementation that drifts from a simple one. Symbolic proofs close
the input space where it is small enough. Coverage shows what no test reaches, and mutation
testing shows what the tests reach but do not check.

## Layers

| Layer | Where | What it gives | Run it |
| --- | --- | --- | --- |
| Unit | `test/<module>/*.t.sol` | Every function's happy path, every revert by its exact selector, events, access control, and a regression test for every review finding | `forge test --match-path "test/stream/**"` |
| Fuzz | `testFuzz_*` beside the unit tests | The same properties over random inputs, 256 runs each | `forge test --match-test testFuzz` |
| Invariant | `*Invariant*.t.sol`, `*.invariant.t.sol` and `test/*/invariant/`, with their handlers | Stateful properties over random call sequences: 256 runs of depth 128, `fail_on_revert` on; the `deep` profile runs 2,000 of depth 256 | `forge test --match-test invariant_`, and `FOUNDRY_PROFILE=deep forge test --match-test invariant_` |
| Integration | [`test/integration/`](../../test/integration/README.md), and a module's real-stack suites such as `test/sales/auction/Auction*.t.sol` | The real, wired v1 stack, deployed by the deploy library with the committed genesis configuration; only external systems are mocked | `forge test --match-path "test/integration/*"` |
| Gas and state growth | `test/integration/GasReport.t.sol`, the `*Gas*` and `*GasCap*` tests, [`StateGrowth`](../../test/helpers/StateGrowth.sol) | Prague gas ceilings and the exact new storage slots and accounts of every operation ([ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md)), and the 16,777,216 transaction cap for worst-case inputs | `forge test --match-test test_Gas_Table -vv` prints the table |
| Oracles and differential | [`TextOracles`](../../test/helpers/TextOracles.sol), the frozen RC1 code in [`Pr744Utf8`](../../test/helpers/Pr744Utf8.sol) and [`Pr744Escape`](../../test/helpers/Pr744Escape.sol), the vectors in [`test/fixtures/oracles/`](../../test/fixtures/oracles) from [`tools/content/oracles.py`](../../tools/content/oracles.py), the uploader's golden vectors, the edition auction's golden vectors in [`test/fixtures/edition-auction/`](../../test/fixtures/edition-auction) from [`tools/edition_auction_ref.py`](../../tools/edition_auction_ref.py), and [`UniformClearingReference`](../../test/helpers/UniformClearingReference.sol) | Assembly against naive byte loops and against RC1; the JSON scanner against `serde_json` (`vm.parseJsonKeys`) and CPython; the Python uploader against the real `ContentStore`; the edition auction's clearing, outcomes and settlement order against the reference model's vectors and, on random books, against a brute-force per-unit clearing (`EditionAuctionDifferential.t.sol`) | `forge test --match-path "test/content/**"`, and `python -m unittest discover -s tools/content -t . -p "test_*.py"` |
| Symbolic | [`test/symbolic/`](../../test/symbolic) | Halmos proofs (`check_*`) for the pure libraries, some for every input and some for every input up to a size ([below](#symbolic-proofs-halmos)) | `FOUNDRY_PROFILE=symbolic halmos` |
| Coverage | `forge coverage` and [`tools/check_coverage.py`](../../tools/check_coverage.py) | What no test reaches, per contract, against a floor per contract ([below](#coverage)) | see below |
| Mutation | [`tools/mutation.py`](../../tools/mutation.py), on `slither-mutate` | Which changes to the code no test notices ([below](#mutation-testing)) | see below |
| Fork | [`test/fork/`](../../test/fork/README.md) | The stack against the real delegation contract, Permit2 and the VRF coordinator on local forks of mainnet and Sepolia, and the deploy script simulated on Sepolia; skipped without an RPC URL | `forge test --match-path "test/fork/*"` with `FORK_MAINNET_RPC` and `FORK_SEPOLIA_RPC` set |
| Live | [`script/Verify.s.sol`](../../script/Verify.s.sol) and the records in [`deployments/11155111/`](../../deployments/11155111) | The Sepolia rehearsals: every address, code hash, configuration value and event read back from the chain, and the v1 flows run for real | [`script/README.md`](../../script/README.md) |

Invariant suites exist for the split wallets, escrow and claim router; the English auction
(in ETH and in an ERC-20, and its halts); Editions; Stream; the content store; the package
registry; the artist registry; the statement log; the VRF entropy module; governance; and, on
the wired stack, a work's lifecycle and the edition auction.

Conventions: forge-std assertions; `vm.expectRevert` with the exact selector and arguments;
mocks in [`test/mocks/<module>/`](../../test/mocks), one behaviour per name, with the
adversarial ones (tokens that lie about balances, return bombs, gas burners, reentrant
recipients) beside them; a review finding gets a regression test named for the behaviour it
pins, with the finding's ID in a `/// Regression:` NatSpec line
([naming](../../test/README.md#naming)).

## What CI runs

| Job | When | What | Time | Required |
| --- | --- | --- | --- | --- |
| Contracts | every pull request and push to `main` | the summary of the four jobs below, green only when all four are | seconds, after the last of them | yes |
| Build and checks | every pull request and push | `forge fmt --check`, `forge build` (from the cached compiler output), the docs facts against the build, the budget gate, the genesis check, the content tooling tests, and the coverage and mutation tools' unit tests | about 3.5 min | through Contracts |
| Tests (unit, fuzz and integration) | every pull request and push | `forge test --no-match-test ^invariant` | about 1 min | through Contracts |
| Tests (economics invariants) | every pull request and push | the economics invariant suite: 256 runs of depth 128 | about 2 min | through Contracts |
| Tests (other invariants) | every pull request and push | every other invariant suite: 256 runs of depth 128 | about 7 min | through Contracts |
| Static analysis | every pull request and push | Slither 0.11.6: no untriaged High or Medium finding | about 1 min | yes |
| Docs | every pull request and push | relative links and anchors in Markdown, the generated role matrix, and the facts the docs quote from the code | under 1 min | no |
| Coverage (`.github/workflows/strength.yml`) | every push to `main`, every day at 04:30 UTC, and on demand | `forge coverage` under the lite profile; the per-contract table in the job summary; fails when a contract drops below its floor; uploads `lcov.info` | about 4 min | no (not on pull requests) |
| Symbolic (Halmos) (`strength.yml`) | as Coverage | every `check_*` in `test/symbolic`, one test contract at a time; fails unless every declared proof passes | about 7 min (31 proofs) | no (not on pull requests) |
| Nightly (`.github/workflows/nightly.yml`) | every day at 03:30 UTC, and on demand | the invariant suites under the `deep` profile (2,000 runs of depth 256), economics and the others in two jobs of up to 3 hours; the fork tests in `test/fork` against public mainnet and Sepolia endpoints | about an hour | no (scheduled) |
| Mutation (`.github/workflows/mutation.yml`) | weekly, Sunday 02:00 UTC, and on demand; one small shard when a push to `main` changes the workflow or the tool | every shard of `tools/mutation.py`, eight jobs at a time; the merged report in the run summary; fails when a planned shard left no results, or a contract's kill rate drops below its floor | several hours | no (scheduled) |

`forge test` runs in three parts whose filters together select every test exactly once (2,486
tests at v1.0.0-rc.1: 2,411, 7 and 68), so the parts run on separate runners. Each
part restores the latest compiler output and compiles only what changed. The 15-minute CI
budget applies to each job. Before the split, one Contracts job built and ran everything in 11
to 13 minutes; split, the longest part (the other invariants, where most suites are) takes
about 7 minutes, and the rest finish in 1 to 4. The organisation's runners are shared, so a
run's wall time is mostly the wait for them.

Coverage and the Halmos proofs run after a merge rather than on the pull request, to keep the
shared runners for the required checks. A change that may lower coverage or touch a proven
library should run them locally first (the commands are below); a regression otherwise shows
on `main`'s next run.

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
- **Expected failures.** Without the optimizer about 51 gas-ceiling tests fail
  (`GasReport`, the `*Gas*` tests, the `tokenURI` budgets). `--allow-failure` keeps the run
  going and writes the report; the Tests jobs run every test for real.
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

Measured on 15 October 2026, on `main` at 054442d (after #63) with these tests (Foundry 1.7.1,
lite profile). Of the 46 src/ contracts with code, 40 are at 100% of lines, branches and functions;
`check_coverage.py` prints all of them. The others, and what they leave unreached:

| Contract | Lines | Branches | Unreached |
| --- | ---: | ---: | --- |
| `curation/PackageRegistry.sol` | 98.99% (196/198) | 95.45% (42/44) | two defensive reverts: an artist registry that returns another ID than the one it just assigned, and `releaseContent` to an artist whose authority is zero (the registry reverts `UnknownArtist` first) |
| `economics/TokenTransfer.sol` | 98.28% (57/58) | 92.31% (12/13) | `transferExact`'s own revert: unreachable, because the strict transfer path never returns false (it reverts inside) |
| `sales/EnglishAuction.sol` | 100% (433/433) | 97.98% (97/99) | `start` on a sale that already exists, and a locked fee share above the denominator |
| `sales/MintSaleBase.sol` (deleted in rc.2) | 99.40% (167/168) | 98.00% (49/50) | `claim` of an ERC-20: unreachable, since only ETH was ever credited (Dutch refunds) |
| `stream/Stream.sol` | 100% (288/288) | 94.34% (50/53) | a package registry that returns a malformed `consume` result, the 65,536th fee recipient, and the 2**23rd terms word in the overflow range |
| `stream/WorkRecords.sol` | 100% (366/366) | 97.53% (79/81) | consent from a party that never registered as an artist, and a content store that returns a short `FileInfo` |
| **src/ total** | **99.91% (4,624/4,628)** | **98.96% (1,043/1,054)** | functions 100% (661/661) |

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
- **How a shard runs.** One shard per src/ file. The seven largest files (`Renderer`,
  `JsonScan`, `PackageRegistry`, `ArtistRegistry`, `EnglishAuction`, `Stream`, `WorkRecords`)
  are split into four shards that run in parallel: statements (revert, comment, CONST),
  arithmetic, logical and unary operators, relational operators, and `if` conditions. They skip
  the other eight operators, which on these files gave hours of almost only equivalent or
  repeated mutants (nine assignment variants of one subtraction, a literal 0 replaced by 0,
  `storage` read as `memory`); every other file runs all fifteen. On those seven files the
  relational shard makes two replacements per comparison (the boundary shift and the equality
  flip, which subsume the other three) instead of five. Each mutant runs the tests of its
  module first, under the `lite` profile with `--fail-fast`; every survivor then runs against
  the whole suite, so a mutant an integration test kills counts as killed. A mutant whose
  tests time out (20 minutes) counts as killed, as slither-mutate counts it; the report
  lists how many.
- **Limits.** Inside inline assembly slither-mutate only comments out statements (its operator
  rules read Solidity expressions), so the word-level logic of `Utf8`, `JsonEscape`,
  `JsonScan`, `DataUri`, `HtmlScript`, `Base64Validator` and `SSTORE2` gets fewer mutants than
  Solidity code does; the oracles and the Halmos proofs cover it. The Halmos proofs are not
  part of the mutants' test command, so a survivor there may still be caught by a proof; triage
  says so. Many assembly survivors only change how far a scan skips ahead, which
  changes gas and not results. A gas test can kill a mutant that only makes the code more
  expensive; that still shows the change is observable.
- **Floors.** [`tools/mutation-floors.json`](../../tools/mutation-floors.json) holds a
  kill-rate floor per contract, a baseline minus 2 points, and `report --floors` fails when a
  contract drops below its floor.
  `python tools/mutation.py report mutation --write-floors tools/mutation-floors.json`
  rewrites them from a run.
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
None was a bug. What mutation testing still leaves:

1. `src/libraries/Dependency.sol`, which #66 added after the campaign, has no baseline row and
   no floor; record both from the weekly run's report. Its own suite,
   `test/libraries/Dependency.t.sol`, pins each check (code, the EIP-7702 refusal, ERC-165, and
   both sides of each code-hash comparison), so its mutants die in the fast first pass.
2. Only an exact-gas harness would see the 32 gas-margin survivors, and only a lying mock of a
   trusted contract the 74 defensive ones.
3. The edition auction (ADR 0005) adds `UniformEditionAuction`, `UniformEditionAuctionLens`,
   `UniformClearing` and `StepLadder` with no baseline row and no floor. Record both from the
   first weekly run after they land, then triage every survivor as the baseline did; the
   differential fuzz and the real-stack invariant suite run in the second pass, so a mutant only
   they notice still counts as killed. The deleted fixed-price and Dutch contracts' floors left
   `tools/mutation-floors.json` with them.

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
